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

  it("excludes directories with ONLY non-image files (.txt, .mp4, .json, .part, .md)", function()
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/notes.txt")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/video.mp4")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/meta.json")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/download.png.part")
    vim.fn.writefile({ "dummy" }, tmp_dir .. "/README.md")

    local posts, _ = ui.scan_local_folder(tmp_dir)
    assert.are.equal(0, #posts)
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

  before_each(function()
    orig_curl_async = download.curl_async
    state.State.torn_down = false
  end)

  after_each(function()
    download.curl_async = orig_curl_async
    state.State.torn_down = false
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

    local called = false
    api.fetch_post_metadata(p, function(_)
      called = true
    end)

    vim.wait(100, function()
      return p._metadata_fetched == true
    end, 10)

    assert.is_false(called)
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

    local called = false
    api.fetch_post_metadata(p, function(_)
      called = true
    end)

    vim.wait(100, function()
      return p._metadata_fetched == true
    end, 10)

    assert.is_false(called)
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
end)
