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
