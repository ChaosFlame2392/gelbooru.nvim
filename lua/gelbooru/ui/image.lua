local config = require("gelbooru.core.config")
local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")

local M = {}

function M.file_ext_from_url(url)
  local clean = (url or ""):match("^[^%?]+") or ""
  return (clean:match("%.([%w]+)$") or "jpg"):lower()
end

function M.is_video_post(p)
  local ext = M.file_ext_from_url(p and p.file_url)
  return ext == "mp4" or ext == "webm"
end

function M.preview_source_name(p, url)
  if url and p and p.sample_url == url then
    return "sample"
  end
  if url and p and p.preview_url == url then
    return "thumbnail"
  end
  if url and p and p.file_url == url then
    return "original"
  end
  return "preview"
end

function M.get_preview_targets(p, url_idx)
  local urls, seen = {}, {}
  local candidates = { p and p.sample_url, p and p.preview_url, p and p.file_url }
  for i = 1, 3 do
    local u = candidates[i]
    if u and u ~= "" and not seen[u] then
      seen[u] = true
      urls[#urls + 1] = u
    end
  end
  if #urls == 0 then
    return {}, nil
  end
  local chosen_idx = math.max(1, math.min(url_idx or 1, #urls))
  local ext = M.file_ext_from_url(urls[chosen_idx])
  local cache_dir = config.options.cache_dir
  return urls, string.format("%s/prev_%s.%s", cache_dir, p.id, ext:lower())
end

function M.close_current_placement()
  local UI = state.UI
  if UI.current_placement and UI.current_placement.close then
    pcall(UI.current_placement.close, UI.current_placement)
    UI.current_placement = nil
  end
end

function M.clear_snacks_cache_for(post_id)
  local snacks_cache = vim.fn.expand("~/.cache/nvim/snacks/image/")
  for _, f in ipairs(vim.fn.glob(snacks_cache .. "*", false, true)) do
    if f:find(tostring(post_id), 1, true) then
      vim.fn.delete(f)
    end
  end
end

-- Nudge the active placement to re-render at the current window dimensions.
-- Clears the cached state so snacks does not skip the update as a no-op.
-- Call this after window geometry changes (e.g. 'm' toggle, VimResized).
function M.nudge_current_placement()
  local UI = state.UI
  local p = UI.current_placement
  if p and not p.closed and vim.api.nvim_buf_is_valid(p.buf) then
    p._state = nil
    pcall(p.update, p)
    log("DEBUG", "RENDER", "Nudged placement for resize")
    return true
  end
  return false
end

function M.render_image(win, path)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local p_ok, placement_mod = pcall(require, "snacks.image.placement")
  if not p_ok or not placement_mod then
    log("WARN", "RENDER", "snacks.image.placement not available")
    return false
  end

  local current = state.UI.current_placement

  -- If we already have a live placement for this exact image, just nudge it to
  -- refit into the (possibly resized) window instead of tearing it down and
  -- recreating. This is the path taken on 'm' toggles and VimResized events.
  if current and not current.closed
    and current.img and current.img.src == path
    and vim.api.nvim_buf_is_valid(current.buf) then
    -- Ensure the img window is showing the placement buffer (may have been
    -- reset to UI.bufs.img by a stale callback during download).
    pcall(vim.api.nvim_win_set_buf, win, current.buf)
    current._state = nil
    pcall(current.update, current)
    log("DEBUG", "RENDER", "In-place resize nudge: %s", path)
    return true
  end

  -- New image: create a fresh placement with auto_resize so snacks wires its
  -- own WinResized handler and recomputes dimensions automatically. We do NOT
  -- pass max_width/max_height — the window itself is the constraint and snacks
  -- reads its live dimensions on every update().
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local opts = { pos = { 1, 1 }, auto_resize = true }

  local place_ok, placement = pcall(placement_mod.new, buf, path, opts)
  if not place_ok or not placement then
    log("WARN", "RENDER", "Failed to create snacks placement for %s: %s", path, tostring(placement))
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return false
  end

  local old_buf = current and current.buf
  M.close_current_placement()
  state.UI.current_placement = placement
  -- Set new buffer on the window BEFORE deleting the old buffer to avoid
  -- invalidating any in-flight snacks placement tracking.
  pcall(vim.api.nvim_win_set_buf, win, buf)
  if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
    pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
  end
  pcall(placement.update, placement)
  log("DEBUG", "RENDER", "Image rendered via snacks.image: %s", path)
  return true
end

return M
