local M = {}

local config = require("gelbooru.core.config")
local util = require("gelbooru.core.util")

function M.extract_post_id(file_path)
  if not file_path or file_path == "" then
    return nil
  end
  local fname = vim.fn.fnamemodify(file_path, ":t")
  -- 1. Exact numeric ID before extension: e.g. 11802758.jpg, 11802758.sample.png
  local id = fname:match("^(%d+)%..+$")
  if id then
    return id
  end
  -- 2. Leading numeric ID followed by delimiter: e.g. 11802758_tag.jpg, 11802758 - tag.jpg
  id = fname:match("^(%d+)[_%s%-]")
  if id then
    return id
  end
  -- 3. Explicit prefix: gelbooru_11802758.jpg, post_11802758.jpg, id_11802758.jpg
  id = fname:match("^[Gg]elbooru[ _%-]+(%d+)")
    or fname:match("^[Pp]ost[ _%-]+(%d+)")
    or fname:match("^[Ii][Dd][ _%-]?(%d+)")
  if id then
    return id
  end
  -- 4. Cache preview file: prev_11802758.jpg
  id = fname:match("^prev_(%d+)")
  if id then
    return id
  end
  return nil
end

function M.scan_local_folder(dir)
  local is_default = (not dir or vim.trim(dir) == "")
  local target = is_default and config.options.save_dir or vim.trim(dir)
  target = target:gsub('^["\']', ''):gsub('["\']$', '')
  local target_path = vim.fn.expand(target)

  if is_default then
    util.ensure(target_path)
  end

  local target_file = nil
  local target_dir = target_path
  if vim.fn.filereadable(target_path) == 1 then
    target_file = vim.fn.fnamemodify(target_path, ":p")
    target_dir = vim.fn.fnamemodify(target_path, ":p:h")
  else
    target_dir = vim.fn.fnamemodify(target_dir, ":p")
  end

  target_dir = target_dir:gsub("/+$", "")
  if target_dir == "" then
    target_dir = "/"
  end

  if vim.fn.isdirectory(target_dir) == 0 then
    return {}, target_dir, target_file
  end

  local valid_exts = {
    jpg = true,
    jpeg = true,
    png = true,
    webp = true,
    gif = true,
    mp4 = true,
    webm = true,
  }

  local files = {}
  local handle = vim.loop.fs_scandir(target_dir)
  if handle then
    while true do
      local name, ftype = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end
      if ftype == "file" or ftype == "link" then
        files[#files + 1] = (target_dir == "/" and "" or target_dir) .. "/" .. name
      end
    end
  end
  table.sort(files)

  local posts = {}
  for _, file_path in ipairs(files) do
    local ext = file_path:match("%.([^%.]+)$")
    if ext and valid_exts[ext:lower()] then
      local post_id = M.extract_post_id(file_path)
      local post = {
        id = post_id,
        file_url = file_path,
        sample_url = file_path,
        preview_url = file_path,
        is_local = true,
        tags = "local",
      }
      if post_id then
        local meta_path = util.meta_cache_path(post_id)
        if meta_path then
          local cached = util.read_json(meta_path)
          if cached then
            post.tags = cached.tags or post.tags
            post.rating = cached.rating or post.rating
            post.score = tonumber(cached.score) or cached.score or post.score
            if cached.width then
              post.width = tonumber(cached.width) or cached.width
            end
            if cached.height then
              post.height = tonumber(cached.height) or cached.height
            end
            if cached.source then
              post.source = cached.source
            end
            post._metadata_fetched = true
          end
        end
      end
      posts[#posts + 1] = post
    end
  end
  return posts, target_dir, target_file
end

return M
