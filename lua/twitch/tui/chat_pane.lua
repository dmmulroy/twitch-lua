-- One chat pane: the feed of messages, a status bar and the line being typed. It takes
-- key bytes, event log bytes and size changes, and writes the screen through `write`.
-- No I/O of its own, so it runs in tests against a fake terminal.
--
--   local chat_pane = require("twitch.tui.chat_pane")
--   local pane = chat_pane.new_chat_pane({
--     write = function(bytes) io.write(bytes) io.flush() end,
--     columns = 40, rows = 50, channel = "dillon", own_login = "dillon",
--     send_message = function(text) return true end,            -- or nil, "why it failed"
--     run_command = function(line) return { level = "info", text = "done" } end,
--     on_quit = function() end,
--   })
--   pane:start()
--   pane:handle_key_bytes(bytes)          -- from the terminal, raw mode
--   pane:handle_event_log_bytes(bytes)    -- from `tail -F` on the event log
--   pane:handle_resize(columns, rows)
--
-- Screen: rows 1..n-2 are the feed, row n-1 the status bar, row n the input line.
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

local INPUT_PROMPT = "> "
local INPUT_PLACEHOLDER = "Send a message"
local WHEEL_SCROLL_ROWS = 3
local MIN_COLUMNS = 4

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
		-- Optional emote images: { revision, emote_columns(request), draw_emote(request) }.
		emotes = opts.emotes,
		store = chat_store.new_chat_store({ max_entries = opts.max_messages }),
		view = chat_feed_layout.new_chat_feed_view(),
		input = message_input.new_message_input(),
		key_parser = terminal_keys.new_key_parser(),
		event_log_remainder = "", -- an event log line that has not ended yet
		started = false,
	}, Pane)
end

local function feed_height(self)
	return math.max(0, self.rows - 2)
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

-- The status bar: channel and connection on the left, scroll position on the right.
local function status_bar_output(self)
	local state = self.store.connection_state
	local connection
	if state == "joined" then
		connection = { text = "●", style = "bar_joined" }
	elseif state == "reconnecting" then
		connection = { text = "◌ reconnecting", style = "bar_warn" }
	elseif state == "stopped" then
		connection = { text = "✖ offline", style = "bar_error" }
	else
		connection = { text = "… connecting", style = "bar" }
	end
	local right
	if self.view.unseen_entries > 0 then
		right = { text = "↓ " .. self.view.unseen_entries .. " new", style = "bar_unseen" }
	elseif self.view.scroll_offset > 0 then
		right = { text = "↑ scrolled", style = "bar" }
	end

	local width = self.columns
	local channel_text = terminal_text.truncate_to_width("#" .. tostring(self.channel or "?"), math.max(0, width - 2))
	local channel_width = terminal_text.display_width(channel_text)
	local right_width = right and terminal_text.display_width(right.text) or 0
	-- Narrow panes: shorten the connection to its symbol before giving up the scroll note.
	local symbol_only = { text = terminal_text.split_display_clusters(connection.text)[1].text, style = connection.style }
	for _, shown in ipairs({ connection, symbol_only }) do
		local left_width = channel_width + 1 + terminal_text.display_width(shown.text)
		local gap = width - left_width - right_width
		if (right and gap >= 1) or (not right and gap >= 0) then
			local out = terminal_screen.styled_span_text({ text = channel_text, style = "bar" }) .. " " .. terminal_screen.styled_span_text(shown)
			if right then
				out = out .. string.rep(" ", gap) .. terminal_screen.styled_span_text(right)
			end
			return out
		end
	end
	return terminal_screen.styled_span_text({ text = channel_text, style = "bar" })
end

-- The input line and where the cursor goes on it.
local function input_row_output(self)
	local text_width = math.max(0, self.columns - #INPUT_PROMPT)
	local out = terminal_screen.styled_span_text({ text = INPUT_PROMPT, style = "prompt" })
	local cursor_column = #INPUT_PROMPT + 1
	if self.input:is_empty() then
		local placeholder = terminal_text.truncate_to_width(INPUT_PLACEHOLDER, text_width)
		out = out .. terminal_screen.styled_span_text({ text = placeholder, style = "placeholder" })
	else
		local visible, cursor = self.input:visible_window(text_width)
		out = out .. visible
		cursor_column = cursor_column + cursor
	end
	return out, cursor_column
end

local function too_small(self)
	return self.columns < MIN_COLUMNS or self.rows < 1
end

--- Redraws the whole pane.
function Pane:render_all()
	if not self.started or too_small(self) then
		return
	end
	local out = { terminal_screen.BEGIN_SYNCHRONIZED_UPDATE, terminal_screen.HIDE_CURSOR }
	local height = feed_height(self)
	if height > 0 then
		local rows = self.view:visible_feed_rows(self.store.entries, self.columns, height, layout_options(self))
		for row = 1, height do
			out[#out + 1] = terminal_screen.move_cursor(row, 1) .. terminal_screen.CLEAR_LINE .. feed_row_output(self, rows[row])
		end
	end
	if self.rows >= 2 then
		out[#out + 1] = terminal_screen.move_cursor(self.rows - 1, 1) .. terminal_screen.CLEAR_LINE .. status_bar_output(self)
	end
	local input_output, cursor_column = input_row_output(self)
	out[#out + 1] = terminal_screen.move_cursor(self.rows, 1) .. terminal_screen.CLEAR_LINE .. input_output
	out[#out + 1] = terminal_screen.move_cursor(self.rows, cursor_column)
	out[#out + 1] = terminal_screen.SHOW_CURSOR .. terminal_screen.END_SYNCHRONIZED_UPDATE
	self.write(table.concat(out))
end

--- Redraws only the input line; typing does not need the feed laid out again.
function Pane:render_input_line()
	if not self.started or too_small(self) then
		return
	end
	local input_output, cursor_column = input_row_output(self)
	self.write(
		terminal_screen.BEGIN_SYNCHRONIZED_UPDATE
			.. terminal_screen.move_cursor(self.rows, 1) .. terminal_screen.CLEAR_LINE .. input_output
			.. terminal_screen.move_cursor(self.rows, cursor_column)
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
		self.write(terminal_screen.LEAVE_CHAT_SCREEN)
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
