-- One chat pane, drawn like twitch-tui (twt): a bordered chat box whose top edge shows the
-- time and channel, and under it a bordered input box. It takes key bytes, event log bytes
-- and size changes, and writes the screen through `write`. No I/O of its own, so it runs in
-- tests against a fake terminal.
--
--   local chat_pane = require("twitch.tui.chat_pane")
--   local pane = chat_pane.new_chat_pane({
--     write = function(bytes) io.write(bytes) io.flush() end,
--     columns = 40, rows = 50, channel = "dillon", own_login = "dillon",
--     send_message = function(text) return true end,            -- or nil, "why it failed"
--     run_command = function(line) return { level = "info", text = "done" } end,
--     on_quit = function() end,
--     clock_text = function() return "Wed Nov 18 08:44:10 2026" end,   -- optional
--   })
--   pane:start()
--   pane:handle_key_bytes(bytes)          -- from the terminal, raw mode
--   pane:handle_event_log_bytes(bytes)    -- from `tail -F` on the event log
--   pane:handle_resize(columns, rows)
--   pane:render_title()                   -- once a second, for the clock
--
-- Screen (n rows):
--   1        ┌[ Time: Wed Nov 18 08:44:10 2026 ] [ Channel: dillon ]──┐
--   2..n-4   │ the feed, newest at the bottom                          │
--   n-3      └──────────────────────────────────────────[ 3 new ]┘   (while scrolled up)
--   n-2      ┌[ Chat ]─────────────────────────────────────────────┐  green, red when empty
--   n-1      │ the line being typed                                │
--   n        └[ 12 / 500 ]─────────────────────────────────────────┘
-- Keys: Enter sends; Up/Down recall sent messages; PageUp/PageDown and the mouse wheel
-- scroll; Esc returns to the newest message; Ctrl-L redraws; Ctrl-C quits.

local chat_events = require("twitch.chat_events")
local chat_feed_layout = require("twitch.tui.chat_feed_layout")
local chat_store = require("twitch.chat_store")
local message_input = require("twitch.tui.message_input")
local terminal_keys = require("twitch.tui.terminal_keys")
local terminal_screen = require("twitch.tui.terminal_screen")
local terminal_text = require("twitch.terminal_text")

local M = {}

local WHEEL_SCROLL_ROWS = 3
-- Below this the boxes do not fit, and only the line being typed is drawn.
local MIN_BOXED_COLUMNS = 8
local MIN_BOXED_ROWS = 6
local MIN_COLUMNS = 2
local INPUT_TITLE = "Chat"
local WEEKDAY_NAMES = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTH_NAMES = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- The current time in twt's format ("%a %b %e %T %Y": "Wed Nov 18 08:44:10 2026").
--- Built by hand: Rex's os.date gets %a wrong and does not know %e or %T.
function M.twt_clock_text(epoch_seconds)
	local date = os.date("*t", epoch_seconds or os.time())
	return string.format(
		"%s %s %2d %02d:%02d:%02d %d",
		WEEKDAY_NAMES[date.wday], MONTH_NAMES[date.month], date.day, date.hour, date.min, date.sec, date.year
	)
end

local Pane = {}
Pane.__index = Pane

--- Creates a chat pane. Nothing is written until start().
function M.new_chat_pane(opts)
	assert(type(opts.write) == "function", "chat_pane: write is required")
	return setmetatable({
		write = opts.write,
		columns = opts.columns or 80,
		rows = opts.rows or 24,
		channel = opts.channel,
		own_login = opts.own_login,
		send_message = opts.send_message or function()
			return nil, "Sending is not set up"
		end,
		run_command = opts.run_command or function()
			return { level = "error", text = "Commands are not set up" }
		end,
		on_quit = opts.on_quit or function() end,
		clock_text = opts.clock_text or M.twt_clock_text,
		-- Optional emote images (twitch.tui.emote_images): revision, emote_columns(request),
		-- draw_emote(request), and optionally begin_render() and end_render().
		emotes = opts.emotes,
		store = chat_store.new_chat_store({ max_entries = opts.max_messages }),
		view = chat_feed_layout.new_chat_feed_view(),
		input = message_input.new_message_input(),
		key_parser = terminal_keys.new_key_parser(),
		event_log_remainder = "", -- an event log line that has not ended yet
		started = false,
	}, Pane)
end

local function is_boxed(self)
	return self.columns >= MIN_BOXED_COLUMNS and self.rows >= MIN_BOXED_ROWS
end

-- Rows of feed inside the chat box: everything but the two box borders and the input box.
local function feed_height(self)
	return is_boxed(self) and (self.rows - 5) or 0
end

-- twt wraps one cell short of the box's inside.
local function feed_width(self)
	return math.max(1, self.columns - 3)
end

local function layout_options(self)
	local emotes = self.emotes
	return {
		own_login = self.own_login,
		emote_revision = emotes and emotes.revision or 0,
		resolve_emote = emotes and function(request)
			return emotes:emote_columns(request)
		end or nil,
	}
end

local function feed_row_output(self, row)
	local parts = {}
	for index, span in ipairs(row) do
		if span.emote and self.emotes then
			parts[index] = self.emotes:draw_emote(span.emote)
		else
			parts[index] = terminal_screen.styled_span_text(span)
		end
	end
	return table.concat(parts)
end

-- Spans laid along a box edge from its corner: what fits in `width` cells, then the edge
-- line. Returns the text and its width.
local function edge_with_title(spans, width, edge_style)
	local out, used = {}, 0
	for _, span in ipairs(spans) do
		if used >= width then
			break
		end
		local text, text_width = terminal_text.truncate_to_width(span.text, width - used)
		if text_width > 0 then
			out[#out + 1] = terminal_screen.styled_span_text({ text = text, style = span.style })
			used = used + text_width
		end
	end
	if used < width then
		out[#out + 1] = terminal_screen.styled_span_text({ text = string.rep(terminal_screen.BOX_HORIZONTAL, width - used), style = edge_style })
	end
	return table.concat(out)
end

-- twt's title pieces: "[ Label: value ]" with the label in the title style.
local function title_spans(pieces, label_style)
	local spans = {}
	for index, piece in ipairs(pieces) do
		spans[#spans + 1] = { text = (index == 1 and "" or " ") .. "[ " }
		spans[#spans + 1] = { text = piece[1], style = label_style }
		spans[#spans + 1] = { text = (piece[2] and (": " .. piece[2]) or "") .. " ]" }
	end
	return spans
end

local function chat_box_top_output(self)
	local spans = title_spans({ { "Time", self.clock_text() }, { "Channel", tostring(self.channel or "?") } }, "title_label")
	return terminal_screen.BOX_TOP_LEFT .. edge_with_title(spans, self.columns - 2) .. terminal_screen.BOX_TOP_RIGHT
end

-- The bottom edge of the chat box; while scrolled up it says so on the right, as twt's
-- scroll offset does.
local function chat_box_bottom_output(self)
	local inner = self.columns - 2
	local note
	if self.view.unseen_entries > 0 then
		note = self.view.unseen_entries .. " new"
	elseif self.view.scroll_offset > 0 then
		note = "Scrolled"
	end
	local spans = note and title_spans({ { note } }, "title_label") or {}
	local note_width = 0
	for _, span in ipairs(spans) do
		note_width = note_width + terminal_text.display_width(span.text)
	end
	if note_width == 0 or note_width > inner then
		return terminal_screen.BOX_BOTTOM_LEFT .. string.rep(terminal_screen.BOX_HORIZONTAL, inner) .. terminal_screen.BOX_BOTTOM_RIGHT
	end
	local out = { terminal_screen.BOX_BOTTOM_LEFT, string.rep(terminal_screen.BOX_HORIZONTAL, inner - note_width) }
	for _, span in ipairs(spans) do
		out[#out + 1] = terminal_screen.styled_span_text(span)
	end
	out[#out + 1] = terminal_screen.BOX_BOTTOM_RIGHT
	return table.concat(out)
end

-- twt's input check: something to send, and no more than Twitch accepts.
local function input_is_sendable(self)
	local count = #self.input.clusters
	return count > 0 and count <= self.input.max_characters
end

-- The three rows of the input box, and the cursor's column.
local function input_box_output(self)
	local valid = input_is_sendable(self)
	local border_style = valid and "input_valid" or "input_invalid"
	local title_style = valid and "input_title_valid" or "input_title_invalid"
	local inner = self.columns - 2
	local top = terminal_screen.styled_span_text({ text = terminal_screen.BOX_TOP_LEFT, style = border_style })
		.. edge_with_title(title_spans({ { INPUT_TITLE } }, title_style), inner, border_style)
		.. terminal_screen.styled_span_text({ text = terminal_screen.BOX_TOP_RIGHT, style = border_style })

	-- one cell spare on the right, so the cursor never sits on the border
	local visible, cursor = self.input:visible_window(math.max(1, inner - 1))
	local padding = inner - terminal_text.display_width(visible)
	local side = terminal_screen.styled_span_text({ text = terminal_screen.BOX_VERTICAL, style = border_style })
	local middle = side .. visible .. string.rep(" ", math.max(0, padding)) .. side

	-- twt draws the counter over a bottom edge in the plain border color
	local counter = #self.input.clusters .. " / " .. self.input.max_characters
	local bottom = terminal_screen.BOX_BOTTOM_LEFT .. edge_with_title(title_spans({ { counter } }, title_style), inner) .. terminal_screen.BOX_BOTTOM_RIGHT
	return top, middle, bottom, 2 + cursor
end

local function too_small(self)
	return self.columns < MIN_COLUMNS or self.rows < 1
end

-- The input line alone, for panes too small for the boxes.
local function bare_input_output(self)
	local visible, cursor = self.input:visible_window(math.max(1, self.columns - 1))
	return visible, 1 + cursor
end

--- Redraws the whole pane.
function Pane:render_all()
	if not self.started or too_small(self) then
		return
	end
	local emotes = self.emotes
	if emotes and emotes.begin_render then
		emotes:begin_render()
	end
	-- out[3] is filled in last: image loads must reach the terminal before the rows that use them
	local out = { terminal_screen.BEGIN_SYNCHRONIZED_UPDATE, terminal_screen.HIDE_CURSOR, "" }
	local cursor_row, cursor_column
	if is_boxed(self) then
		local height = feed_height(self)
		out[#out + 1] = terminal_screen.move_cursor(1, 1) .. terminal_screen.CLEAR_LINE .. chat_box_top_output(self)
		local rows = self.view:visible_feed_rows(self.store.entries, feed_width(self), height, layout_options(self))
		for row = 1, height do
			-- the right border goes at its own column, whatever the row's text measured
			out[#out + 1] = terminal_screen.move_cursor(row + 1, 1) .. terminal_screen.CLEAR_LINE
				.. terminal_screen.BOX_VERTICAL .. feed_row_output(self, rows[row])
				.. terminal_screen.move_cursor(row + 1, self.columns) .. terminal_screen.BOX_VERTICAL
		end
		out[#out + 1] = terminal_screen.move_cursor(self.rows - 3, 1) .. terminal_screen.CLEAR_LINE .. chat_box_bottom_output(self)
		local top, middle, bottom, column = input_box_output(self)
		out[#out + 1] = terminal_screen.move_cursor(self.rows - 2, 1) .. terminal_screen.CLEAR_LINE .. top
		out[#out + 1] = terminal_screen.move_cursor(self.rows - 1, 1) .. terminal_screen.CLEAR_LINE .. middle
		out[#out + 1] = terminal_screen.move_cursor(self.rows, 1) .. terminal_screen.CLEAR_LINE .. bottom
		cursor_row, cursor_column = self.rows - 1, column
	else
		out[#out + 1] = terminal_screen.CLEAR_SCREEN
		local visible, column = bare_input_output(self)
		out[#out + 1] = terminal_screen.move_cursor(self.rows, 1) .. visible
		cursor_row, cursor_column = self.rows, column
	end
	out[#out + 1] = terminal_screen.move_cursor(cursor_row, cursor_column)
	out[#out + 1] = terminal_screen.SHOW_CURSOR .. terminal_screen.END_SYNCHRONIZED_UPDATE
	if emotes and emotes.end_render then
		out[3] = emotes:end_render()
	end
	self.write(table.concat(out))
end

--- Redraws only the input box; typing does not need the feed laid out again.
function Pane:render_input_line()
	if not self.started or too_small(self) then
		return
	end
	if not is_boxed(self) then
		return self:render_all()
	end
	local top, middle, bottom, column = input_box_output(self)
	self.write(
		terminal_screen.BEGIN_SYNCHRONIZED_UPDATE
			.. terminal_screen.move_cursor(self.rows - 2, 1) .. terminal_screen.CLEAR_LINE .. top
			.. terminal_screen.move_cursor(self.rows - 1, 1) .. terminal_screen.CLEAR_LINE .. middle
			.. terminal_screen.move_cursor(self.rows, 1) .. terminal_screen.CLEAR_LINE .. bottom
			.. terminal_screen.move_cursor(self.rows - 1, column)
			.. terminal_screen.END_SYNCHRONIZED_UPDATE
	)
end

--- Redraws only the chat box's top edge, for the clock in its title.
function Pane:render_title()
	if not self.started or too_small(self) or not is_boxed(self) then
		return
	end
	local _, _, _, column = input_box_output(self)
	self.write(
		terminal_screen.BEGIN_SYNCHRONIZED_UPDATE
			.. terminal_screen.move_cursor(1, 1) .. terminal_screen.CLEAR_LINE .. chat_box_top_output(self)
			.. terminal_screen.move_cursor(self.rows - 1, column)
			.. terminal_screen.END_SYNCHRONIZED_UPDATE
	)
end

--- Takes over the terminal and draws the pane.
function Pane:start()
	self.started = true
	self.write(terminal_screen.ENTER_CHAT_SCREEN)
	self:render_all()
end

--- Gives the terminal back as it was.
function Pane:stop()
	if self.started then
		self.started = false
		local unload = self.emotes and self.emotes.release_all_images and self.emotes:release_all_images() or ""
		self.write(unload .. terminal_screen.LEAVE_CHAT_SCREEN)
	end
end

--- Shows a line in the feed that only this pane sees, such as "message not sent".
function Pane:show_local_status(level, text)
	self.store:apply_chat_event(chat_events.chat_status_event(level, text, self.store.connection_state))
	self:render_all()
end

local function submit_input(self)
	local text = self.input:take_message()
	if not text then
		return
	end
	self.view:scroll_to_newest()
	self:render_all() -- show the emptied line before the send, which blocks for a moment
	-- "/me" is part of a chat message; every other "/word" is a command for this pane
	if text:sub(1, 1) == "/" and not text:match("^/me ") then
		local result = self.run_command(text) or {}
		if result.text then
			self:show_local_status(result.level or "info", result.text)
		end
		return
	end
	local sent, problem = self.send_message(text)
	if not sent then
		self.input:restore_message(text)
		self:show_local_status("error", "Not sent: " .. tostring(problem or "unknown error"))
	end
end

-- Returns "all", "input" or nil: how much of the pane the key made stale.
local function apply_key(self, key)
	local input = self.input
	local name = key.key
	if name == "text" or name == "paste" then
		return input:insert_text(key.text) and "input" or nil
	elseif name == "enter" then
		submit_input(self)
		return nil
	elseif name == "backspace" then
		return input:delete_before_cursor() and "input" or nil
	elseif name == "delete" then
		return input:delete_at_cursor() and "input" or nil
	elseif name == "left" then
		input:move_cursor(-1)
		return "input"
	elseif name == "right" then
		input:move_cursor(1)
		return "input"
	elseif name == "home" then
		input:move_cursor_to_start()
		return "input"
	elseif name == "end" then
		input:move_cursor_to_end()
		return "input"
	elseif name == "word_left" then
		input:move_cursor_word_left()
		return "input"
	elseif name == "word_right" then
		input:move_cursor_word_right()
		return "input"
	elseif name == "delete_word" then
		return input:delete_word_before_cursor() and "input" or nil
	elseif name == "up" then
		return input:browse_history(-1) and "input" or nil
	elseif name == "down" then
		return input:browse_history(1) and "input" or nil
	elseif name == "pageup" then
		return self.view:scroll_feed(math.max(1, feed_height(self) - 1)) and "all" or nil
	elseif name == "pagedown" then
		return self.view:scroll_feed(-math.max(1, feed_height(self) - 1)) and "all" or nil
	elseif name == "scroll_up" then
		return self.view:scroll_feed(WHEEL_SCROLL_ROWS) and "all" or nil
	elseif name == "scroll_down" then
		return self.view:scroll_feed(-WHEEL_SCROLL_ROWS) and "all" or nil
	elseif name == "escape" then
		return self.view:scroll_to_newest() and "all" or nil
	elseif name == "ctrl" then
		if key.char == "c" then
			self.on_quit()
		elseif key.char == "l" then
			self.write(terminal_screen.CLEAR_SCREEN)
			return "all"
		elseif key.char == "a" then
			input:move_cursor_to_start()
			return "input"
		elseif key.char == "e" then
			input:move_cursor_to_end()
			return "input"
		elseif key.char == "u" then
			return input:delete_to_line_start() and "input" or nil
		elseif key.char == "k" then
			return input:delete_to_line_end() and "input" or nil
		elseif key.char == "w" then
			return input:delete_word_before_cursor() and "input" or nil
		end
	end
	return nil
end

--- Handles raw key bytes from the terminal.
function Pane:handle_key_bytes(bytes)
	local stale
	for _, key in ipairs(self.key_parser:parse_key_bytes(bytes)) do
		local result = apply_key(self, key)
		if result == "all" or (result == "input" and stale ~= "all") then
			stale = result
		end
	end
	if stale == "all" then
		self:render_all()
	elseif stale == "input" then
		self:render_input_line()
	end
end

--- Handles bytes read from the event log (any chunking; a line may span chunks).
function Pane:handle_event_log_bytes(bytes)
	local buffer = self.event_log_remainder .. bytes
	local changed = false
	local position = 1
	while true do
		local line_end = buffer:find("\n", position, true)
		if not line_end then
			break
		end
		local chat_event = chat_events.decode_chat_event_line(buffer:sub(position, line_end - 1))
		if chat_event and self.store:apply_chat_event(chat_event) then
			changed = true
		end
		position = line_end + 1
	end
	self.event_log_remainder = buffer:sub(position)
	if changed then
		self:render_all()
	end
end

--- Handles a new terminal size.
function Pane:handle_resize(columns, rows)
	if columns == self.columns and rows == self.rows then
		return
	end
	self.columns, self.rows = columns, rows
	if self.started then
		self.write(terminal_screen.CLEAR_SCREEN)
		self:render_all()
	end
end

return M
