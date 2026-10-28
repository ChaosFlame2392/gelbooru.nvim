# Spec: Terminal Graphics Engine, Ghostty 1.4 Native Driver & Asset Pipeline Consolidation

Status: resolved

## Problem Statement

With the release of Ghostty 1.4, modern terminal emulators now support 100% of the Kitty Graphics Protocol—including native multi-frame animations, relative placement, ~16× faster image parsing (~725 MB/s), 25–55% higher macOS I/O throughput, and transparent scrollback compression.

However, the internal architecture of `gelbooru.nvim` was constructed around legacy constraints where terminal graphics parsing was slow and fragile. This mismatch creates substantial architectural friction across three areas:

1. **Leaky Terminal Canvas Coupling**: The canvas presentation layer (`lua/gelbooru/ui/canvas.lua`), media resolver, prewarmer, and lifecycle modules directly inspect and manipulate private internals of `snacks.nvim` (`placement._convert`, `convert.steps`, unlinking `.info` files, and poking internal cache folders). This breaches the graphics seam and requires callers to know about low-level ImageMagick conversion subprocesses.
2. **Duplicated Prewarm and Download Queues**: `lua/gelbooru/media/prewarmer.lua` implements a 508-line duplicate priority queue, sliding-window indexer, and concurrency manager that runs in parallel with `lua/gelbooru/net/download.lua`. It eagerly spawns background ImageMagick `convert` child processes to rasterize images to disk before display. In Ghostty 1.4, which parses raw image transfers in under 2 milliseconds, this duplicate queue wastes CPU, risks race conditions, and induces micro-stuttering during rapid `j`/`k` navigation.
3. **Entangled Media Resolver**: `lua/gelbooru/media/resolver.lua` is a sprawling 1,320-line module that tangles pure binary byte seeking (decoding PNG, WebP, GIF, and JPEG headers) with asynchronous OS child processes (`ffmpeg` thumbnail extraction, PID killing) and third-party disk cache scraping.
4. **Static GIF Presentation**: Animated GIFs and WebPs are flattened into single-frame static previews because existing adapters force ImageMagick to take only frame `[0]`, ignoring Ghostty 1.4's native animation capabilities.
5. **Rigid DPI Clamping**: The canvas defensively resets DPI &ge; 300 to standard 96 DPI, distorting high-resolution illustrations on modern Retina and fractional scaling displays.

## Solution

Untangle the presentation and asset subsystems by establishing three deep modules placed at clean, high-level seams:

1. **Terminal Graphics Engine**: A deep module presenting a small 3-method interface (`display`, `abort`, `clear`) to UI callers. It absorbs all process cancellation, extmark suppression, and DPI management. It hosts an internal capability probe and a native **Ghostty / Kitty Protocol Driver** that transmits images directly via the Kitty Graphics Protocol with Unicode placeholders and enables multi-frame GIF playback. Legacy terminals fall back to an encapsulated Snacks adapter behind the same interface. The obsolete `image.nvim` backend is permanently dropped.
2. **Media Inspector**: A pure, side-effect-free binary inspection module dedicated to fast (<0.02ms) byte-level header parsing and image integrity verification. It has zero dependencies on Neovim windows, buffers, or OS child processes, enabling pure unit testing with zero mocks.
3. **Media Transcoder Adapter**: An isolated subprocess manager handling `ffmpeg` video thumbnail extraction, process handles, and clean SIGKILL termination, while establishing a clean extension seam for future looping video clip previews.
4. **Asset Pipeline Consolidation**: Pass the deletion test by removing the duplicate queue in `prewarmer.lua` and consolidating all post retrieval, prefetching, and render readiness into the rate-governed download pipeline. When running in high-throughput environments like Ghostty 1.4, the pipeline bypasses offline ImageMagick disk conversions.

---

## User Stories

1. As a user browsing posts with `j` and `k`, I want image previews to render instantly without UI micro-stutters or background process stalls.
2. As a user running Ghostty 1.4 or Kitty, I want animated GIFs to play smoothly in the terminal preview canvas instead of displaying as frozen static frames.
3. As a user browsing in Ghostty 1.4 on a high-DPI Mac or Linux display, I want digital illustrations to render at crisp native pixel density without artificial 96 DPI downscaling.
4. As a user running inside a tmux session, I want terminal graphics escape sequences to be automatically wrapped in tmux passthrough without manual configuration.
5. As a user jumping across hundreds of posts (`gg`, `G`) or switching search queries, I want in-flight image transmissions to abort immediately and cleanly without leaving orphan processes or corrupted cache files.
6. As a user viewing video posts (MP4, WebM), I want a clear visual thumbnail to generate asynchronously without blocking keyboard navigation.
7. As a user viewing video posts, I want pressing `O` to launch my configured media player (IINA, mpv, VLC) with the full media file and audio.
8. As a user navigating with the keyboard, I want the image buffer to capture browsing keys (`j`, `k`, `q`, `<CR>`) without cursor displacement or leaking global leader menus.
9. As a user opening the plugin in a terminal without Kitty protocol support (such as iTerm2 or Alacritty), I want the system to fall back seamlessly to Snacks without throwing errors.
10. As a user pressing `R` (force refresh), I want the preview cache to clear and re-fetch from the network while preserving permanently saved files in my save directory.
11. As a user resizing the terminal window or toggling Zen mode (`\`), I want the rendered image placement to nudge and rescale smoothly to fit the new geometry.
12. As a user browsing in low-memory environments, I want terminal scrollback memory to remain flat during extended sessions through clean placement lifecycle teardown.
13. As a plugin developer writing unit tests, I want to test binary image dimension parsing with raw byte arrays without spinning up Neovim windows or mocking terminal graphics protocols.
14. As a plugin developer, I want to test the entire graphics engine through a single in-memory adapter at the engine seam rather than mocking ten private internal fields of third-party plugins.
15. As a maintainer, I want all process termination and `.info` cache cleanup encapsulated in one place, so that adding a new graphics backend requires editing only one adapter file.
16. As a maintainer, I want video transcoding subprocess logic completely isolated from binary header seeking, so changes to `ffmpeg` flags cannot break image format validation.
17. As a maintainer, I want network prefetching and render readiness unified under a single rate governor, eliminating race conditions between downloads and prewarmers.
18. As an AFK agent working on the codebase, I want unambiguous module seams defined in the domain glossary, so that refactoring display logic never touches query execution.

---

## Implementation Decisions

### 1. Terminal Graphics Engine

- Create a deep Terminal Graphics Engine presenting a strict 3-method interface to all UI callers:
  - `display(win, path, opts)`: Displays the verified visual media at the given path inside the target window. Accepts optional callbacks (`on_error`).
  - `abort(win)`: Synchronously aborts any in-flight transmission or child conversion associated with the window.
  - `clear()`: Cleans up the active placement, releases graphics resources from terminal memory, and restores window buffers.
  - `nudge()`: Recalculates placement dimensions on window resize or layout change.
- Callers in UI modules (`render.lua`, `lifecycle.lua`, `keymaps.lua`) interact exclusively with this 3-method interface. All direct references to `snacks.image.placement`, `img._convert`, `convert.steps`, and `.info` disk files are deleted from external modules.
- The Graphics Engine hosts an internal capability probe that detects Ghostty 1.4, Kitty, WezTerm, and tmux pass-through environments.
- When Ghostty 1.4 or Kitty is detected:
  - The engine uses a direct Kitty Protocol Driver that writes transmission escape codes and assigns Unicode placeholder characters to the target buffer.
  - For PNG and JPEG files, the driver passes the file directly without intermediate ImageMagick conversion.
  - For animated GIFs, the driver transmits multi-frame sequences, enabling in-editor animation playback.
- For non-Kitty terminals, the engine delegates to an encapsulated fallback adapter that wraps `snacks.image` behind the same 3-method seam. Legacy support for `image.nvim` is removed.

### 2. Media Inspector Module

- Establish a dedicated, pure `media.inspector` module containing all binary header seek logic:
  - `parse_png_dimensions(f)`
  - `parse_gif_dimensions(f)`
  - `parse_webp_dimensions(f)`
  - `parse_jpeg_dimensions(f)`
  - `read_image_dimensions(path)`
  - `is_image_complete(path)`
  - `is_gif_animated(path)`: Fast binary scan for multiple frame markers or Graphic Control Extensions.
  - `inspect(path)`: Returns a unified metadata record `{ width, height, format, is_animated, is_complete }`.
- This module is strictly pure: zero Neovim buffer/window dependencies, zero child processes, and deterministic return values.
- `media/resolver.lua` delegates all header parsing and completion checks to `media.inspector`.

### 3. Media Transcoder Adapter

- Isolate all `ffmpeg` child process execution into a dedicated `media.transcoder` adapter:
  - `extract_video_thumbnail(video_path, post_or_id, cb)`: Asynchronously runs `ffmpeg` to extract a single-frame preview.
  - `abort_video_transcodes()`: Synchronously kills all active `ffmpeg` child PIDs and unlinks `.part` files.
  - `transcode_animation_loop(video_path, opts, cb)`: Clean, reserved extension point for future looping video clip preview generation.
- `media/resolver.lua` delegates all video transcoding and subprocess tracking to `media.transcoder`.

### 4. Asset Pipeline Consolidation

- Pass the deletion test by eliminating the duplicate queue and sliding-window logic in `lua/gelbooru/media/prewarmer.lua`.
- Consolidate post asset readiness into `lua/gelbooru/net/download.lua`:
  - A single 4-tier token-bucket priority queue coordinates all network downloads and local file readiness.
  - Callers request readiness through `ensure_ready(post, priority, cb)`.
  - When running under the Ghostty/Kitty native driver, offline ImageMagick conversions are skipped because the terminal parses raw bytes directly.
- Retain a minimal backwards-compatible facade for `prewarmer` so existing public call points in UI modules cleanly delegate without regressions.

---

## Testing Decisions

### What Makes a Good Test

Tests must verify **observable external behavior** at the interface, not private internal state or third-party implementation tables:
- For the Graphics Engine: verify that calling `display` produces the expected buffer configuration, that calling `abort` immediately cleans up without delay timers, and that calling `clear` resets placement state.
- For the Media Inspector: verify that binary sample headers (PNG, GIF, WebP, JPEG) return exact pixel dimensions and completion statuses across valid, truncated, and corrupt payloads with zero mocks.
- For the Media Transcoder: verify that video thumbnail extraction spawns the transcoder and that aborting cleanly kills child handles and cleans partial files.
- For the Asset Pipeline: verify that priority ordering, rate limiting, and sliding-window queue pruning function deterministically under cursor flurry.

### Modules Tested

1. `media.inspector`: Pure unit tests in `tests/unit/inspector_spec.lua` running against binary fixtures.
2. `media.transcoder`: Process isolation tests in `tests/unit/transcoder_spec.lua`.
3. `ui.graphics` (Terminal Graphics Engine): Interface and adapter dispatch tests in `tests/unit/canvas_spec.lua`.
4. `net.download` (Asset Pipeline): Queue consolidation and prefetch tests in `tests/unit/download_spec.lua`.
5. Full Integration Suite: End-to-end browsing, layout, Zen mode, and pipeline stress tests in `tests/integration/`.

### Prior Art

- Placement mocking pattern in `tests/integration/helpers/mock_snacks.lua`.
- Headless binary fixture generation in `tests/unit/media_resolver_spec.lua`.
- Concurrency and rapid navigation test harness in `tests/integration/pipeline_stress_spec.lua`.

---

## Out of Scope

- **In-editor full-length MP4/WebM video playback with audio**: Full video playback with audio remains delegated to the user's external media player (`O`). Generating looping animated preview clips from videos is an isolated future extension behind the `media.transcoder` seam.
- **Custom Terminal Emulator Writing**: The plugin interacts with existing terminal protocols; it does not implement a terminal emulator.
- **Search Query Engine Changes**: The query engine, pipeline stages, and tag catalog are settled and unaffected by this spec.

---

## Further Notes

- **Zero Test Regressions**: All 100+ existing unit and integration tests must pass cleanly at each step of implementation.
- **Defensive Fallback Guarantee**: If Ghostty or Kitty protocol detection fails or runs in an unsupported environment, the plugin must fall back gracefully to the existing Snacks adapter with zero user-visible errors.
