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
