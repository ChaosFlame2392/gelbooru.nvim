# Map: High-Performance Network Pipeline & Resilient Lookahead Prefetching

## Task Graph & Frontier

- **01: Decoupled Request Abortion**
  - Path: `.scratch/05-network-and-prefetch/issues/01-decoupled-request-abortion.md`
  - Blocked by: None
  - Status: resolved

- **02: Universal Byte-Range Resumption**
  - Path: `.scratch/05-network-and-prefetch/issues/02-universal-byte-range-resumption.md`
  - Blocked by: 01
  - Status: resolved

- **03: Eager Lookahead & Overlapped Concurrency**
  - Path: `.scratch/05-network-and-prefetch/issues/03-eager-lookahead-and-concurrency.md`
  - Blocked by: 01, 02
  - Status: resolved

## Decisions-so-far
- Baseline test suite is 100% green on `main`.
- Network latency to Gelbooru CDN is dominated by TLS negotiation (~1.7s) and TTFB (~1.4s), requiring overlapped concurrency and byte-range resumption.
- Lookahead prefetching must remain uninterrupted during sequential cursor movements in the active direction.
- Decoupled request abortion (Task 01): `download.abort_all()` removed from `resolver.abort_active()`. Active downloads and prefetch lookahead now continue unimpeded across cursor movement, while request epoch invalidation shields canvas presentation from stale completion. Global download abortion is strictly anchored to query boundaries (`api.execute_search`), history restoration (`history.restore_history`), and UI teardown.
- Universal byte-range resumption (Task 02): `download.download_async` automatically passes `-C -` to curl whenever a `.part` file exists and is larger than 1024 bytes (unless `force = true` or `opts.resume == false`). Partial `.part` files are preserved across aborted requests instead of being deleted, avoiding repeated multi-second transfers from byte 0 on cursor re-entry.
- Eager lookahead & overlapped concurrency (Task 03): `download.prefetch_around()` is triggered immediately upon cursor movement in `render_preview()`, decoupling prefetching from the visual preview canvas debounce timer (`scroll_timer`). Top lookahead targets in the active scroll direction (`idx + dir` and `idx + 2 * dir`) are dispatched concurrently without delay to overlap remote TLS handshakes and saturate bandwidth, while subsequent targets remain staggered. Prefetch handle cleanup safely purges finished transfers without killing in-flight requests.
- Code Review Fixes: Centralized `PREFETCH_LOOKAHEAD_DEPTH = 2` in `core/constants.lua`, eliminated bare magic number `1024` in favor of `constants.MIN_VALID_MEDIA_BYTES`, structured lookahead target loop cleanly in `download.lua`, and pruned duplicate legacy prefetch call inside `render.lua` `scroll_timer`.
