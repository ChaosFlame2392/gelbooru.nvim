# 01: Local Artwork Background Prewarmer

**What to build:** When opening a local directory or navigating saved artwork, upcoming high-resolution images and videos in the active scroll direction (and immediate reverse radius) are proactively converted to terminal graphics format and cached on disk in the background. Navigating to an upcoming post displays the artwork instantaneously without an on-demand graphics conversion stall.

**Blocked by:** None (can start immediately)

**Status:** closed

- [x] Navigating a local folder with `j` or `k` kicks off background graphics conversion for upcoming uncached images in the active direction.
- [x] Opening a local directory for the first time starts prewarming the initial posts near the top of the list immediately.
- [x] For video files in a local folder, video thumbnails are extracted and cached in the background ahead of time.
- [x] Navigating to a prewarmed local image or video thumbnail displays the preview in <30ms on first visit.
- [x] Background prewarming operates across concurrent workers without causing UI stutter.
- [x] Invalid or corrupted image files are handled gracefully without aborting the prewarm queue.
