local inspector = require("gelbooru.media.inspector")

describe("lua.gelbooru.media.inspector", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  local function write_file(name, bytes)
    local full_path = tmp_dir .. "/" .. name
    local parent = vim.fn.fnamemodify(full_path, ":h")
    if vim.fn.isdirectory(parent) ~= 1 then
      vim.fn.mkdir(parent, "p")
    end
    local f = assert(io.open(full_path, "wb"))
    f:write(bytes)
    f:close()
    return full_path
  end

  local function sample_png(w, h)
    w = w or 800
    h = h or 600
    local sig = string.char(137, 80, 78, 71, 13, 10, 26, 10)
    local ihdr_len = string.char(0, 0, 0, 13)
    local ihdr_type = "IHDR"
    local w_bytes = string.char(
      math.floor(w / 16777216) % 256,
      math.floor(w / 65536) % 256,
      math.floor(w / 256) % 256,
      w % 256
    )
    local h_bytes = string.char(
      math.floor(h / 16777216) % 256,
      math.floor(h / 65536) % 256,
      math.floor(h / 256) % 256,
      h % 256
    )
    local ihdr_tail = string.char(8, 2, 0, 0, 0, 0, 0, 0, 0)
    local iend = string.char(0, 0, 0, 0) .. "IEND" .. string.char(174, 66, 96, 130)
    return sig .. ihdr_len .. ihdr_type .. w_bytes .. h_bytes .. ihdr_tail .. iend
  end

  local function sample_jpg(w, h)
    w = w or 1920
    h = h or 1080
    local soi = string.char(255, 216)
    local sof0 = string.char(255, 192)
    local sof_len = string.char(0, 17)
    local precision = string.char(8)
    local height = string.char(math.floor(h / 256), h % 256)
    local width = string.char(math.floor(w / 256), w % 256)
    local tail = string.char(3, 1, 17, 0, 2, 17, 1, 3, 17, 1)
    local eoi = string.char(255, 217)
    return soi .. sof0 .. sof_len .. precision .. height .. width .. tail .. string.rep("A", 600) .. eoi
  end

  local function make_static_gif(w, h, inject_data_with_2c)
    w = w or 10
    h = h or 10
    -- Header: GIF89a
    local header = "GIF89a"
    -- LSD: width(2), height(2), packed(1), bg(1), aspect(1)
    -- packed = 0x80 (GCT flag = 1, GCT size = 2^(0+1) = 2 colors = 6 bytes)
    local lsd = string.char(w % 256, math.floor(w / 256), h % 256, math.floor(h / 256), 128, 0, 0)
    -- GCT: 2 colors (6 bytes)
    local gct = string.char(0, 0, 0, 255, 255, 255)
    -- GCE (Graphic Control Extension): 0x21 0xF9, len 4, 4 bytes, terminator 0x00
    local gce = string.char(0x21, 0xF9, 4, 0, 0, 0, 0, 0)
    -- Image Descriptor 1: 0x2C, left(2), top(2), w(2), h(2), packed(1)
    local id1 = string.char(0x2C, 0, 0, 0, 0, w % 256, math.floor(w / 256), h % 256, math.floor(h / 256), 0)
    -- LZW min code size: 2
    local lzw = string.char(2)
    -- Sub-blocks: subblock size + data + terminator (0x00)
    -- If inject_data_with_2c is true, put 0x2C inside the data subblock to verify parser doesn't false-positive
    local sub_data = inject_data_with_2c and string.char(0x2C, 0x2C, 0x44) or string.char(1, 2, 3)
    local subblock = string.char(#sub_data) .. sub_data .. string.char(0)
    -- Trailer: 0x3B
    local trailer = string.char(0x3B)
    return header .. lsd .. gct .. gce .. id1 .. lzw .. subblock .. trailer
  end

  local function make_animated_gif(w, h)
    w = w or 10
    h = h or 10
    local header = "GIF89a"
    local lsd = string.char(w % 256, math.floor(w / 256), h % 256, math.floor(h / 256), 0, 0, 0)
    -- Frame 1
    local gce1 = string.char(0x21, 0xF9, 4, 0, 0, 0, 0, 0)
    local id1 = string.char(0x2C, 0, 0, 0, 0, w % 256, math.floor(w / 256), h % 256, math.floor(h / 256), 0)
    local lzw1 = string.char(2)
    local sub1 = string.char(2, 1, 2, 0)
    -- Frame 2
    local gce2 = string.char(0x21, 0xF9, 4, 0, 0, 0, 0, 0)
    local id2 = string.char(0x2C, 0, 0, 0, 0, w % 256, math.floor(w / 256), h % 256, math.floor(h / 256), 0)
    local lzw2 = string.char(2)
    local sub2 = string.char(2, 1, 2, 0)
    -- Trailer
    local trailer = string.char(0x3B)
    return header .. lsd .. gce1 .. id1 .. lzw1 .. sub1 .. gce2 .. id2 .. lzw2 .. sub2 .. trailer
  end

  describe("read_image_dimensions and format parsers", function()
    it("extracts PNG dimensions from IHDR", function()
      local p = write_file("test.png", sample_png(800, 600))
      local w, h = inspector.read_image_dimensions(p)
      assert.are.equal(800, w)
      assert.are.equal(600, h)
    end)

    it("extracts GIF dimensions for GIF87a and GIF89a", function()
      local p87 = write_file("test87.gif", "GIF87a" .. string.char(64, 1, 240, 0) .. ";")
      local w87, h87 = inspector.read_image_dimensions(p87)
      assert.are.equal(320, w87)
      assert.are.equal(240, h87)

      local p89 = write_file("test89.gif", "GIF89a" .. string.char(128, 7, 56, 4) .. ";")
      local w89, h89 = inspector.read_image_dimensions(p89)
      assert.are.equal(1920, w89)
      assert.are.equal(1080, h89)
    end)

    it("extracts WebP dimensions from VP8, VP8L, and VP8X chunks", function()
      -- VP8
      local riff_vp8 = "RIFF" .. string.char(40, 0, 0, 0) .. "WEBP"
      local chunk_vp8 = "VP8 " .. string.char(20, 0, 0, 0) .. string.char(0, 0, 0, 157, 1, 42, 128, 2, 224, 1)
      local p_vp8 = write_file("vp8.webp", riff_vp8 .. chunk_vp8 .. string.rep("\0", 20))
      local w1, h1 = inspector.read_image_dimensions(p_vp8)
      assert.are.equal(640, w1)
      assert.are.equal(480, h1)

      -- VP8L
      local riff_vp8l = "RIFF" .. string.char(40, 0, 0, 0) .. "WEBP"
      local chunk_vp8l = "VP8L" .. string.char(10, 0, 0, 0) .. string.char(47, 255, 195, 191, 0)
      local p_vp8l = write_file("vp8l.webp", riff_vp8l .. chunk_vp8l .. string.rep("\0", 20))
      local w2, h2 = inspector.read_image_dimensions(p_vp8l)
      assert.are.equal(1024, w2)
      assert.are.equal(768, h2)

      -- VP8X
      local riff_vp8x = "RIFF" .. string.char(50, 0, 0, 0) .. "WEBP"
      local chunk_vp8x = "VP8X" .. string.char(10, 0, 0, 0) .. string.char(0, 0, 0, 0, 255, 14, 0, 111, 8, 0)
      local p_vp8x = write_file("vp8x.webp", riff_vp8x .. chunk_vp8x .. string.rep("\0", 20))
      local w3, h3 = inspector.read_image_dimensions(p_vp8x)
      assert.are.equal(3840, w3)
      assert.are.equal(2160, h3)
    end)

    it("extracts JPEG dimensions from baseline SOF0 and progressive SOF2", function()
      local p0 = write_file("sof0.jpg", sample_jpg(1920, 1080))
      local w0, h0 = inspector.read_image_dimensions(p0)
      assert.are.equal(1920, w0)
      assert.are.equal(1080, h0)

      local soi = string.char(255, 216)
      local sof2 = string.char(255, 194, 0, 17, 8, 2, 208, 5, 0) .. string.rep("B", 8) .. string.char(255, 217)
      local p2 = write_file("sof2.jpg", soi .. sof2)
      local w2, h2 = inspector.read_image_dimensions(p2)
      assert.are.equal(1280, w2)
      assert.are.equal(720, h2)
    end)

    it("returns nil, nil for nil, empty, missing, or zero-byte files", function()
      assert.is_nil(inspector.read_image_dimensions(nil))
      assert.is_nil(inspector.read_image_dimensions(""))
      assert.is_nil(inspector.read_image_dimensions(tmp_dir .. "/nonexistent.png"))

      local empty = write_file("empty.png", "")
      local w, h = inspector.read_image_dimensions(empty)
      assert.is_nil(w)
      assert.is_nil(h)
    end)
  end)

  describe("is_image_complete", function()
    it("returns true for valid complete images", function()
      local png = write_file("valid.png", sample_png(800, 600))
      assert.is_true(inspector.is_image_complete(png))

      local jpg = write_file("valid.jpg", sample_jpg(1920, 1080))
      assert.is_true(inspector.is_image_complete(jpg))

      local gif = write_file("valid.gif", "GIF89a" .. string.char(10, 0, 10, 0) .. ";")
      assert.is_true(inspector.is_image_complete(gif))

      local riff = "RIFF" .. string.char(12, 0, 0, 0) .. "WEBP" .. "VP8 " .. string.char(4, 0, 0, 0) .. "test"
      local webp = write_file("valid.webp", riff)
      assert.is_true(inspector.is_image_complete(webp))
    end)

    it("returns false for truncated or incomplete images", function()
      local trunc_png = write_file("trunc.png", string.sub(sample_png(800, 600), 1, 30))
      assert.is_false(inspector.is_image_complete(trunc_png))

      local trunc_jpg = write_file("trunc.jpg", string.char(255, 216, 255, 192, 0, 17, 8, 1, 0, 1, 0))
      assert.is_false(inspector.is_image_complete(trunc_jpg))

      local trunc_gif = write_file("trunc.gif", "GIF89a" .. string.char(10, 0, 10, 0))
      assert.is_false(inspector.is_image_complete(trunc_gif))
    end)

    it("returns false for HTML or XML error pages", function()
      local html = write_file("404.jpg", "<!DOCTYPE html><html><body>404 Not Found</body></html>")
      assert.is_false(inspector.is_image_complete(html))

      local xml = write_file("error.png", "<?xml version='1.0'?><Error>Access Denied</Error>")
      assert.is_false(inspector.is_image_complete(xml))
    end)

    it("returns false for nil, empty, missing, or 0-byte paths", function()
      assert.is_false(inspector.is_image_complete(nil))
      assert.is_false(inspector.is_image_complete(""))
      assert.is_false(inspector.is_image_complete(tmp_dir .. "/missing.jpg"))

      local empty = write_file("empty.jpg", "")
      assert.is_false(inspector.is_image_complete(empty))
    end)
  end)

  describe("is_gif_animated", function()
    it("returns false for single-frame static GIF", function()
      local static_gif = write_file("static.gif", make_static_gif(20, 20, false))
      assert.is_false(inspector.is_gif_animated(static_gif))
    end)

    it("returns false for static GIF even when image sub-blocks contain 0x2C byte (no false positives)", function()
      local tricky_gif = write_file("tricky_static.gif", make_static_gif(20, 20, true))
      assert.is_false(inspector.is_gif_animated(tricky_gif))
    end)

    it("returns true for multi-frame animated GIF", function()
      local anim_gif = write_file("anim.gif", make_animated_gif(32, 32))
      assert.is_true(inspector.is_gif_animated(anim_gif))
    end)

    it("returns false for non-GIF, invalid header, nil, missing, or empty file", function()
      local png = write_file("not_gif.png", sample_png())
      assert.is_false(inspector.is_gif_animated(png))

      assert.is_false(inspector.is_gif_animated(nil))
      assert.is_false(inspector.is_gif_animated(""))
      assert.is_false(inspector.is_gif_animated(tmp_dir .. "/missing.gif"))

      local empty = write_file("empty.gif", "")
      assert.is_false(inspector.is_gif_animated(empty))
    end)
  end)

  describe("is_info_corrupt", function()
    it("detects ImageMagick corruption and error keywords", function()
      assert.is_true(inspector.is_info_corrupt("identify: unable to open image"))
      assert.is_true(inspector.is_info_corrupt("error: decode failed"))
      assert.is_true(inspector.is_info_corrupt("improper image header"))
      assert.is_true(inspector.is_info_corrupt("corrupt JPEG data"))
      assert.is_true(inspector.is_info_corrupt("conversion failed"))
      assert.is_true(inspector.is_info_corrupt(""))
      assert.is_true(inspector.is_info_corrupt(nil))
    end)

    it("returns false for valid clean metadata", function()
      assert.is_false(inspector.is_info_corrupt("Format: PNG, Geometry: 800x600, Depth: 8-bit"))
      assert.is_false(inspector.is_info_corrupt("OK: JPEG 1920x1080"))
    end)
  end)

  describe("inspect", function()
    it("returns complete inspection table for PNG", function()
      local png = write_file("test_art.png", sample_png(800, 600))
      local info = inspector.inspect(png)
      assert.is_not_nil(info)
      assert.are.equal(800, info.width)
      assert.are.equal(600, info.height)
      assert.are.equal("png", info.format)
      assert.is_false(info.is_animated)
      assert.is_true(info.is_complete)
    end)

    it("returns complete inspection table for animated GIF", function()
      local anim = write_file("test_anim.gif", make_animated_gif(16, 16))
      local info = inspector.inspect(anim)
      assert.is_not_nil(info)
      assert.are.equal(16, info.width)
      assert.are.equal(16, info.height)
      assert.are.equal("gif", info.format)
      assert.is_true(info.is_animated)
      assert.is_true(info.is_complete)
    end)

    it("returns nil for unreadable, corrupt, or missing file", function()
      assert.is_nil(inspector.inspect(nil))
      assert.is_nil(inspector.inspect(tmp_dir .. "/missing.jpg"))
      local empty = write_file("bad.jpg", "")
      assert.is_nil(inspector.inspect(empty))
    end)
  end)

  describe("zero child processes guarantee", function()
    it("never spawns CLI subprocesses during inspect or dimension reading", function()
      local spawned = false
      local orig_sys = vim.system
      local orig_job = vim.fn.jobstart

      vim.system = function(...)
        spawned = true
        return orig_sys(...)
      end
      vim.fn.jobstart = function(...)
        spawned = true
        return orig_job(...)
      end

      local png = write_file("clean.png", sample_png())
      inspector.read_image_dimensions(png)
      inspector.is_image_complete(png)
      inspector.is_gif_animated(png)
      inspector.inspect(png)

      vim.system = orig_sys
      vim.fn.jobstart = orig_job

      assert.is_false(spawned)
    end)
  end)
end)
