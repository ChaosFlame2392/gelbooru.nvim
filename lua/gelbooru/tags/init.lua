local catalog = require("gelbooru.tags.catalog")
local fetcher = require("gelbooru.tags.fetcher")

local M = setmetatable({
  catalog = catalog,
  fetcher = fetcher,
  update_tags = fetcher.update_tags,
  verify_tags = fetcher.verify_tags,
  refresh_tags = fetcher.refresh_tags,
}, {
  __index = catalog,
})

return M
