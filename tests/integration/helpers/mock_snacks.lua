-- tests/integration/helpers/mock_snacks.lua
-- Mock snacks.image placement engine for gelbooru.nvim integration tests.

local state = require("gelbooru.core.state")

local M = {}

M.placements_created = {}
M.conversions_created = {}
M.conversions_run = {}
M.conversions_aborted = {}

function M.setup()
  M.placements_created = {}
  M.conversions_created = {}
  M.conversions_run = {}
  M.conversions_aborted = {}

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

  local convert_cls = {}
  convert_cls.__index = convert_cls

  convert_cls.run = function(self)
    self.running = true
    table.insert(M.conversions_run, self)
    if self.opts and self.opts.sync then
      self.done_flag = true
      if self.opts.on_done then
        self.opts.on_done(self)
      end
    else
      vim.schedule(function()
        if not self.aborted then
          self.done_flag = true
          if self.opts and self.opts.on_done then
            self.opts.on_done(self)
          end
        end
      end)
    end
  end

  convert_cls.abort = function(self)
    self.aborted = true
    table.insert(M.conversions_aborted, self)
  end

  convert_cls.done = function(self)
    return self.done_flag == true
  end

  convert_cls.ready = function(self)
    return self.done_flag == true
  end

  convert_cls.error = function(self)
    return self._err
  end

  local convert_mod = {
    convert = function(opts)
      local conv = setmetatable({
        opts = opts or {},
        src = opts and opts.src,
        file = opts and opts.src and (opts.src .. ".png"),
        done_flag = false,
        aborted = false,
        _err = nil,
      }, convert_cls)
      table.insert(M.conversions_created, conv)
      return conv
    end,
  }

  _G.Snacks = _G.Snacks or {
    image = {
      config = {
        convert = {},
        debug = {},
      },
    },
  }
  package.loaded["snacks"] = _G.Snacks
  package.loaded["snacks.image.convert"] = convert_mod
end

function M.teardown()
  package.loaded["snacks.image.placement"] = nil
  package.loaded["snacks.image.convert"] = nil
  package.loaded["snacks"] = nil
  _G.Snacks = nil
  M.placements_created = {}
  M.conversions_created = {}
  M.conversions_run = {}
  M.conversions_aborted = {}
end

return M
