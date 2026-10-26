# Spec: Unified Tag Catalog & Candidate Seam

Status: ready-for-agent

## Problem Statement

In `gelbooru.nvim`, tag management is split between static database loading (`lua/gelbooru/tags/db.lua`) and runtime dynamic tag discovery (`lua/gelbooru/tags/resolve.lua`).

Both modules independently manipulate over fourteen shared global state tables (including `State.tags_by_name`, category arrays, first-letter bucket maps, and discovered tag sets) and separately manage debounce timers on the global UI singleton (`UI.save_discovered_timer`, `UI.prune_disk_timer`, and `UI.api_tag_timer`). Callers are presented with an ultra-shallow 17-method forwarding facade (`lua/gelbooru/tags/init.lua`).

Furthermore, because of this fragmentation, the autocomplete engine (`lua/gelbooru/ui/autocomplete.lua`) completely bypasses the tag module's interface: it directly inspects and iterates the raw global bucket tables (`State.series_by_first`, `State.chars_by_first`, etc.) and full category arrays to perform match scoring and popularity weighting.

This results in leaky encapsulation, duplicated tag normalization logic, and high testing friction, as tests cannot exercise tag lookups or persistence without setting up the global session state singleton and its associated timer handles.

## Solution

Consolidate static tag indexing, dynamic discovery, and autocomplete candidate generation into a single deep Tag Catalog module (`lua/gelbooru/tags/catalog.lua`):
1. **Encapsulated In-Memory Catalog**: The Tag Catalog privately manages all category lists, first-letter hash buckets, and exact lookup indices, hiding these internal data structures from external callers.
2. **Unified Search & Candidate Generation**: The catalog exposes a high-level `search(prefix, opts)` interface that encapsulates first-character bucket matching, popularity scoring, substring fallbacks, and live API fallback triggers, allowing the autocomplete UI to focus solely on dropdown rendering.
3. **Integrated Discovery & Debounced Persistence**: Runtime discovered tags and disk pruning timers are managed privately within the catalog, automatically flushing changes to disk without exposing timers on the global UI singleton.

The shallow 17-method facade is retired, and offline scrapers (`tags/fetcher.lua`) interact with the catalog through clean indexing and pruning APIs.

---

## User Stories

1. As a user typing in the query bar, I want tag autocomplete suggestions to appear in under 3ms across 100k+ tags, ranked by category relevance and post popularity.
2. As a user querying newly released tags or artist names from recent posts, I want those tags to be added to the catalog and persisted to disk automatically, so that they autocomplete in future sessions.
3. As a user encountering dead or aliased tags that return zero search results, I want the system to verify and prune them from the catalog automatically, keeping my local database clean.
4. As a user opening Neovim, I want the 100k+ tag database to load progressively across event-loop turns, ensuring the editor never freezes during startup.
5. As a user browsing local or online posts, I want unknown post tags to be resolved in the background so that artist and character badges display correctly in the metadata inspector.
6. As a plugin developer writing tag tests, I want to query the tag catalog and verify search rankings through a single interface, without manually configuring global bucket tables.
7. As a maintainer of the tag subsystem, I want the 17 shallow forwarding functions in the tags facade deleted, consolidating tag operations behind a cohesive catalog module.
8. As a maintainer, I want debounce timers for disk pruning and discovery saving encapsulated within the catalog, removing timer handles from the global UI singleton.

---

## Implementation Decisions

### 1. Unified Tag Catalog Architecture
- Consolidate `tags/db.lua` and `tags/resolve.lua` into a single deep module (`lua/gelbooru/tags/catalog.lua`).
- The catalog encapsulates:
  - The static tag database divided across five categories (Series, Characters, Artists, General, Meta).
  - First-letter hash bucket maps for instant $O(1)$ prefix candidate lookups.
  - Popularity-weighted scoring algorithms.
  - Dynamic runtime discovery store with debounced disk persistence (`discovered.json`).
  - Self-healing verification and disk pruning routines.

### 2. High-Leverage Interface Definition
- Expose a compact interface:
  - `load(opts, callback)`: Progressively loads tag databases across event-loop turns.
  - `search(prefix, opts)`: Returns ranked autocomplete candidate items `{ name, category, count, score }`.
  - `resolve_post_tags(post, callback)`: Hydrates post tags in the background.
  - `record_discovered(tags)`: Records newly discovered tags from API responses.
  - `prune_tag(tag_name)`: Removes dead or invalid tags from in-memory and on-disk stores.

### 3. Autocomplete Coupling Elimination
- Refactor `lua/gelbooru/ui/autocomplete.lua` to call `tag_catalog.search(token)` directly.
- Remove all references in `autocomplete.lua` to global `State` bucket tables (`State.series_by_first`, `chars_by_first`, etc.).
- Delete `UI.save_discovered_timer`, `UI.prune_disk_timer`, and `UI.api_tag_timer` from `lua/gelbooru/core/state.lua`, encapsulating them inside the catalog.
- Replace `lua/gelbooru/tags/init.lua` with the deepened catalog interface.

---

## Testing Decisions

- **Testing External Behavior**:
  - Tests verify that `search(prefix)` returns properly ranked tags without inspecting private bucket tables.
  - Tests verify that `record_discovered(tags)` makes new tags searchable and schedules disk persistence.
  - Tests verify progressive loading completes without blocking.
- **Modules Tested**:
  - Tag Catalog: tested in `tests/unit/tag_catalog_spec.lua` with isolated fixture databases.
  - Autocomplete UI: tested in `tests/integration/autocomplete_spec.lua` through the dropdown rendering seam.
- **Prior Art**:
  - Existing tag tests in `tests/unit/db_spec.lua` and autocomplete tests in `tests/integration/autocomplete_spec.lua`.

---

## Out of Scope

- Image rendering and graphics placement (handled in Feature 01: Media & Canvas).
- Tag query parsing and pipeline stage execution (handled in Feature 02: Query Engine).
- Local folder scanning and background metadata indexing (handled in Feature 04: Local Enricher).

---

## Further Notes

- The 14 raw global tables in `State` are pruned down, significantly reducing the memory footprint and leakage of the session state singleton.
