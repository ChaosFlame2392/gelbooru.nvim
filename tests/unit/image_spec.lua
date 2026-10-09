-- tests/unit/image_spec.lua
-- Unit tests for gelbooru.ui.image — pure URL/path logic only (no renderer calls).

local image = require("gelbooru.ui.image")

describe("image.file_ext_from_url", function()
  it("extracts jpg", function()
    assert.are.equal("jpg", image.file_ext_from_url("https://example.com/img/foo.jpg"))
  end)

  it("extracts png", function()
    assert.are.equal("png", image.file_ext_from_url("https://example.com/img/foo.png"))
  end)

  it("strips query string before extracting", function()
    assert.are.equal("jpg", image.file_ext_from_url("https://example.com/img/foo.jpg?v=2"))
  end)

  it("defaults to jpg for unknown extension", function()
    assert.are.equal("jpg", image.file_ext_from_url("https://example.com/img/noext"))
  end)

  it("handles nil gracefully", function()
    assert.are.equal("jpg", image.file_ext_from_url(nil))
  end)

  it("lowercases the result", function()
    assert.are.equal("png", image.file_ext_from_url("https://example.com/img/foo.PNG"))
  end)
end)

describe("image.is_video_post", function()
  it("detects mp4", function()
    assert.is_true(image.is_video_post({ file_url = "https://example.com/video.mp4" }))
  end)

  it("detects webm", function()
    assert.is_true(image.is_video_post({ file_url = "https://example.com/video.webm" }))
  end)

  it("returns false for images", function()
    assert.is_false(image.is_video_post({ file_url = "https://example.com/img.jpg" }))
  end)

  it("returns false for nil post", function()
    assert.is_false(image.is_video_post(nil))
  end)
end)

describe("image.get_preview_targets", function()
  local config = require("gelbooru.core.config")

  local function fake_post(sample, preview, file_url)
    return { id = 42, sample_url = sample, preview_url = preview, file_url = file_url }
  end

  it("returns urls list and a dest path", function()
    local p = fake_post(
      "https://img.gelbooru.com/samples/sample.jpg",
      "https://img.gelbooru.com/thumbnails/thumb.jpg",
      "https://img.gelbooru.com/images/file.jpg"
    )
    local urls, dest = image.get_preview_targets(p)
    assert.is_truthy(#urls >= 1)
    assert.is_truthy(dest)
    assert.is_truthy(dest:find("42"))
  end)

  it("deduplicates identical URLs", function()
    local same = "https://img.gelbooru.com/images/file.jpg"
    local p = fake_post(same, same, same)
    local urls, _ = image.get_preview_targets(p)
    assert.are.equal(1, #urls)
  end)

  it("returns empty table and nil for nil post", function()
    local urls, dest = image.get_preview_targets(nil)
    assert.are.equal(0, #urls)
    assert.is_nil(dest)
  end)

  it("dest path uses cache_dir from config", function()
    local p = fake_post(nil, nil, "https://img.gelbooru.com/images/file.png")
    local _, dest = image.get_preview_targets(p)
    assert.is_truthy(dest:find(config.options.cache_dir, 1, true))
  end)

  it("returns local file path as dest when is_local is true", function()
    local local_file = "/path/to/downloaded/12345.png"
    local p = { id = "12345", file_url = local_file, sample_url = local_file, preview_url = local_file, is_local = true }
    local urls, dest = image.get_preview_targets(p)
    assert.are.equal(1, #urls)
    assert.are.equal(local_file, urls[1])
    assert.are.equal(local_file, dest)
  end)

  it("returns local video thumb target and NO online URLs when is_local is true for video", function()
    local local_vid = "/path/to/downloaded/54321.mp4"
    local p = {
      id = "54321",
      file_url = local_vid,
      sample_url = "https://img.gelbooru.com/samples/sample.jpg",
      preview_url = "https://img.gelbooru.com/thumbnails/thumb.jpg",
      is_local = true,
    }
    local urls, dest = image.get_preview_targets(p)
    assert.are.equal(1, #urls)
    assert.is_false(urls[1]:match("^https?://") ~= nil)
    local expected_thumb = image.get_video_thumbnail_path(local_vid, p.id)
    assert.are.equal(expected_thumb, dest)
    assert.are.equal(expected_thumb, urls[1])
  end)
end)

describe("image.extract_video_thumbnail & cache", function()
  it("immediately returns nil callback for non-existent, 0-byte, or .part files", function()
    local cb_called = false
    local result = "unset"
    image.extract_video_thumbnail("/non/existent/path/vid.mp4", "1", function(res)
      cb_called = true
      result = res
    end)
    assert.is_true(cb_called)
    assert.is_nil(result)

    -- Test .part file
    local tmp_part = vim.fn.tempname() .. ".part"
    vim.fn.writefile({ "hello" }, tmp_part)
    cb_called = false
    result = "unset"
    image.extract_video_thumbnail(tmp_part, "2", function(res)
      cb_called = true
      result = res
    end)
    assert.is_true(cb_called)
    assert.is_nil(result)
    vim.fn.delete(tmp_part)

    -- Test 0-byte file
    local tmp_zero = vim.fn.tempname() .. ".mp4"
    vim.fn.writefile({}, tmp_zero)
    cb_called = false
    result = "unset"
    image.extract_video_thumbnail(tmp_zero, "3", function(res)
      cb_called = true
      result = res
    end)
    assert.is_true(cb_called)
    assert.is_nil(result)
    vim.fn.delete(tmp_zero)
  end)

  it("clear_snacks_cache_for deletes vthumb_<id>.jpg from cache_dir", function()
    local config = require("gelbooru.core.config")
    local vthumb = string.format("%s/vthumb_9988.jpg", config.options.cache_dir)
    vim.fn.mkdir(config.options.cache_dir, "p")
    vim.fn.writefile({ "dummy" }, vthumb)
    assert.are.equal(1, vim.fn.filereadable(vthumb))

    image.clear_snacks_cache_for("9988")
    assert.are.equal(0, vim.fn.filereadable(vthumb))
  end)

  it("recognizes and uses existing vthumb_<id>.jpg in cache without running ffmpeg", function()
    local config = require("gelbooru.core.config")
    local cache_dir = config.options.cache_dir
    vim.fn.mkdir(cache_dir, "p")
    local vthumb = string.format("%s/vthumb_4567.jpg", cache_dir)
    vim.fn.writefile({ string.rep("x", 600) }, vthumb)

    local cb_called = false
    local result_path = nil
    image.extract_video_thumbnail(nil, "4567", function(res)
      cb_called = true
      result_path = res
    end)

    assert.is_true(cb_called)
    assert.are.equal(vthumb, result_path)
    vim.fn.delete(vthumb)
  end)

  it("finds video in config.options.save_dir when vpath is nil or unreadable", function()
    local config = require("gelbooru.core.config")
    local orig_save_dir = config.options.save_dir
    local tmp_save = vim.fn.tempname()
    vim.fn.mkdir(tmp_save, "p")
    config.options.save_dir = tmp_save

    local vid_file = tmp_save .. "/8877.mp4"
    vim.fn.writefile({ "dummy video content" }, vid_file)

    local saved_path = image.get_saved_video_path("8877")
    assert.are.equal(vid_file, saved_path)

    config.options.save_dir = orig_save_dir
    vim.fn.delete(tmp_save, "rf")
  end)
end)

describe("image.preview_source_name", function()
  local p = {
    id = 1,
    sample_url = "https://example.com/sample.jpg",
    preview_url = "https://example.com/preview.jpg",
    file_url = "https://example.com/file.jpg",
  }

  it("identifies sample", function()
    assert.are.equal("sample", image.preview_source_name(p, p.sample_url))
  end)

  it("identifies thumbnail/preview", function()
    assert.are.equal("thumbnail", image.preview_source_name(p, p.preview_url))
  end)

  it("identifies original", function()
    assert.are.equal("original", image.preview_source_name(p, p.file_url))
  end)

  it("returns 'preview' for unknown url", function()
    assert.are.equal("preview", image.preview_source_name(p, "https://example.com/other.jpg"))
  end)
end)
