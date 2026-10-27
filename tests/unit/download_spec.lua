-- tests/unit/download_spec.lua
-- Unit tests for gelbooru.net.download: retry logic, referer injection,
-- atomic rename, callback deduplication, file size verification,
-- error recovery, process lifecycle, and lookahead prefetch pipeline.

local download = require("gelbooru.net.download")
local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")
local constants = require("gelbooru.core.constants")

local tmp = vim.fn.tempname

describe("download: deduplication & caching", function()
  local orig_system

  before_each(function()
    download.abort_all()
    if download.reset_rate_governor then
      download.reset_rate_governor()
    end
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
    download.abort_all()
    if download.reset_rate_governor then
      download.reset_rate_governor()
    end
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

  it("automatically adds -C - resume argument when .part file > 1024 bytes without explicit opts.resume", function()
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

    -- Call download_async with preview target and no opts
    download.download_async("https://example.com/preview.jpg", dest, function() end)

    assert.is_not_nil(captured_cmd)
    local has_c = false
    for i, arg in ipairs(captured_cmd) do
      if arg == "-C" and captured_cmd[i + 1] == "-" then
        has_c = true
        break
      end
    end
    assert.is_true(has_c)
    assert.are.equal(1, vim.fn.filereadable(part))

    vim.fn.delete(part)
  end)

  it("does not add -C - and unlinks .part when opts.force == true even if .part > 1024 bytes", function()
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

    download.download_async("https://example.com/preview.jpg", dest, function() end, { force = true })

    assert.is_not_nil(captured_cmd)
    local has_c = false
    for i, arg in ipairs(captured_cmd) do
      if arg == "-C" and captured_cmd[i + 1] == "-" then
        has_c = true
        break
      end
    end
    assert.is_false(has_c)
    assert.are.equal(0, vim.fn.filereadable(part))
  end)

  it("does not add -C - and unlinks .part when .part size <= 1024 bytes without force", function()
    local dest = tmp()
    local part = dest .. ".part"
    local f = io.open(part, "wb")
    f:write(string.rep("x", 500))
    f:close()

    local captured_cmd = nil
    vim.system = function(cmd, opts, on_exit)
      captured_cmd = cmd
      return { kill = function() end }
    end

    download.download_async("https://example.com/small.jpg", dest, function() end)

    assert.is_not_nil(captured_cmd)
    local has_c = false
    for i, arg in ipairs(captured_cmd) do
      if arg == "-C" and captured_cmd[i + 1] == "-" then
        has_c = true
        break
      end
    end
    assert.is_false(has_c)
    assert.are.equal(0, vim.fn.filereadable(part))
  end)
end)

describe("download: atomic file rename & size verification", function()
  local orig_system

  before_each(function()
    download.abort_all()
    if download.reset_rate_governor then
      download.reset_rate_governor()
    end
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
    download.abort_all()
    if download.reset_rate_governor then
      download.reset_rate_governor()
    end
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

  it("preserves .part when curl exits with error and .part > 1024 bytes without explicit opts.resume", function()
    local dest = tmp()
    local part = dest .. ".part"
    local exit_fn = nil

    -- Seed an existing .part > 1024 bytes (e.g. from an interrupted preview download)
    local f = io.open(part, "wb")
    f:write(string.rep("x", 2048))
    f:close()

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      return { kill = function() end }
    end

    local result = nil
    -- No explicit opts.resume provided
    download.download_async("https://example.com/preview_fail.jpg", dest, function(ok)
      result = ok
    end)

    assert.is_not_nil(exit_fn)
    exit_fn({ code = 28 }) -- Timeout error
    vim.wait(200, function() return result ~= nil end)

    assert.is_false(result)
    assert.are.equal(1, vim.fn.filereadable(part))
    assert.are.equal(0, vim.fn.filereadable(dest))

    vim.fn.delete(part)
  end)

  it("deletes .part when curl exits with error and opts.force == true", function()
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

    local result = nil
    download.download_async("https://example.com/force_fail.jpg", dest, function(ok)
      result = ok
    end, { force = true })

    assert.is_not_nil(exit_fn)
    exit_fn({ code = 28 }) -- Timeout error
    vim.wait(200, function() return result ~= nil end)

    assert.is_false(result)
    assert.are.equal(0, vim.fn.filereadable(part))
    assert.are.equal(0, vim.fn.filereadable(dest))
  end)

  it("deletes .part when curl exits with code 0 but media validation fails (corrupt payload)", function()
    local dest = tmp() .. ".jpg"
    local part = dest .. ".part"
    local exit_fn = nil

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      -- Write Cloudflare error HTML or corrupt non-media body > 1024 bytes
      local f = io.open(part, "wb")
      f:write("<!DOCTYPE html><html><body>Error 521 Cloudflare</body></html>" .. string.rep(" ", 2000))
      f:close()
      return { kill = function() end }
    end

    local result = nil
    download.download_async("https://example.com/corrupt.jpg", dest, function(ok)
      result = ok
    end)

    assert.is_not_nil(exit_fn)
    exit_fn({ code = 0 }) -- Curl claims success, but body is invalid media
    vim.wait(200, function() return result ~= nil end)

    assert.is_false(result)
    assert.are.equal(0, vim.fn.filereadable(part))
    assert.are.equal(0, vim.fn.filereadable(dest))
  end)
end)

describe("download: curl_async execution & response handling", function()
  local orig_system

  before_each(function()
    download.abort_all()
    if download.reset_rate_governor then
      download.reset_rate_governor()
    end
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
    download.abort_all()
    if download.reset_rate_governor then
      download.reset_rate_governor()
    end
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
    download.abort_all()
    if download.reset_rate_governor then
      download.reset_rate_governor()
    end
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
    download.abort_all()
    if download.reset_rate_governor then
      download.reset_rate_governor()
    end
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
    download.abort_all()
    if download.reset_rate_governor then
      download.reset_rate_governor()
    end
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
      { id = 105, file_url = "http://example.com/105.jpg", sample_url = "http://example.com/105_s.jpg" },
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

  it("dispatches top lookahead targets (N+1 and N+2) concurrently without delay and staggers subsequent targets", function()
    local spawned_urls = {}
    local mock_handle = { kill = function() end }

    vim.system = function(cmd, opts, on_exit)
      table.insert(spawned_urls, cmd[#cmd])
      return mock_handle
    end

    -- Trigger prefetch at index 1 with direction 1 -> immediate targets are posts 102 (N+1) and 103 (N+2)
    download.prefetch_around(1, 1)

    -- Both active handles must be tracked in active_prefetch_handles immediately
    assert.are.equal(2, vim.tbl_count(download.active_prefetch_handles))

    -- Subsequent posts (104, 105) must be staggered via prefetch_timers immediately
    assert.is_true(vim.tbl_count(state.UI.prefetch_timers) >= 2)

    -- Both top lookahead targets (102 and 103) dispatch via rate governor without artificial prefetch timer delay
    vim.wait(250, function() return #spawned_urls >= 2 end, 10)
    assert.are.equal(2, #spawned_urls)
    assert.are.equal("http://example.com/102_s.jpg", spawned_urls[1])
    assert.are.equal("http://example.com/103_s.jpg", spawned_urls[2])
  end)

  it("dispatches top lookahead targets in reverse scroll direction without delay", function()
    local spawned_urls = {}
    local mock_handle = { kill = function() end }

    vim.system = function(cmd, opts, on_exit)
      table.insert(spawned_urls, cmd[#cmd])
      return mock_handle
    end

    -- Trigger prefetch at index 5 with direction -1 -> immediate targets are posts 104 (N-1) and 103 (N-2)
    download.prefetch_around(5, -1)

    vim.wait(250, function() return #spawned_urls >= 2 end, 10)
    assert.are.equal(2, #spawned_urls)
    assert.are.equal("http://example.com/104_s.jpg", spawned_urls[1])
    assert.are.equal("http://example.com/103_s.jpg", spawned_urls[2])
    assert.are.equal(2, vim.tbl_count(download.active_prefetch_handles))
  end)

  it("bounds immediate lookahead targets by math.min(radius, constants.PREFETCH_LOOKAHEAD_DEPTH)", function()
    local spawned_urls = {}
    local mock_handle = { kill = function() end }

    vim.system = function(cmd, opts, on_exit)
      table.insert(spawned_urls, cmd[#cmd])
      return mock_handle
    end

    local orig_radius = config.options.prefetch_radius
    config.options.prefetch_radius = 1
    download.prefetch_around(1, 1)

    -- With radius = 1, only 1 immediate lookahead target (102) should be dispatched
    assert.are.equal(1, #spawned_urls)
    assert.are.equal("http://example.com/102_s.jpg", spawned_urls[1])

    config.options.prefetch_radius = orig_radius
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

describe("download: token-bucket rate governor and priority queue", function()
  local orig_system
  local uv = vim.uv or vim.loop

  before_each(function()
    download.abort_all()
    download.active_downloads = {}
    download.active_handles = {}
    download.interrupted_dests = {}
    download.pending_resumes = {}
    if download.reset_rate_governor then
      download.reset_rate_governor()
    end
    orig_system = vim.system
  end)

  after_each(function()
    vim.system = orig_system
    download.abort_all()
    if download.reset_rate_governor then
      download.reset_rate_governor()
    end
  end)

  it("exposes rate governor constants and priority levels", function()
    assert.are.equal(8, constants.RATE_LIMIT_RPS)
    assert.are.equal(125, constants.RATE_LIMIT_MIN_INTERVAL_MS)
    assert.are.equal(4, constants.RATE_LIMIT_MAX_CONCURRENT_SOCKETS)
    assert.are.equal(1, constants.PRIORITY_PREVIEW)
    assert.are.equal(2, constants.PRIORITY_PREFETCH)
    assert.are.equal(3, constants.PRIORITY_AUTOPAGE)
    assert.are.equal(4, constants.PRIORITY_METADATA)

    assert.are.equal(constants.PRIORITY_PREVIEW, download.PRIORITY_PREVIEW)
    assert.are.equal(constants.PRIORITY_PREFETCH, download.PRIORITY_PREFETCH)
    assert.are.equal(constants.PRIORITY_AUTOPAGE, download.PRIORITY_AUTOPAGE)
    assert.are.equal(constants.PRIORITY_METADATA, download.PRIORITY_METADATA)
  end)

  it("enforces 8 req/sec maximum rate with minimum 125ms interval between dispatches", function()
    local dispatch_times = {}
    local exit_callbacks = {}

    vim.system = function(cmd, opts, on_exit)
      table.insert(dispatch_times, uv.hrtime() / 1e6)
      table.insert(exit_callbacks, on_exit)
      return { kill = function() end }
    end

    local dest1 = tmp()
    local dest2 = tmp()
    local dest3 = tmp()

    download.download_async("https://example.com/1.jpg", dest1, function() end, { priority = 2 })
    download.download_async("https://example.com/2.jpg", dest2, function() end, { priority = 2 })
    download.download_async("https://example.com/3.jpg", dest3, function() end, { priority = 2 })

    -- First task dispatches immediately
    assert.are.equal(1, #dispatch_times)

    -- Wait for the 2nd and 3rd tasks to dispatch via governor timer
    vim.wait(400, function() return #dispatch_times >= 3 end, 10)

    assert.are.equal(3, #dispatch_times)
    local diff1 = dispatch_times[2] - dispatch_times[1]
    local diff2 = dispatch_times[3] - dispatch_times[2]

    -- Each dispatch must be spaced by at least 125ms (allowing 10ms timing jitter)
    assert.is_true(diff1 >= 115, string.format("diff1 expected >= 115ms, got %.1fms", diff1))
    assert.is_true(diff2 >= 115, string.format("diff2 expected >= 115ms, got %.1fms", diff2))

    vim.fn.delete(dest1)
    vim.fn.delete(dest2)
    vim.fn.delete(dest3)
  end)

  it("caps concurrent active network connections at 4 in-flight sockets", function()
    local spawned = {}
    local exit_callbacks = {}

    vim.system = function(cmd, opts, on_exit)
      local url = cmd[#cmd]
      table.insert(spawned, url)
      table.insert(exit_callbacks, on_exit)
      return { kill = function() end }
    end

    -- Queue 6 tasks
    for i = 1, 6 do
      local dest = tmp()
      download.download_async("https://example.com/item" .. i .. ".jpg", dest, function() end, { priority = 2 })
    end

    -- Wait enough time for 4 dispatches to occur (t = 0, 125, 250, 375ms)
    vim.wait(500, function() return #spawned >= 4 end, 10)

    -- Exactly 4 concurrent sockets active; 5th and 6th remain queued
    assert.are.equal(4, #spawned)
    assert.are.equal(4, download.governor.active_sockets)

    -- Wait an additional 200ms; 5th task still MUST NOT dispatch while 4 sockets remain active
    vim.wait(200, function() return false end, 10)
    assert.are.equal(4, #spawned)

    -- Now complete socket 1
    local part = tmp() .. ".part"
    local f = io.open(part, "wb")
    f:write(string.rep("x", 2048))
    f:close()
    exit_callbacks[1]({ code = 0 })

    -- Once a socket completes and minimum interval elapses, task 5 dispatches
    vim.wait(300, function() return #spawned >= 5 end, 10)
    assert.are.equal(5, #spawned)
    assert.are.equal("https://example.com/item5.jpg", spawned[5])

    vim.fn.delete(part)
  end)

  it("dispatches tasks according to 4 priority levels (P1 > P2 > P3 > P4)", function()
    local dispatched_urls = {}
    local exit_callbacks = {}

    vim.system = function(cmd, opts, on_exit)
      local url = cmd[#cmd]
      table.insert(dispatched_urls, url)
      table.insert(exit_callbacks, on_exit)
      return { kill = function() end }
    end

    -- Saturate 4 sockets so newly queued items must wait in priority queue
    for i = 1, 4 do
      download.download_async("https://example.com/active" .. i .. ".jpg", tmp(), function() end, { priority = 1 })
    end
    vim.wait(500, function() return #dispatched_urls >= 4 end, 10)
    assert.are.equal(4, #dispatched_urls)

    -- Now enqueue in reverse priority order: P4 (metadata), P3 (autopage), P2 (prefetch), P1 (cursor preview)
    download.curl_async("https://example.com/api/metadata", function() end, { priority = constants.PRIORITY_METADATA })
    download.curl_async("https://example.com/api/autopage", function() end, { priority = constants.PRIORITY_AUTOPAGE })
    download.download_async("https://example.com/lookahead.jpg", tmp(), function() end, { priority = constants.PRIORITY_PREFETCH })
    download.download_async("https://example.com/cursor_preview.jpg", tmp(), function() end, { priority = constants.PRIORITY_PREVIEW })

    -- Complete in-flight sockets one by one to let queued tasks dispatch
    for i = 1, 4 do
      exit_callbacks[i]({ code = 0 })
      vim.wait(200, function() return #dispatched_urls >= 4 + i end, 10)
    end

    assert.are.equal(8, #dispatched_urls)
    -- Queued tasks must have dispatched in strict priority order:
    -- P1 (cursor preview) -> P2 (lookahead prefetch) -> P3 (autopage) -> P4 (metadata)
    assert.are.equal("https://example.com/cursor_preview.jpg", dispatched_urls[5])
    assert.are.equal("https://example.com/lookahead.jpg", dispatched_urls[6])
    assert.are.equal("https://example.com/api/autopage", dispatched_urls[7])
    assert.are.equal("https://example.com/api/metadata", dispatched_urls[8])
  end)

  it("escalates queued task priority when a higher-priority request arrives for the same destination", function()
    local dispatched_urls = {}
    local exit_callbacks = {}

    vim.system = function(cmd, opts, on_exit)
      local url = cmd[#cmd]
      table.insert(dispatched_urls, url)
      table.insert(exit_callbacks, on_exit)
      return { kill = function() end }
    end

    -- Fill 4 active slots
    for i = 1, 4 do
      download.download_async("https://example.com/slot" .. i .. ".jpg", tmp(), function() end, { priority = 1 })
    end
    vim.wait(500, function() return #dispatched_urls >= 4 end, 10)

    local shared_dest = tmp()
    local other_dest = tmp()

    -- Enqueue shared_dest as P2 (prefetch)
    download.download_async("https://example.com/shared.jpg", shared_dest, function() end, { priority = 2 })
    -- Enqueue other_dest as P2 (prefetch)
    download.download_async("https://example.com/other.jpg", other_dest, function() end, { priority = 2 })

    -- Now user moves cursor to shared_dest, requesting it as P1 (preview)
    download.download_async("https://example.com/shared.jpg", shared_dest, function() end, { priority = 1 })

    -- Release a socket slot
    exit_callbacks[1]({ code = 0 })

    vim.wait(250, function() return #dispatched_urls >= 5 end, 10)
    assert.are.equal(5, #dispatched_urls)
    -- shared.jpg should have been upgraded to P1 and dispatched before other.jpg
    assert.are.equal("https://example.com/shared.jpg", dispatched_urls[5])

    vim.fn.delete(shared_dest)
    vim.fn.delete(other_dest)
  end)

  it("releases connection capacity immediately on curl network error or timeout", function()
    local exit_callbacks = {}
    local spawned = {}

    vim.system = function(cmd, opts, on_exit)
      table.insert(spawned, cmd[#cmd])
      table.insert(exit_callbacks, on_exit)
      return { kill = function() end }
    end

    for i = 1, 4 do
      download.download_async("https://example.com/err" .. i .. ".jpg", tmp(), function() end, { priority = 1 })
    end
    vim.wait(500, function() return #spawned >= 4 end, 10)

    local queued_dest = tmp()
    download.download_async("https://example.com/queued.jpg", queued_dest, function() end, { priority = 1 })

    -- Fail socket 1 with curl error code 28 (timeout)
    exit_callbacks[1]({ code = 28 })

    -- Connection capacity must be released immediately so queued task can dispatch
    vim.wait(250, function() return #spawned >= 5 end, 10)
    assert.are.equal(5, #spawned)
    assert.are.equal("https://example.com/queued.jpg", spawned[5])

    vim.fn.delete(queued_dest)
  end)

  it("releases all connection capacity and aborts queued tasks on download.abort_all()", function()
    local killed_handles = {}
    vim.system = function(cmd, opts, on_exit)
      return {
        kill = function(self, sig)
          table.insert(killed_handles, sig)
        end,
      }
    end

    -- Fill 4 sockets and queue 2 more
    for i = 1, 6 do
      download.download_async("https://example.com/abort" .. i .. ".jpg", tmp(), function() end, { priority = 2 })
    end
    vim.wait(500, function() return download.governor.active_sockets >= 4 end, 10)

    assert.are.equal(4, download.governor.active_sockets)
    assert.is_true(download.governor.queue_count() > 0)

    -- Call abort_all
    download.abort_all()

    -- Active sockets must be 0 and queue cleared
    assert.are.equal(0, download.governor.active_sockets)
    assert.are.equal(0, download.governor.queue_count())

    -- All active handles must have received SIGKILL (9)
    assert.are.equal(4, #killed_handles)
    for _, sig in ipairs(killed_handles) do
      assert.are.equal(9, sig)
    end
  end)

  it("cancels queued task when handle:kill() is called before dispatch", function()
    local spawned = {}
    vim.system = function(cmd, opts, on_exit)
      table.insert(spawned, cmd[#cmd])
      return { kill = function() end }
    end

    -- Fill 4 slots
    for i = 1, 4 do
      download.download_async("https://example.com/fill" .. i .. ".jpg", tmp(), function() end, { priority = 1 })
    end
    vim.wait(500, function() return #spawned >= 4 end, 10)

    -- Queue item 5 and item 6
    local handle5 = download.download_async("https://example.com/kill_before_run.jpg", tmp(), function() end, { priority = 2 })
    download.download_async("https://example.com/survivor.jpg", tmp(), function() end, { priority = 2 })

    assert.is_not_nil(handle5)
    -- Kill handle5 while still queued
    handle5:kill(9)

    -- Reset governor sockets to simulate slot availability
    download.governor.active_sockets = 0
    download.governor.last_dispatch_time = 0
    download.governor.dispatch()

    vim.wait(250, function() return #spawned >= 5 end, 10)
    -- kill_before_run should have been skipped, and survivor should have dispatched
    assert.are.equal("https://example.com/survivor.jpg", spawned[#spawned])
  end)
end)

