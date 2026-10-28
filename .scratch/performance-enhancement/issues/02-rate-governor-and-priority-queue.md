# 02: Token-Bucket Rate Governor and Priority Queue

**What to build:** A centralized rate governor and priority dispatcher regulating all outgoing network operations across the plugin (preview downloads, lookahead prefetches, autopaging API calls, metadata hydration, and tag resolution). Network dispatches are capped at a safe ceiling of 8 requests per second across at most 4 concurrent sockets to prevent IP bans. Foreground user actions (the currently focused post) take immediate priority over background lookahead and metadata tasks.

**Blocked by:** None (can start immediately)

**Status:** completed

- [x] Outgoing network requests never exceed 8 requests per second even when dozens of tasks are enqueued.
- [x] Concurrent active network connections are capped at 4 in-flight sockets.
- [x] Direct cursor preview requests (Priority 1) dispatch ahead of background lookahead prefetches (Priority 2), autopage requests (Priority 3), and background metadata/tag resolutions (Priority 4).
- [x] Requests queued beyond the rate limit wait in priority order and dispatch smoothly as token capacity refills.
- [x] Network errors, timeouts, or aborted requests release connection tokens immediately so subsequent requests are not starved.
