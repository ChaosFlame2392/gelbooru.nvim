# gelbooru.nvim

A Gelbooru browser application for Neovim featuring a tag picker, an image browser with the ability to download images to a designated folder, and search history.

## Requirements

* **Neovim** >= 0.9.0
* **[snacks.nvim](https://github.com/folke/snacks.nvim)** (with `snacks.image` enabled) — used for in-terminal image rendering.
* **[ImageMagick](https://imagemagick.org/)** (`magick` CLI executable in your PATH) — required by `snacks.image` for image format conversion and rendering.
* **`curl`** — for making API requests and downloading post media.

## Installation

### For LazyVim / lazy.nvim

Add the following file to your Neovim configuration (e.g., `~/.config/nvim/lua/plugins/gelbooru.lua`):

```lua
return {
  "ChaosFlame2392/gelbooru.nvim",
  dependencies = {
    "folke/snacks.nvim",
  },
  cmd = { "Gelbooru", "GelbooruTags" },
  opts = {
    -- Optional Configuration Defaults
    -- save_dir = "~/Pictures/Gelbooru",
    -- per_page = 42,
    -- show_tags_in_list = false,
    -- prefetch_radius = 5,
    -- enable_logging = true,
    -- log_level = "DEBUG",
  },
}
```

## Configuration Options

You can pass a table of options to `require("gelbooru").setup(opts)`. Both `snake_case` and `UPPER_CASE` option keys are supported:

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `save_dir` | `string` | `"~/Pictures/Gelbooru"` | Path where full-resolution downloaded images are saved. |
| `auth_file` | `string` | `stdpath("config") .. "/gelbooru_auth.json"` | Path to your JSON credentials file (`api_key` & `user_id`). |
| `tags_dir` | `string` | `"~/.local/share/nvim/gelbooru"` | Directory where local tag databases are stored. |
| `cache_dir` | `string` | `"/tmp/gelbooru_cache"` | Temporary directory used for cached image previews. |
| `enable_logging` | `boolean` | `true` | Enable or disable file logging. Set to `false` to completely disable logging. |
| `log_level` | `string` | `"DEBUG"` | Minimum log level (`"DEBUG"`, `"INFO"`, `"WARN"`, `"ERROR"`, or `"OFF"`). |
| `log_file` | `string` | `stdpath("state") .. "/gelbooru.log"` | Destination path for debug logs. |
| `per_page` | `number` | `42` | Number of results to fetch per page. |
| `prefetch_radius` | `number` | `5` | How many adjacent post previews to pre-download in the background. |
| `show_tags_in_list` | `boolean` | `false` | Whether to display raw tag strings directly inside the list view. |
| `api_base` | `string` | `"https://gelbooru.com/..."` | Base Gelbooru posts API endpoint. |
| `tags_api` | `string` | `"https://gelbooru.com/..."` | Base Gelbooru tags API endpoint. |

## Usage

* `:Gelbooru` — Launch the tag picker and open the Gelbooru browser.
* `:GelbooruTags` — Download and cache Gelbooru tags locally for autocomplete functionality.
