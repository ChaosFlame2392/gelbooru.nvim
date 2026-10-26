# 01: Encapsulated Tag Catalog & Index Loading

**What to build:** Create `lua/gelbooru/tags/catalog.lua` consolidating tag storage. Privately encapsulate static tag tables, first-letter hash buckets, and exact lookup dictionaries away from the global `State` singleton. Provide progressive asynchronous database loading across event-loop turns.

**Type:** task

**Status:** completed

**Blocked by:** None

- [x] Create `lua/gelbooru/tags/catalog.lua`.
- [x] Implement private internal category arrays (series, characters, artists, general, meta) and first-letter index tables.
- [x] Implement progressive chunked tag loading using `vim.defer_fn` across event-loop turns.
- [x] Expose `load(opts, callback)` and `is_loaded()`.
- [x] Write unit tests in `tests/unit/tag_catalog_spec.lua` asserting catalog loads fixture databases correctly without exposing internal bucket tables.
