# Issue 02: Universal Byte-Range Resumption

Status: resolved
Labels: network, download, resilience

## Description
In `lua/gelbooru/net/download.lua`, `download_async()` only enables HTTP byte-range resumption (`-C -`) when `opts.resume == true` (used only for `resume_pending_saves()`). For preview and prefetch downloads, `do_resume` evaluates to false, causing `download_async()` to delete existing `.part` files via `vim.fn.delete(tmp_dest)` and restart the multi-second transfer from byte 0.

## Goal
- Update `download_async()` to automatically enable byte-range resumption (`-C -`) whenever a `.part` file exists and has size > 1024 bytes (unless explicit `force == true` is requested).
- Preserve existing `.part` files across interruptions and resumes.
- Update `tests/unit/download_spec.lua` to assert that `-C -` is passed to `curl` when `.part` files exist for preview targets.
