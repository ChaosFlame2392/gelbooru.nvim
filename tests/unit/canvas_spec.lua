local assert = require("luassert")

describe("ui.canvas: Terminal Canvas Adapter & Placement Isolation", function()
  local canvas
  local state
  local config
  local mock_snacks

  before_each(function()
    package.loaded["gelbooru.ui.canvas"] = nil
    state = require("gelbooru.core.state")
    config = require("gelbooru.core.config")
    state.reset_query_state()
    state.reset_ui()

    mock_snacks = require("tests.integration.helpers.mock_snacks")
    mock_snacks.setup()
  end)

  after_each(function()
    mock_snacks.teardown()
    package.loaded["gelbooru.ui.canvas"] = nil
  end)

  describe("canvas.sanitize_dpi", function()
    it("normalizes extreme astronomical DPI to standard 96x96", function()
      canvas = require("gelbooru.ui.canvas")
      local img = {
        info = {
          dpi = { width = 42000000, height = 42000000 },
        },
      }
      canvas.sanitize_dpi(img)
      assert.are.equal(96, img.info.dpi.width)
      assert.are.equal(96, img.info.dpi.height)
    end)

    it("normalizes sub-50 DPI to standard 96x96", function()
      canvas = require("gelbooru.ui.canvas")
      local img = {
        info = {
          dpi = { width = 10, height = 10 },
        },
      }
      canvas.sanitize_dpi(img)
      assert.are.equal(96, img.info.dpi.width)
      assert.are.equal(96, img.info.dpi.height)
    end)

    it("normalizes unbalanced DPI (>300 on one axis) to standard 96x96", function()
      canvas = require("gelbooru.ui.canvas")
      local img = {
        info = {
          dpi = { width = 72, height = 600 },
        },
      }
      canvas.sanitize_dpi(img)
      assert.are.equal(96, img.info.dpi.width)
      assert.are.equal(96, img.info.dpi.height)
    end)

    it("normalizes exactly 300 DPI images down to 96x96", function()
      canvas = require("gelbooru.ui.canvas")
      local img_300 = { info = { dpi = { width = 300, height = 300 } } }
      canvas.sanitize_dpi(img_300)
      assert.are.equal(96, img_300.info.dpi.width)
      assert.are.equal(96, img_300.info.dpi.height)
    end)

    it("preserves standard and reasonable in-range DPI (50 to < 300) unchanged", function()
      canvas = require("gelbooru.ui.canvas")
      local img_96 = { info = { dpi = { width = 96, height = 96 } } }
      canvas.sanitize_dpi(img_96)
      assert.are.equal(96, img_96.info.dpi.width)
      assert.are.equal(96, img_96.info.dpi.height)

      local img_72 = { info = { dpi = { width = 72, height = 72 } } }
      canvas.sanitize_dpi(img_72)
      assert.are.equal(72, img_72.info.dpi.width)
      assert.are.equal(72, img_72.info.dpi.height)

      local img_150 = { info = { dpi = { width = 150, height = 150 } } }
      canvas.sanitize_dpi(img_150)
      assert.are.equal(150, img_150.info.dpi.width)
      assert.are.equal(150, img_150.info.dpi.height)
    end)

    it("safely handles nil, empty tables, and missing DPI structures", function()
      canvas = require("gelbooru.ui.canvas")
      assert.has_no.errors(function()
        canvas.sanitize_dpi(nil)
        canvas.sanitize_dpi({})
        canvas.sanitize_dpi({ info = nil })
        canvas.sanitize_dpi({ info = {} })
        canvas.sanitize_dpi({ info = { dpi = nil } })
        canvas.sanitize_dpi({ info = { dpi = {} } })
      end)
    end)
  end)

  describe("canvas.abort_convert: immediate conversion abort without delay timers", function()
    local sandbox_dir

    before_each(function()
      sandbox_dir = vim.fn.tempname()
      vim.fn.mkdir(sandbox_dir, "p")
    end)

    after_each(function()
      if sandbox_dir and vim.fn.isdirectory(sandbox_dir) == 1 then
        vim.fn.delete(sandbox_dir, "rf")
      end
    end)

    it("aborts in-flight conversion and unlinks partial 0-byte step files immediately", function()
      canvas = require("gelbooru.ui.canvas")
      local step1_file = sandbox_dir .. "/step1_incomplete.png"
      local step1_info = step1_file .. ".info"
      local step2_file = sandbox_dir .. "/step2_complete.png"

      vim.fn.writefile({}, step1_file)
      vim.fn.writefile({}, step1_info)
      vim.fn.writefile({ "complete payload" }, step2_file)

      local abort_called = false
      local mock_placement = {
        img = {
          _convert = {
            abort = function(self)
              self.aborted = true
              abort_called = true
            end,
            steps = {
              { file = step1_file },
              { file = step2_file },
            },
          },
        },
      }

      canvas.abort_convert(mock_placement)

      assert.is_true(abort_called)
      assert.are.equal(0, vim.fn.filereadable(step1_file))
      assert.are.equal(0, vim.fn.filereadable(step1_info))
      assert.are.equal(1, vim.fn.filereadable(step2_file))
      assert.is_nil(state.UI.abort_cleanup_timer)
    end)

    it("unlinks in-flight aborted step immediately without starting any delay timer", function()
      canvas = require("gelbooru.ui.canvas")
      local step_file = sandbox_dir .. "/inflight_step.png"
      local step_info = step_file .. ".info"
      local comp_file = sandbox_dir .. "/completed_step.png"

      vim.fn.writefile({ "partial data" }, step_file)
      vim.fn.writefile({ "info data" }, step_info)
      vim.fn.writefile({ "completed data" }, comp_file)

      local aborted = false
      local mock_placement = {
        img = {
          _convert = {
            _step = 1,
            abort = function(self)
              aborted = true
            end,
            steps = {
              { file = step_file, done = false },
              { file = comp_file, done = true },
            },
          },
        },
      }

      canvas.abort_convert(mock_placement)
      assert.is_true(aborted)
      assert.are.equal(0, vim.fn.filereadable(step_file))
      assert.are.equal(0, vim.fn.filereadable(step_info))
      assert.are.equal(1, vim.fn.filereadable(comp_file))
      assert.is_nil(state.UI.abort_cleanup_timer)
    end)

    it("safely handles nil or malformed placement objects", function()
      canvas = require("gelbooru.ui.canvas")
      assert.has_no.errors(function()
        canvas.abort_convert(nil)
        canvas.abort_convert({})
        canvas.abort_convert({ img = {} })
        canvas.abort_convert({ img = { _convert = {} } })
      end)
    end)
  end)

  describe("canvas.render: placement creation & lifecycle", function()
    local win
    local buf
    local test_image

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
      win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = 1,
        col = 1,
        width = 40,
        height = 20,
      })
      test_image = vim.fn.tempname() .. ".jpg"
      vim.fn.writefile({ "dummy image data" }, test_image)
    end)

    after_each(function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      if vim.fn.filereadable(test_image) == 1 then
        vim.fn.delete(test_image)
      end
    end)

    it("returns false for invalid window handle", function()
      canvas = require("gelbooru.ui.canvas")
      local ok = canvas.render(999999, test_image)
      assert.is_false(ok)
    end)

    it("creates a snacks placement, sets state.UI.current_placement, and attaches shielded keymaps", function()
      canvas = require("gelbooru.ui.canvas")
      local ok = canvas.render(win, test_image)
      assert.is_true(ok)
      assert.is_not_nil(state.UI.current_placement)
      assert.are.equal(test_image, state.UI.current_placement.src)

      local cur_buf = vim.api.nvim_win_get_buf(win)
      assert.is_true(vim.api.nvim_buf_is_valid(cur_buf))
      assert.is_true(vim.b[cur_buf].which_key_ignore == true)

      -- Verify browsing keymaps are attached to the image buffer
      local keymaps = vim.api.nvim_buf_get_keymap(cur_buf, "n")
      local map_keys = {}
      for _, km in ipairs(keymaps) do
        map_keys[km.lhs] = true
      end
      assert.is_true(map_keys["j"] == true)
      assert.is_true(map_keys["k"] == true)
      assert.is_true(map_keys["gg"] == true)
      assert.is_true(map_keys["G"] == true)
      assert.is_true(map_keys["r"] == true)
      assert.is_true(map_keys["R"] == true)
      assert.is_true(map_keys["m"] == true)
      assert.is_true(map_keys["u"] == true)
      assert.is_true(map_keys["o"] == true)
      assert.is_true(map_keys["O"] == true)
      assert.is_true(map_keys["<CR>"] == true)
      assert.is_true(map_keys["\\"] == true)
      assert.is_true(map_keys["q"] == true)
      assert.is_true(map_keys["<Esc>"] == true)
      assert.is_true(map_keys["/"] == true)
      assert.is_true(map_keys["i"] == true)
    end)

    it("reuses existing placement for same file_path via in-place nudge", function()
      canvas = require("gelbooru.ui.canvas")
      local ok1 = canvas.render(win, test_image)
      assert.is_true(ok1)
      local placement1 = state.UI.current_placement
      assert.is_not_nil(placement1)

      local updates_before = placement1.updated_count
      local ok2 = canvas.render(win, test_image)
      assert.is_true(ok2)
      assert.are.equal(placement1, state.UI.current_placement)
      assert.is_true(placement1.updated_count > updates_before)
    end)

    it("routes placement error cleanly without crashing", function()
      canvas = require("gelbooru.ui.canvas")
      local err_called = false
      local err_msg = nil
      local ok = canvas.render(win, test_image, {
        on_error = function(err)
          err_called = true
          err_msg = err
        end,
      })
      assert.is_true(ok)
      local placement = state.UI.current_placement
      assert.is_not_nil(placement)

      -- Trigger placement error
      placement:error()
      assert.is_true(err_called)
      assert.is_not_nil(err_msg)
    end)
  end)

  describe("canvas.close and canvas.nudge", function()
    local win
    local buf
    local test_image

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
      win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = 1,
        col = 1,
        width = 40,
        height = 20,
      })
      test_image = vim.fn.tempname() .. ".jpg"
      vim.fn.writefile({ "dummy image data" }, test_image)
    end)

    after_each(function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      if vim.fn.filereadable(test_image) == 1 then
        vim.fn.delete(test_image)
      end
    end)

    it("close cleans up current placement and resets state.UI.current_placement", function()
      canvas = require("gelbooru.ui.canvas")
      canvas.render(win, test_image)
      local placement = state.UI.current_placement
      assert.is_not_nil(placement)

      canvas.close()
      assert.is_nil(state.UI.current_placement)
      assert.is_true(placement.closed)
    end)

    it("close calls resolver.abort_video_transcodes()", function()
      canvas = require("gelbooru.ui.canvas")
      local resolver = require("gelbooru.media.resolver")
      local orig_abort = resolver.abort_video_transcodes
      local called = false
      resolver.abort_video_transcodes = function()
        called = true
      end
      canvas.close()
      resolver.abort_video_transcodes = orig_abort
      assert.is_true(called, "canvas.close must invoke resolver.abort_video_transcodes()")
    end)

    it("nudge returns false when no placement is active, true when active", function()
      canvas = require("gelbooru.ui.canvas")
      assert.is_false(canvas.nudge())

      canvas.render(win, test_image)
      local placement = state.UI.current_placement
      local count = placement.updated_count

      assert.is_true(canvas.nudge())
      assert.is_true(placement.updated_count > count)
    end)
  end)

  describe("canvas.render_placeholder", function()
    local win
    local buf

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
      win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = 1,
        col = 1,
        width = 40,
        height = 20,
      })
    end)

    after_each(function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end)

    it("renders simple text placeholder and attaches shielded keymaps", function()
      canvas = require("gelbooru.ui.canvas")
      canvas.render_placeholder(win, nil, "  Loading preview...")

      local cur_buf = vim.api.nvim_win_get_buf(win)
      local lines = vim.api.nvim_buf_get_lines(cur_buf, 0, -1, false)
      assert.are.equal("  Loading preview...", lines[1])
      assert.is_true(vim.b[cur_buf].which_key_ignore == true)
    end)

    it("renders rich video placeholder banner for video post", function()
      canvas = require("gelbooru.ui.canvas")
      local post = {
        id = 12345,
        file_url = "https://example.com/video.mp4",
        width = 1920,
        height = 1080,
      }
      canvas.render_placeholder(win, post, "Preview not playable in terminal")

      local cur_buf = vim.api.nvim_win_get_buf(win)
      local lines = vim.api.nvim_buf_get_lines(cur_buf, 0, -1, false)
      local content = table.concat(lines, "\n")
      assert.is_truthy(content:find("VIDEO FILE: MP4"))
      assert.is_truthy(content:find("1920x1080"))
      assert.is_truthy(content:find("12345"))
      assert.is_truthy(content:find("video.mp4"))
    end)
  end)

  describe("graphics backend dispatch (image_nvim vs snacks.image)", function()
    local win
    local buf
    local test_image

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
      win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = 1,
        col = 1,
        width = 40,
        height = 20,
      })
      test_image = vim.fn.tempname() .. ".jpg"
      vim.fn.writefile({ "dummy image data" }, test_image)
    end)

    after_each(function()
      config.options.backend = "snacks"
      package.loaded["image"] = nil
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      if vim.fn.filereadable(test_image) == 1 then
        vim.fn.delete(test_image)
      end
    end)

    it("dispatches to image.nvim when config.options.backend == 'image_nvim'", function()
      local rendered = false
      local cleared = false
      package.loaded["image"] = {
        from_file = function(path, opts)
          return {
            path = path,
            render = function(self) rendered = true end,
            clear = function(self) cleared = true end,
          }
        end,
      }

      config.options.backend = "image_nvim"
      canvas = require("gelbooru.ui.canvas")
      local ok = canvas.render(win, test_image)

      assert.is_true(ok)
      assert.is_true(rendered)
      assert.is_not_nil(state.UI.current_placement)

      canvas.close()
      assert.is_true(cleared)
      assert.is_nil(state.UI.current_placement)
    end)

    it("falls back to snacks.image when image.nvim is not available", function()
      package.loaded["image"] = nil
      config.options.backend = "image_nvim"

      canvas = require("gelbooru.ui.canvas")
      local ok = canvas.render(win, test_image)

      assert.is_true(ok)
      assert.is_not_nil(state.UI.current_placement)
      -- Verified snacks placement created as fallback
      assert.are.equal(test_image, state.UI.current_placement.src)
    end)
  end)
end)
