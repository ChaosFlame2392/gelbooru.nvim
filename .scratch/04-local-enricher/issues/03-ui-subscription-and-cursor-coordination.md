# 03: UI Subscription & Cursor Coordination

**What to build:** Refactor `lua/gelbooru/local/init.lua` to subscribe to the enrichment worker's `on_post_hydrated` events. Coordinate post re-sorting, cursor stability on the active item ID, and debounced list/metadata repaints in the local browser controller. Delete legacy `lua/gelbooru/local/indexer.lua`.

**Type:** task

**Status:** ready-for-agent

**Blocked by:** 01: Headless Enrichment Queue & Pacing Engine, 02: Pacing Timer Encapsulation & Epoch Cancellation

- [ ] Connect `lua/gelbooru/local/init.lua` to `local.enricher.enqueue`.
- [ ] Handle `on_post_hydrated`: re-sort items if sorting by score, preserve cursor on the currently selected post ID, and trigger debounced `ui.render_list()` and `ui.render_metadata()`.
- [ ] Remove `UI.indexer_task_id` and timer leaks from `core/state.lua`.
- [ ] Delete legacy `lua/gelbooru/local/indexer.lua`.
- [ ] Run full test suite (`make test`) and assert local library integration tests pass with 100% success.
