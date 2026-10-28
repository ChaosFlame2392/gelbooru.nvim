local config = require("gelbooru.core.config")
local constants = require("gelbooru.core.constants")
local inspector = require("gelbooru.media.inspector")
local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")
local transcoder = require("gelbooru.media.transcoder")
local util = require("gelbooru.core.util")

local M = {}

M._active_request_id = 0

-- Connect transcoder clean cache hook to scrubber
transcoder.clean_cache_hook = function(target)
  M.clean_corrupt_snacks_cache(target)
end

-- Re-export pure binary inspector functions
M.read_image_dimensions = inspector.read_image_dimensions
M.is_image_complete = inspector.is_image_complete
M.is_info_corrupt = inspector.is_info_corrupt
M.is_gif_animated = inspector.is_gif_animated
M.inspect = inspector.inspect
M.parse_png_dimensions = inspector.parse_png_dimensions
M.parse_gif_dimensions = inspector.parse_gif_dimensions
M.parse_webp_dimensions = inspector.parse_webp_dimensions
M.parse_jpeg_dimensions = inspector.parse_jpeg_dimensions

-- Re-export isolated transcoder functions
M.VIDEO_EXTS = transcoder.VIDEO_EXTS
M.is_video_post = transcoder.is_video_post
M.get_video_thumbnail_path = transcoder.get_video_thumbnail_path
M.get_saved_video_path = transcoder.get_saved_video_path
M.abort_video_transcodes = transcoder.abort_video_transcodes
M.abort_all_ffmpeg = transcoder.abort_all_ffmpeg
M.extract_video_thumbnail = transcoder.extract_video_thumbnail
M.transcode_animation_loop = transcoder.transcode_animation_loop

function M.clear_snacks_image_cache()
  local ok, img_mod = pcall(require, "snacks.image.image")
  if ok and img_mod and type(img_mod.clear) == "function" then
    pcall(img_mod.clear)
  end
end
local clear_snacks_image_cache = M.clear_snacks_image_cache

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
    candidates = {}
    if p.sample_url and p.sample_url ~= "" then
      table.insert(candidates, p.sample_url)
    end
    if p.preview_url and p.preview_url ~= "" then
      table.insert(candidates, p.preview_url)
    end
    if p.file_url and p.file_url ~= "" then
      table.insert(candidates, p.file_url)
    end
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
  local ok_c, canvas = pcall(require, "gelbooru.ui.canvas")
  if ok_c and canvas and type(canvas.clean_cache) == "function" then
    return canvas.clean_cache(target)
  end
  return false
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
    end, { force = force, priority = constants.PRIORITY_PREVIEW })
  end

  try_candidate(1)
end

setmetatable(M, {
  __index = function(_, k)
    if k == "active_ffmpeg_handles" then
      return transcoder.active_ffmpeg_handles
    end
    if k == "_ffmpeg_thumb_dests" then
      return transcoder._ffmpeg_thumb_dests
    end
    if k == "_aborted_handles" then
      return transcoder._aborted_handles
    end
    return transcoder[k] or inspector[k]
  end,
  __newindex = function(_, k, v)
    if k == "active_ffmpeg_handles" then
      transcoder.active_ffmpeg_handles = v
      transcoder.active_handles = v
      return
    end
    if k == "_ffmpeg_thumb_dests" then
      transcoder._ffmpeg_thumb_dests = v
      transcoder._thumb_dests = v
      return
    end
    if k == "_aborted_handles" then
      transcoder._aborted_handles = v
      return
    end
    rawset(M, k, v)
  end,
})

return M
