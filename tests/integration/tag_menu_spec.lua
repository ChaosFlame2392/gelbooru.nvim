-- tests/integration/tag_menu_spec.lua
-- Integration tests for the Interactive Tag Picker Modal ('t' / 'T')

local harness = require("tests.integration.helpers.harness")
local ui = require("gelbooru.ui")
local api = require("gelbooru.net.api")
local state = require("gelbooru.core.state")
local mock_net = require("tests.integration.helpers.mock_net")

local function get_keymap_cb(buf, mode, key)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local maps = vim.api.nvim_buf_get_keymap(buf, mode or "n")
  for _, m in ipairs(maps) do
    if m.lhs == key or (key == "<Space>" and (m.lhs == " " or m.lhs == "<Space>")) or (key == " " and (m.lhs == " " or m.lhs == "<Space>")) then
      return m.callback or function()
        if m.rhs then
          vim.cmd("normal! " .. m.rhs)
        end
      end
    end
  end
  return nil
end

describe("Integration: Interactive Tag Picker Modal ('t' / 'T')", function()
  before_each(function()
    harness.setup_all()
    harness.reset_environment()
  end)

  after_each(function()
    harness.reset_environment()
    harness.teardown_all()
  end)

  it("opens tag modal when 't' is triggered on active post with categorized/badged tags", function()
    ui.open()
    state.State.posts = vim.deepcopy(mock_net.sample_posts)
    state.State.cur = 1
    ui.render_list()

    local t_cb = get_keymap_cb(state.UI.bufs.list, "n", "t")
    assert.is_not_nil(t_cb, "'t' keymap must be registered on list buffer")
    t_cb()

    assert.is_not_nil(state.UI.wins.tag_modal, "tag modal window must exist")
    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.tag_modal))

    local modal_lines = harness.get_buf_lines(state.UI.bufs.tag_modal)
    assert.is_true(#modal_lines >= 4, "modal should display tags of post")

    -- Check checkbox format and badge categories
    for _, line in ipairs(modal_lines) do
      assert.is_truthy(line:find("^%[ %]"), "each tag line should start with an unselected checkbox [ ]")
    end

    -- kekeflipnote is artist (type 1), vocaloid is series (type 3), hatsune_miku is char (type 4), 1girl is general (type 0)
    local has_artist = false
    local has_series = false
    local has_char = false
    local has_general = false
    for _, line in ipairs(modal_lines) do
      if line:find("kekeflipnote") and line:find("Artist") then has_artist = true end
      if line:find("vocaloid") and line:find("Series") then has_series = true end
      if line:find("hatsune_miku") and line:find("Char") then has_char = true end
      if line:find("1girl") and line:find("General") then has_general = true end
    end
    assert.is_true(has_artist, "should badge artist tag")
    assert.is_true(has_series, "should badge series tag")
    assert.is_true(has_char, "should badge character tag")
    assert.is_true(has_general, "should badge general tag")
  end)

  it("opens tag modal with 'T' and works from metadata buffer", function()
    ui.open()
    state.State.posts = vim.deepcopy(mock_net.sample_posts)
    state.State.cur = 1
    ui.render_list()
    ui.render_metadata(state.State.posts[1])

    vim.api.nvim_set_current_win(state.UI.wins.meta)

    local t_cb = get_keymap_cb(state.UI.bufs.meta, "n", "T")
    assert.is_not_nil(t_cb, "'T' keymap must be registered on meta buffer")
    t_cb()

    assert.is_not_nil(state.UI.wins.tag_modal, "tag modal window must exist")
    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.tag_modal))
  end)

  it("opens tag modal in Zen Mode ('\\')", function()
    ui.open()
    state.State.posts = vim.deepcopy(mock_net.sample_posts)
    state.State.cur = 1
    ui.render_list()

    ui.toggle_zen()
    assert.is_true(state.State.zen_mode)

    local t_cb = get_keymap_cb(state.UI.bufs.list, "n", "t")
    assert.is_not_nil(t_cb)
    t_cb()

    assert.is_not_nil(state.UI.wins.tag_modal)
    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.tag_modal))

    ui.close_tag_modal()
    assert.is_nil(state.UI.wins.tag_modal)
  end)

  it("shows status 'No tags available for this post' when active post has no tags", function()
    ui.open()
    state.State.posts = {
      { id = 999, tags = "", file_url = "https://example.com/notags.jpg" },
    }
    state.State.cur = 1
    ui.render_list()

    ui.open_tag_modal()
    assert.is_nil(state.UI.wins.tag_modal, "modal must not open when post has no tags")

    local status_lines = harness.get_buf_lines(state.UI.bufs.status)
    assert.is_truthy(status_lines[1]:find("No tags available for this post"))
  end)

  it("navigates tag list with 'j' and 'k' (<Down> / <Up>)", function()
    ui.open()
    state.State.posts = vim.deepcopy(mock_net.sample_posts)
    state.State.cur = 1
    ui.render_list()
    ui.open_tag_modal()

    local modal_buf = state.UI.bufs.tag_modal
    local modal_win = state.UI.wins.tag_modal
    assert.are.equal(1, vim.api.nvim_win_get_cursor(modal_win)[1])

    local j_cb = get_keymap_cb(modal_buf, "n", "j")
    assert.is_not_nil(j_cb, "'j' keymap must be registered on modal buffer")
    j_cb()
    assert.are.equal(2, vim.api.nvim_win_get_cursor(modal_win)[1])

    local k_cb = get_keymap_cb(modal_buf, "n", "k")
    assert.is_not_nil(k_cb, "'k' keymap must be registered on modal buffer")
    k_cb()
    assert.are.equal(1, vim.api.nvim_win_get_cursor(modal_win)[1])

    -- Does not decrement past 1
    k_cb()
    assert.are.equal(1, vim.api.nvim_win_get_cursor(modal_win)[1])
  end)

  it("toggles tag selection with <Space>", function()
    ui.open()
    state.State.posts = vim.deepcopy(mock_net.sample_posts)
    state.State.cur = 1
    ui.render_list()
    ui.open_tag_modal()

    local modal_buf = state.UI.bufs.tag_modal
    local space_cb = get_keymap_cb(modal_buf, "n", "<Space>")
    assert.is_not_nil(space_cb, "<Space> keymap must be registered on modal buffer")

    local lines_before = harness.get_buf_lines(modal_buf)
    assert.is_truthy(lines_before[1]:find("^%[ %]"))

    space_cb()
    local lines_after = harness.get_buf_lines(modal_buf)
    assert.is_truthy(lines_after[1]:find("^%[x%]"))

    space_cb()
    local lines_toggled_back = harness.get_buf_lines(modal_buf)
    assert.is_truthy(lines_toggled_back[1]:find("^%[ %]"))
  end)

  it("toggles all tags with 'a' (select all if none/some selected, unselect all if all selected)", function()
    ui.open()
    state.State.posts = vim.deepcopy(mock_net.sample_posts)
    state.State.cur = 1
    ui.render_list()
    ui.open_tag_modal()

    local modal_buf = state.UI.bufs.tag_modal
    local a_cb = get_keymap_cb(modal_buf, "n", "a")
    assert.is_not_nil(a_cb, "'a' keymap must be registered on modal buffer")

    -- 1. None selected -> 'a' selects all
    a_cb()
    local lines_all = harness.get_buf_lines(modal_buf)
    for _, line in ipairs(lines_all) do
      assert.is_truthy(line:find("^%[x%]"))
    end

    -- 2. All selected -> 'a' unselects all
    a_cb()
    local lines_none = harness.get_buf_lines(modal_buf)
    for _, line in ipairs(lines_none) do
      assert.is_truthy(line:find("^%[ %]"))
    end

    -- 3. Some selected -> 'a' selects all
    local space_cb = get_keymap_cb(modal_buf, "n", "<Space>")
    space_cb() -- line 1 is selected
    local lines_some = harness.get_buf_lines(modal_buf)
    assert.is_truthy(lines_some[1]:find("^%[x%]"))
    assert.is_truthy(lines_some[2]:find("^%[ %]"))

    a_cb() -- should select all
    local lines_all_again = harness.get_buf_lines(modal_buf)
    for _, line in ipairs(lines_all_again) do
      assert.is_truthy(line:find("^%[x%]"))
    end
  end)

  it("yanks highlighted tag name into '\"' and '+' registers with 'y' and notifies user", function()
    ui.open()
    state.State.posts = vim.deepcopy(mock_net.sample_posts)
    state.State.cur = 1
    ui.render_list()
    ui.open_tag_modal()

    local modal_buf = state.UI.bufs.tag_modal
    local y_cb = get_keymap_cb(modal_buf, "n", "y")
    assert.is_not_nil(y_cb, "'y' keymap must be registered on modal buffer")

    local lines = harness.get_buf_lines(modal_buf)
    local expected_tag = lines[1]:match("%[%s*%S+%s*%]%s+(%S+)") or lines[1]:match("%S+$")

    y_cb()

    assert.are.equal(expected_tag, vim.fn.getreg('"'))
    assert.are.equal(expected_tag, vim.fn.getreg("+"))

    local status_lines = harness.get_buf_lines(state.UI.bufs.status)
    assert.is_truthy(status_lines[1]:find("Yanked tag: " .. expected_tag))
  end)

  it("commits selected tags with <CR> and triggers search with combined query", function()
    ui.open()
    state.State.posts = vim.deepcopy(mock_net.sample_posts)
    state.State.cur = 1
    ui.render_list()
    ui.open_tag_modal()

    local modal_buf = state.UI.bufs.tag_modal
    local space_cb = get_keymap_cb(modal_buf, "n", "<Space>")
    local j_cb = get_keymap_cb(modal_buf, "n", "j")
    local cr_cb = get_keymap_cb(modal_buf, "n", "<CR>")
    assert.is_not_nil(cr_cb, "<CR> keymap must be registered on modal buffer")

    -- Select item 1 and item 2
    space_cb()
    j_cb()
    space_cb()

    local executed_query = nil
    local orig_search = api.execute_search
    api.execute_search = function(q)
      executed_query = q
    end

    cr_cb()

    assert.is_nil(state.UI.wins.tag_modal, "modal must be closed after committing")
    assert.is_not_nil(executed_query)
    -- Should contain both tags
    local lines = harness.get_buf_lines(state.UI.bufs.input)
    assert.are.equal(executed_query, lines[1])
    assert.is_true(#executed_query:gsub("%S+", "") >= 1, "query should contain multiple tags joined by space")

    api.execute_search = orig_search
  end)

  it("commits highlighted tag under cursor when <CR> is pressed with no tags selected", function()
    ui.open()
    state.State.posts = vim.deepcopy(mock_net.sample_posts)
    state.State.cur = 1
    ui.render_list()
    ui.open_tag_modal()

    local modal_buf = state.UI.bufs.tag_modal
    local lines = harness.get_buf_lines(modal_buf)
    local expected_tag = lines[1]:match("%[%s*%S+%s*%]%s+(%S+)") or lines[1]:match("%S+$")

    local cr_cb = get_keymap_cb(modal_buf, "n", "<CR>")
    local executed_query = nil
    local orig_search = api.execute_search
    api.execute_search = function(q)
      executed_query = q
    end

    cr_cb()

    assert.is_nil(state.UI.wins.tag_modal, "modal must be closed")
    assert.are.equal(expected_tag, executed_query)

    api.execute_search = orig_search
  end)

  it("dismisses modal with 'q' and '<Esc>' without triggering search", function()
    ui.open()
    state.State.posts = vim.deepcopy(mock_net.sample_posts)
    state.State.cur = 1
    ui.render_list()
    ui.open_tag_modal()

    local search_invoked = false
    local orig_search = api.execute_search
    api.execute_search = function()
      search_invoked = true
    end

    local modal_buf = state.UI.bufs.tag_modal
    local q_cb = get_keymap_cb(modal_buf, "n", "q")
    assert.is_not_nil(q_cb)
    q_cb()

    assert.is_nil(state.UI.wins.tag_modal)
    assert.is_false(search_invoked)

    -- Test <Esc>
    ui.open_tag_modal()
    assert.is_not_nil(state.UI.wins.tag_modal)
    local esc_cb = get_keymap_cb(state.UI.bufs.tag_modal, "n", "<Esc>")
    assert.is_not_nil(esc_cb)
    esc_cb()

    assert.is_nil(state.UI.wins.tag_modal)
    assert.is_false(search_invoked)

    api.execute_search = orig_search
  end)

  it("cleans up tag modal handles on ui.teardown()", function()
    ui.open()
    state.State.posts = vim.deepcopy(mock_net.sample_posts)
    state.State.cur = 1
    ui.render_list()
    ui.open_tag_modal()

    assert.is_not_nil(state.UI.wins.tag_modal)
    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.tag_modal))

    ui.teardown()

    assert.is_nil(state.UI.wins.tag_modal)
    assert.is_nil(state.UI.bufs.tag_modal)
  end)
end)
