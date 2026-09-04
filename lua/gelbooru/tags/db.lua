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

function M.parse_tag_file(path, target_list, bucket_map)
  if vim.fn.filereadable(path) == 0 then
    return false
  end
  local content = table.concat(vim.fn.readfile(path), "")
  local ok, data = pcall(vim.fn.json_decode, content)
  if not ok or type(data) ~= "table" then
    return false
  end
  for _, t in ipairs(data) do
    M.add_tag_to_index(t, target_list, bucket_map)
  end
  return true
end

function M.load_tags()
  local State = state.State
  local UI = state.UI

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

  local all_tags = vim.deepcopy(config.META_TAGS)
  for _, t in ipairs(all_tags) do
    M.add_tag_to_index(t, nil, nil)
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
    log("INFO", "TAGS", "Loading split tag databases from %s", tags_dir)
    vim.schedule(function()
      M.parse_tag_file(series_file, State.series, State.series_by_first)
      M.parse_tag_file(chars_file, State.characters, State.chars_by_first)
      M.parse_tag_file(artists_file, State.artists, State.artists_by_first)
      M.parse_tag_file(general_file, State.general, State.general_by_first)

      -- Load persistent discovered tags
      if vim.fn.filereadable(disc_file) == 1 then
        local raw = table.concat(vim.fn.readfile(disc_file), "")
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
          log("INFO", "TAGS", "Loaded %d persisted discovered tags", #State.discovered)
        end
      end

      -- Build a prioritized combined list for initial/empty autocomplete display
      for _, t in ipairs(State.series) do
        if #all_tags < 150 then
          table.insert(all_tags, t)
        end
      end
      for _, t in ipairs(State.characters) do
        if #all_tags < 250 then
          table.insert(all_tags, t)
        end
      end
      for _, t in ipairs(State.general) do
        if #all_tags < 350 then
          table.insert(all_tags, t)
        end
      end
      State.all_tags = all_tags

      log(
        "INFO",
        "TAGS",
        "Loaded: series=%d, characters=%d, artists=%d, general=%d, discovered=%d",
        #State.series,
        #State.characters,
        #State.artists,
        #State.general,
        #State.discovered
      )

      if
        State.input_focused
        and UI.bufs.input
        and UI.wins.ac
        and vim.api.nvim_buf_is_valid(UI.bufs.input)
        and vim.api.nvim_win_is_valid(UI.wins.ac)
      then
        local autocomplete = require("gelbooru.ui.autocomplete")
        pcall(autocomplete.update_autocomplete)
      end
    end)
  else
    State.all_tags = all_tags
  end
end

return M
