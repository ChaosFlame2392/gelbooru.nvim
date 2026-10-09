local config = require("gelbooru.core.config")
local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local download = require("gelbooru.net.download")
local image = require("gelbooru.ui.image")
local tags = require("gelbooru.tags")
local autocomplete = require("gelbooru.ui.autocomplete")
local history = require("gelbooru.core.history")
local api = require("gelbooru.net.api")

local M = {}

M.image = image
M.autocomplete = autocomplete

local RESIZE_DEBOUNCE_MS = 100

-- Layout cache: recomputed only on resize or show_meta / zen_mode / ratio toggle, not every render.
local _layout_cache = nil
local _layout_show_meta = nil
local _layout_zen_mode = nil
local _layout_ratio = nil

local function invalidate_layout()
  _layout_cache = nil
  _layout_show_meta = nil
  _layout_zen_mode = nil
  _layout_ratio = nil
end

function M.teardown()
  local UI = state.UI
  local State = state.State
  State.torn_down = true
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
  if UI.resize_timer then
    pcall(function()
      UI.resize_timer:stop()
      if not UI.resize_timer:is_closing() then
        UI.resize_timer:close()
      end
    end)
    UI.resize_timer = nil
  end
  if UI.resume_timer then
    pcall(function()
      UI.resume_timer:stop()
      if not UI.resume_timer:is_closing() then
        UI.resume_timer:close()
      end
    end)
    UI.resume_timer = nil
  end
  if UI.save_discovered_timer or #State.discovered > 0 then
    pcall(tags.save_discovered_now)
  end

  pcall(function()
    require("gelbooru.local.indexer").stop()
  end)

  download.cancel_prefetch_timers()
  -- Drop pending download callbacks so their closures are freed immediately.
  download.active_downloads = {}
  pcall(download.abort_all)
  download.pending_resumes = {}
  pcall(image.close_current_placement)

  local State = state.State
  if State.prev_mouse ~= nil then
    pcall(function()
      vim.o.mouse = State.prev_mouse
    end)
    State.prev_mouse = nil
  end

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
  for _, k in ipairs({ "hdiv", "meta", "ac" }) do
    local b = UI.bufs[k]
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  invalidate_layout()
  state.reset_query_state()
  state.reset_ui()
  state.reset_tag_state()
  State.torn_down = true
  -- Two GC passes: first collects the tag heap, second handles resurrected objects.
  collectgarbage("collect")
  collectgarbage("collect")
end

function M.set_status(msg, reset_ms)
  local UI = state.UI
  -- Bail if teardown has already cleared UI.bufs; in-flight callbacks reach here.
  if not UI.bufs.status then
    return
  end
  if UI.status_timer then
    UI.status_timer:stop()
    if not UI.status_timer:is_closing() then
      UI.status_timer:close()
    end
    UI.status_timer = nil
  end
  local help =
    "  j/k: nav  u: artist  < / >: width  \\: zen  o: web  O: open  <CR>: save  m: meta  /: search  q: quit"
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

function M.calc_layout(force)
  if force then
    invalidate_layout()
  end
  local State = state.State
  -- Return cached layout if terminal dimensions and show_meta / zen_mode / ratio haven't changed.
  if not force and _layout_cache
    and _layout_show_meta == State.show_meta
    and _layout_zen_mode == State.zen_mode
    and _layout_ratio == State.list_width_ratio
    and _layout_cache._TW == vim.o.columns
    and _layout_cache._TH == vim.o.lines then
    return _layout_cache
  end

  local TW, TH = vim.o.columns, vim.o.lines
  local W = math.floor(TW * 0.95)
  local H = math.floor(TH * 0.95)

  W = math.max(W, 80)
  H = math.max(H, 20)

  -- Clamp width and height so they never exceed vim.o.columns and vim.o.lines
  W = math.min(W, TW)
  H = math.min(H, TH)

  local R = math.max(0, math.floor((TH - H) / 2))
  local C = math.max(0, math.floor((TW - W) / 2))

  local input_h = 1
  local main_h = math.max(1, H - input_h - 4)
  local ratio = math.max(0.10, math.min(0.40, State.list_width_ratio or 0.25))

  local meta_h = State.show_meta and math.min(12, math.floor(main_h * 0.35)) or 0
  local img_h = math.max(1, main_h - meta_h - (State.show_meta and 1 or 0))

  local l = {
    _TW = TW, _TH = TH, -- cache keys
    frame = { row = R, col = C, width = W, height = H },
    input = { row = R + 1, col = C + 1, width = math.max(1, W - 2), height = 1 },
    div = { row = R + 2, col = C + 1, width = math.max(1, W - 2), height = 1 },
    status = { row = R + H - 2, col = C + 1, width = math.max(1, W - 2), height = 1 },
    ac = { row = R + 2, col = C + 1, width = math.max(1, W - 2), height = math.max(1, math.min(15, H - 4)) },
  }

  if State.zen_mode then
    local prev_w = math.max(1, W - 2)
    l.list = { row = R + 3, col = C + 1, width = 1, height = main_h, hide = true }
    l.vdiv = { row = R + 3, col = C + 1, width = 1, height = main_h, hide = true }
    l.img = { row = R + 3, col = C + 1, width = prev_w, height = img_h }
    l.hdiv = State.show_meta and { row = R + 3 + img_h, col = C + 1, width = prev_w, height = 1 } or nil
    l.meta = State.show_meta and { row = R + 3 + img_h + 1, col = C + 1, width = prev_w, height = meta_h } or nil
  else
    local list_w = math.max(1, math.floor(W * ratio))
    local prev_w = math.max(1, W - list_w - 3)
    l.list = { row = R + 3, col = C + 1, width = list_w, height = main_h }
    l.vdiv = { row = R + 3, col = C + 1 + list_w, width = 1, height = main_h }
    l.img = { row = R + 3, col = C + 1 + list_w + 1, width = prev_w, height = img_h }
    l.hdiv = State.show_meta and { row = R + 3 + img_h, col = C + 1 + list_w + 1, width = prev_w, height = 1 } or nil
    l.meta = State.show_meta and { row = R + 3 + img_h + 1, col = C + 1 + list_w + 1, width = prev_w, height = meta_h } or nil
  end

  _layout_cache = l
  _layout_show_meta = State.show_meta
  _layout_zen_mode = State.zen_mode
  _layout_ratio = State.list_width_ratio
  return _layout_cache
end

local function draw_dividers(layout)
  local UI = state.UI
  local State = state.State
  local W = layout.frame.width
  util.set_lines(UI.bufs.div, { string.rep("─", math.max(0, W - 2)) })

  if State.zen_mode then
    util.set_lines(UI.bufs.vdiv, {})
  else
    local vdiv_lines = {}
    for _ = 1, layout.list.height do
      vdiv_lines[#vdiv_lines + 1] = "│"
    end
    util.set_lines(UI.bufs.vdiv, vdiv_lines)
  end

  if layout.hdiv then
    util.set_lines(UI.bufs.hdiv, { string.rep("─", math.max(0, layout.hdiv.width)) })
  end
end

function M.apply_layout(l)
  local UI = state.UI
  local State = state.State
  if not UI.wins.frame or not vim.api.nvim_win_is_valid(UI.wins.frame) then
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

  if State.zen_mode then
    if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
      vim.api.nvim_win_set_config(UI.wins.list, { hide = true })
    end
    if UI.wins.vdiv and vim.api.nvim_win_is_valid(UI.wins.vdiv) then
      vim.api.nvim_win_set_config(UI.wins.vdiv, { hide = true })
    end
  else
    if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
      vim.api.nvim_win_set_config(UI.wins.list, {
        hide = false,
        relative = "editor",
        row = l.list.row,
        col = l.list.col,
        width = l.list.width,
        height = l.list.height,
      })
    end
    if UI.wins.vdiv and vim.api.nvim_win_is_valid(UI.wins.vdiv) then
      vim.api.nvim_win_set_config(UI.wins.vdiv, {
        hide = false,
        relative = "editor",
        row = l.vdiv.row,
        col = l.vdiv.col,
        width = l.vdiv.width,
        height = l.vdiv.height,
      })
    end
  end

  upd(UI.wins.img, l.img)
  upd(UI.wins.status, l.status)
  upd(UI.wins.ac, l.ac)

  if l.hdiv then
    if not UI.wins.hdiv or not vim.api.nvim_win_is_valid(UI.wins.hdiv) then
      UI.wins.hdiv = util.float(UI.bufs.hdiv, l.hdiv.row, l.hdiv.col, l.hdiv.width, l.hdiv.height, { zindex = 51, focusable = false })
    else
      upd(UI.wins.hdiv, l.hdiv)
    end
  elseif UI.wins.hdiv and vim.api.nvim_win_is_valid(UI.wins.hdiv) then
    vim.api.nvim_win_hide(UI.wins.hdiv)
  end

  if l.meta then
    if not UI.wins.meta or not vim.api.nvim_win_is_valid(UI.wins.meta) then
      UI.wins.meta = util.float(UI.bufs.meta, l.meta.row, l.meta.col, l.meta.width, l.meta.height, { zindex = 51 })
      vim.wo[UI.wins.meta].cursorline = true
    else
      upd(UI.wins.meta, l.meta)
    end
  elseif UI.wins.meta and vim.api.nvim_win_is_valid(UI.wins.meta) then
    vim.api.nvim_win_hide(UI.wins.meta)
  end

  draw_dividers(l)

  if State.input_focused then
    if UI.wins.ac and vim.api.nvim_win_is_valid(UI.wins.ac) then
      vim.api.nvim_win_set_config(UI.wins.ac, { hide = false })
    end
  else
    if UI.wins.ac and vim.api.nvim_win_is_valid(UI.wins.ac) then
      vim.api.nvim_win_set_config(UI.wins.ac, { hide = true })
    end
  end
end

local function handle_resize()
  local UI = state.UI
  if not (UI.wins.frame and vim.api.nvim_win_is_valid(UI.wins.frame)) then
    return
  end
  local l = M.calc_layout(true)
  M.apply_layout(l)
  image.nudge_current_placement()
end

function M.handle_resize()
  handle_resize()
end

function M.on_resize()
  handle_resize()
end

function M.render_list()
  local State = state.State
  local UI = state.UI
  local lines = {}
  local l = M.calc_layout()
  local LW = l.list.width
  local local_index = require("gelbooru.local.index")
  local_index.update_saved_index()

  for i, p in ipairs(State.posts) do
    local prefix = (i == State.cur) and "▶ " or "  "
    local r = (p.rating or "?"):sub(1, 1):upper()
    local score = tostring(p.score or 0)
    local is_vid = image.is_video_post(p)
    local is_saved = (not p.is_local) and p.id and (local_index.is_saved(p.id) or (State.saved_index and State.saved_index[tonumber(p.id)] ~= nil))
    local saved_badge = is_saved and " [SAVED]" or ""
    local dims = string.format("%dx%d%s%s", p.width or 0, p.height or 0, is_vid and " [VIDEO]" or "", saved_badge)
    local tags_s = config.options.show_tags_in_list and (" " .. (p.tags or ""):sub(1, math.max(0, LW - 22))) or ""
    lines[i] = string.format("%s%s ★%-5s %-15s%s", prefix, r, score, dims, tags_s)
  end
  if #lines == 0 then
    local no_res_msg = "  No results"
    if State.query and State.query:match("^local:") then
      no_res_msg = "  No images found"
    end
    lines = { State.loading and "  Fetching…" or no_res_msg }
  end
  util.set_lines(UI.bufs.list, lines)
  if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
    pcall(vim.api.nvim_win_set_cursor, UI.wins.list, { math.max(1, State.cur), 0 })
  end
end

local function is_same_post(p1, p2)
  if not p1 or not p2 then
    return false
  end
  if p1 == p2 then
    return true
  end
  if p1.is_local or p2.is_local then
    return p1.file_url ~= nil and p1.file_url == p2.file_url
  end
  return p1.id ~= nil and p2.id ~= nil and tostring(p1.id) == tostring(p2.id)
end

local function load_and_render_image(p, url_idx, retry_count, force_download)
  local UI = state.UI
  local State = state.State
  url_idx = url_idx or 1
  local urls, dest = image.get_preview_targets(p, url_idx)
  if #urls == 0 or not dest then
    return
  end
  url_idx = math.max(1, math.min(url_idx, #urls))
  retry_count = retry_count or 0
  local preview_url = urls[url_idx]

  local function fail_preview(msg)
    if not UI.wins.img or not vim.api.nvim_win_is_valid(UI.wins.img) then
      return
    end
    if not is_same_post(State.posts[State.cur], p) then
      return
    end
    pcall(vim.api.nvim_win_set_buf, UI.wins.img, UI.bufs.img)
    util.set_lines(UI.bufs.img, { "", "  [ " .. msg .. " ]" })
    M.set_status(msg, 2500)
    log("WARN", "PREVIEW", "Preview failed for post %s: %s", tostring(p.id or p.file_url), msg)
  end

  local function do_render()
    if not UI.wins.img or not vim.api.nvim_win_is_valid(UI.wins.img) then
      log("DEBUG", "RENDER", "do_render aborted: img win invalid (post %s)", tostring(p.id or p.file_url))
      return
    end
    if not is_same_post(State.posts[State.cur], p) then
      log("DEBUG", "RENDER", "do_render stale: cur=%d wanted=%s got=%s",
        State.cur, tostring(p.id or p.file_url),
        State.posts[State.cur] and tostring(State.posts[State.cur].id or State.posts[State.cur].file_url) or "nil")
      return
    end
    M.set_status()

    local pext = image.file_ext_from_url(preview_url)
    local source_name = image.preview_source_name(p, preview_url)
    if pext == "mp4" or pext == "webm" then
      if url_idx < #urls then
        load_and_render_image(p, url_idx + 1, 0, force_download)
        return
      end
      util.set_lines(UI.bufs.img, { "", "  [ Video Post - Preview not playable ]", "  Press 'O' to open in browser." })
      M.set_status(string.format("Video post • no static %s available", source_name), 2200)
      return
    end

    local size = vim.fn.getfsize(dest)
    if not p.is_local and size > -1 and size < 1024 then
      log("DEBUG", "RENDER", "file too small (%d bytes), re-fetching (post %s)", size, tostring(p.id or p.file_url))
      if retry_count < 1 then
        load_and_render_image(p, url_idx, retry_count + 1, true)
      elseif url_idx < #urls then
        load_and_render_image(p, url_idx + 1, 0, true)
      else
        fail_preview("Image Download Failed - File too small")
      end
      return
    end

    local ok = image.render_image(UI.wins.img, dest)
    if not ok then
      if not p.is_local and retry_count < 1 then
        load_and_render_image(p, url_idx, retry_count + 1, true)
      elseif not p.is_local and url_idx < #urls then
        load_and_render_image(p, url_idx + 1, 0, true)
      else
        fail_preview("Image Conversion Failed - File may be corrupted or unsupported")
      end
    end
  end

  if p.is_local then
    if force_download and p.id then
      image.clear_snacks_cache_for(p.id)
    end
    do_render()
    return
  end

  if not p.is_local and (vim.fn.filereadable(dest) == 0 or force_download) then
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

function M.render_metadata(p)
  local UI = state.UI
  local State = state.State
  if not p or not UI.bufs.meta or not vim.api.nvim_buf_is_valid(UI.bufs.meta) then
    return
  end

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

  if UI.wins.meta and vim.api.nvim_win_is_valid(UI.wins.meta) then
    pcall(vim.api.nvim_win_set_cursor, UI.wins.meta, { 1, 0 })
  end
end

function M.render_preview(force_download)
  local State = state.State
  local UI = state.UI
  local p = State.posts[State.cur]
  if not p then
    local no_img_msg = (State.query and State.query:match("^local:")) and "  No images found"
      or (#State.posts == 0 and "  No posts found" or "  No post selected")
    image.reset_canvas(no_img_msg)
    return
  end

  local item_key = p.is_local and p.file_url or p.id
  if item_key and item_key == State.cur_id and not force_download then
    return
  end
  State.cur_id = item_key

  M.render_metadata(p)

  -- Background dynamic artist resolution.
  pcall(tags.resolve_post_tags, p, function()
    if state.State.torn_down then
      return
    end
    if is_same_post(State.posts[State.cur], p) then
      M.render_metadata(p)
    end
  end)

  -- If post has an ID, asynchronously fetch its booru metadata via single-post API call
  -- to enrich p.tags, p.rating, p.score and refresh metadata buffer when focused!
  if p.is_local and p.id and (not p._metadata_fetched or force_download) then
    if force_download then
      local meta_path = util.meta_cache_path(p.id)
      if meta_path and vim.fn.filereadable(meta_path) == 1 then
        pcall(vim.fn.delete, meta_path)
      end
      p._metadata_fetched = nil
    end
    api.fetch_post_metadata(p, function(updated_p)
      if state.State.torn_down then
        return
      end
      local UI_cur = state.UI
      if not UI_cur.wins.frame or not vim.api.nvim_win_is_valid(UI_cur.wins.frame) then
        return
      end
      if is_same_post(state.State.posts[state.State.cur], updated_p) then
        M.render_metadata(updated_p)
        M.render_list()
        pcall(tags.resolve_post_tags, updated_p, function()
          if state.State.torn_down then
            return
          end
          if is_same_post(state.State.posts[state.State.cur], updated_p) then
            M.render_metadata(updated_p)
          end
        end)
      end
    end)
  end

  if p.is_local then
    local indexer = require("gelbooru.local.indexer")
    indexer.cursor_rush_prefetch(State.cur, State.scroll_dir)
  end

  local _, dest = image.get_preview_targets(p)
  local is_cached = not force_download and dest and vim.fn.filereadable(dest) == 1 and not download.active_downloads[dest]

  if not is_cached then
    if UI.wins.img and vim.api.nvim_win_is_valid(UI.wins.img) and UI.bufs.img and vim.api.nvim_buf_is_valid(UI.bufs.img) then
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
      if UI.scroll_timer and not UI.scroll_timer:is_closing() then
        UI.scroll_timer:close()
      end
      UI.scroll_timer = nil
      if state.State.torn_down then
        return
      end
      if is_same_post(State.posts[State.cur], p) then
        load_and_render_image(p, 1, 0, force_download)
        if not p.is_local then
          download.prefetch_around(State.cur)
        end
      else
        log("DEBUG", "RENDER", "scroll_timer stale: wanted post %s, cur is now %s",
          tostring(p.id or p.file_url),
          State.posts[State.cur] and tostring(State.posts[State.cur].id or State.posts[State.cur].file_url) or "nil")
      end
    end)
  )
end

local function isolate_input_buffer(buf, win)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].omnifunc = ""
  vim.bo[buf].completefunc = ""
  pcall(function()
    vim.bo[buf].completeopt = ""
  end)

  vim.b[buf].cmp_enabled = false
  pcall(function()
    require("cmp").setup.buffer({ enabled = false })
  end)

  vim.b[buf].completion = false
  vim.b[buf].blink_cmp_enabled = false

  vim.b[buf].copilot_disabled = true
  vim.b[buf].codecompanion_enabled = false
  vim.b[buf].supermaven = false
  vim.b[buf].codeium_enabled = false
  vim.b[buf].codeium_disable = true
end

function M.enter_search()
  local UI = state.UI
  local State = state.State
  State.input_focused = true
  if UI.wins.input and vim.api.nvim_win_is_valid(UI.wins.input) then
    pcall(vim.api.nvim_set_current_win, UI.wins.input)
  end
  vim.cmd("startinsert!")
  autocomplete.update_autocomplete()
  handle_resize()
end

function M.search_active_artist()
  local State = state.State
  local UI = state.UI
  local p = State.posts[State.cur]
  if not p then
    M.set_status("No artist tag found on active post", 2000)
    return
  end

  local artist_tag = nil
  if p.artist and p.artist ~= "" then
    artist_tag = util.decode_html(p.artist)
  elseif p.tags and p.tags ~= "" then
    for raw_tag in p.tags:gmatch("%S+") do
      local tag = util.decode_html(raw_tag)
      local t = State.tags_by_name and State.tags_by_name[tag:lower()]
      if t and tonumber(t.t) == 1 then
        artist_tag = tag
        break
      end
    end
  end

  if artist_tag and artist_tag ~= "" then
    if UI.bufs.input and vim.api.nvim_buf_is_valid(UI.bufs.input) then
      vim.bo[UI.bufs.input].modifiable = true
      vim.api.nvim_buf_set_lines(UI.bufs.input, 0, 1, false, { artist_tag })
    end
    if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
      pcall(vim.api.nvim_set_current_win, UI.wins.list)
    end
    api.execute_search(artist_tag)
  else
    M.set_status("No artist tag found on active post", 2000)
  end
end

function M.ensure_ui()
  local UI = state.UI
  if UI.wins.frame and vim.api.nvim_win_is_valid(UI.wins.frame) then
    return false
  end

  local State = state.State
  if State.prev_mouse == nil then
    State.prev_mouse = vim.o.mouse
  end
  vim.o.mouse = ""
  local api = require("gelbooru.net.api")

  util.ensure(config.options.cache_dir)
  util.ensure(config.options.save_dir)
  util.ensure(config.options.tags_dir)
  tags.load_tags()

  -- Silently resume any orphaned user-save .part files from previous sessions.
  UI.resume_timer = vim.defer_fn(function()
    UI.resume_timer = nil
    if not state.State.torn_down then
      download.resume_pending_saves()
    end
  end, 500)

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
    focusable = false,
  })
  vim.wo[UI.wins.frame].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"

  UI.wins.input = util.float(UI.bufs.input, l.input.row, l.input.col, l.input.width, l.input.height, { zindex = 51 })
  isolate_input_buffer(UI.bufs.input, UI.wins.input)
  UI.wins.div = util.float(UI.bufs.div, l.div.row, l.div.col, l.div.width, l.div.height, { zindex = 51, focusable = false })
  UI.wins.list = util.float(UI.bufs.list, l.list.row, l.list.col, l.list.width, l.list.height, { zindex = 51 })
  UI.wins.vdiv = util.float(UI.bufs.vdiv, l.vdiv.row, l.vdiv.col, l.vdiv.width, l.vdiv.height, { zindex = 51, focusable = false })
  if State.zen_mode then
    vim.api.nvim_win_set_config(UI.wins.list, { hide = true })
    vim.api.nvim_win_set_config(UI.wins.vdiv, { hide = true })
  end
  UI.wins.img = util.float(UI.bufs.img, l.img.row, l.img.col, l.img.width, l.img.height, { zindex = 51, focusable = false })
  if l.hdiv then
    UI.wins.hdiv = util.float(UI.bufs.hdiv, l.hdiv.row, l.hdiv.col, l.hdiv.width, l.hdiv.height, { zindex = 51, focusable = false })
  end
  if l.meta then
    UI.wins.meta = util.float(UI.bufs.meta, l.meta.row, l.meta.col, l.meta.width, l.meta.height, { zindex = 51 })
    vim.wo[UI.wins.meta].cursorline = true
  end
  UI.wins.status = util.float(UI.bufs.status, l.status.row, l.status.col, l.status.width, l.status.height, { zindex = 51, focusable = false })

  UI.wins.ac = util.float(UI.bufs.ac, l.ac.row, l.ac.col, l.ac.width, l.ac.height, { zindex = 60, focusable = false })
  vim.api.nvim_win_set_config(UI.wins.ac, { hide = true })

  vim.wo[UI.wins.list].cursorline = true
  vim.wo[UI.wins.ac].cursorline = true

  draw_dividers(l)

  UI.aug = vim.api.nvim_create_augroup("GelbooruUI", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = UI.aug,
    callback = function()
      if UI.resize_timer and not UI.resize_timer:is_closing() then
        UI.resize_timer:stop()
      else
        UI.resize_timer = (vim.uv or vim.loop).new_timer()
      end
      if UI.resize_timer then
        UI.resize_timer:start(
          RESIZE_DEBOUNCE_MS,
          0,
          function()
            vim.schedule(handle_resize)
          end
        )
      end
    end,
  })

  local function exit_input()
    State.input_focused = false
    vim.cmd("stopinsert")
    if UI.wins.ac and vim.api.nvim_win_is_valid(UI.wins.ac) then
      pcall(vim.api.nvim_win_set_config, UI.wins.ac, { hide = true })
    end
    if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
      pcall(vim.api.nvim_set_current_win, UI.wins.list)
    end
    handle_resize()
  end

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = UI.aug,
    buffer = UI.bufs.input,
    callback = function()
      if not State.torn_down and State.input_focused then
        exit_input()
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = UI.aug,
    buffer = UI.bufs.input,
    callback = function()
      if not State.input_focused then
        State.input_focused = true
        autocomplete.update_autocomplete()
        handle_resize()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = UI.aug,
    buffer = UI.bufs.input,
    callback = function()
      State.autocomplete_cur = 0
      State.autocomplete_navigated = false
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
    local p = State.posts[State.cur]
    if p and p.is_local and p.id then
      local meta_path = util.meta_cache_path(p.id)
      if meta_path and vim.fn.filereadable(meta_path) == 1 then
        pcall(vim.fn.delete, meta_path)
      end
      p._metadata_fetched = nil
    end
    M.render_preview(true)
  end)
  lm("r", function()
    State.cur_id = nil
    M.render_preview(false)
  end)
  lm("j", function()
    if #State.posts == 0 then
      return
    end
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
    if #State.posts == 0 then
      return
    end
    State.cur = math.max(State.cur - 1, 1)
    State.scroll_dir = -1
    if State.history[State.history_idx] then
      State.history[State.history_idx].cur = State.cur
    end
    M.render_list()
    M.render_preview(false)
  end)

  local function open_web_page()
    local p = State.posts[State.cur]
    if not p or not p.id or tostring(p.id) == "" or tostring(p.id) == "nil" then
      M.set_status("No post ID available for browser lookup", 2000)
      return
    end
    util.open_url(string.format("https://gelbooru.com/index.php?page=post&s=view&id=%s", tostring(p.id)))
  end

  local function open_media_viewer()
    local p = State.posts[State.cur]
    if not p then return end
    if p.is_local then
      if not p.file_url or p.file_url == "" then
        M.set_status("No local file available to open", 2000)
        return
      end
      util.open_media(p.file_url)
      return
    end
    if not p.id or tostring(p.id) == "" or tostring(p.id) == "nil" then
      M.set_status("No post ID available to open", 2000)
      return
    end
    if not p.file_url or p.file_url == "" then
      M.set_status("No file URL for this post", 2000)
      return
    end
    local ext = image.file_ext_from_url(p.file_url)
    local dest = string.format("%s/%s.%s", config.options.save_dir, tostring(p.id), ext)
    if vim.fn.filereadable(dest) == 1 then
      util.open_media(dest)
    else
      M.set_status("Downloading " .. tostring(p.id) .. " before opening…")
      api.save_current(function(saved, saved_path)
        if saved and saved_path and vim.fn.filereadable(saved_path) == 1 then
          util.open_media(saved_path)
        end
      end)
    end
  end

  local function toggle_zen()
    State.zen_mode = not State.zen_mode
    local l = M.calc_layout(true)
    M.apply_layout(l)
    if not State.zen_mode then
      if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
        pcall(vim.api.nvim_set_current_win, UI.wins.list)
      end
      M.render_list()
    end
    image.nudge_current_placement()
  end
  M.toggle_zen = toggle_zen

  lm("u", M.search_active_artist)
  lm("<", function()
    State.list_width_ratio = math.max(0.10, math.min(0.40, (State.list_width_ratio or 0.25) - 0.025))
    local l = M.calc_layout(true)
    M.apply_layout(l)
    M.render_list()
    image.nudge_current_placement()
  end)
  lm(">", function()
    State.list_width_ratio = math.max(0.10, math.min(0.40, (State.list_width_ratio or 0.25) + 0.025))
    local l = M.calc_layout(true)
    M.apply_layout(l)
    M.render_list()
    image.nudge_current_placement()
  end)
  lm("\\", toggle_zen)
  lm("o", open_web_page)
  lm("O", open_media_viewer)
  lm("m", function()
    State.show_meta = not State.show_meta
    handle_resize()
  end)
  lm("M", function()
    if not State.show_meta or not (UI.wins.meta and vim.api.nvim_win_is_valid(UI.wins.meta)) then
      State.show_meta = true
      handle_resize()
    end
    if UI.wins.meta and vim.api.nvim_win_is_valid(UI.wins.meta) then
      vim.wo[UI.wins.meta].cursorline = true
      pcall(vim.api.nvim_set_current_win, UI.wins.meta)
      M.set_status("Viewing Metadata — [q/Esc] back to posts, [/ or i] search")
    end
  end)


  for _, k in ipairs({ "i", "I", "a", "A", "s", "S", "/" }) do
    lm(k, M.enter_search)
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

  -- Keymaps for Meta
  local function mm(key, fn)
    util.keymap(UI.bufs.meta, "n", key, fn)
  end
  for _, k in ipairs({ "i", "I", "a", "A", "s", "S", "/" }) do
    mm(k, M.enter_search)
  end
  local function return_to_list()
    if State.input_focused then
      State.input_focused = false
      vim.cmd("stopinsert")
      if UI.wins.ac and vim.api.nvim_win_is_valid(UI.wins.ac) then
        pcall(vim.api.nvim_win_set_config, UI.wins.ac, { hide = true })
      end
    end
    if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
      pcall(vim.api.nvim_set_current_win, UI.wins.list)
      M.set_status()
    end
  end
  mm("q", return_to_list)
  mm("<Esc>", return_to_list)
  mm("M", return_to_list)
  mm("m", function()
    State.show_meta = false
    return_to_list()
    handle_resize()
  end)
  mm("u", M.search_active_artist)
  mm("\\", toggle_zen)
  mm("o", open_web_page)
  mm("O", open_media_viewer)
  mm("<CR>", api.save_current)

  -- Defensive keymaps on non-interactive buffers in case mouse/focus lands in them
  for _, buf in ipairs({ UI.bufs.frame, UI.bufs.div, UI.bufs.vdiv, UI.bufs.hdiv, UI.bufs.img, UI.bufs.status, UI.bufs.ac }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      for _, k in ipairs({ "i", "I", "a", "A", "s", "S", "/" }) do
        util.keymap(buf, "n", k, M.enter_search)
      end
      util.keymap(buf, "n", "q", return_to_list)
      util.keymap(buf, "n", "<Esc>", return_to_list)
      util.keymap(buf, "n", "\\", toggle_zen)
    end
  end

  -- Keymaps for Input
  local function im_n(key, fn)
    util.keymap(UI.bufs.input, "n", key, fn)
  end
  local function im_i(key, fn)
    util.keymap(UI.bufs.input, "i", key, fn)
  end

  local function submit_input()
    local full = vim.api.nvim_buf_get_lines(UI.bufs.input, 0, 1, false)[1] or ""
    full = full:match("^%s*(.-)%s*$")
    exit_input()
    api.execute_search(full)
  end

  im_n("<Esc>", exit_input)
  im_i("<Esc>", exit_input)
  im_n("q", exit_input)
  im_n("j", exit_input)
  im_n("k", exit_input)
  im_n("<CR>", submit_input)
  im_i("<CR>", submit_input)

  for _, k in ipairs({ "i", "I", "a", "A", "s", "S" }) do
    im_n(k, function()
      vim.cmd("startinsert!")
      State.input_focused = true
      autocomplete.update_autocomplete()
      handle_resize()
    end)
  end

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

    -- If the user navigated with Tab/Down/C-n, Space always selects the highlighted entry.
    if State.autocomplete_navigated and State.autocomplete_cur > 0 then
      local t = State.autocomplete_filtered[State.autocomplete_cur]
      if t then
        local prefix = full:sub(1, #full - #last_word)
        local sign = last_word:match("^([-~])") or ""
        local new_text = prefix .. sign .. t.n .. " "
        vim.api.nvim_buf_set_lines(UI.bufs.input, 0, 1, false, { new_text })
        vim.api.nvim_win_set_cursor(UI.wins.input, { 1, #new_text })
        State.autocomplete_cur = 0
        State.autocomplete_navigated = false
        return
      end
    end

    -- Without explicit navigation: auto-select only if the top suggestion is an
    -- exact or normalised match for what was typed.
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

    if t.n:lower() ~= search_target and t_norm ~= target_norm then
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

  return true
end

function M.scan_local_folder(dir)
  return require("gelbooru.local").scan_local_folder(dir)
end


function M.open(initial_tags)
  local UI = state.UI
  if UI.wins.frame and vim.api.nvim_win_is_valid(UI.wins.frame) then
    return
  end
  state.reset_query_state()

  M.ensure_ui()

  vim.api.nvim_set_current_win(UI.wins.list)
  M.set_status()

  if initial_tags and type(initial_tags) == "string" and initial_tags ~= "" then
    vim.api.nvim_buf_set_lines(UI.bufs.input, 0, 1, false, { initial_tags })
    api.execute_search(initial_tags)
  else
    vim.api.nvim_buf_set_lines(UI.bufs.input, 0, 1, false, { "" })
    M.enter_search()
  end
end

function M.open_local(dir)
  return require("gelbooru.local").open_local(dir)
end


return M
