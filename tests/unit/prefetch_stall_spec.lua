local assert = require("luassert")
local download = require("gelbooru.net.download")
local constants = require("gelbooru.core.constants")
local state = require("gelbooru.core.state")
local render = require("gelbooru.ui.render")
local resolver = require("gelbooru.media.resolver")
local config = require("gelbooru.core.config")

describe("prefetch stall and priority escalation under concurrency", function()
  local orig_system
  local tmp_files = {}
  local test_dir

  local function tmp()
    local f = vim.fn.tempname()
    table.insert(tmp_files, f)
    return f
  end

  before_each(function()
    test_dir = vim.fn.tempname()
    local test_cache = test_dir .. "/cache"
    local test_save = test_dir .. "/save"
    local test_tags = test_dir .. "/tags"
    vim.fn.mkdir(test_cache, "p")
    vim.fn.mkdir(test_save, "p")
    vim.fn.mkdir(test_tags, "p")
    config.setup({
      prefetch_radius = 8,
      cache_dir = test_cache,
      save_dir = test_save,
      tags_dir = test_tags,
    })
    state.reset_query_state()
    state.reset_ui()
    state.State.torn_down = false
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
    for _, f in ipairs(tmp_files) do
      pcall(vim.fn.delete, f)
      pcall(vim.fn.delete, f .. ".part")
    end
    tmp_files = {}
    if test_dir then
      pcall(vim.fn.delete, test_dir, "rf")
      test_dir = nil
    end
  end)

  it("bursts socket capacity to dispatch Priority 1 preview immediately when 4 background sockets are active", function()
    local spawned_urls = {}
    local exit_callbacks = {}

    vim.system = function(cmd, opts, on_exit)
      local url = cmd[#cmd]
      table.insert(spawned_urls, url)
      table.insert(exit_callbacks, on_exit)
      return { kill = function() end }
    end

    -- 4 background prefetch tasks saturate all 4 default sockets
    local bg_dests = {}
    for i = 1, 4 do
      bg_dests[i] = tmp()
      download.download_async("https://example.com/bg" .. i .. ".jpg", bg_dests[i], function() end, { priority = constants.PRIORITY_PREFETCH, post_idx = i })
    end

    assert.are.equal(4, #spawned_urls)
    assert.are.equal(4, download.governor.active_sockets)

    -- Now a foreground preview request arrives for post 5 (which user is actively viewing)
    local fg_dest = tmp()
    download.download_async("https://example.com/fg_preview.jpg", fg_dest, function() end, { priority = constants.PRIORITY_PREVIEW, post_idx = 5 })

    -- The foreground preview MUST NOT be starved waiting for background sockets to finish.
    -- It must burst to socket 5 and dispatch immediately!
    assert.are.equal(5, #spawned_urls)
    assert.are.equal("https://example.com/fg_preview.jpg", spawned_urls[5])
    assert.are.equal(5, download.governor.active_sockets)
  end)

  it("escalates queued prefetch task to Priority 1 and dispatches immediately on cursor landing", function()
    local spawned_urls = {}
    local exit_callbacks = {}

    vim.system = function(cmd, opts, on_exit)
      local url = cmd[#cmd]
      table.insert(spawned_urls, url)
      table.insert(exit_callbacks, on_exit)
      return { kill = function() end }
    end

    -- Enqueue 5 prefetch tasks (4 will spawn, 5th remains in queues[2])
    local dests = {}
    for i = 1, 5 do
      dests[i] = tmp()
      download.download_async("https://example.com/item" .. i .. ".jpg", dests[i], function() end, { priority = constants.PRIORITY_PREFETCH, post_idx = i })
    end

    assert.are.equal(4, #spawned_urls)
    assert.are.equal(4, download.governor.active_sockets)

    -- Post 5 is currently queued in queues[2]
    -- User moves cursor to post 5: escalate_preview is called for dests[5]
    download.escalate_preview(dests[5])

    -- Post 5 must immediately burst to socket 5 and spawn without waiting for items 1-4 to exit!
    assert.are.equal(5, #spawned_urls)
    assert.are.equal("https://example.com/item5.jpg", spawned_urls[5])
    assert.are.equal(5, download.governor.active_sockets)
  end)

  it("sliding-window queue bounding does not prune lookahead tasks on single-step cursor jitter", function()
    local spawned_urls = {}
    vim.system = function(cmd, opts, on_exit)
      local url = cmd[#cmd]
      table.insert(spawned_urls, url)
      return { kill = function() end }
    end

    state.State.posts = {}
    for i = 1, 20 do
      table.insert(state.State.posts, {
        id = 1000 + i,
        sample_url = "https://example.com/sample_" .. (1000 + i) .. ".jpg",
        file_url = "https://example.com/file_" .. (1000 + i) .. ".jpg",
      })
    end

    -- User is at post 5, scrolling down
    state.State.cur = 5
    state.State.scroll_dir = 1
    download.prefetch_around(5, 1)

    -- Now user takes 1 step back to post 4 (scroll jitter)
    state.State.cur = 4
    state.State.scroll_dir = -1
    download.prefetch_around(4, -1)

    -- Post 13 (5 + 8) was distance 8 from post 5, and distance 9 from post 4.
    -- With radius 8, a window of 8 would have pruned post 13.
    -- With sliding window hysteresis (radius + 4 = 12), post 13 MUST NOT be pruned!
    local _, dest_13 = resolver.get_preview_targets(state.State.posts[13])
    local task_found = false
    local q = download.governor.queues[constants.PRIORITY_PREFETCH]
    for _, task in ipairs(q or {}) do
      if task.dest == dest_13 and not task.killed then
        task_found = true
        break
      end
    end
    if not task_found and download.active_handles[dest_13] and not download.active_handles[dest_13].killed then
      task_found = true
    end

    assert.is_true(task_found, "Task for post 13 should remain alive during single-step jitter")
  end)

  it("render_preview immediately escalates queued prefetch task to Priority 1 without waiting for 150ms scroll timer", function()
    local spawned_urls = {}
    vim.system = function(cmd, opts, on_exit)
      local url = cmd[#cmd]
      table.insert(spawned_urls, url)
      return { kill = function() end }
    end

    -- Fill 4 background sockets so queued tasks remain in rate governor queue
    for i = 1, 4 do
      download.download_async("https://example.com/bg" .. i .. ".jpg", tmp(), function() end, { priority = constants.PRIORITY_PREFETCH, post_idx = i })
    end
    assert.are.equal(4, #spawned_urls)

    state.State.posts = {
      { id = 2001, sample_url = "https://example.com/2001.jpg", file_url = "https://example.com/2001.jpg" },
      { id = 2002, sample_url = "https://example.com/2002.jpg", file_url = "https://example.com/2002.jpg" },
    }

    local _, dest_2 = resolver.get_preview_targets(state.State.posts[2])
    -- Pre-enqueue post 2 at Priority 2 (prefetch)
    download.download_async("https://example.com/2002.jpg", dest_2, function() end, { priority = constants.PRIORITY_PREFETCH, post_idx = 2 })

    local q2 = download.governor.queues[constants.PRIORITY_PREFETCH]
    local q1 = download.governor.queues[constants.PRIORITY_PREVIEW]
    assert.are.equal(1, #q2)
    assert.are.equal(0, #q1)

    -- Now navigate to post 2 and invoke render_preview
    state.State.cur = 2
    render.render_preview(false)

    -- Immediately, post 2 must have escalated to Priority 1 and burst-dispatched onto socket 5 without waiting 150ms!
    assert.are.equal(5, #spawned_urls)
    assert.are.equal("https://example.com/2002.jpg", spawned_urls[5])
    assert.are.equal(0, #q2)
  end)
end)
