local config = require("gelbooru.core.config")

local M = {}

-- Auth is cached after first read; it never changes during a session.
local _auth_cache = nil

function M.load_auth()
  if _auth_cache then
    return _auth_cache
  end
  local auth_file = config.options.auth_file
  local f = io.open(auth_file, "r")
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

--- Call this if the auth file changes on disk mid-session.
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

function M.url_encode(s)
  local enc = (s or ""):gsub("([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", c:byte())
  end):gsub(" ", "+")
  return enc
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

function M.keymap(buf, mode, key, fn)
  vim.keymap.set(mode, key, fn, { buffer = buf, nowait = true, noremap = true, silent = true })
end

return M
