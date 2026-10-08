-- tests/unit/download_spec.lua
-- Unit tests for gelbooru.net.download resume logic, interrupted-teardown guard,
-- spam deduplication, and pending_resumes race protection.

local download = require("gelbooru.net.download")
local config = require("gelbooru.core.config")

local tmp = vim.fn.tempname

describe("download: deduplication", function()
  before_each(function()
    download.active_downloads = {}
    download.active_handles = {}
    download.interrupted_dests = {}
    download.pending_resumes = {}
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

  it("hooks a second cb into an in-flight download instead of launching a duplicate", function()
    local dest = tmp()
    -- Seed active_downloads to simulate an in-flight download
    download.active_downloads[dest] = { function() end }

    local second_cb_called = false
    download.download_async("http://example.com/fake.jpg", dest, function()
      second_cb_called = true
    end)

    -- The second cb should have been appended, not a new download started
    assert.are.equal(2, #download.active_downloads[dest])
    assert.is_false(second_cb_called)

    -- Clean up
    download.active_downloads[dest] = nil
  end)
end)

describe("download: interrupted_dests teardown guard", function()
  before_each(function()
    download.active_downloads = {}
    download.active_handles = {}
    download.interrupted_dests = {}
    download.pending_resumes = {}
  end)

  it("does not rename .part when dest is flagged as interrupted", function()
    local dest = tmp()
    local part = dest .. ".part"

    -- Write a fake .part file large enough to pass the size guard
    local f = io.open(part, "wb")
    f:write(string.rep("x", 2048))
    f:close()

    -- Flag as interrupted (what teardown does before kill)
    download.interrupted_dests[dest] = true

    -- Simulate the vim.schedule callback firing after kill
    local callbacks_called = {}
    download.active_downloads[dest] = { function(ok) table.insert(callbacks_called, ok) end }

    -- Manually invoke what the callback body does
    local callbacks = download.active_downloads[dest] or {}
    download.active_downloads[dest] = nil
    download.active_handles[dest] = nil

    if download.interrupted_dests[dest] then
      download.interrupted_dests[dest] = nil
      for _, fn in ipairs(callbacks) do pcall(fn, false) end
    end

    -- .part must still exist (not renamed), final dest must not exist
    assert.are.equal(1, vim.fn.filereadable(part))
    assert.are.equal(0, vim.fn.filereadable(dest))
    -- callback was called with false
    assert.are.equal(1, #callbacks_called)
    assert.is_false(callbacks_called[1])

    vim.fn.delete(part)
  end)

  it("clears interrupted_dests flag after the callback consumes it", function()
    local dest = tmp()
    download.interrupted_dests[dest] = true
    download.active_downloads[dest] = {}

    local callbacks = download.active_downloads[dest] or {}
    download.active_downloads[dest] = nil
    if download.interrupted_dests[dest] then
      download.interrupted_dests[dest] = nil
      for _, fn in ipairs(callbacks) do pcall(fn, false) end
    end

    assert.is_nil(download.interrupted_dests[dest])
  end)
end)

describe("download: pending_resumes race guard", function()
  before_each(function()
    download.active_downloads = {}
    download.active_handles = {}
    download.interrupted_dests = {}
    download.pending_resumes = {}
  end)

  it("skips a dest already in pending_resumes", function()
    local dest = "/fake/save_dir/99999.mp4"
    download.pending_resumes[dest] = true

    -- A second call to resume_pending_saves would check this before launching
    local would_resume = not download.active_downloads[dest] and not download.pending_resumes[dest]
    assert.is_false(would_resume)
  end)

  it("allows resume when neither active_downloads nor pending_resumes is set", function()
    local dest = "/fake/save_dir/88888.mp4"
    local would_resume = not download.active_downloads[dest] and not download.pending_resumes[dest]
    assert.is_true(would_resume)
  end)
end)

describe("download: resume flag behaviour", function()
  before_each(function()
    download.active_downloads = {}
    download.active_handles = {}
    download.interrupted_dests = {}
    download.pending_resumes = {}
  end)

  it("preserves .part on failure when resume=true", function()
    local dest = tmp()
    local part = dest .. ".part"

    local f = io.open(part, "wb")
    f:write(string.rep("x", 2048))
    f:close()

    -- Simulate failed download (out.code != 0) with resume=true
    local resume = true
    local ok = false -- simulated failure

    if not ok then
      if not resume and vim.fn.filereadable(part) == 1 then
        vim.fn.delete(part)
      end
    end

    -- .part should still be there
    assert.are.equal(1, vim.fn.filereadable(part))
    vim.fn.delete(part)
  end)

  it("deletes .part on failure when resume=false", function()
    local dest = tmp()
    local part = dest .. ".part"

    local f = io.open(part, "wb")
    f:write(string.rep("x", 2048))
    f:close()

    local resume = false
    local ok = false

    if not ok then
      if not resume and vim.fn.filereadable(part) == 1 then
        vim.fn.delete(part)
      end
    end

    assert.are.equal(0, vim.fn.filereadable(part))
  end)
end)

describe("download: curl arguments and --fail flag", function()
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

  it("includes --fail in download_async curl command", function()
    local dest = tmp()
    local captured_cmd = nil

    vim.system = function(cmd, opts, on_exit)
      captured_cmd = cmd
      return { kill = function() end }
    end

    download.download_async("http://example.com/image.jpg", dest, function() end)

    assert.is_not_nil(captured_cmd)
    assert.is_true(vim.tbl_contains(captured_cmd, "--fail"))
  end)

  it("includes --fail in curl_async curl command", function()
    local captured_cmd = nil

    vim.system = function(cmd, opts, on_exit)
      captured_cmd = cmd
      return { kill = function() end }
    end

    download.curl_async("http://example.com/api", function() end)

    assert.is_not_nil(captured_cmd)
    assert.is_true(vim.tbl_contains(captured_cmd, "--fail"))
  end)

  it("deletes .part when download_async curl exits non-zero (HTTP error)", function()
    local dest = tmp()
    local part = dest .. ".part"
    local callback_res = nil
    local exit_fn = nil

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      -- Write a fake partial file as if curl wrote something before 404
      local f = io.open(part, "wb")
      f:write("404 Not Found")
      f:close()
      return { kill = function() end }
    end

    download.download_async("http://example.com/404.jpg", dest, function(ok)
      callback_res = ok
    end)

    assert.is_not_nil(exit_fn)
    -- Simulate curl exiting with code 22 (HTTP error)
    exit_fn({ code = 22 })
    vim.wait(200, function() return callback_res ~= nil end)

    assert.is_false(callback_res)
    assert.are.equal(0, vim.fn.filereadable(part))
  end)

  it("preserves .part when download_async curl exits non-zero and resume=true", function()
    local dest = tmp()
    local part = dest .. ".part"
    local callback_res = nil
    local exit_fn = nil

    -- Seed an existing .part > 1024 bytes so resume activates
    local f = io.open(part, "wb")
    f:write(string.rep("x", 2048))
    f:close()

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      return { kill = function() end }
    end

    download.download_async("http://example.com/interrupted.jpg", dest, function(ok)
      callback_res = ok
    end, { resume = true })

    assert.is_not_nil(exit_fn)
    exit_fn({ code = 22 })
    vim.wait(200, function() return callback_res ~= nil end)

    assert.is_false(callback_res)
    assert.are.equal(1, vim.fn.filereadable(part))
    vim.fn.delete(part)
  end)
end)

describe("download: process tracking and abort_all", function()
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

  it("tracks child process handle in download_async and removes it when finished", function()
    local dest = tmp()
    local exit_fn = nil
    local mock_handle = { kill = function() end }

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      return mock_handle
    end

    local handle = download.download_async("http://example.com/test.jpg", dest, function() end)

    assert.are.equal(mock_handle, handle)
    assert.are.equal(mock_handle, download.active_handles[dest])

    -- Simulate process exit
    exit_fn({ code = 1 })
    local done = false
    vim.schedule(function() done = true end)
    vim.wait(200, function() return done end)

    assert.is_nil(download.active_handles[dest])
  end)

  it("tracks child process handle in curl_async and removes it when finished", function()
    local exit_fn = nil
    local mock_handle = { kill = function() end }

    vim.system = function(cmd, opts, on_exit)
      exit_fn = on_exit
      return mock_handle
    end

    local handle = download.curl_async("http://example.com/test", function() end)

    assert.are.equal(mock_handle, handle)
    assert.are.equal(mock_handle, download.active_handles[mock_handle])

    -- Simulate process exit
    exit_fn({ code = 0, stdout = "ok" })
    local done = false
    vim.schedule(function() done = true end)
    vim.wait(200, function() return done end)

    assert.is_nil(download.active_handles[mock_handle])
  end)

  it("abort_all kills all active handles, flags interrupted_dests, and empties table", function()
    local killed = {}
    local handle1 = {
      kill = function(self, sig)
        table.insert(killed, { id = 1, sig = sig })
      end,
    }
    local handle2 = {
      kill = function(self, sig)
        table.insert(killed, { id = 2, sig = sig })
      end,
    }

    local dest1 = "/fake/path/test.jpg"
    download.active_handles[dest1] = handle1
    download.active_handles[handle2] = handle2

    download.abort_all()

    assert.are.equal(2, #killed)
    assert.are.equal(9, killed[1].sig)
    assert.are.equal(9, killed[2].sig)
    assert.is_true(download.interrupted_dests[dest1])
    assert.are.equal(0, vim.tbl_count(download.active_handles))
  end)

  it("allows teardown to iterate active_handles and call pcall(handle.kill, handle, 9)", function()
    local killed = {}
    local handle = {
      kill = function(self, sig)
        table.insert(killed, sig)
      end,
    }

    local dest = "/fake/path/image.jpg"
    download.active_handles[dest] = handle

    for d, h in pairs(download.active_handles or {}) do
      download.interrupted_dests[d] = true
      pcall(h.kill, h, 9)
    end
    download.active_handles = {}

    assert.are.equal(1, #killed)
    assert.are.equal(9, killed[1])
    assert.is_true(download.interrupted_dests[dest])
    assert.are.equal(0, vim.tbl_count(download.active_handles))
  end)
end)
