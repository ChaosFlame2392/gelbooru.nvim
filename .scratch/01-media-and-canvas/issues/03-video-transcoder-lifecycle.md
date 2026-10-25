# 03: Video Transcoder Lifecycle & Process Tracking

**What to build:** Decouple FFmpeg child process spawning, handle tracking, and SIGKILL termination into the Media Resolver module. When resolving a video post, automatically yield cached `vthumb_<id>.jpg` thumbnails or produce them in the background with clean cancellation when the user scrolls past.

**Type:** task

**Status:** resolved

**Blocked by:** 01: Headless Media Resolver Seam & Binary Verification

- [x] Video posts with existing `vthumb_<id>.jpg` in volatile cache resolve immediately without spawning processes.
- [x] Video posts without thumbnails spawn background FFmpeg jobs with tracked child handles using `vim.system`.
- [x] Implement `abort_video_transcodes()` in `media/resolver.lua` using `SIGKILL` on active child handles.
- [x] Rapid navigation or UI teardown invokes clean cancellation without leaking child processes.
- [x] Unit tests in `tests/unit/media_resolver_spec.lua` verify video thumbnail cache path resolution, FFmpeg arguments, and process termination.

## Answer

Implemented video transcoder lifecycle, thumbnail caching, and child process tracking in `lua/gelbooru/media/resolver.lua`:
- Fast-path cached video resolution: Video posts with an existing valid `vthumb_<id>.jpg` in volatile cache (size > 512 bytes and passing `is_image_complete` format verification) resolve immediately without spawning FFmpeg child processes. Corrupt or truncated (<512 bytes) thumbnail files are scrubbed and re-generated.
- Background process tracking: `resolver.extract_video_thumbnail(video_path, post_id, cb)` spawns FFmpeg child jobs using `vim.system({"ffmpeg", "-ss", "00:00:01", "-i", video_path, "-frames:v", "1", "-q:v", "2", thumb_dest, "-y"})`, registering handles in `resolver.active_ffmpeg_handles` and tracking target thumbnail paths in `resolver._ffmpeg_thumb_dests`. Handles are automatically untracked upon process exit.
- Process termination & cleanup: `resolver.abort_video_transcodes()` (and alias `resolver.abort_all_ffmpeg`) sends `SIGKILL` (signal 9) inside error-protected `pcall` to all active child handles, removes partial or 0-byte output thumbnail artifacts from disk and snacks cache, suppresses stale exit callbacks, and clears tracking tables.
- Cancellation integration: Wired `abort_video_transcodes()` into `resolver.abort_active()`, ensuring rapid scrolling, query switching, or UI teardown instantly cancels running transcode jobs without leaking child processes.
- Missing tool resilience: Gracefully handles environments where `ffmpeg` is not executable by yielding the raw video path directly with `is_thumbnail = false` without error.
- Verified with 36 headless unit tests in `tests/unit/media_resolver_spec.lua` covering path formatting, arguments, handle registration, abort cleanup, and process killing, with `make test` running 100% green (0 failures / 0 errors).
