-- tests/unit/local_spec.lua
-- Unit tests for local folder scanning, post creation, and metadata enrichment.

local ui = require("gelbooru.ui")
local api = require("gelbooru.net.api")
local config = require("gelbooru.core.config")
local download = require("gelbooru.net.download")
local state = require("gelbooru.core.state")
local image = require("gelbooru.ui.image")

describe("ui.scan_local_folder", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  it("filters image extensions and ignores non-images", function()
    -- Create test files
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/12345.jpg")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/67890.png")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/sample.webp")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/anim.gif")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/photo.jpeg")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/ignore.txt")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/tags.json")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/temp.jpg.part")

    local posts, target_dir = ui.scan_local_folder(tmp_dir)

    assert.are.equal(tmp_dir, target_dir)
    assert.are.equal(5, #posts)

    -- Verify post table schema
    for _, p in ipairs(posts) do
      assert.is_true(p.is_local)
      assert.are.equal("local", p.tags)
      assert.is_truthy(p.file_url)
      assert.are.equal(p.file_url, p.sample_url)
      assert.are.equal(p.file_url, p.preview_url)
    end
  end)

  it("extracts numeric post IDs from filenames", function()
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/11802758.jpg")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/gelbooru_99999.png")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/11802758_hatsune_miku.jpg")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/post-77777.jpg")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/photo_2024.jpg")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/IMG_0042.png")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/[Artist] Cute Girl (2024.01.01).sample.png")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/no_id_landscape.png")

    local posts = ui.scan_local_folder(tmp_dir)

    local id_map = {}
    for _, p in ipairs(posts) do
      local fname = vim.fn.fnamemodify(p.file_url, ":t")
      id_map[fname] = p.id
    end

    assert.are.equal("11802758", id_map["11802758.jpg"])
    assert.are.equal("99999", id_map["gelbooru_99999.png"])
    assert.are.equal("11802758", id_map["11802758_hatsune_miku.jpg"])
    assert.are.equal("77777", id_map["post-77777.jpg"])
    assert.is_nil(id_map["photo_2024.jpg"])
    assert.is_nil(id_map["IMG_0042.png"])
    assert.is_nil(id_map["[Artist] Cute Girl (2024.01.01).sample.png"])
    assert.is_nil(id_map["no_id_landscape.png"])
  end)

  it("defaults to config.options.save_dir when dir is nil or empty", function()
    local _, target_dir_nil = ui.scan_local_folder(nil)
    local _, target_dir_empty = ui.scan_local_folder("")
    local expected = vim.fn.expand(config.options.save_dir):gsub("/+$", "")

    assert.are.equal(expected, target_dir_nil)
    assert.are.equal(expected, target_dir_empty)
  end)

  it("handles non-existent directory gracefully without errors", function()
    local missing_dir = tmp_dir .. "/does_not_exist"
    local posts, target_dir = ui.scan_local_folder(missing_dir)

    assert.are.equal(missing_dir, target_dir)
    assert.are.equal(0, #posts)
  end)

  it("excludes directories with ONLY non-media files (.txt, .zip, .json, .part, .md)", function()
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/notes.txt")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/archive.zip")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/meta.json")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/download.png.part")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/README.md")

    local posts, _ = ui.scan_local_folder(tmp_dir)
    assert.are.equal(0, #posts)
  end)

  it("includes video files (.mp4, .webm) in scanned posts", function()
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/clip.mp4")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/anim.webm")

    local posts, _ = ui.scan_local_folder(tmp_dir)
    assert.are.equal(2, #posts)
    for _, p in ipairs(posts) do
      assert.is_true(p.is_local)
      assert.is_true(image.is_video_post(p))
    end
  end)

  it("pre-hydrates post metadata synchronously from cached JSON files", function()
    local util = require("gelbooru.core.util")
    local img_path = tmp_dir .. "/778899.jpg"
    vim.fn.writefile({ "dummy" }, img_path)

    local cache_dir = vim.fn.tempname()
    vim.fn.mkdir(cache_dir, "p")
    local orig_cache_dir = config.options.cache_dir
    config.options.cache_dir = cache_dir

    local meta_path = util.meta_cache_path("778899")
    util.write_json(meta_path, {
      id = "778899",
      tags = "hatsune_miku 1girl vocaloid",
      rating = "general",
      score = 999,
      width = 3840,
      height = 2160,
      source = "https://example.com/cached",
    })

    local posts, _ = ui.scan_local_folder(tmp_dir)
    assert.are.equal(1, #posts)
    local p = posts[1]
    assert.are.equal("778899", p.id)
    assert.is_true(p._metadata_fetched)
    assert.are.equal("hatsune_miku 1girl vocaloid", p.tags)
    assert.are.equal("general", p.rating)
    assert.are.equal(999, p.score)
    assert.are.equal(3840, p.width)
    assert.are.equal(2160, p.height)
    assert.are.equal("https://example.com/cached", p.source)

    config.options.cache_dir = orig_cache_dir
    vim.fn.delete(cache_dir, "rf")
  end)

  it("handles corrupted, partial, or empty metadata cache files during scan_local_folder without crashing", function()
    local util = require("gelbooru.core.util")
    local img_path = tmp_dir .. "/112233.png"
    vim.fn.writefile({ "dummy" }, img_path)

    local cache_dir = vim.fn.tempname()
    vim.fn.mkdir(cache_dir, "p")
    local orig_cache_dir = config.options.cache_dir
    config.options.cache_dir = cache_dir

    -- Write invalid/corrupt JSON in cache path
    local meta_path = util.meta_cache_path("112233")
    vim.fn.writefile({ "CORRUPTED { INVALID_JSON", "partial content..." }, meta_path)

    local posts, _ = ui.scan_local_folder(tmp_dir)
    assert.are.equal(1, #posts)
    local p = posts[1]
    assert.are.equal("112233", p.id)
    assert.are.equal("local", p.tags)
    assert.is_nil(p._metadata_fetched)

    -- Also test empty (0-byte) cache file
    vim.fn.writefile({}, meta_path)
    local posts_empty, _ = ui.scan_local_folder(tmp_dir)
    assert.are.equal(1, #posts_empty)
    assert.are.equal("112233", posts_empty[1].id)
    assert.are.equal("local", posts_empty[1].tags)
    assert.is_nil(posts_empty[1]._metadata_fetched)

    config.options.cache_dir = orig_cache_dir
    vim.fn.delete(cache_dir, "rf")
  end)

  it("handles directory paths containing brackets and special characters", function()
    local bracket_dir = tmp_dir .. "/[Artist] Special Folder (2024)"
    vim.fn.mkdir(bracket_dir, "p")
    vim.fn.writefile({ "dummy" }, bracket_dir .. "/pic.png")

    local posts, target = ui.scan_local_folder(bracket_dir)
    assert.are.equal(bracket_dir, target)
    assert.are.equal(1, #posts)
    assert.is_truthy(posts[1].file_url:find("pic.png", 1, true))
  end)

  it("correctly resolves filenames with spaces, brackets, utf-8, multiple dots", function()
    local complex_name = "[Artist] 可愛い 女の子 (2024.01.01).sample.png"
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/" .. complex_name)

    local posts, _ = ui.scan_local_folder(tmp_dir)
    assert.are.equal(1, #posts)
    local p = posts[1]
    assert.is_true(p.is_local)
    assert.are.equal(tmp_dir .. "/" .. complex_name, p.file_url)

    -- Target resolution via image.get_preview_targets
    local urls, dest = image.get_preview_targets(p)
    assert.are.equal(1, #urls)
    assert.are.equal(p.file_url, urls[1])
    assert.are.equal(p.file_url, dest)
  end)

  it("supports direct file paths, scanning parent dir and identifying target file", function()
    local img1 = tmp_dir .. "/01_pic.jpg"
    local img2 = tmp_dir .. "/02_pic.jpg"
    vim.fn.writefile({ "dummy" }, img1)
    vim.fn.writefile({ "dummy" }, img2)

    local posts, target_dir, target_file = ui.scan_local_folder(img2)
    assert.are.equal(tmp_dir, target_dir)
    assert.are.equal(img2, target_file)
    assert.are.equal(2, #posts)
  end)

  it("exposes local_browser alias in top-level gelbooru module", function()
    local gelbooru = require("gelbooru")
    assert.is_function(gelbooru.local_browser)
    assert.are.equal(gelbooru.open_local, gelbooru.local_browser)
  end)

  it("exposes local module and scan module functions directly", function()
    local local_mod = require("gelbooru.local")
    local scan_mod = require("gelbooru.local.scan")
    assert.is_function(local_mod.open_local)
    assert.is_function(local_mod.scan_local_folder)
    assert.is_function(scan_mod.scan_local_folder)
    assert.is_function(scan_mod.extract_post_id)
  end)
end)

describe("api.fetch_post_metadata", function()
  local orig_curl_async
  local orig_cache_dir
  local tmp_cache

  before_each(function()
    orig_curl_async = download.curl_async
    state.State.torn_down = false
    orig_cache_dir = config.options.cache_dir
    tmp_cache = vim.fn.tempname()
    vim.fn.mkdir(tmp_cache, "p")
    config.options.cache_dir = tmp_cache
  end)

  after_each(function()
    download.curl_async = orig_curl_async
    state.State.torn_down = false
    config.options.cache_dir = orig_cache_dir
    vim.fn.delete(tmp_cache, "rf")
  end)

  it("enriches post with tags, rating, score, dimensions from API response", function()
    local p = {
      id = "1001",
      file_url = "/tmp/1001.jpg",
      is_local = true,
      tags = "local",
    }

    download.curl_async = function(url, cb)
      assert.is_truthy(url:find("id=1001"))
      vim.schedule(function()
        cb(vim.fn.json_encode({
          post = {
            id = 1001,
            tags = "hatsune_miku 1girl vocaloid",
            rating = "general",
            score = 250,
            width = 1920,
            height = 1080,
            source = "https://example.com/source",
          },
        }))
      end)
    end

    local enriched = false
    api.fetch_post_metadata(p, function(updated_p)
      enriched = true
      assert.are.equal(p, updated_p)
      assert.are.equal("hatsune_miku 1girl vocaloid", p.tags)
      assert.are.equal("general", p.rating)
      assert.are.equal(250, p.score)
      assert.are.equal(1920, p.width)
      assert.are.equal(1080, p.height)
      assert.are.equal("https://example.com/source", p.source)
      assert.is_true(p._metadata_fetched)
    end)

    vim.wait(500, function()
      return enriched
    end, 10)

    assert.is_true(enriched)
  end)

  it("handles array post responses as well as single dict responses", function()
    local p = {
      id = "2002",
      file_url = "/tmp/2002.jpg",
      is_local = true,
      tags = "local",
    }

    download.curl_async = function(url, cb)
      vim.schedule(function()
        cb(vim.fn.json_encode({
          post = {
            {
              id = 2002,
              tags = "megurine_luka 1girl",
              rating = "sensitive",
              score = 120,
            },
          },
        }))
      end)
    end

    local enriched = false
    api.fetch_post_metadata(p, function(_)
      enriched = true
      assert.are.equal("megurine_luka 1girl", p.tags)
      assert.are.equal("sensitive", p.rating)
      assert.are.equal(120, p.score)
    end)

    vim.wait(500, function()
      return enriched
    end, 10)

    assert.is_true(enriched)
  end)

  it("aborts when State.torn_down is true", function()
    local p = {
      id = "3003",
      file_url = "/tmp/3003.jpg",
      is_local = true,
      tags = "local",
    }

    download.curl_async = function(url, cb)
      vim.schedule(function()
        state.State.torn_down = true
        cb(vim.fn.json_encode({
          post = { id = 3003, tags = "should_not_enrich" },
        }))
      end)
    end

    local called = false
    api.fetch_post_metadata(p, function(_)
      called = true
    end)

    vim.wait(100, function()
      return called
    end, 10)

    assert.is_false(called)
    assert.are.equal("local", p.tags)
  end)

  it("safely skips when post has no ID or empty ID", function()
    local called_curl = false
    download.curl_async = function(_, _)
      called_curl = true
    end

    local p_no_id = { file_url = "/tmp/art.png", is_local = true, tags = "local" }
    api.fetch_post_metadata(p_no_id)
    assert.is_false(called_curl)

    local p_empty_id = { id = "", file_url = "/tmp/art.png", is_local = true, tags = "local" }
    api.fetch_post_metadata(p_empty_id)
    assert.is_false(called_curl)
  end)

  it("handles offline / network error (curl returns nil) smoothly without errors", function()
    local p = {
      id = "4004",
      file_url = "/tmp/4004.jpg",
      is_local = true,
      tags = "local",
    }

    download.curl_async = function(_, cb)
      vim.schedule(function()
        cb(nil) -- Simulate offline network failure
      end)
    end

    local result = "sentinel"
    api.fetch_post_metadata(p, function(updated_p)
      result = updated_p
    end)

    vim.wait(100, function()
      return p._metadata_fetched == true
    end, 10)

    assert.is_nil(result)
    assert.are.equal("local", p.tags)
    assert.is_true(p._metadata_fetched)
    assert.is_false(p._metadata_loading)
  end)

  it("handles corrupted JSON response safely via pcall", function()
    local p = {
      id = "5005",
      file_url = "/tmp/5005.jpg",
      is_local = true,
      tags = "local",
    }

    download.curl_async = function(_, cb)
      vim.schedule(function()
        cb("<html><head><title>502 Bad Gateway</title></head><body>Bad Gateway</body></html>")
      end)
    end

    local result = "sentinel"
    api.fetch_post_metadata(p, function(updated_p)
      result = updated_p
    end)

    vim.wait(100, function()
      return p._metadata_fetched == true
    end, 10)

    assert.is_nil(result)
    assert.are.equal("local", p.tags)
    assert.is_true(p._metadata_fetched)
  end)

  it("caches _metadata_fetched to prevent infinite API requests on repeated calls", function()
    local p = {
      id = "6006",
      file_url = "/tmp/6006.jpg",
      is_local = true,
      tags = "local",
    }

    local request_count = 0
    download.curl_async = function(_, cb)
      request_count = request_count + 1
      vim.schedule(function()
        cb(vim.fn.json_encode({
          post = { id = 6006, tags = "test_tag", rating = "general", score = 10 },
        }))
      end)
    end

    api.fetch_post_metadata(p)
    vim.wait(100, function()
      return p._metadata_fetched == true
    end, 10)
    assert.are.equal(1, request_count)

    -- Repeated call should be a no-op due to _metadata_fetched cache
    api.fetch_post_metadata(p)
    assert.are.equal(1, request_count)
  end)

  it("writes metadata to disk cache on successful API fetch", function()
    local util = require("gelbooru.core.util")
    local p = {
      id = "7007",
      file_url = "/tmp/7007.jpg",
      is_local = true,
      tags = "local",
    }

    download.curl_async = function(_, cb)
      vim.schedule(function()
        cb(vim.fn.json_encode({
          post = {
            id = 7007,
            tags = "disk_cache_tag 1girl",
            rating = "general",
            score = 50,
            width = 800,
            height = 600,
            source = "https://example.com/disk_test",
          },
        }))
      end)
    end

    local enriched = false
    api.fetch_post_metadata(p, function(_)
      enriched = true
    end)

    vim.wait(200, function()
      return enriched
    end, 10)

    assert.is_true(enriched)
    local meta_path = util.meta_cache_path("7007")
    assert.are.equal(1, vim.fn.filereadable(meta_path))
    local cached = util.read_json(meta_path)
    assert.is_not_nil(cached)
    assert.are.equal("disk_cache_tag 1girl", cached.tags)
    assert.are.equal("general", cached.rating)
    assert.are.equal(50, cached.score)
    assert.are.equal(800, cached.width)
    assert.are.equal(600, cached.height)
    assert.are.equal("https://example.com/disk_test", cached.source)
  end)

  it("hydrates from disk cache without API call when meta JSON is cached on disk", function()
    local util = require("gelbooru.core.util")
    local meta_path = util.meta_cache_path("8008")
    util.write_json(meta_path, {
      id = "8008",
      tags = "offline_disk_tag",
      rating = "sensitive",
      score = 77,
      width = 1280,
      height = 720,
      source = "https://cached.org",
    })

    local curl_called = false
    download.curl_async = function(_, _)
      curl_called = true
    end

    local p = {
      id = "8008",
      file_url = "/tmp/8008.jpg",
      is_local = true,
      tags = "local",
    }

    local cb_called = false
    api.fetch_post_metadata(p, function(updated_p)
      cb_called = true
      assert.are.equal(p, updated_p)
    end)

    assert.is_true(cb_called)
    assert.is_false(curl_called)
    assert.is_true(p._metadata_fetched)
    assert.are.equal("offline_disk_tag", p.tags)
    assert.are.equal("sensitive", p.rating)
    assert.are.equal(77, p.score)
    assert.are.equal(1280, p.width)
    assert.are.equal(720, p.height)
    assert.are.equal("https://cached.org", p.source)
  end)

  it("api.save_current automatically caches post metadata on successful download", function()
    local util = require("gelbooru.core.util")
    local orig_download_async = download.download_async
    local save_dir = vim.fn.tempname()
    vim.fn.mkdir(save_dir, "p")
    local orig_save_dir = config.options.save_dir
    config.options.save_dir = save_dir

    download.download_async = function(url, dest, cb, opts)
      vim.schedule(function()
        vim.fn.writefile({ "image data" }, dest)
        cb(true)
      end)
    end

    state.State.posts = {
      {
        id = "9009",
        file_url = "https://example.com/9009.jpg",
        tags = "saved_tag artist:foo",
        rating = "general",
        score = 88,
        width = 1920,
        height = 1080,
        source = "https://example.com/source",
      },
    }
    state.State.cur = 1

    local saved_done = false
    api.save_current(function(saved, dest)
      saved_done = true
      assert.is_true(saved)
      assert.is_truthy(dest:find("9009.jpg"))
    end)

    vim.wait(200, function()
      return saved_done
    end, 10)

    assert.is_true(saved_done)
    local meta_path = util.meta_cache_path("9009")
    assert.are.equal(1, vim.fn.filereadable(meta_path))
    local cached = util.read_json(meta_path)
    assert.is_not_nil(cached)
    assert.are.equal("9009", cached.id)
    assert.are.equal("saved_tag artist:foo", cached.tags)
    assert.are.equal("general", cached.rating)
    assert.are.equal(88, cached.score)

    download.download_async = orig_download_async
    config.options.save_dir = orig_save_dir
    vim.fn.delete(save_dir, "rf")
  end)

  it("handles corrupted, partial, or empty metadata cache during fetch_post_metadata by falling back to API fetch", function()
    local util = require("gelbooru.core.util")
    local meta_path = util.meta_cache_path("7711")
    -- Put corrupted JSON in cache file
    vim.fn.writefile({ "CORRUPTED { NO_CLOSE", "partial" }, meta_path)

    local api_called = false
    download.curl_async = function(_, cb)
      api_called = true
      vim.schedule(function()
        cb(vim.fn.json_encode({
          post = {
            id = 7711,
            tags = "repaired_tag anime",
            rating = "general",
            score = 150,
            width = 1920,
            height = 1080,
            source = "https://repaired.org",
          },
        }))
      end)
    end

    local p = {
      id = "7711",
      file_url = "/tmp/7711.jpg",
      is_local = true,
      tags = "local",
    }

    local enriched = false
    api.fetch_post_metadata(p, function(updated_p)
      enriched = true
      assert.are.equal("repaired_tag anime", updated_p.tags)
    end)

    vim.wait(200, function()
      return enriched
    end, 10)

    assert.is_true(api_called)
    assert.is_true(enriched)
    assert.are.equal("repaired_tag anime", p.tags)
    assert.are.equal(150, p.score)

    -- Overwritten cache file should now contain the valid repaired json
    local cached = util.read_json(meta_path)
    assert.is_not_nil(cached)
    assert.are.equal("repaired_tag anime", cached.tags)
    assert.are.equal(150, cached.score)
  end)

  it("fetch_post_metadata safely skips posts with nil, empty, or 'nil' ID without crashing or querying network", function()
    local curl_called = false
    download.curl_async = function(_, _)
      curl_called = true
    end

    local test_posts = {
      { id = nil, is_local = true, tags = "local" },
      { id = "", is_local = true, tags = "local" },
    }

    for _, p in ipairs(test_posts) do
      local cb_called = false
      api.fetch_post_metadata(p, function(_)
        cb_called = true
      end)
      assert.is_false(cb_called)
      assert.is_false(curl_called)
      assert.is_nil(p._metadata_loading)
      assert.is_nil(p._metadata_fetched)
    end

    -- 'nil' string id: safely returns nil without calling curl
    local p_nil_str = { id = "nil", is_local = true, tags = "local" }
    api.fetch_post_metadata(p_nil_str, function(_) end)
    assert.is_false(curl_called)
  end)

  it("api.save_current handles missing ID, empty file_url, and local posts gracefully", function()
    local orig_posts = state.State.posts
    local orig_cur = state.State.cur

    -- Case 1: Post is local (already exists locally, does not download)
    state.State.posts = { { id = "100", file_url = "/local/path/100.jpg", is_local = true } }
    state.State.cur = 1
    local local_cb_called = false
    api.save_current(function(saved, dest)
      local_cb_called = true
      assert.is_true(saved)
      assert.are.equal("/local/path/100.jpg", dest)
    end)
    assert.is_true(local_cb_called)

    -- Case 2: Post has nil file_url
    state.State.posts = { { id = "200", file_url = nil, is_local = false } }
    local nil_cb_called = false
    api.save_current(function(saved, dest)
      nil_cb_called = true
      assert.is_false(saved)
      assert.is_nil(dest)
    end)
    assert.is_true(nil_cb_called)

    -- Case 3: Online post with nil ID
    state.State.posts = { { id = nil, file_url = "https://example.com/test.jpg", is_local = false } }
    local no_id_cb_called = false
    api.save_current(function(saved, dest)
      no_id_cb_called = true
      assert.is_false(saved)
      assert.is_nil(dest)
    end)
    assert.is_true(no_id_cb_called)

    state.State.posts = orig_posts
    state.State.cur = orig_cur
  end)
end)

describe("local.query: Query Parsing and Post Filtering", function()
  local local_query = require("gelbooru.local.query")
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    if tmp_dir and vim.fn.isdirectory(tmp_dir) == 1 then
      vim.fn.delete(tmp_dir, "rf")
    end
  end)

  describe("Query Parsing (parse_query / parse_local_query)", function()
    it("parses empty or nil query to default save_dir with empty tags", function()
      local dir1, tags1 = local_query.parse_query(nil)
      assert.are.equal(config.options.save_dir, dir1)
      assert.are.equal("", tags1)

      local dir2, tags2 = local_query.parse_query("")
      assert.are.equal(config.options.save_dir, dir2)
      assert.are.equal("", tags2)

      local dir3, tags3 = local_query.parse_query("local:")
      assert.are.equal(config.options.save_dir, dir3)
      assert.are.equal("", tags3)

      local dir4, tags4 = local_query.parse_query("local:   ")
      assert.are.equal(config.options.save_dir, dir4)
      assert.are.equal("", tags4)
    end)

    it("parses 'local: <tags>' defaulting directory to config.options.save_dir", function()
      local dir, tags = local_query.parse_query("local: hatsune_miku rating:general")
      assert.are.equal(config.options.save_dir, dir)
      assert.are.equal("hatsune_miku rating:general", tags)
    end)

    it("extracts directory and tags for 'local:<dir> <tags>' and 'local:<dir>'", function()
      local dir1, tags1 = local_query.parse_query("local:/path/to/folder tag1 tag2")
      assert.are.equal("/path/to/folder", dir1)
      assert.are.equal("tag1 tag2", tags1)

      local dir2, tags2 = local_query.parse_query("local:~/Downloads tag1 -tag2")
      assert.are.equal("~/Downloads", dir2)
      assert.are.equal("tag1 -tag2", tags2)

      local dir3, tags3 = local_query.parse_query("local:./photos solo")
      assert.are.equal("./photos", dir3)
      assert.are.equal("solo", tags3)

      local dir4, tags4 = local_query.parse_query("local:/path/to/folder")
      assert.are.equal("/path/to/folder", dir4)
      assert.are.equal("", tags4)
    end)

    it("supports quoted directories with spaces in local: query", function()
      local dir1, tags1 = local_query.parse_query('local:"/path with spaces/folder" tag1')
      assert.are.equal("/path with spaces/folder", dir1)
      assert.are.equal("tag1", tags1)

      local dir2, tags2 = local_query.parse_query("local:'~/My Pictures/Art' -solo")
      assert.are.equal("~/My Pictures/Art", dir2)
      assert.are.equal("-solo", tags2)

      local dir3, tags3 = local_query.parse_query('local: "/my folder" tag1 tag2')
      assert.are.equal("/my folder", dir3)
      assert.are.equal("tag1 tag2", tags3)
    end)

    it("robustly treats existing filesystem directory as dir, even without path prefix", function()
      local sub_dir = tmp_dir .. "/existing_sub"
      vim.fn.mkdir(sub_dir, "p")

      local dir, tags = local_query.parse_query("local:" .. sub_dir .. " tag1")
      assert.are.equal(sub_dir, dir)
      assert.are.equal("tag1", tags)
    end)

    it("treats non-path non-directory first token as tags in default save_dir", function()
      local dir, tags = local_query.parse_query("local:not_a_dir_tag1 tag2")
      assert.are.equal(config.options.save_dir, dir)
      assert.are.equal("not_a_dir_tag1 tag2", tags)
    end)

    it("parse_local_query is an alias to parse_query", function()
      assert.is_function(local_query.parse_local_query)
      local dir1, tags1 = local_query.parse_local_query("local:/tmp tag1")
      local dir2, tags2 = local_query.parse_query("local:/tmp tag1")
      assert.are.equal(dir1, dir2)
      assert.are.equal(tags1, tags2)
    end)

    it("supports flexible placement of local: anywhere in the query string", function()
      local dir1, tags1, f1 = local_query.parse_query("solo hatsune_miku local: sort:score")
      assert.are.equal(config.options.save_dir, dir1)
      assert.are.equal("solo hatsune_miku sort:score", tags1)
      assert.are.equal(2, #f1.positive_tags)
      assert.are.equal("solo", f1.positive_tags[1])
      assert.are.equal("hatsune_miku", f1.positive_tags[2])
      assert.is_not_nil(f1.sort)
      assert.are.equal("score", f1.sort.key)

      local dir2, tags2, f2 = local_query.parse_query("~foot_focus local:")
      assert.are.equal(config.options.save_dir, dir2)
      assert.are.equal("~foot_focus", tags2)
      assert.are.equal(1, #f2.or_tags)
      assert.are.equal("foot_focus", f2.or_tags[1])

      local dir3, tags3, f3 = local_query.parse_query("tag1 tag2 local:/custom/dir tag3")
      assert.are.equal("/custom/dir", dir3)
      assert.are.equal("tag1 tag2 tag3", tags3)
      assert.are.equal(3, #f3.positive_tags)

      local dir4, tags4, f4 = local_query.parse_query('tag1 local:"/path with spaces" tag2')
      assert.are.equal("/path with spaces", dir4)
      assert.are.equal("tag1 tag2", tags4)
      assert.are.equal(2, #f4.positive_tags)
    end)
  end)

  describe("Post Filtering (filter_posts / matches_post)", function()
    local sample_posts

    before_each(function()
      sample_posts = {
        {
          id = "101",
          file_url = tmp_dir .. "/101_hatsune_miku.png",
          tags = "hatsune_miku vocaloid 1girl solo kekeflipnote",
          artist = "kekeflipnote",
          character = "hatsune_miku",
          rating = "general",
          score = 150,
          is_local = true,
        },
        {
          id = "102",
          file_url = tmp_dir .. "/102_megurine_luka.jpg",
          tags = "megurine_luka vocaloid 1girl duet",
          artist = "other_artist",
          character = "megurine_luka",
          rating = "sensitive",
          score = 80,
          is_local = true,
        },
        {
          id = "103",
          file_url = tmp_dir .. "/103_clip.mp4",
          tags = "animation 3d video",
          rating = "questionable",
          score = 25,
          is_local = true,
        },
        {
          id = "104",
          file_url = tmp_dir .. "/104_explicit_art.png",
          tags = "solo mature",
          rating = "explicit",
          score = -5,
          is_local = true,
        },
        {
          id = nil,
          file_url = tmp_dir .. "/untagged_hatsune_miku_dance.png",
          tags = "local",
          is_local = true,
        },
      }
    end)

    it("filters posts by booru tags and artist/character", function()
      local miku_posts = local_query.filter_posts(sample_posts, "vocaloid")
      assert.are.equal(2, #miku_posts)
      assert.are.equal("101", miku_posts[1].id)
      assert.are.equal("102", miku_posts[2].id)

      local keke_posts = local_query.filter_posts(sample_posts, "kekeflipnote")
      assert.are.equal(1, #keke_posts)
      assert.are.equal("101", keke_posts[1].id)
    end)

    it("filters posts by rating: rating:general, rating:g, rating:sensitive, rating:s, etc.", function()
      local gen_posts = local_query.filter_posts(sample_posts, "rating:general")
      assert.are.equal(1, #gen_posts)
      assert.are.equal("101", gen_posts[1].id)

      local gen_g = local_query.filter_posts(sample_posts, "rating:g")
      assert.are.equal(1, #gen_g)
      assert.are.equal("101", gen_g[1].id)

      local sens_posts = local_query.filter_posts(sample_posts, "rating:sensitive")
      assert.are.equal(1, #sens_posts)
      assert.are.equal("102", sens_posts[1].id)

      local sens_s = local_query.filter_posts(sample_posts, "rating:s")
      assert.are.equal(1, #sens_s)
      assert.are.equal("102", sens_s[1].id)

      local q_posts = local_query.filter_posts(sample_posts, "rating:q")
      assert.are.equal(1, #q_posts)
      assert.are.equal("103", q_posts[1].id)

      local exp_posts = local_query.filter_posts(sample_posts, "rating:explicit")
      assert.are.equal(1, #exp_posts)
      assert.are.equal("104", exp_posts[1].id)
    end)

    it("supports negative ratings: -rating:explicit (-rating:e)", function()
      local non_exp = local_query.filter_posts(sample_posts, "-rating:explicit")
      assert.are.equal(4, #non_exp)
      for _, p in ipairs(non_exp) do
        assert.are.not_equal("104", p.id)
      end

      local non_e = local_query.filter_posts(sample_posts, "-rating:e")
      assert.are.equal(4, #non_e)
    end)

    it("filters posts by score: score:>=50, score:>10, score:<=5, score:<0, score:=25, score:25", function()
      local gte_50 = local_query.filter_posts(sample_posts, "score:>=50")
      assert.are.equal(2, #gte_50)
      assert.are.equal("101", gte_50[1].id)
      assert.are.equal("102", gte_50[2].id)

      local gt_80 = local_query.filter_posts(sample_posts, "score:>80")
      assert.are.equal(1, #gt_80)
      assert.are.equal("101", gt_80[1].id)

      local lte_25 = local_query.filter_posts(sample_posts, "score:<=25")
      -- 103 (25), 104 (-5), untagged (0)
      assert.are.equal(3, #lte_25)

      local lt_0 = local_query.filter_posts(sample_posts, "score:<0")
      assert.are.equal(1, #lt_0)
      assert.are.equal("104", lt_0[1].id)

      local eq_25 = local_query.filter_posts(sample_posts, "score:=25")
      assert.are.equal(1, #eq_25)
      assert.are.equal("103", eq_25[1].id)

      local eq_bare = local_query.filter_posts(sample_posts, "score:25")
      assert.are.equal(1, #eq_bare)
      assert.are.equal("103", eq_bare[1].id)
    end)

    it("filters posts with negative tags: -tag (must NOT match in tags, artists, characters, or filename tokens)", function()
      local no_solo = local_query.filter_posts(sample_posts, "-solo")
      assert.are.equal(3, #no_solo)
      for _, p in ipairs(no_solo) do
        assert.are.not_equal("101", p.id)
        assert.are.not_equal("104", p.id)
      end

      local no_miku = local_query.filter_posts(sample_posts, "-miku")
      for _, p in ipairs(no_miku) do
        assert.are.not_equal("101", p.id)
        assert.is_falsy(p.file_url:find("untagged_hatsune_miku_dance"))
      end
    end)

    it("falls back to normalized filename words for untagged / local items", function()
      local dance_posts = local_query.filter_posts(sample_posts, "dance")
      assert.are.equal(1, #dance_posts)
      assert.is_nil(dance_posts[1].id)
      assert.is_truthy(dance_posts[1].file_url:find("untagged_hatsune_miku_dance"))

      local miku_posts = local_query.filter_posts(sample_posts, "miku")
      -- Matches post 101 (tag) and untagged_hatsune_miku_dance (filename)
      assert.are.equal(2, #miku_posts)
    end)

    it("combines multiple filter clauses with logical AND", function()
      local query_str = "vocaloid rating:general score:>=100 -duet"
      local result = local_query.filter_posts(sample_posts, query_str)
      assert.are.equal(1, #result)
      assert.are.equal("101", result[1].id)
    end)

    it("supports native booru tilde (~) OR syntax: local: ~foot_focus ~soles ~foot_job", function()
      local posts = {
        { id = "1", tags = "1girl foot_focus", is_local = true },
        { id = "2", tags = "1girl soles", is_local = true },
        { id = "3", tags = "1girl foot_job", is_local = true },
        { id = "4", tags = "1girl hands", is_local = true },
      }

      local f = local_query.parse_tags("~foot_focus ~soles ~foot_job")
      assert.are.equal(3, #f.or_tags)
      assert.are.equal("foot_focus", f.or_tags[1])
      assert.are.equal("soles", f.or_tags[2])
      assert.are.equal("foot_job", f.or_tags[3])
      assert.are.equal(0, #f.positive_tags)

      local matched = local_query.filter_posts(posts, f)
      assert.are.equal(3, #matched)
      assert.are.equal("1", matched[1].id)
      assert.are.equal("2", matched[2].id)
      assert.are.equal("3", matched[3].id)
    end)

    it("combines positive AND tags with tilde (~) OR group: hatsune_miku ~foot_focus ~soles", function()
      local posts = {
        { id = "1", tags = "hatsune_miku 1girl foot_focus", is_local = true },
        { id = "2", tags = "hatsune_miku 1girl soles", is_local = true },
        { id = "3", tags = "hatsune_miku 1girl portrait", is_local = true },
        { id = "4", tags = "megurine_luka 1girl soles", is_local = true },
      }

      local f = local_query.parse_tags("hatsune_miku ~foot_focus ~soles")
      assert.are.equal(1, #f.positive_tags)
      assert.are.equal("hatsune_miku", f.positive_tags[1])
      assert.are.equal(2, #f.or_tags)

      local matched = local_query.filter_posts(posts, f)
      assert.are.equal(2, #matched)
      assert.are.equal("1", matched[1].id)
      assert.are.equal("2", matched[2].id)
    end)

    it("combines tilde (~) OR group with negative exclusions: ~foot_focus ~soles -comic", function()
      local posts = {
        { id = "1", tags = "foot_focus solo", is_local = true },
        { id = "2", tags = "soles comic", is_local = true },
        { id = "3", tags = "soles illustration", is_local = true },
        { id = "4", tags = "hands illustration", is_local = true },
      }

      local f = local_query.parse_tags("~foot_focus ~soles -comic")
      assert.are.equal(2, #f.or_tags)
      assert.are.equal(1, #f.negative_tags)
      assert.are.equal("comic", f.negative_tags[1])

      local matched = local_query.filter_posts(posts, f)
      assert.are.equal(2, #matched)
      assert.are.equal("1", matched[1].id)
      assert.are.equal("3", matched[2].id)
    end)

    it("supports intra-token tag disjunction (|): foot_focus|soles|foot_job", function()
      local posts = {
        { id = "1", tags = "foot_focus solo", is_local = true },
        { id = "2", tags = "soles solo", is_local = true },
        { id = "3", tags = "foot_job solo", is_local = true },
        { id = "4", tags = "landscape", is_local = true },
      }

      local f = local_query.parse_tags("foot_focus|soles|foot_job")
      assert.are.equal(3, #f.or_tags)
      assert.are.equal("foot_focus", f.or_tags[1])
      assert.are.equal("soles", f.or_tags[2])
      assert.are.equal("foot_job", f.or_tags[3])

      local matched = local_query.filter_posts(posts, f)
      assert.are.equal(3, #matched)

      local combined = local_query.filter_posts(posts, "solo foot_focus|soles -landscape")
      assert.are.equal(2, #combined)
      assert.are.equal("1", combined[1].id)
      assert.are.equal("2", combined[2].id)
    end)

    it("supports rating disjunctions across all forms: ~rating:q ~rating:e, rating:q,e, rating:q|e", function()
      local posts = {
        { id = "1", rating = "general", is_local = true },
        { id = "2", rating = "sensitive", is_local = true },
        { id = "3", rating = "questionable", is_local = true },
        { id = "4", rating = "explicit", is_local = true },
        { id = "5", rating = nil, is_local = true },
      }

      -- 1. Tilde rating syntax: ~rating:questionable ~rating:explicit
      local f1 = local_query.parse_tags("~rating:questionable ~rating:explicit")
      assert.are.equal(2, #f1.ratings)
      assert.are.equal("eq", f1.ratings[1].op)
      assert.are.equal("questionable", f1.ratings[1].val)
      assert.are.equal("eq", f1.ratings[2].op)
      assert.are.equal("explicit", f1.ratings[2].val)

      local m1 = local_query.filter_posts(posts, f1)
      assert.are.equal(2, #m1)
      assert.are.equal("3", m1[1].id)
      assert.are.equal("4", m1[2].id)

      -- 2. Comma separated rating: rating:questionable,explicit
      local f2 = local_query.parse_tags("rating:questionable,explicit")
      local m2 = local_query.filter_posts(posts, f2)
      assert.are.equal(2, #m2)
      assert.are.equal("3", m2[1].id)
      assert.are.equal("4", m2[2].id)

      -- 3. Short aliases comma separated: rating:q,e
      local f3 = local_query.parse_tags("rating:q,e")
      local m3 = local_query.filter_posts(posts, f3)
      assert.are.equal(2, #m3)
      assert.are.equal("3", m3[1].id)
      assert.are.equal("4", m3[2].id)

      -- 4. Pipe separated short aliases: rating:q|e and ~rating:q|e
      local f4 = local_query.parse_tags("rating:q|e")
      local m4 = local_query.filter_posts(posts, f4)
      assert.are.equal(2, #m4)

      local f5 = local_query.parse_tags("~rating:q|e")
      local m5 = local_query.filter_posts(posts, f5)
      assert.are.equal(2, #m5)

      -- 5. Negative rating still strictly rejects
      local f6 = local_query.parse_tags("rating:q,e -rating:e")
      local m6 = local_query.filter_posts(posts, f6)
      assert.are.equal(1, #m6)
      assert.are.equal("3", m6[1].id)

      -- 6. Unhydrated post (nil rating) is rejected when positive rating is required
      assert.is_false(local_query.matches_post(posts[5], f3))
    end)
  end)

  describe("Local Sorting Engine (parse_tags sort directives & sort_posts)", function()
    it("supports cascading & multi-stage sorting with secondary tie-breaking", function()
      -- 1. Comma-separated sort stages: sort:score:desc,date:desc
      local f1 = local_query.parse_tags("sort:score:desc,date:desc")
      assert.is_not_nil(f1.sort)
      assert.are.equal("score", f1.sort.key)
      assert.are.equal("desc", f1.sort.dir)
      assert.are.equal(2, #f1.sort)
      assert.are.equal("score", f1.sort[1].key)
      assert.are.equal("desc", f1.sort[1].dir)
      assert.are.equal("date", f1.sort[2].key)
      assert.are.equal("desc", f1.sort[2].dir)

      -- 2. Multiple sort tokens: sort:score:desc sort:id:asc
      local f2 = local_query.parse_tags("sort:score:desc sort:id:asc")
      assert.are.equal(2, #f2.sort)
      assert.are.equal("score", f2.sort[1].key)
      assert.are.equal("id", f2.sort[2].key)
      assert.are.equal("asc", f2.sort[2].dir)

      -- 3. Piped query stages: hatsune_miku | sort:score:desc | sort:id:asc
      local f3 = local_query.parse_tags("hatsune_miku | sort:score:desc | sort:id:asc")
      assert.are.equal(1, #f3.positive_tags)
      assert.are.equal("hatsune_miku", f3.positive_tags[1])
      assert.are.equal(2, #f3.sort)
      assert.are.equal("score", f3.sort[1].key)
      assert.are.equal("id", f3.sort[2].key)

      -- 4. Secondary tie-breaking execution
      local p1 = { id = "10", score = 50, _mtime = 1000, file_url = "/a.jpg" }
      local p2 = { id = "20", score = 50, _mtime = 2000, file_url = "/b.jpg" }
      local p3 = { id = "30", score = 100, _mtime = 500, file_url = "/c.jpg" }

      -- Primary score desc, secondary date desc
      -- p3 has score 100 (1st)
      -- p1 and p2 tie on score (50). p2 has _mtime 2000 > p1 _mtime 1000 -> p2 is 2nd, p1 is 3rd
      local sorted = local_query.sort_posts({ p1, p2, p3 }, f1.sort)
      assert.are.equal("30", sorted[1].id)
      assert.are.equal("20", sorted[2].id)
      assert.are.equal("10", sorted[3].id)

      -- Primary score desc, secondary id asc
      -- p1 id 10 < p2 id 20 -> p1 is 2nd, p2 is 3rd
      local sorted2 = local_query.sort_posts({ p1, p2, p3 }, f2.sort)
      assert.are.equal("30", sorted2[1].id)
      assert.are.equal("10", sorted2[2].id)
      assert.are.equal("20", sorted2[3].id)
    end)
    it("parses sort:score, sort:id, sort:date, sort:random, sort:mtime, and order: directives", function()
      local f1 = local_query.parse_tags("hatsune_miku sort:score")
      assert.is_not_nil(f1.sort)
      assert.are.equal("score", f1.sort.key)
      assert.are.equal("desc", f1.sort.dir)
      assert.are.equal(1, #f1.positive_tags)
      assert.are.equal("hatsune_miku", f1.positive_tags[1])

      local f2 = local_query.parse_tags("sort:id:asc 1girl")
      assert.is_not_nil(f2.sort)
      assert.are.equal("id", f2.sort.key)
      assert.are.equal("asc", f2.sort.dir)
      assert.are.equal(1, #f2.positive_tags)
      assert.are.equal("1girl", f2.positive_tags[1])

      local f3 = local_query.parse_tags("sort:date")
      assert.is_not_nil(f3.sort)
      assert.are.equal("date", f3.sort.key)
      assert.are.equal("desc", f3.sort.dir)
      assert.are.equal(0, #f3.positive_tags)

      local f4 = local_query.parse_tags("sort:date:asc")
      assert.is_not_nil(f4.sort)
      assert.are.equal("date", f4.sort.key)
      assert.are.equal("asc", f4.sort.dir)
      assert.are.equal(0, #f4.positive_tags)

      local f5 = local_query.parse_tags("sort:random")
      assert.is_not_nil(f5.sort)
      assert.are.equal("random", f5.sort.key)
      assert.are.equal("asc", f5.sort.dir)
      assert.are.equal(0, #f5.positive_tags)

      local f6 = local_query.parse_tags("random")
      assert.is_not_nil(f6.sort)
      assert.are.equal("random", f6.sort.key)
      assert.are.equal("asc", f6.sort.dir)
      assert.are.equal(0, #f6.positive_tags)

      local f7 = local_query.parse_tags("order:score")
      assert.is_not_nil(f7.sort)
      assert.are.equal("score", f7.sort.key)
      assert.are.equal("desc", f7.sort.dir)
      assert.are.equal(0, #f7.positive_tags)

      local f8 = local_query.parse_tags("sort:score order:asc")
      assert.is_not_nil(f8.sort)
      assert.are.equal("score", f8.sort.key)
      assert.are.equal("asc", f8.sort.dir)
      assert.are.equal(0, #f8.positive_tags)
    end)

    it("ensures sort: tokens are strictly excluded from positive_tags", function()
      local f = local_query.parse_tags("solo sort:date -bad sort:score:asc")
      assert.are.equal(1, #f.positive_tags)
      assert.are.equal("solo", f.positive_tags[1])
      assert.are.equal(1, #f.negative_tags)
      assert.are.equal("bad", f.negative_tags[1])
      assert.is_not_nil(f.sort)
    end)

    it("sorts posts by score (desc and asc), falling back to cached JSON metadata when score is nil", function()
      local util = require("gelbooru.core.util")
      local cache_dir = vim.fn.tempname()
      vim.fn.mkdir(cache_dir, "p")
      local orig_cache_dir = config.options.cache_dir
      config.options.cache_dir = cache_dir

      -- Write cached metadata for post 202
      local meta_path = util.meta_cache_path("202")
      util.write_json(meta_path, { id = "202", score = 500 })

      local p1 = { id = "201", score = 100, file_url = tmp_dir .. "/201.jpg" }
      local p2 = { id = "202", score = nil, file_url = tmp_dir .. "/202.jpg" }
      local p3 = { id = "203", score = 300, file_url = tmp_dir .. "/203.jpg" }

      local posts = { p1, p2, p3 }
      local sorted_desc = local_query.sort_posts(posts, { key = "score", dir = "desc" })
      assert.are.equal("202", sorted_desc[1].id)
      assert.are.equal("203", sorted_desc[2].id)
      assert.are.equal("201", sorted_desc[3].id)

      local sorted_asc = local_query.sort_posts(posts, { key = "score", dir = "asc" })
      assert.are.equal("201", sorted_asc[1].id)
      assert.are.equal("203", sorted_asc[2].id)
      assert.are.equal("202", sorted_asc[3].id)

      config.options.cache_dir = orig_cache_dir
      vim.fn.delete(cache_dir, "rf")
    end)

    it("sorts posts by numeric ID (desc and asc)", function()
      local p1 = { id = "45", file_url = tmp_dir .. "/45.jpg" }
      local p2 = { id = "1002", file_url = tmp_dir .. "/1002.jpg" }
      local p3 = { id = "250", file_url = tmp_dir .. "/250.jpg" }

      local sorted_desc = local_query.sort_posts({ p1, p2, p3 }, { key = "id", dir = "desc" })
      assert.are.equal("1002", sorted_desc[1].id)
      assert.are.equal("250", sorted_desc[2].id)
      assert.are.equal("45", sorted_desc[3].id)

      local sorted_asc = local_query.sort_posts({ p1, p2, p3 }, { key = "id", dir = "asc" })
      assert.are.equal("45", sorted_asc[1].id)
      assert.are.equal("250", sorted_asc[2].id)
      assert.are.equal("1002", sorted_asc[3].id)
    end)

    it("sorts posts by date (mtime) using fs_stat and caches _mtime on posts", function()
      local f1 = tmp_dir .. "/f1.jpg"
      local f2 = tmp_dir .. "/f2.jpg"
      local f3 = tmp_dir .. "/f3.jpg"

      vim.fn.writefile({ "a" }, f1)
      local uv = vim.uv or vim.loop
      uv.fs_utime(f1, 1000, 1000)

      vim.fn.writefile({ "b" }, f2)
      uv.fs_utime(f2, 3000, 3000)

      vim.fn.writefile({ "c" }, f3)
      uv.fs_utime(f3, 2000, 2000)

      local p1 = { id = "1", file_url = f1 }
      local p2 = { id = "2", file_url = f2 }
      local p3 = { id = "3", file_url = f3 }

      local sorted_desc = local_query.sort_posts({ p1, p2, p3 }, { key = "date", dir = "desc" })
      assert.are.equal("2", sorted_desc[1].id)
      assert.are.equal("3", sorted_desc[2].id)
      assert.are.equal("1", sorted_desc[3].id)
      assert.are.equal(3000, p2._mtime)
      assert.are.equal(2000, p3._mtime)
      assert.are.equal(1000, p1._mtime)

      local sorted_asc = local_query.sort_posts({ p1, p2, p3 }, { key = "mtime", dir = "asc" })
      assert.are.equal("1", sorted_asc[1].id)
      assert.are.equal("3", sorted_asc[2].id)
      assert.are.equal("2", sorted_asc[3].id)
    end)

    it("sorts posts randomly using Fisher-Yates shuffle", function()
      local posts = {}
      for i = 1, 30 do
        posts[i] = { id = tostring(i), file_url = tmp_dir .. "/" .. i .. ".jpg" }
      end
      local shuffled = local_query.sort_posts(posts, { key = "random", dir = "asc" })
      assert.are.equal(30, #shuffled)
      local seen = {}
      for _, p in ipairs(shuffled) do
        seen[p.id] = true
      end
      for i = 1, 30 do
        assert.is_true(seen[tostring(i)])
      end
    end)

    it("filter_posts automatically applies sorting when sort directive is present", function()
      local p1 = { id = "1", score = 50, tags = "vocaloid miku", file_url = tmp_dir .. "/1.jpg" }
      local p2 = { id = "2", score = 200, tags = "vocaloid luka", file_url = tmp_dir .. "/2.jpg" }
      local p3 = { id = "3", score = 120, tags = "vocaloid rin", file_url = tmp_dir .. "/3.jpg" }

      local filtered = local_query.filter_posts({ p1, p2, p3 }, "vocaloid sort:score")
      assert.are.equal(3, #filtered)
      assert.are.equal("2", filtered[1].id)
      assert.are.equal("3", filtered[2].id)
      assert.are.equal("1", filtered[3].id)
    end)
  end)

  describe("Adversarial Test Suite: Local Queries, Filtering & Boundary Conditions", function()
    local local_query = require("gelbooru.local.query")

    it("tag word boundary matching: searching tag 'cat' does NOT match 'caterpillar' or 'scatter'", function()
      local post_caterpillar = {
        id = "1",
        file_url = tmp_dir .. "/1.jpg",
        tags = "caterpillar insect nature",
        is_local = true,
      }
      local post_scatter = {
        id = "2",
        file_url = tmp_dir .. "/2.jpg",
        tags = "scatter light prism",
        is_local = true,
      }
      local post_exact_cat = {
        id = "3",
        file_url = tmp_dir .. "/3.jpg",
        tags = "cat feline animal",
        is_local = true,
      }
      local post_compound_cat = {
        id = "4",
        file_url = tmp_dir .. "/4.jpg",
        tags = "black_cat cute",
        is_local = true,
      }

      assert.is_false(local_query.matches_post(post_caterpillar, "cat"))
      assert.is_false(local_query.matches_post(post_scatter, "cat"))
      assert.is_true(local_query.matches_post(post_exact_cat, "cat"))
      assert.is_true(local_query.matches_post(post_compound_cat, "cat"))
    end)

    it("negative tag precedence: -tag strictly excludes even when positive tag matched", function()
      local post_both = {
        id = "1",
        file_url = tmp_dir .. "/1.jpg",
        tags = "vocaloid hatsune_miku 1girl solo",
        is_local = true,
      }
      assert.is_true(local_query.matches_post(post_both, "vocaloid"))
      assert.is_false(local_query.matches_post(post_both, "-vocaloid"))
      assert.is_false(local_query.matches_post(post_both, "vocaloid -vocaloid"))
      assert.is_false(local_query.matches_post(post_both, "vocaloid 1girl -hatsune_miku"))
      assert.is_false(local_query.matches_post(post_both, "-solo vocaloid"))

      -- Negative tag on artist and character modifiers
      local post_meta = {
        id = "2",
        file_url = tmp_dir .. "/2.jpg",
        tags = "solo",
        artist = "kekeflipnote",
        character = "hatsune_miku",
        is_local = true,
      }
      assert.is_false(local_query.matches_post(post_meta, "-artist:kekeflipnote"))
      assert.is_false(local_query.matches_post(post_meta, "-character:hatsune_miku"))
      assert.is_true(local_query.matches_post(post_meta, "-artist:other_artist"))
    end)

    it("malformed queries with unclosed quotes and weird whitespace do not crash", function()
      -- Unclosed double quote
      local dir1, tags1, f1 = local_query.parse_query('local:"unclosed path tag')
      assert.is_not_nil(dir1)
      assert.is_not_nil(tags1)
      assert.is_table(f1)

      -- Unclosed single quote
      local dir2, tags2, f2 = local_query.parse_query("local:'unclosed path tag")
      assert.is_not_nil(dir2)
      assert.is_not_nil(tags2)
      assert.is_table(f2)

      -- Weird whitespace (tabs, multi-spaces, trailing spaces)
      local dir3, tags3, f3 = local_query.parse_query("local: \t \t /tmp \t \t tag1 \t tag2  ")
      assert.is_not_nil(dir3)
      assert.are.equal(2, #f3.positive_tags)
      assert.are.equal("tag1", f3.positive_tags[1])
      assert.are.equal("tag2", f3.positive_tags[2])

      -- Whitespace-only after local:
      local dir4, tags4, f4 = local_query.parse_query("local:    \t   ")
      assert.are.equal(config.options.save_dir, dir4)
      assert.are.equal("", tags4)
      assert.are.equal(0, #f4.positive_tags)
    end)

    it("handles special regex and lua pattern characters in tags without pattern errors", function()
      local regex_posts = {
        { id = "1", file_url = tmp_dir .. "/1.jpg", tags = "tag(1) anime", is_local = true },
        { id = "2", file_url = tmp_dir .. "/2.jpg", tags = "c++ programming code", is_local = true },
        { id = "3", file_url = tmp_dir .. "/3.jpg", tags = "foo.bar web", is_local = true },
        { id = "4", file_url = tmp_dir .. "/4.jpg", tags = "[brackets] square", is_local = true },
        { id = "5", file_url = tmp_dir .. "/5.jpg", tags = "* wildcard star", is_local = true },
        { id = "6", file_url = tmp_dir .. "/6.jpg", tags = "? question mark", is_local = true },
        { id = "7", file_url = tmp_dir .. "/7.jpg", tags = "%w lua pattern percent", is_local = true },
      }

      -- Positive matching
      assert.are.equal(1, #local_query.filter_posts(regex_posts, "tag(1)"))
      assert.are.equal(1, #local_query.filter_posts(regex_posts, "c++"))
      assert.are.equal(1, #local_query.filter_posts(regex_posts, "foo.bar"))
      assert.are.equal(1, #local_query.filter_posts(regex_posts, "[brackets]"))
      assert.are.equal(1, #local_query.filter_posts(regex_posts, "*"))
      assert.are.equal(1, #local_query.filter_posts(regex_posts, "?"))
      assert.are.equal(1, #local_query.filter_posts(regex_posts, "%w"))

      -- Negative matching
      assert.are.equal(6, #local_query.filter_posts(regex_posts, "-tag(1)"))
      assert.are.equal(6, #local_query.filter_posts(regex_posts, "-c++"))
      assert.are.equal(6, #local_query.filter_posts(regex_posts, "-[brackets]"))
      assert.are.equal(6, #local_query.filter_posts(regex_posts, "-*"))
      assert.are.equal(6, #local_query.filter_posts(regex_posts, "-?"))
      assert.are.equal(6, #local_query.filter_posts(regex_posts, "-%w"))
    end)

    it("boundary & invalid score filters: score:abc, score:>=, score:<, negative scores", function()
      local score_posts = {
        { id = "1", file_url = tmp_dir .. "/1.jpg", score = -15, is_local = true },
        { id = "2", file_url = tmp_dir .. "/2.jpg", score = -5, is_local = true },
        { id = "3", file_url = tmp_dir .. "/3.jpg", score = 0, is_local = true },
        { id = "4", file_url = tmp_dir .. "/4.jpg", score = 25, is_local = true },
        { id = "5", file_url = tmp_dir .. "/5.jpg", score = 100, is_local = true },
        { id = "6", file_url = tmp_dir .. "/6.jpg", score = nil, is_local = true }, -- missing score
        { id = "7", file_url = tmp_dir .. "/7.jpg", score = "not_num", is_local = true }, -- invalid score string
      }

      -- Negative score comparisons
      local lt_neg10 = local_query.filter_posts(score_posts, "score:<-10")
      assert.are.equal(1, #lt_neg10)
      assert.are.equal("1", lt_neg10[1].id)

      local lte_neg5 = local_query.filter_posts(score_posts, "score:<=-5")
      assert.are.equal(2, #lte_neg5)

      local gte_neg5 = local_query.filter_posts(score_posts, "score:>=-5")
      -- -5, 0, 25, 100, plus nil/not_num (default to 0 >= -5)
      assert.are.equal(6, #gte_neg5)

      -- Invalid score tokens (treated as non-matching plain tags, must not error)
      local invalid1 = local_query.filter_posts(score_posts, "score:abc")
      assert.are.equal(0, #invalid1)

      local invalid2 = local_query.filter_posts(score_posts, "score:>=")
      assert.are.equal(0, #invalid2)

      local invalid3 = local_query.filter_posts(score_posts, "score:<")
      assert.are.equal(0, #invalid3)
    end)

    it("handles missing, nil, or invalid ratings and ratings boundary filters", function()
      local rating_posts = {
        { id = "1", file_url = tmp_dir .. "/1.jpg", rating = "general", is_local = true },
        { id = "2", file_url = tmp_dir .. "/2.jpg", rating = "sensitive", is_local = true },
        { id = "3", file_url = tmp_dir .. "/3.jpg", rating = "questionable", is_local = true },
        { id = "4", file_url = tmp_dir .. "/4.jpg", rating = "explicit", is_local = true },
        { id = "5", file_url = tmp_dir .. "/5.jpg", rating = nil, is_local = true }, -- nil rating
        { id = "6", file_url = tmp_dir .. "/6.jpg", rating = "", is_local = true }, -- empty rating
        { id = "7", file_url = tmp_dir .. "/7.jpg", rating = "?", is_local = true }, -- unknown rating
      }

      -- rating:general matches only post 1 (nil/empty/? must not match)
      local gen_posts = local_query.filter_posts(rating_posts, "rating:general")
      assert.are.equal(1, #gen_posts)
      assert.are.equal("1", gen_posts[1].id)

      -- -rating:explicit must include all non-explicit posts, including posts with nil/empty/? rating
      local non_exp = local_query.filter_posts(rating_posts, "-rating:explicit")
      assert.are.equal(6, #non_exp)
      for _, p in ipairs(non_exp) do
        assert.are.not_equal("4", p.id)
      end

      -- Invalid rating filter doesn't crash
      local invalid_r = local_query.filter_posts(rating_posts, "rating:xyz")
      assert.are.equal(0, #invalid_r)
    end)

    it("filename tokenization edge cases: multiple dots, unicode, special chars, multiple underscores", function()
      local filename_posts = {
        {
          id = nil,
          file_url = tmp_dir .. "/my...sample...vocaloid...art.png",
          tags = "local",
          is_local = true,
        },
        {
          id = nil,
          file_url = tmp_dir .. "/solo___duet---dance.jpg",
          tags = "local",
          is_local = true,
        },
        {
          id = nil,
          file_url = tmp_dir .. "/初音ミク_sing.png",
          tags = "local",
          is_local = true,
        },
        {
          id = nil,
          file_url = tmp_dir .. "/tagged_override.png",
          tags = "cat dog",
          is_local = true,
        },
      }

      -- Multiple dots tokenization
      assert.are.equal(1, #local_query.filter_posts(filename_posts, "vocaloid"))

      -- Multiple underscores and dashes tokenization
      assert.are.equal(1, #local_query.filter_posts(filename_posts, "dance"))
      assert.are.equal(1, #local_query.filter_posts(filename_posts, "duet"))

      -- Tagged image does not use filename fallback when booru tags are present
      assert.are.equal(1, #local_query.filter_posts(filename_posts, "cat"))

      -- Unicode filename tokenization: searching '初音ミク'
      -- In booru/local search, searching unicode tag should match file stem containing that unicode word
      local miku_matches = local_query.filter_posts(filename_posts, "初音ミク")
      assert.are.equal(1, #miku_matches)
    end)

    it("handles corrupt post records safely (nil post, missing fields, non-string tags)", function()
      -- Nil post
      assert.is_false(local_query.matches_post(nil, "cat"))
      assert.are.same({}, local_query.filter_posts(nil, "cat"))

      -- Empty post table
      assert.is_true(local_query.matches_post({}, ""))

      -- Missing file_url
      local post_no_url = { id = "1", tags = "miku" }
      assert.is_true(local_query.matches_post(post_no_url, "miku"))
      assert.is_false(local_query.matches_post(post_no_url, "dance"))

      -- Nil tags string
      local post_nil_tags = { id = "2", file_url = tmp_dir .. "/solo_art.png", tags = nil }
      assert.is_true(local_query.matches_post(post_nil_tags, "solo"))
    end)

    it("QA 1: prevents local substring hijack on is_local:true, -local:tag, nonlocal:tag", function()
      local util = require("gelbooru.core.util")
      assert.is_false(util.is_local_query("is_local:true"))
      assert.is_false(util.is_local_query("-local:tag"))
      assert.is_false(util.is_local_query("nonlocal:tag"))
      assert.is_false(util.is_local_query("my_local:folder"))

      assert.is_true(util.is_local_query("local: /tmp"))
      assert.is_true(util.is_local_query("solo local:"))
      assert.is_true(util.is_local_query("tag1 | local: tag2"))
      assert.is_true(util.is_local_query("local:~/Downloads"))
    end)

    it("QA 2: case-insensitive rating prefix: Rating:general and RATING:q,e parse and match properly", function()
      local f = local_query.parse_tags("Rating:general RATING:q,e -Rating:s")
      assert.are.equal(4, #f.ratings)
      assert.are.equal("general", f.ratings[1].val)
      assert.are.equal("questionable", f.ratings[2].val)
      assert.are.equal("explicit", f.ratings[3].val)
      assert.are.equal("sensitive", f.ratings[4].val)
      assert.are.equal("neq", f.ratings[4].op)

      local p_gen = { id = "1", rating = "general" }
      local p_exp = { id = "2", rating = "explicit" }
      local p_sens = { id = "3", rating = "sensitive" }
      local p_other = { id = "4", rating = "questionable" }

      assert.is_true(local_query.matches_post(p_gen, f))
      assert.is_true(local_query.matches_post(p_exp, f))
      assert.is_false(local_query.matches_post(p_sens, f))
      assert.is_true(local_query.matches_post(p_other, f))
    end)

    it("QA 4: malformed OR input (empty tildes, trailing pipes, double pipes) handled cleanly", function()
      local f1 = local_query.parse_tags("~ ~~ ~|~ || |")
      assert.are.equal(0, #f1.or_tags)

      local f2 = local_query.parse_tags("tag1||tag2 tag3| |tag4 ~~~tag5")
      assert.are.equal(5, #f2.or_tags)
      assert.are.equal("tag1", f2.or_tags[1])
      assert.are.equal("tag2", f2.or_tags[2])
      assert.are.equal("tag3", f2.or_tags[3])
      assert.are.equal("tag4", f2.or_tags[4])
      assert.are.equal("tag5", f2.or_tags[5])

      local posts = {
        { id = "1", tags = "tag2 solo" },
        { id = "2", tags = "other solo" },
      }
      local matched = local_query.filter_posts(posts, f2)
      assert.are.equal(1, #matched)
      assert.are.equal("1", matched[1].id)
    end)

    it("QA 5: multi-clause OR grouping behavior (a|b c|d)", function()
      local f = local_query.parse_tags("a|b c|d")
      assert.are.equal(4, #f.or_tags)
      assert.are.equal("a", f.or_tags[1])
      assert.are.equal("b", f.or_tags[2])
      assert.are.equal("c", f.or_tags[3])
      assert.are.equal("d", f.or_tags[4])

      local p_a = { id = "1", tags = "a extra" }
      local p_d = { id = "2", tags = "d extra" }
      local p_none = { id = "3", tags = "z extra" }

      assert.is_true(local_query.matches_post(p_a, f))
      assert.is_true(local_query.matches_post(p_d, f))
      assert.is_false(local_query.matches_post(p_none, f))
    end)

    it("QA 6: single-quoted directory paths with spaces in local queries", function()
      local dir1, tags1 = local_query.parse_query("local:'/path with spaces/folder' tag1")
      assert.are.equal("/path with spaces/folder", dir1)
      assert.are.equal("tag1", tags1)

      local dir2, tags2 = local_query.parse_query("tag1 local:'/path with spaces/folder' tag2")
      assert.are.equal("/path with spaces/folder", dir2)
      assert.are.equal("tag1 tag2", tags2)
    end)

    it("QA 7: post sorting stability with 200 tied / all-nil records without Lua strict weak ordering errors", function()
      local posts = {}
      for i = 1, 200 do
        posts[i] = { id = nil, score = nil, _mtime = nil, file_url = nil }
      end

      -- Should execute with 0 errors across all sort modes
      assert.has_no.errors(function()
        local_query.sort_posts(posts, { key = "score", dir = "desc" })
      end)
      assert.are.equal(200, #posts)

      assert.has_no.errors(function()
        local_query.sort_posts(posts, { key = "date", dir = "asc" })
      end)
      assert.are.equal(200, #posts)

      assert.has_no.errors(function()
        local_query.sort_posts(posts, {
          { key = "score", dir = "desc" },
          { key = "date", dir = "asc" },
        })
      end)
      assert.are.equal(200, #posts)
    end)

    it("QA 8: negative rating filter retains unhydrated local posts (-rating:explicit)", function()
      local p_unhydrated = { id = "1", rating = nil, tags = "local" }
      local p_explicit = { id = "2", rating = "explicit", tags = "local" }
      local p_general = { id = "3", rating = "general", tags = "local" }

      -- Negative rating: unhydrated post is not explicit, so it is retained
      local f_neg = local_query.parse_tags("-rating:explicit")
      assert.is_true(local_query.matches_post(p_unhydrated, f_neg))
      assert.is_false(local_query.matches_post(p_explicit, f_neg))
      assert.is_true(local_query.matches_post(p_general, f_neg))

      -- Positive rating: unhydrated post does not have general rating, so it is rejected
      local f_pos = local_query.parse_tags("rating:general")
      assert.is_false(local_query.matches_post(p_unhydrated, f_pos))
      assert.is_true(local_query.matches_post(p_general, f_pos))
    end)

    it("QA 9: component word matching in booru tags and artist credits (~focus, ~balk)", function()
      local post = {
        id = "1",
        tags = "foot_focus 1girl",
        artist = "balk_art",
        is_local = true,
      }

      local f1 = local_query.parse_tags("~focus ~unrelated")
      assert.is_true(local_query.matches_post(post, f1))

      local f2 = local_query.parse_tags("~balk ~unrelated")
      assert.is_true(local_query.matches_post(post, f2))

      local f3 = local_query.parse_tags("~nomatch ~unrelated")
      assert.is_false(local_query.matches_post(post, f3))
    end)

    it("QA 10: secondary sort fallback on unknown keys", function()
      local p1 = { id = "10", score = 20 }
      local p2 = { id = "20", score = 50 }
      local p3 = { id = "30", score = 10 }

      -- Fallback when primary key is unknown: uses secondary stage score:desc
      local sorted = local_query.sort_posts({ p1, p2, p3 }, {
        { key = "unknown_stage", dir = "desc" },
        { key = "score", dir = "desc" },
      })
      assert.are.equal("20", sorted[1].id)
      assert.are.equal("10", sorted[2].id)
      assert.are.equal("30", sorted[3].id)

      -- Fallback when all keys are unknown: deterministic ID desc
      local sorted_fallback = local_query.sort_posts({ p1, p2, p3 }, { key = "nonexistent", dir = "asc" })
      assert.are.equal("30", sorted_fallback[1].id)
      assert.are.equal("20", sorted_fallback[2].id)
      assert.are.equal("10", sorted_fallback[3].id)
    end)

    it("-video excludes video posts in matches_post and filter_posts", function()
      local p_video = { id = "1", tags = "video solo 1girl", file_url = "/media/1.mp4", is_local = true }
      local p_image = { id = "2", tags = "solo 1girl", file_url = "/media/2.jpg", is_local = true }
      local p_anim = { id = "3", tags = "video vocaloid", file_url = "/media/3.webm", is_local = true }

      -- matches_post check
      assert.is_false(local_query.matches_post(p_video, "-video"))
      assert.is_true(local_query.matches_post(p_image, "-video"))
      assert.is_false(local_query.matches_post(p_anim, "-video"))

      -- filter_posts check
      local filtered = local_query.filter_posts({ p_video, p_image, p_anim }, "-video")
      assert.are.equal(1, #filtered)
      assert.are.equal("2", filtered[1].id)

      -- Positive video check
      local vid_only = local_query.filter_posts({ p_video, p_image, p_anim }, "video")
      assert.are.equal(2, #vid_only)
      assert.are.equal("1", vid_only[1].id)
      assert.are.equal("3", vid_only[2].id)
    end)
  end)
end)

describe("local.index: Saved Index & Directory Mtime Cache", function()
  local local_index = require("gelbooru.local.index")
  local tmp_dir
  local orig_save_dir

  before_each(function()
    local_index.reset()
    state.State.saved_index = {}
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    orig_save_dir = config.options.save_dir
    config.options.save_dir = tmp_dir
  end)

  after_each(function()
    local_index.reset()
    config.options.save_dir = orig_save_dir
    if tmp_dir and vim.fn.isdirectory(tmp_dir) == 1 then
      vim.fn.delete(tmp_dir, "rf")
    end
  end)

  it("update_saved_index scans directory and builds saved_index with file extensions", function()
    vim.fn.writefile({ "a" }, tmp_dir .. "/11001.jpg")
    vim.fn.writefile({ "b" }, tmp_dir .. "/11002.png")
    vim.fn.writefile({ "c" }, tmp_dir .. "/post_1003.webp")
    vim.fn.writefile({ "d" }, tmp_dir .. "/artwork_no_id.jpg")
    vim.fn.writefile({ "e" }, tmp_dir .. "/notes.txt")

    local idx = local_index.update_saved_index(tmp_dir)

    assert.is_table(idx)
    assert.are.equal("jpg", idx[11001])
    assert.are.equal("png", idx[11002])
    assert.are.equal("webp", idx[1003])
    assert.is_nil(idx["artwork_no_id"])
    assert.is_nil(idx["notes"])
    assert.is_true(local_index.is_saved(11001))
    assert.is_true(local_index.is_saved("11002"))
    assert.is_true(local_index.is_saved(1003))
    assert.is_false(local_index.is_saved(9999))
  end)

  it("caches directory mtime and does not re-scan disk when mtime is unchanged", function()
    vim.fn.writefile({ "a" }, tmp_dir .. "/15001.jpg")

    local_index.update_saved_index(tmp_dir)
    assert.is_true(local_index.is_saved(15001))

    local uv = vim.uv or vim.loop
    local orig_fs_scandir = uv.fs_scandir
    local scandir_called = false
    uv.fs_scandir = function(...)
      scandir_called = true
      return orig_fs_scandir(...)
    end

    local idx2 = local_index.update_saved_index(tmp_dir)
    uv.fs_scandir = orig_fs_scandir

    assert.is_false(scandir_called)
    assert.are.equal("jpg", idx2[15001])
  end)

  it("detects newly added files when directory mtime changes", function()
    vim.fn.writefile({ "a" }, tmp_dir .. "/16001.jpg")
    local_index.update_saved_index(tmp_dir)
    assert.is_true(local_index.is_saved(16001))
    assert.is_false(local_index.is_saved(16002))

    vim.fn.writefile({ "b" }, tmp_dir .. "/16002.png")
    local uv = vim.uv or vim.loop
    local stat = uv.fs_stat(tmp_dir)
    local cur_sec = stat and stat.mtime and (stat.mtime.sec or stat.mtime) or os.time()
    pcall(uv.fs_utime, tmp_dir, cur_sec + 2, cur_sec + 2)

    local idx2 = local_index.update_saved_index(tmp_dir)
    assert.is_true(local_index.is_saved(16001))
    assert.is_true(local_index.is_saved(16002))
    assert.are.equal("png", idx2[16002])
  end)

  it("mark_saved updates saved_index immediately and refreshes mtime to prevent redundant rescan", function()
    vim.fn.writefile({ "a" }, tmp_dir .. "/7001.jpg")
    local_index.update_saved_index(tmp_dir)

    local_index.mark_saved(7002, "png")
    assert.is_true(local_index.is_saved(7002))
    assert.is_true(local_index.is_saved("7002"))
    assert.are.equal("png", state.State.saved_index[7002])

    local_index.mark_saved("7003")
    assert.is_true(local_index.is_saved(7003))
    assert.are.equal("jpg", state.State.saved_index[7003])
  end)

  it("is_saved and mark_saved safely handle nil, empty, or non-numeric IDs", function()
    assert.is_false(local_index.is_saved(nil))
    assert.is_false(local_index.is_saved(""))
    assert.is_false(local_index.is_saved("not_a_number"))

    local_index.mark_saved(nil, "jpg")
    local_index.mark_saved("", "jpg")
    local_index.mark_saved("not_a_number", "jpg")

    assert.is_false(local_index.is_saved(nil))
  end)

  it("handles nil, empty string, or non-existent directories gracefully", function()
    local idx_nil = local_index.update_saved_index(nil)
    assert.is_table(idx_nil)

    local idx_empty = local_index.update_saved_index("")
    assert.is_table(idx_empty)

    local idx_missing = local_index.update_saved_index(tmp_dir .. "/does_not_exist")
    assert.is_table(idx_missing)
  end)

  it("reset clears all cached state and saved_index", function()
    local_index.mark_saved(8001, "jpg")
    assert.is_true(local_index.is_saved(8001))

    local_index.reset()
    assert.is_false(local_index.is_saved(8001))
    assert.are.same({}, state.State.saved_index)
  end)
end)

describe("local.indexer: Dual-Tier Lookahead Prefetch & Background Indexing", function()
  local indexer = require("gelbooru.local.indexer")
  local api = require("gelbooru.net.api")
  local orig_fetch_post_metadata
  local orig_prefetch_radius

  before_each(function()
    indexer.stop()
    orig_fetch_post_metadata = api.fetch_post_metadata
    orig_prefetch_radius = config.options.prefetch_radius
    state.State.torn_down = false
  end)

  after_each(function()
    indexer.stop()
    api.fetch_post_metadata = orig_fetch_post_metadata
    config.options.prefetch_radius = orig_prefetch_radius
    state.State.torn_down = false
  end)

  describe("Tier 1: cursor_rush_prefetch", function()
    it("prefetches adjacent posts in forward scroll direction within radius", function()
      local fetched_ids = {}
      api.fetch_post_metadata = function(p, cb)
        table.insert(fetched_ids, p.id)
        p._metadata_fetched = true
        if cb then cb(p) end
      end

      state.State.posts = {
        { id = "101", is_local = true },
        { id = "102", is_local = true },
        { id = "103", is_local = true },
        { id = "104", is_local = true },
        { id = "105", is_local = true },
        { id = "106", is_local = true },
      }
      state.State.cur = 1
      state.State.scroll_dir = 1
      config.options.prefetch_radius = 3

      indexer.cursor_rush_prefetch(1, 1)

      assert.are.same({ "102", "103", "104" }, fetched_ids)
    end)

    it("prefetches adjacent posts in backward scroll direction within radius", function()
      local fetched_ids = {}
      api.fetch_post_metadata = function(p, cb)
        table.insert(fetched_ids, p.id)
        p._metadata_fetched = true
        if cb then cb(p) end
      end

      state.State.posts = {
        { id = "201", is_local = true },
        { id = "202", is_local = true },
        { id = "203", is_local = true },
        { id = "204", is_local = true },
        { id = "205", is_local = true },
      }
      state.State.cur = 5
      state.State.scroll_dir = -1
      config.options.prefetch_radius = 3

      indexer.cursor_rush_prefetch(5, -1)

      assert.are.same({ "204", "203", "202" }, fetched_ids)
    end)

    it("clamps radius between 3 and 5 and defaults scroll_dir 0 to 1", function()
      local fetched_ids = {}
      api.fetch_post_metadata = function(p, cb)
        table.insert(fetched_ids, p.id)
        p._metadata_fetched = true
        if cb then cb(p) end
      end

      local posts = {}
      for i = 1, 10 do
        table.insert(posts, { id = tostring(300 + i), is_local = true })
      end
      state.State.posts = posts

      config.options.prefetch_radius = 1
      indexer.cursor_rush_prefetch(1, 0)
      assert.are.equal(3, #fetched_ids)

      for _, p in ipairs(posts) do
        p._metadata_fetched = nil
      end
      fetched_ids = {}
      config.options.prefetch_radius = 10
      indexer.cursor_rush_prefetch(1, 1)
      assert.are.equal(5, #fetched_ids)
    end)

    it("skips posts that are already fetched or currently loading", function()
      local fetched_ids = {}
      api.fetch_post_metadata = function(p, cb)
        table.insert(fetched_ids, p.id)
        if cb then cb(p) end
      end

      state.State.posts = {
        { id = "401", is_local = true },
        { id = "402", is_local = true, _metadata_fetched = true },
        { id = "403", is_local = true, _metadata_loading = true },
        { id = "404", is_local = true },
        { id = "405", is_local = true, id = nil },
      }
      config.options.prefetch_radius = 4

      indexer.cursor_rush_prefetch(1, 1)

      assert.are.same({ "404" }, fetched_ids)
    end)

    it("aborts when State.torn_down is true or posts list is empty", function()
      local called = false
      api.fetch_post_metadata = function() called = true end

      state.State.torn_down = true
      state.State.posts = { { id = "501", is_local = true } }
      indexer.cursor_rush_prefetch(1, 1)
      assert.is_false(called)

      state.State.torn_down = false
      state.State.posts = {}
      indexer.cursor_rush_prefetch(1, 1)
      assert.is_false(called)
    end)
  end)

  describe("Tier 2: start_background_indexing & Pacing", function()
    it("starts background indexing, throttling concurrency to MAX_CONCURRENT (2) with 100ms pacing", function()
      local requests = {}
      local callbacks = {}
      api.fetch_post_metadata = function(p, cb)
        table.insert(requests, p.id)
        table.insert(callbacks, cb)
      end

      local test_posts = {
        { id = "601", is_local = true },
        { id = "602", is_local = true },
        { id = "603", is_local = true },
        { id = "604", is_local = true },
      }

      indexer.start_background_indexing(test_posts)

      assert.is_not_nil(state.UI.indexer_timer)

      indexer._tick()
      assert.are.equal(1, #requests)
      assert.are.equal("601", requests[1])

      indexer._tick()
      assert.are.equal(2, #requests)
      assert.are.equal("602", requests[2])

      indexer._tick()
      assert.are.equal(2, #requests)

      local cb1 = table.remove(callbacks, 1)
      test_posts[1]._metadata_fetched = true
      cb1(test_posts[1])

      indexer._tick()
      assert.are.equal(3, #requests)
      assert.are.equal("603", requests[3])

      indexer.stop()
    end)

    it("skips non-local posts, posts without IDs, and posts already fetched", function()
      local requests = {}
      api.fetch_post_metadata = function(p, cb)
        table.insert(requests, p.id)
        if cb then cb(p) end
      end

      local mixed_posts = {
        { id = "701", is_local = false },
        { id = nil, is_local = true },
        { id = "703", is_local = true, _metadata_fetched = true },
        { id = "704", is_local = true, _metadata_loading = true },
        { id = "705", is_local = true },
      }

      indexer.start_background_indexing(mixed_posts)
      indexer._tick()

      assert.are.same({ "705" }, requests)
      indexer.stop()
    end)

    it("indexer.stop cleans up timer, resets workers and queue, and is idempotent", function()
      local test_posts = {
        { id = "801", is_local = true },
        { id = "802", is_local = true },
      }

      indexer.start_background_indexing(test_posts)
      assert.is_not_nil(state.UI.indexer_timer)

      indexer.stop()
      assert.is_nil(state.UI.indexer_timer)

      indexer.stop()
      indexer.abort()
      assert.is_nil(state.UI.indexer_timer)
    end)

    it("handles worker failure (cb called with nil) without leaking worker count", function()
      local requests = {}
      api.fetch_post_metadata = function(p, cb)
        table.insert(requests, p.id)
        vim.schedule(function()
          p._metadata_fetched = true
          if cb then cb(nil) end
        end)
      end

      local test_posts = {
        { id = "901", is_local = true },
        { id = "902", is_local = true },
      }

      indexer.start_background_indexing(test_posts)
      indexer._tick()
      assert.are.equal(1, #requests)

      vim.wait(100, function() return test_posts[1]._metadata_fetched end, 10)

      indexer._tick()
      assert.are.equal(2, #requests)
      assert.are.equal("902", requests[2])

      indexer.stop()
    end)
  end)
end)

describe("Multi-Stage Piped Sorting Pipeline (parse_pipeline & execute_pipeline)", function()
  local local_query = require("gelbooru.local.query")

  describe("query.parse_pipeline", function()
    it("parses empty or nil input to empty base_query and empty stages", function()
      local p1 = local_query.parse_pipeline(nil)
      assert.are.equal("", p1.base_query)
      assert.are.same({}, p1.stages)

      local p2 = local_query.parse_pipeline("")
      assert.are.equal("", p2.base_query)
      assert.are.same({}, p2.stages)

      local p3 = local_query.parse_pipeline("   ")
      assert.are.equal("", p3.base_query)
      assert.are.same({}, p3.stages)
    end)

    it("parses queries without pipes to base_query with empty stages", function()
      local p1 = local_query.parse_pipeline("hatsune_miku rating:general")
      assert.are.equal("hatsune_miku rating:general", p1.base_query)
      assert.are.same({}, p1.stages)

      local p2 = local_query.parse_pipeline("local:/path/to/folder solo")
      assert.are.equal("local:/path/to/folder solo", p2.base_query)
      assert.are.same({}, p2.stages)
    end)

    it("parses multi-stage pipe syntax for local and online queries", function()
      -- Example local bare
      local p1 = local_query.parse_pipeline("local: | sort:id:1000 | sort:score:300 | sort:random")
      assert.are.equal("local:", p1.base_query)
      assert.are.equal(3, #p1.stages)
      assert.are.same({ key = "id", dir = "desc", limit = 1000 }, p1.stages[1])
      assert.are.same({ key = "score", dir = "desc", limit = 300 }, p1.stages[2])
      assert.are.same({ key = "random", dir = "asc", limit = nil }, p1.stages[3])

      -- Example local with tags
      local p2 = local_query.parse_pipeline("local: ~foot_focus ~soles | sort:id:1000 | sort:score:300 | sort:random")
      assert.are.equal("local: ~foot_focus ~soles", p2.base_query)
      assert.are.equal(3, #p2.stages)
      assert.are.same({ key = "id", dir = "desc", limit = 1000 }, p2.stages[1])
      assert.are.same({ key = "score", dir = "desc", limit = 300 }, p2.stages[2])
      assert.are.same({ key = "random", dir = "asc", limit = nil }, p2.stages[3])

      -- Example online single tag
      local p3 = local_query.parse_pipeline("hatsune_miku | sort:id:1000 | sort:score:300 | sort:random")
      assert.are.equal("hatsune_miku", p3.base_query)
      assert.are.equal(3, #p3.stages)
      assert.are.same({ key = "id", dir = "desc", limit = 1000 }, p3.stages[1])
      assert.are.same({ key = "score", dir = "desc", limit = 300 }, p3.stages[2])
      assert.are.same({ key = "random", dir = "asc", limit = nil }, p3.stages[3])

      -- Example online multi tags
      local p4 = local_query.parse_pipeline("solo twintails | sort:id:500 | sort:score:100 | sort:random")
      assert.are.equal("solo twintails", p4.base_query)
      assert.are.equal(3, #p4.stages)
      assert.are.same({ key = "id", dir = "desc", limit = 500 }, p4.stages[1])
      assert.are.same({ key = "score", dir = "desc", limit = 100 }, p4.stages[2])
      assert.are.same({ key = "random", dir = "asc", limit = nil }, p4.stages[3])
    end)

    it("parses directives with various key, dir, limit formats", function()
      -- sort:<key>:<dir>:<limit>
      local p1 = local_query.parse_pipeline("tag | sort:score:asc:250")
      assert.are.same({ { key = "score", dir = "asc", limit = 250 } }, p1.stages)

      -- sort:<key>:<limit>:<dir>
      local p2 = local_query.parse_pipeline("tag | sort:score:250:asc")
      assert.are.same({ { key = "score", dir = "asc", limit = 250 } }, p2.stages)

      -- sort:<key>:<dir>
      local p3 = local_query.parse_pipeline("tag | sort:id:asc")
      assert.are.same({ { key = "id", dir = "asc", limit = nil } }, p3.stages)

      -- sort:<key> (default desc)
      local p4 = local_query.parse_pipeline("tag | sort:score")
      assert.are.same({ { key = "score", dir = "desc", limit = nil } }, p4.stages)

      -- sort:date and sort:mtime
      local p5 = local_query.parse_pipeline("tag | sort:date:50 | sort:mtime:asc:25")
      assert.are.same({
        { key = "date", dir = "desc", limit = 50 },
        { key = "mtime", dir = "asc", limit = 25 },
      }, p5.stages)

      -- order:random, sort:random, random, limit:N
      local p6 = local_query.parse_pipeline("tag | order:random | random | limit:42")
      assert.are.same({
        { key = "random", dir = "asc", limit = nil },
        { key = "random", dir = "asc", limit = nil },
        { key = nil, dir = nil, limit = 42 },
      }, p6.stages)
    end)

    it("handles case-insensitivity, leading pipes, and quoted paths cleanly", function()
      local p1 = local_query.parse_pipeline("TAG | sort:ID:ASC:100 | sort:SCORE:DESC:50 | sort:RANDOM")
      assert.are.same({
        { key = "id", dir = "asc", limit = 100 },
        { key = "score", dir = "desc", limit = 50 },
        { key = "random", dir = "asc", limit = nil },
      }, p1.stages)

      -- Leading pipe without base query
      local p2 = local_query.parse_pipeline("| sort:id:1000 | sort:score:300")
      assert.are.equal("", p2.base_query)
      assert.are.equal(2, #p2.stages)

      -- Intra-token pipe preserved as base query, not stage delimiter
      local p3 = local_query.parse_pipeline("foot_focus|soles | sort:id:1000")
      assert.are.equal("foot_focus|soles", p3.base_query)
      assert.are.same({ { key = "id", dir = "desc", limit = 1000 } }, p3.stages)

      -- Pipe inside quotes preserved
      local p4 = local_query.parse_pipeline('local:"/path with | pipe" | sort:score:100')
      assert.are.equal('local:"/path with | pipe"', p4.base_query)
      assert.are.same({ { key = "score", dir = "desc", limit = 100 } }, p4.stages)
    end)

    it("preserves 'random' as base_query when not prefixed with pipe or sort/order/limit directive", function()
      local p = local_query.parse_pipeline("random | sort:score:100")
      assert.are.equal("random", p.base_query)
      assert.are.equal(1, #p.stages)
      assert.are.same({ key = "score", dir = "desc", limit = 100 }, p.stages[1])
    end)

    it("rejects malformed ghost stages such as sort:: returning original query with 0 stages", function()
      local p = local_query.parse_pipeline("tag | sort::")
      assert.are.equal("tag | sort::", p.base_query)
      assert.are.equal(0, #p.stages)
    end)

    it("parses zenless_zone_zero sort:id:1000|sort:score:200|sort:random -video preserving base_query and 3 stages", function()
      local p = local_query.parse_pipeline("zenless_zone_zero sort:id:1000|sort:score:200|sort:random -video")
      assert.are.equal("zenless_zone_zero -video", p.base_query)
      assert.are.equal(3, #p.stages)
      assert.are.same({ key = "id", dir = "desc", limit = 1000 }, p.stages[1])
      assert.are.same({ key = "score", dir = "desc", limit = 200 }, p.stages[2])
      assert.are.same({ key = "random", dir = "asc", limit = nil }, p.stages[3])

      -- Variations with whitespace or lack thereof
      local p_spaced = local_query.parse_pipeline("zenless_zone_zero sort:id:1000 | sort:score:200 | sort:random -video")
      assert.are.equal("zenless_zone_zero -video", p_spaced.base_query)
      assert.are.equal(3, #p_spaced.stages)
      assert.are.same({ key = "id", dir = "desc", limit = 1000 }, p_spaced.stages[1])
      assert.are.same({ key = "score", dir = "desc", limit = 200 }, p_spaced.stages[2])
      assert.are.same({ key = "random", dir = "asc", limit = nil }, p_spaced.stages[3])

      -- Comma-separated sort stages: tag | sort:score:desc,date:desc
      local p_comma = local_query.parse_pipeline("tag | sort:score:desc,date:desc")
      assert.are.equal("tag", p_comma.base_query)
      assert.are.equal(2, #p_comma.stages)
      assert.are.same({ key = "score", dir = "desc", limit = nil }, p_comma.stages[1])
      assert.are.same({ key = "date", dir = "desc", limit = nil }, p_comma.stages[2])

      -- Standalone single sort without limit and without pipe preserves standard paginated online browsing
      local p_single = local_query.parse_pipeline("solo sort:score")
      assert.are.equal("solo sort:score", p_single.base_query)
      assert.are.equal(0, #p_single.stages)
    end)
  end)

  describe("query.execute_pipeline", function()
    it("pure limit:N stage without sort key slices array without reordering elements", function()
      local posts = {
        { id = "1", score = 10 },
        { id = "2", score = 50 },
        { id = "3", score = 20 },
        { id = "4", score = 40 },
        { id = "5", score = 30 },
      }
      local sliced = local_query.execute_pipeline(posts, { { limit = 3 } })
      assert.are.equal(3, #sliced)
      assert.are.equal("1", sliced[1].id)
      assert.are.equal("2", sliced[2].id)
      assert.are.equal("3", sliced[3].id)
    end)
    it("verifies 1500 posts -> sort:id:1000 -> sort:score:300 -> sort:random sequentially", function()
      local posts = {}
      for i = 1, 1500 do
        posts[i] = {
          id = tostring(i),
          -- Older posts (1..500) have very high scores (1000+), but should be dropped by Stage 1 (sort:id:1000)
          score = (i <= 500) and (1000 + i) or (i % 500),
          file_url = string.format("/media/%d.jpg", i),
        }
      end

      local stages = {
        { key = "id", dir = "desc", limit = 1000 },
        { key = "score", dir = "desc", limit = 300 },
        { key = "random", dir = "asc" },
      }

      local result = local_query.execute_pipeline(posts, stages)

      -- 1. Result count must be exactly 300
      assert.are.equal(300, #result)

      -- 2. Because Stage 1 kept only newest 1000 (IDs 501..1500), NONE of posts 1..500 should be present
      for _, p in ipairs(result) do
        local id_num = tonumber(p.id)
        assert.is_true(id_num >= 501 and id_num <= 1500, "Post ID should be between 501 and 1500, got: " .. tostring(id_num))
      end

      -- 3. Verify that the 300 posts are the highest scored among the candidate pool (IDs 501..1500)
      local pool_scores = {}
      for i = 501, 1500 do
        table.insert(pool_scores, i % 500)
      end
      table.sort(pool_scores, function(a, b) return a > b end)
      local min_expected_score = pool_scores[300]

      for _, p in ipairs(result) do
        assert.is_true(tonumber(p.score) >= min_expected_score)
      end

      -- 4. Verify randomized presentation (not strictly sorted by score desc anymore)
      local is_strictly_score_desc = true
      for i = 1, #result - 1 do
        if tonumber(result[i].score) < tonumber(result[i + 1].score) then
          is_strictly_score_desc = false
          break
        end
      end
      assert.is_false(is_strictly_score_desc)
    end)

    it("verifies slicing limits, ascending/descending, and deterministic tie-breaking", function()
      local p1 = { id = "10", score = 50, _mtime = 1000, file_url = "/b.jpg" }
      local p2 = { id = "20", score = 100, _mtime = 3000, file_url = "/a.jpg" }
      local p3 = { id = "30", score = 50, _mtime = 2000, file_url = "/c.jpg" }
      local p4 = { id = "40", score = 25, _mtime = 500, file_url = "/d.jpg" }

      -- Ascending score with limit 2
      local r_asc = local_query.execute_pipeline({ p1, p2, p3, p4 }, {
        { key = "score", dir = "asc", limit = 2 },
      })
      assert.are.equal(2, #r_asc)
      assert.are.equal("40", r_asc[1].id) -- score 25
      assert.is_true(r_asc[2].id == "30" or r_asc[2].id == "10") -- score 50

      -- Descending ID with limit 3
      local r_id_desc = local_query.execute_pipeline({ p1, p2, p3, p4 }, {
        { key = "id", dir = "desc", limit = 3 },
      })
      assert.are.equal(3, #r_id_desc)
      assert.are.equal("40", r_id_desc[1].id)
      assert.are.equal("30", r_id_desc[2].id)
      assert.are.equal("20", r_id_desc[3].id)

      -- Limit larger than count preserves all
      local r_large = local_query.execute_pipeline({ p1, p2 }, { { limit = 100 } })
      assert.are.equal(2, #r_large)

      -- Deterministic tie-breaking on equal scores: primary score desc, secondary tie-break by ID desc
      local tie1 = { id = "10", score = 50, file_url = "/x.jpg" }
      local tie2 = { id = "20", score = 50, file_url = "/y.jpg" }
      local r_tie = local_query.execute_pipeline({ tie1, tie2 }, {
        { key = "score", dir = "desc" },
      })
      assert.are.equal("20", r_tie[1].id)
      assert.are.equal("10", r_tie[2].id)
    end)

    it("filter_posts automatically executes multi-stage pipeline when pipe syntax is passed", function()
      local p1 = { id = "100", score = 10, tags = "miku solo", file_url = "/100.jpg" }
      local p2 = { id = "200", score = 90, tags = "miku solo", file_url = "/200.jpg" }
      local p3 = { id = "300", score = 50, tags = "miku solo", file_url = "/300.jpg" }
      local p4 = { id = "400", score = 80, tags = "rin solo", file_url = "/400.jpg" }

      -- Filter "miku" then pipe: sort:score:desc:2 -> top 2 scored miku posts
      local filtered = local_query.filter_posts({ p1, p2, p3, p4 }, "miku | sort:score:desc:2")
      assert.are.equal(2, #filtered)
      assert.are.equal("200", filtered[1].id) -- score 90
      assert.are.equal("300", filtered[2].id) -- score 50
    end)

    it("QA H-1: skips explicit directory token when target_dir equals config.options.save_dir", function()
      local cfg = require("gelbooru.core.config")
      local dir, tag_str, f = local_query.parse_query("local: " .. cfg.options.save_dir .. " solo")
      assert.are.equal(cfg.options.save_dir, dir)
      assert.are.equal("solo", tag_str)
      assert.are.same({ "solo" }, f.positive_tags)

      local dir2, tag_str2, f2 = local_query.parse_query([[local: "]] .. cfg.options.save_dir .. [[" ~foot_focus]])
      assert.are.equal(cfg.options.save_dir, dir2)
      assert.are.equal("~foot_focus", tag_str2)
      assert.are.same({ "foot_focus" }, f2.or_tags)
      assert.are.same({}, f2.positive_tags)
    end)

    it("QA M-4: parses standalone sort:id:5 without pipe into pipeline stages with limit", function()
      local p = local_query.parse_pipeline("sort:id:5")
      assert.are.equal("", p.base_query)
      assert.are.equal(1, #p.stages)
      assert.are.equal("id", p.stages[1].key)
      assert.are.equal("desc", p.stages[1].dir)
      assert.are.equal(5, p.stages[1].limit)

      -- With base query: solo sort:id:5
      local p2 = local_query.parse_pipeline("solo sort:id:5")
      assert.are.equal("solo", p2.base_query)
      assert.are.equal(1, #p2.stages)
      assert.are.equal("id", p2.stages[1].key)
      assert.are.equal(5, p2.stages[1].limit)
    end)

    it("QA M-4: parses space-separated pipeline sort:id:1000 sort:score:300 sort:random without pipes", function()
      local p = local_query.parse_pipeline("sort:id:1000 sort:score:300 sort:random")
      assert.are.equal("", p.base_query)
      assert.are.equal(3, #p.stages)
      assert.are.equal("id", p.stages[1].key)
      assert.are.equal(1000, p.stages[1].limit)
      assert.are.equal("score", p.stages[2].key)
      assert.are.equal(300, p.stages[2].limit)
      assert.are.equal("random", p.stages[3].key)
    end)

    it("QA M-4: filter_posts with standalone sort:id:2 limits array to top 2 items", function()
      local p1 = { id = "10", score = 10, file_url = "/10.jpg" }
      local p2 = { id = "20", score = 20, file_url = "/20.jpg" }
      local p3 = { id = "30", score = 30, file_url = "/30.jpg" }
      local filtered = local_query.filter_posts({ p1, p2, p3 }, "sort:id:2")
      assert.are.equal(2, #filtered)
      assert.are.equal("30", filtered[1].id)
      assert.are.equal("20", filtered[2].id)
    end)

    it("Phase 1: parses range and offset syntax in parse_pipeline stages", function()
      -- Range with .. syntax: sort:id:1000..1200
      local p1 = local_query.parse_pipeline("sort:id:1000..1200")
      assert.are.equal(1, #p1.stages)
      assert.are.equal("id", p1.stages[1].key)
      assert.are.equal(1000, p1.stages[1].offset)
      assert.are.equal(1200, p1.stages[1].limit)

      -- Range with - syntax: sort:score:50-100
      local p2 = local_query.parse_pipeline("sort:score:50-100")
      assert.are.equal(1, #p2.stages)
      assert.are.equal("score", p2.stages[1].key)
      assert.are.equal(50, p2.stages[1].offset)
      assert.are.equal(100, p2.stages[1].limit)

      -- Inverted range normalization: sort:id:1200..1000 -> offset 1000, limit 1200
      local p3 = local_query.parse_pipeline("sort:id:1200..1000")
      assert.are.equal(1000, p3.stages[1].offset)
      assert.are.equal(1200, p3.stages[1].limit)

      -- limit:1000..1200
      local p4 = local_query.parse_pipeline("miku | limit:1000..1200")
      assert.are.equal("miku", p4.base_query)
      assert.are.equal(1, #p4.stages)
      assert.are.equal(1000, p4.stages[1].offset)
      assert.are.equal(1200, p4.stages[1].limit)

      -- standalone offset:50
      local p5 = local_query.parse_pipeline("miku | offset:50")
      assert.are.equal("miku", p5.base_query)
      assert.are.equal(1, #p5.stages)
      assert.are.equal(50, p5.stages[1].offset)
      assert.is_nil(p5.stages[1].limit)
    end)

    it("Phase 1: execute_pipeline slices range correctly on large dataset", function()
      local items = {}
      for i = 1, 1500 do
        table.insert(items, { id = tostring(i), score = i, file_url = "/" .. i .. ".jpg" })
      end

      -- Pipeline with sort:id:asc:1000..1200
      -- Items sorted by id ascending (1 to 1500)
      -- offset: 1000, limit: 1200 -> slice 1001 to 1200 = 200 items
      local pipeline = local_query.parse_pipeline("sort:id:asc:1000..1200")
      local sliced = local_query.execute_pipeline(items, pipeline)

      assert.are.equal(200, #sliced)
      assert.are.equal("1001", sliced[1].id)
      assert.are.equal("1200", sliced[#sliced].id)
    end)

    it("Phase 1: execute_pipeline slices with offset only or offset + limit", function()
      local items = {}
      for i = 1, 20 do
        table.insert(items, { id = tostring(i), file_url = "/" .. i .. ".jpg" })
      end

      -- Pipeline with offset:15 (items 16 to 20)
      local p1 = local_query.parse_pipeline("offset:15")
      local sliced1 = local_query.execute_pipeline(items, p1)
      assert.are.equal(5, #sliced1)
      assert.are.equal("16", sliced1[1].id)
      assert.are.equal("20", sliced1[5].id)

      -- Pipeline with offset:10 limit:5 (items 11 to 15)
      local p2 = local_query.parse_pipeline("offset:10 limit:5")
      local sliced2 = local_query.execute_pipeline(items, p2)
      assert.are.equal(5, #sliced2)
      assert.are.equal("11", sliced2[1].id)
      assert.are.equal("15", sliced2[5].id)
    end)

    it("Phase 2: split_by_pipeline_pipe anchors random lookahead and avoids splitting intra-tag pipes", function()
      -- foot_focus|random_encounters has intra-tag pipe, random_encounters is NOT random directive
      local p = local_query.parse_pipeline("foot_focus|random_encounters")
      assert.are.equal("foot_focus|random_encounters", p.base_query)
      assert.are.equal(0, #p.stages)

      -- foot_focus | random DOES split into stage
      local p2 = local_query.parse_pipeline("foot_focus | random")
      assert.are.equal("foot_focus", p2.base_query)
      assert.are.equal(1, #p2.stages)
      assert.are.equal("random", p2.stages[1].key)

      -- chained pipeline: solo | sort:score:100..200 | random
      local p3 = local_query.parse_pipeline("solo | sort:score:100..200 | random")
      assert.are.equal("solo", p3.base_query)
      assert.are.equal(2, #p3.stages)
      assert.are.equal("score", p3.stages[1].key)
      assert.are.equal(100, p3.stages[1].offset)
      assert.are.equal(200, p3.stages[1].limit)
      assert.are.equal("random", p3.stages[2].key)
    end)

    it("Issue 5: parses open-ended ranges (50.., 50-, ..100) in parse_limit_or_range and parse_pipeline", function()
      local o1, l1, r1 = local_query.parse_limit_or_range("50..")
      assert.are.equal(50, o1)
      assert.is_nil(l1)
      assert.is_true(r1)

      local o2, l2, r2 = local_query.parse_limit_or_range("50-")
      assert.are.equal(50, o2)
      assert.is_nil(l2)
      assert.is_true(r2)

      local o3, l3, r3 = local_query.parse_limit_or_range("..100")
      assert.are.equal(1, o3)
      assert.are.equal(100, l3)
      assert.is_true(r3)

      local p1 = local_query.parse_pipeline("sort:id:50..")
      assert.are.equal(1, #p1.stages)
      assert.are.equal("id", p1.stages[1].key)
      assert.are.equal(50, p1.stages[1].offset)
      assert.is_nil(p1.stages[1].limit)
      assert.is_true(p1.stages[1].is_range)

      local p2 = local_query.parse_pipeline("sort:score:50-")
      assert.are.equal(1, #p2.stages)
      assert.are.equal("score", p2.stages[1].key)
      assert.are.equal(50, p2.stages[1].offset)
      assert.is_nil(p2.stages[1].limit)
      assert.is_true(p2.stages[1].is_range)

      local p3 = local_query.parse_pipeline("sort:id:..100")
      assert.are.equal(1, #p3.stages)
      assert.are.equal("id", p3.stages[1].key)
      assert.are.equal(1, p3.stages[1].offset)
      assert.are.equal(100, p3.stages[1].limit)
      assert.is_true(p3.stages[1].is_range)

      local p4 = local_query.parse_pipeline("miku | limit:50..")
      assert.are.equal("miku", p4.base_query)
      assert.are.equal(1, #p4.stages)
      assert.are.equal(50, p4.stages[1].offset)
      assert.is_nil(p4.stages[1].limit)
      assert.is_true(p4.stages[1].is_range)
    end)

    it("Issue 5: execute_pipeline slices from stage.offset to #current for open-ended range", function()
      local items = {}
      for i = 1, 100 do
        table.insert(items, { id = tostring(i), file_url = "/" .. i .. ".jpg" })
      end

      -- Pipeline with sort:id:50.. (items 50 to 100 = 51 items)
      local p1 = local_query.parse_pipeline("sort:id:asc:50..")
      local sliced1 = local_query.execute_pipeline(items, p1)
      assert.are.equal(51, #sliced1)
      assert.are.equal("50", sliced1[1].id)
      assert.are.equal("100", sliced1[#sliced1].id)

      -- Pipeline with sort:id:50- (items 50 to 100 = 51 items)
      local p2 = local_query.parse_pipeline("sort:id:asc:50-")
      local sliced2 = local_query.execute_pipeline(items, p2)
      assert.are.equal(51, #sliced2)
      assert.are.equal("50", sliced2[1].id)
      assert.are.equal("100", sliced2[#sliced2].id)

      -- Pipeline with sort:id:..20 (items 1 to 20 = 20 items)
      local p3 = local_query.parse_pipeline("sort:id:asc:..20")
      local sliced3 = local_query.execute_pipeline(items, p3)
      assert.are.equal(20, #sliced3)
      assert.are.equal("1", sliced3[1].id)
      assert.are.equal("20", sliced3[20].id)
    end)

    it("handles inverted range bounds (50..10) gracefully without throwing error", function()
      local p = local_query.parse_pipeline("sort:id:asc:50..10")
      assert.is_not_nil(p)
    end)

    it("handles non-numeric range bounds (abc..def) gracefully without throwing error", function()
      local ok, res = pcall(local_query.parse_pipeline, "sort:id:asc:abc..def")
      assert.is_true(ok)
      assert.is_not_nil(res)
    end)

    it("handles empty pipeline stage (| |) without throwing error", function()
      local ok, p = pcall(local_query.parse_pipeline, "tag1 | | sort:score")
      assert.is_true(ok)
      assert.is_not_nil(p)
    end)

    it("is_saved returns false when ID is in State.pending_deletions", function()
      local local_index = require("gelbooru.local.index")
      state.State.saved_index = { [1001] = "jpg" }
      state.State.pending_deletions = { ["1001"] = { path = "/tmp/1001.jpg", id = "1001" } }
      assert.is_false(local_index.is_saved(1001))
      state.State.pending_deletions = {}
    end)
  end)

  describe("local/scan.lua edge cases & sequential filename collision", function()
    local tmp_scan_dir
    local scan_mod = require("gelbooru.local.scan")
    local util = require("gelbooru.core.util")

    before_each(function()
      tmp_scan_dir = vim.fn.tempname()
      vim.fn.mkdir(tmp_scan_dir, "p")
    end)

    after_each(function()
      vim.fn.delete(tmp_scan_dir, "rf")
    end)

    it("sequential filenames with bare numeric IDs (0001.jpg, 0002.jpg, 42.png, 999.jpg) produce distinct post records", function()
      vim.fn.writefile({ "dummy1" }, tmp_scan_dir .. "/0001.jpg")
      vim.fn.writefile({ "dummy2" }, tmp_scan_dir .. "/0002.jpg")
      vim.fn.writefile({ "dummy3" }, tmp_scan_dir .. "/42.png")
      vim.fn.writefile({ "dummy4" }, tmp_scan_dir .. "/999.jpg")

      local posts = scan_mod.scan_local_folder(tmp_scan_dir)
      assert.are.equal(4, #posts)

      local seen_urls = {}
      for _, p in ipairs(posts) do
        assert.is_true(p.is_local)
        assert.is_nil(seen_urls[p.file_url])
        seen_urls[p.file_url] = true
      end
    end)

    it("sequential filename collision: handles duplicate numeric ID across distinct files (0001.jpg and 1.jpg)", function()
      local file_a = tmp_scan_dir .. "/0001.jpg"
      local file_b = tmp_scan_dir .. "/1.jpg"
      vim.fn.writefile({ "data_a" }, file_a)
      vim.fn.writefile({ "data_b" }, file_b)

      local posts = scan_mod.scan_local_folder(tmp_scan_dir)
      assert.are.equal(2, #posts)

      local post_a = posts[1]
      local post_b = posts[2]
      assert.are_not.equal(post_a.file_url, post_b.file_url)

      -- Local post identity strictly compares file_url, preventing collision
      assert.is_false(util.is_same_post(post_a, post_b))
    end)

    it("explicit booru prefixes preserve ID extraction regardless of magnitude", function()
      assert.are.equal("42", scan_mod.extract_post_id("gelbooru_42.jpg"))
      assert.are.equal("42", scan_mod.extract_post_id("Gelbooru-42.png"))
      assert.are.equal("42", scan_mod.extract_post_id("post_42.jpg"))
      assert.are.equal("42", scan_mod.extract_post_id("Post 42.jpg"))
      assert.are.equal("42", scan_mod.extract_post_id("id_42.jpg"))
      assert.are.equal("42", scan_mod.extract_post_id("ID42.png"))
      assert.are.equal("42", scan_mod.extract_post_id("prev_42.jpg"))
    end)

    it("extract_post_id returns nil for non-numeric filenames or empty/nil path", function()
      assert.is_nil(scan_mod.extract_post_id(nil))
      assert.is_nil(scan_mod.extract_post_id(""))
      assert.is_nil(scan_mod.extract_post_id("wallpaper.jpg"))
      assert.is_nil(scan_mod.extract_post_id("IMG_0042.png"))
      assert.is_nil(scan_mod.extract_post_id("DSC0001.JPG"))
      assert.is_nil(scan_mod.extract_post_id("screenshot_2024.png"))
    end)

    it("extract_post_id rejects bare numeric filenames < 10000 and accepts >= 10000", function()
      assert.is_nil(scan_mod.extract_post_id("1.png"))
      assert.is_nil(scan_mod.extract_post_id("02.jpg"))
      assert.is_nil(scan_mod.extract_post_id("999.jpg"))
      assert.is_nil(scan_mod.extract_post_id("9999.png"))
      assert.is_nil(scan_mod.extract_post_id("1_tag.jpg"))
      assert.is_nil(scan_mod.extract_post_id("42 - tag.png"))
      assert.are.equal("10000", scan_mod.extract_post_id("10000.jpg"))
      assert.are.equal("10001", scan_mod.extract_post_id("10001_tag.png"))
      assert.are.equal("11802758", scan_mod.extract_post_id("11802758.jpg"))
      assert.are.equal("11802758", scan_mod.extract_post_id("11802758 - tag.jpg"))
    end)

    describe("Strict Booru ID Disambiguation & Pixiv Filename Filtering", function()
      local constants = require("gelbooru.core.constants")

      it("centralizes GELBOORU_ID_CEILING constant", function()
        assert.is_not_nil(constants.GELBOORU_ID_CEILING)
        assert.are.equal(25000000, constants.GELBOORU_ID_CEILING)
      end)

      it("discards Pixiv filenames with _p%d+ convention", function()
        assert.is_nil(scan_mod.extract_post_id("131102272_p0.jpg"))
        assert.is_nil(scan_mod.extract_post_id("140506898_p1.png"))
        assert.is_nil(scan_mod.extract_post_id("11802758_p0.jpg"))
        assert.is_nil(scan_mod.extract_post_id("131102272_p0_master1200.jpg"))
        assert.is_nil(scan_mod.extract_post_id("illust_123456_p0.jpg"))
        assert.is_nil(scan_mod.extract_post_id("sample_p12.png"))
      end)

      it("rejects bare numeric IDs exceeding GELBOORU_ID_CEILING", function()
        assert.is_nil(scan_mod.extract_post_id("25000001.jpg"))
        assert.is_nil(scan_mod.extract_post_id("99999999.png"))
        assert.is_nil(scan_mod.extract_post_id("131102272.jpg"))
        assert.is_nil(scan_mod.extract_post_id("25000001_tag.jpg"))
        assert.is_nil(scan_mod.extract_post_id("99999999 - tag.jpg"))
      end)

      it("preserves valid IDs between 10000 and GELBOORU_ID_CEILING (25000000)", function()
        assert.are.equal("10000", scan_mod.extract_post_id("10000.jpg"))
        assert.are.equal("10001", scan_mod.extract_post_id("10001_tag.png"))
        assert.are.equal("11802758", scan_mod.extract_post_id("11802758.jpg"))
        assert.are.equal("11802758", scan_mod.extract_post_id("11802758_hatsune_miku.jpg"))
        assert.are.equal("25000000", scan_mod.extract_post_id("25000000.png"))
        assert.are.equal("25000000", scan_mod.extract_post_id("25000000_sample.jpg"))
      end)

      it("preserves explicit booru prefixes (post_, id_, ID, gelbooru_) even when exceeding ceiling", function()
        assert.are.equal("99999999", scan_mod.extract_post_id("gelbooru_99999999.jpg"))
        assert.are.equal("99999999", scan_mod.extract_post_id("Gelbooru-99999999.png"))
        assert.are.equal("99999999", scan_mod.extract_post_id("post_99999999.jpg"))
        assert.are.equal("99999999", scan_mod.extract_post_id("Post 99999999.jpg"))
        assert.are.equal("99999999", scan_mod.extract_post_id("id_99999999.jpg"))
        assert.are.equal("99999999", scan_mod.extract_post_id("ID99999999.png"))
        assert.are.equal("30000000", scan_mod.extract_post_id("gelbooru_30000000.jpg"))
      end)

      it("scan_local_folder assigns nil id to Pixiv and over-ceiling bare files while extracting valid IDs", function()
        vim.fn.writefile({ "dummy" }, tmp_scan_dir .. "/131102272_p0.jpg")
        vim.fn.writefile({ "dummy" }, tmp_scan_dir .. "/140506898_p1.png")
        vim.fn.writefile({ "dummy" }, tmp_scan_dir .. "/99999999.jpg")
        vim.fn.writefile({ "dummy" }, tmp_scan_dir .. "/11802758.jpg")
        vim.fn.writefile({ "dummy" }, tmp_scan_dir .. "/post_99999999.jpg")

        local posts = scan_mod.scan_local_folder(tmp_scan_dir)
        local post_map = {}
        for _, p in ipairs(posts) do
          local name = vim.fn.fnamemodify(p.file_url, ":t")
          post_map[name] = p
        end

        assert.is_nil(post_map["131102272_p0.jpg"].id)
        assert.is_nil(post_map["140506898_p1.png"].id)
        assert.is_nil(post_map["99999999.jpg"].id)
        assert.are.equal("11802758", post_map["11802758.jpg"].id)
        assert.are.equal("99999999", post_map["post_99999999.jpg"].id)
      end)
    end)
  end)
end)



