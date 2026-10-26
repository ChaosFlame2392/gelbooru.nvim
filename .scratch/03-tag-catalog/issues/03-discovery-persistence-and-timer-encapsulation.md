# 03: Discovery Persistence & Timer Encapsulation

**What to build:** Move runtime dynamic tag discovery (`discovered.json`) and dead tag pruning into `lua/gelbooru/tags/catalog.lua`. Encapsulate debounce timers internally, removing `UI.save_discovered_timer`, `UI.prune_disk_timer`, and `UI.api_tag_timer` from `State`.

**Type:** task

**Status:** resolved

**Blocked by:** 01: Encapsulated Tag Catalog & Index Loading

- [x] Implement `record_discovered(tags)` with internal debounced JSON persistence to disk.
- [x] Implement `prune_tag(tag_name)` with internal debounced disk sync.
- [x] Implement `resolve_post_tags(post, callback)` for background metadata enrichment.
- [x] Encapsulate timer handles privately in the catalog module and clean up on teardown.
- [x] Unit tests verify dynamic tags become searchable immediately and write to disk cleanly.

## Answer summary

Implemented runtime tag discovery persistence, tag pruning, and timer encapsulation in `lua/gelbooru/tags/catalog.lua`:
- `catalog.record_discovered(tags)` records newly discovered tags into in-memory category tables and bucket indices so they are immediately searchable, while staging them for debounced disk persistence to `discovered.json` via private `save_timer`.
- `catalog.prune_tag(tag_name)` removes unindexed or invalid tags from in-memory catalog data structures and disk index files via debounced `prune_timer`.
- `catalog.resolve_post_tags(post, callback)` coordinates post tag enrichment and discovery ingestion.
- Encapsulated libuv timer handles (`save_timer`, `prune_timer`, `api_tag_timer`, `db_load_timer`) privately within `catalog.lua`, providing clean shutdown and resource management via `catalog.stop_timers()` and `catalog.teardown()`.
- Full unit test coverage in `tests/unit/tag_catalog_spec.lua` verifying dynamic candidate registration, disk synchronization, tag pruning, and timer encapsulation.
