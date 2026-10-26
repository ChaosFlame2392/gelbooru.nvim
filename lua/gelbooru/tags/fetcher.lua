local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")
local util = require("gelbooru.core.util")
local download = require("gelbooru.net.download")
local catalog = require("gelbooru.tags.catalog")
local constants = require("gelbooru.core.constants")

local json_decode = vim.json and vim.json.decode or vim.fn.json_decode
local json_encode = vim.json and vim.json.encode or vim.fn.json_encode

local M = {}

M.is_running = false

local SPINNERS = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function track_timer(timer)
  local UI = state.UI
  UI.fetcher_timers = UI.fetcher_timers or {}
  local idx = #UI.fetcher_timers + 1
  UI.fetcher_timers[idx] = timer
  return idx
end

local function untrack_timer(idx)
  local UI = state.UI
  if UI.fetcher_timers and UI.fetcher_timers[idx] then
    UI.fetcher_timers[idx] = nil
  end
end

local function defer(delay, fn)
  local timer = vim.loop.new_timer()
  local tid = track_timer(timer)
  timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      untrack_timer(tid)
      if not timer:is_closing() then
        timer:close()
      end
      if state.State.torn_down then
        return
      end
      fn()
    end)
  )
  return timer
end

local function create_progress_spinner(title)
  local spin_i = 1
  local prog_w = 44
  local prog_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[prog_buf].bufhidden = "wipe"
  local ok, prog_win = pcall(vim.api.nvim_open_win, prog_buf, false, {
    relative = "editor",
    anchor = "NE",
    row = 1,
    col = math.max(prog_w, (vim.o.columns or 80) - 1),
    width = prog_w,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = string.format(" %s ", title or "GelbooruTags"),
    title_pos = "center",
    zindex = constants.ZINDEX_PROGRESS_SPINNER,
    focusable = false,
  })

  if ok and prog_win then
    state.UI.tags_spinner_win = prog_win
  end

  local function update(msg)
    if not ok or not vim.api.nvim_win_is_valid(prog_win) or not vim.api.nvim_buf_is_valid(prog_buf) then
      return
    end
    pcall(function()
      vim.bo[prog_buf].modifiable = true
      vim.api.nvim_buf_set_lines(prog_buf, 0, -1, false, { string.format(" %s  %s", SPINNERS[spin_i], msg) })
      vim.bo[prog_buf].modifiable = false
    end)
    spin_i = (spin_i % #SPINNERS) + 1
  end

  local function close()
    if ok and prog_win and vim.api.nvim_win_is_valid(prog_win) then
      pcall(vim.api.nvim_win_close, prog_win, true)
    end
    if state.UI.tags_spinner_win == prog_win then
      state.UI.tags_spinner_win = nil
    end
  end

  return {
    update = update,
    close = close,
  }
end

local function preload_db(tags_dir, file, map, seen, all_names)
  local p = tags_dir .. "/" .. file
  local f = io.open(p, "r")
  if not f then
    return 0
  end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(json_decode, raw)
  local count = 0
  if ok and type(data) == "table" then
    for _, t in ipairs(data) do
      if t.n and type(t.n) == "string" then
        local nl = t.n:lower()
        local item = { n = t.n, c = tonumber(t.c) or 0, t = tonumber(t.t) or 0 }
        map[nl] = item
        count = count + 1
        if seen and not seen[nl] then
          seen[nl] = true
          if all_names then
            table.insert(all_names, t.n)
          end
        end
      end
    end
  end
  return count
end

local function save_split_files(tags_dir, series_map, chars_map, artists_map, general_map)
  local function map_to_list(map)
    local list = {}
    for _, v in pairs(map) do
      table.insert(list, v)
    end
    table.sort(list, function(a, b)
      return (a.c or 0) > (b.c or 0)
    end)
    return list
  end

  local function write_json_file(path, list)
    local ok, enc = pcall(json_encode, list)
    if ok and enc then
      local f = io.open(path, "w")
      if f then
        f:write(enc)
        f:close()
        return true
      end
    end
    return false
  end

  write_json_file(tags_dir .. "/series.json", map_to_list(series_map))
  write_json_file(tags_dir .. "/characters.json", map_to_list(chars_map))
  write_json_file(tags_dir .. "/artists.json", map_to_list(artists_map))
  write_json_file(tags_dir .. "/general.json", map_to_list(general_map))
end

local function absorb_and_prune_discovered(series_map, chars_map, artists_map, general_map, seen, all_names)
  local disc_file = config.get_discovered_tags_file()
  local df = io.open(disc_file, "r")
  if not df then
    return 0
  end
  local raw = df:read("*a")
  df:close()
  local ok, disc_list = pcall(json_decode, raw)
  if not ok or type(disc_list) ~= "table" then
    return 0
  end

  local remaining = {}
  local absorbed = 0
  for _, t in ipairs(disc_list) do
    if t.n and type(t.n) == "string" then
      local count = tonumber(t.c) or 0
      local typ = tonumber(t.t) or 0
      local nl = t.n:lower()
      if catalog.is_clean_tag(t.n, count, typ) then
        local item = { n = t.n, c = count, t = typ }
        local handled = false
        if typ == 3 then
          series_map[nl] = item
          handled = true
        elseif typ == 4 then
          chars_map[nl] = item
          handled = true
        elseif typ == 1 then
          artists_map[nl] = item
          handled = true
        elseif typ == 0 or typ == 5 then
          if count >= 10 then
            general_map[nl] = item
            handled = true
          end
        end
        if handled then
          if seen and not seen[nl] then
            seen[nl] = true
            if all_names then
              table.insert(all_names, t.n)
            end
          end
          absorbed = absorbed + 1
        else
          remaining[#remaining + 1] = t
        end
      else
        remaining[#remaining + 1] = t
      end
    end
  end

  if absorbed > 0 then
    local ok_w, enc = pcall(json_encode, remaining)
    if ok_w and enc then
      local f = io.open(disc_file, "w")
      if f then
        f:write(enc)
        f:close()
      end
    end
    if state and state.State then
      state.State.discovered = remaining
    end
  end
  return absorbed
end

--- Batch Tag Verification (:GelbooruTags verify)
--- Verifies existing tag databases using Gelbooru's multi-tag API (&names=tag1+tag2+...)
--- in batches of 50-100 names per request. Synchronizes counts, reclassifies changed
--- types, and purges dead tags (count == 0 or absent from API response) from memory and disk.
---@param opts table|nil Options: { batch_size = number, concurrency = number, on_complete = function }
function M.verify_tags(opts)
  if M.is_running then
    vim.notify("GelbooruTags: an operation is already in progress", vim.log.levels.WARN)
    return
  end
  M.is_running = true

  local tags_dir = config.options.tags_dir
  util.ensure(tags_dir)

  local series_map, chars_map, artists_map, general_map = {}, {}, {}, {}
  local disc_map = {}
  local all_names = {}
  local seen = {}

  preload_db(tags_dir, "series.json", series_map, seen, all_names)
  preload_db(tags_dir, "characters.json", chars_map, seen, all_names)
  preload_db(tags_dir, "artists.json", artists_map, seen, all_names)
  preload_db(tags_dir, "general.json", general_map, seen, all_names)

  -- Also load discovered tags for verification
  local disc_file = config.get_discovered_tags_file()
  local df = io.open(disc_file, "r")
  if df then
    local raw = df:read("*a")
    df:close()
    local ok, disc_list = pcall(json_decode, raw)
    if ok and type(disc_list) == "table" then
      for _, t in ipairs(disc_list) do
        if t.n and type(t.n) == "string" then
          local nl = t.n:lower()
          disc_map[nl] = { n = t.n, c = tonumber(t.c) or 0, t = tonumber(t.t) or 0 }
          if not seen[nl] then
            seen[nl] = true
            table.insert(all_names, t.n)
          end
        end
      end
    end
  end

  if #all_names == 0 then
    M.is_running = false
    vim.notify("GelbooruTags: no tags found in database to verify", vim.log.levels.WARN)
    if opts and opts.on_complete then
      opts.on_complete({ total = 0, updated = 0, reclassified = 0, purged = 0 })
    end
    return
  end

  local BATCH_SIZE = (opts and opts.batch_size) or 60
  local CONCURRENCY = (opts and opts.concurrency) or 6
  local spinner = create_progress_spinner("GelbooruTags: verify")

  local batches = {}
  for i = 1, #all_names, BATCH_SIZE do
    local batch = {}
    for j = i, math.min(i + BATCH_SIZE - 1, #all_names) do
      table.insert(batch, all_names[j])
    end
    table.insert(batches, batch)
  end

  local total_batches = #batches
  local batches_completed = 0
  local next_batch_idx = 1
  local active_workers = 0
  local is_finished = false

  local purged_set = {}
  local updated_items = {}
  local total_verified = 0
  local total_purged = 0

  local function finish_verification()
    if is_finished then
      return
    end
    is_finished = true

    -- 1. Apply updates and reclassifications across category maps
    local total_updated = 0
    local total_reclassified = 0

    for nl, _ in pairs(purged_set) do
      series_map[nl] = nil
      chars_map[nl] = nil
      artists_map[nl] = nil
      general_map[nl] = nil
      disc_map[nl] = nil
    end

    for nl, item in pairs(updated_items) do
      if not purged_set[nl] then
        local was_cat = nil
        local old_count = nil
        if series_map[nl] then
          was_cat = "series"; old_count = series_map[nl].c
        elseif chars_map[nl] then
          was_cat = "chars"; old_count = chars_map[nl].c
        elseif artists_map[nl] then
          was_cat = "artists"; old_count = artists_map[nl].c
        elseif general_map[nl] then
          was_cat = "general"; old_count = general_map[nl].c
        elseif disc_map[nl] then
          was_cat = "disc"; old_count = disc_map[nl].c
        end

        if old_count and old_count ~= item.c then
          total_updated = total_updated + 1
        end

        local new_cat = nil
        if item.t == 3 then
          new_cat = "series"
        elseif item.t == 4 then
          new_cat = "chars"
        elseif item.t == 1 then
          new_cat = "artists"
        elseif item.t == 0 or item.t == 5 then
          if item.c >= 10 then
            new_cat = "general"
          end
        end

        if was_cat and new_cat and was_cat ~= new_cat then
          total_reclassified = total_reclassified + 1
        end

        -- Remove from old map if category changed
        if was_cat and was_cat ~= new_cat then
          if was_cat == "series" then series_map[nl] = nil
          elseif was_cat == "chars" then chars_map[nl] = nil
          elseif was_cat == "artists" then artists_map[nl] = nil
          elseif was_cat == "general" then general_map[nl] = nil
          elseif was_cat == "disc" then disc_map[nl] = nil
          end
        end

        -- Place into new map
        if new_cat == "series" then series_map[nl] = item
        elseif new_cat == "chars" then chars_map[nl] = item
        elseif new_cat == "artists" then artists_map[nl] = item
        elseif new_cat == "general" then general_map[nl] = item
        elseif was_cat == "disc" then disc_map[nl] = item
        end
      end
    end

    -- 2. Save split category files to disk
    save_split_files(tags_dir, series_map, chars_map, artists_map, general_map)

    -- 3. Update discovered.json on disk
    local disc_list = {}
    for _, item in pairs(disc_map) do
      table.insert(disc_list, item)
    end
    local ok_disc, enc_disc = pcall(json_encode, disc_list)
    if ok_disc and enc_disc then
      local f = io.open(disc_file, "w")
      if f then
        f:write(enc_disc)
        f:close()
      end
    end

    -- 4. Synchronize in-memory structures
    for nl, _ in pairs(purged_set) do
      catalog.prune_tag(nl, { immediate_disk = false })
    end
    for _, item in pairs(updated_items) do
      if not purged_set[item.n:lower()] then
        catalog.update_tag_in_index(item)
      end
    end
    if state and state.State then
      state.State.discovered = disc_list
    end

    spinner.close()
    M.is_running = false

    local msg = string.format(
      "GelbooruTags: ✓ verified %d tags — %d updated, %d reclassified, %d purged",
      #all_names,
      total_updated,
      total_reclassified,
      total_purged
    )
    vim.notify(msg, vim.log.levels.INFO)

    if opts and opts.on_complete then
      opts.on_complete({
        total = #all_names,
        updated = total_updated,
        reclassified = total_reclassified,
        purged = total_purged,
      })
    end
  end

  local function worker(batch_idx, retries)
    if is_finished then
      return
    end
    active_workers = active_workers + 1
    retries = retries or 0

    local batch = batches[batch_idx]
    if not batch then
      active_workers = active_workers - 1
      if active_workers == 0 then
        finish_verification()
      end
      return
    end

    local encoded_chunks = {}
    local batch_map = {}
    for _, name in ipairs(batch) do
      table.insert(encoded_chunks, util.url_encode(name))
      batch_map[name:lower()] = true
    end

    local url = string.format("%s&names=%s%s", config.options.tags_api, table.concat(encoded_chunks, "+"), util.auth_qs())

    local function retry_batch(reason)
      if retries < 3 then
        local delay = (2 ^ retries) * 1000
        spinner.update(string.format("retry %d/3 for batch %d…", retries + 1, batch_idx))
        defer(delay, function()
          active_workers = active_workers - 1
          worker(batch_idx, retries + 1)
        end)
      else
        batches_completed = batches_completed + 1
        active_workers = active_workers - 1
        if active_workers == 0 and next_batch_idx > total_batches then
          finish_verification()
        else
          local nxt = next_batch_idx
          next_batch_idx = next_batch_idx + 1
          if nxt <= total_batches then
            worker(nxt, 0)
          end
        end
      end
    end

    download.curl_async(url, function(body)
      if state.State.torn_down then
        spinner.close()
        M.is_running = false
        return
      end

      if not body then
        retry_batch("empty network response")
        return
      end

      local ok, data = pcall(json_decode, body)
      local is_decode_err = (not ok) or (type(data) ~= "table")
      local body_lower = type(body) == "string" and body:lower() or ""
      local has_html_or_err = body_lower:find("<html", 1, true) ~= nil or body_lower:find("error", 1, true) ~= nil

      local tag_list = (not is_decode_err and data and data.tag) and util.ensure_array(data.tag) or nil

      if is_decode_err or has_html_or_err or (data and data.error) then
        if not (tag_list and #tag_list > 0) then
          retry_batch("rate-limit/Cloudflare response")
          return
        end
      end

      local returned_set = {}
      if tag_list and #tag_list > 0 then
        for _, t in ipairs(tag_list) do
          if t.name then
            local nl = t.name:lower()
            returned_set[nl] = true
            local count = tonumber(t.count) or 0
            local typ = tonumber(t.type) or 0

            if count <= 0 or not catalog.is_clean_tag(t.name, count, typ) then
              purged_set[nl] = true
              total_purged = total_purged + 1
            else
              total_verified = total_verified + 1
              updated_items[nl] = { n = t.name, c = count, t = typ }
            end
          end
        end
      end

      -- Purge dead tags: any tag in the batch absent from API response
      for _, name in ipairs(batch) do
        local nl = name:lower()
        if not returned_set[nl] and not purged_set[nl] then
          purged_set[nl] = true
          total_purged = total_purged + 1
        end
      end

      batches_completed = batches_completed + 1
      local verified_so_far = math.min(batches_completed * BATCH_SIZE, #all_names)
      if batches_completed % 2 == 0 or batches_completed == total_batches then
        spinner.update(string.format("%d/%d tags verified (%d dead)…", verified_so_far, #all_names, total_purged))
      end

      active_workers = active_workers - 1
      if not is_finished then
        local nxt = next_batch_idx
        next_batch_idx = next_batch_idx + 1
        if nxt <= total_batches then
          worker(nxt, 0)
        elseif active_workers == 0 then
          finish_verification()
        end
      end
    end)
  end

  local spawn_count = math.min(CONCURRENCY, total_batches)
  for _ = 1, spawn_count do
    local b_idx = next_batch_idx
    next_batch_idx = next_batch_idx + 1
    worker(b_idx, 0)
  end
end

--- Top-Down Count Refresh (:GelbooruTags refresh)
--- Scrapes from page 0 downward to update the top 50,000 most popular tags in-place.
--- Updates existing tags with their new count/type in-place and reclassifies them if type changed.
---@param opts table|nil Options: { max_tags = number, concurrency = number, on_complete = function }
function M.refresh_tags(opts)
  if M.is_running then
    vim.notify("GelbooruTags: an operation is already in progress", vim.log.levels.WARN)
    return
  end
  M.is_running = true

  local tags_dir = config.options.tags_dir
  util.ensure(tags_dir)

  local series_map, chars_map, artists_map, general_map = {}, {}, {}, {}
  local seen = {}

  preload_db(tags_dir, "series.json", series_map, seen)
  preload_db(tags_dir, "characters.json", chars_map, seen)
  preload_db(tags_dir, "artists.json", artists_map, seen)
  preload_db(tags_dir, "general.json", general_map, seen)
  absorb_and_prune_discovered(series_map, chars_map, artists_map, general_map, seen)

  local LIMIT = 100
  local MAX_TAGS = (opts and opts.max_tags) or 50000
  local MAX_PAGES = math.ceil(MAX_TAGS / LIMIT)
  local CONCURRENCY = (opts and opts.concurrency) or 6
  local spinner = create_progress_spinner("GelbooruTags: refresh")

  local next_pid = 0
  local active_workers = 0
  local is_finished = false
  local pages_fetched = 0
  local total_refreshed = 0
  local total_updated = 0
  local total_reclassified = 0
  local total_new = 0

  local function finish_refresh()
    if is_finished then
      return
    end
    is_finished = true

    save_split_files(tags_dir, series_map, chars_map, artists_map, general_map)

    spinner.close()
    M.is_running = false

    local msg = string.format(
      "GelbooruTags: ✓ refreshed %d tags (%d updated, %d reclassified, %d new)",
      total_refreshed,
      total_updated,
      total_reclassified,
      total_new
    )
    vim.notify(msg, vim.log.levels.INFO)

    if opts and opts.on_complete then
      opts.on_complete({
        total = total_refreshed,
        updated = total_updated,
        reclassified = total_reclassified,
        new_tags = total_new,
      })
    end
  end

  local function worker(pid, retries)
    if is_finished and retries == 0 then
      return
    end
    active_workers = active_workers + 1
    retries = retries or 0

    local function retry_page(reason)
      if retries < 3 then
        local delay = (2 ^ retries) * 1000
        spinner.update(string.format("retry %d/3 for page %d…", retries + 1, pid))
        defer(delay, function()
          active_workers = active_workers - 1
          worker(pid, retries + 1)
        end)
      else
        active_workers = active_workers - 1
        if active_workers == 0 then
          finish_refresh()
        end
      end
    end

    local url = string.format("%s&limit=%d&pid=%d&orderby=count%s", config.options.tags_api, LIMIT, pid, util.auth_qs())
    download.curl_async(url, function(body)
      if state.State.torn_down then
        spinner.close()
        M.is_running = false
        return
      end

      if not body then
        retry_page("empty network response")
        return
      end

      local ok, data = pcall(json_decode, body)
      local is_decode_err = (not ok) or (type(data) ~= "table")
      local body_lower = type(body) == "string" and body:lower() or ""
      local has_html_or_err = body_lower:find("<html", 1, true) ~= nil or body_lower:find("error", 1, true) ~= nil

      local tag_list = (not is_decode_err and data and data.tag) and util.ensure_array(data.tag) or nil

      if is_decode_err or has_html_or_err or (data and data.error) then
        if not (tag_list and #tag_list > 0) then
          retry_page("rate-limit/Cloudflare response")
          return
        end
      end

      if tag_list and #tag_list > 0 then
        for _, t in ipairs(tag_list) do
          local name = t.name
          local count = tonumber(t.count) or 0
          local typ = tonumber(t.type) or 0

          if name and catalog.is_clean_tag(name, count, typ) and count >= 1 then
            local nl = name:lower()
            total_refreshed = total_refreshed + 1

            local was_cat = nil
            local existing_item = nil
            if series_map[nl] then
              was_cat = "series"; existing_item = series_map[nl]
            elseif chars_map[nl] then
              was_cat = "chars"; existing_item = chars_map[nl]
            elseif artists_map[nl] then
              was_cat = "artists"; existing_item = artists_map[nl]
            elseif general_map[nl] then
              was_cat = "general"; existing_item = general_map[nl]
            end

            local new_item = { n = name, c = count, t = typ }

            if existing_item then
              if existing_item.c ~= count then
                total_updated = total_updated + 1
              end
              existing_item.c = count

              local new_cat = nil
              if typ == 3 then
                new_cat = "series"
              elseif typ == 4 then
                new_cat = "chars"
              elseif typ == 1 then
                new_cat = "artists"
              elseif typ == 0 or typ == 5 then
                if count >= 10 then
                  new_cat = "general"
                end
              end

              if was_cat ~= new_cat then
                total_reclassified = total_reclassified + 1
                if was_cat == "series" then series_map[nl] = nil
                elseif was_cat == "chars" then chars_map[nl] = nil
                elseif was_cat == "artists" then artists_map[nl] = nil
                elseif was_cat == "general" then general_map[nl] = nil
                end

                if new_cat == "series" then series_map[nl] = new_item
                elseif new_cat == "chars" then chars_map[nl] = new_item
                elseif new_cat == "artists" then artists_map[nl] = new_item
                elseif new_cat == "general" then general_map[nl] = new_item
                end
              end
            else
              total_new = total_new + 1
              if typ == 3 then
                series_map[nl] = new_item
              elseif typ == 4 then
                chars_map[nl] = new_item
              elseif typ == 1 then
                artists_map[nl] = new_item
              elseif typ == 0 or typ == 5 then
                if count >= 10 then
                  general_map[nl] = new_item
                end
              end
            end

            -- Update in-memory tag index if loaded
            catalog.update_tag_in_index(new_item)
          end
        end

        pages_fetched = pages_fetched + 1
        if pages_fetched % 5 == 0 then
          spinner.update(string.format("%d/%d tags refreshed…", total_refreshed, MAX_TAGS))
        end

        if pages_fetched % 50 == 0 then
          save_split_files(tags_dir, series_map, chars_map, artists_map, general_map)
        end

        active_workers = active_workers - 1
        if not is_finished then
          if next_pid < MAX_PAGES and total_refreshed < MAX_TAGS then
            local next_up = next_pid
            next_pid = next_pid + 1
            worker(next_up, 0)
          elseif active_workers == 0 then
            finish_refresh()
          end
        end
      else
        is_finished = true
        active_workers = active_workers - 1
        if active_workers == 0 then
          finish_refresh()
        end
      end
    end)
  end

  local spawn_count = math.min(CONCURRENCY, MAX_PAGES)
  for _ = 1, spawn_count do
    local start_pid = next_pid
    next_pid = next_pid + 1
    worker(start_pid, 0)
  end
end

--- Top-level scraper / updater facade.
--- Dispatches to verify_tags, refresh_tags, or standard scraper based on mode.
---@param mode string|table|nil "verify" | "refresh" | table opts | nil
---@param opts table|nil
function M.update_tags(mode, opts)
  if M.is_running then
    vim.notify("GelbooruTags: an operation is already in progress", vim.log.levels.WARN)
    return
  end

  if type(mode) == "table" and opts == nil then
    opts = mode
    mode = opts.mode
  end

  if mode == "verify" then
    return M.verify_tags(opts)
  elseif mode == "refresh" then
    return M.refresh_tags(opts)
  end

  M.is_running = true

  local series_map, chars_map, artists_map, general_map = {}, {}, {}, {}
  local LIMIT = constants.TAG_SCRAPER_LIMIT
  local CONCURRENCY = (opts and opts.concurrency) or constants.TAG_SCRAPER_CONCURRENCY
  local seen = {}
  local total_fetched = 0

  local tags_dir = config.options.tags_dir
  util.ensure(tags_dir)

  local spinner = create_progress_spinner("GelbooruTags")

  total_fetched = total_fetched + preload_db(tags_dir, "series.json", series_map, seen)
  total_fetched = total_fetched + preload_db(tags_dir, "characters.json", chars_map, seen)
  total_fetched = total_fetched + preload_db(tags_dir, "artists.json", artists_map, seen)
  total_fetched = total_fetched + preload_db(tags_dir, "general.json", general_map, seen)
  total_fetched = total_fetched + absorb_and_prune_discovered(series_map, chars_map, artists_map, general_map, seen)

  local next_pid = math.floor(total_fetched / LIMIT)
  local active_workers = 0
  local is_finished = false
  local pages_fetched = 0

  local function finish_scrape(reason)
    if is_finished then
      return
    end
    is_finished = true

    save_split_files(tags_dir, series_map, chars_map, artists_map, general_map)
    spinner.close()
    M.is_running = false

    if reason then
      vim.notify(
        string.format("GelbooruTags: stopped (%s) — saved %d tags", reason, total_fetched),
        vim.log.levels.WARN
      )
    else
      vim.notify(
        string.format("GelbooruTags: ✓ cached %d clean tags across databases", total_fetched),
        vim.log.levels.INFO
      )
    end

    if opts and opts.on_complete then
      opts.on_complete({ total = total_fetched })
    end
  end

  local function worker(pid, retries)
    if is_finished and retries == 0 then
      return
    end
    active_workers = active_workers + 1
    retries = retries or 0

    local function retry_page(reason)
      if retries < constants.TAG_SCRAPER_MAX_RETRIES then
        local delay = (2 ^ retries) * constants.TAG_SCRAPER_BACKOFF_BASE_MS
        spinner.update(string.format("retry %d/%d for page %d…", retries + 1, constants.TAG_SCRAPER_MAX_RETRIES, pid))
        defer(delay, function()
          active_workers = active_workers - 1
          worker(pid, retries + 1)
        end)
      else
        active_workers = active_workers - 1
        if active_workers == 0 then
          finish_scrape(reason)
        end
      end
    end

    local url = string.format("%s&limit=%d&pid=%d&orderby=count%s", config.options.tags_api, LIMIT, pid, util.auth_qs())
    download.curl_async(url, function(body)
      if state.State.torn_down then
        spinner.close()
        M.is_running = false
        return
      end

      if not body then
        retry_page("empty network response")
        return
      end

      local ok, data = pcall(json_decode, body)
      local is_decode_err = (not ok) or (type(data) ~= "table")
      local body_lower = type(body) == "string" and body:lower() or ""
      local has_html_or_err = body_lower:find("<html", 1, true) ~= nil or body_lower:find("error", 1, true) ~= nil

      local tag_list = (not is_decode_err and data and data.tag) and util.ensure_array(data.tag) or nil

      -- Check if response is Cloudflare HTML, 429 error, or malformed JSON
      if is_decode_err or has_html_or_err or (data and data.error) then
        if not (tag_list and #tag_list > 0) then
          retry_page("error/rate-limit response")
          return
        end
      end

      if tag_list and #tag_list > 0 then
        for _, t in ipairs(tag_list) do
          local name = t.name
          local count = tonumber(t.count) or 0
          local typ = tonumber(t.type) or 0
          if name and catalog.is_clean_tag(name, count, typ) and not seen[name] then
            seen[name] = true
            total_fetched = total_fetched + 1
            local item = { n = name, c = count, t = typ }
            if typ == 3 then
              series_map[name:lower()] = item
            elseif typ == 4 then
              chars_map[name:lower()] = item
            elseif typ == 1 then
              artists_map[name:lower()] = item
            elseif typ == 0 or typ == 5 then
              if count >= constants.TAG_GENERAL_MIN_COUNT then
                general_map[name:lower()] = item
              end
            end
          end
        end

        pages_fetched = pages_fetched + 1
        if pages_fetched % constants.TAG_SCRAPER_PROGRESS_STEP == 0 then
          spinner.update(string.format("%d tags fetched...", total_fetched))
        end

        if pages_fetched % constants.TAG_SCRAPER_CHECKPOINT_STEP == 0 then
          save_split_files(tags_dir, series_map, chars_map, artists_map, general_map)
        end

        active_workers = active_workers - 1
        if not is_finished then
          local next_up = next_pid
          next_pid = next_pid + 1
          worker(next_up, 0)
        end
      else
        active_workers = active_workers - 1
        if active_workers == 0 then
          finish_scrape(nil)
        end
      end
    end)
  end

  for _ = 1, CONCURRENCY do
    local start_pid = next_pid
    next_pid = next_pid + 1
    worker(start_pid, 0)
  end
end

return M
