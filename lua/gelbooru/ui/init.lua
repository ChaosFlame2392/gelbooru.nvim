-- lua/gelbooru/ui/init.lua
-- Thin orchestrator facade for the gelbooru.nvim UI subsystem.
-- Re-exports all layout, keymaps, render, and lifecycle submodules
-- to maintain 100% backwards compatibility with existing plugins and test suites.

local autocomplete = require("gelbooru.ui.autocomplete")
local image = require("gelbooru.ui.image")
local keymaps = require("gelbooru.ui.keymaps")
local layout = require("gelbooru.ui.layout")
local lifecycle = require("gelbooru.ui.lifecycle")
local render = require("gelbooru.ui.render")

local M = {}

-- Submodule Handles
M.autocomplete = autocomplete
M.image = image
M.keymaps = keymaps
M.layout = layout
M.lifecycle = lifecycle
M.render = render

-- Lifecycle Operations
M.open = function(...)
  return lifecycle.open(...)
end
M.open_local = function(...)
  return lifecycle.open_local(...)
end
M.ensure_ui = function(...)
  return lifecycle.ensure_ui(...)
end
M.enter_search = function(...)
  return lifecycle.enter_search(...)
end
M.exit_input = function(...)
  return lifecycle.exit_input(...)
end
M.teardown = function(...)
  return lifecycle.teardown(...)
end
M.scan_local_folder = function(...)
  return lifecycle.scan_local_folder(...)
end

-- Layout Geometry & Responsive Scaling
M.calc_layout = function(...)
  return layout.calc_layout(...)
end
M.apply_layout = function(...)
  return layout.apply_layout(...)
end
M.invalidate_layout = function(...)
  return layout.invalidate_layout(...)
end
M.draw_dividers = function(...)
  return layout.draw_dividers(...)
end
M.handle_resize = function(...)
  return layout.handle_resize(...)
end
M.on_resize = function(...)
  return layout.on_resize(...)
end

-- Rendering & Presentation
M.set_status = function(...)
  return render.set_status(...)
end
M.render_list = function(...)
  return render.render_list(...)
end
M.render_metadata = function(...)
  return render.render_metadata(...)
end
M.render_preview = function(...)
  return render.render_preview(...)
end
M.load_and_render_image = function(...)
  return render.load_and_render_image(...)
end
M.fail_preview = function(...)
  return render.fail_preview(...)
end
M.search_active_artist = function(...)
  return render.search_active_artist(...)
end
M.find_local_file_for_post = function(...)
  return render.find_local_file_for_post(...)
end
M.open_confirm_modal = function(...)
  return render.open_confirm_modal(...)
end
M.close_confirm_modal = function(...)
  return render.close_confirm_modal(...)
end
M.delete_current = function(...)
  return render.delete_current(...)
end
M.resolve_post_dimensions = function(...)
  return image.resolve_post_dimensions(...)
end

-- Keymaps & Action Handlers
M.on_cursor_change = function(...)
  return keymaps.on_cursor_change(...)
end
M.force_refresh = function(...)
  return keymaps.force_refresh(...)
end
M.open_web_page = function(...)
  return keymaps.open_web_page(...)
end
M.open_media_viewer = function(...)
  return keymaps.open_media_viewer(...)
end
M.toggle_zen = function(...)
  return keymaps.toggle_zen(...)
end
M.return_to_list = function(...)
  return keymaps.return_to_list(...)
end
M.handle_mouse_click = function(...)
  return keymaps.handle_mouse_click(...)
end
M.apply_autocomplete_selection = function(...)
  return keymaps.apply_autocomplete_selection(...)
end
M.submit_input = function(...)
  return keymaps.submit_input(...)
end
M.handle_input_bs = function(...)
  return keymaps.handle_input_bs(...)
end
M.setup_list_keymaps = function(...)
  return keymaps.setup_list_keymaps(...)
end
M.setup_meta_keymaps = function(...)
  return keymaps.setup_meta_keymaps(...)
end
M.setup_noninteractive_keymaps = function(...)
  return keymaps.setup_noninteractive_keymaps(...)
end
M.setup_input_keymaps = function(...)
  return keymaps.setup_input_keymaps(...)
end

return M
