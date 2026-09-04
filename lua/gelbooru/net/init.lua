local download = require("gelbooru.net.download")
local api = require("gelbooru.net.api")

local M = {}

M.download = download
M.api = api

-- Re-export common functions directly on net module for convenience
M.curl_async = download.curl_async
M.download_async = download.download_async
M.cancel_prefetch_timers = download.cancel_prefetch_timers
M.prefetch_around = download.prefetch_around
M.fetch = api.fetch
M.execute_search = api.execute_search
M.save_current = api.save_current
M.scroll_meta = api.scroll_meta

return M
