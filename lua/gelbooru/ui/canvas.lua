local config = require("gelbooru.core.config")
local constants = require("gelbooru.core.constants")
local log = require("gelbooru.core.log")
local resolver = require("gelbooru.media.resolver")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")

local M = {}

--- Probes terminal capabilities and selects graphics driver.
--- @param env table|nil: Optional environment table override for testing (defaults to vim.env)
--- @return table: { terminal: string, is_kitty_compliant: boolean, has_placeholders: boolean, has_tmux: boolean, driver: string }
function M.detect_capabilities(env)
  env = env or vim.env
  local term_name = "unknown"
  local is_kitty = false
  local has_placeholders = false

  local ghostty_ver = env.GHOSTTY_VERSION
  local term = env.TERM or ""
  local term_prog = env.TERM_PROGRAM or ""
  local kitty_id = env.KITTY_WINDOW_ID
  local wezterm_pane = env.WEZTERM_PANE

  if (ghostty_ver and ghostty_ver ~= "") or term == "xterm-ghostty" or term == "ghostty" or term_prog:lower() == "ghostty" then
    term_name = "ghostty"
    is_kitty = true
    has_placeholders = true
  elseif (kitty_id and kitty_id ~= "") or term == "xterm-kitty" or term == "kitty" or term_prog:lower() == "kitty" then
    term_name = "kitty"
    is_kitty = true
    has_placeholders = true
  elseif (wezterm_pane and wezterm_pane ~= "") or term_prog:lower() == "wezterm" then
    term_name = "wezterm"
    is_kitty = false
    has_placeholders = false
  end

  local tmux_env = env.TMUX
  local has_tmux = (tmux_env ~= nil and tmux_env ~= "") or term == "tmux" or (type(term) == "string" and term:match("^tmux") ~= nil)

  local cfg_backend = (config.options and config.options.backend or "auto"):lower()
  local driver = "snacks"
  if cfg_backend == "snacks" then
    driver = "snacks"
  elseif cfg_backend == "ghostty" or cfg_backend == "kitty" then
    driver = "native"
  elseif cfg_backend == "auto" then
    if is_kitty and has_placeholders then
      driver = "native"
    else
      driver = "snacks"
    end
  end

  return {
    terminal = term_name,
    is_kitty_compliant = is_kitty,
    has_placeholders = has_placeholders,
    has_tmux = has_tmux,
    driver = driver,
  }
end

local b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function lua_b64(data)
  return ((data:gsub(".", function(x)
    local r, b = "", x:byte()
    for i = 8, 1, -1 do
      r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0")
    end
    return r
  end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
    if #x < 6 then
      return ""
    end
    local c = 0
    for i = 1, 6 do
      if x:sub(i, i) == "1" then
        c = c + 2 ^ (6 - i)
      end
    end
    return b64_chars:sub(c + 1, c + 1)
  end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

--- Base64 encodes a string payload.
--- @param str string
--- @return string
function M.base64_encode(str)
  if not str or str == "" then
    return ""
  end
  if vim.base64 and type(vim.base64.encode) == "function" then
    return vim.base64.encode(str)
  end
  return lua_b64(str)
end

--- Formats a Kitty graphics protocol control sequence.
--- @param params string|table: Control parameters as string or table
--- @param payload string|nil: Optional base64 payload
--- @return string
function M.format_sequence(params, payload)
  local param_str
  if type(params) == "table" then
    local keys = {}
    local p = vim.deepcopy(params)
    if p.q == nil then
      p.q = 2
    end
    for k in pairs(p) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = string.format("%s=%s", k, tostring(p[k]))
    end
    param_str = table.concat(parts, ",")
  else
    param_str = tostring(params or "")
  end

  if payload and payload ~= "" then
    return string.format("\027_G%s;%s\027\\", param_str, tostring(payload))
  end
  return string.format("\027_G%s\027\\", param_str)
end

--- Wraps a terminal escape sequence in DCS passthrough for tmux.
--- @param seq string
--- @return string
function M.wrap_tmux(seq)
  if not seq or seq == "" then
    return ""
  end
  return "\027Ptmux;" .. seq:gsub("\027", "\027\027") .. "\027\\"
end

--- Formats a Kitty graphics delete command to free terminal textures for image ID.
--- @param image_id number
--- @return string
function M.format_delete_sequence(image_id)
  return M.format_sequence(string.format("a=d,d=i,i=%d,q=2", tonumber(image_id) or 0))
end

M._last_written = {}

--- Emits terminal control sequence to UI stdout / UI event stream.
--- @param seq string
--- @param has_tmux boolean|nil
function M.write_sequence(seq, has_tmux)
  local payload = (has_tmux == true) and M.wrap_tmux(seq) or seq
  table.insert(M._last_written, payload)
  local max_written = constants.CANVAS_MAX_LAST_WRITTEN or 50
  if #M._last_written > max_written then
    table.remove(M._last_written, 1)
  end
  if vim.api.nvim_ui_send then
    pcall(vim.api.nvim_ui_send, payload)
  else
    pcall(function()
      io.stdout:write(payload)
      io.stdout:flush()
    end)
  end
end

local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)

local diacritics = vim.split(
  "0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658,0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2,06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743,0745,0747,0749,074A,07EB,07EC,07ED,07EE,07EF,07F0,07F1,07F3,0816,0817,0818,0819,081B,081C,081D,081E,081F,0820,0821,0822,0823,0825,0826,0827,0829,082A,082B,082C,082D,0951,0953,0954,0F82,0F83,0F86,0F87,135D,135E,135F,17DD,193A,1A17,1A75,1A76,1A77,1A78,1A79,1A7A,1A7B,1A7C,1B6B,1B6D,1B6E,1B6F,1B70,1B71,1B72,1B73,1CD0,1CD1,1CD2,1CDA,1CDB,1CE0,1DC0,1DC1,1DC3,1DC4,1DC5,1DC6,1DC7,1DC8,1DC9,1DCB,1DCC,1DD1,1DD2,1DD3,1DD4,1DD5,1DD6,1DD7,1DD8,1DD9,1DDA,1DDB,1DDC,1DDD,1DDE,1DDF,1DE0,1DE1,1DE2,1DE3,1DE4,1DE5,1DE6,1DFE,20D0,20D1,20D4,20D5,20D6,20D7,20DB,20DC,20E1,20E7,20E9,20F0,2CEF,2CF0,2CF1,2DE0,2DE1,2DE2,2DE3,2DE4,2DE5,2DE6,2DE7,2DE8,2DE9,2DEA,2DEB,2DEC,2DED,2DEE,2DEF,2DF0,2DF1,2DF2,2DF3,2DF4,2DF5,2DF6,2DF7,2DF8,2DF9,2DFA,2DFB,2DFC,2DFD,2DFE,2DFF,A66F,A67C,A67D,A6F0,A6F1,A8E0,A8E1,A8E2,A8E3,A8E4,A8E5,A8E6,A8E7,A8E8,A8E9,A8EA,A8EB,A8EC,A8ED,A8EE,A8EF,A8F0,A8F1,AAB0,AAB2,AAB3,AAB7,AAB8,AABE,AABF,AAC1,FE20,FE21,FE22,FE23,FE24,FE25,FE26,10A0F,10A38,1D185,1D186,1D187,1D188,1D189,1D1AA,1D1AB,1D1AC,1D1AD,1D242,1D243,1D244",
  ","
)

local positions = {}
setmetatable(positions, {
  __index = function(_, k)
    if diacritics[k] then
      positions[k] = vim.fn.nr2char(tonumber(diacritics[k], 16))
      return positions[k]
    end
    return ""
  end,
})

--- Generates Unicode placeholder lines for Kitty graphics virtual placement.
--- @param cols number: Image grid columns
--- @param rows number: Image grid rows
--- @return string[]: Buffer lines containing U+10EEEE placeholders with row/col diacritics
function M.generate_placeholder_grid(cols, rows)
  local max_c = math.min(#diacritics, math.max(1, cols))
  local max_r = math.min(#diacritics, math.max(1, rows))
  local lines = {}
  for r = 1, max_r do
    local row_chars = {}
    local r_diacritic = positions[r]
    for c = 1, max_c do
      row_chars[#row_chars + 1] = PLACEHOLDER
      row_chars[#row_chars + 1] = r_diacritic
      row_chars[#row_chars + 1] = positions[c]
    end
    lines[#lines + 1] = table.concat(row_chars)
  end
  return lines
end

--- Creates or updates the highlight group pairing fg=image_id, sp=placement_id.
--- @param image_id number
--- @param placement_id number
--- @return string: Name of the highlight group
function M.create_native_highlight(image_id, placement_id)
  local hl_name = string.format("GelbooruNative_%d_%d", image_id, placement_id)
  vim.api.nvim_set_hl(0, hl_name, {
    fg = image_id,
    sp = placement_id,
    nocombine = true,
  })
  return hl_name
end

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

--- Cleans corrupt snacks cache and companion .info files associated with file_path or target.
--- Encapsulates graphics artifact cleanup inside canvas.lua.
--- @param file_path string|number: File path or target identifier
--- @return boolean: true if any cache files were cleaned
function M.clean_cache(file_path)
  if not file_path or file_path == "" or tostring(file_path) == "nil" then
    return false
  end

  local candidate_files = {}
  if resolver and resolver.find_snacks_cache_candidates then
    candidate_files = resolver.find_snacks_cache_candidates(file_path)
  end

  local any_cleaned = false
  for _, f in ipairs(candidate_files) do
    if vim.fn.filereadable(f) == 1 and not (resolver and resolver.is_in_save_dir and resolver.is_in_save_dir(f)) then
      local size = vim.fn.getfsize(f) or 0
      local is_corrupt = false
      if size <= 0 then
        is_corrupt = true
      elseif f:match("%.info$") then
        local lines = vim.fn.readfile(f)
        local content = vim.trim(table.concat(lines or {}, " "))
        if resolver and resolver.is_info_corrupt and resolver.is_info_corrupt(content) then
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

        if not is_corrupt and resolver and resolver.read_image_dimensions then
          local w, h = resolver.read_image_dimensions(f)
          if not (w and h and w > 0 and h > 0) then
            is_corrupt = true
          end
        end

        if not is_corrupt and resolver and resolver.is_image_complete and not resolver.is_image_complete(f) then
          is_corrupt = true
        end

        local info_file = f .. ".info"
        if not is_corrupt and vim.fn.filereadable(info_file) == 1 then
          local isz = vim.fn.getfsize(info_file) or 0
          if isz <= 0 then
            is_corrupt = true
          else
            local lines = vim.fn.readfile(info_file)
            local content = vim.trim(table.concat(lines or {}, " "))
            if resolver and resolver.is_info_corrupt and resolver.is_info_corrupt(content) then
              is_corrupt = true
            end
          end
        end
      end

      if is_corrupt then
        any_cleaned = true
        pcall(vim.fn.delete, f)
        if not f:match("%.info$") then
          local info_file = f .. ".info"
          if vim.fn.filereadable(info_file) == 1 and not (resolver and resolver.is_in_save_dir and resolver.is_in_save_dir(info_file)) then
            pcall(vim.fn.delete, info_file)
          end
        else
          local img_file = f:gsub("%.info$", "")
          if vim.fn.filereadable(img_file) == 1 and not (resolver and resolver.is_in_save_dir and resolver.is_in_save_dir(img_file)) then
            local isz = vim.fn.getfsize(img_file) or 0
            if isz <= 0 then
              pcall(vim.fn.delete, img_file)
            else
              local iw, ih = resolver and resolver.read_image_dimensions and resolver.read_image_dimensions(img_file)
              if not (iw and ih and iw > 0 and ih > 0) or (resolver and resolver.is_image_complete and not resolver.is_image_complete(img_file)) then
                pcall(vim.fn.delete, img_file)
              end
            end
          end
        end
      end
    end
  end

  -- Check direct .info file if file_path is a path
  if type(file_path) == "string" and not (resolver and resolver.is_in_save_dir and resolver.is_in_save_dir(file_path)) then
    local info_file = file_path:match("%.info$") and file_path or (file_path .. ".info")
    if vim.fn.filereadable(info_file) == 1 and not (resolver and resolver.is_in_save_dir and resolver.is_in_save_dir(info_file)) then
      local isz = vim.fn.getfsize(info_file) or 0
      local is_corrupt = (isz <= 0)
      if not is_corrupt then
        local lines = vim.fn.readfile(info_file)
        local content = vim.trim(table.concat(lines or {}, " "))
        if resolver and resolver.is_info_corrupt and resolver.is_info_corrupt(content) then
          is_corrupt = true
        end
      end
      if is_corrupt then
        pcall(vim.fn.delete, info_file)
        any_cleaned = true
      end
    end
  end

  if any_cleaned and resolver and resolver.clear_snacks_image_cache then
    resolver.clear_snacks_image_cache()
  end
  return any_cleaned
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

M._native_request_id = 0

--- Synchronously aborts in-flight conversions/transfers and clears placement handles.
--- @param win number|nil: Optional target window handle
function M.abort(win)
  M._native_request_id = (M._native_request_id or 0) + 1
  local UI = state.UI
  pcall(resolver.abort_video_transcodes)
  local p = UI.current_placement
  if p then
    if win == nil or p.win == nil or p.win == win then
      M.abort_convert(p)
      if p.close then
        pcall(p.close, p)
      end
      UI.current_placement = nil
    end
  end
end

--- Closes active graphics placement cleanly and restores window buffer.
function M.close()
  M._native_request_id = (M._native_request_id or 0) + 1
  M.abort()
  local UI = state.UI
  if UI.wins and UI.wins.img and vim.api.nvim_win_is_valid(UI.wins.img)
    and UI.bufs and UI.bufs.img and vim.api.nvim_buf_is_valid(UI.bufs.img) then
    pcall(vim.api.nvim_win_set_buf, UI.wins.img, UI.bufs.img)
  end
end

M.clear = M.close

--- Re-calculates and re-anchors active placement after window resize or Zen toggle.
--- @return boolean
function M.nudge()
  local UI = state.UI
  local p = UI.current_placement
  if p and not p.closed and vim.api.nvim_buf_is_valid(p.buf) then
    if not p.is_native then
      M.sanitize_dpi(p.img)
    end
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

local _seq_img_id = 0
local function next_image_id()
  _seq_img_id = (_seq_img_id % 16777215) + 1
  return _seq_img_id
end

--- Formats Kitty graphics protocol media transmission control sequence.
--- Encapsulates extension detection, format code selection, and base64 encoding.
--- @param file_path string: Local verified image or frame path
--- @param image_id number: Terminal image ID
--- @param is_subsequent boolean|nil: True for subsequent animation frames (a=f)
--- @param delay_ms number|nil: Frame delay in milliseconds for animations
--- @return string: Formatted Kitty escape sequence
local function format_media_transmission(file_path, image_id, is_subsequent, delay_ms)
  local ext = file_path:match("%.([%w_]+)$")
  local is_png = (ext and ext:lower() == "png")
  local format_code = is_png and "f=100," or ""
  local action = is_subsequent and "a=f" or "a=t"
  local z_param = (delay_ms and delay_ms > 0) and string.format("z=%d,", delay_ms) or ""
  local params = string.format("%s,t=f,%si=%d,%sq=2", action, format_code, image_id, z_param)
  local b64 = M.base64_encode(file_path)
  return M.format_sequence(params, b64)
end
M._format_media_transmission = format_media_transmission

--- Native Ghostty 1.4 / Kitty Graphics Protocol driver.
--- Transmits images directly via Kitty protocol with Unicode placeholders.
--- @param win number: Target window handle
--- @param file_path string: Local verified image path
--- @param opts table|nil: Options table
--- @param cap table: Capability info table
--- @return boolean
local function render_native(win, file_path, opts, cap)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if vim.fn.filereadable(file_path) ~= 1 then
    return false
  end

  M._native_request_id = (M._native_request_id or 0) + 1
  local req_id = M._native_request_id
  local target_cur = state.State.cur
  local target_cur_id = state.State.cur_id

  local current = state.UI.current_placement
  if current and not current.closed
    and current.src == file_path
    and vim.api.nvim_buf_is_valid(current.buf) then
    pcall(vim.api.nvim_win_set_buf, win, current.buf)
    current._state = nil
    pcall(current.update, current)
    log("DEBUG", "CANVAS", "Native in-place resize nudge: %s", file_path)
    return true
  end

  local function transmit_and_create_placement(frame_files, is_animated)
    if not win or not vim.api.nvim_win_is_valid(win) then
      return false
    end

    local image_id = next_image_id()
    local placement_id = 1
    local has_tmux = cap and cap.has_tmux

    local win_w = vim.api.nvim_win_get_width(win)
    local win_h = vim.api.nvim_win_get_height(win)
    local iw, ih = resolver.read_image_dimensions(file_path)
    local cols = win_w
    local rows = win_h
    if iw and ih and iw > 0 and ih > 0 then
      local r = (iw / ih) * 2.0
      rows = math.floor(cols / r)
      if rows > win_h then
        rows = win_h
        cols = math.floor(rows * r)
      end
    end
    cols = math.max(1, math.min(win_w, math.min(#diacritics, cols)))
    rows = math.max(1, math.min(win_h, math.min(#diacritics, rows)))

    local delay = (opts and opts.delay) or 100

    if is_animated and frame_files and #frame_files > 0 then
      -- Base frame 1: a=t, t=f, z=DELAY
      local t_seq = format_media_transmission(frame_files[1], image_id, false, delay)
      M.write_sequence(t_seq, has_tmux)

      -- Subsequent frames 2..N: a=f, t=f, z=DELAY
      for k = 2, #frame_files do
        local f_seq = format_media_transmission(frame_files[k], image_id, true, delay)
        M.write_sequence(f_seq, has_tmux)
      end

      -- Placement: a=p, U=1
      local p_seq = M.format_sequence(string.format("a=p,U=1,i=%d,p=%d,C=1,c=%d,r=%d,q=2", image_id, placement_id, cols, rows))
      M.write_sequence(p_seq, has_tmux)

      -- Hardware loop control: a=a, i=ID, s=3, v=1
      local a_seq = M.format_sequence(string.format("a=a,i=%d,s=3,v=1,q=2", image_id))
      M.write_sequence(a_seq, has_tmux)
    elseif is_animated then
      -- Fallback: transmit original file directly
      local t_seq = format_media_transmission(file_path, image_id, false, delay)
      M.write_sequence(t_seq, has_tmux)
      local p_seq = M.format_sequence(string.format("a=p,U=1,i=%d,p=%d,C=1,c=%d,r=%d,q=2", image_id, placement_id, cols, rows))
      M.write_sequence(p_seq, has_tmux)
      local a_seq = M.format_sequence(string.format("a=a,i=%d,s=3,v=1,q=2", image_id))
      M.write_sequence(a_seq, has_tmux)
    else
      -- Static PNG/JPEG fast path: omit f=100 for JPEG so terminal auto-detects
      local t_seq = format_media_transmission(file_path, image_id, false, nil)
      M.write_sequence(t_seq, has_tmux)

      local p_seq = M.format_sequence(string.format("a=p,U=1,i=%d,p=%d,C=1,c=%d,r=%d,q=2", image_id, placement_id, cols, rows))
      M.write_sequence(p_seq, has_tmux)
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = true
    M.attach_defensive_keymaps(buf)

    local lines = M.generate_placeholder_grid(cols, rows)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    local hl_name = M.create_native_highlight(image_id, placement_id)
    local ns = vim.api.nvim_create_namespace("gelbooru.canvas")
    for r = 1, rows do
      vim.api.nvim_buf_add_highlight(buf, ns, hl_name, r - 1, 0, -1)
    end
    vim.bo[buf].modifiable = false

    local placement = {
      id = placement_id,
      buf = buf,
      win = win,
      src = file_path,
      closed = false,
      updated_count = 0,
      is_native = true,
      is_animated = (is_animated == true),
      image_id = image_id,
      has_tmux = has_tmux,
      progress = function() end,
      img = {
        id = image_id,
        src = file_path,
        _convert = {
          aborted = false,
          abort = function(self)
            self.aborted = true
          end,
        },
      },
      update = function(self)
        self.updated_count = self.updated_count + 1
        if not self.closed and self.win and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_buf_is_valid(self.buf) then
          local nw = vim.api.nvim_win_get_width(self.win)
          local nh = vim.api.nvim_win_get_height(self.win)
          local niw, nih = resolver.read_image_dimensions(self.src)
          local ncols = nw
          local nrows = nh
          if niw and nih and niw > 0 and nih > 0 then
            local r = (niw / nih) * 2.0
            nrows = math.floor(ncols / r)
            if nrows > nh then
              nrows = nh
              ncols = math.floor(nrows * r)
            end
          end
          ncols = math.max(1, math.min(nw, math.min(#diacritics, ncols)))
          nrows = math.max(1, math.min(nh, math.min(#diacritics, nrows)))

          local re_p_seq = M.format_sequence(string.format("a=p,U=1,i=%d,p=%d,C=1,c=%d,r=%d,q=2", self.image_id, self.id, ncols, nrows))
          M.write_sequence(re_p_seq, self.has_tmux)

          vim.bo[self.buf].modifiable = true
          local new_lines = M.generate_placeholder_grid(ncols, nrows)
          vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, new_lines)
          local p_ns = vim.api.nvim_create_namespace("gelbooru.canvas")
          local p_hl = M.create_native_highlight(self.image_id, self.id)
          for pr = 1, nrows do
            vim.api.nvim_buf_add_highlight(self.buf, p_ns, p_hl, pr - 1, 0, -1)
          end
          vim.bo[self.buf].modifiable = false
        end
      end,
      close = function(self)
        if self.closed then
          return
        end
        self.closed = true
        if self.img and self.img._convert then
          self.img._convert.aborted = true
        end
        local del_seq = M.format_delete_sequence(self.image_id)
        M.write_sequence(del_seq, self.has_tmux)
        if vim.api.nvim_buf_is_valid(self.buf) then
          pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
        end
        if state.UI.current_placement == self then
          state.UI.current_placement = nil
        end
      end,
      error = function(self)
        log("WARN", "CANVAS", "Native placement error for %s", self.src)
        if opts and type(opts.on_error) == "function" then
          pcall(opts.on_error, "Image Display Failed")
        else
          vim.schedule(function()
            if state.State.torn_down then
              return
            end
            local cur_post = state.State.posts and state.State.posts[state.State.cur]
            local render = require("gelbooru.ui.render")
            if render and render.fail_preview then
              render.fail_preview("Image Display Failed", cur_post)
            end
          end)
        end
      end,
    }

    local old_placement = state.UI.current_placement
    state.UI.current_placement = placement

    -- AGENTS.md §6.5: Set window buffer BEFORE closing/deleting superseded buffer
    pcall(vim.api.nvim_win_set_buf, win, buf)

    if old_placement and old_placement ~= placement then
      if old_placement.close then
        pcall(old_placement.close, old_placement)
      end
    end

    log("DEBUG", "CANVAS", "Image rendered via native Ghostty/Kitty driver: %s", file_path)
    return true
  end

  local is_anim = resolver.is_gif_animated and resolver.is_gif_animated(file_path)
  if is_anim then
    local base = vim.fn.fnamemodify(file_path, ":t:r")
    local cache_dir = (config.options and config.options.cache_dir) or "/tmp/gelbooru_cache"
    local anim_dir = cache_dir .. "/anim_" .. base
    local frame_0 = string.format("%s/frame_000.png", anim_dir)

    if vim.fn.filereadable(frame_0) == 1 and (vim.fn.getfsize(frame_0) or 0) > 0 then
      local frame_files = vim.fn.glob(anim_dir .. "/frame_*.png", false, true)
      table.sort(frame_files)
      if #frame_files > 0 then
        return transmit_and_create_placement(frame_files, true)
      end
    end

    -- Non-blocking frame extraction via transcoder
    M.render_placeholder(win, nil, "  Extracting animation frames...")
    M._native_request_id = (M._native_request_id or 0) + 1
    req_id = M._native_request_id
    target_cur = state.State.cur
    target_cur_id = state.State.cur_id
    local transcoder = require("gelbooru.media.transcoder")
    transcoder.coalesce_animation_frames(file_path, anim_dir, function(ok, frame_files)
      if state.State.torn_down then
        return
      end
      if req_id ~= M._native_request_id then
        return
      end
      if not win or not vim.api.nvim_win_is_valid(win) then
        return
      end
      if state.UI.wins and state.UI.wins.img and state.UI.wins.img ~= win then
        return
      end
      if target_cur_id and state.State.cur_id and state.State.cur_id ~= target_cur_id then
        return
      end
      if not ok or not frame_files or #frame_files == 0 then
        return
      end
      transmit_and_create_placement(frame_files, true)
    end)
    return true
  else
    return transmit_and_create_placement(nil, false)
  end
end

--- Fallback adapter delegating to snacks.image.placement.
--- @param win number: Target window handle
--- @param file_path string: Local verified image path
--- @param opts table|nil: Optional options
--- @return boolean
local function render_snacks(win, file_path, opts)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
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
  M.clean_cache(file_path)

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
  local old_placement = current
  state.UI.current_placement = placement
  pcall(vim.api.nvim_win_set_buf, win, buf)
  if old_placement and old_placement ~= placement then
    if old_placement.close then
      pcall(old_placement.close, old_placement)
    end
  end
  if old_buf and vim.api.nvim_buf_is_valid(old_buf) and old_buf ~= buf then
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

--- Unified display interface: dispatches to native driver or snacks adapter.
--- @param win number: Target window handle
--- @param file_path string: Local verified image path
--- @param opts table|nil: Optional options
--- @return boolean
function M.display(win, file_path, opts)
  local cap = M.detect_capabilities()
  if cap.driver == "native" then
    return render_native(win, file_path, opts, cap)
  end
  return render_snacks(win, file_path, opts)
end

M.render = M.display

return M
