# 02: Self-Healing Cache Lifecycle & In-Flight Conversion Abort Cleanup

**What to build:** Prevent and recover from `# Image Conversion Failed: ## identify identify: improper image header` errors during rapid navigation. Aborting an in-flight image conversion cleans up incomplete or 0-byte step files on disk. Centralize cache path resolution in `image.lua`, detect and clean corrupt cache entries before placement creation, support force refresh (`R`) for both numeric post IDs and local media file paths, and ensure unit tests run in temporary sandboxes rather than modifying real user cache paths.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] Centralized cache directory resolution helper in `lua/gelbooru/ui/image.lua` (eliminating duplicated `vim.fn.stdpath("cache")` lookups).
- [x] `abort_convert(placement)` in `lua/gelbooru/ui/image.lua` unlinks any partial 0-byte step files on disk when aborted mid-flight.
- [x] `clean_corrupt_snacks_cache(target)` removes 0-byte or corrupted cache files for the target before creating a placement.
- [x] `clear_snacks_cache_for(post_id_or_path)` invalidates cache by post ID or local file basename, and calls `clean_corrupt_snacks_cache`.
- [x] `render_image` invokes corrupt cache check prior to placement creation.
- [x] Unit tests in `tests/unit/image_spec.lua` verify abort cleanup and cache sanitization in an isolated temporary sandbox (`/tmp/gelbooru_test_*` or `vim.fn.tempname()`).

## Answer

### Implementation Details
1. **Centralized Snacks Cache Directory Resolution**:
   - Implemented `image.get_snacks_cache_dir()` in `lua/gelbooru/ui/image.lua`, centralizing lookup to `vim.fn.stdpath("cache") .. "/snacks/image"` while supporting `image._snacks_cache_dir` override for sandboxed test isolation.
2. **In-Flight Image Conversion Abort & Partial File Cleanup**:
   - Implemented `image.abort_convert(placement)` in `lua/gelbooru/ui/image.lua`. When an in-flight convert process is aborted during rapid navigation, it safely inspects `placement.img._convert.steps` and unlinks partial 0-byte output files and `.info` companion files from disk, preventing `identify: improper image header` errors on subsequent attempts.
3. **Targeted Corrupt Cache Detection & Sanitization**:
   - Implemented `image.clean_corrupt_snacks_cache(target)` to detect and unlink 0-byte or corrupted cache files and error-containing `.info` metadata files matching the target path prefix or basename before placement creation.
   - Updated `render_image` to invoke `clean_corrupt_snacks_cache` prior to creating or updating placements.
4. **Unified Cache Invalidation**:
   - Enhanced `image.clear_snacks_cache_for(post_id_or_path)` to invalidate snacks cache files by numeric post ID, file path, or basename, clearing associated `vthumb_<id>.jpg` files and invoking `clean_corrupt_snacks_cache`.
   - Updated `render.force_refresh()` and keymap handlers so force refresh (`R`) invalidates cache by `p.id or dest or p.file_url`.

### Test Verification
- Added 6 comprehensive unit tests to `tests/unit/image_spec.lua`:
  - `get_snacks_cache_dir` returns isolated sandbox directory when set.
  - `abort_convert` safely aborts conversion and unlinks partial 0-byte step files and `.info` companions while preserving completed step files.
  - `clean_corrupt_snacks_cache` detects and unlinks 0-byte cache and `.info` files for the target without touching unrelated cache files.
  - `clean_corrupt_snacks_cache` detects and unlinks `.info` files containing error messages (e.g. `identify: improper image header`).
  - `clear_snacks_cache_for` invalidates cache and thumbnails by numeric post ID.
  - `clear_snacks_cache_for` invalidates cache by local file path and basename, with safe no-op handling for nil/empty inputs.
- All tests run in isolated temporary directory sandboxes (`vim.fn.tempname()`) without touching real user caches.
- Verified all unit and integration test suites pass with 0 failures and 0 errors via `make test`.
