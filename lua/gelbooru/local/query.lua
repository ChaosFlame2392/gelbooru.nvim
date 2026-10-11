local M = {}

local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")

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

--- Parses query string into directory path, tag string, and structured filter table.
--- Handles:
---   `local: <tags>`, `local:<dir> <tags>`, `local:<dir>`, `local:`,
---   flexible placement (e.g. `solo hatsune_miku local: sort:score`, `~foot_focus local:`),
---   quoted directories (e.g. `local:"/path with spaces" tag1`),
---   or bare directories/tags without `local:`.
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
            or rest:match("^random[%s|:]") or rest:match("^random$") then
            is_pipe_delim = true
          else
            local prev = str:sub(cur_start, i - 1):lower()
            if prev:match("sort:[^%s|]+$") or prev:match("order:[^%s|]+$") or prev:match("limit:[^%s|]+$")
              or prev:match("offset:%d+$") or prev:match("random$") then
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

local function parse_limit_or_range(val)
  if not val then return nil, nil end
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
      local lim_val = t:match(":(.+)$")
      local o, l = parse_limit_or_range(lim_val)
      if o and l then
        stage.offset = o
        stage.limit = l
        matched = true
      elseif l then
        stage.limit = l
        matched = true
      end
    elseif t:match("^offset:(%d+)$") then
      stage.offset = tonumber(t:match("^offset:(%d+)$"))
      matched = true
    elseif t:match("^limit:(.+)$") then
      local lim_val = t:match("^limit:(.+)$")
      local o, l = parse_limit_or_range(lim_val)
      if o and l then
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
        local o, l = parse_limit_or_range(lim_val)
        if o and l then
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
            local o, l = parse_limit_or_range(p1)
            if o and l then
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
            local o, l = parse_limit_or_range(p2)
            if o and l then
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
            local o2, l2 = parse_limit_or_range(p2)
            local o3, l3 = parse_limit_or_range(p3)
            if p2 == "asc" or p2 == "desc" then
              stage.dir = p2
              if o3 and l3 then
                stage.offset = o3
                stage.limit = l3
              elseif l3 then
                stage.limit = l3
              end
              matched = true
            elseif l2 or (o2 and l2) then
              stage.offset = o2
              stage.limit = l2
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

--- Parses a query or tag string containing pipe-separated stages.
--- Format: <base_query> | sort:<key>[:<limit>] | sort:<key>[:<limit>] ...
---@param query_or_tags string|nil
---@return table { base_query = string, stages = table[] }
function M.parse_pipeline(query_or_tags)
  if not query_or_tags or query_or_tags == "" or type(query_or_tags) ~= "string" then
    return { base_query = "", stages = {} }
  end

  local s = vim.trim(query_or_tags)
  if s == "" then
    return { base_query = "", stages = {} }
  end

  local parts = split_by_pipeline_pipe(s)
  local has_pipe = (#parts > 1)

  local stages = {}
  local non_stage_tokens = {}
  local has_preceding_stage = false

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
                return { base_query = s, stages = {} }
              end
              for _, st in ipairs(sub_stages) do
                table.insert(stages, st)
              end
              has_preceding_stage = true
            elseif tok_lower:match("^order:") then
              local st = parse_stage(clean_tok)
              if not st then
                return { base_query = s, stages = {} }
              end
              table.insert(stages, st)
              has_preceding_stage = true
            elseif tok_lower:match("^limit:") or tok_lower:match("^offset:") then
              local st = parse_stage(clean_tok)
              if not st then
                return { base_query = s, stages = {} }
              end
              table.insert(stages, st)
              has_preceding_stage = true
            elseif tok_lower == "random" and (p_idx > 1 or has_preceding_stage) then
              table.insert(stages, { key = "random", dir = "asc", limit = nil })
              has_preceding_stage = true
            elseif (tok_lower == "asc" or tok_lower == "desc") and has_preceding_stage and #stages > 0 and stages[#stages].key then
              stages[#stages].dir = tok_lower
            else
              table.insert(non_stage_tokens, tok.raw)
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
    end
  else
    if #stages > 1 then
      is_pipeline = true
    elseif #stages == 1 and ((stages[1].limit and stages[1].limit > 0) or (stages[1].offset and stages[1].offset > 0)) then
      is_pipeline = true
    end
  end

  if is_pipeline then
    return {
      base_query = table.concat(non_stage_tokens, " "),
      stages = stages,
    }
  end

  return { base_query = s, stages = {} }
end

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

--- Parses tag string into structured conditions.
--- Supports:
---   - ratings: `rating:general` (`rating:g`), `rating:sensitive` (`rating:s`),
---              `rating:questionable` (`rating:q`), `rating:explicit` (`rating:e`),
---              `~rating:<r>`, multi-ratings `rating:q,e`, `rating:q|e`, and negative forms: `-rating:<r>`
---   - scores: `score:>=50`, `score:>10`, `score:<=5`, `score:<0`, `score:=20`, `score:20`
---   - artists: `artist:<name>`, `-artist:<name>`
---   - characters: `character:<name>`, `-character:<name>`
---   - ids: `id:<number>`
---   - negative tags: `-tag`
---   - tilde OR tags: `~tag`
---   - intra-token pipe OR tags: `tag1|tag2`
---   - positive plain tags: `tag`
---   - sort directives & multi-stage cascading: `sort:score:desc,date:desc`, `| sort:...`
---@param tag_str string|nil
---@return table filter
function M.parse_tags(tag_str)
  if not tag_str or tag_str == "" then
    return _parse_tags_internal(tag_str)
  end

  local pipe = M.parse_pipeline(tag_str)
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
  p.score = 0
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
        local sa = get_post_score(a)
        local sb = get_post_score(b)
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
        local ma = get_post_mtime(a)
        local mb = get_post_mtime(b)
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
--- For each stage:
---   a. Sorting:
---      - If stage.key == "random": randomly shuffle array using Fisher-Yates.
---      - Else: sort array by stage.key ("id", "score", "date"/"mtime") in stage.dir ("desc" or "asc").
---   b. Slicing / Limiting:
---      - If stage.offset and stage.offset > 0: slice starting from stage.offset + 1 up to stage.limit.
---      - Else if stage.limit and stage.limit > 0 and #posts > stage.limit: slice to 1..stage.limit.
---@param posts table[]
---@param stages table[]
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

    if (stage.offset and stage.offset > 0) or (stage.limit and stage.limit > 0 and #current > stage.limit) then
      local start_idx = (stage.offset and stage.offset > 0) and (stage.offset + 1) or 1
      local end_idx = (stage.limit and stage.limit > 0) and math.min(#current, stage.limit) or #current
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
    res = M.execute_pipeline(res, filter.pipeline_stages)
  elseif filter.sort then
    res = M.sort_posts(res, filter.sort)
  end

  return res
end

M.parse_local_query = M.parse_query
M.matches_query = M.matches_post

return M
