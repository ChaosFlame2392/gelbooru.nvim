local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")

local M = {}

local MAX_CONCURRENT = 2
local PACING_MS = 100

local queue = {}
local active_workers = 0
local timer = nil
local timer_running = false

local function is_same_post(p1, p2)
  if not p1 or not p2 then
    return false
  end
  if p1 == p2 then
    return true
  end
  if p1.is_local or p2.is_local then
    return p1.file_url ~= nil and p1.file_url == p2.file_url
  end
  return p1.id ~= nil and p2.id ~= nil and tostring(p1.id) == tostring(p2.id)
end

function M.cursor_rush_prefetch(cur_idx, scroll_dir)
  if state.State.torn_down then
    return
  end
  local posts = state.State.posts
  if not posts or #posts == 0 then
    return
  end

  cur_idx = cur_idx or state.State.cur or 1
  scroll_dir = scroll_dir or state.State.scroll_dir or 1
  if scroll_dir == 0 then
    scroll_dir = 1
  end

  local api = require("gelbooru.net.api")
  local radius = math.min(5, math.max(3, config.options.prefetch_radius or 5))

  for offset = 1, radius do
    local idx = cur_idx + (scroll_dir * offset)
    if idx >= 1 and idx <= #posts then
      local p = posts[idx]
      if p and p.id and not p._metadata_fetched and not p._metadata_loading then
        api.fetch_post_metadata(p, function(updated_p)
          if state.State.torn_down or not updated_p then
            return
          end
          local UI = state.UI
          if UI.wins.frame and vim.api.nvim_win_is_valid(UI.wins.frame) then
            local State = state.State
            local cur_p = State.posts[State.cur]
            if is_same_post(cur_p, updated_p) then
              local ui = require("gelbooru.ui")
              ui.render_metadata(updated_p)
              ui.render_list()
            end
          end
        end)
      end
    end
  end
end

local function schedule_tick()
  if state.State.torn_down then
    M.stop()
    return
  end
  if #queue == 0 then
    return
  end

  local uv = vim.uv or vim.loop
  if not timer or timer:is_closing() then
    timer = uv.new_timer()
    if state.UI then
      state.UI.indexer_timer = timer
    end
  end

  if not timer_running then
    timer_running = true
    timer:start(
      PACING_MS,
      0,
      vim.schedule_wrap(function()
        timer_running = false
        M._tick()
      end)
    )
  end
end

function M._tick()
  if state.State.torn_down then
    M.stop()
    return
  end
  if active_workers >= MAX_CONCURRENT or #queue == 0 then
    return
  end

  local p = table.remove(queue, 1)
  while p and (p._metadata_fetched or p._metadata_loading or not p.id) do
    p = table.remove(queue, 1)
  end
  if not p then
    return
  end

  active_workers = active_workers + 1
  local api = require("gelbooru.net.api")
  api.fetch_post_metadata(p, function(updated_p)
    active_workers = math.max(0, active_workers - 1)
    if state.State.torn_down then
      return
    end

    if updated_p then
      local State = state.State
      local UI = state.UI
      if UI.wins.frame and vim.api.nvim_win_is_valid(UI.wins.frame) then
        local cur_post = State.posts[State.cur]
        if is_same_post(cur_post, updated_p) then
          local ui = require("gelbooru.ui")
          ui.render_metadata(updated_p)
          ui.render_list()
        else
          local ui = require("gelbooru.ui")
          ui.render_list()
        end
      end
    end

    if #queue > 0 and not state.State.torn_down then
      schedule_tick()
    end
  end)

  if active_workers < MAX_CONCURRENT and #queue > 0 then
    schedule_tick()
  end
end

function M.start_background_indexing(posts)
  if state.State.torn_down then
    return
  end
  M.stop()

  local target_posts = posts or state.State.posts or {}
  queue = {}
  for _, p in ipairs(target_posts) do
    if p.is_local and p.id and not p._metadata_fetched and not p._metadata_loading then
      table.insert(queue, p)
    end
  end

  if #queue > 0 then
    schedule_tick()
  end
end

function M.stop()
  if timer then
    pcall(function()
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
    end)
    timer = nil
  end
  timer_running = false
  queue = {}
  active_workers = 0
  if state.UI then
    state.UI.indexer_timer = nil
  end
end

M.abort = M.stop

return M
