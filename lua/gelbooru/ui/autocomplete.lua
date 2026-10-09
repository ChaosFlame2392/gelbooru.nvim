local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local tags = require("gelbooru.tags")

local M = {}

function M.update_autocomplete(query)
  local State = state.State
  local UI = state.UI

  State.autocomplete_filtered = {}
  local full = query
  if not full then
    full = (UI.bufs.input and vim.api.nvim_buf_is_valid(UI.bufs.input))
        and (vim.api.nvim_buf_get_lines(UI.bufs.input, 0, 1, false)[1] or "")
      or ""
  end

  local query_part = nil
  if UI.wins.input and vim.api.nvim_win_is_valid(UI.wins.input) then
    local mode = vim.api.nvim_get_mode().mode
    local is_insert = mode:sub(1, 1) == "i"
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, UI.wins.input)
    if ok and cursor and type(cursor[2]) == "number" then
      local col = cursor[2]
      if is_insert and col < #full then
        query_part = full:sub(1, col):match("(%S*)$")
      end
    end
  end
  if not query_part then
    query_part = full:match("(%S*)$") or ""
  end

  local line = full or ""
  local is_local = line:match("^[Ll][Oo][Cc][Aa][Ll]:") ~= nil

  local search_target = query_part:gsub("^[-~]", ""):lower()
  local target_norm = util.normalize_str(search_target)
  local has_norm = target_norm ~= "" and #target_norm > 0

  if search_target == "" then
    for i = 1, #State.all_tags do
      local t = State.all_tags[i]
      if is_local or not t.local_only then
        table.insert(State.autocomplete_filtered, t)
        if #State.autocomplete_filtered >= 300 then
          break
        end
      end
    end
  else
    local seen_names = {}
    local candidates = {}
    local first_char = search_target:sub(1, 1)

    local function check_bucket(bucket, cat_nudge, prefix_only, max_per_bucket)
      if not bucket then
        return
      end
      local added = 0
      local limit = max_per_bucket or 100
      for i = 1, #bucket do
        local t = bucket[i]
        local is_local_only = t.local_only or false
        local count = tonumber(t.c) or 0
        local typ = tonumber(t.t) or 0
        if (is_local or not is_local_only) and (typ == 5 or count >= 1) then
          local nl = t.n_lower
          if not seen_names[nl] then
            local base = 0
            if nl == search_target then
              base = 35.0
            elseif has_norm and t.norm == target_norm then
              base = 30.0
            elseif vim.startswith(nl, search_target) then
              base = 20.0
            elseif has_norm and vim.startswith(t.norm, target_norm) then
              base = 15.0
            elseif not prefix_only and (nl:find(search_target, 1, true) or (has_norm and t.norm:find(target_norm, 1, true))) then
              base = 5.0
            end

            if base > 0 then
              seen_names[nl] = true
              local pop = (typ == 5) and 0 or (math.log10(count + 1) * 10.0)
              local score = (typ == 5) and 1000.0 or (base + pop + (cat_nudge or 0))
              candidates[#candidates + 1] = {
                item = t,
                score = score,
                count = count,
              }
              added = added + 1
              if added >= limit then
                break
              end
            end
          end
        end
      end
    end

    -- 1. First-character bucket lookup
    check_bucket(State.series_by_first[first_char], 2.0, false, 100)
    check_bucket(State.chars_by_first[first_char], 1.0, false, 100)
    check_bucket(State.general_by_first[first_char], 0.0, false, 100)
    check_bucket(State.artists_by_first[first_char], 0.5, true, 100)

    -- META tags are a small fixed list, always injected at top priority
    for _, t in ipairs(config.META_TAGS) do
      if is_local or not t.local_only then
        local nl = t.n_lower or t.n:lower()
        if not seen_names[nl] then
          if nl == search_target or vim.startswith(nl, search_target) then
            seen_names[nl] = true
            candidates[#candidates + 1] = { item = t, score = 1000.0, count = 0 }
          end
        end
      end
    end

    -- 2. Substring fallback across full lists when few candidates found
    if #candidates < 30 and #search_target >= 3 then
      local function check_full_list(list, cat_nudge, max_needed)
        if not list then
          return false
        end
        for i = 1, #list do
          local t = list[i]
          local is_local_only = t.local_only or false
          local count = tonumber(t.c) or 0
          local typ = tonumber(t.t) or 0
          if (is_local or not is_local_only) and (typ == 5 or count >= 1) and not seen_names[t.n_lower] then
            local nl = t.n_lower
            if nl:find(search_target, 1, true) or (has_norm and t.norm:find(target_norm, 1, true)) then
              seen_names[nl] = true
              local pop = (typ == 5) and 0 or (math.log10(count + 1) * 10.0)
              local score = (typ == 5) and 1000.0 or (5.0 + pop + (cat_nudge or 0))
              candidates[#candidates + 1] = {
                item = t,
                score = score,
                count = count,
              }
              if #candidates >= max_needed then
                return true
              end
            end
          end
        end
        return false
      end

      check_full_list(State.series, 2.0, 60)
      if #candidates < 60 then
        check_full_list(State.characters, 1.0, 80)
      end
      if #candidates < 80 then
        check_full_list(State.general, 0.0, 100)
      end
    end

    table.sort(candidates, function(a, b)
      if math.abs(a.score - b.score) > 0.0001 then
        return a.score > b.score
      end
      if a.count ~= b.count then
        return a.count > b.count
      end
      return (a.item.n or "") < (b.item.n or "")
    end)

    for i = 1, math.min(150, #candidates) do
      table.insert(State.autocomplete_filtered, candidates[i].item)
    end

    -- Trigger live API fallback if few results found
    if #candidates < 10 and #search_target >= 3 then
      tags.fetch_api_tags(search_target)
    end
  end

  M.render_candidates()
end

function M.render_candidates()
  local State = state.State
  local UI = state.UI

  if not State.input_focused then
    return
  end

  if not State.autocomplete_filtered or #State.autocomplete_filtered == 0 then
    util.set_lines(UI.bufs.ac, { "  (no matches - searching live tags…)" })
    return
  end

  local lines = {}
  for i, t in ipairs(State.autocomplete_filtered) do
    local mark = (i == State.autocomplete_cur) and " ▶" or "  "
    local badge = config.TAG_BADGES[tonumber(t.t)] or "Tag"
    local cnt = (t.c and t.c > 0) and string.format("%8d", t.c) or "       -"
    local name_display = t.n:sub(1, 46)
    lines[#lines + 1] = string.format("%s  %-46s  [%-7s] %s", mark, name_display, badge, cnt)
  end
  util.set_lines(UI.bufs.ac, lines)

  State.autocomplete_cur = math.max(0, math.min(State.autocomplete_cur or 0, #State.autocomplete_filtered))
  if UI.wins.ac and vim.api.nvim_win_is_valid(UI.wins.ac) then
    pcall(vim.api.nvim_win_set_cursor, UI.wins.ac, { math.max(1, State.autocomplete_cur), 0 })
  end
end

M.render = M.render_candidates

function M.navigate(dir)
  local State = state.State
  if not State.autocomplete_filtered then
    State.autocomplete_filtered = {}
  end

  State.autocomplete_navigated = true
  State.autocomplete_cur = math.max(0, math.min(#State.autocomplete_filtered, (State.autocomplete_cur or 0) + dir))

  M.render_candidates()
end

M.update_suggestions = M.update_autocomplete

return M
