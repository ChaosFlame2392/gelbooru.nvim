local api = require("gelbooru.net.api")
local config = require("gelbooru.core.config")
local constants = require("gelbooru.core.constants")
local download = require("gelbooru.net.download")
local canvas = require("gelbooru.ui.canvas")
local layout = require("gelbooru.ui.layout")
local log = require("gelbooru.core.log")
local resolver = require("gelbooru.media.resolver")
local state = require("gelbooru.core.state")
local catalog = require("gelbooru.tags.catalog")
local util = require("gelbooru.core.util")

local M = {}

local _orig_vim_ui_select = vim.ui and vim.ui.select
local is_same_post = util.is_same_post

function M.set_status(msg, reset_ms)
  local UI = state.UI
  -- Bail if teardown has already cleared UI.bufs; in-flight callbacks reach here.
  if not UI.bufs.status then
    return
  end
  UI.status_timer = util.close_timer(UI.status_timer)
  local help =
    "  j/k: nav  u: artist  d: del  < / >: width  \\: zen  o: web  O: open  <CR>: save  m: meta  /: search  q: quit"
  util.set_lines(UI.bufs.status, { msg and ("  " .. msg) or help })
  if msg and reset_ms and reset_ms > 0 then
    UI.status_timer = vim.loop.new_timer()
    UI.status_timer:start(
      reset_ms,
      0,
      vim.schedule_wrap(function()
        UI.status_timer = util.close_timer(UI.status_timer)
        M.set_status()
      end)
    )
  end
end

function M.render_list()
  local State = state.State
  local UI = state.UI
  local lines = {}
  local l = layout.calc_layout()
  local LW = l.list.width
  local local_index = require("gelbooru.local.index")
  local_index.update_saved_index()

  for i, p in ipairs(State.posts) do
    if i == State.cur and (not p.width or p.width <= 0) then
      resolver.resolve_post_dimensions(p)
    end
    local prefix = (i == State.cur) and "▶ " or "  "
    local r = (p.rating or "?"):sub(1, 1):upper()
    local score = tostring(p.score or 0)
    local is_vid = resolver.is_video_post(p)
    local is_pending = p._pending_delete or (p.id and State.pending_deletions and State.pending_deletions[tostring(p.id)] ~= nil)
    local is_saved = (not p.is_local) and (not is_pending) and p.id and (local_index.is_saved(p.id) or (State.saved_index and State.saved_index[tonumber(p.id)] ~= nil))
    local saved_badge = is_saved and " [SAVED]" or ""
    local dims = string.format("%dx%d%s%s", p.width or 0, p.height or 0, is_vid and " [VIDEO]" or "", saved_badge)
    local tags_s = config.options.show_tags_in_list and (" " .. (p.tags or ""):sub(1, math.max(0, LW - 22))) or ""
    lines[i] = string.format("%s%s ★%-5s %-15s%s", prefix, r, score, dims, tags_s)
  end
  if #lines == 0 then
    local no_res_msg = "  No results"
    if State.query and util.is_local_query(State.query) then
      no_res_msg = "  No images found"
    end
    lines = { State.loading and "  Fetching…" or no_res_msg }
  end
  UI._syncing_cursor = true
  util.set_lines(UI.bufs.list, lines)
  if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
    pcall(vim.api.nvim_win_set_cursor, UI.wins.list, { math.max(1, State.cur), 0 })
  end
  UI._syncing_cursor = false
end

function M.fail_preview(msg, p)
  local UI = state.UI
  local State = state.State
  if not UI.wins.img or not vim.api.nvim_win_is_valid(UI.wins.img) then
    return
  end
  if p and not is_same_post(State.posts[State.cur], p) then
    return
  end
  pcall(canvas.close)
  pcall(vim.api.nvim_win_set_buf, UI.wins.img, UI.bufs.img)
  util.set_lines(UI.bufs.img, { "", "  [ " .. msg .. " ]" })
  M.set_status(msg, constants.STATUS_TIMEOUT_INDEXER_MS)
  if p then
    log("WARN", "PREVIEW", "Preview failed for post %s: %s", tostring(p.id or p.file_url), msg)
  end
end

local fail_preview = M.fail_preview

function M.load_and_render_image(p, opts_or_idx, _, force)
  if not p then return fail_preview("No post selected", nil) end
  resolver.abort_active()
  local opts = type(opts_or_idx) == "table" and opts_or_idx or { force = (opts_or_idx == true or force == true) }
  M.set_status("Loading preview…")
  local epoch = state.State.search_epoch
  resolver.resolve(p, opts, function(target, err)
    if state.State.torn_down or state.State.search_epoch ~= epoch or not is_same_post(state.State.posts[state.State.cur], p) then
      return
    end
    if target and target.path and not (target.is_video and not target.is_thumbnail) then
      if not canvas.render(state.UI.wins.img, target.path) then
        fail_preview("Image Conversion Failed - File may be corrupted or unsupported", p)
      else
        if target.width and target.height and (not p.width or p.width <= 0) then
          p.width, p.height = target.width, target.height
          M.render_metadata(p)
          M.render_list()
        end
        M.set_status(target.is_video and "Video preview [VIDEO] • Press 'O' to play" or nil)
      end
    else
      local is_vid = resolver.is_video_post(p)
      local msg = is_vid and (target and "Preview not playable in terminal • Press 'O' to open" or "Preview not available • Press 'O' to open") or (err or "Preview resolution failed")
      canvas.render_placeholder(state.UI.wins.img, p, msg)
      M.set_status(is_vid and "Video post • Press 'O' to play" or msg, constants.STATUS_TIMEOUT_INDEXER_MS)
    end
  end)
end

function M.render_metadata(p)
  local UI = state.UI
  local State = state.State
  if not p or not UI.bufs.meta or not vim.api.nvim_buf_is_valid(UI.bufs.meta) then
    return
  end

  resolver.resolve_post_dimensions(p)

  local ext_info = resolver.file_ext_from_url(p.file_url)
  local is_vid = resolver.is_video_post(p)
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
    local t = catalog.get_tag(tag)
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
    local no_img_msg = (State.query and util.is_local_query(State.query)) and "  No images found"
      or (#State.posts == 0 and "  No posts found" or "  No post selected")
    canvas.render_placeholder(UI.wins.img, nil, no_img_msg)
    return
  end

  local had_dims = (p.width and p.height and p.width > 0 and p.height > 0)
  resolver.resolve_post_dimensions(p)
  if not had_dims and (p.width and p.width > 0) then
    M.render_list()
  end

  local item_key = p.is_local and p.file_url or p.id
  if item_key and item_key == State.cur_id and not force_download then
    return
  end
  State.cur_id = item_key

  M.render_metadata(p)

  -- Background dynamic artist resolution.
  pcall(catalog.resolve_post_tags, p, function()
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
        pcall(catalog.resolve_post_tags, updated_p, function()
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
    pcall(function()
      require("gelbooru.media.prewarmer").prewarm_posts(State.posts, State.cur, State.scroll_dir)
    end)
  else
    download.prefetch_around(State.cur, State.scroll_dir)
  end

  local _, dest = resolver.get_preview_targets(p)
  local is_saved = resolver.is_in_save_dir(dest)
  local is_cached = (not force_download or is_saved or p.is_local) and dest and vim.fn.filereadable(dest) == 1 and not download.active_downloads[dest]
  if not is_cached and not force_download and resolver.is_video_post(p) then
    local thumb_path = resolver.get_video_thumbnail_path(p.file_url, p.id)
    if vim.fn.filereadable(thumb_path) == 1 and (vim.fn.getfsize(thumb_path) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES then
      is_cached = true
    end
  end

  if not is_cached then
    if UI.wins.img and vim.api.nvim_win_is_valid(UI.wins.img) and UI.bufs.img and vim.api.nvim_buf_is_valid(UI.bufs.img) then
      pcall(vim.api.nvim_win_set_buf, UI.wins.img, UI.bufs.img)
      util.set_lines(UI.bufs.img, { "", "  Loading preview…" })
    end
    M.set_status("Loading preview…")
  else
    M.set_status()
  end

  UI.scroll_timer = util.close_timer(UI.scroll_timer)

  local delay = is_cached and constants.PREVIEW_COOLDOWN_CACHED_MS or UI.PREVIEW_COOLDOWN_MS

  UI.scroll_timer = vim.loop.new_timer()
  UI.scroll_timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      UI.scroll_timer = util.close_timer(UI.scroll_timer)
      if state.State.torn_down then
        return
      end
      if is_same_post(State.posts[State.cur], p) then
        M.load_and_render_image(p, force_download)
      else
        log("DEBUG", "RENDER", "scroll_timer stale: wanted post %s, cur is now %s",
          tostring(p.id or p.file_url),
          State.posts[State.cur] and tostring(State.posts[State.cur].id or State.posts[State.cur].file_url) or "nil")
      end
    end)
  )
end

function M.search_active_artist()
  local State = state.State
  local UI = state.UI
  local p = State.posts[State.cur]
  if not p then
    M.set_status("No artist tag found on active post", constants.STATUS_TIMEOUT_HISTORY_MS)
    return
  end

  local artist_tag = nil
  if p.artist and p.artist ~= "" then
    artist_tag = util.decode_html(p.artist)
  elseif p.tags and p.tags ~= "" then
    for raw_tag in p.tags:gmatch("%S+") do
      local tag = util.decode_html(raw_tag)
      local t = catalog.get_tag(tag)
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
    M.set_status("No artist tag found on active post", constants.STATUS_TIMEOUT_HISTORY_MS)
  end
end

function M.find_local_file_for_post(p)
  if not p then return nil end
  if p.is_local and p.file_url and not p.file_url:match("^https?://") and vim.fn.filereadable(p.file_url) == 1 then
    return p.file_url
  end
  if p.id then
    local ext = (state.State.saved_index and state.State.saved_index[tonumber(p.id)])
      or (p.file_url and not p.file_url:match("^https?://") and util.file_ext(p.file_url))
      or (p.file_url and util.file_ext(p.file_url))
      or "jpg"
    local cand = string.format("%s/%s.%s", config.options.save_dir, tostring(p.id), ext)
    if vim.fn.filereadable(cand) == 1 then
      return cand
    end
    for test_ext in pairs(config.VALID_MEDIA_EXTS) do
      local test_cand = string.format("%s/%s.%s", config.options.save_dir, tostring(p.id), test_ext)
      if vim.fn.filereadable(test_cand) == 1 then
        return test_cand
      end
    end
  end
  return nil
end

function M.close_confirm_modal()
  local UI = state.UI
  if UI.wins.confirm_modal and vim.api.nvim_win_is_valid(UI.wins.confirm_modal) then
    pcall(vim.api.nvim_win_close, UI.wins.confirm_modal, true)
    UI.wins.confirm_modal = nil
  end
  if UI.bufs.confirm_modal and vim.api.nvim_buf_is_valid(UI.bufs.confirm_modal) then
    pcall(vim.api.nvim_buf_delete, UI.bufs.confirm_modal, { force = true })
    UI.bufs.confirm_modal = nil
  end
  if UI.confirm_prev_win and vim.api.nvim_win_is_valid(UI.confirm_prev_win) then
    pcall(vim.api.nvim_set_current_win, UI.confirm_prev_win)
  elseif UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
    pcall(vim.api.nvim_set_current_win, UI.wins.list)
  end
  UI.confirm_prev_win = nil
  vim.schedule(function()
    if not state.State.torn_down then
      state.State.cur_id = nil
      M.render_preview(false)
    end
  end)
end

function M.open_confirm_modal(filename, on_confirm)
  local UI = state.UI
  local cur_win = vim.api.nvim_get_current_win()
  if cur_win ~= UI.wins.confirm_modal then
    UI.confirm_prev_win = cur_win
  end

  if UI.wins.confirm_modal and vim.api.nvim_win_is_valid(UI.wins.confirm_modal) then
    pcall(vim.api.nvim_win_close, UI.wins.confirm_modal, true)
    UI.wins.confirm_modal = nil
  end
  if UI.bufs.confirm_modal and vim.api.nvim_buf_is_valid(UI.bufs.confirm_modal) then
    pcall(vim.api.nvim_buf_delete, UI.bufs.confirm_modal, { force = true })
    UI.bufs.confirm_modal = nil
  end

  local disp_fn = vim.fn.fnamemodify(filename, ":t")
  local max_avail_w = math.max(10, vim.o.columns - 4)
  local modal_w = math.min(max_avail_w, math.max(20, math.min(max_avail_w, math.max(46, #disp_fn + 22))))
  local modal_h = 5
  local modal_row = math.max(1, math.floor((vim.o.lines - modal_h) / 2))
  local modal_col = math.max(1, math.floor((vim.o.columns - modal_w) / 2))

  UI.bufs.confirm_modal = vim.api.nvim_create_buf(false, true)
  vim.bo[UI.bufs.confirm_modal].buftype = "nofile"
  vim.bo[UI.bufs.confirm_modal].bufhidden = "wipe"
  vim.bo[UI.bufs.confirm_modal].modifiable = true
  vim.bo[UI.bufs.confirm_modal].filetype = "gelbooru_confirm_modal"
  pcall(function()
    vim.b[UI.bufs.confirm_modal].which_key_ignore = true
    vim.b[UI.bufs.confirm_modal].whichkey_disable = true
    vim.b[UI.bufs.confirm_modal].miniclue_disable = true
  end)

  local block_keys = {
    "z", "Z", "v", "V", "<C-v>", "c", "C", "d", "D", "p", "P",
    "r", "R", "s", "S", "i", "I", "o", "O", "u", "U", "w", "W",
    "b", "B", "e", "E", "m", "M", "t", "T", "h", "l", "f", "F",
    ";", ":", "'", '"', "<BS>", "<Del>", "/", "?", "<Space>", " "
  }
  for _, bk in ipairs(block_keys) do
    util.keymap(UI.bufs.confirm_modal, "n", bk, function() end)
  end

  local choice = 1 -- 1 = Yes, 2 = Cancel

  local function render_confirm_lines()
    if not UI.bufs.confirm_modal or not vim.api.nvim_buf_is_valid(UI.bufs.confirm_modal) then
      return
    end
    local lines = {
      "  Delete local file?",
      "  " .. disp_fn:sub(1, modal_w - 6),
      "  ",
      (choice == 1 and "▶ Yes, delete (deferred until exit)" or "  Yes, delete (deferred until exit)"),
      (choice == 2 and "▶ Cancel" or "  Cancel"),
    }
    vim.bo[UI.bufs.confirm_modal].modifiable = true
    vim.api.nvim_buf_set_lines(UI.bufs.confirm_modal, 0, -1, false, lines)
    vim.bo[UI.bufs.confirm_modal].modifiable = false
  end

  render_confirm_lines()

  UI.wins.confirm_modal = util.float(UI.bufs.confirm_modal, modal_row, modal_col, modal_w, modal_h, {
    border = "rounded",
    title = " Confirm Delete ",
    title_pos = "center",
    zindex = constants.ZINDEX_CONFIRM_MODAL,
    focusable = true,
  })
  vim.wo[UI.wins.confirm_modal].cursorline = false
  vim.wo[UI.wins.confirm_modal].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  pcall(vim.api.nvim_set_current_win, UI.wins.confirm_modal)
  pcall(vim.api.nvim_win_set_cursor, UI.wins.confirm_modal, { 4, 0 })

  local function cmap(key, fn)
    util.keymap(UI.bufs.confirm_modal, "n", key, fn)
  end

  local function sel_yes()
    choice = 1
    render_confirm_lines()
    if UI.wins.confirm_modal and vim.api.nvim_win_is_valid(UI.wins.confirm_modal) then
      pcall(vim.api.nvim_win_set_cursor, UI.wins.confirm_modal, { 4, 0 })
    end
  end

  local function sel_cancel()
    choice = 2
    render_confirm_lines()
    if UI.wins.confirm_modal and vim.api.nvim_win_is_valid(UI.wins.confirm_modal) then
      pcall(vim.api.nvim_win_set_cursor, UI.wins.confirm_modal, { 5, 0 })
    end
  end

  cmap("j", sel_cancel)
  cmap("<Down>", sel_cancel)
  cmap("k", sel_yes)
  cmap("<Up>", sel_yes)
  cmap("<Tab>", function()
    if choice == 1 then sel_cancel() else sel_yes() end
  end)
  cmap("<S-Tab>", function()
    if choice == 1 then sel_cancel() else sel_yes() end
  end)

  local function commit_choice()
    local chosen = choice
    M.close_confirm_modal()
    if chosen == 1 then
      on_confirm()
    else
      M.set_status("Cancelled", constants.STATUS_TIMEOUT_NOTICE_MS)
    end
  end

  cmap("<CR>", commit_choice)
  cmap("q", function()
    M.close_confirm_modal()
    M.set_status("Cancelled", constants.STATUS_TIMEOUT_NOTICE_MS)
  end)
  cmap("<Esc>", function()
    M.close_confirm_modal()
    M.set_status("Cancelled", constants.STATUS_TIMEOUT_NOTICE_MS)
  end)
  cmap("c", function()
    M.close_confirm_modal()
    M.set_status("Cancelled", constants.STATUS_TIMEOUT_NOTICE_MS)
  end)
  cmap("y", function()
    M.close_confirm_modal()
    on_confirm()
  end)
  cmap("Y", function()
    M.close_confirm_modal()
    on_confirm()
  end)
  cmap("n", function()
    M.close_confirm_modal()
    M.set_status("Cancelled", constants.STATUS_TIMEOUT_NOTICE_MS)
  end)
  cmap("N", function()
    M.close_confirm_modal()
    M.set_status("Cancelled", constants.STATUS_TIMEOUT_NOTICE_MS)
  end)
end

function M.delete_current()
  local State = state.State
  local UI = state.UI
  local p = State.posts[State.cur]
  if not p then return end

  local local_path = M.find_local_file_for_post(p)
  if not local_path or vim.fn.filereadable(local_path) == 0 then
    M.set_status("Post is not saved locally", constants.STATUS_TIMEOUT_INDEXER_MS)
    return
  end

  local del_key = tostring(p.id or local_path)
  if p._pending_delete or (State.pending_deletions and State.pending_deletions[del_key]) then
    M.set_status("Deletion already scheduled (deferred until exit; press <CR> to restore)", constants.STATUS_TIMEOUT_INDEXER_MS)
    return
  end

  local filename = vim.fn.fnamemodify(local_path, ":t")
  local prompt_msg = "Delete local file: " .. filename .. "?"

  local function do_delete()
    State.pending_deletions = State.pending_deletions or {}
    State.pending_deletions[del_key] = {
      path = local_path,
      id = p.id,
      p = p,
    }
    p._pending_delete = true
    p._local_file_path = local_path
    p._was_local = (p.is_local == true)

    local id_num = p.id and tonumber(p.id)
    if id_num then
      local local_index = require("gelbooru.local.index")
      local_index.unmark_saved(id_num)
      if State.saved_index then
        State.saved_index[id_num] = nil
      end
    end

    State.cur_id = nil -- Reset cur_id so render_preview won't early return and blank image!
    M.render_list()
    M.render_preview(false)
    M.render_metadata(p)
    M.set_status(string.format("Deleted local file: %s (deferred until exit; press <CR> to restore)", filename), constants.STATUS_TIMEOUT_LOCAL_MS)
  end

  if vim.ui and vim.ui.select and vim.ui.select ~= _orig_vim_ui_select then
    vim.ui.select({ "Yes, delete file", "Cancel" }, {
      prompt = prompt_msg,
    }, function(choice)
      if choice == "Yes, delete file" then
        do_delete()
      end
    end)
  elseif vim.fn.confirm and (not UI.wins.frame or not vim.api.nvim_win_is_valid(UI.wins.frame)) then
    if vim.fn.confirm(prompt_msg, "&Yes\n&No", 2) == 1 then
      do_delete()
    end
  else
    M.open_confirm_modal(filename, do_delete)
  end
end

return M
