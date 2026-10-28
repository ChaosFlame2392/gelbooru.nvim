# 05: Sliding-Window Queue Bounding and Strict Lifecycle Teardown

**What to build:** Strict resource discipline and complete lifecycle teardown for the prefetch and prewarm engines. The active prewarm and prefetch queues are clamped to a sliding window around the active cursor, dropping out-of-radius targets during large jumps (e.g. jumping to the start/end of the list or switching query pipelines). Closing the browser window (`q` or `<Esc>`) or executing a new query immediately terminates all background conversion and curl processes, closes all timers, and clears queue handles, ensuring flat RAM usage (<150MB) and zero zombie processes.

**Blocked by:** 04: Pipelined Online Preview Prewarming

**Status:** closed

- [x] Large cursor jumps (such as `gg`, `G`, or piped query offset shifts) prune out-of-radius prefetch and prewarm tasks from the queue.
- [x] Closing the browser window (`q` or `<Esc>`) immediately aborts all active background curl transfers, image conversion processes, and ffmpeg thumbnailers.
- [x] All libuv timers associated with prefetching and rate limiting are closed cleanly on UI teardown.
- [x] Query switches cancel in-flight tasks from previous searches so stale results never overwrite active results.
- [x] Continuous navigation through 100+ high-resolution posts maintains flat memory usage without handle leaks.
