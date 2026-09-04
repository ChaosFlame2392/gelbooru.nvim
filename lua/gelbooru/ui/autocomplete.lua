local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local tags = require("gelbooru.tags")

local M = {}

function M.update_autocomplete()
  local State = state.State
  local UI = state.UI

  State.autocomplete_filtered = {}
  local full = (UI.bufs.input and vim.api.nvim_buf_is_valid(UI.bufs.input))
      and (vim.api.nvim_buf_get_lines(UI.bufs.input, 0, 1, false)[1] or "")
    or ""
  local query_part = full:match("(%S*)$") or ""
  local search_target = query_part:gsub("^[-~]", ""):lower()
  local target_norm = util.normalize_str(search_target)

  if search_target == "" then
    for i = 1, math.min(300, #State.all_tags) do
      table.insert(State.autocomplete_filtered, State.all_tags[i])
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
        local count = tonumber(t.c) or 0
        local typ = tonumber(t.t) or 0
        if typ == 5 or count >= 1 then
          local nl = t.n_lower
          if not seen_names[nl] then
            local base = 0
            if nl == search_target then
              base = 35.0
            elseif t.norm == target_norm then
              base = 30.0
            elseif vim.startswith(nl, search_target) then
              base = 20.0
            elseif vim.startswith(t.norm, target_norm) then
              base = 15.0
            elseif not prefix_only and (nl:find(search_target, 1, true) or t.norm:find(target_norm, 1, true)) then
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

    -- 1. Ultra-fast path: query first-character bucket (<3ms)
    check_bucket(State.series_by_first[first_char], 2.0, false, 100)
    check_bucket(State.chars_by_first[first_char], 1.0, false, 100)
    check_bucket(State.general_by_first[first_char], 0.0, false, 100)
    check_bucket(State.artists_by_first[first_char], 0.5, true, 100) -- prefix only for artists

    -- Also check META tags (small fixed list, always top priority)
    for _, t in ipairs(config.META_TAGS) do
      local nl = t.n_lower or t.n:lower()
      if not seen_names[nl] then
        if nl == search_target or vim.startswith(nl, search_target) then
          seen_names[nl] = true
          candidates[#candidates + 1] = { item = t, score = 1000.0, count = 0 }
        end
      end
    end

    -- 2. Substring fallback across full lists if few candidates found and query is >= 3 chars
    if #candidates < 30 and #search_target >= 3 then
      local function check_full_list(list, cat_nudge, max_needed)
        if not list then
          return false
        end
        for i = 1, #list do
          local t = list[i]
          local count = tonumber(t.c) or 0
          local typ = tonumber(t.t) or 0
          if (typ == 5 or count >= 1) and not seen_names[t.n_lower] then
            local nl = t.n_lower
            if nl:find(search_target, 1, true) or t.norm:find(target_norm, 1, true) then
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
        check_full_list(State.chars, 1.0, 80)
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

  if not State.input_focused then
    return
  end

  if #State.autocomplete_filtered == 0 then
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

  State.autocomplete_cur = math.max(0, math.min(State.autocomplete_cur, #State.autocomplete_filtered))
  if vim.api.nvim_win_is_valid(UI.wins.ac) then
    pcall(vim.api.nvim_win_set_cursor, UI.wins.ac, { math.max(1, State.autocomplete_cur), 0 })
  end
end

return M
