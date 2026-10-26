local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local catalog = require("gelbooru.tags.catalog")

local M = {}

catalog.on_tags_updated = function()
  local State = state.State
  local UI = state.UI
  if State.input_focused and UI.bufs.input and UI.wins.ac
    and vim.api.nvim_buf_is_valid(UI.bufs.input)
    and vim.api.nvim_win_is_valid(UI.wins.ac)
  then
    pcall(M.update_autocomplete)
  end
end

function M.update_autocomplete(query)
  local State = state.State
  local UI = state.UI

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
  local is_local = util.is_local_query(line)

  local results = catalog.search(query_part, { is_local = is_local })
  State.autocomplete_filtered = results or {}

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
    local name_display = (t.n or t.name or ""):sub(1, 46)
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
