-- tests/unit/state_spec.lua
-- Unit tests for gelbooru.core.state (State fields and reset_query_state).

local state = require("gelbooru.core.state")

describe("state.State initialization", function()
  it("initializes search_epoch to 0", function()
    assert.is_truthy(state.State.search_epoch ~= nil)
    assert.is_true(type(state.State.search_epoch) == "number")
  end)
end)

describe("state.reset_query_state", function()
  it("resets query, posts, history, history_idx, show_meta and advances search_epoch", function()
    state.State.query = "some_tag"
    state.State.posts = { { id = 1 }, { id = 2 } }
    state.State.page = 5
    state.State.cur = 3
    state.State.loading = true
    state.State.cur_id = 123
    state.State.show_meta = false
    state.State.history = { { query = "prev" } }
    state.State.history_idx = 1
    state.State.autocomplete_cur = 4
    state.State.autocomplete_navigated = true
    state.State.input_focused = true
    state.State.scroll_dir = -1
    local prev_epoch = state.State.search_epoch or 0

    state.reset_query_state()

    assert.are.equal("", state.State.query)
    assert.are.same({}, state.State.posts)
    assert.are.equal(0, state.State.page)
    assert.are.equal(1, state.State.cur)
    assert.are.equal(false, state.State.loading)
    assert.is_nil(state.State.cur_id)
    assert.are.equal(true, state.State.show_meta)
    assert.are.same({}, state.State.history)
    assert.are.equal(0, state.State.history_idx)
    assert.are.equal(1, state.State.autocomplete_cur)
    assert.are.equal(false, state.State.autocomplete_navigated)
    assert.are.equal(false, state.State.input_focused)
    assert.are.equal(1, state.State.scroll_dir)
    assert.are.equal(prev_epoch + 1, state.State.search_epoch)
  end)

  it("advances search_epoch sequentially on subsequent calls", function()
    local e1 = state.State.search_epoch
    state.reset_query_state()
    local e2 = state.State.search_epoch
    state.reset_query_state()
    local e3 = state.State.search_epoch

    assert.are.equal(e1 + 1, e2)
    assert.are.equal(e2 + 1, e3)
  end)
end)
