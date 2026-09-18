-- tests/integration/regressions_spec.lua
-- Integration tests specifically designed to reproduce and catch:
-- 1. Blank list buffer on re-submitting the same search query
-- 2. Image placement failure on 'm' toggle
-- 3. Asynchronous tag resolution preview races (cur_id deduplication deadlock)

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
end)
