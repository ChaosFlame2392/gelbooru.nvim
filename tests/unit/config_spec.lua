-- tests/unit/config_spec.lua
-- Unit tests for gelbooru.core.config.
-- Run: make test

local config = require("gelbooru.core.config")

-- Snapshot defaults once so we can restore after each test.
local ORIG = {}
for k, v in pairs(config.options) do
  ORIG[k] = v
end

describe("config", function()
  before_each(function()
    for k, v in pairs(ORIG) do
      config.options[k] = v
    end
  end)

  describe("defaults", function()
    it("per_page is 42", function()
      assert.are.equal(42, config.options.per_page)
    end)

    it("log_level is WARN", function()
      assert.are.equal("WARN", config.options.log_level)
    end)

    it("api_base is non-empty", function()
      assert.is_truthy(config.options.api_base ~= "")
    end)

    it("prefetch_radius is non-negative", function()
      assert.is_true(config.options.prefetch_radius >= 0)
    end)
  end)

  describe("setup() clamping", function()
    it("clamps per_page below minimum to 1", function()
      config.setup({ per_page = 0 })
      assert.are.equal(1, config.options.per_page)
    end)

    it("clamps per_page above 100 to 100", function()
      config.setup({ per_page = 9999 })
      assert.are.equal(100, config.options.per_page)
    end)

    it("passes through in-range per_page unchanged", function()
      config.setup({ per_page = 42 })
      assert.are.equal(42, config.options.per_page)
    end)

    it("clamps prefetch_radius below 0 to 0", function()
      config.setup({ prefetch_radius = -10 })
      assert.are.equal(0, config.options.prefetch_radius)
    end)

    it("clamps prefetch_radius above 20 to 20", function()
      config.setup({ prefetch_radius = 100 })
      assert.are.equal(20, config.options.prefetch_radius)
    end)

    it("coerces string numbers", function()
      config.setup({ per_page = "20" })
      assert.are.equal(20, config.options.per_page)
    end)
  end)

  describe("setup() key aliasing", function()
    it("accepts uppercase PER_PAGE as fallback", function()
      config.setup({ PER_PAGE = 10 })
      assert.are.equal(10, config.options.per_page)
    end)

    it("lowercase key wins over uppercase", function()
      config.setup({ per_page = 15, PER_PAGE = 99 })
      assert.are.equal(15, config.options.per_page)
    end)

    it("passes string options through unchanged", function()
      config.setup({ log_level = "DEBUG" })
      assert.are.equal("DEBUG", config.options.log_level)
    end)
  end)

  describe("setup() nil safety", function()
    it("is a no-op for nil opts", function()
      local before = config.options.per_page
      config.setup(nil)
      assert.are.equal(before, config.options.per_page)
    end)

    it("is a no-op for empty table", function()
      local before = config.options.per_page
      config.setup({})
      assert.are.equal(before, config.options.per_page)
    end)
  end)
end)
