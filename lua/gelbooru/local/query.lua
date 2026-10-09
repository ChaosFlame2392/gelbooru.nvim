local M = {}

local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")

local function normalize_rating(r)
  if not r or r == "" or r == "?" then
    return nil
  end
  r = r:lower()
  if r == "g" or r == "general" then
    return "general"
  elseif r == "s" or r == "sensitive" then
    return "sensitive"
  elseif r == "q" or r == "questionable" then
    return "questionable"
  elseif r == "e" or r == "explicit" then
    return "explicit"
  end
  return r
end

M.normalize_rating = normalize_rating

--- Parses query string into directory path, tag string, and structured filter table.
--- Handles:
---   `local: <tags>`, `local:<dir> <tags>`, `local:<dir>`, `local:`,
---   quoted directories (e.g. `local:"/path with spaces" tag1`),
---   or bare directories/tags without `local:`.
---
--- Robust detection: If the first token after `local:` starts with `/`, `~`, `.`,
--- or `vim.fn.isdirectory(vim.fn.expand(token)) == 1`, treat it as `<dir>`.
--- Otherwise, treat it as part of `<tags>` in default `config.options.save_dir`.
---@param query_str string|nil
---@return string target_dir
---@return string tag_str
---@return table parsed_filter
function M.parse_query(query_str)
  local is_default = (not query_str or vim.trim(query_str) == "")
  if is_default then
    local def_dir = config.options.save_dir
    return def_dir, "", M.parse_tags("")
  end

  local s = vim.trim(query_str)
  local is_local_prefix = s:match("^[Ll][Oo][Cc][Aa][Ll]:") ~= nil
  local has_space_after_colon = s:match("^[Ll][Oo][Cc][Aa][Ll]:%s+") ~= nil
  local is_direct_local_dir = is_local_prefix and not has_space_after_colon

  local remainder = s:match("^[Ll][Oo][Cc][Aa][Ll]:%s*(.*)")
  if not remainder then
    remainder = s:match("^[Ll][Oo][Cc][Aa][Ll]:(.*)")
  end

  if not remainder then
    remainder = s
  end
  remainder = vim.trim(remainder)

  if remainder == "" then
    local def_dir = config.options.save_dir
    return def_dir, "", M.parse_tags("")
  end

  local first_token = nil
  local rest_str = ""

  local q = remainder:sub(1, 1)
  if q == '"' or q == "'" then
    first_token, rest_str = remainder:match('^"([^"]*)"%s*(.*)')
    if not first_token then
      first_token, rest_str = remainder:match("^'([^']*)'%s*(.*)")
    end
    if not first_token then
      -- Unclosed quote: capture the trailing unclosed quoted text as a search token
      first_token = remainder:sub(2)
      rest_str = ""
    end
  else
    first_token, rest_str = remainder:match("^(%S+)%s*(.*)")
  end

  if not first_token or first_token == "" then
    local def_dir = config.options.save_dir
    return def_dir, "", M.parse_tags("")
  end

  local expanded = vim.fn.expand(first_token)
  local starts_path_char = first_token:match("^[/%~%.]") ~= nil
  local is_dir = starts_path_char or (is_direct_local_dir and vim.fn.isdirectory(expanded) == 1)

  local target_dir = config.options.save_dir
  local tag_str = ""

  if is_dir then
    target_dir = first_token:gsub('^["\']', ""):gsub('["\']$', "")
    tag_str = vim.trim(rest_str or "")
  else
    target_dir = config.options.save_dir
    tag_str = remainder:gsub('^["\']', "")
  end

  local parsed_filter = M.parse_tags(tag_str)
  return target_dir, tag_str, parsed_filter
end

--- Parses tag string into structured conditions.
--- Supports:
---   - ratings: `rating:general` (`rating:g`), `rating:sensitive` (`rating:s`),
---              `rating:questionable` (`rating:q`), `rating:explicit` (`rating:e`),
---              and negative forms: `-rating:<r>`
---   - scores: `score:>=50`, `score:>10`, `score:<=5`, `score:<0`, `score:=20`, `score:20`
---   - artists: `artist:<name>`, `-artist:<name>`
---   - characters: `character:<name>`, `-character:<name>`
---   - ids: `id:<number>`
---   - negative tags: `-tag`
---   - positive plain tags: `tag`
---@param tag_str string|nil
---@return table filter
function M.parse_tags(tag_str)
  local filter = {
    positive_tags = {},
    negative_tags = {},
    ratings = {},
    scores = {},
    artists = {},
    characters = {},
    ids = {},
    sort = nil,
    raw = tag_str or "",
  }

  if not tag_str or tag_str == "" then
    return filter
  end

  for token in tag_str:gmatch("%S+") do
    -- Strip optional outer quotes around individual tags
    token = token:gsub('^["\']', ""):gsub('["\']$', "")

    -- Match sort: and order: directives
    local sort_key, sort_dir = token:match("^sort:([%w_]+):?([%w_]*)$")
    local order_val = token:match("^order:([%w_]+)$")
    if sort_key then
      if sort_key:lower() == "random" then
        filter.sort = { key = "random", dir = "asc" }
      else
        filter.sort = {
          key = sort_key:lower(),
          dir = (sort_dir:lower() == "asc") and "asc" or "desc",
        }
      end
    elseif order_val then
      local oval = order_val:lower()
      if oval == "asc" or oval == "desc" then
        if filter.sort then
          filter.sort.dir = oval
        else
          filter.sort = { key = "date", dir = oval }
        end
      else
        local o_key, o_dir = oval:match("^([%w]+)_([%w]+)$")
        if o_key and (o_dir == "asc" or o_dir == "desc") then
          filter.sort = { key = o_key, dir = o_dir }
        else
          filter.sort = {
            key = oval,
            dir = (filter.sort and filter.sort.dir) or "desc",
          }
        end
      end
    elseif token:lower() == "random" then
      filter.sort = { key = "random", dir = "asc" }
    else
      -- 1. Score: score:>=50, score:>10, score:<=5, score:<0, score:=20, score:20
      local score_op, score_val = token:match("^score:([><=]=?)(%-?%d+)$")
      if not score_op then
        score_val = token:match("^score:(%-?%d+)$")
        if score_val then
          score_op = "=="
        end
      elseif score_op == "=" then
        score_op = "=="
      end

      if score_op and score_val then
        table.insert(filter.scores, { op = score_op, val = tonumber(score_val) })
      else
        -- 2. Rating: rating:<r> or -rating:<r>
        local pos_rating = token:match("^rating:(%a+)$")
        local neg_rating = token:match("^%-rating:(%a+)$")
        if pos_rating then
          local canon = normalize_rating(pos_rating)
          if canon then
            table.insert(filter.ratings, { op = "eq", val = canon })
          end
        elseif neg_rating then
          local canon = normalize_rating(neg_rating)
          if canon then
            table.insert(filter.ratings, { op = "neq", val = canon })
          end
        else
          -- 3. Explicit artist modifier: artist:<name> or -artist:<name>
          local pos_artist = token:match("^artist:(.+)$")
          local neg_artist = token:match("^%-artist:(.+)$")
          if pos_artist then
            table.insert(filter.artists, { op = "eq", val = pos_artist:lower() })
          elseif neg_artist then
            table.insert(filter.artists, { op = "neq", val = neg_artist:lower() })
          else
            -- 4. Explicit character modifier: character:<name> or -character:<name>
            local pos_char = token:match("^character:(.+)$")
            local neg_char = token:match("^%-character:(.+)$")
            if pos_char then
              table.insert(filter.characters, { op = "eq", val = pos_char:lower() })
            elseif neg_char then
              table.insert(filter.characters, { op = "neq", val = neg_char:lower() })
            else
              -- 5. ID: id:<digits>
              local id_val = token:match("^id:(%d+)$")
              if id_val then
                table.insert(filter.ids, id_val)
              else
                -- 6. Negative tags: -tag
                local neg_tag = token:match("^%-(.+)$")
                if neg_tag and neg_tag ~= "" then
                  table.insert(filter.negative_tags, neg_tag:lower())
                else
                  -- 7. Plain positive tags
                  table.insert(filter.positive_tags, token:lower())
                end
              end
            end
          end
        end
      end
    end
  end

  return filter
end

--- Determines whether a post satisfies the given query filter.
---@param post table
---@param filter table|string
---@return boolean
function M.matches_post(post, filter)
  if not post then
    return false
  end
  if type(filter) == "string" then
    filter = M.parse_tags(filter)
  end
  if not filter then
    return true
  end

  -- 1. Post ID check
  if filter.ids and #filter.ids > 0 then
    local matched_id = false
    for _, id in ipairs(filter.ids) do
      if post.id and tostring(post.id) == tostring(id) then
        matched_id = true
        break
      end
    end
    if not matched_id then
      return false
    end
  end

  -- 2. Ratings check: rating:general (rating:g), -rating:explicit (-rating:e), etc.
  if filter.ratings and #filter.ratings > 0 then
    local pr = normalize_rating(post.rating)
    for _, rf in ipairs(filter.ratings) do
      if rf.op == "eq" then
        if not pr or pr ~= rf.val then
          return false
        end
      elseif rf.op == "neq" then
        if pr and pr == rf.val then
          return false
        end
      end
    end
  end

  -- 3. Scores check: score:>=50, score:>10, score:<=5, score:<0, score:=20, score:20
  if filter.scores and #filter.scores > 0 then
    local ps = tonumber(post.score) or 0
    for _, sf in ipairs(filter.scores) do
      if sf.op == ">=" and not (ps >= sf.val) then
        return false
      elseif sf.op == "<=" and not (ps <= sf.val) then
        return false
      elseif sf.op == ">" and not (ps > sf.val) then
        return false
      elseif sf.op == "<" and not (ps < sf.val) then
        return false
      elseif sf.op == "==" and not (ps == sf.val) then
        return false
      end
    end
  end

  -- Extract post match components
  -- Booru tags
  local post_tags = {}
  local raw_tags = post.tags
  if raw_tags and raw_tags ~= "" and raw_tags ~= "local" then
    for t in raw_tags:gmatch("%S+") do
      table.insert(post_tags, t:lower())
    end
  end

  -- Artists & Characters
  local post_artists = {}
  if post.artist and post.artist ~= "" then
    table.insert(post_artists, post.artist:lower())
  end
  local post_characters = {}
  if post.character and post.character ~= "" then
    table.insert(post_characters, post.character:lower())
  end

  local tags_by_name = state.State and state.State.tags_by_name
  if tags_by_name and #post_tags > 0 then
    for _, t in ipairs(post_tags) do
      local info = tags_by_name[t]
      if info then
        if tonumber(info.t) == 1 then
          table.insert(post_artists, t)
        elseif tonumber(info.t) == 4 then
          table.insert(post_characters, t)
        end
      end
    end
  end

  -- Filename tokens and stem
  local file_url = post.file_url or ""
  local stem = vim.fn.fnamemodify(file_url, ":t:r"):lower()
  local filename_tokens = {}
  for w in stem:gmatch("[^%s_%-%._%[%]%(\\)%{%}]+") do
    filename_tokens[w] = true
  end

  -- 4. Explicit artist filter
  if filter.artists and #filter.artists > 0 then
    for _, af in ipairs(filter.artists) do
      local matched_artist = false
      for _, a in ipairs(post_artists) do
        if a == af.val then
          matched_artist = true
          break
        end
        for w in a:gmatch("[^_]+") do
          if w == af.val then
            matched_artist = true
            break
          end
        end
        if matched_artist then
          break
        end
      end
      if af.op == "eq" and not matched_artist then
        return false
      elseif af.op == "neq" and matched_artist then
        return false
      end
    end
  end

  -- 5. Explicit character filter
  if filter.characters and #filter.characters > 0 then
    for _, cf in ipairs(filter.characters) do
      local matched_char = false
      for _, c in ipairs(post_characters) do
        if c == cf.val then
          matched_char = true
          break
        end
        for w in c:gmatch("[^_]+") do
          if w == cf.val then
            matched_char = true
            break
          end
        end
        if matched_char then
          break
        end
      end
      if cf.op == "eq" and not matched_char then
        return false
      elseif cf.op == "neq" and matched_char then
        return false
      end
    end
  end

  -- 6. Negative tags: -tag (must NOT match in tags, artists, characters, or filename tokens)
  if filter.negative_tags and #filter.negative_tags > 0 then
    for _, neg in ipairs(filter.negative_tags) do
      -- Booru tags
      for _, t in ipairs(post_tags) do
        if t == neg then
          return false
        end
        for w in t:gmatch("[^_]+") do
          if w == neg then
            return false
          end
        end
      end
      -- Artists
      for _, a in ipairs(post_artists) do
        if a == neg then
          return false
        end
        for w in a:gmatch("[^_]+") do
          if w == neg then
            return false
          end
        end
      end
      -- Characters
      for _, c in ipairs(post_characters) do
        if c == neg then
          return false
        end
        for w in c:gmatch("[^_]+") do
          if w == neg then
            return false
          end
        end
      end
      -- Filename tokens
      if filename_tokens[neg] or stem == neg then
        return false
      end
      if neg:find("[%s_%-%.]") and stem:find(neg, 1, true) then
        return false
      end
    end
  end

  -- 7. Plain tags: must match in post tags/artists/characters,
  --    OR fallback to normalized filename words for untagged / local items
  if filter.positive_tags and #filter.positive_tags > 0 then
    for _, pos in ipairs(filter.positive_tags) do
      local matched = false

      -- Match in booru tags
      for _, t in ipairs(post_tags) do
        if t == pos then
          matched = true
          break
        end
        for w in t:gmatch("[^_]+") do
          if w == pos then
            matched = true
            break
          end
        end
        if matched then
          break
        end
      end

      -- Match in artists
      if not matched then
        for _, a in ipairs(post_artists) do
          if a == pos then
            matched = true
            break
          end
          for w in a:gmatch("[^_]+") do
            if w == pos then
              matched = true
              break
            end
          end
          if matched then
            break
          end
        end
      end

      -- Match in characters
      if not matched then
        for _, c in ipairs(post_characters) do
          if c == pos then
            matched = true
            break
          end
          for w in c:gmatch("[^_]+") do
            if w == pos then
              matched = true
              break
            end
          end
          if matched then
            break
          end
        end
      end

      -- Fallback to normalized filename words
      if not matched then
        if filename_tokens[pos] or stem == pos then
          matched = true
        elseif pos:find("[%s_%-%.]") and stem:find(pos, 1, true) then
          matched = true
        end
      end

      if not matched then
        return false
      end
    end
  end

  return true
end

local function get_post_score(p)
  if p.score ~= nil then
    return tonumber(p.score) or 0
  end
  if p.id then
    local util = require("gelbooru.core.util")
    local meta_path = util.meta_cache_path(p.id)
    if meta_path then
      local cached = util.read_json(meta_path)
      if cached and cached.score ~= nil then
        p.score = tonumber(cached.score) or 0
        return p.score
      end
    end
  end
  return 0
end

local function get_post_mtime(p)
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

--- Sorts an array of posts by sort options table { key = "...", dir = "asc"|"desc" }.
--- Mutates and returns the array.
---@param posts table[]
---@param sort_opt table
---@return table[]
function M.sort_posts(posts, sort_opt)
  if not posts or #posts <= 1 or not sort_opt or not sort_opt.key then
    return posts or {}
  end

  local key = sort_opt.key:lower()
  local is_asc = (sort_opt.dir == "asc")

  if key == "random" then
    local uv = vim.uv or vim.loop
    math.randomseed(os.time() + (uv.hrtime() % 1000000))
    for i = #posts, 2, -1 do
      local j = math.random(i)
      posts[i], posts[j] = posts[j], posts[i]
    end
    return posts
  end

  if key == "score" then
    table.sort(posts, function(a, b)
      local sa = get_post_score(a)
      local sb = get_post_score(b)
      if sa ~= sb then
        if is_asc then
          return sa < sb
        else
          return sa > sb
        end
      end
      return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
    end)
    return posts
  end

  if key == "id" then
    table.sort(posts, function(a, b)
      local ida = tonumber(a.id) or 0
      local idb = tonumber(b.id) or 0
      if ida ~= idb then
        if is_asc then
          return ida < idb
        else
          return ida > idb
        end
      end
      return (a.file_url or "") < (b.file_url or "")
    end)
    return posts
  end

  if key == "date" or key == "mtime" then
    table.sort(posts, function(a, b)
      local ma = get_post_mtime(a)
      local mb = get_post_mtime(b)
      if ma ~= mb then
        if is_asc then
          return ma < mb
        else
          return ma > mb
        end
      end
      return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
    end)
    return posts
  end

  return posts
end

--- Filters an array of posts by tag/query filter, returning a new filtered array.
---@param posts table[]
---@param filter_or_tag_str table|string|nil
---@return table[] filtered_posts
function M.filter_posts(posts, filter_or_tag_str)
  if not posts or #posts == 0 then
    return {}
  end
  local filter = type(filter_or_tag_str) == "table" and filter_or_tag_str or M.parse_tags(filter_or_tag_str)

  local has_criteria = (filter.positive_tags and #filter.positive_tags > 0)
    or (filter.negative_tags and #filter.negative_tags > 0)
    or (filter.ratings and #filter.ratings > 0)
    or (filter.scores and #filter.scores > 0)
    or (filter.artists and #filter.artists > 0)
    or (filter.characters and #filter.characters > 0)
    or (filter.ids and #filter.ids > 0)

  local res = {}
  if not has_criteria then
    for i = 1, #posts do
      res[i] = posts[i]
    end
  else
    for _, p in ipairs(posts) do
      if M.matches_post(p, filter) then
        res[#res + 1] = p
      end
    end
  end

  if filter.sort then
    res = M.sort_posts(res, filter.sort)
  end

  return res
end

M.parse_local_query = M.parse_query
M.matches_query = M.matches_post

return M
