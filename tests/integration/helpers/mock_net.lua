-- tests/integration/helpers/mock_net.lua
-- Mock network boundary for gelbooru.nvim integration tests.

local download = require("gelbooru.net.download")

local M = {}

M.sample_posts = {
  {
    id = 10001,
    rating = "general",
    score = 150,
    width = 1920,
    height = 1080,
    tags = "hatsune_miku vocaloid 1girl solo kekeflipnote",
    file_url = "https://example.com/sample1.jpg",
    sample_url = "https://example.com/sample1_sample.jpg",
    preview_url = "https://example.com/sample1_prev.jpg",
  },
  {
    id = 10002,
    rating = "sensitive",
    score = 85,
    width = 1200,
    height = 1600,
    tags = "vocaloid 1girl solo",
    file_url = "https://example.com/sample2.jpg",
    sample_url = "https://example.com/sample2_sample.jpg",
    preview_url = "https://example.com/sample2_prev.jpg",
  },
  {
    id = 10003,
    rating = "general",
    score = 210,
    width = 2000,
    height = 2000,
    tags = "zenless_zone_zero 1girl",
    file_url = "https://example.com/sample3.jpg",
    sample_url = "https://example.com/sample3_sample.jpg",
    preview_url = "https://example.com/sample3_prev.jpg",
  },
}

M.sample_tags = {
  { name = "kekeflipnote", type = "1", count = "500" },
  { name = "vocaloid", type = "3", count = "200000" },
  { name = "hatsune_miku", type = "4", count = "140000" },
  { name = "1girl", type = "0", count = "1000000" },
}

local orig_curl_async = download.curl_async
local orig_download_async = download.download_async

function M.setup()
  download.curl_async = function(url, cb)
    if not cb then
      return
    end
    vim.schedule(function()
      if url:find("s=post") then
        local payload = vim.fn.json_encode({ post = M.sample_posts })
        cb(payload)
      elseif url:find("s=tag") then
        local payload = vim.fn.json_encode({ tag = M.sample_tags })
        cb(payload)
      else
        cb("{}")
      end
    end)
  end

  download.download_async = function(url, dest, cb)
    if not dest or dest == "" then
      if cb then
        cb(false)
      end
      return
    end
    -- Write a dummy 2KB valid JPEG file to satisfy media.resolver format integrity validation
    local dir = vim.fn.fnamemodify(dest, ":h")
    vim.fn.mkdir(dir, "p")
    local f = io.open(dest, "wb")
    if f then
      local valid_jpeg = string.char(
        0xFF, 0xD8, -- SOI
        0xFF, 0xC0, 0x00, 0x11, 0x08, -- SOF0 (baseline DCT, 8-bit precision)
        0x04, 0x00, 0x04, 0x00, -- Height: 1024, Width: 1024
        0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00 -- 3 components
      ) .. string.rep("A", 2048) .. string.char(0xFF, 0xD9) -- padding + EOI
      f:write(valid_jpeg)
      f:close()
      if cb then
        vim.schedule(function()
          cb(true)
        end)
      end
    else
      if cb then
        vim.schedule(function()
          cb(false)
        end)
      end
    end
  end
end

function M.teardown()
  download.curl_async = orig_curl_async
  download.download_async = orig_download_async
end

return M
