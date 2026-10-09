-- tests/integration/helpers/harness.lua
-- Integration test harness helper for resetting state, windows, and buffers.

local state = require("gelbooru.core.state")
local ui = require("gelbooru.ui")
local config = require("gelbooru.core.config")
local tags = require("gelbooru.tags")
local download = require("gelbooru.net.download")
local mock_net = require("tests.integration.helpers.mock_net")
local mock_snacks = require("tests.integration.helpers.mock_snacks")

local M = {}

local orig_load_tags = nil
local orig_resume_pending_saves = nil
local orig_tags_dir = nil
local orig_cache_dir = nil
local orig_save_dir = nil
local test_dir = nil

function M.setup_all()
  mock_net.setup()
  mock_snacks.setup()
  _G.image = require("gelbooru.ui.image")

  orig_load_tags = tags.load_tags
  tags.load_tags = function()
    local db = require("gelbooru.tags.db")
    for _, t in ipairs(mock_net.sample_tags) do
      local typ = tonumber(t.type) or 0
      local item = { n = t.name, t = typ, c = tonumber(t.count) or 0 }
      if typ == 3 then
        db.add_tag_to_index(item, state.State.series, state.State.series_by_first)
      elseif typ == 4 then
        db.add_tag_to_index(item, state.State.characters, state.State.chars_by_first)
      elseif typ == 1 then
        db.add_tag_to_index(item, state.State.artists, state.State.artists_by_first)
      else
        db.add_tag_to_index(item, state.State.general, state.State.general_by_first)
      end
    end
  end

  orig_resume_pending_saves = download.resume_pending_saves
  download.resume_pending_saves = function() end

  orig_tags_dir = config.options.tags_dir
  orig_cache_dir = config.options.cache_dir
  orig_save_dir = config.options.save_dir

  test_dir = vim.fn.tempname() .. "_gelbooru_test"
  vim.fn.mkdir(test_dir, "p")
  config.options.tags_dir = test_dir .. "/tags"
  config.options.cache_dir = test_dir .. "/cache"
  config.options.save_dir = test_dir .. "/saved"
  vim.fn.mkdir(config.options.tags_dir, "p")
  vim.fn.mkdir(config.options.cache_dir, "p")
  vim.fn.mkdir(config.options.save_dir, "p")
end

function M.teardown_all()
  mock_net.teardown()
  mock_snacks.teardown()
  _G.image = nil

  if orig_load_tags then
    tags.load_tags = orig_load_tags
    orig_load_tags = nil
  end
  if orig_resume_pending_saves then
    download.resume_pending_saves = orig_resume_pending_saves
    orig_resume_pending_saves = nil
  end
  if orig_tags_dir then
    config.options.tags_dir = orig_tags_dir
    config.options.cache_dir = orig_cache_dir
    config.options.save_dir = orig_save_dir
  end
  if test_dir and vim.fn.isdirectory(test_dir) == 1 then
    vim.fn.delete(test_dir, "rf")
    test_dir = nil
  end
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
  state.State.zen_mode = false
  state.State.list_width_ratio = 0.25
end

function M.get_buf_lines(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

return M
