local config = require("gelbooru.core.config")
local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")

local M = {}

M.active_downloads = {}

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

function M.download_async(url, dest, cb)
  -- 1. Prevent duplicate download if file is already valid on disk
  if vim.fn.filereadable(dest) == 1 and not M.active_downloads[dest] then
    log("DEBUG", "DOWNLOAD", "File already cached on disk: %s", dest)
    if cb then
      pcall(cb, true)
    end
    return
  end

  -- 2. Hook into existing download if already running.
  --    Keep only the latest explicit callback; prefetch callers pass nil so
  --    they never accumulate closures while the download is in-flight.
  local queued = M.active_downloads[dest]
  if queued then
    log("DEBUG", "DOWNLOAD", "Hooking into running download: %s", dest)
    if cb then
      -- Replace previous callback rather than accumulating: only the most
      -- recent explicit caller cares about the result.
      M.active_downloads[dest] = { cb }
    end
    return
  end

  -- 3. Start fresh download
  log("INFO", "DOWNLOAD", "Starting download: %s -> %s", url, dest)
  M.active_downloads[dest] = cb and { cb } or {}
  local tmp_dest = dest .. ".part"
  vim.fn.delete(tmp_dest)

  vim.system({
    "curl",
    "-s",
    "-L",
    "--max-time",
    "60",
    "--connect-timeout",
    "10",
    "--retry",
    "3",
    "--retry-delay",
    "2",
    "--retry-connrefused",
    "-H",
    "Referer: https://gelbooru.com/",
    "-o",
    tmp_dest,
    url,
  }, {}, function(out)
    vim.schedule(function()
      local callbacks = M.active_downloads[dest] or {}
      M.active_downloads[dest] = nil

      local ok = false
      if out.code == 0 and vim.fn.filereadable(tmp_dest) == 1 and vim.fn.getfsize(tmp_dest) > 0 then
        ok = vim.fn.rename(tmp_dest, dest) == 0
        if not ok and vim.fn.filereadable(dest) == 1 then
          vim.fn.delete(dest)
          ok = vim.fn.rename(tmp_dest, dest) == 0
        end
      end

      if vim.fn.filereadable(tmp_dest) == 1 then
        vim.fn.delete(tmp_dest)
      end

      if ok then
        vim.fn.system({ "touch", dest })
        log("DEBUG", "DOWNLOAD", "Download succeeded: %s", dest)
      else
        log("WARN", "DOWNLOAD", "Download failed (code %d): %s", out.code or -1, url)
      end

      for _, fn in ipairs(callbacks) do
        pcall(fn, ok)
      end
    end)
  end)
end

function M.cancel_prefetch_timers()
  local UI = state.UI
  -- Use pairs (not ipairs) to handle nil holes left by fired timers.
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
