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

    it("constants defines PREFETCH_LOOKAHEAD_DEPTH as 8", function()
      local constants = require("gelbooru.core.constants")
      assert.are.equal(8, constants.PREFETCH_LOOKAHEAD_DEPTH)
    end)

    it("constants defines AUTOPAGE_BOUNDARY_THRESHOLD as 15", function()
      local constants = require("gelbooru.core.constants")
      assert.are.equal(15, constants.AUTOPAGE_BOUNDARY_THRESHOLD)
    end)

    it("constants defines DEFAULT_PREFETCH_RADIUS as 8", function()
      local constants = require("gelbooru.core.constants")
      assert.are.equal(8, constants.DEFAULT_PREFETCH_RADIUS)
    end)

    it("constants defines rate governor limits and priority levels", function()
      local constants = require("gelbooru.core.constants")
      assert.are.equal(8, constants.RATE_LIMIT_RPS)
      assert.are.equal(125, constants.RATE_LIMIT_MIN_INTERVAL_MS)
      assert.are.equal(4, constants.RATE_LIMIT_MAX_CONCURRENT_SOCKETS)
      assert.are.equal(1, constants.PRIORITY_PREVIEW)
      assert.are.equal(2, constants.PRIORITY_PREFETCH)
      assert.are.equal(3, constants.PRIORITY_AUTOPAGE)
      assert.are.equal(4, constants.PRIORITY_METADATA)
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

  describe("META_TAGS", function()
    it("contains id: meta tag", function()
      local found = false
      for _, tag in ipairs(config.META_TAGS) do
        if tag.n == "id:" then
          found = true
          assert.are.equal(5, tag.t)
          assert.are.equal(0, tag.c)
          break
        end
      end
      assert.is_true(found, "id: meta tag not found in META_TAGS")
    end)
  end)

  describe("get_discovered_tags_file()", function()
    it("returns path within options.tags_dir", function()
      config.options.tags_dir = "/custom/tags/dir"
      assert.are.equal("/custom/tags/dir/discovered.json", config.get_discovered_tags_file())
    end)
  end)

  describe("TAG_TYPES and TAG_BADGES constants", function()
    it("defines canonical tag category string names", function()
      assert.are.equal("general", config.TAG_TYPES[0])
      assert.are.equal("artist", config.TAG_TYPES[1])
      assert.are.equal("copyright", config.TAG_TYPES[3])
      assert.are.equal("character", config.TAG_TYPES[4])
      assert.are.equal("meta", config.TAG_TYPES[5])
      assert.are.equal("meme", config.TAG_TYPES[6])
    end)

    it("defines user-facing short badges for each category", function()
      assert.are.equal("General", config.TAG_BADGES[0])
      assert.are.equal("Artist", config.TAG_BADGES[1])
      assert.are.equal("Series", config.TAG_BADGES[3])
      assert.are.equal("Char", config.TAG_BADGES[4])
      assert.are.equal("Meta", config.TAG_BADGES[5])
      assert.are.equal("Meme", config.TAG_BADGES[6])
    end)
  end)

  describe("VALID_MEDIA_EXTS", function()
    it("whitelists supported image and video extensions", function()
      local supported = { "jpg", "jpeg", "png", "gif", "webp", "mp4", "webm", "avi", "mov", "mkv" }
      for _, ext in ipairs(supported) do
        assert.is_true(config.VALID_MEDIA_EXTS[ext] == true, "extension " .. ext .. " should be supported")
      end
    end)

    it("rejects non-media extensions", function()
      local unsupported = { "txt", "zip", "json", "part", "md", "exe", "tar", "pdf" }
      for _, ext in ipairs(unsupported) do
        assert.is_nil(config.VALID_MEDIA_EXTS[ext], "extension " .. ext .. " should not be valid media")
      end
    end)
  end)

  describe("setup() option assignments", function()
    it("assigns custom paths and boolean/string configurations", function()
      config.setup({
        save_dir = "/tmp/custom_save",
        tags_dir = "/tmp/custom_tags",
        cache_dir = "/tmp/custom_cache",
        auth_file = "/tmp/custom_auth.json",
        api_base = "https://example.com/api",
        tags_api = "https://example.com/tags",
        log_file = "/tmp/custom_log.log",
        media_player = "mpv",
        show_tags_in_list = true,
      })

      assert.are.equal("/tmp/custom_save", config.options.save_dir)
      assert.are.equal("/tmp/custom_tags", config.options.tags_dir)
      assert.are.equal("/tmp/custom_cache", config.options.cache_dir)
      assert.are.equal("/tmp/custom_auth.json", config.options.auth_file)
      assert.are.equal("https://example.com/api", config.options.api_base)
      assert.are.equal("https://example.com/tags", config.options.tags_api)
      assert.are.equal("/tmp/custom_log.log", config.options.log_file)
      assert.are.equal("mpv", config.options.media_player)
      assert.is_true(config.options.show_tags_in_list)
    end)
  end)
end)

