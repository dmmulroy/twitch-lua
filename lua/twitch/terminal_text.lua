-- Text for a terminal: make chat text safe to print, measure how many cells it takes, and
-- split it into the pieces a terminal draws as one unit. No I/O.
--
--   local terminal_text = require("twitch.terminal_text")
--   local safe = terminal_text.sanitize_chat_text(untrusted)      -- no control characters
--   local cells = terminal_text.display_width(safe)
--   for _, cluster in ipairs(terminal_text.split_display_clusters(safe)) do ... end
--
-- Widths follow what a terminal with grapheme clustering does (Rex's does): combining
-- marks, joiners and variation selectors add nothing, CJK and emoji take two cells. No
-- table like this is complete, so callers must not rely on it being exact: draw each row
-- at an absolute position with line wrapping switched off.

local M = {}

local REPLACEMENT_CHARACTER = "\239\191\189" -- U+FFFD

-- Sorted, non-overlapping { first, last } code point ranges.
local ZERO_WIDTH_RANGES = {
	{ 0x0300, 0x036F }, { 0x0483, 0x0489 }, { 0x0591, 0x05BD }, { 0x05BF, 0x05BF }, { 0x05C1, 0x05C2 },
	{ 0x05C4, 0x05C5 }, { 0x05C7, 0x05C7 }, { 0x0610, 0x061A }, { 0x064B, 0x065F }, { 0x0670, 0x0670 },
	{ 0x06D6, 0x06DC }, { 0x06DF, 0x06E4 }, { 0x06E7, 0x06E8 }, { 0x06EA, 0x06ED }, { 0x0900, 0x0902 },
	{ 0x093A, 0x093A }, { 0x093C, 0x093C }, { 0x0941, 0x0948 }, { 0x094D, 0x094D }, { 0x0E31, 0x0E31 },
	{ 0x0E34, 0x0E3A }, { 0x0E47, 0x0E4E }, { 0x1AB0, 0x1AFF }, { 0x1DC0, 0x1DFF }, { 0x200B, 0x200F },
	{ 0x202A, 0x202E }, { 0x2060, 0x2064 }, { 0x20D0, 0x20FF }, { 0x3099, 0x309A }, { 0xFE00, 0xFE0F },
	{ 0xFE20, 0xFE2F }, { 0xFEFF, 0xFEFF }, { 0x1F3FB, 0x1F3FF }, { 0xE0001, 0xE007F }, { 0xE0100, 0xE01EF },
}

local WIDE_RANGES = {
	{ 0x1100, 0x115F }, { 0x231A, 0x231B }, { 0x2329, 0x232A }, { 0x23E9, 0x23EC }, { 0x23F0, 0x23F0 },
	{ 0x23F3, 0x23F3 }, { 0x25FD, 0x25FE }, { 0x2614, 0x2615 }, { 0x2648, 0x2653 }, { 0x267F, 0x267F },
	{ 0x2693, 0x2693 }, { 0x26A1, 0x26A1 }, { 0x26AA, 0x26AB }, { 0x26BD, 0x26BE }, { 0x26C4, 0x26C5 },
	{ 0x26CE, 0x26CE }, { 0x26D4, 0x26D4 }, { 0x26EA, 0x26EA }, { 0x26F2, 0x26F3 }, { 0x26F5, 0x26F5 },
	{ 0x26FA, 0x26FA }, { 0x26FD, 0x26FD }, { 0x2705, 0x2705 }, { 0x270A, 0x270B }, { 0x2728, 0x2728 },
	{ 0x274C, 0x274C }, { 0x274E, 0x274E }, { 0x2753, 0x2755 }, { 0x2757, 0x2757 }, { 0x2795, 0x2797 },
	{ 0x27B0, 0x27B0 }, { 0x27BF, 0x27BF }, { 0x2B1B, 0x2B1C }, { 0x2B50, 0x2B50 }, { 0x2B55, 0x2B55 },
	{ 0x2E80, 0x303E }, { 0x3041, 0x33FF }, { 0x3400, 0x4DBF }, { 0x4E00, 0x9FFF }, { 0xA000, 0xA4CF },
	{ 0xA960, 0xA97F }, { 0xAC00, 0xD7A3 }, { 0xF900, 0xFAFF }, { 0xFE30, 0xFE4F }, { 0xFF00, 0xFF60 },
	{ 0xFFE0, 0xFFE6 }, { 0x1F004, 0x1F004 }, { 0x1F0CF, 0x1F0CF }, { 0x1F18E, 0x1F18E }, { 0x1F191, 0x1F19A },
	{ 0x1F200, 0x1F251 }, { 0x1F300, 0x1F64F }, { 0x1F680, 0x1F6FF }, { 0x1F7E0, 0x1F7EB }, { 0x1F90C, 0x1F9FF },
	{ 0x1FA70, 0x1FAFF }, { 0x20000, 0x3FFFD },
}

local ZERO_WIDTH_JOINER = 0x200D
local VARIATION_SELECTOR_EMOJI = 0xFE0F

local function in_ranges(ranges, code_point)
	local low, high = 1, #ranges
	while low <= high do
		local middle = math.floor((low + high) / 2)
		local range = ranges[middle]
		if code_point < range[1] then
			high = middle - 1
		elseif code_point > range[2] then
			low = middle + 1
		else
			return true
		end
	end
	return false
end

--- Cells one code point takes on its own: 0, 1 or 2.
function M.code_point_width(code_point)
	if code_point < 0x20 or (code_point >= 0x7F and code_point < 0xA0) then
		return 0
	end
	if code_point < 0x300 then
		return 1
	end
	if in_ranges(ZERO_WIDTH_RANGES, code_point) then
		return 0
	end
	if code_point >= 0x1100 and in_ranges(WIDE_RANGES, code_point) then
		return 2
	end
	return 1
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
		if current and (width == 0 or joined_next) and code_point then
			current.text = current.text .. piece
			-- an emoji variation selector makes a narrow symbol emoji-sized
			if code_point == VARIATION_SELECTOR_EMOJI and current.width == 1 then
				current.width = 2
			end
		else
			count = count + 1
			clusters[count] = { text = code_point and piece or REPLACEMENT_CHARACTER, width = width }
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
