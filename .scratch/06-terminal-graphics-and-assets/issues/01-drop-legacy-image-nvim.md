# 01: Drop Obsolete image.nvim Backend

**What to build:** Remove legacy `image.nvim` backend dispatch, dead configuration options, and associated test cases. Consolidate graphics rendering to the two active targets: native Ghostty/Kitty protocol and Snacks fallback.

**Type:** task

**Status:** resolved

**Blocked by:** None

### Scope & Technical Decisions:
- **Renderer Consolidation:** Reduce graphics backends from three to two:
  1. Primary: Native Ghostty 1.4 / Kitty Graphics Protocol driver (`kitty` / `ghostty`)
  2. Fallback: `snacks.image` adapter (for WezTerm, iTerm2, and terminal pixel renderers)
  - Dropped: Legacy `image.nvim` backend (eliminates Luarocks, ImageMagick C-bindings, and duplicate dispatch code).
- **Configuration Normalization:**
  - Remove `image_nvim` from `lua/gelbooru/core/config.lua`.
  - Normalize `config.options.backend` to accept `"auto"` (default), `"ghostty"`, `"kitty"`, or `"snacks"`.
- **Canvas Cleanup:**
  - Remove `render_image_nvim` function (lines 241–295) in `lua/gelbooru/ui/canvas.lua`.
  - Remove `if config.options.backend == "image_nvim"` dispatch branch.
- **Documentation & Spec:**
  - Update `AGENTS.md` to remove references to `image.nvim` as a runtime dependency.
- **Test Integrity:**
  - Clean up obsolete `image_nvim` tests in `tests/unit/canvas_spec.lua`.
  - Verify that `make test` passes cleanly with 0 failures and 0 errors across all 180+ assertions.

### Acceptance Criteria:
- [x] `render_image_nvim` is completely removed from `lua/gelbooru/ui/canvas.lua`.
- [x] `config.lua` normalizes `backend` option without `image_nvim`.
- [x] `AGENTS.md` accurately lists runtime dependencies (Neovim >= 0.9.0, curl, snacks.nvim or native Kitty graphics).
- [x] `tests/unit/canvas_spec.lua` contains no references to `image.nvim`.
- [x] `make test` runs 100% green with zero errors or failures.

## Answer

### Summary of Changes
1. **Canvas Cleanup (`lua/gelbooru/ui/canvas.lua`)**:
   - Completely deleted `render_image_nvim` function and its buffer allocation / placement wrapper.
   - Removed the `if config.options.backend == "image_nvim"` dispatch check from `canvas.render`.
2. **Configuration Normalization (`lua/gelbooru/core/config.lua`)**:
   - Updated `config.options.backend` default to `"auto"`.
   - Added normalizer in `config.setup()` that maps input (case-insensitively with uppercase alias support) to `"auto"`, `"ghostty"`, `"kitty"`, or `"snacks"`.
   - Obsolete and invalid backends (including `"image_nvim"`) safely normalize to `"auto"`.
3. **Documentation Alignment (`AGENTS.md`)**:
   - Updated runtime dependencies specification to declare `snacks.nvim` or native Kitty graphics instead of `image.nvim`.
4. **Test Suite Integrity (`tests/unit/canvas_spec.lua` & `tests/unit/config_spec.lua`)**:
   - Replaced legacy `image_nvim` dispatch tests in `tests/unit/canvas_spec.lua` with snacks dispatch and isolation tests that ensure third-party `image` packages are never invoked.
   - Added comprehensive normalization tests in `tests/unit/config_spec.lua` testing defaults, valid values, case-insensitivity, aliases, and normalization of legacy `"image_nvim"` to `"auto"`.
   - All tests run 100% green with 0 errors and 0 failures across the test suite via `make test`.
