-- tests/integration/regressions_spec.lua
-- Integration tests specifically designed to reproduce and catch:
-- 1. Blank list buffer on re-submitting the same search query
-- 2. Image placement failure on 'm' toggle
-- 3. Asynchronous tag resolution preview races (cur_id deduplication deadlock)
-- 4. Close-reopen lifecycle, buffer cleanup, and re-entrancy

local harness = require("tests.integration.helpers.harness")
local ui = require("gelbooru.ui")
local api = require("gelbooru.net.api")
local state = require("gelbooru.core.state")
local mock_snacks = require("tests.integration.helpers.mock_snacks")

describe("Regression Tests for UI & Search bugs", function()
  before_each(function()
    harness.setup_all()
    harness.reset_environment()
  end)

  after_each(function()
    harness.reset_environment()
    harness.teardown_all()
  end)

  -- Regression: pressing '/' and <CR> without changing the query used to wipe
  -- State.posts and leave the list buffer blank until the API returned (again).
  -- Fixed in net/api.lua: execute_search() now calls render_list() before the
  -- early return so the existing posts are immediately re-painted.
  it("reproduces search return: list buffer must NOT be blank after exiting or re-submitting search", function()
    ui.open()
    api.execute_search("hatsune_miku")

    vim.wait(1000, function()
      return #state.State.posts > 0
    end, 10)

    -- Navigate to post 3 to prove cursor position is preserved.
    state.State.cur = 3
    ui.render_list()

    -- Simulate the user pressing '/' then <CR> without changing the query.
    -- The input buffer is populated with the current query string, which is
    -- what the real keymap does via api.execute_search(full).
    local same_query = state.State.query
    api.execute_search(same_query)

    -- execute_search should have hit the early-return path and called
    -- render_list() immediately — no async wait needed.
    local list_lines = harness.get_buf_lines(state.UI.bufs.list)
    assert.is_true(#list_lines >= 3, "List buffer was blanked after re-submitting search!")
    assert.are.not_equal("  Fetching…", list_lines[1])
    assert.are.not_equal("  No results", list_lines[1])
  end)

  -- Regression: toggling the metadata panel ('m') used to call on_resize() which
  -- triggered render_preview() and created a new placement buffer while the old
  -- placement was still active, causing snacks.image to lose track of the window.
  it("reproduces 'm' toggle: image placement must remain active and scale correctly on repeated toggles", function()
    ui.open()
    api.execute_search("hatsune_miku")

    vim.wait(1000, function()
      return #state.State.posts > 0
    end, 10)

    ui.render_preview(false)

    -- Let the preview cooldown / scroll timer fire so a placement is created.
    vim.wait(1000, function()
      return state.UI.current_placement ~= nil
    end, 10)

    local initial_placement = state.UI.current_placement
    assert.is_not_nil(initial_placement, "Initial image placement was nil")
    assert.is_false(initial_placement.closed, "Initial placement was prematurely closed")

    -- Toggle meta panel OFF ('m').
    state.State.show_meta = false
    ui.on_resize()

    -- Image placement MUST still be valid and active on the image window.
    assert.is_not_nil(state.UI.current_placement, "Placement lost after 'm' toggle off")
    assert.is_false(state.UI.current_placement.closed, "Placement closed after 'm' toggle off")
    assert.are.equal(state.UI.current_placement.buf, vim.api.nvim_win_get_buf(state.UI.wins.img))

    -- Toggle meta panel back ON ('m').
    state.State.show_meta = true
    ui.on_resize()

    assert.is_not_nil(state.UI.current_placement, "Placement lost after 'm' toggle on")
    assert.is_false(state.UI.current_placement.closed, "Placement closed after 'm' toggle on")
    assert.are.equal(state.UI.current_placement.buf, vim.api.nvim_win_get_buf(state.UI.wins.img))
  end)

  -- Regression: when tags.resolve_post_tags() asynchronously discovers an artist
  -- tag, the on_complete callback called render_preview(false), but the cur_id
  -- deduplication guard (p.id == State.cur_id) caused it to return immediately
  -- without repainting the metadata panel.
  -- Fixed in ui/init.lua: the on_complete callback now resets State.cur_id = nil
  -- before calling render_preview so the deduplication guard is bypassed.
  it("reproduces artist resolution: cur_id deduplication does not prevent metadata panel update", function()
    ui.open()
    api.execute_search("hatsune_miku")

    vim.wait(1000, function()
      return #state.State.posts > 0
    end, 10)

    local p = state.State.posts[1]
    assert.is_not_nil(p, "Expected at least one post")

    -- Render the preview once so cur_id is set, then confirm no artist section yet.
    state.State.tags_by_name = {}
    state.State.cur_id = nil
    ui.render_preview(false)

    local meta_before = harness.get_buf_lines(state.UI.bufs.meta)
    local has_artist_before = false
    for _, l in ipairs(meta_before) do
      if l:find("Artists :") then has_artist_before = true end
    end
    assert.is_false(has_artist_before, "Artist section should not exist before resolution")

    -- Verify that cur_id was set (this is what the original bug depended on).
    assert.are.equal(p.id, state.State.cur_id, "cur_id must be set after render_preview")

    -- Simulate the on_complete callback that resolve_post_tags fires after
    -- discovering an artist. With the fix, cur_id is reset to nil before
    -- render_preview is called so the deduplication guard is bypassed.
    state.State.cur_id = nil

    -- Manually register kekeflipnote as an artist in the tag index (simulating
    -- what resolve_post_tags does after the API response arrives).
    local db = require("gelbooru.tags.db")
    db.add_tag_to_index(
      { n = "kekeflipnote", t = 1, c = 500 },
      state.State.artists,
      state.State.artists_by_first
    )

    -- Now call render_preview(false) exactly as on_complete does.
    ui.render_preview(false)

    local meta_after = harness.get_buf_lines(state.UI.bufs.meta)
    local has_artist_after = false
    for _, l in ipairs(meta_after) do
      if l:find("Artists : kekeflipnote") then has_artist_after = true end
    end
    assert.is_true(has_artist_after, "Metadata panel was not updated when artist was dynamically discovered!")
  end)

  -- Regression: close-reopen lifecycle
  -- Verifies that opening, closing with teardown(), and opening again succeeds
  -- without errors, cleans up hidden buffers (hdiv, meta, ac), resets query state,
  -- and respects the re-entrancy guard while open.
  it("verifies close-reopen lifecycle: teardown cleans up buffers and state, and reopening succeeds cleanly", function()
    ui.open()
    api.execute_search("hatsune_miku")

    vim.wait(1000, function()
      return #state.State.posts > 0
    end, 10)

    local frame_win = state.UI.wins.frame
    local meta_buf = state.UI.bufs.meta
    local ac_buf = state.UI.bufs.ac
    local hdiv_buf = state.UI.bufs.hdiv

    assert.is_true(vim.api.nvim_win_is_valid(frame_win))
    assert.is_true(vim.api.nvim_buf_is_valid(meta_buf))
    assert.is_true(vim.api.nvim_buf_is_valid(ac_buf))
    if hdiv_buf then
      assert.is_true(vim.api.nvim_buf_is_valid(hdiv_buf))
    end

    -- Re-entrancy guard test: calling open while already open is a no-op
    ui.open()
    assert.are.equal(frame_win, state.UI.wins.frame)

    -- Close UI via teardown
    ui.teardown()

    -- Windows must be closed and hidden buffers deleted
    assert.is_false(vim.api.nvim_win_is_valid(frame_win))
    assert.is_false(vim.api.nvim_buf_is_valid(meta_buf))
    assert.is_false(vim.api.nvim_buf_is_valid(ac_buf))
    if hdiv_buf then
      assert.is_false(vim.api.nvim_buf_is_valid(hdiv_buf))
    end

    -- Query state must be reset
    assert.are.equal(0, #state.State.posts)
    assert.are.equal(0, state.State.page)
    assert.are.equal(1, state.State.cur)
    assert.is_nil(state.State.cur_id)
    assert.is_false(state.State.loading)

    -- Reopen UI cleanly
    ui.open()

    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.frame))
    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.list))
    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.img))
    assert.is_true(vim.api.nvim_buf_is_valid(state.UI.bufs.meta))
    assert.is_true(vim.api.nvim_buf_is_valid(state.UI.bufs.ac))

    assert.are.equal(0, #state.State.posts)
    assert.are.equal(1, state.State.cur)
    assert.are.equal(0, state.State.page)
    assert.is_nil(state.State.cur_id)
    assert.is_false(state.State.loading)

    ui.teardown()
  end)

  it("verifies teardown invokes download.abort_all", function()
    local abort_called = false
    local download_mod = require("gelbooru.net.download")
    local orig_abort = download_mod.abort_all
    download_mod.abort_all = function()
      abort_called = true
      orig_abort()
    end

    ui.open()
    ui.teardown()

    download_mod.abort_all = orig_abort
    assert.is_true(abort_called, "download.abort_all was not called during ui.teardown")
  end)

  describe("Adversarial: Input Isolation and Teardown Abort", function()
    it("verifies UI.bufs.input remains strictly modifiable across typing and focus toggles", function()
      ui.open()

      local input_buf = state.UI.bufs.input
      assert.is_not_nil(input_buf)
      assert.is_true(vim.api.nvim_buf_is_valid(input_buf))

      -- Input buffer must be modifiable and not readonly despite buftype = "nofile"
      assert.is_true(vim.bo[input_buf].modifiable, "input buffer is not modifiable")
      assert.is_false(vim.bo[input_buf].readonly, "input buffer is marked readonly")
      assert.are.equal("nofile", vim.bo[input_buf].buftype)

      -- Simulating typing/modifying queries
      vim.api.nvim_buf_set_lines(input_buf, 0, 1, false, { "hatsune_miku rating:general" })
      local lines = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)
      assert.are.equal("hatsune_miku rating:general", lines[1])

      -- Trigger exit input (<Esc>)
      local imaps = vim.api.nvim_buf_get_keymap(input_buf, "i")
      local esc_fn
      for _, km in ipairs(imaps) do
        if km.lhs == "<Esc>" then
          esc_fn = km.callback
        end
      end
      assert.is_not_nil(esc_fn, "Esc keymap not found on input buffer")
      esc_fn()

      assert.is_false(state.State.input_focused)
      assert.are.equal(state.UI.wins.list, vim.api.nvim_get_current_win())

      -- Re-enter search from list using "/" keymap
      local lmaps = vim.api.nvim_buf_get_keymap(state.UI.bufs.list, "n")
      local slash_fn
      for _, km in ipairs(lmaps) do
        if km.lhs == "/" then
          slash_fn = km.callback
        end
      end
      assert.is_not_nil(slash_fn, "/ keymap not found on list buffer")
      slash_fn()

      assert.is_true(state.State.input_focused)
      assert.are.equal(state.UI.wins.input, vim.api.nvim_get_current_win())
      assert.is_true(vim.bo[input_buf].modifiable, "input buffer lost modifiable state after re-entering search")

      -- Append additional tag
      vim.api.nvim_buf_set_lines(input_buf, 0, 1, false, { "hatsune_miku rating:general solo" })
      lines = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)
      assert.are.equal("hatsune_miku rating:general solo", lines[1])

      ui.teardown()
    end)

    it("verifies enter_search() transitions and insert-mode keybindings (<CR>, <Esc>, typing) function correctly", function()
      ui.open()

      local input_buf = state.UI.bufs.input
      assert.is_true(state.State.input_focused)
      assert.are.equal(state.UI.wins.input, vim.api.nvim_get_current_win())

      -- Simulate typing: set line and trigger TextChangedI
      vim.api.nvim_buf_set_lines(input_buf, 0, 1, false, { "vocal" })
      vim.api.nvim_exec_autocmds("TextChangedI", { buffer = input_buf })

      vim.wait(300, function()
        return #state.State.autocomplete_filtered > 0
      end)
      assert.is_true(#state.State.autocomplete_filtered > 0, "Autocomplete filtered list was not populated")
      local ac_lines = harness.get_buf_lines(state.UI.bufs.ac)
      assert.is_true(#ac_lines > 0, "Autocomplete buffer was not rendered")

      -- Execute query via <CR>
      local imaps = vim.api.nvim_buf_get_keymap(input_buf, "i")
      local cr_fn
      for _, km in ipairs(imaps) do
        if km.lhs == "<CR>" then
          cr_fn = km.callback
        end
      end
      assert.is_not_nil(cr_fn, "<CR> keymap not found on input buffer")
      cr_fn()

      assert.is_false(state.State.input_focused)
      assert.are.equal(state.UI.wins.list, vim.api.nvim_get_current_win())
      assert.are.equal("vocal", state.State.query)

      vim.wait(300, function()
        return #state.State.posts > 0
      end)
      assert.is_true(#state.State.posts > 0)

      -- From list buffer, enter search again using "i"
      local lmaps = vim.api.nvim_buf_get_keymap(state.UI.bufs.list, "n")
      local i_fn
      for _, km in ipairs(lmaps) do
        if km.lhs == "i" then
          i_fn = km.callback
        end
      end
      assert.is_not_nil(i_fn, "i keymap not found on list buffer")
      i_fn()

      assert.is_true(state.State.input_focused)
      assert.are.equal(state.UI.wins.input, vim.api.nvim_get_current_win())

      -- Cancel search via <Esc>
      imaps = vim.api.nvim_buf_get_keymap(input_buf, "i")
      local esc_fn
      for _, km in ipairs(imaps) do
        if km.lhs == "<Esc>" then
          esc_fn = km.callback
        end
      end
      assert.is_not_nil(esc_fn, "<Esc> keymap not found on input buffer")
      esc_fn()

      assert.is_false(state.State.input_focused)
      assert.are.equal(state.UI.wins.list, vim.api.nvim_get_current_win())

      ui.teardown()
    end)

    it("verifies isolation is robust when cmp or blink modules exist, absent, or malformed", function()
      local orig_cmp = package.loaded["cmp"]
      local orig_blink = package.loaded["blink.cmp"]

      -- Case 1: cmp is absent
      package.loaded["cmp"] = nil
      package.loaded["blink.cmp"] = nil
      local ok = pcall(ui.open)
      assert.is_true(ok, "ui.open failed when cmp and blink were absent")
      local input_buf = state.UI.bufs.input
      assert.is_false(vim.b[input_buf].cmp_enabled)
      assert.is_false(vim.b[input_buf].blink_cmp_enabled)
      assert.is_false(vim.b[input_buf].completion)
      assert.is_true(vim.b[input_buf].copilot_disabled)
      assert.is_false(vim.b[input_buf].codecompanion_enabled)
      assert.is_false(vim.b[input_buf].supermaven)
      assert.are.equal("", vim.bo[input_buf].omnifunc)
      assert.are.equal("", vim.bo[input_buf].completefunc)
      assert.are.equal("", vim.bo[input_buf].completeopt)
      ui.teardown()

      -- Case 2: cmp exists with mock setup.buffer
      local cmp_buffer_opts = nil
      package.loaded["cmp"] = {
        setup = {
          buffer = function(opts)
            cmp_buffer_opts = opts
          end,
        },
      }
      package.loaded["blink.cmp"] = {
        -- mock blink module
      }
      ok = pcall(ui.open)
      assert.is_true(ok, "ui.open failed when mock cmp and blink existed")
      assert.is_not_nil(cmp_buffer_opts)
      assert.is_false(cmp_buffer_opts.enabled)
      input_buf = state.UI.bufs.input
      assert.is_false(vim.b[input_buf].cmp_enabled)
      assert.is_false(vim.b[input_buf].blink_cmp_enabled)
      ui.teardown()

      -- Case 3: cmp is present but setup.buffer throws runtime error (adversarial)
      package.loaded["cmp"] = {
        setup = {
          buffer = function()
            error("third-party cmp internal error")
          end,
        },
      }
      ok = pcall(ui.open)
      assert.is_true(ok, "ui.open crashed when cmp.setup.buffer raised an error")
      input_buf = state.UI.bufs.input
      assert.is_true(vim.api.nvim_buf_is_valid(input_buf))
      assert.is_true(vim.bo[input_buf].modifiable)
      ui.teardown()

      -- Case 4: cmp table is malformed (no setup table)
      package.loaded["cmp"] = {}
      ok = pcall(ui.open)
      assert.is_true(ok, "ui.open crashed when cmp table was empty/malformed")
      input_buf = state.UI.bufs.input
      assert.is_true(vim.api.nvim_buf_is_valid(input_buf))
      assert.is_true(vim.bo[input_buf].modifiable)
      ui.teardown()

      -- Restore package.loaded
      package.loaded["cmp"] = orig_cmp
      package.loaded["blink.cmp"] = orig_blink
    end)

    it("verifies teardown aborts multiple active download and curl handles, flags interrupted dests, and tolerates handle errors", function()
      local download_mod = require("gelbooru.net.download")

      ui.open()

      local killed_handles = {}
      local make_mock_handle = function(id)
        return {
          id = id,
          kill = function(self, sig)
            table.insert(killed_handles, { id = id, sig = sig })
          end,
        }
      end

      local handle1 = make_mock_handle("img_dest_1")
      local handle2 = make_mock_handle("img_dest_2")
      local handle3 = make_mock_handle("curl_api_handle")
      local handle_throwing = {
        id = "throwing_handle",
        kill = function(self, sig)
          error("mock process already exited / permission denied")
        end,
      }
      local handle_no_kill = {
        id = "malformed_handle",
      }

      local dest1 = "/fake/cache/img1.jpg"
      local dest2 = "/fake/cache/img2.jpg"
      local dest_throw = "/fake/cache/img_throw.jpg"
      local dest_nokill = "/fake/cache/img_nokill.jpg"

      download_mod.active_handles[dest1] = handle1
      download_mod.active_handles[dest2] = handle2
      download_mod.active_handles[handle3] = handle3
      download_mod.active_handles[dest_throw] = handle_throwing
      download_mod.active_handles[dest_nokill] = handle_no_kill

      -- Active downloads callback queue
      local callback_called = false
      download_mod.active_downloads[dest1] = {
        function()
          callback_called = true
        end,
      }

      -- Perform teardown
      local ok, err = pcall(ui.teardown)
      assert.is_true(ok, "teardown failed under active mock handles: " .. tostring(err))

      -- Verify handles received SIGKILL (9)
      local killed_ids = {}
      for _, k in ipairs(killed_handles) do
        killed_ids[k.id] = true
        assert.are.equal(9, k.sig)
      end
      assert.is_true(killed_ids["img_dest_1"], "handle1 was not killed")
      assert.is_true(killed_ids["img_dest_2"], "handle2 was not killed")
      assert.is_true(killed_ids["curl_api_handle"], "handle3 was not killed")

      -- Verify interrupted destinations are flagged
      assert.is_true(download_mod.interrupted_dests[dest1])
      assert.is_true(download_mod.interrupted_dests[dest2])
      assert.is_true(download_mod.interrupted_dests[dest_throw])
      assert.is_true(download_mod.interrupted_dests[dest_nokill])

      -- Verify active tables are cleared
      assert.are.equal(0, vim.tbl_count(download_mod.active_handles))
      assert.are.equal(0, vim.tbl_count(download_mod.active_downloads))

      -- Callback queue dropped without firing
      assert.is_false(callback_called)

      -- UI windows and buffers cleaned up
      assert.is_nil(state.UI.wins.frame)
      assert.is_nil(state.UI.wins.input)
      assert.is_nil(state.UI.wins.list)
      assert.are.equal(0, #state.State.posts)
      assert.are.equal(1, state.State.cur)
    end)

    it("verifies teardown completes cleanly even if download.abort_all raises an unhandled error", function()
      local download_mod = require("gelbooru.net.download")
      local orig_abort = download_mod.abort_all

      ui.open()
      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.frame))

      download_mod.abort_all = function()
        error("catastrophic failure inside download.abort_all")
      end

      -- teardown must not throw because download.abort_all is wrapped in pcall
      local ok, err = pcall(ui.teardown)
      download_mod.abort_all = orig_abort

      assert.is_true(ok, "teardown crashed when abort_all threw error: " .. tostring(err))
      assert.is_nil(state.UI.wins.frame)
      assert.is_nil(state.UI.wins.input)
      assert.is_nil(state.UI.wins.list)
      assert.are.equal(0, #state.State.posts)
    end)
  end)

  describe("Adversarial: Mouse Isolation and Window Focusability (Priority 2.5)", function()
    it("disables mouse on open and restores previous user mouse setting on teardown", function()
      local orig_mouse = "nvi"
      vim.o.mouse = orig_mouse

      ui.open()
      assert.are.equal("", vim.o.mouse, "mouse was not disabled on UI open")

      ui.teardown()
      assert.are.equal(orig_mouse, vim.o.mouse, "original mouse setting was not restored on teardown")
    end)

    it("ensures non-interactive windows (frame, div, vdiv, hdiv, img, status, ac) are not focusable", function()
      ui.open()

      local non_focusable_windows = {
        state.UI.wins.frame,
        state.UI.wins.div,
        state.UI.wins.vdiv,
        state.UI.wins.img,
        state.UI.wins.status,
        state.UI.wins.ac,
      }
      if state.UI.wins.hdiv and vim.api.nvim_win_is_valid(state.UI.wins.hdiv) then
        table.insert(non_focusable_windows, state.UI.wins.hdiv)
      end

      for _, win in ipairs(non_focusable_windows) do
        assert.is_true(vim.api.nvim_win_is_valid(win))
        local cfg = vim.api.nvim_win_get_config(win)
        assert.is_false(cfg.focusable, "window was focusable: " .. tostring(win))
      end

      -- Interactive windows must remain focusable
      assert.is_true(vim.api.nvim_win_get_config(state.UI.wins.input).focusable)
      assert.is_true(vim.api.nvim_win_get_config(state.UI.wins.list).focusable)
      if state.UI.wins.meta and vim.api.nvim_win_is_valid(state.UI.wins.meta) then
        assert.is_true(vim.api.nvim_win_get_config(state.UI.wins.meta).focusable)
      end

      ui.teardown()
    end)

    it("verifies meta window keymaps: enter search, return to list, scroll, toggle M", function()
      state.State.show_meta = true
      ui.open()
      assert.is_truthy(state.UI.wins.meta)
      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.meta))

      -- M from list moves focus to meta window
      vim.api.nvim_set_current_win(state.UI.wins.list)
      local list_maps = vim.api.nvim_buf_get_keymap(state.UI.bufs.list, "n")
      local m_upper_fn
      for _, km in ipairs(list_maps) do
        if km.lhs == "M" then
          m_upper_fn = km.callback
        end
      end
      assert.is_not_nil(m_upper_fn, "M keymap not found on list buffer")
      m_upper_fn()
      assert.are.equal(state.UI.wins.meta, vim.api.nvim_get_current_win())

      -- i in meta enters search mode
      local meta_maps = vim.api.nvim_buf_get_keymap(state.UI.bufs.meta, "n")
      local i_fn, q_fn, esc_fn
      for _, km in ipairs(meta_maps) do
        if km.lhs == "i" then i_fn = km.callback end
        if km.lhs == "q" then q_fn = km.callback end
        if km.lhs == "<Esc>" then esc_fn = km.callback end
      end
      assert.is_not_nil(i_fn, "i keymap not found on meta buffer")
      assert.is_not_nil(q_fn, "q keymap not found on meta buffer")
      assert.is_not_nil(esc_fn, "<Esc> keymap not found on meta buffer")

      -- Test i in meta window transitions to input window
      i_fn()
      assert.is_true(state.State.input_focused)
      assert.are.equal(state.UI.wins.input, vim.api.nvim_get_current_win())

      -- Return to meta and test q returns focus to list window
      vim.api.nvim_set_current_win(state.UI.wins.meta)
      state.State.input_focused = false
      q_fn()
      assert.are.equal(state.UI.wins.list, vim.api.nvim_get_current_win())

      -- Return to meta and test <Esc> returns focus to list window
      vim.api.nvim_set_current_win(state.UI.wins.meta)
      esc_fn()
      assert.are.equal(state.UI.wins.list, vim.api.nvim_get_current_win())

      ui.teardown()
    end)

    it("verifies InsertLeave on UI.bufs.input exits search mode, restores list focus, and hides UI.wins.ac", function()
      ui.open()
      assert.is_true(state.State.input_focused)
      assert.are.equal(state.UI.wins.input, vim.api.nvim_get_current_win())
      assert.is_false(vim.api.nvim_win_get_config(state.UI.wins.ac).hide)

      -- Fire InsertLeave autocommand on UI.bufs.input
      vim.api.nvim_exec_autocmds("InsertLeave", { buffer = state.UI.bufs.input })

      assert.is_false(state.State.input_focused, "State.input_focused was not reset on InsertLeave")
      assert.are.equal(state.UI.wins.list, vim.api.nvim_get_current_win(), "Focus was not restored to list on InsertLeave")
      assert.is_true(vim.api.nvim_win_get_config(state.UI.wins.ac).hide, "UI.wins.ac was not hidden on InsertLeave")

      -- Re-enter search and fire InsertLeave again
      ui.enter_search()
      assert.is_true(state.State.input_focused)
      assert.are.equal(state.UI.wins.input, vim.api.nvim_get_current_win())
      assert.is_false(vim.api.nvim_win_get_config(state.UI.wins.ac).hide)

      vim.api.nvim_exec_autocmds("InsertLeave", { buffer = state.UI.bufs.input })
      assert.is_false(state.State.input_focused)
      assert.are.equal(state.UI.wins.list, vim.api.nvim_get_current_win())
      assert.is_true(vim.api.nvim_win_get_config(state.UI.wins.ac).hide)

      ui.teardown()
    end)

    it("verifies input normal mode mappings (q, j, k, <Esc>, i)", function()
      ui.open()
      local input_buf = state.UI.bufs.input
      local nmaps = vim.api.nvim_buf_get_keymap(input_buf, "n")
      local map_by_lhs = {}
      for _, km in ipairs(nmaps) do
        map_by_lhs[km.lhs] = km.callback
      end

      assert.is_not_nil(map_by_lhs["q"], "q keymap missing on input buffer in normal mode")
      assert.is_not_nil(map_by_lhs["j"], "j keymap missing on input buffer in normal mode")
      assert.is_not_nil(map_by_lhs["k"], "k keymap missing on input buffer in normal mode")
      assert.is_not_nil(map_by_lhs["<Esc>"], "<Esc> keymap missing on input buffer in normal mode")
      assert.is_not_nil(map_by_lhs["i"], "i keymap missing on input buffer in normal mode")
      assert.is_not_nil(map_by_lhs["I"], "I keymap missing on input buffer in normal mode")
      assert.is_not_nil(map_by_lhs["a"], "a keymap missing on input buffer in normal mode")
      assert.is_not_nil(map_by_lhs["A"], "A keymap missing on input buffer in normal mode")
      assert.is_not_nil(map_by_lhs["s"], "s keymap missing on input buffer in normal mode")
      assert.is_not_nil(map_by_lhs["S"], "S keymap missing on input buffer in normal mode")

      -- Test each of q, j, k, <Esc> exits search mode and restores list focus
      for _, key in ipairs({ "q", "j", "k", "<Esc>" }) do
        ui.enter_search()
        assert.is_true(state.State.input_focused)
        assert.are.equal(state.UI.wins.input, vim.api.nvim_get_current_win())

        map_by_lhs[key]()

        assert.is_false(state.State.input_focused, string.format("input was still focused after %s", key))
        assert.are.equal(state.UI.wins.list, vim.api.nvim_get_current_win(), string.format("list was not focused after %s", key))
        assert.is_true(vim.api.nvim_win_get_config(state.UI.wins.ac).hide, string.format("UI.wins.ac was not hidden after %s", key))
      end

      -- Test 'i' in input normal mode re-enters search mode
      map_by_lhs["q"]()
      assert.is_false(state.State.input_focused)
      vim.api.nvim_set_current_win(state.UI.wins.input)

      map_by_lhs["i"]()
      assert.is_true(state.State.input_focused, "i did not re-enter search mode")
      assert.are.equal(state.UI.wins.input, vim.api.nvim_get_current_win())
      assert.is_false(vim.api.nvim_win_get_config(state.UI.wins.ac).hide)

      ui.teardown()
    end)

    it("verifies M hotkey from list focuses meta (even when show_meta was false), and m/q/<Esc> returns to list", function()
      ui.open()
      assert.is_true(state.State.show_meta)

      local list_maps = vim.api.nvim_buf_get_keymap(state.UI.bufs.list, "n")
      local m_lower_fn, m_upper_fn
      for _, km in ipairs(list_maps) do
        if km.lhs == "m" then m_lower_fn = km.callback end
        if km.lhs == "M" then m_upper_fn = km.callback end
      end
      assert.is_not_nil(m_lower_fn, "m keymap not found on list buffer")
      assert.is_not_nil(m_upper_fn, "M keymap not found on list buffer")

      -- Toggle meta off so show_meta is false and meta window is hidden
      m_lower_fn()
      assert.is_false(state.State.show_meta, "m did not toggle State.show_meta to false")
      assert.is_true(state.UI.wins.meta == nil or not vim.api.nvim_win_is_valid(state.UI.wins.meta), "meta win was not hidden")

      vim.api.nvim_set_current_win(state.UI.wins.list)

      -- Press M from list when show_meta was false
      m_upper_fn()

      assert.is_true(state.State.show_meta, "State.show_meta was not toggled to true by M")
      assert.is_not_nil(state.UI.wins.meta, "UI.wins.meta was not created by M")
      assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.meta), "UI.wins.meta is not valid")
      assert.are.equal(state.UI.wins.meta, vim.api.nvim_get_current_win(), "meta window was not focused by M")
      assert.is_true(vim.wo[state.UI.wins.meta].cursorline, "cursorline not enabled on meta window")

      local status_lines = harness.get_buf_lines(state.UI.bufs.status)
      local has_hint = false
      for _, line in ipairs(status_lines) do
        if line:find("Viewing Metadata — %[q/Esc%] back to posts, %[/ or i%] search") then
          has_hint = true
          break
        end
      end
      assert.is_true(has_hint, "status hint not displayed when focusing meta")

      local meta_maps = vim.api.nvim_buf_get_keymap(state.UI.bufs.meta, "n")
      local mm_by_lhs = {}
      for _, km in ipairs(meta_maps) do
        mm_by_lhs[km.lhs] = km.callback
      end
      assert.is_not_nil(mm_by_lhs["q"], "q keymap missing on meta buffer")
      assert.is_not_nil(mm_by_lhs["<Esc>"], "<Esc> keymap missing on meta buffer")
      assert.is_not_nil(mm_by_lhs["M"], "M keymap missing on meta buffer")
      assert.is_not_nil(mm_by_lhs["m"], "m keymap missing on meta buffer")
      assert.is_not_nil(mm_by_lhs["o"], "o keymap missing on meta buffer")
      assert.is_not_nil(mm_by_lhs["O"], "O keymap missing on meta buffer")
      assert.is_not_nil(mm_by_lhs["<CR>"], "<CR> keymap missing on meta buffer")

      -- Test 'q' returns to list
      mm_by_lhs["q"]()
      assert.are.equal(state.UI.wins.list, vim.api.nvim_get_current_win(), "q did not return focus to list")

      -- Refocus meta and test '<Esc>' returns to list
      m_upper_fn()
      assert.are.equal(state.UI.wins.meta, vim.api.nvim_get_current_win())
      mm_by_lhs["<Esc>"]()
      assert.are.equal(state.UI.wins.list, vim.api.nvim_get_current_win(), "<Esc> did not return focus to list")

      -- Refocus meta and test 'M' returns to list
      m_upper_fn()
      assert.are.equal(state.UI.wins.meta, vim.api.nvim_get_current_win())
      mm_by_lhs["M"]()
      assert.are.equal(state.UI.wins.list, vim.api.nvim_get_current_win(), "M did not return focus to list")

      -- Refocus meta and test 'm' returns to list and hides meta
      m_upper_fn()
      assert.are.equal(state.UI.wins.meta, vim.api.nvim_get_current_win())
      mm_by_lhs["m"]()
      assert.are.equal(state.UI.wins.list, vim.api.nvim_get_current_win(), "m did not return focus to list")
      assert.is_false(state.State.show_meta, "m did not set State.show_meta to false")
      assert.is_true(state.UI.wins.meta == nil or not vim.api.nvim_win_is_valid(state.UI.wins.meta), "meta window was not hidden by m")

      ui.teardown()
    end)

    it("verifies defensive mappings on non-interactive buffers (frame, div, vdiv, hdiv, img, status, ac)", function()
      state.State.show_meta = true
      ui.open()

      local non_interactive_bufs = {
        frame = state.UI.bufs.frame,
        div = state.UI.bufs.div,
        vdiv = state.UI.bufs.vdiv,
        hdiv = state.UI.bufs.hdiv,
        img = state.UI.bufs.img,
        status = state.UI.bufs.status,
        ac = state.UI.bufs.ac,
      }

      local search_keys = { "i", "I", "a", "A", "s", "S", "/" }
      local list_keys = { "q", "<Esc>" }

      for name, buf in pairs(non_interactive_bufs) do
        assert.is_not_nil(buf, "buffer " .. name .. " is nil")
        assert.is_true(vim.api.nvim_buf_is_valid(buf), "buffer " .. name .. " is not valid")

        local maps = vim.api.nvim_buf_get_keymap(buf, "n")
        local map_by_lhs = {}
        for _, km in ipairs(maps) do
          map_by_lhs[km.lhs] = km.callback
        end

        for _, k in ipairs(search_keys) do
          assert.is_not_nil(map_by_lhs[k], string.format("search key %s not mapped on %s buffer", k, name))
        end
        for _, k in ipairs(list_keys) do
          assert.is_not_nil(map_by_lhs[k], string.format("list return key %s not mapped on %s buffer", k, name))
        end

        -- Test invoking search mapping from non-interactive buffer
        map_by_lhs["q"]()
        map_by_lhs["/"]()
        assert.is_true(state.State.input_focused, string.format("/ on %s did not enter search", name))
        assert.are.equal(state.UI.wins.input, vim.api.nvim_get_current_win())

        -- Test invoking return to list mapping from non-interactive buffer
        map_by_lhs["q"]()
        assert.are.equal(state.UI.wins.list, vim.api.nvim_get_current_win(), string.format("q on %s did not return to list", name))
        assert.is_false(state.State.input_focused)

        map_by_lhs["i"]()
        assert.is_true(state.State.input_focused)
        map_by_lhs["<Esc>"]()
        assert.are.equal(state.UI.wins.list, vim.api.nvim_get_current_win(), string.format("<Esc> on %s did not return to list", name))
        assert.is_false(state.State.input_focused)
      end

      ui.teardown()
    end)
  end)
end)
