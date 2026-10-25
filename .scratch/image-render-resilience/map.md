# Map: Image Rendering & Local Library Resilience

## Task Graph & Frontier

- **01: Strict Booru ID Disambiguation & Pixiv Filename Filtering**
  - Path: `.scratch/image-render-resilience/issues/01-booru-id-disambiguation.md`
  - Blocked by: None
  - Status: resolved

- **02: Self-Healing Cache Lifecycle & In-Flight Conversion Abort Cleanup**
  - Path: `.scratch/image-render-resilience/issues/02-self-healing-cache-lifecycle.md`
  - Blocked by: None
  - Status: resolved

- **03: Pure-Lua Binary Header Parser for Multi-Format Image Dimensions**
  - Path: `.scratch/image-render-resilience/issues/03-pure-lua-dimension-parser.md`
  - Blocked by: None
  - Status: resolved

- **04: Lazy On-Demand Dimension Resolution & Local Metadata Display**
  - Path: `.scratch/image-render-resilience/issues/04-lazy-dimension-resolution.md`
  - Blocked by: 01, 03
  - Status: resolved

## Decisions-so-far
- Baseline test suite is 100% green on `main`.
- [Ticket 01](issues/01-booru-id-disambiguation.md): Disambiguate booru IDs in local library scan by filtering Pixiv filenames (`_p%d+`) and bounding bare numeric IDs to `GELBOORU_ID_CEILING` (25,000,000) centralized in `lua/gelbooru/core/constants.lua` while preserving explicit prefixes (`post_`, `id_`, `ID`, `gelbooru_`).
- [Ticket 02](issues/02-self-healing-cache-lifecycle.md): Implement self-healing cache lifecycle in `lua/gelbooru/ui/image.lua` with centralized cache directory resolution (`get_snacks_cache_dir`), in-flight conversion abort cleanup (`abort_convert`) unlinking partial 0-byte step files, corrupt cache detection and sanitization (`clean_corrupt_snacks_cache`) before placement creation, and unified cache invalidation (`clear_snacks_cache_for`) for both booru post IDs and local media file paths.
- [Ticket 03](issues/03-pure-lua-dimension-parser.md): Implemented pure-Lua binary header parser (`util.read_image_dimensions`) for PNG, GIF, WebP (VP8/VP8L/VP8X), and JPEG (scanning variable-length APP/Exif segments for SOF markers with O(1) seeking) without spawning external CLI processes, bounded by `MAX_JPEG_MARKERS` (256) and `MAX_WEBP_CHUNKS` (32) in `lua/gelbooru/core/constants.lua`.
- [Ticket 04](issues/04-lazy-dimension-resolution.md): Kept `scan_local_folder` pure filesystem traversal (< 5ms) without synchronous header inspection. Implemented lazy on-demand dimension resolution via `resolve_post_dimensions(p, opt_path)` caching onto `p.width`/`p.height` during `render_list`, `render_metadata`, `render_preview`, and `load_and_render_image`, formatting real image dimensions (`1920x1080`) instead of `0x0` in list lines and metadata panel.
