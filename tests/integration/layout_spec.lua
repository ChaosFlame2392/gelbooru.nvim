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

  it("updates layout dimensions and nudges image placement on resize handling", function()
    local orig_cols = vim.o.columns
    local orig_lines = vim.o.lines

    local ok, err = pcall(function()
      vim.o.columns = 120
      vim.o.lines = 40

      ui.open()
      api.execute_search("vocaloid")

      vim.wait(1000, function()
        return #state.State.posts > 0
      end, 10)

      ui.render_preview(false)

      vim.wait(1000, function()
        return state.UI.current_placement ~= nil
      end, 10)

      local placement = state.UI.current_placement
      assert.is_not_nil(placement)
      local initial_updates = placement.updated_count

      local initial_layout = ui.calc_layout()
      local initial_frame_w = initial_layout.frame.width
      local initial_frame_h = initial_layout.frame.height

      -- Resize terminal and trigger VimResized
      vim.o.columns = 160
      vim.o.lines = 50
      vim.cmd("doautocmd VimResized")

      -- Wait for debounced resize handler (RESIZE_DEBOUNCE_MS = 100) to execute and apply layout
      vim.wait(1000, function()
        local frame_cfg = vim.api.nvim_win_get_config(state.UI.wins.frame)
        return frame_cfg.width ~= initial_frame_w
      end, 20)

      local new_layout = ui.calc_layout()
      assert.is_true(new_layout.frame.width > initial_frame_w)
      assert.is_true(new_layout.frame.height > initial_frame_h)

      -- Verify window configurations updated to match new layout
      local frame_cfg = vim.api.nvim_win_get_config(state.UI.wins.frame)
      assert.are.equal(new_layout.frame.width, frame_cfg.width)
      assert.are.equal(new_layout.frame.height, frame_cfg.height)

      -- Verify image placement was nudged and remains active without error
      assert.is_true(placement.updated_count > initial_updates)
      assert.is_false(placement.closed)
      assert.are.equal(placement.buf, vim.api.nvim_win_get_buf(state.UI.wins.img))

      -- Verify compact terminal dimensions clamp properly without exceeding screen limits
      vim.o.columns = 60
      vim.o.lines = 15
      local compact_layout = ui.calc_layout(true)
      assert.is_true(compact_layout.frame.width <= 60)
      assert.is_true(compact_layout.frame.height <= 15)
      ui.apply_layout(compact_layout)
      assert.is_false(placement.closed)
    end)

    vim.o.columns = orig_cols
    vim.o.lines = orig_lines

    if not ok then
      error(err)
    end
  end)

  it("adversarial: handles rapid flurry of VimResized events and settles on final dimensions", function()
    local orig_cols = vim.o.columns
    local orig_lines = vim.o.lines

    local ok, err = pcall(function()
      vim.o.columns = 100
      vim.o.lines = 30
      ui.open()
      vim.cmd("stopinsert")

      -- Burst of 15 rapid VimResized events oscillating dimensions
      for i = 1, 15 do
        vim.o.columns = 100 + (i * 3)
        vim.o.lines = 30 + (i % 4)
        vim.cmd("doautocmd VimResized")
      end

      -- Settle on final target dimensions
      vim.o.columns = 150
      vim.o.lines = 45
      vim.cmd("doautocmd VimResized")

      local expected_w = math.floor(150 * 0.95)
      local expected_h = math.floor(45 * 0.95)

      -- Wait for debounce timer to settle and apply layout
      local waited = vim.wait(1500, function()
        local frame_cfg = vim.api.nvim_win_get_config(state.UI.wins.frame)
        return frame_cfg.width == expected_w and frame_cfg.height == expected_h
      end, 20)

      assert.is_true(waited)
      local final_layout = ui.calc_layout()
      assert.are.equal(expected_w, final_layout.frame.width)
      assert.are.equal(expected_h, final_layout.frame.height)

      -- Verify internal subwindow bounds match calculated layout
      local list_cfg = vim.api.nvim_win_get_config(state.UI.wins.list)
      local img_cfg = vim.api.nvim_win_get_config(state.UI.wins.img)
      assert.are.equal(final_layout.list.width, list_cfg.width)
      assert.are.equal(final_layout.list.height, list_cfg.height)
      assert.are.equal(final_layout.img.width, img_cfg.width)
      assert.are.equal(final_layout.img.height, img_cfg.height)
    end)

    vim.o.columns = orig_cols
    vim.o.lines = orig_lines

    if not ok then
      error(err)
    end
  end)

  it("adversarial: resizes correctly when metadata panel is toggled off", function()
    local orig_cols = vim.o.columns
    local orig_lines = vim.o.lines

    local ok, err = pcall(function()
      vim.o.columns = 120
      vim.o.lines = 40
      ui.open()
      api.execute_search("vocaloid")

      vim.wait(1000, function()
        return #state.State.posts > 0
      end, 10)

      ui.render_preview(false)
      vim.wait(1000, function()
        return state.UI.current_placement ~= nil
      end, 10)

      local placement = state.UI.current_placement
      assert.is_not_nil(placement)

      -- Toggle metadata panel off
      state.State.show_meta = false
      ui.handle_resize()

      local l1 = ui.calc_layout()
      assert.is_nil(l1.meta)
      assert.is_nil(l1.hdiv)
      local img_cfg1 = vim.api.nvim_win_get_config(state.UI.wins.img)
      assert.are.equal(l1.img.height, img_cfg1.height)
      assert.are.equal(l1.list.height, l1.img.height)

      -- Trigger VimResized while show_meta is false
      vim.o.columns = 150
      vim.o.lines = 48
      vim.cmd("doautocmd VimResized")

      local expected_w = math.floor(150 * 0.95)
      vim.wait(1000, function()
        local frame_cfg = vim.api.nvim_win_get_config(state.UI.wins.frame)
        return frame_cfg.width == expected_w
      end, 20)

      local l2 = ui.calc_layout()
      assert.is_nil(l2.meta)
      assert.is_nil(l2.hdiv)
      local img_cfg2 = vim.api.nvim_win_get_config(state.UI.wins.img)
      assert.are.equal(l2.img.height, img_cfg2.height)
      -- Canvas height should equal list height (full main_h) since meta panel is hidden
      assert.are.equal(l2.list.height, l2.img.height)
      assert.is_false(placement.closed)

      -- Toggle metadata panel back on and trigger resize again
      state.State.show_meta = true
      vim.o.columns = 130
      vim.o.lines = 42
      vim.cmd("doautocmd VimResized")

      local expected_w2 = math.floor(130 * 0.95)
      vim.wait(1000, function()
        local frame_cfg = vim.api.nvim_win_get_config(state.UI.wins.frame)
        return frame_cfg.width == expected_w2
      end, 20)

      local l3 = ui.calc_layout()
      assert.is_not_nil(l3.meta)
      assert.is_not_nil(l3.hdiv)
      local meta_cfg = vim.api.nvim_win_get_config(state.UI.wins.meta)
      assert.are.equal(l3.meta.height, meta_cfg.height)
      assert.is_false(placement.closed)
    end)

    vim.o.columns = orig_cols
    vim.o.lines = orig_lines

    if not ok then
      error(err)
    end
  end)

  it("adversarial: clamps layout within compact bounds (columns=20, lines=10) without coordinate errors", function()
    local orig_cols = vim.o.columns
    local orig_lines = vim.o.lines

    local ok, err = pcall(function()
      -- Start at normal size then dynamically shrink to compact dimensions
      vim.o.columns = 100
      vim.o.lines = 30
      ui.open()

      vim.o.columns = 20
      vim.o.lines = 10
      ui.handle_resize()

      local l = ui.calc_layout()
      assert.is_true(l.frame.width <= 20)
      assert.is_true(l.frame.height <= 10)
      assert.is_true(l.frame.row >= 0)
      assert.is_true(l.frame.col >= 0)

      -- Ensure subwindow coordinates are non-negative and positive dimensions
      for name, win_layout in pairs(l) do
        if type(win_layout) == "table" and win_layout.width then
          assert.is_true(win_layout.width >= 1, "width must be >= 1 for " .. name)
          assert.is_true(win_layout.height >= 1, "height must be >= 1 for " .. name)
          assert.is_true(win_layout.row >= 0, "row must be >= 0 for " .. name)
          assert.is_true(win_layout.col >= 0, "col must be >= 0 for " .. name)
          assert.is_true(win_layout.row + win_layout.height <= 10, "row+height fits within lines for " .. name)
          assert.is_true(win_layout.col + win_layout.width <= 20, "col+width fits within columns for " .. name)
        end
      end

      -- Verify nvim_win_get_config matches without error
      local frame_cfg = vim.api.nvim_win_get_config(state.UI.wins.frame)
      assert.are.equal(l.frame.width, frame_cfg.width)
      assert.are.equal(l.frame.height, frame_cfg.height)

      -- Verify opening UI directly at compact dimensions (20x10) works cleanly
      ui.teardown()
      vim.o.columns = 20
      vim.o.lines = 10
      ui.open()

      local open_l = ui.calc_layout()
      assert.is_true(open_l.frame.width <= 20)
      assert.is_true(open_l.frame.height <= 10)
      local direct_frame_cfg = vim.api.nvim_win_get_config(state.UI.wins.frame)
      assert.are.equal(open_l.frame.width, direct_frame_cfg.width)
      assert.are.equal(open_l.frame.height, direct_frame_cfg.height)
    end)

    vim.o.columns = orig_cols
    vim.o.lines = orig_lines

    if not ok then
      error(err)
    end
  end)

  it("adversarial: handles resize safely after teardown and during teardown race", function()
    local orig_cols = vim.o.columns
    local orig_lines = vim.o.lines

    local ok, err = pcall(function()
      vim.o.columns = 120
      vim.o.lines = 40
      ui.open()

      -- Queue VimResized event and teardown immediately before debounce timer fires
      vim.cmd("doautocmd VimResized")
      ui.teardown()

      -- Wait past the debounce timer window (RESIZE_DEBOUNCE_MS = 100)
      vim.wait(200, function() return false end, 20)

      -- UI windows should remain closed and state cleared
      assert.is_nil(state.UI.wins.frame)
      assert.is_nil(state.UI.resize_timer)

      -- Calling handle_resize or on_resize when UI is closed should cleanly no-op
      local handle_ok = pcall(ui.handle_resize)
      assert.is_true(handle_ok)

      local on_resize_ok = pcall(ui.on_resize)
      assert.is_true(on_resize_ok)

      -- Firing VimResized event when UI is closed should not throw or resurrect windows
      vim.cmd("doautocmd VimResized")
      vim.wait(200, function() return false end, 20)
      assert.is_nil(state.UI.wins.frame)
    end)

    vim.o.columns = orig_cols
    vim.o.lines = orig_lines

    if not ok then
      error(err)
    end
  end)
end)
