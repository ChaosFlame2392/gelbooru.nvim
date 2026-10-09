local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")

local M = {}

function M.save_current_history()
  local State = state.State
  if State.history_idx >= 1 and State.history[State.history_idx] then
    local h = State.history[State.history_idx]
    h.query = State.query
    h.posts = State.posts
    h.page = State.page
    h.cur = State.cur
    log(
      "DEBUG",
      "HISTORY",
      "Saved history idx=%d query='%s' posts=%d page=%d cur=%d",
      State.history_idx,
      h.query,
      #h.posts,
      h.page,
      h.cur
    )
  end
end

local MAX_HISTORY = 30

function M.push_history(query)
  local State = state.State
  M.save_current_history()
  if State.history_idx < #State.history then
    for i = #State.history, State.history_idx + 1, -1 do
      table.remove(State.history, i)
    end
  end
  table.insert(State.history, {
    query = query or State.query,
    posts = {},
    page = 0,
    cur = 1,
  })
  State.history_idx = #State.history
  if #State.history > MAX_HISTORY then
    table.remove(State.history, 1)
    State.history_idx = math.max(1, State.history_idx - 1)
  end
  log(
    "INFO",
    "HISTORY",
    "Pushed history entry idx=%d/%d query='%s'",
    State.history_idx,
    #State.history,
    query or State.query
  )
end

local function clear_preview_buffers(posts_count)
  if state.State.torn_down then
    return
  end
  local img_mod = require("gelbooru.ui.image")
  local msg = posts_count == 0 and "  No posts found" or "  Loading..."
  if state.State.query and state.State.query:match("^local:") and posts_count == 0 then
    msg = "  No images found"
  end
  pcall(img_mod.reset_canvas, msg)
end

function M.restore_history(idx)
  local State = state.State
  local UI = state.UI
  if State.torn_down then
    return
  end
  if idx < 1 or idx > #State.history then
    log("DEBUG", "HISTORY", "restore_history bounds check failed: idx=%d, total=%d", idx, #State.history)
    return
  end
  M.save_current_history()
  local download = require("gelbooru.net.download")
  download.cancel_prefetch_timers()
  pcall(function()
    require("gelbooru.local.indexer").stop()
  end)
  State.search_epoch = (State.search_epoch or 0) + 1
  State.loading = false
  pcall(function()
    require("gelbooru.ui.image").close_current_placement()
  end)
  State.history_idx = idx
  local h = State.history[idx]
  State.query = h.query
  State.posts = h.posts or {}
  State.page = h.page or 0
  State.cur = math.max(1, math.min(h.cur or 1, math.max(1, #State.posts)))
  State.cur_id = nil

  clear_preview_buffers(#State.posts)

  log(
    "INFO",
    "HISTORY",
    "Restored history idx=%d/%d query='%s' posts=%d page=%d cur=%d",
    State.history_idx,
    #State.history,
    State.query,
    #State.posts,
    State.page,
    State.cur
  )

  if UI.bufs.input and vim.api.nvim_buf_is_valid(UI.bufs.input) then
    vim.bo[UI.bufs.input].modifiable = true
    vim.api.nvim_buf_set_lines(UI.bufs.input, 0, 1, false, { State.query })
  end

  local ui = require("gelbooru.ui")
  local api = require("gelbooru.net.api")

  if #State.posts == 0 and State.query ~= "" and not State.query:match("^local:") then
    ui.set_status(string.format("Fetching results for: %s…", State.query))
    ui.render_list()
    api.fetch(1)
  else
    ui.render_list()
    ui.render_preview(false)
  end

  ui.set_status(
    string.format(
      "History %d/%d: %s",
      State.history_idx,
      #State.history,
      State.query ~= "" and State.query or "(empty)"
    ),
    2000
  )
end

function M.history_prev()
  local State = state.State
  if State.history_idx > 1 then
    M.restore_history(State.history_idx - 1)
  else
    local ui = require("gelbooru.ui")
    ui.set_status("At oldest search history entry", 1500)
  end
end

function M.history_next()
  local State = state.State
  if State.history_idx < #State.history then
    M.restore_history(State.history_idx + 1)
  else
    local ui = require("gelbooru.ui")
    ui.set_status("At latest search history entry", 1500)
  end
end

return M
