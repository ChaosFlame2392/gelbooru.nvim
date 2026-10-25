local config = require("gelbooru.core.config")
local constants = require("gelbooru.core.constants")

local M = {}

local _auth_cache = nil

function M.load_auth()
  if _auth_cache then
    return _auth_cache
  end
  local f = io.open(config.options.auth_file, "r")
  if not f then
    _auth_cache = {}
    return _auth_cache
  end
  local raw = f:read("*a")
  f:close()
  local ok, t = pcall(vim.json and vim.json.decode or vim.fn.json_decode, raw)
  _auth_cache = (ok and type(t) == "table") and t or {}
  return _auth_cache
end

function M.invalidate_auth_cache()
  _auth_cache = nil
end

function M.auth_qs()
  local a = M.load_auth()
  if not a.api_key then
    return ""
  end
  return string.format("&api_key=%s&user_id=%s", a.api_key, a.user_id or "")
end

function M.ensure(path)
  vim.fn.mkdir(path, "p")
end

function M.ensure_array(v)
  if type(v) ~= "table" then return {} end
  if v[1] == nil and next(v) ~= nil then return { v } end
  return v
end

function M.url_encode(s)
  if s == nil then return "" end
  s = tostring(s)
  return (s:gsub("([^%w%-%.%_%~ ])", function(c)
    return string.format("%%%02X", string.byte(c))
  end):gsub(" ", "+"))
end

function M.normalize_str(s)
  return (s or ""):gsub("[^%w]", ""):lower()
end

function M.is_local_query(q)
  if not q or type(q) ~= "string" then
    return false
  end
  return q:match("^%s*[\"']?[Ll][Oo][Cc][Aa][Ll]:") ~= nil
    or q:match("[%s%|]+[\"']?[Ll][Oo][Cc][Aa][Ll]:") ~= nil
end

function M.decode_html(str)
  if not str then
    return ""
  end
  str = str:gsub("&gt;", ">")
    :gsub("&lt;", "<")
    :gsub("&amp;", "&")
    :gsub("&quot;", '"')
    :gsub("&#039;", "'")
    :gsub("&#39;", "'")
  return str
end

function M.fuzzy(str, q)
  if q == "" then
    return true
  end
  local qi = 1
  for i = 1, #str do
    if str:sub(i, i):lower() == q:sub(qi, qi):lower() then
      qi = qi + 1
      if qi > #q then
        return true
      end
    end
  end
  return false
end

function M.scratch()
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile = false
  vim.bo[b].modifiable = false
  return b
end

function M.set_lines(buf, lines)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M.float(buf, row, col, w, h, extra)
  local cfg = vim.tbl_extend("force", {
    relative = "editor",
    row = row,
    col = col,
    width = w,
    height = h,
    style = "minimal",
    border = "none",
    zindex = constants.ZINDEX_DEFAULT_FLOAT,
    focusable = true,
  }, extra or {})
  return vim.api.nvim_open_win(buf, false, cfg)
end

function M.meta_cache_path(post_id)
  if not post_id or tostring(post_id) == "" or tostring(post_id) == "nil" then
    return nil
  end
  return string.format("%s/meta_%s.json", config.options.cache_dir, tostring(post_id))
end

function M.read_json(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json and vim.json.decode or vim.fn.json_decode, raw)
  return (ok and type(data) == "table") and data or nil
end

function M.write_json(path, data)
  if not path or not data then
    return false
  end
  local ok, encoded = pcall(vim.fn.json_encode, data)
  if not ok or not encoded then
    return false
  end
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir and dir ~= "" then
    M.ensure(dir)
  end
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return false
  end
  f:write(encoded)
  f:close()
  local ren_ok = vim.fn.rename(tmp, path)
  return ren_ok == 0
end

function M.open_url(url)
  if not url or url == "" then
    return false
  end
  if vim.ui and vim.ui.open then
    local ok = pcall(vim.ui.open, url)
    if ok then
      return true
    end
  end
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    pcall(vim.fn.jobstart, { "cmd.exe", "/c", "start", '""', url }, { detach = true })
    return true
  elseif vim.fn.has("mac") == 1 then
    pcall(vim.fn.jobstart, { "open", "--", url }, { detach = true })
    return true
  else
    pcall(vim.fn.jobstart, { "xdg-open", "--", url }, { detach = true })
    return true
  end
end

function M.open_media(target)
  if not target or target == "" then
    return false
  end
  if config.options.media_player and config.options.media_player ~= "" then
    pcall(vim.fn.jobstart, { config.options.media_player, target }, { detach = true })
    return true
  end
  return M.open_url(target)
end

function M.cache_post_metadata(p)
  if not p or not p.id or tostring(p.id) == "" or tostring(p.id) == "nil" then
    return false
  end
  local meta_path = M.meta_cache_path(p.id)
  if not meta_path then
    return false
  end
  return M.write_json(meta_path, {
    id = p.id,
    tags = p.tags,
    rating = p.rating,
    score = p.score,
    width = p.width,
    height = p.height,
    source = p.source,
  })
end

function M.keymap(buf, mode, key, fn)
  vim.keymap.set(mode, key, fn, { buffer = buf, nowait = true, noremap = true, silent = true })
end

function M.shield_buffer(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  pcall(function()
    vim.bo[buf].filetype = "gelbooru"
    vim.b[buf].which_key_ignore = true
    vim.b[buf].whichkey_disable = true
    vim.b[buf].miniclue_disable = true
  end)
  local ok, wk_conf = pcall(require, "which-key.config")
  if ok and wk_conf and wk_conf.disable and type(wk_conf.disable.ft) == "table" then
    if not vim.tbl_contains(wk_conf.disable.ft, "gelbooru") then
      table.insert(wk_conf.disable.ft, "gelbooru")
    end
  end
  for _, m in ipairs({ "n", "v", "x" }) do
    M.keymap(buf, m, "<Space>", function() end)
    M.keymap(buf, m, " ", function() end)
    M.keymap(buf, m, "<Leader>", function() end)
    M.keymap(buf, m, "<Localleader>", function() end)
  end
  M.keymap(buf, "n", "z", function() end)
  M.keymap(buf, "n", "Z", function() end)
end

function M.close_timer(timer)
  if not timer then
    return nil
  end
  pcall(function()
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end)
  return nil
end

function M.file_ext(url_or_path)
  if not url_or_path or type(url_or_path) ~= "string" then
    return ""
  end
  local clean = url_or_path:gsub("[?#].*$", ""):gsub("[/\\]+$", "")
  local fname = clean:match("([^/\\]+)$") or clean
  local ext = fname:match("%.([^%.]+)$") or ""
  return ext:lower()
end

function M.is_same_post(p1, p2)
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

function M.shuffle(list)
  if not list or #list <= 1 then
    return list or {}
  end
  local uv = vim.uv or vim.loop
  math.randomseed(os.time() + (uv.hrtime() % constants.SHUFFLE_SEED_MODULO))
  math.random()
  math.random()
  math.random()
  for i = #list, 2, -1 do
    local j = math.random(i)
    list[i], list[j] = list[j], list[i]
  end
  return list
end

local function parse_png_dimensions(f)
  f:seek("set", 0)
  local data = f:read(24)
  if not data or #data < 24 then
    return nil, nil
  end
  local b1, b2, b3, b4, b5, b6, b7, b8 = string.byte(data, 1, 8)
  if b1 ~= 137 or b2 ~= 80 or b3 ~= 78 or b4 ~= 71 or b5 ~= 13 or b6 ~= 10 or b7 ~= 26 or b8 ~= 10 then
    return nil, nil
  end
  local ctype = data:sub(13, 16)
  if ctype ~= "IHDR" then
    return nil, nil
  end
  local w1, w2, w3, w4, h1, h2, h3, h4 = string.byte(data, 17, 24)
  local w = w1 * 16777216 + w2 * 65536 + w3 * 256 + w4
  local h = h1 * 16777216 + h2 * 65536 + h3 * 256 + h4
  if w > 0 and h > 0 then
    return w, h
  end
  return nil, nil
end

local function parse_gif_dimensions(f)
  f:seek("set", 0)
  local data = f:read(10)
  if not data or #data < 10 then
    return nil, nil
  end
  local sig = data:sub(1, 6)
  if sig ~= "GIF87a" and sig ~= "GIF89a" then
    return nil, nil
  end
  local w1, w2, h1, h2 = string.byte(data, 7, 10)
  local w = w1 + w2 * 256
  local h = h1 + h2 * 256
  if w > 0 and h > 0 then
    return w, h
  end
  return nil, nil
end

local function parse_webp_dimensions(f)
  f:seek("set", 0)
  local head = f:read(12)
  if not head or #head < 12 then
    return nil, nil
  end
  if head:sub(1, 4) ~= "RIFF" or head:sub(9, 12) ~= "WEBP" then
    return nil, nil
  end

  local offset = 12
  local max_chunks = constants.MAX_WEBP_CHUNKS or 32
  while max_chunks > 0 do
    max_chunks = max_chunks - 1
    f:seek("set", offset)
    local chunk_hdr = f:read(8)
    if not chunk_hdr or #chunk_hdr < 8 then
      return nil, nil
    end
    local fourcc = chunk_hdr:sub(1, 4)
    local s1, s2, s3, s4 = string.byte(chunk_hdr, 5, 8)
    local chunk_size = s1 + s2 * 256 + s3 * 65536 + s4 * 16777216
    if chunk_size < 0 then
      return nil, nil
    end

    if fourcc == "VP8 " then
      local payload = f:read(10)
      if not payload or #payload < 10 then
        return nil, nil
      end
      local sc1, sc2, sc3 = string.byte(payload, 4, 6)
      if sc1 ~= 157 or sc2 ~= 1 or sc3 ~= 42 then
        return nil, nil
      end
      local w1, w2, h1, h2 = string.byte(payload, 7, 10)
      local w = (w1 + w2 * 256) % 16384
      local h = (h1 + h2 * 256) % 16384
      if w > 0 and h > 0 then
        return w, h
      end
      return nil, nil
    elseif fourcc == "VP8L" then
      local payload = f:read(5)
      if not payload or #payload < 5 then
        return nil, nil
      end
      local sig, b0, b1, b2, b3 = string.byte(payload, 1, 5)
      if sig ~= 47 then
        return nil, nil
      end
      local w = (b0 + (b1 % 64) * 256) + 1
      local h = (math.floor(b1 / 64) + b2 * 4 + (b3 % 16) * 1024) + 1
      if w > 0 and h > 0 then
        return w, h
      end
      return nil, nil
    elseif fourcc == "VP8X" then
      local payload = f:read(10)
      if not payload or #payload < 10 then
        return nil, nil
      end
      local w1, w2, w3, h1, h2, h3 = string.byte(payload, 5, 10)
      local w = (w1 + w2 * 256 + w3 * 65536) + 1
      local h = (h1 + h2 * 256 + h3 * 65536) + 1
      if w > 0 and h > 0 then
        return w, h
      end
      return nil, nil
    else
      local pad = (chunk_size % 2 == 1) and 1 or 0
      offset = offset + 8 + chunk_size + pad
    end
  end
  return nil, nil
end

local function parse_jpeg_dimensions(f)
  f:seek("set", 0)
  local soi = f:read(2)
  if not soi or #soi < 2 then
    return nil, nil
  end
  local b1, b2 = string.byte(soi, 1, 2)
  if b1 ~= 255 or b2 ~= 216 then
    return nil, nil
  end

  local max_markers = constants.MAX_JPEG_MARKERS or 256
  while max_markers > 0 do
    local byte = f:read(1)
    if not byte then
      return nil, nil
    end
    local m = string.byte(byte)
    if m == 255 then
      max_markers = max_markers - 1
      while true do
        local next_b = f:read(1)
        if not next_b then
          return nil, nil
        end
        m = string.byte(next_b)
        if m ~= 255 then
          break
        end
      end

      if m == 0 or m == 255 then
        -- 0x00 is escaped 0xFF; continue scanning
      elseif m == 217 or m == 218 then
        -- 0xD9 (EOI) or 0xDA (SOS) reached before SOF marker
        return nil, nil
      elseif (m >= 192 and m <= 195) or (m >= 197 and m <= 199) or (m >= 201 and m <= 203) or (m >= 205 and m <= 207) then
        -- SOF0-SOF3, SOF5-SOF7, SOF9-SOF11, SOF13-SOF15
        local hdr = f:read(7)
        if not hdr or #hdr < 7 then
          return nil, nil
        end
        local l1, l2, prec, h1, h2, w1, w2 = string.byte(hdr, 1, 7)
        local h = h1 * 256 + h2
        local w = w1 * 256 + w2
        if w > 0 and h > 0 then
          return w, h
        end
        return nil, nil
      elseif m == 1 or (m >= 208 and m <= 215) then
        -- TEM (0x01) or RST0-RST7 (0xD0-0xD7) have no payload length
      else
        local len_bytes = f:read(2)
        if not len_bytes or #len_bytes < 2 then
          return nil, nil
        end
        local l1, l2 = string.byte(len_bytes, 1, 2)
        local seg_len = l1 * 256 + l2
        if seg_len < 2 then
          return nil, nil
        end
        local seek_res = f:seek("cur", seg_len - 2)
        if not seek_res then
          return nil, nil
        end
      end
    end
  end
  return nil, nil
end

local function parse_dimensions(f)
  local magic = f:read(4)
  if not magic or #magic < 4 then
    return nil, nil
  end

  local b1, b2, b3, b4 = string.byte(magic, 1, 4)
  if b1 == 137 and b2 == 80 and b3 == 78 and b4 == 71 then
    return parse_png_dimensions(f)
  elseif magic:sub(1, 3) == "GIF" then
    return parse_gif_dimensions(f)
  elseif magic == "RIFF" then
    return parse_webp_dimensions(f)
  elseif b1 == 255 and b2 == 216 then
    return parse_jpeg_dimensions(f)
  end

  return nil, nil
end

function M.read_image_dimensions(path)
  if not path or type(path) ~= "string" or path == "" then
    return nil, nil
  end
  local f = io.open(path, "rb")
  if not f then
    return nil, nil
  end

  local ok, w, h = pcall(parse_dimensions, f)
  f:close()
  if ok and w and h and w > 0 and h > 0 then
    return w, h
  end
  return nil, nil
end

function M.is_image_complete(path)
  if not path or type(path) ~= "string" or path == "" then
    return false
  end
  local sz = vim.fn.getfsize(path)
  if not sz or sz <= 0 then
    return false
  end
  local f = io.open(path, "rb")
  if not f then
    return false
  end

  local head = f:read(16) or ""
  local hlen = #head
  if hlen < 4 then
    f:close()
    return false
  end

  local lower_head = head:lower()
  if lower_head:find("<!doctype", 1, true)
    or lower_head:find("<html", 1, true)
    or lower_head:find("<?xml", 1, true) then
    f:close()
    return false
  end

  local b1, b2, b3, b4 = string.byte(head, 1, 4)

  -- PNG: 8-byte signature (\137PNG\r\n\026\n) and IEND chunk in the last 64 bytes
  if b1 == 137 and b2 == 80 and b3 == 78 and b4 == 71 then
    if hlen < 8 or head:sub(1, 8) ~= "\137PNG\r\n\026\n" or sz < 36 then
      f:close()
      return false
    end
    local seek_back = math.min(sz, 64)
    f:seek("end", -seek_back)
    local tail = f:read(seek_back) or ""
    f:close()
    return tail:find("IEND", 1, true) ~= nil
  end

  -- JPEG: SOI (\255\216) and EOI (\255\217) in the last 128 bytes
  if b1 == 255 and b2 == 216 then
    if sz < 4 then
      f:close()
      return false
    end
    local seek_back = math.min(sz, 128)
    f:seek("end", -seek_back)
    local tail = f:read(seek_back) or ""
    f:close()
    return tail:find("\255\217", 1, true) ~= nil
  end

  -- GIF: GIF87a / GIF89a header and trailer ';' (0x3B)
  if head:sub(1, 3) == "GIF" then
    if hlen < 6 or (head:sub(1, 6) ~= "GIF87a" and head:sub(1, 6) ~= "GIF89a") or sz < 6 then
      f:close()
      return false
    end
    local seek_back = math.min(sz, 4)
    f:seek("end", -seek_back)
    local tail = f:read(seek_back) or ""
    f:close()
    return tail:find(";", 1, true) ~= nil
  end

  -- WebP: RIFF header, WEBP fourcc at bytes 9-12, declared payload size
  if head:sub(1, 4) == "RIFF" then
    if hlen < 12 or head:sub(9, 12) ~= "WEBP" then
      f:close()
      return false
    end
    local s1, s2, s3, s4 = string.byte(head, 5, 8)
    local riff_len = s1 + s2 * 256 + s3 * 65536 + s4 * 16777216
    f:close()
    return sz >= (riff_len + 8)
  end

  f:close()

  -- Fallback for unhandled/other formats: validate dimensions
  local w, h = M.read_image_dimensions(path)
  return (w ~= nil and h ~= nil and w > 0 and h > 0)
end

return M
