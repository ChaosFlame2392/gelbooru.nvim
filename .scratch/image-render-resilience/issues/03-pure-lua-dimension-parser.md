# 03: Pure-Lua Binary Header Parser for Multi-Format Image Dimensions

**What to build:** Implement a fast, pure-Lua binary image header parser (`read_image_dimensions`) in `core/util.lua` that extracts width and height from JPEG, PNG, WebP, and GIF files in microseconds without spawning external processes (`magick`, `sips`, `identify`). The parser must handle JPEG SOF markers across variable-length APP/Exif segments, PNG IHDR chunk, WebP VP8/VP8L/VP8X chunks, and GIF screen descriptors.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] `read_image_dimensions(path)` in `lua/gelbooru/core/util.lua` accurately extracts width and height for valid PNG, GIF, WebP, and JPEG files.
- [x] JPEG parser seeks or scans across variable-length APP segments to find SOF markers (SOF0-SOF3, SOF5-SOF7, SOF9-SOF11, SOF13-SOF15).
- [x] WebP parser supports VP8 (lossy), VP8L (lossless), and VP8X (extended) format headers.
- [x] Returns `nil, nil` safely on non-existent, unreadable, 0-byte, truncated, or unsupported files.
- [x] Pure-Lua parser does not spawn any external CLI commands.
- [x] Unit tests in `tests/unit/util_spec.lua` test byte headers for all 4 formats and edge cases.

## Answer

### Implementation Details
1. **Centralized Parsing Limits**:
   - Centralized `MAX_JPEG_MARKERS = 256` and `MAX_WEBP_CHUNKS = 32` in `lua/gelbooru/core/constants.lua`.
2. **Pure-Lua Multi-Format Header Parser**:
   - Implemented `util.read_image_dimensions(path)` in `lua/gelbooru/core/util.lua` using pure Lua byte operations wrapped in `pcall` with guaranteed `f:close()` cleanup.
   - **PNG**: Validates 8-byte signature, reads IHDR chunk width and height (32-bit big-endian).
   - **GIF**: Validates GIF87a/GIF89a signature, reads logical screen width and height (16-bit little-endian).
   - **WebP**: Validates RIFF/WEBP container and chunk loops up to `MAX_WEBP_CHUNKS`:
     - `VP8 ` (lossy): validates frame tag start code (`0x9D 0x01 0x2A`), reads 14-bit width and height.
     - `VP8L` (lossless): validates `0x2F` signature, unpacks 14-bit `width-1` and `height-1` bitstream header.
     - `VP8X` (extended): unpacks 24-bit canvas `width-1` and `height-1`.
   - **JPEG**: Validates SOI (`0xFF 0xD8`), scans markers across variable-length APP0-APP15/Exif segments with O(1) seeking (`f:seek("cur", seg_len - 2)`) and skips `0xFF` fill padding until encountering SOF markers (SOF0-SOF3, SOF5-SOF7, SOF9-SOF11, SOF13-SOF15), extracting big-endian 16-bit height and width. Stops safely on SOS (`0xDA`) or EOI (`0xD9`).
3. **Safety & Zero CLI Process Spawning**:
   - Operates entirely in Lua memory and file descriptor I/O without invoking `vim.system`, `vim.fn.system`, `jobstart`, or `io.popen`.
   - Returns `nil, nil` safely on non-existent, unreadable, 0-byte, truncated, or non-image files.

### Test Verification
- Added 17 unit tests in `tests/unit/util_spec.lua` verifying:
  - PNG IHDR chunk parsing.
  - GIF87a and GIF89a header parsing.
  - WebP VP8, VP8L, and VP8X format parsing.
  - JPEG baseline SOF0, progressive SOF2, variable-length Exif/APP marker seeking, and fill byte handling.
  - Error resilience for nil/empty/numeric paths, missing files, 0-byte files, truncated headers, text files, and JPEGs without SOF.
  - CLI process safety verifying no system commands are spawned.
- All unit and integration test suites pass (`make test`) with 0 failures and 0 errors.
