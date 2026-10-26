-- tests/unit/db_spec.lua
-- Unit tests for gelbooru.tags.catalog — tag validation and indexing.

local db = require("gelbooru.tags.catalog")
local state = require("gelbooru.core.state")

describe("db.is_clean_tag", function()
  it("accepts a normal tag", function()
    assert.is_true(db.is_clean_tag("hoshino_ai", 5000, 4))
  end)

  it("rejects tags shorter than 2 characters", function()
    assert.is_false(db.is_clean_tag("a", 100, 0))
  end)

  it("rejects nil name", function()
    assert.is_false(db.is_clean_tag(nil, 100, 0))
  end)

  it("rejects count < 1 for non-meta tags", function()
    assert.is_false(db.is_clean_tag("some_tag", 0, 0))
  end)

  it("accepts meta tags (type 5) regardless of count", function()
    assert.is_true(db.is_clean_tag("sort:score", 0, 5))
  end)

  it("rejects tags starting with a separator character", function()
    assert.is_false(db.is_clean_tag("-leading_dash", 100, 0))
    assert.is_false(db.is_clean_tag("_leading_underscore", 100, 0))
  end)

  it("rejects tags containing commas or semicolons", function()
    assert.is_false(db.is_clean_tag("a,b", 100, 0))
    assert.is_false(db.is_clean_tag("a;b", 100, 0))
  end)

  it("rejects URL-like tags", function()
    assert.is_false(db.is_clean_tag("https://example.com", 100, 0))
  end)

  it("rejects tags with double separators", function()
    assert.is_false(db.is_clean_tag("a__b", 100, 0))
    assert.is_false(db.is_clean_tag("a--b", 100, 0))
  end)

  it("rejects very long tags without parens", function()
    local long = ("a"):rep(46)
    assert.is_false(db.is_clean_tag(long, 100, 0))
  end)

  it("accepts long tags that contain parentheses (disambiguation)", function()
    local long = ("a"):rep(46) .. "_(character)"
    assert.is_true(db.is_clean_tag(long, 100, 0))
  end)
end)

describe("db.add_tag_to_index", function()
  local target_list
  local bucket_map

  before_each(function()
    target_list = {}
    bucket_map = {}
    db.reset()
  end)

  it("adds a valid tag to target_list", function()
    local t = { n = "hoshino_ai", c = 5000, t = 4 }
    db.add_tag_to_index(t, target_list, bucket_map)
    assert.are.equal(1, #target_list)
  end)

  it("stamps n_lower on the tag object", function()
    local t = { n = "Hoshino_Ai", c = 5000, t = 4 }
    db.add_tag_to_index(t, target_list, bucket_map)
    assert.are.equal("hoshino_ai", target_list[1].n_lower)
  end)

  it("registers tag in tags_by_name", function()
    local t = { n = "hoshino_ai", c = 5000, t = 4 }
    db.add_tag_to_index(t, target_list, bucket_map)
    assert.is_true(db.has_tag("hoshino_ai"))
  end)

  it("buckets the tag by first letter", function()
    local t = { n = "hoshino_ai", c = 5000, t = 4 }
    db.add_tag_to_index(t, target_list, bucket_map)
    assert.is_not_nil(bucket_map["h"])
    assert.are.equal(1, #bucket_map["h"])
  end)

  it("skips invalid tags silently", function()
    db.add_tag_to_index({ n = "a", c = 0, t = 0 }, target_list, bucket_map)
    assert.are.equal(0, #target_list)
  end)

  it("works with nil target_list (tags_by_name only)", function()
    local t = { n = "hoshino_ai", c = 5000, t = 4 }
    assert.has_no.errors(function()
      db.add_tag_to_index(t, nil, nil)
    end)
    assert.is_true(db.has_tag("hoshino_ai"))
  end)

  it("handles nil or invalid tag table inputs safely without throwing", function()
    assert.has_no.errors(function()
      db.add_tag_to_index(nil, target_list, bucket_map)
      db.add_tag_to_index({}, target_list, bucket_map)
      db.add_tag_to_index({ n = 123 }, target_list, bucket_map)
    end)
    assert.are.equal(0, #target_list)
  end)
end)

describe("db.is_clean_tag edge cases", function()
  it("rejects tags ending with separators or punctuation", function()
    assert.is_false(db.is_clean_tag("tag_", 100, 0))
    assert.is_false(db.is_clean_tag("tag-", 100, 0))
    assert.is_false(db.is_clean_tag("tag.", 100, 0))
    assert.is_false(db.is_clean_tag("tag?", 100, 0))
    assert.is_false(db.is_clean_tag("tag!", 100, 0))
  end)

  it("rejects tags with HTML entities", function()
    assert.is_false(db.is_clean_tag("cat&amp;dog", 100, 0))
    assert.is_false(db.is_clean_tag("&gt;tag", 100, 0))
  end)

  it("rejects non-string names", function()
    assert.is_false(db.is_clean_tag(12345, 100, 0))
    assert.is_false(db.is_clean_tag({}, 100, 0))
    assert.is_false(db.is_clean_tag(true, 100, 0))
  end)
end)

describe("db.parse_tag_file", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    db.reset()
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("returns false for non-existent file", function()
    local ok = db.parse_tag_file(tmp_dir .. "/missing.json", {}, {}, 100)
    assert.is_false(ok)
  end)

  it("returns false for corrupt JSON file", function()
    local corrupt_path = tmp_dir .. "/corrupt.json"
    vim.fn.writefile({ "{ not valid json" }, corrupt_path)
    local ok = db.parse_tag_file(corrupt_path, {}, {}, 100)
    assert.is_false(ok)
  end)

  it("parses valid JSON tag list and populates target list and bucket map up to cap", function()
    local file_path = tmp_dir .. "/sample_series.json"
    local sample_tags = {
      { n = "series_one", c = 1000, t = 3 },
      { n = "series_two", c = 800, t = 3 },
      { n = "series_three", c = 600, t = 3 },
    }
    vim.fn.writefile({ vim.fn.json_encode(sample_tags) }, file_path)

    local target_list = {}
    local bucket_map = {}
    local ok = db.parse_tag_file(file_path, target_list, bucket_map, 2)

    assert.is_true(ok)
    assert.are.equal(2, #target_list)
    assert.are.equal("series_one", target_list[1].n)
    assert.are.equal("series_two", target_list[2].n)
    assert.is_not_nil(bucket_map["s"])
    assert.are.equal(2, #bucket_map["s"])
    assert.is_true(db.has_tag("series_one"))
  end)
end)

describe("catalog.load", function()
  local tmp_dir
  local config = require("gelbooru.core.config")
  local orig_tags_dir

  before_each(function()
    orig_tags_dir = config.options.tags_dir
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    config.options.tags_dir = tmp_dir
    db.reset()
  end)

  after_each(function()
    config.options.tags_dir = orig_tags_dir
    vim.fn.delete(tmp_dir, "rf")
    db.reset()
  end)

  it("loads META_TAGS and marks is_loaded() == true when no category files exist", function()
    local done = false
    db.load({ tags_dir = tmp_dir }, function()
      done = true
    end)
    assert.is_true(db.is_loaded())
    assert.is_false(db.is_loading())
    assert.is_true(db.has_tag("sort:score"))
    assert.is_true(db.has_tag("rating:general"))
  end)

  it("loads discovered.json synchronously if present in tags_dir", function()
    local disc_file = config.get_discovered_tags_file()
    local disc_tags = {
      { n = "custom_artist_tag", c = 50, t = 1 },
      { n = "custom_char_tag", c = 150, t = 4 },
    }
    vim.fn.writefile({ vim.fn.json_encode(disc_tags) }, disc_file)

    -- Create split files so has_split is true
    vim.fn.writefile({ "[]" }, tmp_dir .. "/general.json")

    local done = false
    db.load({ tags_dir = tmp_dir, discovered_file = disc_file }, function()
      done = true
    end)

    assert.is_true(db.has_tag("custom_artist_tag"))
    assert.is_true(db.has_tag("custom_char_tag"))
  end)
end)

describe("db.remove_from_list and db.remove_from_bucket", function()
  it("removes an existing tag from list by lower name", function()
    local list = {
      { n = "Tag_A", n_lower = "tag_a", c = 100, t = 0 },
      { n = "Tag_B", n_lower = "tag_b", c = 200, t = 0 },
    }
    local removed = db.remove_from_list(list, "tag_a")
    assert.is_true(removed)
    assert.are.equal(1, #list)
    assert.are.equal("tag_b", list[1].n_lower)
  end)

  it("returns false if tag is not in list", function()
    local list = { { n = "Tag_A", n_lower = "tag_a" } }
    local removed = db.remove_from_list(list, "tag_z")
    assert.is_false(removed)
    assert.are.equal(1, #list)
  end)

  it("removes a tag from bucket map", function()
    local bucket_map = {
      ["t"] = {
        { n = "tag_one", n_lower = "tag_one" },
        { n = "tag_two", n_lower = "tag_two" },
      },
    }
    local removed = db.remove_from_bucket(bucket_map, "tag_one")
    assert.is_true(removed)
    assert.are.equal(1, #bucket_map["t"])
    assert.are.equal("tag_two", bucket_map["t"][1].n_lower)
  end)

  it("handles nil bucket or list safely", function()
    assert.is_false(db.remove_from_list(nil, "abc"))
    assert.is_false(db.remove_from_bucket(nil, "abc"))
    assert.is_false(db.remove_from_bucket({}, "abc"))
  end)
end)

describe("db.prune_tag", function()
  before_each(function()
    db.reset()
    db.add_tag({ n = "dead_tag", c = 100, t = 0 })
    db.add_tag({ n = "live_tag", c = 500, t = 0 })
  end)

  it("prunes tag from memory across all tables", function()
    local existed = db.prune_tag("dead_tag")
    assert.is_true(existed)
    assert.is_false(db.has_tag("dead_tag"))
    assert.is_true(db.has_tag("live_tag"))
  end)

  it("returns false for non-existent tag", function()
    local existed = db.prune_tag("non_existent_tag")
    assert.is_false(existed)
  end)
end)

describe("db.update_tag_in_index", function()
  before_each(function()
    db.reset()
  end)

  it("updates tag count in place", function()
    db.add_tag({ n = "rem", c = 5000, t = 4 })
    assert.are.equal(5000, db.get_tag("rem").c)

    local ok = db.update_tag_in_index({ n = "rem", c = 7500, t = 4 })
    assert.is_true(ok)
    assert.are.equal(7500, db.get_tag("rem").c)
  end)

  it("reclassifies tag type and moves across category lists and buckets", function()
    db.add_tag({ n = "re_zero", c = 1000, t = 0 })
    assert.are.equal(0, db.get_tag("re_zero").t)

    local ok = db.update_tag_in_index({ n = "re_zero", c = 1200, t = 3 })
    assert.is_true(ok)
    assert.are.equal(3, db.get_tag("re_zero").t)
    assert.are.equal(1200, db.get_tag("re_zero").c)
  end)

  it("prunes tag if updated count becomes 0 or invalid", function()
    db.add_tag({ n = "dead_soon", c = 100, t = 0 })
    assert.is_true(db.has_tag("dead_soon"))

    local ok = db.update_tag_in_index({ n = "dead_soon", c = 0, t = 0 })
    assert.is_false(ok)
    assert.is_false(db.has_tag("dead_soon"))
  end)

  it("adds new clean tag if not previously in index", function()
    local ok = db.update_tag_in_index({ n = "brand_new_series", c = 300, t = 3 })
    assert.is_true(ok)
    assert.is_true(db.has_tag("brand_new_series"))
    assert.are.equal(3, db.get_tag("brand_new_series").t)
  end)
end)

describe("db.prune_tags_from_disk", function()
  local tmp_dir
  local config = require("gelbooru.core.config")
  local orig_tags_dir

  before_each(function()
    orig_tags_dir = config.options.tags_dir
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    config.options.tags_dir = tmp_dir
  end)

  after_each(function()
    config.options.tags_dir = orig_tags_dir
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("prunes dead tags from JSON files on disk while retaining live tags", function()
    local series_path = tmp_dir .. "/series.json"
    local data = {
      { n = "alive_series", c = 1000, t = 3 },
      { n = "dead_series", c = 0, t = 3 },
    }
    local f = io.open(series_path, "w")
    f:write(vim.fn.json_encode(data))
    f:close()

    db.prune_tags_from_disk({ ["dead_series"] = true })

    local f2 = io.open(series_path, "r")
    local raw = f2:read("*a")
    f2:close()
    local parsed = vim.fn.json_decode(raw)

    assert.are.equal(1, #parsed)
    assert.are.equal("alive_series", parsed[1].n)
  end)
end)

describe("db.verify_and_prune_tag", function()
  local download = require("gelbooru.net.download")
  local orig_curl_async

  before_each(function()
    orig_curl_async = download.curl_async
    db.reset()
    db.add_tag({ n = "dying_tag", c = 50, t = 0 })
    db.add_tag({ n = "surviving_tag", c = 50, t = 0 })
  end)

  after_each(function()
    download.curl_async = orig_curl_async
  end)

  it("prunes tag from memory when API returns count == 0", function()
    download.curl_async = function(url, cb)
      vim.schedule(function()
        cb(vim.fn.json_encode({ tag = { { name = "dying_tag", count = "0", type = "0" } } }))
      end)
    end

    local done = false
    local pruned_res = nil
    db.verify_and_prune_tag("dying_tag", function(pruned)
      pruned_res = pruned
      done = true
    end)

    vim.wait(1000, function() return done end)
    assert.is_true(done)
    assert.is_true(pruned_res)
    assert.is_false(db.has_tag("dying_tag"))
    assert.is_true(db.has_tag("surviving_tag"))
  end)

  it("retains tag when API returns active count", function()
    download.curl_async = function(url, cb)
      vim.schedule(function()
        cb(vim.fn.json_encode({ tag = { { name = "surviving_tag", count = "150", type = "0" } } }))
      end)
    end

    local done = false
    local pruned_res = nil
    db.verify_and_prune_tag("surviving_tag", function(pruned)
      pruned_res = pruned
      done = true
    end)

    vim.wait(1000, function() return done end)
    assert.is_true(done)
    assert.is_false(pruned_res)
    assert.is_true(db.has_tag("surviving_tag"))
    assert.are.equal(150, db.get_tag("surviving_tag").c)
  end)
end)

describe("api.check_self_heal", function()
  local api = require("gelbooru.net.api")
  local download = require("gelbooru.net.download")
  local orig_curl_async

  before_each(function()
    orig_curl_async = download.curl_async
    db.reset()
    db.add_tag({ n = "phantom_tag", c = 10, t = 0 })
  end)

  after_each(function()
    download.curl_async = orig_curl_async
  end)

  it("triggers self-healing on single-tag search and prunes dead tag", function()
    download.curl_async = function(url, cb)
      vim.schedule(function()
        cb(vim.fn.json_encode({ tag = {} }))
      end)
    end

    local done = false
    local pruned_res = nil
    api.check_self_heal("phantom_tag", function(pruned)
      pruned_res = pruned
      done = true
    end)

    vim.wait(1000, function() return done end)
    assert.is_true(done)
    assert.is_true(pruned_res)
    assert.is_false(db.has_tag("phantom_tag"))
  end)

  it("ignores multi-tag search without network calls", function()
    local called = false
    download.curl_async = function(url, cb)
      called = true
    end

    api.check_self_heal("tag1 tag2", function(pruned) end)
    assert.is_false(called)
  end)

  it("ignores modifier searches (rating:, sort:, score:)", function()
    local called = false
    download.curl_async = function(url, cb)
      called = true
    end

    api.check_self_heal("rating:general", function(pruned) end)
    api.check_self_heal("sort:score", function(pruned) end)
    api.check_self_heal("-tag", function(pruned) end)
    assert.is_false(called)
  end)
end)

describe("fetcher.verify_tags", function()
  local fetcher = require("gelbooru.tags.fetcher")
  local download = require("gelbooru.net.download")
  local config = require("gelbooru.core.config")
  local orig_curl_async
  local orig_tags_dir
  local tmp_dir

  before_each(function()
    orig_curl_async = download.curl_async
    orig_tags_dir = config.options.tags_dir
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    config.options.tags_dir = tmp_dir
    state.reset_tag_state()
  end)

  after_each(function()
    download.curl_async = orig_curl_async
    config.options.tags_dir = orig_tags_dir
    vim.fn.delete(tmp_dir, "rf")
    state.reset_tag_state()
  end)

  it("verifies batch of tags, purges dead ones, and reclassifies types", function()
    local initial_general = {
      { n = "active_tag", c = 100, t = 0 },
      { n = "dead_tag", c = 50, t = 0 },
      { n = "turned_series", c = 80, t = 0 },
    }
    local f = io.open(tmp_dir .. "/general.json", "w")
    f:write(vim.fn.json_encode(initial_general))
    f:close()

    download.curl_async = function(url, cb)
      vim.schedule(function()
        local payload = {
          tag = {
            { name = "active_tag", count = "120", type = "0" },
            { name = "turned_series", count = "300", type = "3" },
          },
        }
        cb(vim.fn.json_encode(payload))
      end)
    end

    local done = false
    local result = nil
    fetcher.verify_tags({
      batch_size = 50,
      concurrency = 2,
      on_complete = function(res)
        result = res
        done = true
      end,
    })

    vim.wait(2000, function() return done end)
    assert.is_true(done)
    assert.are.equal(3, result.total)
    assert.are.equal(1, result.purged)

    local f_gen = io.open(tmp_dir .. "/general.json", "r")
    local gen_tags = vim.fn.json_decode(f_gen:read("*a"))
    f_gen:close()
    assert.are.equal(1, #gen_tags)
    assert.are.equal("active_tag", gen_tags[1].n)
    assert.are.equal(120, gen_tags[1].c)

    local f_ser = io.open(tmp_dir .. "/series.json", "r")
    local ser_tags = vim.fn.json_decode(f_ser:read("*a"))
    f_ser:close()
    assert.are.equal(1, #ser_tags)
    assert.are.equal("turned_series", ser_tags[1].n)
    assert.are.equal(3, ser_tags[1].t)
  end)
end)

describe("fetcher.refresh_tags", function()
  local fetcher = require("gelbooru.tags.fetcher")
  local download = require("gelbooru.net.download")
  local config = require("gelbooru.core.config")
  local orig_curl_async
  local orig_tags_dir
  local tmp_dir

  before_each(function()
    orig_curl_async = download.curl_async
    orig_tags_dir = config.options.tags_dir
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    config.options.tags_dir = tmp_dir
    state.reset_tag_state()
  end)

  after_each(function()
    download.curl_async = orig_curl_async
    config.options.tags_dir = orig_tags_dir
    vim.fn.delete(tmp_dir, "rf")
    state.reset_tag_state()
  end)

  it("updates top tags in-place and adds newly seen tags", function()
    local initial_chars = {
      { n = "miku", c = 10000, t = 4 },
    }
    local f = io.open(tmp_dir .. "/characters.json", "w")
    f:write(vim.fn.json_encode(initial_chars))
    f:close()

    download.curl_async = function(url, cb)
      vim.schedule(function()
        local payload = {
          tag = {
            { name = "miku", count = "12000", type = "4" },
            { name = "luka", count = "6000", type = "4" },
          },
        }
        cb(vim.fn.json_encode(payload))
      end)
    end

    local done = false
    local result = nil
    fetcher.refresh_tags({
      max_tags = 2,
      concurrency = 1,
      on_complete = function(res)
        result = res
        done = true
      end,
    })

    vim.wait(2000, function() return done end)
    assert.is_true(done)
    assert.are.equal(2, result.total)
    assert.are.equal(1, result.updated)
    assert.are.equal(1, result.new_tags)

    local f_chars = io.open(tmp_dir .. "/characters.json", "r")
    local chars_tags = vim.fn.json_decode(f_chars:read("*a"))
    f_chars:close()
    assert.are.equal(2, #chars_tags)
    assert.are.equal("miku", chars_tags[1].n)
    assert.are.equal(12000, chars_tags[1].c)
    assert.are.equal("luka", chars_tags[2].n)
    assert.are.equal(6000, chars_tags[2].c)
  end)
end)
