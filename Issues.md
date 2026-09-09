# gelbooru.nvim Issues

## Open

### 1 — Meta/image auto-update on state change
The image and metadata windows need to reflect state changes immediately:
- Hiding the meta panel (`m`) should trigger a re-render of the image at the new layout dimensions
- When `resolve_post_tags` discovers an artist and calls `render_preview`, the meta window doesn't update because the `cur_id` dedup guard fires early — the tag list stays stale until the user navigates away and back

### 2 — discovered.json → main tag files transfer
Discovered tags (per-session API lookups) accumulate in `discovered.json` but never get merged back into `series.json / characters.json / artists.json / general.json`.

Options:
- Transfer on `GelbooruTag` run: prune from `discovered.json` anything now present in the main files after a full fetch
- Transfer on open: before loading, diff discovered entries against the main files and absorb them

### 3 — GelbooruTag quality / count regression
The tag-fetch command appears to produce fewer tags than it used to, and the `is_clean_tag` filter does not seem to be taking effect (tag download rate unchanged vs. pre-filter). Needs investigation into whether the filter is applied before or after writing to disk.