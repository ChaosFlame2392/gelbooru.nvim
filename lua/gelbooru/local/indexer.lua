local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local constants = require("gelbooru.core.constants")

local M = {}

local MAX_CONCURRENT = constants.INDEXER_MAX_CONCURRENT
local PACING_MS = constants.INDEXER_PACING_MS

M.queue = {}
M.queue_head = 1
local active_workers = 0
local timer = nil
local timer_running = false

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
  local radius = math.min(constants.RUSH_RADIUS_MAX, math.max(constants.RUSH_RADIUS_MIN, config.options.prefetch_radius or constants.DEFAULT_PREFETCH_RADIUS))

  local epoch = state.State.search_epoch
  for offset = 1, radius do
    local idx = cur_idx + (scroll_dir * offset)
    if idx >= 1 and idx <= #posts then
      local p = posts[idx]
      if p and p.id and not p._metadata_fetched and not p._metadata_loading then
        api.fetch_post_metadata(p, function(updated_p)
          if state.State.torn_down or state.State.search_epoch ~= epoch or not updated_p then
            return
          end
          local UI = state.UI
          if UI.wins.frame and vim.api.nvim_win_is_valid(UI.wins.frame) then
            local State = state.State
            local cur_p = State.posts[State.cur]
            if util.is_same_post(cur_p, updated_p) then
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
  if #M.queue == 0 or (M.queue_head and M.queue_head > #M.queue) then
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
        M.process_next_batch()
      end)
    )
  end
end

function M.process_next_batch()
  if state.State.torn_down then
    M.stop()
    return
  end
  if active_workers >= MAX_CONCURRENT or #M.queue == 0 or (M.queue_head and M.queue_head > #M.queue) then
    return
  end

  M.queue_head = (M.queue_head or 1)
  local p = nil
  while M.queue_head <= #M.queue do
    local item = M.queue[M.queue_head]
    M.queue_head = M.queue_head + 1
    if item and not item._metadata_fetched and not item._metadata_loading and item.id then
      p = item
      break
    end
  end

  if M.queue_head > #M.queue then
    M.queue = {}
    M.queue_head = 1
  end

  if not p then
    return
  end

  local epoch = state.State.search_epoch
  active_workers = active_workers + 1
  local api = require("gelbooru.net.api")
  api.fetch_post_metadata(p, function(updated_p)
    active_workers = math.max(0, active_workers - 1)
    if state.State.torn_down or state.State.search_epoch ~= epoch then
      return
    end

    if updated_p then
      local State = state.State
      local UI = state.UI
      if UI.wins.frame and vim.api.nvim_win_is_valid(UI.wins.frame) then
        if State.local_filter and State.local_folder_posts then
          local query_mod = require("gelbooru.local.query")
          local new_filtered = query_mod.filter_posts(State.local_folder_posts, State.local_filter)
          local is_random_sort = false
          if State.local_filter.sort and State.local_filter.sort.key == "random" then
            is_random_sort = true
          elseif State.local_filter.pipeline_stages then
            for _, st in ipairs(State.local_filter.pipeline_stages) do
              if st.key == "random" then
                is_random_sort = true
                break
              end
            end
          end
          local has_sort = not is_random_sort
            and ((State.local_filter.sort ~= nil)
              or (State.local_filter.pipeline_stages and #State.local_filter.pipeline_stages > 0))

          if #new_filtered ~= #State.posts or has_sort then
            local prev_count = #State.posts
            local cur_post = State.posts[State.cur]
            local new_cur = nil
            if cur_post then
              for idx, p in ipairs(new_filtered) do
                if util.is_same_post(p, cur_post) then
                  new_cur = idx
                  break
                end
              end
            end

            State.posts = new_filtered
            if new_cur then
              State.cur = new_cur
            else
              State.cur = math.max(1, math.min(State.cur or 1, math.max(1, #new_filtered)))
            end

            local ui = require("gelbooru.ui")
            ui.render_list()
            if prev_count == 0 and #State.posts > 0 then
              State.cur = 1
              ui.render_preview(false)
            else
              local active_post = State.posts[State.cur]
              if util.is_same_post(active_post, updated_p) then
                ui.render_metadata(updated_p)
              end
            end
            if State.local_query_tag_str and State.local_query_tag_str ~= "" and #new_filtered ~= prev_count then
              ui.set_status(string.format("Found %d local posts matching '%s'", #new_filtered, State.local_query_tag_str), constants.STATUS_TIMEOUT_INDEXER_MS)
            end
          else
            local cur_post = State.posts[State.cur]
            if util.is_same_post(cur_post, updated_p) then
              local ui = require("gelbooru.ui")
              ui.render_metadata(updated_p)
              ui.render_list()
            end
          end
        else
          local cur_post = State.posts[State.cur]
          if util.is_same_post(cur_post, updated_p) then
            local ui = require("gelbooru.ui")
            ui.render_metadata(updated_p)
            ui.render_list()
          else
            local ui = require("gelbooru.ui")
            ui.render_list()
          end
        end
      end
    end

    if (M.queue_head or 1) <= #M.queue and not state.State.torn_down then
      schedule_tick()
    end
  end)

  if active_workers < MAX_CONCURRENT and (M.queue_head or 1) <= #M.queue then
    schedule_tick()
  end
end

M._tick = M.process_next_batch

function M.start_background_indexing(posts)
  if state.State.torn_down then
    return
  end
  M.stop()

  local target_posts = posts or state.State.posts or {}
  M.queue = {}
  M.queue_head = 1
  for _, p in ipairs(target_posts) do
    if p.is_local and p.id and not p._metadata_fetched and not p._metadata_loading then
      table.insert(M.queue, p)
    end
  end

  if #M.queue > 0 then
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
  M.queue = {}
  M.queue_head = 1
  active_workers = 0
  if state.UI then
    state.UI.indexer_timer = nil
  end
end

M.abort = M.stop

return M
