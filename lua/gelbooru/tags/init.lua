local db = require("gelbooru.tags.db")
local resolve = require("gelbooru.tags.resolve")
local fetcher = require("gelbooru.tags.fetcher")

local M = {}

M.db = db
M.resolve = resolve
M.fetcher = fetcher

-- Re-export all tag operations for clean require("gelbooru.tags") access
M.is_clean_tag = db.is_clean_tag
M.add_tag_to_index = db.add_tag_to_index
M.parse_tag_file = db.parse_tag_file
M.load_tags = db.load_tags

M.persist_discovered_tag = resolve.persist_discovered_tag
M.save_discovered_now = resolve.save_discovered_now
M.resolve_post_tags = resolve.resolve_post_tags
M.fetch_api_tags = resolve.fetch_api_tags

M.update_tags = fetcher.update_tags

return M
