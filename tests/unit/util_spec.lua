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

describe("util.close_timer", function()
  it("stops and closes an active uv timer", function()
    local uv = vim.uv or vim.loop
    local timer = uv.new_timer()
    timer:start(1000, 0, function() end)
    assert.is_true(timer:is_active())

    local res = util.close_timer(timer)
    assert.is_nil(res)
    assert.is_true(timer:is_closing())
  end)

  it("handles nil gracefully without error", function()
    local res = util.close_timer(nil)
    assert.is_nil(res)
  end)

  it("handles already-closed timer without crashing", function()
    local uv = vim.uv or vim.loop
    local timer = uv.new_timer()
    timer:close()
    local res = util.close_timer(timer)
    assert.is_nil(res)
  end)
end)

describe("util.file_ext", function()
  it("extracts extension from simple filename", function()
    assert.are.equal("png", util.file_ext("image.png"))
    assert.are.equal("jpg", util.file_ext("photo.jpg"))
  end)

  it("extracts extension from path", function()
    assert.are.equal("jpeg", util.file_ext("/path/to/archive/file.jpeg"))
    assert.are.equal("webp", util.file_ext("C:\\Users\\Media\\image.webp"))
  end)

  it("strips query params and fragments before extracting extension", function()
    assert.are.equal("png", util.file_ext("https://example.com/cdn/sample.png?width=800&key=val#preview"))
  end)

  it("does not treat directory dots as file extensions when filename has no extension", function()
    assert.are.equal("", util.file_ext("https://example.com/img/noext"))
    assert.are.equal("", util.file_ext("/var/data.d/file_without_ext"))
  end)

  it("lowercases extension", function()
    assert.are.equal("gif", util.file_ext("ANIMATION.GIF"))
  end)

  it("returns empty string for nil or non-string", function()
    assert.are.equal("", util.file_ext(nil))
    assert.are.equal("", util.file_ext(123))
  end)
end)

describe("util.is_same_post", function()
  it("returns true for identical table reference", function()
    local p = { id = "1", file_url = "/a.jpg" }
    assert.is_true(util.is_same_post(p, p))
  end)

  it("returns false if either post is nil", function()
    assert.is_false(util.is_same_post({ id = "1" }, nil))
    assert.is_false(util.is_same_post(nil, { id = "1" }))
  end)

  it("compares local posts by file_url", function()
    local p1 = { is_local = true, file_url = "/path/1.jpg" }
    local p2 = { is_local = true, file_url = "/path/1.jpg" }
    local p3 = { is_local = true, file_url = "/path/2.jpg" }
    assert.is_true(util.is_same_post(p1, p2))
    assert.is_false(util.is_same_post(p1, p3))
  end)

  it("compares remote posts by numeric id string match", function()
    local p1 = { id = 12345, file_url = "https://example.com/12345.jpg" }
    local p2 = { id = "12345", file_url = "https://other.com/sample.jpg" }
    local p3 = { id = "99999", file_url = "https://example.com/99999.jpg" }
    assert.is_true(util.is_same_post(p1, p2))
    assert.is_false(util.is_same_post(p1, p3))
  end)
end)

describe("util.shuffle", function()
  it("handles nil and single element lists without error", function()
    assert.are.same({}, util.shuffle(nil))
    assert.are.same({ 1 }, util.shuffle({ 1 }))
  end)

  it("shuffles array and preserves all elements", function()
    local list = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
    local shuffled = util.shuffle(list)
    assert.are.equal(10, #shuffled)

    local counts = {}
    for _, v in ipairs(shuffled) do
      counts[v] = (counts[v] or 0) + 1
    end
    for i = 1, 10 do
      assert.are.equal(1, counts[i])
    end
  end)
end)

describe("util.load_auth and util.auth_qs", function()
  local tmp_auth
  local config = require("gelbooru.core.config")
  local orig_auth_file

  before_each(function()
    orig_auth_file = config.options.auth_file
    tmp_auth = vim.fn.tempname() .. ".json"
    config.options.auth_file = tmp_auth
    util.invalidate_auth_cache()
  end)

  after_each(function()
    config.options.auth_file = orig_auth_file
    util.invalidate_auth_cache()
    if vim.fn.filereadable(tmp_auth) == 1 then
      vim.fn.delete(tmp_auth)
    end
  end)

  it("returns empty table and empty auth_qs when auth_file does not exist", function()
    local auth = util.load_auth()
    assert.are.same({}, auth)
    assert.are.equal("", util.auth_qs())
  end)

  it("loads credentials, caches them, and builds auth_qs when api_key is present", function()
    local creds = { api_key = "secret_key_123", user_id = "user_456" }
    vim.fn.writefile({ vim.fn.json_encode(creds) }, tmp_auth)

    local auth = util.load_auth()
    assert.are.equal("secret_key_123", auth.api_key)
    assert.are.equal("user_456", auth.user_id)
    assert.are.equal("&api_key=secret_key_123&user_id=user_456", util.auth_qs())

    -- Delete file to prove in-memory caching
    vim.fn.delete(tmp_auth)
    local cached = util.load_auth()
    assert.are.equal("secret_key_123", cached.api_key)

    -- Invalidate cache and verify re-read observes missing file
    util.invalidate_auth_cache()
    local fresh = util.load_auth()
    assert.are.same({}, fresh)
    assert.are.equal("", util.auth_qs())
  end)
end)

describe("util.ensure", function()
  local tmp_base

  before_each(function()
    tmp_base = vim.fn.tempname()
  end)

  after_each(function()
    if vim.fn.isdirectory(tmp_base) == 1 then
      vim.fn.delete(tmp_base, "rf")
    end
  end)

  it("creates nested directory path", function()
    local nested = tmp_base .. "/sub/nested/dir"
    assert.are.equal(0, vim.fn.isdirectory(nested))
    util.ensure(nested)
    assert.are.equal(1, vim.fn.isdirectory(nested))
  end)
end)

describe("util.is_local_query", function()
  it("detects local queries with various prefixes and positions", function()
    assert.is_true(util.is_local_query("local:"))
    assert.is_true(util.is_local_query("local: /path/to/dir"))
    assert.is_true(util.is_local_query("tag1 local: tag2"))
    assert.is_true(util.is_local_query("LOCAL: tag"))
  end)

  it("returns false for online queries, nil, or non-string", function()
    assert.is_false(util.is_local_query("hatsune_miku rating:general"))
    assert.is_false(util.is_local_query("is_local:true"))
    assert.is_false(util.is_local_query("-local:tag"))
    assert.is_false(util.is_local_query(nil))
    assert.is_false(util.is_local_query(123))
  end)
end)

describe("util buffer and window helpers (scratch, set_lines, float, shield_buffer)", function()
  it("scratch creates an unlisted, non-modifiable buffer with wipe hidden", function()
    local buf = util.scratch()
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    assert.are.equal("wipe", vim.bo[buf].bufhidden)
    assert.is_false(vim.bo[buf].modifiable)
    assert.is_false(vim.bo[buf].swapfile)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("set_lines updates buffer content and restores non-modifiable status", function()
    local buf = util.scratch()
    util.set_lines(buf, { "hello", "world" })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.same({ "hello", "world" }, lines)
    assert.is_false(vim.bo[buf].modifiable)

    -- Safely handles invalid buffer without error
    assert.has_no.errors(function()
      util.set_lines(999999, { "line" })
      util.set_lines(nil, { "line" })
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("float creates a floating window with minimal configuration", function()
    local buf = util.scratch()
    local win = util.float(buf, 2, 4, 20, 10, { zindex = 60 })
    assert.is_true(vim.api.nvim_win_is_valid(win))
    local cfg = vim.api.nvim_win_get_config(win)
    assert.are.equal(20, cfg.width)
    assert.are.equal(10, cfg.height)
    assert.are.equal(60, cfg.zindex)
    vim.api.nvim_win_close(win, true)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("shield_buffer applies gelbooru filetype and neutralizes space / leader keys", function()
    local buf = util.scratch()
    util.shield_buffer(buf)

    assert.are.equal("gelbooru", vim.bo[buf].filetype)
    assert.is_true(vim.b[buf].which_key_ignore)
    assert.is_true(vim.b[buf].whichkey_disable)
    assert.is_true(vim.b[buf].miniclue_disable)

    -- Safely handles nil and invalid buffers
    assert.has_no.errors(function()
      util.shield_buffer(nil)
      util.shield_buffer(999999)
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("util.cache_post_metadata", function()
  local tmp_cache
  local config = require("gelbooru.core.config")
  local orig_cache_dir

  before_each(function()
    orig_cache_dir = config.options.cache_dir
    tmp_cache = vim.fn.tempname()
    vim.fn.mkdir(tmp_cache, "p")
    config.options.cache_dir = tmp_cache
  end)

  after_each(function()
    config.options.cache_dir = orig_cache_dir
    vim.fn.delete(tmp_cache, "rf")
  end)

  it("writes metadata JSON to cache directory for post with ID", function()
    local post = {
      id = "889900",
      tags = "tag_a tag_b",
      rating = "general",
      score = 42,
      width = 1920,
      height = 1080,
      source = "https://example.com",
    }

    local ok = util.cache_post_metadata(post)
    assert.is_true(ok)

    local expected_path = tmp_cache .. "/meta_889900.json"
    assert.are.equal(1, vim.fn.filereadable(expected_path))

    local loaded = util.read_json(expected_path)
    assert.are.equal("889900", loaded.id)
    assert.are.equal("tag_a tag_b", loaded.tags)
    assert.are.equal(42, loaded.score)
  end)

  it("returns false and skips writing for post without valid ID", function()
    assert.is_false(util.cache_post_metadata(nil))
    assert.is_false(util.cache_post_metadata({}))
    assert.is_false(util.cache_post_metadata({ id = "" }))
    assert.is_false(util.cache_post_metadata({ id = "nil" }))
  end)
end)
