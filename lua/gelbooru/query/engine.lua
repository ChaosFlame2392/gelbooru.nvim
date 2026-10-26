local config = require("gelbooru.core.config")
local util = require("gelbooru.core.util")
local state = require("gelbooru.core.state")

local M = {}

local RATING_MAP = {
  g = "general",
  general = "general",
  s = "sensitive",
  sensitive = "sensitive",
  q = "questionable",
  questionable = "questionable",
  e = "explicit",
  explicit = "explicit",
}

--- Normalizes booru rating abbreviations and full names to canonical string.
---@param r string|nil
---@return string|nil
local function normalize_rating(r)
  if not r or r == "" or r == "?" then
    return nil
  end
  return RATING_MAP[r:lower()] or r:lower()
end

M.normalize_rating = normalize_rating

--- Normalizes spaces after colon in query modifiers like `sort: random:1000` -> `sort:random:1000`.
---@param q string|nil
---@return string|nil
local function normalize_modifier_spacing(q)
  if not q or type(q) ~= "string" then
    return q
  end
  return q:gsub("([~%-]?)([Ss][Oo][Rr][Tt]):%s+", "%1%2:")
    :gsub("([~%-]?)([Oo][Rr][Dd][Ee][Rr]):%s+", "%1%2:")
    :gsub("([~%-]?)([Ss][Cc][Oo][Rr][Ee]):%s+", "%1%2:")
    :gsub("([~%-]?)([Rr][Aa][Tt][Ii][Nn][Gg]):%s+", "%1%2:")
    :gsub("([~%-]?)([Ii][Dd]):%s+", "%1%2:")
    :gsub("([~%-]?)([Ll][Ii][Mm][Ii][Tt]):%s+", "%1%2:")
    :gsub("([~%-]?)([Oo][Ff][Ff][Ss][Ee][Tt]):%s+", "%1%2:")
end

M.normalize_modifier_spacing = normalize_modifier_spacing

--- Tokenizes raw query string into token objects, preserving quotes and `local:"..."` prefixes.
---@param str string
---@return table[]
local function tokenize_query(str)
  str = normalize_modifier_spacing(str) or ""
  local tokens = {}
  local i = 1
  local len = #str
  while i <= len do
    while i <= len and str:sub(i, i):match("%s") do
      i = i + 1
    end
    if i > len then
      break
    end

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

--- Parses range expressions:
---   "50.." or "50-" -> offset=50, limit=nil, is_range=true
---   "..100" -> offset=1, limit=100, is_range=true
---   "10..50" or "10-50" -> offset=10, limit=50, is_range=true
---   "50" -> offset=nil, limit=50, is_range=false
---@param val string|nil
---@return number|nil offset
---@return number|nil limit
---@return boolean|nil is_range
local function parse_limit_or_range(val)
  if not val then
    return nil, nil, false
  end
  if type(val) ~= "string" and type(val) ~= "number" then
    return nil, nil, false
  end
  val = vim.trim(tostring(val))
  if val == "" then
    return nil, nil, false
  end

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
    return no, nl, true
  end
  local num = val:match("^(%d+)$")
  if num then
    return nil, tonumber(num), false
  end
  return nil, nil, false
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
    elseif t:match("^id:(.+)$") then
      local id_val = t:match("^id:(.+)$")
      local o, l, is_range = parse_limit_or_range(id_val)
      if is_range then
        stage.key = "id"
        stage.dir = "desc"
        stage.offset = o
        stage.limit = l
        stage.is_range = true
        matched = true
      elseif o and l then
        stage.key = "id"
        stage.dir = "desc"
        stage.offset = o
        stage.limit = l
        matched = true
      elseif l then
        stage.key = "id"
        stage.dir = "desc"
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
              stage.key = "id"
              stage.dir = "desc"
              stage.offset = o
              stage.limit = l
              stage.is_range = true
              matched = true
            elseif o and l then
              stage.key = "id"
              stage.dir = "desc"
              stage.offset = o
              stage.limit = l
              matched = true
            elseif l then
              stage.key = "id"
              stage.dir = "desc"
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
        local o_key, o_dir = oval:match("^([%w]+)[:_]([%w]+)$")
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

--- Splits a query string by pipeline pipe characters (`|`), respecting quoted substrings.
---@param str string|nil
---@return string[]
local function split_by_pipeline_pipe(str)
  if not str or str == "" then
    return {}
  end
  local parts = {}
  local len = #str
  local i = 1
  local cur_start = 1
  local in_quote = nil

  while i <= len do
    local c = str:sub(i, i)
    if in_quote then
      if c == in_quote then
        in_quote = nil
      end
      i = i + 1
    else
      if c == '"' or c == "'" then
        in_quote = c
        i = i + 1
      elseif c == "|" then
        local is_pipe_delim = false
        local before_char = (i > 1) and str:sub(i - 1, i - 1) or " "
        local after_char = (i < len) and str:sub(i + 1, i + 1) or " "

        if before_char:match("%s") or after_char:match("%s") or i == 1 then
          is_pipe_delim = true
        else
          local rest = str:sub(i + 1):lower()
          if rest:match("^sort:") or rest:match("^order:") or rest:match("^limit:") or rest:match("^offset:")
            or rest:match("^random[%s|:]") or rest:match("^random$")
            or rest:match("^%d+%.%.") or rest:match("^%.%.%d+") or rest:match("^%d+[%s|]") or rest:match("^%d+$") then
            is_pipe_delim = true
          else
            local prev = str:sub(cur_start, i - 1):lower()
            if prev:match("sort:[^%s|]+$") or prev:match("order:[^%s|]+$") or prev:match("limit:[^%s|]+$")
              or prev:match("offset:%d+$") or prev:match("random$")
              or prev:match("%d+%.%.%d+$") or prev:match("%d+$") then
              is_pipe_delim = true
            end
          end
        end

        if is_pipe_delim then
          table.insert(parts, str:sub(cur_start, i - 1))
          cur_start = i + 1
        end
        i = i + 1
      else
        i = i + 1
      end
    end
  end

  table.insert(parts, str:sub(cur_start, len))
  return parts
end

M.split_by_pipeline_pipe = split_by_pipeline_pipe

--- Parses a query containing pipe-separated or inline stages.
---@param query_or_tags string|nil
---@return table { base_query: string, stages: table[], is_pipeline: boolean }
local function parse_pipeline(query_or_tags)
  if not query_or_tags or query_or_tags == "" or type(query_or_tags) ~= "string" then
    return { base_query = "", stages = {}, is_pipeline = false }
  end

  query_or_tags = normalize_modifier_spacing(query_or_tags) or query_or_tags
  local s = vim.trim(query_or_tags)
  if s == "" then
    return { base_query = "", stages = {}, is_pipeline = false }
  end

  local parts = split_by_pipeline_pipe(s)
  local has_pipe = (#parts > 1)

  local stages = {}
  local non_stage_tokens = {}
  local has_preceding_stage = false
  local has_preceding_sort = false

  for p_idx, part_str in ipairs(parts) do
    local trimmed_part = vim.trim(part_str)
    if trimmed_part ~= "" then
      local tokens = tokenize_query(trimmed_part)
      for _, tok in ipairs(tokens) do
        if tok.quoted or tok.is_local_dir then
          table.insert(non_stage_tokens, tok.raw)
        else
          local raw_text = tok.text:gsub('^["\']', ""):gsub('["\']$', "")
          local clean_tok = raw_text:gsub("^|+", "")
          if clean_tok ~= "" then
            local tok_lower = clean_tok:lower()
            if tok_lower:match("^sort:") then
              local sub_stages = parse_sort_token(clean_tok)
              if not sub_stages or #sub_stages == 0 then
                return { base_query = s, stages = {}, is_pipeline = false }
              end
              for _, st in ipairs(sub_stages) do
                table.insert(stages, st)
                if st.key then
                  has_preceding_sort = true
                end
              end
              has_preceding_stage = true
            elseif tok_lower:match("^order:") then
              local st = parse_stage(clean_tok)
              if not st then
                return { base_query = s, stages = {}, is_pipeline = false }
              end
              table.insert(stages, st)
              if st.key then
                has_preceding_sort = true
              end
              has_preceding_stage = true
            elseif tok_lower:match("^limit:") or tok_lower:match("^offset:") then
              local st = parse_stage(clean_tok)
              if not st then
                return { base_query = s, stages = {}, is_pipeline = false }
              end
              table.insert(stages, st)
              if st.key then
                has_preceding_sort = true
              end
              has_preceding_stage = true
            elseif tok_lower == "random" and (p_idx > 1 or has_preceding_stage) then
              table.insert(stages, { key = "random", dir = "asc", limit = nil })
              has_preceding_stage = true
              has_preceding_sort = true
            elseif (tok_lower == "asc" or tok_lower == "desc") and has_preceding_stage and #stages > 0 and stages[#stages].key then
              stages[#stages].dir = tok_lower
            elseif tok_lower:match("^id:") then
              local id_val = clean_tok:match("^[Ii][Dd]:(.*)$")
              local o, l, is_range = parse_limit_or_range(id_val)
              if is_range or (o and l) or (p_idx > 1 and l) then
                table.insert(stages, {
                  key = "id",
                  dir = "desc",
                  offset = o,
                  limit = l,
                  is_range = is_range or false,
                })
                has_preceding_stage = true
                has_preceding_sort = true
              else
                table.insert(non_stage_tokens, tok.raw)
              end
            else
              local o, l, is_range = parse_limit_or_range(clean_tok)
              if is_range or (o and l) or ((p_idx > 1 or has_preceding_stage) and l) then
                local stage_key = nil
                local stage_dir = nil
                if not has_preceding_sort then
                  stage_key = "id"
                  stage_dir = "desc"
                end
                table.insert(stages, {
                  key = stage_key,
                  dir = stage_dir,
                  offset = o,
                  limit = l,
                  is_range = is_range or false,
                })
                has_preceding_stage = true
                if stage_key then
                  has_preceding_sort = true
                end
              else
                table.insert(non_stage_tokens, tok.raw)
              end
            end
          end
        end
      end
    end
  end

  local is_pipeline = false
  if has_pipe then
    if #stages > 0 then
      is_pipeline = true
    else
      return {
        base_query = table.concat(non_stage_tokens, " "),
        stages = {},
        is_pipeline = false,
      }
    end
  else
    if #stages > 1 then
      is_pipeline = true
    elseif #stages == 1 and ((stages[1].limit and stages[1].limit > 0) or (stages[1].offset and stages[1].offset > 0) or stages[1].is_range) then
      is_pipeline = true
    end
  end

  if is_pipeline then
    return {
      base_query = table.concat(non_stage_tokens, " "),
      stages = stages,
      is_pipeline = true,
    }
  end

  return {
    base_query = s,
    stages = {},
    is_pipeline = false,
  }
end

M.parse_pipeline = parse_pipeline

--- Parses structured filtering criteria from a tag/criteria string.
---@param tag_str string|nil
---@return QueryFilters
local function parse_criteria(tag_str)
  local filters = {
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
    return filters
  end

  tag_str = normalize_modifier_spacing(tag_str) or tag_str

  local function add_rating(op, val)
    for _, r in ipairs(filters.ratings) do
      if r.op == op and r.val == val then
        return
      end
    end
    table.insert(filters.ratings, { op = op, val = val })
  end

  local function add_or_tag(tag)
    tag = tag:gsub("^~+", ""):gsub("~+$", ""):lower()
    if tag == "" or tag:match("^%s*$") then
      return
    end
    for _, t in ipairs(filters.or_tags) do
      if t == tag then
        return
      end
    end
    table.insert(filters.or_tags, tag)
  end

  local function add_sort_stage(key, dir, limit, offset)
    local stage = { key = key, dir = dir or "desc", limit = limit, offset = offset }
    if not filters.sort then
      filters.sort = { key = key, dir = dir or "desc", limit = limit, offset = offset }
      table.insert(filters.sort, stage)
    else
      table.insert(filters.sort, stage)
      filters.sort.key = filters.sort[1].key
      filters.sort.dir = filters.sort[1].dir
    end
  end

  for token in tag_str:gmatch("%S+") do
    token = token:gsub('^["\']', ""):gsub('["\']$', "")

    if token ~= "|" and token ~= "" then
      local sort_expr = token:match("^%|?[Ss][Oo][Rr][Tt]:(.+)$")
      local order_val = token:match("^%|?[Oo][Rr][Dd][Ee][Rr]:(.+)$")

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
            if filters.sort and #filters.sort > 0 then
              filters.sort[#filters.sort].dir = oval
              if #filters.sort == 1 then
                filters.sort.dir = oval
              end
            else
              add_sort_stage("date", oval)
            end
          elseif oval == "random" then
            add_sort_stage("random", "asc")
          else
            local o_key, o_dir = oval:match("^([%w]+)_([%w]+)$")
            if o_key and (o_dir == "asc" or o_dir == "desc") then
              add_sort_stage(o_key, o_dir)
            else
              local d = (filters.sort and filters.sort.dir) or "desc"
              add_sort_stage(oval, d)
            end
          end
        end
      elseif token:lower() == "random" or token:lower() == "|random" then
        add_sort_stage("random", "asc")
      else
        -- Score: score:>=50, score:>10, score:<=5, score:<0, score:=20, score:20
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
          table.insert(filters.scores, { op = score_op, val = tonumber(score_val) })
        else
          -- Rating: rating:<r>, -rating:<r>, ~rating:<r>, multi-ratings: rating:q,e, rating:q|e
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
          -- Explicit artist modifier: artist:<name> or -artist:<name>
          local pos_artist = token:match("^artist:(.+)$")
          local neg_artist = token:match("^%-artist:(.+)$")
          if pos_artist then
            table.insert(filters.artists, { op = "eq", val = pos_artist:lower() })
          elseif neg_artist then
            table.insert(filters.artists, { op = "neq", val = neg_artist:lower() })
          else
            -- Explicit character modifier: character:<name> or -character:<name>
            local pos_char = token:match("^character:(.+)$")
            local neg_char = token:match("^%-character:(.+)$")
            if pos_char then
              table.insert(filters.characters, { op = "eq", val = pos_char:lower() })
            elseif neg_char then
              table.insert(filters.characters, { op = "neq", val = neg_char:lower() })
            else
              -- ID: id:<digits>
              local id_val = token:match("^id:(%d+)$")
              if id_val then
                table.insert(filters.ids, id_val)
              else
                -- Negative tags: -tag
                local neg_tag = token:match("^%-(.+)$")
                if neg_tag and neg_tag ~= "" then
                  table.insert(filters.negative_tags, neg_tag:lower())
                else
                  -- Intra-token Tag Disjunction (|): foot_focus|soles
                  if token:find("|", 1, true) then
                    for part in token:gmatch("[^|]+") do
                      local clean_part = part:gsub("^~", "")
                      if clean_part ~= "" then
                        add_or_tag(clean_part)
                      end
                    end
                  -- Native Booru Tilde (~) OR Syntax: ~foot_focus
                  elseif token:sub(1, 1) == "~" then
                    local tilde_tag = token:sub(2)
                    if tilde_tag ~= "" then
                      add_or_tag(tilde_tag)
                    end
                  -- Plain positive tags
                  else
                    table.insert(filters.positive_tags, token:lower())
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

  return filters
end

M.parse_criteria = parse_criteria

--- Checks if token looks like a directory path or exists as a directory on disk.
---@param token_str string|nil
---@return boolean
local function is_dir_token(token_str)
  if not token_str or token_str == "" then
    return false
  end
  local clean = token_str:gsub('^["\']', ""):gsub('["\']$', "")
  if clean == "" then
    return false
  end
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

local CANONICAL_RATINGS = { "general", "sensitive", "questionable", "explicit" }

--- Formats query tokens into clean remote query branches for the Gelbooru REST API.
--- Handles modifier stripping (~score -> score, ~id -> id, ~sort: -> sort:),
--- invalid sort suffix stripping (sort:score:50 -> sort:score),
--- multi-rating de-Morgan negation (rating:q,e -> -rating:general -rating:sensitive),
--- and tilde OR tag branch generation (~tag1 ~tag2 -> concurrent branches).
---@param tags_str string|nil
---@return string[] branches
local function normalize_remote(tags_str)
  if not tags_str or type(tags_str) ~= "string" or vim.trim(tags_str) == "" then
    return { "" }
  end

  tags_str = normalize_modifier_spacing(tags_str) or tags_str

  local tokens = {}
  for tok in tags_str:gmatch("%S+") do
    table.insert(tokens, tok)
  end

  local sort_order_tokens = {}
  local positive_ratings = {}
  local negative_ratings = {}
  local or_tags = {}
  local base_tokens = {}

  for _, tok in ipairs(tokens) do
    if tok:match("^~?[Ss][Oo][Rr][Tt]:") or tok:match("^~?[Oo][Rr][Dd][Ee][Rr]:") then
      local clean_sort = tok:gsub("^~", "")
      local st = parse_stage(clean_sort)
      if st and st.key then
        local k = st.key:lower()
        if k == "id" or k == "score" then
          local dir_str = (st.dir and st.dir:lower() == "asc") and ":asc"
            or (clean_sort:lower():find(":desc", 1, true) and ":desc" or "")
          local prefix = clean_sort:lower():match("^order:") and "order:" or "sort:"
          table.insert(sort_order_tokens, string.format("%s%s%s", prefix, k, dir_str))
        elseif k == "random" then
          local prefix = clean_sort:lower():match("^order:") and "order:" or "sort:"
          table.insert(sort_order_tokens, prefix .. "random")
        elseif k == "date" or k == "mtime" then
          -- Local-only sorts, omitted from remote booru query
        else
          local dir_str = (st.dir and st.dir:lower() == "asc") and ":asc"
            or (clean_sort:lower():find(":desc", 1, true) and ":desc" or "")
          local prefix = clean_sort:lower():match("^order:") and "order:" or "sort:"
          table.insert(sort_order_tokens, string.format("%s%s%s", prefix, k, dir_str))
        end
      end
    elseif tok:match("^%-[Rr][Aa][Tt][Ii][Nn][Gg]:(.+)$") then
      local val = tok:match("^%-[Rr][Aa][Tt][Ii][Nn][Gg]:(.+)$")
      for r in val:gmatch("[^,|]+") do
        local canon = normalize_rating(vim.trim(r))
        if canon then
          table.insert(negative_ratings, canon)
        end
      end
    elseif tok:match("^~?[Rr][Aa][Tt][Ii][Nn][Gg]:(.+)$") then
      local val = tok:match("^~?[Rr][Aa][Tt][Ii][Nn][Gg]:(.+)$")
      for r in val:gmatch("[^,|]+") do
        local canon = normalize_rating(vim.trim(r))
        if canon then
          table.insert(positive_ratings, canon)
        end
      end
    elseif tok:match("^[~%-]?[Ss][Cc][Oo][Rr][Ee]:") then
      local clean = tok:gsub("^~", "")
      clean = clean:gsub("^[Ss][Cc][Oo][Rr][Ee]:", "score:")
      table.insert(base_tokens, clean)
    elseif tok:match("^[~%-]?[Ii][Dd]:") then
      local clean = tok:gsub("^~", "")
      clean = clean:gsub("^[Ii][Dd]:", "id:")
      table.insert(base_tokens, clean)
    elseif tok:sub(1, 1) == "~" and #tok > 1 then
      table.insert(or_tags, tok:sub(2))
    elseif tok ~= "~" and tok ~= "|" and not tok:match("^|+$") then
      table.insert(base_tokens, tok)
    end
  end

  local function dedup(list)
    local s = {}
    local res = {}
    for _, v in ipairs(list) do
      if not s[v] then
        s[v] = true
        table.insert(res, v)
      end
    end
    return res
  end

  positive_ratings = dedup(positive_ratings)
  negative_ratings = dedup(negative_ratings)
  or_tags = dedup(or_tags)

  local rating_clause = {}
  if #positive_ratings > 0 then
    if #positive_ratings == 1 then
      table.insert(rating_clause, "rating:" .. positive_ratings[1])
    elseif #positive_ratings < 4 then
      local sel = {}
      for _, r in ipairs(positive_ratings) do
        sel[r] = true
      end
      for _, r in ipairs(CANONICAL_RATINGS) do
        if not sel[r] then
          table.insert(rating_clause, "-rating:" .. r)
        end
      end
    end
  end
  for _, r in ipairs(negative_ratings) do
    table.insert(rating_clause, "-rating:" .. r)
  end

  local common_parts = {}
  for _, t in ipairs(base_tokens) do
    table.insert(common_parts, t)
  end
  for _, r in ipairs(rating_clause) do
    table.insert(common_parts, r)
  end
  for _, s in ipairs(sort_order_tokens) do
    table.insert(common_parts, s)
  end
  local common_str = vim.trim(table.concat(common_parts, " "))

  if #or_tags == 0 then
    return { common_str }
  elseif #or_tags == 1 then
    local res = (common_str == "") and or_tags[1] or (common_str .. " " .. or_tags[1])
    return { res }
  else
    local branches = {}
    for _, ot in ipairs(or_tags) do
      local b = (common_str == "") and ot or (common_str .. " " .. ot)
      table.insert(branches, b)
    end
    return branches
  end
end

M.normalize_remote = normalize_remote

--- Checks if a query or tag string explicitly specifies random ordering.
---@param str string|nil
---@return boolean
local function has_random_modifier(str)
  if not str or str == "" or type(str) ~= "string" then
    return false
  end
  local lower = str:lower()
  return lower:find("sort:random", 1, true) ~= nil or lower:find("order:random", 1, true) ~= nil
end

M.has_random_modifier = has_random_modifier

--- Checks if any filter criteria exists in a filters table.
---@param filters table|nil
---@return boolean
local function has_filter_criteria(filters)
  if not filters or type(filters) ~= "table" then
    return false
  end
  return (filters.positive_tags and #filters.positive_tags > 0)
    or (filters.negative_tags and #filters.negative_tags > 0)
    or (filters.or_tags and #filters.or_tags > 0)
    or (filters.or_groups and #filters.or_groups > 0)
    or (filters.ratings and #filters.ratings > 0)
    or (filters.rating ~= nil and filters.rating ~= false and filters.rating ~= "")
    or (filters.scores and #filters.scores > 0)
    or (filters.score ~= nil and filters.score ~= false and filters.score ~= "")
    or (filters.artists and #filters.artists > 0)
    or (filters.artist ~= nil and filters.artist ~= false and filters.artist ~= "")
    or (filters.characters and #filters.characters > 0)
    or (filters.character ~= nil and filters.character ~= false and filters.character ~= "")
    or (filters.ids and #filters.ids > 0)
    or (filters.id ~= nil and filters.id ~= false and filters.id ~= "")
    or false
end

M.has_filter_criteria = has_filter_criteria

--- Prepares a raw query string into a structured execution plan.
---@param query_str string|nil
---@return table plan
function M.prepare(query_str)
  local raw = query_str or ""
  local is_empty = (vim.trim(raw) == "")
  local def_dir = config.options.save_dir

  if is_empty then
    local filters = parse_criteria("")
    local empty_plan = {
      raw = raw,
      is_local = false,
      dir = def_dir,
      target_dir = def_dir,
      tag_str = "",
      base_query = "",
      is_random = false,
      is_pipeline = false,
      has_range = false,
      has_filter = false,
      remote_tags = "",
      remote_branches = { "" },
      stages = {},
      pipeline_stages = {},
      filters = filters,
      sort = nil,
    }
    filters.sort = nil
    filters.pipeline_stages = {}
    filters.has_filter = false
    return setmetatable(empty_plan, {
      __index = filters,
    })
  end

  local norm = normalize_modifier_spacing(raw) or raw
  local tokens = tokenize_query(norm)

  local target_dir = nil
  local local_idx = nil
  local consumed_dir_idx = nil
  local has_local_prefix = false

  -- Look for local: token or local:<dir> token anywhere in the token stream
  for idx, t in ipairs(tokens) do
    if t.is_local_dir then
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
        target_dir = def_dir
      end
      break
    elseif t.text:lower():match("^local:(.+)$") then
      has_local_prefix = true
      local_idx = idx
      local val = t.text:match("^[Ll][Oo][Cc][Aa][Ll]:(.*)")
      if is_dir_token(val) then
        target_dir = val
      else
        target_dir = def_dir
        t.text = val
        t.raw = val
        local_idx = nil
      end
      break
    end
  end

  local remaining_tokens = {}
  local is_local = false

  if has_local_prefix then
    is_local = true
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
    local first = tokens[1]
    if first and is_dir_token(first.text) then
      is_local = true
      target_dir = first.text
      for idx = 2, #tokens do
        table.insert(remaining_tokens, tokens[idx])
      end
    else
      target_dir = def_dir
      for idx = 1, #tokens do
        table.insert(remaining_tokens, tokens[idx])
      end
    end
  end

  if not target_dir or target_dir == "" then
    target_dir = def_dir
  end
  target_dir = target_dir:gsub('^["\']', ""):gsub('["\']$', "")

  -- Reconstruct tag_str from remaining_tokens
  local tag_parts = {}
  for _, t in ipairs(remaining_tokens) do
    if t.quoted or t.text:find("%s") then
      table.insert(tag_parts, '"' .. t.text .. '"')
    else
      table.insert(tag_parts, t.text)
    end
  end
  local tag_str = vim.trim(table.concat(tag_parts, " "))

  local pipe = parse_pipeline(tag_str)
  local base_query = pipe.base_query
  local stages = pipe.stages
  local is_pipeline = pipe.is_pipeline

  local filters = parse_criteria((#stages == 0 and not is_pipeline) and tag_str or base_query)
  local has_filter = has_filter_criteria(filters)
  filters.has_filter = has_filter

  local is_random = false
  local has_range = false
  for _, st in ipairs(stages) do
    if st.key == "random" then
      is_random = true
    end
    if st.is_range or st.offset or st.limit then
      has_range = true
    end
  end
  if not is_random and has_random_modifier(tag_str) then
    is_random = true
  end

  local sort_tbl = nil
  for _, st in ipairs(stages) do
    if st.key then
      if not sort_tbl then
        sort_tbl = {
          key = st.key,
          dir = st.dir or "desc",
          limit = st.limit,
          offset = st.offset,
          is_range = st.is_range,
        }
        table.insert(sort_tbl, {
          key = st.key,
          dir = st.dir or "desc",
          limit = st.limit,
          offset = st.offset,
          is_range = st.is_range,
        })
      else
        table.insert(sort_tbl, {
          key = st.key,
          dir = st.dir or "desc",
          limit = st.limit,
          offset = st.offset,
          is_range = st.is_range,
        })
      end
    end
  end

  if not sort_tbl and filters.sort then
    sort_tbl = filters.sort
  end
  if not is_random and ((sort_tbl and sort_tbl.key == "random") or has_random_modifier(tag_str)) then
    is_random = true
  end

  local remote_tags = ""
  local remote_branches = { "" }

  if not is_local then
    if is_pipeline then
      local remote_sort = nil
      if #stages > 0 and stages[1].key then
        local st1 = stages[1]
        local k = st1.key:lower()
        if k == "id" or k == "score" then
          local dir_str = (st1.dir and st1.dir:lower() == "asc") and ":asc" or ""
          remote_sort = string.format("sort:%s%s", k, dir_str)
        elseif k == "random" then
          remote_sort = "sort:random"
        end
      end
      local remote_input = base_query
      if remote_sort then
        remote_input = (remote_input == "") and remote_sort or (remote_input .. " " .. remote_sort)
      end
      remote_branches = normalize_remote(remote_input)
      remote_tags = remote_branches[1] or ""
    else
      remote_branches = normalize_remote(tag_str)
      remote_tags = remote_branches[1] or ""
    end
  end

  local plan = {
    raw = raw,
    is_local = is_local,
    dir = target_dir,
    target_dir = target_dir,
    tag_str = tag_str,
    base_query = base_query,
    is_random = is_random,
    is_pipeline = is_pipeline,
    has_range = has_range,
    has_filter = has_filter,
    remote_tags = remote_tags,
    remote_branches = remote_branches,
    stages = stages,
    pipeline_stages = stages,
    filters = filters,
    sort = sort_tbl,
  }

  filters.sort = sort_tbl
  filters.pipeline_stages = stages

  return setmetatable(plan, {
    __index = filters,
  })
end

--- Retrieves the numeric score of a post, checking in-memory post field first,
--- then falling back to disk metadata cache (<cache_dir>/meta_<id>.json).
---@param p table|nil
---@return number
function M.get_post_score(p)
  if not p then
    return 0
  end
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
---@param p table|nil
---@return number
function M.get_post_mtime(p)
  if not p then
    return 0
  end
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

--- Evaluates a single post item against filter criteria in a prepared plan or query string.
--- Checks positive tags, negative tags, OR clauses/tags, ratings, scores, IDs, artists, characters,
--- and filename fallback. Handles unhydrated posts gracefully.
---@param post table|nil
---@param plan_or_query table|string|nil
---@return boolean
function M.matches(post, plan_or_query)
  if not post then
    return false
  end
  if not plan_or_query then
    return true
  end

  local plan = plan_or_query
  if type(plan_or_query) == "string" then
    if vim.trim(plan_or_query) == "" then
      return true
    end
    plan = M.prepare(plan_or_query)
  end

  local filter = (type(plan) == "table" and plan.filters) and plan.filters or plan
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
    local pr = normalize_rating(post.rating)
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
    local ps = M.get_post_score(post)
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

  local ok, catalog = pcall(require, "gelbooru.tags.catalog")
  if ok and catalog and #post_tags > 0 then
    for _, t in ipairs(post_tags) do
      local info = catalog.get_tag(t)
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

M.matches_post = M.matches
M.matches_query = M.matches

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

--- Executes a multi-stage piped sorting and slicing pipeline sequentially on a list of posts.
---@param posts table[]
---@param stages table[]|table
---@return table[]
function M.execute_pipeline(posts, stages)
  if not posts or #posts == 0 or not stages then
    return posts or {}
  end
  local stage_list = stages.stages or stages
  if not stage_list or #stage_list == 0 then
    return posts or {}
  end

  local current = {}
  for i = 1, #posts do
    current[i] = posts[i]
  end

  for _, stage in ipairs(stage_list) do
    if stage.key then
      local key = stage.key:lower()
      if key == "random" then
        util.shuffle(current)
      else
        local dir = (stage.dir and stage.dir:lower() == "asc") and "asc" or "desc"
        current = M.sort_posts(current, { key = key, dir = dir })
      end
    end

    if stage.is_range and stage.offset and not stage.limit then
      local start_idx = math.max(1, stage.offset)
      local end_idx = #current
      local sliced = {}
      if start_idx <= #current then
        for i = start_idx, end_idx do
          sliced[#sliced + 1] = current[i]
        end
      end
      current = sliced
    elseif (stage.offset and stage.offset > 0) or (stage.limit and stage.limit > 0) or stage.is_range then
      local start_idx
      if stage.is_range then
        start_idx = math.max(1, stage.offset or 1)
      elseif stage.offset and stage.offset > 0 then
        start_idx = stage.offset + 1
      else
        start_idx = 1
      end

      local end_idx
      if stage.limit and stage.limit > 0 then
        if stage.is_range then
          end_idx = math.min(#current, stage.limit)
        else
          end_idx = math.min(#current, start_idx + stage.limit - 1)
        end
      else
        end_idx = #current
      end

      local sliced = {}
      if start_idx <= #current then
        for i = start_idx, end_idx do
          sliced[#sliced + 1] = current[i]
        end
      end
      current = sliced
    end
  end

  return current
end

--- Atomically evaluates an in-memory post array against a prepared execution plan.
--- Sequentially applies: (1) criteria matching -> (2) sorting -> (3) stage slicing.
---@param posts table[]|nil
---@param plan_or_query table|string|nil
---@return table[] filtered_and_sliced_posts
function M.evaluate(posts, plan_or_query)
  if not posts or #posts == 0 then
    return {}
  end

  local plan = plan_or_query
  if not plan then
    plan = M.prepare(nil)
  elseif type(plan) == "string" then
    plan = M.prepare(plan)
  end

  local filter = (type(plan) == "table" and plan.filters) and plan.filters or plan
  local has_criteria = has_filter_criteria(filter)

  local res = {}
  if not has_criteria then
    for i = 1, #posts do
      res[i] = posts[i]
    end
  else
    for _, p in ipairs(posts) do
      if M.matches(p, filter) then
        table.insert(res, p)
      end
    end
  end

  local stages = (type(plan) == "table") and (plan.stages or plan.pipeline_stages) or nil
  local sort_opt = (type(plan) == "table") and plan.sort or nil

  if sort_opt and (not stages or #stages == 0 or not stages[1].key) then
    res = M.sort_posts(res, sort_opt)
  end

  if stages and #stages > 0 then
    res = M.execute_pipeline(res, stages)
  elseif sort_opt and (not stages or #stages == 0) then
    res = M.sort_posts(res, sort_opt)
  end

  return res
end

M.filter_posts = M.evaluate

--- Parses query string into directory path, tag string, and execution plan/filter.
--- Compatibility helper around engine.prepare().
---@param query_str string|nil
---@return string target_dir
---@return string tag_str
---@return QueryPlan plan
function M.parse_query(query_str)
  local plan = M.prepare(query_str)
  return plan.dir, plan.tag_str, plan
end

M.parse_local_query = M.parse_query

--- Parses tag string into structured conditions.
--- Compatibility helper around engine.prepare().
---@param tag_str string|nil
---@return QueryFilters filters
function M.parse_tags(tag_str)
  local plan = M.prepare(tag_str)
  return plan.filters
end

return M
