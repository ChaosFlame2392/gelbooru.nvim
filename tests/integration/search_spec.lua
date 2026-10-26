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

  it("isolates input buffer from external completion popups", function()
    ui.open()

    local input_buf = state.UI.bufs.input
    assert.is_not_nil(input_buf)
    assert.is_true(vim.api.nvim_buf_is_valid(input_buf))

    assert.are.equal("nofile", vim.bo[input_buf].buftype)
    assert.are.equal("wipe", vim.bo[input_buf].bufhidden)
    assert.are.equal("", vim.bo[input_buf].omnifunc)
    assert.are.equal("", vim.bo[input_buf].completefunc)
    assert.are.equal("", vim.bo[input_buf].completeopt)

    assert.is_false(vim.b[input_buf].cmp_enabled)
    assert.is_false(vim.b[input_buf].blink_cmp_enabled)
    assert.is_false(vim.b[input_buf].completion)
    assert.is_true(vim.b[input_buf].copilot_disabled)
    assert.is_false(vim.b[input_buf].codecompanion_enabled)
    assert.is_false(vim.b[input_buf].supermaven)
    assert.is_false(vim.b[input_buf].codeium_enabled)
    assert.is_true(vim.b[input_buf].codeium_disable)
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
    it("protects execute_search via pcall if canvas.close fails", function()
      ui.open()
      local canvas = require("gelbooru.ui.canvas")
      local orig_close = canvas.close
      canvas.close = function()
        error("Simulated catastrophic close error")
      end

      assert.has_no.errors(function()
        api.execute_search("resilience_query")
      end)

      assert.are.equal("resilience_query", state.State.query)
      local img_lines = harness.get_buf_lines(state.UI.bufs.img)
      assert.are.same({ "  Loading..." }, img_lines)

      canvas.close = orig_close
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

    it("reseeds online search when sort:random is used, bypassing identical query guard and appending nonce", function()
      ui.open()
      local download = require("gelbooru.net.download")

      local requested_urls = {}
      local current_curl = download.curl_async
      download.curl_async = function(url, cb)
        if url:find("s=post") then
          table.insert(requested_urls, url)
        end
        current_curl(url, cb)
      end

      api.execute_search("hatsune_miku sort:random")
      vim.wait(100, function()
        return #state.State.posts > 0
      end)

      assert.are.equal(1, #requested_urls)
      assert.is_truthy(requested_urls[1]:find("&_nonce="))

      -- Re-executing identical query with sort:random bypasses guard and issues second fetch with fresh nonce
      api.execute_search("hatsune_miku sort:random")
      vim.wait(100, function()
        return #requested_urls >= 2
      end)

      assert.are.equal(2, #requested_urls)
      assert.is_truthy(requested_urls[2]:find("&_nonce="))
      assert.are.not_equal(requested_urls[1], requested_urls[2])

      download.curl_async = current_curl
    end)

    it("delegates to ui.open_local when local: is placed anywhere in the query string", function()
      ui.open()
      local open_local_called = false
      local open_local_query = nil
      local orig_open_local = ui.open_local
      ui.open_local = function(q)
        open_local_called = true
        open_local_query = q
      end

      api.execute_search("solo hatsune_miku local: sort:score")
      assert.is_true(open_local_called)
      assert.are.equal("solo hatsune_miku local: sort:score", open_local_query)

      open_local_called = false
      api.execute_search("~foot_focus local:")
      assert.is_true(open_local_called)
      assert.are.equal("~foot_focus local:", open_local_query)

      ui.open_local = orig_open_local
    end)

    it("QA 1: online search does not hijack is_local:true or -local:tag", function()
      ui.open()
      local open_local_called = false
      local orig_open_local = ui.open_local
      ui.open_local = function()
        open_local_called = true
      end

      api.execute_search("is_local:true")
      assert.is_false(open_local_called)

      api.execute_search("-local:tag")
      assert.is_false(open_local_called)

      api.execute_search("nonlocal:tag")
      assert.is_false(open_local_called)

      ui.open_local = orig_open_local
    end)

    it("QA 3: case-insensitive sort:RANDOM and order:Random online reseeding", function()
      ui.open()
      local download = require("gelbooru.net.download")

      local requested_urls = {}
      local current_curl = download.curl_async
      download.curl_async = function(url, cb)
        if url:find("s=post") then
          table.insert(requested_urls, url)
        end
        current_curl(url, cb)
      end

      api.execute_search("hatsune_miku sort:RANDOM")
      vim.wait(100, function()
        return #state.State.posts > 0
      end)

      assert.are.equal(1, #requested_urls)
      assert.is_truthy(requested_urls[1]:find("&_nonce="))

      -- Second execution bypasses guard due to case-insensitive match
      api.execute_search("hatsune_miku sort:RANDOM")
      vim.wait(100, function()
        return #requested_urls >= 2
      end)

      assert.are.equal(2, #requested_urls)
      assert.is_truthy(requested_urls[2]:find("&_nonce="))
      assert.are.not_equal(requested_urls[1], requested_urls[2])

      download.curl_async = current_curl
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

  describe("Multi-Stage Piped Online Search (| sort:<key>[:<limit>])", function()
    it("fetches multi-page candidate pool up to pool limit, then reduces by score and randomizes in memory", function()
      ui.open()
      local download = require("gelbooru.net.download")
      local requested_urls = {}

      -- Simulate 300 posts on Gelbooru: 3 pages of 100 posts each
      local dummy_pages = {}
      for page = 0, 2 do
        local page_posts = {}
        for i = 1, 100 do
          local id_num = 300 - (page * 100 + i - 1) -- 300 down to 1
          table.insert(page_posts, {
            id = id_num,
            score = (id_num % 100), -- scores 0..99
            tags = "hatsune_miku 1girl",
            file_url = string.format("https://example.com/%d.jpg", id_num),
            preview_url = string.format("https://example.com/%d_p.jpg", id_num),
          })
        end
        dummy_pages[page] = page_posts
      end

      local orig_curl_async = download.curl_async
      download.curl_async = function(url, cb)
        if url:find("s=post") then
          table.insert(requested_urls, url)
          local pid = tonumber(url:match("pid=(%d+)")) or 0
          local posts = dummy_pages[pid] or {}
          vim.schedule(function()
            cb(vim.fn.json_encode({ post = posts }))
          end)
        else
          orig_curl_async(url, cb)
        end
      end

      -- Query: hatsune_miku | sort:id:300 | sort:score:50 | sort:random
      api.execute_search("hatsune_miku | sort:id:300 | sort:score:50 | sort:random")

      vim.wait(500, function()
        return #state.State.posts > 0 and not state.State.loading
      end, 20)

      -- 1. Verify candidate pool batch fetching
      assert.are.equal(3, #requested_urls)
      assert.is_truthy(requested_urls[1]:find("limit=100") and requested_urls[1]:find("pid=0"))
      assert.is_truthy(requested_urls[2]:find("limit=100") and requested_urls[2]:find("pid=1"))
      assert.is_truthy(requested_urls[3]:find("limit=100") and requested_urls[3]:find("pid=2"))

      -- 2. Verify remote query included sort:id
      assert.is_truthy(requested_urls[1]:find("sort%%3Aid") or requested_urls[1]:find("sort:id"))

      -- 3. Verify in-memory reduction to top 50 scores
      assert.are.equal(50, #state.State.posts)
      for _, p in ipairs(state.State.posts) do
        assert.is_truthy(tonumber(p.score) >= 50)
      end

      -- 4. Verify list rendering & cursor
      assert.are.equal(1, state.State.cur)
      local list_lines = harness.get_buf_lines(state.UI.bufs.list)
      assert.are.equal(50, #list_lines)
      assert.is_truthy(list_lines[1]:find("▶"))

      download.curl_async = orig_curl_async
    end)

    it("single-page candidate pool fetching when pool limit <= 100", function()
      ui.open()
      local download = require("gelbooru.net.download")
      local requested_urls = {}

      local sample_posts = {}
      for i = 1, 40 do
        table.insert(sample_posts, {
          id = 1000 + i,
          score = i * 2,
          tags = "solo",
          file_url = string.format("https://example.com/%d.jpg", 1000 + i),
        })
      end

      local orig_curl_async = download.curl_async
      download.curl_async = function(url, cb)
        if url:find("s=post") then
          table.insert(requested_urls, url)
          vim.schedule(function()
            cb(vim.fn.json_encode({ post = sample_posts }))
          end)
        else
          orig_curl_async(url, cb)
        end
      end

      api.execute_search("solo | sort:score:15 | sort:random")

      vim.wait(300, function()
        return #state.State.posts > 0 and not state.State.loading
      end, 20)

      -- Only 1 batch request issued with limit=15
      assert.are.equal(1, #requested_urls)
      assert.is_truthy(requested_urls[1]:find("limit=15"))
      assert.is_truthy(requested_urls[1]:find("sort%%3Ascore") or requested_urls[1]:find("sort:score"))
      assert.are.equal(15, #state.State.posts)

      download.curl_async = orig_curl_async
    end)

    it("handles server returning fewer posts than requested without hanging", function()
      ui.open()
      local download = require("gelbooru.net.download")

      local orig_curl_async = download.curl_async
      download.curl_async = function(url, cb)
        if url:find("s=post") then
          -- Return 10 posts even though limit requested 100
          local short_batch = {}
          for i = 1, 10 do
            table.insert(short_batch, { id = 500 + i, score = i, file_url = "https://example.com/short.jpg" })
          end
          vim.schedule(function()
            cb(vim.fn.json_encode({ post = short_batch }))
          end)
        else
          orig_curl_async(url, cb)
        end
      end

      -- Target pool 500, but server returns only 10
      api.execute_search("short_tag | sort:id:500 | sort:score:5 | sort:random")

      vim.wait(300, function()
        return #state.State.posts > 0 and not state.State.loading
      end, 20)

      -- Pipeline completes with available posts reduced to 5
      assert.are.equal(5, #state.State.posts)

      download.curl_async = orig_curl_async
    end)

    it("handles empty API response on piped search gracefully", function()
      ui.open()
      local download = require("gelbooru.net.download")

      local orig_curl_async = download.curl_async
      download.curl_async = function(url, cb)
        if url:find("s=post") then
          vim.schedule(function()
            cb(vim.fn.json_encode({ post = {} }))
          end)
        else
          orig_curl_async(url, cb)
        end
      end

      api.execute_search("nonexistent_tag | sort:id:1000 | sort:random")

      vim.wait(300, function()
        return not state.State.loading
      end, 20)

      assert.are.equal(0, #state.State.posts)
      local img_lines = harness.get_buf_lines(state.UI.bufs.img)
      assert.are.same({ "  No posts found" }, img_lines)

      download.curl_async = orig_curl_async
    end)

    it("guards forward and backward pagination on piped searches without issuing network requests and displays notice", function()
      ui.open()
      local download = require("gelbooru.net.download")
      local curl_called = false
      local orig_curl_async = download.curl_async

      -- Prepopulate state as if a piped search had completed
      state.State.query = "miku | sort:id:500 | sort:random"
      state.State.posts = { { id = 1, tags = "miku", score = 10 } }
      state.State.page = 1
      state.State.loading = false

      download.curl_async = function(url, cb)
        if url:find("s=post") then
          curl_called = true
        else
          orig_curl_async(url, cb)
        end
      end

      -- Attempt forward pagination (<Tab> / api.fetch(1))
      api.fetch(1)
      assert.is_false(curl_called)
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1] and status_lines[1]:find("Pagination not supported on piped searches"))

      -- Attempt backward pagination (<S-Tab> / api.fetch(-1))
      api.fetch(-1)
      assert.is_false(curl_called)
      assert.are.equal(1, #state.State.posts)

      download.curl_async = orig_curl_async
    end)

    it("processes partial candidate pool into top scores on mid-stream network failure without hanging", function()
      ui.open()
      local download = require("gelbooru.net.download")

      local req_count = 0
      local orig_curl_async = download.curl_async
      download.curl_async = function(url, cb)
        if url:find("s=post") then
          req_count = req_count + 1
          if req_count == 1 then
            -- Page 1 succeeds with 100 posts (scores 1..100)
            local page1_posts = {}
            for i = 1, 100 do
              table.insert(page1_posts, { id = 1000 + i, score = i, file_url = "https://example.com/p.jpg" })
            end
            vim.schedule(function()
              cb(vim.fn.json_encode({ post = page1_posts }))
            end)
          else
            -- Page 2 fails (e.g. network disconnect returning nil)
            vim.schedule(function()
              cb(nil)
            end)
          end
        else
          orig_curl_async(url, cb)
        end
      end

      -- Target pool 300 posts, reduce to top 20 scores
      api.execute_search("network_test | sort:id:300 | sort:score:20")

      vim.wait(300, function()
        return not state.State.loading and #state.State.posts > 0
      end, 20)

      -- Verify it recovered from mid-stream failure, finished the pipeline with available 100 posts,
      -- and reduced to top 20 scores (scores 81..100)
      assert.is_false(state.State.loading)
      assert.are.equal(20, #state.State.posts)
      assert.are.equal(100, tonumber(state.State.posts[1].score))
      download.curl_async = orig_curl_async
    end)

    it("standalone sort:id:5 without pipe limits candidate pool and results to 5 posts in online mode", function()
      ui.open()
      local download = require("gelbooru.net.download")
      local orig_curl_async = download.curl_async

      download.curl_async = function(url, cb)
        if url:find("s=post") then
          local mock_posts = {}
          for i = 1, 42 do
            table.insert(mock_posts, {
              id = tostring(i),
              score = tostring(i * 10),
              tags = "miku solo",
              file_url = "https://example.com/" .. i .. ".jpg",
            })
          end
          vim.schedule(function()
            cb(vim.fn.json_encode({ post = mock_posts }))
          end)
        else
          orig_curl_async(url, cb)
        end
      end

      api.execute_search("sort:id:5")

      vim.wait(300, function()
        return not state.State.loading and #state.State.posts > 0
      end, 20)

      assert.is_false(state.State.loading)
      assert.are.equal(5, #state.State.posts)
      -- Sorted by ID desc: 42, 41, 40, 39, 38
      assert.are.equal("42", state.State.posts[1].id)
      assert.are.equal("38", state.State.posts[5].id)

      download.curl_async = orig_curl_async
    end)

    it("sets pool_target to 1000 and preserves -video in remote_tags for zenless_zone_zero sort:id:1000|sort:score:200|sort:random -video", function()
      ui.open()
      local download = require("gelbooru.net.download")
      local orig_curl_async = download.curl_async
      local captured_urls = {}
      local status_messages = {}

      local orig_set_status = ui.set_status
      ui.set_status = function(msg, dur)
        if msg then
          table.insert(status_messages, msg)
        end
        return orig_set_status(msg, dur)
      end

      -- Mock 3 batches of 100 posts (300 posts total), with IDs from 1 to 300
      download.curl_async = function(url, cb)
        if url:find("s=post") then
          table.insert(captured_urls, url)
          local pid = tonumber(url:match("pid=(%d+)")) or 0
          local posts = {}
          for i = 1, 100 do
            local id_num = (pid * 100) + i
            table.insert(posts, {
              id = tostring(id_num),
              score = tostring(id_num * 2),
              tags = "zenless_zone_zero",
              file_url = string.format("https://example.com/%d.jpg", id_num),
            })
          end
          vim.schedule(function()
            cb(vim.fn.json_encode({ post = posts }))
          end)
        else
          orig_curl_async(url, cb)
        end
      end

      api.execute_search("zenless_zone_zero sort:id:1000|sort:score:200|sort:random -video")

      vim.wait(500, function()
        return not state.State.loading and #state.State.posts > 0
      end, 20)

      assert.is_false(state.State.loading)

      -- 1. Verify remote_tags URL encoding preserves base_query (-video) and sort:id:desc
      assert.is_true(#captured_urls > 0)
      local first_url = captured_urls[1]
      assert.is_truthy(first_url:find("zenless_zone_zero"))
      assert.is_truthy(first_url:find("%-video") or first_url:find("-video"))
      assert.is_truthy(first_url:find("sort%%3Aid") or first_url:find("sort:id"))

      -- 2. Verify status messages reflect candidate pool target of 1000
      local found_target_1000 = false
      for _, msg in ipairs(status_messages) do
        if msg:find("/1000") then
          found_target_1000 = true
          break
        end
      end
      assert.is_true(found_target_1000)

      -- 3. Verify in-memory reduction sliced down to 200 posts (Stage 2 sort:score:200)
      assert.are.equal(200, #state.State.posts)

      download.curl_async = orig_curl_async
      ui.set_status = orig_set_status
    end)

    it("Phase 1: executes piped search with server-side offset jump (sort:id:1000..1200 starts at pid=10)", function()
      ui.open()
      local download = require("gelbooru.net.download")
      local orig_curl_async = download.curl_async
      local captured_urls = {}

      download.curl_async = function(url, cb)
        if url:find("s=post") then
          table.insert(captured_urls, url)
          local pid = tonumber(url:match("pid=(%d+)")) or 0
          local posts = {}
          for i = 1, 100 do
            local id_num = (pid * 100) + i
            table.insert(posts, {
              id = tostring(id_num),
              score = tostring(id_num),
              tags = "miku",
              file_url = string.format("https://example.com/%d.jpg", id_num),
            })
          end
          vim.schedule(function()
            cb(vim.fn.json_encode({ post = posts }))
          end)
        else
          orig_curl_async(url, cb)
        end
      end

      api.execute_search("miku sort:id:1000..1200")

      vim.wait(500, function()
        return not state.State.loading and #state.State.posts > 0
      end, 20)

      assert.is_false(state.State.loading)
      assert.is_true(#captured_urls > 0)
      -- First request MUST jump directly to pid=10 (1000 / 100 = 10)
      assert.is_truthy(captured_urls[1]:find("pid=10"))
      -- Verify we got 200 posts
      assert.are.equal(200, #state.State.posts)

      download.curl_async = orig_curl_async
    end)

    it("Phase 2: restore_history re-executes search when State.posts is empty", function()
      local history = require("gelbooru.core.history")
      ui.open()

      local search_executed = nil
      local orig_execute = api.execute_search
      api.execute_search = function(q, opts)
        search_executed = q
        state.State.posts = {}
      end

      -- Push history 1 with empty posts
      state.State.query = "obscure_tag | sort:score:10"
      state.State.posts = {}
      history.push_history("obscure_tag | sort:score:10")
      history.save_current_history()

      -- Now push history 2 with posts
      history.push_history("miku")
      state.State.query = "miku"
      state.State.posts = { { id = "1", file_url = "/1.jpg" } }
      history.save_current_history()

      assert.are.equal(2, #state.State.history)
      assert.are.equal(2, state.State.history_idx)

      -- Restore previous history (idx 1, which had empty posts)
      history.restore_history(1)

      -- Should have called api.execute_search instead of api.fetch(1)
      assert.are.equal("obscure_tag | sort:score:10", search_executed)
      -- History length should remain 2 (not duplicated)
      assert.are.equal(2, #state.State.history)
      assert.are.equal(1, state.State.history_idx)

      api.execute_search = orig_execute
    end)

    it("Phase 2: autocomplete does not trigger API lookup for syntax directives", function()
      ui.open()
      local download = require("gelbooru.net.download")
      local orig_curl_async = download.curl_async
      local tags_api_called = false

      download.curl_async = function(url, cb)
        if url:find("s=tag") then
          tags_api_called = true
        end
        orig_curl_async(url, cb)
      end

      local ac = require("gelbooru.ui.autocomplete")
      -- Directly test autocomplete with directives
      ac.update_autocomplete("sort:s")
      ac.update_autocomplete("order:r")
      ac.update_autocomplete("limit:1")
      ac.update_autocomplete("offset:1")

      vim.wait(100, function() return false end, 20)
      assert.is_false(tags_api_called)

      download.curl_async = orig_curl_async
    end)

    it("Phase 2: autocomplete preserves leading delimiter in submit_input and Space commit", function()
      ui.open()
      local catalog = require("gelbooru.tags.catalog")
      catalog.add_tag({ n = "hatsune_miku", c = 5000, t = 4 })
      local ac = require("gelbooru.ui.autocomplete")

      local function get_cb(buf, mode, key)
        local maps = vim.api.nvim_buf_get_keymap(buf, mode)
        for _, m in ipairs(maps) do
          if m.lhs == key or (key == "<Space>" and m.lhs == " ") then return m.callback end
        end
      end

      -- 1. Test <CR> submit_input with leading pipe delimiter
      vim.api.nvim_buf_set_lines(state.UI.bufs.input, 0, -1, false, { "|hatsune" })
      vim.api.nvim_win_set_cursor(state.UI.wins.input, { 1, 8 })
      ac.update_autocomplete("|hatsune")

      state.State.autocomplete_navigated = true
      state.State.autocomplete_cur = 1

      local cr_cb = get_cb(state.UI.bufs.input, "n", "<CR>")
      assert.is_not_nil(cr_cb)
      cr_cb()

      assert.are.equal("|hatsune_miku", state.State.query)

      -- 2. Test <Space> auto-commit with leading minus delimiter
      vim.api.nvim_buf_set_lines(state.UI.bufs.input, 0, -1, false, { "-hatsune_miku" })
      vim.api.nvim_win_set_cursor(state.UI.wins.input, { 1, 13 })
      ac.update_autocomplete("-hatsune_miku")
      state.State.autocomplete_cur = 1

      local sp_cb = get_cb(state.UI.bufs.input, "i", "<Space>")
      assert.is_not_nil(sp_cb)
      sp_cb()

      local committed_line = vim.api.nvim_buf_get_lines(state.UI.bufs.input, 0, 1, false)[1]
      assert.are.equal("-hatsune_miku ", committed_line)
    end)

    it("Issue 6: ~sort:/~order: are stripped; ratings translate to native Gelbooru syntax, and tags are normalized", function()
      -- Ratings: single rating translates directly to rating:<name>
      assert.are.equal("rating:general", api.normalize_remote_tags("~rating:general"))
      assert.are.equal("rating:explicit", api.normalize_remote_tags("~rating:explicit"))
      assert.are.equal("rating:questionable", api.normalize_remote_tags("~rating:questionable"))

      -- Rating OR (e.g. explicit OR questionable): translates to native exclusions of unselected ratings
      assert.are.equal(
        "zenless_zone_zero -rating:general -rating:sensitive",
        api.normalize_remote_tags("zenless_zone_zero ~rating:explicit ~rating:questionable")
      )

      -- Single tag with ~: "1 out of 1 is just 1", stripped so Gelbooru finds it
      assert.are.equal("foot_focus", api.normalize_remote_tags("~foot_focus"))
      assert.are.equal("score:100", api.normalize_remote_tags("~score:100"))
      assert.are.equal("id:12345", api.normalize_remote_tags("~id:12345"))

      -- Multi-tag OR returns executable branches:
      local branches = api.normalize_remote_query("~foot_focus ~soles")
      assert.are.equal(2, #branches)
      assert.are.equal("foot_focus", branches[1])
      assert.are.equal("soles", branches[2])

      -- Only ~sort: and ~order: (sorting directives, not filterable tags) get ~ stripped
      assert.are.equal("sort:score", api.normalize_remote_tags("~sort:score"))
      assert.are.equal("sort:id:desc", api.normalize_remote_tags("~sort:id:desc"))
      assert.are.equal("order:id:desc", api.normalize_remote_tags("~order:id:desc"))

      -- Integration: verify remote curl query sends native -rating:general -rating:sensitive for rating OR
      ui.open()
      local download = require("gelbooru.net.download")
      local orig_curl_async = download.curl_async
      local captured_urls = {}

      download.curl_async = function(url, cb)
        if url:find("s=post") then
          table.insert(captured_urls, url)
          local posts = {
            { id = "1", score = "100", tags = "miku", file_url = "https://example.com/1.jpg" },
          }
          vim.schedule(function()
            cb(vim.fn.json_encode({ post = posts }))
          end)
        else
          orig_curl_async(url, cb)
        end
      end

      -- zenless_zone_zero ~rating:explicit ~rating:questionable sends native query without ~
      api.execute_search("zenless_zone_zero ~rating:explicit ~rating:questionable")
      vim.wait(200, function()
        return not state.State.loading and #state.State.posts > 0
      end, 20)

      assert.is_true(#captured_urls > 0)
      local req_url = captured_urls[1]
      -- Gelbooru requires -rating:general and -rating:sensitive to match explicit or questionable
      assert.is_truthy(
        req_url:find("%%2Drating%%3Ageneral") or req_url:find("%-rating:general") or req_url:find("rating%%3Ageneral"),
        "outgoing URL must exclude general rating, got: " .. req_url
      )

      -- ~sort: IS stripped — verify
      captured_urls = {}
      api.execute_search("hatsune_miku ~sort:score")
      vim.wait(200, function()
        return not state.State.loading and #state.State.posts > 0
      end, 20)
      assert.is_true(#captured_urls > 0)
      local sort_url = captured_urls[1]
      -- ~sort: stripped to sort:, so ~sort should not appear
      assert.is_falsy(
        sort_url:find("%%7Esort") or sort_url:find("~sort"),
        "~sort: must be stripped from outgoing URL"
      )

      download.curl_async = orig_curl_async
    end)

    it("Issue 5: executes piped search with open-ended range (sort:id:50..)", function()
      ui.open()
      local config = require("gelbooru.core.config")
      local download = require("gelbooru.net.download")
      local orig_curl_async = download.curl_async
      local captured_urls = {}

      download.curl_async = function(url, cb)
        if url:find("s=post") then
          table.insert(captured_urls, url)
          local pid = tonumber(url:match("pid=(%d+)")) or 0
          local limit = tonumber(url:match("limit=(%d+)")) or 100
          local posts = {}
          for i = 1, limit do
            local id_num = (pid * 100) + i
            table.insert(posts, {
              id = tostring(id_num),
              score = tostring(id_num),
              tags = "miku",
              file_url = string.format("https://example.com/%d.jpg", id_num),
            })
          end
          vim.schedule(function()
            cb(vim.fn.json_encode({ post = posts }))
          end)
        else
          orig_curl_async(url, cb)
        end
      end

      -- sort:id:50.. has offset = 50, limit = nil
      -- pool_target = math.min(50 + config.options.per_page, 2000)
      api.execute_search("miku sort:id:50..")

      vim.wait(500, function()
        return not state.State.loading and #state.State.posts > 0
      end, 20)

      assert.is_false(state.State.loading)
      assert.is_true(#captured_urls > 0)
      -- First request fetches batch 1 (pid=0)
      assert.is_truthy(captured_urls[1]:find("pid=0"))
      -- rel_start = 50 - 0 + 1 = 51, rel_end = #candidate_pool = pool_target -> config.options.per_page items
      local expected_count = config.options.per_page
      assert.are.equal(expected_count, #state.State.posts)
      assert.are.equal("51", state.State.posts[1].id)
      assert.are.equal(tostring(50 + expected_count), state.State.posts[#state.State.posts].id)

      download.curl_async = orig_curl_async
    end)

    it("normalize_remote_query handles uppercase ~Score: and ~ID:, drops bare ~, and deduplicates OR tags", function()
      local branches = api.normalize_remote_query("~Score:>=50 ~ID:12345 ~miku ~miku ~luka ~")
      assert.are.equal(2, #branches)
      assert.is_truthy(branches[1]:lower():find("score:>=50"))
      assert.is_truthy(branches[1]:lower():find("id:12345"))
      assert.is_falsy(branches[1]:find("~Score"))
      assert.is_falsy(branches[1]:find("~ID"))
      assert.is_falsy(branches[1]:find("%s~%s"))
      -- Check that miku and luka are in the branches (no duplicate miku branch)
      local has_miku = false
      local has_luka = false
      for _, b in ipairs(branches) do
        if b:find("miku") then has_miku = true end
        if b:find("luka") then has_luka = true end
      end
      assert.is_true(has_miku)
      assert.is_true(has_luka)
    end)

    it("multi-branch search preserves query sort directives (such as sort:score) on merged posts", function()
      ui.open()
      local download = require("gelbooru.net.download")
      local orig_curl_async = download.curl_async

      download.curl_async = function(url, cb)
        if url:find("miku") then
          vim.schedule(function()
            cb(vim.fn.json_encode({
              post = {
                { id = "100", score = "10", file_url = "https://example.com/100.jpg" },
                { id = "300", score = "50", file_url = "https://example.com/300.jpg" },
              },
            }))
          end)
        elseif url:find("luka") then
          vim.schedule(function()
            cb(vim.fn.json_encode({
              post = {
                { id = "200", score = "80", file_url = "https://example.com/200.jpg" },
                { id = "400", score = "20", file_url = "https://example.com/400.jpg" },
              },
            }))
          end)
        else
          orig_curl_async(url, cb)
        end
      end

      api.execute_search("~miku ~luka sort:score")

      vim.wait(500, function()
        return not state.State.loading and #state.State.posts == 4
      end, 20)

      assert.are.equal(4, #state.State.posts)
      -- Sorted by score descending: id 200 (score 80), id 300 (score 50), id 400 (score 20), id 100 (score 10)
      assert.are.equal("200", state.State.posts[1].id)
      assert.are.equal("300", state.State.posts[2].id)
      assert.are.equal("400", state.State.posts[3].id)
      assert.are.equal("100", state.State.posts[4].id)

      download.curl_async = orig_curl_async
    end)

    it("force_refresh R invalidates cached metadata for online posts with ID", function()
      ui.open()
      local p = { id = "777888", tags = "original_tag", score = 10, file_url = "https://example.com/777888.jpg" }
      state.State.posts = { p }
      state.State.cur = 1

      local meta_path = util.meta_cache_path(p.id)
      util.write_json(meta_path, { id = p.id, tags = "cached_tag", score = 99 })
      assert.is_true(vim.fn.filereadable(meta_path) == 1)

      p._metadata_fetched = true
      ui.force_refresh()

      assert.is_false(vim.fn.filereadable(meta_path) == 1, "meta cache file must be deleted on R")
      assert.is_nil(p._metadata_fetched, "_metadata_fetched must be reset on R")
    end)

    it("save_current restores post and clears internal _was_local and _local_file_path staging flags", function()
      ui.open()
      local tmp = vim.fn.tempname() .. ".jpg"
      local f = io.open(tmp, "w")
      if f then f:write("data"); f:close() end

      local p = { id = "999111", is_local = false, file_url = "https://example.com/999111.jpg" }
      state.State.posts = { p }
      state.State.cur = 1
      state.State.pending_deletions = {
        ["999111"] = { path = tmp, id = p.id, p = p },
      }
      p._pending_delete = true
      p._local_file_path = tmp
      p._was_local = false

      api.save_current(function(saved, path)
        assert.is_true(saved)
        assert.are.equal(tmp, path)
      end)

      assert.is_nil(p._pending_delete)
      assert.is_nil(p._was_local, "_was_local must be cleared after restore")
      assert.is_nil(p._local_file_path, "_local_file_path must be cleared after restore")
      assert.is_nil(state.State.pending_deletions["999111"])

      vim.fn.delete(tmp)
    end)

    it("handles single post dictionary API response via ensure_array (Issue 6)", function()
      ui.open()
      local download = require("gelbooru.net.download")
      local orig_curl = download.curl_async

      download.curl_async = function(url, cb)
        if url:find("s=post") then
          -- Gelbooru API returns a JSON dictionary table for single post, NOT an array
          local single_dict = {
            id = 5566,
            rating = "general",
            score = 123,
            width = 1280,
            height = 720,
            tags = "single_tag_solo vocaloid",
            file_url = "https://example.com/5566.jpg",
            preview_url = "https://example.com/5566_prev.jpg",
          }
          vim.schedule(function()
            cb(vim.fn.json_encode({ post = single_dict }))
          end)
        else
          orig_curl(url, cb)
        end
      end

      api.execute_search("id:5566")

      vim.wait(200, function()
        return #state.State.posts > 0
      end)

      assert.are.equal(1, #state.State.posts)
      assert.are.equal(5566, state.State.posts[1].id)
      assert.are.equal("single_tag_solo vocaloid", state.State.posts[1].tags)
      assert.are.equal(1, state.State.cur)

      download.curl_async = orig_curl
    end)

    it("multi-flight epoch invalidation discards responses from all earlier queries (Issue 5)", function()
      ui.open()
      local download = require("gelbooru.net.download")
      local captured = {}
      local orig_curl = download.curl_async

      download.curl_async = function(url, cb)
        if url:find("s=post") then
          table.insert(captured, { url = url, cb = cb })
        else
          orig_curl(url, cb)
        end
      end

      -- Launch three rapid consecutive queries: Q1, Q2, Q3
      api.execute_search("search_alpha")
      local epoch1 = state.State.search_epoch

      api.execute_search("search_beta")
      local epoch2 = state.State.search_epoch

      api.execute_search("search_gamma")
      local epoch3 = state.State.search_epoch

      assert.is_true(epoch2 > epoch1)
      assert.is_true(epoch3 > epoch2)
      assert.are.equal(3, #captured)

      -- Q3 responds first
      local p3 = { id = 3000, score = 300, tags = "gamma_tag", file_url = "https://example.com/3000.jpg" }
      captured[3].cb(vim.fn.json_encode({ post = { p3 } }))

      assert.are.equal("search_gamma", state.State.query)
      assert.are.equal(1, #state.State.posts)
      assert.are.equal(3000, state.State.posts[1].id)

      -- Q1 and Q2 respond late
      local p1 = { id = 1000, score = 100, tags = "alpha_tag", file_url = "https://example.com/1000.jpg" }
      local p2 = { id = 2000, score = 200, tags = "beta_tag", file_url = "https://example.com/2000.jpg" }
      captured[1].cb(vim.fn.json_encode({ post = { p1 } }))
      captured[2].cb(vim.fn.json_encode({ post = { p2 } }))

      -- Confirm state and post list remain strictly on Q3
      assert.are.equal("search_gamma", state.State.query)
      assert.are.equal(1, #state.State.posts)
      assert.are.equal(3000, state.State.posts[1].id)

      download.curl_async = orig_curl
    end)

    it("candidate pool caches query and R forces cache clearance and fresh network fetch (Issue 7)", function()
      ui.open()
      local download = require("gelbooru.net.download")
      local orig_curl = download.curl_async
      local fetch_count = 0

      download.curl_async = function(url, cb)
        if url:find("s=post") then
          fetch_count = fetch_count + 1
          local posts = {
            { id = 901, score = 90, tags = "ttl_pool", file_url = "https://example.com/901.jpg" },
            { id = 902, score = 80, tags = "ttl_pool", file_url = "https://example.com/902.jpg" },
          }
          vim.schedule(function()
            cb(vim.fn.json_encode({ post = posts }))
          end)
        else
          orig_curl(url, cb)
        end
      end

      -- First piped search fetches candidate pool from network
      api.execute_search("ttl_pool | sort:score:10")
      vim.wait(300, function() return #state.State.posts > 0 end)
      assert.is_true(fetch_count >= 1)
      local first_fetches = fetch_count
      assert.are.equal(2, #state.State.posts)

      -- Second piped search with downstream slice hits session cache (0 extra curl calls)
      api.execute_search("ttl_pool | sort:score:1")
      assert.are.equal(first_fetches, fetch_count)
      assert.are.equal(1, #state.State.posts)

      -- Trigger force refresh 'R'
      ui.force_refresh()

      -- Next search must bypass cache and issue fresh network request
      api.execute_search("ttl_pool | sort:score:10")
      vim.wait(300, function() return fetch_count > first_fetches and #state.State.posts > 0 end)
      assert.is_true(fetch_count > first_fetches)
      assert.are.equal(2, #state.State.posts)

      download.curl_async = orig_curl
    end)
  end)
end)

