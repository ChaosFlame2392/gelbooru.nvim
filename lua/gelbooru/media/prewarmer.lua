-- lua/gelbooru/media/prewarmer.lua
-- Proactive background image and video thumbnail prewarming engine for local library
-- and preview graphics. Converts upcoming media into terminal graphics format
-- (snacks.image.convert) ahead of the cursor to eliminate on-demand conversion stalls.

local constants = require("gelbooru.core.constants")
local state = require("gelbooru.core.state")
local resolver = require("gelbooru.media.resolver")
local util = require("gelbooru.core.util")
local log = require("gelbooru.core.log")

local M = {}

M.active_conversions = {}
M.active_jobs = {}
M.prewarmed_cache = {}
M.queue = {}
M.max_concurrent = constants.PREWARM_MAX_CONCURRENT or 3
M.radius = constants.PREWARM_LOCAL_RADIUS or 5
M.sliding_window = constants.PREWARM_SLIDING_WINDOW or 10
M.last_dir = nil

local function get_convert_module()
  pcall(require, "snacks")
  local ok, convert = pcall(require, "snacks.image.convert")
  if ok and convert and type(convert.convert) == "function" then
    return convert
  end
  return nil
end

function M.has_converted_artifact(path)
  if not path or type(path) ~= "string" or path == "" then
    return false
  end
  local convert_mod = get_convert_module()
  if convert_mod and type(convert_mod.get_file) == "function" then
    local ok, file = pcall(convert_mod.get_file, path)
    if ok and file and type(file) == "string" and vim.fn.filereadable(file) == 1 then
      local sz = vim.fn.getfsize(file) or 0
      if sz > 0 then
        return true
      end
    end
  end
  return false
end

function M.is_prewarmed(path)
  if not path or type(path) ~= "string" or path == "" then
    return false
  end
  if M.prewarmed_cache[path] == true then
    return true
  end
  if M.has_converted_artifact(path) then
    M.prewarmed_cache[path] = true
    return true
  end
  return false
end

local function count_active_jobs()
  local count = 0
  for _ in pairs(M.active_jobs) do
    count = count + 1
  end
  return count
end

function M.drain_queue()
  if state.State.torn_down then
    M.queue = {}
    return
  end

  local active = count_active_jobs()
  while active < M.max_concurrent and #M.queue > 0 do
    local item = table.remove(M.queue, 1)
    if item then
      if item.post and not item.post._pending_delete then
        local path = item.post.file_url
        if not M.active_jobs[path] then
          if M.is_prewarmed(path) then
            if item.cb then pcall(item.cb, true) end
          else
            active = active + 1
            M.prewarm_post(item.post, item.cb)
          end
        end
      elseif item.path and not (item.post and item.post._pending_delete) then
        local path = item.path
        if not M.active_jobs[path] then
          if M.is_prewarmed(path) then
            if item.cb then pcall(item.cb, true) end
          else
            active = active + 1
            M._do_prewarm_file(path, item.cb)
          end
        end
      end
    end
  end
end

function M._do_prewarm_file(file_path, cb, convert_mod)
  convert_mod = convert_mod or get_convert_module()
  if not convert_mod then
    if cb then cb(true) end
    M.drain_queue()
    return nil
  end

  local job = {
    src = file_path,
    cb = cb,
  }
  M.active_jobs[file_path] = job

  local conv
  local ok, res = pcall(function()
    return convert_mod.convert({
      src = file_path,
      on_done = function(c)
        if state.State.torn_down then return end
        M.active_conversions[c] = nil
        M.active_jobs[file_path] = nil
        local err = c:error()
        local success = not err
        if success then
          M.prewarmed_cache[file_path] = true
        else
          log("WARN", "PREWARM", "Conversion failed for %s: %s", file_path, tostring(err))
        end
        if job.cb then
          pcall(job.cb, success, err)
        end
        job.conv = nil
        job.cb = nil
        M.drain_queue()
      end,
    })
  end)

  if not ok or not res then
    M.active_jobs[file_path] = nil
    if cb then cb(false, tostring(res)) end
    M.drain_queue()
    return nil
  end

  conv = res
  job.conv = conv
  M.active_conversions[conv] = true

  pcall(function()
    conv:run()
  end)

  return conv
end

function M.prewarm_file(file_path, cb, opts)
  if not file_path or type(file_path) ~= "string" or file_path == "" then
    if cb then cb(false, "Invalid file path") end
    return nil
  end

  if vim.fn.filereadable(file_path) == 0 then
    if cb then cb(false, "File not readable: " .. file_path) end
    return nil
  end

  local fsize = vim.fn.getfsize(file_path) or 0
  if fsize <= 0 then
    if cb then cb(false, "File empty: " .. file_path) end
    return nil
  end

  if M.is_prewarmed(file_path) then
    if cb then cb(true) end
    return nil
  end

  local existing_job = M.active_jobs[file_path]
  if existing_job then
    if cb then
      local orig_cb = existing_job.cb
      existing_job.cb = function(ok, err)
        if orig_cb then pcall(orig_cb, ok, err) end
        pcall(cb, ok, err)
      end
    end
    return existing_job.conv
  end

  local convert_mod = get_convert_module()
  if not convert_mod then
    if cb then cb(true) end
    return nil
  end

  -- Check if already queued
  for _, item in ipairs(M.queue) do
    if item.path == file_path or (item.post and item.post.file_url == file_path) then
      if cb then
        local orig_cb = item.cb
        item.cb = function(ok, err)
          if orig_cb then pcall(orig_cb, ok, err) end
          pcall(cb, ok, err)
        end
      end
      return nil
    end
  end

  if count_active_jobs() >= M.max_concurrent then
    table.insert(M.queue, {
      path = file_path,
      cb = cb,
      post_idx = opts and opts.post_idx,
    })
    return nil
  end

  return M._do_prewarm_file(file_path, cb, convert_mod)
end

function M.prewarm_post(post, cb)
  if not post or post._pending_delete then
    if cb then cb(false, "Post deleted or invalid") end
    return nil
  end

  if post.file_url and M.is_prewarmed(post.file_url) then
    if cb then cb(true) end
    return nil
  end

  local is_vid = resolver.is_video_post(post)
  if is_vid then
    local vpath = post.file_url
    if not vpath or vim.fn.filereadable(vpath) == 0 then
      if cb then cb(false, "Video file unreadable") end
      return nil
    end

    local thumb_dest = resolver.get_video_thumbnail_path(vpath, post.id)
    if vim.fn.filereadable(thumb_dest) == 1
      and (vim.fn.getfsize(thumb_dest) or 0) > constants.MIN_VALID_VIDEO_THUMB_BYTES
      and resolver.is_image_complete(thumb_dest) then
      if M.is_prewarmed(thumb_dest) then
        M.prewarmed_cache[thumb_dest] = true
        if post.file_url then
          M.prewarmed_cache[post.file_url] = true
        end
        if cb then cb(true) end
        return nil
      end
      return M.prewarm_file(thumb_dest, function(ok, err)
        if ok then
          M.prewarmed_cache[thumb_dest] = true
          if post.file_url then
            M.prewarmed_cache[post.file_url] = true
          end
        end
        if cb then cb(ok, err) end
      end)
    end

    local job = { post = post, is_video = true, cb = cb }
    M.active_jobs[vpath] = job

    resolver.extract_video_thumbnail(vpath, post, function(tpath)
      if state.State.torn_down then
        return
      end
      if post._pending_delete then
        M.active_jobs[vpath] = nil
        if cb then cb(false, "Cancelled") end
        M.drain_queue()
        return
      end

      if tpath and vim.fn.filereadable(tpath) == 1 then
        local conv = M.prewarm_file(tpath, function(ok, err)
          if state.State.torn_down then
            return
          end
          M.active_jobs[vpath] = nil
          if ok then
            M.prewarmed_cache[tpath] = true
            if post.file_url then
              M.prewarmed_cache[post.file_url] = true
            end
          end
          if cb then cb(ok, err) end
          M.drain_queue()
        end)
        job.conv = conv
      else
        M.active_jobs[vpath] = nil
        if cb then cb(false, "Video thumbnail extraction failed") end
        M.drain_queue()
      end
    end)
    return job
  else
    local path = post.file_url
    return M.prewarm_file(path, cb)
  end
end

function M.prewarm_posts(posts, cur_idx, dir_or_opts)
  posts = posts or state.State.posts
  if not posts or #posts == 0 then
    return
  end

  cur_idx = cur_idx or state.State.cur or 1
  local dir = 1
  local radius = constants.PREWARM_LOCAL_RADIUS or 5
  local include_cur = false

  if type(dir_or_opts) == "number" then
    dir = dir_or_opts
  elseif type(dir_or_opts) == "table" then
    dir = dir_or_opts.dir or 1
    radius = dir_or_opts.radius or radius
    include_cur = dir_or_opts.include_cur or false
  end

  local direction_reversed = (M.last_dir ~= nil and M.last_dir ~= dir)
  M.last_dir = dir

  local target_indices = {}
  local seen_indices = {}

  if include_cur and cur_idx >= 1 and cur_idx <= #posts then
    table.insert(target_indices, cur_idx)
    seen_indices[cur_idx] = true
  end

  if dir >= 0 then
    -- Forward targets
    for offset = 1, radius do
      local idx = cur_idx + offset
      if idx >= 1 and idx <= #posts and not seen_indices[idx] then
        table.insert(target_indices, idx)
        seen_indices[idx] = true
      end
    end
    -- Immediate reverse target
    local rev_idx = cur_idx - 1
    if rev_idx >= 1 and rev_idx <= #posts and not seen_indices[rev_idx] then
      table.insert(target_indices, rev_idx)
      seen_indices[rev_idx] = true
    end
  else
    -- Backward targets
    for offset = 1, radius do
      local idx = cur_idx - offset
      if idx >= 1 and idx <= #posts and not seen_indices[idx] then
        table.insert(target_indices, idx)
        seen_indices[idx] = true
      end
    end
    -- Immediate forward target
    local fwd_idx = cur_idx + 1
    if fwd_idx >= 1 and fwd_idx <= #posts and not seen_indices[fwd_idx] then
      table.insert(target_indices, fwd_idx)
      seen_indices[fwd_idx] = true
    end
  end

  -- Sliding-window bounded queue: prune items beyond window threshold
  local window = constants.PREWARM_SLIDING_WINDOW or 10
  M.prune_queue(cur_idx, window)

  -- Enqueue lookahead targets
  for _, idx in ipairs(target_indices) do
    local p = posts[idx]
    if p and not p._pending_delete then
      local path = p.file_url
      local already_queued = false
      for _, item in ipairs(M.queue) do
        if item.post_idx == idx or (path and item.path == path) then
          already_queued = true
          break
        end
      end

      local is_cached = (path and M.is_prewarmed(path))
      if not is_cached and resolver.is_video_post(p) then
        local vthumb = resolver.get_video_thumbnail_path(path, p.id)
        if vthumb and M.is_prewarmed(vthumb) then
          M.prewarmed_cache[path] = true
          is_cached = true
        end
      end

      if not already_queued and not M.active_jobs[path] and not is_cached then
        table.insert(M.queue, {
          post = p,
          post_idx = idx,
          path = path,
        })
      end
    end
  end

  -- Reorder pending queue items so tasks in the active direction (closest to cur_idx first)
  -- are processed ahead of tasks from the old direction
  if direction_reversed or dir_or_opts ~= nil then
    M.reorder_queue(cur_idx, dir)
  end

  M.drain_queue()
end

function M.reorder_queue(cur_idx, dir)
  if not M.queue or #M.queue <= 1 then
    return
  end
  cur_idx = cur_idx or (state.State and state.State.cur) or 1
  dir = dir or 1

  table.sort(M.queue, function(a, b)
    local idx_a = a.post_idx
    local idx_b = b.post_idx

    if not idx_a and not idx_b then
      return false
    elseif not idx_a then
      return false
    elseif not idx_b then
      return true
    end

    local rank_a = util.directional_rank(idx_a, cur_idx, dir)
    local rank_b = util.directional_rank(idx_b, cur_idx, dir)

    return rank_a < rank_b
  end)
end

function M.prune_queue(cur_idx, window)
  window = window or constants.PREWARM_SLIDING_WINDOW or 10
  cur_idx = cur_idx or (state.State and state.State.cur) or 1
  local pruned = {}
  for _, item in ipairs(M.queue) do
    if not item.post_idx or math.abs(item.post_idx - cur_idx) <= window then
      table.insert(pruned, item)
    else
      if item.cb then
        pcall(item.cb, false, "Pruned from queue: out of radius")
      end
    end
  end
  M.queue = pruned
end

function M.stop()
  M.last_dir = nil
  for _, item in ipairs(M.queue) do
    if item and item.cb then
      pcall(item.cb, false, "Cancelled")
    end
  end
  M.queue = {}

  for conv in pairs(M.active_conversions) do
    if conv and conv.abort then
      pcall(conv.abort, conv)
    end
  end
  M.active_conversions = {}

  for _, job in pairs(M.active_jobs) do
    if job and job.conv and job.conv.abort then
      pcall(job.conv.abort, job.conv)
    end
    if job then
      job.conv = nil
      job.cb = nil
    end
  end
  M.active_jobs = {}
end

function M.reset()
  M.stop()
  M.prewarmed_cache = {}
  M.last_dir = nil
end

function M.invalidate(file_path_or_id)
  if not file_path_or_id then return end
  local str = tostring(file_path_or_id)
  M.prewarmed_cache[str] = nil
  for k in pairs(M.prewarmed_cache) do
    if k:find(str, 1, true) then
      M.prewarmed_cache[k] = nil
    end
  end
end

return M
