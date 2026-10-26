# Issue 01: Decoupled Request Abortion

Status: resolved
Labels: network, media, lifecycle

## Description
In `lua/gelbooru/media/resolver.lua`, `resolver.abort_active()` invokes `download.abort_all()`. Every time `load_and_render_image()` runs during cursor navigation, all active downloads in `M.active_handles` (including background lookahead prefetches for adjacent posts) are violently killed via `SIGKILL (9)`.

## Goal
- Modify `resolver.abort_active()` to increment the active request epoch, abort FFmpeg video transcodes, and close canvas image placement, without invoking `download.abort_all()`.
- Ensure active prefetch downloads in the current scroll direction continue downloading unimpeded.
- Update `tests/unit/media_resolver_spec.lua` to verify that `resolver.abort_active()` preserves active background downloads while ignoring stale callbacks.
