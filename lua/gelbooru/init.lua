-- ─────────────────────────────────────────────────────────────────────────────
-- gelbooru.lua — Gelbooru image browser for Neovim
--
-- Commands:
--   :Gelbooru       — open tag picker → image browser
--   :GelbooruTags   — download & cache popular tags for autocomplete
--
-- Auth setup (do once, never commit to git):
--   Create ~/.config/nvim/gelbooru_auth.json:
--   { "api_key": "YOUR_KEY", "user_id": "YOUR_ID" }
--
-- ─────────────────────────────────────────────────────────────────────────────

local M = {}

-- ── Paths & constants ─────────────────────────────────────────────────────────
local SAVE_DIR = vim.fn.expand("~/Pictures/Gelbooru")
local AUTH_FILE = vim.fn.stdpath("config") .. "/gelbooru_auth.json"
local TAGS_DIR = vim.fn.expand("~/.local/share/nvim/gelbooru")
local DISCOVERED_TAGS_FILE = TAGS_DIR .. "/discovered.json"
local LEGACY_TAGS_FILE = vim.fn.expand("~/.local/share/nvim/gelbooru_tags.json")
local LOG_FILE = vim.fn.stdpath("state") .. "/gelbooru.log"
local CACHE_DIR = "/tmp/gelbooru_cache"
local API_BASE = "https://gelbooru.com/index.php?page=dapi&s=post&q=index&json=1"
local TAGS_API = "https://gelbooru.com/index.php?page=dapi&s=tag&q=index&json=1"
local PER_PAGE = 42
local SHOW_TAGS_IN_LIST = false
local PREFETCH_RADIUS = 5

function M.setup(opts)
  if not opts then return end
  local function get_opt(k1, k2, default)
    if opts[k1] ~= nil then return opts[k1] end
    if k2 and opts[k2] ~= nil then return opts[k2] end
    return default
  end

  SAVE_DIR = get_opt("SAVE_DIR", "save_dir", SAVE_DIR)
  AUTH_FILE = get_opt("AUTH_FILE", "auth_file", AUTH_FILE)
  TAGS_DIR = get_opt("TAGS_DIR", "tags_dir", TAGS_DIR)
  DISCOVERED_TAGS_FILE = TAGS_DIR .. "/discovered.json"
  LEGACY_TAGS_FILE = get_opt("LEGACY_TAGS_FILE", "legacy_tags_file", LEGACY_TAGS_FILE)
  LOG_FILE = get_opt("LOG_FILE", "log_file", LOG_FILE)
  CACHE_DIR = get_opt("CACHE_DIR", "cache_dir", CACHE_DIR)
  API_BASE = get_opt("API_BASE", "api_base", API_BASE)
  TAGS_API = get_opt("TAGS_API", "tags_api", TAGS_API)
  PER_PAGE = get_opt("PER_PAGE", "per_page", PER_PAGE)
  SHOW_TAGS_IN_LIST = get_opt("SHOW_TAGS_IN_LIST", "show_tags_in_list", SHOW_TAGS_IN_LIST)
  PREFETCH_RADIUS = get_opt("PREFETCH_RADIUS", "prefetch_radius", PREFETCH_RADIUS)
end

local TAG_TYPES = {
  [0] = "general",
  [1] = "artist",
  [3] = "copyright",
  [4] = "character",
  [5] = "meta",
  [6] = "meme",
}

local TAG_BADGES = {
  [0] = "General",
  [1] = "Artist",
  [3] = "Series",
  [4] = "Char",
  [5] = "Meta",
  [6] = "Meme",
}

local META_TAGS = {
  { n = "sort:score", c = 0, t = 5 },
  { n = "sort:score:asc", c = 0, t = 5 },
  { n = "sort:id", c = 0, t = 5 },
  { n = "sort:id:asc", c = 0, t = 5 },
  { n = "rating:general", c = 0, t = 5 },
  { n = "rating:sensitive", c = 0, t = 5 },
  { n = "rating:questionable", c = 0, t = 5 },
  { n = "rating:explicit", c = 0, t = 5 },
}

-- ── Logging Helper ───────────────────────────────────────────────────────────
local LOG_LEVELS = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
local CURRENT_LOG_LEVEL = LOG_LEVELS.DEBUG

local function log(level, cat, fmt, ...)
  if LOG_LEVELS[level] and LOG_LEVELS[level] < CURRENT_LOG_LEVEL then
    return
  end
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or (fmt or "")
  local line = string.format("[%s] [%-5s] [%-10s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), level, cat, msg)
  local f = io.open(LOG_FILE, "a")
  if f then
    f:write(line)
    f:close()
  end
end

-- ── Low-level helpers ─────────────────────────────────────────────────────────

local function load_auth()
  if vim.fn.filereadable(AUTH_FILE) == 0 then
    return {}
  end
  local raw = table.concat(vim.fn.readfile(AUTH_FILE), "")
  local ok, t = pcall(vim.fn.json_decode, raw)
  return (ok and type(t) == "table") and t or {}
end

local function auth_qs()
  local a = load_auth()
  if not a.api_key then
    return ""
  end
  return string.format("&api_key=%s&user_id=%s", a.api_key, a.user_id or "")
end

local function ensure(path)
  vim.fn.mkdir(path, "p")
end

local function url_encode(s)
  local enc = (s or ""):gsub("([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", c:byte())
  end):gsub(" ", "+")
  return enc
end

local function normalize_str(s)
  return (s or ""):gsub("[^%w]", ""):lower()
end

local function decode_html(str)
  if not str then
    return ""
  end
  str = str:gsub("&gt;", ">")
    :gsub("&lt;", "<")
    :gsub("&amp;", "&")
    :gsub("&quot;", '"')
    :gsub("&#039;", "'")
    :gsub("&#39;", "'")
  return str
end

local function fuzzy(str, q)
  if q == "" then
    return true
  end
  local qi = 1
  for i = 1, #str do
    if str:sub(i, i):lower() == q:sub(qi, qi):lower() then
      qi = qi + 1
      if qi > #q then
        return true
      end
    end
  end
  return false
end

-- ── Buffer / window helpers ───────────────────────────────────────────────────

local function scratch()
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile = false
  vim.bo[b].modifiable = false
  return b
end

local function set_lines(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function float(buf, row, col, w, h, extra)
  local cfg = vim.tbl_extend("force", {
    relative = "editor",
    row = row,
    col = col,
    width = w,
    height = h,
    style = "minimal",
    border = "none",
    zindex = 51,
    focusable = true,
  }, extra or {})
  return vim.api.nvim_open_win(buf, false, cfg)
end

local function keymap(buf, mode, key, fn)
  vim.keymap.set(mode, key, fn, { buffer = buf, nowait = true, noremap = true, silent = true })
end

-- ── Async Network Helpers ─────────────────────────────────────────────────────

local active_downloads = {}

local function curl_async(url, cb)
  log("DEBUG", "CURL", "GET %s", url)
  vim.system({
    "curl",
    "-s",
    "-L",
    "--max-time",
    "25",
    "--connect-timeout",
    "10",
    "--retry",
    "3",
    "--retry-delay",
    "2",
    "--retry-connrefused",
    url,
  }, { text = true }, function(out)
    vim.schedule(function()
      cb(out.code == 0 and out.stdout or nil)
    end)
  end)
end

local function download_async(url, dest, cb)
  -- 1. Prevent duplicate download if file is already valid on disk
  if vim.fn.filereadable(dest) == 1 and not active_downloads[dest] then
    log("DEBUG", "DOWNLOAD", "File already cached on disk: %s", dest)
    if cb then
      pcall(cb, true)
    end
    return
  end

  -- 2. Hook into existing download if already running
  local queued = active_downloads[dest]
  if queued then
    log("DEBUG", "DOWNLOAD", "Hooking into running download: %s", dest)
    if cb then
      table.insert(queued, cb)
    end
    return
  end

  -- 3. Start fresh download
  log("INFO", "DOWNLOAD", "Starting download: %s -> %s", url, dest)
  active_downloads[dest] = cb and { cb } or {}
  local tmp_dest = dest .. ".part"
  vim.fn.delete(tmp_dest)

  vim.system({
    "curl",
    "-s",
    "-L",
    "--max-time",
    "60",
    "--connect-timeout",
    "10",
    "--retry",
    "3",
    "--retry-delay",
    "2",
    "--retry-connrefused",
    "-H",
    "Referer: https://gelbooru.com/",
    "-o",
    tmp_dest,
    url,
  }, {}, function(out)
    vim.schedule(function()
      local callbacks = active_downloads[dest] or {}
      active_downloads[dest] = nil

      local ok = false
      if out.code == 0 and vim.fn.filereadable(tmp_dest) == 1 and vim.fn.getfsize(tmp_dest) > 0 then
        ok = vim.fn.rename(tmp_dest, dest) == 0
        if not ok and vim.fn.filereadable(dest) == 1 then
          vim.fn.delete(dest)
          ok = vim.fn.rename(tmp_dest, dest) == 0
        end
      end

      if vim.fn.filereadable(tmp_dest) == 1 then
        vim.fn.delete(tmp_dest)
      end

      if ok then
        vim.fn.system({ "touch", dest })
        log("DEBUG", "DOWNLOAD", "Download succeeded: %s", dest)
      else
        log("WARN", "DOWNLOAD", "Download failed (code %d): %s", out.code or -1, url)
      end

      for _, fn in ipairs(callbacks) do
        pcall(fn, ok)
      end
    end)
  end)
end

-- ── Image rendering ───────────────────────────────────────────────────────────

local UI = {
  wins = {},
  bufs = {},
  aug = nil,
  scroll_timer = nil,
  status_timer = nil,
  api_tag_timer = nil,
  ac_debounce_timer = nil,
  save_discovered_timer = nil,
  prefetch_timers = {},
  current_placement = nil,
  PREVIEW_COOLDOWN_MS = 150,
}

local function render_image(win, path, width, height)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local p_ok, placement_mod = pcall(require, "snacks.image.placement")
  if p_ok and placement_mod then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local opts = { pos = { 1, 1 } }
    if width and height then
      opts.max_width = width
      opts.max_height = height
    end
    local place_ok, placement = pcall(placement_mod.new, buf, path, opts)
    if place_ok and placement then
      -- Close and clean up previous placement
      if UI.current_placement and UI.current_placement.close then
        pcall(UI.current_placement.close, UI.current_placement)
      end
      UI.current_placement = placement
      pcall(vim.api.nvim_win_set_buf, win, buf)
      pcall(placement.update, placement)
      log("DEBUG", "RENDER", "Image rendered via snacks.image: %s", path)
      return true
    else
      log("WARN", "RENDER", "Failed to create snacks placement for %s: %s", path, tostring(placement))
    end
  else
    log("WARN", "RENDER", "snacks.image.placement not available")
  end
  return false
end

-- ── Preview & Video Helpers ───────────────────────────────────────────────────

local function file_ext_from_url(url)
  local clean = (url or ""):match("^[^%?]+") or ""
  return (clean:match("%.([%w]+)$") or "jpg"):lower()
end

local function is_video_post(p)
  local ext = file_ext_from_url(p and p.file_url)
  return ext == "mp4" or ext == "webm"
end

local function preview_source_name(p, url)
  if url and p and p.sample_url == url then
    return "sample"
  end
  if url and p and p.preview_url == url then
    return "thumbnail"
  end
  if url and p and p.file_url == url then
    return "original"
  end
  return "preview"
end

local function get_preview_targets(p)
  local urls, seen = {}, {}
  local candidates = { p and p.sample_url, p and p.preview_url, p and p.file_url }
  for i = 1, 3 do
    local u = candidates[i]
    if u and u ~= "" and not seen[u] then
      seen[u] = true
      urls[#urls + 1] = u
    end
  end
  if #urls == 0 then
    return {}, nil
  end
  local ext = file_ext_from_url(urls[1])
  return urls, string.format("%s/prev_%s.%s", CACHE_DIR, p.id, ext:lower())
end

-- ── APPLICATION STATE ─────────────────────────────────────────────────────────

local State = {
  query = "",
  posts = {},
  page = 0,
  cur = 1,
  loading = false,
  cur_id = nil,
  show_meta = true,
  history = {},
  history_idx = 0,
  series = {},
  characters = {},
  artists = {},
  general = {},
  discovered = {},
  discovered_by_name = {},
  chars_by_first = {},
  series_by_first = {},
  artists_by_first = {},
  general_by_first = {},
  all_tags = {},
  tags_by_name = {},
  autocomplete_filtered = {},
  autocomplete_cur = 1,
  autocomplete_navigated = false,
  input_focused = false,
  scroll_dir = 1, -- 1 = down, -1 = up
}

-- ── Database & Tag Management ─────────────────────────────────────────────────

local function is_clean_tag(name, count, typ)
  if not name or type(name) ~= "string" or #name < 2 then
    return false
  end
  typ = tonumber(typ) or 0
  count = tonumber(count) or 0
  if typ == 5 then -- Meta tags (sort:score, rating:general)
    return true
  end
  -- Reject 0-count or negative-count tags (typos/dead spam)
  if count < 1 then
    return false
  end
  -- Reject leading/trailing punctuation or whitespace (e.g. -foot_focus, foot_focus,)
  if name:find("^[%s%-_,%.%?!;:'%\"]") or name:find("[%s%-_,%.%?!;:'%\"]$") then
    return false
  end
  -- Reject commas, semicolons, quotes, question marks
  if name:find("[,;%?!'%\"]") then
    return false
  end
  -- Reject URLs or HTML entities
  if name:find("https?://") or name:find("&%w+;") then
    return false
  end
  -- Reject double underscores or dashes
  if name:find("__") or name:find("%-%-") or name:find("%.%.") then
    return false
  end
  -- Reject spam tags (concatenated words without parens > 45 chars)
  if #name > 45 and not name:find("%(") then
    return false
  end
  return true
end

local function add_tag_to_index(t, target_list, bucket_map)
  if not t or not t.n or type(t.n) ~= "string" then
    return
  end
  local c = tonumber(t.c) or 0
  local typ = tonumber(t.t) or 0
  if not is_clean_tag(t.n, c, typ) then
    return
  end
  local nl = t.n:lower()
  t.n_lower = nl
  t.norm = normalize_str(nl)
  t.c = c
  t.t = typ
  if target_list then
    target_list[#target_list + 1] = t
  end
  State.tags_by_name[nl] = t
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

local function persist_discovered_tag(item)
  if not item or not item.n or item.n == "" then
    return
  end
  local c = tonumber(item.c) or 0
  local typ = tonumber(item.t) or 0
  if not is_clean_tag(item.n, c, typ) then
    return
  end
  local nl = item.n:lower()
  if State.discovered_by_name[nl] then
    return
  end
  State.discovered_by_name[nl] = true
  State.discovered[#State.discovered + 1] = {
    n = item.n,
    t = typ,
    c = c,
  }

  if not UI.save_discovered_timer then
    UI.save_discovered_timer = vim.loop.new_timer()
  end
  UI.save_discovered_timer:stop()
  UI.save_discovered_timer:start(
    500,
    0,
    vim.schedule_wrap(function()
      local ok, encoded = pcall(vim.fn.json_encode, State.discovered)
      if ok and encoded then
        local f = io.open(DISCOVERED_TAGS_FILE, "w")
        if f then
          f:write(encoded)
          f:close()
          log("INFO", "TAGS", "Persisted %d discovered tags to %s", #State.discovered, DISCOVERED_TAGS_FILE)
        end
      end
    end)
  )
end

local function parse_tag_file(path, target_list, bucket_map)
  if vim.fn.filereadable(path) == 0 then
    return false
  end
  local content = table.concat(vim.fn.readfile(path), "")
  local ok, data = pcall(vim.fn.json_decode, content)
  if not ok or type(data) ~= "table" then
    return false
  end
  for _, t in ipairs(data) do
    add_tag_to_index(t, target_list, bucket_map)
  end
  return true
end

local update_autocomplete -- forward declaration

local function load_tags()
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

  local all_tags = vim.deepcopy(META_TAGS)
  for _, t in ipairs(all_tags) do
    add_tag_to_index(t, nil, nil)
  end

  ensure(TAGS_DIR)
  local series_file = TAGS_DIR .. "/series.json"
  local chars_file = TAGS_DIR .. "/characters.json"
  local artists_file = TAGS_DIR .. "/artists.json"
  local general_file = TAGS_DIR .. "/general.json"

  local has_split = vim.fn.filereadable(series_file) == 1
    or vim.fn.filereadable(chars_file) == 1
    or vim.fn.filereadable(general_file) == 1

  if has_split then
    log("INFO", "TAGS", "Loading split tag databases from %s", TAGS_DIR)
    vim.schedule(function()
      parse_tag_file(series_file, State.series, State.series_by_first)
      parse_tag_file(chars_file, State.characters, State.chars_by_first)
      parse_tag_file(artists_file, State.artists, State.artists_by_first)
      parse_tag_file(general_file, State.general, State.general_by_first)

      -- Load persistent discovered tags
      if vim.fn.filereadable(DISCOVERED_TAGS_FILE) == 1 then
        local raw = table.concat(vim.fn.readfile(DISCOVERED_TAGS_FILE), "")
        local ok, disc = pcall(vim.fn.json_decode, raw)
        if ok and type(disc) == "table" then
          for _, t in ipairs(disc) do
            if t.n and type(t.n) == "string" then
              local nl = t.n:lower()
              State.discovered_by_name[nl] = true
              State.discovered[#State.discovered + 1] = t
              local typ = tonumber(t.t) or 0
              if typ == 3 then
                add_tag_to_index(t, State.series, State.series_by_first)
              elseif typ == 4 then
                add_tag_to_index(t, State.characters, State.chars_by_first)
              elseif typ == 1 then
                add_tag_to_index(t, State.artists, State.artists_by_first)
              else
                add_tag_to_index(t, State.general, State.general_by_first)
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
        pcall(update_autocomplete)
      end
    end)
  elseif vim.fn.filereadable(LEGACY_TAGS_FILE) == 1 then
    -- Fallback to legacy file if split databases do not yet exist
    log("INFO", "TAGS", "Loading legacy tag file: %s", LEGACY_TAGS_FILE)
    vim.system({ "cat", LEGACY_TAGS_FILE }, { text = true }, function(out)
      vim.schedule(function()
        if out.code == 0 and out.stdout and out.stdout ~= "" then
          local ok, data = pcall(vim.fn.json_decode, out.stdout)
          if ok and type(data) == "table" then
            for _, t in ipairs(data) do
              if t.n and type(t.n) == "string" and (tonumber(t.c) or 0) > 0 then
                local typ = tonumber(t.t) or 0
                if typ == 3 then
                  add_tag_to_index(t, State.series, State.series_by_first)
                elseif typ == 4 then
                  add_tag_to_index(t, State.characters, State.chars_by_first)
                elseif typ == 1 then
                  add_tag_to_index(t, State.artists, State.artists_by_first)
                else
                  add_tag_to_index(t, State.general, State.general_by_first)
                end
              end
            end
          end
        end
        State.all_tags = all_tags
        if State.input_focused and UI.bufs.input and vim.api.nvim_buf_is_valid(UI.bufs.input) then
          pcall(update_autocomplete)
        end
      end)
    end)
  else
    State.all_tags = all_tags
  end
end

-- Dynamic on-demand tag resolution for tags on an active post (Fix for Issue 2)
local function resolve_post_tags(p, on_complete)
  if not p or not p.tags then
    return
  end
  local missing = {}
  local seen = {}
  for raw_tag in (p.tags or ""):gmatch("%S+") do
    local clean_tag = decode_html(raw_tag):lower()
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
    chunks[#chunks + 1] = url_encode(missing[i])
  end
  local url = string.format("%s&names=%s%s", TAGS_API, table.concat(chunks, "+"), auth_qs())

  curl_async(url, function(body)
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
          if is_clean_tag(t.name, count, typ) then
            local item = {
              n = t.name,
              t = typ,
              c = count,
            }
            local nl = item.n:lower()
            if not State.tags_by_name[nl] then
              if item.t == 1 then
                found_artist = true
                add_tag_to_index(item, State.artists, State.artists_by_first)
                log("INFO", "TAG_RESOLVE", "Discovered artist '%s' for post %s", item.n, tostring(p.id))
              elseif item.t == 3 then
                add_tag_to_index(item, State.series, State.series_by_first)
              elseif item.t == 4 then
                add_tag_to_index(item, State.characters, State.chars_by_first)
              else
                add_tag_to_index(item, State.general, State.general_by_first)
              end
              persist_discovered_tag(item)
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

-- Live tag search fallback when typing in search bar
local function fetch_api_tags(query)
  if query == "" or #query < 2 then
    return
  end
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

      local url = string.format("%s&name_pattern=%%%s%%&orderby=count&limit=25%s", TAGS_API, url_encode(query), auth_qs())
      curl_async(url, function(body)
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
                  add_tag_to_index(item, State.series, State.series_by_first)
                elseif item.t == 4 then
                  add_tag_to_index(item, State.characters, State.chars_by_first)
                elseif item.t == 1 then
                  add_tag_to_index(item, State.artists, State.artists_by_first)
                else
                  add_tag_to_index(item, State.general, State.general_by_first)
                end
                persist_discovered_tag(item)
                added = true
              end
            end
          end
          if added and State.input_focused then
            pcall(update_autocomplete)
          end
        end
      end)
    end)
  )
end

-- ── Autocomplete & Search Ranking ─────────────────────────────────────────────

update_autocomplete = function()
  State.autocomplete_filtered = {}
  local full = vim.api.nvim_buf_get_lines(UI.bufs.input, 0, 1, false)[1] or ""
  local query_part = full:match("(%S*)$") or ""
  local search_target = query_part:gsub("^[-~]", ""):lower()
  local target_norm = normalize_str(search_target)

  if search_target == "" then
    for i = 1, math.min(300, #State.all_tags) do
      table.insert(State.autocomplete_filtered, State.all_tags[i])
    end
  else
    local seen_names = {}
    local candidates = {}
    local first_char = search_target:sub(1, 1)

    local function check_bucket(bucket, cat_bonus, prefix_only)
      if not bucket then
        return false
      end
      for i = 1, #bucket do
        local t = bucket[i]
        local count = tonumber(t.c) or 0
        local typ = tonumber(t.t) or 0
        if typ == 5 or count >= 1 then
          local nl = t.n_lower
          if not seen_names[nl] then
          local score = 0
          if nl == search_target or t.norm == target_norm then
            score = 100
          elseif vim.startswith(nl, search_target) or vim.startswith(t.norm, target_norm) then
            score = 80
          elseif not prefix_only and (nl:find(search_target, 1, true) or t.norm:find(target_norm, 1, true)) then
            score = 50
          end

          if score > 0 then
            seen_names[nl] = true
            candidates[#candidates + 1] = {
              item = t,
              score = score + cat_bonus,
              count = count,
            }
            if #candidates >= 200 then
              return true
            end
          end
        end
      end
    end
    return false
    end

    -- 1. Ultra-fast path: query first-character bucket (<3ms)
    check_bucket(State.series_by_first[first_char], 15, false)
    check_bucket(State.chars_by_first[first_char], 10, false)
    check_bucket(State.general_by_first[first_char], 0, false)
    check_bucket(State.artists_by_first[first_char], 5, true) -- prefix only for artists

    -- Also check META tags (small fixed list)
    for _, t in ipairs(META_TAGS) do
      local nl = t.n_lower or t.n:lower()
      if not seen_names[nl] then
        if nl == search_target or vim.startswith(nl, search_target) then
          seen_names[nl] = true
          candidates[#candidates + 1] = { item = t, score = 90, count = 0 }
        end
      end
    end

    -- 2. Substring fallback across full series/general if few candidates found and query is >= 3 chars
    if #candidates < 20 and #search_target >= 3 then
      local function check_full_list(list, cat_bonus)
        if not list then
          return false
        end
        for i = 1, #list do
          local t = list[i]
          local count = tonumber(t.c) or 0
          local typ = tonumber(t.t) or 0
          if (typ == 5 or count >= 1) and not seen_names[t.n_lower] and (t.n_lower:find(search_target, 1, true) or t.norm:find(target_norm, 1, true)) then
            seen_names[t.n_lower] = true
            candidates[#candidates + 1] = {
              item = t,
              score = 50 + cat_bonus,
              count = count,
            }
            if #candidates >= 100 then
              return true
            end
          end
        end
        return false
      end

      check_full_list(State.series, 15)
      if #candidates < 30 then
        check_full_list(State.general, 0)
      end
    end

    table.sort(candidates, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      return a.count > b.count
    end)

    for i = 1, math.min(150, #candidates) do
      table.insert(State.autocomplete_filtered, candidates[i].item)
    end

    -- Trigger live API fallback if few results found
    if #candidates < 10 and #search_target >= 3 then
      fetch_api_tags(search_target)
    end
  end

  if not State.input_focused then
    return
  end

  if #State.autocomplete_filtered == 0 then
    set_lines(UI.bufs.ac, { "  (no matches - searching live tags…)" })
    return
  end

  local lines = {}
  for i, t in ipairs(State.autocomplete_filtered) do
    local mark = (i == State.autocomplete_cur) and " ▶" or "  "
    local badge = TAG_BADGES[tonumber(t.t)] or "Tag"
    local cnt = (t.c and t.c > 0) and string.format("%8d", t.c) or "       -"
    local name_display = t.n:sub(1, 46)
    lines[#lines + 1] = string.format("%s  %-46s  [%-7s] %s", mark, name_display, badge, cnt)
  end
  set_lines(UI.bufs.ac, lines)

  State.autocomplete_cur = math.max(0, math.min(State.autocomplete_cur, #State.autocomplete_filtered))
  if vim.api.nvim_win_is_valid(UI.wins.ac) then
    pcall(vim.api.nvim_win_set_cursor, UI.wins.ac, { math.max(1, State.autocomplete_cur), 0 })
  end
end

-- ── UI Cleanup & Teardown ─────────────────────────────────────────────────────

local function teardown()
  log("INFO", "LIFECYCLE", "Teardown Gelbooru UI")
  if UI.scroll_timer then
    UI.scroll_timer:stop()
    if not UI.scroll_timer:is_closing() then
      UI.scroll_timer:close()
    end
    UI.scroll_timer = nil
  end
  if UI.status_timer then
    UI.status_timer:stop()
    if not UI.status_timer:is_closing() then
      UI.status_timer:close()
    end
    UI.status_timer = nil
  end
  if UI.api_tag_timer then
    pcall(function()
      UI.api_tag_timer:stop()
      if not UI.api_tag_timer:is_closing() then
        UI.api_tag_timer:close()
      end
    end)
    UI.api_tag_timer = nil
  end
  if UI.ac_debounce_timer then
    pcall(function()
      UI.ac_debounce_timer:stop()
      if not UI.ac_debounce_timer:is_closing() then
        UI.ac_debounce_timer:close()
      end
    end)
    UI.ac_debounce_timer = nil
  end
  if UI.save_discovered_timer then
    pcall(function()
      UI.save_discovered_timer:stop()
      if not UI.save_discovered_timer:is_closing() then
        UI.save_discovered_timer:close()
      end
    end)
    UI.save_discovered_timer = nil
    if #State.discovered > 0 then
      local ok, encoded = pcall(vim.fn.json_encode, State.discovered)
      if ok and encoded then
        local f = io.open(DISCOVERED_TAGS_FILE, "w")
        if f then
          f:write(encoded)
          f:close()
        end
      end
    end
  end

  for _, timer in ipairs(UI.prefetch_timers or {}) do
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  UI.prefetch_timers = {}

  if UI.current_placement and UI.current_placement.close then
    pcall(UI.current_placement.close, UI.current_placement)
    UI.current_placement = nil
  end

  vim.cmd("stopinsert")
  if UI.aug then
    pcall(vim.api.nvim_del_augroup_by_id, UI.aug)
    UI.aug = nil
  end
  for _, w in pairs(UI.wins) do
    if vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  UI.wins = {}
end

local function set_status(msg, reset_ms)
  if UI.status_timer then
    UI.status_timer:stop()
    if not UI.status_timer:is_closing() then
      UI.status_timer:close()
    end
    UI.status_timer = nil
  end
  local help =
    "  j/k: nav  <CR>: save  <Tab>/<S-Tab>: page  r: refresh  m: meta  /: search  [/]: history  q: quit"
  set_lines(UI.bufs.status, { msg and ("  " .. msg) or help })
  if msg and reset_ms and reset_ms > 0 then
    UI.status_timer = vim.loop.new_timer()
    UI.status_timer:start(
      reset_ms,
      0,
      vim.schedule_wrap(function()
        if UI.status_timer and not UI.status_timer:is_closing() then
          UI.status_timer:close()
        end
        UI.status_timer = nil
        set_status()
      end)
    )
  end
end

-- ── Layout Management ─────────────────────────────────────────────────────────

local function calc_layout()
  local TW, TH = vim.o.columns, vim.o.lines
  local W = math.floor(TW * 0.95)
  local H = math.floor(TH * 0.95)

  W = math.max(W, 80)
  H = math.max(H, 20)

  local R = math.floor((TH - H) / 2)
  local C = math.floor((TW - W) / 2)

  local input_h = 1
  local main_h = H - input_h - 4
  local list_w = math.floor(W * 0.25)
  local prev_w = W - list_w - 3

  local meta_h = State.show_meta and math.min(12, math.floor(main_h * 0.35)) or 0
  local img_h = main_h - meta_h - (State.show_meta and 1 or 0)

  return {
    frame = { row = R, col = C, width = W, height = H },
    input = { row = R + 1, col = C + 1, width = W - 2, height = 1 },
    div = { row = R + 2, col = C + 1, width = W - 2, height = 1 },
    list = { row = R + 3, col = C + 1, width = list_w, height = main_h },
    vdiv = { row = R + 3, col = C + 1 + list_w, width = 1, height = main_h },
    img = { row = R + 3, col = C + 1 + list_w + 1, width = prev_w, height = img_h },
    hdiv = State.show_meta and { row = R + 3 + img_h, col = C + 1 + list_w + 1, width = prev_w, height = 1 }
      or nil,
    meta = State.show_meta and { row = R + 3 + img_h + 1, col = C + 1 + list_w + 1, width = prev_w, height = meta_h }
      or nil,
    status = { row = R + H - 2, col = C + 1, width = W - 2, height = 1 },
    ac = { row = R + 2, col = C + 1, width = W - 2, height = math.min(15, H - 4) },
  }
end

local function draw_dividers(layout)
  local W = layout.frame.width
  set_lines(UI.bufs.div, { string.rep("─", W - 2) })

  local vdiv_lines = {}
  for _ = 1, layout.list.height do
    vdiv_lines[#vdiv_lines + 1] = "│"
  end
  set_lines(UI.bufs.vdiv, vdiv_lines)

  if layout.hdiv then
    set_lines(UI.bufs.hdiv, { string.rep("─", layout.hdiv.width) })
  end
end

local function apply_layout(l)
  if not vim.api.nvim_win_is_valid(UI.wins.frame) then
    return
  end

  local function upd(win, cfg)
    if win and vim.api.nvim_win_is_valid(win) and cfg then
      vim.api.nvim_win_set_config(win, {
        relative = "editor",
        row = cfg.row,
        col = cfg.col,
        width = cfg.width,
        height = cfg.height,
      })
    end
  end

  upd(UI.wins.frame, l.frame)
  upd(UI.wins.input, l.input)
  upd(UI.wins.div, l.div)
  upd(UI.wins.list, l.list)
  upd(UI.wins.vdiv, l.vdiv)
  upd(UI.wins.img, l.img)
  upd(UI.wins.status, l.status)
  upd(UI.wins.ac, l.ac)

  if l.hdiv then
    if not UI.wins.hdiv or not vim.api.nvim_win_is_valid(UI.wins.hdiv) then
      UI.wins.hdiv = float(UI.bufs.hdiv, l.hdiv.row, l.hdiv.col, l.hdiv.width, l.hdiv.height, { zindex = 51 })
    else
      upd(UI.wins.hdiv, l.hdiv)
    end
  elseif UI.wins.hdiv and vim.api.nvim_win_is_valid(UI.wins.hdiv) then
    vim.api.nvim_win_hide(UI.wins.hdiv)
  end

  if l.meta then
    if not UI.wins.meta or not vim.api.nvim_win_is_valid(UI.wins.meta) then
      UI.wins.meta = float(UI.bufs.meta, l.meta.row, l.meta.col, l.meta.width, l.meta.height, { zindex = 51 })
    else
      upd(UI.wins.meta, l.meta)
    end
  elseif UI.wins.meta and vim.api.nvim_win_is_valid(UI.wins.meta) then
    vim.api.nvim_win_hide(UI.wins.meta)
  end

  draw_dividers(l)

  if State.input_focused then
    if vim.api.nvim_win_is_valid(UI.wins.ac) then
      vim.api.nvim_win_set_config(UI.wins.ac, { hide = false })
    end
  else
    if vim.api.nvim_win_is_valid(UI.wins.ac) then
      vim.api.nvim_win_set_config(UI.wins.ac, { hide = true })
    end
  end
end

local function on_resize()
  local l = calc_layout()
  apply_layout(l)
  if _G.render_preview then
    _G.render_preview(false)
  end
end

-- ── List & Preview Navigation ─────────────────────────────────────────────────

local function render_list()
  local lines = {}
  local l = calc_layout()
  local LW = l.list.width
  for i, p in ipairs(State.posts) do
    local prefix = (i == State.cur) and "▶ " or "  "
    local r = (p.rating or "?"):sub(1, 1):upper()
    local score = tostring(p.score or 0)
    local is_vid = is_video_post(p)
    local dims = string.format("%dx%d%s", p.width or 0, p.height or 0, is_vid and " [V]" or "")
    local tags_s = SHOW_TAGS_IN_LIST and (" " .. (p.tags or ""):sub(1, math.max(0, LW - 22))) or ""
    lines[i] = string.format("%s%s ★%-5s %-15s%s", prefix, r, score, dims, tags_s)
  end
  if #lines == 0 then
    lines = { State.loading and "  Fetching…" or "  No results" }
  end
  set_lines(UI.bufs.list, lines)
  if vim.api.nvim_win_is_valid(UI.wins.list) then
    pcall(vim.api.nvim_win_set_cursor, UI.wins.list, { math.max(1, State.cur), 0 })
  end
end

-- Directional prefetching with cancellation of obsolete timers (Fix for Issue 1)
local function prefetch_around(idx)
  -- 1. Cancel unstarted prefetch timers from earlier scrolls to avoid network saturation
  for _, timer in ipairs(UI.prefetch_timers or {}) do
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  UI.prefetch_timers = {}

  local dir = State.scroll_dir or 1
  local ahead, behind = {}, {}

  for i = 1, PREFETCH_RADIUS do
    local fwd = idx + dir * i
    local bwd = idx - dir * i
    if fwd >= 1 and fwd <= #State.posts then
      table.insert(ahead, fwd)
    end
    if bwd >= 1 and bwd <= #State.posts then
      table.insert(behind, bwd)
    end
  end

  local ordered = {}
  for _, i in ipairs(ahead) do
    table.insert(ordered, i)
  end
  for _, i in ipairs(behind) do
    table.insert(ordered, i)
  end

  local delay = 0
  for _, i in ipairs(ordered) do
    local p = State.posts[i]
    local urls, dest = get_preview_targets(p)
    local url = urls[1]

    if url and dest then
      if vim.fn.filereadable(dest) == 0 and not active_downloads[dest] then
        local timer = vim.loop.new_timer()
        table.insert(UI.prefetch_timers, timer)
        local cap_url, cap_dest = url, dest
        local cap_pid = p.id

        timer:start(
          delay,
          0,
          vim.schedule_wrap(function()
            if not timer:is_closing() then
              timer:close()
            end
            if vim.fn.filereadable(cap_dest) == 0 and not active_downloads[cap_dest] then
              log("DEBUG", "PREFETCH", "Prefetching post %s (dir=%d)", tostring(cap_pid), dir)
              download_async(cap_url, cap_dest, function() end)
            end
          end)
        )
        delay = delay + 75
      end
    end
  end
end

local function load_and_render_image(p, url_idx, retry_count, force_download)
  local urls, dest = get_preview_targets(p)
  if #urls == 0 or not dest then
    return
  end
  url_idx = math.max(1, math.min(url_idx or 1, #urls))
  retry_count = retry_count or 0
  local preview_url = urls[url_idx]

  local function fail_preview(msg)
    if not vim.api.nvim_win_is_valid(UI.wins.img) then
      return
    end
    if not State.posts[State.cur] or State.posts[State.cur].id ~= p.id then
      return
    end
    pcall(vim.api.nvim_win_set_buf, UI.wins.img, UI.bufs.img)
    set_lines(UI.bufs.img, { "", "  [ " .. msg .. " ]" })
    set_status(msg, 2500)
    log("WARN", "PREVIEW", "Preview failed for post %s: %s", tostring(p.id), msg)
  end

  local function do_render()
    if not vim.api.nvim_win_is_valid(UI.wins.img) then
      return
    end
    if not State.posts[State.cur] or State.posts[State.cur].id ~= p.id then
      return
    end
    set_status()

    local pext = file_ext_from_url(preview_url)
    local source_name = preview_source_name(p, preview_url)
    if pext == "mp4" or pext == "webm" then
      set_lines(UI.bufs.img, { "", "  [ Video Post - Preview not playable ]", "  Press 'O' to open in browser." })
      set_status(string.format("Video post • no static %s available", source_name), 2200)
      return
    end

    local size = vim.fn.getfsize(dest)
    if size > -1 and size < 1024 then
      if retry_count < 1 then
        load_and_render_image(p, url_idx, retry_count + 1, true)
      elseif url_idx < #urls then
        load_and_render_image(p, url_idx + 1, 0, true)
      else
        fail_preview("Image Download Failed - File too small")
      end
      return
    end

    local l = calc_layout()
    local ok = render_image(UI.wins.img, dest, l.img.width, l.img.height)
    if not ok then
      if retry_count < 1 then
        load_and_render_image(p, url_idx, retry_count + 1, true)
      elseif url_idx < #urls then
        load_and_render_image(p, url_idx + 1, 0, true)
      else
        fail_preview("Image Conversion Failed - File may be corrupted or unsupported")
      end
    end
  end

  if vim.fn.filereadable(dest) == 0 or force_download then
    if force_download and vim.fn.filereadable(dest) == 1 then
      vim.fn.delete(dest)
      -- Clear snacks cache for this image if forcing download
      local snacks_cache = vim.fn.expand("~/.cache/nvim/snacks/image/")
      for _, f in ipairs(vim.fn.glob(snacks_cache .. "*", false, true)) do
        if f:find(tostring(p.id), 1, true) then
          vim.fn.delete(f)
        end
      end
    end
    set_status("Downloading preview…")
    download_async(preview_url, dest, function(ok)
      if ok then
        do_render()
      elseif url_idx < #urls then
        load_and_render_image(p, url_idx + 1, 0, true)
      else
        fail_preview("Preview Download Failed")
      end
    end)
  elseif active_downloads[dest] then
    download_async(preview_url, dest, function(ok)
      if ok then
        do_render()
      elseif url_idx < #urls then
        load_and_render_image(p, url_idx + 1, 0, true)
      else
        fail_preview("Preview Download Failed")
      end
    end)
  else
    do_render()
  end
end

_G.render_preview = function(force_download)
  local p = State.posts[State.cur]
  if not p then
    set_lines(UI.bufs.img, { "  No post selected" })
    set_lines(UI.bufs.meta, {})
    return
  end

  if p.id == State.cur_id and not force_download then
    return
  end
  State.cur_id = p.id

  local ext_info = file_ext_from_url(p.file_url)
  local is_vid = is_video_post(p)
  local meta = {
    "",
    string.format("  ID      : %s", p.id or "?"),
    string.format("  Rating  : %s", p.rating or "?"),
    string.format("  Score   : %s", p.score or "?"),
    string.format("  Format  : %s", ext_info .. (is_vid and " (Video)" or "")),
    string.format("  Size    : %dx%d", p.width or 0, p.height or 0),
    string.format("  Source  : %s", (p.source or "")),
  }

  local tags_sorted = {}
  local artist_tags = {}
  for raw_tag in (p.tags or ""):gmatch("%S+") do
    local tag = decode_html(raw_tag)
    local t = State.tags_by_name and State.tags_by_name[tag:lower()]
    if t and tonumber(t.t) == 1 then
      table.insert(artist_tags, tag)
    else
      table.insert(tags_sorted, tag)
    end
  end
  table.sort(tags_sorted)

  if #artist_tags > 0 then
    meta[#meta + 1] = ""
    meta[#meta + 1] = "  Artists : " .. table.concat(artist_tags, ", ")
  end
  meta[#meta + 1] = ""
  meta[#meta + 1] = "  Tags:"

  for _, tag in ipairs(tags_sorted) do
    meta[#meta + 1] = "    " .. tag
  end
  set_lines(UI.bufs.meta, meta)

  if vim.api.nvim_win_is_valid(UI.wins.meta) then
    pcall(vim.api.nvim_win_set_cursor, UI.wins.meta, { 1, 0 })
  end

  -- Background dynamic artist resolution for any unclassified tags on this post
  pcall(resolve_post_tags, p, function()
    if State.posts[State.cur] and State.posts[State.cur].id == p.id then
      _G.render_preview(false)
    end
  end)

  -- Check cache before doing anything visual
  local _, dest = get_preview_targets(p)
  local is_cached = not force_download and dest and vim.fn.filereadable(dest) == 1 and not active_downloads[dest]

  if not is_cached then
    if vim.api.nvim_win_is_valid(UI.wins.img) and vim.api.nvim_buf_is_valid(UI.bufs.img) then
      pcall(vim.api.nvim_win_set_buf, UI.wins.img, UI.bufs.img)
    end
    set_status("Loading preview…")
  else
    set_status()
  end

  if UI.scroll_timer then
    UI.scroll_timer:stop()
    if not UI.scroll_timer:is_closing() then
      UI.scroll_timer:close()
    end
  end

  -- Cached images display with minimal debounce (30ms); uncached with cooldown
  local delay = is_cached and 30 or UI.PREVIEW_COOLDOWN_MS

  UI.scroll_timer = vim.loop.new_timer()
  UI.scroll_timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      if not UI.scroll_timer:is_closing() then
        UI.scroll_timer:close()
      end
      UI.scroll_timer = nil
      if State.posts[State.cur] and State.posts[State.cur].id == p.id then
        load_and_render_image(p, 1, 0, force_download)
        prefetch_around(State.cur)
      end
    end)
  )
end

-- ── History Management ────────────────────────────────────────────────────────

local function save_current_history()
  if State.history_idx >= 1 and State.history[State.history_idx] then
    local h = State.history[State.history_idx]
    h.query = State.query
    h.posts = vim.deepcopy(State.posts)
    h.page = State.page
    h.cur = State.cur
    log(
      "DEBUG",
      "HISTORY",
      "Saved history idx=%d query='%s' posts=%d page=%d cur=%d",
      State.history_idx,
      h.query,
      #h.posts,
      h.page,
      h.cur
    )
  end
end

local function push_history(query)
  save_current_history()
  if State.history_idx < #State.history then
    for i = #State.history, State.history_idx + 1, -1 do
      table.remove(State.history, i)
    end
  end
  table.insert(State.history, {
    query = query or State.query,
    posts = {},
    page = 0,
    cur = 1,
  })
  State.history_idx = #State.history
  log(
    "INFO",
    "HISTORY",
    "Pushed history entry idx=%d/%d query='%s'",
    State.history_idx,
    #State.history,
    query or State.query
  )
end

local fetch -- forward declaration

local function restore_history(idx)
  if idx < 1 or idx > #State.history then
    log("DEBUG", "HISTORY", "restore_history bounds check failed: idx=%d, total=%d", idx, #State.history)
    return
  end
  save_current_history()
  State.history_idx = idx
  local h = State.history[idx]
  State.query = h.query
  State.posts = vim.deepcopy(h.posts or {})
  State.page = h.page or 0
  State.cur = math.max(1, math.min(h.cur or 1, math.max(1, #State.posts)))
  State.cur_id = nil

  log(
    "INFO",
    "HISTORY",
    "Restored history idx=%d/%d query='%s' posts=%d page=%d cur=%d",
    State.history_idx,
    #State.history,
    State.query,
    #State.posts,
    State.page,
    State.cur
  )

  vim.api.nvim_buf_set_lines(UI.bufs.input, 0, 1, false, { State.query })

  if #State.posts == 0 and State.query ~= "" then
    set_status(string.format("Fetching results for: %s…", State.query))
    render_list()
    _G.render_preview(false)
    fetch(1)
  else
    render_list()
    _G.render_preview(false)
  end
  set_status(
    string.format(
      "History %d/%d: %s",
      State.history_idx,
      #State.history,
      State.query ~= "" and State.query or "(empty)"
    ),
    2000
  )
end

-- ── Search & Fetching ─────────────────────────────────────────────────────────

fetch = function(direction)
  direction = direction or 1
  if direction < 0 then
    if State.page <= 1 then
      return
    end
    local to_remove = math.min(PER_PAGE, #State.posts)
    for _ = 1, to_remove do
      table.remove(State.posts)
    end
    State.page = State.page - 1
    State.cur = math.max(1, #State.posts)
    State.cur_id = nil
    save_current_history()
    render_list()
    _G.render_preview(false)
    return
  end

  if State.loading then
    return
  end
  State.loading = true
  set_status("Fetching page " .. (State.page + 1) .. "…")
  local url = string.format(
    "%s&tags=%s&limit=%d&pid=%d%s",
    API_BASE,
    url_encode(State.query),
    PER_PAGE,
    State.page,
    auth_qs()
  )
  curl_async(url, function(body)
    State.loading = false
    if not body then
      set_status("Error: API request failed")
      render_list()
      return
    end
    local ok, data = pcall(vim.fn.json_decode, body)
    if not ok or not data or not data.post then
      set_status("No results" .. (State.query ~= "" and (" for: " .. State.query) or ""))
      render_list()
      save_current_history()
      return
    end
    for _, p in ipairs(data.post) do
      table.insert(State.posts, p)
    end
    State.page = State.page + 1
    save_current_history()
    set_status()
    render_list()
    if State.cur == 1 then
      _G.render_preview(false)
    end
  end)
end

local function execute_search(query)
  if query == State.query and #State.posts > 0 then
    return
  end
  push_history(query)
  State.query = query
  State.posts = {}
  State.page = 0
  State.cur = 1
  State.cur_id = nil
  render_list()
  _G.render_preview(false)
  fetch(1)

  -- Auto-resolve any unknown query tags so they are saved to discovered.json
  for word in (query or ""):gmatch("%S+") do
    local clean_word = word:gsub("^[-~]", ""):lower()
    if clean_word ~= "" and not clean_word:find(":") and not State.tags_by_name[clean_word] then
      local url = string.format("%s&names=%s%s", TAGS_API, url_encode(clean_word), auth_qs())
      curl_async(url, function(body)
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
                  add_tag_to_index(item, State.series, State.series_by_first)
                elseif item.t == 4 then
                  add_tag_to_index(item, State.characters, State.chars_by_first)
                elseif item.t == 1 then
                  add_tag_to_index(item, State.artists, State.artists_by_first)
                else
                  add_tag_to_index(item, State.general, State.general_by_first)
                end
                persist_discovered_tag(item)
              end
            end
          end
        end
      end)
    end
  end
end

local function save_current()
  local p = State.posts[State.cur]
  if not p or not p.file_url then
    set_status("No file URL for this post", 2000)
    return
  end
  local ext = p.file_url:match("%.(%w+)$") or "jpg"
  local dest = string.format("%s/%s.%s", SAVE_DIR, p.id, ext)
  if vim.fn.filereadable(dest) == 1 then
    set_status("Already saved → " .. dest, 2500)
    return
  end
  set_status("Saving " .. p.id .. "…")
  download_async(p.file_url, dest, function(saved)
    set_status(saved and ("✓ Saved → " .. dest) or "✗ Save failed!", 3000)
  end)
end

local function scroll_meta(dir)
  if not State.show_meta or not vim.api.nvim_win_is_valid(UI.wins.meta) then
    return
  end
  local cur_pos = vim.api.nvim_win_get_cursor(UI.wins.meta)
  local max_lines = vim.api.nvim_buf_line_count(UI.bufs.meta)
  local new_line = math.max(1, math.min(max_lines, cur_pos[1] + dir))
  vim.api.nvim_win_set_cursor(UI.wins.meta, { new_line, 0 })
end

-- ── Tag Fetcher Command (:GelbooruTags) ────────────────────────────────────────

M.update_tags = function()
  local series_map, chars_map, artists_map, general_map = {}, {}, {}, {}
  local LIMIT = 100
  local CONCURRENCY = 8
  local SPINNERS = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local spin_i = 1
  local seen = {}
  local total_fetched = 0

  ensure(TAGS_DIR)

  local prog_w = 40
  local prog_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[prog_buf].bufhidden = "wipe"
  local prog_win = vim.api.nvim_open_win(prog_buf, false, {
    relative = "editor",
    anchor = "NE",
    row = 1,
    col = vim.o.columns - 1,
    width = prog_w,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = " GelbooruTags ",
    title_pos = "center",
    zindex = 300,
    focusable = false,
  })

  local function update_progress(msg)
    if not vim.api.nvim_win_is_valid(prog_win) then
      return
    end
    vim.bo[prog_buf].modifiable = true
    vim.api.nvim_buf_set_lines(prog_buf, 0, -1, false, { string.format(" %s  %s", SPINNERS[spin_i], msg) })
    vim.bo[prog_buf].modifiable = false
    spin_i = (spin_i % #SPINNERS) + 1
  end

  local function close_progress()
    pcall(vim.api.nvim_win_close, prog_win, true)
  end

  local function is_valid_name(n)
    if type(n) ~= "string" or #n < 2 then
      return false
    end
    if n:match("[,%.%?!;:\"']$") then
      return false
    end
    if n:match("^https?://") then
      return false
    end
    return true
  end

  -- Preload existing clean databases so we never overwrite them
  local function preload_db(file, map)
    local p = TAGS_DIR .. "/" .. file
    if vim.fn.filereadable(p) == 1 then
      local raw = table.concat(vim.fn.readfile(p), "")
      local ok, data = pcall(vim.fn.json_decode, raw)
      if ok and type(data) == "table" then
        for _, t in ipairs(data) do
          if t.n and type(t.n) == "string" then
            map[t.n:lower()] = t
            seen[t.n] = true
            total_fetched = total_fetched + 1
          end
        end
      end
    end
  end

  preload_db("series.json", series_map)
  preload_db("characters.json", chars_map)
  preload_db("artists.json", artists_map)
  preload_db("general.json", general_map)

  local next_pid = math.floor(total_fetched / LIMIT)
  local active_workers = 0
  local is_finished = false
  local pages_fetched = 0

  local function save_split_files()
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
    pcall(vim.fn.writefile, { vim.fn.json_encode(map_to_list(series_map)) }, TAGS_DIR .. "/series.json")
    pcall(vim.fn.writefile, { vim.fn.json_encode(map_to_list(chars_map)) }, TAGS_DIR .. "/characters.json")
    pcall(vim.fn.writefile, { vim.fn.json_encode(map_to_list(artists_map)) }, TAGS_DIR .. "/artists.json")
    pcall(vim.fn.writefile, { vim.fn.json_encode(map_to_list(general_map)) }, TAGS_DIR .. "/general.json")
  end

  local function worker(pid, retries)
    if is_finished and retries == 0 then
      return
    end
    active_workers = active_workers + 1
    retries = retries or 0

    local url = string.format("%s&limit=%d&pid=%d&orderby=count%s", TAGS_API, LIMIT, pid, auth_qs())
    curl_async(url, function(body)
      if not body then
        if retries < 10 then
          local delay = math.min(10000, (2 ^ retries) * 1000)
          update_progress(string.format("retry %d/10 for page %d…", retries + 1, pid))
          vim.defer_fn(function()
            active_workers = active_workers - 1
            worker(pid, retries + 1)
          end, delay)
        else
          is_finished = true
          active_workers = active_workers - 1
          if active_workers == 0 then
            save_split_files()
            close_progress()
            vim.notify(
              string.format("GelbooruTags: stopped at page %d — saved %d tags", pid, total_fetched),
              vim.log.levels.WARN
            )
          end
        end
        return
      end

      local ok, data = pcall(vim.fn.json_decode, body)
      if ok and data and type(data.tag) == "table" and #data.tag > 0 then
        for _, t in ipairs(data.tag) do
          local name = t.name
          local count = tonumber(t.count) or 0
          local typ = tonumber(t.type) or 0
          if name and is_valid_name(name) and count > 0 and not seen[name] then
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
              if count >= 10 then
                general_map[name:lower()] = item
              end
            end
          end
        end

        pages_fetched = pages_fetched + 1
        if pages_fetched % 5 == 0 then
          update_progress(string.format("%d tags fetched...", total_fetched))
        end

        if pages_fetched % 20 == 0 then
          save_split_files()
        end

        active_workers = active_workers - 1
        if not is_finished then
          local next_up = next_pid
          next_pid = next_pid + 1
          worker(next_up, 0)
        end
      else
        is_finished = true
        active_workers = active_workers - 1
        if active_workers == 0 then
          save_split_files()
          close_progress()
          vim.notify(
            string.format("GelbooruTags: ✓ cached %d clean tags across databases", total_fetched),
            vim.log.levels.INFO
          )
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

-- ── Main Entrypoint (:Gelbooru) ───────────────────────────────────────────────

M.tags = M.update_tags
M.browse = function()
  return M.open()
end

M.open = function()
  ensure(CACHE_DIR)
  ensure(SAVE_DIR)
  ensure(TAGS_DIR)
  load_tags()

  UI.bufs.frame = scratch()
  UI.bufs.input = vim.api.nvim_create_buf(false, true)
  vim.bo[UI.bufs.input].bufhidden = "wipe"
  vim.bo[UI.bufs.input].modifiable = true
  UI.bufs.div = scratch()
  UI.bufs.list = scratch()
  UI.bufs.vdiv = scratch()
  UI.bufs.img = scratch()
  UI.bufs.hdiv = scratch()
  vim.bo[UI.bufs.hdiv].bufhidden = "hide"
  UI.bufs.meta = scratch()
  vim.bo[UI.bufs.meta].bufhidden = "hide"
  UI.bufs.status = scratch()
  UI.bufs.ac = scratch()
  vim.bo[UI.bufs.ac].bufhidden = "hide"

  local l = calc_layout()

  UI.wins.frame = float(UI.bufs.frame, l.frame.row, l.frame.col, l.frame.width, l.frame.height, {
    border = "rounded",
    title = "  Gelbooru  ",
    title_pos = "center",
    zindex = 50,
  })
  vim.wo[UI.wins.frame].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"

  UI.wins.input = float(UI.bufs.input, l.input.row, l.input.col, l.input.width, l.input.height, { zindex = 51 })
  UI.wins.div = float(UI.bufs.div, l.div.row, l.div.col, l.div.width, l.div.height, { zindex = 51 })
  UI.wins.list = float(UI.bufs.list, l.list.row, l.list.col, l.list.width, l.list.height, { zindex = 51 })
  UI.wins.vdiv = float(UI.bufs.vdiv, l.vdiv.row, l.vdiv.col, l.vdiv.width, l.vdiv.height, { zindex = 51 })
  UI.wins.img = float(UI.bufs.img, l.img.row, l.img.col, l.img.width, l.img.height, { zindex = 51 })
  if l.hdiv then
    UI.wins.hdiv = float(UI.bufs.hdiv, l.hdiv.row, l.hdiv.col, l.hdiv.width, l.hdiv.height, { zindex = 51 })
  end
  if l.meta then
    UI.wins.meta = float(UI.bufs.meta, l.meta.row, l.meta.col, l.meta.width, l.meta.height, { zindex = 51 })
  end
  UI.wins.status = float(UI.bufs.status, l.status.row, l.status.col, l.status.width, l.status.height, { zindex = 51 })

  UI.wins.ac = float(UI.bufs.ac, l.ac.row, l.ac.col, l.ac.width, l.ac.height, { zindex = 60 })
  vim.api.nvim_win_set_config(UI.wins.ac, { hide = true })

  vim.wo[UI.wins.list].cursorline = true
  vim.wo[UI.wins.ac].cursorline = true

  draw_dividers(l)

  UI.aug = vim.api.nvim_create_augroup("GelbooruUI", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = UI.aug,
    callback = function()
      vim.schedule(on_resize)
    end,
  })

  -- Input Buffer Autocommands
  vim.api.nvim_create_autocmd("BufEnter", {
    group = UI.aug,
    buffer = UI.bufs.input,
    callback = function()
      if not State.input_focused then
        State.input_focused = true
        update_autocomplete()
        on_resize()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = UI.aug,
    buffer = UI.bufs.input,
    callback = function()
      State.autocomplete_cur = 0
      State.autocomplete_navigated = false
      if UI.ac_debounce_timer then
        UI.ac_debounce_timer:stop()
      else
        UI.ac_debounce_timer = vim.loop.new_timer()
      end
      UI.ac_debounce_timer:start(
        50,
        0,
        vim.schedule_wrap(function()
          if State.input_focused and UI.bufs.input and vim.api.nvim_buf_is_valid(UI.bufs.input) then
            update_autocomplete()
          end
        end)
      )
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = UI.aug,
    pattern = tostring(UI.wins.frame),
    once = true,
    callback = teardown,
  })

  -- Keymaps for List
  local function lm(key, fn)
    keymap(UI.bufs.list, "n", key, fn)
  end
  for _, k in ipairs({ "<C-p>" }) do
    lm(k, "<Nop>")
  end
  lm("q", teardown)
  lm("<Esc>", teardown)
  lm("<CR>", save_current)
  lm("<Tab>", function()
    fetch(1)
  end)
  lm("<S-Tab>", function()
    fetch(-1)
  end)
  lm("R", function()
    _G.render_preview(true)
  end)
  lm("r", function()
    State.cur_id = nil
    _G.render_preview(false)
  end)
  lm("j", function()
    State.cur = math.min(State.cur + 1, #State.posts)
    State.scroll_dir = 1
    if State.history[State.history_idx] then
      State.history[State.history_idx].cur = State.cur
    end
    render_list()
    _G.render_preview(false)
    if State.cur >= #State.posts - 5 then
      fetch(1)
    end
  end)
  lm("k", function()
    State.cur = math.max(State.cur - 1, 1)
    State.scroll_dir = -1
    if State.history[State.history_idx] then
      State.history[State.history_idx].cur = State.cur
    end
    render_list()
    _G.render_preview(false)
  end)
  lm("o", function()
    local p = State.posts[State.cur]
    if p and p.file_url then
      vim.fn.system({ "open", p.file_url })
    end
  end)
  lm("O", function()
    local p = State.posts[State.cur]
    if p and p.id then
      vim.fn.system({ "open", string.format("https://gelbooru.com/index.php?page=post&s=view&id=%s", p.id) })
    end
  end)
  lm("m", function()
    State.show_meta = not State.show_meta
    on_resize()
  end)

  local function enter_search()
    State.input_focused = true
    vim.api.nvim_set_current_win(UI.wins.input)
    vim.cmd("startinsert!")
    update_autocomplete()
    on_resize()
  end
  for _, k in ipairs({ "i", "I", "a", "A", "s", "S", "/" }) do
    lm(k, enter_search)
  end

  lm("<C-d>", function()
    scroll_meta(5)
  end)
  lm("<C-u>", function()
    scroll_meta(-5)
  end)

  lm("[", function()
    restore_history(State.history_idx - 1)
  end)
  lm("]", function()
    restore_history(State.history_idx + 1)
  end)

  keymap(UI.bufs.list, "n", "<ScrollWheelDown>", function()
    scroll_meta(3)
  end)
  keymap(UI.bufs.list, "n", "<ScrollWheelUp>", function()
    scroll_meta(-3)
  end)

  -- Keymaps for Input
  local function im_n(key, fn)
    keymap(UI.bufs.input, "n", key, fn)
  end
  local function im_i(key, fn)
    keymap(UI.bufs.input, "i", key, fn)
  end

  local function exit_input()
    State.input_focused = false
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(UI.wins.list)
    on_resize()
  end

  local function submit_input()
    local full = vim.api.nvim_buf_get_lines(UI.bufs.input, 0, 1, false)[1] or ""
    full = full:match("^%s*(.-)%s*$")
    exit_input()
    execute_search(full)
  end

  im_n("<Esc>", exit_input)
  im_i("<Esc>", exit_input)
  im_n("<CR>", submit_input)
  im_i("<CR>", submit_input)

  local function nav_down()
    State.autocomplete_navigated = true
    State.autocomplete_cur = math.min(State.autocomplete_cur + 1, #State.autocomplete_filtered)
    update_autocomplete()
  end
  local function nav_up()
    State.autocomplete_navigated = true
    State.autocomplete_cur = math.max(State.autocomplete_cur - 1, 0)
    update_autocomplete()
  end
  im_i("<Down>", nav_down)
  im_i("<C-n>", nav_down)
  im_i("<Tab>", nav_down)
  im_i("<Up>", nav_up)
  im_i("<C-p>", nav_up)
  im_i("<S-Tab>", nav_up)

  im_i("<Space>", function()
    local full = vim.api.nvim_buf_get_lines(UI.bufs.input, 0, 1, false)[1] or ""
    local last_word = full:match("(%S*)$") or ""

    if last_word == "" or State.autocomplete_cur == 0 then
      vim.api.nvim_feedkeys(" ", "n", true)
      return
    end

    local t = State.autocomplete_filtered[State.autocomplete_cur]
    if not t then
      vim.api.nvim_feedkeys(" ", "n", true)
      return
    end

    local search_target = last_word:gsub("^[-~]", ""):lower()
    local target_norm = normalize_str(search_target)
    local t_norm = normalize_str(t.n)

    if not State.autocomplete_navigated and t.n:lower() ~= search_target and t_norm ~= target_norm then
      vim.api.nvim_feedkeys(" ", "n", true)
      return
    end

    local prefix = full:sub(1, #full - #last_word)
    local sign = last_word:match("^([-~])") or ""
    local new_text = prefix .. sign .. t.n .. " "
    vim.api.nvim_buf_set_lines(UI.bufs.input, 0, 1, false, { new_text })
    vim.api.nvim_win_set_cursor(UI.wins.input, { 1, #new_text })
    State.autocomplete_cur = 0
    State.autocomplete_navigated = false
  end)

  vim.api.nvim_set_current_win(UI.wins.list)
  set_status()

  vim.api.nvim_buf_set_lines(UI.bufs.input, 0, 1, false, { "" })
  enter_search()
end

return M
