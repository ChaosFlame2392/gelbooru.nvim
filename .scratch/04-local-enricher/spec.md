# Spec: Headless Local Enrichment Worker & Event Seam

Status: ready-for-agent

## Problem Statement

In `gelbooru.nvim`, the background metadata indexing pipeline (`lua/gelbooru/local/indexer.lua`) is tightly coupled with the user interface.

Specifically, when indexing local files in the background, network callbacks inside the indexer directly mutate UI cursor state (`State.cur`), trigger post list repaints (`ui.render_list()`), format metadata buffers (`ui.render_metadata()`), and recalculate window layout geometry. Furthermore, timer handles and task queues are exposed on the global UI singleton (`UI.indexer_task_id`, `UI.prefetch_timers`).

This deep coupling causes severe architectural friction:
- The background worker acts as an active UI controller rather than a focused data enrichment pipeline.
- Network callbacks executing across event-loop turns can mutate UI cursor state and trigger window repaints unexpectedly while the user is actively navigating.
- Headless testing of indexing concurrency, rate limiting, and queue management is extremely difficult because test suites must mock floating windows, buffers, and UI presentation handles just to verify background metadata fetching.

## Solution

Decouple the background metadata indexer from UI state by introducing an Event-Driven Enrichment Worker (`lua/gelbooru/local/enricher.lua`):
1. **Headless Enrichment Worker**: A data-pipeline module that accepts posts or numeric IDs to hydrate. It manages concurrency limits, queue pacing timers, head-pointer queue management, and epoch-based request cancellation internally. Upon completing a metadata fetch, it notifies callers via a clean callback seam: `on_post_hydrated(post)`.
2. **UI Subscription Controller**: The local browser controller (`lua/gelbooru/local/init.lua`) subscribes to hydration events. It decides when to re-filter the local folder, how to track cursor movement on the focused item, and when to trigger window repaints.

The worker contains zero references to floating windows, cursor indices, or UI rendering functions, enabling it to be tested and operated in complete isolation.

---

## User Stories

1. As a user opening a local directory with unindexed booru images, I want metadata (tags, ratings, scores, dimensions) to hydrate smoothly in the background without UI freezes.
2. As a user scrolling through a local folder, I want posts near my cursor to be prioritized for metadata lookahead, so that the images currently in view populate first.
3. As a user navigating a sorted local library, I want post re-sorting and cursor tracking to remain smooth as metadata scores hydrate, without jumping to the wrong image.
4. As a user switching to a new search query while local background indexing is running, I want previous background tasks to cancel cleanly, so that old callbacks do not overwrite new search results.
5. As a user on a rate-limited connection, I want the indexer to pace background requests smoothly (e.g. 100ms intervals with a concurrency limit of 2), preventing connection drops.
6. As a plugin developer writing concurrency tests, I want to test queue pacing, worker replenishment, and rate limiting headlessly, without spinning up Neovim floating windows or mocking UI buffers.
7. As a maintainer, I want all UI repainting, status messages, and cursor preservation logic localized in the UI controller, rather than triggered from inside worker network callbacks.
8. As a maintainer, I want timer handles and queue structures fully encapsulated within the worker module, rather than exposed on the global UI singleton.

---

## Implementation Decisions

### 1. Headless Enrichment Worker Architecture
- Replace `lua/gelbooru/local/indexer.lua` with a headless module `lua/gelbooru/local/enricher.lua`.
- The worker encapsulates:
  - FIFO work queue with head-pointer advancement to avoid array re-indexing overhead.
  - Concurrency management (maintaining a strict maximum of 2 concurrent workers).
  - Pacing timers (enforcing a 100ms interval between batch dispatches).
  - Epoch-based cancellation (discarding completion callbacks if the search epoch advances).
  - Cursor rush lookahead prioritization.

### 2. Event-Driven Seam
- Expose a lean interface:
  - `enqueue(posts, opts, on_post_hydrated)`: Enqueues posts for background hydration and registers completion event handler.
  - `prioritize_near(cursor_idx, radius)`: Moves items near the cursor to the front of the queue.
  - `cancel()`: Terminates active and pending enrichment tasks immediately.
  - `is_active()`: Returns boolean status of active indexing.

### 3. UI Controller Subscription
- `lua/gelbooru/local/init.lua` orchestrates local browsing and subscribes to `on_post_hydrated(post)`:
  - Re-applies active sort filters if sorting by score.
  - Preserves cursor on the active post ID during re-sorts.
  - Schedules debounced window repaints (`render_list`, `render_metadata`).
- All window manipulation, cursor setting, and UI rendering are purged from the worker.

---

## Testing Decisions

- **Testing External Behavior**:
  - Tests verify that `enqueue()` processes posts and invokes `on_post_hydrated` with enriched metadata.
  - Tests verify concurrency clamping to 2 and pacing interval of 100ms headlessly.
  - Tests verify `cancel()` prevents subsequent callbacks from firing.
- **Modules Tested**:
  - Enrichment Worker: tested in `tests/unit/local_enricher_spec.lua` without UI mocks.
  - Local Browser Integration: tested in `tests/integration/local_spec.lua`.
- **Prior Art**:
  - Concurrency stress tests in `tests/integration/pipeline_stress_spec.lua`.

---

## Out of Scope

- Binary image decoding and canvas placement (handled in Feature 01: Media & Canvas).
- Query syntax parsing and pipeline stage transforms (handled in Feature 02: Query Engine).
- Autocomplete candidate generation (handled in Feature 03: Tag Catalog).

---

## Further Notes

- The worker delegates remote metadata HTTP queries directly to `net.api.fetch_post_metadata`, preserving existing disk caching without duplicating storage logic.
