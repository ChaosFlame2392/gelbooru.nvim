local parse = require("gelbooru.query.parse")
local sort = require("gelbooru.query.sort")
local util = require("gelbooru.core.util")

local M = {}

--- Splits a query string by pipeline pipe characters (`|`), respecting quoted substrings
--- and heuristics distinguishing pipeline operators from literal pipe characters.
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

M.split_by_pipeline_pipe = split_by_pipeline_pipe

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
      local tokens = parse.tokenize_query(trimmed_part)
      for _, tok in ipairs(tokens) do
        if tok.quoted or tok.is_local_dir then
          table.insert(non_stage_tokens, tok.raw)
        else
          local raw_text = tok.text:gsub('^["\']', ""):gsub('["\']$', "")
          local clean_tok = raw_text:gsub("^|+", "")
          if clean_tok ~= "" then
            local tok_lower = clean_tok:lower()
            if tok_lower:match("^sort:") then
              local sub_stages = parse.parse_sort_token(clean_tok)
              if not sub_stages or #sub_stages == 0 then
                return { base_query = s, stages = {} }
              end
              for _, st in ipairs(sub_stages) do
                table.insert(stages, st)
              end
              has_preceding_stage = true
            elseif tok_lower:match("^order:") then
              local st = parse.parse_stage(clean_tok)
              if not st then
                return { base_query = s, stages = {} }
              end
              table.insert(stages, st)
              has_preceding_stage = true
            elseif tok_lower:match("^limit:") or tok_lower:match("^offset:") then
              local st = parse.parse_stage(clean_tok)
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
        current = sort.sort_posts(current, { key = key, dir = dir })
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
    elseif (stage.offset and stage.offset > 0) or (stage.limit and stage.limit > 0 and #current > stage.limit) then
      local start_idx = (stage.is_range and stage.offset) or ((stage.offset and stage.offset > 0) and (stage.offset + 1) or 1)
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

return M
