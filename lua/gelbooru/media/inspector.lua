-- lua/gelbooru/media/inspector.lua
-- Pure, deterministic binary parser for image dimensions and integrity validation.
-- Zero side effects, zero Neovim window/buffer dependencies, sub-millisecond execution.

local constants = require("gelbooru.core.constants")

local M = {}

--- Parses PNG width and height from file handle.
--- @param f file*
--- @return number|nil width, number|nil height
function M.parse_png_dimensions(f)
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

--- Parses GIF width and height from file handle.
--- @param f file*
--- @return number|nil width, number|nil height
function M.parse_gif_dimensions(f)
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

--- Parses WebP width and height from file handle.
--- @param f file*
--- @return number|nil width, number|nil height
function M.parse_webp_dimensions(f)
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

--- Parses JPEG width and height from file handle.
--- @param f file*
--- @return number|nil width, number|nil height
function M.parse_jpeg_dimensions(f)
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
        local _, _, _, h1, h2, w1, w2 = string.byte(hdr, 1, 7)
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
    return M.parse_png_dimensions(f)
  elseif magic:sub(1, 3) == "GIF" then
    return M.parse_gif_dimensions(f)
  elseif magic == "RIFF" then
    return M.parse_webp_dimensions(f)
  elseif b1 == 255 and b2 == 216 then
    return M.parse_jpeg_dimensions(f)
  end

  return nil, nil
end

--- Reads image pixel dimensions from file header without external processes.
--- @param path string: Image file path
--- @return number|nil width, number|nil height
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

--- Verifies binary completion of an image file (checks headers, trailers, and EOI/IEND markers).
--- @param path string: File path
--- @return boolean
function M.is_image_complete(path)
  if not path or type(path) ~= "string" or path == "" then
    return false
  end
  local f = io.open(path, "rb")
  if not f then
    return false
  end

  local sz = f:seek("end") or 0
  if sz <= 0 then
    f:close()
    return false
  end
  f:seek("set", 0)

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

  local w, h = M.read_image_dimensions(path)
  return (w ~= nil and h ~= nil and w > 0 and h > 0)
end

--- Checks whether an image file is an animated GIF by parsing block structure and counting image frames.
--- Parses strictly according to GIF87a/GIF89a specifications, skipping sub-blocks.
--- @param path string: File path
--- @return boolean
function M.is_gif_animated(path)
  if not path or type(path) ~= "string" or path == "" then
    return false
  end
  local f = io.open(path, "rb")
  if not f then
    return false
  end
  local sig = f:read(6) or ""
  if sig ~= "GIF87a" and sig ~= "GIF89a" then
    f:close()
    return false
  end

  -- Logical Screen Descriptor: 7 bytes
  local lsd = f:read(7)
  if not lsd or #lsd < 7 then
    f:close()
    return false
  end
  local packed = string.byte(lsd, 5)
  local has_gct = (packed >= 128)
  if has_gct then
    local gct_entries = 2 ^ ((packed % 8) + 1)
    f:seek("cur", gct_entries * 3)
  end

  local frame_count = 0
  while true do
    local b = f:read(1)
    if not b then
      break
    end
    local byte = string.byte(b)
    if byte == 0x3B then -- Trailer
      break
    elseif byte == 0x21 then -- Extension block
      local ext_type = f:read(1)
      if not ext_type then
        break
      end
      -- Skip all sub-blocks of this extension
      while true do
        local sz_b = f:read(1)
        if not sz_b then
          break
        end
        local sz = string.byte(sz_b)
        if sz == 0 then
          break
        end
        f:seek("cur", sz)
      end
    elseif byte == 0x2C then -- Image Descriptor
      frame_count = frame_count + 1
      if frame_count > 1 then
        f:close()
        return true
      end
      -- Skip remainder of Image Descriptor (9 bytes: left, top, width, height, packed)
      local id_rem = f:read(9)
      if not id_rem or #id_rem < 9 then
        break
      end
      local id_packed = string.byte(id_rem, 9)
      local has_lct = (id_packed >= 128)
      if has_lct then
        local lct_entries = 2 ^ ((id_packed % 8) + 1)
        f:seek("cur", lct_entries * 3)
      end
      -- Skip LZW minimum code size (1 byte)
      f:seek("cur", 1)
      -- Skip image data sub-blocks
      while true do
        local sz_b = f:read(1)
        if not sz_b then
          break
        end
        local sz = string.byte(sz_b)
        if sz == 0 then
          break
        end
        f:seek("cur", sz)
      end
    else
      -- Unknown block or sync lost
      break
    end
  end

  f:close()
  return frame_count > 1
end

--- Inspects an image file and returns dimension and format details.
--- @param path string
--- @return table|nil
function M.inspect(path)
  if not path or type(path) ~= "string" or path == "" then
    return nil
  end
  local w, h = M.read_image_dimensions(path)
  if not w or not h then
    return nil
  end
  local is_anim = M.is_gif_animated(path)
  local ext = path:match("%.([%w_]+)$")
  return {
    width = w,
    height = h,
    format = ext and ext:lower() or "unknown",
    is_animated = is_anim,
    is_complete = M.is_image_complete(path),
  }
end

--- Checks if an info file's content is corrupt or indicates conversion failure.
--- @param content string
--- @return boolean
function M.is_info_corrupt(content)
  if not content or content == "" then
    return true
  end
  local c = content:lower()
  return c:find("identify:", 1, true) ~= nil
    or c:find("improper", 1, true) ~= nil
    or c:find("error", 1, true) ~= nil
    or c:find("failed", 1, true) ~= nil
    or c:find("corrupt", 1, true) ~= nil
end

return M
