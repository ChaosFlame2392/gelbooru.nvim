# Map: Query Engine Collapse & Pipeline Consolidation

## Task Graph & Frontier

- **01: Query Plan Parser & Normalization**
  - Path: `.scratch/02-query-engine/issues/01-plan-parser-and-normalization.md`
  - Blocked by: None
  - Status: resolved

- **02: Dataset Evaluator & In-Memory Pipeline Transforms**
  - Path: `.scratch/02-query-engine/issues/02-dataset-evaluator-and-sorting.md`
  - Blocked by: None
  - Status: resolved

- **03: Facade Elimination & Caller Migration**
  - Path: `.scratch/02-query-engine/issues/03-facade-elimination-and-caller-migration.md`
  - Blocked by: 01, 02
  - Status: resolved

## Decisions-so-far
- Baseline test suite is 100% green on `main`.
- Circular dependency between `parse.lua` and `pipeline.lua` is eliminated by combining parsing and stage evaluation in `lua/gelbooru/query/engine.lua`.
- 18-method facade in `query/init.lua` and 6-line alias `local/query.lua` are deleted.
- Ticket 01 resolved: Created `lua/gelbooru/query/engine.lua` with `prepare(query_str)` (QueryPlan generation, criteria parsing, modifier normalization, pipeline range extraction) and `normalize_remote(tags_str)` ([01-plan-parser-and-normalization.md](file:///Users/balkrishan/Development/gelbooru.nvim/.scratch/02-query-engine/issues/01-plan-parser-and-normalization.md)).
- Ticket 02 resolved: Implemented `engine.matches` and `engine.evaluate` in `lua/gelbooru/query/engine.lua` with criteria matching, sorting (score, id, mtime, random), and pipeline range/offset/limit slicing ([02-dataset-evaluator-and-sorting.md](file:///Users/balkrishan/Development/gelbooru.nvim/.scratch/02-query-engine/issues/02-dataset-evaluator-and-sorting.md)).
- Ticket 03 resolved: Migrated all callers (`net/api.lua`, `local/init.lua`, `local/indexer.lua`, `ui/autocomplete.lua`) to `query.engine`, deleted 5 legacy files, preserved O(1) autocomplete latency, resolved code-review findings, and verified 100% test pass ([03-facade-elimination-and-caller-migration.md](file:///Users/balkrishan/Development/gelbooru.nvim/.scratch/02-query-engine/issues/03-facade-elimination-and-caller-migration.md)).
