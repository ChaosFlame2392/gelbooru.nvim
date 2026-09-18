-- tests/integration/helpers/mock_snacks.lua
-- Mock snacks.image placement engine for gelbooru.nvim integration tests.

local state = require("gelbooru.core.state")

local M = {}

M.placements_created = {}

function M.setup()
  M.placements_created = {}

  package.loaded["snacks.image.placement"] = {
    new = function(buf, src, opts)
      local placement = {
        id = #M.placements_created + 1,
        buf = buf,
        src = src,
        opts = opts or {},
        closed = false,
        updated_count = 0,
        close = function(self)
          self.closed = true
          if state.UI.current_placement == self then
            state.UI.current_placement = nil
          end
        end,
        update = function(self)
          self.updated_count = self.updated_count + 1
        end,
      }
      table.insert(M.placements_created, placement)
      return placement
    end,
  }
end

function M.teardown()
  package.loaded["snacks.image.placement"] = nil
  M.placements_created = {}
end

return M
