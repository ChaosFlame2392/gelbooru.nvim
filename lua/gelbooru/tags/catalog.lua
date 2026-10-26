local config = require("gelbooru.core.config")
local constants = require("gelbooru.core.constants")
local log = require("gelbooru.core.log")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local download = require("gelbooru.net.download")

local json_decode = vim.json and vim.json.decode or vim.fn.json_decode

local M = {}

-- Private encapsulated tag stores
local series = {}
local characters = {}
local artists = {}
local general = {}
local meta = {}

-- First-letter hash bucket maps for instant prefix candidate lookups
local series_by_first = {}
local chars_by_first = {}
local artists_by_first = {}
local general_by_first = {}

-- Exact lookup indices
local tags_by_name = {}
local discovered_by_name = {}
local discovered = {}
local all_tags = {}

-- Lifecycle and async state
local is_loading = false
local is_loaded = false
local load_epoch = 0
local pending_load_callbacks = {}

-- Encapsulated debounce timers & background state
local save_discovered_timer = nil
local prune_disk_timer = nil
local api_tag_timer = nil
local pending_prunes = {}
local in_flight_tags = {}
local negative_tag_cache = {}
local current_tags_dir = nil
local current_discovered_file = nil

local DEFAULT_TAG_CAPS = {
  series = constants.TAG_DEFAULT_CAP_SERIES,
  characters = constants.TAG_DEFAULT_CAP_CHARS,
  artists = constants.TAG_DEFAULT_CAP_ARTISTS,
  general = constants.TAG_DEFAULT_CAP_GENERAL,
}

--- Validate tag format, length, and count constraints.
--- @param name string|any
--- @param count number|any
--- @param typ number|any
--- @return boolean
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

--- Add a validated tag into the specified category list and bucket map, registering in tags_by_name.
--- @param t table
--- @param target_list? table
--- @param bucket_map? table
--- @return boolean
function M.add_tag_to_index(t, target_list, bucket_map, force)
  if not t or not t.n or type(t.n) ~= "string" then
    return false
  end
  local c = tonumber(t.c) or 0
  local typ = tonumber(t.t) or 0
  if not force and not M.is_clean_tag(t.n, c, typ) then
    return false
  end
  local nl = t.n:lower()
  t.n_lower = nl
  t.norm = util.normalize_str(nl)
  t.c = c
  t.t = typ
  if target_list then
    target_list[#target_list + 1] = t
  end
  tags_by_name[nl] = t
  if bucket_map then
    local b = nl:sub(1, 1)
    local bucket = bucket_map[b]
    if not bucket then
      bucket = {}
      bucket_map[b] = bucket
    end
    bucket[#bucket + 1] = t
  end
  return true
end

local function get_category_target(typ)
  if typ == 3 then
    return series, series_by_first
  elseif typ == 4 then
    return characters, chars_by_first
  elseif typ == 1 then
    return artists, artists_by_first
  elseif typ == 5 then
    return meta, nil
  else
    return general, general_by_first
  end
end

--- Add a tag to the appropriate internal category and bucket map based on its type.
--- @param t table
--- @param force? boolean
--- @return boolean
function M.add_tag(t, force)
  if not t then
    return false
  end
  local name = t.n or t.name
  if not name or type(name) ~= "string" then
    return false
  end
  local typ = tonumber(t.t or t.type or t.category) or 0
  local count = tonumber(t.c or t.count) or 0
  local item = (t.n and t.t) and t or { n = name, t = typ, c = count, local_only = t.local_only }

  local target_list, bucket_map = get_category_target(typ)
  local added = M.add_tag_to_index(item, target_list, bucket_map, force)
  if added and typ == 5 then
    all_tags[#all_tags + 1] = item
  end
  return added
end

--- Parse a JSON tag array file up to a specified cap and index its items.
--- @param path string
--- @param target_list? table
--- @param bucket_map? table
--- @param cap? number
--- @return boolean
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

--- Returns true if tag catalog is loaded.
--- @return boolean
function M.is_loaded()
  return is_loaded
end

--- Returns true if tag catalog is currently asynchronously loading.
--- @return boolean
function M.is_loading()
  return is_loading
end

--- Look up a tag by its name (case-insensitive).
--- @param name string
--- @return table|nil
function M.get_tag(name)
  if not name or type(name) ~= "string" then
    return nil
  end
  local nl = name:lower()
  local t = tags_by_name[nl] or tags_by_name[name]
  if not t and state.State and state.State.tags_by_name then
    t = state.State.tags_by_name[nl] or state.State.tags_by_name[name]
  end
  return t
end

--- Check if a tag exists in the catalog.
--- @param name string
--- @return boolean
function M.has_tag(name)
  return M.get_tag(name) ~= nil
end

--- Return catalog summary statistics for testing and diagnostics.
--- @return table
function M.get_stats()
  local total = 0
  for _ in pairs(tags_by_name) do
    total = total + 1
  end
  return {
    series = #series,
    characters = #characters,
    artists = #artists,
    general = #general,
    meta = #meta,
    discovered = #discovered,
    all_tags = #all_tags,
    total = total,
  }
end

--- Remove matching item from array list.
--- @param list table
--- @param name_lower string
--- @return boolean
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

--- Remove matching item from bucket map.
--- @param bucket_map table
--- @param name_lower string
--- @return boolean
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

--- Optional listener callback for tag updates (e.g. from UI)
M.on_tags_updated = nil

local function notify_tags_updated(items)
  if type(M.on_tags_updated) == "function" then
    pcall(M.on_tags_updated, items)
  end
end

--- Immediately flush any pending tag prunes to disk without waiting for debounce.
function M.flush_prunes_now()
  prune_disk_timer = util.close_timer(prune_disk_timer)
  local prunes = pending_prunes
  pending_prunes = {}
  if prunes and next(prunes) ~= nil then
    M.prune_tags_from_disk(prunes)
  end
end

--- Reset all catalog state, close all background timers, and abort any in-flight asynchronous tasks.
function M.reset()
  save_discovered_timer = util.close_timer(save_discovered_timer)
  prune_disk_timer = util.close_timer(prune_disk_timer)
  api_tag_timer = util.close_timer(api_tag_timer)
  pending_prunes = {}
  in_flight_tags = {}
  negative_tag_cache = {}
  current_tags_dir = nil
  current_discovered_file = nil

  load_epoch = load_epoch + 1
  is_loading = false
  is_loaded = false
  pending_load_callbacks = {}

  series = {}
  characters = {}
  artists = {}
  general = {}
  meta = {}

  series_by_first = {}
  chars_by_first = {}
  artists_by_first = {}
  general_by_first = {}

  tags_by_name = {}
  discovered_by_name = {}
  discovered = {}
  all_tags = {}
end

--- Cleanly flush pending changes, stop and close all encapsulated timers, and reset catalog state.
function M.teardown()
  pcall(M.save_discovered_now)
  pcall(M.flush_prunes_now)
  M.reset()
end

--- Progressively load tag databases across event-loop turns without blocking the main thread.
--- @param opts? table|function
--- @param callback? function
function M.load(opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}

  if is_loaded then
    if callback then
      callback(true)
    end
    return
  end

  if is_loading then
    if callback then
      table.insert(pending_load_callbacks, callback)
    end
    return
  end

  if callback then
    table.insert(pending_load_callbacks, callback)
  end

  is_loading = true
  local epoch = load_epoch + 1
  load_epoch = epoch

  local caps = vim.tbl_extend("force", DEFAULT_TAG_CAPS, opts.caps or {})
  local tags_dir = opts.tags_dir or config.options.tags_dir
  local disc_file = opts.discovered_file or (config.get_discovered_tags_file and config.get_discovered_tags_file()) or (tags_dir .. "/discovered.json")
  current_tags_dir = opts.tags_dir
  current_discovered_file = opts.discovered_file

  series = {}
  characters = {}
  artists = {}
  general = {}
  meta = {}

  series_by_first = {}
  chars_by_first = {}
  artists_by_first = {}
  general_by_first = {}

  tags_by_name = {}
  discovered_by_name = {}
  discovered = {}
  all_tags = {}

  -- Inject meta tags
  if config.META_TAGS then
    for _, t in ipairs(config.META_TAGS) do
      local copy = { n = t.n, c = t.c, t = t.t, local_only = t.local_only }
      M.add_tag_to_index(copy, meta, nil)
      all_tags[#all_tags + 1] = copy
    end
  end

  util.ensure(tags_dir)
  local series_file = tags_dir .. "/series.json"
  local chars_file = tags_dir .. "/characters.json"
  local artists_file = tags_dir .. "/artists.json"
  local general_file = tags_dir .. "/general.json"

  local has_split = vim.fn.filereadable(series_file) == 1
    or vim.fn.filereadable(chars_file) == 1
    or vim.fn.filereadable(general_file) == 1

  local function finish_loading()
    is_loading = false
    is_loaded = true

    local cbs = pending_load_callbacks
    pending_load_callbacks = {}
    for _, cb in ipairs(cbs) do
      pcall(cb, true)
    end
  end

  if not has_split then
    finish_loading()
    return
  end

  log("INFO", "TAGS", "Loading tag databases from %s", tags_dir)

  -- Step 1: Load discovered.json synchronously (small, high personal relevance)
  local df = io.open(disc_file, "r")
  if df then
    local raw = df:read("*a")
    df:close()
    local ok, disc = pcall(json_decode, raw)
    if ok and type(disc) == "table" then
      for _, t in ipairs(disc) do
        if t.n and type(t.n) == "string" then
          local nl = t.n:lower()
          discovered_by_name[nl] = true
          discovered[#discovered + 1] = t
          M.add_tag(t)
        end
      end
    end
  end

  -- Step 2: Load category databases across progressive event-loop turns
  vim.schedule(function()
    if load_epoch ~= epoch or (state.State and state.State.torn_down) then
      return
    end
    M.parse_tag_file(series_file, series, series_by_first, caps.series)

    vim.schedule(function()
      if load_epoch ~= epoch or (state.State and state.State.torn_down) then
        return
      end
      M.parse_tag_file(general_file, general, general_by_first, caps.general)

      -- Build initial all_tags recommendation set from series and general
      for _, t in ipairs(series) do
        if #all_tags < constants.TAG_RECOMMEND_CAP_PRIMARY then
          table.insert(all_tags, t)
        end
      end
      for _, t in ipairs(general) do
        if #all_tags < constants.TAG_RECOMMEND_CAP_SECONDARY then
          table.insert(all_tags, t)
        end
      end

      notify_tags_updated()

      vim.schedule(function()
        if load_epoch ~= epoch or (state.State and state.State.torn_down) then
          return
        end
        M.parse_tag_file(chars_file, characters, chars_by_first, caps.characters)

        vim.schedule(function()
          if load_epoch ~= epoch or (state.State and state.State.torn_down) then
            return
          end
          M.parse_tag_file(artists_file, artists, artists_by_first, caps.artists)

          log(
            "INFO",
            "TAGS",
            "Tag catalog ready: series=%d, characters=%d, artists=%d, general=%d, discovered=%d, meta=%d",
            #series,
            #characters,
            #artists,
            #general,
            #discovered,
            #meta
          )

          notify_tags_updated()
          finish_loading()
        end)
      end)
    end)
  end)
end

--- Record newly discovered tag or list of tags, adding them to memory catalog and debouncing disk persistence (500ms).
--- @param item_or_items table
--- @return boolean
function M.record_discovered(item_or_items)
  if not item_or_items then
    return false
  end
  local items = item_or_items
  if (item_or_items.n and type(item_or_items.n) == "string")
    or (item_or_items.name and type(item_or_items.name) == "string")
  then
    items = { item_or_items }
  elseif type(item_or_items) ~= "table" then
    return false
  end

  local added_any = false
  for _, item in ipairs(items) do
    if item then
      local name = item.n or item.name
      if name and type(name) == "string" then
        local c = tonumber(item.c or item.count) or 0
        local typ = tonumber(item.t or item.type or item.category) or 0
        if M.is_clean_tag(name, c, typ) then
          local nl = name:lower()
          local record_item = {
            n = name,
            t = typ,
            c = c,
          }
          if not discovered_by_name[nl] then
            discovered_by_name[nl] = true
            discovered[#discovered + 1] = record_item
            added_any = true
          end
          if not tags_by_name[nl] then
            M.add_tag(record_item)
            added_any = true
          end
        end
      end
    end
  end

  if not added_any then
    return false
  end

  if state.State and state.State.torn_down then
    return false
  end

  if save_discovered_timer and save_discovered_timer:is_closing() then
    save_discovered_timer = nil
  end
  if not save_discovered_timer then
    save_discovered_timer = vim.loop.new_timer()
  end
  save_discovered_timer:stop()
  save_discovered_timer:start(
    constants.DISCOVERED_FLUSH_DEBOUNCE_MS or 500,
    0,
    vim.schedule_wrap(function()
      if state.State and state.State.torn_down then
        save_discovered_timer = util.close_timer(save_discovered_timer)
        return
      end
      if save_discovered_timer then
        M.save_discovered_now()
      end
    end)
  )

  return true
end

--- Immediately flush all discovered tags to disk, merging with existing entries.
function M.save_discovered_now()
  save_discovered_timer = util.close_timer(save_discovered_timer)

  if state.State and state.State.torn_down then
    return
  end

  if #discovered == 0 then
    return
  end

  local disc_file = current_discovered_file
    or (config.get_discovered_tags_file and config.get_discovered_tags_file())
    or ((current_tags_dir or config.options.tags_dir) .. "/discovered.json")
  if not disc_file then
    return
  end

  util.ensure(vim.fn.fnamemodify(disc_file, ":h"))

  -- Read existing disk entries and merge to prevent data loss across sessions
  local existing_map = {}
  local merged = {}
  local df = io.open(disc_file, "r")
  if df then
    local raw = df:read("*a")
    df:close()
    local ok, disk_list = pcall(json_decode, raw)
    if ok and type(disk_list) == "table" then
      for _, t in ipairs(disk_list) do
        if t.n and type(t.n) == "string" then
          local nl = t.n:lower()
          if not pending_prunes[nl] then
            existing_map[nl] = true
            merged[#merged + 1] = t
          end
        end
      end
    end
  end

  for _, t in ipairs(discovered) do
    if t.n and type(t.n) == "string" then
      local nl = t.n:lower()
      if not pending_prunes[nl] and not existing_map[nl] then
        existing_map[nl] = true
        merged[#merged + 1] = t
      end
    end
  end

  if util.write_json(disc_file, merged) then
    log("INFO", "TAGS", "Persisted %d discovered tags to %s", #merged, disc_file)
  end

  for _, t in ipairs(merged) do
    if t.n and type(t.n) == "string" then
      local nl = t.n:lower()
      if not discovered_by_name[nl] then
        discovered_by_name[nl] = true
        discovered[#discovered + 1] = t
      end
    end
  end
end

--- Prune specified lowercase tag set from all disk files.
--- @param prune_set table<string, boolean>
function M.prune_tags_from_disk(prune_set)
  if state.State and state.State.torn_down then
    return
  end
  if not prune_set or next(prune_set) == nil then
    return
  end
  local tags_dir = current_tags_dir or config.options.tags_dir
  local disc_file = current_discovered_file
    or (config.get_discovered_tags_file and config.get_discovered_tags_file())
    or (tags_dir .. "/discovered.json")
  local files = {
    tags_dir .. "/series.json",
    tags_dir .. "/characters.json",
    tags_dir .. "/artists.json",
    tags_dir .. "/general.json",
    disc_file,
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
          util.write_json(path, filtered)
        end
      end
    end
  end
end

--- Schedule a debounced disk prune.
--- @param name_lower string
function M.schedule_disk_prune(name_lower)
  if not name_lower then
    return
  end
  pending_prunes[name_lower] = true

  prune_disk_timer = util.close_timer(prune_disk_timer)
  if state.State and state.State.torn_down then
    return
  end

  prune_disk_timer = vim.loop.new_timer()
  prune_disk_timer:start(
    constants.TAG_PRUNE_DEBOUNCE_MS or 1000,
    0,
    vim.schedule_wrap(function()
      prune_disk_timer = util.close_timer(prune_disk_timer)
      if state.State and state.State.torn_down then
        pending_prunes = {}
        return
      end
      local prunes = pending_prunes
      pending_prunes = {}
      if prunes and next(prunes) ~= nil then
        M.prune_tags_from_disk(prunes)
      end
    end)
  )
end

local function remove_from_category(typ, nl)
  local target_list, bucket_map = get_category_target(typ)
  if target_list then
    M.remove_from_list(target_list, nl)
  end
  if bucket_map then
    M.remove_from_bucket(bucket_map, nl)
  end
  if typ == 5 then
    M.remove_from_list(all_tags, nl)
  end
end

--- Prune a tag from memory catalog and schedule or immediately write to disk.
--- @param tag_name string
--- @param opts? table
--- @return boolean
function M.prune_tag(tag_name, opts)
  if not tag_name or type(tag_name) ~= "string" or tag_name == "" then
    return false
  end
  local nl = tag_name:lower()
  local existed = false

  local existing = tags_by_name[nl]
  if existing then
    tags_by_name[nl] = nil
    existed = true
    if existing.t ~= nil then
      remove_from_category(existing.t, nl)
    else
      if M.remove_from_list(series, nl) then existed = true end
      if M.remove_from_list(characters, nl) then existed = true end
      if M.remove_from_list(artists, nl) then existed = true end
      if M.remove_from_list(general, nl) then existed = true end
      if M.remove_from_list(meta, nl) then existed = true end

      if M.remove_from_bucket(series_by_first, nl) then existed = true end
      if M.remove_from_bucket(chars_by_first, nl) then existed = true end
      if M.remove_from_bucket(artists_by_first, nl) then existed = true end
      if M.remove_from_bucket(general_by_first, nl) then existed = true end
    end
  else
    if M.remove_from_list(series, nl) then existed = true end
    if M.remove_from_list(characters, nl) then existed = true end
    if M.remove_from_list(artists, nl) then existed = true end
    if M.remove_from_list(general, nl) then existed = true end
    if M.remove_from_list(meta, nl) then existed = true end

    if M.remove_from_bucket(series_by_first, nl) then existed = true end
    if M.remove_from_bucket(chars_by_first, nl) then existed = true end
    if M.remove_from_bucket(artists_by_first, nl) then existed = true end
    if M.remove_from_bucket(general_by_first, nl) then existed = true end
  end

  if M.remove_from_list(all_tags, nl) then existed = true end

  if discovered_by_name[nl] then
    discovered_by_name[nl] = nil
    existed = true
  end
  if M.remove_from_list(discovered, nl) then existed = true end

  pending_prunes[nl] = true

  if opts and opts.immediate_disk then
    prune_disk_timer = util.close_timer(prune_disk_timer)
    local prunes = pending_prunes
    pending_prunes = {}
    M.prune_tags_from_disk(prunes)
  else
    M.schedule_disk_prune(nl)
  end

  return existed
end

--- Update count or reclassify category of a tag in the catalog.
--- @param item table
--- @return boolean
function M.update_tag_in_index(item)
  if not item or not item.n or type(item.n) ~= "string" then
    return false
  end
  local nl = item.n:lower()
  local new_count = tonumber(item.c) or 0
  local new_type = tonumber(item.t) or 0

  if not M.is_clean_tag(item.n, new_count, new_type) then
    M.prune_tag(nl)
    return false
  end

  local existing = tags_by_name[nl]
  if existing then
    local old_type = tonumber(existing.t) or 0
    existing.c = new_count
    if old_type ~= new_type then
      remove_from_category(old_type, nl)
      existing.t = new_type
      M.add_tag(existing)
    end
    return true
  else
    local t = { n = item.n, c = new_count, t = new_type }
    return M.add_tag(t)
  end
end

--- Verify a single tag online against Gelbooru API; prune from memory and disk if dead.
--- @param tag_name string
--- @param cb? function
function M.verify_and_prune_tag(tag_name, cb)
  if not tag_name or type(tag_name) ~= "string" or tag_name == "" then
    if cb then cb(false) end
    return
  end
  local clean_tag = tag_name:lower()
  local url = string.format("%s&names=%s%s", config.options.tags_api, util.url_encode(clean_tag), util.auth_qs())

  download.curl_async(url, function(body)
    if state.State and state.State.torn_down then
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

--- Extract unknown tags from post, query Gelbooru API in batch, record discovered tags,
--- and invoke callback if an artist was discovered.
--- @param p table
--- @param on_complete? function
function M.resolve_post_tags(p, on_complete)
  if not p or not p.tags or p.tags == "" or not p.tags:find("%S") then
    return
  end
  local missing = {}
  local seen = {}
  for raw_tag in (p.tags or ""):gmatch("%S+") do
    local clean_tag = util.decode_html(raw_tag):lower()
    if clean_tag ~= "" and not seen[clean_tag] then
      seen[clean_tag] = true
      if not tags_by_name[clean_tag]
        and not in_flight_tags[clean_tag]
        and not negative_tag_cache[clean_tag] then
        table.insert(missing, clean_tag)
      end
    end
  end

  if #missing == 0 then
    if on_complete then
      pcall(on_complete, { found_artist = false, count = 0 })
    end
    return
  end

  log("DEBUG", "TAG_RESOLVE", "Resolving %d unknown tags for post %s", #missing, tostring(p.id))
  local chunks = {}
  local queried_tags = {}
  for i = 1, math.min(#missing, constants.TAG_RESOLVE_BATCH_SIZE or 40) do
    local tag = missing[i]
    chunks[#chunks + 1] = util.url_encode(tag)
    queried_tags[#queried_tags + 1] = tag
    in_flight_tags[tag] = true
  end
  local url = string.format("%s&names=%s%s", config.options.tags_api, table.concat(chunks, "+"), util.auth_qs())

  download.curl_async(url, function(body)
    for _, tag in ipairs(queried_tags) do
      in_flight_tags[tag] = nil
    end

    if state.State and state.State.torn_down then
      return
    end
    if not body then
      if on_complete then
        pcall(on_complete, { found_artist = false, count = 0, error = "no_body" })
      end
      return
    end
    local ok, data = pcall(json_decode, body)
    if ok and data and type(data) == "table" and not data.error and (data.tag or data["@attributes"]) then
      local tag_list = data.tag and util.ensure_array(data.tag) or {}
      local found_set = {}
      local found_artist = false
      local discovered_items = {}
      for _, t in ipairs(tag_list) do
        if t.name and t.type then
          local count = tonumber(t.count) or 0
          local typ = tonumber(t.type) or 0
          local nl = t.name:lower()
          found_set[nl] = true
          if M.is_clean_tag(t.name, count, typ) then
            local item = {
              n = t.name,
              t = typ,
              c = count,
            }
            if not tags_by_name[nl] then
              if item.t == 1 then
                found_artist = true
                log("INFO", "TAG_RESOLVE", "Discovered artist '%s' for post %s", item.n, tostring(p.id))
              end
              M.add_tag(item)
              discovered_items[#discovered_items + 1] = item
            elseif item.t == 1 then
              found_artist = true
            end
          end
        end
      end

      if #discovered_items > 0 then
        M.record_discovered(discovered_items)
      end

      for _, tag in ipairs(queried_tags) do
        if not found_set[tag] then
          negative_tag_cache[tag] = true
        end
      end

      if on_complete then
        pcall(on_complete, { found_artist = found_artist, count = #discovered_items })
      end
    else
      if on_complete then
        pcall(on_complete, { found_artist = false, count = 0, error = "invalid_response" })
      end
    end
  end)
end

--- Debounced API query (300ms) for live fallback tags, updating catalog and triggering UI autocomplete re-render if input is focused.
--- @param query string
function M.fetch_api_tags(query)
  if not query or type(query) ~= "string" or query == "" or #query < 2 then
    return
  end

  api_tag_timer = util.close_timer(api_tag_timer)

  local timer = vim.loop.new_timer()
  api_tag_timer = timer
  timer:start(
    constants.TAG_API_FETCH_DEBOUNCE_MS or 300,
    0,
    vim.schedule_wrap(function()
      if api_tag_timer == timer then
        api_tag_timer = nil
      end
      timer = util.close_timer(timer)

      if state.State and state.State.torn_down then
        return
      end

      local url = string.format(
        "%s&name_pattern=%%%s%%&orderby=count&limit=%d%s",
        config.options.tags_api,
        util.url_encode(query),
        constants.TAG_API_FETCH_LIMIT or 25,
        util.auth_qs()
      )
      download.curl_async(url, function(body)
        if state.State and state.State.torn_down then
          return
        end
        if not body then
          return
        end
        local ok, data = pcall(json_decode, body)
        local tag_list = (ok and data and data.tag) and util.ensure_array(data.tag) or {}
        if #tag_list > 0 then
          local discovered_items = {}
          for _, t in ipairs(tag_list) do
            if t.name and t.type then
              local name_lower = t.name:lower()
              local count = tonumber(t.count) or 0
              local typ = tonumber(t.type) or 0
              if not tags_by_name[name_lower] and M.is_clean_tag(t.name, count, typ) then
                local item = {
                  n = t.name,
                  t = typ,
                  c = count,
                }
                M.add_tag(item)
                discovered_items[#discovered_items + 1] = item
              end
            end
          end
          if #discovered_items > 0 then
            M.record_discovered(discovered_items)
            notify_tags_updated(discovered_items)
          end
        end
      end)
    end)
  )
end

--- Clear in-flight and negative lookup caches.
function M.reset_cache()
  in_flight_tags = {}
  negative_tag_cache = {}
end

--- Check if token represents a query syntax directive rather than a booru tag.
--- @param t string|any
--- @return boolean
local function is_syntax_directive(t)
  if not t or type(t) ~= "string" or t == "" then
    return false
  end
  local s = t:lower()
  if s == "random" or s == "asc" or s == "desc" then
    return true
  end
  if s:match("^sort:")
    or s:match("^order:")
    or s:match("^limit:")
    or s:match("^offset:")
    or s:match("^rating:")
    or s:match("^score:")
    or s:match("^id:")
    or s:match("^artist:")
    or s:match("^character:") then
    return true
  end
  return false
end

M.is_syntax_directive = is_syntax_directive

local function make_candidate(t, score, count, typ, is_local_only)
  return setmetatable({
    item = t,
    name = t.n,
    n = t.n,
    category = typ,
    t = typ,
    count = count,
    c = count,
    score = score,
    local_only = is_local_only,
  }, { __index = t })
end

local function calculate_candidate_score(base_score, typ, count, cat_nudge)
  if typ == 5 then
    return constants.SCORE_META_PIN
  end
  local pop = math.log10(count + 1) * constants.SCORE_POP_MULTIPLIER
  return (base_score or 0) + pop + (cat_nudge or 0)
end

--- Search tag catalog for matching candidates, scored by match accuracy, popularity, and category relevance.
--- @param prefix? string
--- @param opts? { is_local?: boolean, limit?: number }
--- @return table[]
function M.search(prefix, opts)
  local raw = type(prefix) == "string" and prefix or (prefix and tostring(prefix) or "")
  local search_target = raw:match("^%s*(.-)%s*$") or ""
  search_target = search_target:gsub("^[|%-~]+", ""):lower()
  local is_local = (opts and opts.is_local) or false

  -- Empty prefix query handling: returns items from all_tags (and config.META_TAGS fallback)
  if search_target == "" then
    local max_empty = (opts and opts.limit) or constants.AC_EMPTY_QUERY_LIMIT
    local results = {}
    local seen = {}

    local function add_item(t)
      local is_local_only = t.local_only or false
      if is_local or not is_local_only then
        local nl = t.n_lower or (t.n and t.n:lower())
        if nl and not seen[nl] then
          seen[nl] = true
          local count = tonumber(t.c) or 0
          local typ = tonumber(t.t) or 0
          local score = calculate_candidate_score(0, typ, count, 0)
          results[#results + 1] = make_candidate(t, score, count, typ, is_local_only)
        end
      end
    end

    for i = 1, #all_tags do
      add_item(all_tags[i])
    end
    if config.META_TAGS then
      for _, t in ipairs(config.META_TAGS) do
        add_item(t)
      end
    end

    table.sort(results, function(a, b)
      if math.abs(a.score - b.score) > 0.0001 then
        return a.score > b.score
      end
      if a.count ~= b.count then
        return a.count > b.count
      end
      return (a.name or "") < (b.name or "")
    end)

    local sliced = {}
    local limit = math.min(max_empty, #results)
    for i = 1, limit do
      sliced[i] = results[i]
    end
    return sliced
  end

  local seen_names = {}
  local candidates = {}
  local first_char = search_target:sub(1, 1)
  local target_norm = util.normalize_str(search_target)
  local has_norm = target_norm ~= "" and #target_norm > 0

  local function evaluate_tag(t, cat_nudge, base_override)
    local is_local_only = t.local_only or false
    local count = tonumber(t.c) or 0
    local typ = tonumber(t.t) or 0
    if not ((is_local or not is_local_only) and (typ == 5 or count >= 1)) then
      return nil
    end
    local nl = t.n_lower or (t.n and t.n:lower())
    if not nl or seen_names[nl] then
      return nil
    end

    local base = base_override
    if not base then
      if nl == search_target then
        base = constants.SCORE_BASE_EXACT
      elseif has_norm and t.norm == target_norm then
        base = constants.SCORE_BASE_NORM
      elseif vim.startswith(nl, search_target) then
        base = constants.SCORE_BASE_PREFIX
      elseif has_norm and t.norm and vim.startswith(t.norm, target_norm) then
        base = constants.SCORE_BASE_PREFIX_NORM
      elseif nl:find(search_target, 1, true) or (has_norm and t.norm and t.norm:find(target_norm, 1, true)) then
        base = constants.SCORE_BASE_SUBSTRING
      end
    else
      if not (nl:find(search_target, 1, true) or (has_norm and t.norm and t.norm:find(target_norm, 1, true))) then
        base = nil
      end
    end

    if not base or base <= 0 then
      return nil
    end

    seen_names[nl] = true
    local score = calculate_candidate_score(base, typ, count, cat_nudge)
    return make_candidate(t, score, count, typ, is_local_only)
  end

  local function check_bucket(bucket, cat_nudge, prefix_only, max_per_bucket)
    if not bucket then
      return
    end
    local added = 0
    local limit = max_per_bucket or constants.AC_BUCKET_LIMIT
    for i = 1, #bucket do
      local cand = evaluate_tag(bucket[i], cat_nudge)
      if cand then
        candidates[#candidates + 1] = cand
        added = added + 1
        if added >= limit then
          break
        end
      end
    end
  end

  -- 1. First-character bucket lookup
  check_bucket(series_by_first[first_char], constants.CAT_NUDGE_SERIES, false, constants.AC_BUCKET_LIMIT)
  check_bucket(chars_by_first[first_char], constants.CAT_NUDGE_CHARACTER, false, constants.AC_BUCKET_LIMIT)
  check_bucket(general_by_first[first_char], constants.CAT_NUDGE_GENERAL, false, constants.AC_BUCKET_LIMIT)
  check_bucket(artists_by_first[first_char], constants.CAT_NUDGE_ARTIST, true, constants.AC_BUCKET_LIMIT)

  -- Check META tags
  local meta_list = (#meta > 0) and meta or (config.META_TAGS or {})
  for _, t in ipairs(meta_list) do
    if is_local or not t.local_only then
      local nl = t.n_lower or (t.n and t.n:lower())
      if nl and not seen_names[nl] then
        if nl == search_target or vim.startswith(nl, search_target) then
          seen_names[nl] = true
          candidates[#candidates + 1] = make_candidate(t, constants.SCORE_META_PIN, 0, 5, t.local_only or false)
        end
      end
    end
  end

  -- 2. Substring fallback across full lists when few candidates found
  if #candidates < constants.AC_SUBSTRING_TRIGGER and #search_target >= constants.AC_MIN_TRIGGER_LEN then
    local function check_full_list(list, cat_nudge, max_needed)
      if not list then
        return false
      end
      for i = 1, #list do
        local cand = evaluate_tag(list[i], cat_nudge, constants.SCORE_BASE_SUBSTRING)
        if cand then
          candidates[#candidates + 1] = cand
          if #candidates >= max_needed then
            return true
          end
        end
      end
      return false
    end

    check_full_list(series, constants.CAT_NUDGE_SERIES, 60)
    if #candidates < 60 then
      check_full_list(characters, constants.CAT_NUDGE_CHARACTER, 80)
    end
    if #candidates < 80 then
      check_full_list(general, constants.CAT_NUDGE_GENERAL, 100)
    end
  end

  table.sort(candidates, function(a, b)
    if math.abs(a.score - b.score) > 0.0001 then
      return a.score > b.score
    end
    if a.count ~= b.count then
      return a.count > b.count
    end
    return (a.name or "") < (b.name or "")
  end)

  -- Trigger live API fallback when candidates < AC_API_FALLBACK_COUNT
  if #candidates < constants.AC_API_FALLBACK_COUNT and #search_target >= constants.AC_MIN_TRIGGER_LEN and not is_syntax_directive(search_target) then
    if type(M.fetch_api_tags) == "function" then
      pcall(M.fetch_api_tags, search_target)
    end
  end

  local results = {}
  local max_cand = (opts and opts.limit) or constants.AC_MAX_RENDERED_CANDIDATES
  local limit = math.min(max_cand, #candidates)
  for i = 1, limit do
    results[i] = candidates[i]
  end
  return results
end

return M
