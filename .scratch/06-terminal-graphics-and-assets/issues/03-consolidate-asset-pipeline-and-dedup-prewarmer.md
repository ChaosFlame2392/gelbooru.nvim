# 03: Consolidate Asset Pipeline & Eliminate Duplicate Prewarmer Queue

**What to build:** Pass the deletion test on the 508-line `lua/gelbooru/media/prewarmer.lua` by eliminating its duplicate queue, sliding-window management, and concurrent conversions. Consolidate post asset readiness into `lua/gelbooru/net/download.lua` using the existing 4-tier token-bucket rate governor.

**Type:** task

**Status:** resolved

**Blocked by:** 02

### Scope & Technical Decisions:
1. **The Deletion Test**:
   - `lua/gelbooru/media/prewarmer.lua` currently contains 508 lines of redundant queue management:
     - `M.prewarm_queue`, `M.active_conversions`, `M.is_converting`, `M._max_concurrent_conversions`
     - Duplicate priority sorting, sliding-window distance calculations, and recursive drain loops
     - Duplicate retry logic and image conversion tracking that overlaps directly with `lua/gelbooru/net/download.lua`
   - All concurrency, priority scheduling, and rate limiting belong in a single unified place: `lua/gelbooru/net/download.lua`.

2. **Consolidation into `lua/gelbooru/net/download.lua`**:
   - Leverage the existing 4-tier token-bucket scheduler:
     - `TIER_URGENT = 1` (Active cursor preview)
     - `TIER_LOOKAHEAD = 2` (Adjacent posts in scroll direction)
     - `TIER_THUMBNAIL = 3` (Video thumbnail extractions)
     - `TIER_INDEXER = 4` (Background library metadata indexing)
   - Expose `download.ensure_ready(post, priority, cb)`:
     - Checks local disk presence (`save_dir` or cache) and verifies integrity via `media.inspector.is_image_complete`.
     - For video posts: dispatches thumbnail extraction through `media.transcoder.extract_video_thumbnail` governed by the queue.
     - For online posts: enqueues network retrieval via curl according to tier priority.
     - Invokes callback with verified local file path once ready.

3. **Unified Sliding-Window Pruning**:
   - Large cursor jumps (`gg`, `G`, search query execution) must prune all pending readiness and download tasks whose distance `|post_idx - cur_idx| > radius` (default 10) in a single pass.
   - Closing the browser (`ui.teardown()`) aborts all active curl transfers, ffmpeg jobs, and flushes the unified queue.

4. **Facade Retention in `media/prewarmer.lua`**:
   - Convert `media/prewarmer.lua` into a lean facade (sub-80 lines) delegating `prewarm_post`, `schedule_lookahead`, `cancel_prewarm`, and `teardown` directly to `download.ensure_ready` and `download.prune_out_of_radius`.
   - Ensures zero breakage for existing UI callers (`ui/render.lua`, `local/indexer.lua`).

5. **Testing Protocol**:
   - Verify `tests/unit/download_spec.lua` passes with the new `ensure_ready` API.
   - Verify `tests/unit/prewarmer_spec.lua` passes against the consolidated implementation.
   - Verify `tests/integration/pipeline_stress_spec.lua` Section 4 (Sliding-Window Queue Bounding) passes.

### Acceptance Criteria:
- [x] Duplicate queue, active conversions, and sliding-window logic are deleted from `media/prewarmer.lua`.
- [x] `media/prewarmer.lua` is reduced from 508 lines to a clean facade delegating to `net/download.lua`.
- [x] `net/download.lua` exposes `ensure_ready(post, priority, cb)` managing images and video thumbnails through the 4-tier scheduler.
- [x] Large cursor jumps prune pending tasks in the single unified queue.
- [x] `tests/unit/download_spec.lua`, `tests/unit/prewarmer_spec.lua`, and `pipeline_stress_spec.lua` run 100% green.

## Answer
Passed the deletion test on `lua/gelbooru/media/prewarmer.lua`, reducing it from 508 lines to 79 lines. All queueing, rate limiting, and sliding-window distance calculations have been consolidated into `lua/gelbooru/net/download.lua` under a unified 4-tier scheduler exposing `ensure_ready(post, priority, cb)` and unified radius-based task pruning (`prune_out_of_radius`). All unit and integration test suites pass 100% green.
