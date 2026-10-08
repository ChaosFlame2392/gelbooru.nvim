local M = {}

local scan = require("gelbooru.local.scan")
local state = require("gelbooru.core.state")
local history = require("gelbooru.core.history")
local image = require("gelbooru.ui.image")

M.extract_post_id = scan.extract_post_id
M.scan_local_folder = scan.scan_local_folder

function M.open_local(dir)
  local ui = require("gelbooru.ui")
  local posts, target_dir, target_file = M.scan_local_folder(dir)
  local is_new = not (state.UI.wins.frame and vim.api.nvim_win_is_valid(state.UI.wins.frame))

  if is_new then
    state.reset_query_state()
  end

  ui.ensure_ui()

  local UI = state.UI
  local State = state.State
  image.reset_canvas(#posts == 0 and "  No images found" or "  Loading...")

  local new_query = "local:" .. target_dir
  history.push_history(new_query)

  State.search_epoch = (State.search_epoch or 0) + 1
  State.loading = false
  State.posts = posts
  State.query = new_query

  local initial_cur = 1
  if target_file and #posts > 0 then
    for idx, p in ipairs(posts) do
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
    State.history[State.history_idx].posts = posts
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
  if vim.fn.isdirectory(target_dir) == 0 then
    ui.set_status(string.format("Directory not found: %s", target_dir), 3000)
  elseif #posts == 0 then
    ui.set_status(string.format("No images found in %s", target_dir), 3000)
  else
    ui.set_status(string.format("Loaded %d local images from %s", #posts, target_dir), 3000)
  end
end

return M
