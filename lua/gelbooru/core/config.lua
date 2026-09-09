local M = {}

M.options = {
  save_dir = vim.fn.expand("~/Pictures/Gelbooru"),
  auth_file = vim.fn.stdpath("config") .. "/gelbooru_auth.json",
  tags_dir = vim.fn.expand("~/.local/share/nvim/gelbooru"),
  cache_dir = "/tmp/gelbooru_cache",
  log_level = "WARN",
  log_file = vim.fn.stdpath("state") .. "/gelbooru.log",
  api_base = "https://gelbooru.com/index.php?page=dapi&s=post&q=index&json=1",
  tags_api = "https://gelbooru.com/index.php?page=dapi&s=tag&q=index&json=1",
  per_page = 42,
  show_tags_in_list = false,
  prefetch_radius = 5,
}

function M.get_discovered_tags_file()
  return M.options.tags_dir .. "/discovered.json"
end

M.TAG_TYPES = {
  [0] = "general",
  [1] = "artist",
  [3] = "copyright",
  [4] = "character",
  [5] = "meta",
  [6] = "meme",
}

M.TAG_BADGES = {
  [0] = "General",
  [1] = "Artist",
  [3] = "Series",
  [4] = "Char",
  [5] = "Meta",
  [6] = "Meme",
}

M.META_TAGS = {
  { n = "sort:score", c = 0, t = 5 },
  { n = "sort:score:asc", c = 0, t = 5 },
  { n = "sort:id", c = 0, t = 5 },
  { n = "sort:id:asc", c = 0, t = 5 },
  { n = "rating:general", c = 0, t = 5 },
  { n = "rating:sensitive", c = 0, t = 5 },
  { n = "rating:questionable", c = 0, t = 5 },
  { n = "rating:explicit", c = 0, t = 5 },
}

function M.setup(opts)
  if not opts then
    return
  end

  local function get_opt(k1, k2, default)
    if opts[k1] ~= nil then
      return opts[k1]
    end
    if k2 and opts[k2] ~= nil then
      return opts[k2]
    end
    return default
  end

  local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, math.floor(tonumber(v) or lo)))
  end

  M.options.save_dir = get_opt("save_dir", "SAVE_DIR", M.options.save_dir)
  M.options.auth_file = get_opt("auth_file", "AUTH_FILE", M.options.auth_file)
  M.options.tags_dir = get_opt("tags_dir", "TAGS_DIR", M.options.tags_dir)
  M.options.cache_dir = get_opt("cache_dir", "CACHE_DIR", M.options.cache_dir)
  M.options.log_level = get_opt("log_level", "LOG_LEVEL", M.options.log_level)
  M.options.log_file = get_opt("log_file", "LOG_FILE", M.options.log_file)
  M.options.api_base = get_opt("api_base", "API_BASE", M.options.api_base)
  M.options.tags_api = get_opt("tags_api", "TAGS_API", M.options.tags_api)
  M.options.per_page = clamp(get_opt("per_page", "PER_PAGE", M.options.per_page), 1, 100)
  M.options.show_tags_in_list = get_opt("show_tags_in_list", "SHOW_TAGS_IN_LIST", M.options.show_tags_in_list)
  M.options.prefetch_radius = clamp(get_opt("prefetch_radius", "PREFETCH_RADIUS", M.options.prefetch_radius), 0, 20)
end

return M
