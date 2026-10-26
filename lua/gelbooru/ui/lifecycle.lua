local api = require("gelbooru.net.api")
local autocomplete = require("gelbooru.ui.autocomplete")
local config = require("gelbooru.core.config")
local constants = require("gelbooru.core.constants")
local download = require("gelbooru.net.download")
local canvas = require("gelbooru.ui.canvas")
local resolver = require("gelbooru.media.resolver")
local keymaps = require("gelbooru.ui.keymaps")
local layout = require("gelbooru.ui.layout")
local log = require("gelbooru.core.log")
local render = require("gelbooru.ui.render")
local state = require("gelbooru.core.state")
local catalog = require("gelbooru.tags.catalog")
local util = require("gelbooru.core.util")

local M = {}

function M.teardown()
  local UI = state.UI
  local State = state.State
  State.torn_down = true
  log("INFO", "LIFECYCLE", "Teardown Gelbooru UI")
  UI.scroll_timer = util.close_timer(UI.scroll_timer)
  UI.status_timer = util.close_timer(UI.status_timer)
  UI.ac_debounce_timer = util.close_timer(UI.ac_debounce_timer)
  UI.resize_timer = util.close_timer(UI.resize_timer)
  UI.resume_timer = util.close_timer(UI.resume_timer)
  pcall(catalog.teardown)

  for _, t in pairs(UI.fetcher_timers or {}) do
    util.close_timer(t)
  end
  UI.fetcher_timers = {}
  if UI.tags_spinner_win and vim.api.nvim_win_is_valid(UI.tags_spinner_win) then
    pcall(vim.api.nvim_win_close, UI.tags_spinner_win, true)
    UI.tags_spinner_win = nil
  end

  pcall(function()
    require("gelbooru.local.indexer").stop()
  end)

  download.cancel_prefetch_timers(true)
  -- Drop pending download callbacks so their closures are freed immediately.
  download.active_downloads = {}
  pcall(download.abort_all)
  download.pending_resumes = {}
  pcall(resolver.abort_video_transcodes)
  pcall(canvas.close)

  -- Execute deferred deletions on disk now that Gelbooru UI is tearing down.
  if State.pending_deletions then
    local uv = vim.uv or vim.loop
    for _, item in pairs(State.pending_deletions) do
      if item and item.path then
        if uv and uv.fs_unlink then
          pcall(uv.fs_unlink, item.path)
        end
        if vim.fn.filereadable(item.path) == 1 then
          pcall(os.remove, item.path)
          pcall(vim.fn.delete, item.path)
        end
        if item.id then
          local meta_path = util.meta_cache_path(item.id)
          if meta_path and vim.fn.filereadable(meta_path) == 1 then
            pcall(vim.fn.delete, meta_path)
          end
          local vthumb = resolver.get_video_thumbnail_path(item.path, item.id)
          if vthumb and vim.fn.filereadable(vthumb) == 1 then
            pcall(vim.fn.delete, vthumb)
          end
          local direct_vthumb = string.format("%s/vthumb_%s.jpg", config.options.cache_dir, tostring(item.id))
          if vim.fn.filereadable(direct_vthumb) == 1 then
            pcall(vim.fn.delete, direct_vthumb)
          end
          resolver.clear_cache(item.id or item.file_url)
        end
      end
    end
    State.pending_deletions = {}
  end

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
  for _, k in ipairs({ "img", "hdiv", "meta", "ac", "confirm_modal" }) do
    local b = UI.bufs[k]
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  layout.invalidate_layout()
  state.reset_query_state()
  state.reset_ui()
  state.reset_tag_state()
  State.torn_down = true
  -- Two GC passes: first collects the tag heap, second handles resurrected objects.
  collectgarbage("collect")
  collectgarbage("collect")
end

function M.isolate_input_buffer(buf, win)
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
  layout.handle_resize()
end

function M.exit_input()
  local UI = state.UI
  local State = state.State
  State.input_focused = false
  vim.cmd("stopinsert")
  if UI.wins.ac and vim.api.nvim_win_is_valid(UI.wins.ac) then
    pcall(vim.api.nvim_win_set_config, UI.wins.ac, { hide = true })
  end
  if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
    pcall(vim.api.nvim_set_current_win, UI.wins.list)
  end
  layout.handle_resize()
  if #State.posts == 0 then
    render.set_status("Empty search query. Press [/ or i] to type tags, [q] to exit")
  end
end

function M.setup_autocmds()
  local UI = state.UI
  local State = state.State

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
          constants.RESIZE_DEBOUNCE_MS,
          0,
          function()
            vim.schedule(layout.handle_resize)
          end
        )
      end
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = UI.aug,
    buffer = UI.bufs.input,
    callback = function()
      if not State.torn_down and State.input_focused then
        M.exit_input()
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
        layout.handle_resize()
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
        constants.AC_INPUT_DEBOUNCE_MS,
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

  vim.api.nvim_create_autocmd("WinEnter", {
    group = UI.aug,
    callback = function()
      if State.torn_down or not (UI.wins.frame and vim.api.nvim_win_is_valid(UI.wins.frame)) then
        return
      end
      local cur_win = vim.api.nvim_get_current_win()
      if UI.wins.confirm_modal and vim.api.nvim_win_is_valid(UI.wins.confirm_modal) then
        if cur_win ~= UI.wins.confirm_modal then
          pcall(vim.api.nvim_set_current_win, UI.wins.confirm_modal)
        end
        return
      end

      if cur_win == UI.wins.list or cur_win == UI.wins.input then
        return
      end
      if UI.wins.meta and vim.api.nvim_win_is_valid(UI.wins.meta) and cur_win == UI.wins.meta then
        return
      end

      if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
        pcall(vim.api.nvim_set_current_win, UI.wins.list)
      end

      vim.schedule(function()
        if State.torn_down or not (UI.wins.frame and vim.api.nvim_win_is_valid(UI.wins.frame)) then
          return
        end
        local cur = vim.api.nvim_get_current_win()
        if UI.wins.confirm_modal and vim.api.nvim_win_is_valid(UI.wins.confirm_modal) then
          if cur ~= UI.wins.confirm_modal then
            pcall(vim.api.nvim_set_current_win, UI.wins.confirm_modal)
          end
          return
        end
        if cur == UI.wins.list or cur == UI.wins.input then
          return
        end
        if UI.wins.meta and vim.api.nvim_win_is_valid(UI.wins.meta) and cur == UI.wins.meta then
          return
        end
        if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
          pcall(vim.api.nvim_set_current_win, UI.wins.list)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = UI.aug,
    buffer = UI.bufs.list,
    callback = function()
      if UI._syncing_cursor or State.torn_down then
        return
      end
      if not UI.wins.list or not vim.api.nvim_win_is_valid(UI.wins.list) then
        return
      end
      if vim.api.nvim_get_current_win() ~= UI.wins.list then
        return
      end
      local ok, cursor = pcall(vim.api.nvim_win_get_cursor, UI.wins.list)
      if not ok or not cursor then
        return
      end
      local m = vim.fn.getmousepos()
      if m and m.winid and m.winid ~= 0 and m.winid ~= UI.wins.list then
        UI._syncing_cursor = true
        pcall(vim.api.nvim_win_set_cursor, UI.wins.list, { math.max(1, State.cur), 0 })
        UI._syncing_cursor = false
        return
      end
      local line = cursor[1]
      if #State.posts > 0 and line ~= State.cur and line <= #State.posts and line >= 1 then
        State.scroll_dir = (line > State.cur) and 1 or -1
        State.cur = line
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
    end,
  })
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
  vim.o.mouse = "a"

  util.ensure(config.options.cache_dir)
  util.ensure(config.options.save_dir)
  util.ensure(config.options.tags_dir)
  catalog.load()

  -- Silently resume any orphaned user-save .part files from previous sessions.
  UI.resume_timer = vim.defer_fn(function()
    UI.resume_timer = nil
    if not state.State.torn_down then
      download.resume_pending_saves()
    end
  end, constants.RESUME_STARTUP_DELAY_MS)

  UI.bufs.frame = util.scratch()
  UI.bufs.input = vim.api.nvim_create_buf(false, true)
  vim.bo[UI.bufs.input].bufhidden = "wipe"
  vim.bo[UI.bufs.input].modifiable = true
  UI.bufs.div = util.scratch()
  UI.bufs.list = util.scratch()
  UI.bufs.vdiv = util.scratch()
  UI.bufs.img = util.scratch()
  vim.bo[UI.bufs.img].bufhidden = "hide"
  UI.bufs.hdiv = util.scratch()
  vim.bo[UI.bufs.hdiv].bufhidden = "hide"
  UI.bufs.meta = util.scratch()
  vim.bo[UI.bufs.meta].bufhidden = "hide"
  UI.bufs.status = util.scratch()
  UI.bufs.ac = util.scratch()
  vim.bo[UI.bufs.ac].bufhidden = "hide"

  for _, b in pairs(UI.bufs) do
    if b and vim.api.nvim_buf_is_valid(b) then
      util.shield_buffer(b)
    end
  end

  local l = layout.calc_layout()

  UI.wins.frame = util.float(UI.bufs.frame, l.frame.row, l.frame.col, l.frame.width, l.frame.height, {
    border = "rounded",
    title = "  Gelbooru  ",
    title_pos = "center",
    zindex = 50,
    focusable = false,
  })
  vim.wo[UI.wins.frame].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"

  UI.wins.input = util.float(UI.bufs.input, l.input.row, l.input.col, l.input.width, l.input.height, { zindex = constants.ZINDEX_DEFAULT_FLOAT })
  M.isolate_input_buffer(UI.bufs.input, UI.wins.input)
  UI.wins.div = util.float(UI.bufs.div, l.div.row, l.div.col, l.div.width, l.div.height, { zindex = constants.ZINDEX_DEFAULT_FLOAT, focusable = false })
  UI.wins.list = util.float(UI.bufs.list, l.list.row, l.list.col, l.list.width, l.list.height, { zindex = constants.ZINDEX_DEFAULT_FLOAT })
  UI.wins.vdiv = util.float(UI.bufs.vdiv, l.vdiv.row, l.vdiv.col, l.vdiv.width, l.vdiv.height, { zindex = constants.ZINDEX_DEFAULT_FLOAT, focusable = false })
  if State.zen_mode then
    vim.api.nvim_win_set_config(UI.wins.list, { hide = true })
    vim.api.nvim_win_set_config(UI.wins.vdiv, { hide = true })
  end
  UI.wins.img = util.float(UI.bufs.img, l.img.row, l.img.col, l.img.width, l.img.height, { zindex = constants.ZINDEX_DEFAULT_FLOAT, focusable = false })
  if l.hdiv then
    UI.wins.hdiv = util.float(UI.bufs.hdiv, l.hdiv.row, l.hdiv.col, l.hdiv.width, l.hdiv.height, { zindex = constants.ZINDEX_DEFAULT_FLOAT, focusable = false })
  end
  if l.meta then
    UI.wins.meta = util.float(UI.bufs.meta, l.meta.row, l.meta.col, l.meta.width, l.meta.height, { zindex = constants.ZINDEX_DEFAULT_FLOAT })
    vim.wo[UI.wins.meta].cursorline = true
  end
  UI.wins.status = util.float(UI.bufs.status, l.status.row, l.status.col, l.status.width, l.status.height, { zindex = constants.ZINDEX_DEFAULT_FLOAT, focusable = false })

  UI.wins.ac = util.float(UI.bufs.ac, l.ac.row, l.ac.col, l.ac.width, l.ac.height, { zindex = constants.ZINDEX_AUTOCOMPLETE, focusable = false })
  vim.api.nvim_win_set_config(UI.wins.ac, { hide = true })

  vim.wo[UI.wins.list].cursorline = true
  vim.wo[UI.wins.ac].cursorline = true

  layout.draw_dividers(l)
  M.setup_autocmds()

  keymaps.setup_list_keymaps()
  keymaps.setup_meta_keymaps()
  keymaps.setup_noninteractive_keymaps()
  keymaps.setup_input_keymaps()

  return true
end

function M.open(initial_tags)
  local UI = state.UI
  if UI.wins.frame and vim.api.nvim_win_is_valid(UI.wins.frame) then
    return
  end
  state.reset_query_state()

  M.ensure_ui()

  vim.api.nvim_set_current_win(UI.wins.list)
  render.set_status()

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

function M.scan_local_folder(dir)
  return require("gelbooru.local").scan_local_folder(dir)
end

return M
