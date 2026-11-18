local t = require("spec_helper")
local chat_events = require("twitch.chat_events")
local chat_pane = require("twitch.tui.chat_pane")
local fake_terminal_grid = require("fake_terminal_grid")

local ESC = string.char(27)

-- A started pane drawing into a fake terminal.
local function new_pane(columns, rows, opts)
	local grid = fake_terminal_grid.new_fake_terminal_grid(columns, rows)
	local calls = { sent = {}, commands = {}, quit = 0, raw = {} }
	opts = opts or {}
	local pane = chat_pane.new_chat_pane({
		write = function(bytes)
			calls.raw[#calls.raw + 1] = bytes
			grid:write(bytes)
		end,
		columns = columns,
		rows = rows,
		channel = "dillon",
		own_login = "dillon",
		send_message = opts.send_message or function(text)
			calls.sent[#calls.sent + 1] = text
			return true
		end,
		run_command = function(line)
			calls.commands[#calls.commands + 1] = line
			return { level = "info", text = "ran " .. line }
		end,
		on_quit = function()
			calls.quit = calls.quit + 1
		end,
		emotes = opts.emotes,
	})
	pane:start()
	return pane, grid, calls
end

local next_seq = 0
local function log_line(event)
	next_seq = next_seq + 1
	event.seq = next_seq
	return chat_events.encode_chat_event_line(event) .. "\n"
end

local function message_line(name, text, extra)
	local event = { kind = "message", id = "id-" .. (next_seq + 1), name = name, login = name:lower(), user_id = name, text = text, parts = { { type = "text", text = text } } }
	for key, value in pairs(extra or {}) do
		event[key] = value
	end
	return log_line(event)
end

t.test("chat_pane: start takes the alternate screen and draws the empty pane", function()
	local _, grid = new_pane(30, 6)
	t.equal(grid.modes["?1049"], true)
	t.equal(grid.modes["?7"], false) -- line wrapping off
	t.equal(grid.modes["?2004"], true)
	t.equal(grid:row_text(5), "#dillon … connecting")
	t.equal(grid:row_text(6), "> Send a message")
	t.equal({ grid.cursor_row, grid.cursor_column }, { 6, 3 })
end)

t.test("chat_pane: messages from the event log fill the feed from the bottom and wrap", function()
	local pane, grid = new_pane(24, 7)
	pane:handle_event_log_bytes(
		log_line({ kind = "status", level = "info", text = "Joined #dillon", state = "joined" })
			.. message_line("Viewer", "hello there everyone in chat")
	)
	t.equal(grid:row_text(1), "")
	t.equal(grid:row_text(3), "· Joined #dillon")
	t.equal(grid:row_text(4), "Viewer: hello there")
	t.equal(grid:row_text(5), "everyone in chat")
	t.equal(grid:row_text(6), "#dillon ●")
end)

t.test("chat_pane: a row exactly as wide as the pane keeps its last character", function()
	local pane, grid = new_pane(20, 5)
	pane:handle_event_log_bytes(message_line("Viewer", "twelve chars"))
	t.equal(grid:row_text(3), "Viewer: twelve chars")
	pane:handle_key_bytes("eighteen characters")
	t.equal(grid:row_text(5), "> ghteen characters")
end)

t.test("chat_pane: an event log line split across reads is applied once it is whole", function()
	local pane, grid = new_pane(30, 5)
	local line = message_line("Viewer", "split line")
	pane:handle_event_log_bytes(line:sub(1, 20))
	t.equal(grid:row_text(3), "")
	pane:handle_event_log_bytes(line:sub(21))
	t.equal(grid:row_text(3), "Viewer: split line")
	-- a damaged line is skipped and the next one still shows
	pane:handle_event_log_bytes('{"seq":99999,"kind":"mess\n' .. message_line("Other", "fine"))
	t.equal(grid:row_text(3), "Other: fine")
end)

t.test("chat_pane: escape codes in chat text never reach the terminal", function()
	local pane, grid, calls = new_pane(40, 5)
	local before = #calls.raw
	pane:handle_event_log_bytes(message_line("Evil" .. ESC .. "[2J", "boo" .. ESC .. "]0;owned" .. string.char(7) .. ESC .. "[?1049l"))
	t.equal(grid:row_text(3), "Evil[2J: boo]0;owned[?1049l")
	t.equal(grid.modes["?1049"], true)
	local written = table.concat(calls.raw, "", before + 1)
	t.equal(written:find(string.char(7), 1, true), nil)
	t.equal(written:find(ESC .. "]", 1, true), nil)
end)

t.test("chat_pane: typing shows on the input line and Enter sends it", function()
	local pane, grid, calls = new_pane(30, 5)
	pane:handle_key_bytes("hello chat")
	t.equal(grid:row_text(5), "> hello chat")
	t.equal({ grid.cursor_row, grid.cursor_column }, { 5, 13 })
	pane:handle_key_bytes(string.char(127) .. string.char(127) .. string.char(127) .. string.char(127) .. "all\r")
	t.equal(calls.sent, { "hello all" })
	t.equal(grid:row_text(5), "> Send a message")
	-- a blank line sends nothing
	pane:handle_key_bytes("   \r")
	t.equal(#calls.sent, 1)
end)

t.test("chat_pane: a message that could not be sent comes back with the reason", function()
	local pane, grid = new_pane(40, 6, {
		send_message = function()
			return nil, "you are timed out"
		end,
	})
	pane:handle_key_bytes("please\r")
	t.equal(grid:row_text(6), "> please")
	t.equal(grid:row_text(4), "· Not sent: you are timed out")
end)

t.test("chat_pane: a line starting with / is a command, except /me", function()
	local pane, grid, calls = new_pane(40, 6)
	pane:handle_key_bytes("/title new title\r")
	t.equal(calls.commands, { "/title new title" })
	t.equal(#calls.sent, 0)
	t.equal(grid:row_text(4), "· ran /title new title")
	pane:handle_key_bytes("/me waves\r")
	t.equal(calls.sent, { "/me waves" })
end)

t.test("chat_pane: editing keys", function()
	local pane, grid = new_pane(40, 4)
	pane:handle_key_bytes("one two three")
	pane:handle_key_bytes(string.char(23)) -- Ctrl-W
	t.equal(grid:row_text(4), "> one two")
	pane:handle_key_bytes(string.char(1) .. "X") -- Ctrl-A
	t.equal(grid:row_text(4), "> Xone two")
	pane:handle_key_bytes(ESC .. "[C" .. ESC .. "[3~") -- right, delete
	t.equal(grid:row_text(4), "> Xoe two")
	pane:handle_key_bytes(string.char(5) .. string.char(21)) -- Ctrl-E, Ctrl-U
	t.equal(grid:row_text(4), "> Send a message")
end)

t.test("chat_pane: Up and Down recall sent messages", function()
	local pane, grid = new_pane(40, 4)
	pane:handle_key_bytes("first\rsecond\r")
	pane:handle_key_bytes(ESC .. "[A")
	t.equal(grid:row_text(4), "> second")
	pane:handle_key_bytes(ESC .. "[A")
	t.equal(grid:row_text(4), "> first")
	pane:handle_key_bytes(ESC .. "[B" .. ESC .. "[B")
	t.equal(grid:row_text(4), "> Send a message")
end)

t.test("chat_pane: scrolling holds position, shows unseen messages, and Esc returns", function()
	local pane, grid = new_pane(30, 5) -- 3 feed rows
	local lines = {}
	for index = 1, 8 do
		lines[index] = message_line("V", "message " .. index)
	end
	pane:handle_event_log_bytes(table.concat(lines))
	t.equal(grid:row_text(3), "V: message 8")
	pane:handle_key_bytes(ESC .. "[5~") -- PageUp: 2 rows
	t.equal(grid:row_text(3), "V: message 6")
	-- 30 columns: the connection shrinks to its symbol to leave room for the scroll note
	t.equal(grid:row_text(4), "#dillon …           ↑ scrolled")
	pane:handle_event_log_bytes(message_line("V", "message 9"))
	t.equal(grid:row_text(3), "V: message 6")
	t.truthy(grid:row_text(4):find("↓ 1 new", 1, true))
	pane:handle_key_bytes(ESC .. "[<64;5;5M") -- wheel up: 3 rows
	t.equal(grid:row_text(3), "V: message 3")
	pane:handle_key_bytes(ESC)
	t.equal(grid:row_text(3), "V: message 9")
	t.equal(grid:row_text(4):find("new", 1, true), nil)
end)

t.test("chat_pane: sending jumps back to the newest message", function()
	local pane, grid = new_pane(30, 5)
	local lines = {}
	for index = 1, 8 do
		lines[index] = message_line("V", "message " .. index)
	end
	pane:handle_event_log_bytes(table.concat(lines))
	pane:handle_key_bytes(ESC .. "[5~")
	pane:handle_key_bytes("hi\r")
	t.equal(grid:row_text(3), "V: message 8")
end)

t.test("chat_pane: deletions and clears from moderators update the feed", function()
	local pane, grid = new_pane(40, 6)
	pane:handle_event_log_bytes(message_line("Viewer", "rude words", { id = "bad" }) .. message_line("Other", "hi"))
	pane:handle_event_log_bytes(log_line({ kind = "delete", message_id = "bad" }))
	t.equal(grid:row_text(3), "Viewer: <message deleted>")
	pane:handle_event_log_bytes(log_line({ kind = "clear" }))
	t.equal(grid:row_text(3), "")
	t.equal(grid:row_text(4), "· Chat was cleared by a moderator")
end)

t.test("chat_pane: the status bar follows the connection", function()
	local pane, grid = new_pane(40, 5)
	pane:handle_event_log_bytes(log_line({ kind = "status", level = "warn", text = "Twitch went silent. Retrying in 1s.", state = "reconnecting" }))
	t.equal(grid:row_text(4), "#dillon ◌ reconnecting")
	pane:handle_event_log_bytes(log_line({ kind = "status", level = "error", text = "Twitch token is invalid", state = "stopped" }))
	t.equal(grid:row_text(4), "#dillon ✖ offline")
	t.equal(grid:row_text(3), "· Twitch token is invalid")
end)

t.test("chat_pane: resizing redraws to the new size", function()
	local pane, grid = new_pane(40, 6)
	pane:handle_event_log_bytes(message_line("Viewer", "a message that fits on one row at first"))
	t.equal(grid:row_text(3), "Viewer: a message that fits on one row")
	t.equal(grid:row_text(4), "at first")
	grid:resize(20, 8)
	pane:handle_resize(20, 8)
	t.equal(grid:row_text(4), "Viewer: a message")
	t.equal(grid:row_text(5), "that fits on one row")
	t.equal(grid:row_text(6), "at first")
	t.equal(grid:row_text(7), "#dillon … connecting")
	t.equal(grid:row_text(8), "> Send a message")
end)

t.test("chat_pane: a long line being typed scrolls sideways", function()
	local pane, grid = new_pane(12, 3)
	pane:handle_key_bytes("abcdefghijklmnop")
	t.equal(grid:row_text(3), "> hijklmnop")
	t.equal(grid.cursor_column, 12)
end)

t.test("chat_pane: Ctrl-C asks to quit; stop restores the terminal", function()
	local pane, grid, calls = new_pane(30, 5)
	pane:handle_key_bytes(string.char(3))
	t.equal(calls.quit, 1)
	pane:stop()
	t.equal(grid.modes["?1049"], false)
	t.equal(grid.modes["?7"], true)
	t.equal(grid.modes["?1000"], false)
end)

t.test("chat_pane: tiny sizes do not raise", function()
	local pane = new_pane(40, 5)
	pane:handle_resize(3, 1)
	pane:handle_resize(10, 1)
	pane:handle_resize(10, 2)
	pane:handle_key_bytes("x")
	pane:handle_event_log_bytes(message_line("Viewer", "hello"))
end)

t.test("chat_pane: emote spans are drawn by the emote helper", function()
	local emotes = { revision = 1 }
	function emotes:emote_columns(request)
		if request.id == "25" then
			return 2
		end
	end
	function emotes:draw_emote(request)
		return "[" .. request.id .. "]"
	end
	local pane, grid = new_pane(40, 5, { emotes = emotes })
	pane:handle_event_log_bytes(message_line("Viewer", "hi Kappa", {
		parts = { { type = "text", text = "hi " }, { type = "emote", text = "Kappa", emote_id = "25" } },
	}))
	t.equal(grid:row_text(3), "Viewer: hi [25]")
end)
