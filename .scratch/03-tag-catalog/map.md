# Map: Unified Tag Catalog & Candidate Seam

## Task Graph & Frontier

- **01: Encapsulated Tag Catalog & Index Loading**
  - Path: `.scratch/03-tag-catalog/issues/01-encapsulated-catalog-and-index.md`
  - Blocked by: None
  - Status: resolved

- **02: Candidate Search & Popularity Scoring Engine**
  - Path: `.scratch/03-tag-catalog/issues/02-candidate-search-and-scoring.md`
  - Blocked by: 01
  - Status: resolved

- **03: Discovery Persistence & Timer Encapsulation**
  - Path: `.scratch/03-tag-catalog/issues/03-discovery-persistence-and-timer-encapsulation.md`
  - Blocked by: 01
  - Status: resolved

- **04: Autocomplete Migration & Facade Removal**
  - Path: `.scratch/03-tag-catalog/issues/04-autocomplete-migration-and-facade-removal.md`
  - Blocked by: 02, 03
  - Status: resolved

## Decisions-so-far
- Baseline test suite is 100% green on `main`.
- 14 raw global tables in `State` are encapsulated privately in `lua/gelbooru/tags/catalog.lua`.
- Timers `UI.save_discovered_timer`, `UI.prune_disk_timer`, and `UI.api_tag_timer` are removed from the global UI singleton.
- `tags/init.lua` 17-method facade is replaced with the deepened catalog interface.
- Ticket 01 resolved: Created `lua/gelbooru/tags/catalog.lua` with private encapsulation of category tables and first-letter index tables, progressive asynchronous database loading across event-loop turns, query validation (`is_clean_tag`), and unit tests in `tests/unit/tag_catalog_spec.lua`.
- Ticket 02 resolved: Implemented `catalog.search(prefix, opts)` in `lua/gelbooru/tags/catalog.lua` with first-letter hash bucket candidate lookup, popularity-weighted logarithmic scoring, category relevance nudges, meta tag pinning, full-list substring fallbacks, and live API fallback triggers.
- Ticket 03 resolved: Implemented runtime dynamic tag discovery (`record_discovered`), dead tag pruning (`prune_tag`), post tag resolution (`resolve_post_tags`), and private debounce timer encapsulation (`save_timer`, `prune_timer`, `api_tag_timer`) in `lua/gelbooru/tags/catalog.lua`, backed by comprehensive unit tests.
- Ticket 04 resolved: Refactored autocomplete UI to query tag catalog directly, removed legacy timers from global State, deleted deprecated tags/db.lua and tags/resolve.lua, replaced tags/init.lua facade with catalog module re-exports, and verified all tests pass.
