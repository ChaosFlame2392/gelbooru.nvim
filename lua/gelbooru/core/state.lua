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
  scroll_dir = 1,
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

function M.reset_ui()
  M.UI.wins = {}
  M.UI.bufs = {}
  M.UI.aug = nil
  M.UI.scroll_timer = nil
  M.UI.status_timer = nil
  M.UI.api_tag_timer = nil
  M.UI.ac_debounce_timer = nil
  M.UI.save_discovered_timer = nil
  M.UI.prefetch_timers = {}
  M.UI.current_placement = nil
end

function M.reset_tag_state()
  M.State.series = {}
  M.State.characters = {}
  M.State.artists = {}
  M.State.general = {}
  M.State.discovered = {}
  M.State.discovered_by_name = {}
  M.State.chars_by_first = {}
  M.State.series_by_first = {}
  M.State.artists_by_first = {}
  M.State.general_by_first = {}
  M.State.all_tags = {}
  M.State.tags_by_name = {}
  M.State.autocomplete_filtered = {}
end

return M
