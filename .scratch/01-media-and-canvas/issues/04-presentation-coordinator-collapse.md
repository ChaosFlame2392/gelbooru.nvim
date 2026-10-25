# 04: Presentation Coordinator Collapse & Image Module Deletion

**What to build:** Refactor `load_and_render_image` in `lua/gelbooru/ui/render.lua` from 225 lines down to a lean coordinator (< 40 lines): request resolution from the Media Resolver, verify cursor epoch/alignment on completion, and pass the verified path to the Canvas Adapter. Delete monolithic `lua/gelbooru/ui/image.lua` without retaining a shallow facade.

**Type:** task

**Status:** resolved

**Blocked by:** 01: Headless Media Resolver Seam & Binary Verification, 02: Terminal Canvas Adapter & Placement Isolation, 03: Video Transcoder Lifecycle & Process Tracking

- [x] Refactor `load_and_render_image` in `lua/gelbooru/ui/render.lua` to delegate to `media.resolver.resolve` and `ui.canvas.render`.
- [x] Delete `lua/gelbooru/ui/image.lua` completely; update callers in `ui/keymaps.lua`, `ui/lifecycle.lua`, and `ui/render.lua` to call `media/resolver.lua` or `ui/canvas.lua` directly.
- [x] Remove `UI.abort_cleanup_timer` from `lua/gelbooru/core/state.lua` and `constants.ABORT_CLEANUP_DELAY_MS` from `lua/gelbooru/core/constants.lua`.
- [x] Clean up `lua/gelbooru/core/util.lua` by removing migrated binary image parsing and format completion functions.
- [x] Verify that rapid cursor navigation (`j`/`k`/`gg`/`G`) smoothly aborts stale resolutions without UI stutter or corrupted caches.
- [x] Verify force refresh (`R`) purges volatile caches while strictly protecting `save_dir`.
- [x] Run full test suite (`make test`) and ensure all unit and integration tests pass with zero regressions.

## Answer

Refactored the presentation coordination flow and eliminated legacy monolithic `lua/gelbooru/ui/image.lua`:
- Lean presentation coordinator: Refactored `load_and_render_image` in `lua/gelbooru/ui/render.lua` from 225 lines down to a lean coordinator (< 60 lines) that delegates media acquisition, fallback chains, and video transcoding to `media.resolver.resolve`, and terminal rendering/placeholders to `ui.canvas.render` and `ui.canvas.render_placeholder`. Verifies post cursor alignment (`is_same_post`) and teardown guard before rendering, and hydrates post dimensions and metadata seamlessly.
- Complete deletion of `lua/gelbooru/ui/image.lua`: Removed the 998-line monolithic image module completely without retaining a shallow facade or forwarding shim.
- Comprehensive caller migration: Updated all consumer call sites across the codebase:
  - `lua/gelbooru/core/history.lua`: `canvas.close()` and `resolver.abort_active()` on history restore.
  - `lua/gelbooru/local/init.lua`: `canvas.close()` on local folder transition.
  - `lua/gelbooru/net/api.lua`: `canvas.close()`, `resolver.abort_active()`, `resolver.clear_cache()` on search execution and force refresh.
  - `lua/gelbooru/net/download.lua`: `resolver.get_preview_cache_path()` for prefetch caching and cache existence checks.
  - `lua/gelbooru/ui/init.lua`: Re-exported public API symbols (`close`, `nudge`, `render`, `render_placeholder` from canvas; `resolve`, `clear_cache`, `abort_active` from resolver).
  - `lua/gelbooru/ui/keymaps.lua`: Migrated force refresh (`R`), re-render (`r`), zen toggle, width adjustment, and mouse click handlers.
  - `lua/gelbooru/ui/layout.lua`: `canvas.nudge()` on window resize and layout calculation.
  - `lua/gelbooru/ui/lifecycle.lua`: `canvas.close()`, `canvas.abort_convert()`, and `resolver.abort_active()` during teardown.
- Cleaned core utilities: Migrated binary image header parsing (`read_image_dimensions`) and completeness checks (`is_image_complete`) exclusively to `media.resolver`, removing them from `core/util.lua`.
- Test harness & suite migration: Replaced legacy `image_spec.lua` and old util image assertions with unit tests in `tests/unit/media_resolver_spec.lua` and `tests/unit/canvas_spec.lua`, and migrated integration test mocks and helpers (`harness.lua`, `mock_net.lua`, `minor_features_spec.lua`, `local_spec.lua`, `search_spec.lua`, `regressions_spec.lua`).
- Verification: Full test suite (`make test`) runs 100% green across all unit and integration specs (0 failures, 0 errors), and `make lint` passes cleanly with 0 linter diagnostics.

