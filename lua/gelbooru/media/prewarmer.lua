-- lua/gelbooru/media/prewarmer.lua
-- Lean facade delegating post asset readiness, lookahead prefetching,
-- sliding-window queue bounding, and lifecycle cancellation to net.download.
local constants = require("gelbooru.core.constants")
local state = require("gelbooru.core.state")
local inspector = require("gelbooru.media.inspector")
local download = require("gelbooru.net.download")

local M = {
  queue = {}, active_conversions = {}, active_jobs = {}, prewarmed_cache = {},
  last_dir = nil, max_concurrent = constants.PREWARM_MAX_CONCURRENT or 3,
  radius = constants.PREWARM_LOCAL_RADIUS or 5, sliding_window = constants.PREWARM_SLIDING_WINDOW or 10,
}

function M.ensure_ready(post, priority, cb) return download.ensure_ready(post, priority, cb) end

function M.prewarm_post(post, cb)
  if not post or post._pending_delete then if cb then cb(false, "Post deleted or invalid") end return nil end
  return download.ensure_ready(post, download.TIER_URGENT, function(path, err)
    if path then M.prewarmed_cache[path] = true; if post.file_url then M.prewarmed_cache[post.file_url] = true end end
    if cb then cb(path ~= nil, err) end
  end)
end

function M.prewarm_file(path, cb, _)
  if not path or path == "" then if cb then cb(false, "Invalid path") end return nil end
  if M.is_prewarmed(path) then if cb then cb(true) end return nil end
  if vim.fn.filereadable(path) == 0 then if cb then cb(false, "Unreadable") end return nil end
  local ok = inspector.is_image_complete(path)
  if ok then M.prewarmed_cache[path] = true end
  if cb then cb(ok, ok and nil or "Invalid image") end
  return nil
end

function M.prewarm_posts(posts, cur_idx, dir_or_opts)
  posts = posts or state.State.posts; if not posts or #posts == 0 then return end
  cur_idx = cur_idx or state.State.cur or 1
  local dir = type(dir_or_opts) == "number" and dir_or_opts or (type(dir_or_opts) == "table" and dir_or_opts.dir) or 1
  local radius = (type(dir_or_opts) == "table" and dir_or_opts.radius) or constants.PREWARM_LOCAL_RADIUS or 5
  M.last_dir = dir
  M.prune_queue(cur_idx, constants.PREWARM_SLIDING_WINDOW or 10)
  if type(dir_or_opts) == "table" and dir_or_opts.include_cur and posts[cur_idx] then download.ensure_ready(posts[cur_idx], download.TIER_URGENT) end
  local step = dir >= 0 and 1 or -1
  for offset = 1, radius do
    local p = posts[cur_idx + (step * offset)]
    if p and not p._pending_delete then download.ensure_ready(p, download.TIER_LOOKAHEAD) end
  end
  local rev_p = posts[cur_idx - step]
  if rev_p and not rev_p._pending_delete then download.ensure_ready(rev_p, download.TIER_LOOKAHEAD) end
end
M.schedule_lookahead = M.prewarm_posts

function M.prune_queue(cur_idx, window)
  window, cur_idx = window or constants.PREWARM_SLIDING_WINDOW or 10, cur_idx or (state.State and state.State.cur) or 1
  download.prune_out_of_radius(cur_idx, window)
  local pruned = {}
  for _, it in ipairs(M.queue or {}) do
    if not it.post_idx or math.abs(it.post_idx - cur_idx) <= window then table.insert(pruned, it)
    elseif it.cb then pcall(it.cb, false, "Pruned from queue: out of radius") end
  end
  M.queue = pruned
end
function M.reorder_queue(cur_idx, dir) download.reorder_prefetch_queue(cur_idx, dir) end
function M.stop()
  M.last_dir = nil
  for _, it in ipairs(M.queue or {}) do if it and it.cb then pcall(it.cb, false, "Cancelled") end end
  for conv in pairs(M.active_conversions or {}) do if conv and conv.abort then pcall(conv.abort, conv) end end
  for _, job in pairs(M.active_jobs or {}) do if job and job.conv and job.conv.abort then pcall(job.conv.abort, job.conv) end end
  M.queue, M.active_conversions, M.active_jobs = {}, {}, {}
end
M.cancel_prewarm, M.teardown = M.stop, M.stop; function M.reset() M.stop(); M.prewarmed_cache = {}; M.last_dir = nil end
function M.is_prewarmed(p) return p and p ~= "" and M.prewarmed_cache[p] == true or false end; M.has_converted_artifact = M.is_prewarmed
function M.invalidate(id)
  if not id then return end
  local str = tostring(id)
  M.prewarmed_cache[str] = nil
  for k in pairs(M.prewarmed_cache) do if k:find(str, 1, true) then M.prewarmed_cache[k] = nil end end
end
return M
