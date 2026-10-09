# gelbooru.nvim

A Gelbooru browser application for Neovim featuring a tag picker, an image browser with the ability to download images to a designated folder, and search history.

## Requirements

* **Neovim** >= 0.9.0
* **[snacks.nvim](https://github.com/folke/snacks.nvim)** (with `snacks.image` enabled) — used for in-terminal image rendering.
* **[ImageMagick](https://imagemagick.org/)** (`magick` CLI executable in your PATH) — required by `snacks.image` for image format conversion and rendering.
* **`curl`** — for making API requests and downloading post media.

## Installation

### For LazyVim / lazy.nvim

Add the following file to your Neovim configuration (e.g., `~/.config/nvim/lua/plugins/gelbooru.lua`):

```lua
return {
  "ChaosFlame2392/gelbooru.nvim",
  dependencies = {
    "folke/snacks.nvim",
  },
  cmd = { "Gelbooru", "GelbooruTags" },
  opts = {
    -- Optional Configuration Defaults
    -- save_dir = "~/Pictures/Gelbooru",
    -- per_page = 42,
    -- show_tags_in_list = false,
    -- prefetch_radius = 5,
    -- log_level = "DEBUG",
  },
}
```

## Configuration Options

You can pass a table of options to `require("gelbooru").setup(opts)`. Both `snake_case` and `UPPER_CASE` option keys are supported:

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `save_dir` | `string` | `"~/Pictures/Gelbooru"` | Path where full-resolution downloaded images are saved. |
| `auth_file` | `string` | `stdpath("config") .. "/gelbooru_auth.json"` | Path to your JSON credentials file (`api_key` & `user_id`). |
| `tags_dir` | `string` | `"~/.local/share/nvim/gelbooru"` | Directory where local tag databases are stored. |
| `cache_dir` | `string` | `"/tmp/gelbooru_cache"` | Temporary directory used for cached image previews. |
| `log_level` | `string` | `"DEBUG"` | Minimum log level (`"DEBUG"`, `"INFO"`, `"WARN"`, `"ERROR"`, or `"OFF"` to disable). |
| `log_file` | `string` | `stdpath("state") .. "/gelbooru.log"` | Destination path for debug logs. |
| `per_page` | `number` | `42` | Number of results to fetch per page. |
| `prefetch_radius` | `number` | `5` | How many adjacent post previews to pre-download in the background. |
| `show_tags_in_list` | `boolean` | `false` | Whether to display raw tag strings directly inside the list view. |
| `api_base` | `string` | `"https://gelbooru.com/..."` | Base Gelbooru posts API endpoint. |
| `tags_api` | `string` | `"https://gelbooru.com/..."` | Base Gelbooru tags API endpoint. |

## Usage

* `:Gelbooru [tags]` — Launch the tag picker and open the Gelbooru browser (online search).
* `:GelbooruLocal [dir]` — Open the local folder browser for saved images and videos (defaults to `save_dir`).
* `:GelbooruTags` — Download and cache Gelbooru tags locally for instant autocomplete.

Inside the search bar, you can also query local folders directly:
* `local:/path/to/folder` — Browse a specific local directory.
* `local:/path/to/folder tag1 tag2` — Search and filter local files by booru tags.
* `local: tag1 tag2` — Search and filter files in your default `save_dir` by tags.

---

## Actionable Plan: Local Library, Metadata Caching, Lookahead & Media Engine

This roadmap outlines the architecture and implementation milestones for turning `gelbooru.nvim` into a high-performance local media library browser with offline booru metadata enrichment.

### Milestone 1: Persistent Metadata Disk Cache & Auto-Cache on Save
* **Auto-Cache on Save (`<CR>`)**: When saving an online post in `:Gelbooru`, automatically persist the post's full metadata JSON to `<cache_dir>/meta_<id>.json` alongside saving the media file to `save_dir`. In local mode or for already-saved posts, `<CR>` displays a local file notice without re-downloading.
* **On-Demand Cache on API Resolve**: When metadata is fetched from the Gelbooru API for any local post with an extracted ID, atomically write the JSON to `<cache_dir>/meta_<id>.json`.
* **Instant Sub-Millisecond Pre-Hydration**: On folder scan (`:GelbooruLocal`), immediately check `cache_dir` for all scanned files with numeric IDs. Pre-hydrate `tags`, `rating`, `score`, `width`, `height`, and `source` into memory synchronously during folder scan (<5ms for 100+ files).
* **Full Offline Browsing**: Local files with cached metadata display full artist, series, character, and general tags even with zero internet connection.
* **Cache Refresh (`r` vs `R`)**:
  - `r` (Soft Redraw): Resets `State.cur_id = nil` and redraws the current post canvas and metadata without deleting any cached files or making network requests.
  - `R` (Force Refresh): Invalidates volatile cache files in `<cache_dir>` (`prev_<id>.<ext>`, `meta_<id>.json`) and snacks image cache, then re-fetches metadata and re-downloads preview from the network. Strictly **NEVER** touches, modifies, or deletes permanent files in `save_dir` or local user libraries.

### Milestone 2: Dual-Tier Lookahead & Background Folder Indexing Engine
* **Tier 1: High-Priority Cursor Rush (Lookahead)**:
  - When navigating local posts, schedule an immediate metadata prefetch queue looking ahead in the cursor's scroll direction (`idx ± prefetch_radius`).
  - Rushes ahead of user navigation so scrolling (`j`/`k`) displays rich metadata, tags, and score with 0ms perceived delay.
* **Tier 2: Low-Priority Folder Indexer (Whole-Folder Crawler)**:
  - When opening a local folder, spawn a background worker that scans for all unindexed posts (posts with an ID but no cached metadata).
  - Fetches and persists metadata to `<cache_dir>/meta_<id>.json` in a throttled, asynchronous queue (e.g. 100ms interval) without starving the cursor-rush queue or blocking Neovim's main thread.
  - Displays indexing progress in the status bar (e.g. `Indexing metadata: 12/80 [■■□□□]`).
  - Cancels or pauses automatically when the user executes a new search, navigates history, or closes the UI (`teardown`).

### Milestone 3: Local Library Tag & Keyword Search (`local:<dir> <tags>`)
* **Query Syntax**:
  - `local:<dir> <tags>` — Browse directory `<dir>` filtered by specified tags (e.g. `local:/Users/balkrishan/Desktop/homework/Gelbooru zenless_zone_zero`).
  - `local: <tags>` — Shorthand searching within the default `save_dir`.
* **Query Tokenizer**:
  - Splits directory path from tag expressions.
  - Supports positive tag matching (`zenless_zone_zero`, `ellen_joe`), negative exclusion (`-rating:explicit`, `-comic`), rating filters (`rating:general`), and score filters (`score:>=50`).
* **Multi-Source Matcher**:
  - Matches against cached metadata tags, artist names, character names, and series names.
  - Fallback filename matching: for unindexed local files or files without IDs, matches search tokens against normalized filename words.
* **Autocomplete Integration**:
  - While typing in `local:` search mode, suggestions in `UI.wins.ac` prioritize tags present in the local cache alongside global indexed tags.

### Milestone 4: Local Video Pipeline (`.mp4`, `.webm`)
* **Scanner Extension**:
  - Include `.mp4` and `.webm` files in `scan_local_folder`, with ID extraction support (e.g. `11802758.mp4`, `gelbooru_99999.webm`).
* **UI Representation**:
  - Dedicated list badges: `[VIDEO]` or `[MP4]`/`[WEBM]`.
  - Preview canvas display: render extracted video thumbnail (via ffmpeg/imagemagick poster if available) or an informative video media card (displaying duration, resolution, dimensions, file size).
* **Media Playback Keymaps**:
  - `O`: launch default system media player (e.g. `mpv`, `vlc`, or system default viewer via `vim.ui.open`) with the local video file path.
  - `o`: open the corresponding Gelbooru post web page in the default web browser if a post ID is present.
  - `<CR>`: display local file notice.

### Milestone 5: Unified Online ↔ Local Hybrid Lifecycle & Context-Aware Actions
* **Automatic Full-Resolution Canvas Upgrade on Download**:
  - In online mode, when a user saves a post via `<CR>`, upon download completion to `save_dir/<id>.<ext>`, immediately replace the sample/preview on canvas with the full-resolution local image/video file.
  - Seamlessly re-renders the active image placement using the full-res local file without flickering or network re-fetching.
* **Local Library Presence Detection in Online Mode**:
  - When browsing online posts, check if `save_dir/<id>.<ext>` already exists on disk (via `saved_index`).
  - If a local download is already present:
    - Displays a `[SAVED]` or `✓` indicator in the post list.
    - Preview rendering prefers the full-resolution local file in `save_dir` over fetching/caching a lower-resolution remote sample.
* **Consistent & Unambiguous Keymaps**:
  - **`<CR>` (Save Online / Notice Local)**:
    - In online mode: downloads full-resolution `file_url` to `config.options.save_dir` and caches metadata.
    - In local mode (or if post is already saved in `save_dir`): displays local file path notice without triggering download or opening external viewers.
  - **`o` (Open Booru Web Page)**:
    - Opens the full Gelbooru post web page (`https://gelbooru.com/index.php?page=post&s=view&id=...`) in the default web browser.
  - **`O` (Open Locally with System Media Viewer)**:
    - Opens the media file directly in the system default image/video viewer (`mpv`, VLC, Preview).
    - **Download-on-demand**: If the post is not yet downloaded, automatically downloads it to `save_dir` first, then opens it locally either way!
* **Artist Quick-Search Hotkey (`u`)**:
  - Single keypress avoiding conflict with `A` (which is reserved for entering search mode).
  - In list mode and meta inspector, pressing `u` extracts the artist tag from the active post (from `p.artist` or dynamic tag indices) and immediately queries it in the search bar for instant author discovery.
* **Dynamic Explorer Width Adjustment & Zen Mode (`<` / `>`, `\`)**:
  - Interactive hotkeys `<` and `>` incrementally narrow or widen the left post list by 2–5 columns (`State.list_width_ratio` clamped 0.10–0.40, default 0.22), allocating more space to the image canvas.
  - Collapsible Zen Mode toggle (`\`): collapses the post list to 0 width, granting 100% of the display area to the image canvas for full-size viewing; pressing `\` restores the explorer list.
  - Image preview automatically scales and re-renders dynamically via `image.nudge_current_placement()`.

### Milestone 6: Implementation Checklist & Action Steps
1. **Phase 1 — Cache & Save Pipeline**:
   - Add `get_meta_cache_path(id)` in `core/config.lua` / `local/meta.lua`.
   - Update `api.save_current()` to write metadata JSON on save.
   - Update `api.fetch_post_metadata()` to read/write `<cache_dir>/meta_<id>.json`.
   - Pre-hydrate cached metadata in `local/scan.lua` during directory scan.
2. **Phase 2 — Dual Lookahead Queue**:
   - Implement `prefetch_metadata_around(idx)` in `local/init.lua` for cursor rush.
   - Implement `start_folder_indexer(posts)` background queue in `local/init.lua`.
   - Wire prefetch cancellation into `download.cancel_prefetch_timers()` and `teardown()`.
3. **Phase 3 — Video Pipeline & Player Dispatch**:
   - Add `.mp4` and `.webm` to `scan_local_folder` extensions.
   - Update `ui/init.lua` list renderer and keymaps (`O`, `<CR>`) for local video files.
4. **Phase 4 — Unified Online ↔ Local Hybrid Integration**:
   - Detect existing saved file in `save_dir` for online posts (`saved_index`).
   - Upgrade canvas preview to full-resolution local file immediately upon save completion.
   - Context-aware `o` (web page), `O` (open local, download first if needed), and `<CR>` (save or notice).
5. **Phase 5 — Tag Query & Local Filtering**:
   - Implement `parse_local_query(raw_query)` in `local/init.lua`.
   - Implement `filter_local_posts(posts, tag_tokens)` matching cached metadata and filenames.
   - Connect query input bar `<CR>` execution to filtered local browsing.
6. **Phase 6 — Artist Jump & Dynamic Explorer Width**:
   - Bind `u` to quick artist search.
   - Bind `<` / `>` to adjust explorer width ratio and `\` to toggle Zen Mode canvas expansion.

### Milestone 7: Advanced Query Engine, Flexible Syntax & Pipeline Sorting
* **Flexible `local:` Placement**: Support placing `local:` or `local:<dir>` anywhere in the search query (e.g. `tag1 tag2 local:` or `solo local: tag2`), normalizing tokens automatically so token ordering does not dictate engine mode.
* **Online `sort:random` Reseeding & Cache Invalidation**: Ensure online `sort:random` queries fetch a fresh randomized assortment on each `<CR>` execution by bypassing identical-query deduplication and sending nonces / cache-busting headers.
* **Multi-Stage Piped Sorting Pipeline (`sort:id:1000 | sort:score:500 | sort:random`)**:
  - Unix-style composable query pipe syntax allowing chained operations.
  - Example: Fetch the 1,000 most recent posts (`sort:id:1000`), sort those by score to keep the top 500 (`sort:score:500`), and randomly shuffle the remaining 500 (`sort:random`).

### Milestone 8: Visual Rendering Polish, Eager Lookahead & Local Deletion
* **Eager Lookahead Network Prefetch Pipeline**:
  - Eliminate ~500ms delay during navigation by decoupling prefetching from the 150ms preview cooldown.
  - Maintain active prefetch workers across cursor steps in the same direction and eliminate artificial 50ms queuing delays for adjacent posts.
* **Zen Mode Cursor Artifact Elimination**:
  - Hide Neovim's terminal cursor (`█`) in the image canvas window during Zen Mode (`\`) via `guicursor` adjustment or cursor parking to ensure an uncluttered, borderless viewing canvas.
* **Tiny Image Canvas Scaling & Minimum Dimension Guard**:
  - Ensure small native pixel images scale smoothly to fill available canvas bounds rather than rendering as tiny dots/postage stamps.
* **Local Media Deletion Workflow (`d` / `D`)**:
  - In local mode, allow deleting the focused image/video file directly from disk via `d` or `D`.
  - Prompts with an interactive confirmation modal, safely unlinks the file, purges metadata and thumbnail caches, updates `saved_index`, and smoothly advances the post list cursor.

---

### Performance & Memory Safety Invariants (Zero Leaks & Sub-3ms Latency)

* **Handle & Timer Lifecycle Guarantees**:
  - Every libuv handle (`uv_timer_t`) created for cursor lookahead, debounce, or background indexing must be tracked in `UI.prefetch_timers` or `State.indexer_timer`.
  - On navigation, query change, or teardown: unconditionally execute `timer:stop()` and `timer:close()`. Never nil timer references without closing the underlying C handle.
* **Bounded Process Concurrency**:
  - The background folder crawler is strictly throttled to at most 1–2 concurrent `curl` processes with staggered intervals (100ms+), preventing process exhaustion or system lag.
  - All spawned processes are tracked in `download.active_handles` and aborted immediately via `download.abort_all()` on UI close.
* **Lean In-Memory Footprint & String Deduplication**:
  - Metadata pre-hydration extracts only essential fields (`tags`, `rating`, `score`, `width`, `height`, `source`), dropping raw JSON buffers immediately to allow garbage collection.
  - Scanned file lists store lightweight post tables; large local libraries (1,000+ images) avoid unbounded memory growth.
* **Buffer & Image Graphics Recycling**:
  - Image placements allocate scratch buffers with `bufhidden = "wipe"`.
  - When swapping previews, the new buffer is set on the window *before* the previous buffer is deleted, preventing placement tracking failures, buffer leaks, and canvas flickering.
* **Non-Blocking UI Loop**:
  - Local disk operations use fast cached reads and pcall guards, ensuring cursor navigation remains buttery-smooth at 60+ FPS even in folders with thousands of media files.
