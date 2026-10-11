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

local SESSION_CACHE_TTL = 300 -- 5 minutes in-session TTL

local function get_session_cache(key)
  local sc = state.State.session_cache
  if not sc or not sc[key] then
    return nil
  end
  local entry = sc[key]
  if os.time() > entry.expires_at then
    sc[key] = nil
    return nil
  end
  return entry.data
end

local function set_session_cache(key, data)
  if not state.State.session_cache then
    state.State.session_cache = {}
  end
  state.State.session_cache[key] = {
    data = data,
    expires_at = os.time() + SESSION_CACHE_TTL,
  }
end

local M = {}

function M.clear_session_cache()
  state.State.session_cache = {}
end

--- Normalizes query modifiers for Gelbooru API compatibility.
--- Gelbooru DAPI accepts ~ strictly on tags (~hatsune_miku ~megurine_luka),
--- but rejects ~rating:..., ~score:..., or ~id:..., returning 0 results.
--- Normalizes raw query tokens for remote Gelbooru API querying.
--- Gelbooru's dapi does not support native `~` syntax on tags or ratings.
--- This parses query tokens and returns a list of executable remote query branch strings:
--- 1. ~sort: and ~order: have `~` stripped.
--- 2. Ratings:
---    - Single rating (e.g. `~rating:questionable` or `rating:q`): returns `rating:questionable`
---    - Multiple OR ratings (e.g. `~rating:explicit ~rating:questionable`, `rating:q,e`, `rating:q|e`):
---      Gelbooru does not have positive rating OR, but supports `-rating:tag`.
---      Translates to negative exclusions of the unselected ratings (e.g. `-rating:general -rating:sensitive`),
---      which Gelbooru executes natively in a single API call!
--- 3. Modifiers: ~score: and ~id: have `~` stripped.
--- 4. Tags with `~`:
---    - Single `~tag`: "1 out of 1 is just 1", strips `~` so Gelbooru finds the tag.
---    - Multiple `~tag`: returns branches (one for each OR tag) to be queried concurrently and merged.
---@param tags_str string|nil
---@return string[] branches
function M.normalize_remote_query(tags_str)
  if not tags_str or tags_str == "" then
    return { "" }
  end

  local tokens = {}
  for tok in tags_str:gmatch("%S+") do
    table.insert(tokens, tok)
  end

  local sort_order_tokens = {}
  local positive_ratings = {}
  local negative_ratings = {}
  local or_tags = {}
  local base_tokens = {}

  local all_canonical_ratings = { "general", "sensitive", "questionable", "explicit" }
  local rating_map = {
    g = "general", general = "general",
    s = "sensitive", sensitive = "sensitive",
    q = "questionable", questionable = "questionable",
    e = "explicit", explicit = "explicit",
  }

  for _, tok in ipairs(tokens) do
    if tok:match("^~?[Ss][Oo][Rr][Tt]:") then
      table.insert(sort_order_tokens, (tok:gsub("^~", "")))
    elseif tok:match("^~?[Oo][Rr][Dd][Ee][Rr]:") then
      table.insert(sort_order_tokens, (tok:gsub("^~", "")))
    elseif tok:match("^%-[Rr][Aa][Tt][Ii][Nn][Gg]:(.+)$") then
      local val = tok:match("^%-[Rr][Aa][Tt][Ii][Nn][Gg]:(.+)$")
      for r in val:gmatch("[^,|]+") do
        local canon = rating_map[r:lower()]
        if canon then table.insert(negative_ratings, canon) end
      end
    elseif tok:match("^~?[Rr][Aa][Tt][Ii][Nn][Gg]:(.+)$") then
      local val = tok:match("^~?[Rr][Aa][Tt][Ii][Nn][Gg]:(.+)$")
      for r in val:gmatch("[^,|]+") do
        local canon = rating_map[r:lower()]
        if canon then table.insert(positive_ratings, canon) end
      end
    elseif tok:match("^~score:") then
      table.insert(base_tokens, (tok:gsub("^~", "")))
    elseif tok:match("^~id:") then
      table.insert(base_tokens, (tok:gsub("^~", "")))
    elseif tok:sub(1, 1) == "~" and #tok > 1 then
      table.insert(or_tags, tok:sub(2))
    else
      table.insert(base_tokens, tok)
    end
  end

  -- Deduplicate ratings
  local function dedup(list)
    local s = {}
    local res = {}
    for _, v in ipairs(list) do
      if not s[v] then
        s[v] = true
        table.insert(res, v)
      end
    end
    return res
  end
  positive_ratings = dedup(positive_ratings)
  negative_ratings = dedup(negative_ratings)

  local rating_clause = {}
  if #positive_ratings > 0 then
    if #positive_ratings == 1 then
      table.insert(rating_clause, "rating:" .. positive_ratings[1])
    elseif #positive_ratings < 4 then
      local sel = {}
      for _, r in ipairs(positive_ratings) do sel[r] = true end
      for _, r in ipairs(all_canonical_ratings) do
        if not sel[r] then
          table.insert(rating_clause, "-rating:" .. r)
        end
      end
    end
  end
  for _, r in ipairs(negative_ratings) do
    table.insert(rating_clause, "-rating:" .. r)
  end

  local common_parts = {}
  for _, t in ipairs(base_tokens) do table.insert(common_parts, t) end
  for _, r in ipairs(rating_clause) do table.insert(common_parts, r) end
  for _, s in ipairs(sort_order_tokens) do table.insert(common_parts, s) end
  local common_str = table.concat(common_parts, " ")

  if #or_tags == 0 then
    return { common_str }
  elseif #or_tags == 1 then
    local res = common_str == "" and or_tags[1] or (common_str .. " " .. or_tags[1])
    return { res }
  else
    local branches = {}
    for _, ot in ipairs(or_tags) do
      local b = common_str == "" and ot or (common_str .. " " .. ot)
      table.insert(branches, b)
    end
    return branches
  end
end

---@param tags_str string|nil
---@return string
function M.normalize_remote_tags(tags_str)
  local branches = M.normalize_remote_query(tags_str)
  return branches[1] or ""
end

function M.fetch(direction, is_explicit)
  direction = direction or 1
  local State = state.State
  local UI = state.UI
  local ui = require("gelbooru.ui")

  if not State.query or util.is_local_query(State.query) then
    return
  end

  local query_mod = require("gelbooru.query")
  local pipe = query_mod.parse_pipeline(State.query)
  if pipe and pipe.stages and #pipe.stages > 0 then
    if is_explicit ~= false then
      ui.set_status("Pagination not supported on piped searches", 2000)
    end
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
  local nonce_param = ""
  if State.query then
    local q_lower = State.query:lower()
    if q_lower:find("sort:random", 1, true) or q_lower:find("order:random", 1, true) then
      local uv = vim.uv or vim.loop
      local nonce = string.format("%d_%d", os.time(), (uv and uv.hrtime() or math.random(100000, 999999)) % 1000000)
      nonce_param = "&_nonce=" .. nonce
    end
  end
  local branches = M.normalize_remote_query(State.query or "")
  local remote_tags = branches[1] or ""
  local cache_key = (nonce_param == "")
      and string.format("page:%s:pid=%d:limit=%d", table.concat(branches, "||"), State.page, config.options.per_page)
    or nil
  if cache_key then
    local cached_posts = get_session_cache(cache_key)
    if cached_posts and #cached_posts > 0 then
      for _, p in ipairs(cached_posts) do
        table.insert(State.posts, p)
      end
      State.page = State.page + 1
      State.loading = false
      history.save_current_history()
      ui.set_status()
      ui.render_list()
      if State.cur == 1 then
        ui.render_preview(false)
      end
      return
    end
  end

  local epoch = State.search_epoch

  if #branches <= 1 then
    local url = string.format(
      "%s&tags=%s&limit=%d&pid=%d%s%s",
      config.options.api_base,
      util.url_encode(remote_tags),
      config.options.per_page,
      State.page,
      util.auth_qs(),
      nonce_param
    )
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
      if cache_key and #posts > 0 then
        set_session_cache(cache_key, posts)
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
  else
    -- Multi-branch parallel querying for OR tags (e.g. ~foot_focus ~soles)
    local all_posts = {}
    local completed = 0
    local any_network_success = false

    for _, branch_tag in ipairs(branches) do
      local branch_url = string.format(
        "%s&tags=%s&limit=%d&pid=%d%s%s",
        config.options.api_base,
        util.url_encode(branch_tag),
        config.options.per_page,
        State.page,
        util.auth_qs(),
        nonce_param
      )
      download.curl_async(branch_url, function(body)
        if State.search_epoch ~= epoch or State.torn_down then
          return
        end
        completed = completed + 1
        if body then
          any_network_success = true
          local ok, data = pcall(vim.json and vim.json.decode or vim.fn.json_decode, body)
          if ok and data and data.post then
            local p_list = ensure_array(data.post)
            for _, p in ipairs(p_list) do
              table.insert(all_posts, p)
            end
          end
        end

        if completed == #branches then
          State.loading = false
          if not any_network_success then
            ui.set_status("Error: API request failed")
            ui.render_list()
            util.set_lines(UI.bufs.img, { "  Error: API request failed" })
            util.set_lines(UI.bufs.meta, {})
            return
          end

          if #all_posts == 0 then
            ui.set_status("No results" .. (State.query ~= "" and (" for: " .. State.query) or ""))
            ui.render_list()
            history.save_current_history()
            util.set_lines(UI.bufs.img, { "  No posts found" })
            util.set_lines(UI.bufs.meta, {})
            return
          end

          local seen_ids = {}
          local deduped = {}
          for _, p in ipairs(all_posts) do
            local pid = tostring(p.id or p.file_url or "")
            if pid ~= "" and not seen_ids[pid] then
              seen_ids[pid] = true
              table.insert(deduped, p)
            end
          end

          table.sort(deduped, function(a, b)
            local ida = tonumber(a.id) or 0
            local idb = tonumber(b.id) or 0
            return ida > idb
          end)

          if cache_key and #deduped > 0 then
            set_session_cache(cache_key, deduped)
          end
          for _, p in ipairs(deduped) do
            table.insert(State.posts, p)
          end
          State.page = State.page + 1
          history.save_current_history()
          ui.set_status()
          ui.render_list()
          if State.cur == 1 then
            ui.render_preview(false)
          end
        end
      end)
    end
  end
end

local function clear_preview_loading()
  if state.State.torn_down then
    return
  end
  pcall(function()
    require("gelbooru.ui.image").reset_canvas("  Loading...")
  end)
end

function M.execute_search(query, opts)
  local State = state.State
  local ui = require("gelbooru.ui")

  if State.torn_down then
    return
  end

  if query and util.is_local_query(query) then
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
  local is_random = false
  if type(query) == "string" then
    local q_lower = query:lower()
    if q_lower:find("sort:random", 1, true) or q_lower:find("order:random", 1, true) then
      is_random = true
    else
      for token in q_lower:gmatch("%S+") do
        if token == "random" or token == "|random" or token == "random|" then
          is_random = true
          break
        end
      end
      if not is_random then
        local query_mod = require("gelbooru.query")
        local p = query_mod.parse_pipeline(query)
        if p and p.stages then
          for _, st in ipairs(p.stages) do
            if st.key == "random" then
              is_random = true
              break
            end
          end
        end
      end
    end
  end
  if not is_random and query == State.query and #State.posts > 0 then
    ui.render_list()
    return
  end

  download.cancel_prefetch_timers(true)
  pcall(function()
    require("gelbooru.local.indexer").stop()
  end)

  clear_preview_loading()

  State.search_epoch = (State.search_epoch or 0) + 1
  State.loading = false  -- Must reset so in-flight fetch doesn't lock out new search!
  if not (opts and opts.skip_history) and not State.restoring_history then
    history.push_history(query)
  end
  State.query = query
  State.posts = {}
  State.page = 0
  State.cur = 1
  State.cur_id = nil
  ui.render_list()

  local query_mod = require("gelbooru.query")
  local pipe = query_mod.parse_pipeline(query)

  if pipe and #pipe.stages > 0 then
    M.execute_piped_search(query, pipe)
  else
    M.fetch(1)
  end

  -- Auto-resolve any unknown query tags so they are saved to discovered.json
  local tags_to_resolve = (pipe and pipe.base_query) or query or ""
  for word in tags_to_resolve:gmatch("%S+") do
    local clean_word = word:gsub("^[-~]", ""):lower()
    if clean_word ~= "" and clean_word ~= "|" and not clean_word:find(":") and not State.tags_by_name[clean_word] then
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

function M.execute_piped_search(query, pipe)
  local State = state.State
  local ui = require("gelbooru.ui")
  local query_mod = require("gelbooru.query")

  local epoch = State.search_epoch
  local stages = pipe.stages
  local stage1 = stages[1]
  local base_query = pipe.base_query or ""

  local page_size = 100
  local pid = 0
  local start_pid = 0
  if stage1 and stage1.offset and stage1.offset > 0 then
    start_pid = math.floor(stage1.offset / page_size)
    pid = start_pid
  end

  -- Determine candidate pool target size:
  -- If stage1 has a range/offset (e.g. sort:id:1000..1200 or offset:1000), fetch needed window.
  -- If stage1 has a limit (e.g. sort:id:1000), pool_target = math.min(stage1.limit, 2000).
  -- If stage1 has an open-ended range/offset (e.g. sort:id:50..), pool_target = math.min(stage1.offset + config.options.per_page, 2000).
  -- If stage1 has no limit, but any downstream stage has a limit (e.g. tag | sort:score:200 | sort:random),
  -- ensure pool_target = math.min(2000, math.max(max_stage_limit, config.options.per_page)).
  local pool_target
  if stage1 and stage1.offset and not stage1.limit then
    local base_offset = start_pid * page_size
    local rel_start = stage1.offset - base_offset
    local needed = rel_start + config.options.per_page
    pool_target = math.min(needed, 2000)
  elseif stage1 and stage1.offset and stage1.offset > 0 then
    local base_offset = start_pid * page_size
    local rel_start = stage1.offset - base_offset
    local count = (stage1.limit and stage1.limit > stage1.offset) and (stage1.limit - stage1.offset) or config.options.per_page
    local needed = rel_start + count
    pool_target = math.min(needed, 2000)
  elseif stage1 and stage1.limit and stage1.limit > 0 then
    pool_target = math.min(stage1.limit, 2000)
  else
    local max_stage_limit = 0
    for _, st in ipairs(stages) do
      if st.limit and st.limit > max_stage_limit then
        max_stage_limit = st.limit
      end
    end
    if max_stage_limit > 0 then
      pool_target = math.min(2000, math.max(max_stage_limit, config.options.per_page))
    else
      pool_target = config.options.per_page
    end
  end

  -- If Stage 1 has a remote sort key (sort:id, sort:score, sort:random),
  -- pass it in the remote tags parameter so Gelbooru server orders the initial stream.
  local remote_tags = base_query
  if stage1 and stage1.key then
    local k = stage1.key:lower()
    local remote_sort = nil
    if k == "id" or k == "score" then
      local dir_str = (stage1.dir and stage1.dir:lower() == "asc") and ":asc" or ":desc"
      remote_sort = string.format("sort:%s%s", k, dir_str)
    elseif k == "random" then
      remote_sort = "sort:random"
    end
    if remote_sort then
      if remote_tags ~= "" then
        remote_tags = remote_tags .. " " .. remote_sort
      else
        remote_tags = remote_sort
      end
    end
  end
  remote_tags = M.normalize_remote_tags(remote_tags)

  local nonce_param = ""
  if remote_tags:lower():find("sort:random", 1, true) or remote_tags:lower():find("order:random", 1, true) then
    local uv = vim.uv or vim.loop
    local nonce = string.format("%d_%d", os.time(), (uv and uv.hrtime() or math.random(100000, 999999)) % 1000000)
    nonce_param = "&_nonce=" .. nonce
  end

  State.loading = true
  local candidate_pool = {}

  local function finish_pipeline()
    if State.search_epoch ~= epoch or State.torn_down then
      return
    end
    State.loading = false

    if #candidate_pool == 0 then
      ui.set_status("No results" .. (query ~= "" and (" for: " .. query) or ""))
      ui.render_list()
      history.save_current_history()
      util.set_lines(state.UI.bufs.img, { "  No posts found" })
      util.set_lines(state.UI.bufs.meta, {})
      return
    end

    -- Execute subsequent pipeline stages in memory:
    -- If stage1 had an offset, cleanly slice in-memory array to requested window,
    -- then run downstream pipeline stages on the window.
    local final_posts
    if stage1 and stage1.offset and stage1.offset > 0 then
      local base_offset = start_pid * page_size
      local rel_start = math.max(1, (stage1.offset - base_offset) + 1)
      local rel_end
      if stage1.offset and not stage1.limit then
        rel_end = #candidate_pool
      else
        rel_end = (stage1.limit and stage1.limit > 0) and (stage1.limit - base_offset) or #candidate_pool
        rel_end = math.min(#candidate_pool, rel_end)
      end

      local window_posts = {}
      if rel_start <= #candidate_pool then
        for i = rel_start, rel_end do
          table.insert(window_posts, candidate_pool[i])
        end
      end

      if #stages > 1 then
        local downstream_stages = {}
        for s_idx = 2, #stages do
          table.insert(downstream_stages, stages[s_idx])
        end
        final_posts = query_mod.execute_pipeline(window_posts, downstream_stages)
      else
        final_posts = window_posts
      end
    else
      final_posts = query_mod.execute_pipeline(candidate_pool, stages)
    end

    State.posts = final_posts
    State.page = pid + 1
    State.cur = 1
    State.cur_id = nil
    history.save_current_history()
    ui.set_status()
    ui.render_list()
    if #final_posts > 0 then
      ui.render_preview(false)
    else
      util.set_lines(state.UI.bufs.img, { "  No posts found" })
      util.set_lines(state.UI.bufs.meta, {})
    end
  end

  local function fetch_batch()
    if State.search_epoch ~= epoch or State.torn_down then
      return
    end

    local remaining = pool_target - #candidate_pool
    if remaining <= 0 then
      finish_pipeline()
      return
    end

    local limit = math.min(page_size, remaining)
    ui.set_status(string.format("Fetching candidate pool (%d/%d)…", #candidate_pool, pool_target))

    local url = string.format(
      "%s&tags=%s&limit=%d&pid=%d%s%s",
      config.options.api_base,
      util.url_encode(remote_tags),
      limit,
      pid,
      util.auth_qs(),
      nonce_param
    )

    download.curl_async(url, function(body)
      if State.search_epoch ~= epoch then
        return
      end
      if State.torn_down or not (state.UI.wins.frame and vim.api.nvim_win_is_valid(state.UI.wins.frame)) then
        State.loading = false
        return
      end

      if not body then
        if #candidate_pool > 0 then
          finish_pipeline()
        else
          State.loading = false
          ui.set_status("Error: API request failed")
          ui.render_list()
          util.set_lines(state.UI.bufs.img, { "  Error: API request failed" })
          util.set_lines(state.UI.bufs.meta, {})
        end
        return
      end

      local ok, data = pcall(vim.json and vim.json.decode or vim.fn.json_decode, body)
      if not ok or not data or not data.post then
        if #candidate_pool > 0 then
          finish_pipeline()
        else
          State.loading = false
          ui.set_status("No results" .. (query ~= "" and (" for: " .. query) or ""))
          ui.render_list()
          history.save_current_history()
          util.set_lines(state.UI.bufs.img, { "  No posts found" })
          util.set_lines(state.UI.bufs.meta, {})
        end
        return
      end

      local posts = ensure_array(data.post)
      if #posts == 0 then
        if #candidate_pool > 0 then
          finish_pipeline()
        else
          State.loading = false
          ui.set_status("No results" .. (query ~= "" and (" for: " .. query) or ""))
          ui.render_list()
          history.save_current_history()
          util.set_lines(state.UI.bufs.img, { "  No posts found" })
          util.set_lines(state.UI.bufs.meta, {})
        end
        return
      end

      for _, p in ipairs(posts) do
        table.insert(candidate_pool, p)
      end

      if #posts < limit or #candidate_pool >= pool_target then
        finish_pipeline()
      else
        pid = pid + 1
        fetch_batch()
      end
    end)
  end

  fetch_batch()
end

function M.save_current(cb)
  local State = state.State
  local ui = require("gelbooru.ui")
  local p = State.posts[State.cur]
  if not p then
    ui.set_status("No file URL for this post", 2000)
    if cb then cb(false, nil) end
    return
  end

  local del_key = tostring(p.id or (p._local_file_path or ""))
  if p._pending_delete or (State.pending_deletions and State.pending_deletions[del_key]) then
    local pending = State.pending_deletions and State.pending_deletions[del_key]
    local path = (pending and pending.path) or p._local_file_path
    if State.pending_deletions then
      State.pending_deletions[del_key] = nil
    end
    p._pending_delete = nil
    local id_num = p.id and tonumber(p.id)
    local ext = util.file_ext(path or p.file_url or "jpg")
    if ext == "" then ext = "jpg" end
    if id_num then
      local local_index = require("gelbooru.local.index")
      local_index.mark_saved(id_num, ext)
      if State.saved_index then
        State.saved_index[id_num] = ext
      end
    end
    if path and vim.fn.filereadable(path) == 1 then
      p.is_local = true
      p.file_url = path
      ui.render_list()
      ui.set_status("Restored file: " .. vim.fn.fnamemodify(path, ":t"), 2500)
      if cb then cb(true, path) end
      return
    end
  end

  if not p.file_url then
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
  local ext = util.file_ext(p.file_url)
  if ext == "" then
    ext = "jpg"
  end
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
            file_url = p.file_url,
            preview_url = p.preview_url,
            sample_url = p.sample_url,
          }
          util.write_json(meta_path, meta_data)
        end
        local UI = state.UI
        if UI.wins.img and vim.api.nvim_win_is_valid(UI.wins.img) and State.posts[State.cur] == p then
          if image.is_video_post(p) then
            image.extract_video_thumbnail(dest, p.id, function(thumb)
              if thumb and UI.wins.img and vim.api.nvim_win_is_valid(UI.wins.img) and State.posts[State.cur] == p then
                image.render_image(UI.wins.img, thumb)
              end
            end)
          else
            image.render_image(UI.wins.img, dest)
          end
        elseif image.is_video_post(p) then
          image.extract_video_thumbnail(dest, p.id)
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
          file_url = p.file_url,
          preview_url = p.preview_url,
          sample_url = p.sample_url,
        }
        util.write_json(meta_path, meta_data)
      end
      local UI = state.UI
      if UI.wins.img and vim.api.nvim_win_is_valid(UI.wins.img) and State.posts[State.cur] == p then
        if image.is_video_post(p) then
          image.extract_video_thumbnail(dest, p.id, function(thumb)
            if thumb and UI.wins.img and vim.api.nvim_win_is_valid(UI.wins.img) and State.posts[State.cur] == p then
              image.render_image(UI.wins.img, thumb)
            end
          end)
        else
          image.render_image(UI.wins.img, dest)
        end
      elseif image.is_video_post(p) then
        image.extract_video_thumbnail(dest, p.id)
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
      if cached.file_url then
        p._remote_file_url = cached.file_url
      end
      if cached.preview_url and (not p.preview_url or p.preview_url == p.file_url) then
        p.preview_url = cached.preview_url
        p._remote_preview_url = cached.preview_url
      end
      if cached.sample_url and (not p.sample_url or p.sample_url == p.file_url) then
        p.sample_url = cached.sample_url
        p._remote_sample_url = cached.sample_url
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
    if d.file_url then
      p._remote_file_url = d.file_url
    end
    if d.preview_url and (not p.preview_url or p.preview_url == p.file_url) then
      p.preview_url = d.preview_url
      p._remote_preview_url = d.preview_url
    end
    if d.sample_url and (not p.sample_url or p.sample_url == p.file_url) then
      p.sample_url = d.sample_url
      p._remote_sample_url = d.sample_url
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
        file_url = d.file_url or p._remote_file_url or p.file_url,
        preview_url = p.preview_url,
        sample_url = p.sample_url,
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
