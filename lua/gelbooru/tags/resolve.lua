local config = require("gelbooru.core.config")
local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local download = require("gelbooru.net.download")
local db = require("gelbooru.tags.db")

local M = {}

function M.persist_discovered_tag(item)
  if not item or not item.n or item.n == "" then
    return
  end
  local c = tonumber(item.c) or 0
  local typ = tonumber(item.t) or 0
  if not db.is_clean_tag(item.n, c, typ) then
    return
  end
  local nl = item.n:lower()
  local State = state.State
  local UI = state.UI
  if State.discovered_by_name[nl] then
    return
  end
  State.discovered_by_name[nl] = true
  State.discovered[#State.discovered + 1] = {
    n = item.n,
    t = typ,
    c = c,
  }

  local disc_file = config.get_discovered_tags_file()
  -- Guard: if the existing timer was already closed by teardown, discard it.
  if UI.save_discovered_timer and UI.save_discovered_timer:is_closing() then
    UI.save_discovered_timer = nil
  end
  if not UI.save_discovered_timer then
    UI.save_discovered_timer = vim.loop.new_timer()
  end
  UI.save_discovered_timer:stop()
  UI.save_discovered_timer:start(
    500,
    0,
    vim.schedule_wrap(function()
      -- Timer may have been closed by teardown before this fires.
      if not UI.save_discovered_timer then
        return
      end
      local ok, encoded = pcall(vim.fn.json_encode, State.discovered)
      if ok and encoded then
        local f = io.open(disc_file, "w")
        if f then
          f:write(encoded)
          f:close()
          log("INFO", "TAGS", "Persisted %d discovered tags to %s", #State.discovered, disc_file)
        end
      end
    end)
  )
end

function M.resolve_post_tags(p, on_complete)
  if not p or not p.tags then
    return
  end
  local State = state.State
  local missing = {}
  local seen = {}
  for raw_tag in (p.tags or ""):gmatch("%S+") do
    local clean_tag = util.decode_html(raw_tag):lower()
    if clean_tag ~= "" and not seen[clean_tag] then
      seen[clean_tag] = true
      if not State.tags_by_name[clean_tag] then
        table.insert(missing, clean_tag)
      end
    end
  end

  if #missing == 0 then
    return
  end

  log("DEBUG", "TAG_RESOLVE", "Resolving %d unknown tags for post %s", #missing, tostring(p.id))
  local chunks = {}
  for i = 1, math.min(#missing, 40) do
    chunks[#chunks + 1] = util.url_encode(missing[i])
  end
  local url = string.format("%s&names=%s%s", config.options.tags_api, table.concat(chunks, "+"), util.auth_qs())

  download.curl_async(url, function(body)
    if not body then
      return
    end
    local ok, data = pcall(vim.fn.json_decode, body)
    if ok and data and type(data.tag) == "table" then
      local found_artist = false
      for _, t in ipairs(data.tag) do
        if t.name and t.type then
          local count = tonumber(t.count) or 0
          local typ = tonumber(t.type) or 0
          if db.is_clean_tag(t.name, count, typ) then
            local item = {
              n = t.name,
              t = typ,
              c = count,
            }
            local nl = item.n:lower()
            if not State.tags_by_name[nl] then
              if item.t == 1 then
                found_artist = true
                db.add_tag_to_index(item, State.artists, State.artists_by_first)
                log("INFO", "TAG_RESOLVE", "Discovered artist '%s' for post %s", item.n, tostring(p.id))
              elseif item.t == 3 then
                db.add_tag_to_index(item, State.series, State.series_by_first)
              elseif item.t == 4 then
                db.add_tag_to_index(item, State.characters, State.chars_by_first)
              else
                db.add_tag_to_index(item, State.general, State.general_by_first)
              end
              M.persist_discovered_tag(item)
            elseif item.t == 1 then
              found_artist = true
            end
          end
        end
      end
      if found_artist and on_complete then
        on_complete()
      end
    end
  end)
end

function M.fetch_api_tags(query)
  if query == "" or #query < 2 then
    return
  end
  local UI = state.UI
  local State = state.State

  if UI.api_tag_timer then
    pcall(function()
      UI.api_tag_timer:stop()
      if not UI.api_tag_timer:is_closing() then
        UI.api_tag_timer:close()
      end
    end)
    UI.api_tag_timer = nil
  end

  local timer = vim.loop.new_timer()
  UI.api_tag_timer = timer
  timer:start(
    300,
    0,
    vim.schedule_wrap(function()
      if not timer:is_closing() then
        timer:close()
      end
      if UI.api_tag_timer == timer then
        UI.api_tag_timer = nil
      end

      local url = string.format("%s&name_pattern=%%%s%%&orderby=count&limit=25%s", config.options.tags_api, util.url_encode(query), util.auth_qs())
      download.curl_async(url, function(body)
        if not body then
          return
        end
        local ok, data = pcall(vim.fn.json_decode, body)
        if ok and data and type(data.tag) == "table" and #data.tag > 0 then
          local added = false
          for _, t in ipairs(data.tag) do
            if t.name and t.type then
              local name_lower = t.name:lower()
              if not State.tags_by_name[name_lower] then
                local item = {
                  n = t.name,
                  t = tonumber(t.type) or 0,
                  c = tonumber(t.count) or 0,
                }
                if item.t == 3 then
                  db.add_tag_to_index(item, State.series, State.series_by_first)
                elseif item.t == 4 then
                  db.add_tag_to_index(item, State.characters, State.chars_by_first)
                elseif item.t == 1 then
                  db.add_tag_to_index(item, State.artists, State.artists_by_first)
                else
                  db.add_tag_to_index(item, State.general, State.general_by_first)
                end
                M.persist_discovered_tag(item)
                added = true
              end
            end
          end
          if added and State.input_focused then
            local autocomplete = require("gelbooru.ui.autocomplete")
            pcall(autocomplete.update_autocomplete)
          end
        end
      end)
    end)
  )
end

return M
