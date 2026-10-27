-- tests/unit/prewarmer_spec.lua
-- Unit tests for gelbooru.media.prewarmer background prewarming engine.

local mock_snacks = require("tests.integration.helpers.mock_snacks")
local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")
local resolver = require("gelbooru.media.resolver")

describe("gelbooru.media.prewarmer", function()
  local prewarmer
  local tmp_dir

  before_each(function()
    mock_snacks.setup()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    config.options.cache_dir = tmp_dir .. "/cache"
    vim.fn.mkdir(config.options.cache_dir, "p")

    package.loaded["gelbooru.media.prewarmer"] = nil
    prewarmer = require("gelbooru.media.prewarmer")
    prewarmer.reset()
  end)

  after_each(function()
    if prewarmer then
      prewarmer.stop()
      prewarmer.reset()
    end
    mock_snacks.teardown()
    vim.fn.delete(tmp_dir, "rf")
  end)

  local function make_dummy_file(rel_path, size)
    local full_path = tmp_dir .. "/" .. rel_path
    local parent = vim.fn.fnamemodify(full_path, ":h")
    vim.fn.mkdir(parent, "p")
    local f = io.open(full_path, "wb")
    if f then
      f:write(string.rep("A", size or 2048))
      f:close()
    end
    return full_path
  end

  describe("prewarm_file", function()
    it("creates snacks convert instance and calls :run() for valid file", function()
      local img_path = make_dummy_file("img1.png", 4096)
      local done = false
      local result_ok

      prewarmer.prewarm_file(img_path, function(ok)
        done = true
        result_ok = ok
      end)

      assert.is_true(#mock_snacks.conversions_created >= 1)
      assert.is_true(#mock_snacks.conversions_run >= 1)
      assert.are.equal(img_path, mock_snacks.conversions_run[1].src)

      vim.wait(500, function() return done end, 10)
      assert.is_true(done)
      assert.is_true(result_ok)
    end)

    it("caches prewarmed status on success so repeated calls are no-ops", function()
      local img_path = make_dummy_file("cached_img.jpg", 4096)
      local count = 0

      prewarmer.prewarm_file(img_path, function(ok)
        count = count + 1
      end)
      vim.wait(500, function() return count == 1 end, 10)
      assert.are.equal(1, #mock_snacks.conversions_run)

      -- Second call should recognize already prewarmed file and return immediately without running convert again
      local second_done = false
      prewarmer.prewarm_file(img_path, function(ok)
        second_done = true
      end)
      assert.is_true(second_done)
      assert.are.equal(1, #mock_snacks.conversions_run)
    end)

    it("handles non-existent or unreadable file gracefully", function()
      local missing_path = tmp_dir .. "/does_not_exist.jpg"
      local done = false
      local result_ok, err_msg

      prewarmer.prewarm_file(missing_path, function(ok, err)
        done = true
        result_ok = ok
        err_msg = err
      end)

      assert.is_true(done)
      assert.is_false(result_ok)
      assert.is_truthy(err_msg)
      assert.are.equal(0, #mock_snacks.conversions_run)
    end)

    it("handles convert error gracefully without crashing", function()
      local img_path = make_dummy_file("corrupt.png", 2048)

      -- Simulate snacks conversion error
      local orig_convert = package.loaded["snacks.image.convert"].convert
      package.loaded["snacks.image.convert"].convert = function(opts)
        local conv = orig_convert(opts)
        conv._err = "ImageMagick decode error"
        return conv
      end

      local done = false
      local result_ok, err_msg
      prewarmer.prewarm_file(img_path, function(ok, err)
        done = true
        result_ok = ok
        err_msg = err
      end)

      vim.wait(500, function() return done end, 10)
      assert.is_true(done)
      assert.is_false(result_ok)
      assert.is_truthy(err_msg)
    end)

    it("queues prewarm_file when max_concurrent jobs are active and drains automatically", function()
      -- Simulate slow running conversions that do not complete synchronously
      local orig_run = package.loaded["snacks.image.convert"].convert
      local active_on_dones = {}
      package.loaded["snacks.image.convert"].convert = function(opts)
        local conv = orig_run(opts)
        conv.run = function(self)
          self.running = true
          table.insert(mock_snacks.conversions_run, self)
          table.insert(active_on_dones, function()
            self.done_flag = true
            if opts.on_done then opts.on_done(self) end
          end)
        end
        return conv
      end

      -- Start 3 conversions (saturating max_concurrent = 3)
      local f1 = make_dummy_file("f1.png", 2048)
      local f2 = make_dummy_file("f2.png", 2048)
      local f3 = make_dummy_file("f3.png", 2048)
      local f4 = make_dummy_file("f4.png", 2048)

      prewarmer.prewarm_file(f1)
      prewarmer.prewarm_file(f2)
      prewarmer.prewarm_file(f3)

      assert.are.equal(3, #mock_snacks.conversions_run)

      -- 4th file should be queued in prewarmer.queue because active == 3
      local f4_done = false
      prewarmer.prewarm_file(f4, function(ok)
        f4_done = ok
      end)

      assert.are.equal(3, #mock_snacks.conversions_run)
      assert.are.equal(1, #prewarmer.queue)
      assert.are.equal(f4, prewarmer.queue[1].path)

      -- Finish one of the active conversions
      local finish_first = table.remove(active_on_dones, 1)
      finish_first()

      -- f4 should now be dequeued and running
      vim.wait(500, function() return #mock_snacks.conversions_run == 4 end, 10)
      assert.are.equal(4, #mock_snacks.conversions_run)
      assert.are.equal(f4, mock_snacks.conversions_run[4].src)

      -- Finish the rest
      while #active_on_dones > 0 do
        local fin = table.remove(active_on_dones, 1)
        fin()
      end
      vim.wait(500, function() return f4_done end, 10)
      assert.is_true(f4_done)
    end)

    it("conversion failure on queued prewarm_file does not block subsequent queue items", function()
      local orig_run = package.loaded["snacks.image.convert"].convert
      local active_on_dones = {}
      package.loaded["snacks.image.convert"].convert = function(opts)
        local conv = orig_run(opts)
        conv.run = function(self)
          self.running = true
          table.insert(mock_snacks.conversions_run, self)
          table.insert(active_on_dones, function()
            self.done_flag = true
            if opts.src:find("corrupt") then
              self._err = "Corrupt file"
            end
            if opts.on_done then opts.on_done(self) end
          end)
        end
        return conv
      end

      local f1 = make_dummy_file("f1.png", 2048)
      local f2 = make_dummy_file("f2.png", 2048)
      local f3 = make_dummy_file("f3.png", 2048)
      local f_corrupt = make_dummy_file("corrupt_q.png", 2048)
      local f_good = make_dummy_file("good_q.png", 2048)

      prewarmer.prewarm_file(f1)
      prewarmer.prewarm_file(f2)
      prewarmer.prewarm_file(f3)

      local corrupt_done, corrupt_ok
      prewarmer.prewarm_file(f_corrupt, function(ok)
        corrupt_done = true
        corrupt_ok = ok
      end)

      local good_done, good_ok
      prewarmer.prewarm_file(f_good, function(ok)
        good_done = true
        good_ok = ok
      end)

      assert.are.equal(2, #prewarmer.queue)

      -- Drain all conversions
      while #active_on_dones > 0 do
        local fin = table.remove(active_on_dones, 1)
        fin()
      end

      vim.wait(500, function() return corrupt_done and good_done end, 10)
      assert.is_true(corrupt_done)
      assert.is_false(corrupt_ok)
      assert.is_true(good_done)
      assert.is_true(good_ok)
    end)
  end)

  describe("prewarm_post", function()
    it("prewarms standard local image post", function()
      local img_path = make_dummy_file("local_101.jpg", 3000)
      local post = {
        id = 101,
        is_local = true,
        file_url = img_path,
      }

      local done = false
      prewarmer.prewarm_post(post, function(ok)
        done = true
      end)

      assert.is_true(#mock_snacks.conversions_run >= 1)
      assert.are.equal(img_path, mock_snacks.conversions_run[1].src)
      vim.wait(500, function() return done end, 10)
      assert.is_true(done)
    end)

    it("detects video post, extracts video thumbnail, and prewarms thumbnail", function()
      local vid_path = make_dummy_file("video_202.mp4", 5000)
      local thumb_path = config.options.cache_dir .. "/vthumb_202.jpg"
      make_dummy_file("cache/vthumb_202.jpg", 1024)

      local post = {
        id = 202,
        is_local = true,
        file_url = vid_path,
        is_video = true,
      }

      local orig_extract = resolver.extract_video_thumbnail
      local extract_called = false
      resolver.extract_video_thumbnail = function(path, p, cb)
        extract_called = true
        cb(thumb_path)
      end

      local done = false
      prewarmer.prewarm_post(post, function(ok)
        done = true
      end)

      assert.is_true(extract_called)
      assert.is_true(#mock_snacks.conversions_run >= 1)
      assert.are.equal(thumb_path, mock_snacks.conversions_run[1].src)

      vim.wait(500, function() return done end, 10)
      assert.is_true(done)

      resolver.extract_video_thumbnail = orig_extract
    end)

    it("ignores post with _pending_delete safely", function()
      local img_path = make_dummy_file("del.jpg", 2048)
      local post = {
        id = 303,
        is_local = true,
        file_url = img_path,
        _pending_delete = true,
      }

      local done = false
      local result_ok
      prewarmer.prewarm_post(post, function(ok)
        done = true
        result_ok = ok
      end)

      assert.is_true(done)
      assert.is_false(result_ok)
      assert.are.equal(0, #mock_snacks.conversions_run)
    end)
  end)

  describe("prewarm_posts batch & lookahead", function()
    it("prewarms initial posts near top on folder open (include_cur = true)", function()
      local posts = {}
      for i = 1, 10 do
        local p = make_dummy_file(string.format("item_%d.jpg", i), 2048)
        table.insert(posts, { id = i, is_local = true, file_url = p })
      end

      prewarmer.prewarm_posts(posts, 1, { dir = 1, include_cur = true, radius = 5 })

      -- Should prewarm cur (1) and cur+1 through cur+4 (posts 1..5)
      vim.wait(1000, function() return #mock_snacks.conversions_run >= 5 end, 20)
      assert.is_true(#mock_snacks.conversions_run >= 5)

      local warmed_srcs = {}
      for _, c in ipairs(mock_snacks.conversions_run) do
        warmed_srcs[c.src] = true
      end
      for i = 1, 5 do
        assert.is_true(warmed_srcs[posts[i].file_url] == true, "Post " .. i .. " should be prewarmed")
      end
    end)

    it("prioritizes lookahead posts in scroll direction with immediate reverse", function()
      local posts = {}
      for i = 1, 20 do
        local p = make_dummy_file(string.format("seq_%d.jpg", i), 2048)
        table.insert(posts, { id = i, is_local = true, file_url = p })
      end

      -- Scrolling down (dir = 1) from post 5
      prewarmer.prewarm_posts(posts, 5, 1)

      -- Forward radius is 5 (posts 6, 7, 8, 9, 10) plus reverse post 4
      vim.wait(1000, function() return #mock_snacks.conversions_run >= 6 end, 20)
      assert.is_true(#mock_snacks.conversions_run >= 6)

      local warmed_srcs = {}
      for _, c in ipairs(mock_snacks.conversions_run) do
        warmed_srcs[c.src] = true
      end
      -- Check forward targets
      for i = 6, 10 do
        assert.is_true(warmed_srcs[posts[i].file_url] == true, "Post " .. i .. " should be prewarmed")
      end
      -- Check immediate reverse target
      assert.is_true(warmed_srcs[posts[4].file_url] == true, "Post 4 (immediate reverse) should be prewarmed")
    end)

    it("prioritizes reverse direction when scrolling up (dir = -1)", function()
      local posts = {}
      for i = 1, 20 do
        local p = make_dummy_file(string.format("rev_%d.jpg", i), 2048)
        table.insert(posts, { id = i, is_local = true, file_url = p })
      end

      -- Scrolling up (dir = -1) from post 10
      prewarmer.prewarm_posts(posts, 10, -1)

      -- Backward radius is 5 (posts 9, 8, 7, 6, 5) plus immediate forward post 11
      vim.wait(1000, function() return #mock_snacks.conversions_run >= 6 end, 20)
      assert.is_true(#mock_snacks.conversions_run >= 6)

      local warmed_srcs = {}
      for _, c in ipairs(mock_snacks.conversions_run) do
        warmed_srcs[c.src] = true
      end
      for i = 5, 9 do
        assert.is_true(warmed_srcs[posts[i].file_url] == true, "Post " .. i .. " should be prewarmed")
      end
      assert.is_true(warmed_srcs[posts[11].file_url] == true, "Post 11 (immediate forward) should be prewarmed")
    end)

    it("bounds pending queue to sliding window and prunes out-of-radius tasks", function()
      local posts = {}
      for i = 1, 50 do
        local p = make_dummy_file(string.format("bound_%d.jpg", i), 2048)
        table.insert(posts, { id = i, is_local = true, file_url = p })
      end

      -- Queue posts around post 1
      prewarmer.prewarm_posts(posts, 1, 1)

      -- Large jump to post 40
      prewarmer.prewarm_posts(posts, 40, 1)

      -- Any pending jobs far from post 40 (|idx - 40| > 10) should have been pruned from queue
      for _, item in ipairs(prewarmer.queue or {}) do
        assert.is_true(math.abs(item.post_idx - 40) <= 10)
      end
    end)

    it("handles corrupted files without aborting subsequent queue items", function()
      local posts = {}
      for i = 1, 6 do
        local p = make_dummy_file(string.format("item_%d.jpg", i), 2048)
        table.insert(posts, { id = i, is_local = true, file_url = p })
      end

      -- Make post 2 fail conversion
      local orig_convert = package.loaded["snacks.image.convert"].convert
      package.loaded["snacks.image.convert"].convert = function(opts)
        local conv = orig_convert(opts)
        if opts.src == posts[2].file_url then
          conv._err = "Corrupted JPEG"
        end
        return conv
      end

      prewarmer.prewarm_posts(posts, 1, { dir = 1, include_cur = true, radius = 5 })

      -- All other posts (1, 3, 4, 5) should still be processed
      vim.wait(1000, function() return #mock_snacks.conversions_run >= 5 end, 20)
      assert.is_true(#mock_snacks.conversions_run >= 5)

      local warmed_srcs = {}
      for _, c in ipairs(mock_snacks.conversions_run) do
        warmed_srcs[c.src] = true
      end
      assert.is_true(warmed_srcs[posts[1].file_url] == true)
      assert.is_true(warmed_srcs[posts[3].file_url] == true)
      assert.is_true(warmed_srcs[posts[4].file_url] == true)
      assert.is_true(warmed_srcs[posts[5].file_url] == true)
    end)
  end)

  describe("stop & lifecycle", function()
    it("aborts active conversions and clears queues on stop()", function()
      local posts = {}
      for i = 1, 10 do
        local p = make_dummy_file(string.format("stop_%d.jpg", i), 2048)
        table.insert(posts, { id = i, is_local = true, file_url = p })
      end

      -- Prevent mock conversions from completing automatically so they stay in flight
      local orig_run = package.loaded["snacks.image.convert"].convert
      package.loaded["snacks.image.convert"].convert = function(opts)
        local conv = orig_run(opts)
        conv.run = function(self)
          self.running = true
          table.insert(mock_snacks.conversions_run, self)
          -- Don't call on_done
        end
        return conv
      end

      prewarmer.prewarm_posts(posts, 1, { dir = 1, include_cur = true, radius = 5 })
      assert.is_true(#mock_snacks.conversions_run > 0)

      prewarmer.stop()

      -- Conversions should be aborted
      assert.is_true(#mock_snacks.conversions_aborted > 0)
      assert.are.equal(0, #prewarmer.queue)
      assert.are.equal(0, vim.tbl_count(prewarmer.active_conversions))
    end)

    it("clears cache for specific item on invalidate()", function()
      local img_path = make_dummy_file("inv.jpg", 2048)
      local done = false
      prewarmer.prewarm_file(img_path, function()
        done = true
      end)
      vim.wait(500, function() return done end, 10)

      assert.is_true(prewarmer.prewarmed_cache[img_path] == true)
      prewarmer.invalidate(img_path)
      assert.is_nil(prewarmer.prewarmed_cache[img_path])
    end)

    it("prunes out-of-radius tasks via prune_queue and notifies callbacks", function()
      local cancelled = {}
      for i = 1, 5 do
        table.insert(prewarmer.queue, {
          path = "/tmp/item_" .. i .. ".jpg",
          post_idx = i * 10, -- 10, 20, 30, 40, 50
          cb = function(ok, err)
            table.insert(cancelled, { idx = i * 10, ok = ok, err = err })
          end,
        })
      end

      -- Prune around cursor 20 with window 10 (keeps [10, 30], drops 40, 50)
      assert.is_function(prewarmer.prune_queue)
      prewarmer.prune_queue(20, 10)

      assert.are.equal(3, #prewarmer.queue)
      assert.are.equal(10, prewarmer.queue[1].post_idx)
      assert.are.equal(20, prewarmer.queue[2].post_idx)
      assert.are.equal(30, prewarmer.queue[3].post_idx)

      assert.are.equal(2, #cancelled)
      assert.are.equal(40, cancelled[1].idx)
      assert.is_false(cancelled[1].ok)
      assert.are.equal(50, cancelled[2].idx)
      assert.is_false(cancelled[2].ok)
    end)
  end)
end)