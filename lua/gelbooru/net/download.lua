local config = require("gelbooru.core.config")
local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local constants = require("gelbooru.core.constants")

local M = {}

M.active_downloads = {}
M.active_handles = {}
M.pending_resumes = {} -- guards the async gap between scan and active_downloads registration
M.interrupted_dests = {} -- dests killed by teardown; callbacks skip rename and preserve .part
M.interrupted_handles = {}
M.queued_retries = {}
M.active_prefetch_handles = {}
M.queued_prefetch_dests = {}
M.last_prefetch_dir = nil

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

function M.abort_all()
  M.cancel_pending_resumes()
  for dest, handle in pairs(M.active_handles or {}) do
    if type(dest) == "string" then
      M.interrupted_dests[dest] = true
    end
    if handle then
      M.interrupted_handles[handle] = true
      if handle.kill then
        pcall(handle.kill, handle, 9)
      end
    end
  end
  M.active_handles = {}
  M.active_prefetch_handles = {}
  M.queued_prefetch_dests = {}
end

function M.curl_async(url, cb)
  log("DEBUG", "CURL", "GET %s", url)
  local handle
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
      if handle then
        M.active_handles[handle] = nil
        M.interrupted_dests[handle] = nil
      end
      vim.schedule(function()
        if handle then
          M.active_handles[handle] = nil
          M.interrupted_dests[handle] = nil
        end
        if cb then
          cb(out.code == 0 and out.stdout or nil)
        end
      end)
    end)
  end)

  if not spawn_ok or not res then
    log("ERROR", "CURL", "Failed to spawn curl: %s", tostring(res))
    if cb then
      vim.schedule(function()
        cb(nil)
      end)
    end
    return nil
  end
  handle = res

  if handle and not done then
    M.active_handles[handle] = handle
  end
  return handle
end

-- opts: { resume = bool }
-- When resume=true and a .part file already exists with bytes, uses curl -C - to
-- continue the interrupted transfer instead of restarting from scratch.
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
      if cb then
        pcall(cb, true)
      end
      return
    else
      if not is_in_save_dir(dest) then
        log("WARN", "DOWNLOAD", "Existing cached file corrupted on disk, deleting: %s", dest)
        vim.fn.delete(dest)
      else
        log("WARN", "DOWNLOAD", "File in save_dir failed media validation; keeping permanent file intact: %s", dest)
      end
    end
  end

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
    return running_handle
  end

  local tmp_dest = dest .. ".part"
  local resume = opts and opts.resume == true
  local part_size = vim.fn.getfsize(tmp_dest)
  local do_resume = resume and part_size > 1024

  if do_resume then
    log("INFO", "DOWNLOAD", "Resuming download at %d bytes: %s -> %s", part_size, url, dest)
  else
    log("INFO", "DOWNLOAD", "Starting download: %s -> %s", url, dest)
    vim.fn.delete(tmp_dest)
  end

  M.active_downloads[dest] = cb and { cb } or {}

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

  local handle
  local done = false
  local spawn_ok, res = pcall(vim.system, curl_cmd, {}, function(out)
    done = true
    if handle then
      M.active_handles[dest] = nil
    end
    vim.schedule(function()
      local callbacks = M.active_downloads[dest] or {}
      M.active_downloads[dest] = nil
      M.active_handles[dest] = nil

      local was_interrupted = (handle and M.interrupted_handles[handle]) or M.interrupted_dests[dest]
      if handle then
        M.interrupted_handles[handle] = nil
      end
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

      -- Only delete .part on failure for non-resume downloads; for resumes we
      -- leave a failed .part intact so the next session can retry resuming it.
      if not ok then
        if not resume and vim.fn.filereadable(tmp_dest) == 1 then
          vim.fn.delete(tmp_dest)
        end
        log("WARN", "DOWNLOAD", "Download failed or corrupted (code %d): %s", out.code or -1, url)
      else
        pcall(function()
          local uv = vim.uv or vim.loop
          local now = os.time()
          uv.fs_utime(dest, now, now)
        end)
        log("INFO", "DOWNLOAD", "Download succeeded: %s", dest)
      end

      for _, fn in ipairs(callbacks) do
        pcall(fn, ok)
      end
    end)
  end)

  if not spawn_ok or not res then
    log("ERROR", "DOWNLOAD", "Failed to spawn curl: %s", tostring(res))
    local callbacks = M.active_downloads[dest] or {}
    M.active_downloads[dest] = nil
    M.active_handles[dest] = nil
    for _, fn in ipairs(callbacks) do
      pcall(fn, false)
    end
    return nil
  end

  handle = res
  if handle and not done then
    M.active_handles[dest] = handle
  end
  return handle
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
            end, { resume = true })
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
  M.last_prefetch_dir = nil
  if abort_active then
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
  local radius = config.options.prefetch_radius
  local dir = scroll_dir or State.scroll_dir or 1
  if dir == 0 then
    dir = 1
  end

  -- Direction handling:
  -- Do not cancel in-flight prefetch downloads if moving in the same direction (`scroll_dir`).
  -- If scroll direction has reversed, cancel old prefetch timers and abort opposite in-flight prefetch downloads.
  if M.last_prefetch_dir ~= nil and M.last_prefetch_dir ~= dir then
    M.cancel_prefetch_timers(true)
  end
  M.last_prefetch_dir = dir

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

  local immediate_next = idx + dir
  local delay = 0

  for _, i in ipairs(ordered) do
    local p = State.posts[i]
    if p and not p.is_local then
      local urls, dest = resolver.get_preview_targets(p)
      local url = urls and urls[1]

      if url and dest then
        if type(url) == "string" and url:match("^https?://") then
          if vim.fn.filereadable(dest) == 0 and not M.active_downloads[dest] then
            if i == immediate_next then
              -- Immediate next post (`cur + dir`): eliminate artificial 50ms delay, trigger immediately!
              log("DEBUG", "PREFETCH", "Prefetching immediate next post %s (dir=%d)", tostring(p.id), dir)
              M.queued_prefetch_dests[dest] = nil
              local handle = M.download_async(url, dest, function()
                if M.active_prefetch_handles then
                  M.active_prefetch_handles[dest] = nil
                end
              end)
              if handle and M.active_prefetch_handles then
                M.active_prefetch_handles[dest] = handle
              end
            elseif not M.queued_prefetch_dests[dest] then
              delay = delay + constants.PREFETCH_STAGGER_MS
              M.queued_prefetch_dests[dest] = true
              local timer = vim.loop.new_timer()
              local timer_idx = #UI.prefetch_timers + 1
              UI.prefetch_timers[timer_idx] = timer
              local cap_url, cap_dest = url, dest
              local cap_pid = p.id

              timer:start(
                delay,
                0,
                vim.schedule_wrap(function()
                  if not timer:is_closing() then
                    timer:close()
                  end
                  UI.prefetch_timers[timer_idx] = nil
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
                    end)
                    if handle and M.active_prefetch_handles then
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
end

return M
