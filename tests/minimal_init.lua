-- Minimal Neovim environment for headless test runs.
-- Usage: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {sequential=true}"
-- Or via: make test

vim.opt.rtp:prepend(".")

-- Plenary: resolved from env TEST_PLENARY or common lazy/packer paths.
local candidates = {
  os.getenv("TEST_PLENARY"),
  vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/packer/start/plenary.nvim"),
}

local found = false
for _, p in ipairs(candidates) do
  if p and vim.fn.isdirectory(p) == 1 then
    vim.opt.rtp:prepend(p)
    found = true
    break
  end
end

if not found then
  error("plenary.nvim not found. Set TEST_PLENARY=/path/to/plenary.nvim or install it via lazy/packer.")
end

require("plenary.busted")
