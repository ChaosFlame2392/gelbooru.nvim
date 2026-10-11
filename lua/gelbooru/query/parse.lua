local config = require("gelbooru.core.config")

local M = {}

--- Normalizes booru rating abbreviations and full names to canonical string:
--- "g" / "general" -> "general"
--- "s" / "sensitive" -> "sensitive"
--- "q" / "questionable" -> "questionable"
--- "e" / "explicit" -> "explicit"
---@param r string|nil
---@return string|nil
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

--- Tokenizes raw query string into token objects, preserving quotes and `local:"..."` prefixes.
---@param str string
---@return table[]
local function tokenize_query(str)
  local tokens = {}
  local i = 1
  local len = #str
  while i <= len do
    while i <= len and str:sub(i, i):match("%s") do
      i = i + 1
    end
    if i > len then break end

    -- Check if token starts with local: followed by quote, e.g. local:"/path"
    local local_match_quote = str:sub(i):match("^[Ll][Oo][Cc][Aa][Ll]:([\"'])")
    if local_match_quote then
      local q = local_match_quote
      local start_content = i + 7 -- after local:"
      local j = start_content
      while j <= len and str:sub(j, j) ~= q do
        j = j + 1
      end
      local content = str:sub(start_content, j - 1)
      table.insert(tokens, { is_local_dir = true, text = content, quoted = true, raw = str:sub(i, math.min(j, len)) })
      i = j + 1
    else
      local c = str:sub(i, i)
      if c == '"' or c == "'" then
        local q = c
        local j = i + 1
        while j <= len and str:sub(j, j) ~= q do
          j = j + 1
        end
        local content = str:sub(i + 1, j - 1)
        table.insert(tokens, { text = content, quoted = true, raw = str:sub(i, math.min(j, len)) })
        i = j + 1
      else
        local j = i
        while j <= len and not str:sub(j, j):match("%s") do
          j = j + 1
        end
        local token = str:sub(i, j - 1)
        table.insert(tokens, { text = token, quoted = false, raw = token })
        i = j
      end
    end
  end
  return tokens
end

M.tokenize_query = tokenize_query

--- Checks if token looks like a directory path or exists as a directory on disk.
---@param token_str string|nil
---@return boolean
local function is_dir_token(token_str)
  if not token_str or token_str == "" then return false end
  local clean = token_str:gsub('^["\']', ""):gsub('["\']$', "")
  if clean == "" then return false end
  local starts_path = clean:match("^/") ~= nil
    or clean:match("^%~[/\\]") ~= nil
    or clean == "~"
    or clean:match("^%.[/\\]") ~= nil
    or clean == "."
    or clean == ".."
  if starts_path then
    return true
  end
  local expanded = vim.fn.expand(clean)
  return vim.fn.isdirectory(expanded) == 1
end

M.is_dir_token = is_dir_token

--- Parses range expressions:
---   "50.." or "50-" -> offset=50, limit=nil, is_range=true
---   "..100" -> offset=1, limit=100, is_range=true
---   "10..50" or "10-50" -> offset=10, limit=50
---   "50" -> offset=nil, limit=50
---@param val string|nil
---@return number|nil offset
---@return number|nil limit
---@return boolean|nil is_range
local function parse_limit_or_range(val)
  if not val then return nil, nil end
  local open_o = val:match("^(%d+)%.%.$") or val:match("^(%d+)%-$")
  if open_o then
    return tonumber(open_o), nil, true
  end
  local open_l = val:match("^%.%.(%d+)$")
  if open_l then
    return 1, tonumber(open_l), true
  end
  local o, l = val:match("^(%d+)%.%.(%d+)$")
  if not o then
    o, l = val:match("^(%d+)%-(%d+)$")
  end
  if o and l then
    local no, nl = tonumber(o), tonumber(l)
    if no and nl and no > nl then
      no, nl = nl, no
    end
    return no, nl
  end
  local num = val:match("^(%d+)$")
  if num then
    return nil, tonumber(num)
  end
  return nil, nil
end

M.parse_limit_or_range = parse_limit_or_range

--- Parses a single pipeline sort, order, limit, or offset stage string.
---@param stage_str string|nil
---@return table|nil stage
local function parse_stage(stage_str)
  if not stage_str or stage_str == "" then
    return nil
  end
  local stage = { key = nil, dir = nil, limit = nil, offset = nil }
  local matched = false

  for token in stage_str:gmatch("%S+") do
    token = token:gsub('^["\']', ""):gsub('["\']$', "")
    token = token:gsub("^|+", "")
    local t = token:lower()

    if t == "random" then
      stage.key = "random"
      stage.dir = "asc"
      matched = true
    elseif t == "order:random" or t == "sort:random" then
      stage.key = "random"
      stage.dir = "asc"
      matched = true
    elseif t:match("^order:random:(.+)$") or t:match("^sort:random:(.+)$") then
      stage.key = "random"
      stage.dir = "asc"
      local lim_val = t:match("^%a+:%a+:(.+)$") or t:match(":(.+)$")
      local o, l, is_range = parse_limit_or_range(lim_val)
      if is_range then
        stage.offset = o
        stage.limit = l
        stage.is_range = true
        matched = true
      elseif o and l then
        stage.offset = o
        stage.limit = l
        matched = true
      elseif l then
        stage.limit = l
        matched = true
      end
    elseif t:match("^offset:(.+)$") then
      local off_val = t:match("^offset:(.+)$")
      local o, l, is_range = parse_limit_or_range(off_val)
      if is_range then
        stage.offset = o
        stage.limit = l
        stage.is_range = true
        matched = true
      elseif o and l then
        stage.offset = o
        stage.limit = l
        matched = true
      elseif l then
        stage.offset = l
        matched = true
      end
    elseif t:match("^limit:(.+)$") then
      local lim_val = t:match("^limit:(.+)$")
      local o, l, is_range = parse_limit_or_range(lim_val)
      if is_range then
        stage.offset = o
        stage.limit = l
        stage.is_range = true
        matched = true
      elseif o and l then
        stage.offset = o
        stage.limit = l
        matched = true
      elseif l then
        stage.limit = l
        matched = true
      end
    elseif t:match("^sort:(.+)$") then
      local expr = t:match("^sort:(.+)$")
      if expr == "random" then
        stage.key = "random"
        stage.dir = "asc"
        matched = true
      elseif expr:match("^random:(.+)$") then
        stage.key = "random"
        stage.dir = "asc"
        local lim_val = expr:match("^random:(.+)$")
        local o, l, is_range = parse_limit_or_range(lim_val)
        if is_range then
          stage.offset = o
          stage.limit = l
          stage.is_range = true
          matched = true
        elseif o and l then
          stage.offset = o
          stage.limit = l
          matched = true
        elseif l then
          stage.limit = l
          matched = true
        end
      else
        local parts = {}
        for p in expr:gmatch("[^:]+") do
          table.insert(parts, p)
        end
        if #parts == 1 then
          local p1 = parts[1]
          if p1 == "random" then
            stage.key = "random"
            stage.dir = "asc"
            matched = true
          else
            local o, l, is_range = parse_limit_or_range(p1)
            if is_range then
              stage.offset = o
              stage.limit = l
              stage.is_range = true
              matched = true
            elseif o and l then
              stage.offset = o
              stage.limit = l
              matched = true
            elseif l then
              stage.limit = l
              matched = true
            elseif p1 ~= "" and p1:match("^[%w_]+$") then
              stage.key = p1
              stage.dir = "desc"
              matched = true
            end
          end
        elseif #parts == 2 then
          local p1, p2 = parts[1], parts[2]
          if p1:match("^[%w_]+$") then
            stage.key = p1
            local o, l, is_range = parse_limit_or_range(p2)
            if is_range then
              stage.offset = o
              stage.limit = l
              stage.is_range = true
              stage.dir = (p1 == "random") and "asc" or "desc"
              matched = true
            elseif o and l then
              stage.offset = o
              stage.limit = l
              stage.dir = (p1 == "random") and "asc" or "desc"
              matched = true
            elseif l then
              stage.limit = l
              stage.dir = (p1 == "random") and "asc" or "desc"
              matched = true
            elseif p2 == "asc" or p2 == "desc" then
              stage.dir = p2
              matched = true
            else
              stage.dir = "desc"
              matched = true
            end
          end
        elseif #parts >= 3 then
          local p1, p2, p3 = parts[1], parts[2], parts[3]
          if p1:match("^[%w_]+$") then
            stage.key = p1
            local o2, l2, r2 = parse_limit_or_range(p2)
            local o3, l3, r3 = parse_limit_or_range(p3)
            if p2 == "asc" or p2 == "desc" then
              stage.dir = p2
              if r3 then
                stage.offset = o3
                stage.limit = l3
                stage.is_range = true
              elseif o3 and l3 then
                stage.offset = o3
                stage.limit = l3
              elseif l3 then
                stage.limit = l3
              end
              matched = true
            elseif r2 or l2 or (o2 and l2) then
              stage.offset = o2
              stage.limit = l2
              if r2 then
                stage.is_range = true
              end
              if p3 == "asc" or p3 == "desc" then
                stage.dir = p3
              else
                stage.dir = "desc"
              end
              matched = true
            else
              stage.dir = "desc"
              matched = true
            end
          end
        end
      end
    elseif t:match("^order:(.+)$") then
      local oval = t:match("^order:(.+)$")
      if oval == "asc" or oval == "desc" then
        stage.dir = oval
        matched = true
      elseif oval == "random" then
        stage.key = "random"
        stage.dir = "asc"
        matched = true
      else
        local o_key, o_dir = oval:match("^([%w]+)_([%w]+)$")
        if o_key and (o_dir == "asc" or o_dir == "desc") then
          stage.key = o_key
          stage.dir = o_dir
          matched = true
        elseif oval ~= "" and oval:match("^[%w_]+$") then
          stage.key = oval
          stage.dir = "desc"
          matched = true
        end
      end
    end
  end

  if not matched or (not stage.key and not stage.limit and not stage.offset) then
    return nil
  end

  if stage.key and not stage.dir then
    stage.dir = (stage.key == "random") and "asc" or "desc"
  end

  return stage
end

M.parse_stage = parse_stage

--- Parses sort token with optional comma separation into stage list.
---@param token_str string
---@return table[]|nil
local function parse_sort_token(token_str)
  local clean = token_str:gsub('^["\']', ""):gsub('["\']$', ""):gsub("^|+", "")
  local expr = clean:match("^[Ss][Oo][Rr][Tt]:(.*)$")
  if not expr or expr == "" then
    return nil
  end

  if expr:find(",") then
    local stages = {}
    for part in expr:gmatch("[^,]+") do
      part = vim.trim(part)
      if part == "" then
        return nil
      end
      local sub_str = part:lower():match("^sort:") and part or ("sort:" .. part)
      local st = parse_stage(sub_str)
      if not st then
        return nil
      end
      table.insert(stages, st)
    end
    if #stages == 0 then
      return nil
    end
    return stages
  else
    local st = parse_stage(clean)
    if not st then
      return nil
    end
    return { st }
  end
end

M.parse_sort_token = parse_sort_token

--- Parses tag string into structured conditions internally without pipeline delegation.
---@param tag_str string|nil
---@return table
local function _parse_tags_internal(tag_str)
  local filter = {
    positive_tags = {},
    negative_tags = {},
    or_tags = {},
    ratings = {},
    scores = {},
    artists = {},
    characters = {},
    ids = {},
    sort = nil,
    pipeline_stages = nil,
    raw = tag_str or "",
  }

  if not tag_str or tag_str == "" then
    return filter
  end

  local function add_rating(op, val)
    for _, r in ipairs(filter.ratings) do
      if r.op == op and r.val == val then
        return
      end
    end
    table.insert(filter.ratings, { op = op, val = val })
  end

  local function add_or_tag(tag)
    tag = tag:gsub("^~+", ""):gsub("~+$", ""):lower()
    if tag == "" or tag:match("^%s*$") then
      return
    end
    for _, t in ipairs(filter.or_tags) do
      if t == tag then
        return
      end
    end
    table.insert(filter.or_tags, tag)
  end

  local function add_sort_stage(key, dir, limit, offset)
    local stage = { key = key, dir = dir or "desc", limit = limit, offset = offset }
    if not filter.sort then
      filter.sort = { key = key, dir = dir or "desc", limit = limit, offset = offset }
      table.insert(filter.sort, stage)
    else
      table.insert(filter.sort, stage)
      filter.sort.key = filter.sort[1].key
      filter.sort.dir = filter.sort[1].dir
    end
    if limit or offset or (filter.pipeline_stages and #filter.pipeline_stages > 0) or #filter.sort > 1 then
      if not filter.pipeline_stages then
        filter.pipeline_stages = {}
        for _, s in ipairs(filter.sort) do
          table.insert(filter.pipeline_stages, s)
        end
      else
        table.insert(filter.pipeline_stages, stage)
      end
    end
  end

  for token in tag_str:gmatch("%S+") do
    -- Strip optional outer quotes around individual tags
    token = token:gsub('^["\']', ""):gsub('["\']$', "")

    if token == "|" then
      -- Pipe separator between stages, e.g. "hatsune_miku | sort:score"
      -- Just skip the literal pipe token
    else
      -- 1. Sort and Order directives (including piped |sort: and comma-separated sort:score:desc,date:desc)
      local sort_expr = token:match("^%|?sort:(.+)$")
      local order_val = token:match("^%|?order:(.+)$")
      local limit_expr = token:match("^limit:(.+)$")
      local offset_val = token:match("^offset:(%d+)$")
      if sort_expr then
        for part in sort_expr:gmatch("[^,]+") do
          local st = parse_stage("sort:" .. part)
          if st then
            add_sort_stage(st.key, st.dir, st.limit, st.offset)
          else
            local p_key, p_dir = part:match("^([%w_]+):?([%w_]*)$")
            if p_key then
              if p_key:lower() == "random" then
                add_sort_stage("random", "asc")
              else
                local k = p_key:lower()
                local d = (p_dir:lower() == "asc") and "asc" or "desc"
                add_sort_stage(k, d)
              end
            end
          end
        end
      elseif order_val then
        local st = parse_stage("order:" .. order_val)
        if st then
          add_sort_stage(st.key, st.dir, st.limit, st.offset)
        else
          local oval = order_val:lower()
          if oval == "asc" or oval == "desc" then
            if filter.sort and #filter.sort > 0 then
              filter.sort[#filter.sort].dir = oval
              if #filter.sort == 1 then
                filter.sort.dir = oval
              end
            else
              add_sort_stage("date", oval)
            end
          else
            local o_key, o_dir = oval:match("^([%w]+)_([%w]+)$")
            if o_key and (o_dir == "asc" or o_dir == "desc") then
              add_sort_stage(o_key, o_dir)
            else
              local d = (filter.sort and filter.sort.dir) or "desc"
              add_sort_stage(oval, d)
            end
          end
        end
      elseif limit_expr then
        local o, l = parse_limit_or_range(limit_expr)
        if o and l then
          if not filter.pipeline_stages then
            filter.pipeline_stages = {}
          end
          table.insert(filter.pipeline_stages, { offset = o, limit = l })
        elseif l and l > 0 then
          if not filter.pipeline_stages then
            filter.pipeline_stages = {}
          end
          table.insert(filter.pipeline_stages, { limit = l })
        end
      elseif offset_val then
        local off = tonumber(offset_val)
        if off and off > 0 then
          if not filter.pipeline_stages then
            filter.pipeline_stages = {}
          end
          table.insert(filter.pipeline_stages, { offset = off })
        end
      elseif token:lower() == "random" or token:lower() == "|random" then
        add_sort_stage("random", "asc")
      else
        -- 2. Score: score:>=50, score:>10, score:<=5, score:<0, score:=20, score:20
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
          -- 3. Rating: rating:<r>, -rating:<r>, ~rating:<r>, multi-ratings: rating:q,e, rating:q|e, ~rating:q|e, -rating:q,e
          local neg_rating = token:match("^%-[Rr][Aa][Tt][Ii][Nn][Gg]:(.+)$")
          local pos_rating = token:match("^~?[Rr][Aa][Tt][Ii][Nn][Gg]:(.+)$")
          if neg_rating then
            for r in neg_rating:gmatch("[^,%|]+") do
              local canon = normalize_rating(vim.trim(r))
              if canon then
                add_rating("neq", canon)
              end
            end
          elseif pos_rating then
            for r in pos_rating:gmatch("[^,%|]+") do
              local canon = normalize_rating(vim.trim(r))
              if canon then
                add_rating("eq", canon)
              end
            end
          else
            -- 4. Explicit artist modifier: artist:<name> or -artist:<name>
            local pos_artist = token:match("^artist:(.+)$")
            local neg_artist = token:match("^%-artist:(.+)$")
            if pos_artist then
              table.insert(filter.artists, { op = "eq", val = pos_artist:lower() })
            elseif neg_artist then
              table.insert(filter.artists, { op = "neq", val = neg_artist:lower() })
            else
              -- 5. Explicit character modifier: character:<name> or -character:<name>
              local pos_char = token:match("^character:(.+)$")
              local neg_char = token:match("^%-character:(.+)$")
              if pos_char then
                table.insert(filter.characters, { op = "eq", val = pos_char:lower() })
              elseif neg_char then
                table.insert(filter.characters, { op = "neq", val = neg_char:lower() })
              else
                -- 6. ID: id:<digits>
                local id_val = token:match("^id:(%d+)$")
                if id_val then
                  table.insert(filter.ids, id_val)
                else
                  -- 7. Negative tags: -tag
                  local neg_tag = token:match("^%-(.+)$")
                  if neg_tag and neg_tag ~= "" then
                    table.insert(filter.negative_tags, neg_tag:lower())
                  else
                    -- 8. Intra-token Tag Disjunction (|): foot_focus|soles|foot_job
                    if token:find("|", 1, true) then
                      for part in token:gmatch("[^|]+") do
                        local clean_part = part:gsub("^~", "")
                        if clean_part ~= "" then
                          add_or_tag(clean_part)
                        end
                      end
                    -- 9. Native Booru Tilde (~) OR Syntax: ~foot_focus
                    elseif token:sub(1, 1) == "~" then
                      local tilde_tag = token:sub(2)
                      if tilde_tag ~= "" then
                        add_or_tag(tilde_tag)
                      end
                    -- 10. Plain positive tags
                    else
                      table.insert(filter.positive_tags, token:lower())
                    end
                  end
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

M._parse_tags_internal = _parse_tags_internal

--- Parses tag string into structured conditions.
--- Supports ratings, scores, artists, characters, ids, negative tags,
--- tilde OR tags, pipe OR tags, plain tags, and sort/pipeline directives.
---@param tag_str string|nil
---@return table filter
function M.parse_tags(tag_str)
  if not tag_str or tag_str == "" then
    return _parse_tags_internal(tag_str)
  end

  local pipeline_mod = require("gelbooru.query.pipeline")
  local pipe = pipeline_mod.parse_pipeline(tag_str)
  if pipe and #pipe.stages > 0 then
    local base_filter = _parse_tags_internal(pipe.base_query)
    base_filter.pipeline_stages = pipe.stages
    local sort_tbl = nil
    for _, st in ipairs(pipe.stages) do
      if st.key then
        if not sort_tbl then
          sort_tbl = { key = st.key, dir = st.dir or "desc" }
          table.insert(sort_tbl, { key = st.key, dir = st.dir or "desc" })
        else
          table.insert(sort_tbl, { key = st.key, dir = st.dir or "desc" })
        end
      end
    end
    if sort_tbl then
      sort_tbl.key = sort_tbl[1].key
      sort_tbl.dir = sort_tbl[1].dir
      base_filter.sort = sort_tbl
    end
    base_filter.raw = tag_str
    return base_filter
  end

  return _parse_tags_internal(tag_str)
end

--- Parses query string into directory path, tag string, and structured filter table.
--- Handles `local: <tags>`, `local:<dir> <tags>`, quoted directories, or bare tags/dirs.
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
  local tokens = tokenize_query(s)
  if #tokens == 0 then
    local def_dir = config.options.save_dir
    return def_dir, "", M.parse_tags("")
  end

  local target_dir = nil
  local local_idx = nil
  local consumed_dir_idx = nil
  local has_local_prefix = false

  -- Look for local: token or local:<dir> token anywhere in the token stream
  for idx, t in ipairs(tokens) do
    if t.is_local_dir then
      -- local:"/path with spaces"
      has_local_prefix = true
      local_idx = idx
      target_dir = t.text
      break
    elseif t.text:lower() == "local:" then
      has_local_prefix = true
      local_idx = idx
      local next_t = tokens[idx + 1]
      if next_t and is_dir_token(next_t.text) then
        target_dir = next_t.text
        consumed_dir_idx = idx + 1
      else
        target_dir = config.options.save_dir
      end
      break
    elseif t.text:lower():match("^local:(.+)$") then
      has_local_prefix = true
      local_idx = idx
      local val = t.text:match("^[Ll][Oo][Cc][Aa][Ll]:(.*)")
      if is_dir_token(val) then
        target_dir = val
      else
        -- e.g. local:not_a_dir_tag1 -> target_dir is save_dir, and val is treated as a tag!
        target_dir = config.options.save_dir
        t.text = val
        t.raw = val
        local_idx = nil
      end
      break
    end
  end

  local remaining_tokens = {}
  if has_local_prefix then
    for idx, t in ipairs(tokens) do
      if idx == local_idx then
        -- Skip the local: or local:"..." token
      elseif consumed_dir_idx and idx == consumed_dir_idx then
        -- Skip the consumed directory token
      else
        table.insert(remaining_tokens, t)
      end
    end
  else
    -- No local: prefix found. Check if first token is directory.
    local first = tokens[1]
    if first and is_dir_token(first.text) then
      target_dir = first.text
      for idx = 2, #tokens do
        table.insert(remaining_tokens, tokens[idx])
      end
    else
      target_dir = config.options.save_dir
      for idx = 1, #tokens do
        table.insert(remaining_tokens, tokens[idx])
      end
    end
  end

  if not target_dir or target_dir == "" then
    target_dir = config.options.save_dir
  end
  target_dir = target_dir:gsub('^["\']', ""):gsub('["\']$', "")

  -- Reconstruct tag_str
  local tag_parts = {}
  for _, t in ipairs(remaining_tokens) do
    if t.quoted or t.text:find("%s") then
      table.insert(tag_parts, '"' .. t.text .. '"')
    else
      table.insert(tag_parts, t.text)
    end
  end
  local tag_str = vim.trim(table.concat(tag_parts, " "))
  local parsed_filter = M.parse_tags(tag_str)
  return target_dir, tag_str, parsed_filter
end

M.parse_local_query = M.parse_query

return M
