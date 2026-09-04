-- ─────────────────────────────────────────────────────────────────────────────
-- gelbooru.nvim — Gelbooru image browser for Neovim
--
-- Commands:
--   :Gelbooru       — open tag picker → image browser
--   :GelbooruTags   — download & cache popular tags for autocomplete
--
-- Auth setup (do once, never commit to git):
--   Create ~/.config/nvim/gelbooru_auth.json:
--   { "api_key": "YOUR_KEY", "user_id": "YOUR_ID" }
-- ─────────────────────────────────────────────────────────────────────────────

local M = {}

local config = require("gelbooru.core.config")
local ui = require("gelbooru.ui")
local tags = require("gelbooru.tags")

function M.setup(opts)
  config.setup(opts)
end

function M.open(initial_tags)
  ui.open(initial_tags)
end

function M.browse()
  return M.open()
end

function M.update_tags()
  tags.update_tags()
end

M.tags = M.update_tags

return M
