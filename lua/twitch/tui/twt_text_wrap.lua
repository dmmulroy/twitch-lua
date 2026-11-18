-- Wraps chat text exactly where twitch-tui (twt) does. twt calls
-- `textwrap::wrap(payload, Options::new(width).initial_indent(prefix))` with textwrap
-- 0.16.2's defaults, so this is a port of those defaults:
--   * words end at Unicode line break opportunities (UAX #14, the unicode-linebreak 0.1.5
--     tables), except after "-" and a soft hyphen;
--   * a word is split after a "-" that sits between letters or digits;
--   * a word wider than a whole line is broken into line-wide pieces;
--   * lines are chosen by "optimal fit": the fewest, most even lines, found with the SMAWK
--     algorithm (smawk 0.3.3), with textwrap's penalties. This is why twt sometimes moves
--     a word down although it would fit.
-- Widths are textwrap's: the sum of each character's width (unicode-width 0.2.2).
--
--   local twt_text_wrap = require("twitch.tui.twt_text_wrap")
--   local lines = twt_text_wrap.wrap_text_like_twt(text, 36, 11)
--   -- { { first = 1, last = 31, penalty = "" }, ... }  byte ranges of `text`, inclusive
--
-- `first_line_indent` is the width twt reserves on the first line for the author prefix
-- (twt counts it in bytes: the byte length of "badges..name" plus 2 for ": ").

local unicode_tables = require("twitch.unicode_tables")
local terminal_text = require("twitch.terminal_text")

local M = {}

-- textwrap's default Penalties.
local NLINE_PENALTY = 1000
local OVERFLOW_PENALTY = 50 * 50
local SHORT_LAST_LINE_FRACTION = 4
local SHORT_LAST_LINE_PENALTY = 25
local HYPHEN_PENALTY = 25

local SOFT_HYPHEN = 0xAD

local function range_value(ranges, code_point, default)
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
	return default
end

--- A character's width as unicode-width 0.2.2 reports it (textwrap's ch_width): 0, 1 or 2.
function M.unicode_character_width(code_point)
	return range_value(unicode_tables.CHARACTER_WIDTH_RANGES, code_point, 1)
end

local function line_break_class(code_point)
	return range_value(unicode_tables.LINE_BREAK_CLASS_RANGES, code_point, 0)
end

-- The characters of `text`: { start byte, end byte, code point }.
local function characters_of(text)
	local characters = {}
	local position, length = 1, #text
	while position <= length do
		local code_point, size = terminal_text.decode_utf8_at(text, position)
		characters[#characters + 1] = { position, position + size - 1, code_point or 0xFFFD }
		position = position + size
	end
	return characters
end

--- Byte positions (1-based) where textwrap may start a new word: unicode-linebreak's
--- break opportunities, without the ones after "-" or a soft hyphen, and without the last.
function M.word_break_positions(text)
	local characters = characters_of(text)
	local positions = {}
	local state, after_zero_width_joiner = unicode_tables.LINE_BREAK_SOT, false
	local pair_table = unicode_tables.LINE_BREAK_PAIR_TABLE
	local count = #characters
	for index = 1, count + 1 do
		local class, byte_position
		if index <= count then
			class, byte_position = line_break_class(characters[index][3]), characters[index][1]
		else
			class, byte_position = unicode_tables.LINE_BREAK_EOT, #text + 1
		end
		local value = pair_table[state + 1][class + 1]
		local mandatory = (value % 128) >= 64
		local is_break = value >= 128 and (not after_zero_width_joiner or mandatory)
		state = value % 64
		after_zero_width_joiner = class == unicode_tables.LINE_BREAK_ZWJ
		if is_break then
			local previous = characters[index - 1]
			local previous_code_point = previous and previous[3]
			if previous_code_point ~= 45 and previous_code_point ~= SOFT_HYPHEN then
				positions[#positions + 1] = byte_position
			end
		end
	end
	positions[#positions] = nil -- textwrap drops the final opportunity
	return positions
end

-- textwrap's display_width: the sum of character widths.
local function textwrap_width(text, first, last)
	local width = 0
	local position = first
	while position <= last do
		local code_point, size = terminal_text.decode_utf8_at(text, position)
		width = width + M.unicode_character_width(code_point or 0xFFFD)
		position = position + size
	end
	return width
end

-- A word: bytes first..word_last are the word, word_last+1..last its trailing spaces.
-- width is the word's width; penalty is "" or "-".
local function new_word(text, first, word_last, last, penalty)
	return {
		first = first,
		word_last = word_last,
		last = last,
		width = textwrap_width(text, first, word_last),
		whitespace = last - word_last,
		penalty = penalty or "",
	}
end

-- textwrap's Word::from: the trailing spaces are the word's whitespace.
local function word_from_range(text, first, last)
	local word_last = last
	while word_last >= first and text:byte(word_last) == 32 do
		word_last = word_last - 1
	end
	return new_word(text, first, word_last, last)
end

local function find_words(text)
	local words = {}
	local start = 1
	for _, position in ipairs(M.word_break_positions(text)) do
		words[#words + 1] = word_from_range(text, start, position - 1)
		start = position
	end
	if start <= #text then
		words[#words + 1] = word_from_range(text, start, #text)
	end
	return words
end

-- Rust's char::is_alphanumeric, from the generated table.
local function is_alphanumeric(code_point)
	return code_point ~= nil and range_value(unicode_tables.ALPHANUMERIC_RANGES, code_point, 0) == 1
end

-- textwrap's HyphenSplitter: split after a "-" between two letters or digits.
local function split_words_at_hyphens(text, words)
	local split = {}
	for _, word in ipairs(words) do
		local points = {}
		local position = word.first
		while position <= word.word_last do
			if text:byte(position) == 45 then
				local before
				if position > word.first then
					-- the character before may be several bytes long
					local back = position - 1
					while back > word.first and text:byte(back) >= 0x80 and text:byte(back) < 0xC0 do
						back = back - 1
					end
					before = terminal_text.decode_utf8_at(text, back)
				end
				local after = position < word.word_last and terminal_text.decode_utf8_at(text, position + 1) or nil
				if is_alphanumeric(before) and is_alphanumeric(after) then
					points[#points + 1] = position + 1
				end
			end
			position = position + 1
		end
		local previous = word.first
		for _, point in ipairs(points) do
			-- the piece ends in "-", so it needs no extra hyphen
			split[#split + 1] = new_word(text, previous, point - 1, point - 1, "")
			previous = point
		end
		if previous <= word.word_last or previous == word.first then
			local piece = new_word(text, previous, word.word_last, word.last, word.penalty)
			split[#split + 1] = piece
		end
	end
	return split
end

-- textwrap's break_words: a word wider than `line_width` is cut into pieces that fit.
local function break_long_words(text, words, line_width)
	local out = {}
	for _, word in ipairs(words) do
		if word.width > line_width then
			local offset, width = word.first, 0
			local position = word.first
			while position <= word.word_last do
				local code_point, size = terminal_text.decode_utf8_at(text, position)
				local character_width = M.unicode_character_width(code_point or 0xFFFD)
				if width > 0 and width + character_width > line_width then
					out[#out + 1] = { first = offset, word_last = position - 1, last = position - 1, width = width, whitespace = 0, penalty = "" }
					offset, width = position, character_width
				else
					width = width + character_width
				end
				position = position + size
			end
			if offset <= word.word_last then
				out[#out + 1] = { first = offset, word_last = word.word_last, last = word.last, width = width, whitespace = word.whitespace, penalty = word.penalty }
			end
		else
			out[#out + 1] = word
		end
	end
	return out
end

-- smawk 0.3.3's smawk_inner, with 0-based indices kept as they are in Rust.
local function smawk_inner(matrix, rows, rows_start, rows_end, cols, cols_start, cols_end, minima)
	if cols_start == cols_end then
		return
	end
	local cols_len = cols_end - cols_start
	local stack_start = rows_end
	local odd_cols_start = cols_end
	local odd_cols_len = math.floor(cols_len / 2)

	local stack_len = 0
	for index = rows_start, rows_end - 1 do
		local row = rows[index]
		while stack_len > 0 do
			local stack_top = rows[stack_start + stack_len - 1]
			local col = cols[cols_start + stack_len - 1]
			if matrix(stack_top, col) > matrix(row, col) then
				stack_len = stack_len - 1
			else
				break
			end
		end
		if stack_len < cols_len then
			rows[stack_start + stack_len] = row
			stack_len = stack_len + 1
		end
	end

	for index = 0, odd_cols_len - 1 do
		cols[odd_cols_start + index] = cols[cols_start + 2 * index + 1]
	end

	smawk_inner(matrix, rows, stack_start, stack_start + stack_len, cols, odd_cols_start, odd_cols_start + odd_cols_len, minima)

	local r = 0
	for c = 0, cols_len - 1 do
		if c % 2 == 0 then
			local col = cols[cols_start + c]
			local row = rows[stack_start + r]
			local last_row
			if c == cols_len - 1 then
				last_row = rows[stack_start + stack_len - 1]
			else
				last_row = minima[cols[cols_start + c + 1]]
			end
			local best_value, best_row = matrix(row, col), row
			while row ~= last_row and r < stack_len - 1 do
				r = r + 1
				row = rows[stack_start + r]
				local value = matrix(row, col)
				-- Rust compares the tuples (value, row)
				if value < best_value or (value == best_value and row < best_row) then
					best_value, best_row = value, row
				end
			end
			minima[col] = best_row
		end
	end
end

-- smawk 0.3.3's online_column_minima. result[j] = { row, value }, 0-based.
local function online_column_minima(initial, size, matrix)
	local result = { [0] = { 0, initial } }
	local result_length = 1
	local finished, base, tentative = 0, 0, 0
	local function m(i, j)
		return matrix(result, i, j)
	end
	local rows, cols, minima = {}, {}, {}
	while finished < size - 1 do
		local i = finished + 1
		if i > tentative then
			local rows_end = finished + 1 - base
			for index = 0, rows_end - 1 do
				rows[index] = base + index
			end
			tentative = math.min(finished + rows_end, size - 1)
			local cols_end = tentative - finished
			for index = 0, cols_end - 1 do
				cols[index] = finished + 1 + index
			end
			smawk_inner(m, rows, 0, rows_end, cols, 0, cols_end, minima)
			for col = finished + 1, tentative do
				local row = minima[col]
				local value = m(row, col)
				if col >= result_length then
					result[col] = { row, value }
					result_length = result_length + 1
				elseif value < result[col][2] then
					result[col] = { row, value }
				end
			end
			finished = i
		else
			local diagonal = m(i - 1, i)
			if diagonal < result[i][2] then
				result[i] = { i - 1, diagonal }
				base, tentative, finished = i - 1, i, i
			elseif m(i - 1, tentative) >= result[tentative][2] then
				finished = i
			else
				base, tentative, finished = i - 1, i, i
			end
		end
	end
	return result
end

-- textwrap 0.16.2's wrap_optimal_fit. `words` is 1-based; returns { { first, last } }
-- indices into it, one per line.
local function wrap_optimal_fit(words, line_widths)
	local count = #words
	local default_line_width = line_widths[#line_widths]
	local widths = { [0] = 0 }
	for index = 1, count do
		local word = words[index]
		widths[index] = widths[index - 1] + word.width + word.whitespace
	end
	local line_numbers = { [0] = 0 }
	local line_numbers_length = 1
	local function line_number_of(i, minima)
		while line_numbers_length < i + 1 do
			local position = line_numbers_length
			line_numbers[position] = 1 + line_number_of(minima[position][1], minima)
			line_numbers_length = line_numbers_length + 1
		end
		return line_numbers[i]
	end

	local minima = online_column_minima(0, count + 1, function(minima, i, j)
		local line_number = line_number_of(i, minima)
		local line_width = line_widths[line_number + 1] or default_line_width
		local target_width = math.max(line_width, 1)
		local last_word = words[j] -- fragments[j - 1] in Rust's 0-based terms
		local width = widths[j] - widths[i] - last_word.whitespace + (last_word.penalty ~= "" and 1 or 0)
		local cost = minima[i][2] + NLINE_PENALTY
		if width > target_width then
			cost = cost + (width - target_width) * OVERFLOW_PENALTY
		elseif j < count then
			local gap = target_width - width
			cost = cost + gap * gap
		elseif i + 1 == j and width < target_width / SHORT_LAST_LINE_FRACTION then
			cost = cost + SHORT_LAST_LINE_PENALTY
		end
		if last_word.penalty ~= "" then
			cost = cost + HYPHEN_PENALTY
		end
		return cost
	end)

	local lines = {}
	local position = count
	while true do
		local previous = minima[position][1]
		table.insert(lines, 1, { first = previous + 1, last = position })
		position = previous
		if position == 0 then
			break
		end
	end
	return lines
end

--- Wraps `text` as twt does for a chat line `width` cells wide whose first line starts
--- after `first_line_indent` cells. `word_width_floor(first, last)` may raise the width
--- of a word (an emote drawn wider than its name, a character this terminal draws wider)
--- so that no line can come out wider than `width`.
--- Returns the lines as { first, last, penalty } byte ranges of `text` (last < first for
--- an empty line); `penalty` is "-" when the line ends inside a hyphenated word.
function M.wrap_text_like_twt(text, width, first_line_indent, word_width_floor)
	local line_widths = { math.max(0, width - first_line_indent), width }
	local words = split_words_at_hyphens(text, find_words(text))
	words = break_long_words(text, words, line_widths[2])
	if word_width_floor then
		for _, word in ipairs(words) do
			word.width = math.max(word.width, word_width_floor(word.first, word.word_last))
		end
	end
	-- twt always has a prefix, so textwrap puts an empty word first: a long first word can
	-- then move to the second line instead of being squeezed beside the name.
	table.insert(words, 1, { first = 1, word_last = 0, last = 0, width = 0, whitespace = 0, penalty = "" })

	local lines = {}
	for _, line in ipairs(wrap_optimal_fit(words, line_widths)) do
		local first_word, last_word = words[line.first], words[line.last]
		local first = first_word.first
		-- an empty first word sits before the text; the line starts at the next word
		for index = line.first, line.last do
			if words[index].last >= words[index].first then
				first = words[index].first
				break
			end
		end
		lines[#lines + 1] = { first = first, last = last_word.word_last, penalty = last_word.penalty }
	end
	return lines
end

return M
