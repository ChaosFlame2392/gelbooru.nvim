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

function M.get_preview_targets(p)
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
  local ext = M.file_ext_from_url(urls[1])
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

function M.render_image(win, path, width, height)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local p_ok, placement_mod = pcall(require, "snacks.image.placement")
  if p_ok and placement_mod then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local opts = { pos = { 1, 1 } }
    if width and height then
      opts.max_width = width
      opts.max_height = height
    end
    local place_ok, placement = pcall(placement_mod.new, buf, path, opts)
    if place_ok and placement then
      local old_buf = state.UI.current_placement and state.UI.current_placement.buf
      M.close_current_placement()
      state.UI.current_placement = placement
      pcall(vim.api.nvim_win_set_buf, win, buf)
      if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
        pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
      end
      pcall(placement.update, placement)
      log("DEBUG", "RENDER", "Image rendered via snacks.image: %s", path)
      return true
    else
      log("WARN", "RENDER", "Failed to create snacks placement for %s: %s", path, tostring(placement))
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  else
    log("WARN", "RENDER", "snacks.image.placement not available")
  end
  return false
end

return M
