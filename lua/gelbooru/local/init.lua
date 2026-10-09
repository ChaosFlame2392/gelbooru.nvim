local M = {}

local scan = require("gelbooru.local.scan")
local state = require("gelbooru.core.state")
local history = require("gelbooru.core.history")
local image = require("gelbooru.ui.image")

local query = require("gelbooru.local.query")
local index = require("gelbooru.local.index")
local indexer = require("gelbooru.local.indexer")

M.extract_post_id = scan.extract_post_id
M.scan_local_folder = scan.scan_local_folder
M.parse_query = query.parse_query
M.parse_local_query = query.parse_local_query
M.filter_posts = query.filter_posts
M.index = index
M.indexer = indexer

function M.open_local(query_or_dir)
  local ui = require("gelbooru.ui")
  local target_dir, tag_str, parsed_filter = query.parse_query(query_or_dir)
  local posts, resolved_dir, target_file = M.scan_local_folder(target_dir)
  local filtered_posts = query.filter_posts(posts, parsed_filter)

  local is_new = not (state.UI.wins.frame and vim.api.nvim_win_is_valid(state.UI.wins.frame))

  if is_new then
    state.reset_query_state()
  end

  ui.ensure_ui()

  local UI = state.UI
  local State = state.State
  image.reset_canvas(#filtered_posts == 0 and "  No images found" or "  Loading...")

  local new_query
  if query_or_dir and type(query_or_dir) == "string" and query_or_dir:match("^[Ll][Oo][Cc][Aa][Ll]:") then
    new_query = query_or_dir
  else
    if tag_str and tag_str ~= "" then
      new_query = "local:" .. resolved_dir .. " " .. tag_str
    else
      new_query = "local:" .. resolved_dir
    end
  end

  history.push_history(new_query)

  State.search_epoch = (State.search_epoch or 0) + 1
  State.loading = false
  State.posts = filtered_posts
  State.query = new_query

  local initial_cur = 1
  if target_file and #filtered_posts > 0 then
    for idx, p in ipairs(filtered_posts) do
      if p.file_url == target_file then
        initial_cur = idx
        break
      end
    end
  end
  State.cur = initial_cur
  State.cur_id = nil
  State.page = 0
  if State.history[State.history_idx] then
    State.history[State.history_idx].posts = filtered_posts
    State.history[State.history_idx].cur = initial_cur
  end

  if UI.bufs.input and vim.api.nvim_buf_is_valid(UI.bufs.input) then
    vim.bo[UI.bufs.input].modifiable = true
    vim.api.nvim_buf_set_lines(UI.bufs.input, 0, 1, false, { State.query })
  end
  if UI.wins.list and vim.api.nvim_win_is_valid(UI.wins.list) then
    pcall(vim.api.nvim_set_current_win, UI.wins.list)
  end
  State.input_focused = false

  ui.render_list()
  ui.render_preview(false)
  indexer.start_background_indexing(filtered_posts)
  if vim.fn.isdirectory(resolved_dir) == 0 then
    ui.set_status(string.format("Directory not found: %s", resolved_dir), 3000)
  elseif #posts == 0 then
    ui.set_status(string.format("No images found in %s", resolved_dir), 3000)
  elseif #filtered_posts == 0 then
    ui.set_status(string.format("No posts matching '%s' in %s", tag_str, resolved_dir), 3000)
  else
    if tag_str and tag_str ~= "" then
      ui.set_status(string.format("Found %d local posts matching '%s' in %s", #filtered_posts, tag_str, resolved_dir), 3000)
    else
      ui.set_status(string.format("Loaded %d local images from %s", #filtered_posts, resolved_dir), 3000)
    end
  end
end

return M
