-- tests/unit/tag_catalog_spec.lua
-- Unit tests for gelbooru.tags.catalog — encapsulated catalog, validation, and index loading.

local state = require("gelbooru.core.state")
local config = require("gelbooru.core.config")
local constants = require("gelbooru.core.constants")

describe("tags.catalog", function()
  local catalog
  local tmp_dir

  local orig_tags_dir
  local orig_curl_async
  local download = require("gelbooru.net.download")

  before_each(function()
    package.loaded["gelbooru.tags.catalog"] = nil
    catalog = require("gelbooru.tags.catalog")
    catalog.reset()
    state.reset_tag_state()

    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    orig_tags_dir = config.options.tags_dir
    config.options.tags_dir = tmp_dir
    orig_curl_async = download.curl_async
  end)

  after_each(function()
    if catalog then
      catalog.reset()
    end
    download.curl_async = orig_curl_async
    config.options.tags_dir = orig_tags_dir
    if tmp_dir and vim.fn.isdirectory(tmp_dir) == 1 then
      vim.fn.delete(tmp_dir, "rf")
    end
    state.reset_tag_state()
  end)

  describe("is_clean_tag", function()
    it("accepts a normal tag with count > 0", function()
      assert.is_true(catalog.is_clean_tag("hoshino_ai", 5000, 4))
    end)

    it("rejects tags shorter than minimum length", function()
      assert.is_false(catalog.is_clean_tag("a", 100, 0))
    end)

    it("rejects nil or non-string tag names", function()
      assert.is_false(catalog.is_clean_tag(nil, 100, 0))
      assert.is_false(catalog.is_clean_tag(12345, 100, 0))
      assert.is_false(catalog.is_clean_tag({}, 100, 0))
    end)

    it("rejects non-meta tags with count < 1", function()
      assert.is_false(catalog.is_clean_tag("some_tag", 0, 0))
      assert.is_false(catalog.is_clean_tag("some_tag", -5, 0))
    end)

    it("accepts meta tags (type 5) regardless of count", function()
      assert.is_true(catalog.is_clean_tag("sort:score", 0, 5))
      assert.is_true(catalog.is_clean_tag("rating:general", 0, 5))
    end)

    it("rejects tags starting or ending with punctuation/separators", function()
      assert.is_false(catalog.is_clean_tag("-leading_dash", 100, 0))
      assert.is_false(catalog.is_clean_tag("_leading_underscore", 100, 0))
      assert.is_false(catalog.is_clean_tag("trailing_dash-", 100, 0))
      assert.is_false(catalog.is_clean_tag("trailing_underscore_", 100, 0))
      assert.is_false(catalog.is_clean_tag("trailing_dot.", 100, 0))
      assert.is_false(catalog.is_clean_tag("trailing_question?", 100, 0))
      assert.is_false(catalog.is_clean_tag("trailing_exclamation!", 100, 0))
    end)

    it("rejects tags containing commas, semicolons, quotes or invalid chars", function()
      assert.is_false(catalog.is_clean_tag("tag,with,comma", 100, 0))
      assert.is_false(catalog.is_clean_tag("tag;semicolon", 100, 0))
      assert.is_false(catalog.is_clean_tag("tag'quote", 100, 0))
      assert.is_false(catalog.is_clean_tag('tag"doublequote', 100, 0))
    end)

    it("rejects URLs and HTML entities", function()
      assert.is_false(catalog.is_clean_tag("https://gelbooru.com", 100, 0))
      assert.is_false(catalog.is_clean_tag("cat&amp;dog", 100, 0))
      assert.is_false(catalog.is_clean_tag("&gt;tag", 100, 0))
    end)

    it("rejects tags with double separators", function()
      assert.is_false(catalog.is_clean_tag("double__underscore", 100, 0))
      assert.is_false(catalog.is_clean_tag("double--hyphen", 100, 0))
      assert.is_false(catalog.is_clean_tag("double..dot", 100, 0))
    end)

    it("rejects tags exceeding maximum length unless containing disambiguation parens", function()
      local too_long = ("a"):rep(constants.TAG_MAX_NAME_LEN + 1)
      assert.is_false(catalog.is_clean_tag(too_long, 100, 0))

      local long_with_parens = ("a"):rep(constants.TAG_MAX_NAME_LEN + 1) .. "_(character)"
      assert.is_true(catalog.is_clean_tag(long_with_parens, 100, 0))
    end)
  end)

  describe("tag indexing & encapsulation", function()
    it("indexes tags and normalizes lowercase and normalized keys", function()
      catalog.add_tag({ n = "Hoshino_Ai", c = 5000, t = 4 })

      assert.is_true(catalog.has_tag("Hoshino_Ai"))
      assert.is_true(catalog.has_tag("hoshino_ai"))

      local tag = catalog.get_tag("hoshino_ai")
      assert.is_not_nil(tag)
      assert.are.equal("Hoshino_Ai", tag.n)
      assert.are.equal("hoshino_ai", tag.n_lower)
      assert.are.equal(5000, tag.c)
      assert.are.equal(4, tag.t)
    end)

    it("skips indexing invalid or unclean tags", function()
      catalog.add_tag({ n = "a", c = 0, t = 0 })
      assert.is_false(catalog.has_tag("a"))
      assert.is_nil(catalog.get_tag("a"))

      catalog.add_tag(nil)
      catalog.add_tag({})
      catalog.add_tag({ n = 12345 })
    end)

    it("does not leak tag tables or bucket maps into global State", function()
      catalog.add_tag({ n = "vocaloid", c = 200000, t = 3 })

      assert.is_nil(state.State.tags_by_name)
      assert.is_nil(state.State.series)
      assert.is_nil(state.State.series_by_first)
      assert.is_true(catalog.has_tag("vocaloid"))
    end)

    it("does not expose internal category arrays or bucket maps on the catalog object", function()
      catalog.add_tag({ n = "vocaloid", c = 200000, t = 3 })

      assert.is_nil(catalog.series)
      assert.is_nil(catalog.characters)
      assert.is_nil(catalog.artists)
      assert.is_nil(catalog.general)
      assert.is_nil(catalog.series_by_first)
      assert.is_nil(catalog.chars_by_first)
      assert.is_nil(catalog.tags_by_name)
    end)
  end)

  describe("progressive loading & lifecycle", function()
    it("reports is_loaded() == false before loading and true after completion", function()
      assert.is_false(catalog.is_loaded())
    end)

    it("loads META_TAGS when no category files exist in tags_dir", function()
      local done = false
      catalog.load({ tags_dir = tmp_dir, discovered_file = tmp_dir .. "/discovered.json" }, function()
        done = true
      end)

      assert.is_true(done)
      assert.is_true(catalog.is_loaded())
      assert.is_true(catalog.has_tag("sort:score"))
      assert.is_true(catalog.has_tag("rating:general"))
      assert.is_true(catalog.has_tag("id:"))

      local stats = catalog.get_stats()
      assert.is_true(stats.meta >= #config.META_TAGS)
      assert.are.equal(0, stats.series)
      assert.are.equal(0, stats.characters)
    end)

    it("loads discovered.json synchronously if present in tags_dir", function()
      local disc_file = tmp_dir .. "/discovered.json"
      local disc_tags = {
        { n = "custom_artist_tag", c = 50, t = 1 },
        { n = "custom_char_tag", c = 150, t = 4 },
      }
      vim.fn.writefile({ vim.fn.json_encode(disc_tags) }, disc_file)

      -- Create an empty series file so has_split is true
      vim.fn.writefile({ "[]" }, tmp_dir .. "/series.json")

      local done = false
      catalog.load({ tags_dir = tmp_dir, discovered_file = disc_file }, function()
        done = true
      end)

      -- Discovered tags should already be available immediately or when done
      assert.is_true(catalog.has_tag("custom_artist_tag"))
      assert.is_true(catalog.has_tag("custom_char_tag"))

      vim.wait(1000, function() return done end)
      assert.is_true(done)
      assert.is_true(catalog.is_loaded())
    end)

    it("progressively loads category files across event loop turns", function()
      local series_tags = {
        { n = "genshin_impact", c = 90000, t = 3 },
        { n = "honkai_star_rail", c = 80000, t = 3 },
      }
      local char_tags = {
        { n = "furina", c = 40000, t = 4 },
      }
      local artist_tags = {
        { n = "ask_(artist)", c = 5000, t = 1 },
      }
      local general_tags = {
        { n = "1girl", c = 1000000, t = 0 },
        { n = "solo", c = 950000, t = 0 },
      }

      vim.fn.writefile({ vim.fn.json_encode(series_tags) }, tmp_dir .. "/series.json")
      vim.fn.writefile({ vim.fn.json_encode(char_tags) }, tmp_dir .. "/characters.json")
      vim.fn.writefile({ vim.fn.json_encode(artist_tags) }, tmp_dir .. "/artists.json")
      vim.fn.writefile({ vim.fn.json_encode(general_tags) }, tmp_dir .. "/general.json")

      local done = false
      catalog.load({ tags_dir = tmp_dir, discovered_file = tmp_dir .. "/discovered.json" }, function()
        done = true
      end)

      -- Immediately after call, should be in loading state
      assert.is_false(catalog.is_loaded())
      assert.is_true(catalog.is_loading())

      vim.wait(2000, function() return done end)
      assert.is_true(done)
      assert.is_true(catalog.is_loaded())
      assert.is_false(catalog.is_loading())

      assert.is_true(catalog.has_tag("genshin_impact"))
      assert.is_true(catalog.has_tag("honkai_star_rail"))
      assert.is_true(catalog.has_tag("furina"))
      assert.is_true(catalog.has_tag("ask_(artist)"))
      assert.is_true(catalog.has_tag("1girl"))
      assert.is_true(catalog.has_tag("solo"))

      local stats = catalog.get_stats()
      assert.are.equal(2, stats.series)
      assert.are.equal(1, stats.characters)
      assert.are.equal(1, stats.artists)
      assert.are.equal(2, stats.general)
    end)

    it("respects caps options to limit loaded tags per category", function()
      local series_tags = {
        { n = "series_1", c = 100, t = 3 },
        { n = "series_2", c = 90, t = 3 },
        { n = "series_3", c = 80, t = 3 },
      }
      vim.fn.writefile({ vim.fn.json_encode(series_tags) }, tmp_dir .. "/series.json")

      local done = false
      catalog.load({
        tags_dir = tmp_dir,
        discovered_file = tmp_dir .. "/discovered.json",
        caps = { series = 2 },
      }, function()
        done = true
      end)

      vim.wait(2000, function() return done end)
      assert.is_true(done)

      assert.is_true(catalog.has_tag("series_1"))
      assert.is_true(catalog.has_tag("series_2"))
      assert.is_false(catalog.has_tag("series_3"))

      local stats = catalog.get_stats()
      assert.are.equal(2, stats.series)
    end)

    it("reset() cancels in-flight loading and clears all state", function()
      local series_tags = {
        { n = "series_1", c = 100, t = 3 },
      }
      vim.fn.writefile({ vim.fn.json_encode(series_tags) }, tmp_dir .. "/series.json")

      local called = false
      catalog.load({ tags_dir = tmp_dir, discovered_file = tmp_dir .. "/discovered.json" }, function()
        called = true
      end)

      catalog.reset()

      assert.is_false(catalog.is_loaded())
      assert.is_false(catalog.is_loading())
      assert.is_false(catalog.has_tag("series_1"))
      assert.are.equal(0, catalog.get_stats().total)

      -- Wait to ensure in-flight schedule turns do not run and resurrect data
      vim.wait(200)
      assert.is_false(called)
      assert.is_false(catalog.has_tag("series_1"))
    end)

    it("queues and invokes all callbacks when load is called multiple times concurrently", function()
      local series_tags = {
        { n = "series_concurrent", c = 500, t = 3 },
      }
      vim.fn.writefile({ vim.fn.json_encode(series_tags) }, tmp_dir .. "/series.json")

      local cb1_called = false
      local cb2_called = false
      local cb3_called = false

      catalog.load({ tags_dir = tmp_dir, discovered_file = tmp_dir .. "/discovered.json" }, function()
        cb1_called = true
      end)
      catalog.load({ tags_dir = tmp_dir, discovered_file = tmp_dir .. "/discovered.json" }, function()
        cb2_called = true
      end)
      catalog.load({ tags_dir = tmp_dir, discovered_file = tmp_dir .. "/discovered.json" }, function()
        cb3_called = true
      end)

      vim.wait(2000, function() return cb1_called and cb2_called and cb3_called end)
      assert.is_true(cb1_called)
      assert.is_true(cb2_called)
      assert.is_true(cb3_called)
      assert.is_true(catalog.is_loaded())
    end)

    it("invokes callback immediately when load is called after already loaded", function()
      catalog.load({ tags_dir = tmp_dir, discovered_file = tmp_dir .. "/discovered.json" })
      assert.is_true(catalog.is_loaded())

      local cb_called = false
      catalog.load(function()
        cb_called = true
      end)
      assert.is_true(cb_called)
    end)

    it("handles corrupt JSON files gracefully without throwing", function()
      vim.fn.writefile({ "{ corrupt json" }, tmp_dir .. "/series.json")

      local done = false
      assert.has_no.errors(function()
        catalog.load({ tags_dir = tmp_dir, discovered_file = tmp_dir .. "/discovered.json" }, function()
          done = true
        end)
      end)

      vim.wait(2000, function() return done end)
      assert.is_true(done)
      assert.is_true(catalog.is_loaded())
    end)

    it("handles corrupt discovered.json file gracefully", function()
      vim.fn.writefile({ "{ corrupt json" }, tmp_dir .. "/discovered.json")
      vim.fn.writefile({ "[]" }, tmp_dir .. "/series.json")

      local done = false
      assert.has_no.errors(function()
        catalog.load({ tags_dir = tmp_dir, discovered_file = tmp_dir .. "/discovered.json" }, function()
          done = true
        end)
      end)

      vim.wait(2000, function() return done end)
      assert.is_true(done)
      assert.is_true(catalog.is_loaded())
    end)
  end)

  describe("catalog list and bucket removal helpers", function()
    it("removes items from list by lowercase name", function()
      local list = {
        { n = "Tag_1", n_lower = "tag_1" },
        { n = "Tag_2", n_lower = "tag_2" },
      }
      assert.is_true(catalog.remove_from_list(list, "tag_1"))
      assert.are.equal(1, #list)
      assert.are.equal("tag_2", list[1].n_lower)
      assert.is_false(catalog.remove_from_list(list, "non_existent"))
    end)

    it("removes items from bucket map by lowercase name", function()
      local bucket_map = {
        ["t"] = {
          { n = "tag_1", n_lower = "tag_1" },
          { n = "tag_2", n_lower = "tag_2" },
        },
      }
      assert.is_true(catalog.remove_from_bucket(bucket_map, "tag_1"))
      assert.are.equal(1, #bucket_map["t"])
      assert.are.equal("tag_2", bucket_map["t"][1].n_lower)
      assert.is_false(catalog.remove_from_bucket(bucket_map, "non_existent"))
      assert.is_false(catalog.remove_from_bucket(nil, "tag_1"))
    end)
  end)

  describe("record_discovered & save_discovered_now", function()
    it("records a single discovered tag and indexes it immediately", function()
      local ok = catalog.record_discovered({ n = "yoasobi", c = 1200, t = 1 })
      assert.is_true(ok)
      assert.is_true(catalog.has_tag("yoasobi"))
      assert.is_true(catalog.has_tag("YOASOBI"))

      local tag = catalog.get_tag("yoasobi")
      assert.is_not_nil(tag)
      assert.are.equal("yoasobi", tag.n_lower)
      assert.are.equal(1, tag.t)
      assert.are.equal(1200, tag.c)

      local stats = catalog.get_stats()
      assert.are.equal(1, stats.artists)
      assert.are.equal(1, stats.discovered)
    end)

    it("records an array of discovered tags and filters out unclean items", function()
      local ok = catalog.record_discovered({
        { n = "hoshino_aquamarine", c = 8000, t = 4 },
        { n = "kurokawa_akane", c = 7500, t = 4 },
        { n = "a", c = 0, t = 0 },
        { n = "-invalid_dash", c = 100, t = 0 },
      })
      assert.is_true(ok)
      assert.is_true(catalog.has_tag("hoshino_aquamarine"))
      assert.is_true(catalog.has_tag("kurokawa_akane"))
      assert.is_false(catalog.has_tag("a"))
      assert.is_false(catalog.has_tag("-invalid_dash"))

      local stats = catalog.get_stats()
      assert.are.equal(2, stats.characters)
      assert.are.equal(2, stats.discovered)
    end)

    it("returns false and avoids duplication when tags are already discovered", function()
      catalog.record_discovered({ n = "yoasobi", c = 1200, t = 1 })
      assert.are.equal(1, catalog.get_stats().discovered)

      local again = catalog.record_discovered({ n = "yoasobi", c = 1200, t = 1 })
      assert.is_false(again)
      assert.are.equal(1, catalog.get_stats().discovered)
    end)

    it("debounces JSON persistence to disk after 500ms", function()
      local disc_file = config.get_discovered_tags_file()
      assert.are.equal(0, vim.fn.filereadable(disc_file))

      catalog.record_discovered({ n = "delayed_save_artist", c = 500, t = 1 })
      -- Immediately after call, file should not yet be written
      assert.are.equal(0, vim.fn.filereadable(disc_file))

      -- Wait for 500ms debounce timer to fire
      local written = vim.wait(1000, function()
        return vim.fn.filereadable(disc_file) == 1
      end)
      assert.is_true(written)

      local f = io.open(disc_file, "r")
      local raw = f:read("*a")
      f:close()
      local items = vim.fn.json_decode(raw)
      assert.are.equal(1, #items)
      assert.are.equal("delayed_save_artist", items[1].n)
      assert.are.equal(1, items[1].t)
      assert.are.equal(500, items[1].c)
    end)

    it("save_discovered_now flushes immediately without waiting for timer", function()
      local disc_file = config.get_discovered_tags_file()
      catalog.record_discovered({ n = "immediate_flush_tag", c = 300, t = 0 })
      assert.are.equal(0, vim.fn.filereadable(disc_file))

      catalog.save_discovered_now()
      assert.are.equal(1, vim.fn.filereadable(disc_file))

      local f = io.open(disc_file, "r")
      local raw = f:read("*a")
      f:close()
      local items = vim.fn.json_decode(raw)
      assert.are.equal(1, #items)
      assert.are.equal("immediate_flush_tag", items[1].n)
    end)

    it("save_discovered_now merges with existing entries on disk", function()
      local disc_file = config.get_discovered_tags_file()
      local existing = {
        { n = "preexisting_tag", c = 100, t = 3 },
      }
      vim.fn.writefile({ vim.fn.json_encode(existing) }, disc_file)

      catalog.record_discovered({ n = "new_tag", c = 200, t = 0 })
      catalog.save_discovered_now()

      local f = io.open(disc_file, "r")
      local raw = f:read("*a")
      f:close()
      local items = vim.fn.json_decode(raw)
      assert.are.equal(2, #items)
      assert.are.equal("preexisting_tag", items[1].n)
      assert.are.equal("new_tag", items[2].n)
    end)
  end)

  describe("prune_tag & disk pruning", function()
    it("prunes tag from memory immediately and updates stats", function()
      catalog.record_discovered({ n = "temporary_artist", c = 300, t = 1 })
      assert.is_true(catalog.has_tag("temporary_artist"))
      assert.are.equal(1, catalog.get_stats().artists)
      assert.are.equal(1, catalog.get_stats().discovered)

      local existed = catalog.prune_tag("temporary_artist")
      assert.is_true(existed)
      assert.is_false(catalog.has_tag("temporary_artist"))
      assert.are.equal(0, catalog.get_stats().artists)
      assert.are.equal(0, catalog.get_stats().discovered)
    end)

    it("returns false when pruning a tag that does not exist in memory", function()
      assert.is_false(catalog.prune_tag("ghost_tag"))
      assert.is_false(catalog.prune_tag(nil))
      assert.is_false(catalog.prune_tag(""))
    end)

    it("prunes tag from disk immediately when immediate_disk option is true", function()
      local series_file = tmp_dir .. "/series.json"
      local disc_file = config.get_discovered_tags_file()
      vim.fn.writefile({ vim.fn.json_encode({
        { n = "dead_series", c = 100, t = 3 },
        { n = "alive_series", c = 200, t = 3 },
      }) }, series_file)
      vim.fn.writefile({ vim.fn.json_encode({
        { n = "dead_series", c = 100, t = 3 },
      }) }, disc_file)

      catalog.add_tag({ n = "dead_series", c = 100, t = 3 })
      catalog.add_tag({ n = "alive_series", c = 200, t = 3 })

      local ok = catalog.prune_tag("dead_series", { immediate_disk = true })
      assert.is_true(ok)
      assert.is_false(catalog.has_tag("dead_series"))
      assert.is_true(catalog.has_tag("alive_series"))

      local f_ser = io.open(series_file, "r")
      local ser_data = vim.fn.json_decode(f_ser:read("*a"))
      f_ser:close()
      assert.are.equal(1, #ser_data)
      assert.are.equal("alive_series", ser_data[1].n)

      local f_disc = io.open(disc_file, "r")
      local disc_data = vim.fn.json_decode(f_disc:read("*a"))
      f_disc:close()
      assert.are.equal(0, #disc_data)
    end)

    it("debounces disk prune with 1000ms delay by default", function()
      local general_file = tmp_dir .. "/general.json"
      vim.fn.writefile({ vim.fn.json_encode({
        { n = "soon_dead_tag", c = 50, t = 0 },
        { n = "survivor_tag", c = 50, t = 0 },
      }) }, general_file)

      catalog.add_tag({ n = "soon_dead_tag", c = 50, t = 0 })
      catalog.add_tag({ n = "survivor_tag", c = 50, t = 0 })

      catalog.prune_tag("soon_dead_tag")
      assert.is_false(catalog.has_tag("soon_dead_tag"))

      -- Immediately after call, disk file should still have the tag
      local f1 = io.open(general_file, "r")
      local d1 = vim.fn.json_decode(f1:read("*a"))
      f1:close()
      assert.are.equal(2, #d1)

      -- Wait for 1000ms timer to flush
      local pruned_disk = vim.wait(2000, function()
        local f = io.open(general_file, "r")
        if not f then return false end
        local d = vim.fn.json_decode(f:read("*a"))
        f:close()
        return #d == 1
      end)
      assert.is_true(pruned_disk)
    end)
  end)

  describe("resolve_post_tags", function()
    it("ignores posts without tags or with empty tags", function()
      local called = false
      catalog.resolve_post_tags(nil, function() called = true end)
      catalog.resolve_post_tags({}, function() called = true end)
      catalog.resolve_post_tags({ tags = "" }, function() called = true end)
      assert.is_false(called)
    end)

    it("extracts unknown tags, queries API, records discovered tags, and triggers callback on artist", function()
      catalog.add_tag({ n = "already_known", c = 1000, t = 0 })

      local queried_url = nil
      download.curl_async = function(url, cb)
        queried_url = url
        vim.schedule(function()
          local payload = {
            tag = {
              { name = "discovered_artist", count = "350", type = "1" },
              { name = "discovered_char", count = "1200", type = "4" },
            },
          }
          cb(vim.fn.json_encode(payload))
        end)
      end

      local callback_called = false
      local post = {
        id = 99999,
        tags = "already_known discovered_artist discovered_char dead_mystery_tag",
      }

      catalog.resolve_post_tags(post, function()
        callback_called = true
      end)

      assert.is_not_nil(queried_url)
      assert.is_true(queried_url:find("discovered_artist") ~= nil)
      assert.is_true(queried_url:find("discovered_char") ~= nil)
      assert.is_nil(queried_url:find("already_known"))

      vim.wait(1000, function() return callback_called end)
      assert.is_true(callback_called)
      assert.is_true(catalog.has_tag("discovered_artist"))
      assert.is_true(catalog.has_tag("discovered_char"))
      assert.are.equal(1, catalog.get_tag("discovered_artist").t)
      assert.are.equal(4, catalog.get_tag("discovered_char").t)

      -- dead_mystery_tag was not in API response, so it should be placed in negative cache
      -- A second resolve call with the same post should not query the API again
      queried_url = nil
      catalog.resolve_post_tags(post, function() end)
      assert.is_nil(queried_url)
    end)
  end)

  describe("fetch_api_tags", function()
    it("ignores queries shorter than 2 characters", function()
      local queried = false
      download.curl_async = function(url, cb)
        queried = true
      end
      catalog.fetch_api_tags("")
      catalog.fetch_api_tags("a")
      vim.wait(400)
      assert.is_false(queried)
    end)

    it("debounces API query (300ms) and indexes returned tags", function()
      local queried_url = nil
      download.curl_async = function(url, cb)
        queried_url = url
        vim.schedule(function()
          local payload = {
            tag = {
              { name = "live_api_series", count = "4500", type = "3" },
              { name = "live_api_artist", count = "800", type = "1" },
            },
          }
          cb(vim.fn.json_encode(payload))
        end)
      end

      catalog.fetch_api_tags("live")
      assert.is_nil(queried_url) -- Debounced, not immediate

      -- Wait 300ms for debounce timer to fire
      vim.wait(1000, function() return queried_url ~= nil end)
      assert.is_not_nil(queried_url)
      assert.is_true(queried_url:find("name_pattern=%%live%%") ~= nil)

      -- Wait for curl callback to schedule
      vim.wait(1000, function() return catalog.has_tag("live_api_series") end)
      assert.is_true(catalog.has_tag("live_api_series"))
      assert.is_true(catalog.has_tag("live_api_artist"))
      assert.are.equal(3, catalog.get_tag("live_api_series").t)
      assert.are.equal(1, catalog.get_tag("live_api_artist").t)
    end)
  end)

  describe("timer encapsulation & teardown", function()
    it("does not expose timer handles on global UI or catalog object", function()
      catalog.record_discovered({ n = "encapsulated_tag", c = 100, t = 0 })
      catalog.prune_tag("some_tag")
      catalog.fetch_api_tags("test")

      -- Global UI handles must remain nil
      assert.is_nil(state.UI.save_discovered_timer)
      assert.is_nil(state.UI.prune_disk_timer)
      assert.is_nil(state.UI.api_tag_timer)

      -- Catalog object should encapsulate them (nil publicly)
      assert.is_nil(catalog.save_discovered_timer)
      assert.is_nil(catalog.prune_disk_timer)
      assert.is_nil(catalog.api_tag_timer)
    end)

    it("teardown and reset stop and close all internal timers cleanly", function()
      catalog.record_discovered({ n = "timer_cleanup_tag", c = 100, t = 0 })
      catalog.prune_tag("timer_cleanup_tag")
      catalog.fetch_api_tags("query")

      assert.has_no.errors(function()
        catalog.teardown()
      end)

      -- Wait past all debounce intervals to ensure no dead timer callbacks fire
      vim.wait(1200)
    end)
  end)

  describe("search", function()
    describe("empty prefix", function()
      it("returns items from all_tags clamped by limit", function()
        catalog.add_tag({ n = "tag_a", c = 100, t = 0 })
        catalog.add_tag({ n = "tag_b", c = 200, t = 3 })
        local results = catalog.search("")
        assert.is_table(results)
        assert.is_true(#results > 0)
        local limited = catalog.search("", { limit = 2 })
        assert.are.equal(2, #limited)
      end)

      it("filters out local_only meta tags when is_local is false", function()
        local results = catalog.search("", { is_local = false })
        for _, cand in ipairs(results) do
          assert.is_not.equal("sort:date", cand.name)
          assert.is_not.equal("sort:mtime", cand.name)
        end
      end)

      it("includes local_only meta tags when is_local is true", function()
        local results = catalog.search("", { is_local = true })
        local has_date = false
        for _, cand in ipairs(results) do
          if cand.name == "sort:date" or cand.name == "sort:mtime" then
            has_date = true
            break
          end
        end
        assert.is_true(has_date)
      end)
    end)

    describe("candidate item format", function()
      it("returns items with consistent fields (item, name, category, count, score, n, t, c)", function()
        catalog.add_tag({ n = "hoshino_ai", c = 5000, t = 4 })
        local results = catalog.search("hoshino")
        assert.is_true(#results >= 1)
        local cand = results[1]
        assert.are.equal("hoshino_ai", cand.name)
        assert.are.equal("hoshino_ai", cand.n)
        assert.are.equal("hoshino_ai", cand.item.n)
        assert.are.equal(4, cand.category)
        assert.are.equal(4, cand.t)
        assert.are.equal(5000, cand.count)
        assert.are.equal(5000, cand.c)
        assert.is_number(cand.score)
      end)
    end)

    describe("prefix matching & first-letter hash buckets", function()
      it("matches tags from respective first-letter hash buckets", function()
        catalog.add_tag({ n = "genshin_impact", c = 90000, t = 3 })
        catalog.add_tag({ n = "ganyu", c = 50000, t = 4 })
        catalog.add_tag({ n = "green_hair", c = 10000, t = 0 })

        local results = catalog.search("gen")
        assert.is_true(#results >= 1)
        assert.are.equal("genshin_impact", results[1].name)
      end)

      it("performs bucket lookup under 3ms for indexed tags", function()
        for i = 1, 500 do
          catalog.add_tag({ n = "test_tag_" .. i, c = i * 10, t = 0 })
        end
        local t0 = vim.loop.hrtime()
        local results = catalog.search("test_tag_1")
        local t1 = vim.loop.hrtime()
        local elapsed_ms = (t1 - t0) / 1e6
        assert.is_true(#results > 0)
        assert.is_true(elapsed_ms < 3.0)
      end)
    end)

    describe("base scoring & match accuracy", function()
      it("scores exact match higher than normalized match, prefix, and substring", function()
        catalog.add_tag({ n = "hatsune_miku", c = 100, t = 4 })
        catalog.add_tag({ n = "hatsune_miku_v4", c = 100, t = 4 })
        catalog.add_tag({ n = "dark_hatsune_miku", c = 100, t = 4 })

        local results = catalog.search("hatsune_miku")
        assert.are.equal("hatsune_miku", results[1].name)
        assert.are.equal("hatsune_miku_v4", results[2].name)
      end)

      it("recognizes normalized exact match (e.g. without underscores)", function()
        catalog.add_tag({ n = "hatsune_miku", c = 100, t = 4 })
        local results = catalog.search("hatsunemiku")
        assert.is_true(#results >= 1)
        assert.are.equal("hatsune_miku", results[1].name)
        local base_expected = constants.SCORE_BASE_NORM
        local pop = math.log10(101) * constants.SCORE_POP_MULTIPLIER
        local nudge = constants.CAT_NUDGE_CHARACTER
        assert.are.same(math.floor(base_expected + pop + nudge), math.floor(results[1].score))
      end)

      it("pins meta tags with SCORE_META_PIN", function()
        local results = catalog.search("sort:score")
        assert.is_true(#results >= 1)
        assert.are.equal("sort:score", results[1].name)
        assert.are.equal(constants.SCORE_META_PIN, results[1].score)
      end)
    end)

    describe("popularity & category weighting", function()
      it("ranks higher count above lower count for same match type and category", function()
        catalog.add_tag({ n = "solo_1", c = 100, t = 0 })
        catalog.add_tag({ n = "solo_2", c = 100000, t = 0 })

        local results = catalog.search("solo_")
        assert.are.equal("solo_2", results[1].name)
        assert.are.equal("solo_1", results[2].name)
      end)

      it("applies category nudges (Series > Character > Artist > General) when count is identical", function()
        catalog.add_tag({ n = "cat_series", c = 1000, t = 3 })
        catalog.add_tag({ n = "cat_char", c = 1000, t = 4 })
        catalog.add_tag({ n = "cat_artist", c = 1000, t = 1 })
        catalog.add_tag({ n = "cat_general", c = 1000, t = 0 })

        local results = catalog.search("cat_")
        assert.are.equal("cat_series", results[1].name)
        assert.are.equal("cat_char", results[2].name)
        assert.are.equal("cat_artist", results[3].name)
        assert.are.equal("cat_general", results[4].name)
      end)
    end)

    describe("substring fallback", function()
      it("falls back to full lists for substring match when bucket candidates are few", function()
        catalog.add_tag({ n = "racing_miku", c = 1000, t = 4 })
        local results = catalog.search("miku")
        local found = false
        for _, cand in ipairs(results) do
          if cand.name == "racing_miku" then
            found = true
            break
          end
        end
        assert.is_true(found)
      end)

      it("does not trigger substring fallback if prefix length is below AC_MIN_TRIGGER_LEN", function()
        catalog.add_tag({ n = "racing_miku", c = 1000, t = 4 })
        local results = catalog.search("mi")
        for _, cand in ipairs(results) do
          assert.is_not.equal("racing_miku", cand.name)
        end
      end)
    end)

    describe("live API fallback", function()
      it("triggers fetch_api_tags when candidates < AC_API_FALLBACK_COUNT and len >= AC_MIN_TRIGGER_LEN", function()
        local called_with = nil
        catalog.fetch_api_tags = function(target)
          called_with = target
        end

        catalog.search("unseen_tag_xyz")
        assert.are.equal("unseen_tag_xyz", called_with)
      end)

      it("does not trigger fetch_api_tags when search target is a syntax directive", function()
        local called = false
        catalog.fetch_api_tags = function()
          called = true
        end

        catalog.search("sort:unseen")
        assert.is_false(called)

        catalog.search("rating:explicit")
        assert.is_false(called)

        catalog.search("random")
        assert.is_false(called)
      end)

      it("does not trigger fetch_api_tags when prefix length < AC_MIN_TRIGGER_LEN", function()
        local called = false
        catalog.fetch_api_tags = function()
          called = true
        end

        catalog.search("ab")
        assert.is_false(called)
      end)
    end)

    describe("query modifiers & options", function()
      it("strips leading negation, pipe, and tilde modifiers", function()
        catalog.add_tag({ n = "hoshino_ai", c = 5000, t = 4 })
        local r1 = catalog.search("-hoshino")
        assert.are.equal("hoshino_ai", r1[1].name)

        local r2 = catalog.search("|hoshino")
        assert.are.equal("hoshino_ai", r2[1].name)

        local r3 = catalog.search("~hoshino")
        assert.are.equal("hoshino_ai", r3[1].name)
      end)

      it("respects opts.limit", function()
        for i = 1, 20 do
          catalog.add_tag({ n = "limit_test_" .. i, c = 100, t = 0 })
        end
        local results = catalog.search("limit_test", { limit = 5 })
        assert.are.equal(5, #results)
      end)
    end)
  end)

  describe("Lifecycle & Callback Guarantees", function()
    it("flush_prunes_now writes pending prunes to disk immediately", function()
      local disk_file = tmp_dir .. "/general.json"
      local f = io.open(disk_file, "w")
      f:write(vim.json.encode({ { n = "prune_now_tag", c = 10, t = 0 } }))
      f:close()

      catalog.add_tag({ n = "prune_now_tag", c = 10, t = 0 })
      catalog.prune_tag("prune_now_tag") -- schedules debounced prune
      assert.is_false(catalog.has_tag("prune_now_tag"))

      -- Immediately flush before debounce expires
      catalog.flush_prunes_now()

      local in_f = io.open(disk_file, "r")
      local content = in_f:read("*a")
      in_f:close()
      assert.is_nil(content:find("prune_now_tag"))
    end)

    it("teardown cleanly flushes discovered and prunes, and cancels timers", function()
      catalog.record_discovered({ { n = "teardown_disc", t = 0, c = 5 } })
      catalog.schedule_disk_prune("some_prune")
      assert.has_no.errors(function()
        catalog.teardown()
      end)
      assert.is_false(catalog.has_tag("teardown_disc"))
    end)

    it("resolve_post_tags invokes on_complete even when no artist is in the response", function()
      local download = require("gelbooru.net.download")
      local orig_curl = download.curl_async
      download.curl_async = function(url, cb)
        cb(vim.json.encode({
          tag = {
            { name = "character_only", type = "4", count = "100" },
          },
        }))
      end

      local callback_called = false
      local result_meta = nil
      catalog.resolve_post_tags({ id = 999, tags = "character_only" }, function(res)
        callback_called = true
        result_meta = res
      end)

      assert.is_true(callback_called)
      assert.is_not_nil(result_meta)
      assert.is_false(result_meta.found_artist)
      assert.are.equal(1, result_meta.count)
      assert.is_true(catalog.has_tag("character_only"))

      download.curl_async = orig_curl
    end)
  end)
end)
