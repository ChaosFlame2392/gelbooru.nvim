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
  series = {},
  characters = {},
  artists = {},
  general = {},
  discovered = {},
  discovered_by_name = {},
  chars_by_first = {},
  series_by_first = {},
  artists_by_first = {},
  general_by_first = {},
  all_tags = {},
  tags_by_name = {},
  autocomplete_filtered = {},
  autocomplete_cur = 1,
  autocomplete_navigated = false,
  input_focused = false,
  scroll_dir = 1, -- 1 = down, -1 = up
}

M.UI = {
  wins = {},
  bufs = {},
  aug = nil,
  scroll_timer = nil,
  status_timer = nil,
  api_tag_timer = nil,
  ac_debounce_timer = nil,
  save_discovered_timer = nil,
  prefetch_timers = {},
  current_placement = nil,
  PREVIEW_COOLDOWN_MS = 150,
}

function M.reset_query_state()
  M.State.posts = {}
  M.State.page = 0
  M.State.cur = 1
  M.State.loading = false
  M.State.cur_id = nil
end

return M
