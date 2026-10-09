-- tests/unit/util_spec.lua
-- Unit tests for gelbooru.core.util (pure functions only — no vim API needed).

local util = require("gelbooru.core.util")
local config = require("gelbooru.core.config")

describe("util.url_encode", function()
  it("encodes spaces as +", function()
    assert.are.equal("hello+world", util.url_encode("hello world"))
  end)

  it("encodes special characters", function()
    local enc = util.url_encode("a&b=c")
    assert.is_falsy(enc:find("&"))
    assert.is_falsy(enc:find("="))
  end)

  it("leaves alphanumerics untouched", function()
    assert.are.equal("abc123", util.url_encode("abc123"))
  end)

  it("encodes colons", function()
    -- sort:score is a common gelbooru tag modifier
    local enc = util.url_encode("sort:score")
    assert.are.equal("sort%3Ascore", enc)
  end)

  it("handles empty string", function()
    assert.are.equal("", util.url_encode(""))
  end)

  it("handles nil gracefully", function()
    assert.are.equal("", util.url_encode(nil))
  end)

  it("encodes literal + as %2B", function()
    assert.are.equal("c%2B%2B", util.url_encode("c++"))
  end)

  it("encodes literal + alongside spaces", function()
    assert.are.equal("c%2B%2B+tag", util.url_encode("c++ tag"))
  end)
end)

describe("util.ensure_array", function()
  it("wraps dictionary table in an array", function()
    assert.are.same({ { id = 1 } }, util.ensure_array({ id = 1 }))
  end)

  it("leaves array table unchanged", function()
    assert.are.same({ 1, 2 }, util.ensure_array({ 1, 2 }))
  end)

  it("returns empty table for empty table", function()
    assert.are.same({}, util.ensure_array({}))
  end)

  it("returns empty table for nil", function()
    assert.are.same({}, util.ensure_array(nil))
  end)

  it("returns empty table for non-table values", function()
    assert.are.same({}, util.ensure_array("string"))
    assert.are.same({}, util.ensure_array(123))
    assert.are.same({}, util.ensure_array(true))
  end)
end)

describe("util.normalize_str", function()
  it("strips non-word characters", function()
    assert.are.equal("helloworld", util.normalize_str("hello_world"))
  end)

  it("lowercases result", function()
    assert.are.equal("abc", util.normalize_str("ABC"))
  end)

  it("handles nil", function()
    assert.are.equal("", util.normalize_str(nil))
  end)
end)

describe("util.decode_html", function()
  it("decodes &gt; and &lt;", function()
    assert.are.equal("<b>", util.decode_html("&lt;b&gt;"))
  end)

  it("decodes &amp;", function()
    assert.are.equal("a&b", util.decode_html("a&amp;b"))
  end)

  it("decodes &quot;", function()
    assert.are.equal('"', util.decode_html("&quot;"))
  end)

  it("decodes &#039; and &#39;", function()
    assert.are.equal("'", util.decode_html("&#039;"))
    assert.are.equal("'", util.decode_html("&#39;"))
  end)

  it("returns empty string for nil", function()
    assert.are.equal("", util.decode_html(nil))
  end)

  it("leaves plain text unchanged", function()
    assert.are.equal("hello", util.decode_html("hello"))
  end)
end)

describe("util.fuzzy", function()
  it("matches subsequences", function()
    assert.is_true(util.fuzzy("zenless_zone_zero", "zzz"))
  end)

  it("is case-insensitive", function()
    assert.is_true(util.fuzzy("ZenlessZoneZero", "zzz"))
  end)

  it("empty query always matches", function()
    assert.is_true(util.fuzzy("anything", ""))
  end)

  it("returns false for non-matching subsequence", function()
    assert.is_false(util.fuzzy("abc", "xyz"))
  end)

  it("exact match succeeds", function()
    assert.is_true(util.fuzzy("tag", "tag"))
  end)
end)

describe("util.meta_cache_path", function()
  local config = require("gelbooru.core.config")

  it("returns cache file path formatted with post id", function()
    local path = util.meta_cache_path(12345)
    assert.are.equal(config.options.cache_dir .. "/meta_12345.json", path)
  end)

  it("handles string id", function()
    local path = util.meta_cache_path("9999")
    assert.are.equal(config.options.cache_dir .. "/meta_9999.json", path)
  end)

  it("returns nil for nil, empty, or 'nil' id", function()
    assert.is_nil(util.meta_cache_path(nil))
    assert.is_nil(util.meta_cache_path(""))
    assert.is_nil(util.meta_cache_path("nil"))
  end)
end)

describe("util.read_json and util.write_json", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("writes and reads json table correctly", function()
    local path = tmp_dir .. "/test.json"
    local data = { id = 42, tags = "tag1 tag2", count = 100 }
    local write_ok = util.write_json(path, data)
    assert.is_true(write_ok)
    assert.are.equal(1, vim.fn.filereadable(path))

    local read_data = util.read_json(path)
    assert.is_not_nil(read_data)
    assert.are.equal(42, read_data.id)
    assert.are.equal("tag1 tag2", read_data.tags)
    assert.are.equal(100, read_data.count)
  end)

  it("read_json returns nil for non-existent file, empty file, or corrupted json", function()
    assert.is_nil(util.read_json(tmp_dir .. "/nonexistent.json"))

    -- Empty file (0 bytes)
    local empty_path = tmp_dir .. "/empty.json"
    vim.fn.writefile({}, empty_path)
    assert.is_nil(util.read_json(empty_path))

    -- Truncated / partial JSON
    local partial_path = tmp_dir .. "/partial.json"
    vim.fn.writefile({ '{"id": 1234, "tags": "partial_tag', '"rating": "gen' }, partial_path)
    assert.is_nil(util.read_json(partial_path))

    -- JSON scalar / non-table types
    local scalar_path = tmp_dir .. "/scalar.json"
    vim.fn.writefile({ '"just a string"' }, scalar_path)
    assert.is_nil(util.read_json(scalar_path))

    local num_path = tmp_dir .. "/num.json"
    vim.fn.writefile({ "999" }, num_path)
    assert.is_nil(util.read_json(num_path))

    -- Raw corrupted garbage bytes
    local bad_path = tmp_dir .. "/corrupt.json"
    vim.fn.writefile({ "not a valid json" }, bad_path)
    assert.is_nil(util.read_json(bad_path))
  end)

  it("write_json writes atomically via .tmp and renames to target path", function()
    local path = tmp_dir .. "/atomic_test.json"
    local orig_rename = vim.fn.rename
    local rename_src, rename_dest

    vim.fn.rename = function(src, dest)
      rename_src = src
      rename_dest = dest
      return orig_rename(src, dest)
    end

    local ok = util.write_json(path, { test = "atomic", value = 123 })
    assert.is_true(ok)
    assert.are.equal(path .. ".tmp", rename_src)
    assert.are.equal(path, rename_dest)
    assert.are.equal(0, vim.fn.filereadable(path .. ".tmp"))
    assert.are.equal(1, vim.fn.filereadable(path))

    local read = util.read_json(path)
    assert.is_not_nil(read)
    assert.are.equal("atomic", read.test)

    vim.fn.rename = orig_rename
  end)

  it("write_json automatically creates nested parent directory if it does not exist", function()
    local nested_path = tmp_dir .. "/nested/sub/folder/cache.json"
    local ok = util.write_json(nested_path, { nested = true })
    assert.is_true(ok)
    assert.are.equal(1, vim.fn.filereadable(nested_path))
    local data = util.read_json(nested_path)
    assert.is_not_nil(data)
    assert.is_true(data.nested)
  end)

  it("write_json returns false if rename fails or data is invalid", function()
    assert.is_false(util.write_json(nil, { a = 1 }))
    assert.is_false(util.write_json(tmp_dir .. "/test.json", nil))

    -- Non-serializable data (functions)
    local invalid_data = { bad = function() end }
    assert.is_false(util.write_json(tmp_dir .. "/invalid.json", invalid_data))

    -- Simulated rename failure
    local orig_rename = vim.fn.rename
    vim.fn.rename = function(_, _)
      return -1
    end
    assert.is_false(util.write_json(tmp_dir .. "/rename_fail.json", { ok = true }))
    vim.fn.rename = orig_rename
  end)
end)

describe("util.open_url and util.open_media", function()
  it("open_url returns false for nil or empty url", function()
    assert.is_false(util.open_url(nil))
    assert.is_false(util.open_url(""))
  end)

  it("open_url calls vim.ui.open when available", function()
    local opened = nil
    local orig_open = vim.ui and vim.ui.open
    vim.ui.open = function(url)
      opened = url
    end

    local ok = util.open_url("https://gelbooru.com/post/1")
    assert.is_true(ok)
    assert.are.equal("https://gelbooru.com/post/1", opened)

    vim.ui.open = orig_open
  end)

  it("open_media returns false for nil or empty target", function()
    assert.is_false(util.open_media(nil))
    assert.is_false(util.open_media(""))
  end)

  it("open_media invokes system opener for images", function()
    local opened = nil
    local orig_open = vim.ui and vim.ui.open
    vim.ui.open = function(target)
      opened = target
    end

    local ok = util.open_media("/tmp/image.png")
    assert.is_true(ok)
    assert.are.equal("/tmp/image.png", opened)

    vim.ui.open = orig_open
  end)

  it("open_media launches media_player when configured", function()
    local orig_player = config.options.media_player
    local orig_jobstart = vim.fn.jobstart
    local job_cmd, job_opts

    config.options.media_player = "iina"
    vim.fn.jobstart = function(cmd, opts)
      job_cmd = cmd
      job_opts = opts
      return 100
    end

    local ok_mp4 = util.open_media("/storage/video/test_clip.mp4")
    assert.is_true(ok_mp4)
    assert.are.same({ "iina", "/storage/video/test_clip.mp4" }, job_cmd)
    assert.is_true(job_opts.detach)

    config.options.media_player = orig_player
    vim.fn.jobstart = orig_jobstart
  end)

  it("open_media defaults to open_url when media_player is not configured", function()
    local orig_player = config.options.media_player
    local orig_open = vim.ui and vim.ui.open
    local opened = nil

    config.options.media_player = nil
    vim.ui.open = function(target)
      opened = target
    end

    local ok = util.open_media("/storage/video/fallback.mp4")
    assert.is_true(ok)
    assert.are.equal("/storage/video/fallback.mp4", opened)

    config.options.media_player = orig_player
    vim.ui.open = orig_open
  end)
end)
