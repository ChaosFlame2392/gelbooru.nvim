-- tests/integration/helpers/mock_snacks.lua
-- Mock snacks.image placement engine for gelbooru.nvim integration tests.

local state = require("gelbooru.core.state")

local M = {}

M.placements_created = {}

function M.setup()
  M.placements_created = {}

  local placement_cls = {}
  placement_cls.__index = placement_cls

  placement_cls.progress = function(self)
    self.spinner_started = true
  end

  placement_cls.close = function(self)
    self.closed = true
    if state.UI.current_placement == self then
      state.UI.current_placement = nil
    end
  end

  placement_cls.update = function(self)
    self.updated_count = self.updated_count + 1
  end

  local mod
  mod = {
    new = function(buf, src, opts)
      local convert_obj = {
        aborted = false,
        abort = function(self)
          self.aborted = true
        end,
      }
      local placement = setmetatable({
        id = #M.placements_created + 1,
        buf = buf,
        src = src,
        opts = opts or {},
        closed = false,
        updated_count = 0,
        spinner_started = false,
        img = {
          src = src,
          _convert = convert_obj,
        },
      }, placement_cls)

      if mod.progress then
        mod.progress(placement)
      end

      table.insert(M.placements_created, placement)
      return placement
    end,
    progress = placement_cls.progress,
  }

  package.loaded["snacks.image.placement"] = mod
end

function M.teardown()
  package.loaded["snacks.image.placement"] = nil
  M.placements_created = {}
end

return M
