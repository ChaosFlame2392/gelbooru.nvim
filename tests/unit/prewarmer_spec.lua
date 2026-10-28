-- tests/unit/prewarmer_spec.lua
-- Unit tests for gelbooru.media.prewarmer facade and delegation to net.download.

local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")
local constants = require("gelbooru.core.constants")
local download = require("gelbooru.net.download")

describe("gelbooru.media.prewarmer facade", function()
  local prewarmer
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    config.options.cache_dir = tmp_dir .. "/cache"
    vim.fn.mkdir(config.options.cache_dir, "p")

    package.loaded["gelbooru.media.prewarmer"] = nil
    prewarmer = require("gelbooru.media.prewarmer")
    prewarmer.reset()
    download.abort_all()
    if download.reset_rate_governor then
      download.reset_rate_governor()
    end
  end)

  after_each(function()
    if prewarmer then
      prewarmer.stop()
      prewarmer.reset()
    end
    download.abort_all()
    vim.fn.delete(tmp_dir, "rf")
  end)

  local function write_valid_jpeg(path, size)
    local parent = vim.fn.fnamemodify(path, ":h")
    vim.fn.mkdir(parent, "p")
    local f = io.open(path, "wb")
    if f then
      local valid_jpeg = string.char(
        0xFF, 0xD8,
        0xFF, 0xC0, 0x00, 0x11, 0x08,
        0x04, 0x00, 0x04, 0x00,
        0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00
      ) .. string.rep("A", size or 2048) .. string.char(0xFF, 0xD9)
      f:write(valid_jpeg)
      f:close()
    end
  end

  describe("prewarm_file", function()
    it("verifies readable valid image, caches status in prewarmed_cache, and calls cb(true)", function()
      local img_path = tmp_dir .. "/img1.jpg"
      write_valid_jpeg(img_path, 2048)

      local done = false
      local result_ok
      prewarmer.prewarm_file(img_path, function(ok)
        done = true
        result_ok = ok
      end)

      assert.is_true(done)
      assert.is_true(result_ok)
      assert.is_true(prewarmer.is_prewarmed(img_path))
      assert.is_true(prewarmer.has_converted_artifact(img_path))
    end)

    it("cached image returns immediately on repeated calls without re-inspecting", function()
      local img_path = tmp_dir .. "/cached.jpg"
      write_valid_jpeg(img_path, 2048)
      prewarmer.prewarmed_cache[img_path] = true

      local called = false
      prewarmer.prewarm_file(img_path, function(ok)
        called = ok
      end)

      assert.is_true(called)
    end)

    it("handles missing or unreadable files gracefully", function()
      local done = false
      local result_ok, err_msg
      prewarmer.prewarm_file(tmp_dir .. "/missing.jpg", function(ok, err)
        done = true
        result_ok = ok
        err_msg = err
      end)

      assert.is_true(done)
      assert.is_false(result_ok)
      assert.is_truthy(err_msg)
    end)

    it("handles corrupt image files gracefully", function()
      local corrupt_path = tmp_dir .. "/corrupt.jpg"
      local f = io.open(corrupt_path, "wb")
      f:write("corrupt not a jpeg")
      f:close()

      local done = false
      local result_ok, err_msg
      prewarmer.prewarm_file(corrupt_path, function(ok, err)
        done = true
        result_ok = ok
        err_msg = err
      end)

      assert.is_true(done)
      assert.is_false(result_ok)
      assert.is_truthy(err_msg)
    end)
  end)

  describe("prewarm_post delegation", function()
    it("delegates local image post readiness to download.ensure_ready", function()
      local img_path = tmp_dir .. "/local_post.jpg"
      write_valid_jpeg(img_path, 2048)
      local post = { id = 100, is_local = true, file_url = img_path }

      local done = false
      local result_ok
      prewarmer.prewarm_post(post, function(ok)
        done = true
        result_ok = ok
      end)

      vim.wait(300, function() return done end, 10)
      assert.is_true(done)
      assert.is_true(result_ok)
      assert.is_true(prewarmer.is_prewarmed(img_path))
    end)

    it("rejects post with _pending_delete immediately", function()
      local post = { id = 101, _pending_delete = true }
      local done = false
      local result_ok
      prewarmer.prewarm_post(post, function(ok)
        done = true
        result_ok = ok
      end)

      assert.is_true(done)
      assert.is_false(result_ok)
    end)

    it("handles video post with existing thumbnail by caching both thumb and video path", function()
      local vid_path = tmp_dir .. "/video_102.mp4"
      local f = io.open(vid_path, "wb")
      f:write("dummy video data")
      f:close()

      local thumb_path = config.options.cache_dir .. "/vthumb_102.jpg"
      write_valid_jpeg(thumb_path, 2048)

      local post = { id = 102, is_local = true, file_url = vid_path, is_video = true }

      local done = false
      local result_ok
      prewarmer.prewarm_post(post, function(ok)
        done = true
        result_ok = ok
      end)

      vim.wait(300, function() return done end, 10)
      assert.is_true(done)
      assert.is_true(result_ok)
      assert.is_true(prewarmer.is_prewarmed(thumb_path))
      assert.is_true(prewarmer.is_prewarmed(vid_path))
    end)
  end)

  describe("prewarm_posts batch & lookahead", function()
    it("dispatches ensure_ready for lookahead and reverse posts", function()
      local posts = {}
      for i = 1, 10 do
        local p = tmp_dir .. string.format("/item_%d.jpg", i)
        write_valid_jpeg(p, 2048)
        table.insert(posts, { id = i, is_local = true, file_url = p })
      end

      prewarmer.prewarm_posts(posts, 5, 1)

      -- Lookahead from 5 forward (6..10) plus reverse (4) should be ready/cached
      vim.wait(500, function()
        return prewarmer.is_prewarmed(posts[6].file_url) and prewarmer.is_prewarmed(posts[4].file_url)
      end, 20)

      assert.is_true(prewarmer.is_prewarmed(posts[6].file_url))
      assert.is_true(prewarmer.is_prewarmed(posts[4].file_url))
    end)

    it("schedule_lookahead is an alias for prewarm_posts", function()
      assert.are.equal(prewarmer.prewarm_posts, prewarmer.schedule_lookahead)
    end)
  end)

  describe("prune_queue, reorder_queue & lifecycle", function()
    it("prunes out-of-radius tasks from prewarmer.queue and delegates to download.prune_out_of_radius", function()
      local cancelled = {}
      for i = 1, 5 do
        table.insert(prewarmer.queue, {
          path = "/tmp/item_" .. i .. ".jpg",
          post_idx = i * 10,
          cb = function(ok, err)
            table.insert(cancelled, { idx = i * 10, ok = ok, err = err })
          end,
        })
      end

      prewarmer.prune_queue(20, 10)

      assert.are.equal(3, #prewarmer.queue)
      assert.are.equal(10, prewarmer.queue[1].post_idx)
      assert.are.equal(20, prewarmer.queue[2].post_idx)
      assert.are.equal(30, prewarmer.queue[3].post_idx)
      assert.are.equal(2, #cancelled)
    end)

    it("reorder_queue delegates to download.reorder_prefetch_queue", function()
      assert.is_function(prewarmer.reorder_queue)
      prewarmer.reorder_queue(5, -1)
    end)

    it("stop and reset clear queue, active conversions, jobs, and cache", function()
      prewarmer.prewarmed_cache["test.jpg"] = true
      table.insert(prewarmer.queue, { path = "queued.jpg" })
      prewarmer.active_conversions["conv"] = true
      prewarmer.active_jobs["job"] = { conv = nil }

      prewarmer.stop()
      assert.are.equal(0, #prewarmer.queue)
      assert.are.equal(0, vim.tbl_count(prewarmer.active_conversions))
      assert.are.equal(0, vim.tbl_count(prewarmer.active_jobs))
      assert.is_true(prewarmer.is_prewarmed("test.jpg"))

      prewarmer.reset()
      assert.is_false(prewarmer.is_prewarmed("test.jpg"))
    end)

    it("invalidate removes specific items from prewarmed_cache", function()
      prewarmer.prewarmed_cache["/path/to/img_99.jpg"] = true
      prewarmer.prewarmed_cache["99"] = true
      assert.is_true(prewarmer.is_prewarmed("/path/to/img_99.jpg"))

      prewarmer.invalidate(99)
      assert.is_false(prewarmer.is_prewarmed("/path/to/img_99.jpg"))
      assert.is_false(prewarmer.is_prewarmed("99"))
    end)
  end)
end)
