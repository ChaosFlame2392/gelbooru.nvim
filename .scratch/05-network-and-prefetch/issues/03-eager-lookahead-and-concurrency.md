# Issue 03: Eager Lookahead & Overlapped Concurrency

Status: resolved
Labels: network, prefetch, ui

## Description
Currently, `download.prefetch_around()` is only called inside the 150ms `scroll_timer` debounce callback in `lua/gelbooru/ui/render.lua`. During active cursor scrolling (`j`/`k`), the debounce timer is repeatedly restarted, preventing prefetching from ever running until navigation stops. In addition, lookahead posts are staggered by 50ms delays, leaving high-speed network connections idle while waiting sequentially for remote TLS handshakes.

## Goal
- Trigger `download.prefetch_around()` eagerly upon cursor movement in `render_preview()`, decoupling prefetching from the visual preview canvas debounce.
- Dispatch top lookahead targets (immediate next posts) concurrently without delay, allowing TLS handshakes to overlap and saturating bandwidth.
- Update `tests/unit/download_spec.lua` and `tests/integration/pipeline_stress_spec.lua` to verify eager prefetch dispatch and concurrent handle tracking.
