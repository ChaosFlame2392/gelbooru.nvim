# gelbooru.nvim

A Gelbooru browser application for Neovim featuring a tag picker, an image browser with the ability to download images to a designated folder, and search history.

## Installation

### For LazyVim / lazy.nvim

Add the following file to your Neovim configuration (e.g., `~/.config/nvim/lua/plugins/gelbooru.lua`):

```lua
return {
  "ChaosFlame2392/gelbooru.nvim",
  cmd = { "Gelbooru", "GelbooruTags" },
  opts = {
    -- Optional Configuration Defaults
    -- SAVE_DIR = "~/Gelbooru",
    -- PER_PAGE = 42,
    -- SHOW_TAGS_IN_LIST = false,
    -- PREFETCH_RADIUS = 5,
  },
  config = function(_, opts)
    local gelbooru = require("gelbooru")
    gelbooru.setup(opts)
  end,
  init = function()
    vim.api.nvim_create_user_command("Gelbooru", function()
      require("gelbooru").open()
    end, { desc = "Browse Gelbooru: tag picker → image browser" })

    vim.api.nvim_create_user_command("GelbooruTags", function()
      require("gelbooru").update_tags()
    end, { desc = "Download & cache Gelbooru tags for autocomplete" })
  end,
}

```

## Configuration Options

You can pass a table of options to `require("gelbooru").setup(opts)`:

| Option | Type | Description |
| --- | --- | --- |
| `SAVE_DIR` | `string` | Path where full-resolution downloaded images are saved. (Default: `~/Pictures/Gelbooru`) |
| `AUTH_FILE` | `string` | Path to your JSON credentials file (`api_key` & `user_id`). |
| `CACHE_DIR` | `string` | Temporary directory used for cached image previews. |
| `TAGS_DIR` | `string` | Directory where local tag caches are stored. |
| `DISCOVERED_TAGS_FILE` | `string` | Path to store newly discovered tags dynamically. |
| `LEGACY_TAGS_FILE` | `string` | Path to legacy tag cache data. |
| `LOG_FILE` | `string` | Path for debug logs. |
| `API_BASE` | `string` | Base Gelbooru posts API endpoint. |
| `TAGS_API` | `string` | Base Gelbooru tags API endpoint. |
| `PER_PAGE` | `number` | Number of results to fetch per page (Default: `42`). |
| `SHOW_TAGS_IN_LIST` | `boolean` | Whether to display raw tag strings directly inside the list view. |
| `PREFETCH_RADIUS` | `number` | How many adjacent post previews to pre-download in background (Default: `5`). |

## Usage

* `:Gelbooru` — Launch the tag picker and open the Gelbooru browser.
* `:GelbooruTags` — Download and cache Gelbooru tags locally for autocomplete functionality.
