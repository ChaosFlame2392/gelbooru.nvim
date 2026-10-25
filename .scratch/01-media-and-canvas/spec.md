# Spec: Media Resolver Decoupling & Terminal Canvas Adapter

Status: ready-for-agent

## Problem Statement

In `gelbooru.nvim`, the visual presentation module has become deeply entangled with network downloads, binary byte sniffing, process management, and cache forensics.

Specifically, `lua/gelbooru/ui/image.lua` has expanded to over 1,110 lines, housing eight disparate concerns ranging from child process management (`SIGKILL` on FFmpeg) and ImageMagick cache globbing to DPI clamping and buffer keymap shielding. Furthermore, recent commits introduced binary header parsing (`read_image_dimensions`) and format validation (`is_image_complete`) directly into `lua/gelbooru/core/util.lua`, turning it into a 620-line dumping ground without domain locality.

When in-flight ImageMagick processes were aborted mid-conversion, truncated 0-byte cache files were left on disk. Rather than separating the media acquisition pipeline from terminal presentation, emergency patches added an arbitrary 50ms timer (`UI.abort_cleanup_timer`) on the global UI singleton to sleep before unlinking files. Simultaneously, `load_and_render_image` in `lua/gelbooru/ui/render.lua` grew to 225 lines, forcing the UI presentation layer to coordinate curl retries, thumbnail extraction, binary integrity checks, and window redraws.

This lack of depth and blurred seams between media resolution and window presentation creates severe architectural friction:
- Presentation code must manage curl retries and asynchronous child process lifecycles.
- Testing media resolution requires mocking Neovim floating windows, buffer handles, layout geometry, and terminal graphic protocols simultaneously.
- Transient network or transcoding failures can corrupt UI state or trap the user in broken visual feedback loops.

## Solution

Decouple media resolution from terminal display by establishing two deep modules with a clean seam:
1. **Media Resolver Module** (`media/resolver.lua`): A headless data pipeline that accepts a post object and resolves it to a verified local media target (`{ path, is_video, is_thumbnail, width, height }`). It absorbs candidate URL fallback chains, download retries, FFmpeg video thumbnail generation, snacks cache corruption scrubbing, and binary dimension parsing (moved out of `util.lua`).
2. **Terminal Canvas Adapter** (`ui/canvas.lua`): A pure display adapter that receives a verified local file path and a target window handle. It coordinates graphics protocol placement (`snacks.image` / `image.nvim`), DPI clamping, synchronous cache clearing on abortion, and buffer keymap shielding, with zero knowledge of network transfers or video transcoding.

The rendering presentation controller becomes a lean 35-line coordinator: it requests resolution from the Media Resolver and passes the verified path to the Canvas Adapter. The arbitrary 50ms cleanup timer on the global UI singleton is permanently deleted.

---

## User Stories

1. As a user viewing a post in the browser, I want high-resolution media previews to resolve smoothly without UI freezing or flickering.
2. As a user browsing posts with multiple preview URLs, I want the system to seamlessly fall back to sample or full-size files if the primary thumbnail fails.
3. As a user viewing a video post, I want background FFmpeg transcoding to generate a sharp video thumbnail without blocking my editor.
4. As a user scrolling rapidly past heavy artwork, I want in-flight downloads, ImageMagick conversions, and FFmpeg transcode jobs to be aborted cleanly without leaving corrupted 0-byte cache files on disk.
5. As a user navigating past an aborted image, I want conversion cleanup to complete immediately without unmanaged delay timers on the UI singleton.
6. As a user pressing `R` (force refresh), I want volatile preview caches to be purged and re-acquired while permanent saved media in my storage directory is strictly protected.
7. As a user opening a video with `O`, I want the media file to launch in my system media player immediately, without requiring terminal canvas placement.
8. As a user navigating with the keyboard, I want the image buffer to capture browsing keys (`j`, `k`, `q`, `<CR>`) without cursor displacement or leaking global leader menus.
9. As a user with high-DPI displays, I want anomalous image DPI metadata to be clamped automatically, preventing visual placement distortions.
10. As a user browsing local folders, I want image dimensions to be resolved on demand without spawning external CLI processes.
11. As a plugin developer writing unit tests, I want to test URL fallback chains, retry logic, and video thumbnail generation headlessly, without spinning up floating windows or mocking terminal graphics protocols.
12. As a plugin developer, I want to test terminal canvas placement and keymap shielding with local test fixtures without mocking network APIs.
13. As a maintainer, I want binary image decoding and format completion checks to reside with media resolution logic rather than in a general utility file.
14. As a maintainer, I want child process spawning (curl, FFmpeg) and terminal graphics placement separated, so that supporting alternative image backends does not touch media resolution logic.
15. As a maintainer, I want the 225-line image loading function decomposed into a 35-line presentation coordinator delegating across a clean seam.

---

## Implementation Decisions

### 1. Headless Media Resolver Module
- Create a dedicated headless Media Resolver module (`lua/gelbooru/media/resolver.lua`) located outside the UI package.
- The Media Resolver exposes a compact asynchronous contract:
  - `resolve(post, opts, callback)`: Resolves a post to a verified local media target `{ path, is_video, is_thumbnail, width, height }`.
  - `clear_cache(post_id_or_path)`: Invalidates volatile cache files and snacks converted files for a given item.
  - `abort_active()`: Terminates active download handles, conversion steps, and FFmpeg processes for stale requests.
- Encapsulates:
  - URL candidate priority ordering (`sample_url` -> `preview_url` -> `file_url`).
  - Pure-Lua binary image header decoding (migrated out of `core/util.lua`).
  - Binary media integrity validation via chunk and marker inspection (migrated out of `core/util.lua`).
  - Background FFmpeg child process spawning, process handle tracking, and `SIGKILL` termination.
  - Pre-placement detection and purging of corrupted snacks cache files.

### 2. Terminal Canvas Adapter
- Create a terminal canvas display adapter module (`lua/gelbooru/ui/canvas.lua`).
- The Canvas Adapter exposes:
  - `render(win, file_path)`: Displays a local file in a floating window via graphics protocols.
  - `render_placeholder(win, post, message)`: Renders textual fallback or loading states.
  - `close()`: Closes the active graphics placement handle cleanly.
  - `nudge()`: Re-calculates and re-anchors active placement after window resizing.
- Encapsulates:
  - Graphics backend dispatch (`snacks.image` / `image.nvim`).
  - DPI sanitization and clamping.
  - Immediate conversion abort cleanup without delay timers, deleting `UI.abort_cleanup_timer` and `constants.ABORT_CLEANUP_DELAY_MS`.
  - Buffer-local keymap attachment and boundary shielding via `util.shield_buffer`.

### 3. Presentation Coordinator Collapse
- Refactor `load_and_render_image` in `lua/gelbooru/ui/render.lua` from 225 lines to ~35 lines:
  - Asks the Media Resolver to resolve the current post.
  - On callback, verifies search epoch and cursor alignment.
  - Hands the verified file path to the Canvas Adapter for terminal display.
- Delete `lua/gelbooru/ui/image.lua` completely; all callers use the Media Resolver or Canvas Adapter directly.

---

## Testing Decisions

- **Testing External Behavior**:
  - Tests verify that `resolve()` returns the expected verified file path or failure callback given valid, corrupted, or missing files.
  - Tests verify that aborting an in-flight resolution cancels active jobs without leaving 0-byte files on disk.
  - Tests verify that canvas rendering attaches expected buffer options and keymaps without testing private graphics protocol structures.
- **Modules Tested**:
  - Media Resolver: tested headlessly in `tests/unit/media_resolver_spec.lua` with zero Neovim window setup.
  - Canvas Adapter: tested in `tests/unit/canvas_spec.lua` using isolated buffer fixtures.
- **Prior Art**:
  - Existing network download mocks in `tests/integration/helpers/mock_net.lua` and placement mocks in `tests/integration/helpers/mock_snacks.lua`.

---

## Out of Scope

- Tag query parsing and pipeline stage execution (handled in Feature 02: Query Engine).
- Autocomplete candidate generation and tag categories (handled in Feature 03: Tag Catalog).
- Local folder directory traversal and background metadata indexing (handled in Feature 04: Local Enricher).

---

## Further Notes

- By moving binary parsing out of `lua/gelbooru/core/util.lua`, `util.lua` shrinks significantly and returns to being a pure utility module.
- All temporary preview files remain in `/tmp/gelbooru_cache/`, while permanently saved files in `config.options.save_dir` are strictly untouched during cache invalidation.
