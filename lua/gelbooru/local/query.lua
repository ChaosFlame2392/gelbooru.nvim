-- Re-export all functions and submodules from the dedicated query package
-- so existing code and tests (`require("gelbooru.local.query")`) continue to work seamlessly.
local query = require("gelbooru.query")

return query
