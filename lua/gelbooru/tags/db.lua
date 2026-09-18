local config = require("gelbooru.core.config")
local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")

local M = {}

function M.is_clean_tag(name, count, typ)
  if not name or type(name) ~= "string" or #name < 2 then
    return false
  end
  typ = tonumber(typ) or 0
  count = tonumber(count) or 0
  if typ == 5 then -- Meta tags (sort:score, rating:general)
    return true
  end
  if count < 1 then
    return false
  end
  if name:find("^[%s%-_,%.%?!;:'%\"]") or name:find("[%s%-_,%.%?!;:'%\"]$") then
    return false
  end
  if name:find("[,;%?!'%\"]") then
    return false
  end
  if name:find("https?://") or name:find("&%w+;") then
    return false
  end
  if name:find("__") or name:find("%-%-") or name:find("%.%.") then
    return false
  end
  if #name > 45 and not name:find("%(") then
    return false
  end
  return true
end

function M.add_tag_to_index(t, target_list, bucket_map)
  if not t or not t.n or type(t.n) ~= "string" then
    return
  end
  local c = tonumber(t.c) or 0
  local typ = tonumber(t.t) or 0
  if not M.is_clean_tag(t.n, c, typ) then
    return
  end
  local nl = t.n:lower()
  t.n_lower = nl
  t.norm = util.normalize_str(nl)
  t.c = c
  t.t = typ
  if target_list then
    target_list[#target_list + 1] = t
  end
  state.State.tags_by_name[nl] = t
  if bucket_map then
    local b = nl:sub(1, 1)
    local bucket = bucket_map[b]
    if not bucket then
      bucket = {}
      bucket_map[b] = bucket
    end
    bucket[#bucket + 1] = t
  end
end

local DEFAULT_TAG_CAPS = {
  series = 35000,
  characters = 40000,
  artists = 40000,
  general = 40000,
}

function M.parse_tag_file(path, target_list, bucket_map, cap)
  local f = io.open(path, "r")
  if not f then
    return false
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.fn.json_decode, content)
  if not ok or type(data) ~= "table" then
    return false
  end
  local max_items = cap or #data
  local limit = math.min(#data, max_items)
  for i = 1, limit do
    M.add_tag_to_index(data[i], target_list, bucket_map)
  end
  return true
end

function M.load_tags(caps)
  local State = state.State
  local UI = state.UI
  caps = caps or DEFAULT_TAG_CAPS

  State.tags_by_name = {}
  State.series = {}
  State.characters = {}
  State.artists = {}
  State.general = {}
  State.discovered = {}
  State.discovered_by_name = {}
  State.chars_by_first = {}
  State.series_by_first = {}
  State.artists_by_first = {}
  State.general_by_first = {}

  local all_tags = {}
  for _, t in ipairs(config.META_TAGS) do
    local copy = { n = t.n, c = t.c, t = t.t }
    M.add_tag_to_index(copy, nil, nil)
    all_tags[#all_tags + 1] = copy
  end

  local tags_dir = config.options.tags_dir
  util.ensure(tags_dir)
  local series_file = tags_dir .. "/series.json"
  local chars_file = tags_dir .. "/characters.json"
  local artists_file = tags_dir .. "/artists.json"
  local general_file = tags_dir .. "/general.json"
  local disc_file = config.get_discovered_tags_file()

  local has_split = vim.fn.filereadable(series_file) == 1
    or vim.fn.filereadable(chars_file) == 1
    or vim.fn.filereadable(general_file) == 1

  if has_split then
    log("INFO", "TAGS", "Loading tag databases from %s", tags_dir)

    -- Step 1: Load discovered.json synchronously (small, highly personal/relevant)
    local df = io.open(disc_file, "r")
    if df then
      local raw = df:read("*a")
      df:close()
      local ok, disc = pcall(vim.fn.json_decode, raw)
      if ok and type(disc) == "table" then
        for _, t in ipairs(disc) do
          if t.n and type(t.n) == "string" then
            local nl = t.n:lower()
            State.discovered_by_name[nl] = true
            State.discovered[#State.discovered + 1] = t
            local typ = tonumber(t.t) or 0
            if typ == 3 then
              M.add_tag_to_index(t, State.series, State.series_by_first)
            elseif typ == 4 then
              M.add_tag_to_index(t, State.characters, State.chars_by_first)
            elseif typ == 1 then
              M.add_tag_to_index(t, State.artists, State.artists_by_first)
            else
              M.add_tag_to_index(t, State.general, State.general_by_first)
            end
          end
        end
      end
    end

    -- Step 2: Load category databases across progressive event-loop turns so
    -- the Neovim main thread never freezes and the UI appears instantaneously.
    vim.schedule(function()
      M.parse_tag_file(series_file, State.series, State.series_by_first, caps.series)

      vim.schedule(function()
        M.parse_tag_file(general_file, State.general, State.general_by_first, caps.general)

        -- Build initial all_tags recommendation set from series and general
        for _, t in ipairs(State.series) do
          if #all_tags < 150 then
            table.insert(all_tags, t)
          end
        end
        for _, t in ipairs(State.general) do
          if #all_tags < 350 then
            table.insert(all_tags, t)
          end
        end
        State.all_tags = all_tags

        if State.input_focused and UI.bufs.input and UI.wins.ac
          and vim.api.nvim_buf_is_valid(UI.bufs.input)
          and vim.api.nvim_win_is_valid(UI.wins.ac)
        then
          local autocomplete = require("gelbooru.ui.autocomplete")
          pcall(autocomplete.update_autocomplete)
        end

        vim.schedule(function()
          M.parse_tag_file(chars_file, State.characters, State.chars_by_first, caps.characters)

          vim.schedule(function()
            M.parse_tag_file(artists_file, State.artists, State.artists_by_first, caps.artists)

            log(
              "INFO",
              "TAGS",
              "Tags ready: series=%d, characters=%d, artists=%d, general=%d, discovered=%d",
              #State.series,
              #State.characters,
              #State.artists,
              #State.general,
              #State.discovered
            )

            if State.input_focused and UI.bufs.input and UI.wins.ac
              and vim.api.nvim_buf_is_valid(UI.bufs.input)
              and vim.api.nvim_win_is_valid(UI.wins.ac)
            then
              local autocomplete = require("gelbooru.ui.autocomplete")
              pcall(autocomplete.update_autocomplete)
            end
          end)
        end)
      end)
    end)
  else
    State.all_tags = all_tags
  end
end

return M
