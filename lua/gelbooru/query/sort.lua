local util = require("gelbooru.core.util")

local M = {}

--- Retrieves the numeric score of a post, checking in-memory post field first,
--- then falling back to disk metadata cache (<cache_dir>/meta_<id>.json).
---@param p table
---@return number
function M.get_post_score(p)
  if p.score ~= nil then
    return tonumber(p.score) or 0
  end
  if p.id then
    local meta_path = util.meta_cache_path(p.id)
    if meta_path then
      local cached = util.read_json(meta_path)
      if cached and cached.score ~= nil then
        p.score = tonumber(cached.score) or 0
        return p.score
      end
    end
  end
  p.score = 0
  return 0
end

--- Retrieves the modification timestamp (mtime) of a local post file,
--- caching it on `p._mtime`.
---@param p table
---@return number
function M.get_post_mtime(p)
  if p._mtime ~= nil then
    return p._mtime
  end
  local uv = vim.uv or vim.loop
  if p.file_url then
    local stat = uv.fs_stat(p.file_url)
    if stat and stat.mtime and stat.mtime.sec then
      p._mtime = stat.mtime.sec
      return p._mtime
    end
  end
  p._mtime = 0
  return 0
end

--- Sorts an array of posts by sort options table { key = "...", dir = "asc"|"desc" }
--- or cascading stages array { { key = "...", dir = "..." }, ... }.
--- Mutates and returns the array.
---@param posts table[]
---@param sort_opt table
---@return table[]
function M.sort_posts(posts, sort_opt)
  if not posts or #posts <= 1 or not sort_opt then
    return posts or {}
  end

  local stages = {}
  if sort_opt[1] and type(sort_opt[1]) == "table" then
    for _, st in ipairs(sort_opt) do
      if st.key then
        table.insert(stages, st)
      end
    end
  elseif sort_opt.key then
    table.insert(stages, { key = sort_opt.key, dir = sort_opt.dir or "desc" })
  end

  if #stages == 0 then
    return posts
  end

  if stages[1].key == "random" then
    util.shuffle(posts)
    return posts
  end

  table.sort(posts, function(a, b)
    for _, st in ipairs(stages) do
      local key = st.key:lower()
      local is_asc = (st.dir == "asc")

      if key == "score" then
        local sa = M.get_post_score(a)
        local sb = M.get_post_score(b)
        if sa ~= sb then
          if is_asc then
            return sa < sb
          else
            return sa > sb
          end
        end
      elseif key == "id" then
        local ida = tonumber(a.id) or 0
        local idb = tonumber(b.id) or 0
        if ida ~= idb then
          if is_asc then
            return ida < idb
          else
            return ida > idb
          end
        end
      elseif key == "date" or key == "mtime" then
        local ma = M.get_post_mtime(a)
        local mb = M.get_post_mtime(b)
        if ma ~= mb then
          if is_asc then
            return ma < mb
          else
            return ma > mb
          end
        end
      end
    end

    local ida = tonumber(a.id) or 0
    local idb = tonumber(b.id) or 0
    if ida ~= idb then
      return ida > idb
    end
    return (a.file_url or "") < (b.file_url or "")
  end)

  return posts
end

return M
