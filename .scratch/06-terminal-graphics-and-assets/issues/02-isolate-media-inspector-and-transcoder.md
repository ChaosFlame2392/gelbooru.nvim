# 02: Untangle Media Subsystem: Extract Pure Inspector & Isolated Transcoder

**What to build:** Decompose the 1,320-line `lua/gelbooru/media/resolver.lua` by extracting pure binary dimension and format verification into `lua/gelbooru/media/inspector.lua`, and subprocess `ffmpeg` lifecycle into `lua/gelbooru/media/transcoder.lua`. Preserve 100% of the current video thumbnailing user experience and keep `resolver.lua` backwards-compatible.

**Type:** task

**Status:** resolved

**Blocked by:** 01

### Scope & Technical Decisions:
1. **Pure Binary Inspector (`lua/gelbooru/media/inspector.lua`)**:
   - Zero side effects, zero Neovim window/buffer dependencies, sub-millisecond execution.
   - Strictly forbidden from spawning CLI child processes (`ffmpeg`, `magick`, `identify`).
   - Binary header seeking:
     - PNG: 8-byte signature `\137PNG\r\n\026\n`, IHDR chunk dimensions, and trailing IEND marker verification.
     - GIF: `GIF87a`/`GIF89a` signature, screen dimensions, trailing semicolon (`;`).
     - WebP: RIFF header, WEBP fourcc, payload chunk traversal (VP8 lossy, VP8L lossless, VP8X extended).
     - JPEG: SOI `\255\216`, SOF marker scanning (`SOF0` through `SOF15` excluding DHT/DQT), EOI `\255\217`.
   - `is_gif_animated(path)`: Robust GIF block parser that traverses Logical Screen Descriptor, skips global/local color tables and extension sub-blocks, and counts Image Descriptors (`0x2C`) outside of LZW data. Returns `true` as soon as frame count > 1.
   - `is_info_corrupt(content)`: Pure string inspector detecting ImageMagick corruption keywords.
   - `inspect(path)`: Returns `{ width, height, format, is_animated, is_complete }`.

2. **Isolated Transcoder (`lua/gelbooru/media/transcoder.lua`)**:
   - Manages OS child processes for video transcoding (`ffmpeg`) with deterministic handle tracking and lifecycle cancellation.
   - **Distraction-Free Video Contract**:
     - During post browsing/navigation: strictly extracts a clean single-frame static thumbnail (`vthumb_<id>.jpg`), avoiding janky in-terminal live video streaming inside tmux.
     - Full video playback is handled externally on demand via `O` (IINA, VLC, `open`).
     - Exposes `transcode_animation_loop` as a reserved extension slot for future looping video clips without altering browse path behavior.
   - `abort_video_transcodes()`: Loops over active handles, sends `SIGKILL` (signal 9), unlinks partial `.part` files and corrupt thumbnails (`<= 512` bytes or incomplete), and resets handle tracking.
   - `extract_video_thumbnail(video_path, post_or_id, cb)`: Spawns `ffmpeg -ss 00:00:01 -i <path> -frames:v 1 -q:v 2 <dest>.part -y`, tracks handle in `active_ffmpeg_handles`, atomically renames on success, and invokes callback.

3. **Resolver Delegation & Backwards Compatibility (`lua/gelbooru/media/resolver.lua`)**:
   - Re-exports all inspector and transcoder functions so existing callers and test suites continue to work seamlessly:
     - `read_image_dimensions`, `is_image_complete`, `is_info_corrupt`, `is_gif_animated`, `inspect` -> `media.inspector`
     - `is_video_post`, `get_video_thumbnail_path`, `get_saved_video_path`, `abort_video_transcodes`, `extract_video_thumbnail` -> `media.transcoder`
   - Keeps cache forensics and scrubbing (`clean_corrupt_snacks_cache`, `clear_cache`) and wires `transcoder.clean_cache_hook` to clean snacks cache on corrupt video thumbnail abortion.
   - Preserves `M.active_ffmpeg_handles` table reference identity for existing test assertions.

4. **Testing Protocol**:
   - Add unit tests in `tests/unit/inspector_spec.lua` running against binary fixtures without mocks.
   - Ensure all existing tests in `tests/unit/media_resolver_spec.lua` remain 100% green.

### Acceptance Criteria:
- [x] `lua/gelbooru/media/inspector.lua` handles all binary parsing with zero child processes.
- [x] `inspector.is_gif_animated` correctly detects multi-frame GIFs and avoids false positives on static GIFs.
- [x] `lua/gelbooru/media/transcoder.lua` encapsulates `ffmpeg` tracking, `SIGKILL` termination, and single-frame thumbnail extraction.
- [x] `lua/gelbooru/media/resolver.lua` cleanly delegates to `inspector` and `transcoder` while keeping 100% backwards compatibility.
- [x] Pure unit tests in `tests/unit/inspector_spec.lua` pass.
- [x] Existing `tests/unit/media_resolver_spec.lua` passes with 0 failures and 0 errors.

## Answer

Extracted and untangled media subsystem into two clean deep modules:
1. `lua/gelbooru/media/inspector.lua`:
   - Pure, zero-dependency, side-effect-free binary image dimension seeking and completion validation for PNG, GIF87a/89a, WebP (VP8, VP8L, VP8X), and JPEG (SOF0-SOF15).
   - Implemented `is_gif_animated(path)` with spec-accurate block traversal that skips Logical Screen Descriptors, Global/Local Color Tables, and extension sub-blocks to count Image Descriptors (`0x2C`) outside LZW payloads, preventing false positives on static GIFs containing `0x2C` data bytes.
   - Implemented `inspect(path)` and `is_info_corrupt(content)` with zero CLI subprocess spawning.
2. `lua/gelbooru/media/transcoder.lua`:
   - Isolated FFmpeg child process lifecycle management, tracking active handles in `active_ffmpeg_handles` and thumbnail destinations in `_ffmpeg_thumb_dests`.
   - Single-frame preview extraction (`extract_video_thumbnail`) with atomic `.part` renaming and fallback error handling.
   - `abort_video_transcodes()` with deterministic `SIGKILL` (signal 9) process cancellation, `.part` unlinking, corrupt thumbnail pruning, and clean cache hooks.
   - Added `transcode_animation_loop` extension point.
3. `lua/gelbooru/media/resolver.lua`:
   - Decomposed from 1,320 lines to ~550 lines by delegating header inspection to `media.inspector` and video transcoding to `media.transcoder`.
   - Preserved 100% backwards compatibility and `active_ffmpeg_handles` table identity via metatable `__index` and `__newindex` delegation, verified with all 41 existing resolver unit tests and entire test suite passing with 0 errors and 0 failures.
