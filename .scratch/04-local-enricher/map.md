# Map: Headless Local Enrichment Worker & Event Seam

## Task Graph & Frontier

- **01: Headless Enrichment Queue & Pacing Engine**
  - Path: `.scratch/04-local-enricher/issues/01-headless-enrichment-queue.md`
  - Blocked by: None
  - Status: ready-for-agent

- **02: Pacing Timer Encapsulation & Epoch Cancellation**
  - Path: `.scratch/04-local-enricher/issues/02-pacing-timer-encapsulation-and-lifecycle.md`
  - Blocked by: 01
  - Status: ready-for-agent

- **03: UI Subscription & Cursor Coordination**
  - Path: `.scratch/04-local-enricher/issues/03-ui-subscription-and-cursor-coordination.md`
  - Blocked by: 01, 02
  - Status: ready-for-agent

## Decisions-so-far
- Baseline test suite is 100% green on `main`.
- `local/indexer.lua` is replaced with `local/enricher.lua`.
- UI presentation manipulation, cursor mutation, and window redraws are removed from the worker.
- The worker notifies callers via `on_post_hydrated(post)`.
