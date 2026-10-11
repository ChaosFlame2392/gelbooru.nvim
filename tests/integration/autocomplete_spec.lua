-- tests/integration/autocomplete_spec.lua
-- Integration test for gelbooru autocomplete candidate lookup, popup buffer rendering, and navigation.

local harness = require("tests.integration.helpers.harness")
local ui = require("gelbooru.ui")
local autocomplete = require("gelbooru.ui.autocomplete")
local db = require("gelbooru.tags.db")
local state = require("gelbooru.core.state")
local api = require("gelbooru.net.api")

describe("Integration: Autocomplete Engine", function()
  before_each(function()
    harness.setup_all()
    harness.reset_environment()
    -- Load sample tags into index (must be clean and have n_lower/norm)
    db.add_tag_to_index({ n = "hatsune_miku", t = 4, c = 140000 }, state.State.characters, state.State.chars_by_first)
    db.add_tag_to_index({ n = "vocaloid", t = 3, c = 200000 }, state.State.series, state.State.series_by_first)
    db.add_tag_to_index({ n = "kekeflipnote", t = 1, c = 500 }, state.State.artists, state.State.artists_by_first)
  end)

  after_each(function()
    harness.reset_environment()
    harness.teardown_all()
  end)

  it("populates autocomplete buffer for matching tag query prefix", function()
    ui.open()
    db.add_tag_to_index({ n = "hatsune_miku", t = 4, c = 140000 }, state.State.characters, state.State.chars_by_first)
    vim.api.nvim_buf_set_lines(state.UI.bufs.input, 0, 1, false, { "hats" })

    autocomplete.update_autocomplete()

    assert.is_true(#state.State.autocomplete_filtered > 0)
    assert.are.equal("hatsune_miku", state.State.autocomplete_filtered[1].n)

    local ac_lines = harness.get_buf_lines(state.UI.bufs.ac)
    assert.is_true(#ac_lines > 0)
    assert.is_true(ac_lines[1]:find("hatsune_miku") ~= nil)
  end)

  it("advances autocomplete navigation index on selection move", function()
    ui.open()
    db.add_tag_to_index({ n = "vocaloid", t = 3, c = 200000 }, state.State.series, state.State.series_by_first)
    vim.api.nvim_buf_set_lines(state.UI.bufs.input, 0, 1, false, { "vocal" })
    autocomplete.update_autocomplete()

    state.State.autocomplete_navigated = true
    state.State.autocomplete_cur = 1
    autocomplete.update_autocomplete()

    assert.is_true(state.State.autocomplete_navigated)
    assert.are.equal(1, state.State.autocomplete_cur)
  end)

  it("does not show local_only tags (sort:date, sort:mtime) without local: prefix", function()
    ui.open()
    vim.api.nvim_buf_set_lines(state.UI.bufs.input, 0, 1, false, { "sort:d" })
    autocomplete.update_autocomplete()

    local names = {}
    for _, item in ipairs(state.State.autocomplete_filtered or {}) do
      names[item.n] = true
    end
    assert.is_nil(names["sort:date"])
    assert.is_nil(names["sort:date:asc"])

    vim.api.nvim_buf_set_lines(state.UI.bufs.input, 0, 1, false, { "sort:m" })
    autocomplete.update_autocomplete()
    names = {}
    for _, item in ipairs(state.State.autocomplete_filtered or {}) do
      names[item.n] = true
    end
    assert.is_nil(names["sort:mtime"])
  end)

  it("shows local_only tags when local: prefix is present", function()
    ui.open()
    vim.api.nvim_buf_set_lines(state.UI.bufs.input, 0, 1, false, { "local: sort:d" })
    autocomplete.update_autocomplete()

    local names = {}
    for _, item in ipairs(state.State.autocomplete_filtered or {}) do
      names[item.n] = true
    end
    assert.is_true(names["sort:date"] == true)
    assert.is_true(names["sort:date:asc"] == true)

    vim.api.nvim_buf_set_lines(state.UI.bufs.input, 0, 1, false, { "local: sort:m" })
    autocomplete.update_autocomplete()
    names = {}
    for _, item in ipairs(state.State.autocomplete_filtered or {}) do
      names[item.n] = true
    end
    assert.is_true(names["sort:mtime"] == true)
  end)

  it("shows non-local meta tags (such as sort:random) in both online and local modes", function()
    ui.open()
    vim.api.nvim_buf_set_lines(state.UI.bufs.input, 0, 1, false, { "sort:r" })
    autocomplete.update_autocomplete()
    local names = {}
    for _, item in ipairs(state.State.autocomplete_filtered or {}) do
      names[item.n] = true
    end
    assert.is_true(names["sort:random"] == true)

    vim.api.nvim_buf_set_lines(state.UI.bufs.input, 0, 1, false, { "local: sort:r" })
    autocomplete.update_autocomplete()
    names = {}
    for _, item in ipairs(state.State.autocomplete_filtered or {}) do
      names[item.n] = true
    end
    assert.is_true(names["sort:random"] == true)
  end)

  local function get_keymap_cb(buf, mode, key)
    local maps = vim.api.nvim_buf_get_keymap(buf, mode or "i")
    for _, m in ipairs(maps) do
      if m.lhs == key or (key == "<Space>" and m.lhs == " ") or (key == " " and m.lhs == "<Space>") then
        return m.callback
      end
    end
    return nil
  end

  describe("Issue 3: Query Bar Substring Autocomplete Cursor Alignment", function()
    it("completes token under cursor with <Space> when cursor is on earlier token (not tail)", function()
      ui.open()
      db.add_tag_to_index({ n = "rating:explicit", t = 5, c = 1000 }, state.State.all_tags, state.State.all_tags_by_first)

      local text = "rating:expli tag1"
      vim.api.nvim_buf_set_lines(state.UI.bufs.input, 0, 1, false, { text })
      -- Set cursor at end of "rating:expli" (col 12)
      vim.api.nvim_win_set_cursor(state.UI.wins.input, { 1, 12 })

      state.State.autocomplete_filtered = { { n = "rating:explicit" } }
      state.State.autocomplete_cur = 1
      state.State.autocomplete_navigated = true

      local space_cb = get_keymap_cb(state.UI.bufs.input, "i", "<Space>")
      assert.is_not_nil(space_cb, "<Space> keymap must exist on input buffer")
      space_cb()

      local lines = vim.api.nvim_buf_get_lines(state.UI.bufs.input, 0, 1, false)
      assert.are.equal("rating:explicit  tag1", lines[1])
      local cur = vim.api.nvim_win_get_cursor(state.UI.wins.input)
      assert.are.equal(16, cur[2]) -- #"" + #"" + #"rating:explicit" + 1 = 16
    end)

    it("completes token under cursor with <Space> when cursor is in the middle of a token", function()
      ui.open()
      local text = "rating:expli tag1"
      vim.api.nvim_buf_set_lines(state.UI.bufs.input, 0, 1, false, { text })
      -- Set cursor at col 10 (inside "rating:expli", right after "rating:exp")
      vim.api.nvim_win_set_cursor(state.UI.wins.input, { 1, 10 })

      state.State.autocomplete_filtered = { { n = "rating:explicit" } }
      state.State.autocomplete_cur = 1
      state.State.autocomplete_navigated = true

      local space_cb = get_keymap_cb(state.UI.bufs.input, "i", "<Space>")
      assert.is_not_nil(space_cb)
      space_cb()

      local lines = vim.api.nvim_buf_get_lines(state.UI.bufs.input, 0, 1, false)
      assert.are.equal("rating:explicit  tag1", lines[1])
      local cur = vim.api.nvim_win_get_cursor(state.UI.wins.input)
      assert.are.equal(16, cur[2])
    end)

    it("preserves leading modifier prefix (| or -) when completing token under cursor", function()
      ui.open()
      local text = "-rating:expli tag1"
      vim.api.nvim_buf_set_lines(state.UI.bufs.input, 0, 1, false, { text })
      -- Set cursor at col 13 (end of "-rating:expli")
      vim.api.nvim_win_set_cursor(state.UI.wins.input, { 1, 13 })

      state.State.autocomplete_filtered = { { n = "rating:explicit" } }
      state.State.autocomplete_cur = 1
      state.State.autocomplete_navigated = true

      local space_cb = get_keymap_cb(state.UI.bufs.input, "i", "<Space>")
      assert.is_not_nil(space_cb)
      space_cb()

      local lines = vim.api.nvim_buf_get_lines(state.UI.bufs.input, 0, 1, false)
      assert.are.equal("-rating:explicit  tag1", lines[1])
      local cur = vim.api.nvim_win_get_cursor(state.UI.wins.input)
      assert.are.equal(17, cur[2]) -- #"" + #"-" + #"rating:explicit" + 1 = 17
    end)

    it("completes token under cursor with <CR> (submit_input) without extra space and executes search", function()
      ui.open()
      local executed_query = nil
      local orig_search = api.execute_search
      api.execute_search = function(q)
        executed_query = q
      end

      local text = "rating:expli tag1"
      vim.api.nvim_buf_set_lines(state.UI.bufs.input, 0, 1, false, { text })
      vim.api.nvim_win_set_cursor(state.UI.wins.input, { 1, 12 })

      state.State.autocomplete_filtered = { { n = "rating:explicit" } }
      state.State.autocomplete_cur = 1
      state.State.autocomplete_navigated = true

      local cr_cb = get_keymap_cb(state.UI.bufs.input, "i", "<CR>")
      assert.is_not_nil(cr_cb, "<CR> keymap must exist on input buffer")
      cr_cb()

      assert.are.equal("rating:explicit tag1", executed_query)

      api.execute_search = orig_search
    end)
  end)
end)
