local config = require("gelbooru.core.config")
local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local constants = require("gelbooru.core.constants")

local uv = vim.uv or vim.loop

local M = {}

M.PRIORITY_PREVIEW = constants.PRIORITY_PREVIEW
M.PRIORITY_PREFETCH = constants.PRIORITY_PREFETCH
M.PRIORITY_AUTOPAGE = constants.PRIORITY_AUTOPAGE
M.PRIORITY_METADATA = constants.PRIORITY_METADATA

M.TIER_URGENT = constants.TIER_URGENT or 1
M.TIER_LOOKAHEAD = constants.TIER_LOOKAHEAD or 2
M.TIER_THUMBNAIL = constants.TIER_THUMBNAIL or 3
M.TIER_INDEXER = constants.TIER_INDEXER or 4

M.RATE_LIMIT_RPS = constants.RATE_LIMIT_RPS
M.RATE_LIMIT_MIN_INTERVAL_MS = constants.RATE_LIMIT_MIN_INTERVAL_MS
M.RATE_LIMIT_MAX_CONCURRENT_SOCKETS = constants.RATE_LIMIT_MAX_CONCURRENT_SOCKETS

M.active_downloads = {}
M.active_handles = {}
M.pending_resumes = {} -- guards the async gap between scan and active_downloads registration
M.interrupted_dests = {} -- dests killed by teardown; callbacks skip rename and preserve .part
M.interrupted_handles = {}
M.queued_retries = {}
M.active_prefetch_handles = {}
M.queued_prefetch_dests = {}
M.last_prefetch_dir = nil
M._prefetch_timer_meta = {}

-- Centralized Token-Bucket Rate Governor & Priority Queue
local governor = {
  active_sockets = 0,
  last_dispatch_time = 0,
  last_refill_time = 0,
  tokens = constants.RATE_LIMIT_MAX_CONCURRENT_SOCKETS,
  timer = nil,
  queues = {
    [1] = {},
    [2] = {},
    [3] = {},
    [4] = {},
  },
}
M.governor = governor

function governor.now_ms()
  return (vim.uv or vim.loop).hrtime() / 1e6
end

function governor.refill()
  local now = governor.now_ms()
  if governor.last_refill_time == 0 or governor.last_dispatch_time == 0 then
    governor.tokens = constants.RATE_LIMIT_MAX_CONCURRENT_SOCKETS
    governor.last_refill_time = now
    return
  end
  local elapsed = now - governor.last_refill_time
  if elapsed > 0 then
    local added = elapsed * (constants.RATE_LIMIT_RPS / 1000)
    governor.tokens = math.min(constants.RATE_LIMIT_MAX_CONCURRENT_SOCKETS, (governor.tokens or 0) + added)
    governor.last_refill_time = now
  end
end

function governor.queue_count()
  local count = 0
  for p = 1, 4 do
    for _, task in ipairs(governor.queues[p] or {}) do
      if not task.killed then
        count = count + 1
      end
    end
  end
  return count
end

function governor.is_empty()
  for p = 1, 4 do
    local q = governor.queues[p]
    if q and #q > 0 then
      for _, task in ipairs(q) do
        if not task.killed then
          return false
        end
      end
    end
  end
  return true
end

function governor.reset(notify_cancelled)
  if governor.timer and not governor.timer:is_closing() then
    pcall(function()
      governor.timer:stop()
      governor.timer:close()
    end)
  end
  governor.timer = nil
  governor.active_sockets = 0
  governor.active_preview_sockets = 0
  governor.last_dispatch_time = 0
  governor.last_refill_time = 0
  governor.tokens = constants.RATE_LIMIT_MAX_CONCURRENT_SOCKETS

  if notify_cancelled then
    for p = 1, 4 do
      local q = governor.queues[p] or {}
      for _, task in ipairs(q) do
        if not task.killed and task.on_cancel then
          pcall(task.on_cancel)
        end
      end
    end
  end

  governor.queues = {
    [1] = {},
    [2] = {},
    [3] = {},
    [4] = {},
  }
end

function M.reset_rate_governor()
  governor.reset(false)
end

function governor.schedule_dispatch(delay_ms)
  if state.State.torn_down then
    return
  end
  delay_ms = math.max(1, delay_ms or 1)
  if not governor.timer or governor.timer:is_closing() then
    governor.timer = (vim.uv or vim.loop).new_timer()
  end
  governor.timer:stop()
  governor.timer:start(delay_ms, 0, vim.schedule_wrap(function()
    governor.dispatch()
  end))
end

local function _schedule_token_refill(gov)
  gov = gov or governor
  local needed = 1 - (gov.tokens or 0)
  local wait_ms = math.max(1, math.ceil(needed / (constants.RATE_LIMIT_RPS / 1000)))
  gov.schedule_dispatch(wait_ms)
end

function governor.release_socket(priority)
  governor.active_sockets = math.max(0, governor.active_sockets - 1)
  if priority == constants.PRIORITY_PREVIEW then
    governor.active_preview_sockets = math.max(0, (governor.active_preview_sockets or 0) - 1)
  end
  if not governor.is_empty() then
    governor.refill()
    if (governor.tokens or 0) >= 1 - 1e-9 then
      governor.dispatch()
    else
      _schedule_token_refill(governor)
    end
  end
end

function governor.dispatch()
  if state.State.torn_down then
    return
  end

  governor.refill()

  while true do
    local next_task = nil
    for p = 1, 4 do
      local q = governor.queues[p]
      while q and #q > 0 do
        local candidate = q[1]
        if candidate.killed then
          table.remove(q, 1)
        else
          local can_dispatch = false
          if p == constants.PRIORITY_PREVIEW then
            local max_sockets = (governor.active_preview_sockets or 0) == 0
              and constants.RATE_LIMIT_BURST_SOCKETS
              or constants.RATE_LIMIT_MAX_CONCURRENT_SOCKETS
            local has_tokens = (governor.tokens or 0) >= 1 - 1e-9
            local can_burst_token = (governor.active_preview_sockets or 0) == 0
            if governor.active_sockets < max_sockets and (has_tokens or can_burst_token) then
              can_dispatch = true
            end
          else
            if governor.active_sockets < constants.RATE_LIMIT_MAX_CONCURRENT_SOCKETS and (governor.tokens or 0) >= 1 - 1e-9 then
              can_dispatch = true
            end
          end

          if can_dispatch then
            next_task = table.remove(q, 1)
            break
          else
            break
          end
        end
      end
      if next_task then
        break
      end
    end

    if not next_task then
      break
    end

    -- Consume token and socket, then dispatch immediately
    governor.tokens = math.max(0, (governor.tokens or 1) - 1)
    governor.active_sockets = governor.active_sockets + 1
    if next_task.priority == constants.PRIORITY_PREVIEW then
      governor.active_preview_sockets = (governor.active_preview_sockets or 0) + 1
    end
    governor.last_dispatch_time = governor.now_ms()

    local ok, err = pcall(next_task.run)
    if not ok then
      log("ERROR", "GOVERNOR", "Task dispatch execution error: %s", tostring(err))
      if next_task.socket_active then
        next_task.socket_active = false
        governor.release_socket(next_task.priority)
      end
    end
  end

  if not governor.is_empty() and governor.active_sockets < constants.RATE_LIMIT_MAX_CONCURRENT_SOCKETS then
    governor.refill()
    if (governor.tokens or 0) < 1 - 1e-9 then
      _schedule_token_refill(governor)
    end
  end
end

function governor.enqueue(task)
  local p = task.priority or constants.PRIORITY_METADATA
  p = math.max(1, math.min(4, p))
  task.priority = p
  if p == constants.PRIORITY_PREVIEW then
    table.insert(governor.queues[constants.PRIORITY_PREVIEW], 1, task)
  else
    table.insert(governor.queues[p], task)
  end
  governor.dispatch()
end

function governor.upgrade_priority(dest, new_priority)
  if not dest then return end
  new_priority = math.max(1, math.min(4, new_priority or 1))

  local q_cur = governor.queues[new_priority]
  if q_cur and new_priority == constants.PRIORITY_PREVIEW then
    for i, task in ipairs(q_cur) do
      if task.dest == dest and not task.killed then
        if i > 1 then
          table.remove(q_cur, i)
          table.insert(q_cur, 1, task)
          governor.dispatch()
        end
        return
      end
    end
  end

  for p = new_priority + 1, 4 do
    local q = governor.queues[p]
    if q then
      for i, task in ipairs(q) do
        if task.dest == dest and not task.killed then
          table.remove(q, i)
          task.priority = new_priority
          table.insert(governor.queues[new_priority], 1, task)
          governor.dispatch()
          return
        end
      end
    end
  end
end

function governor.reorder_prefetch(cur_idx, dir)
  local q = governor.queues[constants.PRIORITY_PREFETCH]
  if not q or #q <= 1 then
    return
  end
  cur_idx = cur_idx or 1
  dir = dir or 1

  table.sort(q, function(a, b)
    if a.killed ~= b.killed then
      return b.killed
    end

    local idx_a = a.post_idx
    local idx_b = b.post_idx

    if not idx_a and not idx_b then
      return false
    elseif not idx_a then
      return false
    elseif not idx_b then
      return true
    end

    local rank_a = util.directional_rank(idx_a, cur_idx, dir)
    local rank_b = util.directional_rank(idx_b, cur_idx, dir)

    return rank_a < rank_b
  end)
end

function M.escalate_preview(dest)
  governor.upgrade_priority(dest, constants.PRIORITY_PREVIEW)
end

function M.is_downloading(dest)
  return M.active_downloads[dest] ~= nil
end

function M.reorder_prefetch_queue(cur_idx, dir)
  governor.reorder_prefetch(cur_idx, dir)
end

function governor.prune_tasks(cur_idx, window)
  window = window or constants.PREWARM_SLIDING_WINDOW or 10
  cur_idx = cur_idx or 1
  for p = 1, 4 do
    local q = governor.queues[p]
    if q then
      local i = 1
      while i <= #q do
        local task = q[i]
        if task.post_idx and math.abs(task.post_idx - cur_idx) > window then
          table.remove(q, i)
          task.killed = true
          if task.handle then
            task.handle.killed = true
          end
          if task.dest and M.active_downloads[task.dest] then
            local cbs = M.active_downloads[task.dest]
            M.active_downloads[task.dest] = nil
            M.active_handles[task.dest] = nil
            for _, fn in ipairs(cbs) do
              pcall(fn, false)
            end
          end
          if task.on_cancel then
            pcall(task.on_cancel)
          end
        else
          i = i + 1
        end
      end
    end
  end
end

governor.prune_prefetch = governor.prune_tasks

function M.prune_out_of_radius(cur_idx, window)
  window = window or constants.PREWARM_SLIDING_WINDOW or 10
  cur_idx = cur_idx or (state.State and state.State.cur) or 1
  governor.prune_tasks(cur_idx, window)

  local UI = state.UI
  if UI and UI.prefetch_timers then
    for timer, tval in pairs(UI.prefetch_timers) do
      local t = (type(timer) == "userdata" or type(timer) == "table") and timer or tval
      local meta = M._prefetch_timer_meta and M._prefetch_timer_meta[t]
      if meta and meta.post_idx and math.abs(meta.post_idx - cur_idx) > window then
        if not t:is_closing() then
          pcall(t.stop, t)
          pcall(t.close, t)
        end
        UI.prefetch_timers[timer] = nil
        if meta.dest and M.queued_prefetch_dests then
          M.queued_prefetch_dests[meta.dest] = nil
        end
        if M._prefetch_timer_meta then
          M._prefetch_timer_meta[t] = nil
        end
      end
    end
  end
end

M.prune_prefetch_queue = M.prune_out_of_radius

local function is_in_save_dir(path)
  if not path or type(path) ~= "string" or path == "" then
    return false
  end
  local save_dir = config.options.save_dir and vim.fn.expand(config.options.save_dir)
  if not save_dir or save_dir == "" then
    return false
  end
  save_dir = save_dir:gsub("/+$", "")
  local prefix = save_dir .. "/"
  return path == save_dir or path:sub(1, #prefix) == prefix
end

local function is_preview_target(dest, opts)
  if opts and (opts.is_save or opts.save) then
    return false
  end
  if is_in_save_dir(dest) then
    return false
  end
  if opts and opts.is_preview ~= nil then
    return opts.is_preview
  end
  if type(dest) == "string" and (dest:match("prev_[%w_]+%.") or dest:match("[/\\]prev_") or dest:match("^prev_")) then
    return true
  end
  return false
end

local function should_prewarm(dest, opts)
  if opts and opts.prewarm == false then
    return false
  end
  if opts and opts.prewarm == true then
    return true
  end
  return is_preview_target(dest, opts)
end

local function _trigger_prewarm(dest, opts)
  if should_prewarm(dest, opts) then
    pcall(function()
      local prewarmer = require("gelbooru.media.prewarmer")
      prewarmer.prewarm_file(dest, nil, opts)
    end)
  end
end

function M.is_valid_media(file_path, ref_path)
  if not file_path or vim.fn.filereadable(file_path) ~= 1 then
    return false
  end
  local size = vim.fn.getfsize(file_path)
  if not size or size <= 0 then
    return false
  end

  local target = ref_path or file_path
  local ext = target:match("%.([%w_]+)$")
  if ext then
    ext = ext:lower()
    if ext == "part" then
      ext = target:match("%.([%w_]+)%.part$")
      if ext then
        ext = ext:lower()
      end
    end
  end

  local f = io.open(file_path, "rb")
  if not f then
    return false
  end

  local head = f:read(16) or ""
  local hlen = #head
  f:close()

  -- Reject HTML/XML error bodies (Cloudflare, API 500/404 pages)
  local lower_head = head:lower()
  if lower_head:find("<!doctype", 1, true)
    or lower_head:find("<html", 1, true)
    or lower_head:find("<?xml", 1, true) then
    return false
  end

  -- Video files (mp4, mov, m4v)
  if ext == "mp4" or ext == "mov" or ext == "m4v" then
    return size >= constants.MIN_VALID_MEDIA_BYTES and (hlen >= 8 and head:sub(5, 8) == "ftyp")
  end

  local is_known_image = (ext == "gif" or head:sub(1, 3) == "GIF"
    or ext == "jpg" or ext == "jpeg" or (hlen >= 2 and head:byte(1) == 0xFF and head:byte(2) == 0xD8)
    or ext == "png" or (hlen >= 8 and head:sub(1, 8) == "\137PNG\r\n\026\n")
    or ext == "webp" or (hlen >= 12 and head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP"))

  if is_known_image then
    if ext == "gif" or head:sub(1, 3) == "GIF" then
      if size < constants.MIN_VALID_GIF_BYTES then
        return false
      end
    else
      if size < constants.MIN_VALID_IMAGE_BYTES then
        return false
      end
    end
    return require("gelbooru.media.resolver").is_image_complete(file_path)
  end

  -- Generic fallback (unit test mocks, text or raw payloads): size > MIN_VALID_MEDIA_BYTES bytes
  return size > constants.MIN_VALID_MEDIA_BYTES
end

local function _abort_handles_map(handles_map)
  for dest, handle in pairs(handles_map or {}) do
    if type(dest) == "string" then
      M.interrupted_dests[dest] = true
    end
    if handle then
      M.interrupted_handles[handle] = true
      if handle.kill then
        pcall(handle.kill, handle, 9)
      elseif handle.proc and handle.proc.kill then
        pcall(handle.proc.kill, handle.proc, 9)
      end
      handle.proc = nil
      handle.task = nil
    end
  end
end
M._abort_handles_map = _abort_handles_map

function M.abort_all()
  M.cancel_pending_resumes()
  M.cancel_prefetch_timers(true)
  _abort_handles_map(M.active_handles)
  _abort_handles_map(M.active_prefetch_handles)
  pcall(function()
    require("gelbooru.media.transcoder").abort_video_transcodes()
  end)
  if M.governor then
    M.governor.reset(true)
  end
  M.active_handles = {}
  M.active_prefetch_handles = {}
  M.queued_prefetch_dests = {}
  M._prefetch_timer_meta = {}
end

function M.curl_async(url, cb, opts)
  local priority = constants.PRIORITY_METADATA
  if type(opts) == "number" then
    priority = opts
  elseif type(opts) == "table" and opts.priority then
    priority = opts.priority
  end

  local handle_proxy = {
    url = url,
    proc = nil,
    killed = false,
  }

  local task = {
    url = url,
    priority = priority,
    handle = handle_proxy,
    socket_active = false,
    on_cancel = function()
      if cb then
        vim.schedule(function() pcall(cb, nil) end)
      end
    end,
  }

  handle_proxy.task = task
  handle_proxy.kill = function(self, sig)
    self.killed = true
    if self.task then
      self.task.killed = true
    end
    if self.proc and self.proc.kill then
      pcall(self.proc.kill, self.proc, sig or 9)
    end
  end

  task.run = function()
    if handle_proxy.killed then
      if cb then
        vim.schedule(function() pcall(cb, nil) end)
      end
      return
    end

    task.socket_active = true
    log("DEBUG", "CURL", "GET %s", url)
    local done = false

    local spawn_ok, res = pcall(function()
      return vim.system({
        "curl",
        "-s",
        "--fail",
        "-L",
        "--max-time",
        tostring(constants.CURL_API_TIMEOUT_SEC),
        "--connect-timeout",
        tostring(constants.CURL_CONNECT_TIMEOUT_SEC),
        "--retry",
        "3",
        "--retry-delay",
        "2",
        "--retry-connrefused",
        url,
      }, { text = true }, function(out)
        done = true
        if task.socket_active then
          task.socket_active = false
          governor.release_socket(task.priority)
        end
        if handle_proxy then
          M.active_handles[handle_proxy] = nil
          M.interrupted_dests[handle_proxy] = nil
        end
        vim.schedule(function()
          if state.State.torn_down then return end
          if handle_proxy then
            M.active_handles[handle_proxy] = nil
            M.interrupted_dests[handle_proxy] = nil
            handle_proxy.proc = nil
            handle_proxy.task = nil
          end
          task.handle = nil
          task.run = nil
          task.on_cancel = nil
          if cb then
            cb(out.code == 0 and out.stdout or nil)
          end
        end)
      end)
    end)

    if not spawn_ok or not res then
      if task.socket_active then
        task.socket_active = false
        governor.release_socket(task.priority)
      end
      log("ERROR", "CURL", "Failed to spawn curl: %s", tostring(res))
      if cb then
        vim.schedule(function()
          cb(nil)
        end)
      end
      return nil
    end

    handle_proxy.proc = res
    if not done then
      M.active_handles[handle_proxy] = handle_proxy
    end
  end

  governor.enqueue(task)
  return handle_proxy
end

-- opts: { resume = bool, force = bool, priority = number }
-- Automatically enables HTTP byte-range resumption (-C -) whenever a .part file
-- exists and has size > 1024 bytes, unless opts.force is true.
function M.download_async(url, dest, cb, opts)
  if not url or type(url) ~= "string" or not url:match("^https?://") then
    log("WARN", "DOWNLOAD", "Invalid HTTP(S) URL rejected: %s", tostring(url))
    if cb then
      vim.schedule(function() pcall(cb, false) end)
    end
    return nil
  end

  if vim.fn.filereadable(dest) == 1 and not M.active_downloads[dest] then
    if M.is_valid_media(dest) then
      log("DEBUG", "DOWNLOAD", "File already cached on disk: %s", dest)
      _trigger_prewarm(dest, opts)
      if cb then
        pcall(cb, true)
      end
      return nil
    else
      if not is_in_save_dir(dest) then
        log("WARN", "DOWNLOAD", "Existing cached file corrupted on disk, deleting: %s", dest)
        vim.fn.delete(dest)
      else
        log("WARN", "DOWNLOAD", "File in save_dir failed media validation; keeping permanent file intact: %s", dest)
      end
    end
  end

  local priority = (opts and opts.priority) or constants.PRIORITY_PREVIEW
  local queued = M.active_downloads[dest]
  local running_handle = M.active_handles[dest]
  if queued then
    if running_handle and M.interrupted_handles[running_handle] then
      log("DEBUG", "DOWNLOAD", "Waiting for interrupted download to exit before re-fetching: %s", dest)
      M.queued_retries = M.queued_retries or {}
      M.queued_retries[dest] = M.queued_retries[dest] or {}
      if cb then
        table.insert(M.queued_retries[dest], cb)
      end
      return running_handle
    end
    log("DEBUG", "DOWNLOAD", "Hooking into running download: %s", dest)
    if cb then
      table.insert(M.active_downloads[dest], cb)
    end
    governor.upgrade_priority(dest, priority)
    return running_handle
  end

  local tmp_dest = dest .. ".part"
  local force = opts and opts.force == true
  local part_size = vim.fn.getfsize(tmp_dest)
  local do_resume = not force and part_size > constants.MIN_VALID_MEDIA_BYTES

  if do_resume then
    local pf = io.open(tmp_dest, "rb")
    if pf then
      local head = pf:read(16) or ""
      pf:close()
      local lower_head = head:lower()
      if lower_head:find("<!doctype", 1, true) or lower_head:find("<html", 1, true) or lower_head:find("<?xml", 1, true) then
        do_resume = false
      end
    else
      do_resume = false
    end
  end

  if do_resume then
    log("INFO", "DOWNLOAD", "Resuming download at %d bytes: %s -> %s", part_size, url, dest)
  else
    log("INFO", "DOWNLOAD", "Starting download: %s -> %s", url, dest)
    vim.fn.delete(tmp_dest)
  end

  M.active_downloads[dest] = cb and { cb } or {}

  local handle_proxy = {
    dest = dest,
    url = url,
    proc = nil,
    killed = false,
  }

  local task = {
    dest = dest,
    url = url,
    priority = priority,
    post_idx = opts and opts.post_idx,
    handle = handle_proxy,
    socket_active = false,
    on_cancel = function()
      local callbacks = M.active_downloads[dest] or {}
      M.active_downloads[dest] = nil
      M.active_handles[dest] = nil
      for _, fn in ipairs(callbacks) do
        pcall(fn, false)
      end
    end,
  }

  handle_proxy.task = task
  handle_proxy.kill = function(self, sig)
    self.killed = true
    if self.task then
      self.task.killed = true
    end
    if not self.proc and self.dest and M.active_downloads[self.dest] then
      local callbacks = M.active_downloads[self.dest] or {}
      M.active_downloads[self.dest] = nil
      M.active_handles[self.dest] = nil
      for _, fn in ipairs(callbacks) do
        pcall(fn, false)
      end
    end
    if self.proc and self.proc.kill then
      pcall(self.proc.kill, self.proc, sig or 9)
    end
  end

  M.active_handles[dest] = handle_proxy

  task.run = function()
    if handle_proxy.killed then
      task.on_cancel()
      return
    end

    task.socket_active = true

    local curl_cmd = {
      "curl", "-s", "--fail", "-L",
      "--max-time", tostring(constants.CURL_DOWNLOAD_TIMEOUT_SEC),
      "--connect-timeout", tostring(constants.CURL_CONNECT_TIMEOUT_SEC),
      "--retry", "3", "--retry-delay", "2", "--retry-connrefused",
      "-H", "Referer: https://gelbooru.com/",
    }
    if do_resume then
      table.insert(curl_cmd, "-C")
      table.insert(curl_cmd, "-")
    end
    table.insert(curl_cmd, "-o")
    table.insert(curl_cmd, tmp_dest)
    table.insert(curl_cmd, url)

    local done = false
    local spawn_ok, res = pcall(vim.system, curl_cmd, {}, function(out)
      done = true
      if task.socket_active then
        task.socket_active = false
        governor.release_socket(task.priority)
      end
      if handle_proxy then
        M.active_handles[dest] = nil
      end
      vim.schedule(function()
        if state.State.torn_down then return end
        local callbacks = M.active_downloads[dest] or {}
        M.active_downloads[dest] = nil
        M.active_handles[dest] = nil

        local was_interrupted = (handle_proxy and M.interrupted_handles[handle_proxy])
          or (handle_proxy and handle_proxy.proc and M.interrupted_handles[handle_proxy.proc])
          or M.interrupted_dests[dest]

        if handle_proxy then
          M.interrupted_handles[handle_proxy] = nil
          if handle_proxy.proc then
            M.interrupted_handles[handle_proxy.proc] = nil
          end
          handle_proxy.proc = nil
          handle_proxy.task = nil
        end
        task.handle = nil
        task.run = nil
        task.on_cancel = nil
        if M.interrupted_dests[dest] then
          M.interrupted_dests[dest] = nil
        end

        -- If teardown killed this download, never rename the .part regardless of
        -- curl's exit code (kill vs natural-exit race can produce code 0).
        if was_interrupted then
          log("INFO", "DOWNLOAD", "Download interrupted by teardown/cancel, .part preserved: %s", tmp_dest)
          for _, fn in ipairs(callbacks) do pcall(fn, false) end

          -- If a new request was queued while this was exiting, kick it off cleanly now!
          local queued_cbs = M.queued_retries and M.queued_retries[dest]
          if queued_cbs and #queued_cbs > 0 then
            M.queued_retries[dest] = nil
            M.download_async(url, dest, function(ok)
              for _, qcb in ipairs(queued_cbs) do pcall(qcb, ok) end
            end, opts)
          end
          return
        end

        local ok = false
        if out.code == 0 and vim.fn.filereadable(tmp_dest) == 1 and M.is_valid_media(tmp_dest, dest) then
          ok = vim.fn.rename(tmp_dest, dest) == 0
          if not ok and vim.fn.filereadable(dest) == 1 then
            if not is_in_save_dir(dest) then
              vim.fn.delete(dest)
            end
            ok = vim.fn.rename(tmp_dest, dest) == 0
          end
        end

        -- Only delete .part on failure for non-resumable downloads, range errors, or corrupt payloads;
        -- for resumable downloads we leave a failed .part intact so future requests can resume it.
        if not ok then
          local current_part_size = vim.fn.getfsize(tmp_dest)
          local is_range_error = (out.code == 33 or out.code == 22)
          local preserve_part = not force and not is_range_error and current_part_size > constants.MIN_VALID_MEDIA_BYTES and out.code ~= 0
          if not preserve_part and vim.fn.filereadable(tmp_dest) == 1 then
            vim.fn.delete(tmp_dest)
          end
          log("WARN", "DOWNLOAD", "Download failed or corrupted (code %d): %s", out.code or -1, url)
        else
          log("INFO", "DOWNLOAD", "Download succeeded: %s", dest)

          -- Pipelined online preview prewarming:
          -- Forward completed preview image immediately into disk-to-disk graphics prewarmer
          _trigger_prewarm(dest, opts)
        end

        for _, fn in ipairs(callbacks) do
          pcall(fn, ok)
        end
      end)
    end)

    if not spawn_ok or not res then
      if task.socket_active then
        task.socket_active = false
        governor.release_socket(task.priority)
      end
      log("ERROR", "DOWNLOAD", "Failed to spawn curl: %s", tostring(res))
      local callbacks = M.active_downloads[dest] or {}
      M.active_downloads[dest] = nil
      M.active_handles[dest] = nil
      for _, fn in ipairs(callbacks) do
        pcall(fn, false)
      end
      return nil
    end

    handle_proxy.proc = res
    if handle_proxy and not done then
      M.active_handles[dest] = handle_proxy
    end
  end

  governor.enqueue(task)
  return handle_proxy
end

-- Scans save_dir for orphaned .part files from previous sessions and queues
-- them for background resumption by fetching their file_url from the API.
function M.resume_pending_saves()
  local config = require("gelbooru.core.config")
  local util = require("gelbooru.core.util")
  local parts = vim.fn.glob(config.options.save_dir .. "/*.part", false, true)
  if not parts or #parts == 0 then
    return
  end

  log("INFO", "DOWNLOAD", "Found %d orphaned .part file(s) in save_dir, queuing resume", #parts)

  for i, part_path in ipairs(parts) do
    local basename = vim.fn.fnamemodify(part_path, ":t")
    -- filename is <post_id>.<ext>.part
    local post_id, ext = basename:match("^(%d+)%.(%w+)%.part$")
    if not post_id then
      log("WARN", "DOWNLOAD", "Could not parse post_id from part file: %s", basename)
    else
      local dest = config.options.save_dir .. "/" .. post_id .. "." .. ext
      if vim.fn.filereadable(dest) == 1 then
        -- Already completed somehow, clean up the orphan
        vim.fn.delete(part_path)
      elseif not M.active_downloads[dest] and not M.pending_resumes[dest] then
        -- Stagger requests by 200ms each so we don't hammer the API on open
        local timer
        timer = vim.defer_fn(function()
          M.pending_resumes[dest] = nil
          if timer then
            M.pending_resumes[timer] = nil
          end
          if state.State.torn_down then
            return
          end
          local api_url = string.format("%s&id=%s%s", config.options.api_base, post_id, util.auth_qs())
          M.curl_async(api_url, function(body)
            if not body then
              log("WARN", "DOWNLOAD", "API lookup failed for orphaned post %s", post_id)
              return
            end
            local ok, data = pcall(vim.fn.json_decode, body)
            if not ok or not data or not data.post then
              log("WARN", "DOWNLOAD", "No post found for orphaned id %s", post_id)
              return
            end
            local posts = util.ensure_array(data.post)
            if not posts or not posts[1] then
              log("WARN", "DOWNLOAD", "No post found for orphaned id %s", post_id)
              return
            end
            local file_url = posts[1].file_url
            if not file_url or file_url == "" then
              log("WARN", "DOWNLOAD", "No file_url for orphaned post %s", post_id)
              return
            end
            log("INFO", "DOWNLOAD", "Resuming orphaned save: post %s -> %s", post_id, dest)
            M.download_async(file_url, dest, function(saved)
              log(saved and "INFO" or "WARN", "DOWNLOAD",
                saved and "Auto-resumed save completed: %s" or "Auto-resume failed: %s", dest)
            end, { resume = true, priority = constants.PRIORITY_METADATA })
          end)
        end, i * constants.RESUME_STAGGER_MS)
        M.pending_resumes[dest] = timer or true
        if timer then
          M.pending_resumes[timer] = timer
        end
      end
    end
  end
end

function M.cancel_pending_resumes()
  for k, v in pairs(M.pending_resumes or {}) do
    local timer = (type(k) == "table" or type(k) == "userdata") and k or v
    if (type(timer) == "table" or type(timer) == "userdata") and timer.stop then
      if not (timer.is_closing and timer:is_closing()) then
        pcall(function()
          timer:stop()
          timer:close()
        end)
      end
    end
  end
  M.pending_resumes = {}
end

function M.cancel_prefetch_timers(abort_active)
  M.cancel_pending_resumes()
  local UI = state.UI
  for _, timer in pairs(UI.prefetch_timers or {}) do
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  UI.prefetch_timers = {}
  M.queued_prefetch_dests = {}
  M._prefetch_timer_meta = {}
  if abort_active then
    M.last_prefetch_dir = nil
    for dest, handle in pairs(M.active_prefetch_handles or {}) do
      M.interrupted_dests[dest] = true
      if handle then
        M.interrupted_handles[handle] = true
        if handle.kill then
          pcall(handle.kill, handle, 9)
        end
      end
    end
    M.active_prefetch_handles = {}
  else
    if M.active_prefetch_handles then
      for dest, _ in pairs(M.active_prefetch_handles) do
        if not M.active_downloads[dest] then
          M.active_prefetch_handles[dest] = nil
        end
      end
    end
  end
end

function M.prefetch_around(idx, scroll_dir)
  if state.State.torn_down then
    return
  end

  local State = state.State
  if not State.posts or #State.posts == 0 then
    return
  end

  local UI = state.UI
  local resolver = require("gelbooru.media.resolver")
  local radius = config.options.prefetch_radius or constants.DEFAULT_PREFETCH_RADIUS
  local dir = scroll_dir or State.scroll_dir or 1
  if dir == 0 then
    dir = 1
  end

  -- Direction handling:
  -- Anti-jitter connection resilience:
  -- When scroll direction changes, do NOT cancel/SIGKILL in-flight curl downloads.
  -- Let active transfers finish and populate the disk cache naturally.
  -- Cancel un-fired stagger timers and re-order the prefetch queue to favor the new direction.
  if M.last_prefetch_dir ~= nil and M.last_prefetch_dir ~= dir then
    M.cancel_prefetch_timers(false)
    governor.reorder_prefetch(idx, dir)
  end
  M.last_prefetch_dir = dir

  -- Prune out-of-radius tasks from rate governor prefetch queue & pending stagger timers
  -- Allow hysteresis margin (radius + constants.PREFETCH_JITTER_MARGIN) so 1-2 step cursor jitter does not thrash lookahead queue
  local prune_window = math.max(radius + constants.PREFETCH_JITTER_MARGIN, constants.PREWARM_SLIDING_WINDOW)
  M.prune_prefetch_queue(idx, prune_window)

  local ahead, behind = {}, {}
  for i = 1, radius do
    local fwd = idx + dir * i
    local bwd = idx - dir * i
    if fwd >= 1 and fwd <= #State.posts then
      table.insert(ahead, fwd)
    end
    if bwd >= 1 and bwd <= #State.posts then
      table.insert(behind, bwd)
    end
  end

  local ordered = {}
  for _, i in ipairs(ahead) do
    table.insert(ordered, i)
  end
  for _, i in ipairs(behind) do
    table.insert(ordered, i)
  end

  -- Top lookahead targets in active scroll direction within radius:
  local immediate_targets = {}
  for step = 1, math.min(radius, constants.PREFETCH_LOOKAHEAD_DEPTH) do
    local lookahead_idx = idx + dir * step
    if lookahead_idx >= 1 and lookahead_idx <= #State.posts then
      immediate_targets[lookahead_idx] = true
    end
  end

  local delay = 0

  for _, i in ipairs(ordered) do
    local p = State.posts[i]
    if p and not p.is_local then
      local urls, dest = resolver.get_preview_targets(p)
      local url = urls and urls[1]

      if url and dest then
        if type(url) == "string" and url:match("^https?://") then
          if vim.fn.filereadable(dest) == 0 and not M.active_downloads[dest] then
            if immediate_targets[i] then
              -- Top lookahead targets in active scroll direction:
              -- Eliminate artificial delay and dispatch concurrently without delay to overlap TLS handshakes!
              log("DEBUG", "PREFETCH", "Prefetching immediate lookahead post %s (idx=%d, dir=%d)", tostring(p.id), i, dir)
              M.queued_prefetch_dests[dest] = nil
              local handle = M.download_async(url, dest, function()
                if M.active_prefetch_handles then
                  M.active_prefetch_handles[dest] = nil
                end
              end, { priority = constants.PRIORITY_PREFETCH, post_idx = i })
              if handle and M.active_prefetch_handles and M.active_downloads[dest] then
                M.active_prefetch_handles[dest] = handle
              end
            elseif not M.queued_prefetch_dests[dest] then
              delay = delay + constants.PREFETCH_STAGGER_MS
              M.queued_prefetch_dests[dest] = true
              local timer = vim.loop.new_timer()
              UI.prefetch_timers[timer] = timer
              local cap_url, cap_dest = url, dest
              local cap_pid = p.id
              local cap_idx = i
              M._prefetch_timer_meta = M._prefetch_timer_meta or {}
              M._prefetch_timer_meta[timer] = { post_idx = cap_idx, dest = cap_dest }

              timer:start(
                delay,
                0,
                vim.schedule_wrap(function()
                  if not timer:is_closing() then
                    timer:close()
                  end
                  UI.prefetch_timers[timer] = nil
                  if M._prefetch_timer_meta then
                    M._prefetch_timer_meta[timer] = nil
                  end
                  if M.queued_prefetch_dests then
                    M.queued_prefetch_dests[cap_dest] = nil
                  end
                  if state.State.torn_down or not (state.UI.wins and state.UI.wins.frame and vim.api.nvim_win_is_valid(state.UI.wins.frame)) then
                    return
                  end
                  if vim.fn.filereadable(cap_dest) == 0 and not M.active_downloads[cap_dest] then
                    log("DEBUG", "PREFETCH", "Prefetching post %s (dir=%d)", tostring(cap_pid), dir)
                    local handle = M.download_async(cap_url, cap_dest, function()
                      if M.active_prefetch_handles then
                        M.active_prefetch_handles[cap_dest] = nil
                      end
                    end, { priority = constants.PRIORITY_PREFETCH, post_idx = cap_idx })
                    if handle and M.active_prefetch_handles and M.active_downloads[cap_dest] then
                      M.active_prefetch_handles[cap_dest] = handle
                    end
                  end
                end)
              )
            end
          end
        elseif resolver.is_video_post(p) and vim.fn.filereadable(url) == 1 then
          -- Saved video in save_dir: prefetch video thumbnail via ffmpeg
          if vim.fn.filereadable(dest) == 0 then
            resolver.extract_video_thumbnail(url, p)
          end
        end
      end
    end
  end

  governor.reorder_prefetch(idx, dir)
end

--- Records a ready media path and its associated post in the prewarmed cache.
--- @param post table|string|nil: Post object or URL
--- @param path string|nil: Resolved local file path
local function record_prewarmed(post, path)
  pcall(function()
    local prewarmer = require("gelbooru.media.prewarmer")
    if not prewarmer or not prewarmer.prewarmed_cache then
      return
    end
    if path and path ~= "" then
      prewarmer.prewarmed_cache[path] = true
    end
    if type(post) == "table" and post.file_url then
      prewarmer.prewarmed_cache[post.file_url] = true
    elseif type(post) == "string" and post ~= "" and post ~= path then
      prewarmer.prewarmed_cache[post] = true
    end
  end)
end

M.record_prewarmed = record_prewarmed

function M.extract_thumbnail_queued(vpath, post, thumb_dest, priority, cb)
  priority = priority or M.TIER_THUMBNAIL
  if M.active_downloads[thumb_dest] then
    if cb then
      table.insert(M.active_downloads[thumb_dest], cb)
    end
    governor.upgrade_priority(thumb_dest, priority)
    return M.active_handles[thumb_dest]
  end

  M.active_downloads[thumb_dest] = cb and { cb } or {}

  local handle_proxy = {
    dest = thumb_dest,
    proc = nil,
    killed = false,
  }

  local task = {
    dest = thumb_dest,
    priority = priority,
    post_idx = post and (post.post_idx or post._idx),
    handle = handle_proxy,
    socket_active = false,
    on_cancel = function()
      local cbs = M.active_downloads[thumb_dest] or {}
      M.active_downloads[thumb_dest] = nil
      M.active_handles[thumb_dest] = nil
      for _, fn in ipairs(cbs) do
        pcall(fn, nil, "Cancelled")
      end
    end,
  }

  task.run = function()
    if handle_proxy.killed or state.State.torn_down then
      task.on_cancel()
      return
    end

    task.socket_active = true
    local transcoder = require("gelbooru.media.transcoder")
    local proc = transcoder.extract_video_thumbnail(vpath, post, function(tpath, err)
      if task.socket_active then
        task.socket_active = false
        governor.release_socket(task.priority)
      end
      vim.schedule(function()
        local cbs = M.active_downloads[thumb_dest] or {}
        M.active_downloads[thumb_dest] = nil
        M.active_handles[thumb_dest] = nil
        if handle_proxy then
          handle_proxy.proc = nil
          handle_proxy.task = nil
        end
        task.handle = nil
        task.run = nil
        task.on_cancel = nil

        if state.State.torn_down or handle_proxy.killed then
          for _, fn in ipairs(cbs) do pcall(fn, nil, "Interrupted") end
          return
        end

        local inspector = require("gelbooru.media.inspector")
        local ok = tpath and vim.fn.filereadable(tpath) == 1
          and (vim.fn.getfsize(tpath) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES
          and inspector.is_image_complete(tpath)

        if ok then
          record_prewarmed(post, thumb_dest)
        end

        for _, fn in ipairs(cbs) do
          pcall(fn, ok and tpath or nil, ok and nil or (err or "Video thumbnail extraction failed"))
        end
      end)
    end)

    handle_proxy.proc = proc
    if handle_proxy.killed and proc and proc.kill then
      pcall(proc.kill, proc, 9)
    end
  end

  handle_proxy.task = task
  handle_proxy.kill = function(self, sig)
    self.killed = true
    if self.task then
      self.task.killed = true
    end
    if not self.proc and self.dest and M.active_downloads[self.dest] then
      local cbs = M.active_downloads[self.dest] or {}
      M.active_downloads[self.dest] = nil
      M.active_handles[self.dest] = nil
      for _, fn in ipairs(cbs) do pcall(fn, nil, "Cancelled") end
    end
    if self.proc and self.proc.kill then
      pcall(self.proc.kill, self.proc, sig or 9)
    end
  end

  M.active_handles[thumb_dest] = handle_proxy
  governor.enqueue(task)
  return handle_proxy
end

function M.ensure_ready(post, priority, cb)
  if state.State.torn_down then
    if cb then vim.schedule(function() cb(nil, "Torn down") end) end
    return nil
  end

  if not post or (type(post) == "table" and post._pending_delete) then
    if cb then vim.schedule(function() cb(nil, "Post deleted or invalid") end) end
    return nil
  end

  local opts = type(priority) == "table" and priority or {}
  priority = (type(priority) == "number" and priority) or opts.priority or M.TIER_URGENT
  priority = math.max(1, math.min(4, priority))
  local post_idx = opts.post_idx or (type(post) == "table" and (post.post_idx or post._idx))

  local inspector = require("gelbooru.media.inspector")
  local resolver = require("gelbooru.media.resolver")

  if type(post) == "string" then
    local path = post
    if vim.fn.filereadable(path) == 1 then
      if inspector.is_image_complete(path) then
        record_prewarmed(post, path)
        if cb then vim.schedule(function() cb(path) end) end
        return path
      else
        if cb then vim.schedule(function() cb(nil, "Corrupted image file") end) end
        return nil
      end
    else
      if cb then vim.schedule(function() cb(nil, "File not readable: " .. tostring(path)) end) end
      return nil
    end
  end

  local is_vid = resolver.is_video_post(post)

  if is_vid then
    local vpath = (post.is_local and post.file_url)
      or (post.id and resolver.get_saved_media_path(post.id, post.file_url))

    if vpath and vim.fn.filereadable(vpath) == 1 then
      local thumb_dest = resolver.get_video_thumbnail_path(vpath, post.id)
      if vim.fn.filereadable(thumb_dest) == 1
        and (vim.fn.getfsize(thumb_dest) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES
        and inspector.is_image_complete(thumb_dest) then
        record_prewarmed(post, thumb_dest)
        if cb then vim.schedule(function() cb(thumb_dest) end) end
        return thumb_dest
      end

      local thumb_priority = (priority == M.TIER_URGENT) and M.TIER_URGENT or M.TIER_THUMBNAIL
      return M.extract_thumbnail_queued(vpath, post, thumb_dest, thumb_priority, cb)
    else
      local urls, dest = resolver.get_preview_targets(post)
      if not dest then
        if cb then vim.schedule(function() cb(nil, "No destination for video post") end) end
        return nil
      end
      if vim.fn.filereadable(dest) == 1 and M.is_valid_media(dest) then
        record_prewarmed(post, dest)
        if cb then vim.schedule(function() cb(dest) end) end
        return dest
      end
      local url = urls and urls[1]
      if not url or not url:match("^https?://") then
        if cb then vim.schedule(function() cb(nil, "No preview URL for video post") end) end
        return nil
      end
      return M.download_async(url, dest, function(ok)
        if ok then
          record_prewarmed(post, dest)
        end
        if cb then
          cb(ok and dest or nil, ok and nil or "Video preview download failed")
        end
      end, {
        priority = priority,
        post_idx = post_idx,
      })
    end
  end

  if post.is_local then
    local lpath = post.file_url
    if lpath and vim.fn.filereadable(lpath) == 1 and inspector.is_image_complete(lpath) then
      record_prewarmed(post, lpath)
      if cb then vim.schedule(function() cb(lpath) end) end
      return lpath
    else
      if cb then vim.schedule(function() cb(nil, "Local image unreadable or corrupt") end) end
      return nil
    end
  end

  local saved_path = post.id and resolver.get_saved_media_path(post.id, post.file_url)
  if saved_path and vim.fn.filereadable(saved_path) == 1 and M.is_valid_media(saved_path) then
    record_prewarmed(post, saved_path)
    if cb then vim.schedule(function() cb(saved_path) end) end
    return saved_path
  end

  local urls, dest = resolver.get_preview_targets(post)
  if not dest then
    if cb then vim.schedule(function() cb(nil, "No destination for post") end) end
    return nil
  end
  if vim.fn.filereadable(dest) == 1 and M.is_valid_media(dest) then
    record_prewarmed(post, dest)
    if cb then vim.schedule(function() cb(dest) end) end
    return dest
  end

  local url = urls and urls[1]
  if not url or not url:match("^https?://") then
    if cb then vim.schedule(function() cb(nil, "No valid URL for post") end) end
    return nil
  end

  return M.download_async(url, dest, function(ok)
    if ok then
      record_prewarmed(post, dest)
    end
    if cb then
      cb(ok and dest or nil, ok and nil or "Image download failed")
    end
  end, {
    priority = priority,
    post_idx = post_idx,
  })
end

return M
