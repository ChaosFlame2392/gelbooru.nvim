local config = require("gelbooru.core.config")
local constants = require("gelbooru.core.constants")
local transcoder = require("gelbooru.media.transcoder")

describe("lua.gelbooru.media.transcoder", function()
  local tmp_dir
  local prev_save_dir
  local prev_cache_dir
  local orig_system
  local orig_executable

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    vim.fn.mkdir(tmp_dir .. "/cache", "p")
    vim.fn.mkdir(tmp_dir .. "/save", "p")

    prev_save_dir = config.options.save_dir
    prev_cache_dir = config.options.cache_dir
    config.options.save_dir = tmp_dir .. "/save"
    config.options.cache_dir = tmp_dir .. "/cache"

    orig_system = vim.system
    orig_executable = vim.fn.executable

    transcoder.active_ffmpeg_handles = {}
    transcoder._ffmpeg_thumb_dests = {}
    transcoder._aborted_handles = {}
    transcoder.clean_cache_hook = nil
  end)

  after_each(function()
    config.options.save_dir = prev_save_dir
    config.options.cache_dir = prev_cache_dir
    vim.system = orig_system
    vim.fn.executable = orig_executable
    transcoder.abort_video_transcodes()
    vim.fn.delete(tmp_dir, "rf")
  end)

  local function write_file(rel_path, bytes)
    local full_path = tmp_dir .. "/" .. rel_path
    local parent = vim.fn.fnamemodify(full_path, ":h")
    if vim.fn.isdirectory(parent) ~= 1 then
      vim.fn.mkdir(parent, "p")
    end
    local f = assert(io.open(full_path, "wb"))
    f:write(bytes)
    f:close()
    return full_path
  end

  local function sample_jpg(w, h)
    w = w or 640
    h = h or 360
    local soi = string.char(255, 216)
    local sof0 = string.char(255, 192, 0, 17, 8, math.floor(h / 256), h % 256, math.floor(w / 256), w % 256, 3, 1, 17, 0, 2, 17, 1, 3, 17, 1)
    local eoi = string.char(255, 217)
    return soi .. sof0 .. string.rep("A", 600) .. eoi
  end

  describe("is_video_post", function()
    it("returns true for posts with is_video flag", function()
      assert.is_true(transcoder.is_video_post({ is_video = true }))
    end)

    it("returns true for video file extensions in file_url", function()
      assert.is_true(transcoder.is_video_post({ file_url = "https://example.com/media/clip.mp4" }))
      assert.is_true(transcoder.is_video_post({ file_url = "https://example.com/media/clip.webm" }))
      assert.is_true(transcoder.is_video_post({ file_url = "https://example.com/media/clip.mkv" }))
      assert.is_true(transcoder.is_video_post({ file_url = "https://example.com/media/clip.mov" }))
      assert.is_true(transcoder.is_video_post({ file_url = "https://example.com/media/clip.avi" }))
    end)

    it("returns false for image extensions or nil/empty posts", function()
      assert.is_false(transcoder.is_video_post({ file_url = "https://example.com/art.png" }))
      assert.is_false(transcoder.is_video_post({ file_url = "https://example.com/photo.jpg" }))
      assert.is_false(transcoder.is_video_post({ file_url = "https://example.com/anim.gif" }))
      assert.is_false(transcoder.is_video_post({ file_url = "https://example.com/doc.webp" }))
      assert.is_false(transcoder.is_video_post(nil))
      assert.is_false(transcoder.is_video_post({}))
    end)
  end)

  describe("get_video_thumbnail_path and get_saved_video_path", function()
    it("formats video thumbnail path in cache_dir with post ID", function()
      local p = transcoder.get_video_thumbnail_path("/path/to/video.mp4", 12345)
      assert.are.equal(tmp_dir .. "/cache/vthumb_12345.jpg", p)
    end)

    it("falls back to file stem if post_id is nil", function()
      local p = transcoder.get_video_thumbnail_path("/path/to/sample_clip.mp4", nil)
      assert.are.equal(tmp_dir .. "/cache/vthumb_sample_clip.jpg", p)
    end)

    it("locates saved video in save_dir across extensions", function()
      local saved_file = write_file("save/9999.webm", string.rep("x", 1024))
      local found = transcoder.get_saved_video_path(9999)
      assert.are.equal(saved_file, found)
    end)

    it("returns nil if post is not saved in save_dir", function()
      assert.is_nil(transcoder.get_saved_video_path(8888))
      assert.is_nil(transcoder.get_saved_video_path(nil))
    end)
  end)

  describe("abort_video_transcodes and handle tracking", function()
    it("terminates all active handles with SIGKILL, unlinks .part, and deletes corrupt thumbnails", function()
      local killed_sig = nil
      local mock_handle = {
        kill = function(self, sig) killed_sig = sig end,
        thumb_dest = tmp_dir .. "/cache/vthumb_777.jpg",
        thumb_part = tmp_dir .. "/cache/vthumb_777.jpg.part",
      }

      write_file("cache/vthumb_777.jpg.part", "incomplete part")
      write_file("cache/vthumb_777.jpg", "corrupt tiny")

      local cleaned_cache_target = nil
      transcoder.clean_cache_hook = function(tgt) cleaned_cache_target = tgt end

      transcoder.active_ffmpeg_handles[mock_handle] = mock_handle
      transcoder.abort_video_transcodes()

      assert.are.equal(9, killed_sig)
      assert.is_true(mock_handle._aborted)
      assert.are.equal(0, vim.tbl_count(transcoder.active_ffmpeg_handles))
      assert.are.equal(0, vim.fn.filereadable(mock_handle.thumb_part))
      assert.are.equal(0, vim.fn.filereadable(mock_handle.thumb_dest))
      assert.are.equal(mock_handle.thumb_dest, cleaned_cache_target)
    end)
  end)

  describe("extract_video_thumbnail", function()
    it("returns existing valid thumbnail immediately without spawning ffmpeg", function()
      local vthumb = write_file("cache/vthumb_456.jpg", sample_jpg(640, 360))
      local spawned = false
      vim.system = function(...)
        spawned = true
        return { kill = function() end }
      end

      local post = { id = 456, file_url = write_file("save/456.mp4", string.rep("v", 1024)) }
      local res_path
      transcoder.extract_video_thumbnail(post.file_url, post, function(p) res_path = p end)

      assert.are.equal(vthumb, res_path)
      assert.is_false(spawned)
    end)

    it("spawns ffmpeg with correct arguments and tracks handle", function()
      local spawned_cmd = nil
      vim.fn.executable = function(bin)
        if bin == "ffmpeg" then return 1 end
        return orig_executable(bin)
      end

      local fake_handle = { kill = function() end }
      vim.system = function(cmd, opts, on_exit)
        spawned_cmd = cmd
        return fake_handle
      end

      local video = write_file("save/101.mp4", string.rep("v", 1024))
      local handle = transcoder.extract_video_thumbnail(video, 101, function() end)

      assert.is_not_nil(spawned_cmd)
      assert.are.equal("ffmpeg", spawned_cmd[1])
      assert.are.equal("-ss", spawned_cmd[2])
      assert.are.equal("00:00:01", spawned_cmd[3])
      assert.are.equal("-i", spawned_cmd[4])
      assert.are.equal(video, spawned_cmd[5])
      assert.are.equal("-frames:v", spawned_cmd[6])
      assert.are.equal("1", spawned_cmd[7])
      assert.are.equal("-q:v", spawned_cmd[8])
      assert.are.equal("2", spawned_cmd[9])
      assert.are.equal(tmp_dir .. "/cache/vthumb_101.jpg.part", spawned_cmd[10])
      assert.are.equal("-y", spawned_cmd[11])
      assert.are.equal(fake_handle, transcoder.active_ffmpeg_handles[fake_handle])
    end)

    it("returns nil if ffmpeg is not executable", function()
      vim.fn.executable = function(bin)
        if bin == "ffmpeg" then return 0 end
        return orig_executable(bin)
      end

      local video = write_file("save/102.mp4", string.rep("v", 1024))
      local called = false
      local res = nil
      transcoder.extract_video_thumbnail(video, 102, function(p)
        called = true
        res = p
      end)

      assert.is_true(called)
      assert.is_nil(res)
    end)
  end)

  describe("transcode_animation_loop", function()
    it("invokes callback with nil as a clean extension seam", function()
      local called = false
      local res = "not-nil"
      transcoder.transcode_animation_loop("/dummy/video.mp4", {}, function(p)
        called = true
        res = p
      end)
      assert.is_true(called)
      assert.is_nil(res)
    end)
  end)

  describe("coalesce_animation_frames", function()
    it("returns existing cached frame files immediately without spawning process when frame_000.png exists", function()
      local anim_dir = tmp_dir .. "/cache/anim_test_cached"
      vim.fn.mkdir(anim_dir, "p")
      write_file("cache/anim_test_cached/frame_000.png", "frame0")
      write_file("cache/anim_test_cached/frame_001.png", "frame1")

      local spawned = false
      vim.system = function(...)
        spawned = true
        return { kill = function() end }
      end

      local done_ok = nil
      local done_files = nil
      local handle = transcoder.coalesce_animation_frames("/dummy/anim.gif", anim_dir, function(ok, files)
        done_ok = ok
        done_files = files
      end)

      assert.is_nil(handle)
      assert.is_false(spawned)
      assert.is_true(done_ok)
      assert.are.equal(2, #done_files)
    end)

    it("spawns magick/convert with -coalesce asynchronously, tracks handle in active_handles, and cleans up", function()
      local anim_dir = tmp_dir .. "/cache/anim_test_async"
      local spawned_cmd = nil
      local exit_cb = nil

      vim.fn.executable = function(bin)
        if bin == "magick" then return 1 end
        return orig_executable(bin)
      end

      local fake_handle = { kill = function() end }
      vim.system = function(cmd, opts, on_exit)
        spawned_cmd = cmd
        exit_cb = on_exit
        return fake_handle
      end

      local done_ok = nil
      local done_files = nil
      local handle = transcoder.coalesce_animation_frames("/dummy/anim.gif", anim_dir, function(ok, files)
        done_ok = ok
        done_files = files
      end)

      assert.are.equal(fake_handle, handle)
      assert.are.equal(fake_handle, transcoder.active_handles[fake_handle])
      assert.are.equal("magick", spawned_cmd[1])
      assert.are.equal("/dummy/anim.gif", spawned_cmd[2])
      assert.are.equal("-coalesce", spawned_cmd[3])
      assert.are.equal(anim_dir .. "/frame_%03d.png", spawned_cmd[4])

      -- Create output frame files before exiting process
      write_file("cache/anim_test_async/frame_000.png", "frame0")
      write_file("cache/anim_test_async/frame_001.png", "frame1")

      exit_cb({ code = 0 })
      vim.wait(100, function() return done_ok ~= nil end, 10)

      assert.is_true(done_ok)
      assert.are.equal(2, #done_files)
      assert.is_nil(transcoder.active_handles[fake_handle])
    end)

    it("terminates in-flight coalescing handle on abort_video_transcodes() via SIGKILL", function()
      local anim_dir = tmp_dir .. "/cache/anim_test_abort"
      local killed_sig = nil
      local fake_handle = {
        kill = function(self, sig)
          killed_sig = sig
        end,
      }

      vim.fn.executable = function(bin)
        if bin == "magick" then return 1 end
        return orig_executable(bin)
      end

      vim.system = function(cmd, opts, on_exit)
        return fake_handle
      end

      local done_ok = nil
      local handle = transcoder.coalesce_animation_frames("/dummy/anim.gif", anim_dir, function(ok)
        done_ok = ok
      end)

      assert.are.equal(fake_handle, handle)
      assert.are.equal(fake_handle, transcoder.active_handles[fake_handle])

      transcoder.abort_video_transcodes()

      assert.are.equal(constants.SIGKILL or 9, killed_sig)
      assert.is_nil(transcoder.active_handles[fake_handle])
    end)

    it("returns false if neither magick nor convert is executable", function()
      vim.fn.executable = function(bin)
        if bin == "magick" or bin == "convert" then return 0 end
        return orig_executable(bin)
      end

      local done_ok = nil
      local handle = transcoder.coalesce_animation_frames("/dummy/anim.gif", tmp_dir .. "/anim_no_tool", function(ok)
        done_ok = ok
      end)

      assert.is_nil(handle)
      assert.is_false(done_ok)
    end)
  end)
end)
