local api = require("gelbooru.net.api")
local autocomplete = require("gelbooru.ui.autocomplete")
local config = require("gelbooru.core.config")
local constants = require("gelbooru.core.constants")
local download = require("gelbooru.net.download")
local history = require("gelbooru.core.history")
local image = require("gelbooru.ui.image")
local layout = require("gelbooru.ui.layout")
local render = require("gelbooru.ui.render")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")

local M = {}

local function enter_search()
  require("gelbooru.ui.lifecycle").enter_search()
end

local function exit_input()
  require("gelbooru.ui.lifecycle").exit_input()
end

local function teardown()
  require("gelbooru.ui.lifecycle").teardown()
end

function M.on_cursor_change(action)
  local State = state.State
  local UI = state.UI
  if #State.posts == 0 then
    return
  end
  local old_cur = State.cur
  if action == 1 or action == "j" then
    State.cur = math.min(State.cur + 1, #State.posts)
    State.scroll_dir = 1
  elseif action == -1 or action == "k" then
    State.cur = math.max(State.cur - 1, 1)
    State.scroll_dir = -1
  elseif action == "gg" then
    State.cur = 1
    State.scroll_dir = -1
  elseif action == "G" then
    State.cur = #State.posts
    State.scroll_dir = 1
  elseif type(action) == "number" then
    State.cur = math.max(1, math.min(#State.posts, action))
    if State.cur > old_cur then
      State.scroll_dir = 1
    elseif State.cur < old_cur then
      State.scroll_dir = -1
    end
  end
  if State.history[State.history_idx] then
    State.history[State.history_idx].cur = State.cur
  end
  UI._syncing_cursor = true
  render.render_list()
  UI._syncing_cursor = false
  render.render_preview(false)
  if not (State.posts[State.cur] and State.posts[State.cur].is_local) then
    download.prefetch_around(State.cur, State.scroll_dir)
  end
  if State.cur >= #State.posts - constants.AUTOPAGE_BOUNDARY_THRESHOLD then
    api.fetch(1, false)
  end
end

function M.force_refresh()
  local State = state.State
  local p = State.posts[State.cur]
  if p and p.id then
    local meta_path = util.meta_cache_path(p.id)
    if meta_path and vim.fn.filereadable(meta_path) == 1 then
      pcall(vim.fn.delete, meta_path)
    end
    p._metadata_fetched = nil
  end
  pcall(function()
    require("gelbooru.net.api").clear_session_cache()
  end)
  render.render_preview(true)
end

function M.open_web_page()
  local State = state.State
  local p = State.posts[State.cur]
  if not p or not p.id or tostring(p.id) == "" or tostring(p.id) == "nil" then
    render.set_status("No post ID available for browser lookup", constants.STATUS_TIMEOUT_HISTORY_MS)
    return
  end
  util.open_url(string.format("https://gelbooru.com/index.php?page=post&s=view&id=%s", tostring(p.id)))
end

function M.open_media_viewer()
  local State = state.State
  local p = State.posts[State.cur]
  if not p then return end
  if p.is_local then
    if not p.file_url or p.file_url == "" then
      render.set_status("No local file available to open", constants.STATUS_TIMEOUT_HISTORY_MS)
      return
    end
    util.open_media(p.file_url)
    return
  end
  if not p.id or tostring(p.id) == "" or tostring(p.id) == "nil" then
    render.set_status("No post ID available to open", constants.STATUS_TIMEOUT_HISTORY_MS)
    return
  end
  if not p.file_url or p.file_url == "" then
    render.set_status("No file URL for this post", constants.STATUS_TIMEOUT_HISTORY_MS)
    return
  end
  local ext = image.file_ext_from_url(p.file_url)
  local dest = string.format("%s/%s.%s", config.options.save_dir, tostring(p.id), ext)
  if vim.fn.filereadable(dest) == 1 then
    util.open_media(dest)
  else
    render.set_status("Downloading " .. tostring(p.id) .. " before opening…")
    api.save_current(function(saved, saved_path)
      if saved and saved_path and vim.fn.filereadable(saved_path) == 1 then
        util.open_media(saved_path)
      end
    end)
  end
end

function M.toggle_zen()
  local State = state.State
  local UI = state.UI
  State.zen_mode = not State.zen_mode
  local l = layout.calc_layout(true)
  layout.apply_layout(l)
  if State.zen_mode then
    if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
      vim.wo[UI.wins.list].cursorline = false
      pcall(vim.api.nvim_set_current_win, UI.wins.list)
    end
  else
    if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
      vim.wo[UI.wins.list].cursorline = true
      pcall(vim.api.nvim_set_current_win, UI.wins.list)
    end
    render.render_list()
  end
  image.nudge_current_placement()
end

function M.return_to_list()
  local State = state.State
  local UI = state.UI
  if State.input_focused then
    State.input_focused = false
    vim.cmd("stopinsert")
    if UI.wins.ac and vim.api.nvim_win_is_valid(UI.wins.ac) then
      pcall(vim.api.nvim_win_set_config, UI.wins.ac, { hide = true })
    end
  end
  if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
    pcall(vim.api.nvim_set_current_win, UI.wins.list)
    pcall(vim.api.nvim_win_set_cursor, UI.wins.list, { math.max(1, State.cur), 0 })
    render.set_status()
  end
  vim.schedule(function()
    if State.torn_down then return end
    if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
      local cur = vim.api.nvim_get_current_win()
      if cur ~= UI.wins.list and cur ~= UI.wins.input and cur ~= UI.wins.meta then
        pcall(vim.api.nvim_set_current_win, UI.wins.list)
        pcall(vim.api.nvim_win_set_cursor, UI.wins.list, { math.max(1, State.cur), 0 })
      end
    end
  end)
end

function M.handle_mouse_click()
  local State = state.State
  local UI = state.UI
  if State.torn_down then
    return
  end
  if UI.wins.confirm_modal and vim.api.nvim_win_is_valid(UI.wins.confirm_modal) then
    pcall(vim.api.nvim_set_current_win, UI.wins.confirm_modal)
    return
  end

  local m = vim.fn.getmousepos()
  if not m or not m.winid or m.winid == 0 then
    return
  end

  if m.winid == UI.wins.list then
    if State.input_focused then
      exit_input()
    end
    if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
      pcall(vim.api.nvim_set_current_win, UI.wins.list)
      if m.line >= 1 and m.line <= #State.posts then
        M.on_cursor_change(m.line)
      else
        pcall(vim.api.nvim_win_set_cursor, UI.wins.list, { math.max(1, State.cur), 0 })
      end
    end
  elseif UI.wins.meta and vim.api.nvim_win_is_valid(UI.wins.meta) and m.winid == UI.wins.meta then
    if State.input_focused then
      exit_input()
    end
    pcall(vim.api.nvim_set_current_win, UI.wins.meta)
    if m.line >= 1 then
      pcall(vim.api.nvim_win_set_cursor, UI.wins.meta, { m.line, math.max(0, m.wincol - 1) })
    end
  elseif UI.wins.input and vim.api.nvim_win_is_valid(UI.wins.input) and m.winid == UI.wins.input then
    enter_search()
  else
    -- Click was on non-interactive float (img, div, vdiv, hdiv, status, frame) or outside
    if State.input_focused then
      exit_input()
    end
    if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
      pcall(vim.api.nvim_set_current_win, UI.wins.list)
      pcall(vim.api.nvim_win_set_cursor, UI.wins.list, { math.max(1, State.cur), 0 })
    end
  end
end

function M.apply_autocomplete_selection(t, add_space)
  local UI = state.UI
  local State = state.State
  local full = vim.api.nvim_buf_get_lines(UI.bufs.input, 0, 1, false)[1] or ""
  local col = #full
  if UI.wins.input and vim.api.nvim_win_is_valid(UI.wins.input) then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, UI.wins.input)
    if ok and cursor and type(cursor[2]) == "number" then
      col = cursor[2]
    end
  end
  local before = full:sub(1, col)
  local word_before = before:match("(%S*)$") or ""
  local after = full:sub(col + 1)
  local word_after = after:match("^(%S*)") or ""
  local prefix = before:sub(1, #before - #word_before)
  local rest_after = after:sub(#word_after + 1)
  local sign = word_before:match("^([|%-~]+)") or ""

  local new_text = prefix .. sign .. t.n .. (add_space and " " or "") .. rest_after
  vim.api.nvim_buf_set_lines(UI.bufs.input, 0, 1, false, { new_text })
  local new_cursor_col = #prefix + #sign + #t.n + (add_space and 1 or 0)
  if UI.wins.input and vim.api.nvim_win_is_valid(UI.wins.input) then
    pcall(vim.api.nvim_win_set_cursor, UI.wins.input, { 1, new_cursor_col })
  end
  State.autocomplete_cur = 0
  State.autocomplete_navigated = false
  return new_text
end

function M.submit_input()
  local UI = state.UI
  local State = state.State
  local full = vim.api.nvim_buf_get_lines(UI.bufs.input, 0, 1, false)[1] or ""
  if State.autocomplete_navigated and State.autocomplete_cur > 0 then
    local t = State.autocomplete_filtered[State.autocomplete_cur]
    if t then
      full = M.apply_autocomplete_selection(t, false)
    end
  end
  full = full:match("^%s*(.-)%s*$")
  exit_input()
  api.execute_search(full)
end

function M.handle_input_bs()
  local UI = state.UI
  local State = state.State
  local line = vim.api.nvim_buf_get_lines(UI.bufs.input, 0, 1, false)[1] or ""
  local cursor = vim.api.nvim_win_get_cursor(UI.wins.input)
  local col = cursor[2]
  local total_chars = vim.fn.strchars(line)
  if total_chars > 0 then
    local char_idx = vim.fn.charidx(line, col)
    if char_idx < 0 or char_idx >= total_chars then
      char_idx = total_chars
    end
    if char_idx > 0 then
      local before = vim.fn.strcharpart(line, 0, char_idx - 1)
      local after = vim.fn.strcharpart(line, char_idx)
      local new_line = before .. after
      vim.api.nvim_buf_set_lines(UI.bufs.input, 0, 1, false, { new_line })
      local new_byte_col = #before
      pcall(vim.api.nvim_win_set_cursor, UI.wins.input, { 1, new_byte_col })
    end
  end
  vim.cmd("startinsert!")
  State.input_focused = true
  autocomplete.update_autocomplete()
  layout.handle_resize()
end

function M.setup_list_keymaps()
  local UI = state.UI
  local State = state.State
  local function lm(key, fn)
    util.keymap(UI.bufs.list, "n", key, fn)
  end
  lm("q", teardown)
  lm("<Esc>", teardown)
  lm("<CR>", api.save_current)
  lm("<Tab>", function()
    api.fetch(1, true)
  end)
  lm("<S-Tab>", function()
    api.fetch(-1, true)
  end)
  lm("R", M.force_refresh)
  lm("r", function()
    State.cur_id = nil
    render.render_preview(false)
  end)
  lm("j", function()
    M.on_cursor_change(1)
  end)
  lm("k", function()
    M.on_cursor_change(-1)
  end)
  lm("gg", function()
    M.on_cursor_change("gg")
  end)
  lm("G", function()
    M.on_cursor_change("G")
  end)
  lm("u", render.search_active_artist)
  lm("d", render.delete_current)
  lm("D", render.delete_current)
  lm("<", function()
    State.list_width_ratio = math.max(constants.MIN_LIST_RATIO, math.min(constants.MAX_LIST_RATIO, (State.list_width_ratio or constants.DEFAULT_LIST_WIDTH_RATIO) - constants.LIST_WIDTH_STEP))
    local l = layout.calc_layout(true)
    layout.apply_layout(l)
    render.render_list()
    image.nudge_current_placement()
  end)
  lm(">", function()
    State.list_width_ratio = math.max(constants.MIN_LIST_RATIO, math.min(constants.MAX_LIST_RATIO, (State.list_width_ratio or constants.DEFAULT_LIST_WIDTH_RATIO) + constants.LIST_WIDTH_STEP))
    local l = layout.calc_layout(true)
    layout.apply_layout(l)
    render.render_list()
    image.nudge_current_placement()
  end)
  lm("\\", M.toggle_zen)
  lm("o", M.open_web_page)
  lm("O", M.open_media_viewer)
  lm("m", function()
    State.show_meta = not State.show_meta
    layout.handle_resize()
  end)
  lm("M", function()
    if not State.show_meta or not (UI.wins.meta and vim.api.nvim_win_is_valid(UI.wins.meta)) then
      State.show_meta = true
      layout.handle_resize()
    end
    if UI.wins.meta and vim.api.nvim_win_is_valid(UI.wins.meta) then
      vim.wo[UI.wins.meta].cursorline = true
      pcall(vim.api.nvim_set_current_win, UI.wins.meta)
      render.set_status("Viewing Metadata — [q/Esc] back to posts, [/ or i] search")
    end
  end)

  for _, k in ipairs({ "i", "I", "a", "A", "s", "S", "/" }) do
    lm(k, enter_search)
  end

  lm("<C-d>", function()
    api.scroll_meta(constants.META_KEY_SCROLL_STEP)
  end)
  lm("<C-u>", function()
    api.scroll_meta(-constants.META_KEY_SCROLL_STEP)
  end)

  lm("[", history.history_prev)
  lm("]", history.history_next)

  util.keymap(UI.bufs.list, "n", "<ScrollWheelDown>", function()
    api.scroll_meta(constants.META_MOUSE_SCROLL_STEP)
  end)
  util.keymap(UI.bufs.list, "n", "<ScrollWheelUp>", function()
    api.scroll_meta(-constants.META_MOUSE_SCROLL_STEP)
  end)
  lm("<BS>", history.history_prev)

  local mouse_clicks = {
    "<LeftMouse>", "<2-LeftMouse>", "<3-LeftMouse>", "<4-LeftMouse>",
    "<RightMouse>", "<2-RightMouse>", "<3-RightMouse>", "<4-RightMouse>",
  }
  local mouse_drags = {
    "<LeftDrag>", "<LeftRelease>", "<RightDrag>", "<RightRelease>",
  }
  for _, click in ipairs(mouse_clicks) do
    util.keymap(UI.bufs.list, "n", click, M.handle_mouse_click)
  end
  for _, drag in ipairs(mouse_drags) do
    util.keymap(UI.bufs.list, "n", drag, function()
      if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
        pcall(vim.api.nvim_win_set_cursor, UI.wins.list, { math.max(1, State.cur), 0 })
      end
    end)
  end
end

function M.setup_meta_keymaps()
  local UI = state.UI
  local State = state.State
  local function mm(key, fn)
    util.keymap(UI.bufs.meta, "n", key, fn)
  end
  for _, k in ipairs({ "i", "I", "a", "A", "s", "S", "/" }) do
    mm(k, enter_search)
  end

  mm("q", M.return_to_list)
  mm("<Esc>", M.return_to_list)
  mm("M", M.return_to_list)
  mm("<BS>", M.return_to_list)
  mm("m", function()
    State.show_meta = false
    M.return_to_list()
    layout.handle_resize()
  end)
  mm("u", render.search_active_artist)
  mm("d", render.delete_current)
  mm("D", render.delete_current)
  mm("\\", M.toggle_zen)
  mm("o", M.open_web_page)
  mm("O", M.open_media_viewer)
  mm("<CR>", api.save_current)

  local mouse_clicks = {
    "<LeftMouse>", "<2-LeftMouse>", "<3-LeftMouse>", "<4-LeftMouse>",
    "<RightMouse>", "<2-RightMouse>", "<3-RightMouse>", "<4-RightMouse>",
  }
  for _, click in ipairs(mouse_clicks) do
    util.keymap(UI.bufs.meta, "n", click, M.handle_mouse_click)
  end
end

function M.setup_noninteractive_keymaps()
  local UI = state.UI
  local mouse_clicks = {
    "<LeftMouse>", "<2-LeftMouse>", "<3-LeftMouse>", "<4-LeftMouse>",
    "<RightMouse>", "<2-RightMouse>", "<3-RightMouse>", "<4-RightMouse>",
  }
  local shield_keys = {
    "b", "B", "c", "C", "e", "E", "f", "F", "h", "H", "l", "L",
    "n", "N", "p", "P", "v", "V", "<C-v>", "w", "W", "x", "X",
    "y", "Y", "z", "Z", ";", ":", "'", '"', "<BS>", "<Del>",
    "<C-f>", "<C-b>", "<C-d>", "<C-u>", "<C-e>", "<C-y>", "<C-o>", "<C-i>",
    "<C-p>", "<C-n>", "<C-w>", "<C-r>", "<Tab>", "<S-Tab>",
    "<Up>", "<Down>", "<Left>", "<Right>",
  }
  for _, buf in ipairs({ UI.bufs.frame, UI.bufs.div, UI.bufs.vdiv, UI.bufs.hdiv, UI.bufs.img, UI.bufs.status, UI.bufs.ac }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      util.shield_buffer(buf)
      for _, click in ipairs(mouse_clicks) do
        util.keymap(buf, "n", click, M.handle_mouse_click)
      end
      util.keymap(buf, "n", "<Space>", M.return_to_list)
      util.keymap(buf, "n", " ", M.return_to_list)
      util.keymap(buf, "n", "<Leader>", M.return_to_list)
      util.keymap(buf, "n", "<Localleader>", M.return_to_list)
      for _, k in ipairs({ "i", "I", "a", "A", "s", "S", "/" }) do
        util.keymap(buf, "n", k, enter_search)
      end
      util.keymap(buf, "n", "q", M.return_to_list)
      util.keymap(buf, "n", "<Esc>", M.return_to_list)
      util.keymap(buf, "n", "\\", M.toggle_zen)
      util.keymap(buf, "n", "d", render.delete_current)
      util.keymap(buf, "n", "D", render.delete_current)
      for _, sk in ipairs(shield_keys) do
        util.keymap(buf, "n", sk, M.return_to_list)
      end
    end
  end
end

function M.setup_input_keymaps()
  local UI = state.UI
  local State = state.State
  local function im_n(key, fn)
    util.keymap(UI.bufs.input, "n", key, fn)
  end
  local function im_i(key, fn)
    util.keymap(UI.bufs.input, "i", key, fn)
  end

  im_n("<Esc>", exit_input)
  im_i("<Esc>", exit_input)
  im_n("q", exit_input)
  im_n("j", exit_input)
  im_n("k", exit_input)
  im_n("<CR>", M.submit_input)
  im_i("<CR>", M.submit_input)

  for _, k in ipairs({ "i", "I", "a", "A", "s", "S", "/" }) do
    im_n(k, function()
      vim.cmd("startinsert!")
      State.input_focused = true
      autocomplete.update_autocomplete()
      layout.handle_resize()
    end)
  end

  im_n("<BS>", M.handle_input_bs)
  im_n("<C-h>", M.handle_input_bs)

  local function nav_down()
    autocomplete.navigate(1)
  end
  local function nav_up()
    autocomplete.navigate(-1)
  end
  im_i("<Down>", nav_down)
  im_i("<C-n>", nav_down)
  im_i("<Tab>", nav_down)
  im_i("<Up>", nav_up)
  im_i("<C-p>", nav_up)
  im_i("<S-Tab>", nav_up)

  im_i("<Space>", function()
    -- If the user navigated with Tab/Down/C-n, Space always selects the highlighted entry.
    if State.autocomplete_navigated and State.autocomplete_cur > 0 then
      local t = State.autocomplete_filtered[State.autocomplete_cur]
      if t then
        M.apply_autocomplete_selection(t, true)
        return
      end
    end

    local full = vim.api.nvim_buf_get_lines(UI.bufs.input, 0, 1, false)[1] or ""
    local col = #full
    if UI.wins.input and vim.api.nvim_win_is_valid(UI.wins.input) then
      local ok, cursor = pcall(vim.api.nvim_win_get_cursor, UI.wins.input)
      if ok and cursor and type(cursor[2]) == "number" then
        col = cursor[2]
      end
    end
    local before = full:sub(1, col)
    local word_before = before:match("(%S*)$") or ""
    local after = full:sub(col + 1)
    local word_after = after:match("^(%S*)") or ""
    local target_word = word_before .. word_after

    -- Without explicit navigation: auto-select only if the top suggestion is an
    -- exact or normalised match for what was typed.
    if target_word == "" or State.autocomplete_cur == 0 then
      vim.api.nvim_feedkeys(" ", "n", true)
      return
    end

    local t = State.autocomplete_filtered[State.autocomplete_cur]
    if not t then
      vim.api.nvim_feedkeys(" ", "n", true)
      return
    end

    local search_target = target_word:gsub("^[|%-~]+", ""):lower()
    local target_norm = util.normalize_str(search_target)
    local t_norm = util.normalize_str(t.n)

    if t.n:lower() ~= search_target and t_norm ~= target_norm then
      vim.api.nvim_feedkeys(" ", "n", true)
      return
    end

    M.apply_autocomplete_selection(t, true)
  end)
end

return M
