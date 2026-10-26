local config = require("gelbooru.core.config")
local constants = require("gelbooru.core.constants")
local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")

local M = {}

M.VIDEO_EXTS = {
  ["mp4"] = true,
  ["webm"] = true,
  ["avi"] = true,
  ["mov"] = true,
  ["mkv"] = true,
}

M.active_ffmpeg_handles = {}
M._active_request_id = 0

function M.clear_snacks_image_cache()
  local ok, img_mod = pcall(require, "snacks.image.image")
  if ok and img_mod and type(img_mod.clear) == "function" then
    pcall(img_mod.clear)
  end
end
local clear_snacks_image_cache = M.clear_snacks_image_cache

--------------------------------------------------------------------------------
-- Binary Image Parsing & Format Completion Validation
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- URL & Post Classification Helpers
--------------------------------------------------------------------------------

function M.file_ext_from_url(url)
  if not url or type(url) ~= "string" or url == "" then
    return "jpg"
  end
  local clean = url:match("^([^?#]+)") or url
  local ext = clean:match("%.([%w_]+)$")
  return (ext and ext ~= "") and ext:lower() or "jpg"
end

function M.is_video_post(p)
  if not p then
    return false
  end
  if p.is_video == true then
    return true
  end
  local ext = M.file_ext_from_url(p.file_url)
  return M.VIDEO_EXTS[ext] == true
end

function M.preview_source_name(p, url)
  if url and p and p.sample_url == url then
    return "sample"
  end
  if url and p and p.preview_url == url then
    return "thumbnail"
  end
  if url and p and p.file_url == url then
    return "original"
  end
  return "preview"
end

function M.is_in_save_dir(path)
  if not path or type(path) ~= "string" or path == "" then
    return false
  end
  local save_dir = config.options.save_dir and vim.fn.expand(config.options.save_dir)
  if not save_dir or save_dir == "" then
    return false
  end
  save_dir = save_dir:gsub("/+$", "")
  local prefix = save_dir .. "/"
  return path == save_dir or path:sub(1, #prefix) == prefix
end

function M.is_in_cache_dir(path)
  if not path or type(path) ~= "string" or path == "" then
    return false
  end
  local cache_dir = config.options.cache_dir and vim.fn.expand(config.options.cache_dir)
  if not cache_dir or cache_dir == "" then
    return false
  end
  cache_dir = cache_dir:gsub("/+$", "")
  local prefix = cache_dir .. "/"
  return path == cache_dir or path:sub(1, #prefix) == prefix
end

function M.get_saved_media_path(post_id, fallback_url)
  if not post_id or tostring(post_id) == "" or tostring(post_id) == "nil" then
    return nil
  end
  local State = state.State
  local del_key = tostring(post_id)
  if State and State.pending_deletions and State.pending_deletions[del_key] then
    return nil
  end

  local save_dir = config.options.save_dir and vim.fn.expand(config.options.save_dir)
  if not save_dir or save_dir == "" or vim.fn.isdirectory(save_dir) ~= 1 then
    return nil
  end

  local num_id = tonumber(post_id)
  local local_index = require("gelbooru.local.index")
  local saved_ext = num_id and State and State.saved_index and State.saved_index[num_id]
  if not saved_ext and local_index.update_saved_index then
    local idx = local_index.update_saved_index()
    saved_ext = num_id and idx and idx[num_id]
  end

  if saved_ext and saved_ext ~= "" then
    local candidate = string.format("%s/%s.%s", save_dir, tostring(post_id), saved_ext)
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end

  if fallback_url and fallback_url ~= "" then
    local ext = M.file_ext_from_url(fallback_url)
    if ext and ext ~= "" then
      local candidate = string.format("%s/%s.%s", save_dir, tostring(post_id), ext)
      if vim.fn.filereadable(candidate) == 1 then
        return candidate
      end
    end
  end

  local common_exts = { "jpg", "jpeg", "png", "gif", "webm", "mp4", "mkv" }
  for _, ext in ipairs(common_exts) do
    local candidate = string.format("%s/%s.%s", save_dir, tostring(post_id), ext)
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end

  return nil
end

function M.get_preview_targets(p, url_idx)
  if not p then
    return {}, nil
  end

  local cache_dir = config.options.cache_dir
  if p.is_local then
    if M.is_video_post(p) then
      local thumb_dest = M.get_video_thumbnail_path(p.file_url, p.id)
      return { thumb_dest }, thumb_dest
    end
    return { p.file_url }, p.file_url
  end

  -- Prioritize permanently downloaded media from save_dir over low-res preview cache
  if p.id and not p._pending_delete then
    local saved_path = M.get_saved_media_path(p.id, p.file_url)
    if saved_path then
      if M.is_video_post(p) or (saved_path and M.VIDEO_EXTS[util.file_ext(saved_path)]) then
        local thumb_dest = M.get_video_thumbnail_path(saved_path, p.id)
        return { thumb_dest }, thumb_dest
      end
      return { saved_path }, saved_path
    end
  end

  local urls, seen = {}, {}
  local candidates
  if M.is_video_post(p) then
    candidates = {}
    if p.preview_url and p.preview_url ~= "" then
      table.insert(candidates, p.preview_url)
    end
    if p.sample_url and p.sample_url ~= "" and not M.VIDEO_EXTS[util.file_ext(p.sample_url)] then
      table.insert(candidates, p.sample_url)
    end
  else
    candidates = { p.sample_url, p.preview_url, p.file_url }
  end
  for i = 1, #candidates do
    local u = candidates[i]
    if u and u ~= "" and not seen[u] then
      seen[u] = true
      urls[#urls + 1] = u
    end
  end
  if #urls == 0 then
    return {}, nil
  end
  local chosen_idx = math.max(1, math.min(url_idx or 1, #urls))
  local ext = M.file_ext_from_url(urls[chosen_idx])
  return urls, string.format("%s/prev_%s.%s", cache_dir, p.id, ext:lower())
end

function M.resolve_post_dimensions(p, opt_path)
  if not p then
    return nil, nil
  end
  if p.width and p.height and p.width > 0 and p.height > 0 then
    return p.width, p.height
  end
  local path = opt_path or p.file_url or p.sample_url or p.preview_url
  if not (path and type(path) == "string" and vim.fn.filereadable(path) == 1) then
    local _, dest = M.get_preview_targets(p)
    if dest and vim.fn.filereadable(dest) == 1 then
      path = dest
    end
  end
  if path and type(path) == "string" and vim.fn.filereadable(path) == 1 then
    local w, h = M.read_image_dimensions(path)
    if w and h and w > 0 and h > 0 then
      p.width = w
      p.height = h
      return w, h
    end
  end
  return p.width, p.height
end

--------------------------------------------------------------------------------
-- Video Thumbnailing & Transcoder Lifecycle
--------------------------------------------------------------------------------

function M.get_video_thumbnail_path(video_path, post_id)
  local cache_dir = config.options.cache_dir
  local id_key = (post_id and tostring(post_id) ~= "" and tostring(post_id) ~= "nil")
    and tostring(post_id)
    or (video_path and video_path:match("([^/]+)%.%w+$") or "temp")
  return string.format("%s/vthumb_%s.jpg", cache_dir, id_key)
end

function M.get_saved_video_path(post_id)
  if not post_id or tostring(post_id) == "" or tostring(post_id) == "nil" then
    return nil
  end
  local save_dir = config.options.save_dir and vim.fn.expand(config.options.save_dir)
  if not save_dir or save_dir == "" then
    return nil
  end
  local State = state.State
  local local_index = require("gelbooru.local.index")
  local num_id = tonumber(post_id)
  local saved_ext = num_id and State and State.saved_index and State.saved_index[num_id]
  if not saved_ext and local_index.update_saved_index then
    local idx = local_index.update_saved_index()
    saved_ext = num_id and idx and idx[num_id]
  end
  if saved_ext and M.VIDEO_EXTS[saved_ext] then
    local candidate = string.format("%s/%s.%s", save_dir, tostring(post_id), saved_ext)
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end
  for ext in pairs(M.VIDEO_EXTS) do
    local candidate = string.format("%s/%s.%s", save_dir, tostring(post_id), ext)
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end
  return nil
end

M._ffmpeg_thumb_dests = {}
M._aborted_handles = {}

function M.abort_video_transcodes()
  for h in pairs(M.active_ffmpeg_handles or {}) do
    if h then
      if M._aborted_handles then
        M._aborted_handles[h] = true
      end
      pcall(function() h._aborted = true end)
      if h.kill then
        pcall(h.kill, h, constants.SIGKILL or 9)
      end
      local tdest = (M._ffmpeg_thumb_dests and M._ffmpeg_thumb_dests[h]) or h.thumb_dest
      local tpart = (h and h.thumb_part) or (tdest and (tdest .. ".part"))
      if tpart and vim.fn.filereadable(tpart) == 1 then
        pcall(vim.fn.delete, tpart)
      end
      if tdest and vim.fn.filereadable(tdest) == 1 then
        local sz = vim.fn.getfsize(tdest) or 0
        if sz <= constants.MIN_VALID_VIDEO_THUMB_BYTES or not M.is_image_complete(tdest) then
          pcall(vim.fn.delete, tdest)
          M.clean_corrupt_snacks_cache(tdest)
        end
      end
    end
  end
  M.active_ffmpeg_handles = {}
  M._ffmpeg_thumb_dests = {}
end
M.abort_all_ffmpeg = M.abort_video_transcodes

function M.extract_video_thumbnail(video_path, post_or_id, cb)
  local post = type(post_or_id) == "table" and post_or_id or nil
  local post_id = post and post.id or post_or_id

  if post_id then
    local cached_thumb = M.get_video_thumbnail_path(video_path, post_id)
    if vim.fn.filereadable(cached_thumb) == 1 then
      if (vim.fn.getfsize(cached_thumb) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES and M.is_image_complete(cached_thumb) then
        if cb then cb(cached_thumb) end
        return
      else
        pcall(vim.fn.delete, cached_thumb)
        M.clean_corrupt_snacks_cache(cached_thumb)
      end
    end
  end

  local vpath = video_path
  if (not vpath or vim.fn.filereadable(vpath) == 0 or vpath:match("%.jpg$") or vpath:match("vthumb_")) and post_id then
    local found = nil
    if post and post.file_url and vim.fn.filereadable(post.file_url) == 1 then
      found = post.file_url
    end
    if not found then
      found = M.get_saved_video_path(post_id)
    end
    if found then
      vpath = found
    elseif vpath and (vpath:match("%.jpg$") or vpath:match("vthumb_")) then
      vpath = nil
    end
  end

  if not vpath or vpath:match("%.part$") or vpath:match("%.jpg$") or vpath:match("vthumb_")
    or vim.fn.filereadable(vpath) == 0 or (vim.fn.getfsize(vpath) or 0) <= 0 then
    if cb then cb(nil) end
    return
  end

  local thumb_dest = M.get_video_thumbnail_path(vpath, post_id)
  if vim.fn.filereadable(thumb_dest) == 1 then
    if (vim.fn.getfsize(thumb_dest) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES and M.is_image_complete(thumb_dest) then
      if cb then cb(thumb_dest) end
      return
    else
      pcall(vim.fn.delete, thumb_dest)
      M.clean_corrupt_snacks_cache(thumb_dest)
    end
  end

  if vim.fn.executable("ffmpeg") ~= 1 then
    if cb then cb(nil) end
    return
  end

  util.ensure(config.options.cache_dir)

  local temp_part = thumb_dest .. ".part"
  local handle = nil
  local done = false
  local spawn_ok, res = pcall(function()
    return vim.system({
      "ffmpeg",
      "-ss",
      "00:00:01",
      "-i",
      vpath,
      "-frames:v",
      "1",
      "-q:v",
      "2",
      temp_part,
      "-y",
    }, {}, function(out)
      done = true
      local was_aborted = (handle and M._aborted_handles and M._aborted_handles[handle])
        or (handle and handle._aborted)
      if handle then
        M.active_ffmpeg_handles[handle] = nil
        if M._ffmpeg_thumb_dests then
          M._ffmpeg_thumb_dests[handle] = nil
        end
      end
      vim.schedule(function()
        if state.State.torn_down or was_aborted or (handle and handle._aborted) then
          if vim.fn.filereadable(temp_part) == 1 then
            pcall(vim.fn.delete, temp_part)
          end
          if vim.fn.filereadable(thumb_dest) == 1 and ((vim.fn.getfsize(thumb_dest) or 0) <= constants.MIN_VALID_VIDEO_THUMB_BYTES or not M.is_image_complete(thumb_dest)) then
            pcall(vim.fn.delete, thumb_dest)
            M.clean_corrupt_snacks_cache(thumb_dest)
          end
          return
        end
        if handle then
          M.active_ffmpeg_handles[handle] = nil
          if M._ffmpeg_thumb_dests then
            M._ffmpeg_thumb_dests[handle] = nil
          end
        end
        if out.code == 0 and vim.fn.filereadable(temp_part) == 1 and (vim.fn.getfsize(temp_part) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES and M.is_image_complete(temp_part) then
          local ren_ok = os.rename(temp_part, thumb_dest)
          if ren_ok then
            if cb then cb(thumb_dest) end
            return
          end
        end
        if vim.fn.filereadable(temp_part) == 1 then
          pcall(vim.fn.delete, temp_part)
        end
        if vim.fn.filereadable(thumb_dest) == 1 and ((vim.fn.getfsize(thumb_dest) or 0) <= constants.MIN_VALID_VIDEO_THUMB_BYTES or not M.is_image_complete(thumb_dest)) then
          pcall(vim.fn.delete, thumb_dest)
          M.clean_corrupt_snacks_cache(thumb_dest)
        end
        if cb then cb(nil) end
      end)
    end)
  end)

  if not spawn_ok or not res then
    if cb then cb(nil) end
    return nil
  end

  handle = res
  pcall(function()
    handle.thumb_dest = thumb_dest
    handle.thumb_part = temp_part
  end)
  if M._ffmpeg_thumb_dests then
    M._ffmpeg_thumb_dests[handle] = thumb_dest
  end
  if handle and not done then
    M.active_ffmpeg_handles[handle] = handle
  end
  return handle
end

--------------------------------------------------------------------------------
-- Snacks Cache Forensics & Corruption Scrubbing
--------------------------------------------------------------------------------

function M.get_snacks_cache_dir()
  if M._snacks_cache_dir and type(M._snacks_cache_dir) == "string" and M._snacks_cache_dir ~= "" then
    return M._snacks_cache_dir
  end
  if _G.Snacks and _G.Snacks.image and _G.Snacks.image.config and type(_G.Snacks.image.config.cache) == "string" and _G.Snacks.image.config.cache ~= "" then
    return _G.Snacks.image.config.cache
  end
  local ok, cache_dir = pcall(vim.fn.stdpath, "cache")
  local snacks_cache = (ok and type(cache_dir) == "string" and cache_dir ~= "") and (cache_dir .. "/snacks/image")
    or vim.fn.expand("~/.cache/nvim/snacks/image")
  if vim.fn.isdirectory(snacks_cache) == 0 then
    local fallback = vim.fn.expand("~/.cache/nvim/snacks/image")
    if vim.fn.isdirectory(fallback) == 1 then
      snacks_cache = fallback
    end
  end
  return snacks_cache
end

local function sanitize_base_candidates(name)
  local base = vim.fn.fnamemodify(name, ":t:r")
  local sanitized_base = base:gsub("[^%w%.]+", "-")
  local bases = { base }
  if sanitized_base ~= base then
    table.insert(bases, sanitized_base)
  end
  return bases
end

local function is_info_corrupt(content)
  if not content or content == "" then
    return true
  end
  local c = content:lower()
  return c:find("identify:") ~= nil
    or c:find("improper") ~= nil
    or c:find("error") ~= nil
    or c:find("failed") ~= nil
    or c:find("corrupt") ~= nil
end
M.is_info_corrupt = is_info_corrupt

function M.find_snacks_cache_candidates(target)
  if not target or target == "" or tostring(target) == "nil" then
    return {}
  end
  local snacks_cache = M.get_snacks_cache_dir()
  if vim.fn.isdirectory(snacks_cache) ~= 1 then
    return {}
  end

  local str_target = tostring(target)
  local candidate_files = {}
  local seen = {}
  local function add_cand(f)
    if f and f ~= "" and not seen[f] then
      seen[f] = true
      table.insert(candidate_files, f)
    end
  end

  local is_url = str_target:match("^https?://") ~= nil
  local is_path = not is_url and (str_target:find("/") ~= nil or vim.fn.filereadable(str_target) == 1)

  if is_url then
    local clean_url = str_target:match("^([^?#]+)") or str_target
    local bases = sanitize_base_candidates(clean_url)

    local ok_sha, hash = pcall(vim.fn.sha256, clean_url .. "0")
    if ok_sha and hash then
      local h8 = hash:sub(1, 8)
      for _, b in ipairs(bases) do
        local prefix = h8 .. "-" .. b
        for _, f in ipairs(vim.fn.glob(snacks_cache .. "/" .. prefix .. "*", false, true)) do
          add_cand(f)
        end
      end
    end
    for _, b in ipairs(bases) do
      for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*-" .. b .. ".*", false, true)) do
        add_cand(f)
      end
      for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*-" .. b .. "-*.*", false, true)) do
        add_cand(f)
      end
      for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*" .. b .. "*", false, true)) do
        add_cand(f)
      end
    end
  elseif is_path then
    local norm_src = vim.fs.normalize(vim.fn.fnamemodify(str_target, ":p"))
    local bases = sanitize_base_candidates(norm_src)

    local ok_sha, hash = pcall(vim.fn.sha256, norm_src .. "0")
    if ok_sha and hash then
      local h8 = hash:sub(1, 8)
      for _, b in ipairs(bases) do
        local prefix = h8 .. "-" .. b
        for _, f in ipairs(vim.fn.glob(snacks_cache .. "/" .. prefix .. "*", false, true)) do
          add_cand(f)
        end
      end
    end
    for _, b in ipairs(bases) do
      for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*-" .. b .. ".*", false, true)) do
        add_cand(f)
      end
      for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*-" .. b .. "-*.*", false, true)) do
        add_cand(f)
      end
    end
  else
    local bases = sanitize_base_candidates(str_target)

    if str_target:match("^%d+$") then
      local pattern = "%f[%d]" .. str_target .. "%f[%D]"
      for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*", false, true)) do
        if f:find(pattern) then
          add_cand(f)
        end
      end
    else
      for _, b in ipairs(bases) do
        for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*-" .. b .. ".*", false, true)) do
          add_cand(f)
        end
        for _, f in ipairs(vim.fn.glob(snacks_cache .. "/*" .. b .. "*", false, true)) do
          add_cand(f)
        end
      end
    end
  end

  return candidate_files
end

function M.clean_corrupt_snacks_cache(target)
  if not target or target == "" or tostring(target) == "nil" then
    return
  end
  local candidate_files = M.find_snacks_cache_candidates(target)
  local any_cleaned = false
  for _, f in ipairs(candidate_files) do
    if vim.fn.filereadable(f) == 1 and not M.is_in_save_dir(f) then
      local size = vim.fn.getfsize(f) or 0
      local is_corrupt = false
      if size <= 0 then
        is_corrupt = true
      elseif f:match("%.info$") then
        local lines = vim.fn.readfile(f)
        local content = vim.trim(table.concat(lines or {}, " "))
        if is_info_corrupt(content) then
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

        if not is_corrupt then
          local w, h = M.read_image_dimensions(f)
          if not (w and h and w > 0 and h > 0) then
            is_corrupt = true
          end
        end

        if not is_corrupt and not M.is_image_complete(f) then
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
            if is_info_corrupt(content) then
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
          if vim.fn.filereadable(info_file) == 1 and not M.is_in_save_dir(info_file) then
            pcall(vim.fn.delete, info_file)
          end
        else
          local img_file = f:gsub("%.info$", "")
          if vim.fn.filereadable(img_file) == 1 and not M.is_in_save_dir(img_file) then
            local isz = vim.fn.getfsize(img_file) or 0
            if isz <= 0 then
              pcall(vim.fn.delete, img_file)
            else
              local iw, ih = M.read_image_dimensions(img_file)
              if not (iw and ih and iw > 0 and ih > 0) or not M.is_image_complete(img_file) then
                pcall(vim.fn.delete, img_file)
              end
            end
          end
        end
      end
    end
  end

  if any_cleaned then
    clear_snacks_image_cache()
  end
end

function M.clear_snacks_cache_for(post_id_or_path)
  if not post_id_or_path or tostring(post_id_or_path) == "" or tostring(post_id_or_path) == "nil" then
    return
  end
  local candidate_files = M.find_snacks_cache_candidates(post_id_or_path)
  local any_deleted = false
  for _, f in ipairs(candidate_files) do
    if vim.fn.filereadable(f) == 1 and not M.is_in_save_dir(f) then
      pcall(vim.fn.delete, f)
      any_deleted = true
    end
  end

  local str_target = tostring(post_id_or_path)
  local num_id = str_target:match("(%d+)")
  if num_id then
    local config_cache = config.options.cache_dir
    local vthumb = string.format("%s/vthumb_%s.jpg", config_cache, num_id)
    if vim.fn.filereadable(vthumb) == 1 and not M.is_in_save_dir(vthumb) then
      pcall(vim.fn.delete, vthumb)
      any_deleted = true
    end
  end

  M.clean_corrupt_snacks_cache(post_id_or_path)
  if any_deleted then
    clear_snacks_image_cache()
  end
end

function M.clear_cache(post_id_or_path)
  if not post_id_or_path or tostring(post_id_or_path) == "" or tostring(post_id_or_path) == "nil" then
    return
  end

  local str_target = tostring(post_id_or_path)
  local num_id = str_target:match("(%d+)")
  local cache_dir = config.options.cache_dir

  if num_id and cache_dir and vim.fn.isdirectory(cache_dir) == 1 then
    for _, f in ipairs(vim.fn.glob(cache_dir .. "/prev_" .. num_id .. ".*", false, true)) do
      if not M.is_in_save_dir(f) then
        pcall(vim.fn.delete, f)
      end
    end
    local vthumb = string.format("%s/vthumb_%s.jpg", cache_dir, num_id)
    if vim.fn.filereadable(vthumb) == 1 and not M.is_in_save_dir(vthumb) then
      pcall(vim.fn.delete, vthumb)
    end
  end

  if M.is_in_cache_dir(str_target) and vim.fn.filereadable(str_target) == 1 and not M.is_in_save_dir(str_target) then
    pcall(vim.fn.delete, str_target)
  end

  M.clear_snacks_cache_for(post_id_or_path)
end

--------------------------------------------------------------------------------
-- Public Seam: abort_active and resolve
--------------------------------------------------------------------------------

function M.abort_active()
  M._active_request_id = (M._active_request_id or 0) + 1
  M.abort_video_transcodes()
  local ok_c, canvas = pcall(require, "gelbooru.ui.canvas")
  if ok_c and canvas and type(canvas.close) == "function" then
    pcall(canvas.close)
  end
end

local function handle_video_thumb_result(req_id, post, fallback_path, tpath, callback)
  if req_id ~= M._active_request_id then
    return
  end
  if tpath and vim.fn.filereadable(tpath) == 1 and M.is_image_complete(tpath) then
    M.clean_corrupt_snacks_cache(tpath)
    local w, h = M.resolve_post_dimensions(post, tpath)
    callback({
      path = tpath,
      is_video = true,
      is_thumbnail = true,
      width = w,
      height = h,
    })
  else
    callback({
      path = fallback_path,
      is_video = true,
      is_thumbnail = false,
      width = post.width,
      height = post.height,
    })
  end
end

function M.resolve(post, opts, callback)
  if not callback then
    return
  end
  if not post then
    callback(nil, "No post provided")
    return
  end

  local req_id = (M._active_request_id or 0) + 1
  M._active_request_id = req_id

  local force = opts and opts.force == true
  if force then
    M.clear_cache(post.id or post.file_url)
  end

  local is_vid = M.is_video_post(post)

  -- Fast path for video posts: if existing valid vthumb in cache, resolve immediately without spawning processes
  if is_vid and not force then
    local vthumb = M.get_video_thumbnail_path(post.file_url, post.id)
    if vim.fn.filereadable(vthumb) == 1
      and (vim.fn.getfsize(vthumb) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES
      and M.is_image_complete(vthumb) then
      M.clean_corrupt_snacks_cache(vthumb)
      local w, h = M.resolve_post_dimensions(post, vthumb)
      callback({
        path = vthumb,
        is_video = true,
        is_thumbnail = true,
        width = w,
        height = h,
      })
      return
    end
  end

  -- 1. Local post resolution
  if post.is_local then
    if is_vid then
      local thumb_dest = M.get_video_thumbnail_path(post.file_url, post.id)
      if not force and vim.fn.filereadable(thumb_dest) == 1
        and (vim.fn.getfsize(thumb_dest) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES
        and M.is_image_complete(thumb_dest) then
        M.clean_corrupt_snacks_cache(thumb_dest)
        local w, h = M.resolve_post_dimensions(post, thumb_dest)
        callback({
          path = thumb_dest,
          is_video = true,
          is_thumbnail = true,
          width = w,
          height = h,
        })
        return
      end

      M.extract_video_thumbnail(post.file_url, post, function(tpath)
        handle_video_thumb_result(req_id, post, post.file_url, tpath, callback)
      end)
      return
    end

    -- Local image
    local path = post.file_url
    if not (path and type(path) == "string" and vim.fn.filereadable(path) == 1) then
      callback(nil, "Local file not readable: " .. tostring(path))
      return
    end
    if not M.is_image_complete(path) then
      callback(nil, "Local file corrupted or incomplete: " .. tostring(path))
      return
    end
    M.clean_corrupt_snacks_cache(path)
    local w, h = M.resolve_post_dimensions(post, path)
    callback({
      path = path,
      is_video = false,
      is_thumbnail = false,
      width = w,
      height = h,
    })
    return
  end

  -- 2. Saved post in save_dir (for remote posts)
  if post.id and not post._pending_delete then
    local saved_path = M.get_saved_media_path(post.id, post.file_url)
    if saved_path and vim.fn.filereadable(saved_path) == 1 then
      local saved_ext = util.file_ext(saved_path)
      if is_vid or M.VIDEO_EXTS[saved_ext] then
        local thumb_dest = M.get_video_thumbnail_path(saved_path, post.id)
        if not force and vim.fn.filereadable(thumb_dest) == 1
          and (vim.fn.getfsize(thumb_dest) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES
          and M.is_image_complete(thumb_dest) then
          M.clean_corrupt_snacks_cache(thumb_dest)
          local w, h = M.resolve_post_dimensions(post, thumb_dest)
          callback({
            path = thumb_dest,
            is_video = true,
            is_thumbnail = true,
            width = w,
            height = h,
          })
          return
        end

        M.extract_video_thumbnail(saved_path, post, function(tpath)
          handle_video_thumb_result(req_id, post, saved_path, tpath, callback)
        end)
        return
      else
        -- Saved image
        if M.is_image_complete(saved_path) then
          M.clean_corrupt_snacks_cache(saved_path)
          local w, h = M.resolve_post_dimensions(post, saved_path)
          callback({
            path = saved_path,
            is_video = false,
            is_thumbnail = false,
            width = w,
            height = h,
          })
          return
        end
      end
    end
  end

  -- 3. Online remote candidates: sample_url -> preview_url -> file_url
  local candidates = {}
  local seen = {}
  local function add_cand(u)
    if u and type(u) == "string" and u ~= "" and not seen[u] then
      seen[u] = true
      table.insert(candidates, u)
    end
  end

  if is_vid then
    if post.sample_url and not M.VIDEO_EXTS[M.file_ext_from_url(post.sample_url)] then
      add_cand(post.sample_url)
    end
    add_cand(post.preview_url)
    if #candidates == 0 then
      add_cand(post.sample_url)
      add_cand(post.file_url)
    end
  else
    add_cand(post.sample_url)
    add_cand(post.preview_url)
    add_cand(post.file_url)
  end

  if #candidates == 0 then
    callback(nil, "No candidate URLs for post")
    return
  end

  local cache_dir = config.options.cache_dir
  util.ensure(cache_dir)

  local function try_candidate(idx)
    if req_id ~= M._active_request_id then
      return
    end
    if idx > #candidates then
      callback(nil, "All candidate URLs failed to resolve")
      return
    end

    local url = candidates[idx]
    local ext = M.file_ext_from_url(url)
    local dest = string.format("%s/prev_%s.%s", cache_dir, tostring(post.id or "temp"), ext:lower())

    if not force and vim.fn.filereadable(dest) == 1 then
      if M.VIDEO_EXTS[ext:lower()] then
        if (vim.fn.getfsize(dest) or 0) > 0 then
          M.extract_video_thumbnail(dest, post, function(tpath)
            handle_video_thumb_result(req_id, post, dest, tpath, callback)
          end)
          return
        else
          pcall(vim.fn.delete, dest)
          M.clean_corrupt_snacks_cache(dest)
        end
      elseif (vim.fn.getfsize(dest) or 0) > 0 and M.is_image_complete(dest) then
        M.clean_corrupt_snacks_cache(dest)
        local w, h = M.resolve_post_dimensions(post, dest)
        local is_thumb = (url ~= post.file_url)
        callback({
          path = dest,
          is_video = is_vid,
          is_thumbnail = is_thumb,
          width = w,
          height = h,
        })
        return
      else
        pcall(vim.fn.delete, dest)
        M.clean_corrupt_snacks_cache(dest)
      end
    end

    local download = require("gelbooru.net.download")
    download.download_async(url, dest, function(ok)
      if req_id ~= M._active_request_id then
        return
      end

      if ok and vim.fn.filereadable(dest) == 1 then
        if M.VIDEO_EXTS[ext:lower()] then
          M.extract_video_thumbnail(dest, post, function(tpath)
            handle_video_thumb_result(req_id, post, dest, tpath, callback)
          end)
          return
        elseif M.is_image_complete(dest) then
          M.clean_corrupt_snacks_cache(dest)
          local w, h = M.resolve_post_dimensions(post, dest)
          local is_thumb = (url ~= post.file_url)
          callback({
            path = dest,
            is_video = is_vid,
            is_thumbnail = is_thumb,
            width = w,
            height = h,
          })
          return
        end
      end

      if vim.fn.filereadable(dest) == 1 and not M.is_in_save_dir(dest) then
        pcall(vim.fn.delete, dest)
      end
      M.clean_corrupt_snacks_cache(dest)
      try_candidate(idx + 1)
    end, { force = force })
  end

  try_candidate(1)
end

return M
