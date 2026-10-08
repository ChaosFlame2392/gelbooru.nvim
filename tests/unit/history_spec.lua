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
  state.State.search_epoch = 0
  state.State.torn_down = false
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

  it("advances search_epoch, resets loading, closes placement and sets Loading... when posts exist", function()
    history.push_history("first")
    state.State.query = "first"
    state.State.posts = fake_posts(5)
    history.save_current_history()

    history.push_history("second")
    state.State.loading = true
    local start_epoch = state.State.search_epoch or 0

    local placement_closed = false
    state.UI.current_placement = {
      close = function()
        placement_closed = true
      end,
    }

    local img_buf = vim.api.nvim_create_buf(false, true)
    local meta_buf = vim.api.nvim_create_buf(false, true)
    state.UI.bufs = { img = img_buf, meta = meta_buf, input = false }

    package.loaded["gelbooru.ui"] = {
      set_status = function() end,
      render_list = function() end,
      render_preview = function() end,
    }
    package.loaded["gelbooru.net.api"] = { fetch = function() end }

    history.restore_history(1)

    assert.are.equal(start_epoch + 1, state.State.search_epoch)
    assert.is_false(state.State.loading)
    assert.is_true(placement_closed)
    assert.is_nil(state.UI.current_placement)

    local img_lines = vim.api.nvim_buf_get_lines(img_buf, 0, -1, false)
    assert.are.same({ "  Loading..." }, img_lines)

    package.loaded["gelbooru.ui"] = nil
    package.loaded["gelbooru.net.api"] = nil
    pcall(vim.api.nvim_buf_delete, img_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, meta_buf, { force = true })
    state.UI.bufs = {}
  end)

  it("sets No posts found when restoring history entry with 0 posts", function()
    history.push_history("empty_query")
    state.State.query = "empty_query"
    state.State.posts = {}
    history.save_current_history()

    history.push_history("second")

    local img_buf = vim.api.nvim_create_buf(false, true)
    local meta_buf = vim.api.nvim_create_buf(false, true)
    state.UI.bufs = { img = img_buf, meta = meta_buf, input = false }

    package.loaded["gelbooru.ui"] = {
      set_status = function() end,
      render_list = function() end,
      render_preview = function() end,
    }
    package.loaded["gelbooru.net.api"] = { fetch = function() end }

    history.restore_history(1)

    local img_lines = vim.api.nvim_buf_get_lines(img_buf, 0, -1, false)
    assert.are.same({ "  No posts found" }, img_lines)

    package.loaded["gelbooru.ui"] = nil
    package.loaded["gelbooru.net.api"] = nil
    pcall(vim.api.nvim_buf_delete, img_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, meta_buf, { force = true })
    state.UI.bufs = {}
  end)

  it("handles rapid history navigation ([ and ]) back and forth across empty and populated history entries", function()
    -- Entry 1: empty
    history.push_history("empty_1")
    state.State.query = "empty_1"
    state.State.posts = {}
    history.save_current_history()

    -- Entry 2: populated
    history.push_history("populated_2")
    state.State.query = "populated_2"
    state.State.posts = fake_posts(2)
    history.save_current_history()

    -- Entry 3: empty
    history.push_history("empty_3")
    state.State.query = "empty_3"
    state.State.posts = {}
    history.save_current_history()

    -- Entry 4: populated
    history.push_history("populated_4")
    state.State.query = "populated_4"
    state.State.posts = fake_posts(4)
    history.save_current_history()

    local img_buf = vim.api.nvim_create_buf(false, true)
    local meta_buf = vim.api.nvim_create_buf(false, true)
    state.UI.bufs = { img = img_buf, meta = meta_buf, input = false }

    package.loaded["gelbooru.ui"] = {
      set_status = function() end,
      render_list = function() end,
      render_preview = function() end,
    }
    package.loaded["gelbooru.net.api"] = { fetch = function() end }

    -- Navigate to 4 initially
    history.restore_history(4)
    local epoch_at_4 = state.State.search_epoch

    -- 1. Step back to 3 (empty): history_prev
    local placement_3 = {
      closed = false,
      close = function(self)
        self.closed = true
        if state.UI.current_placement == self then
          state.UI.current_placement = nil
        end
      end,
    }
    state.UI.current_placement = placement_3
    history.history_prev()
    assert.are.equal(3, state.State.history_idx)
    assert.is_true(placement_3.closed)
    assert.is_nil(state.UI.current_placement)
    assert.is_true(state.State.search_epoch > epoch_at_4)
    local img_lines_3 = vim.api.nvim_buf_get_lines(img_buf, 0, -1, false)
    assert.are.same({ "  No posts found" }, img_lines_3)

    -- 2. Step back to 2 (populated): history_prev
    local placement_2 = {
      closed = false,
      close = function(self)
        self.closed = true
        if state.UI.current_placement == self then
          state.UI.current_placement = nil
        end
      end,
    }
    state.UI.current_placement = placement_2
    local epoch_at_3 = state.State.search_epoch
    history.history_prev()
    assert.are.equal(2, state.State.history_idx)
    assert.is_true(placement_2.closed)
    assert.is_nil(state.UI.current_placement)
    assert.is_true(state.State.search_epoch > epoch_at_3)
    local img_lines_2 = vim.api.nvim_buf_get_lines(img_buf, 0, -1, false)
    assert.are.same({ "  Loading..." }, img_lines_2)

    -- 3. Step back to 1 (empty): history_prev
    local placement_1 = {
      closed = false,
      close = function(self)
        self.closed = true
        if state.UI.current_placement == self then
          state.UI.current_placement = nil
        end
      end,
    }
    state.UI.current_placement = placement_1
    local epoch_at_2 = state.State.search_epoch
    history.history_prev()
    assert.are.equal(1, state.State.history_idx)
    assert.is_true(placement_1.closed)
    assert.is_nil(state.UI.current_placement)
    assert.is_true(state.State.search_epoch > epoch_at_2)
    local img_lines_1 = vim.api.nvim_buf_get_lines(img_buf, 0, -1, false)
    assert.are.same({ "  No posts found" }, img_lines_1)

    -- 4. Step forward to 2 (populated): history_next
    local placement_f2 = {
      closed = false,
      close = function(self)
        self.closed = true
        if state.UI.current_placement == self then
          state.UI.current_placement = nil
        end
      end,
    }
    state.UI.current_placement = placement_f2
    local epoch_at_1 = state.State.search_epoch
    history.history_next()
    assert.are.equal(2, state.State.history_idx)
    assert.is_true(placement_f2.closed)
    assert.is_nil(state.UI.current_placement)
    assert.is_true(state.State.search_epoch > epoch_at_1)
    local img_lines_f2 = vim.api.nvim_buf_get_lines(img_buf, 0, -1, false)
    assert.are.same({ "  Loading..." }, img_lines_f2)

    -- 5. Step forward to 3 (empty): history_next
    local placement_f3 = {
      closed = false,
      close = function(self)
        self.closed = true
        if state.UI.current_placement == self then
          state.UI.current_placement = nil
        end
      end,
    }
    state.UI.current_placement = placement_f3
    local epoch_at_f2 = state.State.search_epoch
    history.history_next()
    assert.are.equal(3, state.State.history_idx)
    assert.is_true(placement_f3.closed)
    assert.is_nil(state.UI.current_placement)
    assert.is_true(state.State.search_epoch > epoch_at_f2)
    local img_lines_f3 = vim.api.nvim_buf_get_lines(img_buf, 0, -1, false)
    assert.are.same({ "  No posts found" }, img_lines_f3)

    -- 6. Step forward to 4 (populated): history_next
    local placement_f4 = {
      closed = false,
      close = function(self)
        self.closed = true
        if state.UI.current_placement == self then
          state.UI.current_placement = nil
        end
      end,
    }
    state.UI.current_placement = placement_f4
    local epoch_at_f3 = state.State.search_epoch
    history.history_next()
    assert.are.equal(4, state.State.history_idx)
    assert.is_true(placement_f4.closed)
    assert.is_nil(state.UI.current_placement)
    assert.is_true(state.State.search_epoch > epoch_at_f3)
    local img_lines_f4 = vim.api.nvim_buf_get_lines(img_buf, 0, -1, false)
    assert.are.same({ "  Loading..." }, img_lines_f4)

    package.loaded["gelbooru.ui"] = nil
    package.loaded["gelbooru.net.api"] = nil
    pcall(vim.api.nvim_buf_delete, img_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, meta_buf, { force = true })
    state.UI.bufs = {}
  end)

  it("handles image placement close errors resiliently via pcall during restore_history", function()
    history.push_history("first")
    state.State.query = "first"
    state.State.posts = fake_posts(3)
    history.save_current_history()

    history.push_history("second")

    local img_buf = vim.api.nvim_create_buf(false, true)
    local meta_buf = vim.api.nvim_create_buf(false, true)
    state.UI.bufs = { img = img_buf, meta = meta_buf, input = false }

    package.loaded["gelbooru.ui"] = {
      set_status = function() end,
      render_list = function() end,
      render_preview = function() end,
    }
    package.loaded["gelbooru.net.api"] = { fetch = function() end }

    -- Simulate an explosive placement whose close() throws an error
    state.UI.current_placement = {
      close = function()
        error("Catastrophic error in placement close")
      end,
    }

    assert.has_no.errors(function()
      history.restore_history(1)
    end)

    assert.are.equal(1, state.State.history_idx)
    assert.are.equal("first", state.State.query)
    assert.are.equal(3, #state.State.posts)

    package.loaded["gelbooru.ui"] = nil
    package.loaded["gelbooru.net.api"] = nil
    pcall(vim.api.nvim_buf_delete, img_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, meta_buf, { force = true })
    state.UI.bufs = {}
  end)

  it("aborts restore_history immediately when State.torn_down is true", function()
    history.push_history("entry1")
    history.push_history("entry2")
    state.State.history_idx = 2
    state.State.torn_down = true
    local start_epoch = state.State.search_epoch or 0

    assert.has_no.errors(function()
      history.restore_history(1)
    end)

    -- history_idx and search_epoch must remain unchanged
    assert.are.equal(2, state.State.history_idx)
    assert.are.equal(start_epoch, state.State.search_epoch)
  end)
end)
