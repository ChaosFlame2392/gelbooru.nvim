-- tests/unit/history_spec.lua
-- Unit tests for gelbooru.core.history — push, save, restore, bounds.

local history = require("gelbooru.core.history")
local state = require("gelbooru.core.state")

-- Helpers
local function reset_state()
  state.State.query = ""
  state.State.posts = {}
  state.State.page = 0
  state.State.cur = 1
  state.State.cur_id = nil
  state.State.history = {}
  state.State.history_idx = 0
end

local function fake_posts(n)
  local t = {}
  for i = 1, n do
    t[i] = { id = i, tags = "" }
  end
  return t
end

describe("history.push_history", function()
  before_each(reset_state)

  it("creates a new entry", function()
    history.push_history("zenless_zone_zero")
    assert.are.equal(1, #state.State.history)
    assert.are.equal("zenless_zone_zero", state.State.history[1].query)
  end)

  it("advances history_idx", function()
    history.push_history("a")
    history.push_history("b")
    assert.are.equal(2, state.State.history_idx)
  end)

  it("truncates forward history on new push", function()
    history.push_history("a")
    history.push_history("b")
    history.push_history("c")
    -- Go back to b
    state.State.history_idx = 2
    -- Push a new query from position 2 — should drop c
    history.push_history("d")
    assert.are.equal(3, #state.State.history)
    assert.are.equal("d", state.State.history[3].query)
  end)

  it("saves current state before pushing", function()
    history.push_history("first")
    state.State.query = "first"
    state.State.posts = fake_posts(5)
    state.State.page = 1
    state.State.cur = 3
    history.push_history("second")
    local first = state.State.history[1]
    assert.are.equal("first", first.query)
    assert.are.equal(5, #first.posts)
    assert.are.equal(1, first.page)
    assert.are.equal(3, first.cur)
  end)
end)

describe("history.save_current_history", function()
  before_each(reset_state)

  it("is a no-op when history is empty", function()
    assert.has_no.errors(function()
      history.save_current_history()
    end)
  end)

  it("stores posts by reference, not by copy", function()
    history.push_history("test")
    local posts = fake_posts(3)
    state.State.posts = posts
    history.save_current_history()
    assert.are.equal(posts, state.State.history[1].posts)
  end)
end)

describe("history.restore_history", function()
  before_each(reset_state)

  it("restores query and posts", function()
    history.push_history("first")
    state.State.query = "first"
    state.State.posts = fake_posts(10)
    state.State.page = 2
    history.push_history("second")

    -- Mock UI functions that restore_history calls
    local ui_calls = {}
    package.loaded["gelbooru.ui"] = {
      set_status = function() end,
      render_list = function() ui_calls[#ui_calls+1] = "render_list" end,
      render_preview = function() ui_calls[#ui_calls+1] = "render_preview" end,
    }
    package.loaded["gelbooru.net.api"] = { fetch = function() end }
    -- Provide a minimal bufs.input mock
    state.UI.bufs = { input = false }

    history.restore_history(1)

    assert.are.equal("first", state.State.query)
    assert.are.equal(1, state.State.history_idx)

    -- Cleanup mocks
    package.loaded["gelbooru.ui"] = nil
    package.loaded["gelbooru.net.api"] = nil
    state.UI.bufs = {}
  end)

  it("clamps cur to #posts on restore", function()
    history.push_history("q")
    state.State.posts = fake_posts(3)
    state.State.cur = 10  -- out of bounds
    history.save_current_history()
    history.push_history("q2")

    package.loaded["gelbooru.ui"] = {
      set_status = function() end,
      render_list = function() end,
      render_preview = function() end,
    }
    package.loaded["gelbooru.net.api"] = { fetch = function() end }
    state.UI.bufs = { input = false }

    history.restore_history(1)
    assert.is_true(state.State.cur <= 3)

    package.loaded["gelbooru.ui"] = nil
    package.loaded["gelbooru.net.api"] = nil
    state.UI.bufs = {}
  end)

  it("ignores out-of-bounds index silently", function()
    history.push_history("only")
    assert.has_no.errors(function()
      history.restore_history(99)
    end)
    -- history_idx unchanged
    assert.are.equal(1, state.State.history_idx)
  end)
end)
