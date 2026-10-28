# Map: Terminal Graphics Engine, Ghostty 1.4 Native Driver & Asset Pipeline Consolidation

## Task Graph & Frontier

- **01: Drop Obsolete image.nvim Backend**
  - Path: `.scratch/06-terminal-graphics-and-assets/issues/01-drop-legacy-image-nvim.md`
  - Blocked by: None
  - Status: resolved

- **02: Untangle Media Subsystem: Extract Pure Inspector & Isolated Transcoder**
  - Path: `.scratch/06-terminal-graphics-and-assets/issues/02-isolate-media-inspector-and-transcoder.md`
  - Blocked by: 01
  - Status: resolved

- **03: Consolidate Asset Pipeline & Eliminate Duplicate Prewarmer Queue**
  - Path: `.scratch/06-terminal-graphics-and-assets/issues/03-consolidate-asset-pipeline-and-dedup-prewarmer.md`
  - Blocked by: 02
  - Status: resolved

- **04: Ghostty 1.4 / Kitty Native Graphics Driver & Canvas Seam Deepening**
  - Path: `.scratch/06-terminal-graphics-and-assets/issues/04-ghostty-kitty-native-graphics-driver.md`
  - Blocked by: 03
  - Status: resolved

## Decisions-so-far
- Ghostty 1.4 features 100% Kitty Graphics Protocol compliance, ~725 MB/s graphics parsing, and multi-frame animation support.
- Dropping legacy `image.nvim` backend completely, reducing to two active renderers: Ghostty/Kitty native driver and Snacks fallback for other terminals.
- Existing video user experience is strictly preserved: `ffmpeg` static thumbnail extraction for preview, `O` for full video in external player.
- Architecture untangles pure binary header seeking into `media.inspector`, subprocess lifecycle into `media.transcoder`, and consolidates duplicate prewarm queues into `net.download`.
- Ticket 01 resolved: Removed legacy `render_image_nvim` from `canvas.lua`, normalized `config.options.backend` to accept `"auto"` (default), `"ghostty"`, `"kitty"`, or `"snacks"` (with legacy/invalid options normalizing to `"auto"`), updated runtime dependencies in `AGENTS.md`, and purged all `image.nvim` references from `canvas_spec.lua`.
- Ticket 02 resolved: Extracted pure binary parser into `lua/gelbooru/media/inspector.lua` with robust GIF block traversal and zero child processes; extracted FFmpeg subprocess lifecycle into `lua/gelbooru/media/transcoder.lua` with SIGKILL process cleanup and `active_ffmpeg_handles` tracking; decomposed `lua/gelbooru/media/resolver.lua` to delegate cleanly with 100% backwards compatibility and table identity preservation; verified with `tests/unit/inspector_spec.lua`, `tests/unit/transcoder_spec.lua`, and full green test suite.
- Ticket 03 resolved: Consolidated asset pipeline and duplicate queues into `lua/gelbooru/net/download.lua` with unified 4-tier scheduler and `ensure_ready(post, priority, cb)`; reduced `lua/gelbooru/media/prewarmer.lua` to a lean 79-line facade; unified sliding-window task pruning under cursor flurry; all unit and integration tests passing green.
- Ticket 04 resolved: Deepened `canvas.lua` behind a unified 3-method interface (`display`, `abort`, `clear`), with full backwards-compatible aliases (`render = display`, `close = clear`); implemented capability detection for Ghostty, Kitty, WezTerm, and tmux passthrough; implemented Kitty graphics escape sequence formatter, tmux DCS wrapper, and Unicode placeholder grid generation (`U=1`, `0x10EEEE` + row/col diacritics paired with `fg = ID, sp = PID`); implemented fast path direct file transmission (`t=f`) for static PNG/JPEG bypassing ImageMagick; implemented native multi-frame animated GIF hardware loop playback (`a=f`, `a=a`) without Neovim CPU usage; implemented instant GPU texture deletion on post navigation/teardown (`a=d, d=i, i=ID`); all unit and integration tests 100% green.
