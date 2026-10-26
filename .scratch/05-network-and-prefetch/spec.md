# Spec: High-Performance Network Pipeline & Resilient Lookahead Prefetching

Status: completed

## Problem Statement

Users on high-speed internet connections experience severe latency, sluggish preview rendering, and zero bandwidth saturation when browsing Gelbooru posts in `gelbooru.nvim`.

Instead of previews loading near-instantaneously as the user navigates, each image preview takes several seconds to display. During active cursor navigation (`j`/`k`), background lookahead prefetching repeatedly fails, leaving behind truncated `.part` files in the temporary cache directory that are subsequently wiped out and re-downloaded from scratch.

Investigation reveals three compounding architectural causes:
1. **Prefetch Abortion Regression**: In the media resolution pipeline, navigation-triggered abort routines invoke the global download abortion handler (`abort_all`), which issues `SIGKILL` to all in-flight curl processes across the entire plugin. Consequently, any background prefetch downloads for upcoming posts are violently terminated on every cursor step.
2. **Destructive Partial Cache Invalidation**: When a download restarts for a post whose prefetch was interrupted, partial `.part` files are deleted from disk rather than resumed via HTTP byte-range requests (`-C -`), discarding all transferred data and restarting from byte zero.
3. **Artificially Delayed & Serialized Lookahead Dispatch**: Prefetching is gated behind a 150ms post-render cooldown timer and artificially staggered by 50ms intervals per post. High-speed network connections are left completely idle while the user navigates, and the high round-trip latency of remote booru CDNs (~300ms RTT, ~1.7s TLS negotiation) cannot be overlapped.

## Solution

Revamp the networking and prefetch pipeline to maximize throughput, eliminate wasted bandwidth, and achieve sub-100ms perceived preview rendering on high-speed networks:
1. **Isolated Request Cancellation**: Decouple active post cancellation from background prefetch downloads. Cancelling the previous post's canvas render or video transcode must never terminate lookahead prefetch downloads for upcoming posts in the active scroll direction.
2. **Resilient Byte-Range Resumption**: Enable automatic HTTP byte-range continuation (`curl -C -`) for all media downloads where a valid `.part` file exists, preserving previously downloaded bytes across aborts, restarts, and network hiccups.
3. **Eager & Concurrent Lookahead Dispatch**: Initiate lookahead prefetching immediately upon cursor movement rather than waiting for preview debounce timers to expire. Dispatch top lookahead targets concurrently to overlap TCP and TLS connection handshakes, saturating available bandwidth.
4. **Transparent Download Deduplication**: Allow the foreground preview resolver to hook into already-running background prefetch handles seamlessly, rendering images instantly upon download completion without re-spawning curl.

---

## User Stories

1. As a user on a high-speed fiber or broadband connection, I want image previews to load near-instantaneously as I scroll through search results, so that browsing feels snappy and responsive.
2. As a user navigating through posts with `j` and `k`, I want upcoming posts in my scroll direction to download in the background ahead of my cursor, so that previews are already cached on disk when I land on them.
3. As a user quickly tapping `j` through several posts, I want in-flight prefetch downloads for future posts to continue downloading without being terminated by intermediate cursor steps.
4. As a user moving past a post whose download was partially completed, I want subsequent requests for that post to resume from the existing bytes via HTTP Range headers rather than re-downloading from scratch.
5. As a user browsing a booru hosted on high-latency overseas CDNs, I want lookahead prefetch requests to dispatch concurrently, so that TLS 1.3 handshakes overlap rather than serialize sequentially.
6. As a user landing on a post that is currently 90% downloaded by the background prefetcher, I want the active preview to hook directly into the running download handle rather than killing it and restarting.
7. As a user rapidly switching scroll direction from downwards to upwards, I want prefetch downloads in the old opposite direction to cancel cleanly while new prefetch downloads in the active direction spin up immediately.
8. As a user submitting a new search query or changing filters, I want all active prefetch downloads from the previous query to be cleanly terminated and purged to prevent cache pollution and epoch mismatch.
9. As a user closing or tearing down the plugin window, I want all background network processes to terminate immediately without leaving dangling background curl processes.
10. As a user viewing large high-resolution sample images, I want network transfers to utilize my full connection bandwidth without artificial pacing delays.
11. As a user browsing on an unstable connection, I want network timeouts and connection drops on prefetch downloads to be handled gracefully without locking or blanking the preview canvas.
12. As a developer writing integration tests, I want to verify that cursor movement preserves background prefetch handles and that partial downloads resume from existing disk offsets.

---

## Implementation Decisions

### 1. Decoupled Request Abortion Architecture
- Modify the media resolution abort routine so that it increments the active request epoch, aborts video transcode subprocesses, and closes terminal canvas image placements without invoking the global download termination routine.
- Restrict global download cancellation (`abort_all`) strictly to terminal UI teardown and new search execution epochs.
- Preserve lookahead prefetch handles in the current scroll direction across consecutive post preview requests.

### 2. Universal Byte-Range Resumption
- Generalize download resumption in the asynchronous transfer engine: whenever a `.part` file exceeds 1024 bytes and the request is not an explicit force-refresh, pass `-C -` to curl to request HTTP `Range` offsets.
- Only delete `.part` files if the download completes with corrupt or non-media binary headers, or if an explicit force-refresh (`R`) is invoked by the user.

### 3. Eager Lookahead Dispatch
- Trigger lookahead prefetch evaluation immediately upon cursor movement in the post list, rather than delaying it behind the preview render debounce timer.
- Keep the preview canvas render debounced (to prevent terminal image conversion churn during rapid scrolling), but decouple network lookahead dispatch so transfer latency is fully masked.

### 4. Overlapped Connection Concurrency
- Eliminate artificial sequential delay timers for the top lookahead targets (e.g. posts at $N+1$ and $N+2$), allowing curl subprocesses to execute concurrently.
- Let subsequent lookahead posts within the prefetch radius stagger at compact intervals to prevent connection flooding while maximizing socket utilization.

### 5. Seamless Callback Hooking & Deduplication
- Ensure the foreground preview resolver checks active download tables before initiating a fetch. If a lookahead prefetch is already in-flight for the destination path, the foreground callback attaches to the existing handle, eliminating redundant network requests and socket contention.

---

## Testing Decisions

### Test Quality & External Behavior
- Tests must assert observable external behavior: curl command-line arguments, file size preservation, callback dispatch, and process lifecycle handles.
- Tests must not rely on internal timer IDs or private loop references.

### Modules to Test
- **Download Engine Unit Tests**: Verify that `download_async` appends `-C -` when `.part` files exist and does not delete valid partial files; verify callback deduplication when multiple callers request the same target.
- **Media Resolver Unit Tests**: Verify that `resolver.abort_active()` increments request epoch, closes canvas, and aborts FFmpeg without killing active download handles in the download engine.
- **Pipeline & Prefetch Integration Tests**: Exercise rapid `j`/`k` cursor movements against simulated network delays, asserting that lookahead downloads stay active in the scroll direction and complete without teardown interruption errors.

### Prior Art
- `tests/unit/download_spec.lua`: Established patterns for mocking `vim.system`, testing curl arguments, simulating download completion, and validating binary media.
- `tests/unit/media_resolver_spec.lua`: Existing tests for `abort_active` request epoch guards and canvas teardown.
- `tests/integration/pipeline_stress_spec.lua`: Multi-flight rapid user interaction and race safety testing harness.

---

## Out of Scope

- Implementing an in-process libcurl C binding or raw TCP socket client (the plugin strictly requires standard system `curl` without native C dependencies).
- Implementing peer-to-peer image sharing or multi-server mirroring.
- Modifying offline tag database scraping (`tags/fetcher.lua`) pacing or concurrency.

---

## Further Notes

- Gelbooru's nginx edge servers support standard `Accept-Ranges: bytes` and HTTP/1.1 `Connection: keep-alive`.
- Full-resolution `save_dir` media downloads already use `-C -` resumption via `resume_pending_saves()`; extending this capability to preview cache files brings consistency across all download pathways.
