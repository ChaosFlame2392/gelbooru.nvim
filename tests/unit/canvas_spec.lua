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

  describe("driver interface & 3-method seam", function()
    it("exposes display, abort, clear, nudge and backwards-compatible aliases", function()
      canvas = require("gelbooru.ui.canvas")
      assert.is_function(canvas.display)
      assert.is_function(canvas.abort)
      assert.is_function(canvas.clear)
      assert.is_function(canvas.nudge)
      assert.are.equal(canvas.display, canvas.render)
      assert.are.equal(canvas.clear, canvas.close)
    end)
  end)

  describe("canvas.detect_capabilities: terminal capability probe", function()
    before_each(function()
      config.options.backend = "auto"
      canvas = require("gelbooru.ui.canvas")
    end)

    after_each(function()
      config.options.backend = "auto"
    end)

    it("detects Ghostty 1.4 via GHOSTTY_VERSION", function()
      local cap = canvas.detect_capabilities({ GHOSTTY_VERSION = "1.4.0" })
      assert.are.equal("ghostty", cap.terminal)
      assert.is_true(cap.is_kitty_compliant)
      assert.is_true(cap.has_placeholders)
      assert.is_false(cap.has_tmux)
      assert.are.equal("native", cap.driver)
    end)

    it("detects Ghostty via TERM=xterm-ghostty", function()
      local cap = canvas.detect_capabilities({ TERM = "xterm-ghostty" })
      assert.are.equal("ghostty", cap.terminal)
      assert.is_true(cap.is_kitty_compliant)
      assert.is_true(cap.has_placeholders)
      assert.are.equal("native", cap.driver)
    end)

    it("detects Kitty via KITTY_WINDOW_ID", function()
      local cap = canvas.detect_capabilities({ KITTY_WINDOW_ID = "42" })
      assert.are.equal("kitty", cap.terminal)
      assert.is_true(cap.is_kitty_compliant)
      assert.is_true(cap.has_placeholders)
      assert.are.equal("native", cap.driver)
    end)

    it("detects Kitty via TERM=xterm-kitty", function()
      local cap = canvas.detect_capabilities({ TERM = "xterm-kitty" })
      assert.are.equal("kitty", cap.terminal)
      assert.is_true(cap.is_kitty_compliant)
      assert.is_true(cap.has_placeholders)
      assert.are.equal("native", cap.driver)
    end)

    it("detects Ghostty with tmux passthrough when TMUX is set", function()
      local cap = canvas.detect_capabilities({
        TMUX = "/tmp/tmux-501/default,1234,0",
        GHOSTTY_VERSION = "1.4.0",
      })
      assert.are.equal("ghostty", cap.terminal)
      assert.is_true(cap.is_kitty_compliant)
      assert.is_true(cap.has_placeholders)
      assert.is_true(cap.has_tmux)
      assert.are.equal("native", cap.driver)
    end)

    it("falls back to snacks for WezTerm (no Unicode placeholders support)", function()
      local cap = canvas.detect_capabilities({
        TERM_PROGRAM = "WezTerm",
        WEZTERM_PANE = "1",
      })
      assert.are.equal("wezterm", cap.terminal)
      assert.is_false(cap.is_kitty_compliant)
      assert.is_false(cap.has_placeholders)
      assert.are.equal("snacks", cap.driver)
    end)

    it("falls back to snacks for unknown / generic xterm terminals", function()
      local cap = canvas.detect_capabilities({
        TERM = "xterm-256color",
      })
      assert.are.equal("unknown", cap.terminal)
      assert.is_false(cap.is_kitty_compliant)
      assert.is_false(cap.has_placeholders)
      assert.are.equal("snacks", cap.driver)
    end)

    it("honors user override backend='snacks' even on Ghostty", function()
      config.options.backend = "snacks"
      local cap = canvas.detect_capabilities({ GHOSTTY_VERSION = "1.4.0" })
      assert.are.equal("ghostty", cap.terminal)
      assert.are.equal("snacks", cap.driver)
    end)

    it("honors user override backend='ghostty' or 'kitty' even on unknown terminal", function()
      config.options.backend = "ghostty"
      local cap1 = canvas.detect_capabilities({ TERM = "xterm-256color" })
      assert.are.equal("native", cap1.driver)

      config.options.backend = "kitty"
      local cap2 = canvas.detect_capabilities({ TERM = "xterm-256color" })
      assert.are.equal("native", cap2.driver)
    end)
  end)

  describe("Kitty protocol sequence formatting & tmux wrapping", function()
    before_each(function()
      canvas = require("gelbooru.ui.canvas")
    end)

    it("formats control sequences with and without payload", function()
      local seq_no_data = canvas.format_sequence("a=p,U=1,i=1,p=1,C=1,c=40,r=20,q=2")
      assert.are.equal("\027_Ga=p,U=1,i=1,p=1,C=1,c=40,r=20,q=2\027\\", seq_no_data)

      local seq_with_data = canvas.format_sequence("a=t,t=f,f=100,i=1,q=2", "L3BhdGgvdG8vaW1hZ2U=")
      assert.are.equal("\027_Ga=t,t=f,f=100,i=1,q=2;L3BhdGgvdG8vaW1hZ2U=\027\\", seq_with_data)
    end)

    it("formats table parameters deterministically with default q=2", function()
      local seq = canvas.format_sequence({
        a = "t",
        t = "f",
        f = 100,
        i = 5,
      }, "ZGF0YQ==")
      assert.is_truthy(seq:find("^\027_G"))
      assert.is_truthy(seq:find("\027\\$"))
      assert.is_truthy(seq:find(";ZGF0YQ=="))
      assert.is_truthy(seq:find("a=t"))
      assert.is_truthy(seq:find("t=f"))
      assert.is_truthy(seq:find("f=100"))
      assert.is_truthy(seq:find("i=5"))
      assert.is_truthy(seq:find("q=2"))
    end)

    it("formats delete command to immediately free terminal graphics RAM", function()
      local del_seq = canvas.format_delete_sequence(42)
      assert.are.equal("\027_Ga=d,d=i,i=42,q=2\027\\", del_seq)
    end)

    it("wraps Kitty control sequence in DCS passthrough for tmux by doubling escape bytes", function()
      local raw = "\027_Ga=d,d=i,i=42,q=2\027\\"
      local wrapped = canvas.wrap_tmux(raw)
      assert.are.equal("\027Ptmux;\027\027_Ga=d,d=i,i=42,q=2\027\027\\\027\\", wrapped)
    end)

    it("encodes file paths to base64 accurately", function()
      local encoded = canvas.base64_encode("/tmp/test/img.png")
      assert.is_string(encoded)
      assert.is_true(#encoded > 0)
      if vim.base64 and vim.base64.decode then
        assert.are.equal("/tmp/test/img.png", vim.base64.decode(encoded))
      end
    end)
  end)

  describe("Unicode placeholder grid & highlight group generation", function()
    before_each(function()
      canvas = require("gelbooru.ui.canvas")
    end)

    it("generates placeholder grid with correct rows, columns, and diacritic coordinates", function()
      local cols = 4
      local rows = 3
      local lines = canvas.generate_placeholder_grid(cols, rows)

      assert.are.equal(rows, #lines)
      for r = 1, rows do
        assert.is_string(lines[r])
        -- Each cell contains PLACEHOLDER (U+10EEEE) plus 2 diacritics
        local count = 0
        for _ in lines[r]:gmatch(vim.fn.nr2char(0x10EEEE)) do
          count = count + 1
        end
        assert.are.equal(cols, count)
      end
    end)

    it("creates highlight group pairing fg=image_id, sp=placement_id with nocombine=true", function()
      local image_id = 123
      local placement_id = 456
      local hl_group = canvas.create_native_highlight(image_id, placement_id)

      assert.is_string(hl_group)
      assert.is_truthy(hl_group:find(tostring(image_id)))
      assert.is_truthy(hl_group:find(tostring(placement_id)))

      local hl = vim.api.nvim_get_hl(0, { name = hl_group })
      assert.are.equal(image_id, hl.fg)
      assert.are.equal(placement_id, hl.sp)
      assert.is_true(hl.nocombine)
    end)
  end)

  describe("native Ghostty / Kitty driver: static PNG/JPEG fast path & GPU cleanup", function()
    local win
    local buf
    local test_image

    before_each(function()
      config.options.backend = "ghostty"
      buf = vim.api.nvim_create_buf(false, true)
      win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = 1,
        col = 1,
        width = 40,
        height = 20,
      })
      test_image = vim.fn.tempname() .. ".png"
      vim.fn.writefile({ "PNG fake data" }, test_image)
      canvas = require("gelbooru.ui.canvas")
      canvas._last_written = {}
    end)

    after_each(function()
      config.options.backend = "auto"
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

    it("transmits file directly via t=f fast path and generates Unicode placeholders", function()
      local ok = canvas.display(win, test_image)
      assert.is_true(ok)

      local placement = state.UI.current_placement
      assert.is_not_nil(placement)
      assert.are.equal(test_image, placement.src)
      assert.is_true(placement.is_native)
      assert.is_number(placement.image_id)

      -- Verify sequences sent: transmit (a=t, t=f) and placement (a=p, U=1)
      local all_seqs = table.concat(canvas._last_written or {}, "\n")
      assert.is_truthy(all_seqs:find("a=t"))
      assert.is_truthy(all_seqs:find("t=f"))
      assert.is_truthy(all_seqs:find("f=100"))
      assert.is_truthy(all_seqs:find("a=p"))
      assert.is_truthy(all_seqs:find("U=1"))

      -- Verify base64 path is in transmit sequence
      local b64 = canvas.base64_encode(test_image)
      assert.is_truthy(all_seqs:find(b64, 1, true))

      -- Verify buffer contains Unicode placeholders
      local cur_buf = vim.api.nvim_win_get_buf(win)
      local lines = vim.api.nvim_buf_get_lines(cur_buf, 0, -1, false)
      assert.is_true(#lines > 0)
      assert.is_truthy(lines[1]:find(vim.fn.nr2char(0x10EEEE)))

      -- Verify defensive keymaps attached
      assert.is_true(vim.b[cur_buf].which_key_ignore == true)
    end)

    it("wraps transmission sequences in tmux DCS passthrough when TMUX environment is detected", function()
      -- Mock environment with TMUX
      local orig_detect = canvas.detect_capabilities
      canvas.detect_capabilities = function()
        return {
          terminal = "ghostty",
          is_kitty_compliant = true,
          has_placeholders = true,
          has_tmux = true,
          driver = "native",
        }
      end

      local ok = canvas.display(win, test_image)
      canvas.detect_capabilities = orig_detect
      assert.is_true(ok)

      local all_seqs = table.concat(canvas._last_written or {}, "\n")
      assert.is_truthy(all_seqs:find("\027Ptmux;"))
      assert.is_truthy(all_seqs:find("\027\027_G"))
      assert.is_truthy(all_seqs:find("\027\027\\\027\\"))
    end)

    it("frees terminal GPU textures (a=d, d=i, i=ID) immediately on clear()", function()
      local ok = canvas.display(win, test_image)
      assert.is_true(ok)
      local placement = state.UI.current_placement
      local img_id = placement.image_id

      canvas._last_written = {}
      canvas.clear()

      assert.is_nil(state.UI.current_placement)
      assert.is_true(placement.closed)

      local all_seqs = table.concat(canvas._last_written or {}, "\n")
      assert.is_truthy(all_seqs:find("a=d"))
      assert.is_truthy(all_seqs:find("d=i"))
      assert.is_truthy(all_seqs:find("i=" .. tostring(img_id)))
    end)

    it("nudges placement on window resize, updating placeholder grid", function()
      local ok = canvas.display(win, test_image)
      assert.is_true(ok)
      local placement = state.UI.current_placement
      local old_count = placement.updated_count

      canvas._last_written = {}
      local nudged = canvas.nudge()
      assert.is_true(nudged)
      assert.is_true(placement.updated_count > old_count)

      local all_seqs = table.concat(canvas._last_written or {}, "\n")
      assert.is_truthy(all_seqs:find("a=p"))
      assert.is_truthy(all_seqs:find("U=1"))
    end)

    it("omits f=100 for JPEG files allowing terminal auto-detection", function()
      local jpg_image = vim.fn.tempname() .. ".jpg"
      vim.fn.writefile({ "JPEG fake data" }, jpg_image)

      local ok = canvas.display(win, jpg_image)
      assert.is_true(ok)

      local all_seqs = table.concat(canvas._last_written or {}, "\n")
      assert.is_truthy(all_seqs:find("a=t"))
      assert.is_truthy(all_seqs:find("t=f"))
      assert.is_falsy(all_seqs:find("f=100"))

      vim.fn.delete(jpg_image)
    end)

    it("does not force artificial 96 DPI clamping on native placement", function()
      local ok = canvas.display(win, test_image)
      assert.is_true(ok)
      local placement = state.UI.current_placement
      assert.is_not_nil(placement)
      if placement.img and placement.img.info then
        assert.is_nil(placement.img.info.dpi)
      end
    end)

    it("bounds _last_written ring buffer to MAX_LAST_WRITTEN entries", function()
      canvas._last_written = {}
      for i = 1, 65 do
        canvas.write_sequence(string.format("test_seq_%d", i))
      end
      assert.are.equal(50, #canvas._last_written)
      assert.are.equal("test_seq_65", canvas._last_written[#canvas._last_written])
      assert.are.equal("test_seq_16", canvas._last_written[1])
    end)

    it("canvas.abort(win) respects win argument and only aborts matching window", function()
      local ok = canvas.display(win, test_image)
      assert.is_true(ok)
      assert.is_not_nil(state.UI.current_placement)

      -- Different window should NOT abort
      canvas.abort(win + 999)
      assert.is_not_nil(state.UI.current_placement)

      -- Matching window should abort
      canvas.abort(win)
      assert.is_nil(state.UI.current_placement)
    end)

    it("sets window buffer before deleting superseded buffer to prevent invalid buffer pointer", function()
      local ok1 = canvas.display(win, test_image)
      assert.is_true(ok1)
      local first_buf = vim.api.nvim_win_get_buf(win)
      assert.is_true(vim.api.nvim_buf_is_valid(first_buf))

      local test_image2 = vim.fn.tempname() .. ".png"
      vim.fn.writefile({ "PNG fake 2" }, test_image2)

      local set_buf_order = {}
      local orig_set_buf = vim.api.nvim_win_set_buf
      local orig_buf_delete = vim.api.nvim_buf_delete

      vim.api.nvim_win_set_buf = function(w, b)
        table.insert(set_buf_order, { action = "set_buf", win = w, buf = b })
        return orig_set_buf(w, b)
      end
      vim.api.nvim_buf_delete = function(b, opts)
        table.insert(set_buf_order, { action = "delete_buf", buf = b })
        return orig_buf_delete(b, opts)
      end

      local ok2 = canvas.display(win, test_image2)
      vim.api.nvim_win_set_buf = orig_set_buf
      vim.api.nvim_buf_delete = orig_buf_delete

      assert.is_true(ok2)
      local set_idx = nil
      local del_idx = nil
      for idx, ev in ipairs(set_buf_order) do
        if ev.action == "set_buf" and ev.buf ~= first_buf then
          set_idx = set_idx or idx
        elseif ev.action == "delete_buf" and ev.buf == first_buf then
          del_idx = del_idx or idx
        end
      end

      assert.is_not_nil(set_idx, "New buffer must be set in window")
      if del_idx then
        assert.is_true(set_idx < del_idx, "nvim_win_set_buf must happen before superseded buffer deletion")
      end

      vim.fn.delete(test_image2)
    end)
  end)

  describe("native Ghostty / Kitty driver: multi-frame animated GIF path", function()
    local win
    local buf
    local gif_path
    local anim_dir

    before_each(function()
      config.options.backend = "ghostty"
      buf = vim.api.nvim_create_buf(false, true)
      win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = 1,
        col = 1,
        width = 40,
        height = 20,
      })
      gif_path = vim.fn.tempname() .. ".gif"
      vim.fn.writefile({ "GIF89a fake animated gif" }, gif_path)

      -- Pre-create coalesced frame files in cache for fast deterministic testing
      local base = vim.fn.fnamemodify(gif_path, ":t:r")
      anim_dir = config.options.cache_dir .. "/anim_" .. base
      vim.fn.mkdir(anim_dir, "p")
      vim.fn.writefile({ "frame 0" }, anim_dir .. "/frame_000.png")
      vim.fn.writefile({ "frame 1" }, anim_dir .. "/frame_001.png")
      vim.fn.writefile({ "frame 2" }, anim_dir .. "/frame_002.png")

      canvas = require("gelbooru.ui.canvas")
      canvas._last_written = {}
    end)

    after_each(function()
      config.options.backend = "auto"
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      if vim.fn.filereadable(gif_path) == 1 then
        vim.fn.delete(gif_path)
      end
      if anim_dir and vim.fn.isdirectory(anim_dir) == 1 then
        vim.fn.delete(anim_dir, "rf")
      end
    end)

    it("coalesces frames, transmits base frame (a=t), subsequent frames (a=f), placement (a=p), and loop (a=a)", function()
      -- Mock is_gif_animated returning true
      local resolver = require("gelbooru.media.resolver")
      local orig_is_anim = resolver.is_gif_animated
      resolver.is_gif_animated = function(path)
        if path == gif_path then
          return true
        end
        return false
      end

      local ok = canvas.display(win, gif_path)
      resolver.is_gif_animated = orig_is_anim
      assert.is_true(ok)

      local placement = state.UI.current_placement
      assert.is_not_nil(placement)
      assert.is_true(placement.is_animated)

      local all_seqs = table.concat(canvas._last_written or {}, "\n")

      -- Base frame: a=t, t=f, z=DELAY
      assert.is_truthy(all_seqs:find("a=t"))
      assert.is_truthy(all_seqs:find("z="))

      -- Subsequent frames: a=f, t=f, z=DELAY
      assert.is_truthy(all_seqs:find("a=f"))

      -- Placement: a=p, U=1
      assert.is_truthy(all_seqs:find("a=p"))
      assert.is_truthy(all_seqs:find("U=1"))

      -- Hardware loop control: a=a, s=3, v=1
      assert.is_truthy(all_seqs:find("a=a"))
      assert.is_truthy(all_seqs:find("s=3"))
      assert.is_truthy(all_seqs:find("v=1"))
      assert.is_falsy(all_seqs:find("s=2"))
      assert.is_falsy(all_seqs:find("v=0"))

      -- Verify buffer contains Unicode placeholders
      local cur_buf = vim.api.nvim_win_get_buf(win)
      local lines = vim.api.nvim_buf_get_lines(cur_buf, 0, -1, false)
      assert.is_true(#lines > 0)
      assert.is_truthy(lines[1]:find(vim.fn.nr2char(0x10EEEE)))

      -- Verify zero Lua timer is allocated for animation
      assert.is_nil(state.UI.animation_timer)
    end)

    it("extracts frames asynchronously via transcoder when not cached", function()
      local gif_test = vim.fn.tempname() .. ".gif"
      vim.fn.writefile({ "GIF89a async test" }, gif_test)

      local base = vim.fn.fnamemodify(gif_test, ":t:r")
      local a_dir = config.options.cache_dir .. "/anim_" .. base
      if vim.fn.isdirectory(a_dir) == 1 then
        vim.fn.delete(a_dir, "rf")
      end

      local resolver = require("gelbooru.media.resolver")
      local orig_is_anim = resolver.is_gif_animated
      resolver.is_gif_animated = function(p) return p == gif_test end

      local transcoder = require("gelbooru.media.transcoder")
      local orig_coalesce = transcoder.coalesce_animation_frames
      local coalesce_called = false
      local coalesce_cb = nil

      transcoder.coalesce_animation_frames = function(media, out_dir, cb)
        coalesce_called = true
        coalesce_cb = cb
        return { kill = function() end }
      end

      local ok = canvas.display(win, gif_test)
      assert.is_true(ok)
      assert.is_true(coalesce_called)

      -- Placeholder shown while extracting
      local cur_buf = vim.api.nvim_win_get_buf(win)
      local lines = vim.api.nvim_buf_get_lines(cur_buf, 0, -1, false)
      assert.is_truthy(table.concat(lines, "\n"):find("Extracting animation frames"))

      -- Now complete async extraction
      local base = vim.fn.fnamemodify(gif_test, ":t:r")
      local a_dir = config.options.cache_dir .. "/anim_" .. base
      vim.fn.mkdir(a_dir, "p")
      local f0 = a_dir .. "/frame_000.png"
      local f1 = a_dir .. "/frame_001.png"
      vim.fn.writefile({ "f0" }, f0)
      vim.fn.writefile({ "f1" }, f1)

      coalesce_cb(true, { f0, f1 })

      -- Now placement is active and animated
      local p = state.UI.current_placement
      assert.is_not_nil(p)
      assert.is_true(p.is_animated)

      transcoder.coalesce_animation_frames = orig_coalesce
      resolver.is_gif_animated = orig_is_anim
      vim.fn.delete(gif_test)
      vim.fn.delete(a_dir, "rf")
    end)

    it("does not transmit or create placement when extraction fails or aborts with cb(false, nil)", function()
      local gif_fail = vim.fn.tempname() .. ".gif"
      vim.fn.writefile({ "GIF89a fail test" }, gif_fail)

      local resolver = require("gelbooru.media.resolver")
      local orig_is_anim = resolver.is_gif_animated
      resolver.is_gif_animated = function(p) return p == gif_fail end

      local transcoder = require("gelbooru.media.transcoder")
      local orig_coalesce = transcoder.coalesce_animation_frames
      transcoder.coalesce_animation_frames = function(media, out_dir, cb)
        cb(false, nil)
        return nil
      end

      canvas._last_written = {}
      state.UI.current_placement = nil

      local ok = canvas.display(win, gif_fail)
      assert.is_true(ok)

      -- Placement must NOT be created for failed/aborted extraction
      assert.is_nil(state.UI.current_placement)

      -- No transmit or loop sequence written
      local all_seqs = table.concat(canvas._last_written or {}, "\n")
      assert.is_falsy(all_seqs:find("s=3"))
      assert.is_falsy(all_seqs:find("v=1"))

      transcoder.coalesce_animation_frames = orig_coalesce
      resolver.is_gif_animated = orig_is_anim
      vim.fn.delete(gif_fail)
    end)

    it("guards against superseded extraction callback when canvas.abort is invoked", function()
      local gif_abort = vim.fn.tempname() .. ".gif"
      vim.fn.writefile({ "GIF89a abort test" }, gif_abort)

      local resolver = require("gelbooru.media.resolver")
      local orig_is_anim = resolver.is_gif_animated
      resolver.is_gif_animated = function(p) return p == gif_abort end

      local transcoder = require("gelbooru.media.transcoder")
      local orig_coalesce = transcoder.coalesce_animation_frames
      local saved_cb = nil
      transcoder.coalesce_animation_frames = function(media, out_dir, cb)
        saved_cb = cb
        return { kill = function() end }
      end

      canvas._last_written = {}
      state.UI.current_placement = nil

      local ok = canvas.display(win, gif_abort)
      assert.is_true(ok)
      assert.is_not_nil(saved_cb)

      -- User navigates away, triggering canvas.abort()
      canvas.abort(win)
      canvas._last_written = {}

      -- Late callback arrives after abort
      saved_cb(true, { "/tmp/fake_frame_000.png" })

      -- Stale callback must be ignored and not create placement
      assert.is_nil(state.UI.current_placement)
      local all_seqs = table.concat(canvas._last_written or {}, "\n")
      assert.is_falsy(all_seqs:find("s=3"))

      transcoder.coalesce_animation_frames = orig_coalesce
      resolver.is_gif_animated = orig_is_anim
      vim.fn.delete(gif_abort)
    end)
  end)

  describe("format_media_transmission helper", function()
    it("formats base frame and subsequent frames with proper action and format code", function()
      canvas = require("gelbooru.ui.canvas")
      local fmt = canvas._format_media_transmission
      assert.is_not_nil(fmt)

      -- PNG base frame with delay
      local png_base = fmt("/path/to/frame.png", 42, false, 80)
      assert.is_truthy(png_base:find("a=t"))
      assert.is_truthy(png_base:find("t=f"))
      assert.is_truthy(png_base:find("f=100"))
      assert.is_truthy(png_base:find("i=42"))
      assert.is_truthy(png_base:find("z=80"))
      assert.is_truthy(png_base:find("q=2"))

      -- PNG subsequent frame with delay
      local png_sub = fmt("/path/to/frame2.png", 42, true, 80)
      assert.is_truthy(png_sub:find("a=f"))
      assert.is_truthy(png_sub:find("t=f"))
      assert.is_truthy(png_sub:find("f=100"))
      assert.is_truthy(png_sub:find("i=42"))
      assert.is_truthy(png_sub:find("z=80"))

      -- JPEG image without delay (auto-detect format, omit f=100)
      local jpg_seq = fmt("/path/to/image.jpg", 99, false, nil)
      assert.is_truthy(jpg_seq:find("a=t"))
      assert.is_truthy(jpg_seq:find("t=f"))
      assert.is_falsy(jpg_seq:find("f=100"))
      assert.is_truthy(jpg_seq:find("i=99"))
      assert.is_falsy(jpg_seq:find("z="))
    end)
  end)

  describe("canvas.clean_cache graphics artifact encapsulation", function()
    local tmp_dir
    local orig_snacks_cache

    before_each(function()
      tmp_dir = vim.fn.tempname()
      vim.fn.mkdir(tmp_dir .. "/snacks_cache", "p")
      local resolver = require("gelbooru.media.resolver")
      orig_snacks_cache = resolver._snacks_cache_dir
      resolver._snacks_cache_dir = tmp_dir .. "/snacks_cache"
    end)

    after_each(function()
      local resolver = require("gelbooru.media.resolver")
      resolver._snacks_cache_dir = orig_snacks_cache
      if tmp_dir and vim.fn.isdirectory(tmp_dir) == 1 then
        vim.fn.delete(tmp_dir, "rf")
      end
    end)

    it("cleans 0-byte files and corrupt .info files while preserving valid cache", function()
      canvas = require("gelbooru.ui.canvas")
      local resolver = require("gelbooru.media.resolver")

      local c0 = tmp_dir .. "/snacks_cache/zero-byte.jpg"
      vim.fn.writefile({}, c0)
      local err_info = tmp_dir .. "/snacks_cache/error.info"
      vim.fn.writefile({ "identify: improper image header" }, err_info)
      local valid_f = tmp_dir .. "/snacks_cache/valid.jpg"
      vim.fn.writefile({ "valid content header" }, valid_f)

      assert.are.equal(1, vim.fn.filereadable(c0))
      assert.are.equal(1, vim.fn.filereadable(err_info))
      assert.are.equal(1, vim.fn.filereadable(valid_f))

      -- Clean zero-byte
      local res0 = canvas.clean_cache("zero-byte")
      assert.is_true(res0)
      assert.are.equal(0, vim.fn.filereadable(c0))

      -- Clean error info
      local res_err = canvas.clean_cache("error")
      assert.is_true(res_err)
      assert.are.equal(0, vim.fn.filereadable(err_info))

      -- Valid cache remains untouched
      assert.are.equal(1, vim.fn.filereadable(valid_f))

      -- resolver.clean_corrupt_snacks_cache delegates to canvas.clean_cache
      local c0_b = tmp_dir .. "/snacks_cache/zero-byte-2.jpg"
      vim.fn.writefile({}, c0_b)
      assert.are.equal(1, vim.fn.filereadable(c0_b))
      local del_res = resolver.clean_corrupt_snacks_cache("zero-byte-2")
      assert.is_true(del_res)
      assert.are.equal(0, vim.fn.filereadable(c0_b))
    end)
  end)

  describe("graphics backend dispatch (snacks adapter)", function()
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
      config.options.backend = "auto"
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

    it("dispatches to snacks.image for snacks or auto backend", function()
      config.options.backend = "snacks"
      canvas = require("gelbooru.ui.canvas")
      local ok = canvas.render(win, test_image)

      assert.is_true(ok)
      assert.is_not_nil(state.UI.current_placement)
      assert.are.equal(test_image, state.UI.current_placement.src)
    end)

    it("ignores third-party image package if present in runtime", function()
      package.loaded["image"] = {
        from_file = function()
          error("legacy image package should never be invoked")
        end,
      }

      config.options.backend = "snacks"
      canvas = require("gelbooru.ui.canvas")
      local ok = canvas.render(win, test_image)

      assert.is_true(ok)
      assert.is_not_nil(state.UI.current_placement)
      assert.are.equal(test_image, state.UI.current_placement.src)

      package.loaded["image"] = nil
    end)
  end)
end)
