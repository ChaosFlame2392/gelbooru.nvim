# 04: Lazy On-Demand Dimension Resolution & Local Metadata Display

**What to build:** Integrate lazy on-demand image dimension resolution for local images without Gelbooru metadata. Ensure `scan_local_folder` remains a pure, non-blocking filesystem traversal (< 5ms) without synchronous header inspection. Resolve dimensions on demand when a post is active/rendered, formatting real dimensions (`1920x1080`) in the post list and metadata window instead of placeholder `0x0`.

**Blocked by:** 01, 03

**Status:** resolved

- [x] `scan_local_folder` remains pure directory traversal and does not synchronously inspect image file headers.
- [x] Active local post has its dimensions resolved lazily via `util.read_image_dimensions` when active or rendered.
- [x] Post list rendering and metadata panel show real dimensions (e.g. `1920x1080`) instead of `0x0` for local images.
- [x] Integration tests in `tests/integration/local_spec.lua` verify sub-5ms scan speed and correct lazy dimension hydration.

## Answer

### Implementation Details
1. **Pure Filesystem Traversal Preservation**:
   - Kept `scan_local_folder` in `lua/gelbooru/local/scan.lua` as a pure, lightweight filesystem traversal without synchronous header inspection or dimension extraction, ensuring sub-5ms folder scanning.
2. **Lazy Dimension Resolution Engine**:
   - Implemented `render.resolve_post_dimensions(p, opt_path)` in `lua/gelbooru/ui/render.lua` and exported it via `lua/gelbooru/ui/init.lua`.
   - Checks if `p.width` and `p.height` are already populated (> 0). If not, resolves path from `opt_path`, `p.file_url`, or `p.preview_url`, validates local existence via `vim.fn.filereadable`, and invokes pure-Lua `util.read_image_dimensions(target_path)`.
   - Results are cached directly onto `p.width` and `p.height`, ensuring subsequent accesses require zero disk I/O.
3. **On-Demand Hydration Across UI Render Lifecycle**:
   - `render_list()`: Lazily resolves dimensions for the active cursor post (`i == State.cur`), formatting real dimensions (e.g. `1920x1080`) in the post list line while inactive posts remain lightweight.
   - `render_preview()`: Resolves dimensions for the active post and triggers `render_list()` to upgrade display if dimensions were newly discovered.
   - `render_metadata()`: Resolves dimensions before formatting metadata lines, rendering `Size : <width>x<height>` in the inspector panel.
   - `load_and_render_image()`: Resolves dimensions on completed local render and refreshes metadata and list buffers.
4. **Snacks Image Cache Integration**:
   - Added `clean_corrupt_snacks_cache` invocation in `render_image` to sanitize any corrupt or 0-byte cache entries before creating or updating placements.

### Test Verification
- Added 4 integration tests in `tests/integration/local_spec.lua` within `Lazy On-Demand Image Dimension Resolution`:
  - `scan_local_folder does not synchronously inspect image headers and completes under 5ms`: Verified zero calls to `read_image_dimensions` during scan and sub-5ms execution.
  - `open_local lazily resolves dimensions for the active post and formats them in list and metadata panel`: Verified active post dimensions are resolved and rendered (e.g., `1920x1080` instead of `0x0`), while inactive posts remain unresolved (`nil`).
  - `navigating via on_cursor_change lazily resolves dimensions for the newly active post`: Verified cursor navigation lazily resolves newly focused item dimensions and dynamically updates the post list and metadata window.
  - `ui.resolve_post_dimensions resolves dimensions lazily and caches on post object`: Verified caching semantics and confirmed zero file reads on subsequent calls.
- Verified all unit and integration test suites pass (`make test`) with 0 failures and 0 errors.
