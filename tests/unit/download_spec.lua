-- tests/unit/download_spec.lua
-- Unit tests for gelbooru.net.download: retry logic, referer injection,
-- atomic rename, callback deduplication, file size verification,
-- error recovery, process lifecycle, and lookahead prefetch pipeline.

local download = require("gelbooru.net.download")
local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")

local tmp = vim.fn.tempname

describe("download: deduplication & caching", function()
  local orig_system

  before_each(function()
    download.active_downloads = {}
    download.active_handles = {}
    download.interrupted_dests = {}
    download.pending_resumes = {}
    orig_system = vim.system
  end)

  after_each(function()
    vim.system = orig_system
  end)

  it("returns immediately with cb(true) when dest already exists on disk", function()
    local dest = tmp()
    local f = io.open(dest, "wb")
    f:write(string.rep("x", 2048))
    f:close()

    local called_with = nil
    download.download_async("http://example.com/fake.jpg", dest, function(ok)
      called_with = ok
    end)

    assert.is_true(called_with)
    assert.is_nil(download.active_downloads[dest])
    vim.fn.delete(dest)
  end)

  it("deduplicates concurrent calls to same destination URL and notifies all callbacks", function()
    local dest = tmp()
    local part = dest .. ".part"
    local spawn_count = 0
    local exit_fn = nil

    vim.system = function(cmd, opts, on_exit)
      spawn_count = spawn_count + 1
      exit_fn = on_exit
      return { kill = function() end }
    end

    local cb1_result, cb2_result, cb3_result = nil, nil, nil
    download.download_async("https://gelbooru.com/img/1.jpg", dest, function(ok) cb1_result = ok end)
    download.download_async("https://gelbooru.com/img/1.jpg", dest, function(ok) cb2_result = ok end)
    download.download_async("https://gelbooru.com/img/1.jpg", dest, function(ok) cb3_result = ok end)

    -- Exactly one curl process spawned, 3 callbacks queued
    assert.are.equal(1, spawn_count)
    assert.are.equal(3, #download.active_downloads[dest])

    -- Write valid part file and simulate successful download exit
    local f = io.open(part, "wb")
    f:write(string.rep("x", 2048))
    f:close()

    exit_fn({ code = 0 })
    vim.wait(200, function() return cb1_result ~= nil and cb2_result ~= nil and cb3_result ~= nil end)

    assert.is_true(cb1_result)
    assert.is_true(cb2_result)
    assert.is_true(cb3_result)
    assert.is_nil(download.active_downloads[dest])
    assert.is_nil(download.active_handles[dest])
    assert.are.equal(1, vim.fn.filereadable(dest))

    vim.fn.delete(dest)
  end)
end)

describe("download: curl arguments, retry options & referer injection", function()
  local orig_system

  before_each(function()
    download.active_downloads = {}
    download.active_handles = {}
    download.interrupted_dests = {}
    download.pending_resumes = {}
    orig_system = vim.system
  end)

  after_each(function()
    vim.system = orig_system
  end)

  it("injects Referer header for Gelbooru CDN domains in download_async", function()
    local dest = tmp()
    local captured_cmd = nil

    vim.system = function(cmd, opts, on_exit)
      captured_cmd = cmd
      return { kill = function() end }
    end

    download.download_async("https://gelbooru.com/images/sample.jpg", dest, function() end)

    assert.is_not_nil(captured_cmd)
    local has_referer_flag = false
    local has_referer_value = false
    for i, arg in ipairs(captured_cmd) do
      if arg == "-H" and captured_cmd[i + 1] == "Referer: https://gelbooru.com/" then
        has_referer_flag = true
        has_referer_value = true
        break
      end
    end
    assert.is_true(has_referer_flag)
    assert.is_true(has_referer_value)
  end)

  it("includes retry logic flags (--retry 3, --retry-delay 2, --retry-connrefused) in download_async", function()
    local dest = tmp()
    local captured_cmd = nil

    vim.system = function(cmd, opts, on_exit)
      captured_cmd = cmd
      return { kill = function() end }
    end

    download.download_async("https://gelbooru.com/img.jpg", dest, function() end)

    assert.is_not_nil(captured_cmd)
    assert.is_true(vim.tbl_contains(captured_cmd, "--retry"))
    assert.is_true(vim.tbl_contains(captured_cmd, "3"))
    assert.is_true(vim.tbl_contains(captured_cmd, "--retry-delay"))
    assert.is_true(vim.tbl_contains(captured_cmd, "2"))
    assert.is_true(vim.tbl_contains(captured_cmd, "--retry-connrefused"))
    assert.is_true(vim.tbl_contains(captured_cmd, "--fail"))
  end)

  it("includes retry logic flags in curl_async", function()
    local captured_cmd = nil

    vim.system = function(cmd, opts, on_exit)
      captured_cmd = cmd
      return { kill = function() end }
    end

    download.curl_async("https://gelbooru.com/index.php?page=dapi", function() end)

    assert.is_not_nil(captured_cmd)
    assert.is_true(vim.tbl_contains(captured_cmd, "--retry"))
    assert.is_true(vim.tbl_contains(captured_cmd, "3"))
    assert.is_true(vim.tbl_contains(captured_cmd, "--retry-delay"))
    assert.is_true(vim.tbl_contains(captured_cmd, "2"))
    assert.is_true(vim.tbl_contains(captured_cmd, "--retry-connrefused"))
    assert.is_true(vim.tbl_contains(captured_cmd, "--fail"))
  end)

  it("adds -C - resume argument when .part file > 1024 bytes and resume=true", function()
    local dest = tmp()
    local part = dest .. ".part"
    local f = io.open(part, "wb")
    f:write(string.rep("x", 2048))
    f:close()

    local captured_cmd = nil
    vim.system = function(cmd, opts, on_exit)
      captured_cmd = cmd
      return { kill = function() end }
    end

    download.download_async("https://example.com/big.mp4", dest, function() end, { resume = true })

    assert.is_not_nil(captured_cmd)
    local has_c = false
    for i, arg in ipairs(captured_cmd) do
      if arg == "-C" and captured_cmd[i + 1] == "-" then
        has_c = true
        break
      end
    end
    assert.is_true(has_c)

    vim.fn.delete(part)
  end)
end)

describe("download: atomic file rename & size verification", function()
  local orig_system

  before_each(function()
    download.active_downloads = {}
    download.active_handles = {}
    download.interrupted_dests = {}
    download.pending_resumes = {}
    orig_system = vim.system
  end)

  after_each(function()
    vim.system = orig_system
  end)

  it("atomically renames .part to destination file on successful download (> 1024 bytes)", function()
    local dest = tmp()
    local part = dest .. ".part"
    local exit_fn = nil

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      -- Simulate curl writing valid payload > 1024 bytes
      local f = io.open(part, "wb")
      f:write(string.rep("data", 512))
      f:close()
      return { kill = function() end }
    end

    local result = nil
    download.download_async("https://example.com/valid.jpg", dest, function(ok)
      result = ok
    end)

    assert.is_not_nil(exit_fn)
    exit_fn({ code = 0 })
    vim.wait(200, function() return result ~= nil end)

    assert.is_true(result)
    assert.are.equal(1, vim.fn.filereadable(dest))
    assert.are.equal(0, vim.fn.filereadable(part))
    assert.is_true(vim.fn.getfsize(dest) > 1024)

    vim.fn.delete(dest)
  end)

  it("safely replaces destination if created during download before rename", function()
    local dest = tmp()
    local part = dest .. ".part"
    local exit_fn = nil

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      -- Pre-create dest during in-flight download before curl finishes
      local f_old = io.open(dest, "wb")
      f_old:write("concurrently created file")
      f_old:close()

      local f = io.open(part, "wb")
      f:write(string.rep("new_data", 512))
      f:close()
      return { kill = function() end }
    end

    local result = nil
    download.download_async("https://example.com/overwrite.jpg", dest, function(ok)
      result = ok
    end)

    assert.is_not_nil(exit_fn)
    exit_fn({ code = 0 })
    vim.wait(200, function() return result ~= nil end)

    assert.is_true(result)
    assert.are.equal(1, vim.fn.filereadable(dest))
    assert.are.equal(0, vim.fn.filereadable(part))

    vim.fn.delete(dest)
  end)

  it("rejects download and deletes .part when file size is <= 1024 bytes (truncated/empty)", function()
    local dest = tmp()
    local part = dest .. ".part"
    local exit_fn = nil

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      -- Write truncated payload (<= 1024 bytes)
      local f = io.open(part, "wb")
      f:write("tiny error payload")
      f:close()
      return { kill = function() end }
    end

    local result = nil
    download.download_async("https://example.com/tiny.jpg", dest, function(ok)
      result = ok
    end)

    assert.is_not_nil(exit_fn)
    exit_fn({ code = 0 })
    vim.wait(200, function() return result ~= nil end)

    assert.is_false(result)
    assert.are.equal(0, vim.fn.filereadable(dest))
    assert.are.equal(0, vim.fn.filereadable(part))
  end)

  it("handles missing .part file when curl exits code 0", function()
    local dest = tmp()
    local part = dest .. ".part"
    local exit_fn = nil

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      -- Do not create part file at all
      return { kill = function() end }
    end

    local result = nil
    download.download_async("https://example.com/ghost.jpg", dest, function(ok)
      result = ok
    end)

    assert.is_not_nil(exit_fn)
    exit_fn({ code = 0 })
    vim.wait(200, function() return result ~= nil end)

    assert.is_false(result)
    assert.are.equal(0, vim.fn.filereadable(dest))
  end)
end)

describe("download: failure recovery & resume flag behaviour", function()
  local orig_system

  before_each(function()
    download.active_downloads = {}
    download.active_handles = {}
    download.interrupted_dests = {}
    download.pending_resumes = {}
    orig_system = vim.system
  end)

  after_each(function()
    vim.system = orig_system
  end)

  it("deletes .part when curl exits with error and resume=false", function()
    local dest = tmp()
    local part = dest .. ".part"
    local exit_fn = nil

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      local f = io.open(part, "wb")
      f:write("partial data")
      f:close()
      return { kill = function() end }
    end

    local result = nil
    download.download_async("https://example.com/fail.jpg", dest, function(ok)
      result = ok
    end, { resume = false })

    assert.is_not_nil(exit_fn)
    exit_fn({ code = 22 }) -- HTTP error (e.g. 404)
    vim.wait(200, function() return result ~= nil end)

    assert.is_false(result)
    assert.are.equal(0, vim.fn.filereadable(part))
    assert.are.equal(0, vim.fn.filereadable(dest))
  end)

  it("preserves .part when curl exits with error and resume=true", function()
    local dest = tmp()
    local part = dest .. ".part"
    local exit_fn = nil

    -- Seed an existing .part > 1024 bytes
    local f = io.open(part, "wb")
    f:write(string.rep("x", 2048))
    f:close()

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      return { kill = function() end }
    end

    local result = nil
    download.download_async("https://example.com/resume_fail.mp4", dest, function(ok)
      result = ok
    end, { resume = true })

    assert.is_not_nil(exit_fn)
    exit_fn({ code = 28 }) -- Timeout error
    vim.wait(200, function() return result ~= nil end)

    assert.is_false(result)
    assert.are.equal(1, vim.fn.filereadable(part))
    assert.are.equal(0, vim.fn.filereadable(dest))

    vim.fn.delete(part)
  end)
end)

describe("download: curl_async execution & response handling", function()
  local orig_system

  before_each(function()
    download.active_downloads = {}
    download.active_handles = {}
    download.interrupted_dests = {}
    download.pending_resumes = {}
    orig_system = vim.system
  end)

  after_each(function()
    vim.system = orig_system
  end)

  it("invokes cb with stdout body when curl exits code 0", function()
    local exit_fn = nil
    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      return { kill = function() end }
    end

    local res_body = nil
    download.curl_async("https://gelbooru.com/api/posts", function(body)
      res_body = body
    end)

    assert.is_not_nil(exit_fn)
    exit_fn({ code = 0, stdout = '{"post": [{"id": 1}]}' })
    vim.wait(200, function() return res_body ~= nil end)

    assert.are.equal('{"post": [{"id": 1}]}', res_body)
  end)

  it("invokes cb with nil when curl exits non-zero (HTTP error or network failure)", function()
    local exit_fn = nil
    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      return { kill = function() end }
    end

    local called = false
    local res_body = "initial"
    download.curl_async("https://gelbooru.com/api/fail", function(body)
      called = true
      res_body = body
    end)

    assert.is_not_nil(exit_fn)
    exit_fn({ code = 7, stdout = nil }) -- Failed to connect
    vim.wait(200, function() return called end)

    assert.is_true(called)
    assert.is_nil(res_body)
  end)
end)

describe("download: interrupted teardown guard & abort_all", function()
  local orig_system

  before_each(function()
    download.active_downloads = {}
    download.active_handles = {}
    download.interrupted_dests = {}
    download.pending_resumes = {}
    orig_system = vim.system
  end)

  after_each(function()
    vim.system = orig_system
  end)

  it("does not rename .part when download is aborted by abort_all before process completes", function()
    local dest = tmp()
    local part = dest .. ".part"
    local killed = false
    local exit_fn = nil

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      local f = io.open(part, "wb")
      f:write(string.rep("x", 2048))
      f:close()
      return {
        kill = function(self, sig)
          killed = true
          assert.are.equal(9, sig)
        end,
      }
    end

    local cb_called = false
    local cb_result = nil
    download.download_async("https://example.com/abort.jpg", dest, function(ok)
      cb_called = true
      cb_result = ok
    end)

    assert.is_not_nil(download.active_handles[dest])

    -- Abort all in-flight downloads (simulating teardown)
    download.abort_all()
    assert.is_true(killed)
    assert.is_true(download.interrupted_dests[dest])

    -- Now simulate curl exiting after kill signal
    exit_fn({ code = 0 })
    vim.wait(200, function() return cb_called end)

    assert.is_true(cb_called)
    assert.is_false(cb_result)
    assert.are.equal(1, vim.fn.filereadable(part))
    assert.are.equal(0, vim.fn.filereadable(dest))
    assert.is_nil(download.interrupted_dests[dest])
    assert.is_nil(download.active_downloads[dest])

    vim.fn.delete(part)
  end)
end)

describe("download: safe queue pruning and error handling", function()
  local orig_system

  before_each(function()
    download.active_downloads = {}
    download.active_handles = {}
    download.interrupted_dests = {}
    download.pending_resumes = {}
    orig_system = vim.system
  end)

  after_each(function()
    vim.system = orig_system
  end)

  it("safely handles vim.system spawn errors in download_async and notifies queued callbacks", function()
    local dest = tmp()
    vim.system = function()
      error("Spawn failed: executable not found")
    end

    local result = nil
    download.download_async("https://example.com/spawn_fail.jpg", dest, function(ok)
      result = ok
    end)

    assert.is_false(result)
    assert.is_nil(download.active_downloads[dest])
    assert.is_nil(download.active_handles[dest])
  end)

  it("safely handles vim.system spawn errors in curl_async and invokes cb(nil)", function()
    vim.system = function()
      error("Spawn failed: executable not found")
    end

    local result = "unset"
    download.curl_async("https://example.com/api", function(body)
      result = body
    end)

    vim.wait(200, function() return result ~= "unset" end)
    assert.is_nil(result)
  end)

  it("continues executing subsequent callbacks if one callback throws an error", function()
    local dest = tmp()
    local part = dest .. ".part"
    local exit_fn = nil

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      local f = io.open(part, "wb")
      f:write(string.rep("x", 2048))
      f:close()
      return { kill = function() end }
    end

    local cb2_called = false
    download.download_async("https://example.com/test.jpg", dest, function()
      error("Unexpected consumer error in cb1")
    end)
    download.download_async("https://example.com/test.jpg", dest, function(ok)
      cb2_called = ok
    end)

    exit_fn({ code = 0 })
    vim.wait(200, function() return cb2_called ~= false end)

    assert.is_true(cb2_called)
    assert.is_nil(download.active_downloads[dest])

    vim.fn.delete(dest)
  end)
end)

describe("download: resume_pending_saves & timer management", function()
  local save_dir
  local orig_save_dir

  before_each(function()
    download.active_downloads = {}
    download.active_handles = {}
    download.interrupted_dests = {}
    download.pending_resumes = {}

    orig_save_dir = config.options.save_dir
    save_dir = tmp()
    vim.fn.mkdir(save_dir, "p")
    config.options.save_dir = save_dir
  end)

  after_each(function()
    download.cancel_pending_resumes()
    config.options.save_dir = orig_save_dir
    vim.fn.delete(save_dir, "rf")
  end)

  it("discovers orphaned .part files and adds them to pending_resumes", function()
    local orphan = save_dir .. "/99999.jpg.part"
    local f = io.open(orphan, "wb")
    f:write(string.rep("x", 2048))
    f:close()

    local dest = save_dir .. "/99999.jpg"
    download.resume_pending_saves()

    assert.is_not_nil(download.pending_resumes[dest])

    download.cancel_pending_resumes()
    assert.are.equal(0, vim.tbl_count(download.pending_resumes))
  end)

  it("deletes orphaned .part file if final destination already exists", function()
    local orphan = save_dir .. "/88888.jpg.part"
    local dest = save_dir .. "/88888.jpg"

    local f_orphan = io.open(orphan, "wb")
    f_orphan:write("orphan data")
    f_orphan:close()

    local f_dest = io.open(dest, "wb")
    f_dest:write("completed file")
    f_dest:close()

    download.resume_pending_saves()

    assert.are.equal(0, vim.fn.filereadable(orphan))
    assert.are.equal(1, vim.fn.filereadable(dest))
    assert.is_nil(download.pending_resumes[dest])
  end)

  it("skips files already present in pending_resumes", function()
    local orphan = save_dir .. "/77777.jpg.part"
    local dest = save_dir .. "/77777.jpg"
    local f = io.open(orphan, "wb")
    f:write(string.rep("x", 2048))
    f:close()

    -- Simulate destination already marked in pending_resumes
    download.pending_resumes[dest] = true

    download.resume_pending_saves()

    -- pending_resumes[dest] remains true (not replaced with a new timer)
    assert.are.equal(true, download.pending_resumes[dest])
  end)
end)

describe("download: eager lookahead & prefetch pipeline (Issue 4)", function()
  local orig_system
  local orig_posts
  local orig_cur
  local orig_scroll_dir
  local orig_torn_down

  before_each(function()
    download.active_downloads = {}
    download.active_handles = {}
    download.active_prefetch_handles = {}
    download.queued_prefetch_dests = {}
    download.last_prefetch_dir = nil
    download.cancel_prefetch_timers()

    orig_system = vim.system
    orig_posts = state.State.posts
    orig_cur = state.State.cur
    orig_scroll_dir = state.State.scroll_dir
    orig_torn_down = state.State.torn_down

    state.State.torn_down = false
    state.State.posts = {
      { id = 101, file_url = "http://example.com/101.jpg", sample_url = "http://example.com/101_s.jpg" },
      { id = 102, file_url = "http://example.com/102.jpg", sample_url = "http://example.com/102_s.jpg" },
      { id = 103, file_url = "http://example.com/103.jpg", sample_url = "http://example.com/103_s.jpg" },
      { id = 104, file_url = "http://example.com/104.jpg", sample_url = "http://example.com/104_s.jpg" },
    }
    state.State.cur = 1
    state.State.scroll_dir = 1
  end)

  after_each(function()
    download.cancel_prefetch_timers()
    vim.system = orig_system
    state.State.posts = orig_posts
    state.State.cur = orig_cur
    state.State.scroll_dir = orig_scroll_dir
    state.State.torn_down = orig_torn_down
  end)

  it("eliminates artificial 50ms delay and triggers immediate next post (cur + dir) synchronously", function()
    local spawned_urls = {}
    local mock_handle = { kill = function() end }

    vim.system = function(cmd, opts, on_exit)
      table.insert(spawned_urls, cmd[#cmd])
      return mock_handle
    end

    -- Trigger prefetch at index 1 with direction 1 -> immediate next is post 102
    download.prefetch_around(1, 1)

    -- Post 102 (immediate next) must have triggered download_async immediately without waiting for timers!
    assert.is_true(#spawned_urls >= 1)
    assert.are.equal("http://example.com/102_s.jpg", spawned_urls[1])
  end)

  it("does not cancel in-flight prefetch downloads if moving in the same direction", function()
    local killed = {}
    local mock_handle = {
      kill = function(self, sig)
        table.insert(killed, sig)
      end,
    }

    vim.system = function(cmd, opts, on_exit)
      return mock_handle
    end

    -- First prefetch call moving forward (dir = 1)
    download.prefetch_around(1, 1)
    assert.are.equal(1, download.last_prefetch_dir)

    local active_count_before = vim.tbl_count(download.active_prefetch_handles)
    assert.is_true(active_count_before >= 1)

    -- Second prefetch call still moving forward (dir = 1)
    download.prefetch_around(2, 1)

    -- In-flight handles should NOT have been killed
    assert.are.equal(0, #killed)
    assert.are.equal(1, download.last_prefetch_dir)
  end)

  it("cancels and aborts in-flight prefetch downloads when moving in reversed direction", function()
    local killed = {}
    local mock_handle = {
      kill = function(self, sig)
        table.insert(killed, sig)
      end,
    }

    vim.system = function(cmd, opts, on_exit)
      return mock_handle
    end

    -- Start prefetch moving forward (dir = 1)
    download.prefetch_around(1, 1)
    assert.are.equal(1, download.last_prefetch_dir)
    assert.is_true(vim.tbl_count(download.active_prefetch_handles) >= 1)

    -- Reverse scroll direction to backward (dir = -1)
    download.prefetch_around(2, -1)

    -- Opposite in-flight prefetch handles must have been killed with SIGKILL (9)
    assert.is_true(#killed >= 1)
    assert.are.equal(9, killed[1])
    assert.are.equal(-1, download.last_prefetch_dir)
  end)

  it("respects State.torn_down and performs no prefetch actions", function()
    state.State.torn_down = true
    local called = false

    vim.system = function(cmd, opts, on_exit)
      called = true
      return { kill = function() end }
    end

    download.prefetch_around(1, 1)

    assert.is_false(called)
    assert.are.equal(0, vim.tbl_count(download.active_prefetch_handles))
  end)
end)

describe("download.is_valid_media: header and trailer integrity validation", function()
  it("validates complete JPEG with SOI (FF D8) and EOI (FF D9)", function()
    local path = tmp() .. ".jpg"
    local f = io.open(path, "wb")
    f:write("\255\216" .. string.rep("x", 2048) .. "\255\217")
    f:close()

    assert.is_true(download.is_valid_media(path))
    vim.fn.delete(path)
  end)

  it("rejects truncated JPEG missing EOI marker (FF D9)", function()
    local path = tmp() .. ".jpg"
    local f = io.open(path, "wb")
    -- Truncated JPEG stream (SOI present, but ends midway through scan data)
    f:write("\255\216" .. string.rep("x", 2048) .. "\000\000")
    f:close()

    assert.is_false(download.is_valid_media(path))
    vim.fn.delete(path)
  end)

  it("rejects truncated JPEG with size < 512 bytes", function()
    local path = tmp() .. ".jpg"
    local f = io.open(path, "wb")
    f:write("\255\216" .. string.rep("x", 100) .. "\255\217")
    f:close()

    assert.is_false(download.is_valid_media(path))
    vim.fn.delete(path)
  end)

  it("validates complete PNG ending with IEND chunk", function()
    local path = tmp() .. ".png"
    local f = io.open(path, "wb")
    f:write("\137PNG\r\n\026\n" .. string.rep("x", 2048) .. "IEND\174\66\96\130")
    f:close()

    assert.is_true(download.is_valid_media(path))
    vim.fn.delete(path)
  end)

  it("rejects truncated PNG missing IEND chunk", function()
    local path = tmp() .. ".png"
    local f = io.open(path, "wb")
    f:write("\137PNG\r\n\026\n" .. string.rep("x", 2048))
    f:close()

    assert.is_false(download.is_valid_media(path))
    vim.fn.delete(path)
  end)

  it("rejects HTML error page disguised with image extension", function()
    local path = tmp() .. ".jpg"
    local f = io.open(path, "wb")
    f:write("<!DOCTYPE html><html><body><h1>503 Service Unavailable</h1></body></html>")
    f:close()

    assert.is_false(download.is_valid_media(path))
    vim.fn.delete(path)
  end)

  it("rejects non-HTTP URL in download_async and safely notifies cb(false)", function()
    local dest = tmp()
    local cb_result = nil
    local handle = download.download_async("/local/path/file.jpg", dest, function(ok)
      cb_result = ok
    end)

    assert.is_nil(handle)
    vim.wait(200, function() return cb_result ~= nil end)
    assert.is_false(cb_result)
  end)

  it("rejects non-existent file path and empty file in is_valid_media", function()
    assert.is_false(download.is_valid_media("/path/does/not/exist.jpg"))

    local empty_file = tmp() .. ".jpg"
    local f = io.open(empty_file, "wb")
    f:close()
    assert.is_false(download.is_valid_media(empty_file))
    vim.fn.delete(empty_file)
  end)

  it("validates complete GIF87a and GIF89a and rejects truncated or tiny GIF", function()
    local valid_gif89 = tmp() .. ".gif"
    local f = io.open(valid_gif89, "wb")
    f:write("GIF89a" .. string.rep("x", 256) .. ";")
    f:close()
    assert.is_true(download.is_valid_media(valid_gif89))
    vim.fn.delete(valid_gif89)

    local valid_gif87 = tmp() .. ".gif"
    f = io.open(valid_gif87, "wb")
    f:write("GIF87a" .. string.rep("x", 256) .. ";")
    f:close()
    assert.is_true(download.is_valid_media(valid_gif87))
    vim.fn.delete(valid_gif87)

    -- Truncated GIF missing ';'
    local trunc_gif = tmp() .. ".gif"
    f = io.open(trunc_gif, "wb")
    f:write("GIF89a" .. string.rep("x", 256))
    f:close()
    assert.is_false(download.is_valid_media(trunc_gif))
    vim.fn.delete(trunc_gif)

    -- Short GIF (< 128 bytes)
    local short_gif = tmp() .. ".gif"
    f = io.open(short_gif, "wb")
    f:write("GIF89a" .. string.rep("x", 50) .. ";")
    f:close()
    assert.is_false(download.is_valid_media(short_gif))
    vim.fn.delete(short_gif)
  end)

  it("validates complete WEBP and rejects corrupt or short WEBP", function()
    local valid_webp = tmp() .. ".webp"
    local f = io.open(valid_webp, "wb")
    f:write("RIFF\000\000\000\000WEBP" .. string.rep("x", 1024))
    f:close()
    assert.is_true(download.is_valid_media(valid_webp))
    vim.fn.delete(valid_webp)

    -- Corrupt WEBP: missing WEBP tag at bytes 9-12
    local corrupt_webp = tmp() .. ".webp"
    f = io.open(corrupt_webp, "wb")
    f:write("RIFF\000\000\000\000NOPE" .. string.rep("x", 1024))
    f:close()
    assert.is_false(download.is_valid_media(corrupt_webp))
    vim.fn.delete(corrupt_webp)

    -- Short WEBP (< 512 bytes)
    local short_webp = tmp() .. ".webp"
    f = io.open(short_webp, "wb")
    f:write("RIFF\000\000\000\000WEBP" .. string.rep("x", 200))
    f:close()
    assert.is_false(download.is_valid_media(short_webp))
    vim.fn.delete(short_webp)
  end)

  it("validates complete MP4/MOV and rejects corrupt or tiny video", function()
    local valid_mp4 = tmp() .. ".mp4"
    local f = io.open(valid_mp4, "wb")
    f:write("\000\000\000\020ftypmp42" .. string.rep("x", 2048))
    f:close()
    assert.is_true(download.is_valid_media(valid_mp4))
    vim.fn.delete(valid_mp4)

    -- Corrupt video missing 'ftyp'
    local corrupt_mp4 = tmp() .. ".mp4"
    f = io.open(corrupt_mp4, "wb")
    f:write("\000\000\000\020nope" .. string.rep("x", 2048))
    f:close()
    assert.is_false(download.is_valid_media(corrupt_mp4))
    vim.fn.delete(corrupt_mp4)

    -- Short video (< 1024 bytes)
    local short_mp4 = tmp() .. ".mp4"
    f = io.open(short_mp4, "wb")
    f:write("\000\000\000\020ftypmp42" .. string.rep("x", 500))
    f:close()
    assert.is_false(download.is_valid_media(short_mp4))
    vim.fn.delete(short_mp4)
  end)

  it("rejects XML error page disguised with image extension", function()
    local xml_file = tmp() .. ".png"
    local f = io.open(xml_file, "wb")
    f:write("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>AccessDenied</Code></Error>")
    f:close()
    assert.is_false(download.is_valid_media(xml_file))
    vim.fn.delete(xml_file)
  end)

  it("resolves ref_path extension for in-flight .part files", function()
    local target_dest = tmp() .. ".jpg"
    local part_file = target_dest .. ".part"
    local f = io.open(part_file, "wb")
    f:write("\255\216" .. string.rep("x", 2048) .. "\255\217")
    f:close()

    assert.is_true(download.is_valid_media(part_file, target_dest))
    vim.fn.delete(part_file)
  end)
end)

describe("download.cancel_pending_resumes and download.cancel_prefetch_timers", function()
  it("cancel_pending_resumes clears pending_resumes table and closes stored timers", function()
    local uv = vim.uv or vim.loop
    local timer = uv.new_timer()
    timer:start(10000, 0, function() end)
    download.pending_resumes = { [timer] = true }

    download.cancel_pending_resumes()

    assert.are.same({}, download.pending_resumes)
    assert.is_true(timer:is_closing())
  end)

  it("cancel_prefetch_timers closes timers and optionally kills active prefetch handles", function()
    local uv = vim.uv or vim.loop
    local timer = uv.new_timer()
    timer:start(10000, 0, function() end)
    state.UI.prefetch_timers = { [1] = timer }
    download.queued_prefetch_dests = { ["/tmp/prev.jpg"] = true }

    local killed_sig = nil
    local mock_handle = {
      kill = function(self, sig)
        killed_sig = sig
      end,
    }
    download.active_prefetch_handles = { ["/tmp/prev.jpg"] = mock_handle }

    download.cancel_prefetch_timers(true)

    assert.are.same({}, state.UI.prefetch_timers)
    assert.are.same({}, download.queued_prefetch_dests)
    assert.are.same({}, download.active_prefetch_handles)
    assert.are.equal(9, killed_sig)
  end)
end)

