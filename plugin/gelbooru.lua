if vim.g.loaded_gelbooru == 1 then
  return
end
vim.g.loaded_gelbooru = 1

vim.api.nvim_create_user_command("Gelbooru", function(opts)
  local arg = opts.args and vim.trim(opts.args)
  require("gelbooru").open((arg and arg ~= "") and arg or nil)
end, { nargs = "*", desc = "Browse Gelbooru: tag picker → image browser" })

local function tag_complete(arglead)
  local subcmds = { "verify", "refresh" }
  return vim.tbl_filter(function(s)
    return s:find("^" .. vim.pesc(arglead))
  end, subcmds)
end

vim.api.nvim_create_user_command("GelbooruTags", function(opts)
  local arg = opts.args and vim.trim(opts.args)
  require("gelbooru").update_tags((arg and arg ~= "") and arg or nil)
end, {
  nargs = "?",
  complete = tag_complete,
  desc = "Download, refresh, or verify Gelbooru tags for autocomplete",
})

vim.api.nvim_create_user_command("GelbooruTag", function(opts)
  local arg = opts.args and vim.trim(opts.args)
  require("gelbooru").update_tags((arg and arg ~= "") and arg or nil)
end, {
  nargs = "?",
  complete = tag_complete,
  desc = "Alias for GelbooruTags",
})

vim.api.nvim_create_user_command("GelbooruLocal", function(opts)
  local arg = opts.args and vim.trim(opts.args)
  require("gelbooru").open_local((arg and arg ~= "") and arg or nil)
end, { nargs = "?", complete = "dir", desc = "Browse local Gelbooru image folder" })
