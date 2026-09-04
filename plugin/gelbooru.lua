if vim.g.loaded_gelbooru == 1 then
  return
end
vim.g.loaded_gelbooru = 1

vim.api.nvim_create_user_command("Gelbooru", function()
  require("gelbooru").open()
end, { desc = "Browse Gelbooru: tag picker → image browser" })

vim.api.nvim_create_user_command("GelbooruTags", function()
  require("gelbooru").update_tags()
end, { desc = "Download & cache Gelbooru tags for autocomplete" })
