-- tests/integration/search_spec.lua
-- Integration test for gelbooru search entry, query execution, list repainting, and history updates.

local harness = require("tests.integration.helpers.harness")
local ui = require("gelbooru.ui")
local api = require("gelbooru.net.api")
local state = require("gelbooru.core.state")

describe("Integration: Search & List flow", function()
  before_each(function()
    harness.setup_all()
    harness.reset_environment()
  end)

  after_each(function()
    harness.reset_environment()
    harness.teardown_all()
  end)

  it("opens UI with valid floating windows and initial buffers", function()
    ui.open()

    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.frame))
    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.input))
    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.list))
    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.img))
    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.status))
  end)

  it("executes search, resets cursor to 1, repaints list buffer, and pushes history", function()
    ui.open()

    api.execute_search("hatsune_miku")

    -- Wait for mock async curl callback to resolve
    vim.wait(100, function()
      return #state.State.posts > 0
    end)

    assert.are.equal("hatsune_miku", state.State.query)
    assert.are.equal(1, state.State.cur)
    assert.are.equal(3, #state.State.posts)
    assert.are.equal(1, state.State.history_idx)

    local list_lines = harness.get_buf_lines(state.UI.bufs.list)
    assert.is_true(#list_lines >= 3)
    -- First post in list should have cursor prefix '▶'
    assert.is_true(list_lines[1]:find("▶") ~= nil)
  end)

  it("resets cur to 1 when re-executing a new search query from a scrolled position", function()
    ui.open()
    api.execute_search("vocaloid")

    vim.wait(100, function()
      return #state.State.posts > 0
    end)

    -- Scroll cursor down to post 2
    state.State.cur = 2
    ui.render_list()

    local list_lines_before = harness.get_buf_lines(state.UI.bufs.list)
    assert.is_true(list_lines_before[2]:find("▶") ~= nil)

    -- Execute new search
    api.execute_search("zenless_zone_zero")

    vim.wait(100, function()
      return state.State.query == "zenless_zone_zero" and #state.State.posts > 0
    end)

    assert.are.equal(1, state.State.cur)
    local list_lines_after = harness.get_buf_lines(state.UI.bufs.list)
    assert.is_true(list_lines_after[1]:find("▶") ~= nil)
  end)
end)
