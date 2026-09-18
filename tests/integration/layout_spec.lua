-- tests/integration/layout_spec.lua
-- Integration test for gelbooru floating layout, metadata panel toggle ('m'), and dynamic tag resolution.

local harness = require("tests.integration.helpers.harness")
local ui = require("gelbooru.ui")
local api = require("gelbooru.net.api")
local state = require("gelbooru.core.state")

describe("Integration: Layout & Metadata Panel", function()
  before_each(function()
    harness.setup_all()
    harness.reset_environment()
  end)

  after_each(function()
    harness.reset_environment()
    harness.teardown_all()
  end)

  it("calculates initial layout with show_meta = true and creates meta window", function()
    state.State.show_meta = true
    ui.open()

    local l = ui.calc_layout()
    assert.is_not_nil(l.meta)
    assert.is_not_nil(l.hdiv)
    assert.is_true(l.meta.height > 0)

    assert.is_true(vim.api.nvim_win_is_valid(state.UI.wins.meta))
  end)

  it("hides meta and hdiv windows when show_meta is toggled off", function()
    state.State.show_meta = true
    ui.open()

    -- Toggle meta off
    state.State.show_meta = false
    ui.on_resize()

    local l = ui.calc_layout()
    assert.is_nil(l.meta)
    assert.is_nil(l.hdiv)

    -- Floating layout should expand preview img window height
    local img_cfg = vim.api.nvim_win_get_config(state.UI.wins.img)
    assert.are.equal(l.img.height, img_cfg.height)
  end)

  it("formats metadata buffer lines correctly for selected post", function()
    ui.open()
    api.execute_search("vocaloid")

    vim.wait(100, function()
      return #state.State.posts > 0
    end)

    ui.render_preview(false)

    local meta_lines = harness.get_buf_lines(state.UI.bufs.meta)
    assert.is_true(#meta_lines > 0)

    local found_id, found_rating, found_score = false, false, false
    for _, line in ipairs(meta_lines) do
      if line:find("ID      :") then found_id = true end
      if line:find("Rating  :") then found_rating = true end
      if line:find("Score   :") then found_score = true end
    end

    assert.is_true(found_id)
    assert.is_true(found_rating)
    assert.is_true(found_score)
  end)
end)
