local config = require("gelbooru.core.config")
local constants = require("gelbooru.core.constants")
local state = require("gelbooru.core.state")

describe("lua.gelbooru.media.resolver", function()
  local resolver
  local tmp_dir
  local prev_save_dir
  local prev_cache_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    vim.fn.mkdir(tmp_dir .. "/cache", "p")
    vim.fn.mkdir(tmp_dir .. "/save", "p")
    vim.fn.mkdir(tmp_dir .. "/snacks_cache", "p")

    prev_save_dir = config.options.save_dir
    prev_cache_dir = config.options.cache_dir
    config.options.save_dir = tmp_dir .. "/save"
    config.options.cache_dir = tmp_dir .. "/cache"

    state.reset_query_state()
    resolver = require("gelbooru.media.resolver")
    resolver._snacks_cache_dir = tmp_dir .. "/snacks_cache"
  end)

  after_each(function()
    config.options.save_dir = prev_save_dir
    config.options.cache_dir = prev_cache_dir
    vim.fn.delete(tmp_dir, "rf")
  end)

  local function write_file(path_rel, bytes)
    local full_path = tmp_dir .. "/" .. path_rel
    local parent = vim.fn.fnamemodify(full_path, ":h")
    if vim.fn.isdirectory(parent) ~= 1 then
      vim.fn.mkdir(parent, "p")
    end
    local f = assert(io.open(full_path, "wb"))
    f:write(bytes)
    f:close()
    return full_path
  end

  local function sample_png()
    local sig = string.char(137, 80, 78, 71, 13, 10, 26, 10)
    local ihdr_len = string.char(0, 0, 0, 13)
    local ihdr_type = "IHDR"
    local width_bytes = string.char(0, 0, 3, 32) -- 800
    local height_bytes = string.char(0, 0, 2, 88) -- 600
    local ihdr_tail = string.char(8, 2, 0, 0, 0, 0, 0, 0, 0)
    local iend = string.char(0, 0, 0, 0) .. "IEND" .. string.char(174, 66, 96, 130)
    return sig .. ihdr_len .. ihdr_type .. width_bytes .. height_bytes .. ihdr_tail .. iend
  end

  local function sample_jpg(w, h)
    w = w or 1920
    h = h or 1080
    local soi = string.char(255, 216)
    local sof0 = string.char(255, 192)
    local sof_len = string.char(0, 17)
    local precision = string.char(8)
    local height = string.char(math.floor(h / 256), h % 256)
    local width = string.char(math.floor(w / 256), w % 256)
    local tail = string.char(3, 1, 17, 0, 2, 17, 1, 3, 17, 1)
    local eoi = string.char(255, 217)
    return soi .. sof0 .. sof_len .. precision .. height .. width .. tail .. string.rep("A", 600) .. eoi
  end

  describe("read_image_dimensions", function()
    it("extracts dimensions from PNG IHDR header", function()
      local p = write_file("test.png", sample_png())
      local w, h = resolver.read_image_dimensions(p)
      assert.are.equal(800, w)
      assert.are.equal(600, h)
    end)

    it("extracts dimensions from GIF87a and GIF89a headers", function()
      local p87 = write_file("test87.gif", "GIF87a" .. string.char(64, 1, 240, 0) .. ";")
      local w87, h87 = resolver.read_image_dimensions(p87)
      assert.are.equal(320, w87)
      assert.are.equal(240, h87)

      local p89 = write_file("test89.gif", "GIF89a" .. string.char(128, 7, 56, 4) .. ";")
      local w89, h89 = resolver.read_image_dimensions(p89)
      assert.are.equal(1920, w89)
      assert.are.equal(1080, h89)
    end)

    it("extracts dimensions from WebP VP8, VP8L, and VP8X", function()
      -- VP8
      local riff_vp8 = "RIFF" .. string.char(40, 0, 0, 0) .. "WEBP"
      local chunk_vp8 = "VP8 " .. string.char(20, 0, 0, 0) .. string.char(0, 0, 0, 157, 1, 42, 128, 2, 224, 1)
      local p_vp8 = write_file("vp8.webp", riff_vp8 .. chunk_vp8 .. string.rep("\0", 20))
      local w1, h1 = resolver.read_image_dimensions(p_vp8)
      assert.are.equal(640, w1)
      assert.are.equal(480, h1)

      -- VP8L
      local riff_vp8l = "RIFF" .. string.char(40, 0, 0, 0) .. "WEBP"
      local chunk_vp8l = "VP8L" .. string.char(10, 0, 0, 0) .. string.char(47, 255, 195, 191, 0)
      local p_vp8l = write_file("vp8l.webp", riff_vp8l .. chunk_vp8l .. string.rep("\0", 20))
      local w2, h2 = resolver.read_image_dimensions(p_vp8l)
      assert.are.equal(1024, w2)
      assert.are.equal(768, h2)

      -- VP8X
      local riff_vp8x = "RIFF" .. string.char(50, 0, 0, 0) .. "WEBP"
      local chunk_vp8x = "VP8X" .. string.char(10, 0, 0, 0) .. string.char(0, 0, 0, 0, 255, 14, 0, 111, 8, 0)
      local p_vp8x = write_file("vp8x.webp", riff_vp8x .. chunk_vp8x .. string.rep("\0", 20))
      local w3, h3 = resolver.read_image_dimensions(p_vp8x)
      assert.are.equal(3840, w3)
      assert.are.equal(2160, h3)
    end)

    it("extracts dimensions from baseline SOF0 and progressive SOF2 JPEG", function()
      local p_sof0 = write_file("sof0.jpg", sample_jpg(1920, 1080))
      local w0, h0 = resolver.read_image_dimensions(p_sof0)
      assert.are.equal(1920, w0)
      assert.are.equal(1080, h0)

      local soi = string.char(255, 216)
      local sof2 = string.char(255, 194, 0, 17, 8, 2, 208, 5, 0) .. string.rep("B", 8) .. string.char(255, 217)
      local p_sof2 = write_file("sof2.jpg", soi .. sof2)
      local w2, h2 = resolver.read_image_dimensions(p_sof2)
      assert.are.equal(1280, w2)
      assert.are.equal(720, h2)
    end)

    it("returns nil, nil for nil, empty, missing, or 0-byte files", function()
      assert.is_nil(resolver.read_image_dimensions(nil))
      assert.is_nil(resolver.read_image_dimensions(""))
      assert.is_nil(resolver.read_image_dimensions(tmp_dir .. "/missing.png"))

      local empty = write_file("empty.png", "")
      local w, h = resolver.read_image_dimensions(empty)
      assert.is_nil(w)
      assert.is_nil(h)
    end)

    it("does not spawn external CLI processes", function()
      local spawned = false
      local old_sys = vim.system
      local old_job = vim.fn.jobstart
      vim.system = function(...) spawned = true return old_sys(...) end
      vim.fn.jobstart = function(...) spawned = true return old_job(...) end

      local p = write_file("quick.png", sample_png())
      resolver.read_image_dimensions(p)

      vim.system = old_sys
      vim.fn.jobstart = old_job
      assert.is_false(spawned)
    end)
  end)

  describe("is_image_complete", function()
    it("returns false for missing or 0-byte files", function()
      assert.is_false(resolver.is_image_complete(nil))
      assert.is_false(resolver.is_image_complete(""))
      assert.is_false(resolver.is_image_complete(tmp_dir .. "/nonexistent.png"))

      local empty = write_file("zero.jpg", "")
      assert.is_false(resolver.is_image_complete(empty))
    end)

    it("verifies PNG completeness via IEND chunk presence", function()
      local p_ok = write_file("ok.png", sample_png())
      assert.is_true(resolver.is_image_complete(p_ok))

      local trunc_png = sample_png():sub(1, #sample_png() - 12)
      local p_trunc = write_file("trunc.png", trunc_png)
      assert.is_false(resolver.is_image_complete(p_trunc))
    end)

    it("verifies JPEG completeness via EOI marker presence", function()
      local p_ok = write_file("ok.jpg", sample_jpg(100, 100))
      assert.is_true(resolver.is_image_complete(p_ok))

      local trunc_jpg = sample_jpg(100, 100):sub(1, -3)
      local p_trunc = write_file("trunc.jpg", trunc_jpg)
      assert.is_false(resolver.is_image_complete(p_trunc))
    end)

    it("verifies GIF completeness via trailing semicolon", function()
      local ok_gif = write_file("ok.gif", "GIF89a" .. string.char(10, 0, 10, 0) .. ";")
      local trunc_gif = write_file("trunc.gif", "GIF89a" .. string.char(10, 0, 10, 0))
      assert.is_true(resolver.is_image_complete(ok_gif))
      assert.is_false(resolver.is_image_complete(trunc_gif))
    end)

    it("verifies WebP completeness via declared RIFF length and WEBP signature", function()
      local riff_valid = "RIFF" .. string.char(100, 0, 0, 0) .. "WEBP" .. string.rep("W", 100)
      local riff_trunc = "RIFF" .. string.char(100, 0, 0, 0) .. "WEBP" .. string.rep("W", 10)
      local riff_not_webp = "RIFF" .. string.char(100, 0, 0, 0) .. "WAVE" .. string.rep("W", 100)

      local valid_webp = write_file("complete.webp", riff_valid)
      local trunc_webp = write_file("truncated.webp", riff_trunc)
      local not_webp = write_file("audio.wav", riff_not_webp)

      assert.is_true(resolver.is_image_complete(valid_webp))
      assert.is_false(resolver.is_image_complete(trunc_webp))
      assert.is_false(resolver.is_image_complete(not_webp))
    end)

    it("scans last 64 bytes for PNG IEND chunk when trailing padding exists", function()
      local ihdr = string.char(137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13)
        .. "IHDR"
        .. string.char(0, 0, 0, 10, 0, 0, 0, 10, 8, 2, 0, 0, 0, 0, 0, 0, 0)
      local iend = string.char(0, 0, 0, 0) .. "IEND" .. string.char(174, 66, 96, 130)
      local padding = string.rep("\0", 16)

      local valid_padded = write_file("padded.png", ihdr .. iend .. padding)
      assert.is_true(resolver.is_image_complete(valid_padded))
    end)

    it("rejects HTML error payloads and arbitrary non-image text", function()
      local html_p = write_file("err.html", "<!DOCTYPE html><html><body>502 Bad Gateway</body></html>")
      local xml_p = write_file("err.xml", "<?xml version=\"1.0\"?><error>Access Denied</error>")
      local random_bin = write_file("random.bin", string.rep("\123\234\056\078", 50))
      assert.is_false(resolver.is_image_complete(html_p))
      assert.is_false(resolver.is_image_complete(xml_p))
      assert.is_false(resolver.is_image_complete(random_bin))
    end)
  end)

  describe("URL and post metadata helpers", function()
    it("file_ext_from_url extracts clean extension and defaults to jpg", function()
      assert.are.equal("png", resolver.file_ext_from_url("https://example.com/image.png?size=large#foo"))
      assert.are.equal("webm", resolver.file_ext_from_url("/home/user/video.webm"))
      assert.are.equal("jpg", resolver.file_ext_from_url("https://example.com/no_ext"))
      assert.are.equal("jpg", resolver.file_ext_from_url(nil))
    end)

    it("is_video_post identifies video extensions", function()
      assert.is_true(resolver.is_video_post({ file_url = "https://example.com/video.mp4" }))
      assert.is_true(resolver.is_video_post({ file_url = "/path/to/media.webm" }))
      assert.is_false(resolver.is_video_post({ file_url = "https://example.com/art.png" }))
      assert.is_false(resolver.is_video_post(nil))
    end)

    it("preview_source_name correctly classifies URL source", function()
      local p = {
        sample_url = "https://example.com/sample.jpg",
        preview_url = "https://example.com/thumb.jpg",
        file_url = "https://example.com/orig.jpg",
      }
      assert.are.equal("sample", resolver.preview_source_name(p, p.sample_url))
      assert.are.equal("thumbnail", resolver.preview_source_name(p, p.preview_url))
      assert.are.equal("original", resolver.preview_source_name(p, p.file_url))
      assert.are.equal("preview", resolver.preview_source_name(p, "https://example.com/other.jpg"))
    end)

    it("is_in_save_dir accurately checks path against configured save_dir", function()
      local inside = tmp_dir .. "/save/image1.png"
      local outside = tmp_dir .. "/cache/prev_1.png"
      assert.is_true(resolver.is_in_save_dir(inside))
      assert.is_false(resolver.is_in_save_dir(outside))
      assert.is_false(resolver.is_in_save_dir(nil))
    end)
  end)

  describe("Cache forensics and scrubbing", function()
    it("clean_corrupt_snacks_cache deletes 0-byte and truncated cache files but preserves valid ones", function()
      local corrupt_0 = write_file("snacks_cache/corrupt-0.jpg", "")
      local corrupt_info = write_file("snacks_cache/error.info", "identify: improper image header")
      local valid_f = write_file("snacks_cache/valid.jpg", sample_jpg(100, 100))

      resolver.clean_corrupt_snacks_cache("corrupt-0")
      assert.are.equal(0, vim.fn.filereadable(corrupt_0))

      resolver.clean_corrupt_snacks_cache("error")
      assert.are.equal(0, vim.fn.filereadable(corrupt_info))

      resolver.clean_corrupt_snacks_cache("valid")
      assert.are.equal(1, vim.fn.filereadable(valid_f))
    end)

    it("clear_cache purges volatile cache files while strictly protecting save_dir", function()
      local post_id = 12345
      local volatile_prev = write_file("cache/prev_" .. post_id .. ".jpg", sample_jpg(100, 100))
      local volatile_vthumb = write_file("cache/vthumb_" .. post_id .. ".jpg", sample_jpg(100, 100))
      local snacks_cand = write_file("snacks_cache/ab12cd34-" .. post_id .. ".jpg", sample_jpg(100, 100))
      local permanent_saved = write_file("save/" .. post_id .. ".jpg", sample_jpg(100, 100))

      resolver.clear_cache(post_id)

      assert.are.equal(0, vim.fn.filereadable(volatile_prev), "Volatile preview cache should be deleted")
      assert.are.equal(0, vim.fn.filereadable(volatile_vthumb), "Volatile video thumbnail should be deleted")
      assert.are.equal(0, vim.fn.filereadable(snacks_cand), "Snacks cache candidate should be deleted")
      assert.are.equal(1, vim.fn.filereadable(permanent_saved), "Permanent file in save_dir MUST NOT be deleted")
    end)
  end)

  describe("resolve public seam", function()
    it("returns error callback when post is nil", function()
      local cb_called = false
      resolver.resolve(nil, nil, function(res, err)
        cb_called = true
        assert.is_nil(res)
        assert.is_not_nil(err)
      end)
      assert.is_true(cb_called)
    end)

    it("resolves valid local image post directly without network downloads", function()
      local local_img = write_file("local_gallery/photo.png", sample_png())
      local post = {
        is_local = true,
        file_url = local_img,
      }

      local cb_res, cb_err
      resolver.resolve(post, nil, function(res, err)
        cb_res = res
        cb_err = err
      end)

      assert.is_nil(cb_err)
      assert.is_not_nil(cb_res)
      assert.are.equal(local_img, cb_res.path)
      assert.is_false(cb_res.is_video)
      assert.is_false(cb_res.is_thumbnail)
      assert.are.equal(800, cb_res.width)
      assert.are.equal(600, cb_res.height)
      assert.are.equal(800, post.width)
      assert.are.equal(600, post.height)
    end)

    it("returns error for missing or corrupted local image post", function()
      local post_missing = {
        is_local = true,
        file_url = tmp_dir .. "/does_not_exist.png",
      }
      local cb_res, cb_err
      resolver.resolve(post_missing, nil, function(res, err)
        cb_res = res
        cb_err = err
      end)
      assert.is_nil(cb_res)
      assert.is_not_nil(cb_err)

      local corrupt_img = write_file("corrupt.png", "NOT_A_PNG")
      local post_corrupt = {
        is_local = true,
        file_url = corrupt_img,
      }
      resolver.resolve(post_corrupt, nil, function(res, err)
        cb_res = res
        cb_err = err
      end)
      assert.is_nil(cb_res)
      assert.is_not_nil(cb_err)
    end)

    it("resolves saved post from save_dir before attempting remote candidate downloads", function()
      local post_id = 99999
      local saved_path = write_file("save/" .. post_id .. ".png", sample_png())
      local post = {
        id = post_id,
        sample_url = "https://example.com/sample.jpg",
        preview_url = "https://example.com/preview.jpg",
        file_url = "https://example.com/full.png",
      }

      local cb_res, cb_err
      resolver.resolve(post, nil, function(res, err)
        cb_res = res
        cb_err = err
      end)

      assert.is_nil(cb_err)
      assert.is_not_nil(cb_res)
      assert.are.equal(saved_path, cb_res.path)
      assert.is_false(cb_res.is_video)
      assert.is_false(cb_res.is_thumbnail)
      assert.are.equal(800, cb_res.width)
      assert.are.equal(600, cb_res.height)
    end)

    it("follows candidate fallback order: sample_url -> preview_url -> file_url", function()
      local download = require("gelbooru.net.download")
      local download_attempts = {}

      local orig_download = download.download_async
      download.download_async = function(url, dest, cb)
        table.insert(download_attempts, url)
        if url == "https://example.com/sample.jpg" then
          -- Fail first candidate (sample_url)
          cb(false)
        elseif url == "https://example.com/preview.jpg" then
          -- Succeed on second candidate (preview_url)
          local content = sample_jpg(320, 240)
          local f = assert(io.open(dest, "wb"))
          f:write(content)
          f:close()
          cb(true)
        else
          cb(false)
        end
      end

      local post = {
        id = 54321,
        sample_url = "https://example.com/sample.jpg",
        preview_url = "https://example.com/preview.jpg",
        file_url = "https://example.com/full.png",
      }

      local cb_res, cb_err
      resolver.resolve(post, nil, function(res, err)
        cb_res = res
        cb_err = err
      end)

      download.download_async = orig_download

      assert.is_nil(cb_err)
      assert.is_not_nil(cb_res)
      assert.are.same({
        "https://example.com/sample.jpg",
        "https://example.com/preview.jpg",
      }, download_attempts)
      assert.is_true(cb_res.path:find("prev_54321.jpg", 1, true) ~= nil)
      assert.is_true(cb_res.is_thumbnail)
      assert.are.equal(320, cb_res.width)
      assert.are.equal(240, cb_res.height)
    end)

    it("reports error when all candidate URLs fail to download", function()
      local download = require("gelbooru.net.download")
      local orig_download = download.download_async
      download.download_async = function(url, dest, cb)
        cb(false)
      end

      local post = {
        id = 88888,
        sample_url = "https://example.com/s.jpg",
        preview_url = "https://example.com/p.jpg",
        file_url = "https://example.com/f.jpg",
      }

      local cb_res, cb_err
      resolver.resolve(post, nil, function(res, err)
        cb_res = res
        cb_err = err
      end)

      download.download_async = orig_download

      assert.is_nil(cb_res)
      assert.is_not_nil(cb_err)
    end)

    it("force option clears volatile cache before resolving", function()
      local post_id = 77777
      local old_cache = write_file("cache/prev_" .. post_id .. ".jpg", sample_jpg(100, 100))
      local downloaded_new = false

      local download = require("gelbooru.net.download")
      local orig_download = download.download_async
      download.download_async = function(url, dest, cb)
        downloaded_new = true
        local f = assert(io.open(dest, "wb"))
        f:write(sample_jpg(1200, 800))
        f:close()
        cb(true)
      end

      local post = {
        id = post_id,
        sample_url = "https://example.com/sample.jpg",
      }

      local cb_res
      resolver.resolve(post, { force = true }, function(res)
        cb_res = res
      end)

      download.download_async = orig_download

      assert.is_true(downloaded_new)
      assert.is_not_nil(cb_res)
      assert.are.equal(1200, cb_res.width)
      assert.are.equal(800, cb_res.height)
    end)

    it("abort_active preserves active background downloads while ignoring stale callbacks", function()
      local download = require("gelbooru.net.download")
      local orig_download = download.download_async
      local orig_abort_all = download.abort_all
      local captured_cb = nil
      local abort_all_called = false

      download.download_async = function(url, dest, cb)
        captured_cb = cb
      end
      download.abort_all = function()
        abort_all_called = true
        orig_abort_all()
      end

      local killed_handles = {}
      local mock_handle = {
        kill = function(self, sig)
          table.insert(killed_handles, sig)
        end,
      }
      download.active_handles["/tmp/prefetch_test.jpg"] = mock_handle
      download.active_prefetch_handles["/tmp/prefetch_test.jpg"] = mock_handle

      local post = {
        id = 44444,
        sample_url = "https://example.com/slow.jpg",
      }

      local resolution_called = false
      resolver.resolve(post, nil, function(res, err)
        resolution_called = true
      end)

      assert.is_not_nil(captured_cb)
      -- User navigates away, triggering abort_active
      resolver.abort_active()

      -- resolver.abort_active must NOT invoke download.abort_all()
      assert.is_false(abort_all_called, "resolver.abort_active must not call download.abort_all()")
      -- Active background downloads and prefetch handles must continue unimpeded
      assert.are.equal(0, #killed_handles, "Background download handle must not be killed by resolver.abort_active()")
      assert.are.equal(mock_handle, download.active_handles["/tmp/prefetch_test.jpg"])
      assert.are.equal(mock_handle, download.active_prefetch_handles["/tmp/prefetch_test.jpg"])

      -- Late callback arrives after abort
      captured_cb(true)

      download.download_async = orig_download
      download.abort_all = orig_abort_all
      download.active_handles["/tmp/prefetch_test.jpg"] = nil
      download.active_prefetch_handles["/tmp/prefetch_test.jpg"] = nil
      assert.is_false(resolution_called, "Callback must be dropped after abort_active()")
    end)
  end)

  describe("video thumbnail cache path resolution and saved video lookup", function()
    it("get_video_thumbnail_path formats path with post ID if present", function()
      local thumb_path = resolver.get_video_thumbnail_path("/path/to/clip.mp4", 12345)
      assert.are.equal(config.options.cache_dir .. "/vthumb_12345.jpg", thumb_path)
    end)

    it("get_video_thumbnail_path falls back to filename when post ID is absent", function()
      local thumb_path = resolver.get_video_thumbnail_path("/media/my_video.webm", nil)
      assert.are.equal(config.options.cache_dir .. "/vthumb_my_video.jpg", thumb_path)
    end)

    it("get_saved_video_path discovers saved video file in save_dir across supported extensions", function()
      local vid_mp4 = write_file("save/5001.mp4", "fake-video-bytes")
      assert.are.equal(vid_mp4, resolver.get_saved_video_path(5001))

      local vid_webm = write_file("save/5002.webm", "fake-video-bytes")
      assert.are.equal(vid_webm, resolver.get_saved_video_path("5002"))

      assert.is_nil(resolver.get_saved_video_path(nil))
      assert.is_nil(resolver.get_saved_video_path(""))
      assert.is_nil(resolver.get_saved_video_path(9999999))
    end)
  end)

  describe("video transcoding and process tracking", function()
    local orig_system
    local orig_executable

    before_each(function()
      orig_system = vim.system
      orig_executable = vim.fn.executable
      resolver.active_ffmpeg_handles = {}
    end)

    after_each(function()
      vim.system = orig_system
      vim.fn.executable = orig_executable
      resolver.abort_video_transcodes()
    end)

    it("video posts with existing valid vthumb_<id>.jpg in cache resolve immediately without spawning processes", function()
      local vthumb = write_file("cache/vthumb_8801.jpg", sample_jpg(640, 360))
      local spawned = false
      vim.system = function(...)
        spawned = true
        return { kill = function() end }
      end

      -- 1. Local video post
      local local_post = {
        is_local = true,
        id = 8801,
        file_url = write_file("local/8801.mp4", string.rep("x", 2048)),
      }
      local cb_res
      resolver.resolve(local_post, nil, function(res) cb_res = res end)
      assert.is_not_nil(cb_res)
      assert.are.equal(vthumb, cb_res.path)
      assert.is_true(cb_res.is_video)
      assert.is_true(cb_res.is_thumbnail)
      assert.are.equal(640, cb_res.width)
      assert.are.equal(360, cb_res.height)
      assert.is_false(spawned)

      -- 2. Online video post with cached thumbnail
      local online_post = {
        id = 8801,
        file_url = "https://example.com/stream.mp4",
        preview_url = "https://example.com/preview.jpg",
      }
      cb_res = nil
      resolver.resolve(online_post, nil, function(res) cb_res = res end)
      assert.is_not_nil(cb_res)
      assert.are.equal(vthumb, cb_res.path)
      assert.is_true(cb_res.is_video)
      assert.is_true(cb_res.is_thumbnail)
      assert.are.equal(640, cb_res.width)
      assert.are.equal(360, cb_res.height)
      assert.is_false(spawned)
    end)

    it("rejects corrupt or truncated (<512 bytes) cached thumbnail and triggers regeneration", function()
      local corrupt_vthumb = write_file("cache/vthumb_8802.jpg", string.rep("x", 100))
      local spawned_cmd = nil
      vim.fn.executable = function(bin)
        if bin == "ffmpeg" then return 1 end
        return orig_executable(bin)
      end
      vim.system = function(cmd, opts, on_exit)
        spawned_cmd = cmd
        return { kill = function() end }
      end

      local post = {
        is_local = true,
        id = 8802,
        file_url = write_file("local/8802.mp4", string.rep("x", 2048)),
      }
      resolver.resolve(post, nil, function() end)

      assert.is_not_nil(spawned_cmd)
      assert.are.equal("ffmpeg", spawned_cmd[1])
    end)

    it("spawns background FFmpeg job with correct CLI arguments and tracks handle in active_ffmpeg_handles", function()
      local spawned_cmd = nil
      local exit_cb = nil
      local mock_handle = { kill = function() end }

      vim.fn.executable = function(bin)
        if bin == "ffmpeg" then return 1 end
        return orig_executable(bin)
      end
      vim.system = function(cmd, opts, on_exit)
        spawned_cmd = cmd
        exit_cb = on_exit
        return mock_handle
      end

      local vid_path = write_file("local/movie.mp4", string.rep("x", 2048))
      local post = {
        is_local = true,
        id = 9005,
        file_url = vid_path,
      }

      local res_result = nil
      resolver.resolve(post, nil, function(res)
        res_result = res
      end)

      -- Verify arguments passed to vim.system
      assert.is_not_nil(spawned_cmd)
      local expected_thumb = config.options.cache_dir .. "/vthumb_9005.jpg"
      local expected_part = expected_thumb .. ".part"
      assert.are.same({
        "ffmpeg",
        "-ss",
        "00:00:01",
        "-i",
        vid_path,
        "-frames:v",
        "1",
        "-q:v",
        "2",
        expected_part,
        "-y",
      }, spawned_cmd)

      -- Verify handle tracking
      assert.are.equal(mock_handle, resolver.active_ffmpeg_handles[mock_handle])

      -- Simulate successful FFmpeg exit: ffmpeg writes to .part, resolver atomically renames
      write_file("cache/vthumb_9005.jpg.part", sample_jpg(1280, 720))
      exit_cb({ code = 0 })

      -- Wait for vim.schedule
      local done = false
      vim.schedule(function() done = true end)
      vim.wait(200, function() return done end)

      -- Handle removed from active table
      assert.is_nil(resolver.active_ffmpeg_handles[mock_handle])

      -- Resolve callback yielded verified thumbnail
      assert.is_not_nil(res_result)
      assert.are.equal(expected_thumb, res_result.path)
      assert.is_true(res_result.is_video)
      assert.is_true(res_result.is_thumbnail)
      assert.are.equal(1280, res_result.width)
      assert.are.equal(720, res_result.height)
    end)

    it("abort_video_transcodes sends SIGKILL to all active handles and clears the table", function()
      local killed = {}
      local handle1 = { kill = function(self, sig) table.insert(killed, { id = 1, sig = sig }) end }
      local handle2 = { kill = function(self, sig) table.insert(killed, { id = 2, sig = sig }) end }
      local handle3 = { kill = function(self, sig) table.insert(killed, { id = 3, sig = sig }) end }

      resolver.active_ffmpeg_handles[handle1] = handle1
      resolver.active_ffmpeg_handles[handle2] = handle2
      resolver.active_ffmpeg_handles[handle3] = handle3

      assert.are.equal(3, vim.tbl_count(resolver.active_ffmpeg_handles))

      resolver.abort_video_transcodes()

      assert.are.equal(3, #killed)
      assert.are.equal(9, killed[1].sig)
      assert.are.equal(9, killed[2].sig)
      assert.are.equal(9, killed[3].sig)
      assert.are.equal(0, vim.tbl_count(resolver.active_ffmpeg_handles))

      -- Subsequent invocation is a safe no-op
      assert.has_no.errors(function()
        resolver.abort_video_transcodes()
      end)
    end)

    it("abort_video_transcodes protects against handles whose kill() throws", function()
      local bad_handle = {
        kill = function() error("Process already dead or permission denied") end,
      }
      local good_handle = {
        killed = false,
        kill = function(self, sig)
          self.killed = true
          assert.are.equal(9, sig)
        end,
      }

      resolver.active_ffmpeg_handles[bad_handle] = bad_handle
      resolver.active_ffmpeg_handles[good_handle] = good_handle

      assert.has_no.errors(function()
        resolver.abort_video_transcodes()
      end)

      assert.is_true(good_handle.killed)
      assert.are.equal(0, vim.tbl_count(resolver.active_ffmpeg_handles))
    end)

    it("abort_active calls abort_video_transcodes and suppresses stale callbacks", function()
      local exit_cb = nil
      local killed_sig = nil
      local mock_handle = {
        kill = function(self, sig)
          killed_sig = sig
        end,
      }

      vim.fn.executable = function() return 1 end
      vim.system = function(cmd, opts, on_exit)
        exit_cb = on_exit
        return mock_handle
      end

      local vid_path = write_file("local/clip.mp4", string.rep("x", 2048))
      local post = {
        is_local = true,
        id = 9911,
        file_url = vid_path,
      }

      local callback_called = false
      resolver.resolve(post, nil, function(res)
        callback_called = true
      end)

      assert.is_not_nil(exit_cb)
      assert.are.equal(mock_handle, resolver.active_ffmpeg_handles[mock_handle])

      -- User navigates away
      resolver.abort_active()

      assert.are.equal(9, killed_sig)
      assert.are.equal(0, vim.tbl_count(resolver.active_ffmpeg_handles))

      -- Late exit arrives after abort
      write_file("cache/vthumb_9911.jpg", sample_jpg(100, 100))
      exit_cb({ code = 0 })

      local done = false
      vim.schedule(function() done = true end)
      vim.wait(200, function() return done end)

      assert.is_false(callback_called, "Resolution callback must not be invoked after abort")
    end)

    it("cleans up partial or 0-byte thumbnail files if FFmpeg was aborted mid-transcode", function()
      local exit_cb = nil
      local mock_handle = { kill = function() end }

      vim.fn.executable = function() return 1 end
      vim.system = function(cmd, opts, on_exit)
        exit_cb = on_exit
        return mock_handle
      end

      local vid_path = write_file("local/interrupted.mp4", string.rep("x", 2048))
      local post = {
        is_local = true,
        id = 9922,
        file_url = vid_path,
      }

      resolver.resolve(post, nil, function() end)

      -- Create 0-byte / truncated thumbnail and .part representing partial write when killed
      local partial_thumb = write_file("cache/vthumb_9922.jpg", "")
      local partial_part = write_file("cache/vthumb_9922.jpg.part", "")
      assert.are.equal(1, vim.fn.filereadable(partial_thumb))
      assert.are.equal(1, vim.fn.filereadable(partial_part))

      resolver.abort_video_transcodes()

      -- Exit callback fires after kill with non-zero exit
      exit_cb({ code = 137 })

      local done = false
      vim.schedule(function() done = true end)
      vim.wait(200, function() return done end)

      assert.are.equal(0, vim.fn.filereadable(partial_thumb), "Partial thumbnail file should be deleted on abort")
      assert.are.equal(0, vim.fn.filereadable(partial_part), "Partial .part file should be deleted on abort")
    end)

    it("handles missing ffmpeg executable gracefully by falling back without error", function()
      vim.fn.executable = function(tool)
        if tool == "ffmpeg" then return 0 end
        return orig_executable(tool)
      end

      local vid_path = write_file("local/nofmt.mp4", string.rep("x", 2048))
      local post = {
        is_local = true,
        id = 9933,
        file_url = vid_path,
        width = 1920,
        height = 1080,
      }

      local cb_res
      resolver.resolve(post, nil, function(res)
        cb_res = res
      end)

      assert.is_not_nil(cb_res)
      assert.are.equal(vid_path, cb_res.path)
      assert.is_true(cb_res.is_video)
      assert.is_false(cb_res.is_thumbnail)
      assert.are.equal(1920, cb_res.width)
      assert.are.equal(1080, cb_res.height)
    end)

    it("abort_active aborts video transcodes and increments request id without upward canvas dependency", function()
      local canvas = require("gelbooru.ui.canvas")
      local orig_close = canvas.close
      local close_called = false
      canvas.close = function()
        close_called = true
      end

      local orig_abort_transcodes = resolver.abort_video_transcodes
      local abort_transcodes_called = false
      resolver.abort_video_transcodes = function()
        abort_transcodes_called = true
      end

      local prev_req_id = resolver._active_request_id or 0
      resolver.abort_active()
      canvas.close = orig_close
      resolver.abort_video_transcodes = orig_abort_transcodes

      assert.is_false(close_called, "abort_active must not call canvas.close() (presentation responsibility)")
      assert.is_true(abort_transcodes_called, "abort_active must call abort_video_transcodes()")
      assert.are.equal(prev_req_id + 1, resolver._active_request_id)
    end)

    it("is_info_corrupt accurately identifies corrupt content", function()
      assert.is_true(resolver.is_info_corrupt(nil))
      assert.is_true(resolver.is_info_corrupt(""))
      assert.is_true(resolver.is_info_corrupt("identify: unable to open image"))
      assert.is_true(resolver.is_info_corrupt("improper image header"))
      assert.is_true(resolver.is_info_corrupt("Error: decoding failed"))
      assert.is_true(resolver.is_info_corrupt("corrupt file"))
      assert.is_false(resolver.is_info_corrupt("PNG 800 600"))
    end)

    it("extract_video_thumbnail uses passed post object directly without inspecting state.State.posts", function()
      local state = require("gelbooru.core.state")
      local orig_posts = state.State.posts
      state.State.posts = nil -- deliberately nil to verify no access

      local vid_path = write_file("local/direct_post.mp4", string.rep("x", 2048))
      local post = {
        id = 8888,
        file_url = vid_path,
      }

      local orig_executable = vim.fn.executable
      vim.fn.executable = function() return 0 end -- fast exit

      local thumb_result
      resolver.extract_video_thumbnail(vid_path, post, function(tpath)
        thumb_result = tpath
      end)

      vim.fn.executable = orig_executable
      state.State.posts = orig_posts
      assert.is_nil(thumb_result) -- ffmpeg not executable, but executed safely without touching state.State.posts
    end)
  end)
end)
