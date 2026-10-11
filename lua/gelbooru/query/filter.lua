local parse = require("gelbooru.query.parse")
local pipeline = require("gelbooru.query.pipeline")
local sort = require("gelbooru.query.sort")
local state = require("gelbooru.core.state")

local M = {}

--- Determines whether a post satisfies the given query filter.
---@param post table
---@param filter table|string
---@return boolean
function M.matches_post(post, filter)
  if not post then
    return false
  end
  if type(filter) == "string" then
    filter = parse.parse_tags(filter)
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

  -- 2. Ratings check: rating:general (rating:g), -rating:explicit (-rating:e), ~rating:<r>, multi-ratings
  if filter.ratings and #filter.ratings > 0 then
    local pr = parse.normalize_rating(post.rating)
    local has_pos = false
    local pos_matched = false
    for _, rf in ipairs(filter.ratings) do
      if rf.op == "neq" then
        if pr and pr == rf.val then
          return false
        end
      elseif rf.op == "eq" then
        has_pos = true
        if pr and pr == rf.val then
          pos_matched = true
        end
      end
    end
    if has_pos and not pos_matched then
      return false
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

  local function matches_tag(candidate)
    -- Match in booru tags
    for _, t in ipairs(post_tags) do
      if t == candidate then
        return true
      end
      for w in t:gmatch("[^_]+") do
        if w == candidate then
          return true
        end
      end
    end

    -- Match in artists
    for _, a in ipairs(post_artists) do
      if a == candidate then
        return true
      end
      for w in a:gmatch("[^_]+") do
        if w == candidate then
          return true
        end
      end
    end

    -- Match in characters
    for _, c in ipairs(post_characters) do
      if c == candidate then
        return true
      end
      for w in c:gmatch("[^_]+") do
        if w == candidate then
          return true
        end
      end
    end

    -- Fallback to normalized filename words
    if filename_tokens[candidate] or stem == candidate then
      return true
    end
    if candidate:find("[%s_%-%.]") and stem:find(candidate, 1, true) then
      return true
    end

    return false
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
      if matches_tag(neg) then
        return false
      end
    end
  end

  -- 7. Plain positive tags: must match in post tags/artists/characters,
  --    OR fallback to normalized filename words for untagged / local items
  if filter.positive_tags and #filter.positive_tags > 0 then
    for _, pos in ipairs(filter.positive_tags) do
      if not matches_tag(pos) then
        return false
      end
    end
  end

  -- 8. OR tags: post must match at least one tag in filter.or_tags
  --    (across booru tags, artists, characters, and filename tokens)
  if filter.or_tags and #filter.or_tags > 0 then
    local or_matched = false
    for _, ot in ipairs(filter.or_tags) do
      if matches_tag(ot) then
        or_matched = true
        break
      end
    end
    if not or_matched then
      return false
    end
  end

  return true
end

M.matches_query = M.matches_post

--- Filters an array of posts by tag/query filter, returning a new filtered array.
---@param posts table[]
---@param filter_or_tag_str table|string|nil
---@return table[] filtered_posts
function M.filter_posts(posts, filter_or_tag_str)
  if not posts or #posts == 0 then
    return {}
  end
  local filter = type(filter_or_tag_str) == "table" and filter_or_tag_str or parse.parse_tags(filter_or_tag_str)

  local has_criteria = (filter.positive_tags and #filter.positive_tags > 0)
    or (filter.negative_tags and #filter.negative_tags > 0)
    or (filter.or_tags and #filter.or_tags > 0)
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

  if filter.pipeline_stages and #filter.pipeline_stages > 0 then
    res = pipeline.execute_pipeline(res, filter.pipeline_stages)
  elseif filter.sort then
    res = sort.sort_posts(res, filter.sort)
  end

  return res
end

return M
