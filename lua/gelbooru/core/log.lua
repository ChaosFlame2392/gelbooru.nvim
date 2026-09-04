local config = require("gelbooru.core.config")

local M = {}

local LOG_LEVELS = {
  DEBUG = 1,
  INFO = 2,
  WARN = 3,
  ERROR = 4,
}

function M.log(level, cat, fmt, ...)
  local configured_level = config.options.log_level
  if configured_level == false then
    return
  end
  if type(configured_level) == "string" then
    local upper_lvl = configured_level:upper()
    if upper_lvl == "OFF" or upper_lvl == "NONE" then
      return
    end
    local threshold = LOG_LEVELS[upper_lvl] or LOG_LEVELS.DEBUG
    if LOG_LEVELS[level] and LOG_LEVELS[level] < threshold then
      return
    end
  elseif type(configured_level) == "number" then
    if LOG_LEVELS[level] and LOG_LEVELS[level] < configured_level then
      return
    end
  end

  local msg = select("#", ...) > 0 and string.format(fmt, ...) or (fmt or "")
  local line = string.format("[%s] [%-5s] [%-10s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), level, cat, msg)
  local f = io.open(config.options.log_file, "a")
  if f then
    f:write(line)
    f:close()
  end
end

setmetatable(M, {
  __call = function(_, ...)
    M.log(...)
  end,
})

return M
