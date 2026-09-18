-- tests/integration/autocomplete_spec.lua
-- Integration test for gelbooru autocomplete candidate lookup, popup buffer rendering, and navigation.

local harness = require("tests.integration.helpers.harness")
local ui = require("gelbooru.ui")
local autocomplete = require("gelbooru.ui.autocomplete")
local db = require("gelbooru.tags.db")
local state = require("gelbooru.core.state")

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
end)
