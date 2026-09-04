local config = require("gelbooru.core.config")
local util = require("gelbooru.core.util")
local download = require("gelbooru.net.download")

local M = {}

function M.update_tags()
  local series_map, chars_map, artists_map, general_map = {}, {}, {}, {}
  local LIMIT = 100
  local CONCURRENCY = 8
  local SPINNERS = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local spin_i = 1
  local seen = {}
  local total_fetched = 0

  local tags_dir = config.options.tags_dir
  util.ensure(tags_dir)

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
    local p = tags_dir .. "/" .. file
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
    pcall(vim.fn.writefile, { vim.fn.json_encode(map_to_list(series_map)) }, tags_dir .. "/series.json")
    pcall(vim.fn.writefile, { vim.fn.json_encode(map_to_list(chars_map)) }, tags_dir .. "/characters.json")
    pcall(vim.fn.writefile, { vim.fn.json_encode(map_to_list(artists_map)) }, tags_dir .. "/artists.json")
    pcall(vim.fn.writefile, { vim.fn.json_encode(map_to_list(general_map)) }, tags_dir .. "/general.json")
  end

  local function worker(pid, retries)
    if is_finished and retries == 0 then
      return
    end
    active_workers = active_workers + 1
    retries = retries or 0

    local url = string.format("%s&limit=%d&pid=%d&orderby=count%s", config.options.tags_api, LIMIT, pid, util.auth_qs())
    download.curl_async(url, function(body)
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

return M
