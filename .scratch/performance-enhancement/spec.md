# Spec: High-Throughput Prefetching, Rate-Governed Pipeline & Image Prewarming Engine

Status: completed

## Problem Statement

When browsing Gelbooru artwork—both in local folders and online searches—users experience frustrating stalls and latency hiccups:

1. **Local Library Navigation Stalls (~630ms Gap)**:
   When scrolling through a local folder or saved library, navigating to an uncached image (an image not yet converted in the active session) incurs an immediate visual freeze of 600–650ms. Because local booru artwork consists of high-resolution images (often 3000x4000 to 4000x8000 pixels, 2MB–20MB), on-demand terminal graphics conversion via ImageMagick (`magick`) requires ~600ms of CPU processing. Combined with the preview cooldown timer (30ms), the user is forced to wait ~630ms on every new post. Once an image is loaded once, snacks caches the converted PNG, making subsequent visits instant (<5ms). However, the plugin currently has zero background prewarming for local images—the prefetch system explicitly ignores local posts (`if p and not p.is_local then`), leaving every uncached local image to suffer the full 630ms conversion penalty on first view.

2. **Online Prefetch Starvation ("Works for a bit, then makes me wait")**:
   When browsing Gelbooru online, prefetching works smoothly for 2–3 posts before abruptly stalling and forcing the user to wait for network downloads before resuming. This stutter happens because:
   - The immediate lookahead depth is artificially clamped to only 2 posts ahead, which is quickly exhausted during standard navigation.
   - Remaining candidates within the prefetch radius are delayed behind artificial 50ms stagger timers.
   - Newly downloaded preview files are not pre-warmed through the graphics converter upon download completion, meaning the user still suffers an on-demand conversion delay upon landing on a freshly downloaded post.
   - Any minor scroll direction adjustment or cursor jitter triggers aggressive `SIGKILL` cancellations on in-flight downloads, discarding network progress and forcing expensive TLS renegotiations and byte-range resumes.
   - The autopage boundary threshold is currently set to only 5 posts (`AUTOPAGE_BOUNDARY_THRESHOLD = 5`). As lookahead outpaces the user, it hits a hard wall at post 42 because page 2 is not requested until post 37, causing periodic starvation every 42 posts.

3. **Rate Limit & Memory Constraints**:
   Gelbooru strictly bans IP addresses exceeding 10 requests per second. Aggressive network saturation must never exceed this ceiling. Furthermore, continuous scrolling through 100+ high-resolution posts must maintain flat RAM consumption without memory leaks.

## Solution

Implement an aggressive, asynchronous dual-tier Prefetch and Image Prewarming Engine for both local libraries and online booru queries:

1. **Local Artwork Background Prewarmer**:
   Proactively prewarm and convert upcoming local booru images into terminal graphics format (`snacks.image.convert`) in the background along the active scroll direction (and immediate reverse radius). By the time the user presses `j` or `k`, the target image has already been scaled and converted on disk, making local browsing instantaneous (<30ms) on first visit.

2. **Centralized 8 req/sec Token-Bucket Rate Governor**:
   Enforce a global rate governor across all network operations (post downloads, metadata hydration, API queries, and tag resolutions). Cap network activity at a safe, maximum-throughput ceiling of 8 requests per second, completely preventing IP bans while keeping the download pipeline saturated.

3. **Deep Lookahead, Stagger Elimination & Pipelined Prewarming**:
   - Expand the immediate lookahead depth to 8 posts ahead in the active scroll direction without artificial 50ms timer staggering.
   - Cap concurrent active downloads at 4 parallel workers under the rate governor.
   - Immediately pipe completed downloads into background image conversion so preview files are converted to terminal graphics *before* the user lands on them.

4. **Autopage Boundary Advance (Threshold = 15)**:
   Increase the autopage trigger boundary from 5 to 15 posts before the end of the active list. The next batch of 42 posts is fetched asynchronously in the background long before the cursor or lookahead buffer nears the end of the page, eliminating boundary stalls.

5. **Strict Priority Queuing & Anti-Jitter Connection Resilience**:
   - Prioritize preview image downloads directly ahead of the cursor above background metadata hydration and unknown tag taxonomy lookups.
   - Replace hard `SIGKILL` cancellations on direction adjustments with queue re-ordering, allowing near-complete downloads to finish and populate the cache rather than restarting handshakes.

6. **Disciplined Memory Bounds & Pure Disk-to-Disk Prewarming**:
   - Prewarming runs purely disk-to-disk (ImageMagick converts directly into `~/.cache/nvim/snacks/image/`). It never creates Neovim dummy buffers or transmits image bitmaps into terminal memory until the user actually lands on the post.
   - Queue handles and child processes are aggressively dereferenced upon completion, maintaining flat RAM usage (<150MB) even across 100+ post scrolling stress tests.
   - Comprehensive teardown cleans all timers, aborts child processes, and collects memory.

---

## User Stories

### Local Library Browsing & Prewarming
1. As a user browsing a local folder of high-resolution booru artwork, I want upcoming images in my scroll direction to be pre-converted in the background, so that landing on each post displays the image instantly without a 630ms delay.
2. As a user opening a local directory for the first time, I want the first few images near the top of the list to begin prewarming immediately, so that my initial scrolling is fluid from the start.
3. As a user scrolling down with `j`, I want the prewarmer to prioritize images ahead of my cursor over images behind my cursor, so that my forward path is always warm.
4. As a user reversing direction with `k`, I want the prewarmer to dynamically adapt and prioritize images in the reverse direction, so that browsing backward is equally seamless.
5. As a user on Apple Silicon (M1/M2/M3), I want background image conversion to run across 3 concurrent workers, so that conversions complete in parallel without causing UI stutter.
6. As a user browsing mixed-media folders with both images and videos, I want the prewarmer to generate video thumbnails ahead of time via ffmpeg, so that video posts do not stall the preview panel.
7. As a user with very large images (15MB–25MB PNG/JPEG), I want the prewarm engine to convert them ahead of time so I never see blank canvas placeholders.

### Online Search & High-Performance Network Lookahead
8. As a user browsing Gelbooru online, I want preview downloads to run aggressively ahead of my cursor (up to 8 posts ahead), so that I never outrun the prefetch buffer during normal browsing.
9. As a user browsing online results, I want completed image downloads to immediately trigger background graphics conversion, so that the image is already converted when my cursor arrives.
10. As a user on a fast internet connection, I want immediate lookahead downloads to dispatch without artificial timer delays, so that my bandwidth is utilized immediately.
11. As a user browsing Gelbooru, I want all network requests to be regulated under an 8 req/sec governor, so that I can never be banned or rate-limited for exceeding Gelbooru's 10 req/sec rule.
12. As a user actively scrolling through posts, I want preview downloads directly ahead of my cursor to take strict priority over background metadata hydration, so that tags never delay images.
13. As a user scrolling toward the end of an online page, I want background pagination to fetch the next batch at 15 posts before the bottom, so that the post stream never pauses at page boundaries.
14. As a user rapidly tapping `j` through posts, I want minor cursor pauses or direction jitter to not abort active downloads, so that bandwidth and TLS handshakes are not wasted restarting cancelled transfers.

### Lifecycle, Resource Discipline & Error Resilience
15. As a user closing the Gelbooru browser window (`q` or `<Esc>`), I want all active background conversions, curl processes, and prefetch timers to terminate cleanly, so that zero background processes remain running on my machine.
16. As a user switching from one query to another, I want in-flight prefetch and prewarm tasks from the previous query to cancel immediately, so that old images do not overwrite new search results or consume bandwidth.
17. As a user scrolling through hundreds of posts in a single session, I want prewarming to operate purely disk-to-disk without creating terminal memory textures in advance, so that RAM usage stays flat and does not balloon to 1GB–2GB.
18. As a user encountering a corrupted local file or invalid image, I want the background prewarmer to record the failure gracefully and skip to the next post, without crashing the prewarm pipeline.

---

## Implementation Decisions

### 1. Centralized 8 req/sec Rate Governor
- Introduce a centralized rate governor in `net.download` that regulates all outgoing network calls (`download_async`, `curl_async`, API fetch, tag resolution).
- Enforce a minimum interval of 125ms between dispatches and cap the burst token bucket at 4 concurrent in-flight sockets.
- If requests arrive faster than the 8 req/sec threshold, queue them by priority:
  1. Priority 1: Direct cursor preview target (`cur`).
  2. Priority 2: Immediate lookahead preview targets in active direction (`cur + 1` .. `cur + 8`).
  3. Priority 3: Autopage fetch (`api.fetch(1)`).
  4. Priority 4: Background metadata hydration and unknown tag resolution.

### 2. Autopage Advance & Deep Lookahead
- Update `constants.AUTOPAGE_BOUNDARY_THRESHOLD` from 5 to 15.
- Update `constants.PREFETCH_LOOKAHEAD_DEPTH` to 8.
- Remove `PREFETCH_STAGGER_MS` delay for forward targets within the lookahead depth; dispatch immediately through the rate governor.

### 3. Unified Prewarm Pipeline (Local & Download Completion)
- Create a dedicated prewarm scheduler that operates across both local and online media:
  - For local artwork: when cursor moves, collect the next 5 posts in the active scroll direction. If their converted artifact does not exist on disk, enqueue them in the prewarmer.
  - For online artwork: upon successful download of `prev_<id>.jpg`, immediately forward the file path into the prewarmer.
- Prewarmer runs up to 3 concurrent ImageMagick conversion processes in the background via `snacks.image.convert.convert({ src = path })` or equivalent.
- Prewarming is strictly disk-to-disk: it produces `<snacks_cache>/<hash>-<name>.png` without creating Neovim buffers or terminal placement objects.

### 4. Bounded Queue & Memory Discipline
- Keep active prewarm and prefetch queues clamped to a sliding window of at most 10 items. Drop out-of-radius items if the user jumps across large offsets.
- On process completion, immediately set child handles and callbacks to `nil` to enable prompt garbage collection.
- Trigger garbage collection pacing on page boundary transitions.

### 5. Graceful Anti-Jitter Queue Re-Ordering
- When scroll direction reverses (`j` to `k`), do not kill in-flight downloads with `SIGKILL`.
- Re-sort the queue so targets in the new direction are dispatched next, allowing near-complete downloads to finish naturally and enter the cache.
- Hard process cancellation is reserved for search query changes and UI teardown.

### 6. Strict Lifecycle Teardown
- Register all prewarm handles, download handles, and timers in lifecycle tracking tables.
- Window close (`q`, `<Esc>`) and `teardown()` immediately abort all child processes, close all timers, wipe queues, and execute garbage collection passes.

---

## Testing Decisions

### What Makes a Good Test
- Tests must assert observable latency, cache artifact creation, rate limits, and memory/process cleanup—never internal private flags.
- Tests must verify:
  1. Advancing cursor in a local folder pre-converts upcoming images on disk before direct selection.
  2. Navigating to a prewarmed post renders in <30ms without on-demand ImageMagick conversion delay.
  3. Network requests never exceed the 8 req/sec ceiling even when dozens of prefetch targets are queued.
  4. Completed downloads automatically trigger background graphics conversion.
  5. Continuous scrolling through 50+ posts does not leak handles or cause runaway memory growth.
  6. Teardown terminates all workers and leaves zero residual processes or open timers.

### Modules Tested
- **Prefetch & Rate Governor**: Tested in `tests/unit/download_spec.lua` asserting rate limits, priority ordering, and lookahead depth.
- **Local Prewarmer**: Tested in `tests/unit/local_spec.lua` asserting pre-conversion of adjacent local files.
- **Stress & Concurrency Safety**: Tested in `tests/integration/pipeline_stress_spec.lua` asserting flurry navigation (`j`/`k`), direction reversals, and leak-free teardown.

### Prior Art
- Network download and prefetch tests in `tests/unit/download_spec.lua`.
- Pipeline stress and race safety tests in `tests/integration/pipeline_stress_spec.lua`.

---

## Out of Scope

- Implementing custom C-level image decoders.
- Modifying terminal emulator internal graphics rendering pipelines.
- Persistent cross-session in-memory image caching (relying on disk cache directories).
