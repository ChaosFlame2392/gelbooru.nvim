local config = require("gelbooru.core.config")
local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")

local M = {}

M.active_downloads = {}
M.active_handles = {}
M.pending_resumes = {} -- guards the async gap between scan and active_downloads registration
M.interrupted_dests = {} -- dests killed by teardown; callbacks skip rename and preserve .part

function M.curl_async(url, cb)
  log("DEBUG", "CURL", "GET %s", url)
  vim.system({
    "curl",
    "-s",
    "-L",
    "--max-time",
    "25",
    "--connect-timeout",
    "10",
    "--retry",
    "3",
    "--retry-delay",
    "2",
    "--retry-connrefused",
    url,
  }, { text = true }, function(out)
    vim.schedule(function()
      cb(out.code == 0 and out.stdout or nil)
    end)
  end)
end

-- opts: { resume = bool }
-- When resume=true and a .part file already exists with bytes, uses curl -C - to
-- continue the interrupted transfer instead of restarting from scratch.
function M.download_async(url, dest, cb, opts)
  if vim.fn.filereadable(dest) == 1 and not M.active_downloads[dest] then
    log("DEBUG", "DOWNLOAD", "File already cached on disk: %s", dest)
    if cb then
      pcall(cb, true)
    end
    return
  end

  local queued = M.active_downloads[dest]
  if queued then
    log("DEBUG", "DOWNLOAD", "Hooking into running download: %s", dest)
    if cb then
      table.insert(M.active_downloads[dest], cb)
    end
    return
  end

  local tmp_dest = dest .. ".part"
  local resume = opts and opts.resume
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
    "curl", "-s", "-L",
    "--max-time", "300",
    "--connect-timeout", "10",
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

  local handle = vim.system(curl_cmd, {}, function(out)
    vim.schedule(function()
      local callbacks = M.active_downloads[dest] or {}
      M.active_downloads[dest] = nil
      M.active_handles[dest] = nil

      -- If teardown killed this download, never rename the .part regardless of
      -- curl's exit code (kill vs natural-exit race can produce code 0).
      if M.interrupted_dests[dest] then
        M.interrupted_dests[dest] = nil
        log("INFO", "DOWNLOAD", "Download interrupted by teardown, .part preserved: %s", tmp_dest)
        for _, fn in ipairs(callbacks) do pcall(fn, false) end
        return
      end

      local ok = false
      if out.code == 0 and vim.fn.filereadable(tmp_dest) == 1 and vim.fn.getfsize(tmp_dest) > 1024 then
        ok = vim.fn.rename(tmp_dest, dest) == 0
        if not ok and vim.fn.filereadable(dest) == 1 then
          vim.fn.delete(dest)
          ok = vim.fn.rename(tmp_dest, dest) == 0
        end
      end

      -- Only delete .part on failure for non-resume downloads; for resumes we
      -- leave a failed .part intact so the next session can retry resuming it.
      if not ok then
        if not resume and vim.fn.filereadable(tmp_dest) == 1 then
          vim.fn.delete(tmp_dest)
        end
        log("WARN", "DOWNLOAD", "Download failed (code %d): %s", out.code or -1, url)
      else
        vim.fn.system({ "touch", dest })
        log("INFO", "DOWNLOAD", "Download succeeded: %s", dest)
      end

      for _, fn in ipairs(callbacks) do
        pcall(fn, ok)
      end
    end)
  end)
  M.active_handles[dest] = handle
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
        M.pending_resumes[dest] = true
        -- Stagger requests by 200ms each so we don't hammer the API on open
        vim.defer_fn(function()
          local api_url = string.format("%s&id=%s%s", config.options.api_base, post_id, util.auth_qs())
          M.curl_async(api_url, function(body)
            M.pending_resumes[dest] = nil
            if not body then
              log("WARN", "DOWNLOAD", "API lookup failed for orphaned post %s", post_id)
              return
            end
            local ok, data = pcall(vim.fn.json_decode, body)
            if not ok or not data or not data.post or not data.post[1] then
              log("WARN", "DOWNLOAD", "No post found for orphaned id %s", post_id)
              return
            end
            local file_url = data.post[1].file_url
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
        end, i * 200)
      end
    end
  end
end

function M.cancel_prefetch_timers()
  local UI = state.UI
  for _, timer in pairs(UI.prefetch_timers or {}) do
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  UI.prefetch_timers = {}
end

function M.prefetch_around(idx)
  M.cancel_prefetch_timers()

  local State = state.State
  local UI = state.UI
  local image = require("gelbooru.ui.image")
  local radius = config.options.prefetch_radius
  local dir = State.scroll_dir or 1
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

  local delay = 0
  for _, i in ipairs(ordered) do
    local p = State.posts[i]
    local urls, dest = image.get_preview_targets(p)
    local url = urls[1]

    if url and dest then
      if vim.fn.filereadable(dest) == 0 and not M.active_downloads[dest] then
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
            -- Remove from list so it doesn't grow unboundedly across navigation.
            UI.prefetch_timers[timer_idx] = nil
            if vim.fn.filereadable(cap_dest) == 0 and not M.active_downloads[cap_dest] then
              log("DEBUG", "PREFETCH", "Prefetching post %s (dir=%d)", tostring(cap_pid), dir)
              M.download_async(cap_url, cap_dest)
            end
          end)
        )
        delay = delay + 50
      end
    end
  end
end

return M
