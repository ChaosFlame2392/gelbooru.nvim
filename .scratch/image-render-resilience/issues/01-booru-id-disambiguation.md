# 01: Strict Booru ID Disambiguation & Pixiv Filename Filtering

**What to build:** Prevent spurious Gelbooru remote API queries and network queue flooding when opening folders with non-booru artwork (such as Pixiv downloads like `131102272_p0.jpg` or bare large numbers). Disambiguate Gelbooru IDs by enforcing the ceiling threshold in `core/constants.lua`, filtering out Pixiv `_p%d+` markers, and bounding bare numeric filenames between 10,000 and 25,000,000 while honoring explicit booru prefix bypasses.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] `GELBOORU_ID_CEILING = 25000000` is centralized in `lua/gelbooru/core/constants.lua`.
- [x] `extract_post_id` in `lua/gelbooru/local/scan.lua` returns `nil` for Pixiv artwork convention filenames (`_p%d+`).
- [x] `extract_post_id` returns `nil` for bare numeric filenames exceeding `GELBOORU_ID_CEILING`.
- [x] `extract_post_id` continues to extract valid post IDs within range (10,000 to 25,000,000) and preserves explicit booru prefixes (`post_`, `id_`, `ID`, `gelbooru_`).
- [x] Unit tests in `tests/unit/local_spec.lua` pass and verify ID disambiguation and ceiling boundaries.

## Answer

### Implementation Details
1. **Centralized Ceiling Constant**:
   - Added `GELBOORU_ID_CEILING = 25000000` in `lua/gelbooru/core/constants.lua`.
2. **Pixiv Filename Filtering**:
   - In `lua/gelbooru/local/scan.lua`: added an early check `if fname:find("_p%d+") then return nil end` to discard Pixiv artwork convention filenames before attempting pattern matching.
3. **Bare Numeric ID Upper Bounding**:
   - In `lua/gelbooru/local/scan.lua`: clamped bare numeric filenames (both `^(%d+)%..+$` and `^(%d+)[_%s%-]`) to `n >= 10000 and n <= constants.GELBOORU_ID_CEILING`.
   - Preserved explicit booru prefix matching (`post_`, `id_`, `ID`, `gelbooru_`, `gelbooru-`), allowing explicit IDs to bypass the bare numeric ceiling.

### Test Verification
- Added a dedicated test suite `Strict Booru ID Disambiguation & Pixiv Filename Filtering` in `tests/unit/local_spec.lua` verifying:
  - Centralization and value of `GELBOORU_ID_CEILING`.
  - Discarding Pixiv filenames with `_p%d+`.
  - Rejection of bare numeric IDs exceeding `GELBOORU_ID_CEILING`.
  - Extraction of valid IDs between 10,000 and 25,000,000.
  - Extraction of IDs with explicit booru prefixes even above ceiling.
  - Integration with `scan_local_folder` where Pixiv and over-ceiling bare files have `id = nil`.
- Executed `make test` on integration branch `feature/image-render-resilience`: all 32 integration tests, 11 autocomplete tests, 14 pipeline stress tests, 8 layout tests, and unit tests passed with 0 failures and 0 errors.
