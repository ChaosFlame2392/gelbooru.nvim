# 02: Terminal Canvas Adapter & Placement Isolation

**What to build:** A standalone terminal canvas display adapter module (`lua/gelbooru/ui/canvas.lua`) that handles window graphics placement (`snacks.image` / `image.nvim`), DPI clamping, synchronous conversion abort cleanup without delay timers, placement error callbacks, placeholder rendering, and buffer keymap shielding. Takes a verified local path and target window handle without any knowledge of network fetching, curl retries, or video transcoding.

**Type:** task

**Status:** resolved

**Blocked by:** None

- [x] Create `lua/gelbooru/ui/canvas.lua` exposing `render(win, file_path)`, `render_placeholder(win, post, message)`, `nudge()`, and `close()`.
- [x] DPI sanitization clamps anomalous image DPI metadata (DPI >= 300) before placement creation.
- [x] Placement error events (`placement.error`) route cleanly to failure handlers without UI freezing.
- [x] Immediate in-flight conversion abortion without unmanaged timers: delete `UI.abort_cleanup_timer` and `constants.ABORT_CLEANUP_DELAY_MS`. Unlink partial files and clear in-memory image cache immediately.
- [x] Defensive buffer keymaps (j, k, gg, G, r, R, m, u, o, O, <CR>, \, q, <Esc>, /, i) and mouse events are attached and shielded via `util.shield_buffer`.
- [x] Unit and mock tests in `tests/unit/canvas_spec.lua` verify placement lifecycle, DPI sanitization, and keymap shielding.

## Answer

Implemented standalone terminal canvas display adapter in `lua/gelbooru/ui/canvas.lua`:
- `canvas.render(win, file_path, on_error)`: Validates window, ensures non-interactive shielded buffer, suppresses `snacks.image` progress bars, pre-sanitizes DPI before placement, hooks `placement.error` to `on_error` callback without freezing UI, tracks active placement in `state.UI.current_placement`, and attaches defensive keymaps.
- `canvas.render_placeholder(win, post, message)`: Renders formatted placeholder buffer lines (including rich video banner for video posts with filename, format, and hints) and attaches shielded keymaps.
- `canvas.nudge()`: Repositions active placement on window resize or layout adjustments.
- `canvas.close()`: Safely closes and detaches active placement handle and clears `state.UI.current_placement`.
- `canvas.sanitize_dpi(img)`: Clamps anomalous or corrupt DPI metadata (DPI >= 300 or < 50, or unbalanced axis DPI) to standard 96x96 before image dimensions cause rendering distortion or crashes.
- `canvas.abort_convert(placement)`: Performs immediate, synchronous in-flight conversion abortion without unmanaged timers; deletes partial 0-byte conversion artifacts immediately and clears in-memory image cache. Eliminated `UI.abort_cleanup_timer` and `constants.ABORT_CLEANUP_DELAY_MS`.
- `canvas.attach_defensive_keymaps(buf)`: Installs browsing keymaps (`j`, `k`, `gg`, `G`, `r`, `R`, `m`, `u`, `o`, `O`, `<CR>`, `\`, `q`, `<Esc>`, `/`, `i`) and mouse click handlers, shielded against key leaking via `util.shield_buffer`.
- Verified with 17 test cases in `tests/unit/canvas_spec.lua` and full test suite passing cleanly with 0 failures / 0 errors.
