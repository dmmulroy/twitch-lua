-- Decodes an animated GIF into RGBA frames in pure Lua (5.1, LuaJIT, Rex). No bit
-- library and no I/O. Used for animated emotes: every emote provider serves them as GIF.
--
--   local gif_decoder = require("twitch.gif_decoder")
--   local image, err = gif_decoder.decode_gif(bytes)
--   image = { width, height, loop_count, frames = { { delay_cs, rgba }, ... } }
--
-- Each frame's `rgba` is the whole canvas after that frame is drawn: width * height * 4
-- bytes, rows top to bottom, which is what the Kitty graphics protocol takes as f=32.
-- `delay_cs` is the frame's delay in hundredths of a second, as stored in the file.
-- Checked against ffmpeg on 43 real emotes (2,257 frames): every pixel equal.

local compat = require("distilled.compat")

local M = {}

local POW2 = {}
for i = 0, 24 do
	POW2[i] = 2 ^ i
end

local TRANSPARENT = string.char(0, 0, 0, 0)
local MAX_PIXELS = 512 * 512 -- emotes are at most 112x112 (4x scale); refuse anything huge
local DEFAULT_MAX_FRAMES = 1000

local function u16(s, i)
	local lo, hi = s:byte(i, i + 1)
	return lo + hi * 256
end

-- A color table as a list of 4-byte RGBA strings, indexed from 0.
local function read_color_table(s, pos, count)
	local colors = {}
	for i = 0, count - 1 do
		local r, g, b = s:byte(pos + i * 3, pos + i * 3 + 2)
		colors[i] = string.char(r, g, b, 255)
	end
	return colors, pos + count * 3
end

-- Joins the data sub-blocks that start at `pos`. Returns the bytes and the position after
-- the block terminator.
local function read_sub_blocks(s, pos)
	local parts, n = {}, 0
	while true do
		local size = s:byte(pos)
		if not size then
			return nil, "gif_decoder: data ends inside a sub-block"
		end
		if size == 0 then
			return table.concat(parts), pos + 1
		end
		n = n + 1
		parts[n] = s:sub(pos + 1, pos + size)
		pos = pos + 1 + size
	end
end

-- LZW (GIF variant: LSB-first codes, 3..12 bits). Returns a list of color indices.
local function lzw_decode(data, min_code_size, pixel_count)
	local clear = POW2[min_code_size]
	local end_of_information = clear + 1
	local next_code = clear + 2
	local code_size = min_code_size + 1
	local code_limit = POW2[code_size]
	local prefix, suffix, stack = {}, {}, {}
	local out, n = {}, 0
	local bit_buffer, bit_count = 0, 0
	local pos, data_len = 1, #data
	local previous, first

	while n < pixel_count do
		while bit_count < code_size do
			if pos > data_len then
				return out, n -- truncated data: keep what we have
			end
			bit_buffer = bit_buffer + data:byte(pos) * POW2[bit_count]
			bit_count = bit_count + 8
			pos = pos + 1
		end
		local code = bit_buffer % code_limit
		bit_buffer = (bit_buffer - code) / code_limit
		bit_count = bit_count - code_size

		if code == clear then
			next_code = clear + 2
			code_size = min_code_size + 1
			code_limit = POW2[code_size]
			previous = nil
		elseif code == end_of_information then
			break
		elseif previous == nil then
			if code >= clear then
				return nil, "gif_decoder: bad first LZW code"
			end
			n = n + 1
			out[n] = code
			first = code
			previous = code
		else
			local in_code = code
			local depth = 0
			if code >= next_code then
				if code > next_code then
					return nil, "gif_decoder: LZW code out of range"
				end
				depth = 1
				stack[1] = first
				code = previous
			end
			while code >= clear do
				depth = depth + 1
				stack[depth] = suffix[code]
				code = prefix[code]
			end
			first = code
			n = n + 1
			out[n] = code
			for k = depth, 1, -1 do
				n = n + 1
				out[n] = stack[k]
			end
			if next_code < 4096 then
				prefix[next_code] = previous
				suffix[next_code] = first
				next_code = next_code + 1
				if next_code == code_limit and code_size < 12 then
					code_size = code_size + 1
					code_limit = POW2[code_size]
				end
			end
			previous = in_code
		end
	end
	return out, n
end

local INTERLACE_PASSES = { { 0, 8 }, { 4, 8 }, { 2, 4 }, { 1, 2 } }

local function canvas_to_rgba(canvas, width, height)
	local rows = {}
	for y = 0, height - 1 do
		rows[y + 1] = table.concat(canvas, "", y * width + 1, (y + 1) * width)
	end
	return table.concat(rows)
end

local function decode_gif_unchecked(s, max_frames)
	local signature = s:sub(1, 6)
	if signature ~= "GIF89a" and signature ~= "GIF87a" then
		return nil, "gif_decoder: not a GIF"
	end
	local width, height = u16(s, 7), u16(s, 9)
	if width == 0 or height == 0 or width * height > MAX_PIXELS then
		return nil, "gif_decoder: unsupported GIF size " .. width .. "x" .. height
	end
	local packed = s:byte(11)
	local pos = 14
	local global_colors
	if packed >= 128 then
		global_colors, pos = read_color_table(s, pos, POW2[packed % 8 + 1])
	end

	local canvas = {}
	for i = 1, width * height do
		canvas[i] = TRANSPARENT
	end

	local image = { width = width, height = height, loop_count = nil, frames = {} }
	-- From the graphic control extension that precedes each image.
	local delay_cs, transparent_index, disposal = 0, nil, 0

	while true do
		local block = s:byte(pos)
		if block == nil or block == 0x3B then
			break
		elseif block == 0x21 then
			local label = s:byte(pos + 1)
			if label == 0xF9 then
				local flags = s:byte(pos + 3)
				delay_cs = u16(s, pos + 4)
				transparent_index = (flags % 2 == 1) and s:byte(pos + 6) or nil
				disposal = ((flags - flags % 4) / 4) % 8
				pos = pos + 8
			elseif label == 0xFF and s:sub(pos + 3, pos + 13) == "NETSCAPE2.0" then
				local data, after = read_sub_blocks(s, pos + 14)
				if not data then
					return nil, after
				end
				if #data >= 3 and data:byte(1) == 1 then
					image.loop_count = u16(data, 2) -- 0 means forever
				end
				pos = after
			else
				local data, after = read_sub_blocks(s, pos + 2)
				if not data then
					return nil, after
				end
				pos = after
			end
		elseif block == 0x2C then
			local left, top = u16(s, pos + 1), u16(s, pos + 3)
			local frame_width, frame_height = u16(s, pos + 5), u16(s, pos + 7)
			local flags = s:byte(pos + 9)
			pos = pos + 10
			local colors = global_colors
			if flags >= 128 then
				colors, pos = read_color_table(s, pos, POW2[flags % 8 + 1])
			end
			if not colors then
				return nil, "gif_decoder: frame has no color table"
			end
			local interlaced = (flags % 128) >= 64
			local min_code_size = s:byte(pos)
			if not min_code_size or min_code_size < 2 or min_code_size > 11 then
				return nil, "gif_decoder: bad LZW code size"
			end
			local data, after = read_sub_blocks(s, pos + 1)
			if not data then
				return nil, after
			end
			pos = after

			local indices, count = lzw_decode(data, min_code_size, frame_width * frame_height)
			if not indices then
				return nil, count
			end

			local restore
			if disposal == 3 then
				restore = {}
				for i = 1, width * height do
					restore[i] = canvas[i]
				end
			end

			-- Draw the frame's rectangle, clipped to the canvas.
			local source_row = 0
			local function draw_row(y)
				local canvas_y = top + y
				if canvas_y < height then
					local base = canvas_y * width + left
					local source = source_row * frame_width
					for x = 1, frame_width do
						local index = indices[source + x]
						if index ~= nil and index ~= transparent_index and left + x <= width then
							canvas[base + x] = colors[index] or TRANSPARENT
						end
					end
				end
				source_row = source_row + 1
			end
			if interlaced then
				for _, pass in ipairs(INTERLACE_PASSES) do
					for y = pass[1], frame_height - 1, pass[2] do
						draw_row(y)
					end
				end
			else
				for y = 0, frame_height - 1 do
					draw_row(y)
				end
			end

			image.frames[#image.frames + 1] = {
				delay_cs = delay_cs,
				rgba = canvas_to_rgba(canvas, width, height),
			}
			if #image.frames >= max_frames then
				image.truncated = true
				break
			end

			-- Disposal applies before the next frame is drawn.
			if disposal == 2 then
				for y = top, math.min(top + frame_height, height) - 1 do
					local base = y * width
					for x = left + 1, math.min(left + frame_width, width) do
						canvas[base + x] = TRANSPARENT
					end
				end
			elseif disposal == 3 then
				canvas = restore
			end
			delay_cs, transparent_index, disposal = 0, nil, 0
		else
			return nil, string.format("gif_decoder: unknown block 0x%02X at byte %d", block, pos)
		end
	end

	if #image.frames == 0 then
		return nil, "gif_decoder: GIF has no frames"
	end
	return image
end

--- Decodes GIF bytes. Returns the image, or nil and a message for data that is not a
--- usable GIF; it never raises, whatever the bytes are. Image data that ends early keeps
--- the pixels that were read. `opts.max_frames` (default 1000) stops a huge animation
--- and sets `image.truncated`.
function M.decode_gif(s, opts)
	if type(s) ~= "string" or #s < 13 then
		return nil, "gif_decoder: not a GIF"
	end
	local max_frames = opts and opts.max_frames or DEFAULT_MAX_FRAMES
	local ok, image, err = compat.pcall(decode_gif_unchecked, s, max_frames)
	if not ok then
		return nil, "gif_decoder: damaged GIF"
	end
	return image, err
end

return M
