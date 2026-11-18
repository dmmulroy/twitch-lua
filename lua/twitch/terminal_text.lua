-- Text for a terminal: make chat text safe to print, measure how many cells it takes, and
-- split it into the pieces a terminal draws as one unit. No I/O.
--
--   local terminal_text = require("twitch.terminal_text")
--   local safe = terminal_text.sanitize_chat_text(untrusted)      -- no control characters
--   local cells = terminal_text.display_width(safe)
--   for _, cluster in ipairs(terminal_text.split_display_clusters(safe)) do ... end
--
-- Widths follow what a terminal with grapheme clustering does (Rex's does): combining
-- marks, joiners and variation selectors add nothing, CJK and emoji take two cells, and an
-- emoji with its modifiers, or a flag, is one unit. No table like this matches every
-- terminal, so callers must not rely on it being exact: draw each row at an absolute
-- position with line wrapping switched off.

local M = {}

local REPLACEMENT_CHARACTER = "\239\191\189" -- U+FFFD

local unicode_tables = require("twitch.unicode_tables")

local ZERO_WIDTH_JOINER = 0x200D
local VARIATION_SELECTOR_EMOJI = 0xFE0F
local REGIONAL_INDICATOR_FIRST, REGIONAL_INDICATOR_LAST = 0x1F1E6, 0x1F1FF
local EMOJI_MODIFIER_FIRST, EMOJI_MODIFIER_LAST = 0x1F3FB, 0x1F3FF

local function unicode_width(code_point)
	local ranges = unicode_tables.CHARACTER_WIDTH_RANGES
	local low, high = 1, #ranges
	while low <= high do
		local middle = math.floor((low + high) / 2)
		local range = ranges[middle]
		if code_point < range[1] then
			high = middle - 1
		elseif code_point > range[2] then
			low = middle + 1
		else
			return range[3]
		end
	end
	return 1
end

--- Cells one code point takes on its own: 0, 1 or 2, from unicode-width 0.2.2 (the table
--- twt's ratatui uses). Skin-tone modifiers count 0: they join the emoji before them.
function M.code_point_width(code_point)
	if code_point < 0x20 or (code_point >= 0x7F and code_point < 0xA0) then
		return 0
	end
	if code_point < 0x300 then
		return 1
	end
	if code_point >= EMOJI_MODIFIER_FIRST and code_point <= EMOJI_MODIFIER_LAST then
		return 0
	end
	return unicode_width(code_point)
end

-- Decodes the UTF-8 sequence at `position`. Returns the code point and the sequence's
-- length, or nil and 1 for a byte that is not valid UTF-8.
local function decode_utf8_at(text, position)
	local first = text:byte(position)
	if first < 0x80 then
		return first, 1
	end
	local length, code_point
	if first >= 0xC2 and first <= 0xDF then
		length, code_point = 2, first - 0xC0
	elseif first >= 0xE0 and first <= 0xEF then
		length, code_point = 3, first - 0xE0
	elseif first >= 0xF0 and first <= 0xF4 then
		length, code_point = 4, first - 0xF0
	else
		return nil, 1
	end
	for offset = 1, length - 1 do
		local continuation = text:byte(position + offset)
		if not continuation or continuation < 0x80 or continuation > 0xBF then
			return nil, 1
		end
		code_point = code_point * 64 + (continuation - 0x80)
	end
	if (length == 3 and (code_point < 0x800 or (code_point >= 0xD800 and code_point <= 0xDFFF)))
		or (length == 4 and (code_point < 0x10000 or code_point > 0x10FFFF)) then
		return nil, 1
	end
	return code_point, length
end

--- Makes untrusted text safe to write to a terminal: control characters (including ESC)
--- become spaces or are dropped, and bytes that are not valid UTF-8 become U+FFFD. Chat text
--- must go through this before it is drawn.
function M.sanitize_chat_text(text)
	local out, count = {}, 0
	local position, length = 1, #text
	while position <= length do
		local code_point, size = decode_utf8_at(text, position)
		count = count + 1
		if not code_point then
			out[count] = REPLACEMENT_CHARACTER
		elseif code_point == 0x09 or code_point == 0x0A or code_point == 0x0D then
			out[count] = " "
		elseif code_point < 0x20 or (code_point >= 0x7F and code_point < 0xA0) then
			out[count] = ""
		else
			out[count] = text:sub(position, position + size - 1)
		end
		position = position + size
	end
	return table.concat(out)
end

--- Splits text into display clusters: each is what the terminal draws as one unit (a
--- letter with its accents, an emoji with its modifiers). Returns a list of
--- { text = "...", width = 0 | 1 | 2 }. The text should already be sanitized.
function M.split_display_clusters(text)
	local clusters, count = {}, 0
	local position, length = 1, #text
	local joined_next = false -- the previous code point was a zero-width joiner
	while position <= length do
		local code_point, size = decode_utf8_at(text, position)
		local piece = text:sub(position, position + size - 1)
		local width = code_point and M.code_point_width(code_point) or 1
		local current = clusters[count]
		-- the second of two regional indicators makes one flag with the first
		local completes_flag = current and current.flag_half and code_point
			and code_point >= REGIONAL_INDICATOR_FIRST and code_point <= REGIONAL_INDICATOR_LAST
		if completes_flag then
			current.text = current.text .. piece
			current.flag_half = nil
		elseif current and (width == 0 or joined_next) and code_point then
			current.text = current.text .. piece
			-- an emoji variation selector makes a narrow symbol emoji-sized
			if code_point == VARIATION_SELECTOR_EMOJI and current.width == 1 then
				current.width = 2
			end
		else
			count = count + 1
			clusters[count] = { text = code_point and piece or REPLACEMENT_CHARACTER, width = width }
			if code_point and code_point >= REGIONAL_INDICATOR_FIRST and code_point <= REGIONAL_INDICATOR_LAST then
				clusters[count].flag_half = true
			end
		end
		joined_next = code_point == ZERO_WIDTH_JOINER
		position = position + size
	end
	return clusters
end

--- How many terminal cells the text takes.
function M.display_width(text)
	local width = 0
	for _, cluster in ipairs(M.split_display_clusters(text)) do
		width = width + cluster.width
	end
	return width
end

--- The longest prefix of the text that fits in `max_width` cells, and its width.
function M.truncate_to_width(text, max_width)
	local out, width = {}, 0
	for _, cluster in ipairs(M.split_display_clusters(text)) do
		if width + cluster.width > max_width then
			break
		end
		width = width + cluster.width
		out[#out + 1] = cluster.text
	end
	return table.concat(out), width
end

--- Encodes one code point as UTF-8.
function M.utf8_from_code_point(code_point)
	if code_point < 0x80 then
		return string.char(code_point)
	elseif code_point < 0x800 then
		return string.char(0xC0 + math.floor(code_point / 64), 0x80 + code_point % 64)
	elseif code_point < 0x10000 then
		return string.char(0xE0 + math.floor(code_point / 4096), 0x80 + math.floor(code_point / 64) % 64, 0x80 + code_point % 64)
	end
	return string.char(
		0xF0 + math.floor(code_point / 262144),
		0x80 + math.floor(code_point / 4096) % 64,
		0x80 + math.floor(code_point / 64) % 64,
		0x80 + code_point % 64
	)
end

M.decode_utf8_at = decode_utf8_at

return M
