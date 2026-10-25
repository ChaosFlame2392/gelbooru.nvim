# 01: Query Plan Parser & Normalization

**What to build:** Implement `prepare(query_str)` in `lua/gelbooru/query/engine.lua`. It parses raw query strings into structured execution plans, extracting target directory, remote tags, filter criteria (positive tags, negative tags, OR clauses, ratings, scores), and pipeline stages (`sort`, `limit`, `offset`, ranges) without requiring external pipeline submodules.

**Type:** task

**Status:** resolved

**Blocked by:** None

- [x] Create `lua/gelbooru/query/engine.lua`.
- [x] Implement `prepare(query_str)` producing a unified execution plan with flags (`is_local`, `is_random`, `is_pipeline`, `has_range`).
- [x] Implement modifier spacing normalization (e.g. `sort: score:50` -> `sort:score score:50`).
- [x] Support pipeline stage splitting on `|` and bare ranges (`500..600`, `..200`, `100..`).
- [x] Implement `normalize_remote(tags_str)` producing clean remote booru tag branches without invalid sort suffixes.
- [x] Unit tests in `tests/unit/query_engine_spec.lua` verify preparation of simple, modifier, piped, and local queries.

## Answer

Ticket 01 is implemented, tested, and merged into `feat/query-engine-consolidation`:
- **Module Implementation (`lua/gelbooru/query/engine.lua`)**:
  - Implemented `prepare(query_str)` producing a structured `QueryPlan` table containing:
    - Root flags: `is_local`, `is_random`, `is_pipeline`, `has_range`, `has_filter`.
    - Local directory detection and extraction (`dir`, `local_tags`), handling bare directory paths, `local:dir`, quoted paths with spaces, and fallback to `config.options.save_dir`.
    - Criteria extraction: `positive_tags`, `negative_tags`, `or_tags` (intra-tag `|` and `~`), `ratings`, `scores`, `artists`, `characters`, `ids`.
    - Pipeline stages: splits pipeline on `|`, parses `sort`, `limit`, `offset`, and bare or modifier ranges (`start_idx..end_idx`), normalizing inverted ranges.
    - Modifier spacing normalization for separated colons (`sort: score:50`, `rating: general`, etc.).
  - Implemented `normalize_remote(tags_str)`:
    - Strips leading `~` from modifiers.
    - Cleans invalid suffixes from remote sort directives (e.g. `sort:id:asc` -> `sort:id`).
    - Applies de-Morgan negation on multi-rating queries.
    - Expands tilde OR tags into concurrent query branches and removes standalone pipe characters.
- **Verification (`tests/unit/query_engine_spec.lua`)**:
  - 27 unit tests verifying empty/nil query handling, criteria extraction, modifier normalization, range parsing, local directory parsing, and remote query normalization.
  - Full suite verified clean via `make test` and `make lint`.
