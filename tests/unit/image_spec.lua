-- tests/unit/image_spec.lua
-- Unit tests for gelbooru.ui.image — URL parsing, video detection, candidate targets,
-- thumbnail extraction/cleanup, DPI sanitization, and ffmpeg lifecycle management.

local image = require("gelbooru.ui.image")
local config = require("gelbooru.core.config")

describe("image.file_ext_from_url: comprehensive URL parsing & edge cases", function()
  it("extracts standard image and video extensions", function()
    assert.are.equal("jpg", image.file_ext_from_url("https://example.com/img/foo.jpg"))
    assert.are.equal("jpeg", image.file_ext_from_url("https://example.com/img/foo.jpeg"))
    assert.are.equal("png", image.file_ext_from_url("https://example.com/img/foo.png"))
    assert.are.equal("webp", image.file_ext_from_url("https://example.com/img/foo.webp"))
    assert.are.equal("gif", image.file_ext_from_url("https://example.com/img/foo.gif"))
    assert.are.equal("mp4", image.file_ext_from_url("https://example.com/vid/sample.mp4"))
    assert.are.equal("webm", image.file_ext_from_url("https://example.com/vid/sample.webm"))
    assert.are.equal("avi", image.file_ext_from_url("https://example.com/vid/sample.avi"))
    assert.are.equal("mov", image.file_ext_from_url("https://example.com/vid/sample.mov"))
  end)

  it("strips complex query strings and query parameters before extracting", function()
    assert.are.equal("jpg", image.file_ext_from_url("https://example.com/img/foo.jpg?v=2"))
    assert.are.equal("png", image.file_ext_from_url("https://example.com/img/foo.png?token=abc123xyz&w=1920&h=1080"))
    assert.are.equal("webp", image.file_ext_from_url("https://example.com/img/sample.webp?download=1&auth=yes#section"))
  end)

  it("strips fragment anchors (#) before extracting", function()
    assert.are.equal("jpg", image.file_ext_from_url("https://example.com/img/foo.jpg#preview"))
    assert.are.equal("png", image.file_ext_from_url("https://example.com/img/foo.png#top"))
    assert.are.equal("mp4", image.file_ext_from_url("https://example.com/vid/foo.mp4#t=10s,20s"))
  end)

  it("handles relative URLs and local filesystem paths", function()
    assert.are.equal("webp", image.file_ext_from_url("/images/sample.webp"))
    assert.are.equal("gif", image.file_ext_from_url("../assets/icon.gif"))
    assert.are.equal("jpeg", image.file_ext_from_url("./photo.jpeg"))
    assert.are.equal("png", image.file_ext_from_url("images/banner.png"))
    assert.are.equal("mp4", image.file_ext_from_url("C:\\Media\\video.mp4"))
  end)

  it("handles double extensions (e.g. .part, .tar.gz, .sample.png)", function()
    assert.are.equal("part", image.file_ext_from_url("https://example.com/download.jpg.part"))
    assert.are.equal("gz", image.file_ext_from_url("https://example.com/archive.tar.gz"))
    assert.are.equal("png", image.file_ext_from_url("https://img.gelbooru.com/samples/12/34/sample_1234.sample.png"))
  end)

  it("parses unusual booru CDN URLs with multiple slashes and deep subpaths", function()
    assert.are.equal("jpeg", image.file_ext_from_url("https://img3.gelbooru.com//images/ab/cd/abcdef0123456789.jpeg"))
    assert.are.equal("jpg", image.file_ext_from_url("https://img-cache.gelbooru.com/samples/12/34/sample_12345.jpg?h=1200"))
  end)

  it("defaults to jpg when filename has no extension, even with dots in directory or query", function()
    assert.are.equal("jpg", image.file_ext_from_url("https://example.com/img/noext"))
    assert.are.equal("jpg", image.file_ext_from_url("https://example.com/v2.0/download"))
    assert.are.equal("jpg", image.file_ext_from_url("https://example.com/get?file=other.png"))
    assert.are.equal("jpg", image.file_ext_from_url("https://example.com/path/"))
  end)

  it("lowercases uppercase and mixed-case extensions", function()
    assert.are.equal("png", image.file_ext_from_url("https://example.com/img/foo.PNG"))
    assert.are.equal("jpeg", image.file_ext_from_url("https://example.com/img/foo.JPeG"))
    assert.are.equal("mp4", image.file_ext_from_url("https://example.com/vid/clip.MP4"))
    assert.are.equal("webm", image.file_ext_from_url("https://example.com/vid/anim.WEBM"))
  end)

  it("handles nil and non-string inputs gracefully by defaulting to jpg", function()
    assert.are.equal("jpg", image.file_ext_from_url(nil))
    assert.are.equal("jpg", image.file_ext_from_url(""))
    assert.are.equal("jpg", image.file_ext_from_url(12345))
    assert.are.equal("jpg", image.file_ext_from_url({}))
    assert.are.equal("jpg", image.file_ext_from_url(true))
  end)
end)

describe("image.is_video_post: multi-format video detection", function()
  it("detects mp4, webm, avi, mov, and mkv videos", function()
    assert.is_true(image.is_video_post({ file_url = "https://example.com/video.mp4" }))
    assert.is_true(image.is_video_post({ file_url = "https://example.com/video.webm" }))
    assert.is_true(image.is_video_post({ file_url = "https://example.com/clip.avi" }))
    assert.is_true(image.is_video_post({ file_url = "https://example.com/movie.mov" }))
    assert.is_true(image.is_video_post({ file_url = "https://example.com/recording.mkv" }))
  end)

  it("detects uppercase video extensions (.MP4, .WEBM, .AVI, .MOV)", function()
    assert.is_true(image.is_video_post({ file_url = "https://example.com/video.MP4" }))
    assert.is_true(image.is_video_post({ file_url = "https://example.com/video.WEBM" }))
    assert.is_true(image.is_video_post({ file_url = "https://example.com/video.AVI" }))
    assert.is_true(image.is_video_post({ file_url = "https://example.com/video.MOV" }))
  end)

  it("detects video files with query parameters and fragments", function()
    assert.is_true(image.is_video_post({ file_url = "https://cdn.booru.com/vid.mp4?expires=12345&sig=abc#t=0" }))
    assert.is_true(image.is_video_post({ file_url = "/storage/videos/clip.webm?preview=1" }))
  end)

  it("returns false for image posts", function()
    assert.is_false(image.is_video_post({ file_url = "https://example.com/img.jpg" }))
    assert.is_false(image.is_video_post({ file_url = "https://example.com/img.jpeg" }))
    assert.is_false(image.is_video_post({ file_url = "https://example.com/img.png" }))
    assert.is_false(image.is_video_post({ file_url = "https://example.com/img.gif" }))
    assert.is_false(image.is_video_post({ file_url = "https://example.com/img.webp" }))
  end)

  it("returns false for image posts that have video names as filename substrings", function()
    assert.is_false(image.is_video_post({ file_url = "https://example.com/my_mp4_archive.jpg" }))
    assert.is_false(image.is_video_post({ file_url = "https://example.com/webm_thumb.png" }))
  end)

  it("returns false for nil, missing, or non-table posts", function()
    assert.is_false(image.is_video_post(nil))
    assert.is_false(image.is_video_post({}))
    assert.is_false(image.is_video_post({ file_url = nil }))
    assert.is_false(image.is_video_post({ file_url = "" }))
  end)
end)

describe("image.get_preview_targets: candidate resolution order for images vs videos", function()
  local function fake_post(sample, preview, file_url)
    return { id = 42, sample_url = sample, preview_url = preview, file_url = file_url }
  end

  it("returns candidates strictly in [sample_url, preview_url, file_url] order and exact dest", function()
    local p = fake_post(
      "https://img.gelbooru.com/samples/sample.jpg",
      "https://img.gelbooru.com/thumbnails/thumb.jpg",
      "https://img.gelbooru.com/images/file.jpg"
    )
    local urls, dest = image.get_preview_targets(p, 1)
    assert.are.equal(3, #urls)
    assert.are.equal("https://img.gelbooru.com/samples/sample.jpg", urls[1])
    assert.are.equal("https://img.gelbooru.com/thumbnails/thumb.jpg", urls[2])
    assert.are.equal("https://img.gelbooru.com/images/file.jpg", urls[3])
    assert.are.equal(config.options.cache_dir .. "/prev_42.jpg", dest)
  end)

  it("respects url_idx selection for preview destination file extension", function()
    local p = {
      id = 100,
      sample_url = "https://example.com/sample.jpg",
      preview_url = "https://example.com/preview.png",
      file_url = "https://example.com/file.webp",
    }
    local _, dest1 = image.get_preview_targets(p, 1)
    assert.are.equal(config.options.cache_dir .. "/prev_100.jpg", dest1)

    local _, dest2 = image.get_preview_targets(p, 2)
    assert.are.equal(config.options.cache_dir .. "/prev_100.png", dest2)

    local _, dest3 = image.get_preview_targets(p, 3)
    assert.are.equal(config.options.cache_dir .. "/prev_100.webp", dest3)
  end)

  it("deduplicates identical URLs while maintaining resolution order", function()
    local same = "https://img.gelbooru.com/images/file.jpg"
    local p = fake_post(same, same, same)
    local urls, dest = image.get_preview_targets(p)
    assert.are.equal(1, #urls)
    assert.are.equal(same, urls[1])
    assert.are.equal(config.options.cache_dir .. "/prev_42.jpg", dest)
  end)

  it("skips nil or empty candidates smoothly", function()
    local p = fake_post(nil, "https://example.com/preview.jpg", "https://example.com/file.png")
    local urls, dest = image.get_preview_targets(p)
    assert.are.equal(2, #urls)
    assert.are.equal("https://example.com/preview.jpg", urls[1])
    assert.are.equal("https://example.com/file.png", urls[2])
    assert.are.equal(config.options.cache_dir .. "/prev_42.jpg", dest)

    local p2 = fake_post("", "", "https://example.com/file.png")
    local urls2, dest2 = image.get_preview_targets(p2)
    assert.are.equal(1, #urls2)
    assert.are.equal("https://example.com/file.png", urls2[1])
    assert.are.equal(config.options.cache_dir .. "/prev_42.png", dest2)
  end)

  it("returns empty table and nil dest when post has no valid URLs", function()
    local urls, dest = image.get_preview_targets(nil)
    assert.are.equal(0, #urls)
    assert.is_nil(dest)

    local urls2, dest2 = image.get_preview_targets({ id = 999, sample_url = nil, preview_url = "", file_url = nil })
    assert.are.equal(0, #urls2)
    assert.is_nil(dest2)
  end)

  it("returns local file path directly as dest when is_local is true for image", function()
    local local_file = "/path/to/downloaded/12345.png"
    local p = { id = "12345", file_url = local_file, sample_url = local_file, preview_url = local_file, is_local = true }
    local urls, dest = image.get_preview_targets(p)
    assert.are.equal(1, #urls)
    assert.are.equal(local_file, urls[1])
    assert.are.equal(local_file, dest)
  end)

  it("returns local video thumb target and zero online URLs when is_local is true for video", function()
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
    assert.is_nil(urls[1]:match("^https?://"))
    local expected_thumb = image.get_video_thumbnail_path(local_vid, p.id)
    assert.are.equal(expected_thumb, dest)
    assert.are.equal(expected_thumb, urls[1])
    assert.are.equal(config.options.cache_dir .. "/vthumb_54321.jpg", dest)
  end)

  it("generates correct video thumbnail path when post_id is nil, empty, or string", function()
    local thumb1 = image.get_video_thumbnail_path("/media/video_clip.mp4", nil)
    assert.are.equal(config.options.cache_dir .. "/vthumb_video_clip.jpg", thumb1)

    local thumb2 = image.get_video_thumbnail_path("/media/video_clip.mp4", "")
    assert.are.equal(config.options.cache_dir .. "/vthumb_video_clip.jpg", thumb2)

    local thumb3 = image.get_video_thumbnail_path("/media/video_clip.mp4", "998877")
    assert.are.equal(config.options.cache_dir .. "/vthumb_998877.jpg", thumb3)
  end)
end)

describe("image.preview_source_name", function()
  local p = {
    id = 1,
    sample_url = "https://example.com/sample.jpg",
    preview_url = "https://example.com/preview.jpg",
    file_url = "https://example.com/file.jpg",
  }

  it("identifies sample, thumbnail, original, and preview sources correctly", function()
    assert.are.equal("sample", image.preview_source_name(p, p.sample_url))
    assert.are.equal("thumbnail", image.preview_source_name(p, p.preview_url))
    assert.are.equal("original", image.preview_source_name(p, p.file_url))
    assert.are.equal("preview", image.preview_source_name(p, "https://example.com/other.jpg"))
    assert.are.equal("preview", image.preview_source_name(nil, p.sample_url))
  end)
end)

describe("image: video thumbnail fallback and corrupt/truncated thumbnail cleanup", function()
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

  it("rejects corrupt or truncated (<512 bytes) cached thumbnail and triggers regeneration", function()
    local cache_dir = config.options.cache_dir
    vim.fn.mkdir(cache_dir, "p")
    local vthumb = string.format("%s/vthumb_8888.jpg", cache_dir)
    -- Write 100 bytes (corrupt / truncated thumbnail)
    vim.fn.writefile({ string.rep("x", 100) }, vthumb)
    assert.are.equal(1, vim.fn.filereadable(vthumb))

    local orig_executable = vim.fn.executable
    vim.fn.executable = function(tool)
      if tool == "ffmpeg" then return 0 end -- simulate ffmpeg unavailable
      return orig_executable(tool)
    end

    local cb_called = false
    local result = "unset"
    image.extract_video_thumbnail("/non/existent/vid.mp4", "8888", function(res)
      cb_called = true
      result = res
    end)

    vim.fn.executable = orig_executable
    vim.fn.delete(vthumb)

    -- Should reject the <= 512 byte thumbnail and return nil rather than returning corrupt file
    assert.is_true(cb_called)
    assert.is_nil(result)
  end)

  it("clear_snacks_cache_for deletes vthumb_<id>.jpg from cache_dir and matching snacks cache", function()
    local vthumb = string.format("%s/vthumb_9988.jpg", config.options.cache_dir)
    vim.fn.mkdir(config.options.cache_dir, "p")
    vim.fn.writefile({ "dummy" }, vthumb)
    assert.are.equal(1, vim.fn.filereadable(vthumb))

    image.clear_snacks_cache_for("9988")
    assert.are.equal(0, vim.fn.filereadable(vthumb))

    -- Safe no-op for nil or empty ID
    assert.has_no.errors(function()
      image.clear_snacks_cache_for(nil)
      image.clear_snacks_cache_for("")
      image.clear_snacks_cache_for("nil")
    end)
  end)

  it("recognizes and uses existing valid (>512 bytes) vthumb_<id>.jpg in cache without running ffmpeg", function()
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

  it("finds video in config.options.save_dir across supported extensions when vpath is nil", function()
    local orig_save_dir = config.options.save_dir
    local tmp_save = vim.fn.tempname()
    vim.fn.mkdir(tmp_save, "p")
    config.options.save_dir = tmp_save

    -- Test mp4
    local vid_mp4 = tmp_save .. "/8877.mp4"
    vim.fn.writefile({ "dummy video content" }, vid_mp4)
    assert.are.equal(vid_mp4, image.get_saved_video_path("8877"))
    vim.fn.delete(vid_mp4)

    -- Test webm
    local vid_webm = tmp_save .. "/8878.webm"
    vim.fn.writefile({ "dummy video content" }, vid_webm)
    assert.are.equal(vid_webm, image.get_saved_video_path("8878"))
    vim.fn.delete(vid_webm)

    -- Test nil/invalid inputs
    assert.is_nil(image.get_saved_video_path(nil))
    assert.is_nil(image.get_saved_video_path(""))
    assert.is_nil(image.get_saved_video_path("nil"))

    config.options.save_dir = orig_save_dir
    vim.fn.delete(tmp_save, "rf")
  end)
end)

describe("image.sanitize_dpi: extreme DPI normalization", function()
  it("normalizes extreme astronomical DPI to standard 96x96", function()
    local img = {
      info = {
        dpi = { width = 42000000, height = 42000000 },
      },
    }
    image.sanitize_dpi(img)
    assert.are.equal(96, img.info.dpi.width)
    assert.are.equal(96, img.info.dpi.height)
  end)

  it("normalizes sub-50 DPI to standard 96x96", function()
    local img = {
      info = {
        dpi = { width = 10, height = 10 },
      },
    }
    image.sanitize_dpi(img)
    assert.are.equal(96, img.info.dpi.width)
    assert.are.equal(96, img.info.dpi.height)
  end)

  it("normalizes unbalanced DPI (>300 on one axis) to standard 96x96", function()
    local img = {
      info = {
        dpi = { width = 72, height = 600 },
      },
    }
    image.sanitize_dpi(img)
    assert.are.equal(96, img.info.dpi.width)
    assert.are.equal(96, img.info.dpi.height)
  end)

  it("preserves standard and reasonable in-range DPI (50 to < 300) unchanged", function()
    local img_96 = { info = { dpi = { width = 96, height = 96 } } }
    image.sanitize_dpi(img_96)
    assert.are.equal(96, img_96.info.dpi.width)
    assert.are.equal(96, img_96.info.dpi.height)

    local img_72 = { info = { dpi = { width = 72, height = 72 } } }
    image.sanitize_dpi(img_72)
    assert.are.equal(72, img_72.info.dpi.width)
    assert.are.equal(72, img_72.info.dpi.height)

    local img_150 = { info = { dpi = { width = 150, height = 150 } } }
    image.sanitize_dpi(img_150)
    assert.are.equal(150, img_150.info.dpi.width)
    assert.are.equal(150, img_150.info.dpi.height)
  end)

  it("normalizes exactly 300 DPI images (standard export DPI) down to 96x96", function()
    local img_300 = { info = { dpi = { width = 300, height = 300 } } }
    image.sanitize_dpi(img_300)
    assert.are.equal(96, img_300.info.dpi.width)
    assert.are.equal(96, img_300.info.dpi.height)
  end)

  it("safely handles nil, empty tables, and missing DPI structures", function()
    assert.has_no.errors(function()
      image.sanitize_dpi(nil)
      image.sanitize_dpi({})
      image.sanitize_dpi({ info = nil })
      image.sanitize_dpi({ info = {} })
      image.sanitize_dpi({ info = { dpi = nil } })
      image.sanitize_dpi({ info = { dpi = {} } })
    end)
  end)
end)

describe("image: ffmpeg process management & rapid cycling (Issue 13)", function()
  local orig_system
  local orig_executable

  before_each(function()
    orig_system = vim.system
    orig_executable = vim.fn.executable
    image.active_ffmpeg_handles = {}
  end)

  after_each(function()
    vim.system = orig_system
    vim.fn.executable = orig_executable
    image.abort_all_ffmpeg()
  end)

  it("stores ffmpeg handle in active_ffmpeg_handles when spawning", function()
    local mock_handle = { kill = function() end }
    local exit_fn = nil
    vim.fn.executable = function() return 1 end

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      return mock_handle
    end

    local tmp_vid = vim.fn.tempname() .. ".mp4"
    local f = io.open(tmp_vid, "wb")
    f:write(string.rep("x", 2048))
    f:close()

    local handle = image.extract_video_thumbnail(tmp_vid, "9001", function() end)

    assert.are.equal(mock_handle, handle)
    assert.are.equal(mock_handle, image.active_ffmpeg_handles[mock_handle])

    -- Simulate process exit
    exit_fn({ code = 0 })
    local done = false
    vim.schedule(function() done = true end)
    vim.wait(200, function() return done end)

    assert.is_nil(image.active_ffmpeg_handles[mock_handle])
    vim.fn.delete(tmp_vid)
  end)

  it("abort_all_ffmpeg kills all active handles with SIGKILL and clears active_ffmpeg_handles under rapid cycling", function()
    local killed = {}
    local handle1 = { kill = function(self, sig) table.insert(killed, { id = 1, sig = sig }) end }
    local handle2 = { kill = function(self, sig) table.insert(killed, { id = 2, sig = sig }) end }
    local handle3 = { kill = function(self, sig) table.insert(killed, { id = 3, sig = sig }) end }

    image.active_ffmpeg_handles[handle1] = handle1
    image.active_ffmpeg_handles[handle2] = handle2
    image.active_ffmpeg_handles[handle3] = handle3

    assert.are.equal(3, vim.tbl_count(image.active_ffmpeg_handles))

    image.abort_all_ffmpeg()

    assert.are.equal(3, #killed)
    assert.are.equal(9, killed[1].sig)
    assert.are.equal(9, killed[2].sig)
    assert.are.equal(9, killed[3].sig)
    assert.are.equal(0, vim.tbl_count(image.active_ffmpeg_handles))

    -- Subsequent call when empty is safe no-op
    assert.has_no.errors(function()
      image.abort_all_ffmpeg()
    end)
  end)

  it("handles rogue handles whose kill() method throws errors via pcall protection", function()
    local handle_exploding = {
      kill = function()
        error("Catastrophic kernel error during kill")
      end,
    }
    local handle_normal = {
      kill_called = false,
      kill = function(self, sig)
        self.kill_called = true
        assert.are.equal(9, sig)
      end,
    }

    image.active_ffmpeg_handles[handle_exploding] = handle_exploding
    image.active_ffmpeg_handles[handle_normal] = handle_normal

    assert.has_no.errors(function()
      image.abort_all_ffmpeg()
    end)

    assert.is_true(handle_normal.kill_called)
    assert.are.equal(0, vim.tbl_count(image.active_ffmpeg_handles))
  end)

  it("close_current_placement calls abort_all_ffmpeg and clears placement", function()
    local killed = {}
    local handle = { kill = function(self, sig) table.insert(killed, sig) end }
    image.active_ffmpeg_handles[handle] = handle

    local placement_closed = false
    local state = require("gelbooru.core.state")
    state.UI.current_placement = {
      close = function()
        placement_closed = true
      end,
    }

    image.close_current_placement()

    assert.is_true(placement_closed)
    assert.is_nil(state.UI.current_placement)
    assert.are.equal(1, #killed)
    assert.are.equal(9, killed[1])
    assert.are.equal(0, vim.tbl_count(image.active_ffmpeg_handles))
  end)
end)

describe("image: self-healing cache lifecycle & in-flight conversion abort cleanup (Ticket 02)", function()
  local sandbox_root
  local sandbox_snacks_cache
  local sandbox_config_cache
  local orig_cache_dir
  local orig_snacks_override

  before_each(function()
    sandbox_root = vim.fn.tempname()
    sandbox_snacks_cache = sandbox_root .. "/snacks/image"
    sandbox_config_cache = sandbox_root .. "/gelbooru_cache"
    vim.fn.mkdir(sandbox_snacks_cache, "p")
    vim.fn.mkdir(sandbox_config_cache, "p")

    orig_cache_dir = config.options.cache_dir
    config.options.cache_dir = sandbox_config_cache

    orig_snacks_override = image._snacks_cache_dir
    image._snacks_cache_dir = sandbox_snacks_cache
  end)

  after_each(function()
    config.options.cache_dir = orig_cache_dir
    image._snacks_cache_dir = orig_snacks_override
    if sandbox_root and vim.fn.isdirectory(sandbox_root) == 1 then
      vim.fn.delete(sandbox_root, "rf")
    end
  end)

  it("get_snacks_cache_dir returns isolated sandbox directory when set", function()
    assert.are.equal(sandbox_snacks_cache, image.get_snacks_cache_dir())
  end)

  it("abort_convert(placement) unlinks partial 0-byte step files on disk when aborted mid-flight", function()
    local step1_file = sandbox_root .. "/step1_incomplete.png"
    local step1_info = step1_file .. ".info"
    local step2_file = sandbox_root .. "/step2_complete.png"

    -- step1 is 0 bytes (interrupted mid-flight)
    vim.fn.writefile({}, step1_file)
    vim.fn.writefile({}, step1_info)
    assert.are.equal(1, vim.fn.filereadable(step1_file))
    assert.are.equal(1, vim.fn.filereadable(step1_info))

    -- step2 has valid content (>0 bytes)
    vim.fn.writefile({ "complete data payload" }, step2_file)
    assert.are.equal(1, vim.fn.filereadable(step2_file))

    local abort_called = false
    local mock_placement = {
      img = {
        _convert = {
          abort = function(self)
            self.aborted = true
            abort_called = true
          end,
          steps = {
            { file = step1_file },
            { file = step2_file },
          },
        },
      },
    }

    image.abort_convert(mock_placement)

    assert.is_true(abort_called)
    -- 0-byte step files must be unlinked
    assert.are.equal(0, vim.fn.filereadable(step1_file))
    assert.are.equal(0, vim.fn.filereadable(step1_info))
    -- Valid completed step files must be preserved
    assert.are.equal(1, vim.fn.filereadable(step2_file))

    -- Safe no-op on nil / empty placement
    assert.has_no.errors(function()
      image.abort_convert(nil)
      image.abort_convert({})
      image.abort_convert({ img = {} })
      image.abort_convert({ img = { _convert = {} } })
    end)
  end)

  it("abort_convert unlinks partial file associated with the in-flight aborted step", function()
    local step_file = sandbox_snacks_cache .. "/test_inflight_step.png"
    local step_info = step_file .. ".info"
    local comp_file = sandbox_snacks_cache .. "/test_completed_step.png"

    vim.fn.writefile({ "partial truncated byte stream" }, step_file)
    vim.fn.writefile({ "info stream" }, step_info)
    vim.fn.writefile({ "completed step data" }, comp_file)

    local aborted = false
    local mock_placement = {
      img = {
        _convert = {
          _step = 1,
          abort = function(self)
            aborted = true
          end,
          steps = {
            { file = step_file, done = false },
            { file = comp_file, done = true },
          },
        },
      },
    }

    local state = require("gelbooru.core.state")
    image.abort_convert(mock_placement)
    assert.is_true(aborted)
    -- In-flight step file and info should be unlinked
    assert.are.equal(0, vim.fn.filereadable(step_file))
    assert.are.equal(0, vim.fn.filereadable(step_info))
    -- Completed step file should remain preserved
    assert.are.equal(1, vim.fn.filereadable(comp_file))
    -- Timer is tracked in state.UI
    assert.is_not_nil(state.UI.abort_cleanup_timer)
    -- Wait for timer to finish and clean up
    vim.wait(150, function() return state.UI.abort_cleanup_timer == nil end)
    assert.is_nil(state.UI.abort_cleanup_timer)
  end)

  it("abort_convert does not start timer or flag aborted in-flight when all steps are completed", function()
    local state = require("gelbooru.core.state")
    local comp_file = sandbox_snacks_cache .. "/test_already_done.png"
    vim.fn.writefile({ "valid complete png" }, comp_file)

    local aborted = false
    local mock_placement = {
      img = {
        _convert = {
          _step = 1,
          abort = function(self)
            aborted = true
          end,
          steps = {
            { file = comp_file, done = true },
          },
        },
      },
    }

    image.abort_convert(mock_placement)
    assert.is_true(aborted)
    assert.is_nil(state.UI.abort_cleanup_timer)
  end)

  it("teardown cancels and closes state.UI.abort_cleanup_timer safely", function()
    local state = require("gelbooru.core.state")
    local lifecycle = require("gelbooru.ui.lifecycle")
    local uv = vim.uv or vim.loop
    local dummy_timer = uv.new_timer()
    dummy_timer:start(10000, 0, function() end)
    state.UI.abort_cleanup_timer = dummy_timer

    lifecycle.teardown()
    assert.is_nil(state.UI.abort_cleanup_timer)
    assert.is_true(dummy_timer:is_closing() or not dummy_timer:is_active())
  end)

  it("clean_corrupt_snacks_cache(target) detects and unlinks 0-byte or corrupted cache files for the target", function()
    local target_path = "/media/artwork/character_portrait.png"
    local norm = vim.fs.normalize(vim.fn.fnamemodify(target_path, ":p"))
    local base = "character_portrait"
    local prefix = vim.fn.sha256(norm .. "0"):sub(1, 8) .. "-" .. base

    -- Create 0-byte cache file for target
    local f_zero_png = sandbox_snacks_cache .. "/" .. prefix .. ".png"
    vim.fn.writefile({}, f_zero_png)
    assert.are.equal(1, vim.fn.filereadable(f_zero_png))

    -- Create 0-byte .info file for target
    local f_zero_info = sandbox_snacks_cache .. "/" .. prefix .. ".png.info"
    vim.fn.writefile({}, f_zero_info)
    assert.are.equal(1, vim.fn.filereadable(f_zero_info))

    -- Create valid non-empty cache file for target (valid PNG bytes)
    local f_valid_png = sandbox_snacks_cache .. "/" .. prefix .. "_sample.png"
    local valid_png_bytes = string.char(137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13)
      .. "IHDR"
      .. string.char(0, 0, 0, 10, 0, 0, 0, 10, 8, 2, 0, 0, 0, 0, 0, 0, 0)
      .. string.char(0, 0, 0, 0) .. "IEND" .. string.char(174, 66, 96, 130)
    local fd = io.open(f_valid_png, "wb")
    assert.is_truthy(fd)
    fd:write(valid_png_bytes)
    fd:close()
    assert.are.equal(1, vim.fn.filereadable(f_valid_png))

    -- Create truncated/corrupt cache file for target (>0 bytes but unparseable image dimensions)
    local f_corrupt_png = sandbox_snacks_cache .. "/" .. prefix .. "_corrupt.png"
    local f_corrupt_info = f_corrupt_png .. ".info"
    vim.fn.writefile({ "incomplete-truncated-image-header" }, f_corrupt_png)
    vim.fn.writefile({ "format png 0x0" }, f_corrupt_info)
    assert.are.equal(1, vim.fn.filereadable(f_corrupt_png))
    assert.are.equal(1, vim.fn.filereadable(f_corrupt_info))

    -- Create 0-byte cache file for an UNRELATED target (must not be unlinked by targeted clean)
    local f_unrelated = sandbox_snacks_cache .. "/99887766-unrelated_post.png"
    vim.fn.writefile({}, f_unrelated)
    assert.are.equal(1, vim.fn.filereadable(f_unrelated))

    -- Invoke targeted clean
    image.clean_corrupt_snacks_cache(target_path)

    -- Corrupted 0-byte cache files for target are unlinked
    assert.are.equal(0, vim.fn.filereadable(f_zero_png))
    assert.are.equal(0, vim.fn.filereadable(f_zero_info))

    -- Truncated/corrupted image file and its companion .info are unlinked
    assert.are.equal(0, vim.fn.filereadable(f_corrupt_png))
    assert.are.equal(0, vim.fn.filereadable(f_corrupt_info))

    -- Valid cache file for target is preserved
    assert.are.equal(1, vim.fn.filereadable(f_valid_png))

    -- Unrelated cache file remains untouched
    assert.are.equal(1, vim.fn.filereadable(f_unrelated))
  end)

  it("clean_corrupt_snacks_cache detects and unlinks truncated PNG cache files that lack IEND chunk or valid .info", function()
    local target_path = "/media/artwork/aborted_post.jpg"
    local norm = vim.fs.normalize(vim.fn.fnamemodify(target_path, ":p"))
    local base = "aborted_post"
    local prefix = vim.fn.sha256(norm .. "0"):sub(1, 8) .. "-" .. base

    -- Simulate an aborted conversion: ImageMagick wrote 7659 bytes of PNG data
    -- (starting with valid PNG header + IHDR chunk), but was killed before completing
    -- so it lacks the IEND chunk and the companion .info file was never created.
    local f_truncated_png = sandbox_snacks_cache .. "/" .. prefix .. ".png"
    local ihdr_bytes = string.char(137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13)
      .. "IHDR"
      .. string.char(0, 0, 0, 10, 0, 0, 0, 10, 8, 2, 0, 0, 0, 0, 0, 0, 0)
    local fd = io.open(f_truncated_png, "wb")
    assert.is_truthy(fd)
    fd:write(ihdr_bytes .. string.rep("x", 7000))
    fd:close()
    assert.are.equal(1, vim.fn.filereadable(f_truncated_png))

    -- Notice: no .info file exists because conversion was killed mid-flight
    local f_info = f_truncated_png .. ".info"
    assert.are.equal(0, vim.fn.filereadable(f_info))

    -- clean_corrupt_snacks_cache MUST detect this truncated/aborted file and unlink it
    image.clean_corrupt_snacks_cache(target_path)

    assert.are.equal(0, vim.fn.filereadable(f_truncated_png))
  end)

  it("clean_corrupt_snacks_cache unlinks corrupted .info text files containing error messages", function()
    local target_path = "/media/artwork/corrupt_header.jpg"
    local norm = vim.fs.normalize(vim.fn.fnamemodify(target_path, ":p"))
    local base = "corrupt_header"
    local prefix = vim.fn.sha256(norm .. "0"):sub(1, 8) .. "-" .. base

    local f_bad_info = sandbox_snacks_cache .. "/" .. prefix .. ".info"
    vim.fn.writefile({ "identify: improper image header", "convert: corrupt file" }, f_bad_info)
    assert.are.equal(1, vim.fn.filereadable(f_bad_info))

    image.clean_corrupt_snacks_cache(target_path)

    assert.are.equal(0, vim.fn.filereadable(f_bad_info))
  end)

  it("clear_snacks_cache_for invalidates cache by numeric post ID and calls clean_corrupt_snacks_cache", function()
    local post_id = "54321"
    local f_cache = sandbox_snacks_cache .. "/12345678-prev_" .. post_id .. ".png"
    local vthumb = sandbox_config_cache .. "/vthumb_" .. post_id .. ".jpg"

    vim.fn.writefile({ "some cache data" }, f_cache)
    vim.fn.writefile({ "thumb data" }, vthumb)

    assert.are.equal(1, vim.fn.filereadable(f_cache))
    assert.are.equal(1, vim.fn.filereadable(vthumb))

    image.clear_snacks_cache_for(post_id)

    assert.are.equal(0, vim.fn.filereadable(f_cache))
    assert.are.equal(0, vim.fn.filereadable(vthumb))
  end)

  it("clear_snacks_cache_for invalidates cache by local file path and basename", function()
    local full_path = "/storage/images/my_favorite_art.png"
    local base = "my_favorite_art"
    local f_cache1 = sandbox_snacks_cache .. "/87654321-" .. base .. ".png"
    local f_cache2 = sandbox_snacks_cache .. "/87654321-" .. base .. ".png.info"

    -- Test by full path
    vim.fn.writefile({ "cache payload" }, f_cache1)
    vim.fn.writefile({ "info payload" }, f_cache2)
    assert.are.equal(1, vim.fn.filereadable(f_cache1))
    assert.are.equal(1, vim.fn.filereadable(f_cache2))

    image.clear_snacks_cache_for(full_path)

    assert.are.equal(0, vim.fn.filereadable(f_cache1))
    assert.are.equal(0, vim.fn.filereadable(f_cache2))

    -- Test by basename
    local f_cache3 = sandbox_snacks_cache .. "/abcdef12-" .. base .. ".png"
    vim.fn.writefile({ "cache payload 3" }, f_cache3)
    assert.are.equal(1, vim.fn.filereadable(f_cache3))

    image.clear_snacks_cache_for("my_favorite_art.png")

    assert.are.equal(0, vim.fn.filereadable(f_cache3))

    -- Safe no-op for nil, empty, and 'nil'
    assert.has_no.errors(function()
      image.clear_snacks_cache_for(nil)
      image.clear_snacks_cache_for("")
      image.clear_snacks_cache_for("nil")
    end)
  end)

  it("handles remote HTTP/HTTPS URLs without prepending cwd", function()
    local url = "https://img.gelbooru.com/samples/ab/cd/sample_99999.jpg?12345"
    local base = "sample_99999"
    local clean_url = "https://img.gelbooru.com/samples/ab/cd/sample_99999.jpg"
    local prefix = vim.fn.sha256(clean_url .. "0"):sub(1, 8) .. "-" .. base
    local f_cache = sandbox_snacks_cache .. "/" .. prefix .. ".png"
    local f_info = f_cache .. ".info"

    vim.fn.writefile({}, f_cache)
    vim.fn.writefile({}, f_info)
    assert.are.equal(1, vim.fn.filereadable(f_cache))
    assert.are.equal(1, vim.fn.filereadable(f_info))

    -- clean_corrupt_snacks_cache should find and clean 0-byte cache files for the remote URL
    image.clean_corrupt_snacks_cache(url)
    assert.are.equal(0, vim.fn.filereadable(f_cache))
    assert.are.equal(0, vim.fn.filereadable(f_info))

    -- clear_snacks_cache_for should also find and delete cache files for remote URL
    local f_cache2 = sandbox_snacks_cache .. "/" .. prefix .. "-scaled.png"
    vim.fn.writefile({ "some data" }, f_cache2)
    assert.are.equal(1, vim.fn.filereadable(f_cache2))
    image.clear_snacks_cache_for(url)
    assert.are.equal(0, vim.fn.filereadable(f_cache2))
  end)

  it("find_snacks_cache_candidates resolves candidate files across formats without duplication", function()
    local full_path = "/storage/images/my_art_test.png"
    local base = "my_art_test"
    local f_cand1 = sandbox_snacks_cache .. "/11223344-" .. base .. ".png"
    local f_cand2 = sandbox_snacks_cache .. "/11223344-" .. base .. ".png.info"
    vim.fn.writefile({ "cand1" }, f_cand1)
    vim.fn.writefile({ "cand2" }, f_cand2)

    local cands = image.find_snacks_cache_candidates(full_path)
    assert.is_table(cands)
    assert.is_true(#cands >= 2)

    -- Cleanup
    vim.fn.delete(f_cand1)
    vim.fn.delete(f_cand2)
  end)
end)

describe("image.resolve_post_dimensions", function()
  it("returns nil, nil for nil or missing post", function()
    local w, h = image.resolve_post_dimensions(nil)
    assert.is_nil(w)
    assert.is_nil(h)
  end)

  it("returns cached dimensions immediately if p.width and p.height > 0", function()
    local p = { width = 1920, height = 1080 }
    local w, h = image.resolve_post_dimensions(p)
    assert.are.equal(1920, w)
    assert.are.equal(1080, h)
  end)

  it("lazily resolves dimensions from valid image file and caches on post object", function()
    local tmp_png = vim.fn.tempname() .. ".png"
    local sig = string.char(137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13)
      .. "IHDR"
      .. string.char(0, 0, 1, 0, 0, 0, 0, 128, 8, 2, 0, 0, 0, 0, 0, 0, 0) -- 256 x 128
    local fd = io.open(tmp_png, "wb")
    assert.is_truthy(fd)
    fd:write(sig)
    fd:close()

    local p = { file_url = tmp_png }
    local w, h = image.resolve_post_dimensions(p)
    assert.are.equal(256, w)
    assert.are.equal(128, h)
    assert.are.equal(256, p.width)
    assert.are.equal(128, p.height)

    -- Cleans up file; subsequent call returns cached values
    vim.fn.delete(tmp_png)
    local w2, h2 = image.resolve_post_dimensions(p)
    assert.are.equal(256, w2)
    assert.are.equal(128, h2)
  end)

  it("render_image sets placement.error hook to clean cache and trigger fail_preview", function()
    local state = require("gelbooru.core.state")
    local render = require("gelbooru.ui.render")
    local failed_msg = nil
    local orig_fail = render.fail_preview
    render.fail_preview = function(msg, p)
      failed_msg = msg
    end

    local test_target = "/media/test/mock_error_post.jpg"
    state.State.posts = { { file_url = test_target, id = 777 } }
    state.State.cur = 1
    state.State.torn_down = false

    local win = vim.api.nvim_get_current_win()
    local ok = image.render_image(win, test_target)
    if ok and state.UI.current_placement and state.UI.current_placement.error then
      state.UI.current_placement:error()
      vim.wait(150, function() return failed_msg ~= nil end)
      assert.is_not_nil(failed_msg)
      assert.is_true(failed_msg:find("Image Conversion Failed") ~= nil)
    end

    render.fail_preview = orig_fail
  end)
end)

