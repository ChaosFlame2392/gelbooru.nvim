-- lua/gelbooru/media/transcoder.lua
-- Asynchronous media transcoding adapter managing OS child processes (ffmpeg)
-- with deterministic process tracking, lifecycle cancellation, and thumbnail generation.

local config = require("gelbooru.core.config")
local constants = require("gelbooru.core.constants")
local state = require("gelbooru.core.state")
local inspector = require("gelbooru.media.inspector")
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
M.active_handles = M.active_ffmpeg_handles
M._ffmpeg_thumb_dests = {}
M._thumb_dests = M._ffmpeg_thumb_dests
M._aborted_handles = {}
M.clean_cache_hook = nil

--- Determines if post represents video media.
--- @param p table|nil
--- @return boolean
function M.is_video_post(p)
  if not p then
    return false
  end
  if p.is_video == true then
    return true
  end
  local url = p.file_url or ""
  local clean = url:match("^([^?#]+)") or url
  local ext = clean:match("%.([%w_]+)$")
  local lext = (ext and ext ~= "") and ext:lower() or "jpg"
  return M.VIDEO_EXTS[lext] == true
end

--- Formats the standard path for video thumbnail.
--- @param video_path string
--- @param post_id number|string|nil
--- @return string
function M.get_video_thumbnail_path(video_path, post_id)
  local cache_dir = config.options.cache_dir
  local id_key = (post_id and tostring(post_id) ~= "" and tostring(post_id) ~= "nil")
    and tostring(post_id)
    or (video_path and video_path:match("([^/]+)%.%w+$") or "temp")
  return string.format("%s/vthumb_%s.jpg", cache_dir, id_key)
end

--- Discovers saved video file in save_dir across supported extensions.
--- @param post_id number|string
--- @return string|nil
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

local function clean_target_cache(target)
  if M.clean_cache_hook and type(M.clean_cache_hook) == "function" then
    pcall(M.clean_cache_hook, target)
  end
end

--- Synchronously aborts all in-flight ffmpeg thumbnail processes and deletes partial files.
function M.abort_video_transcodes()
  local handles = {}
  local seen = {}
  for h in pairs(M.active_handles or {}) do
    handles[#handles + 1] = h
    seen[h] = true
  end
  for h in pairs(M.active_ffmpeg_handles or {}) do
    if not seen[h] then
      handles[#handles + 1] = h
      seen[h] = true
    end
  end
  for _, h in ipairs(handles) do
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
        if sz <= constants.MIN_VALID_VIDEO_THUMB_BYTES or not inspector.is_image_complete(tdest) then
          pcall(vim.fn.delete, tdest)
          clean_target_cache(tdest)
        end
      end
    end
  end
  for k in pairs(M.active_ffmpeg_handles or {}) do
    M.active_ffmpeg_handles[k] = nil
  end
  for k in pairs(M.active_handles or {}) do
    M.active_handles[k] = nil
  end
  for k in pairs(M._ffmpeg_thumb_dests or {}) do
    M._ffmpeg_thumb_dests[k] = nil
  end
end
M.abort_all_ffmpeg = M.abort_video_transcodes

--- Asynchronously extracts a single frame thumbnail from a video file.
--- @param video_path string: Local readable video file path
--- @param post_or_id table|number|string: Post object or ID
--- @param cb fun(thumb_path: string|nil): Callback on completion
--- @return table|nil: Process handle
function M.extract_video_thumbnail(video_path, post_or_id, cb)
  local post = type(post_or_id) == "table" and post_or_id or nil
  local post_id = post and post.id or post_or_id

  if post_id then
    local cached_thumb = M.get_video_thumbnail_path(video_path, post_id)
    if vim.fn.filereadable(cached_thumb) == 1 then
      if (vim.fn.getfsize(cached_thumb) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES and inspector.is_image_complete(cached_thumb) then
        if cb then cb(cached_thumb) end
        return
      else
        pcall(vim.fn.delete, cached_thumb)
        clean_target_cache(cached_thumb)
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
    if (vim.fn.getfsize(thumb_dest) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES and inspector.is_image_complete(thumb_dest) then
      if cb then cb(thumb_dest) end
      return
    else
      pcall(vim.fn.delete, thumb_dest)
      clean_target_cache(thumb_dest)
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
          if vim.fn.filereadable(thumb_dest) == 1 and ((vim.fn.getfsize(thumb_dest) or 0) <= constants.MIN_VALID_VIDEO_THUMB_BYTES or not inspector.is_image_complete(thumb_dest)) then
            pcall(vim.fn.delete, thumb_dest)
            clean_target_cache(thumb_dest)
          end
          return
        end
        if handle then
          M.active_ffmpeg_handles[handle] = nil
          if M._ffmpeg_thumb_dests then
            M._ffmpeg_thumb_dests[handle] = nil
          end
        end
        if out.code == 0 and vim.fn.filereadable(temp_part) == 1 and (vim.fn.getfsize(temp_part) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES and inspector.is_image_complete(temp_part) then
          local ren_ok = os.rename(temp_part, thumb_dest)
          if ren_ok then
            if cb then cb(thumb_dest) end
            return
          end
        end
        if vim.fn.filereadable(temp_part) == 1 then
          pcall(vim.fn.delete, temp_part)
        end
        if vim.fn.filereadable(thumb_dest) == 1 and ((vim.fn.getfsize(thumb_dest) or 0) <= constants.MIN_VALID_VIDEO_THUMB_BYTES or not inspector.is_image_complete(thumb_dest)) then
          pcall(vim.fn.delete, thumb_dest)
          clean_target_cache(thumb_dest)
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

--- Reserved extension point for looping animated video preview clips.
--- @param video_path string
--- @param opts table|nil
--- @param cb fun(dest_path: string|nil)
function M.transcode_animation_loop(video_path, opts, cb)
  if cb then
    cb(nil)
  end
end

--- Asynchronously extracts animation frames (e.g. from GIF) using ImageMagick coalesce.
--- Checks cache first; if present, invokes callback immediately.
--- If not cached, runs tool (magick or convert) asynchronously via vim.system,
--- tracking process handle in active_handles for deterministic SIGKILL abort.
--- @param media_path string: Local media file path
--- @param output_dir string: Destination directory for frame PNG files
--- @param cb fun(ok: boolean, frame_files: string[]|nil): Completion callback
--- @return table|nil: Process handle if spawned, or nil if already cached or failed
function M.coalesce_animation_frames(media_path, output_dir, cb)
  if not media_path or not output_dir or output_dir == "" then
    if cb then cb(false, nil) end
    return nil
  end

  local frame_0 = string.format("%s/frame_000.png", output_dir)
  if vim.fn.filereadable(frame_0) == 1 and (vim.fn.getfsize(frame_0) or 0) > 0 then
    local frame_files = vim.fn.glob(output_dir .. "/frame_*.png", false, true)
    table.sort(frame_files)
    if #frame_files > 0 then
      if cb then cb(true, frame_files) end
      return nil
    end
  end

  local tool = (vim.fn.executable("magick") == 1 and "magick") or (vim.fn.executable("convert") == 1 and "convert")
  if not tool then
    if cb then cb(false, nil) end
    return nil
  end

  vim.fn.mkdir(output_dir, "p")
  local out_pattern = output_dir .. "/frame_%03d.png"

  local handle = nil
  local done = false
  local spawn_ok, res = pcall(function()
    return vim.system({
      tool,
      media_path,
      "-coalesce",
      out_pattern,
    }, {}, function(out)
      done = true
      local was_aborted = (handle and M._aborted_handles and M._aborted_handles[handle])
        or (handle and handle._aborted)
      if handle then
        M.active_handles[handle] = nil
        if M.active_ffmpeg_handles then
          M.active_ffmpeg_handles[handle] = nil
        end
      end
      vim.schedule(function()
        if state.State.torn_down or was_aborted or (handle and handle._aborted) then
          if cb then cb(false, nil) end
          return
        end
        if out.code == 0 then
          local frame_files = vim.fn.glob(output_dir .. "/frame_*.png", false, true)
          table.sort(frame_files)
          if #frame_files > 0 then
            if cb then cb(true, frame_files) end
            return
          end
        end
        if cb then cb(false, nil) end
      end)
    end)
  end)

  if not spawn_ok or not res then
    if cb then cb(false, nil) end
    return nil
  end

  handle = res
  if handle and not done then
    M.active_handles[handle] = handle
    if M.active_ffmpeg_handles then
      M.active_ffmpeg_handles[handle] = handle
    end
  end
  return handle
end

return M
