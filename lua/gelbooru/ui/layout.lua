local config = require("gelbooru.core.config")
local constants = require("gelbooru.core.constants")
local canvas = require("gelbooru.ui.canvas")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")

local M = {}

-- Layout cache: recomputed only on resize or show_meta / zen_mode / ratio toggle, not every render.
local _layout_cache = nil
local _layout_show_meta = nil
local _layout_zen_mode = nil
local _layout_ratio = nil

function M.invalidate_layout()
  _layout_cache = nil
  _layout_show_meta = nil
  _layout_zen_mode = nil
  _layout_ratio = nil
end

local invalidate_layout = M.invalidate_layout

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
  local W = math.floor(TW * constants.LAYOUT_SCALE_FACTOR)
  local H = math.floor(TH * constants.LAYOUT_SCALE_FACTOR)

  W = math.max(W, constants.MIN_LAYOUT_WIDTH)
  H = math.max(H, constants.MIN_LAYOUT_HEIGHT)

  -- Clamp width and height so they never exceed vim.o.columns and vim.o.lines
  W = math.min(W, TW)
  H = math.min(H, TH)

  local R = math.max(0, math.floor((TH - H) / 2))
  local C = math.max(0, math.floor((TW - W) / 2))

  local input_h = 1
  local main_h = math.max(1, H - input_h - 4)
  local ratio = math.max(constants.MIN_LIST_RATIO, math.min(constants.MAX_LIST_RATIO, State.list_width_ratio or constants.DEFAULT_LIST_WIDTH_RATIO))

  local meta_h = State.show_meta and math.max(0, math.min(constants.MAX_META_HEIGHT, math.floor(main_h * constants.META_HEIGHT_RATIO))) or 0
  local has_meta = State.show_meta and meta_h > 0
  if not has_meta then
    meta_h = 0
  end
  local img_h = has_meta and math.max(1, main_h - meta_h - 1) or math.max(1, main_h)

  local l = {
    _TW = TW, _TH = TH, -- cache keys
    frame = { row = R, col = C, width = W, height = H },
    input = { row = R + 1, col = C + 1, width = math.max(1, W - 2), height = 1 },
    div = { row = R + 2, col = C + 1, width = math.max(1, W - 2), height = 1 },
    status = { row = R + H - 2, col = C + 1, width = math.max(1, W - 2), height = 1 },
    ac = { row = R + 2, col = C + 1, width = math.max(1, W - 2), height = math.max(1, math.min(constants.MAX_AC_HEIGHT, H - constants.AC_MARGIN_HEIGHT)) },
  }

  if State.zen_mode then
    local prev_w = math.max(1, W - 2)
    l.list = { row = R + 3, col = C + 1, width = 1, height = main_h, hide = true }
    l.vdiv = { row = R + 3, col = C + 1, width = 1, height = main_h, hide = true }
    l.img = { row = R + 3, col = C + 1, width = prev_w, height = img_h }
    l.hdiv = has_meta and { row = R + 3 + img_h, col = C + 1, width = prev_w, height = 1 } or nil
    l.meta = has_meta and { row = R + 3 + img_h + 1, col = C + 1, width = prev_w, height = meta_h } or nil
  else
    local list_w = math.max(1, math.floor(W * ratio))
    local prev_w = math.max(1, W - list_w - 3)
    l.list = { row = R + 3, col = C + 1, width = list_w, height = main_h }
    l.vdiv = { row = R + 3, col = C + 1 + list_w, width = 1, height = main_h }
    l.img = { row = R + 3, col = C + 1 + list_w + 1, width = prev_w, height = img_h }
    l.hdiv = has_meta and { row = R + 3 + img_h, col = C + 1 + list_w + 1, width = prev_w, height = 1 } or nil
    l.meta = has_meta and { row = R + 3 + img_h + 1, col = C + 1 + list_w + 1, width = prev_w, height = meta_h } or nil
  end

  _layout_cache = l
  _layout_show_meta = State.show_meta
  _layout_zen_mode = State.zen_mode
  _layout_ratio = State.list_width_ratio
  return _layout_cache
end

function M.draw_dividers(layout)
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

  local supports_hide = (vim.fn.has("nvim-0.10") == 1)

  if State.zen_mode then
    if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
      if supports_hide then
        vim.api.nvim_win_set_config(UI.wins.list, { hide = true })
      else
        vim.api.nvim_win_set_config(UI.wins.list, {
          relative = "editor",
          row = l.list.row,
          col = l.list.col,
          width = 1,
          height = l.list.height,
        })
      end
    end
    if UI.wins.vdiv and vim.api.nvim_win_is_valid(UI.wins.vdiv) then
      if supports_hide then
        vim.api.nvim_win_set_config(UI.wins.vdiv, { hide = true })
      else
        vim.api.nvim_win_set_config(UI.wins.vdiv, {
          relative = "editor",
          row = l.vdiv.row,
          col = l.vdiv.col,
          width = 1,
          height = l.vdiv.height,
        })
      end
    end
  else
    if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
      local cfg = {
        relative = "editor",
        row = l.list.row,
        col = l.list.col,
        width = l.list.width,
        height = l.list.height,
      }
      if supports_hide then cfg.hide = false end
      vim.api.nvim_win_set_config(UI.wins.list, cfg)
    end
    if UI.wins.vdiv and vim.api.nvim_win_is_valid(UI.wins.vdiv) then
      local cfg = {
        relative = "editor",
        row = l.vdiv.row,
        col = l.vdiv.col,
        width = l.vdiv.width,
        height = l.vdiv.height,
      }
      if supports_hide then cfg.hide = false end
      vim.api.nvim_win_set_config(UI.wins.vdiv, cfg)
    end
  end

  upd(UI.wins.img, l.img)
  upd(UI.wins.status, l.status)
  upd(UI.wins.ac, l.ac)

  if l.hdiv then
    if not UI.wins.hdiv or not vim.api.nvim_win_is_valid(UI.wins.hdiv) then
      UI.wins.hdiv = util.float(UI.bufs.hdiv, l.hdiv.row, l.hdiv.col, l.hdiv.width, l.hdiv.height, { zindex = constants.ZINDEX_DEFAULT_FLOAT, focusable = false })
    else
      upd(UI.wins.hdiv, l.hdiv)
    end
  elseif UI.wins.hdiv and vim.api.nvim_win_is_valid(UI.wins.hdiv) then
    vim.api.nvim_win_hide(UI.wins.hdiv)
  end

  if l.meta then
    if not UI.wins.meta or not vim.api.nvim_win_is_valid(UI.wins.meta) then
      UI.wins.meta = util.float(UI.bufs.meta, l.meta.row, l.meta.col, l.meta.width, l.meta.height, { zindex = constants.ZINDEX_DEFAULT_FLOAT })
      vim.wo[UI.wins.meta].cursorline = true
    else
      upd(UI.wins.meta, l.meta)
    end
  elseif UI.wins.meta and vim.api.nvim_win_is_valid(UI.wins.meta) then
    vim.api.nvim_win_hide(UI.wins.meta)
  end

  M.draw_dividers(l)

  if State.input_focused then
    if UI.wins.ac and vim.api.nvim_win_is_valid(UI.wins.ac) then
      if supports_hide then
        vim.api.nvim_win_set_config(UI.wins.ac, { hide = false })
      else
        upd(UI.wins.ac, l.ac)
      end
    end
  else
    if UI.wins.ac and vim.api.nvim_win_is_valid(UI.wins.ac) then
      if supports_hide then
        vim.api.nvim_win_set_config(UI.wins.ac, { hide = true })
      else
        vim.api.nvim_win_set_config(UI.wins.ac, {
          relative = "editor",
          row = 9999,
          col = 9999,
          width = 1,
          height = 1,
        })
      end
    end
  end
end

function M.handle_resize()
  local UI = state.UI
  if not (UI.wins.frame and vim.api.nvim_win_is_valid(UI.wins.frame)) then
    return
  end
  local l = M.calc_layout(true)
  M.apply_layout(l)
  canvas.nudge()
end

M.on_resize = M.handle_resize

return M
