local constants = require("gelbooru.core.constants")

local M = {}

M.State = {
  query = "",
  posts = {},
  page = 0,
  cur = 1,
  loading = false,
  cur_id = nil,
  show_meta = true,
  history = {},
  history_idx = 0,
  autocomplete_filtered = {},
  autocomplete_cur = 1,
  autocomplete_navigated = false,
  input_focused = false,
  scroll_dir = 1,
  search_epoch = 0,
  torn_down = false,
  prev_mouse = nil,
  list_width_ratio = constants.DEFAULT_LIST_WIDTH_RATIO,
  zen_mode = false,
  saved_index = {},
  session_cache = {},
  pending_deletions = {},
  local_folder_posts = nil,
  local_filter = nil,
  local_query_tag_str = nil,
}

M.UI = {
  wins = {},
  bufs = {},
  aug = nil,
  scroll_timer = nil,
  status_timer = nil,
  ac_debounce_timer = nil,
  fetcher_timers = {},
  tags_spinner_win = nil,
  resize_timer = nil,
  resume_timer = nil,
  prefetch_timers = {},
  indexer_timer = nil,
  current_placement = nil,
  confirm_prev_win = nil,
  PREVIEW_COOLDOWN_MS = constants.PREVIEW_COOLDOWN_REMOTE_MS,
}

function M.reset_query_state()
  M.State.query = ""
  M.State.posts = {}
  M.State.page = 0
  M.State.cur = 1
  M.State.loading = false
  M.State.cur_id = nil
  M.State.show_meta = true
  M.State.history = {}
  M.State.history_idx = 0
  M.State.autocomplete_filtered = {}
  M.State.autocomplete_cur = 1
  M.State.autocomplete_navigated = false
  M.State.input_focused = false
  M.State.scroll_dir = 1
  M.State.search_epoch = (M.State.search_epoch or 0) + 1
  M.State.torn_down = false
  M.State.list_width_ratio = constants.DEFAULT_LIST_WIDTH_RATIO
  M.State.zen_mode = false
  M.State.saved_index = {}
  M.State.pending_deletions = {}
  -- session_cache is preserved across query resets (TTL-managed in net/api.lua)
  M.State.local_folder_posts = nil
  M.State.local_filter = nil
  M.State.local_query_tag_str = nil
  pcall(function()
    require("gelbooru.local.index").reset()
  end)
end

function M.reset_ui()
  M.UI.wins = {}
  M.UI.bufs = {}
  M.UI.aug = nil
  M.UI.scroll_timer = nil
  M.UI.status_timer = nil
  M.UI.ac_debounce_timer = nil
  M.UI.fetcher_timers = {}
  M.UI.tags_spinner_win = nil
  M.UI.resize_timer = nil
  M.UI.resume_timer = nil
  M.UI.prefetch_timers = {}
  M.UI.indexer_timer = nil
  M.UI.current_placement = nil
  M.UI.confirm_prev_win = nil
end

function M.reset_tag_state()
  M.State.autocomplete_filtered = {}
  pcall(function()
    require("gelbooru.tags.catalog").reset()
  end)
end

return M
