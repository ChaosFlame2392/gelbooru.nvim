local config = require("gelbooru.core.config")
local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local download = require("gelbooru.net.download")
local constants = require("gelbooru.core.constants")

local json_decode = vim.json and vim.json.decode or vim.fn.json_decode
local json_encode = vim.json and vim.json.encode or vim.fn.json_encode

local M = {}

function M.is_clean_tag(name, count, typ)
  if not name or type(name) ~= "string" or #name < constants.TAG_MIN_NAME_LEN then
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
  if #name > constants.TAG_MAX_NAME_LEN and not name:find("%(") then
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

function M.remove_from_list(list, name_lower)
  if not list or not name_lower then
    return false
  end
  local removed = false
  for i = #list, 1, -1 do
    local item = list[i]
    if item and (item.n_lower == name_lower or (item.n and item.n:lower() == name_lower)) then
      table.remove(list, i)
      removed = true
    end
  end
  return removed
end

function M.remove_from_bucket(bucket_map, name_lower)
  if not bucket_map or not name_lower or #name_lower == 0 then
    return false
  end
  local b = name_lower:sub(1, 1)
  local bucket = bucket_map[b]
  if bucket then
    return M.remove_from_list(bucket, name_lower)
  end
  return false
end

function M.prune_tags_from_disk(prune_set)
  if not prune_set or next(prune_set) == nil then
    return
  end
  local tags_dir = config.options.tags_dir
  local files = {
    tags_dir .. "/series.json",
    tags_dir .. "/characters.json",
    tags_dir .. "/artists.json",
    tags_dir .. "/general.json",
    config.get_discovered_tags_file(),
  }

  for _, path in ipairs(files) do
    local f = io.open(path, "r")
    if f then
      local raw = f:read("*a")
      f:close()
      local ok, list = pcall(json_decode, raw)
      if ok and type(list) == "table" then
        local modified = false
        local filtered = {}
        for _, t in ipairs(list) do
          local nl = t.n and t.n:lower()
          if nl and prune_set[nl] then
            modified = true
          else
            filtered[#filtered + 1] = t
          end
        end
        if modified then
          local enc_ok, enc = pcall(json_encode, filtered)
          if enc_ok and enc then
            local out = io.open(path, "w")
            if out then
              out:write(enc)
              out:close()
            end
          end
        end
      end
    end
  end
end

function M.schedule_disk_prune(name_lower)
  if not name_lower then
    return
  end
  local State = state.State
  local UI = state.UI
  State.pending_prunes = State.pending_prunes or {}
  State.pending_prunes[name_lower] = true

  if UI.prune_disk_timer and not UI.prune_disk_timer:is_closing() then
    UI.prune_disk_timer:stop()
  else
    UI.prune_disk_timer = vim.loop.new_timer()
  end

  UI.prune_disk_timer:start(
    1000,
    0,
    vim.schedule_wrap(function()
      if UI.prune_disk_timer and not UI.prune_disk_timer:is_closing() then
        UI.prune_disk_timer:stop()
        UI.prune_disk_timer:close()
        UI.prune_disk_timer = nil
      end
      if State.torn_down then
        return
      end
      local prunes = State.pending_prunes
      State.pending_prunes = {}
      if prunes and next(prunes) ~= nil then
        M.prune_tags_from_disk(prunes)
      end
    end)
  )
end

function M.prune_tag(tag_name, opts)
  if not tag_name or type(tag_name) ~= "string" or tag_name == "" then
    return false
  end
  local nl = tag_name:lower()
  local State = state.State
  local existed = false

  if State.tags_by_name and State.tags_by_name[nl] then
    State.tags_by_name[nl] = nil
    existed = true
  end

  if State.series then
    if M.remove_from_list(State.series, nl) then existed = true end
  end
  if State.characters then
    if M.remove_from_list(State.characters, nl) then existed = true end
  end
  if State.artists then
    if M.remove_from_list(State.artists, nl) then existed = true end
  end
  if State.general then
    if M.remove_from_list(State.general, nl) then existed = true end
  end

  if State.series_by_first then M.remove_from_bucket(State.series_by_first, nl) end
  if State.chars_by_first then M.remove_from_bucket(State.chars_by_first, nl) end
  if State.artists_by_first then M.remove_from_bucket(State.artists_by_first, nl) end
  if State.general_by_first then M.remove_from_bucket(State.general_by_first, nl) end

  if State.all_tags then M.remove_from_list(State.all_tags, nl) end

  if State.discovered_by_name and State.discovered_by_name[nl] then
    State.discovered_by_name[nl] = nil
    existed = true
  end
  if State.discovered then
    if M.remove_from_list(State.discovered, nl) then existed = true end
  end

  if opts and opts.immediate_disk then
    M.prune_tags_from_disk({ [nl] = true })
  else
    M.schedule_disk_prune(nl)
  end

  return existed
end

function M.update_tag_in_index(item)
  if not item or not item.n or type(item.n) ~= "string" then
    return false
  end
  local nl = item.n:lower()
  local State = state.State
  local new_count = tonumber(item.c) or 0
  local new_type = tonumber(item.t) or 0

  if not M.is_clean_tag(item.n, new_count, new_type) then
    M.prune_tag(nl)
    return false
  end

  if not State.tags_by_name then
    State.tags_by_name = {}
  end

  local existing = State.tags_by_name[nl]
  if existing then
    local old_type = tonumber(existing.t) or 0
    existing.c = new_count
    if old_type ~= new_type then
      -- Reclassify tag: remove from old category list and bucket
      if old_type == 3 then
        if State.series then M.remove_from_list(State.series, nl) end
        if State.series_by_first then M.remove_from_bucket(State.series_by_first, nl) end
      elseif old_type == 4 then
        if State.characters then M.remove_from_list(State.characters, nl) end
        if State.chars_by_first then M.remove_from_bucket(State.chars_by_first, nl) end
      elseif old_type == 1 then
        if State.artists then M.remove_from_list(State.artists, nl) end
        if State.artists_by_first then M.remove_from_bucket(State.artists_by_first, nl) end
      else
        if State.general then M.remove_from_list(State.general, nl) end
        if State.general_by_first then M.remove_from_bucket(State.general_by_first, nl) end
      end

      -- Insert into new category list and bucket
      existing.t = new_type
      if new_type == 3 then
        M.add_tag_to_index(existing, State.series, State.series_by_first)
      elseif new_type == 4 then
        M.add_tag_to_index(existing, State.characters, State.chars_by_first)
      elseif new_type == 1 then
        M.add_tag_to_index(existing, State.artists, State.artists_by_first)
      else
        M.add_tag_to_index(existing, State.general, State.general_by_first)
      end
    end
    return true
  else
    -- Add newly discovered tag to appropriate category
    local t = { n = item.n, c = new_count, t = new_type }
    if new_type == 3 then
      M.add_tag_to_index(t, State.series, State.series_by_first)
    elseif new_type == 4 then
      M.add_tag_to_index(t, State.characters, State.chars_by_first)
    elseif new_type == 1 then
      M.add_tag_to_index(t, State.artists, State.artists_by_first)
    else
      M.add_tag_to_index(t, State.general, State.general_by_first)
    end
    return true
  end
end

function M.verify_and_prune_tag(tag_name, cb)
  if not tag_name or type(tag_name) ~= "string" or tag_name == "" then
    if cb then cb(false) end
    return
  end
  local clean_tag = tag_name:lower()
  local url = string.format("%s&names=%s%s", config.options.tags_api, util.url_encode(clean_tag), util.auth_qs())

  download.curl_async(url, function(body)
    if state.State.torn_down then
      if cb then cb(false) end
      return
    end
    if not body then
      if cb then cb(false) end
      return
    end

    local ok, data = pcall(json_decode, body)
    local is_dead = true
    if ok and data and type(data) == "table" and not data.error and data.tag then
      local tag_list = util.ensure_array(data.tag)
      for _, t in ipairs(tag_list) do
        if t.name and t.name:lower() == clean_tag then
          local count = tonumber(t.count) or 0
          local typ = tonumber(t.type) or 0
          if count > 0 and M.is_clean_tag(t.name, count, typ) then
            is_dead = false
            M.update_tag_in_index({ n = t.name, c = count, t = typ })
          end
          break
        end
      end
    end

    if is_dead then
      log("INFO", "SELF_HEAL", "Pruned dead or aliased tag '%s' from memory and disk", clean_tag)
      M.prune_tag(clean_tag)
      if cb then cb(true) end
    else
      if cb then cb(false) end
    end
  end)
end

local DEFAULT_TAG_CAPS = {
  series = constants.TAG_DEFAULT_CAP_SERIES,
  characters = constants.TAG_DEFAULT_CAP_CHARS,
  artists = constants.TAG_DEFAULT_CAP_ARTISTS,
  general = constants.TAG_DEFAULT_CAP_GENERAL,
}

function M.parse_tag_file(path, target_list, bucket_map, cap)
  local f = io.open(path, "r")
  if not f then
    return false
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(json_decode, content)
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
  if State.tags_loaded or State.tags_loading then
    return
  end
  State.tags_loading = true
  local epoch = (State.tag_load_epoch or 0) + 1
  State.tag_load_epoch = epoch

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
    local copy = { n = t.n, c = t.c, t = t.t, local_only = t.local_only }
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
      local ok, disc = pcall(json_decode, raw)
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
      if State.torn_down or State.tag_load_epoch ~= epoch then
        return
      end
      M.parse_tag_file(series_file, State.series, State.series_by_first, caps.series)

      vim.schedule(function()
        if State.torn_down or State.tag_load_epoch ~= epoch then
          return
        end
        M.parse_tag_file(general_file, State.general, State.general_by_first, caps.general)

        -- Build initial all_tags recommendation set from series and general
        for _, t in ipairs(State.series) do
          if #all_tags < constants.TAG_RECOMMEND_CAP_PRIMARY then
            table.insert(all_tags, t)
          end
        end
        for _, t in ipairs(State.general) do
          if #all_tags < constants.TAG_RECOMMEND_CAP_SECONDARY then
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
          if State.torn_down or State.tag_load_epoch ~= epoch then
            return
          end
          M.parse_tag_file(chars_file, State.characters, State.chars_by_first, caps.characters)

          vim.schedule(function()
            if State.torn_down or State.tag_load_epoch ~= epoch then
              return
            end
            M.parse_tag_file(artists_file, State.artists, State.artists_by_first, caps.artists)

            State.tags_loading = false
            State.tags_loaded = true

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
    State.tags_loading = false
    State.tags_loaded = true
    State.all_tags = all_tags
  end
end

return M
