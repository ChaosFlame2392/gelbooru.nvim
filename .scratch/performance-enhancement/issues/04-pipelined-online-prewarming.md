# 04: Pipelined Online Preview Prewarming

**What to build:** A seamless bridge connecting online preview downloads directly to the disk-to-disk graphics conversion engine. The moment a preview image completes downloading to disk, it is automatically forwarded into the background prewarmer to be converted to terminal graphics format before the user lands on the post.

**Blocked by:** 01: Local Artwork Background Prewarmer, 03: Deep Lookahead, Autopage Boundary Advance and Anti-Jitter Resilience

**Status:** completed

- [x] Successful completion of an online preview download immediately enqueues the downloaded file into the background graphics prewarmer.
- [x] Prewarming executes disk-to-disk without creating dummy Neovim buffers or premature terminal window placements.
- [x] Navigating to a freshly downloaded online post displays the image instantly (<30ms) without waiting for on-demand conversion.
- [x] Conversion failures or truncated preview images are handled gracefully and do not block subsequent queue items.
