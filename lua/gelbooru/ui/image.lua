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
  if not p then
    return {}, nil
  end

  local cache_dir = config.options.cache_dir
  if p.is_local then
    if M.is_video_post(p) then
      local thumb_dest = M.get_video_thumbnail_path(p.file_url, p.id)
      return { thumb_dest }, thumb_dest
    end
    return { p.file_url }, p.file_url
  end

  local urls, seen = {}, {}
  local candidates = { p.sample_url, p.preview_url, p.file_url }
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
  return urls, string.format("%s/prev_%s.%s", cache_dir, p.id, ext:lower())
end

function M.close_current_placement()
  local UI = state.UI
  if UI.current_placement and UI.current_placement.close then
    pcall(UI.current_placement.close, UI.current_placement)
    UI.current_placement = nil
  end
  if UI.wins and UI.wins.img and vim.api.nvim_win_is_valid(UI.wins.img)
    and UI.bufs and UI.bufs.img and vim.api.nvim_buf_is_valid(UI.bufs.img) then
    pcall(vim.api.nvim_win_set_buf, UI.wins.img, UI.bufs.img)
  end
end

local function attach_defensive_keymaps(buf)
  local util = require("gelbooru.core.util")
  local function go_search()
    local ui = require("gelbooru.ui")
    if ui and ui.enter_search then
      ui.enter_search()
    end
  end
  local function go_list()
    local s = require("gelbooru.core.state")
    if s.State.input_focused then
      s.State.input_focused = false
      vim.cmd("stopinsert")
      if s.UI.wins.ac and vim.api.nvim_win_is_valid(s.UI.wins.ac) then
        pcall(vim.api.nvim_win_set_config, s.UI.wins.ac, { hide = true })
      end
    end
    if s.UI.wins.list and vim.api.nvim_win_is_valid(s.UI.wins.list) then
      pcall(vim.api.nvim_set_current_win, s.UI.wins.list)
      local ui = require("gelbooru.ui")
      if ui and ui.set_status then
        ui.set_status()
      end
    end
  end

  local function handle_q()
    local s = require("gelbooru.core.state")
    local ui = require("gelbooru.ui")
    if s.State.zen_mode then
      if ui and ui.teardown then
        ui.teardown()
      end
    else
      go_list()
    end
  end

  local function nav(action)
    local ui = require("gelbooru.ui")
    if ui and ui.on_cursor_change then
      ui.on_cursor_change(action)
    end
  end

  util.keymap(buf, "n", "j", function() nav(1) end)
  util.keymap(buf, "n", "k", function() nav(-1) end)
  util.keymap(buf, "n", "gg", function() nav("gg") end)
  util.keymap(buf, "n", "G", function() nav("G") end)

  util.keymap(buf, "n", "r", function()
    local s = require("gelbooru.core.state")
    s.State.cur_id = nil
    local ui = require("gelbooru.ui")
    if ui and ui.render_preview then
      ui.render_preview(false)
    end
  end)

  util.keymap(buf, "n", "R", function()
    local ui = require("gelbooru.ui")
    if ui and ui.force_refresh then
      ui.force_refresh()
    end
  end)

  util.keymap(buf, "n", "m", function()
    local s = require("gelbooru.core.state")
    s.State.show_meta = not s.State.show_meta
    local ui = require("gelbooru.ui")
    if ui and ui.on_resize then
      ui.on_resize()
    end
  end)

  util.keymap(buf, "n", "u", function()
    local ui = require("gelbooru.ui")
    if ui and ui.search_active_artist then
      ui.search_active_artist()
    end
  end)

  util.keymap(buf, "n", "o", function()
    local ui = require("gelbooru.ui")
    if ui and ui.open_web_page then
      ui.open_web_page()
    end
  end)

  util.keymap(buf, "n", "O", function()
    local ui = require("gelbooru.ui")
    if ui and ui.open_media_viewer then
      ui.open_media_viewer()
    end
  end)

  util.keymap(buf, "n", "<CR>", function()
    local api = require("gelbooru.net.api")
    if api and api.save_current then
      api.save_current()
    end
  end)

  util.keymap(buf, "n", "\\", function()
    local ui = require("gelbooru.ui")
    if ui and ui.toggle_zen then
      ui.toggle_zen()
    end
  end)

  util.keymap(buf, "n", "q", handle_q)
  util.keymap(buf, "n", "<Esc>", handle_q)

  for _, k in ipairs({ "i", "I", "a", "A", "s", "S", "/" }) do
    util.keymap(buf, "n", k, go_search)
  end
end

function M.reset_canvas(placeholder)
  pcall(M.close_current_placement)
  if state.State.torn_down then
    return
  end
  local UI = state.UI
  local util = require("gelbooru.core.util")
  placeholder = placeholder or "  Loading..."
  if not (UI.bufs and UI.bufs.img and vim.api.nvim_buf_is_valid(UI.bufs.img)) then
    UI.bufs.img = util.scratch()
    vim.bo[UI.bufs.img].bufhidden = "hide"
  end
  util.set_lines(UI.bufs.img, { placeholder })
  if UI.bufs and UI.bufs.meta and vim.api.nvim_buf_is_valid(UI.bufs.meta) then
    util.set_lines(UI.bufs.meta, {})
  end
  vim.bo[UI.bufs.img].modifiable = false
  attach_defensive_keymaps(UI.bufs.img)
  if UI.wins and UI.wins.img and vim.api.nvim_win_is_valid(UI.wins.img)
    and UI.bufs and UI.bufs.img and vim.api.nvim_buf_is_valid(UI.bufs.img) then
    pcall(vim.api.nvim_win_set_buf, UI.wins.img, UI.bufs.img)
  end
end

function M.get_video_thumbnail_path(video_path, post_id)
  local cache_dir = config.options.cache_dir
  local id_key = (post_id and tostring(post_id) ~= "" and tostring(post_id) ~= "nil")
    and tostring(post_id)
    or (video_path and video_path:match("([^/]+)%.%w+$") or "temp")
  return string.format("%s/vthumb_%s.jpg", cache_dir, id_key)
end

function M.get_saved_video_path(post_id)
  if not post_id or tostring(post_id) == "" or tostring(post_id) == "nil" then
    return nil
  end
  local save_dir = config.options.save_dir and vim.fn.expand(config.options.save_dir)
  if not save_dir or save_dir == "" then
    return nil
  end
  local State = state.State
  local local_index = require("gelbooru.local.index")
  local num_id = tonumber(post_id)
  local saved_ext = num_id and State and State.saved_index and State.saved_index[num_id]
  if not saved_ext and local_index.update_saved_index then
    local idx = local_index.update_saved_index()
    saved_ext = num_id and idx and idx[num_id]
  end
  if saved_ext and (saved_ext == "mp4" or saved_ext == "webm") then
    local candidate = string.format("%s/%s.%s", save_dir, tostring(post_id), saved_ext)
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end
  for _, ext in ipairs({ "mp4", "webm" }) do
    local candidate = string.format("%s/%s.%s", save_dir, tostring(post_id), ext)
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end
  return nil
end

function M.extract_video_thumbnail(video_path, post_id, cb)
  if post_id then
    local cached_thumb = M.get_video_thumbnail_path(video_path, post_id)
    if vim.fn.filereadable(cached_thumb) == 1 and (vim.fn.getfsize(cached_thumb) or 0) > 512 then
      if cb then cb(cached_thumb) end
      return
    end
  end

  local vpath = video_path
  if (not vpath or vim.fn.filereadable(vpath) == 0 or vpath:match("%.jpg$") or vpath:match("vthumb_")) and post_id then
    local State = state.State
    local found = nil
    if State and State.posts then
      for _, post in ipairs(State.posts) do
        if post.id and tostring(post.id) == tostring(post_id) and post.file_url and vim.fn.filereadable(post.file_url) == 1 then
          found = post.file_url
          break
        end
      end
    end
    if not found then
      found = M.get_saved_video_path(post_id)
    end
    if found then
      vpath = found
    elseif vpath and (vpath:match("%.jpg$") or vpath:match("vthumb_")) then
      vpath = nil
    end
  end

  if not vpath or vpath:match("%.part$") or vpath:match("%.jpg$") or vpath:match("vthumb_")
    or vim.fn.filereadable(vpath) == 0 or (vim.fn.getfsize(vpath) or 0) <= 0 then
    if cb then cb(nil) end
    return
  end

  local thumb_dest = M.get_video_thumbnail_path(vpath, post_id)
  if vim.fn.filereadable(thumb_dest) == 1 and (vim.fn.getfsize(thumb_dest) or 0) > 512 then
    if cb then cb(thumb_dest) end
    return
  end

  if vim.fn.executable("ffmpeg") ~= 1 then
    if cb then cb(nil) end
    return
  end

  local util = require("gelbooru.core.util")
  util.ensure(config.options.cache_dir)

  local spawn_ok = pcall(function()
    return vim.system({
      "ffmpeg",
      "-ss",
      "00:00:01",
      "-i",
      vpath,
      "-frames:v",
      "1",
      "-q:v",
      "2",
      thumb_dest,
      "-y",
    }, {}, function(out)
      vim.schedule(function()
        if out.code == 0 and vim.fn.filereadable(thumb_dest) == 1 and (vim.fn.getfsize(thumb_dest) or 0) > 512 then
          if cb then cb(thumb_dest) end
        else
          if cb then cb(nil) end
        end
      end)
    end)
  end)
  if not spawn_ok and cb then
    cb(nil)
  end
end

function M.render_video_placeholder(p, message)
  pcall(M.close_current_placement)
  if state.State.torn_down then
    return
  end
  local UI = state.UI
  local util = require("gelbooru.core.util")
  if not (UI.bufs and UI.bufs.img and vim.api.nvim_buf_is_valid(UI.bufs.img)) then
    UI.bufs.img = util.scratch()
    vim.bo[UI.bufs.img].bufhidden = "hide"
  end

  local filename = p and (p.file_url and p.file_url:match("([^/]+)$") or tostring(p.id or "video")) or "video"
  local ext = (filename:match("%.([%w]+)$") or "video"):upper()
  local status_msg = message or "Preview not playable in terminal"

  local lines = {
    "",
    "  ▶ [ VIDEO FILE: " .. ext .. " ]",
    "",
    "  File       : " .. filename,
  }
  if p and p.width and p.height and p.width > 0 and p.height > 0 then
    lines[#lines + 1] = string.format("  Dimensions : %dx%d", p.width, p.height)
  end
  if p and p.id then
    lines[#lines + 1] = "  Post ID    : " .. tostring(p.id)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Status     : " .. status_msg
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Keymaps:"
  lines[#lines + 1] = "    • 'O' : Open / play in media viewer"
  if p and p.id and not p.is_local then
    lines[#lines + 1] = "    • 'o' : Open post web page"
  end

  util.set_lines(UI.bufs.img, lines)
  vim.bo[UI.bufs.img].modifiable = false
  attach_defensive_keymaps(UI.bufs.img)

  if UI.wins and UI.wins.img and vim.api.nvim_win_is_valid(UI.wins.img)
    and UI.bufs and UI.bufs.img and vim.api.nvim_buf_is_valid(UI.bufs.img) then
    pcall(vim.api.nvim_win_set_buf, UI.wins.img, UI.bufs.img)
  end
end

function M.clear_snacks_cache_for(post_id)
  if not post_id or tostring(post_id) == "" or tostring(post_id) == "nil" then
    return
  end
  local ok, cache_dir = pcall(vim.fn.stdpath, "cache")
  local snacks_cache = (ok and type(cache_dir) == "string" and cache_dir ~= "") and (cache_dir .. "/snacks/image/")
    or vim.fn.expand("~/.cache/nvim/snacks/image/")
  if vim.fn.isdirectory(snacks_cache) == 0 then
    local fallback = vim.fn.expand("~/.cache/nvim/snacks/image/")
    if vim.fn.isdirectory(fallback) == 1 then
      snacks_cache = fallback
    end
  end
  local pattern = "%f[%d]" .. post_id .. "%f[%D]"
  for _, f in ipairs(vim.fn.glob(snacks_cache .. "*", false, true)) do
    if f:find(pattern) then
      vim.fn.delete(f)
    end
  end
  local config_cache = config.options.cache_dir
  local vthumb = string.format("%s/vthumb_%s.jpg", config_cache, tostring(post_id))
  if vim.fn.filereadable(vthumb) == 1 then
    pcall(vim.fn.delete, vthumb)
  end
end

local function sanitize_dpi(img)
  if img and img.info and img.info.dpi then
    local dpi = img.info.dpi
    if (dpi.width and (dpi.width > 300 or dpi.width < 50))
      or (dpi.height and (dpi.height > 300 or dpi.height < 50)) then
      dpi.width = 96
      dpi.height = 96
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
    sanitize_dpi(p.img)
    p._state = nil
    pcall(p.update, p)
    pcall(vim.api.nvim_buf_clear_namespace, p.buf, vim.api.nvim_create_namespace("snacks.image"), 0, 1)
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
    sanitize_dpi(current.img)
    pcall(vim.api.nvim_win_set_buf, win, current.buf)
    current._state = nil
    pcall(current.update, current)
    pcall(vim.api.nvim_buf_clear_namespace, current.buf, vim.api.nvim_create_namespace("snacks.image"), 0, 1)
    log("DEBUG", "RENDER", "In-place resize nudge: %s", path)
    return true
  end

  -- New image: create a fresh placement with auto_resize so snacks wires its
  -- own WinResized handler and recomputes dimensions automatically. We do NOT
  -- pass max_width/max_height — the window itself is the constraint and snacks
  -- reads its live dimensions on every update().
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  attach_defensive_keymaps(buf)
  local opts = {
    pos = { 1, 0 },
    auto_resize = true,
    on_update_pre = function(p)
      sanitize_dpi(p and p.img)
    end,
  }

  local place_ok, placement = pcall(placement_mod.new, buf, path, opts)
  if not place_ok or not placement then
    log("WARN", "RENDER", "Failed to create snacks placement for %s: %s", path, tostring(placement))
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return false
  end

  placement.progress = function() end
  local orig_update = placement.update
  placement.update = function(self)
    sanitize_dpi(self and self.img)
    if orig_update then
      pcall(orig_update, self)
    end
    if self and self.buf and vim.api.nvim_buf_is_valid(self.buf) then
      pcall(vim.api.nvim_buf_clear_namespace, self.buf, vim.api.nvim_create_namespace("snacks.image"), 0, 1)
    end
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
  pcall(vim.api.nvim_buf_clear_namespace, placement.buf, vim.api.nvim_create_namespace("snacks.image"), 0, 1)
  pcall(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = false
    end
  end)
  log("DEBUG", "RENDER", "Image rendered via snacks.image: %s", path)
  return true
end

return M
