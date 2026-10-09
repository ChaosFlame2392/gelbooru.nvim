local config = require("gelbooru.core.config")
local state = require("gelbooru.core.state")
local scan = require("gelbooru.local.scan")
local util = require("gelbooru.core.util")

local M = {}

local _last_mtime = nil
local _last_dir = nil
local _has_scanned = false

local VALID_EXTS = {
  jpg = true,
  jpeg = true,
  png = true,
  gif = true,
  webp = true,
  mp4 = true,
  webm = true,
}

local function normalize_dir(raw_dir)
  if not raw_dir or raw_dir == "" then
    return nil
  end
  local clean_dir = raw_dir:gsub('^["\']', ''):gsub('["\']$', '')
  local target_dir = vim.fn.expand(clean_dir)
  if target_dir:match("^~/") then
    target_dir = (vim.env.HOME or os.getenv("HOME") or "") .. target_dir:sub(2)
  end
  return target_dir
end

function M.update_saved_index(dir_override)
  local State = state.State
  if not State.saved_index then
    State.saved_index = {}
  end

  local uv = vim.uv or vim.loop
  local target_dir = normalize_dir(dir_override or config.options.save_dir)
  if not target_dir then
    return State.saved_index
  end

  local stat = uv.fs_stat(target_dir)
  if not stat or not stat.mtime then
    return State.saved_index
  end

  local mtime = stat.mtime.sec or stat.mtime
  if _last_dir == target_dir and _last_mtime and mtime and _last_mtime == mtime and _has_scanned then
    return State.saved_index
  end

  local handle = uv.fs_scandir(target_dir)
  if not handle then
    return State.saved_index
  end

  local new_index = {}
  while true do
    local name, ftype = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if ftype == "file" or ftype == "link" or not ftype then
      local ext = name:match("%.([^%.]+)$")
      if ext and VALID_EXTS[ext:lower()] and not name:match("%.part$") then
        local id_str = scan.extract_post_id(name)
        if id_str then
          local num_id = tonumber(id_str)
          if num_id then
            new_index[num_id] = ext:lower()
          end
        end
      end
    end
  end

  State.saved_index = new_index
  _last_mtime = mtime
  _last_dir = target_dir
  _has_scanned = true

  return State.saved_index
end

function M.mark_saved(id, ext)
  if not id then
    return
  end
  local num_id = tonumber(id)
  if not num_id then
    return
  end
  local State = state.State
  if not State.saved_index then
    State.saved_index = {}
  end
  local clean_ext = (ext or "jpg"):lower()
  if clean_ext == "part" then
    return
  end
  State.saved_index[num_id] = clean_ext

  -- Refresh mtime to prevent redundant rescan
  local uv = vim.uv or vim.loop
  local target_dir = normalize_dir(config.options.save_dir)
  if target_dir then
    local stat = uv.fs_stat(target_dir)
    if stat and stat.mtime then
      _last_mtime = stat.mtime.sec or stat.mtime
      _last_dir = target_dir
      _has_scanned = true
    end
  end
end

function M.is_saved(id)
  if not id then
    return false
  end
  local num_id = tonumber(id)
  if not num_id then
    return false
  end
  local State = state.State
  return (State.saved_index and State.saved_index[num_id] ~= nil) or false
end

function M.reset()
  _last_mtime = nil
  _last_dir = nil
  _has_scanned = false
  if state.State then
    state.State.saved_index = {}
  end
end

return M
