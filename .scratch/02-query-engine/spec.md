# Spec: Query Engine Collapse & Pipeline Consolidation

Status: ready-for-agent

## Problem Statement

In `gelbooru.nvim`, query execution is fragmented across four shallow submodules (`query/parse.lua`, `query/pipeline.lua`, `query/filter.lua`, and `query/sort.lua`) that suffer from circular dependencies and leaky abstractions. Specifically, `pipeline.lua` requires `parse.lua` at top level, while `parse.lua` must lazily require `pipeline.lua` inside its tag parsing function to avoid a module initialization cycle.

This fragmentation is fronted by an 18-method pass-through facade (`lua/gelbooru/query/init.lua`), which is further mirrored by a 6-line alias file (`lua/gelbooru/local/query.lua`). Callers in the API client, local folder browser, and background indexer are forced to coordinate multi-stage query execution manually: they must tokenize strings, normalize spacing, parse pipeline stages, filter post arrays, sort posts, and execute pipeline slices across separate function calls.

This wide interface leaks internal execution order to callers, makes pipeline behavior harder to trace, and complicates testing by forcing tests to interact with four distinct modules rather than evaluating queries through a single cohesive interface.

## Solution

Collapse the query subsystem into a single deep Query Engine module (`lua/gelbooru/query/engine.lua`) presenting two primary operations:
1. `prepare(query_str)`: Tokenizes and normalizes the query string into a structured execution plan, cleanly identifying target directories (for local searches), remote booru tags (for online searches), post filter criteria, and pipeline stages.
2. `evaluate(posts, plan)`: Atomically evaluates the post array against the prepared plan—applying criteria matching, sorting, multi-stage pipeline transforms, and range/limit slicing in sequence.

By consolidating stage parsing into the parser and embedding pipeline evaluation within the engine, the circular `require` cycle is eliminated, the 18-method forwarding facade and redundant alias are deleted, and callers evaluate queries and post arrays in a single step.

---

## User Stories

1. As a user searching for tags with modifiers (e.g. `rating:general score:>=50`), I want all criteria to be parsed and applied consistently across both online and local searches.
2. As a user chaining operations with pipes (e.g. `hatsune_miku | sort:score | 1..30`), I want the query engine to evaluate all stages sequentially without UI lag.
3. As a user browsing a local directory with complex filters (e.g. `local:~/Art/ -tag1 ~rating:general | sort:date`), I want the local path and filtering stages to be separated cleanly in a single preparation step.
4. As a user running single-tag or multi-tag searches with tildes or negative tags, I want boolean logic and tag matching to evaluate accurately against post metadata.
5. As a user applying range or limit directives (e.g. `1000..1200`, `limit:50`, `offset:100`), I want dataset slicing to be calculated efficiently without off-by-one errors or duplicate items.
6. As a user entering queries with erratic modifier spacing (e.g. `sort: score:50`), I want automatic modifier spacing normalization so that queries never fail due to formatting quirks.
7. As a plugin developer writing query tests, I want to pass a query string and a list of posts to a single evaluation function and receive the sliced result, so that tests do not need to coordinate parser, pipeline, filter, and sort modules independently.
8. As a maintainer of the query subsystem, I want circular require dependencies between parser and pipeline modules eliminated, so that module loading is reliable and free of hidden initialization order traps.
9. As a maintainer, I want the 18 shallow forwarding functions in the query facade and redundant local query aliases deleted, shrinking the codebase surface area and making navigation straightforward.
10. As a network client or local browser caller, I want to query whether a search plan requires pagination or multi-branch fetching through simple plan properties, without manually inspecting raw query strings.

---

## Implementation Decisions

### 1. Unified Query Engine Architecture
- Create `lua/gelbooru/query/engine.lua` consolidating query tokenization, modifier normalization, pipeline stage parsing, post filtering, and post sorting behind a single module.
- Move pipeline stage parsing logic directly into the parsing workflow, ensuring that stage extraction and tag parsing occur without cross-requiring separate modules.
- Sorting algorithms (score, id, mtime, random) and condition evaluators remain pure internal helpers behind the engine seam.

### 2. High-Leverage Interface Definition
- Expose a compact, high-leverage interface:
  - `prepare(query_str)`: Takes a raw query string and produces a normalized execution plan:
    - Target directory path (if local).
    - Remote booru tag string (if online).
    - Structured filter criteria (positive tags, negative tags, OR clauses, ratings, score comparisons, IDs).
    - Pipelined execution stages (sort keys, directions, limits, offsets, ranges).
    - Metadata flags (`is_local`, `is_random`, `is_pipeline`, `has_range`).
  - `evaluate(posts, plan)`: Evaluates an in-memory post array against a prepared execution plan and returns the transformed, sliced post array.
  - `normalize_remote(tags_str)`: Formats query tokens into clean remote query branches for the REST API client.
  - `matches(post, plan)`: Evaluates a single post item against the plan's criteria.

### 3. Elimination of Facades & Aliases
- Deprecate and remove the 18-method forwarding facade (`lua/gelbooru/query/init.lua`).
- Delete the 6-line alias file (`lua/gelbooru/local/query.lua`).
- Refactor the REST API client (`net/api.lua`) and local browser controller (`local/init.lua`) to call `prepare()` and `evaluate()` directly.

---

## Testing Decisions

- **Testing External Behavior**:
  - Tests verify that `prepare()` produces the expected execution plan for various query expressions (pipes, ranges, modifiers, local prefixes).
  - Tests verify that `evaluate()` transforms raw post arrays correctly according to filters, sort orders, limits, and offsets.
  - Tests verify that circular require issues no longer exist when requiring the query engine.
- **Modules Tested**:
  - Tested headlessly in `tests/unit/query_engine_spec.lua` with input/output assertions.
- **Prior Art**:
  - Existing query unit tests in `tests/unit/query_spec.lua` and pipeline integration tests in `tests/integration/pipeline_stress_spec.lua`.

---

## Out of Scope

- Image rendering and graphics placement (handled in Feature 01: Media & Canvas).
- Tag autocomplete and dynamic discovery (handled in Feature 03: Tag Catalog).
- Local folder scanning and background metadata indexing (handled in Feature 04: Local Enricher).

---

## Further Notes

- The deletion test is completely satisfied: deleting the 4 shallow submodules and facade concentrates complexity inside `query/engine.lua` and shrinks the surface area for callers.
