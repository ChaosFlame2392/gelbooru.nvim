# Map: Media Resolver Decoupling & Terminal Canvas Adapter

## Task Graph & Frontier

- **01: Headless Media Resolver Seam & Binary Verification**
  - Path: `.scratch/01-media-and-canvas/issues/01-headless-media-resolver.md`
  - Blocked by: None
  - Status: resolved

- **02: Terminal Canvas Adapter & Placement Isolation**
  - Path: `.scratch/01-media-and-canvas/issues/02-terminal-canvas-adapter.md`
  - Blocked by: None
  - Status: resolved

- **03: Video Transcoder Lifecycle & Process Tracking**
  - Path: `.scratch/01-media-and-canvas/issues/03-video-transcoder-lifecycle.md`
  - Blocked by: 01
  - Status: resolved

- **04: Presentation Coordinator Collapse & Image Module Deletion**
  - Path: `.scratch/01-media-and-canvas/issues/04-presentation-coordinator-collapse.md`
  - Blocked by: 01, 02, 03
  - Status: resolved

## Decisions-so-far
- Baseline test suite is 100% green on `main`.
- Pure-Lua binary image header parsing (`read_image_dimensions`) and format validation (`is_image_complete`) migrate from `core/util.lua` to `media/resolver.lua`.
- Arbitrary 50ms timer (`UI.abort_cleanup_timer`) and `constants.ABORT_CLEANUP_DELAY_MS` are deleted; conversion abort unlinks partial files immediately.
- Monolithic `ui/image.lua` (1,111 lines) is deleted, avoiding any shallow facade.
- Ticket 02 resolved: Implemented standalone terminal canvas adapter `lua/gelbooru/ui/canvas.lua` (`render`, `render_placeholder`, `nudge`, `close`, `sanitize_dpi`, `abort_convert`, and `attach_defensive_keymaps`), clamping anomalous DPI metadata (>= 300 or < 50) to 96, eliminating unmanaged abort delay timers (`UI.abort_cleanup_timer`, `constants.ABORT_CLEANUP_DELAY_MS`), attaching shielded buffer keymaps, and verified with 17 unit tests ([02-terminal-canvas-adapter.md](file:///Users/balkrishan/Development/gelbooru.nvim/.scratch/01-media-and-canvas/issues/02-terminal-canvas-adapter.md)).
- Ticket 01 resolved: Implemented headless media resolver `lua/gelbooru/media/resolver.lua` (`resolve`, `read_image_dimensions`, `is_image_complete`, `clean_corrupt_snacks_cache`, `clear_cache`, `abort_active`), providing candidate fallback chain (`sample_url` -> `preview_url` -> `file_url`), corrupt cache forensics, and lazy dimension resolution without graphics dependencies, verified with 25 unit tests ([01-headless-media-resolver.md](file:///Users/balkrishan/Development/gelbooru.nvim/.scratch/01-media-and-canvas/issues/01-headless-media-resolver.md)).
- Ticket 03 resolved: Implemented video transcoder lifecycle and process tracking in `lua/gelbooru/media/resolver.lua` (`extract_video_thumbnail`, `abort_video_transcodes`, `abort_all_ffmpeg`, `get_video_thumbnail_path`, `get_saved_video_path`), enabling fast-path resolution of cached video thumbnails, background FFmpeg child jobs via `vim.system` with handle tracking, safe SIGKILL cancellation with partial file cleanup on abort or UI teardown, and graceful missing-executable fallback, verified with 36 unit tests ([03-video-transcoder-lifecycle.md](file:///Users/balkrishan/Development/gelbooru.nvim/.scratch/01-media-and-canvas/issues/03-video-transcoder-lifecycle.md)).
- Ticket 04 resolved: Collapsed `load_and_render_image` in `lua/gelbooru/ui/render.lua` down to a lean presentation coordinator (< 60 lines) delegating resolution to `media.resolver.resolve` and rendering to `ui.canvas.render`/`ui.canvas.render_placeholder`, deleted monolithic `lua/gelbooru/ui/image.lua` (998 lines) without shallow facades, migrated all callers across UI, local, net, and tests to `media.resolver` and `ui.canvas`, cleaned redundant binary parsing utilities from `core/util.lua`, and verified full test suite and linter pass cleanly ([04-presentation-coordinator-collapse.md](file:///Users/balkrishan/Development/gelbooru.nvim/.scratch/01-media-and-canvas/issues/04-presentation-coordinator-collapse.md)).
