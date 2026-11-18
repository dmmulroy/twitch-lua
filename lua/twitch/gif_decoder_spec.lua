local t = require("spec_helper")
local gif_decoder = require("twitch.gif_decoder")

local function read_fixture(name)
	local file = assert(io.open(SPEC_ROOT .. "/spec/fixtures/gif/" .. name, "rb"))
	local bytes = file:read("*a")
	file:close()
	return bytes
end

-- Adler-32, to compare frames without storing megabytes of pixels.
local function checksum(bytes)
	local a, b = 1, 0
	for index = 1, #bytes do
		a = (a + bytes:byte(index)) % 65521
		b = (b + a) % 65521
	end
	return b * 65536 + a
end

-- Real emotes whose every frame was compared with ffmpeg's output, pixel for pixel
-- (ffmpeg -i x.gif -fps_mode passthrough -f rawvideo -pix_fmt rgba). These numbers are
-- checksums of those verified frames.
local VERIFIED_EMOTES = {
	{ file = "7tv_01FCY771D800007PQ2DF3GDTN6_2x.gif", width = 64, height = 64, frames = 15, first_frame = 2767938513, all_frames = 843436588, first_delay_cs = 3 },
	{ file = "tw_c_emotesv2_3a5b59f49ec2433bb76a0071ec4997bb.gif", width = 112, height = 112, frames = 27, first_frame = 922370093, all_frames = 1923042537, first_delay_cs = 3 },
	{ file = "tw_g_emotesv2_ba5ae4be5c724ca59d649fa713ff0730.gif", width = 56, height = 56, frames = 20, first_frame = 69689486, all_frames = 2086033538, first_delay_cs = 10 },
	{ file = "tw_g_emotesv2_cb4c93c8bef44ae6888cf239f98754b7.gif", width = 56, height = 56, frames = 12, first_frame = 1370866185, all_frames = 134792374, first_delay_cs = 8 },
}

for _, expected in ipairs(VERIFIED_EMOTES) do
	t.test("gif_decoder: real emote " .. expected.file:sub(1, 24) .. " matches the frames verified against ffmpeg", function()
		local image = assert(gif_decoder.decode_gif(read_fixture(expected.file)))
		t.equal({ image.width, image.height, #image.frames }, { expected.width, expected.height, expected.frames })
		t.equal(image.loop_count, 0)
		t.equal(image.frames[1].delay_cs, expected.first_delay_cs)
		t.equal(checksum(image.frames[1].rgba), expected.first_frame)
		local total = 0
		for _, frame in ipairs(image.frames) do
			t.equal(#frame.rgba, expected.width * expected.height * 4)
			total = (total * 31 + checksum(frame.rgba)) % 2147483647
		end
		t.equal(total, expected.all_frames)
	end)
end

---------------------------------------------------------------------------------------
-- A tiny GIF writer, so each feature can be tested on an image small enough to read.
---------------------------------------------------------------------------------------

local function u16(value)
	return string.char(value % 256, math.floor(value / 256))
end

local function color_table(colors)
	local parts = {}
	for index, color in ipairs(colors) do
		parts[index] = string.char(color[1], color[2], color[3])
	end
	return table.concat(parts)
end

-- log2 of the color count, minus one: the size field of a color table.
local function table_size_bits(colors)
	local bits, count = 0, 2
	while count < #colors do
		bits, count = bits + 1, count * 2
	end
	assert(count == #colors, "color tables hold 2, 4, 8, ... colors")
	return bits
end

-- LZW with no compression: a clear code is sent often enough that the code size never grows.
local function lzw_data(indices, min_code_size)
	local clear, end_code = 2 ^ min_code_size, 2 ^ min_code_size + 1
	local code_size = min_code_size + 1
	local bytes, bit_buffer, bit_count = {}, 0, 0
	local function emit(code)
		bit_buffer = bit_buffer + code * 2 ^ bit_count
		bit_count = bit_count + code_size
		while bit_count >= 8 do
			bytes[#bytes + 1] = string.char(bit_buffer % 256)
			bit_buffer = math.floor(bit_buffer / 256)
			bit_count = bit_count - 8
		end
	end
	local since_clear, per_clear = 0, 2 ^ min_code_size - 2
	emit(clear)
	for _, index in ipairs(indices) do
		if since_clear == per_clear then
			emit(clear)
			since_clear = 0
		end
		emit(index)
		since_clear = since_clear + 1
	end
	emit(end_code)
	if bit_count > 0 then
		bytes[#bytes + 1] = string.char(bit_buffer % 256)
	end
	local data = table.concat(bytes)
	local blocks = {}
	for start = 1, #data, 255 do
		local chunk = data:sub(start, start + 254)
		blocks[#blocks + 1] = string.char(#chunk) .. chunk
	end
	return string.char(min_code_size) .. table.concat(blocks) .. string.char(0)
end

local INTERLACE_PASSES = { { 0, 8 }, { 4, 8 }, { 2, 4 }, { 1, 2 } }

-- spec: { width, height, colors, frames = { { pixels, left, top, width, height, delay_cs,
-- disposal, transparent, interlaced, local_colors } } }. `pixels` are color indices, row by row.
local function build_gif(spec)
	local bits = table_size_bits(spec.colors)
	local out = { "GIF89a", u16(spec.width), u16(spec.height), string.char(0x80 + bits, 0, 0), color_table(spec.colors) }
	for _, frame in ipairs(spec.frames) do
		local width, height = frame.width or spec.width, frame.height or spec.height
		local flags = (frame.disposal or 0) * 4 + (frame.transparent and 1 or 0)
		out[#out + 1] = string.char(0x21, 0xF9, 4, flags) .. u16(frame.delay_cs or 0) .. string.char(frame.transparent or 0, 0)
		local image_flags = (frame.local_colors and (0x80 + table_size_bits(frame.local_colors)) or 0) + (frame.interlaced and 0x40 or 0)
		out[#out + 1] = string.char(0x2C) .. u16(frame.left or 0) .. u16(frame.top or 0) .. u16(width) .. u16(height) .. string.char(image_flags)
		if frame.local_colors then
			out[#out + 1] = color_table(frame.local_colors)
		end
		local pixels = frame.pixels
		if frame.interlaced then
			pixels = {}
			for _, pass in ipairs(INTERLACE_PASSES) do
				for row = pass[1], height - 1, pass[2] do
					for column = 1, width do
						pixels[#pixels + 1] = frame.pixels[row * width + column]
					end
				end
			end
		end
		local color_count = #(frame.local_colors or spec.colors)
		local min_code_size = math.max(2, table_size_bits(frame.local_colors or spec.colors) + 1)
		assert(color_count <= 2 ^ min_code_size)
		out[#out + 1] = lzw_data(pixels, min_code_size)
	end
	out[#out + 1] = string.char(0x3B)
	return table.concat(out)
end

local RED, GREEN, BLUE, WHITE = { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 }, { 255, 255, 255 }
local COLORS = { RED, GREEN, BLUE, WHITE }
local PIXEL = { r = string.char(255, 0, 0, 255), g = string.char(0, 255, 0, 255), b = string.char(0, 0, 255, 255), w = string.char(255, 255, 255, 255), _ = string.char(0, 0, 0, 0) }

-- "rg/bw" -> the RGBA bytes of a 2x2 image.
local function rgba_of(picture)
	local out = {}
	for letter in picture:gmatch("[rgbw_]") do
		out[#out + 1] = PIXEL[letter]
	end
	return table.concat(out)
end

t.test("gif_decoder: a single frame, rows top to bottom", function()
	local image = assert(gif_decoder.decode_gif(build_gif({
		width = 2, height = 2, colors = COLORS,
		frames = { { pixels = { 0, 1, 2, 3 }, delay_cs = 7 } },
	})))
	t.equal({ image.width, image.height, #image.frames }, { 2, 2, 1 })
	t.equal(image.frames[1].rgba, rgba_of("rg/bw"))
	t.equal(image.frames[1].delay_cs, 7)
end)

t.test("gif_decoder: more pixels than fit between LZW clear codes", function()
	local pixels, picture = {}, {}
	for index = 1, 64 do
		pixels[index] = index % 4
		picture[index] = ({ "r", "g", "b", "w" })[index % 4 + 1]
	end
	local image = assert(gif_decoder.decode_gif(build_gif({ width = 8, height = 8, colors = COLORS, frames = { { pixels = pixels } } })))
	t.equal(image.frames[1].rgba, rgba_of(table.concat(picture)))
end)

t.test("gif_decoder: interlaced rows are put back in order", function()
	local pixels, picture = {}, {}
	for row = 0, 9 do
		pixels[row + 1] = row % 4
		picture[row + 1] = ({ "r", "g", "b", "w" })[row % 4 + 1]
	end
	local image = assert(gif_decoder.decode_gif(build_gif({
		width = 1, height = 10, colors = COLORS,
		frames = { { pixels = pixels, interlaced = true } },
	})))
	t.equal(image.frames[1].rgba, rgba_of(table.concat(picture)))
end)

t.test("gif_decoder: transparent pixels of a later frame show the frame before (disposal 1)", function()
	local image = assert(gif_decoder.decode_gif(build_gif({
		width = 2, height = 2, colors = COLORS,
		frames = {
			{ pixels = { 0, 0, 0, 0 }, disposal = 1 },
			{ pixels = { 1, 3, 3, 1 }, transparent = 3 },
		},
	})))
	t.equal(image.frames[1].rgba, rgba_of("rr/rr"))
	t.equal(image.frames[2].rgba, rgba_of("gr/rg"))
end)

t.test("gif_decoder: disposal 2 clears the frame's rectangle before the next frame", function()
	local image = assert(gif_decoder.decode_gif(build_gif({
		width = 2, height = 2, colors = COLORS,
		frames = {
			{ pixels = { 0, 0, 0, 0 }, disposal = 1 },
			{ pixels = { 1 }, left = 1, top = 0, width = 1, height = 1, disposal = 2 },
			{ pixels = { 2 }, left = 0, top = 1, width = 1, height = 1 },
		},
	})))
	t.equal(image.frames[2].rgba, rgba_of("rg/rr"))
	t.equal(image.frames[3].rgba, rgba_of("r_/br"))
end)

t.test("gif_decoder: disposal 3 restores what was there before the frame", function()
	local image = assert(gif_decoder.decode_gif(build_gif({
		width = 2, height = 2, colors = COLORS,
		frames = {
			{ pixels = { 0, 0, 0, 0 }, disposal = 1 },
			{ pixels = { 1, 1, 1, 1 }, disposal = 3 },
			{ pixels = { 2 }, left = 0, top = 0, width = 1, height = 1 },
		},
	})))
	t.equal(image.frames[2].rgba, rgba_of("gg/gg"))
	t.equal(image.frames[3].rgba, rgba_of("br/rr"))
end)

t.test("gif_decoder: a frame's own color table replaces the global one for that frame", function()
	local image = assert(gif_decoder.decode_gif(build_gif({
		width = 2, height = 1, colors = COLORS,
		frames = {
			{ pixels = { 0, 1 }, disposal = 1 },
			{ pixels = { 0, 1 }, local_colors = { BLUE, WHITE } },
		},
	})))
	t.equal(image.frames[1].rgba, rgba_of("rg"))
	t.equal(image.frames[2].rgba, rgba_of("bw"))
end)

t.test("gif_decoder: a frame that hangs over the canvas edge is clipped", function()
	local image = assert(gif_decoder.decode_gif(build_gif({
		width = 2, height = 2, colors = COLORS,
		frames = { { pixels = { 1, 2, 3, 0 }, left = 1, top = 1, width = 2, height = 2 } },
	})))
	t.equal(image.frames[1].rgba, rgba_of("__/_g"))
end)

t.test("gif_decoder: max_frames stops a long animation", function()
	local frames = {}
	for index = 1, 6 do
		frames[index] = { pixels = { index % 4 } }
	end
	local image = assert(gif_decoder.decode_gif(build_gif({ width = 1, height = 1, colors = COLORS, frames = frames }), { max_frames = 4 }))
	t.equal(#image.frames, 4)
	t.equal(image.truncated, true)
end)

t.test("gif_decoder: things that are not GIFs are refused with a message", function()
	for _, bytes in ipairs({ "", "GIF", "not a gif at all, just text", string.rep(string.char(0), 64), string.char(0x89) .. "PNG\r\n" .. string.rep("x", 40) }) do
		local image, err = gif_decoder.decode_gif(bytes)
		t.equal(image, nil)
		t.truthy(type(err) == "string" and err:find("gif_decoder:", 1, true))
	end
	t.equal(gif_decoder.decode_gif(nil), nil)
	-- a zero-sized and an enormous canvas
	t.equal(gif_decoder.decode_gif("GIF89a" .. u16(0) .. u16(5) .. string.char(0, 0, 0) .. string.char(0x3B)), nil)
	t.equal(gif_decoder.decode_gif("GIF89a" .. u16(60000) .. u16(60000) .. string.char(0, 0, 0) .. string.char(0x3B)), nil)
end)

t.test("gif_decoder: a file cut off anywhere never raises", function()
	local bytes = read_fixture("tw_g_emotesv2_cb4c93c8bef44ae6888cf239f98754b7.gif")
	for _, length in ipairs({ 13, 14, 200, 781, 800, 1500, 5000, #bytes - 1 }) do
		local image, err = gif_decoder.decode_gif(bytes:sub(1, length))
		t.truthy(image ~= nil or type(err) == "string", "cut at " .. length)
		if image then
			t.truthy(#image.frames >= 1)
		end
	end
end)

t.test("gif_decoder: corrupted bytes never raise", function()
	local bytes = read_fixture("tw_g_emotesv2_cb4c93c8bef44ae6888cf239f98754b7.gif")
	local seed = 12345
	local function next_random(limit)
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed % limit
	end
	for _ = 1, 60 do
		local position = 14 + next_random(#bytes - 14)
		local damaged = bytes:sub(1, position - 1) .. string.char(next_random(256)) .. bytes:sub(position + 1)
		local image, err = gif_decoder.decode_gif(damaged)
		t.truthy(image ~= nil or type(err) == "string")
	end
end)
