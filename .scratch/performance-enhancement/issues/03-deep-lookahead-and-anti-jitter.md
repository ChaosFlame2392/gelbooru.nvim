# 03: Deep Lookahead, Autopage Boundary Advance and Anti-Jitter Resilience

**What to build:** Aggressive online prefetching and fluid pagination that never starves during continuous scrolling. Preview images are prefetched up to 8 posts ahead in the active scroll direction without artificial stagger delays, dispatched through the rate governor. As the user scrolls toward the bottom of the active page, the next page is fetched in the background 15 posts before reaching the boundary. Rapid navigation pauses or direction reversals re-prioritize the download queue rather than violently killing active transfers with `SIGKILL`, preserving bandwidth and TLS connections.

**Blocked by:** 02: Token-Bucket Rate Governor and Priority Queue

**Status:** complete

- [x] Navigating online results prefetches preview images up to 8 posts ahead in the active scroll direction.
- [x] Lookahead downloads dispatch immediately through the rate governor without artificial timer staggering.
- [x] Scrolling within 15 posts of the end of the loaded post list triggers an asynchronous background fetch for the next page of posts.
- [x] Reversing scroll direction (e.g. `j` to `k`) re-orders the prefetch queue to favor the new direction without terminating in-flight curl transfers via `SIGKILL`.
- [x] Resumed downloads and near-complete transfers continue populating the disk cache unimpeded during cursor jitter.
