# 03: Facade Elimination & Caller Migration

**What to build:** Retire the 18-method forwarding facade (`lua/gelbooru/query/init.lua`) and the 6-line alias (`lua/gelbooru/local/query.lua`). Migrate all callers in `net/api.lua`, `local/init.lua`, and `ui/autocomplete.lua` to call `query.engine` directly. Delete legacy shallow files (`query/parse.lua`, `query/pipeline.lua`, `query/filter.lua`, `query/sort.lua`).

**Type:** task

**Status:** resolved

**Blocked by:** 01: Query Plan Parser & Normalization, 02: Dataset Evaluator & In-Memory Pipeline Transforms

- [x] Migrate `lua/gelbooru/net/api.lua` to use `query.engine.prepare` and `query.engine.evaluate`.
- [x] Migrate `lua/gelbooru/local/init.lua` to use `query.engine.prepare` and `query.engine.evaluate`.
- [x] Migrate `lua/gelbooru/ui/autocomplete.lua` to use `query.engine.prepare`.
- [x] Delete `lua/gelbooru/query/parse.lua`, `query/pipeline.lua`, `query/filter.lua`, `query/sort.lua`.
- [x] Delete `lua/gelbooru/local/query.lua` and delete or replace `lua/gelbooru/query/init.lua` to expose only the deepened engine interface.
- [x] Update existing unit and integration test suites to call the deepened query engine interface.
- [x] Verify full test suite (`make test`) passes with 100% success.

## Answer

Ticket 03 is fully implemented, verified, and merged into `feat/query-engine-consolidation`:
- **Callers Migrated**:
  - `lua/gelbooru/net/api.lua`: migrated `execute_search`, candidate pool pipeline execution, and query normalization to `engine.prepare` and `engine.execute_pipeline`.
  - `lua/gelbooru/local/init.lua`: migrated directory resolution and local dataset evaluation to `engine.prepare` and `engine.evaluate`.
  - `lua/gelbooru/local/indexer.lua`: migrated post criteria matching to `engine.prepare` and `engine.matches`.
  - `lua/gelbooru/ui/autocomplete.lua`: uses `util.is_local_query` for zero keystroke lag and `engine.prepare` for query structuring.
- **Legacy Files Deleted**:
  - `lua/gelbooru/query/parse.lua`, `lua/gelbooru/query/pipeline.lua`, `lua/gelbooru/query/filter.lua`, `lua/gelbooru/query/sort.lua`, and `lua/gelbooru/local/query.lua` deleted (net removal of 1,600+ lines).
  - `lua/gelbooru/query/init.lua` re-exports `query.engine` as the sole package seam.
- **Verification**:
  - `make test` and `make lint` 100% passing across all 14 test suites and 27 source files.

