# 02: Pacing Timer Encapsulation & Epoch Cancellation

**What to build:** Encapsulate queue pacing timers privately inside `lua/gelbooru/local/enricher.lua`. Support epoch-based cancellation and teardown cleanup, ensuring in-flight callbacks from previous folders or searches are cleanly discarded without leaking libuv timer handles.

**Type:** task

**Status:** ready-for-agent

**Blocked by:** 01: Headless Enrichment Queue & Pacing Engine

- [ ] Encapsulate pacing timer handles privately inside `enricher.lua`.
- [ ] Implement `cancel()` discarding all pending queue items and in-flight responses.
- [ ] Bind cancellation to session search epoch; discard stale responses automatically when epoch advances.
- [ ] Implement clean teardown routine closing timer handles without leaks.
- [ ] Unit tests verify rapid queue cancellation and epoch invalidation prevent stale callback execution.
