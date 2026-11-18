local t = require("spec_helper")
local emote_cache = require("twitch.emote_cache")
local gif_decoder = require("twitch.gif_decoder")

local function new_cache()
	local dir = t.temporary_directory()
	t.make_directories(dir .. "/twitch", dir .. "/bttv", dir .. "/7tv", dir .. "/ffz")
	return dir
end

local function read_file(path)
	local file = assert(io.open(path, "rb"))
	local bytes = file:read("*a")
	file:close()
	return bytes
end

-- The header of a PNG of the given size (the image data is not needed for these tests).
local function png_header(width, height)
	local function u32(value)
		return string.char(math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256, math.floor(value / 256) % 256, value % 256)
	end
	return "\137PNG\r\n\26\n" .. u32(13) .. "IHDR" .. u32(width) .. u32(height) .. string.char(8, 6, 0, 0, 0) .. "crc!" .. "rest of the file"
end

t.test("emote_cache: paths stay inside the cache for safe ids only", function()
	t.equal(emote_cache.emote_cache_paths("/c", "twitch", "25"), {
		meta = "/c/twitch/25.json", png = "/c/twitch/25.png", frames = "/c/twitch/25.rgba", failed = "/c/twitch/25.failed",
	})
	t.equal(emote_cache.emote_cache_paths("/c", "twitch", "../../x"), nil)
	t.equal(emote_cache.emote_cache_paths("/c", "../twitch", "25"), nil)
	t.equal(emote_cache.emote_cache_paths("/c", "giphy", "25"), nil)
end)

t.test("emote_cache: png_image_size reads the header and refuses other data", function()
	t.equal({ emote_cache.png_image_size(png_header(56, 50)) }, { 56, 50 })
	t.equal(emote_cache.png_image_size("GIF89a" .. string.rep("x", 40)), nil)
	t.equal(emote_cache.png_image_size(""), nil)
	t.equal(emote_cache.png_image_size(png_header(0, 5)), nil)
	t.equal(emote_cache.png_image_size(png_header(100000, 5)), nil)
end)

t.test("emote_cache: a stored PNG can be read back by any pane", function()
	local dir = new_cache()
	t.equal(emote_cache.read_emote_meta(dir, "twitch", "25"), nil)
	local png = png_header(56, 50)
	local meta = assert(emote_cache.store_png_emote(dir, "twitch", "25", png))
	t.equal(meta, { kind = "png", width = 56, height = 50, file = dir .. "/twitch/25.png" })
	t.equal(emote_cache.read_emote_meta(dir, "twitch", "25"), meta)
	t.equal(read_file(meta.file), png)
	local stored, err = emote_cache.store_png_emote(dir, "twitch", "26", "<html>not found</html>")
	t.equal(stored, nil)
	t.truthy(err:find("not a PNG", 1, true))
	t.equal(emote_cache.read_emote_meta(dir, "twitch", "26"), nil)
end)

t.test("emote_cache: a decoded GIF is stored as frames back to back with their delays", function()
	local dir = new_cache()
	local file = assert(io.open(SPEC_ROOT .. "/spec/fixtures/gif/tw_g_emotesv2_cb4c93c8bef44ae6888cf239f98754b7.gif", "rb"))
	local image = assert(gif_decoder.decode_gif(file:read("*a")))
	file:close()
	local meta = assert(emote_cache.store_gif_emote(dir, "twitch", "emotesv2_cb4c", image))
	t.equal({ meta.kind, meta.width, meta.height, meta.frame_count, meta.frame_bytes }, { "frames", 56, 56, 12, 56 * 56 * 4 })
	t.equal(#meta.delays_ms, 12)
	t.equal(meta.delays_ms[1], 80)
	local frames = read_file(meta.file)
	t.equal(#frames, 12 * 56 * 56 * 4)
	t.equal(frames:sub(1, meta.frame_bytes), image.frames[1].rgba)
	t.equal(frames:sub(11 * meta.frame_bytes + 1), image.frames[12].rgba)
	t.equal(emote_cache.read_emote_meta(dir, "twitch", "emotesv2_cb4c"), meta)
end)

t.test("emote_cache: GIF delays of 0 and 1 hundredths play as a tenth of a second", function()
	local dir = new_cache()
	local pixel = string.char(1, 2, 3, 255)
	local meta = assert(emote_cache.store_gif_emote(dir, "bttv", "abc", {
		width = 1, height = 1,
		frames = { { delay_cs = 0, rgba = pixel }, { delay_cs = 1, rgba = pixel }, { delay_cs = 2, rgba = pixel }, { delay_cs = 7, rgba = pixel } },
	}))
	t.equal(meta.delays_ms, { 100, 100, 20, 70 })
end)

t.test("emote_cache: limit_emote_frames drops frames evenly and keeps the loop's length", function()
	local frames = {}
	for index = 1, 10 do
		frames[index] = { delay_ms = 10 * index, rgba = "frame" .. index }
	end
	t.equal(emote_cache.limit_emote_frames(frames, 100, 20, 100000), frames) -- within both limits
	local by_count = emote_cache.limit_emote_frames(frames, 100, 4, 100000)
	t.equal(#by_count, 4)
	t.equal(by_count[1], { delay_ms = 10 + 20 + 30, rgba = "frame1" })
	t.equal(by_count[4], { delay_ms = 100, rgba = "frame10" })
	local total = 0
	for _, frame in ipairs(by_count) do
		total = total + frame.delay_ms
	end
	t.equal(total, 550)
	-- the byte limit: 100 bytes a frame, 250 bytes allowed -> 2 frames
	local by_bytes = emote_cache.limit_emote_frames(frames, 100, 20, 250)
	t.equal(#by_bytes, 2)
	t.equal(by_bytes[2].rgba, "frame6")
	-- one frame larger than the whole budget still keeps one frame
	t.equal(#emote_cache.limit_emote_frames(frames, 1000, 20, 250), 1)
end)

t.test("emote_cache: the largest real emote is cut to the limits", function()
	-- 492 frames of 70x70: the BTTV emote that would be 9.6 MB uncapped
	local frame_bytes = 70 * 70 * 4
	local frames = {}
	for index = 1, 492 do
		frames[index] = { delay_ms = 30, rgba = "" }
	end
	local limited = emote_cache.limit_emote_frames(frames, frame_bytes)
	t.truthy(#limited <= emote_cache.MAX_EMOTE_FRAMES)
	t.truthy(#limited * frame_bytes <= emote_cache.MAX_EMOTE_ANIMATION_BYTES)
	local total = 0
	for _, frame in ipairs(limited) do
		total = total + frame.delay_ms
	end
	t.equal(total, 492 * 30)
end)

t.test("emote_cache: a failed emote is not retried until the retry time has passed", function()
	local dir = new_cache()
	t.equal(emote_cache.emote_failed_recently(dir, "7tv", "01ABC", 1000), false)
	emote_cache.mark_emote_failed(dir, "7tv", "01ABC", "HTTP 404", 1000)
	t.equal(emote_cache.emote_failed_recently(dir, "7tv", "01ABC", 1000 + 599), true)
	t.equal(emote_cache.emote_failed_recently(dir, "7tv", "01ABC", 1000 + 600), false)
	emote_cache.mark_emote_failed(dir, "7tv", "../bad", "x", 1000) -- ignored, not raised
end)

t.test("emote_cache: a damaged meta file reads as not cached", function()
	local dir = new_cache()
	local file = assert(io.open(dir .. "/twitch/25.json", "w"))
	file:write('{"kind":"png","width":')
	file:close()
	t.equal(emote_cache.read_emote_meta(dir, "twitch", "25"), nil)
	file = assert(io.open(dir .. "/twitch/26.json", "w"))
	file:write('{"kind":"frames","width":1,"height":1,"file":"/x"}')
	file:close()
	t.equal(emote_cache.read_emote_meta(dir, "twitch", "26"), nil)
end)
