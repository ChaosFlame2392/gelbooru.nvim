local config = require("gelbooru.core.config")
local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local download = require("gelbooru.net.download")
local image = require("gelbooru.ui.image")
local tags = require("gelbooru.tags")
local autocomplete = require("gelbooru.ui.autocomplete")
local history = require("gelbooru.core.history")

local M = {}

M.image = image
M.autocomplete = autocomplete

-- Layout cache: recomputed only on resize or show_meta toggle, not every render.
local _layout_cache = nil
local _layout_show_meta = nil

local function invalidate_layout()
  _layout_cache = nil
end

function M.teardown()
  local UI = state.UI
  local State = state.State
  log("INFO", "LIFECYCLE", "Teardown Gelbooru UI")
  if UI.scroll_timer then
    UI.scroll_timer:stop()
    if not UI.scroll_timer:is_closing() then
      UI.scroll_timer:close()
    end
    UI.scroll_timer = nil
  end
  if UI.status_timer then
    UI.status_timer:stop()
    if not UI.status_timer:is_closing() then
      UI.status_timer:close()
    end
    UI.status_timer = nil
  end
  if UI.api_tag_timer then
    pcall(function()
      UI.api_tag_timer:stop()
      if not UI.api_tag_timer:is_closing() then
        UI.api_tag_timer:close()
      end
    end)
    UI.api_tag_timer = nil
  end
  if UI.ac_debounce_timer then
    pcall(function()
      UI.ac_debounce_timer:stop()
      if not UI.ac_debounce_timer:is_closing() then
        UI.ac_debounce_timer:close()
      end
    end)
    UI.ac_debounce_timer = nil
  end
  if UI.save_discovered_timer then
    pcall(function()
      UI.save_discovered_timer:stop()
      if not UI.save_discovered_timer:is_closing() then
        UI.save_discovered_timer:close()
      end
    end)
    UI.save_discovered_timer = nil
    if #State.discovered > 0 then
      local ok, encoded = pcall(vim.fn.json_encode, State.discovered)
      if ok and encoded then
        local disc_file = config.get_discovered_tags_file()
        local f = io.open(disc_file, "w")
        if f then
          f:write(encoded)
          f:close()
        end
      end
    end
  end

  download.cancel_prefetch_timers()
  -- Drop pending download callbacks so their closures are freed immediately.
  download.active_downloads = {}
  image.close_current_placement()

  vim.cmd("stopinsert")
  if UI.aug then
    pcall(vim.api.nvim_del_augroup_by_id, UI.aug)
    UI.aug = nil
  end
  for _, w in pairs(UI.wins) do
    if vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  -- Invalidate layout cache so the next open() recomputes from scratch.
  invalidate_layout()
  -- Clear all stale buf/win IDs so they don't accumulate across open/close cycles.
  state.reset_ui()
  -- Release the 800 k-tag heap so the GC can reclaim ~150 MB between sessions.
  state.reset_tag_state()
  -- Force an immediate GC pass so the tag heap and post array closures are
  -- reclaimed right away rather than waiting for the incremental collector.
  -- Two passes handle objects that are finalised and re-queued in the first pass.
  collectgarbage("collect")
  collectgarbage("collect")
end

function M.set_status(msg, reset_ms)
  local UI = state.UI
  if UI.status_timer then
    UI.status_timer:stop()
    if not UI.status_timer:is_closing() then
      UI.status_timer:close()
    end
    UI.status_timer = nil
  end
  local help =
    "  j/k: nav  <CR>: save  <Tab>/<S-Tab>: page  r: refresh  m: meta  /: search  [/]: history  q: quit"
  util.set_lines(UI.bufs.status, { msg and ("  " .. msg) or help })
  if msg and reset_ms and reset_ms > 0 then
    UI.status_timer = vim.loop.new_timer()
    UI.status_timer:start(
      reset_ms,
      0,
      vim.schedule_wrap(function()
        if UI.status_timer and not UI.status_timer:is_closing() then
          UI.status_timer:close()
        end
        UI.status_timer = nil
        M.set_status()
      end)
    )
  end
end

function M.calc_layout()
  local State = state.State
  -- Return cached layout if terminal dimensions and show_meta haven't changed.
  if _layout_cache and _layout_show_meta == State.show_meta
    and _layout_cache._TW == vim.o.columns
    and _layout_cache._TH == vim.o.lines then
    return _layout_cache
  end

  local TW, TH = vim.o.columns, vim.o.lines
  local W = math.floor(TW * 0.95)
  local H = math.floor(TH * 0.95)

  W = math.max(W, 80)
  H = math.max(H, 20)

  local R = math.floor((TH - H) / 2)
  local C = math.floor((TW - W) / 2)

  local input_h = 1
  local main_h = H - input_h - 4
  local list_w = math.floor(W * 0.25)
  local prev_w = W - list_w - 3

  local meta_h = State.show_meta and math.min(12, math.floor(main_h * 0.35)) or 0
  local img_h = main_h - meta_h - (State.show_meta and 1 or 0)

  _layout_cache = {
    _TW = TW, _TH = TH, -- cache keys
    frame = { row = R, col = C, width = W, height = H },
    input = { row = R + 1, col = C + 1, width = W - 2, height = 1 },
    div = { row = R + 2, col = C + 1, width = W - 2, height = 1 },
    list = { row = R + 3, col = C + 1, width = list_w, height = main_h },
    vdiv = { row = R + 3, col = C + 1 + list_w, width = 1, height = main_h },
    img = { row = R + 3, col = C + 1 + list_w + 1, width = prev_w, height = img_h },
    hdiv = State.show_meta and { row = R + 3 + img_h, col = C + 1 + list_w + 1, width = prev_w, height = 1 }
      or nil,
    meta = State.show_meta and { row = R + 3 + img_h + 1, col = C + 1 + list_w + 1, width = prev_w, height = meta_h }
      or nil,
    status = { row = R + H - 2, col = C + 1, width = W - 2, height = 1 },
    ac = { row = R + 2, col = C + 1, width = W - 2, height = math.min(15, H - 4) },
  }
  _layout_show_meta = State.show_meta
  return _layout_cache
end

local function draw_dividers(layout)
  local UI = state.UI
  local W = layout.frame.width
  util.set_lines(UI.bufs.div, { string.rep("─", W - 2) })

  local vdiv_lines = {}
  for _ = 1, layout.list.height do
    vdiv_lines[#vdiv_lines + 1] = "│"
  end
  util.set_lines(UI.bufs.vdiv, vdiv_lines)

  if layout.hdiv then
    util.set_lines(UI.bufs.hdiv, { string.rep("─", layout.hdiv.width) })
  end
end

function M.apply_layout(l)
  local UI = state.UI
  local State = state.State
  if not vim.api.nvim_win_is_valid(UI.wins.frame) then
    return
  end

  local function upd(win, cfg)
    if win and vim.api.nvim_win_is_valid(win) and cfg then
      vim.api.nvim_win_set_config(win, {
        relative = "editor",
        row = cfg.row,
        col = cfg.col,
        width = cfg.width,
        height = cfg.height,
      })
    end
  end

  upd(UI.wins.frame, l.frame)
  upd(UI.wins.input, l.input)
  upd(UI.wins.div, l.div)
  upd(UI.wins.list, l.list)
  upd(UI.wins.vdiv, l.vdiv)
  upd(UI.wins.img, l.img)
  upd(UI.wins.status, l.status)
  upd(UI.wins.ac, l.ac)

  if l.hdiv then
    if not UI.wins.hdiv or not vim.api.nvim_win_is_valid(UI.wins.hdiv) then
      UI.wins.hdiv = util.float(UI.bufs.hdiv, l.hdiv.row, l.hdiv.col, l.hdiv.width, l.hdiv.height, { zindex = 51 })
    else
      upd(UI.wins.hdiv, l.hdiv)
    end
  elseif UI.wins.hdiv and vim.api.nvim_win_is_valid(UI.wins.hdiv) then
    vim.api.nvim_win_hide(UI.wins.hdiv)
  end

  if l.meta then
    if not UI.wins.meta or not vim.api.nvim_win_is_valid(UI.wins.meta) then
      UI.wins.meta = util.float(UI.bufs.meta, l.meta.row, l.meta.col, l.meta.width, l.meta.height, { zindex = 51 })
    else
      upd(UI.wins.meta, l.meta)
    end
  elseif UI.wins.meta and vim.api.nvim_win_is_valid(UI.wins.meta) then
    vim.api.nvim_win_hide(UI.wins.meta)
  end

  draw_dividers(l)

  if State.input_focused then
    if vim.api.nvim_win_is_valid(UI.wins.ac) then
      vim.api.nvim_win_set_config(UI.wins.ac, { hide = false })
    end
  else
    if vim.api.nvim_win_is_valid(UI.wins.ac) then
      vim.api.nvim_win_set_config(UI.wins.ac, { hide = true })
    end
  end
end

function M.on_resize()
  invalidate_layout()
  local l = M.calc_layout()
  M.apply_layout(l)
  M.render_preview(false)
end

function M.render_list()
  local State = state.State
  local UI = state.UI
  local lines = {}
  local l = M.calc_layout()
  local LW = l.list.width
  for i, p in ipairs(State.posts) do
    local prefix = (i == State.cur) and "▶ " or "  "
    local r = (p.rating or "?"):sub(1, 1):upper()
    local score = tostring(p.score or 0)
    local is_vid = image.is_video_post(p)
    local dims = string.format("%dx%d%s", p.width or 0, p.height or 0, is_vid and " [V]" or "")
    local tags_s = config.options.show_tags_in_list and (" " .. (p.tags or ""):sub(1, math.max(0, LW - 22))) or ""
    lines[i] = string.format("%s%s ★%-5s %-15s%s", prefix, r, score, dims, tags_s)
  end
  if #lines == 0 then
    lines = { State.loading and "  Fetching…" or "  No results" }
  end
  util.set_lines(UI.bufs.list, lines)
  if vim.api.nvim_win_is_valid(UI.wins.list) then
    pcall(vim.api.nvim_win_set_cursor, UI.wins.list, { math.max(1, State.cur), 0 })
  end
end

local function load_and_render_image(p, url_idx, retry_count, force_download)
  local UI = state.UI
  local State = state.State
  local urls, dest = image.get_preview_targets(p)
  if #urls == 0 or not dest then
    return
  end
  url_idx = math.max(1, math.min(url_idx or 1, #urls))
  retry_count = retry_count or 0
  local preview_url = urls[url_idx]

  local function fail_preview(msg)
    if not vim.api.nvim_win_is_valid(UI.wins.img) then
      return
    end
    if not State.posts[State.cur] or State.posts[State.cur].id ~= p.id then
      return
    end
    pcall(vim.api.nvim_win_set_buf, UI.wins.img, UI.bufs.img)
    util.set_lines(UI.bufs.img, { "", "  [ " .. msg .. " ]" })
    M.set_status(msg, 2500)
    log("WARN", "PREVIEW", "Preview failed for post %s: %s", tostring(p.id), msg)
  end

  local function do_render()
    if not vim.api.nvim_win_is_valid(UI.wins.img) then
      return
    end
    if not State.posts[State.cur] or State.posts[State.cur].id ~= p.id then
      return
    end
    M.set_status()

    local pext = image.file_ext_from_url(preview_url)
    local source_name = image.preview_source_name(p, preview_url)
    if pext == "mp4" or pext == "webm" then
      util.set_lines(UI.bufs.img, { "", "  [ Video Post - Preview not playable ]", "  Press 'O' to open in browser." })
      M.set_status(string.format("Video post • no static %s available", source_name), 2200)
      return
    end

    local size = vim.fn.getfsize(dest)
    if size > -1 and size < 1024 then
      if retry_count < 1 then
        load_and_render_image(p, url_idx, retry_count + 1, true)
      elseif url_idx < #urls then
        load_and_render_image(p, url_idx + 1, 0, true)
      else
        fail_preview("Image Download Failed - File too small")
      end
      return
    end

    local l = M.calc_layout()
    local ok = image.render_image(UI.wins.img, dest, l.img.width, l.img.height)
    if not ok then
      if retry_count < 1 then
        load_and_render_image(p, url_idx, retry_count + 1, true)
      elseif url_idx < #urls then
        load_and_render_image(p, url_idx + 1, 0, true)
      else
        fail_preview("Image Conversion Failed - File may be corrupted or unsupported")
      end
    end
  end

  if vim.fn.filereadable(dest) == 0 or force_download then
    if force_download and vim.fn.filereadable(dest) == 1 then
      vim.fn.delete(dest)
      image.clear_snacks_cache_for(p.id)
    end
    M.set_status("Downloading preview…")
    download.download_async(preview_url, dest, function(ok)
      if ok then
        do_render()
      elseif url_idx < #urls then
        load_and_render_image(p, url_idx + 1, 0, true)
      else
        fail_preview("Preview Download Failed")
      end
    end)
  elseif download.active_downloads[dest] then
    download.download_async(preview_url, dest, function(ok)
      if ok then
        do_render()
      elseif url_idx < #urls then
        load_and_render_image(p, url_idx + 1, 0, true)
      else
        fail_preview("Preview Download Failed")
      end
    end)
  else
    do_render()
  end
end

function M.render_preview(force_download)
  local State = state.State
  local UI = state.UI
  local p = State.posts[State.cur]
  if not p then
    util.set_lines(UI.bufs.img, { "  No post selected" })
    util.set_lines(UI.bufs.meta, {})
    return
  end

  if p.id == State.cur_id and not force_download then
    return
  end
  State.cur_id = p.id

  local ext_info = image.file_ext_from_url(p.file_url)
  local is_vid = image.is_video_post(p)
  local meta = {
    "",
    string.format("  ID      : %s", p.id or "?"),
    string.format("  Rating  : %s", p.rating or "?"),
    string.format("  Score   : %s", p.score or "?"),
    string.format("  Format  : %s", ext_info .. (is_vid and " (Video)" or "")),
    string.format("  Size    : %dx%d", p.width or 0, p.height or 0),
    string.format("  Source  : %s", (p.source or "")),
  }

  local tags_sorted = {}
  local artist_tags = {}
  for raw_tag in (p.tags or ""):gmatch("%S+") do
    local tag = util.decode_html(raw_tag)
    local t = State.tags_by_name and State.tags_by_name[tag:lower()]
    if t and tonumber(t.t) == 1 then
      table.insert(artist_tags, tag)
    else
      table.insert(tags_sorted, tag)
    end
  end
  table.sort(tags_sorted)

  if #artist_tags > 0 then
    meta[#meta + 1] = ""
    meta[#meta + 1] = "  Artists : " .. table.concat(artist_tags, ", ")
  end
  meta[#meta + 1] = ""
  meta[#meta + 1] = "  Tags:"

  for _, tag in ipairs(tags_sorted) do
    meta[#meta + 1] = "    " .. tag
  end
  util.set_lines(UI.bufs.meta, meta)

  if vim.api.nvim_win_is_valid(UI.wins.meta) then
    pcall(vim.api.nvim_win_set_cursor, UI.wins.meta, { 1, 0 })
  end

  -- Background dynamic artist resolution for any unclassified tags on this post
  pcall(tags.resolve_post_tags, p, function()
    if State.posts[State.cur] and State.posts[State.cur].id == p.id then
      M.render_preview(false)
    end
  end)

  -- Check cache before doing anything visual
  local _, dest = image.get_preview_targets(p)
  local is_cached = not force_download and dest and vim.fn.filereadable(dest) == 1 and not download.active_downloads[dest]

  if not is_cached then
    if vim.api.nvim_win_is_valid(UI.wins.img) and vim.api.nvim_buf_is_valid(UI.bufs.img) then
      pcall(vim.api.nvim_win_set_buf, UI.wins.img, UI.bufs.img)
    end
    M.set_status("Loading preview…")
  else
    M.set_status()
  end

  if UI.scroll_timer then
    UI.scroll_timer:stop()
    if not UI.scroll_timer:is_closing() then
      UI.scroll_timer:close()
    end
  end

  local delay = is_cached and 30 or UI.PREVIEW_COOLDOWN_MS

  UI.scroll_timer = vim.loop.new_timer()
  UI.scroll_timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      if not UI.scroll_timer:is_closing() then
        UI.scroll_timer:close()
      end
      UI.scroll_timer = nil
      if State.posts[State.cur] and State.posts[State.cur].id == p.id then
        load_and_render_image(p, 1, 0, force_download)
        download.prefetch_around(State.cur)
      end
    end)
  )
end

function M.open(initial_tags)
  local State = state.State
  local UI = state.UI
  local api = require("gelbooru.net.api")

  util.ensure(config.options.cache_dir)
  util.ensure(config.options.save_dir)
  util.ensure(config.options.tags_dir)
  tags.load_tags()

  UI.bufs.frame = util.scratch()
  UI.bufs.input = vim.api.nvim_create_buf(false, true)
  vim.bo[UI.bufs.input].bufhidden = "wipe"
  vim.bo[UI.bufs.input].modifiable = true
  UI.bufs.div = util.scratch()
  UI.bufs.list = util.scratch()
  UI.bufs.vdiv = util.scratch()
  UI.bufs.img = util.scratch()
  UI.bufs.hdiv = util.scratch()
  vim.bo[UI.bufs.hdiv].bufhidden = "hide"
  UI.bufs.meta = util.scratch()
  vim.bo[UI.bufs.meta].bufhidden = "hide"
  UI.bufs.status = util.scratch()
  UI.bufs.ac = util.scratch()
  vim.bo[UI.bufs.ac].bufhidden = "hide"

  local l = M.calc_layout()

  UI.wins.frame = util.float(UI.bufs.frame, l.frame.row, l.frame.col, l.frame.width, l.frame.height, {
    border = "rounded",
    title = "  Gelbooru  ",
    title_pos = "center",
    zindex = 50,
  })
  vim.wo[UI.wins.frame].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"

  UI.wins.input = util.float(UI.bufs.input, l.input.row, l.input.col, l.input.width, l.input.height, { zindex = 51 })
  UI.wins.div = util.float(UI.bufs.div, l.div.row, l.div.col, l.div.width, l.div.height, { zindex = 51 })
  UI.wins.list = util.float(UI.bufs.list, l.list.row, l.list.col, l.list.width, l.list.height, { zindex = 51 })
  UI.wins.vdiv = util.float(UI.bufs.vdiv, l.vdiv.row, l.vdiv.col, l.vdiv.width, l.vdiv.height, { zindex = 51 })
  UI.wins.img = util.float(UI.bufs.img, l.img.row, l.img.col, l.img.width, l.img.height, { zindex = 51 })
  if l.hdiv then
    UI.wins.hdiv = util.float(UI.bufs.hdiv, l.hdiv.row, l.hdiv.col, l.hdiv.width, l.hdiv.height, { zindex = 51 })
  end
  if l.meta then
    UI.wins.meta = util.float(UI.bufs.meta, l.meta.row, l.meta.col, l.meta.width, l.meta.height, { zindex = 51 })
  end
  UI.wins.status = util.float(UI.bufs.status, l.status.row, l.status.col, l.status.width, l.status.height, { zindex = 51 })

  UI.wins.ac = util.float(UI.bufs.ac, l.ac.row, l.ac.col, l.ac.width, l.ac.height, { zindex = 60 })
  vim.api.nvim_win_set_config(UI.wins.ac, { hide = true })

  vim.wo[UI.wins.list].cursorline = true
  vim.wo[UI.wins.ac].cursorline = true

  draw_dividers(l)

  UI.aug = vim.api.nvim_create_augroup("GelbooruUI", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = UI.aug,
    callback = function()
      vim.schedule(M.on_resize)
    end,
  })

  -- Input Buffer Autocommands
  vim.api.nvim_create_autocmd("BufEnter", {
    group = UI.aug,
    buffer = UI.bufs.input,
    callback = function()
      if not State.input_focused then
        State.input_focused = true
        autocomplete.update_autocomplete()
        M.on_resize()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = UI.aug,
    buffer = UI.bufs.input,
    callback = function()
      State.autocomplete_cur = 0
      State.autocomplete_navigated = false
      -- If the existing timer is still alive, stop and reuse it (avoids alloc).
      -- If it was closed by teardown, create a fresh one.
      if UI.ac_debounce_timer then
        if UI.ac_debounce_timer:is_closing() then
          UI.ac_debounce_timer = vim.loop.new_timer()
        else
          UI.ac_debounce_timer:stop()
        end
      else
        UI.ac_debounce_timer = vim.loop.new_timer()
      end
      UI.ac_debounce_timer:start(
        50,
        0,
        vim.schedule_wrap(function()
          if State.input_focused and UI.bufs.input and vim.api.nvim_buf_is_valid(UI.bufs.input) then
            autocomplete.update_autocomplete()
          end
        end)
      )
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = UI.aug,
    pattern = tostring(UI.wins.frame),
    once = true,
    callback = M.teardown,
  })

  -- Keymaps for List
  local function lm(key, fn)
    util.keymap(UI.bufs.list, "n", key, fn)
  end
  for _, k in ipairs({ "<C-p>" }) do
    lm(k, "<Nop>")
  end
  lm("q", M.teardown)
  lm("<Esc>", M.teardown)
  lm("<CR>", api.save_current)
  lm("<Tab>", function()
    api.fetch(1)
  end)
  lm("<S-Tab>", function()
    api.fetch(-1)
  end)
  lm("R", function()
    M.render_preview(true)
  end)
  lm("r", function()
    State.cur_id = nil
    M.render_preview(false)
  end)
  lm("j", function()
    State.cur = math.min(State.cur + 1, #State.posts)
    State.scroll_dir = 1
    if State.history[State.history_idx] then
      State.history[State.history_idx].cur = State.cur
    end
    M.render_list()
    M.render_preview(false)
    if State.cur >= #State.posts - 5 then
      api.fetch(1)
    end
  end)
  lm("k", function()
    State.cur = math.max(State.cur - 1, 1)
    State.scroll_dir = -1
    if State.history[State.history_idx] then
      State.history[State.history_idx].cur = State.cur
    end
    M.render_list()
    M.render_preview(false)
  end)
  lm("o", function()
    local p = State.posts[State.cur]
    if p and p.file_url then
      vim.fn.system({ "open", p.file_url })
    end
  end)
  lm("O", function()
    local p = State.posts[State.cur]
    if p and p.id then
      vim.fn.system({ "open", string.format("https://gelbooru.com/index.php?page=post&s=view&id=%s", p.id) })
    end
  end)
  lm("m", function()
    State.show_meta = not State.show_meta
    M.on_resize()
  end)

  local function enter_search()
    State.input_focused = true
    pcall(vim.api.nvim_set_current_win, UI.wins.input)
    vim.cmd("startinsert!")
    autocomplete.update_autocomplete()
    M.on_resize()
  end
  for _, k in ipairs({ "i", "I", "a", "A", "s", "S", "/" }) do
    lm(k, enter_search)
  end

  lm("<C-d>", function()
    api.scroll_meta(5)
  end)
  lm("<C-u>", function()
    api.scroll_meta(-5)
  end)

  lm("[", history.history_prev)
  lm("]", history.history_next)

  util.keymap(UI.bufs.list, "n", "<ScrollWheelDown>", function()
    api.scroll_meta(3)
  end)
  util.keymap(UI.bufs.list, "n", "<ScrollWheelUp>", function()
    api.scroll_meta(-3)
  end)

  -- Keymaps for Input
  local function im_n(key, fn)
    util.keymap(UI.bufs.input, "n", key, fn)
  end
  local function im_i(key, fn)
    util.keymap(UI.bufs.input, "i", key, fn)
  end

  local function exit_input()
    State.input_focused = false
    vim.cmd("stopinsert")
    pcall(vim.api.nvim_set_current_win, UI.wins.list)
    M.on_resize()
  end

  local function submit_input()
    local full = vim.api.nvim_buf_get_lines(UI.bufs.input, 0, 1, false)[1] or ""
    full = full:match("^%s*(.-)%s*$")
    exit_input()
    api.execute_search(full)
  end

  im_n("<Esc>", exit_input)
  im_i("<Esc>", exit_input)
  im_n("<CR>", submit_input)
  im_i("<CR>", submit_input)

  local function nav_down()
    State.autocomplete_navigated = true
    State.autocomplete_cur = math.min(State.autocomplete_cur + 1, #State.autocomplete_filtered)
    autocomplete.update_autocomplete()
  end
  local function nav_up()
    State.autocomplete_navigated = true
    State.autocomplete_cur = math.max(State.autocomplete_cur - 1, 0)
    autocomplete.update_autocomplete()
  end
  im_i("<Down>", nav_down)
  im_i("<C-n>", nav_down)
  im_i("<Tab>", nav_down)
  im_i("<Up>", nav_up)
  im_i("<C-p>", nav_up)
  im_i("<S-Tab>", nav_up)

  im_i("<Space>", function()
    local full = vim.api.nvim_buf_get_lines(UI.bufs.input, 0, 1, false)[1] or ""
    local last_word = full:match("(%S*)$") or ""

    if last_word == "" or State.autocomplete_cur == 0 then
      vim.api.nvim_feedkeys(" ", "n", true)
      return
    end

    local t = State.autocomplete_filtered[State.autocomplete_cur]
    if not t then
      vim.api.nvim_feedkeys(" ", "n", true)
      return
    end

    local search_target = last_word:gsub("^[-~]", ""):lower()
    local target_norm = util.normalize_str(search_target)
    local t_norm = util.normalize_str(t.n)

    if not State.autocomplete_navigated and t.n:lower() ~= search_target and t_norm ~= target_norm then
      vim.api.nvim_feedkeys(" ", "n", true)
      return
    end

    local prefix = full:sub(1, #full - #last_word)
    local sign = last_word:match("^([-~])") or ""
    local new_text = prefix .. sign .. t.n .. " "
    vim.api.nvim_buf_set_lines(UI.bufs.input, 0, 1, false, { new_text })
    vim.api.nvim_win_set_cursor(UI.wins.input, { 1, #new_text })
    State.autocomplete_cur = 0
    State.autocomplete_navigated = false
  end)

  vim.api.nvim_set_current_win(UI.wins.list)
  M.set_status()

  if initial_tags and type(initial_tags) == "string" and initial_tags ~= "" then
    vim.api.nvim_buf_set_lines(UI.bufs.input, 0, 1, false, { initial_tags })
    api.execute_search(initial_tags)
  else
    vim.api.nvim_buf_set_lines(UI.bufs.input, 0, 1, false, { "" })
    enter_search()
  end
end

return M
