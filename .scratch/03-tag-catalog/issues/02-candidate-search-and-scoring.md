# 02: Candidate Search & Popularity Scoring Engine

**What to build:** Move tag candidate matching and popularity-weighted ranking from `ui/autocomplete.lua` into `lua/gelbooru/tags/catalog.lua`. Expose `search(prefix, opts)` returning sorted candidates (`{ name, category, count, score }`) with prefix bucketing, substring fallbacks, and local-only filtering.

**Type:** task

**Status:** resolved

**Blocked by:** 01: Encapsulated Tag Catalog & Index Loading

- [x] Implement `search(prefix, opts)` in `lua/gelbooru/tags/catalog.lua`.
- [x] Match candidates via first-letter hash buckets for sub-3ms prefix lookups.
- [x] Implement category relevance weighting and logarithmic post count scoring.
- [x] Implement substring fallback search when prefix search returns fewer than limit results.
- [x] Support `opts.is_local` filtering to control local-only meta tags (`sort:date`, `sort:mtime`).
- [x] Unit tests in `tests/unit/tag_catalog_spec.lua` verify search ranking, candidate sorting, and fallback results.

## Answer summary

Implemented `catalog.search(prefix, opts)` in `lua/gelbooru/tags/catalog.lua`:
- First-letter hash bucket lookups (`series_by_first`, `chars_by_first`, `artists_by_first`, `general_by_first`) delivering sub-3ms candidate matching.
- Exact match, normalized match, prefix, and substring base scoring combined with logarithmic post count popularity scoring (`math.log10(count + 1) * constants.SCORE_POP_MULTIPLIER`) and category nudges (`Series > Character > Artist > General`).
- Meta tags pinned at `constants.SCORE_META_PIN` (1,000,000).
- Substring fallback search across full lists when bucket search yields fewer than `constants.AC_SUBSTRING_TRIGGER` candidates for queries with length >= `constants.AC_MIN_TRIGGER_LEN`.
- Live API tag lookup trigger (`catalog.fetch_api_tags` / `tags.fetch_api_tags`) when candidate count < `constants.AC_API_FALLBACK_COUNT` and query is not a syntax directive.
- Option filtering (`opts.is_local` filtering of `local_only` meta tags, `opts.limit` result caps).
- Full unit test coverage in `tests/unit/tag_catalog_spec.lua`.
