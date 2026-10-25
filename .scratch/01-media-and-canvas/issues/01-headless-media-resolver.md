# 01: Headless Media Resolver Seam & Binary Verification

**What to build:** A standalone headless Media Resolver module (`lua/gelbooru/media/resolver.lua`) that takes a post model and resolves it to a verified local media file (`{ path, is_video, is_thumbnail, width, height }`). Encapsulates URL candidate priority (`sample_url` -> `preview_url` -> `file_url`), corrupt snacks cache detection, binary completion validation, and lazy dimension parsing, completely decoupled from Neovim windows and terminal graphics protocols.

**Type:** task

**Status:** resolved

**Blocked by:** None

- [x] Create `lua/gelbooru/media/resolver.lua` with asynchronous `resolve(post, opts, callback)` contract.
- [x] Migrate `read_image_dimensions` and `is_image_complete` from `lua/gelbooru/core/util.lua` into `media/resolver.lua`.
- [x] Implement candidate URL fallback chain (`sample_url` -> `preview_url` -> `file_url`) for online posts, and local file path resolution for saved posts.
- [x] Pre-resolution cache forensics detect and scrub 0-byte or truncated cache files before returning paths.
- [x] Lazy dimension resolution caches `width` and `height` onto the post object.
- [x] Implement `clear_cache(post_id_or_path)` invalidating volatile `/tmp/gelbooru_cache/` files and snacks cache files while strictly protecting `save_dir`.
- [x] Implement `abort_active()` to cancel in-flight curl downloads.
- [x] Write headless unit tests in `tests/unit/media_resolver_spec.lua` passing without requiring window or graphics mocks.

## Answer

Implemented standalone headless Media Resolver module in `lua/gelbooru/media/resolver.lua`:
- `resolver.resolve(post, opts, callback)`: Asynchronous resolution contract taking post model and options (`force`, `request_id`). Resolves saved local post files directly before network fallbacks; executes remote candidate fallback chain (`sample_url` -> `preview_url` -> `file_url`); runs pre-resolution cache forensics detecting and scrubbing 0-byte or truncated cache files before returning resolved paths; and lazily hydrates image dimensions onto the post object.
- `resolver.read_image_dimensions(path)` & `resolver.is_image_complete(path)`: Migrated pure-Lua binary image header parsing (PNG IHDR, GIF87a/89a, WebP VP8/VP8L/VP8X, JPEG SOF0/SOF2) and format completion validation (PNG IEND, JPEG EOI, GIF semicolon, HTML error payload rejection) from `lua/gelbooru/core/util.lua` into `media/resolver.lua` without spawning external CLI processes.
- `resolver.clean_corrupt_snacks_cache(target)` & `resolver.clear_cache(post_id_or_path)`: Scans and purges 0-byte or truncated snacks cache files and volatile preview cache entries (`/tmp/gelbooru_cache/`) while strictly safeguarding permanent user files in `save_dir`.
- `resolver.abort_active()`: Cancels active curl download tasks and increments request sequence to ignore stale asynchronous callbacks.
- Verified with 25 headless unit tests in `tests/unit/media_resolver_spec.lua` and full suite passing with 0 failures / 0 errors.

