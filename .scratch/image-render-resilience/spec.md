# Spec: Image Rendering & Local Library Resilience

Status: ready-for-agent

## Problem Statement

When browsing through images rapidly in `gelbooru.nvim` using navigation keys (`j`, `k`, `gg`, `G`), the image preview canvas frequently breaks down and displays an unrecoverable error:
`# Image Conversion Failed: ## identify identify: improper image header`
This error persists even when revisiting the same image, permanently corrupting that post's preview until the user manually digs into hidden system cache directories to delete corrupted files.

Furthermore, when browsing local directories containing non-Gelbooru images (such as Pixiv illustrations named `131102272_p0.jpg` or hash-named files like `74c142921564d5417585a9215bd2c9ee.jpeg`), the browser experiences severe performance degradation and UI freezes because the local scanner mistakenly treats 9-digit Pixiv IDs as Gelbooru post IDs and fires hundreds of failing curl requests to the remote API. Non-Gelbooru images also display placeholder `? ★0 0x0` dimensions because image resolutions are never resolved without remote metadata.

## Solution

1. **Self-Healing Conversion & Cache Lifecycle**: Harden the image conversion lifecycle so that aborting an in-flight image conversion (caused by rapid cursor navigation) immediately deletes any incomplete, 0-byte, or corrupted files on disk. Automatically detect and purge corrupted cache entries before attempting to render, preventing poisoned cache states from displaying `improper image header` errors.
2. **Strict Booru ID Disambiguation**: Restrict post ID extraction from filenames by filtering out known non-booru patterns (such as Pixiv `_p%d+` suffixes) and bounding bare numeric filenames to plausible booru ID ranges, while preserving explicit prefix bypasses (`post_`, `id_`, `ID`) as specified in repository standards.
3. **Non-Blocking On-Demand Local Dimension Resolution**: Implement a pure-Lua binary header parser capable of extracting width and height for JPEG, PNG, WebP, and GIF files in microseconds. Invoke this parser lazily during post rendering rather than synchronously during directory scanning, keeping local folder scans sub-5ms while displaying real dimensions instead of `0x0`.
4. **Test Suite Isolation**: Ensure all regression and unit tests run in strictly isolated temporary environments without touching or polluting user cache directories.

---

## User Stories

1. As a user browsing local images rapidly with `j` and `k`, I want image previews to update smoothly without crashing into "Image Conversion Failed" errors when I move off an image before it finishes loading.
2. As a user who encountered an interrupted or cancelled image conversion, I want subsequent visits to that same image to re-render cleanly rather than being permanently broken by a 0-byte cached file.
3. As a user browsing a local folder with mixed artwork (e.g. Pixiv downloads named `<id>_p0.jpg`), I want the browser to recognize that these are local images rather than Gelbooru posts so that my network queue is not flooded with hundreds of failing API requests.
4. As a user viewing local images without Gelbooru metadata, I want to see actual image dimensions (e.g. `1920x1080`) in the post list and metadata window instead of `0x0`.
5. As a user opening large local folders with thousands of images, I want directory scanning to remain instant (under 5ms) without hanging Neovim while reading file headers.
6. As a user pressing `R` (force refresh) on a local image or non-booru image, I want its cached preview to be fully cleared and re-generated on demand.
7. As a plugin developer running `make test`, I want the test suite to execute with complete memory and filesystem isolation without writing or modifying files in `~/.cache` or user configuration folders.
8. As a user scrolling past large images (e.g. 4000x5000), I want the system to avoid overwhelming the CPU with excessive spawned background conversion processes.
9. As a user viewing metadata for non-booru local images, I want the UI to present clean, readable fallback metadata without misleading error states.
10. As a maintainer of the codebase, I want all timing, ceiling, and validation constants centralized in the named constants table rather than scattered as magic numbers across modules.

---

## Implementation Decisions

### 1. Image Lifecycle & Cache Integrity
- When image conversions are cancelled mid-flight (e.g. during rapid cursor movement), the abort handler must inspect any in-progress step output files and immediately unlink any file whose size is zero or incomplete.
- A centralized cache directory resolution utility must be shared across cache cleanup and invalidation routines to eliminate duplicated logic.
- Cache validation must be targeted: when rendering an image, check and clean any corrupted cache files associated with that specific target before creating a placement, rather than running a synchronous filesystem glob across the entire cache directory on every cursor movement.
- Force refresh (`R`) must accept both numeric post IDs and local media file paths, clearing matching cache files regardless of whether a post has a Gelbooru numeric ID.

### 2. Local Filename Parsing & Booru Identification
- Centralize all ceiling thresholds in the constants table (`GELBOORU_ID_CEILING`).
- Filenames containing explicit Pixiv part markers (`_p%d+`) must never be extracted as Gelbooru post IDs.
- Bare numeric filenames must fall strictly between the minimum threshold (10,000) and the maximum plausible booru ceiling to be considered post IDs.
- Explicit booru prefixes (`gelbooru_`, `post_`, `id_`, `ID`) bypass the numeric ceiling, adhering to the documented disambiguation standards.

### 3. Pure-Lua Image Header Parsing & Lazy Dimension Resolution
- Fast binary header parsers for JPEG (SOF marker scanning across variable-length APP/Exif segments), PNG (IHDR chunk), WebP (VP8/VP8L/VP8X chunks), and GIF (logical screen descriptor) must operate in pure Lua without spawning subprocesses (`magick`, `sips`, `identify`).
- JPEG parser must support seeking or chunked reading across multi-kilobyte APP1/Exif segments to ensure dimensions are always extracted even on camera/raw-exported JPEGs.
- Directory scanning (`scan_local_folder`) must remain pure filesystem traversal (`uv.fs_scandir`) without synchronous image inspection to preserve the sub-5ms architectural invariant.
- Dimension inspection must occur lazily on demand when a post is active or rendered.

### 4. Zero-I/O Headless Test Suite Discipline
- All unit and integration tests verifying cache cleanup and conversion abort logic must point their cache directories to temporary sandboxes (`/tmp/gelbooru_test_*` or `vim.fn.tempname()`), completely isolated from the real user environment.

---

## Testing Decisions

### What makes a good test
- Tests must verify behavior exclusively through public module interfaces, avoiding coupling to internal private state.
- Tests must be completely deterministic, fast (<1s execution), and free of side effects on the developer's machine.

### Seams to test
1. **Filename Disambiguation Seam**: Tests pass various filename formats (Pixiv `_p0`, large numeric strings, booru-prefixed names, hash strings) to `extract_post_id` and assert on the returned ID or nil.
2. **Cache Pruning & Abortion Seam**: Tests create temporary 0-byte and corrupted cache fixtures in an isolated sandbox, invoke cleanup and abortion routines, and assert that corrupted files are unlinked while valid cache files remain intact.
3. **Pure-Lua Dimension Parser Seam**: Tests pass byte buffers representing valid PNG, JPEG (with large Exif headers), WebP, and GIF headers, asserting exact width and height extraction.
4. **Local Browser Integration Seam**: Integration test scans a fixture directory with mixed file types and verifies that post entries are constructed without network requests and display valid dimensions.

### Prior Art
- `tests/unit/local_spec.lua` for directory scanning and post ID extraction tests.
- `tests/unit/image_spec.lua` for URL parsing and video detection tests.
- `tests/helpers/harness.lua` for headless window and mock environment isolation.

---

## Out of Scope

- External metadata extraction (e.g. reading embedded EXIF tags, IPTC metadata, or artist comments from local file metadata).
- Re-architecting `snacks.image` itself (all fixes wrap and guard the integration cleanly from within `gelbooru.nvim`).
- Automatic reverse-image searching or booru querying via perceptual image hashing (deferred to future aggregator roadmap).

---

## Further Notes

- Once this spec is confirmed, it can be broken down into tracer-bullet tickets using `/to-tickets` in a fresh context window.
