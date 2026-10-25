local config = require("gelbooru.core.config")
local constants = require("gelbooru.core.constants")
local log = require("gelbooru.core.log")
local resolver = require("gelbooru.media.resolver")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")

local M = {}

--- Clamps DPI >= 300 or < 50 to 96 to prevent layout and graphics protocol distortion.
--- @param img table|nil
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

--- Attaches defensive buffer keymaps and shields the buffer against leader menu leaks.
--- @param buf number
function M.attach_defensive_keymaps(buf)
  local keymaps = require("gelbooru.ui.keymaps")
  keymaps.attach_image_keymaps(buf)
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

--- Synchronously aborts in-flight conversion on placement and unlinks partial files.
--- Clears Snacks in-memory image cache immediately. Zero delay timers used.
--- @param placement table|nil
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

  local had_aborted_in_flight = false
  if type(convert.steps) == "table" then
    for _, step in ipairs(convert.steps) do
      if step and step.file then
        local is_aborted_step = (step == aborted_step)
        local is_done = step.done == true
        local sz = (vim.fn.filereadable(step.file) == 1) and (vim.fn.getfsize(step.file) or 0) or -1

        if is_aborted_step and not is_done then
          had_aborted_in_flight = true
        end

        if sz == 0 or (is_aborted_step and not is_done) then
          delete_step_file(step.file)
        elseif sz > 0 then
          local info_file = step.file .. ".info"
          local info_corrupt = false
          if vim.fn.filereadable(info_file) == 1 then
            local lines = vim.fn.readfile(info_file)
            local content = vim.trim(table.concat(lines or {}, " "))
            if resolver.is_info_corrupt then
              info_corrupt = resolver.is_info_corrupt(content)
            else
              local c = content:lower()
              info_corrupt = c:find("identify:") ~= nil or c:find("improper") ~= nil or c:find("error") ~= nil or c:find("failed") ~= nil or c:find("corrupt") ~= nil
            end
          end
          if info_corrupt or (is_aborted_step and not is_done and not resolver.is_image_complete(step.file)) then
            delete_step_file(step.file)
          end
        end
      end
    end
  end

  if convert.file then
    local sz = (vim.fn.filereadable(convert.file) == 1) and (vim.fn.getfsize(convert.file) or 0) or -1
    if sz == 0 or (had_aborted_in_flight and sz > 0 and not resolver.is_image_complete(convert.file)) then
      delete_step_file(convert.file)
      had_aborted_in_flight = true
    end
  end

  if had_aborted_in_flight then
    resolver.clear_snacks_image_cache()
  end
end

--- Closes active graphics placement cleanly and restores window buffer.
function M.close()
  local UI = state.UI
  pcall(resolver.abort_video_transcodes)
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
end

--- Re-calculates and re-anchors active placement after window resize or Zen toggle.
--- @return boolean
function M.nudge()
  local UI = state.UI
  local p = UI.current_placement
  if p and not p.closed and vim.api.nvim_buf_is_valid(p.buf) then
    M.sanitize_dpi(p.img)
    p._state = nil
    pcall(p.update, p)
    log("DEBUG", "CANVAS", "Nudged placement for resize")
    return true
  end
  return false
end

--- Renders textual placeholder or rich video banner into the canvas window.
--- @param win number: Target window handle
--- @param post table|nil: Optional post metadata for video details
--- @param message string: Status or notice message
function M.render_placeholder(win, post, message)
  pcall(M.close)
  if state.State.torn_down then
    return
  end
  local UI = state.UI
  local target_win = (win and vim.api.nvim_win_is_valid(win)) and win or (UI.wins and UI.wins.img)
  local has_valid_win = target_win and vim.api.nvim_win_is_valid(target_win)
  local has_valid_buf = UI.bufs and UI.bufs.img and vim.api.nvim_buf_is_valid(UI.bufs.img)
  if not has_valid_win and not has_valid_buf then
    return
  end

  if not (UI.bufs and UI.bufs.img and vim.api.nvim_buf_is_valid(UI.bufs.img)) then
    UI.bufs.img = util.scratch()
    vim.bo[UI.bufs.img].bufhidden = "hide"
  end
  local buf = UI.bufs.img

  local lines
  if post and resolver.is_video_post(post) then
    local filename = (post.file_url and post.file_url:match("([^/]+)$")) or tostring(post.id or "video")
    local ext = (filename:match("%.([%w]+)$") or "video"):upper()
    local status_msg = message or "Preview not playable in terminal"

    lines = {
      "",
      "  ▶ [ VIDEO FILE: " .. ext .. " ]",
      "",
      "  File       : " .. filename,
    }
    if not post.width or post.width <= 0 then
      local path = post.file_url or post.sample_url
      if path and type(path) == "string" and vim.fn.filereadable(path) == 1 then
        local w, h = resolver.read_image_dimensions(path)
        if w and h and w > 0 and h > 0 then
          post.width = w
          post.height = h
        end
      end
    end
    if post.width and post.height and post.width > 0 and post.height > 0 then
      lines[#lines + 1] = string.format("  Dimensions : %dx%d", post.width, post.height)
    end
    if post.id then
      lines[#lines + 1] = "  Post ID    : " .. tostring(post.id)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Status     : " .. status_msg
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Keymaps:"
    lines[#lines + 1] = "    • 'O' : Open / play in media viewer"
    if post.id and not post.is_local then
      lines[#lines + 1] = "    • 'o' : Open post web page"
    end
  else
    local msg = message or "  Loading..."
    if type(msg) == "table" then
      lines = msg
    else
      lines = vim.split(msg, "\n")
    end
    if UI.bufs and UI.bufs.meta and vim.api.nvim_buf_is_valid(UI.bufs.meta) and msg == "  Loading..." then
      util.set_lines(UI.bufs.meta, {})
    end
  end

  util.set_lines(buf, lines)
  vim.bo[buf].modifiable = false
  M.attach_defensive_keymaps(buf)

  if has_valid_win then
    pcall(vim.api.nvim_win_set_buf, target_win, buf)
  end
end

local function render_image_nvim(win, file_path, opts)
  local ok_image, image_api = pcall(require, "image")
  if not ok_image or not image_api then
    return false
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  M.attach_defensive_keymaps(buf)

  local ok_img, img = pcall(image_api.from_file, file_path, {
    window = win,
    buffer = buf,
    with_virtual_padding = true,
  })
  if not ok_img or not img then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return false
  end

  local ok_render = pcall(img.render, img)
  if not ok_render then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return false
  end

  local current = state.UI.current_placement
  local old_buf = current and current.buf
  M.close()

  state.UI.current_placement = {
    img = img,
    buf = buf,
    src = file_path,
    close = function(self)
      if self.img and self.img.clear then
        pcall(self.img.clear, self.img)
      end
      self.closed = true
    end,
    update = function(self)
      if self.img and self.img.render then
        pcall(self.img.render, self.img)
      end
    end,
  }

  pcall(vim.api.nvim_win_set_buf, win, buf)
  if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
    pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
  end
  log("DEBUG", "CANVAS", "Image rendered via image.nvim: %s", file_path)
  return true
end

--- Displays a verified local file in the given floating window via graphics protocols.
--- Clamps anomalous DPI, attaches shielded keymaps, and binds placement.
--- @param win number: Target window handle
--- @param file_path string: Local verified image path
--- @param opts table|nil: Optional options (e.g. { on_error = fun(err: string) })
--- @return boolean: True if placement rendered successfully
function M.render(win, file_path, opts)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  if config.options.backend == "image_nvim" then
    local ok_nvim = render_image_nvim(win, file_path, opts)
    if ok_nvim then
      return true
    end
    log("WARN", "CANVAS", "image.nvim backend failed or unavailable, falling back to snacks.image")
  end

  local p_ok, placement_mod = pcall(require, "snacks.image.placement")
  if not p_ok or not placement_mod then
    log("WARN", "CANVAS", "snacks.image.placement not available")
    return false
  end

  if placement_mod.progress then
    placement_mod.progress = function() end
  end

  local current = state.UI.current_placement

  -- In-place resize nudge if current placement already matches this exact image
  if current and not current.closed
    and current.img and current.img.src == file_path
    and vim.api.nvim_buf_is_valid(current.buf) then
    M.sanitize_dpi(current.img)
    pcall(vim.api.nvim_win_set_buf, win, current.buf)
    current._state = nil
    pcall(current.update, current)
    log("DEBUG", "CANVAS", "In-place resize nudge: %s", file_path)
    return true
  end

  -- Purge corrupted snacks cache before rendering
  resolver.clean_corrupt_snacks_cache(file_path)

  -- Pre-sanitize cached terminal image DPI if present
  local ok_term, term = pcall(require, "snacks.image.terminal")
  if ok_term and term and term.images and term.images[file_path] then
    M.sanitize_dpi(term.images[file_path])
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  M.attach_defensive_keymaps(buf)

  local place_opts = {
    pos = { 1, 0 },
    auto_resize = true,
    on_update_pre = function(p)
      M.sanitize_dpi(p and p.img)
    end,
  }

  local place_ok, placement = pcall(placement_mod.new, buf, file_path, place_opts)
  if not place_ok or not placement then
    log("WARN", "CANVAS", "Failed to create snacks placement for %s: %s", file_path, tostring(placement))
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return false
  end

  placement.progress = function() end
  M.sanitize_dpi(placement.img)

  local orig_update = placement.update
  placement.update = function(self)
    M.sanitize_dpi(self and self.img)
    if orig_update then
      pcall(orig_update, self)
    end
  end

  local orig_error = placement.error
  placement.error = function(self)
    log("WARN", "CANVAS", "Snacks image conversion failed for %s", file_path)
    resolver.clear_cache(file_path)

    if orig_error then
      pcall(orig_error, self)
    end

    if opts and type(opts.on_error) == "function" then
      pcall(opts.on_error, "Image Conversion Failed - File may be corrupted or unsupported")
    else
      vim.schedule(function()
        if state.State.torn_down then
          return
        end
        local cur_post = state.State.posts and state.State.posts[state.State.cur]
        local render = require("gelbooru.ui.render")
        if render and render.fail_preview then
          render.fail_preview("Image Conversion Failed - File may be corrupted or unsupported", cur_post)
        end
      end)
    end
  end

  local old_buf = current and current.buf
  M.close()
  state.UI.current_placement = placement
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
  log("DEBUG", "CANVAS", "Image rendered via snacks.image: %s", file_path)
  return true
end

return M
