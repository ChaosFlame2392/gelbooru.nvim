-- tests/integration/minor_features_spec.lua
-- Exhaustive adversarial test suite for Section 2.8 Minor Features:
-- 1. Artist Quick-Search Hotkey ('u')
-- 2. Dynamic Explorer Menu Width ('<' / '>') and Zen Mode Canvas Expansion ('\')
-- 3. Media Viewer Dispatch ('O') and Web Post Lookup ('o')

local harness = require("tests.integration.helpers.harness")
local ui = require("gelbooru.ui")
local api = require("gelbooru.net.api")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local config = require("gelbooru.core.config")
local image = require("gelbooru.ui.image")

local function get_keymap_cb(buf, mode, key)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local maps = vim.api.nvim_buf_get_keymap(buf, mode or "n")
  for _, m in ipairs(maps) do
    if m.lhs == key or (key == "<" and m.lhs == "<lt>") or (key == "<lt>" and m.lhs == "<") then
      return m.callback or function()
        if m.rhs then
          vim.cmd("normal! " .. m.rhs)
        end
      end
    end
  end
  return nil
end

local function trigger_key(buf, key)
  local cb = get_keymap_cb(buf, "n", key)
  if cb then
    cb()
    return true
  end
  -- Fallback to normal mode command if window valid and active
  local cur_buf = vim.api.nvim_get_current_buf()
  if cur_buf == buf then
    pcall(vim.cmd, "normal " .. key)
    return true
  end
  return false
end

describe("Section 2.8: Minor Features Integration & Adversarial Suite", function()
  local tmp_save_dir
  local orig_save_dir

  before_each(function()
    harness.setup_all()
    harness.reset_environment()
    orig_save_dir = config.options.save_dir
    tmp_save_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_save_dir, "p")
    config.options.save_dir = tmp_save_dir
  end)

  after_each(function()
    harness.reset_environment()
    harness.teardown_all()
    if tmp_save_dir and vim.fn.isdirectory(tmp_save_dir) == 1 then
      vim.fn.delete(tmp_save_dir, "rf")
    end
    config.options.save_dir = orig_save_dir
  end)

  -----------------------------------------------------------------------------
  -- 1. Artist Quick-Search Hotkey ('u')
  -----------------------------------------------------------------------------
  describe("1. Artist Quick-Search Hotkey ('u')", function()
    it("populates UI.bufs.input and executes search when post has explicit p.artist", function()
      ui.open()

      local search_query = nil
      local orig_execute_search = api.execute_search
      api.execute_search = function(q)
        search_query = q
      end

      state.State.posts = {
        { id = 101, artist = "miku_artist", tags = "cat_ears solo", score = 10, file_url = "https://example.com/101.jpg" },
      }
      state.State.cur = 1
      ui.render_list()

      local win_list = state.UI.wins.list
      vim.api.nvim_set_current_win(win_list)

      local u_cb = get_keymap_cb(state.UI.bufs.list, "n", "u")
      assert.is_not_nil(u_cb, "'u' keymap must be registered on list buffer")
      u_cb()

      assert.are.equal("miku_artist", search_query)
      local input_lines = harness.get_buf_lines(state.UI.bufs.input)
      assert.are.equal("miku_artist", input_lines[1])

      api.execute_search = orig_execute_search
    end)

    it("identifies artist tag from tags string via tag type 1 (t.t == 1) in State.tags_by_name", function()
      ui.open()

      local search_query = nil
      local orig_execute_search = api.execute_search
      api.execute_search = function(q)
        search_query = q
      end

      state.State.tags_by_name = {
        ["cat_ears"] = { n = "cat_ears", t = 0 },
        ["solo"] = { n = "solo", t = 0 },
        ["original_artist"] = { n = "original_artist", t = 1 },
      }

      state.State.posts = {
        { id = 102, tags = "cat_ears solo original_artist", score = 25, file_url = "https://example.com/102.jpg" },
      }
      state.State.cur = 1
      ui.render_list()

      local u_cb = get_keymap_cb(state.UI.bufs.list, "n", "u")
      assert.is_not_nil(u_cb, "'u' keymap must be registered on list buffer")
      u_cb()

      assert.are.equal("original_artist", search_query)
      local input_lines = harness.get_buf_lines(state.UI.bufs.input)
      assert.are.equal("original_artist", input_lines[1])

      api.execute_search = orig_execute_search
    end)

    it("shows status 'No artist tag found on active post' and does NOT invoke search when no artist tag exists", function()
      ui.open()

      local search_invoked = false
      local orig_execute_search = api.execute_search
      api.execute_search = function(q)
        search_invoked = true
      end

      state.State.tags_by_name = {
        ["cat_ears"] = { n = "cat_ears", t = 0 },
        ["solo"] = { n = "solo", t = 0 },
        ["hatsune_miku"] = { n = "hatsune_miku", t = 4 }, -- character tag, not artist
      }

      state.State.posts = {
        { id = 103, tags = "cat_ears solo hatsune_miku", score = 5, file_url = "https://example.com/103.jpg" },
      }
      state.State.cur = 1
      ui.render_list()

      local u_cb = get_keymap_cb(state.UI.bufs.list, "n", "u")
      assert.is_not_nil(u_cb, "'u' keymap must be registered on list buffer")
      u_cb()

      assert.is_false(search_invoked, "execute_search must not be called when post has no artist tag")
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("No artist tag found on active post"), "Expected status message about no artist tag")

      api.execute_search = orig_execute_search
    end)

    it("handles post with nil or empty tags gracefully without crash", function()
      ui.open()

      local search_invoked = false
      local orig_execute_search = api.execute_search
      api.execute_search = function(q)
        search_invoked = true
      end

      state.State.posts = {
        { id = 104, tags = nil, score = 0, file_url = "https://example.com/104.jpg" },
      }
      state.State.cur = 1

      local u_cb = get_keymap_cb(state.UI.bufs.list, "n", "u")
      assert.is_not_nil(u_cb, "'u' keymap must be registered on list buffer")
      assert.has_no.errors(function()
        u_cb()
      end)

      assert.is_false(search_invoked)
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("No artist tag found on active post"))

      api.execute_search = orig_execute_search
    end)

    it("handles empty post list without crash and informs user", function()
      ui.open()

      state.State.posts = {}
      state.State.cur = 1

      local u_cb = get_keymap_cb(state.UI.bufs.list, "n", "u")
      assert.is_not_nil(u_cb, "'u' keymap must be registered on list buffer")
      assert.has_no.errors(function()
        u_cb()
      end)

      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("No artist tag") or status_lines[1]:find("No post"))
    end)

    it("works from metadata buffer ('UI.bufs.meta')", function()
      ui.open()

      local search_query = nil
      local orig_execute_search = api.execute_search
      api.execute_search = function(q)
        search_query = q
      end

      state.State.posts = {
        { id = 105, artist = "meta_artist", tags = "solo", score = 15, file_url = "https://example.com/105.jpg" },
      }
      state.State.cur = 1
      state.State.show_meta = true
      ui.render_preview(false)

      local meta_u_cb = get_keymap_cb(state.UI.bufs.meta, "n", "u")
      assert.is_not_nil(meta_u_cb, "'u' keymap must be registered on meta buffer")

      meta_u_cb()
      assert.are.equal("meta_artist", search_query)
      local input_lines = harness.get_buf_lines(state.UI.bufs.input)
      assert.are.equal("meta_artist", input_lines[1])

      api.execute_search = orig_execute_search
    end)

    it("decodes HTML entities in artist tag string correctly", function()
      ui.open()

      local search_query = nil
      local orig_execute_search = api.execute_search
      api.execute_search = function(q)
        search_query = q
      end

      state.State.tags_by_name = {
        ["artist's_work"] = { n = "artist's_work", t = 1 },
      }

      state.State.posts = {
        { id = 106, tags = "solo artist&#039;s_work", score = 20, file_url = "https://example.com/106.jpg" },
      }
      state.State.cur = 1
      ui.render_list()

      local u_cb = get_keymap_cb(state.UI.bufs.list, "n", "u")
      assert.is_not_nil(u_cb)
      u_cb()

      assert.are.equal("artist's_work", search_query)

      api.execute_search = orig_execute_search
    end)
  end)

  -----------------------------------------------------------------------------
  -- 2. Dynamic Explorer Menu Width & Canvas Expansion (Zen Mode)
  -----------------------------------------------------------------------------
  describe("2. Dynamic Explorer Menu Width & Zen Mode Canvas Expansion", function()
    it("'<' keymap decrements State.list_width_ratio by 0.025 and nudges image placement", function()
      ui.open()
      state.State.list_width_ratio = 0.25

      local nudged = false
      local orig_nudge = image.nudge_current_placement
      image.nudge_current_placement = function()
        nudged = true
      end

      local lt_cb = get_keymap_cb(state.UI.bufs.list, "n", "<")
      assert.is_not_nil(lt_cb, "'<' keymap must be registered on list buffer")

      lt_cb()

      assert.is_true(math.abs(state.State.list_width_ratio - 0.225) < 1e-6, "list_width_ratio should decrement by 0.025")
      assert.is_true(nudged, "image.nudge_current_placement should be called on width change")

      image.nudge_current_placement = orig_nudge
    end)

    it("'<' clamps State.list_width_ratio at 0.10 minimum", function()
      ui.open()
      state.State.list_width_ratio = 0.11

      local lt_cb = get_keymap_cb(state.UI.bufs.list, "n", "<")
      assert.is_not_nil(lt_cb, "'<' keymap must be registered on list buffer")

      lt_cb() -- should reach 0.10 (clamped)
      assert.is_true(math.abs(state.State.list_width_ratio - 0.10) < 1e-6)

      lt_cb() -- should stay clamped at 0.10
      assert.is_true(math.abs(state.State.list_width_ratio - 0.10) < 1e-6)
    end)

    it("'>' keymap increments State.list_width_ratio by 0.025 and nudges image placement", function()
      ui.open()
      state.State.list_width_ratio = 0.25

      local nudged = false
      local orig_nudge = image.nudge_current_placement
      image.nudge_current_placement = function()
        nudged = true
      end

      local gt_cb = get_keymap_cb(state.UI.bufs.list, "n", ">")
      assert.is_not_nil(gt_cb, "'>' keymap must be registered on list buffer")

      gt_cb()

      assert.is_true(math.abs(state.State.list_width_ratio - 0.275) < 1e-6, "list_width_ratio should increment by 0.025")
      assert.is_true(nudged, "image.nudge_current_placement should be called on width change")

      image.nudge_current_placement = orig_nudge
    end)

    it("'>' clamps State.list_width_ratio at 0.40 maximum", function()
      ui.open()
      state.State.list_width_ratio = 0.39

      local gt_cb = get_keymap_cb(state.UI.bufs.list, "n", ">")
      assert.is_not_nil(gt_cb, "'>' keymap must be registered on list buffer")

      gt_cb() -- should reach 0.40 (clamped)
      assert.is_true(math.abs(state.State.list_width_ratio - 0.40) < 1e-6)

      gt_cb() -- should stay clamped at 0.40
      assert.is_true(math.abs(state.State.list_width_ratio - 0.40) < 1e-6)
    end)

    it("calc_layout dynamically factors in State.list_width_ratio", function()
      ui.open()

      state.State.list_width_ratio = 0.20
      local l1 = ui.calc_layout(true)

      state.State.list_width_ratio = 0.35
      local l2 = ui.calc_layout(true)

      assert.is_true(l2.list.width > l1.list.width, "list width should increase with higher list_width_ratio")
      assert.is_true(l2.img.width < l1.img.width, "preview width should decrease with higher list_width_ratio")
    end)

    it("Zen Mode toggle ('\\') hides list and vdiv, expands preview to full width, and restores on second toggle", function()
      ui.open()

      local nudged_count = 0
      local orig_nudge = image.nudge_current_placement
      image.nudge_current_placement = function()
        nudged_count = nudged_count + 1
      end

      local zen_cb = get_keymap_cb(state.UI.bufs.list, "n", "\\")
      assert.is_not_nil(zen_cb, "'\\' keymap must be registered on list buffer")

      -- First press: enter zen mode
      zen_cb()
      assert.is_true(state.State.zen_mode, "State.zen_mode should be true after first press")
      assert.is_true(nudged_count >= 1, "image placement should be nudged on entering zen mode")

      -- Verify layout or window configs in zen mode
      local l_zen = ui.calc_layout()
      local frame_w = l_zen.frame.width
      local frame_col = l_zen.frame.col

      -- Preview window should span full frame interior (width = frame_w - 2, col = frame_col + 1)
      assert.are.equal(frame_w - 2, l_zen.img.width)
      assert.are.equal(frame_col + 1, l_zen.img.col)

      -- List and vdiv windows should be hidden
      local list_cfg = vim.api.nvim_win_get_config(state.UI.wins.list)
      assert.is_true(list_cfg.hide == true, "list window should have hide = true in zen mode")
      local vdiv_cfg = vim.api.nvim_win_get_config(state.UI.wins.vdiv)
      assert.is_true(vdiv_cfg.hide == true, "vdiv window should have hide = true in zen mode")

      -- Second press: exit zen mode
      zen_cb()
      assert.is_false(state.State.zen_mode, "State.zen_mode should be false after second press")
      assert.is_true(nudged_count >= 2, "image placement should be nudged on exiting zen mode")

      local l_normal = ui.calc_layout()
      assert.is_true(l_normal.img.width < frame_w - 2, "preview width should return to split size")

      local list_cfg_restored = vim.api.nvim_win_get_config(state.UI.wins.list)
      assert.is_false(list_cfg_restored.hide == true, "list window should no longer be hidden")
      local vdiv_cfg_restored = vim.api.nvim_win_get_config(state.UI.wins.vdiv)
      assert.is_false(vdiv_cfg_restored.hide == true, "vdiv window should no longer be hidden")

      image.nudge_current_placement = orig_nudge
    end)

    it("stress test: toggles Zen Mode repeatedly 15 times without error or leaking window handles", function()
      ui.open()

      local zen_cb = get_keymap_cb(state.UI.bufs.list, "n", "\\")
      assert.is_not_nil(zen_cb, "'\\' keymap must be registered on list buffer")

      local initial_wins = vim.api.nvim_list_wins()

      for i = 1, 15 do
        assert.has_no.errors(function()
          zen_cb()
        end)
      end

      -- If toggled 15 times starting from false, final state should be true
      assert.is_true(state.State.zen_mode)

      -- Toggle 1 more time to return to false
      zen_cb()
      assert.is_false(state.State.zen_mode)

      -- Verify all core windows remain valid
      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.frame))
      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.list))
      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.img))
      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.status))

      -- Window count should not grow uncontrollably
      local final_wins = vim.api.nvim_list_wins()
      assert.is_true(#final_wins <= #initial_wins + 2, "No window handles should leak across zen toggles")
    end)
  end)

  -----------------------------------------------------------------------------
  -- 3. Media Viewer Dispatch & Keymap Consistency ('o' and 'O')
  -----------------------------------------------------------------------------
  describe("3. Media Viewer Dispatch & Keymap Consistency", function()
    it("'o' on post with ID opens web URL via util.open_url", function()
      ui.open()

      local opened_url = nil
      local orig_open_url = util.open_url
      util.open_url = function(url)
        opened_url = url
        return true
      end

      state.State.posts = {
        { id = 554433, file_url = "https://example.com/554433.jpg", score = 10 },
      }
      state.State.cur = 1
      ui.render_list()

      local o_cb = get_keymap_cb(state.UI.bufs.list, "n", "o")
      assert.is_not_nil(o_cb, "'o' keymap must be registered on list buffer")

      o_cb()
      assert.are.equal("https://gelbooru.com/index.php?page=post&s=view&id=554433", opened_url)

      util.open_url = orig_open_url
    end)

    it("'o' on post without ID rejects lookup, shows status message, and opens no URL", function()
      ui.open()

      local opened_url = nil
      local orig_open_url = util.open_url
      util.open_url = function(url)
        opened_url = url
        return true
      end

      -- Local post or post with nil ID
      state.State.posts = {
        { is_local = true, id = nil, file_url = "/tmp/test_artwork.jpg", score = 0 },
      }
      state.State.cur = 1
      ui.render_list()

      local o_cb = get_keymap_cb(state.UI.bufs.list, "n", "o")
      assert.is_not_nil(o_cb, "'o' keymap must be registered on list buffer")

      o_cb()

      assert.is_nil(opened_url, "util.open_url must not be invoked on post without numeric ID")
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("No post ID available for browser lookup"))

      util.open_url = orig_open_url
    end)

    it("'o' works identically from meta buffer ('UI.bufs.meta')", function()
      ui.open()

      local opened_url = nil
      local orig_open_url = util.open_url
      util.open_url = function(url)
        opened_url = url
        return true
      end

      state.State.posts = {
        { id = 887766, file_url = "https://example.com/887766.jpg", score = 12 },
      }
      state.State.cur = 1
      state.State.show_meta = true
      ui.render_preview(false)

      local meta_o_cb = get_keymap_cb(state.UI.bufs.meta, "n", "o")
      assert.is_not_nil(meta_o_cb, "'o' keymap must be registered on meta buffer")

      meta_o_cb()
      assert.are.equal("https://gelbooru.com/index.php?page=post&s=view&id=887766", opened_url)

      util.open_url = orig_open_url
    end)

    it("'O' on local post calls util.open_media(p.file_url) directly", function()
      ui.open()

      local opened_media = nil
      local orig_open_media = util.open_media
      util.open_media = function(target)
        opened_media = target
        return true
      end

      local local_path = tmp_save_dir .. "/artwork_local.png"
      local f = io.open(local_path, "wb")
      if f then f:write("test"); f:close() end

      state.State.posts = {
        { is_local = true, id = 991, file_url = local_path, score = 0 },
      }
      state.State.cur = 1
      ui.render_list()

      local O_cb = get_keymap_cb(state.UI.bufs.list, "n", "O")
      assert.is_not_nil(O_cb, "'O' keymap must be registered on list buffer")

      O_cb()

      assert.are.equal(local_path, opened_media)

      util.open_media = orig_open_media
    end)

    it("'O' on downloaded remote post in save_dir calls util.open_media with existing file", function()
      ui.open()

      local opened_media = nil
      local orig_open_media = util.open_media
      util.open_media = function(target)
        opened_media = target
        return true
      end

      local saved_file = tmp_save_dir .. "/777.jpg"
      local f = io.open(saved_file, "wb")
      if f then f:write("already saved content"); f:close() end

      state.State.posts = {
        { is_local = false, id = 777, file_url = "https://example.com/777.jpg", score = 20 },
      }
      state.State.cur = 1
      ui.render_list()

      local O_cb = get_keymap_cb(state.UI.bufs.list, "n", "O")
      assert.is_not_nil(O_cb, "'O' keymap must be registered on list buffer")

      O_cb()

      assert.are.equal(saved_file, opened_media)

      util.open_media = orig_open_media
    end)

    it("'O' on un-downloaded remote post automatically calls api.save_current and opens saved file on completion", function()
      ui.open()

      local opened_media = nil
      local orig_open_media = util.open_media
      util.open_media = function(target)
        opened_media = target
        return true
      end

      local save_current_called = false
      local expected_dest = tmp_save_dir .. "/888.png"

      local orig_save_current = api.save_current
      api.save_current = function(cb)
        save_current_called = true
        local f = io.open(expected_dest, "wb")
        if f then f:write("downloaded"); f:close() end
        if cb then
          cb(true, expected_dest)
        end
      end

      state.State.posts = {
        { is_local = false, id = 888, file_url = "https://example.com/888.png", score = 30 },
      }
      state.State.cur = 1
      ui.render_list()

      local O_cb = get_keymap_cb(state.UI.bufs.list, "n", "O")
      assert.is_not_nil(O_cb, "'O' keymap must be registered on list buffer")

      O_cb()

      assert.is_true(save_current_called, "api.save_current should be invoked when remote media not yet downloaded")
      assert.are.equal(expected_dest, opened_media, "util.open_media should be called with downloaded file path")

      api.save_current = orig_save_current
      util.open_media = orig_open_media
    end)

    it("'O' displays error status and does not call util.open_media when auto-download fails", function()
      ui.open()

      local opened_media = nil
      local orig_open_media = util.open_media
      util.open_media = function(target)
        opened_media = target
        return true
      end

      local orig_save_current = api.save_current
      api.save_current = function(cb)
        ui.set_status("Failed to download media to open", 3000)
        if cb then
          cb(false, nil)
        end
      end

      state.State.posts = {
        { is_local = false, id = 999, file_url = "https://example.com/999.png", score = 1 },
      }
      state.State.cur = 1
      ui.render_list()

      local O_cb = get_keymap_cb(state.UI.bufs.list, "n", "O")
      assert.is_not_nil(O_cb)

      O_cb()

      assert.is_nil(opened_media, "util.open_media must not be called when download fails")
      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_truthy(status_lines[1]:find("Failed to download media to open"))

      api.save_current = orig_save_current
      util.open_media = orig_open_media
    end)

    it("'O' works from metadata buffer ('UI.bufs.meta')", function()
      ui.open()

      local opened_media = nil
      local orig_open_media = util.open_media
      util.open_media = function(target)
        opened_media = target
        return true
      end

      local local_path = tmp_save_dir .. "/meta_media.jpg"
      local f = io.open(local_path, "wb")
      if f then f:write("media"); f:close() end

      state.State.posts = {
        { is_local = true, id = 111, file_url = local_path, score = 5 },
      }
      state.State.cur = 1
      state.State.show_meta = true
      ui.render_preview(false)

      local meta_O_cb = get_keymap_cb(state.UI.bufs.meta, "n", "O")
      assert.is_not_nil(meta_O_cb, "'O' keymap must be registered on meta buffer")

      meta_O_cb()
      assert.are.equal(local_path, opened_media)

      util.open_media = orig_open_media
    end)

    it("set_status() default help text includes 'u: artist', '< / >: width', '\\: zen', 'o: web', 'O: open'", function()
      ui.open()

      ui.set_status() -- Reset to default help text

      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      assert.is_true(#status_lines >= 1)
      local help_line = status_lines[1]

      assert.is_truthy(help_line:find("u: artist"), "Help text must document 'u: artist'")
      assert.is_truthy(help_line:find("< / >: width") or help_line:find("</>: width"), "Help text must document '< / >: width'")
      assert.is_truthy(help_line:find("\\: zen"), "Help text must document '\\: zen'")
      assert.is_truthy(help_line:find("o: web"), "Help text must document 'o: web'")
      assert.is_truthy(help_line:find("O: open"), "Help text must document 'O: open'")
    end)
  end)
end)
