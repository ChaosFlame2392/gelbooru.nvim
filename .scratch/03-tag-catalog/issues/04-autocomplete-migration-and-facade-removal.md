# 04: Autocomplete Migration & Facade Removal

**What to build:** Refactor `lua/gelbooru/ui/autocomplete.lua` into a pure UI dropdown module calling `tag_catalog.search`. Delete legacy `tags/db.lua` and `tags/resolve.lua`, and replace the 17-method facade in `tags/init.lua` with the deepened catalog interface.

**Type:** task

**Status:** resolved

**Blocked by:** 02: Candidate Search & Popularity Scoring Engine, 03: Discovery Persistence & Timer Encapsulation

- [x] Refactor `lua/gelbooru/ui/autocomplete.lua` to call `tags.catalog.search(token, opts)` directly, removing all references to `State.series_by_first`, etc.
- [x] Remove `save_discovered_timer`, `prune_disk_timer`, and `api_tag_timer` from `lua/gelbooru/core/state.lua`.
- [x] Delete legacy files `lua/gelbooru/tags/db.lua` and `lua/gelbooru/tags/resolve.lua`.
- [x] Replace `lua/gelbooru/tags/init.lua` to re-export the deepened catalog module.
- [x] Run full test suite (`make test`) and assert autocomplete integration tests pass with zero regressions.

## Answer summary

Migrated autocomplete and finalized the tag catalog refactoring by removing legacy facades:
- Refactored `lua/gelbooru/ui/autocomplete.lua` into a pure presentation layer that queries `tags.catalog.search(token, opts)`, completely decoupling UI rendering from candidate indexing, scoring algorithms, and category bucket structures.
- Removed legacy timers (`save_discovered_timer`, `prune_disk_timer`, `api_tag_timer`) from `State.UI` in `lua/gelbooru/core/state.lua`, as they are now fully encapsulated inside `tags/catalog.lua`.
- Deleted obsolete legacy files `lua/gelbooru/tags/db.lua` and `lua/gelbooru/tags/resolve.lua`.
- Replaced the shallow 17-method facade in `lua/gelbooru/tags/init.lua` with a lean, deepened module re-exporting the catalog interface and background fetcher.
- Updated call sites across `net/api.lua`, `query/engine.lua`, `ui/lifecycle.lua`, `ui/render.lua`, and test harnesses/specs (`db_spec.lua`, `autocomplete_spec.lua`, `harness.lua`, `pipeline_stress_spec.lua`, `regressions_spec.lua`).
- Verified with `make lint` and `make test`; all unit and integration test suites passed with zero regressions.
