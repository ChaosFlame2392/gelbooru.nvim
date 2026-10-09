local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local download = require("gelbooru.net.download")
local tags = require("gelbooru.tags")
local history = require("gelbooru.core.history")
local image = require("gelbooru.ui.image")

local function ensure_array(v)
  if util.ensure_array then return util.ensure_array(v) end
  if type(v) ~= "table" then return {} end
  if v[1] == nil and next(v) ~= nil then return { v } end
  return v
end

local M = {}

function M.fetch(direction)
  direction = direction or 1
  local State = state.State
  local UI = state.UI
  local ui = require("gelbooru.ui")

  if not State.query or State.query:match("^local:") then
    return
  end

  if direction < 0 then
    if State.page <= 1 then
      return
    end
    -- Forward pagination appends new pages to the tail of State.posts.
    -- Backward pagination must remove from the TAIL, not the head!
    local to_remove = math.min(config.options.per_page, #State.posts)
    local new_posts = {}
    for i = 1, #State.posts - to_remove do
      new_posts[#new_posts + 1] = State.posts[i]
    end
    State.posts = new_posts
    State.page = State.page - 1
    -- Land on the first post of the page now at the top of the list.
    State.cur = math.max(1, math.min(State.cur, #State.posts))
    State.cur_id = nil
    history.save_current_history()
    ui.render_list()
    ui.render_preview(false)
    return
  end

  if State.loading then
    return
  end
  State.loading = true
  ui.set_status("Fetching page " .. (State.page + 1) .. "…")
  local url = string.format(
    "%s&tags=%s&limit=%d&pid=%d%s",
    config.options.api_base,
    util.url_encode(State.query),
    config.options.per_page,
    State.page,
    util.auth_qs()
  )
  local epoch = State.search_epoch
  download.curl_async(url, function(body)
    if State.search_epoch ~= epoch then
      -- Response is stale from an older search query, discard it
      return
    end
    -- Also guard if UI has been torn down:
    if State.torn_down or not (UI.wins.frame and vim.api.nvim_win_is_valid(UI.wins.frame)) then
      return
    end
    State.loading = false
    if not body then
      ui.set_status("Error: API request failed")
      ui.render_list()
      util.set_lines(UI.bufs.img, { "  Error: API request failed" })
      util.set_lines(UI.bufs.meta, {})
      return
    end
    local ok, data = pcall(vim.json and vim.json.decode or vim.fn.json_decode, body)
    if not ok or not data or not data.post then
      ui.set_status("No results" .. (State.query ~= "" and (" for: " .. State.query) or ""))
      ui.render_list()
      history.save_current_history()
      util.set_lines(UI.bufs.img, { "  No posts found" })
      util.set_lines(UI.bufs.meta, {})
      return
    end
    local posts = ensure_array(data.post)
    if #posts == 0 then
      ui.set_status("No results" .. (State.query ~= "" and (" for: " .. State.query) or ""))
      ui.render_list()
      history.save_current_history()
      util.set_lines(UI.bufs.img, { "  No posts found" })
      util.set_lines(UI.bufs.meta, {})
      return
    end
    for _, p in ipairs(posts) do
      table.insert(State.posts, p)
    end
    State.page = State.page + 1
    history.save_current_history()
    ui.set_status()
    ui.render_list()
    if State.cur == 1 then
      ui.render_preview(false)
    end
  end)
end

local function clear_preview_loading()
  if state.State.torn_down then
    return
  end
  pcall(function()
    require("gelbooru.ui.image").reset_canvas("  Loading...")
  end)
end

function M.execute_search(query)
  local State = state.State
  local ui = require("gelbooru.ui")

  if State.torn_down then
    return
  end

  if query and query:match("^local:") then
    ui.open_local(query)
    return
  end

  if type(query) == "string" then
    query = query:gsub("^%s*id:%s*(%d+)%s*$", "id:%1")
    local bare_id = query:match("^%s*(%d+)%s*$")
    if bare_id then
      query = "id:" .. bare_id
      local UI = state.UI
      if UI.bufs and UI.bufs.input and vim.api.nvim_buf_is_valid(UI.bufs.input) then
        pcall(vim.api.nvim_buf_set_lines, UI.bufs.input, 0, 1, false, { query })
      end
    end
  end
  if query == State.query and #State.posts > 0 then
    ui.render_list()
    return
  end

  download.cancel_prefetch_timers()
  pcall(function()
    require("gelbooru.local.indexer").stop()
  end)

  clear_preview_loading()

  State.search_epoch = (State.search_epoch or 0) + 1
  State.loading = false  -- Must reset so in-flight fetch doesn't lock out new search!
  history.push_history(query)
  State.query = query
  State.posts = {}
  State.page = 0
  State.cur = 1
  State.cur_id = nil
  ui.render_list()
  M.fetch(1)

  -- Auto-resolve any unknown query tags so they are saved to discovered.json
  for word in (query or ""):gmatch("%S+") do
    local clean_word = word:gsub("^[-~]", ""):lower()
    if clean_word ~= "" and not clean_word:find(":") and not State.tags_by_name[clean_word] then
      local url = string.format("%s&names=%s%s", config.options.tags_api, util.url_encode(clean_word), util.auth_qs())
      download.curl_async(url, function(body)
        if state.State.torn_down then
          return
        end
        if not body then
          return
        end
        local ok, data = pcall(vim.json and vim.json.decode or vim.fn.json_decode, body)
        if ok and data and data.tag then
          local tag_list = ensure_array(data.tag)
          for _, t in ipairs(tag_list) do
            if t.name and t.type then
              local nl = t.name:lower()
              if not State.tags_by_name[nl] then
                local item = {
                  n = t.name,
                  t = tonumber(t.type) or 0,
                  c = tonumber(t.count) or 0,
                }
                if item.t == 3 then
                  tags.add_tag_to_index(item, State.series, State.series_by_first)
                elseif item.t == 4 then
                  tags.add_tag_to_index(item, State.characters, State.chars_by_first)
                elseif item.t == 1 then
                  tags.add_tag_to_index(item, State.artists, State.artists_by_first)
                else
                  tags.add_tag_to_index(item, State.general, State.general_by_first)
                end
                tags.persist_discovered_tag(item)
              end
            end
          end
        end
      end)
    end
  end
end

function M.save_current(cb)
  local State = state.State
  local ui = require("gelbooru.ui")
  local p = State.posts[State.cur]
  if not p or not p.file_url then
    ui.set_status("No file URL for this post", 2000)
    if cb then cb(false, nil) end
    return
  end
  if p.is_local then
    ui.set_status("Local file: " .. p.file_url, 2500)
    if cb then cb(true, p.file_url) end
    return
  end
  if not p.id or tostring(p.id) == "" or tostring(p.id) == "nil" then
    ui.set_status("No post ID available to save", 2000)
    if cb then cb(false, nil) end
    return
  end
  local ext = p.file_url:match("%.(%w+)$") or "jpg"
  local dest = string.format("%s/%s.%s", config.options.save_dir, p.id, ext)
  if vim.fn.filereadable(dest) == 1 then
    local local_index = require("gelbooru.local.index")
    local_index.mark_saved(p.id, ext)
    ui.set_status("Already saved → " .. dest, 2500)
    if cb then cb(true, dest) end
    return
  end
  if download.active_downloads[dest] then
    ui.set_status("Already downloading… " .. p.id, 2000)
    download.download_async(p.file_url, dest, function(saved)
      if saved then
        local local_index = require("gelbooru.local.index")
        local_index.mark_saved(p.id, ext)
        local meta_path = util.meta_cache_path(p.id)
        if meta_path then
          local meta_data = {
            id = p.id,
            tags = p.tags,
            rating = p.rating,
            score = p.score,
            width = p.width,
            height = p.height,
            source = p.source,
          }
          util.write_json(meta_path, meta_data)
        end
        local UI = state.UI
        if UI.wins.img and vim.api.nvim_win_is_valid(UI.wins.img) and State.posts[State.cur] == p then
          image.render_image(UI.wins.img, dest)
        end
        ui.render_list()
      end
      if cb then cb(saved, dest) end
    end, { resume = true })
    return
  end
  util.ensure(config.options.save_dir)
  ui.set_status("Saving " .. p.id .. "…")
  download.download_async(p.file_url, dest, function(saved)
    if saved then
      local local_index = require("gelbooru.local.index")
      local_index.mark_saved(p.id, ext)
      local meta_path = util.meta_cache_path(p.id)
      if meta_path then
        local meta_data = {
          id = p.id,
          tags = p.tags,
          rating = p.rating,
          score = p.score,
          width = p.width,
          height = p.height,
          source = p.source,
        }
        util.write_json(meta_path, meta_data)
      end
      local UI = state.UI
      if UI.wins.img and vim.api.nvim_win_is_valid(UI.wins.img) and State.posts[State.cur] == p then
        image.render_image(UI.wins.img, dest)
      end
      ui.render_list()
    end
    ui.set_status(saved and ("✓ Saved → " .. dest) or "✗ Save failed!", 3000)
    if cb then
      cb(saved, dest)
    end
  end, { resume = true })
end

function M.fetch_post_by_id(id, cb)
  if not id or tostring(id) == "" or tostring(id) == "nil" then
    if cb then cb(nil) end
    return
  end
  local url = string.format("%s&id=%s%s", config.options.api_base, util.url_encode(tostring(id)), util.auth_qs())
  download.curl_async(url, function(body)
    if state.State.torn_down then
      return
    end
    if not body then
      if cb then cb(nil) end
      return
    end
    local ok, data = pcall(vim.json and vim.json.decode or vim.fn.json_decode, body)
    if not ok or not data or not data.post then
      if cb then cb(nil) end
      return
    end
    local posts = ensure_array(data.post)
    if #posts > 0 and posts[1] then
      if cb then cb(posts[1]) end
    else
      if cb then cb(nil) end
    end
  end)
end

function M.fetch_post_metadata(p, cb)
  if not p or not p.id or tostring(p.id) == "" or p._metadata_fetched or p._metadata_loading then
    return
  end
  if state.State.torn_down then
    return
  end

  local meta_path = util.meta_cache_path(p.id)
  if meta_path then
    local cached = util.read_json(meta_path)
    if cached then
      p.tags = cached.tags or p.tags
      p.rating = cached.rating or p.rating
      p.score = tonumber(cached.score) or cached.score or p.score
      if cached.width then
        p.width = tonumber(cached.width) or cached.width
      end
      if cached.height then
        p.height = tonumber(cached.height) or cached.height
      end
      if cached.source then
        p.source = cached.source
      end
      p._metadata_fetched = true
      if not state.State.torn_down and cb then
        cb(p)
      end
      return
    end
  end

  p._metadata_loading = true
  M.fetch_post_by_id(p.id, function(d)
    p._metadata_loading = false
    p._metadata_fetched = true
    if state.State.torn_down then
      return
    end
    if not d then
      if cb then
        cb(nil)
      end
      return
    end
    p.tags = d.tags or p.tags
    p.rating = d.rating or p.rating
    p.score = tonumber(d.score) or d.score or p.score
    if d.width then
      p.width = tonumber(d.width) or d.width
    end
    if d.height then
      p.height = tonumber(d.height) or d.height
    end
    if d.source then
      p.source = d.source
    end
    if meta_path then
      local meta_data = {
        id = p.id,
        tags = p.tags,
        rating = p.rating,
        score = p.score,
        width = p.width,
        height = p.height,
        source = p.source,
      }
      util.write_json(meta_path, meta_data)
    end
    if cb then
      cb(p)
    end
  end)
end

function M.scroll_meta(dir)
  local State = state.State
  local UI = state.UI
  if not State.show_meta or not vim.api.nvim_win_is_valid(UI.wins.meta) then
    return
  end
  local cur_pos = vim.api.nvim_win_get_cursor(UI.wins.meta)
  local max_lines = vim.api.nvim_buf_line_count(UI.bufs.meta)
  local new_line = math.max(1, math.min(max_lines, cur_pos[1] + dir))
  pcall(vim.api.nvim_win_set_cursor, UI.wins.meta, { new_line, 0 })
end

return M
