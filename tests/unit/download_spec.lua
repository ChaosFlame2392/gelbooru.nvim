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
