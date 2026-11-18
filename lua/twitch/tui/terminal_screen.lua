-- The escape sequences a chat pane writes: cursor movement, clearing, terminal modes and
-- the colors of each span style. Only builds strings.
--
--   local terminal_screen = require("twitch.tui.terminal_screen")
--   write(terminal_screen.move_cursor(3, 1) .. terminal_screen.styled_span_text(span))

local M = {}

local ESC = string.char(27)
M.ESC = ESC

M.CLEAR_SCREEN = ESC .. "[2J"
-- Rows are cleared before they are written, never after: with line wrapping off, the
-- cursor stays on the last column after a full-width row, and clearing "to the end of the
-- line" from there would erase the character just written.
M.CLEAR_LINE = ESC .. "[2K"
M.RESET_STYLE = ESC .. "[0m"
M.HIDE_CURSOR = ESC .. "[?25l"
M.SHOW_CURSOR = ESC .. "[?25h"

-- Mode 2026: the terminal holds the screen until the update ends, so a redraw never shows half-done.
M.BEGIN_SYNCHRONIZED_UPDATE = ESC .. "[?2026h"
M.END_SYNCHRONIZED_UPDATE = ESC .. "[?2026l"

--- Written once when a pane starts: its own screen, no line wrapping (a row that is
--- wider than expected is cut off instead of pushing other rows down), mouse wheel
--- reports and bracketed paste.
M.ENTER_CHAT_SCREEN = ESC .. "[?1049h" .. ESC .. "[?7l" .. ESC .. "[?1000h" .. ESC .. "[?1006h" .. ESC .. "[?2004h" .. M.CLEAR_SCREEN
--- Undoes ENTER_CHAT_SCREEN.
M.LEAVE_CHAT_SCREEN = ESC .. "[?2004l" .. ESC .. "[?1006l" .. ESC .. "[?1000l" .. ESC .. "[?7h" .. M.SHOW_CURSOR .. ESC .. "[?1049l"

--- Moves the cursor; row and column start at 1.
function M.move_cursor(row, column)
	return ESC .. "[" .. row .. ";" .. column .. "H"
end

-- SGR parameters per span style. Palette colors (31-36) follow the terminal's theme.
local STYLE_PARAMETERS = {
	text = nil,
	name = "1",
	action = "3",
	mention = "1",
	self_mention = "1;33",
	cheer = "1;35",
	notice = "35",
	deleted = "2;3",
	status_info = "2",
	status_warn = "33",
	status_error = "31",
	marker = "33",
	prompt = "2",
	placeholder = "2;3",
	bar = "2",
	bar_joined = "32",
	bar_warn = "33",
	bar_error = "31",
	bar_unseen = "1;36",
}

local function color_parameters(color)
	local red, green, blue = tostring(color):match("^#(%x%x)(%x%x)(%x%x)$")
	if not red then
		return nil
	end
	return "38;2;" .. tonumber(red, 16) .. ";" .. tonumber(green, 16) .. ";" .. tonumber(blue, 16)
end

--- The text of a span wrapped in its style's colors. `span` is { text, style, color }.
function M.styled_span_text(span)
	local parameters = STYLE_PARAMETERS[span.style]
	local color = span.color and color_parameters(span.color)
	if color then
		parameters = parameters and (parameters .. ";" .. color) or color
	end
	if not parameters then
		return span.text
	end
	return ESC .. "[" .. parameters .. "m" .. span.text .. M.RESET_STYLE
end

return M
