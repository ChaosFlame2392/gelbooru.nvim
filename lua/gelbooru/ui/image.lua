local config = require("gelbooru.core.config")
local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local constants = require("gelbooru.core.constants")

local M = {}

M.active_ffmpeg_handles = {}

function M.file_ext_from_url(url)
  local ext = util.file_ext(url)
  return ext ~= "" and ext or "jpg"
end

M.VIDEO_EXTS = {
  ["mp4"] = true,
  ["webm"] = true,
  ["avi"] = true,
  ["mov"] = true,
  ["mkv"] = true,
}

function M.is_video_post(p)
  local ext = M.file_ext_from_url(p and p.file_url)
  return M.VIDEO_EXTS[ext] == true
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

function M.get_saved_media_path(post_id, fallback_url)
  if not post_id or tostring(post_id) == "" or tostring(post_id) == "nil" then
    return nil
  end
  local State = state.State
  local del_key = tostring(post_id)
  if State and State.pending_deletions and State.pending_deletions[del_key] then
    return nil
  end

  local save_dir = config.options.save_dir and vim.fn.expand(config.options.save_dir)
  if not save_dir or save_dir == "" or vim.fn.isdirectory(save_dir) ~= 1 then
    return nil
  end

  local num_id = tonumber(post_id)
  local local_index = require("gelbooru.local.index")
  local saved_ext = num_id and State and State.saved_index and State.saved_index[num_id]
  if not saved_ext and local_index.update_saved_index then
    local idx = local_index.update_saved_index()
    saved_ext = num_id and idx and idx[num_id]
  end

  if saved_ext and saved_ext ~= "" then
    local candidate = string.format("%s/%s.%s", save_dir, tostring(post_id), saved_ext)
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end

  if fallback_url and fallback_url ~= "" then
    local ext = M.file_ext_from_url(fallback_url)
    if ext and ext ~= "" then
      local candidate = string.format("%s/%s.%s", save_dir, tostring(post_id), ext)
      if vim.fn.filereadable(candidate) == 1 then
        return candidate
      end
    end
  end

  local common_exts = { "jpg", "jpeg", "png", "gif", "webm", "mp4", "mkv" }
  for _, ext in ipairs(common_exts) do
    local candidate = string.format("%s/%s.%s", save_dir, tostring(post_id), ext)
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end

  return nil
end

function M.is_in_save_dir(path)
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

  -- Prioritize permanently downloaded media from save_dir over low-res preview cache
  if p.id and not p._pending_delete then
    local saved_path = M.get_saved_media_path(p.id, p.file_url)
    if saved_path then
      if M.is_video_post(p) or (saved_path and M.VIDEO_EXTS[util.file_ext(saved_path)]) then
        local thumb_dest = M.get_video_thumbnail_path(saved_path, p.id)
        return { thumb_dest }, thumb_dest
      end
      return { saved_path }, saved_path
    end
  end

  local urls, seen = {}, {}
  local candidates
  if M.is_video_post(p) then
    candidates = {}
    if p.preview_url and p.preview_url ~= "" then
      table.insert(candidates, p.preview_url)
    end
    if p.sample_url and p.sample_url ~= "" and not M.VIDEO_EXTS[util.file_ext(p.sample_url)] then
      table.insert(candidates, p.sample_url)
    end
  else
    candidates = { p.sample_url, p.preview_url, p.file_url }
  end
  for i = 1, #candidates do
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

function M.resolve_post_dimensions(p, opt_path)
  if not p then
    return nil, nil
  end
  if p.width and p.height and p.width > 0 and p.height > 0 then
    return p.width, p.height
  end
  local path = opt_path or p.file_url or p.sample_url or p.preview_url
  if not (path and type(path) == "string" and vim.fn.filereadable(path) == 1) then
    local _, dest = M.get_preview_targets(p)
    if dest and vim.fn.filereadable(dest) == 1 then
      path = dest
    end
  end
  if path and type(path) == "string" and vim.fn.filereadable(path) == 1 then
    local w, h = util.read_image_dimensions(path)
    if w and h and w > 0 and h > 0 then
      p.width = w
      p.height = h
      return w, h
    end
  end
  return p.width, p.height
end

function M.abort_all_ffmpeg()
  for h in pairs(M.active_ffmpeg_handles or {}) do
    if h and h.kill then
      pcall(h.kill, h, constants.SIGKILL)
    end
  end
  M.active_ffmpeg_handles = {}
end

function M.abort_convert(placement)
  if not placement then
    return
  end
  local img = placement.img
  local convert = (img and img._convert) or placement._convert
  if not convert then
    return
  end

  local aborted_step = nil
  if type(convert.current) == "function" then
    local ok, cur = pcall(convert.current, convert)
    if ok and cur then
      aborted_step = cur
    end
  end
  if not aborted_step and type(convert.steps) == "table" then
    local step_idx = convert._step or convert.step
    if type(step_idx) == "number" and convert.steps[step_idx] then
      aborted_step = convert.steps[step_idx]
    else
      for _, s in ipairs(convert.steps) do
        if s and s.proc then
          aborted_step = s
          break
        end
      end
    end
  end

  if type(convert.abort) == "function" then
    pcall(convert.abort, convert)
  end

  local function delete_step_file(file)
    if not file or file == "" then
      return
    end
    if vim.fn.filereadable(file) == 1 then
      pcall(vim.fn.delete, file)
    end
    local info_file = file .. ".info"
    if vim.fn.filereadable(info_file) == 1 then
      pcall(vim.fn.delete, info_file)
    end
  end

  -- Unlink any partial or 0-byte step files on disk when aborted mid-flight
  if type(convert.steps) == "table" then
    for _, step in ipairs(convert.steps) do
      if step and step.file then
        local is_aborted_step = (step == aborted_step)
        local is_done = step.done == true
        local sz = (vim.fn.filereadable(step.file) == 1) and (vim.fn.getfsize(step.file) or 0) or -1

        if sz == 0 or (is_aborted_step and not is_done) then
          delete_step_file(step.file)
        elseif sz > 0 then
          local info_file = step.file .. ".info"
          local info_corrupt = false
          if vim.fn.filereadable(info_file) == 1 then
            local lines = vim.fn.readfile(info_file)
            local content = vim.trim(table.concat(lines or {}, " ")):lower()
            if content:find("identify:") or content:find("improper") or content:find("error") or content:find("failed") then
              info_corrupt = true
            end
          end
          if info_corrupt or is_aborted_step then
            delete_step_file(step.file)
          end
        end
      end
    end
  end

  if convert.file then
    local sz = (vim.fn.filereadable(convert.file) == 1) and (vim.fn.getfsize(convert.file) or 0) or -1
    if sz <= 0 then
      delete_step_file(convert.file)
    end
  end
end

function M.close_current_placement()
  local UI = state.UI
  if UI.current_placement then
    M.abort_convert(UI.current_placement)
    if UI.current_placement.close then
      pcall(UI.current_placement.close, UI.current_placement)
    end
    UI.current_placement = nil
  end
  if UI.wins and UI.wins.img and vim.api.nvim_win_is_valid(UI.wins.img)
    and UI.bufs and UI.bufs.img and vim.api.nvim_buf_is_valid(UI.bufs.img) then
    pcall(vim.api.nvim_win_set_buf, UI.wins.img, UI.bufs.img)
  end
  M.abort_all_ffmpeg()
end

local function attach_defensive_keymaps(buf)
  local util = require("gelbooru.core.util")
  util.shield_buffer(buf)

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
      pcall(vim.api.nvim_win_set_cursor, s.UI.wins.list, { math.max(1, s.State.cur), 0 })
      local ui = require("gelbooru.ui")
      if ui and ui.set_status then
        ui.set_status()
      end
    end
    vim.schedule(function()
      if s.State.torn_down then
        return
      end
      if s.UI.wins.list and vim.api.nvim_win_is_valid(s.UI.wins.list) then
        local cur = vim.api.nvim_get_current_win()
        if cur ~= s.UI.wins.list and cur ~= s.UI.wins.input and cur ~= s.UI.wins.meta then
          pcall(vim.api.nvim_set_current_win, s.UI.wins.list)
          pcall(vim.api.nvim_win_set_cursor, s.UI.wins.list, { math.max(1, s.State.cur), 0 })
        end
      end
    end)
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

  util.keymap(buf, "n", "<LeftMouse>", go_list)
  util.keymap(buf, "n", "<2-LeftMouse>", go_list)
  util.keymap(buf, "n", "<3-LeftMouse>", go_list)
  util.keymap(buf, "n", "<4-LeftMouse>", go_list)
  util.keymap(buf, "n", "<RightMouse>", go_list)
  util.keymap(buf, "n", "<Space>", go_list)
  util.keymap(buf, "n", " ", go_list)
  util.keymap(buf, "n", "<Leader>", go_list)
  util.keymap(buf, "n", "<Localleader>", go_list)

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

  util.keymap(buf, "n", "d", function()
    local ui = require("gelbooru.ui")
    if ui and ui.delete_current then
      ui.delete_current()
    end
  end)
  util.keymap(buf, "n", "D", function()
    local ui = require("gelbooru.ui")
    if ui and ui.delete_current then
      ui.delete_current()
    end
  end)

  for _, k in ipairs({ "i", "I", "a", "A", "s", "S", "/" }) do
    util.keymap(buf, "n", k, go_search)
  end

  local shield_keys = {
    "b", "B", "c", "C", "e", "E", "f", "F", "h", "H", "l", "L",
    "n", "N", "p", "P", "v", "V", "<C-v>", "w", "W", "x", "X",
    "y", "Y", "z", "Z", ";", ":", "'", '"', "<BS>", "<Del>",
    "<C-f>", "<C-b>", "<C-d>", "<C-u>", "<C-e>", "<C-y>", "<C-o>", "<C-i>",
    "<C-p>", "<C-n>", "<C-w>", "<C-r>", "<Tab>", "<S-Tab>",
    "<Up>", "<Down>", "<Left>", "<Right>",
  }
  for _, sk in ipairs(shield_keys) do
    util.keymap(buf, "n", sk, go_list)
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
  if saved_ext and M.VIDEO_EXTS[saved_ext] then
    local candidate = string.format("%s/%s.%s", save_dir, tostring(post_id), saved_ext)
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end
  for ext in pairs(M.VIDEO_EXTS) do
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
    if vim.fn.filereadable(cached_thumb) == 1 and (vim.fn.getfsize(cached_thumb) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES then
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
  if vim.fn.filereadable(thumb_dest) == 1 and (vim.fn.getfsize(thumb_dest) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES then
    if cb then cb(thumb_dest) end
    return
  end

  if vim.fn.executable("ffmpeg") ~= 1 then
    if cb then cb(nil) end
    return
  end

  local util = require("gelbooru.core.util")
  util.ensure(config.options.cache_dir)

  local handle = nil
  local done = false
  local spawn_ok, res = pcall(function()
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
      done = true
      if handle then
        M.active_ffmpeg_handles[handle] = nil
      end
      vim.schedule(function()
        if state.State.torn_down then
          return
        end
        if handle then
          M.active_ffmpeg_handles[handle] = nil
        end
        if out.code == 0 and vim.fn.filereadable(thumb_dest) == 1 and (vim.fn.getfsize(thumb_dest) or 0) > 512 then
          if cb then cb(thumb_dest) end
        else
          if cb then cb(nil) end
        end
      end)
    end)
  end)

  if not spawn_ok or not res then
    if cb then cb(nil) end
    return nil
  end

  handle = res
  if handle and not done then
    M.active_ffmpeg_handles[handle] = handle
  end
  return handle
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
  if p and (not p.width or p.width <= 0) then
    local path = p.file_url or p.sample_url
    if path and type(path) == "string" and vim.fn.filereadable(path) == 1 then
      local w, h = util.read_image_dimensions(path)
      if w and h and w > 0 and h > 0 then
        p.width = w
        p.height = h
      end
    end
  end
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

function M.get_snacks_cache_dir()
  if M._snacks_cache_dir and type(M._snacks_cache_dir) == "string" and M._snacks_cache_dir ~= "" then
    return M._snacks_cache_dir
  end
  if _G.Snacks and _G.Snacks.image and _G.Snacks.image.config and type(_G.Snacks.image.config.cache) == "string" and _G.Snacks.image.config.cache ~= "" then
    return _G.Snacks.image.config.cache
  end
  local ok, cache_dir = pcall(vim.fn.stdpath, "cache")
  local snacks_cache = (ok and type(cache_dir) == "string" and cache_dir ~= "") and (cache_dir .. "/snacks/image")
    or vim.fn.expand("~/.cache/nvim/snacks/image")
  if vim.fn.isdirectory(snacks_cache) == 0 then
    local fallback = vim.fn.expand("~/.cache/nvim/snacks/image")
    if vim.fn.isdirectory(fallback) == 1 then
      snacks_cache = fallback
    end
  end
  return snacks_cache
end

function M.find_snacks_cache_candidates(target)
  if not target or target == "" or tostring(target) == "nil" then
    return {}
  end
  local snacks_cache = M.get_snacks_cache_dir()
  if vim.fn.isdirectory(snacks_cache) ~= 1 then
    return {}
  end

  local str_target = tostring(target)
  local candidate_files = {}
  local seen = {}
  local function add_cand(f)
    if f and f ~= "" and not seen[f] then
      seen[f] = true
      table.insert(candidate_files, f)
    end
  end

  local is_url = str_target:match("^https?://") ~= nil
  local is_path = not is_url and (str_target:find("/") ~= nil or vim.fn.filereadable(str_target) == 1)

  if is_url then
    local clean_url = str_target:match("^([^?#]+)") or str_target
    local fname = clean_url:match("([^/]+)$") or clean_url
    local base = vim.fn.fnamemodify(fname, ":r")
    local sanitized_base = base:gsub("[^%w%.]+", "-")
    local bases = { base }
    if sanitized_base ~= base then
      table.insert(bases, sanitized_base)
    end

    local ok_sha, hash = pcall(vim.fn.sha256, clean_url .. "0")
    if ok_sha and hash then
      local h8 = hash:sub(1, 8)
      for _, b in ipairs(bases) do
        local prefix = h8 .. "-" .. b
        for _, f in ipairs(vim.fn.glob(snacks_cache .. "/" .. prefix .. "*", false, true)) do
          add_cand(f)
        end
      end
    end
    for _, b in ipairs(bases) do
      for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*-" .. b .. ".*", false, true)) do
        add_cand(f)
      end
      for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*-" .. b .. "-*.*", false, true)) do
        add_cand(f)
      end
      for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*" .. b .. "*", false, true)) do
        add_cand(f)
      end
    end
  elseif is_path then
    local norm_src = vim.fs.normalize(vim.fn.fnamemodify(str_target, ":p"))
    local base = vim.fn.fnamemodify(norm_src, ":t:r")
    local sanitized_base = base:gsub("[^%w%.]+", "-")
    local bases = { base }
    if sanitized_base ~= base then
      table.insert(bases, sanitized_base)
    end

    local ok_sha, hash = pcall(vim.fn.sha256, norm_src .. "0")
    if ok_sha and hash then
      local h8 = hash:sub(1, 8)
      for _, b in ipairs(bases) do
        local prefix = h8 .. "-" .. b
        for _, f in ipairs(vim.fn.glob(snacks_cache .. "/" .. prefix .. "*", false, true)) do
          add_cand(f)
        end
      end
    end
    for _, b in ipairs(bases) do
      for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*-" .. b .. ".*", false, true)) do
        add_cand(f)
      end
      for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*-" .. b .. "-*.*", false, true)) do
        add_cand(f)
      end
    end
  else
    local base = vim.fn.fnamemodify(str_target, ":t:r")
    local sanitized_base = base:gsub("[^%w%.]+", "-")
    local bases = { base }
    if sanitized_base ~= base then
      table.insert(bases, sanitized_base)
    end

    if str_target:match("^%d+$") then
      local pattern = "%f[%d]" .. str_target .. "%f[%D]"
      for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*", false, true)) do
        if f:find(pattern) then
          add_cand(f)
        end
      end
    else
      for _, b in ipairs(bases) do
        for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*-" .. b .. ".*", false, true)) do
          add_cand(f)
        end
        for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*" .. b .. "*", false, true)) do
          add_cand(f)
        end
      end
    end
  end

  return candidate_files
end

function M.clean_corrupt_snacks_cache(target)
  if not target or target == "" or tostring(target) == "nil" then
    return
  end
  local candidate_files = M.find_snacks_cache_candidates(target)
  for _, f in ipairs(candidate_files) do
    if vim.fn.filereadable(f) == 1 then
      local size = vim.fn.getfsize(f) or 0
      local is_corrupt = false
      if size <= 0 then
        is_corrupt = true
      elseif f:match("%.info$") then
        local lines = vim.fn.readfile(f)
        local content = vim.trim(table.concat(lines or {}, " ")):lower()
        if content == ""
          or content:find("identify:")
          or content:find("improper image header")
          or content:find("error")
          or content:find("failed")
          or content:find("corrupt") then
          is_corrupt = true
        end
      else
        local fd = io.open(f, "rb")
        if fd then
          local head = fd:read(64) or ""
          fd:close()
          local lhead = head:lower()
          if lhead:find("identify:")
            or lhead:find("improper")
            or lhead:find("<!doctype")
            or lhead:find("<html") then
            is_corrupt = true
          end
        end

        if not is_corrupt then
          local w, h = util.read_image_dimensions(f)
          if not (w and h and w > 0 and h > 0) then
            is_corrupt = true
          end
        end

        local info_file = f .. ".info"
        if not is_corrupt and vim.fn.filereadable(info_file) == 1 then
          local isz = vim.fn.getfsize(info_file) or 0
          if isz <= 0 then
            is_corrupt = true
          else
            local lines = vim.fn.readfile(info_file)
            local content = vim.trim(table.concat(lines or {}, " ")):lower()
            if content == ""
              or content:find("identify:")
              or content:find("improper image header")
              or content:find("error")
              or content:find("failed")
              or content:find("corrupt") then
              is_corrupt = true
            end
          end
        end
      end

      if is_corrupt then
        pcall(vim.fn.delete, f)
        if not f:match("%.info$") then
          local info_file = f .. ".info"
          if vim.fn.filereadable(info_file) == 1 then
            pcall(vim.fn.delete, info_file)
          end
        else
          local img_file = f:gsub("%.info$", "")
          if vim.fn.filereadable(img_file) == 1 then
            local isz = vim.fn.getfsize(img_file) or 0
            if isz <= 0 then
              pcall(vim.fn.delete, img_file)
            else
              local iw, ih = util.read_image_dimensions(img_file)
              if not (iw and ih and iw > 0 and ih > 0) then
                pcall(vim.fn.delete, img_file)
              end
            end
          end
        end
      end
    end
  end
end

function M.clear_snacks_cache_for(post_id_or_path)
  if not post_id_or_path or tostring(post_id_or_path) == "" or tostring(post_id_or_path) == "nil" then
    return
  end
  local candidate_files = M.find_snacks_cache_candidates(post_id_or_path)
  for _, f in ipairs(candidate_files) do
    pcall(vim.fn.delete, f)
  end

  local str_target = tostring(post_id_or_path)
  local num_id = str_target:match("(%d+)")
  if num_id then
    local config_cache = config.options.cache_dir
    local vthumb = string.format("%s/vthumb_%s.jpg", config_cache, num_id)
    if vim.fn.filereadable(vthumb) == 1 then
      pcall(vim.fn.delete, vthumb)
    end
  end

  M.clean_corrupt_snacks_cache(post_id_or_path)
end

function M.sanitize_dpi(img)
  if img and img.info and img.info.dpi then
    local dpi = img.info.dpi
    if (dpi.width and (dpi.width >= constants.DPI_MAX_VALID or dpi.width < constants.DPI_MIN_VALID))
      or (dpi.height and (dpi.height >= constants.DPI_MAX_VALID or dpi.height < constants.DPI_MIN_VALID)) then
      dpi.width = constants.STANDARD_SCREEN_DPI
      dpi.height = constants.STANDARD_SCREEN_DPI
    end
  end
end
local sanitize_dpi = M.sanitize_dpi

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

  -- Suppress snacks' unmanaged progress timer on the class table BEFORE placement.new runs.
  -- Otherwise placement.new synchronously invokes self:progress() which starts an unmanaged 80ms
  -- timer writing "convert loading …" into the placement buffer.
  if placement_mod.progress then
    placement_mod.progress = function() end
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
    log("DEBUG", "RENDER", "In-place resize nudge: %s", path)
    return true
  end

  -- Purge any 0-byte or corrupted cache entries before attempting to render
  M.clean_corrupt_snacks_cache(path)

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
  pcall(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = false
    end
  end)
  log("DEBUG", "RENDER", "Image rendered via snacks.image: %s", path)
  return true
end

return M
