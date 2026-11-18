-- Turns the raw bytes a terminal sends for key presses into key events. No I/O.
--
--   local terminal_keys = require("twitch.tui.terminal_keys")
--   local parser = terminal_keys.new_key_parser()
--   for _, key in ipairs(parser:parse_key_bytes(bytes)) do ... end
--
-- Key events:
--   { key = "text", text = "é" }        printable input, one or more characters
--   { key = "paste", text = "..." }     a bracketed paste, control characters removed
--   { key = "enter" | "backspace" | "delete" | "tab" | "escape" }
--   { key = "up" | "down" | "left" | "right" | "home" | "end" | "pageup" | "pagedown" }
--   { key = "word_left" | "word_right" | "delete_word" }      Alt-B/F, Alt-Backspace, Ctrl-arrows
--   { key = "ctrl", char = "c" }        Ctrl with a letter
--   { key = "scroll_up" | "scroll_down" }                     mouse wheel (SGR mouse mode)
-- Input that ends mid-sequence is kept until the next call. A lone ESC at the end of a
-- chunk is the Escape key.

local terminal_text = require("twitch.terminal_text")

local M = {}

local ESC = string.char(27)
local PASTE_START = ESC .. "[200~"
local PASTE_END = ESC .. "[201~"
local MAX_PENDING_BYTES = 64 * 1024

-- tonumber(nil) raises in Rex's Lua, and a failed string.match returns nil.
local function number_or_nil(text)
	if text == nil then
		return nil
	end
	return tonumber(text)
end

-- Final byte of a CSI sequence -> key, for sequences with no or default parameters.
local CSI_LETTER_KEYS = { A = "up", B = "down", C = "right", D = "left", H = "home", F = "end" }
-- "ESC [ <number> ~" keys.
local CSI_TILDE_KEYS = { ["1"] = "home", ["3"] = "delete", ["4"] = "end", ["5"] = "pageup", ["6"] = "pagedown", ["7"] = "home", ["8"] = "end" }

local Parser = {}
Parser.__index = Parser

--- Creates a parser; keep one per terminal.
function M.new_key_parser()
	return setmetatable({ pending = "", in_paste = false, paste_parts = nil }, Parser)
end

local function emit_text(keys, text)
	local last = keys[#keys]
	if last and last.key == "text" then
		last.text = last.text .. text
	else
		keys[#keys + 1] = { key = "text", text = text }
	end
end

-- Parses a CSI sequence starting at `start` (the ESC). Returns the next position, or nil
-- when the sequence is not complete yet.
local function parse_csi(buffer, start, keys)
	local finish = buffer:find("[@-~]", start + 2)
	if not finish then
		return nil
	end
	local parameters = buffer:sub(start + 2, finish - 1)
	local final = buffer:sub(finish, finish)
	if final == "~" then
		local number = parameters:match("^(%d+)")
		local key = CSI_TILDE_KEYS[number or ""]
		if key then
			keys[#keys + 1] = { key = key }
		end
	elseif (final == "M" or final == "m") and parameters:sub(1, 1) == "<" then
		-- SGR mouse: ESC [ < button ; x ; y M. Buttons 64 and 65 are the wheel.
		local button = number_or_nil(parameters:match("^<(%d+)"))
		if final == "M" and button then
			local base = button % 128 -- drop modifier bits above the wheel bit
			if base == 64 or base == 68 or base == 72 or base == 80 then
				keys[#keys + 1] = { key = "scroll_up" }
			elseif base == 65 or base == 69 or base == 73 or base == 81 then
				keys[#keys + 1] = { key = "scroll_down" }
			end
		end
	elseif CSI_LETTER_KEYS[final] then
		local modifier = number_or_nil(parameters:match(";(%d+)$"))
		local key = CSI_LETTER_KEYS[final]
		-- modifier 5 is Ctrl, 3 is Alt: with left/right they move by a word
		if (modifier == 5 or modifier == 3) and (key == "left" or key == "right") then
			key = "word_" .. key
		end
		keys[#keys + 1] = { key = key }
	elseif final == "Z" then
		keys[#keys + 1] = { key = "backtab" }
	end
	-- anything else (focus reports, replies to queries) is ignored
	return finish + 1
end

--- Parses a chunk of input and returns the key events it completes.
function Parser:parse_key_bytes(bytes)
	local keys = {}
	local buffer = self.pending .. bytes
	self.pending = ""
	local position, length = 1, #buffer

	while position <= length do
		if self.in_paste then
			local finish = buffer:find(PASTE_END, position, true)
			if not finish then
				-- The chunk may end partway through the end marker: keep that part for later.
				local keep = 0
				for size = math.min(#PASTE_END - 1, length - position + 1), 1, -1 do
					if buffer:sub(length - size + 1) == PASTE_END:sub(1, size) then
						keep = size
						break
					end
				end
				self.paste_parts[#self.paste_parts + 1] = buffer:sub(position, length - keep)
				self.pending = buffer:sub(length - keep + 1)
				return keys
			end
			self.paste_parts[#self.paste_parts + 1] = buffer:sub(position, finish - 1)
			keys[#keys + 1] = { key = "paste", text = terminal_text.sanitize_chat_text(table.concat(self.paste_parts)) }
			self.in_paste, self.paste_parts = false, nil
			position = finish + #PASTE_END
		else
			local byte = buffer:byte(position)
			if byte == 27 then
				local next_byte = buffer:byte(position + 1)
				if next_byte == nil then
					keys[#keys + 1] = { key = "escape" }
					position = position + 1
				elseif next_byte == 91 then -- "[": CSI
					if buffer:sub(position, position + #PASTE_START - 1) == PASTE_START then
						self.in_paste, self.paste_parts = true, {}
						position = position + #PASTE_START
					else
						local next_position = parse_csi(buffer, position, keys)
						if not next_position then
							self.pending = buffer:sub(position)
							break
						end
						position = next_position
					end
				elseif next_byte == 79 then -- "O": SS3, application cursor keys
					local final = buffer:sub(position + 2, position + 2)
					if final == "" then
						self.pending = buffer:sub(position)
						break
					end
					if CSI_LETTER_KEYS[final] then
						keys[#keys + 1] = { key = CSI_LETTER_KEYS[final] }
					end
					position = position + 3
				elseif next_byte == 127 or next_byte == 8 then
					keys[#keys + 1] = { key = "delete_word" }
					position = position + 2
				elseif next_byte == 98 then -- Alt-b
					keys[#keys + 1] = { key = "word_left" }
					position = position + 2
				elseif next_byte == 102 then -- Alt-f
					keys[#keys + 1] = { key = "word_right" }
					position = position + 2
				elseif next_byte == 27 then
					keys[#keys + 1] = { key = "escape" }
					position = position + 1
				else
					-- Alt with some other key: ignore the pair
					position = position + 2
				end
			elseif byte == 13 or byte == 10 then
				keys[#keys + 1] = { key = "enter" }
				position = position + 1
			elseif byte == 127 or byte == 8 then
				keys[#keys + 1] = { key = "backspace" }
				position = position + 1
			elseif byte == 9 then
				keys[#keys + 1] = { key = "tab" }
				position = position + 1
			elseif byte < 32 then
				if byte >= 1 and byte <= 26 then
					keys[#keys + 1] = { key = "ctrl", char = string.char(byte + 96) }
				end
				position = position + 1
			else
				local code_point, size = terminal_text.decode_utf8_at(buffer, position)
				if not code_point and byte >= 0xC2 and byte <= 0xF4 and position + 3 > length then
					-- possibly a character split across chunks
					local needed = (byte >= 0xF0 and 4) or (byte >= 0xE0 and 3) or 2
					if length - position + 1 < needed then
						self.pending = buffer:sub(position)
						break
					end
				end
				if code_point and (code_point < 0x80 or code_point >= 0xA0) then
					emit_text(keys, buffer:sub(position, position + size - 1))
				end
				position = position + size
			end
		end
	end

	if #self.pending > MAX_PENDING_BYTES then
		self.pending = ""
	end
	return keys
end

return M
