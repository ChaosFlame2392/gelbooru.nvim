-- tests/integration/pipeline_stress_spec.lua
-- Pipeline & Concurrency Stress Test Suite for gelbooru.nvim
-- Covers:
-- 1. Multi-Stage Pipeline Stress Testing (piped stages, open-ended ranges, extreme syntax, candidate pool sizing)
-- 2. Rapid User Interaction & Race Safety (rapid search switching, rapid pagination, j/k flurry, open/close cycling)
-- 3. Local Library & Metadata Concurrency (Tier 2 crawler during navigation, hydration re-sorting, search interruption)

local harness = require("tests.integration.helpers.harness")
local ui = require("gelbooru.ui")
local api = require("gelbooru.net.api")
local state = require("gelbooru.core.state")
local query = require("gelbooru.query")
local download = require("gelbooru.net.download")
local indexer = require("gelbooru.local.indexer")
local config = require("gelbooru.core.config")
local util = require("gelbooru.core.util")

describe("Pipeline & Concurrency Stress Testing Suite", function()
  before_each(function()
    harness.setup_all()
    harness.reset_environment()
  end)

  after_each(function()
    indexer.stop()
    download.cancel_prefetch_timers(true)
    harness.reset_environment()
    harness.teardown_all()
  end)

  -----------------------------------------------------------------------------
  -- SECTION 1: Multi-Stage Pipeline Stress Testing
  -----------------------------------------------------------------------------
  describe("1. Multi-Stage Pipeline Stress Testing", function()
    it("parses and executes piped query with multiple sort/limit/random stages sequentially", function()
      local query_str = "tag1 tag2 | sort:id:1000..1200 | sort:score:50 | sort:random"
      local parsed = query.parse_pipeline(query_str)

      assert.are.equal("tag1 tag2", parsed.base_query)
      assert.are.equal(3, #parsed.stages)

      -- Stage 1: sort by id desc, slice window 1000..1200
      assert.are.equal("id", parsed.stages[1].key)
      assert.are.equal("desc", parsed.stages[1].dir)
      assert.are.equal(1000, parsed.stages[1].offset)
      assert.are.equal(1200, parsed.stages[1].limit)

      -- Stage 2: sort by score desc, limit to 50
      assert.are.equal("score", parsed.stages[2].key)
      assert.are.equal("desc", parsed.stages[2].dir)
      assert.are.equal(50, parsed.stages[2].limit)

      -- Stage 3: random shuffle
      assert.are.equal("random", parsed.stages[3].key)
      assert.are.equal("asc", parsed.stages[3].dir)

      -- Generate 1500 posts with varying IDs and scores
      local dataset = {}
      for i = 1, 1500 do
        table.insert(dataset, {
          id = tostring(i),
          score = (i * 37) % 1000,
          file_url = string.format("/media/%d.jpg", i),
        })
      end

      local result = query.execute_pipeline(dataset, parsed.stages)

      -- Exactly 50 posts must remain after slicing
      assert.are.equal(50, #result)

      -- In stage 1, dataset was sorted by id desc (1500 down to 1),
      -- then sliced 1001..1200 (200 items: IDs 500 down to 301).
      -- In stage 2, those 200 items were sorted by score desc and limited to 50.
      -- In stage 3, those 50 items were shuffled.
      -- Verify all remaining items originated from the 1001..1200 window (IDs 301..500)
      for _, p in ipairs(result) do
        local id_num = tonumber(p.id)
        assert.is_true(id_num >= 301 and id_num <= 500, string.format("ID %d was not in window 301..500", id_num))
      end
    end)

    it("handles open-ended ranges in pipeline parsing and execution (50.., ..200)", function()
      -- Open-ended range from start (..200)
      local p_head = query.parse_pipeline("sort:id:..200")
      assert.are.equal(1, #p_head.stages)
      assert.are.equal(1, p_head.stages[1].offset)
      assert.are.equal(200, p_head.stages[1].limit)
      assert.is_true(p_head.stages[1].is_range)

      -- Open-ended range to tail (50..)
      local p_tail = query.parse_pipeline("sort:id:50..")
      assert.are.equal(1, #p_tail.stages)
      assert.are.equal(50, p_tail.stages[1].offset)
      assert.is_nil(p_tail.stages[1].limit)
      assert.is_true(p_tail.stages[1].is_range)

      -- Open-ended range with limit directive
      local p_lim_head = query.parse_pipeline("miku | limit:..50")
      assert.are.equal(1, #p_lim_head.stages)
      assert.are.equal(1, p_lim_head.stages[1].offset)
      assert.are.equal(50, p_lim_head.stages[1].limit)

      local p_lim_tail = query.parse_pipeline("miku | limit:50..")
      assert.are.equal(1, #p_lim_tail.stages)
      assert.are.equal(50, p_lim_tail.stages[1].offset)
      assert.is_nil(p_lim_tail.stages[1].limit)

      -- Execution tests on 100 items sorted asc
      local items = {}
      for i = 1, 100 do
        table.insert(items, { id = tostring(i), score = i })
      end

      -- ..20 should yield items 1 to 20
      local sliced_head = query.execute_pipeline(items, query.parse_pipeline("sort:id:asc:..20"))
      assert.are.equal(20, #sliced_head)
      assert.are.equal("1", sliced_head[1].id)
      assert.are.equal("20", sliced_head[#sliced_head].id)

      -- 50.. should yield items 50 to 100 (51 items)
      local sliced_tail = query.execute_pipeline(items, query.parse_pipeline("sort:id:asc:50.."))
      assert.are.equal(51, #sliced_tail)
      assert.are.equal("50", sliced_tail[1].id)
      assert.are.equal("100", sliced_tail[#sliced_tail].id)
    end)

    it("executes remote piped search with open-ended range ..200 without dropping the first post", function()
      ui.open()
      local orig_curl = download.curl_async
      local requested_urls = {}

      download.curl_async = function(url, cb)
        if url:find("s=post") then
          table.insert(requested_urls, url)
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
          orig_curl(url, cb)
        end
      end

      api.execute_search("miku sort:id:..200")

      vim.wait(500, function()
        return not state.State.loading and #state.State.posts > 0
      end, 10)

      assert.is_false(state.State.loading)
      assert.are.equal(200, #state.State.posts)
      -- First post MUST be ID 1 (not dropped!)
      assert.are.equal("1", state.State.posts[1].id)
      assert.are.equal("200", state.State.posts[200].id)

      download.curl_async = orig_curl
    end)

    it("gracefully handles extreme pipeline edge cases (empty stages, trailing pipes, bare pipes, whitespace)", function()
      -- Empty stage (| |) between valid query and sort
      local p_empty = query.parse_pipeline("tag | | sort:score")
      assert.are.equal("tag", p_empty.base_query)
      assert.are.equal(1, #p_empty.stages)
      assert.are.equal("score", p_empty.stages[1].key)

      -- Multiple empty stages (| | | |)
      local p_multi_empty = query.parse_pipeline("tag | | | | sort:score")
      assert.are.equal("tag", p_multi_empty.base_query)
      assert.are.equal(1, #p_multi_empty.stages)

      -- Whitespace-only stage
      local p_ws = query.parse_pipeline("tag |   |   | sort:score")
      assert.are.equal("tag", p_ws.base_query)
      assert.are.equal(1, #p_ws.stages)

      -- Trailing pipes
      local p_trail = query.parse_pipeline("tag |")
      assert.are.equal("tag", p_trail.base_query)
      assert.are.equal(0, #p_trail.stages)

      local p_trail_ws = query.parse_pipeline("tag |   ")
      assert.are.equal("tag", p_trail_ws.base_query)
      assert.are.equal(0, #p_trail_ws.stages)

      local p_trail_stage = query.parse_pipeline("tag | sort:score |")
      assert.are.equal("tag", p_trail_stage.base_query)
      assert.are.equal(1, #p_trail_stage.stages)

      -- Leading pipes
      local p_lead = query.parse_pipeline("| sort:score")
      assert.are.equal("", p_lead.base_query)
      assert.are.equal(1, #p_lead.stages)

      local p_lead_tag = query.parse_pipeline("| tag | sort:score")
      assert.are.equal("tag", p_lead_tag.base_query)
      assert.are.equal(1, #p_lead_tag.stages)

      -- Bare pipe strings
      local p_bare1 = query.parse_pipeline("|")
      assert.are.equal("", p_bare1.base_query)
      assert.are.equal(0, #p_bare1.stages)

      local p_bare2 = query.parse_pipeline("|||")
      assert.are.equal("", p_bare2.base_query)
      assert.are.equal(0, #p_bare2.stages)

      local p_bare3 = query.parse_pipeline(" | | ")
      assert.are.equal("", p_bare3.base_query)
      assert.are.equal(0, #p_bare3.stages)

      -- Inverted range bounds (50..10 -> 10..50)
      local p_inv = query.parse_pipeline("sort:id:asc:50..10")
      assert.are.equal(1, #p_inv.stages)
      assert.are.equal(10, p_inv.stages[1].offset)
      assert.are.equal(50, p_inv.stages[1].limit)

      -- Non-numeric range bounds (abc..def)
      local ok, p_non_num = pcall(query.parse_pipeline, "sort:id:asc:abc..def")
      assert.is_true(ok)
      assert.is_not_nil(p_non_num)

      -- normalize_remote_query strips standalone pipe delimiters
      local norm = api.normalize_remote_query("tag |")
      assert.are.equal(1, #norm)
      assert.are.equal("tag", norm[1])

      local norm_multi = api.normalize_remote_query("tag | |")
      assert.are.equal(1, #norm_multi)
      assert.are.equal("tag", norm_multi[1])
    end)

    it("handles candidate pool sizing when upstream returns fewer posts than requested", function()
      ui.open()
      local orig_curl = download.curl_async

      -- Mock API returns only 25 posts total, even though pool_target requests 200 posts
      download.curl_async = function(url, cb)
        if url:find("s=post") then
          local posts = {}
          for i = 1, 25 do
            table.insert(posts, {
              id = tostring(i),
              score = tostring(i * 10),
              tags = "miku",
              file_url = string.format("https://example.com/%d.jpg", i),
            })
          end
          vim.schedule(function()
            cb(vim.fn.json_encode({ post = posts }))
          end)
        else
          orig_curl(url, cb)
        end
      end

      -- Query requests a pool of 200 posts then sorts by score:50 then random
      api.execute_search("miku | sort:score:50 | sort:random")

      vim.wait(500, function()
        return not state.State.loading and #state.State.posts > 0
      end, 10)

      assert.is_false(state.State.loading)
      -- Upstream had 25 posts, so candidate pool took all 25 without hanging
      assert.are.equal(25, #state.State.posts)
      assert.are.equal(1, state.State.cur)

      local list_lines = harness.get_buf_lines(state.UI.bufs.list)
      assert.are.equal(25, #list_lines)
      assert.is_truthy(list_lines[1]:find("▶"))

      download.curl_async = orig_curl
    end)

    it("handles candidate pool sizing when upstream returns 0 posts or network error", function()
      ui.open()
      local orig_curl = download.curl_async

      -- Case A: Upstream returns 0 posts
      download.curl_async = function(url, cb)
        if url:find("s=post") then
          vim.schedule(function()
            cb(vim.fn.json_encode({ post = {} }))
          end)
        else
          orig_curl(url, cb)
        end
      end

      api.execute_search("empty_tag | sort:score:50")

      vim.wait(500, function()
        return not state.State.loading
      end, 10)

      assert.is_false(state.State.loading)
      assert.are.equal(0, #state.State.posts)

      local list_lines = harness.get_buf_lines(state.UI.bufs.list)
      assert.are.equal("  No results", list_lines[1])
      local img_lines = harness.get_buf_lines(state.UI.bufs.img)
      assert.are.equal("  No posts found", img_lines[1])

      -- Case B: Upstream returns nil (network failure)
      download.curl_async = function(url, cb)
        if url:find("s=post") then
          vim.schedule(function()
            cb(nil)
          end)
        else
          orig_curl(url, cb)
        end
      end

      api.execute_search("error_tag | sort:score:50")

      vim.wait(500, function()
        return not state.State.loading
      end, 10)

      assert.is_false(state.State.loading)
      assert.are.equal(0, #state.State.posts)
      local img_err_lines = harness.get_buf_lines(state.UI.bufs.img)
      assert.are.equal("  Error: API request failed", img_err_lines[1])

      download.curl_async = orig_curl
    end)
  end)

  -----------------------------------------------------------------------------
  -- SECTION 2: Rapid User Interaction & Race Safety
  -----------------------------------------------------------------------------
  describe("2. Rapid User Interaction & Race Safety", function()
    it("cancels stale in-flight results when rapid search switching fires new searches", function()
      ui.open()
      local download_mod = require("gelbooru.net.download")
      local orig_curl = download_mod.curl_async

      local active_callbacks = {}
      download_mod.curl_async = function(url, cb)
        if url:find("s=post") then
          local q_tag = url:match("tags=([^&]+)")
          table.insert(active_callbacks, { tag = q_tag, cb = cb })
        else
          orig_curl(url, cb)
        end
      end

      -- Fire 5 rapid searches in sequence
      api.execute_search("query_alpha")
      local epoch_alpha = state.State.search_epoch

      api.execute_search("query_beta")
      local epoch_beta = state.State.search_epoch

      api.execute_search("query_gamma")
      local epoch_gamma = state.State.search_epoch

      api.execute_search("query_delta")
      local epoch_delta = state.State.search_epoch

      api.execute_search("query_omega")
      local epoch_omega = state.State.search_epoch

      assert.is_true(epoch_omega > epoch_delta)
      assert.is_true(epoch_delta > epoch_gamma)
      assert.is_true(epoch_gamma > epoch_beta)
      assert.is_true(epoch_beta > epoch_alpha)

      -- Deliver callbacks OUT OF ORDER:
      -- Callback 1 (alpha) completes first
      local make_response = function(name)
        return vim.fn.json_encode({
          post = {
            { id = "101", tags = name, score = 10, file_url = "https://example.com/101.jpg" },
          },
        })
      end

      -- Fulfill alpha, beta, gamma, delta
      for i = 1, 4 do
        if active_callbacks[i] then
          active_callbacks[i].cb(make_response("stale_" .. i))
        end
      end

      -- State MUST NOT be populated with stale results
      assert.are.equal(0, #state.State.posts)
      assert.are.equal("query_omega", state.State.query)

      -- Now fulfill the final search (omega)
      if active_callbacks[5] then
        active_callbacks[5].cb(make_response("fresh_omega"))
      end

      -- State MUST now contain ONLY omega
      assert.are.equal(1, #state.State.posts)
      assert.are.equal("fresh_omega", state.State.posts[1].tags)
      assert.are.equal("query_omega", state.State.query)

      download_mod.curl_async = orig_curl
    end)

    it("guards rapid pagination (<Tab> / <S-Tab>) while fetches are in progress", function()
      ui.open()
      local download_mod = require("gelbooru.net.download")
      local orig_curl = download_mod.curl_async

      local captured_fetches = {}
      download_mod.curl_async = function(url, cb)
        if url:find("s=post") then
          table.insert(captured_fetches, { url = url, cb = cb })
        else
          orig_curl(url, cb)
        end
      end

      api.execute_search("paged_query")
      assert.are.equal(1, #captured_fetches)

      -- Respond to initial page 1
      captured_fetches[1].cb(vim.fn.json_encode({
        post = {
          { id = "1", score = 1, tags = "paged", file_url = "https://example.com/1.jpg" },
          { id = "2", score = 2, tags = "paged", file_url = "https://example.com/2.jpg" },
        },
      }))

      assert.are.equal(1, state.State.page)
      assert.are.equal(2, #state.State.posts)
      assert.is_false(state.State.loading)

      -- Rapidly trigger <Tab> 5 times while network is pending
      api.fetch(1) -- starts fetch 2
      assert.is_true(state.State.loading)
      local fetches_count_after_first_tab = #captured_fetches
      assert.are.equal(2, fetches_count_after_first_tab)

      -- Subsequent <Tab> calls while loading MUST be no-ops
      api.fetch(1)
      api.fetch(1)
      api.fetch(1)
      assert.are.equal(fetches_count_after_first_tab, #captured_fetches)

      -- Complete page 2 fetch
      captured_fetches[2].cb(vim.fn.json_encode({
        post = {
          { id = "3", score = 3, tags = "paged", file_url = "https://example.com/3.jpg" },
        },
      }))

      assert.is_false(state.State.loading)
      assert.are.equal(2, state.State.page)
      assert.are.equal(3, #state.State.posts)

      -- Rewind page (<S-Tab>)
      api.fetch(-1)
      assert.are.equal(1, state.State.page)

      -- Rewinding when already on page 1 must be safe no-op
      api.fetch(-1)
      api.fetch(-1)
      assert.are.equal(1, state.State.page)

      download_mod.curl_async = orig_curl
    end)

    it("prefetch scheduler handles rapid cursor flurry (j/k) and direction reversals safely", function()
      ui.open()
      local download_mod = require("gelbooru.net.download")

      -- Populate 30 dummy posts
      local posts = {}
      for i = 1, 30 do
        table.insert(posts, {
          id = tostring(i),
          score = i,
          width = 800,
          height = 600,
          file_url = string.format("https://example.com/%d.jpg", i),
          preview_url = string.format("https://example.com/prev_%d.jpg", i),
        })
      end
      state.State.posts = posts
      state.State.cur = 1
      ui.render_list()

      -- Rapidly scroll DOWN (j flurry)
      for step = 1, 10 do
        state.State.cur = step
        state.State.scroll_dir = 1
        download_mod.prefetch_around(state.State.cur, 1)
      end

      assert.are.equal(1, download_mod.last_prefetch_dir)
      local timers_fwd = vim.tbl_count(state.UI.prefetch_timers or {})

      -- Immediate reversal UP (k flurry)
      for step = 10, 1, -1 do
        state.State.cur = step
        state.State.scroll_dir = -1
        download_mod.prefetch_around(state.State.cur, -1)
      end

      -- Direction reversal MUST update last_prefetch_dir to -1
      assert.are.equal(-1, download_mod.last_prefetch_dir)

      -- Alternating rapid oscillations: j, k, j, k, j, k
      for _ = 1, 5 do
        state.State.scroll_dir = 1
        download_mod.prefetch_around(5, 1)
        state.State.scroll_dir = -1
        download_mod.prefetch_around(5, -1)
      end

      -- Explicit cancellation cleans up all timers and handles
      download_mod.cancel_prefetch_timers(true)
      assert.are.equal(0, vim.tbl_count(state.UI.prefetch_timers or {}))
      assert.are.equal(0, vim.tbl_count(download_mod.active_prefetch_handles or {}))
      assert.is_nil(download_mod.last_prefetch_dir)
    end)

    it("survives rapid UI open/close/re-open cycling without window or buffer errors", function()
      -- Rapid open -> close cycle 5 times
      for cycle = 1, 5 do
        ui.open()
        assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.frame))
        assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.list))
        assert.is_false(state.State.torn_down)

        ui.teardown()
        assert.is_true(state.State.torn_down)
        assert.is_nil(state.UI.wins.frame)
        assert.is_nil(state.UI.wins.list)
      end

      -- Open UI, fire an in-flight search request, and immediately teardown while request is running
      ui.open()
      local in_flight_cb = nil
      local orig_curl = download.curl_async
      download.curl_async = function(url, cb)
        if url:find("s=post") then
          in_flight_cb = cb
        else
          orig_curl(url, cb)
        end
      end

      api.execute_search("racing_query")
      assert.is_not_nil(in_flight_cb)

      -- Teardown while curl is in flight
      ui.teardown()
      assert.is_true(state.State.torn_down)

      -- Delayed curl response arrives AFTER teardown: must not throw error or resurrect UI
      local ok = pcall(function()
        in_flight_cb(vim.fn.json_encode({
          post = { { id = "999", tags = "racing", score = 10, file_url = "https://example.com/999.jpg" } },
        }))
      end)
      assert.is_true(ok)
      assert.is_nil(state.UI.wins.frame)

      -- Reopen UI cleanly after race
      ui.open()
      assert.is_false(state.State.torn_down)
      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.frame))

      download.curl_async = orig_curl
      ui.teardown()
    end)
  end)

  -----------------------------------------------------------------------------
  -- SECTION 3: Local Library & Metadata Concurrency
  -----------------------------------------------------------------------------
  describe("3. Local Library & Metadata Concurrency", function()
    it("runs Tier 2 background indexing concurrently while user navigates without crashing", function()
      ui.open()
      local local_posts = {
        { id = "701", is_local = true, file_url = "/tmp/701.jpg" },
        { id = "702", is_local = true, file_url = "/tmp/702.jpg" },
        { id = "703", is_local = true, file_url = "/tmp/703.jpg" },
        { id = "704", is_local = true, file_url = "/tmp/704.jpg" },
      }
      state.State.posts = local_posts
      state.State.cur = 1
      ui.render_list()

      local fetched_ids = {}
      local orig_fetch = api.fetch_post_metadata
      api.fetch_post_metadata = function(p, cb)
        table.insert(fetched_ids, p.id)
        vim.schedule(function()
          p._metadata_fetched = true
          p.score = tonumber(p.id) or 0
          cb(p)
        end)
      end

      -- Start Tier 2 crawler
      indexer.start_background_indexing(local_posts)

      -- Simulate user navigating while crawler is running
      state.State.cur = 2
      ui.render_list()

      indexer._tick()
      indexer._tick()

      vim.wait(200, function()
        return #fetched_ids >= 2
      end, 20)

      assert.is_true(#fetched_ids >= 2)
      assert.are.equal(2, state.State.cur)

      indexer.stop()
      api.fetch_post_metadata = orig_fetch
    end)

    it("dynamically re-sorts local posts and preserves cursor tracking as scores hydrate", function()
      ui.open()
      local p1 = { id = "10", is_local = true, file_url = "/tmp/10.jpg", score = 0 }
      local p2 = { id = "20", is_local = true, file_url = "/tmp/20.jpg", score = 0 }
      local p3 = { id = "30", is_local = true, file_url = "/tmp/30.jpg", score = 0 }

      local all_folder_posts = { p1, p2, p3 }
      state.State.local_folder_posts = all_folder_posts
      state.State.posts = { p1, p2, p3 }
      state.State.cur = 2 -- Focused on p2
      state.State.local_filter = {
        sort = { key = "score", dir = "desc" },
        positive_tags = {},
        negative_tags = {},
      }
      ui.render_list()

      local orig_fetch = api.fetch_post_metadata
      local hydrate_cb = nil
      api.fetch_post_metadata = function(p, cb)
        hydrate_cb = cb
      end

      indexer.start_background_indexing(all_folder_posts)
      indexer._tick()

      -- Simulate post 30 hydrating with a huge score (999)
      p3.score = 999
      p3._metadata_fetched = true
      if hydrate_cb then
        hydrate_cb(p3)
      end

      -- After hydration, posts must re-sort with p3 at the top: { p3 (999), p1 (0), p2 (0) }
      assert.are.equal(3, #state.State.posts)
      assert.are.equal("30", state.State.posts[1].id)
      assert.are.equal(999, state.State.posts[1].score)

      -- Active cursor must have tracked p2 (which moved to index 2 due to id tie-breaking 20 > 10)
      assert.are.equal(2, state.State.cur)
      assert.are.equal("20", state.State.posts[state.State.cur].id)

      indexer.stop()
      api.fetch_post_metadata = orig_fetch
    end)

    it("aborts Tier 2 indexer and cancels old folder callbacks when user switches to a new search", function()
      ui.open()
      local old_folder_posts = {
        { id = "801", is_local = true, file_url = "/tmp/801.jpg" },
        { id = "802", is_local = true, file_url = "/tmp/802.jpg" },
      }
      state.State.local_folder_posts = old_folder_posts
      state.State.posts = old_folder_posts
      state.State.local_filter = { sort = { key = "score", dir = "desc" } }

      local delayed_callback = nil
      local orig_fetch = api.fetch_post_metadata
      api.fetch_post_metadata = function(p, cb)
        delayed_callback = cb
      end

      indexer.start_background_indexing(old_folder_posts)
      indexer._tick()
      assert.is_not_nil(delayed_callback)

      -- User fires a new online search
      api.execute_search("vocaloid")

      -- Indexer must have been stopped
      assert.are.equal(0, #indexer.queue)

      -- Delayed hydration callback from old folder finally returns
      local stale_post = { id = "801", is_local = true, score = 999 }
      local ok = pcall(delayed_callback, stale_post)
      assert.is_true(ok)

      -- Old folder post MUST NOT overwrite State.posts
      assert.are.equal("vocaloid", state.State.query)
      assert.is_falsy(state.State.posts[1] and state.State.posts[1].id == "801")

      indexer.stop()
      api.fetch_post_metadata = orig_fetch
    end)

    it("verifies thorough timer cleanup and zero handle leaks across rapid open/close cycling (Issue 4)", function()
      local uv = vim.uv or vim.loop

      for cycle = 1, 15 do
        ui.open()

        -- Simulate active in-flight timers across all subsystems
        local timers = {
          scroll = uv.new_timer(),
          status = uv.new_timer(),
          api_tag = uv.new_timer(),
          ac_debounce = uv.new_timer(),
          resize = uv.new_timer(),
          resume = uv.new_timer(),
          save_discovered = uv.new_timer(),
          prefetch = uv.new_timer(),
        }

        for _, t in pairs(timers) do
          t:start(10000, 0, function() end)
        end

        state.UI.scroll_timer = timers.scroll
        state.UI.status_timer = timers.status
        state.UI.api_tag_timer = timers.api_tag
        state.UI.ac_debounce_timer = timers.ac_debounce
        state.UI.resize_timer = timers.resize
        state.UI.resume_timer = timers.resume
        state.UI.save_discovered_timer = timers.save_discovered
        state.UI.prefetch_timers = { [1] = timers.prefetch }

        -- Teardown UI
        ui.teardown()

        -- Verify all timers were stopped, closed, and nil'd out
        assert.is_nil(state.UI.scroll_timer)
        assert.is_nil(state.UI.status_timer)
        assert.is_nil(state.UI.api_tag_timer)
        assert.is_nil(state.UI.ac_debounce_timer)
        assert.is_nil(state.UI.resize_timer)
        assert.is_nil(state.UI.resume_timer)
        assert.is_nil(state.UI.save_discovered_timer)
        assert.are.same({}, state.UI.prefetch_timers)

        for name, t in pairs(timers) do
          assert.is_true(t:is_closing(), "Timer " .. name .. " must be closing after teardown")
        end

        assert.are.same({}, download.active_prefetch_handles)
        assert.are.same({}, download.active_downloads)
        assert.are.same({}, download.pending_resumes)
        assert.is_true(state.State.torn_down)

        -- Windows must be closed
        for win_name, win_id in pairs(state.UI.wins or {}) do
          if type(win_id) == "number" then
            assert.is_false(vim.api.nvim_win_is_valid(win_id), "Window " .. win_name .. " must be closed")
          end
        end
      end
    end)
  end)
end)

