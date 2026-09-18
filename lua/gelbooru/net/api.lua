local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local download = require("gelbooru.net.download")
local tags = require("gelbooru.tags")
local history = require("gelbooru.core.history")

local M = {}

function M.fetch(direction)
  direction = direction or 1
  local State = state.State
  local ui = require("gelbooru.ui")

  if direction < 0 then
    if State.page <= 1 then
      return
    end
    -- Posts are appended in fetch order, so the oldest page occupies
    -- indices 1..per_page. Build a new array without those entries so we
    -- don't mutate a table that may be shared with a history entry.
    local to_remove = math.min(config.options.per_page, #State.posts)
    local new_posts = {}
    for i = to_remove + 1, #State.posts do
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
  download.curl_async(url, function(body)
    State.loading = false
    if not body then
      ui.set_status("Error: API request failed")
      ui.render_list()
      return
    end
    local ok, data = pcall(vim.fn.json_decode, body)
    if not ok or not data or not data.post then
      ui.set_status("No results" .. (State.query ~= "" and (" for: " .. State.query) or ""))
      ui.render_list()
      history.save_current_history()
      return
    end
    for _, p in ipairs(data.post) do
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

function M.execute_search(query)
  local State = state.State
  local ui = require("gelbooru.ui")

  if query == State.query and #State.posts > 0 then
    ui.render_list()
    return
  end
  history.push_history(query)
  State.query = query
  State.posts = {}
  State.page = 0
  State.cur = 1
  State.cur_id = nil
  ui.render_list()
  ui.render_preview(false)
  M.fetch(1)

  -- Auto-resolve any unknown query tags so they are saved to discovered.json
  for word in (query or ""):gmatch("%S+") do
    local clean_word = word:gsub("^[-~]", ""):lower()
    if clean_word ~= "" and not clean_word:find(":") and not State.tags_by_name[clean_word] then
      local url = string.format("%s&names=%s%s", config.options.tags_api, util.url_encode(clean_word), util.auth_qs())
      download.curl_async(url, function(body)
        if not body then
          return
        end
        local ok, data = pcall(vim.fn.json_decode, body)
        if ok and data and type(data.tag) == "table" then
          for _, t in ipairs(data.tag) do
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

function M.save_current()
  local State = state.State
  local ui = require("gelbooru.ui")
  local p = State.posts[State.cur]
  if not p or not p.file_url then
    ui.set_status("No file URL for this post", 2000)
    return
  end
  local ext = p.file_url:match("%.(%w+)$") or "jpg"
  local dest = string.format("%s/%s.%s", config.options.save_dir, p.id, ext)
  if vim.fn.filereadable(dest) == 1 then
    ui.set_status("Already saved → " .. dest, 2500)
    return
  end
  ui.set_status("Saving " .. p.id .. "…")
  download.download_async(p.file_url, dest, function(saved)
    ui.set_status(saved and ("✓ Saved → " .. dest) or "✗ Save failed!", 3000)
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
