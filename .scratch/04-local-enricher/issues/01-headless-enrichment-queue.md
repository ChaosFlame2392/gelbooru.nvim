# 01: Headless Enrichment Queue & Pacing Engine

**What to build:** Create `lua/gelbooru/local/enricher.lua`. Manage a FIFO post queue with head-pointer advancement, batch hydration pacing (100ms interval), concurrency limits (max 2 concurrent requests), and metadata resolution via `net.api.fetch_post_metadata`.

**Type:** task

**Status:** ready-for-agent

**Blocked by:** None

- [ ] Create `lua/gelbooru/local/enricher.lua`.
- [ ] Implement FIFO queue with head-pointer advancement to avoid array reindexing overhead.
- [ ] Implement worker concurrency limiter (max 2 concurrent HTTP requests).
- [ ] Implement cursor rush prioritization `prioritize_near(cursor_idx, radius)`.
- [ ] Expose `enqueue(posts, opts, callback)` emitting `on_post_hydrated(post)` on completion.
- [ ] Write unit tests in `tests/unit/local_enricher_spec.lua` asserting queue processing, concurrency bounds, and event firing.
