-- tests/integration/helpers/harness.lua
-- Integration test harness helper for resetting state, windows, and buffers.

local state = require("gelbooru.core.state")
local ui = require("gelbooru.ui")
local mock_net = require("tests.integration.helpers.mock_net")
local mock_snacks = require("tests.integration.helpers.mock_snacks")

local M = {}

function M.setup_all()
  mock_net.setup()
  mock_snacks.setup()
end

function M.teardown_all()
  mock_net.teardown()
  mock_snacks.teardown()
end

function M.reset_environment()
  pcall(ui.teardown)
  state.reset_ui()
  state.reset_tag_state()
  state.State.query = ""
  state.State.posts = {}
  state.State.page = 0
  state.State.cur = 1
  state.State.cur_id = nil
  state.State.history = {}
  state.State.history_idx = 0
  state.State.show_meta = true
end

function M.get_buf_lines(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

return M
