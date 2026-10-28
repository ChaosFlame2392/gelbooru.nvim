# 04: Ghostty 1.4 / Kitty Native Graphics Driver & Canvas Seam Deepening

**What to build:** Deepen `lua/gelbooru/ui/canvas.lua` behind a clean 3-method interface (`display`, `abort`, `clear`). Implement a native Ghostty 1.4 / Kitty Graphics Protocol driver that uses Unicode placeholders and direct file transmission (`t=f`) or animation control (`a=f`, `a=a`) for GIFs, bypassing ImageMagick conversion overhead. Maintain seamless fallback to Snacks for non-Kitty terminals.

**Type:** task

**Status:** resolved

**Blocked by:** 03

### Prototype Findings & Validated Decision:
- **Verdict:** Ghostty 1.4 native Kitty graphics animation (`a=f`, `a=a`) and Unicode placeholders (`U=1`) through tmux 3.8 (`allow-passthrough all`) was verified live on-screen via `scripts/prototype_ghostty_tmux.lua`.
- **Protocol details validated:**
  - Base frame: `a=t, t=f, f=100, i=ID, z=DELAY, data=PATH`
  - Subsequent frames: `a=f, t=f, f=100, i=ID, z=DELAY, data=PATH`
  - Placement: `a=p, U=1, i=ID, p=PID, C=1, c=COLS, r=ROWS`
  - Hardware loop control: `a=a, i=ID, s=2, v=0`
  - Highlight pairing: `fg=ID, sp=PID` applied to `PLACEHOLDER` (`0x10EEEE`) grid with diacritic coordinates.
  - Zero Neovim CPU usage during animation loop (handled entirely in terminal GPU clock).

### Scope & Technical Decisions:
1. **Engine Interface Seam (`lua/gelbooru/ui/canvas.lua`)**:
   - Deepen `canvas.lua` into a unified driver interface exposing three core methods:
     - `display(win, file_path, opts)`: Displays verified image or animation in floating window.
     - `abort()`: Synchronously aborts in-flight conversions/transfers and clears placement handles.
     - `clear()`: Purges graphics placement and frees terminal GPU textures (`a=d, d=i, i=ID`).
   - Retain existing aliases (`render = display`, `close = clear`) for backwards compatibility with existing UI callers (`ui/render.lua`, `ui/lifecycle.lua`).

2. **Native Ghostty 1.4 / Kitty Driver**:
   - Fast path for static PNG and JPEG:
     - Transmits file directly via `a=t, t=f, f=100, i=ID, data=base64(path)` (and `a=p, U=1, i=ID, p=PID, C=1, c=width, r=height`).
     - Bypasses intermediate ImageMagick disk rasterization in Ghostty (~725 MB/s parsing).
   - Multi-frame GIF animation path:
     - When `media.inspector.is_gif_animated(path)` is true, coalesces frames via `magick` into cache, transmits base frame (`a=t`) and subsequent frames (`a=f`), creates Unicode placement (`a=p, U=1`), and starts loop playback (`a=a, s=2, v=0`).
     - Emits Unicode placeholder characters (`0x10EEEE` + row/col diacritics) into the canvas buffer.
     - Highlight group maps `fg = ID` and `sp = PID` with `nocombine = true`.
     - Animation runs at 60 FPS in Ghostty hardware without any Lua timer loop in Neovim.

3. **Tmux Passthrough Wrapping**:
   - Detects `$TMUX` and wraps all Kitty control sequences in DCS passthrough: `\027Ptmux;\027\027_G...\027\027\\\027\\`.
   - Sends sequences via `vim.api.nvim_ui_send` for non-interfering TUI transmission.

4. **Snacks Fallback Adapter**:
   - For WezTerm, iTerm2, Alacritty, or non-Kitty terminals, automatically delegates to `snacks.image.placement`.
   - User override supported via `config.options.backend = "snacks"` or `"auto"`.

5. **Testing Protocol**:
   - Unit tests in `tests/unit/canvas_spec.lua` covering driver selection, sequence formatting, tmux wrapping, and placeholder grid generation.
   - Integration tests in `tests/integration/layout_spec.lua` and `tests/integration/regressions_spec.lua` verifying placement lifecycle, window resize nudges, and teardown.

### Acceptance Criteria:
- [x] Capability detection detects Ghostty 1.4, Kitty, and tmux passthrough.
- [x] Static PNG/JPEG fast path transmits directly via `t=f` with Unicode placeholders (`U=1`).
- [x] Multi-frame animated GIFs play smoothly via native Kitty animation (`a=f`, `a=a`) without Neovim CPU loops.
- [x] Snacks adapter cleanly handles fallback for non-Kitty terminals.
- [x] Closing or navigating posts immediately frees GPU memory (`a=d, d=i, i=ID`).
- [x] `make test` runs 100% green with zero errors or failures.

## Answer

### Implementation Summary
Ticket 04 deepens `lua/gelbooru/ui/canvas.lua` behind a unified 3-method interface (`display`, `abort`, `clear`), providing a native Ghostty 1.4 / Kitty Graphics Protocol driver alongside the encapsulated Snacks fallback adapter.

1. **Capability Detection & Environment Probe**:
   - Implemented `detect_capabilities(env)` in `canvas.lua` detecting Ghostty (`GHOSTTY_VERSION`, `TERM=xterm-ghostty`, `TERM_PROGRAM=ghostty`), Kitty (`KITTY_WINDOW_ID`, `TERM=xterm-kitty`, `TERM_PROGRAM=kitty`), WezTerm (`WEZTERM_PANE`), and tmux passthrough (`$TMUX`, `TERM=tmux`).
   - Normalizes driver selection with `config.options.backend` ("ghostty", "kitty", "snacks", "auto").

2. **Kitty Protocol Control Sequences & Tmux DCS Passthrough**:
   - Implemented deterministic sequence formatting: `format_sequence(params, payload)`.
   - Implemented DCS tmux passthrough wrapper: `wrap_tmux(seq)` wrapping `\027Ptmux;\027\027_G...\027\027\\\027\\` by doubling escape bytes.
   - Implemented `format_delete_sequence(image_id)` generating `a=d, d=i, i=ID, q=2` to immediately free terminal graphics RAM.
   - Implemented `write_sequence(seq, has_tmux)` sending via `vim.api.nvim_ui_send` (or stdout fallback).

3. **Unicode Placeholders & Highlight Group Generation**:
   - Populated standard Kitty 244-entry diacritic table and mapped combining diacritics starting at `U+0305`.
   - Implemented `generate_placeholder_grid(cols, rows)` generating rows of `0x10EEEE` with row and column coordinate diacritics.
   - Implemented `create_native_highlight(image_id, placement_id)` binding `fg = image_id, sp = placement_id, nocombine = true`.

4. **Static PNG / JPEG Fast Path**:
   - Emits `a=t, t=f, f=100, i=ID, q=2;base64(path)` and `a=p, U=1, i=ID, p=PID, C=1, c=cols, r=rows, q=2`.
   - Populates image window buffer with placeholder text grid and attaches defensive keymaps.
   - Bypasses intermediate ImageMagick conversion.

5. **Multi-Frame Animated GIF Hardware Playback**:
   - Checks `resolver.is_gif_animated(path)`.
   - Coalesces frames into cache directory via `magick` or `convert` (reusing cached frames if already present).
   - Transmits base frame (`a=t, t=f, z=DELAY`), subsequent frames (`a=f, t=f, z=DELAY`), placement (`a=p, U=1`), and starts loop playback (`a=a, s=2, v=0`).
   - Zero Neovim CPU usage: hardware loop executes entirely inside terminal GPU clock.

6. **Unified Seam & Lifecycle Cleanup**:
   - `display(win, path, opts)` dispatches to native or snacks adapter based on detected driver.
   - `abort(win)` terminates in-flight conversions/processes and resets placement.
   - `clear()` purges graphics placement, restores buffer, and sends `a=d, d=i, i=ID` to immediately free GPU textures.
   - Retained backwards-compatible aliases: `render = display`, `close = clear`.
   - In-place resize nudge `nudge()` updates dimensions and placeholder grids.

### Verification
- 22 new unit tests added to `tests/unit/canvas_spec.lua` covering driver detection, sequence generation, tmux wrapping, base64 encoding, placeholder generation, highlight group mapping, static PNG fast path, animated GIF playback, and GPU texture deletion.
- Full test suite (`make test`) runs 100% green with 0 errors and 0 failures.
- `make lint` passes cleanly across all 30 codebase files.
