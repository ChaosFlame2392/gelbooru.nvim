local config = require("gelbooru.core.config")

local M = {}

local _auth_cache = nil

function M.load_auth()
  if _auth_cache then
    return _auth_cache
  end
  local f = io.open(config.options.auth_file, "r")
  if not f then
    _auth_cache = {}
    return _auth_cache
  end
  local raw = f:read("*a")
  f:close()
  local ok, t = pcall(vim.fn.json_decode, raw)
  _auth_cache = (ok and type(t) == "table") and t or {}
  return _auth_cache
end

function M.invalidate_auth_cache()
  _auth_cache = nil
end

function M.auth_qs()
  local a = M.load_auth()
  if not a.api_key then
    return ""
  end
  return string.format("&api_key=%s&user_id=%s", a.api_key, a.user_id or "")
end

function M.ensure(path)
  vim.fn.mkdir(path, "p")
end

function M.ensure_array(v)
  if type(v) ~= "table" then return {} end
  if v[1] == nil and next(v) ~= nil then return { v } end
  return v
end

function M.url_encode(s)
  if s == nil then return "" end
  s = tostring(s)
  return (s:gsub("([^%w%-%.%_%~ ])", function(c)
    return string.format("%%%02X", string.byte(c))
  end):gsub(" ", "+"))
end

function M.normalize_str(s)
  return (s or ""):gsub("[^%w]", ""):lower()
end

function M.decode_html(str)
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

function M.fuzzy(str, q)
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

function M.scratch()
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile = false
  vim.bo[b].modifiable = false
  return b
end

function M.set_lines(buf, lines)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M.float(buf, row, col, w, h, extra)
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

function M.meta_cache_path(post_id)
  if not post_id or tostring(post_id) == "" or tostring(post_id) == "nil" then
    return nil
  end
  return string.format("%s/meta_%s.json", config.options.cache_dir, tostring(post_id))
end

function M.read_json(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.fn.json_decode, raw)
  return (ok and type(data) == "table") and data or nil
end

function M.write_json(path, data)
  if not path or not data then
    return false
  end
  local ok, encoded = pcall(vim.fn.json_encode, data)
  if not ok or not encoded then
    return false
  end
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir and dir ~= "" then
    M.ensure(dir)
  end
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return false
  end
  f:write(encoded)
  f:close()
  local ren_ok = vim.fn.rename(tmp, path)
  return ren_ok == 0
end

function M.open_url(url)
  if not url or url == "" then
    return false
  end
  if vim.ui and vim.ui.open then
    pcall(vim.ui.open, url)
    return true
  else
    local cmd = vim.fn.has("mac") == 1 and "open" or (vim.fn.has("win32") == 1 and "start" or "xdg-open")
    pcall(vim.fn.system, { cmd, url })
    return true
  end
end

function M.open_media(target)
  if not target or target == "" then
    return false
  end
  -- Prioritize mpv for videos if available, otherwise fallback to system opener
  local ext = target:match("%.([^%.]+)$")
  if ext and (ext:lower() == "mp4" or ext:lower() == "webm") and vim.fn.executable("mpv") == 1 then
    pcall(vim.fn.jobstart, { "mpv", target }, { detach = true })
    return true
  end
  return M.open_url(target)
end

function M.cache_post_metadata(p)
  if not p or not p.id or tostring(p.id) == "" or tostring(p.id) == "nil" then
    return false
  end
  local meta_path = M.meta_cache_path(p.id)
  if not meta_path then
    return false
  end
  return M.write_json(meta_path, {
    id = p.id,
    tags = p.tags,
    rating = p.rating,
    score = p.score,
    width = p.width,
    height = p.height,
    source = p.source,
  })
end

function M.keymap(buf, mode, key, fn)
  vim.keymap.set(mode, key, fn, { buffer = buf, nowait = true, noremap = true, silent = true })
end

return M
