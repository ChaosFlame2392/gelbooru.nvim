-- tests/integration/search_spec.lua
-- Integration test for gelbooru search entry, query execution, list repainting, and history updates.

local harness = require("tests.integration.helpers.harness")
local ui = require("gelbooru.ui")
local api = require("gelbooru.net.api")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")

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

  it("closes existing placement and clears canvas immediately when executing a new search", function()
    ui.open()
    api.execute_search("hatsune_miku")

    vim.wait(100, function()
      return #state.State.posts > 0
    end)

    -- Simulate an active image placement and previous preview content
    local fake_placement = {
      closed = false,
      close = function(self)
        self.closed = true
        if state.UI.current_placement == self then
          state.UI.current_placement = nil
        end
      end,
    }
    state.UI.current_placement = fake_placement
    util.set_lines(state.UI.bufs.img, { "  Previous image preview" })
    util.set_lines(state.UI.bufs.meta, { "  Previous metadata" })

    -- Execute a new search
    api.execute_search("zenless_zone_zero")

    -- Placement must be closed immediately
    assert.is_true(fake_placement.closed)
    assert.is_nil(state.UI.current_placement)

    -- Canvas must be cleared immediately to Loading... and meta to empty
    local img_lines = harness.get_buf_lines(state.UI.bufs.img)
    assert.are.same({ "  Loading..." }, img_lines)
    local meta_lines = harness.get_buf_lines(state.UI.bufs.meta)
    assert.are.same({ "" }, meta_lines)
  end)

  it("prepends id: when search query is a bare integer", function()
    ui.open()
    api.execute_search("12345")

    assert.are.equal("id:12345", state.State.query)
    assert.are.equal("id:12345", state.State.history[#state.State.history].query)
  end)

  describe("Adversarial: Stale preview invalidation & epoch safety", function()
    it("discards late network response from query A when query B was initiated rapidly", function()
      ui.open()
      local download = require("gelbooru.net.download")
      local captured = {}
      local orig_curl_async = download.curl_async

      download.curl_async = function(url, cb)
        if url:find("s=post") then
          table.insert(captured, { url = url, cb = cb })
        else
          orig_curl_async(url, cb)
        end
      end

      -- Launch search A
      api.execute_search("query_alpha")
      assert.are.equal(1, #captured)

      -- Immediately launch search B before A responds
      api.execute_search("query_beta")
      assert.are.equal(2, #captured)

      -- Search B responds first with its posts
      local beta_post = {
        id = 8888,
        rating = "general",
        score = 500,
        width = 1920,
        height = 1080,
        tags = "query_beta_exclusive tag2",
        file_url = "https://example.com/beta.jpg",
        preview_url = "https://example.com/beta_prev.jpg",
      }
      captured[2].cb(vim.fn.json_encode({ post = { beta_post } }))

      -- Confirm state reflects query B
      assert.are.equal("query_beta", state.State.query)
      assert.are.equal(1, #state.State.posts)
      assert.are.equal(8888, state.State.posts[1].id)

      -- Now simulate query A's delayed response arriving late
      local alpha_post = {
        id = 7777,
        rating = "sensitive",
        score = 100,
        width = 800,
        height = 600,
        tags = "query_alpha_exclusive tag1",
        file_url = "https://example.com/alpha.jpg",
        preview_url = "https://example.com/alpha_prev.jpg",
      }
      captured[1].cb(vim.fn.json_encode({ post = { alpha_post } }))

      -- Assert: query A was discarded, state still strictly belongs to query B
      assert.are.equal("query_beta", state.State.query)
      assert.are.equal(1, #state.State.posts)
      assert.are.equal(8888, state.State.posts[1].id)

      local meta_lines = harness.get_buf_lines(state.UI.bufs.meta)
      local meta_text = table.concat(meta_lines, "\n")
      assert.is_nil(meta_text:find("7777"))
      assert.is_nil(meta_text:find("query_alpha_exclusive"))

      download.curl_async = orig_curl_async
    end)

    it("prevents late response from query A from overwriting 'No posts found' when query B returned empty", function()
      ui.open()
      local download = require("gelbooru.net.download")
      local captured = {}
      local orig_curl_async = download.curl_async

      download.curl_async = function(url, cb)
        if url:find("s=post") then
          table.insert(captured, { url = url, cb = cb })
        else
          orig_curl_async(url, cb)
        end
      end

      -- Launch search A, then immediately search B
      api.execute_search("query_alpha")
      api.execute_search("query_beta_empty")
      assert.are.equal(2, #captured)

      -- Query B resolves with 0 posts
      captured[2].cb(vim.fn.json_encode({ post = {} }))

      assert.are.equal(0, #state.State.posts)
      local img_lines = harness.get_buf_lines(state.UI.bufs.img)
      assert.are.same({ "  No posts found" }, img_lines)

      -- Query A arrives late with posts
      local alpha_post = {
        id = 7777,
        rating = "general",
        score = 50,
        width = 500,
        height = 500,
        tags = "tag_a",
        file_url = "https://example.com/a.jpg",
      }
      captured[1].cb(vim.fn.json_encode({ post = { alpha_post } }))

      -- Canvas must STILL show "  No posts found" and State.posts must be empty
      assert.are.equal(0, #state.State.posts)
      local img_lines_after = harness.get_buf_lines(state.UI.bufs.img)
      assert.are.same({ "  No posts found" }, img_lines_after)

      download.curl_async = orig_curl_async
    end)
  end)

  describe("Adversarial: Bare integer search edge cases", function()
    it("rewrites pure digits with optional leading and trailing whitespace to id:<digits>", function()
      ui.open()

      -- Pure digits
      api.execute_search("9999")
      assert.are.equal("id:9999", state.State.query)
      assert.are.equal("id:9999", state.State.history[#state.State.history].query)
      assert.are.same({ "id:9999" }, harness.get_buf_lines(state.UI.bufs.input))

      -- Leading and trailing whitespace
      api.execute_search("  12345  ")
      assert.are.equal("id:12345", state.State.query)
      assert.are.equal("id:12345", state.State.history[#state.State.history].query)
      assert.are.same({ "id:12345" }, harness.get_buf_lines(state.UI.bufs.input))

      -- Tabs and spaces
      api.execute_search("\t  77777  \t")
      assert.are.equal("id:77777", state.State.query)
      assert.are.equal("id:77777", state.State.history[#state.State.history].query)
      assert.are.same({ "id:77777" }, harness.get_buf_lines(state.UI.bufs.input))
    end)

    it("does not rewrite mixed queries containing non-digits", function()
      ui.open()

      -- Digits followed by tag
      api.execute_search("12345 tag")
      assert.are.equal("12345 tag", state.State.query)

      -- Tag followed by digits
      api.execute_search("tag 12345")
      assert.are.equal("tag 12345", state.State.query)

      -- Alphanumeric mixed
      api.execute_search("12345tag")
      assert.are.equal("12345tag", state.State.query)

      -- Already prefixed id tag
      api.execute_search("id:12345")
      assert.are.equal("id:12345", state.State.query)

      -- Pure whitespace
      api.execute_search("   ")
      assert.are.equal("   ", state.State.query)
    end)

    it("rewrites space-separated id tag queries to normalized id:<digits>", function()
      ui.open()

      api.execute_search("  id:  12345 ")
      assert.are.equal("id:12345", state.State.query)
      assert.are.equal("id:12345", state.State.history[#state.State.history].query)

      api.execute_search("id: 99999")
      assert.are.equal("id:99999", state.State.query)
      assert.are.equal("id:99999", state.State.history[#state.State.history].query)
    end)
  end)

  describe("Adversarial: Placement error resilience & teardown race safety", function()
    it("protects execute_search via pcall if image.close_current_placement fails", function()
      ui.open()
      local image_mod = require("gelbooru.ui.image")
      local orig_close = image_mod.close_current_placement
      image_mod.close_current_placement = function()
        error("Simulated catastrophic close error")
      end

      assert.has_no.errors(function()
        api.execute_search("resilience_query")
      end)

      assert.are.equal("resilience_query", state.State.query)
      local img_lines = harness.get_buf_lines(state.UI.bufs.img)
      assert.are.same({ "  Loading..." }, img_lines)

      image_mod.close_current_placement = orig_close
    end)

    it("protects execute_search if current_placement:close() throws an error", function()
      ui.open()
      state.UI.current_placement = {
        close = function()
          error("Placement object close threw error")
        end,
      }

      assert.has_no.errors(function()
        api.execute_search("placement_obj_fail")
      end)

      assert.are.equal("placement_obj_fail", state.State.query)
      assert.is_nil(state.UI.current_placement)
    end)

    it("discards API response safely if teardown occurred while network request was in flight", function()
      ui.open()
      local download = require("gelbooru.net.download")
      local captured_cb = nil
      local orig_curl_async = download.curl_async

      download.curl_async = function(url, cb)
        if url:find("s=post") then
          captured_cb = cb
        else
          orig_curl_async(url, cb)
        end
      end

      api.execute_search("pending_race")
      assert.is_not_nil(captured_cb)

      -- UI teardown occurs while request is in flight
      ui.teardown()
      assert.is_true(state.State.torn_down)

      -- Response arrives after teardown
      assert.has_no.errors(function()
        captured_cb(vim.fn.json_encode({ post = { { id = 9999, tags = "race" } } }))
      end)

      -- Posts must remain empty and no errors raised
      assert.are.equal(0, #state.State.posts)

      download.curl_async = orig_curl_async
    end)

    it("ignores execute_search when State.torn_down is true", function()
      ui.open()
      ui.teardown()
      assert.is_true(state.State.torn_down)

      local prev_epoch = state.State.search_epoch
      api.execute_search("should_be_ignored")

      assert.are.not_equal("should_be_ignored", state.State.query)
      assert.are.equal(prev_epoch, state.State.search_epoch)
    end)
  end)
end)
