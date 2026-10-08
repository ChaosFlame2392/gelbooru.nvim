-- tests/integration/local_spec.lua
-- Exhaustive integration and adversarial tests for GelbooruLocal folder browsing,
-- metadata enrichment, safety invariants, offline resilience, and mode transitions.

local harness = require("tests.integration.helpers.harness")
local ui = require("gelbooru.ui")
local api = require("gelbooru.net.api")
local state = require("gelbooru.core.state")
local history = require("gelbooru.core.history")
local download = require("gelbooru.net.download")

describe("Integration: Local Folder Browser Mode", function()
  local tmp_dir

  before_each(function()
    harness.setup_all()
    harness.reset_environment()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    -- Create dummy images (> 1024 bytes)
    for _, name in ipairs({ "1001.jpg", "1002.png", "artwork_no_id.webp" }) do
      local f = io.open(tmp_dir .. "/" .. name, "wb")
      if f then
        f:write(string.rep("B", 2048))
        f:close()
      end
    end
  end)

  after_each(function()
    harness.reset_environment()
    harness.teardown_all()
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("opens UI with local images, sets query, and renders list", function()
    ui.open_local(tmp_dir)

    assert.is_truthy(state.UI.wins.frame)
    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.frame))
    assert.are.equal("local:" .. tmp_dir, state.State.query)
    assert.are.equal(3, #state.State.posts)
    assert.are.equal(1, state.State.cur)

    local list_lines = harness.get_buf_lines(state.UI.bufs.list)
    assert.are.equal(3, #list_lines)
    assert.is_truthy(list_lines[1]:find("▶"))

    -- Save current post should inform user it is a local file
    api.save_current()
    local status_lines = harness.get_buf_lines(state.UI.bufs.status)
    assert.is_truthy(status_lines[1]:find("Local file:"))

    -- Pagination should be a no-op in local mode
    local initial_count = #state.State.posts
    api.fetch(1)
    assert.are.equal(initial_count, #state.State.posts)
  end)

  it("enriches metadata for focused post with post ID from Gelbooru API", function()
    ui.open_local(tmp_dir)

    -- Post 1 is 1001.jpg which has id = "1001". Mock net returns sample_posts[1].
    vim.wait(1000, function()
      local p = state.State.posts[1]
      return p and p._metadata_fetched == true
    end, 20)

    local p = state.State.posts[1]
    assert.is_true(p._metadata_fetched)
    assert.is_truthy(p.tags:find("hatsune_miku"))

    local meta_lines = harness.get_buf_lines(state.UI.bufs.meta)
    local has_rating = false
    local has_score = false
    local has_tag = false
    for _, line in ipairs(meta_lines) do
      if line:find("Rating") then has_rating = true end
      if line:find("Score") then has_score = true end
      if line:find("hatsune_miku") then has_tag = true end
    end
    assert.is_true(has_rating)
    assert.is_true(has_score)
    assert.is_true(has_tag)
  end)

  it("supports user command GelbooruLocal", function()
    require("gelbooru")
    vim.cmd("runtime plugin/gelbooru.lua")

    vim.cmd("GelbooruLocal " .. tmp_dir)

    assert.is_truthy(state.UI.wins.frame)
    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.frame))
    assert.are.equal("local:" .. tmp_dir, state.State.query)
    assert.are.equal(3, #state.State.posts)
  end)

  it("supports opening a direct file path and focuses that file", function()
    local target_file = tmp_dir .. "/1002.png"
    ui.open_local(target_file)

    assert.is_truthy(state.UI.wins.frame)
    assert.are.equal("local:" .. tmp_dir, state.State.query)
    assert.are.equal(3, #state.State.posts)
    assert.are.equal(2, state.State.cur)
    assert.are.equal(target_file, state.State.posts[state.State.cur].file_url)
  end)

  describe("Directory & File Edge Cases", function()
    it("handles empty directory without nil-indexing errors and renders 'No images found'", function()
      local empty_dir = vim.fn.tempname()
      vim.fn.mkdir(empty_dir, "p")

      ui.open_local(empty_dir)

      assert.is_truthy(state.UI.wins.frame)
      assert.are.equal(0, #state.State.posts)
      assert.are.equal("local:" .. empty_dir, state.State.query)

      -- List buffer renders 'No images found'
      local list_lines = harness.get_buf_lines(state.UI.bufs.list)
      assert.are.equal(1, #list_lines)
      assert.is_truthy(list_lines[1]:find("No images found"))

      -- Preview buffer renders 'No images found'
      local img_lines = harness.get_buf_lines(state.UI.bufs.img)
      assert.is_truthy(img_lines[1]:find("No images found"))

      -- Status buffer contains 'No images found'
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("No images found"))

      -- Navigating j/k on empty posts is safe and doesn't throw or set cur = 0
      local win_list = state.UI.wins.list
      vim.api.nvim_set_current_win(win_list)
      local orig_cur = state.State.cur
      vim.cmd("normal! j")
      assert.are.equal(orig_cur, state.State.cur)
      vim.cmd("normal! k")
      assert.are.equal(orig_cur, state.State.cur)

      -- Actions on empty directory don't crash
      api.save_current()
      local save_status = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(save_status[1]:find("No file URL"))

      ui.render_preview(false)
      ui.render_preview(true)

      vim.fn.delete(empty_dir, "rf")
    end)

    it("handles non-existent directory gracefully with status message and doesn't crash", function()
      local missing_dir = tmp_dir .. "/non_existent_folder_xyz"
      ui.open_local(missing_dir)

      assert.is_truthy(state.UI.wins.frame)
      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.frame))
      assert.are.equal(0, #state.State.posts)

      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("Directory not found") or status_lines[1]:find("No images found"))

      local list_lines = harness.get_buf_lines(state.UI.bufs.list)
      assert.is_truthy(list_lines[1]:find("No images found"))
    end)

    it("handles directory with ONLY non-image files (.txt, .mp4, .json, .part, .md)", function()
      local non_img_dir = vim.fn.tempname()
      vim.fn.mkdir(non_img_dir, "p")
      vim.fn.writefile({ "text notes" }, non_img_dir .. "/notes.txt")
      vim.fn.writefile({ "video data" }, non_img_dir .. "/movie.mp4")
      vim.fn.writefile({ "{}" }, non_img_dir .. "/data.json")
      vim.fn.writefile({ "partial" }, non_img_dir .. "/temp.jpg.part")
      vim.fn.writefile({ "# readme" }, non_img_dir .. "/README.md")

      ui.open_local(non_img_dir)
      assert.are.equal(0, #state.State.posts)

      local list_lines = harness.get_buf_lines(state.UI.bufs.list)
      assert.is_truthy(list_lines[1]:find("No images found"))

      vim.fn.delete(non_img_dir, "rf")
    end)

    it("handles filenames with spaces, brackets, utf-8, multiple dots correctly", function()
      local special_dir = vim.fn.tempname()
      vim.fn.mkdir(special_dir, "p")
      local names = {
        "[Artist] Cute Girl (2024.01.01).sample.png",
        "絵師_初音ミク.jpg",
        "spaces in filename 123.webp",
      }
      for _, n in ipairs(names) do
        local f = io.open(special_dir .. "/" .. n, "wb")
        if f then
          f:write(string.rep("C", 2048))
          f:close()
        end
      end

      ui.open_local(special_dir)
      assert.are.equal(3, #state.State.posts)

      -- Verify target resolution
      for _, p in ipairs(state.State.posts) do
        local urls, dest = ui.image.get_preview_targets(p)
        assert.are.equal(p.file_url, dest)
        assert.are.equal(1, #urls)
      end

      vim.fn.delete(special_dir, "rf")
    end)

    it("handles post without numeric ID safely (p.id = nil, no crash, skips API fetch)", function()
      ui.open_local(tmp_dir)

      -- Post 3 is artwork_no_id.webp
      local p_no_id = state.State.posts[3]
      assert.is_nil(p_no_id.id)
      assert.are.equal("artwork_no_id.webp", vim.fn.fnamemodify(p_no_id.file_url, ":t"))

      -- Focus post 3
      state.State.cur = 3
      ui.render_list()
      ui.render_preview(false)

      local meta_lines = harness.get_buf_lines(state.UI.bufs.meta)
      local found_id_placeholder = false
      for _, l in ipairs(meta_lines) do
        if l:find("ID%s*:%s*%?") then
          found_id_placeholder = true
        end
      end
      assert.is_true(found_id_placeholder)
      assert.is_nil(p_no_id._metadata_fetched)
    end)
  end)

  describe("Critical Safety: Local File Preservation", function()
    it("CRITICAL: 'R' (force refresh) DOES NOT delete or truncate the local file", function()
      local test_file = tmp_dir .. "/1001.jpg"
      local original_content = "ORIGINAL_LOCAL_IMAGE_PAYLOAD_PROTECTED_" .. string.rep("X", 2000)
      local f = io.open(test_file, "wb")
      f:write(original_content)
      f:close()

      ui.open_local(tmp_dir)
      assert.are.equal(1, state.State.cur)

      -- Trigger 'R' force refresh
      ui.render_preview(true)

      -- Give libuv timers a moment to process render
      vim.wait(150, function() return false end, 10)

      -- File must STILL exist on disk and be completely intact!
      assert.are.equal(1, vim.fn.filereadable(test_file))
      local f_read = io.open(test_file, "rb")
      assert.is_truthy(f_read)
      local content_after = f_read:read("*a")
      f_read:close()

      assert.are.equal(#original_content, #content_after)
      assert.are.equal(original_content, content_after)
    end)

    it("'<CR>' does not trigger download over local file and informs user", function()
      local called_download = false
      local orig_download_async = download.download_async
      download.download_async = function(...)
        called_download = true
        return orig_download_async(...)
      end

      ui.open_local(tmp_dir)
      api.save_current()

      assert.is_false(called_download)
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("Local file:"))

      download.download_async = orig_download_async
    end)

    it("'O' keymap on post without ID does not open malformed URL like ...&id=nil", function()
      ui.open_local(tmp_dir)

      -- Select post 3 (artwork_no_id.webp, id is nil)
      state.State.cur = 3
      local p = state.State.posts[3]
      assert.is_nil(p.id)

      -- Spy on vim.ui.open
      local opened_url = nil
      local orig_ui_open = vim.ui.open
      vim.ui.open = function(url)
        opened_url = url
      end

      -- Trigger 'O' keymap action
      local win_list = state.UI.wins.list
      vim.api.nvim_set_current_win(win_list)
      vim.cmd("normal O")

      assert.is_nil(opened_url)
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("No post ID available"))

      vim.ui.open = orig_ui_open
    end)
  end)

  describe("Offline & Network Resilience", function()
    it("handles offline network error (curl returns nil) without crashing and local image remains rendered", function()
      download.curl_async = function(_, cb)
        vim.schedule(function()
          cb(nil)
        end)
      end

      ui.open_local(tmp_dir)

      vim.wait(300, function()
        local p = state.State.posts[1]
        return p and p._metadata_fetched == true
      end, 20)

      local p = state.State.posts[1]
      assert.is_true(p._metadata_fetched)
      assert.are.equal("local", p.tags)
      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.frame))
    end)

    it("handles corrupted JSON API response cleanly via pcall", function()
      download.curl_async = function(_, cb)
        vim.schedule(function()
          cb("<<<MALFORMED_HTML_RESPONSE_500>>>")
        end)
      end

      ui.open_local(tmp_dir)

      vim.wait(300, function()
        local p = state.State.posts[1]
        return p and p._metadata_fetched == true
      end, 20)

      local p = state.State.posts[1]
      assert.is_true(p._metadata_fetched)
      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.frame))
    end)

    it("_metadata_fetched caching prevents repeated API requests on cursoring", function()
      local calls_by_id = {}
      download.curl_async = function(url, cb)
        local post_id = url:match("id=(%d+)")
        if post_id then
          calls_by_id[post_id] = (calls_by_id[post_id] or 0) + 1
          vim.schedule(function()
            cb(vim.fn.json_encode({
              post = { { id = tonumber(post_id), tags = "test_tag", rating = "general", score = 99 } },
            }))
          end)
        else
          vim.schedule(function() cb("{}") end)
        end
      end

      ui.open_local(tmp_dir)

      vim.wait(300, function()
        local p = state.State.posts[1]
        return p and p._metadata_fetched == true
      end, 20)

      assert.are.equal(1, calls_by_id["1001"])

      -- Move away to post 2 (triggers fetch for 1002)
      state.State.cur = 2
      ui.render_preview(false)
      vim.wait(300, function()
        local p2 = state.State.posts[2]
        return p2 and p2._metadata_fetched == true
      end, 20)
      assert.are.equal(1, calls_by_id["1002"])

      -- Move back to post 1: must NOT trigger a second fetch for 1001
      state.State.cur = 1
      ui.render_preview(false)
      vim.wait(100, function() return false end, 10)
      assert.are.equal(1, calls_by_id["1001"])

      -- Move back to post 2: must NOT trigger a second fetch for 1002
      state.State.cur = 2
      ui.render_preview(false)
      vim.wait(100, function() return false end, 10)
      assert.are.equal(1, calls_by_id["1002"])
    end)
  end)

  describe("Mode Switching & History Transitions", function()
    it("transitions seamlessly between online search and local folder browsing via history", function()
      -- Step 1: Open UI and execute online search
      ui.open("hatsune_miku")

      vim.wait(500, function()
        return #state.State.posts > 0
      end, 20)

      assert.are.equal("hatsune_miku", state.State.query)
      assert.are.equal(3, #state.State.posts)
      assert.is_nil(state.State.posts[1].is_local)

      -- Step 2: Open local directory
      ui.open_local(tmp_dir)

      assert.are.equal("local:" .. tmp_dir, state.State.query)
      assert.are.equal(3, #state.State.posts)
      assert.is_true(state.State.posts[1].is_local)
      assert.are.equal(2, state.State.history_idx)

      -- Step 3: Navigate backward in history '['
      history.history_prev()

      assert.are.equal("hatsune_miku", state.State.query)
      assert.are.equal(3, #state.State.posts)
      assert.is_nil(state.State.posts[1].is_local)
      local input_text = vim.api.nvim_buf_get_lines(state.UI.bufs.input, 0, 1, false)[1]
      assert.are.equal("hatsune_miku", input_text)

      -- Step 4: Navigate forward in history ']'
      history.history_next()

      assert.are.equal("local:" .. tmp_dir, state.State.query)
      assert.are.equal(3, #state.State.posts)
      assert.is_true(state.State.posts[1].is_local)
      input_text = vim.api.nvim_buf_get_lines(state.UI.bufs.input, 0, 1, false)[1]
      assert.are.equal("local:" .. tmp_dir, input_text)
    end)

    it("transitions from local mode to online search when new query is submitted", function()
      ui.open_local(tmp_dir)
      assert.are.equal("local:" .. tmp_dir, state.State.query)

      -- Enter search mode and submit a new query
      ui.enter_search()
      assert.is_true(state.State.input_focused)

      api.execute_search("vocaloid")

      vim.wait(500, function()
        return #state.State.posts > 0 and state.State.posts[1].is_local == nil
      end, 20)

      assert.are.equal("vocaloid", state.State.query)
      assert.is_nil(state.State.posts[1].is_local)

      -- Verify history now contains both
      history.history_prev()
      assert.are.equal("local:" .. tmp_dir, state.State.query)
      assert.is_true(state.State.posts[1].is_local)
    end)

    it("accepts local: directory query from input bar in execute_search", function()
      ui.open("hatsune_miku")
      vim.wait(300, function() return #state.State.posts > 0 end, 10)

      -- Submitting local:<path> in search bar routes to open_local
      api.execute_search("local:" .. tmp_dir)

      assert.are.equal("local:" .. tmp_dir, state.State.query)
      assert.are.equal(3, #state.State.posts)
      assert.is_true(state.State.posts[1].is_local)
    end)

    it("pagination (<Tab> / <S-Tab>) does not append remote results into local post list", function()
      ui.open_local(tmp_dir)
      local initial_count = #state.State.posts

      api.fetch(1)
      assert.are.equal(initial_count, #state.State.posts)

      api.fetch(-1)
      assert.are.equal(initial_count, #state.State.posts)
    end)
  end)

  describe("Rapid Navigation & Teardown Race Conditions", function()
    it("handles rapid cursoring across local posts without crashing", function()
      ui.open_local(tmp_dir)

      -- Rapidly cycle through posts
      for _ = 1, 10 do
        for i = 1, #state.State.posts do
          state.State.cur = i
          ui.render_preview(false)
        end
      end

      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.frame))
    end)

    it("safely tears down while async metadata requests are in-flight without errors", function()
      local in_flight_cb = nil
      download.curl_async = function(url, cb)
        if url:find("s=post") then
          in_flight_cb = cb -- Hold onto callback
        else
          cb("{}")
        end
      end

      ui.open_local(tmp_dir)
      assert.is_truthy(in_flight_cb)

      -- Trigger teardown while request is pending
      ui.teardown()
      assert.is_true(state.State.torn_down)

      -- Callback resolves AFTER teardown
      if in_flight_cb then
        in_flight_cb(vim.fn.json_encode({
          post = { { id = 1001, tags = "should_be_ignored" } },
        }))
      end

      -- Verify no panic, windows are gone
      assert.is_nil(state.UI.wins.frame)
    end)
  end)
end)
