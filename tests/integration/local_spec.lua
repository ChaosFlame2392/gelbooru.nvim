-- tests/integration/local_spec.lua
-- Exhaustive integration and adversarial tests for GelbooruLocal folder browsing,
-- metadata enrichment, safety invariants, offline resilience, and mode transitions.

local harness = require("tests.integration.helpers.harness")
local ui = require("gelbooru.ui")
local api = require("gelbooru.net.api")
local state = require("gelbooru.core.state")
local history = require("gelbooru.core.history")
local download = require("gelbooru.net.download")
local config = require("gelbooru.core.config")
local util = require("gelbooru.core.util")
local mock_snacks = require("tests.integration.helpers.mock_snacks")
local prewarmer = require("gelbooru.media.prewarmer")

describe("Integration: Local Folder Browser Mode", function()
  local tmp_dir
  local tmp_cache
  local orig_cache_dir

  before_each(function()
    harness.setup_all()
    harness.reset_environment()
    orig_cache_dir = config.options.cache_dir
    tmp_cache = vim.fn.tempname()
    vim.fn.mkdir(tmp_cache, "p")
    config.options.cache_dir = tmp_cache
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    -- Create dummy images (> 1024 bytes)
    for _, name in ipairs({ "10001.jpg", "10002.png", "artwork_no_id.webp" }) do
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
    config.options.cache_dir = orig_cache_dir
    vim.fn.delete(tmp_cache, "rf")
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

    -- Post 1 is 10001.jpg which has id = "10001". Mock net returns sample_posts[1].
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
    local target_file = tmp_dir .. "/10002.png"
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

    it("handles directory with ONLY non-image files (.txt, .zip, .json, .part, .md)", function()
      local non_img_dir = vim.fn.tempname()
      vim.fn.mkdir(non_img_dir, "p")
      vim.fn.writefile({ "text notes" }, non_img_dir .. "/notes.txt")
      vim.fn.writefile({ "archive data" }, non_img_dir .. "/archive.zip")
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
      local resolver = require("gelbooru.media.resolver")
      for _, p in ipairs(state.State.posts) do
        local urls, dest = resolver.get_preview_targets(p)
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
      local test_file = tmp_dir .. "/10001.jpg"
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

    it("'o' triggers web page lookup and 'O' opens local media viewer", function()
      ui.open_local(tmp_dir)

      -- Spy on util.open_url and util.open_media (or vim.ui.open)
      local opened_url = nil
      local orig_ui_open = vim.ui.open
      vim.ui.open = function(url)
        opened_url = url
      end

      local win_list = state.UI.wins.list
      vim.api.nvim_set_current_win(win_list)

      -- Post 1 has ID 10001
      state.State.cur = 1
      local p1 = state.State.posts[1]
      assert.are.equal("10001", tostring(p1.id))

      -- 'o' triggers web page lookup for post with ID
      opened_url = nil
      vim.cmd("normal o")
      assert.are.equal("https://gelbooru.com/index.php?page=post&s=view&id=10001", opened_url)

      -- 'O' triggers local media viewer for post 1
      opened_url = nil
      vim.cmd("normal O")
      assert.are.equal(p1.file_url, opened_url)

      -- Select post 3 (artwork_no_id.webp, id is nil)
      state.State.cur = 3
      local p3 = state.State.posts[3]
      assert.is_nil(p3.id)

      -- 'O' keymap action on post without ID still opens local media viewer
      opened_url = nil
      vim.cmd("normal O")
      assert.are.equal(p3.file_url, opened_url)

      -- 'o' keymap on post without ID must NOT open web page or local file, and must show status
      opened_url = nil
      vim.cmd("normal o")
      assert.is_nil(opened_url)
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("No post ID available for browser lookup"))

      -- Online post without ID or local file: 'O' shows status and does not open
      opened_url = nil
      state.State.posts[4] = { is_local = false, id = nil, file_url = nil }
      state.State.cur = 4
      vim.cmd("normal O")
      assert.is_nil(opened_url)
      status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("No post ID") or status_lines[1]:find("No file URL"))

      vim.ui.open = orig_ui_open
    end)

    it("force refresh 'R' strictly deletes ONLY the cache json and preserves media file bytes intact", function()
      local util = require("gelbooru.core.util")
      local test_file = tmp_dir .. "/10001.jpg"
      local original_content = "ORIGINAL_LOCAL_IMAGE_PAYLOAD_PROTECTED_" .. string.rep("X", 2000)
      local f = io.open(test_file, "wb")
      f:write(original_content)
      f:close()

      -- Create disk cache for post 10001
      local meta_path = util.meta_cache_path("10001")
      util.write_json(meta_path, { id = 10001, tags = "initial_cached_tag" })
      assert.are.equal(1, vim.fn.filereadable(meta_path))

      ui.open_local(tmp_dir)
      assert.are.equal(1, state.State.cur)
      local p = state.State.posts[1]
      assert.are.equal("10001", p.id)

      -- Trigger 'R' force refresh via list window normal mode mapping
      local win_list = state.UI.wins.list
      vim.api.nvim_set_current_win(win_list)
      vim.cmd("normal R")

      -- The cache JSON MUST be deleted from disk
      assert.are.equal(0, vim.fn.filereadable(meta_path))

      -- The local media file MUST still exist with identical bytes
      assert.are.equal(1, vim.fn.filereadable(test_file))
      local f_read = io.open(test_file, "rb")
      assert.is_truthy(f_read)
      local content_after = f_read:read("*a")
      f_read:close()
      assert.are.equal(original_content, content_after)
    end)

    it("force refresh 'R' on post without ID preserves media file and skips cache deletion cleanly", function()
      local test_file = tmp_dir .. "/artwork_no_id.webp"
      local original_content = "ORIGINAL_WEBP_NO_ID_" .. string.rep("Z", 1500)
      local f = io.open(test_file, "wb")
      f:write(original_content)
      f:close()

      ui.open_local(tmp_dir)
      state.State.cur = 3
      local p = state.State.posts[3]
      assert.is_nil(p.id)

      local win_list = state.UI.wins.list
      vim.api.nvim_set_current_win(win_list)
      vim.cmd("normal R")

      -- Media file must remain intact and no error raised
      assert.are.equal(1, vim.fn.filereadable(test_file))
      local f_read = io.open(test_file, "rb")
      local content_after = f_read:read("*a")
      f_read:close()
      assert.are.equal(original_content, content_after)
    end)
  end)

  describe("Local Video Pipeline & Playback", function()
    local vid_dir

    before_each(function()
      vid_dir = vim.fn.tempname()
      vim.fn.mkdir(vid_dir, "p")
      vim.fn.writefile({ string.rep("V", 1200) }, vid_dir .. "/01_sample.mp4")
      vim.fn.writefile({ string.rep("W", 1200) }, vid_dir .. "/02_sample.webm")
      vim.fn.writefile({ string.rep("P", 1200) }, vid_dir .. "/03_sample.png")
    end)

    after_each(function()
      vim.fn.delete(vid_dir, "rf")
    end)

    it("scans video files, labels them with [VIDEO] badge in list, and 'O' launches open_media", function()
      local util = require("gelbooru.core.util")
      ui.open_local(vid_dir)

      assert.are.equal(3, #state.State.posts)
      local list_lines = harness.get_buf_lines(state.UI.bufs.list)
      assert.are.equal(3, #list_lines)

      -- Video posts have [VIDEO] badge in list line
      assert.is_truthy(list_lines[1]:find("%[VIDEO%]"))
      assert.is_truthy(list_lines[2]:find("%[VIDEO%]"))
      -- Non-video image does NOT have [VIDEO] badge
      assert.is_falsy(list_lines[3]:find("%[VIDEO%]"))

      -- Spy on util.open_media
      local opened_media = nil
      local orig_open_media = util.open_media
      util.open_media = function(target)
        opened_media = target
        return true
      end

      -- Select post 1 (mp4) and press 'O'
      state.State.cur = 1
      local win_list = state.UI.wins.list
      vim.api.nvim_set_current_win(win_list)
      vim.cmd("normal O")

      assert.are.equal(state.State.posts[1].file_url, opened_media)
      assert.is_truthy(opened_media:find("%.mp4$"))

      -- Select post 2 (webm) and press 'O'
      opened_media = nil
      state.State.cur = 2
      vim.cmd("normal O")
      assert.are.equal(state.State.posts[2].file_url, opened_media)
      assert.is_truthy(opened_media:find("%.webm$"))

      util.open_media = orig_open_media
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

      assert.are.equal(1, calls_by_id["10001"])

      -- Move away to post 2 (triggers fetch for 10002)
      state.State.cur = 2
      ui.render_preview(false)
      vim.wait(300, function()
        local p2 = state.State.posts[2]
        return p2 and p2._metadata_fetched == true
      end, 20)
      assert.are.equal(1, calls_by_id["10002"])

      -- Move back to post 1: must NOT trigger a second fetch for 10001
      state.State.cur = 1
      ui.render_preview(false)
      vim.wait(100, function() return false end, 10)
      assert.are.equal(1, calls_by_id["10001"])

      -- Move back to post 2: must NOT trigger a second fetch for 10002
      state.State.cur = 2
      ui.render_preview(false)
      vim.wait(100, function() return false end, 10)
      assert.are.equal(1, calls_by_id["10002"])
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
          post = { { id = 10001, tags = "should_be_ignored" } },
        }))
      end

      -- Verify no panic, windows are gone
      assert.is_nil(state.UI.wins.frame)
    end)
  end)

  describe("Sprint 2: Local Tag Filtering & Search Routing Integration", function()
    it("execute_search('local: <tags>') routes to open_local and filters default save_dir", function()
      -- Seed save_dir with images
      local save_img1 = config.options.save_dir .. "/2001_hatsune_miku.png"
      local save_img2 = config.options.save_dir .. "/2002_megurine_luka.png"
      local f1 = io.open(save_img1, "wb")
      if f1 then f1:write(string.rep("A", 2048)) f1:close() end
      local f2 = io.open(save_img2, "wb")
      if f2 then f2:write(string.rep("B", 2048)) f2:close() end

      ui.open()
      api.execute_search("local: miku")

      assert.are.equal("local: miku", state.State.query)
      assert.are.equal(1, #state.State.posts)
      assert.is_truthy(state.State.posts[1].file_url:find("2001_hatsune_miku"))
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("miku"))
    end)

    it("execute_search('local:<dir> <tags>') routes to open_local with custom folder", function()
      local custom_dir = vim.fn.tempname()
      vim.fn.mkdir(custom_dir, "p")
      local f1 = io.open(custom_dir .. "/pic_solo.jpg", "wb")
      if f1 then f1:write(string.rep("A", 2048)) f1:close() end
      local f2 = io.open(custom_dir .. "/pic_duet.jpg", "wb")
      if f2 then f2:write(string.rep("B", 2048)) f2:close() end

      ui.open()
      api.execute_search("local:" .. custom_dir .. " solo")

      assert.are.equal("local:" .. custom_dir .. " solo", state.State.query)
      assert.are.equal(1, #state.State.posts)
      assert.is_truthy(state.State.posts[1].file_url:find("pic_solo"))

      vim.fn.delete(custom_dir, "rf")
    end)

    it("displays informative status message and 'No images found' when query matches 0 posts", function()
      ui.open_local(tmp_dir)
      api.execute_search("local:" .. tmp_dir .. " non_existent_tag_xyz")

      assert.are.equal(0, #state.State.posts)
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("No posts matching 'non_existent_tag_xyz'"))

      local list_lines = harness.get_buf_lines(state.UI.bufs.list)
      assert.is_truthy(list_lines[1]:find("No images found"))

      local img_lines = harness.get_buf_lines(state.UI.bufs.img)
      assert.is_truthy(img_lines[1]:find("No images found"))
    end)

    it("preserves history stack with exact State.query and filtered post count across [ and ]", function()
      local query1 = "local:" .. tmp_dir
      ui.open_local(tmp_dir)
      assert.are.equal(3, #state.State.posts)

      -- Query 2: filter for 10001
      api.execute_search("local:" .. tmp_dir .. " 10001")
      assert.are.equal(1, #state.State.posts)
      assert.are.equal("local:" .. tmp_dir .. " 10001", state.State.query)

      -- Navigate back with history_prev ([)
      history.history_prev()
      assert.are.equal(query1, state.State.query)
      assert.are.equal(3, #state.State.posts)

      -- Navigate forward with history_next (])
      history.history_next()
      assert.are.equal("local:" .. tmp_dir .. " 10001", state.State.query)
      assert.are.equal(1, #state.State.posts)
    end)
  end)

  describe("Sprint 2: Video Pipeline Verification (.mp4, .webm, [VIDEO] badge, keymaps)", function()
    local vid_dir

    before_each(function()
      vid_dir = vim.fn.tempname()
      vim.fn.mkdir(vid_dir, "p")
      local f1 = io.open(vid_dir .. "/animation.mp4", "wb")
      if f1 then f1:write(string.rep("V", 2048)) f1:close() end
      local f2 = io.open(vid_dir .. "/clip.webm", "wb")
      if f2 then f2:write(string.rep("W", 2048)) f2:close() end
      local f3 = io.open(vid_dir .. "/still.jpg", "wb")
      if f3 then f3:write(string.rep("J", 2048)) f3:close() end
    end)

    after_each(function()
      if vid_dir and vim.fn.isdirectory(vid_dir) == 1 then
        vim.fn.delete(vid_dir, "rf")
      end
    end)

    it("scans and classifies .mp4 and .webm as video posts", function()
      local posts = ui.scan_local_folder(vid_dir)
      assert.are.equal(3, #posts)

      local resolver = require("gelbooru.media.resolver")
      local vids = 0
      for _, p in ipairs(posts) do
        if resolver.is_video_post(p) then
          vids = vids + 1
        end
      end
      assert.are.equal(2, vids)
    end)

    it("render_list displays [VIDEO] badge for video media", function()
      ui.open_local(vid_dir)
      assert.are.equal(3, #state.State.posts)

      local list_lines = harness.get_buf_lines(state.UI.bufs.list)
      local video_badges = 0
      for _, line in ipairs(list_lines) do
        if line:find("%[VIDEO%]") then
          video_badges = video_badges + 1
        end
      end
      assert.are.equal(2, video_badges)
    end)

    it("keymap O opens video post via util.open_media", function()
      ui.open_local(vid_dir)

      local opened = nil
      local orig_open_media = util.open_media
      util.open_media = function(target)
        opened = target
        return true
      end

      -- Focus first post (animation.mp4)
      state.State.cur = 1
      assert.is_truthy(state.State.posts[1].file_url:find("animation.mp4"))

      local list_win = state.UI.wins.list
      vim.api.nvim_set_current_win(list_win)
      vim.cmd("normal O")

      assert.is_not_nil(opened)
      assert.is_truthy(opened:find("animation.mp4"))

      util.open_media = orig_open_media
    end)

    it("keymap <CR> on local post displays local file notice and does NOT initiate download", function()
      ui.open_local(vid_dir)

      local download_started = false
      local orig_download = download.download_async
      download.download_async = function(...)
        download_started = true
        return orig_download(...)
      end

      state.State.cur = 1
      api.save_current()

      assert.is_false(download_started)
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("Local file:"))

      download.download_async = orig_download
    end)
  end)

  describe("Adversarial Integration Suite: Local Query Filtering & Robustness", function()
    local adv_dir

    before_each(function()
      adv_dir = vim.fn.tempname()
      vim.fn.mkdir(adv_dir, "p")
      -- Seed images with various tag and name patterns
      -- 1. Caterpillar post
      local f1 = io.open(adv_dir .. "/10101_caterpillar.png", "wb")
      if f1 then f1:write(string.rep("A", 2048)) f1:close() end
      util.write_json(util.meta_cache_path("10101"), {
        id = "10101",
        tags = "caterpillar insect nature",
        rating = "general",
        score = 15,
      })

      -- 2. Cat post
      local f2 = io.open(adv_dir .. "/10102_cat.png", "wb")
      if f2 then f2:write(string.rep("B", 2048)) f2:close() end
      util.write_json(util.meta_cache_path("10102"), {
        id = "10102",
        tags = "cat feline animal black_cat",
        rating = "sensitive",
        score = -12,
      })

      -- 3. Complex special characters and negative score
      local f3 = io.open(adv_dir .. "/10103_special_c++.png", "wb")
      if f3 then f3:write(string.rep("C", 2048)) f3:close() end
      util.write_json(util.meta_cache_path("10103"), {
        id = "10103",
        tags = "tag(1) c++ [brackets] * ?",
        rating = "explicit",
        score = -25,
      })

      -- 4. Untagged image with dots in filename
      local f4 = io.open(adv_dir .. "/untagged.art.solo.2024.jpg", "wb")
      if f4 then f4:write(string.rep("D", 2048)) f4:close() end

      -- 5. Video post .mp4
      local f5 = io.open(adv_dir .. "/10105_sample_anim.mp4", "wb")
      if f5 then f5:write(string.rep("E", 2048)) f5:close() end
      util.write_json(util.meta_cache_path("10105"), {
        id = "10105",
        tags = "animation 3d video",
        rating = "questionable",
        score = 50,
      })
    end)

    after_each(function()
      if adv_dir and vim.fn.isdirectory(adv_dir) == 1 then
        vim.fn.delete(adv_dir, "rf")
      end
    end)

    it("tag word boundary matching: searching 'cat' in local folder should not match 'caterpillar'", function()
      ui.open_local(adv_dir .. " cat")

      -- Only 102_cat.png should match 'cat'
      assert.are.equal(1, #state.State.posts)
      assert.are.equal("10102", state.State.posts[1].id)
    end)

    it("handles negative scores (score:<-10) and boundary filters in execute_search", function()
      ui.open()
      api.execute_search("local:" .. adv_dir .. " score:<-10")

      -- Posts with score < -10: 10102 (-12) and 10103 (-25)
      assert.are.equal(2, #state.State.posts)
      for _, p in ipairs(state.State.posts) do
        assert.is_true(p.score < -10)
      end
    end)

    it("handles malformed queries: unclosed quotes and weird whitespace gracefully via execute_search", function()
      ui.open()

      -- Unclosed quote in directory
      api.execute_search('local:"' .. adv_dir .. ' cat')
      assert.is_truthy(state.UI.wins.frame)
      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.frame))

      -- Tabs and excess whitespace
      api.execute_search("local:\t\t" .. adv_dir .. "  \t \t solo \t  ")
      assert.are.equal(1, #state.State.posts)
      assert.is_truthy(state.State.posts[1].file_url:find("untagged.art.solo"))
    end)

    it("handles special regex characters in tags (tag(1), c++, [brackets], *, ?) without crash", function()
      ui.open()
      api.execute_search("local:" .. adv_dir .. " c++")

      assert.are.equal(1, #state.State.posts)
      assert.are.equal("10103", state.State.posts[1].id)

      -- Negative matching with special chars
      api.execute_search("local:" .. adv_dir .. " -c++")
      for _, p in ipairs(state.State.posts) do
        assert.are.not_equal("10103", p.id)
      end
    end)

    it("survives rapid local query switching and history preservation", function()
      ui.open_local(adv_dir)
      assert.are.equal(5, #state.State.posts)

      -- Rapidly fire 5 different query searches in succession
      api.execute_search("local:" .. adv_dir .. " cat")
      api.execute_search("local:" .. adv_dir .. " c++")
      api.execute_search("local:" .. adv_dir .. " solo")
      api.execute_search("local:" .. adv_dir .. " rating:explicit")
      api.execute_search("local:" .. adv_dir .. " -rating:explicit")

      assert.are.equal("local:" .. adv_dir .. " -rating:explicit", state.State.query)
      -- 10101, 10102, untagged, video are non-explicit
      assert.are.equal(4, #state.State.posts)

      -- History navigation backward works cleanly
      history.history_prev()
      assert.are.equal("local:" .. adv_dir .. " rating:explicit", state.State.query)
      assert.are.equal(1, #state.State.posts)
      assert.are.equal("10103", state.State.posts[1].id)
    end)

    it("teardown safety during local query search and zero-result keypress flurry", function()
      ui.open_local(adv_dir .. " non_existent_tag_zero_results")
      assert.are.equal(0, #state.State.posts)

      -- Stress test keymaps on empty list buffer without crashing
      local win_list = state.UI.wins.list
      vim.api.nvim_set_current_win(win_list)

      vim.cmd("normal j")
      vim.cmd("normal k")
      vim.cmd("normal O")
      vim.cmd("normal o")
      vim.cmd("normal u")
      vim.cmd("normal \r")
      vim.cmd("normal R")
      vim.cmd("normal m")
      vim.cmd("normal m")
      vim.cmd("normal \\")
      vim.cmd("normal \\")
      vim.cmd("normal <")
      vim.cmd("normal >")

      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.frame))

      -- Immediate teardown
      ui.teardown()
      assert.is_true(state.State.torn_down)
      assert.is_nil(state.UI.wins.frame)
    end)

    it("video pipeline: .mp4 post renders [VIDEO] badge and 'O' invokes util.open_media", function()
      ui.open_local(adv_dir)

      local opened_path = nil
      local orig_open_media = util.open_media
      util.open_media = function(path)
        opened_path = path
        return true
      end

      -- Filter for video post
      api.execute_search("local:" .. adv_dir .. " animation")
      assert.are.equal(1, #state.State.posts)
      assert.is_truthy(state.State.posts[1].file_url:find("10105_sample_anim.mp4"))

      -- List buffer has [VIDEO] badge
      local list_lines = harness.get_buf_lines(state.UI.bufs.list)
      assert.is_truthy(list_lines[1]:find("%[VIDEO%]"))

      -- Press 'O' to open
      local win_list = state.UI.wins.list
      vim.api.nvim_set_current_win(win_list)
      vim.cmd("normal O")

      assert.is_not_nil(opened_path)
      assert.is_truthy(opened_path:find("sample_anim.mp4"))

      util.open_media = orig_open_media
    end)
  end)

  describe("Sprint 3: Dual-Tier Lookahead & Online-Local Hybrid Index Integration", function()
    local local_index = require("gelbooru.local.index")
    local indexer = require("gelbooru.local.indexer")
    local canvas = require("gelbooru.ui.canvas")

    before_each(function()
      local_index.reset()
      indexer.stop()
    end)

    after_each(function()
      indexer.stop()
      local_index.reset()
    end)

    it("render_list displays [SAVED] badge for online posts when present in save_dir and updates via mtime cache", function()
      local saved_file = config.options.save_dir .. "/10001.jpg"
      local f = io.open(saved_file, "wb")
      if f then f:write(string.rep("S", 2048)) f:close() end

      ui.open("hatsune_miku")
      vim.wait(300, function() return #state.State.posts > 0 end, 10)

      assert.are.equal(3, #state.State.posts)
      assert.are.equal(10001, state.State.posts[1].id)
      assert.are.equal(10002, state.State.posts[2].id)

      ui.render_list()

      local list_lines = harness.get_buf_lines(state.UI.bufs.list)
      assert.is_truthy(list_lines[1]:find("%[SAVED%]"))
      assert.is_falsy(list_lines[2]:find("%[SAVED%]"))

      state.State.posts[1].is_local = true
      ui.render_list()
      list_lines = harness.get_buf_lines(state.UI.bufs.list)
      assert.is_falsy(list_lines[1]:find("%[SAVED%]"))
    end)

    it("instant canvas upgrade to saved file and [SAVED] list badge on <CR> save completion", function()
      ui.open("hatsune_miku")
      vim.wait(300, function() return #state.State.posts > 0 end, 10)

      state.State.cur = 2
      local p2 = state.State.posts[2]
      assert.are.equal(10002, p2.id)

      ui.render_list()
      local list_lines_before = harness.get_buf_lines(state.UI.bufs.list)
      assert.is_falsy(list_lines_before[2]:find("%[SAVED%]"))
      assert.is_false(local_index.is_saved(10002))

      local rendered_image_path = nil
      local orig_render_image = canvas.render
      canvas.render = function(win, path)
        rendered_image_path = path
        return orig_render_image(win, path)
      end

      local save_cb_called = false
      api.save_current(function(saved, dest)
        save_cb_called = true
        assert.is_true(saved)
        assert.is_truthy(dest:find("10002"))
      end)

      vim.wait(500, function() return save_cb_called end, 10)
      assert.is_true(save_cb_called)

      assert.is_true(local_index.is_saved(10002))

      assert.is_not_nil(rendered_image_path)
      assert.is_truthy(rendered_image_path:find("10002"))
      assert.are.equal(1, vim.fn.filereadable(rendered_image_path))

      local list_lines_after = harness.get_buf_lines(state.UI.bufs.list)
      assert.is_truthy(list_lines_after[2]:find("%[SAVED%]"))

      canvas.render = orig_render_image
    end)

    it("render_preview triggers cursor_rush_prefetch for local posts with current cursor and direction", function()
      ui.open_local(tmp_dir)

      local prefetch_called = false
      local prefetch_idx = nil
      local prefetch_dir = nil
      local orig_rush = indexer.cursor_rush_prefetch
      indexer.cursor_rush_prefetch = function(idx, dir)
        prefetch_called = true
        prefetch_idx = idx
        prefetch_dir = dir
        return orig_rush(idx, dir)
      end

      state.State.cur = 2
      state.State.scroll_dir = -1

      ui.render_preview(false)

      assert.is_true(prefetch_called)
      assert.are.equal(2, prefetch_idx)
      assert.are.equal(-1, prefetch_dir)

      indexer.cursor_rush_prefetch = orig_rush
    end)

    it("open_local initiates background indexing via start_background_indexing", function()
      local bg_started = false
      local bg_posts_count = nil
      local orig_start_bg = indexer.start_background_indexing
      indexer.start_background_indexing = function(posts)
        bg_started = true
        bg_posts_count = #posts
        return orig_start_bg(posts)
      end

      ui.open_local(tmp_dir)

      assert.is_true(bg_started)
      assert.are.equal(3, bg_posts_count)

      indexer.start_background_indexing = orig_start_bg
    end)

    it("teardown stops indexer timers cleanly with zero memory leaks", function()
      ui.open_local(tmp_dir)

      local fresh_posts = {
        { id = "9901", is_local = true },
        { id = "9902", is_local = true },
      }
      indexer.start_background_indexing(fresh_posts)
      assert.is_not_nil(state.UI.indexer_timer)

      ui.teardown()

      assert.is_true(state.State.torn_down)
      assert.is_nil(state.UI.indexer_timer)
    end)
  end)

  describe("Local File Deletion ('d' / 'D')", function()
    local function get_keymap_cb(buf, mode, key)
      if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return nil
      end
      local maps = vim.api.nvim_buf_get_keymap(buf, mode or "n")
      for _, m in ipairs(maps) do
        if m.lhs == key then
          return m.callback or function()
            if m.rhs then
              vim.cmd("normal! " .. m.rhs)
            end
          end
        end
      end
      return nil
    end

    it("guards against deleting unsaved remote post and displays status notice", function()
      ui.open()
      state.State.posts = {
        { id = 5001, file_url = "https://example.com/5001.jpg", rating = "g", score = 10, is_local = false },
      }
      state.State.cur = 1
      ui.render_list()

      local d_cb = get_keymap_cb(state.UI.bufs.list, "n", "d")
      assert.is_not_nil(d_cb, "'d' keymap must be registered on list buffer")

      local select_called = false
      local orig_select = vim.ui.select
      vim.ui.select = function()
        select_called = true
      end

      d_cb()

      assert.is_false(select_called, "confirmation dialog should not be shown for unsaved post")
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("Post is not saved locally"))

      vim.ui.select = orig_select
    end)

    it("cancels deletion when user selects Cancel in confirmation dialog", function()
      ui.open_local(tmp_dir)
      local target_file = tmp_dir .. "/10001.jpg"
      assert.are.equal(1, vim.fn.filereadable(target_file))

      local orig_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice)
        assert.is_truthy(opts.prompt:find("Delete local file: 10001.jpg"))
        on_choice("Cancel")
      end

      local d_cb = get_keymap_cb(state.UI.bufs.list, "n", "d")
      d_cb()

      -- File remains on disk
      assert.are.equal(1, vim.fn.filereadable(target_file))
      -- Post remains in State.posts
      assert.are.equal(3, #state.State.posts)
      assert.are.equal(1, state.State.cur)

      vim.ui.select = orig_select
    end)

    it("deletes local file, removes cached metadata and thumbnail, unmarks saved_index, keeps user focused in viewer, and updates display", function()
      local local_index = require("gelbooru.local.index")
      local target_file = tmp_dir .. "/10001.jpg"
      assert.are.equal(1, vim.fn.filereadable(target_file))

      -- Create meta cache file and thumbnail file
      local meta_path = util.meta_cache_path("10001")
      util.write_json(meta_path, {
        id = "10001",
        file_url = "https://example.com/10001.jpg",
        preview_url = "https://example.com/1001_prev.jpg",
        tags = "hatsune_miku 1girl",
      })
      local vthumb_path = string.format("%s/vthumb_%s.jpg", config.options.cache_dir, "10001")
      local vf = io.open(vthumb_path, "wb")
      if vf then vf:write("dummy thumbnail") vf:close() end

      ui.open_local(tmp_dir)
      local initial_count = #state.State.posts
      assert.are.equal(1, state.State.cur)

      local orig_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice)
        assert.is_truthy(opts.prompt:find("10001.jpg"))
        on_choice("Yes, delete file")
      end

      local d_cb = get_keymap_cb(state.UI.bufs.list, "n", "d")
      d_cb()

      -- 1. File remains readable on disk until UI teardown
      assert.are.equal(1, vim.fn.filereadable(target_file))
      assert.is_not_nil(state.State.pending_deletions["10001"] or state.State.pending_deletions[target_file])
      -- 2. Metadata cache and video thumbnail remain intact for inspection
      assert.are.equal(1, vim.fn.filereadable(meta_path))
      assert.are.equal(1, vim.fn.filereadable(vthumb_path))
      -- 3. Unmarked from saved_index immediately
      assert.is_false(local_index.is_saved(10001))
      -- 4. User remains focused on the EXACT same post
      assert.are.equal(initial_count, #state.State.posts)
      assert.are.equal(1, state.State.cur)
      local current_post = state.State.posts[state.State.cur]
      assert.are.equal("10001", tostring(current_post.id))
      -- 5. Post list display updated (no [SAVED] marker)
      local list_lines = harness.get_buf_lines(state.UI.bufs.list)
      assert.is_nil(list_lines[1]:find("%[SAVED%]"))
      -- 6. Status notice displayed indicating deferred deletion
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("deferred until exit"))

      -- 7. Actual physical unlinking happens on teardown
      ui.teardown()
      assert.are.equal(0, vim.fn.filereadable(target_file))
      assert.are.equal(0, vim.fn.filereadable(meta_path))
      assert.are.equal(0, vim.fn.filereadable(vthumb_path))

      vim.ui.select = orig_select
    end)

    it("allows cancelling confirmation dialog with no changes", function()
      local local_index = require("gelbooru.local.index")
      local target_file = tmp_dir .. "/10001.jpg"

      ui.open_local(tmp_dir)
      -- Mark saved AFTER open_local so the saved_index survives the directory rescan
      local_index.mark_saved(10001, "jpg")
      assert.is_true(local_index.is_saved(10001))

      local orig_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice)
        on_choice("Cancel")
      end

      local d_cb = get_keymap_cb(state.UI.bufs.list, "n", "d")
      d_cb()

      assert.are.equal(1, vim.fn.filereadable(target_file))
      assert.is_nil(state.State.pending_deletions["10001"])
      -- Cancel means no pending deletion, so is_saved is still true
      assert.is_true(local_index.is_saved(10001))

      vim.ui.select = orig_select
    end)

    it("allows restoring pending deletion via <CR> without network re-download", function()
      local local_index = require("gelbooru.local.index")
      local target_file = tmp_dir .. "/10001.jpg"
      local_index.mark_saved(10001, "jpg")

      ui.open_local(tmp_dir)

      local orig_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice)
        on_choice("Yes, delete file")
      end

      local d_cb = get_keymap_cb(state.UI.bufs.list, "n", "d")
      d_cb()

      assert.are.equal(1, vim.fn.filereadable(target_file))
      assert.is_false(local_index.is_saved(10001))
      assert.is_not_nil(state.State.pending_deletions["10001"] or state.State.pending_deletions[target_file])

      -- Press <CR> to restore before exit
      local restore_done = false
      api.save_current(function(saved, dest)
        restore_done = true
        assert.is_true(saved)
      end)

      assert.is_true(restore_done)
      assert.is_true(local_index.is_saved(10001))
      assert.is_nil(state.State.pending_deletions["10001"])

      -- On teardown, the file is NOT unlinked because deletion was aborted!
      ui.teardown()
      assert.are.equal(1, vim.fn.filereadable(target_file))

      vim.ui.select = orig_select
    end)

    it("keymap 'D' and keymap 'd' from meta buffer schedule deferred deletion", function()
      local target_file = tmp_dir .. "/10001.jpg"
      ui.open_local(tmp_dir)

      -- 1. 'D' on list buffer
      local D_cb = get_keymap_cb(state.UI.bufs.list, "n", "D")
      assert.is_not_nil(D_cb, "'D' must be registered on list buffer")

      -- 2. 'd' and 'D' on meta buffer
      local meta_d_cb = get_keymap_cb(state.UI.bufs.meta, "n", "d")
      local meta_D_cb = get_keymap_cb(state.UI.bufs.meta, "n", "D")
      assert.is_not_nil(meta_d_cb, "'d' must be registered on meta buffer")
      assert.is_not_nil(meta_D_cb, "'D' must be registered on meta buffer")

      local orig_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice)
        on_choice("Yes, delete file")
      end

      meta_d_cb()

      assert.are.equal(1, vim.fn.filereadable(target_file))
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("deferred until exit"))

      ui.teardown()
      assert.are.equal(0, vim.fn.filereadable(target_file))

      vim.ui.select = orig_select
    end)

    it("deletes a downloaded online post on teardown and removes [SAVED] immediately", function()
      local local_index = require("gelbooru.local.index")
      local saved_file = config.options.save_dir .. "/10001.jpg"
      local f = io.open(saved_file, "wb")
      if f then f:write(string.rep("Z", 2048)) f:close() end
      local_index.mark_saved(10001, "jpg")
      assert.is_true(local_index.is_saved(10001))

      ui.open("hatsune_miku")
      state.State.posts = {
        { id = 10001, file_url = "https://example.com/10001.jpg", rating = "g", score = 50, is_local = false },
      }
      state.State.cur = 1
      ui.render_list()

      local list_lines_before = harness.get_buf_lines(state.UI.bufs.list)
      assert.is_truthy(list_lines_before[1]:find("%[SAVED%]"))

      local orig_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice)
        on_choice("Yes, delete file")
      end

      local d_cb = get_keymap_cb(state.UI.bufs.list, "n", "d")
      d_cb()

      -- File remains on disk until teardown
      assert.are.equal(1, vim.fn.filereadable(saved_file))
      assert.is_false(local_index.is_saved(10001))
      assert.are.equal(1, state.State.cur)
      assert.are.equal(1, #state.State.posts)

      -- [SAVED] badge immediately removed from post list
      local list_lines_after = harness.get_buf_lines(state.UI.bufs.list)
      assert.is_nil(list_lines_after[1]:find("%[SAVED%]"))

      -- Physical unlink occurs on teardown
      ui.teardown()
      assert.are.equal(0, vim.fn.filereadable(saved_file))

      vim.ui.select = orig_select
    end)

    it("shows 'already scheduled' status if d is pressed twice on same post", function()
      local target_file = tmp_dir .. "/10001.jpg"
      ui.open_local(tmp_dir)

      local orig_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice)
        on_choice("Yes, delete file")
      end

      local d_cb = get_keymap_cb(state.UI.bufs.list, "n", "d")
      d_cb()

      -- Second press on same post
      d_cb()
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("already scheduled") or status_lines[1]:find("Already scheduled"))

      vim.ui.select = orig_select
      ui.teardown()
    end)

    it("floating confirmation modal allows navigation with j/k and confirm with <CR>", function()
      local target_file = tmp_dir .. "/10001.jpg"
      ui.open_local(tmp_dir)

      local d_cb = get_keymap_cb(state.UI.bufs.list, "n", "d")
      d_cb()

      assert.is_not_nil(state.UI.wins.confirm_modal)
      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.confirm_modal))

      local modal_buf = state.UI.bufs.confirm_modal
      local j_cb = get_keymap_cb(modal_buf, "n", "j")
      local k_cb = get_keymap_cb(modal_buf, "n", "k")
      local cr_cb = get_keymap_cb(modal_buf, "n", "<CR>")

      -- Navigate down to Cancel then up to Yes
      j_cb()
      local lines_cancel = harness.get_buf_lines(modal_buf)
      assert.is_truthy(lines_cancel[5]:find("▶ Cancel"))

      k_cb()
      local lines_yes = harness.get_buf_lines(modal_buf)
      assert.is_truthy(lines_yes[4]:find("▶ Yes"))

      -- Press <CR> on Yes
      cr_cb()
      assert.is_nil(state.UI.wins.confirm_modal)
      assert.is_not_nil(state.State.pending_deletions["10001"] or state.State.pending_deletions[target_file])

      ui.teardown()
      assert.are.equal(0, vim.fn.filereadable(target_file))
    end)

    it("pending deletion survives history navigation without being cleared", function()
      local target_file = tmp_dir .. "/10001.jpg"
      ui.open_local(tmp_dir)

      local orig_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice)
        on_choice("Yes, delete file")
      end

      local d_cb = get_keymap_cb(state.UI.bufs.list, "n", "d")
      d_cb()
      assert.is_not_nil(state.State.pending_deletions["10001"] or state.State.pending_deletions[target_file])

      -- Navigate history
      local history = require("gelbooru.core.history")
      history.push_history("test_query")
      assert.is_not_nil(state.State.pending_deletions["10001"] or state.State.pending_deletions[target_file])

      history.history_prev()
      assert.is_not_nil(state.State.pending_deletions["10001"] or state.State.pending_deletions[target_file])

      vim.ui.select = orig_select
      ui.teardown()
      assert.are.equal(0, vim.fn.filereadable(target_file))
    end)

    it("clears State.pending_deletions table on ui.teardown()", function()
      local target_file = tmp_dir .. "/10001.jpg"
      ui.open_local(tmp_dir)

      local orig_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice)
        on_choice("Yes, delete file")
      end

      local d_cb = get_keymap_cb(state.UI.bufs.list, "n", "d")
      d_cb()

      ui.teardown()
      assert.are.equal(0, vim.tbl_count(state.State.pending_deletions or {}))
      vim.ui.select = orig_select
    end)
  end)

  describe("Lazy On-Demand Image Dimension Resolution", function()
    local dim_dir

    local function make_png(path, w, h)
      local sig = string.char(137, 80, 78, 71, 13, 10, 26, 10)
      local ihdr_len = string.char(0, 0, 0, 13)
      local ihdr_type = "IHDR"
      local w_bytes = string.char(math.floor(w / 16777216) % 256, math.floor(w / 65536) % 256, math.floor(w / 256) % 256, w % 256)
      local h_bytes = string.char(math.floor(h / 16777216) % 256, math.floor(h / 65536) % 256, math.floor(h / 256) % 256, h % 256)
      local ihdr_tail = string.char(8, 2, 0, 0, 0, 0, 0, 0, 0)
      local f = io.open(path, "wb")
      if f then
        f:write(sig .. ihdr_len .. ihdr_type .. w_bytes .. h_bytes .. ihdr_tail .. string.rep("0", 1024))
        f:close()
      end
    end

    local function make_jpg(path, w, h)
      local soi = string.char(255, 216)
      local sof0 = string.char(255, 192, 0, 17, 8, math.floor(h / 256) % 256, h % 256, math.floor(w / 256) % 256, w % 256, 3, 1, 17, 0, 2, 17, 1, 3, 17, 1)
      local f = io.open(path, "wb")
      if f then
        f:write(soi .. sof0 .. string.rep("J", 1024))
        f:close()
      end
    end

    before_each(function()
      dim_dir = vim.fn.tempname()
      vim.fn.mkdir(dim_dir, "p")
      make_png(dim_dir .. "/01_banner.png", 1920, 1080)
      make_jpg(dim_dir .. "/02_portrait.jpg", 1280, 720)
      make_png(dim_dir .. "/03_square.png", 800, 800)
    end)

    after_each(function()
      if dim_dir and vim.fn.isdirectory(dim_dir) == 1 then
        vim.fn.delete(dim_dir, "rf")
      end
    end)

    it("scan_local_folder does not synchronously inspect image headers and completes under 5ms", function()
      local orig_read = util.read_image_dimensions
      local read_calls = 0
      util.read_image_dimensions = function(...)
        read_calls = read_calls + 1
        return orig_read(...)
      end

      local uv = vim.uv or vim.loop
      local t0 = uv.hrtime()
      local posts = ui.scan_local_folder(dim_dir)
      local elapsed_ms = (uv.hrtime() - t0) / 1e6
      util.read_image_dimensions = orig_read

      assert.are.equal(3, #posts)
      assert.are.equal(0, read_calls)
      assert.is_true(elapsed_ms < 10, string.format("Scan took %.2f ms, expected fast scan", elapsed_ms))
      for _, p in ipairs(posts) do
        assert.is_nil(p.width)
        assert.is_nil(p.height)
      end
    end)

    it("open_local lazily resolves dimensions for the active post and formats them in list and metadata panel", function()
      ui.open_local(dim_dir)

      assert.are.equal(3, #state.State.posts)
      assert.are.equal(1, state.State.cur)

      -- Active post (1) should have dimensions lazily resolved
      local p1 = state.State.posts[1]
      assert.are.equal(1920, p1.width)
      assert.are.equal(1080, p1.height)

      -- Inactive posts should remain unresolved (lazy)
      local p2 = state.State.posts[2]
      assert.is_nil(p2.width)
      assert.is_nil(p2.height)

      local p3 = state.State.posts[3]
      assert.is_nil(p3.width)
      assert.is_nil(p3.height)

      -- Post list buffer must render real dimensions for active post
      local list_lines = harness.get_buf_lines(state.UI.bufs.list)
      assert.is_truthy(list_lines[1]:find("1920x1080"))
      assert.is_falsy(list_lines[1]:find("0x0"))

      -- Post list buffer for inactive posts still renders 0x0 placeholder
      assert.is_truthy(list_lines[2]:find("0x0"))

      -- Metadata panel must render real dimensions
      local meta_lines = harness.get_buf_lines(state.UI.bufs.meta)
      local found_size = false
      for _, line in ipairs(meta_lines) do
        if line:find("Size%s*:%s*1920x1080") then
          found_size = true
        end
      end
      assert.is_true(found_size)
    end)

    it("navigating via on_cursor_change lazily resolves dimensions for the newly active post", function()
      ui.open_local(dim_dir)
      assert.are.equal(1, state.State.cur)

      -- Post 2 is initially unresolved
      assert.is_nil(state.State.posts[2].width)
      assert.is_nil(state.State.posts[2].height)

      -- Navigate down to post 2
      ui.on_cursor_change(1)
      assert.are.equal(2, state.State.cur)

      -- Post 2 should now have lazily resolved dimensions
      local p2 = state.State.posts[2]
      assert.are.equal(1280, p2.width)
      assert.are.equal(720, p2.height)

      -- Post list line for post 2 must now show 1280x720 instead of 0x0
      local list_lines = harness.get_buf_lines(state.UI.bufs.list)
      assert.is_truthy(list_lines[2]:find("1280x720"))
      assert.is_falsy(list_lines[2]:find("0x0"))

      -- Metadata panel must now show Size : 1280x720
      local meta_lines = harness.get_buf_lines(state.UI.bufs.meta)
      local found_size = false
      for _, line in ipairs(meta_lines) do
        if line:find("Size%s*:%s*1280x720") then
          found_size = true
        end
      end
      assert.is_true(found_size)
    end)

    it("resolver.resolve_post_dimensions resolves dimensions lazily and caches on post object", function()
      local posts = ui.scan_local_folder(dim_dir)
      local p = posts[2]
      assert.is_nil(p.width)
      assert.is_nil(p.height)

      local resolver = require("gelbooru.media.resolver")
      local w, h = resolver.resolve_post_dimensions(p)
      assert.are.equal(1280, w)
      assert.are.equal(720, h)
      assert.are.equal(1280, p.width)
      assert.are.equal(720, p.height)

      -- Subsequent invocation uses cached values without reading file
      local orig_read = resolver.read_image_dimensions
      local read_called = false
      resolver.read_image_dimensions = function(...)
        read_called = true
        return orig_read(...)
      end

      local cw, ch = resolver.resolve_post_dimensions(p)
      resolver.read_image_dimensions = orig_read
      assert.is_false(read_called)
      assert.are.equal(1280, cw)
      assert.are.equal(720, ch)
    end)
  end)

  describe("Local Artwork Background Prewarming", function()
    local prewarm_dir

    before_each(function()
      prewarm_dir = vim.fn.tempname()
      vim.fn.mkdir(prewarm_dir, "p")
      for i = 1, 10 do
        local p = string.format("%s/item_%02d.jpg", prewarm_dir, i)
        local f = io.open(p, "wb")
        if f then
          f:write(string.char(0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x00, 0x01, 0x00, 0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00) .. string.rep("Z", 2048) .. string.char(0xFF, 0xD9))
          f:close()
        end
      end
    end)

    after_each(function()
      vim.fn.delete(prewarm_dir, "rf")
    end)

    it("opening a local directory starts prewarming initial posts immediately", function()
      ui.open_local(prewarm_dir)

      assert.are.equal(10, #state.State.posts)
      assert.are.equal(1, state.State.cur)

      -- Verify that initial posts have been prewarmed/verified ready
      vim.wait(1000, function() return prewarmer.is_prewarmed(state.State.posts[1].file_url) end, 20)

      for i = 1, 5 do
        assert.is_true(prewarmer.is_prewarmed(state.State.posts[i].file_url) == true)
      end
    end)

    it("navigating with j kicks off background prewarming for upcoming images in scroll direction", function()
      ui.open_local(prewarm_dir)
      vim.wait(1000, function() return prewarmer.is_prewarmed(state.State.posts[1].file_url) end, 20)

      -- Navigate down with j
      local keymaps = require("gelbooru.ui.keymaps")
      keymaps.on_cursor_change("j")

      assert.are.equal(2, state.State.cur)
      assert.are.equal(1, state.State.scroll_dir)

      -- Lookahead should now prewarm up to post 7
      vim.wait(1000, function()
        return prewarmer.is_prewarmed(state.State.posts[7].file_url)
      end, 20)

      assert.is_true(prewarmer.is_prewarmed(state.State.posts[7].file_url) == true)
    end)

    it("extracts and caches video thumbnails ahead of time for local video files", function()
      local vid_path = prewarm_dir .. "/clip_01.mp4"
      local f = io.open(vid_path, "wb")
      if f then
        f:write(string.rep("V", 4096))
        f:close()
      end

      local resolver_mod = require("gelbooru.media.resolver")
      local orig_extract = resolver_mod.extract_video_thumbnail
      local thumb_path = config.options.cache_dir .. "/vthumb_clip_01.jpg"
      local f_thumb = io.open(thumb_path, "wb")
      if f_thumb then
        f_thumb:write(string.rep("T", 2048))
        f_thumb:close()
      end

      local extract_called = false
      resolver_mod.extract_video_thumbnail = function(path, p, cb)
        extract_called = true
        cb(thumb_path)
      end

      ui.open_local(prewarm_dir)
      vim.wait(1000, function() return extract_called end, 20)

      assert.is_true(extract_called)
      resolver_mod.extract_video_thumbnail = orig_extract
    end)

    it("teardown aborts background prewarming and cleans queues", function()
      ui.open_local(prewarm_dir)
      assert.is_truthy(state.UI.wins.frame)

      ui.teardown()

      assert.are.equal(0, #prewarmer.queue)
      assert.are.equal(0, vim.tbl_count(prewarmer.active_conversions))
    end)
  end)
end)
