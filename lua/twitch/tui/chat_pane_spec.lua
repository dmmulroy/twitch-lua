local t = require("spec_helper")
local chat_events = require("twitch.chat_events")
local chat_pane = require("twitch.tui.chat_pane")
local fake_terminal_grid = require("fake_terminal_grid")

local ESC = string.char(27)
local CLOCK = "Wed Nov 18 08:44:10 2026"

-- A started pane drawing into a fake terminal. Layout for `rows`: row 1 is the chat box's
-- top edge, rows 2..rows-4 the feed, rows-3 its bottom edge, rows-2..rows the input box.
local function new_pane(columns, rows, opts)
	local grid = fake_terminal_grid.new_fake_terminal_grid(columns, rows)
	local calls = { sent = {}, commands = {}, quit = 0, raw = {}, clock = CLOCK }
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
		clock_text = function()
			return calls.clock
		end,
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

-- The text between a box's side borders.
local function inside(grid, row)
	local text = grid:row_text(row)
	return (text:gsub("^│", ""):gsub("│$", ""):gsub(" +$", ""))
end

-- The feed's rows, top to bottom.
local function feed(grid)
	local rows = {}
	for row = 2, grid.rows - 4 do
		rows[#rows + 1] = inside(grid, row)
	end
	return rows
end

local function input_text(grid)
	return inside(grid, grid.rows - 1)
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

t.test("chat_pane: start takes the alternate screen and draws twt's two boxes", function()
	local _, grid, calls = new_pane(60, 8)
	t.equal(grid.modes["?1049"], true)
	t.equal(grid.modes["?7"], false) -- line wrapping off
	t.equal(grid.modes["?2004"], true)
	t.equal(grid:row_text(1), "┌[ Time: " .. CLOCK .. " ] [ Channel: dillon ]" .. string.rep("─", 4) .. "┐")
	t.equal(grid:row_text(2), "│" .. string.rep(" ", 58) .. "│")
	t.equal(grid:row_text(5), "└" .. string.rep("─", 58) .. "┘")
	t.equal(grid:row_text(6), "┌[ Chat ]" .. string.rep("─", 50) .. "┐")
	t.equal(grid:row_text(7), "│" .. string.rep(" ", 58) .. "│")
	t.equal(grid:row_text(8), "└[ 0 / 500 ]" .. string.rep("─", 47) .. "┘")
	t.equal({ grid.cursor_row, grid.cursor_column }, { 7, 2 })
	-- an empty line cannot be sent: the input box is red, its title bold red
	local screen = table.concat(calls.raw)
	t.truthy(screen:find(ESC .. "[31m┌" .. ESC .. "[0m", 1, true))
	t.truthy(screen:find(ESC .. "[1;31mChat" .. ESC .. "[0m", 1, true))
	t.truthy(screen:find(ESC .. "[1;31mTime" .. ESC .. "[0m", 1, true))
end)

t.test("chat_pane: the title is cut at the box's width, as twt does in a narrow pane", function()
	local _, grid = new_pane(39, 8)
	t.equal(grid:row_text(1), "┌[ Time: " .. CLOCK .. " ] [ ┐")
end)

t.test("chat_pane: render_title updates the clock without touching the rest", function()
	local pane, grid, calls = new_pane(60, 8)
	pane:handle_key_bytes("draft")
	calls.clock = "Wed Nov 18 08:44:11 2026"
	local before = #calls.raw
	pane:render_title()
	t.equal(#calls.raw, before + 1)
	t.truthy(grid:row_text(1):find("08:44:11", 1, true))
	t.equal(input_text(grid), "draft")
	t.equal({ grid.cursor_row, grid.cursor_column }, { 7, 7 })
end)

t.test("chat_pane: messages from the event log fill the feed from the bottom and wrap like twt", function()
	-- 39 columns: the twt pane seen in Rex wrapped this message after "experience"
	local pane, grid = new_pane(39, 9)
	pane:handle_event_log_bytes(
		log_line({ kind = "status", level = "info", text = "Joined #dillon", state = "joined" })
			.. message_line("bishalr0y", "how's you experience with rex?")
	)
	t.equal(feed(grid), { "", "Twitch: Joined #dillon", "bishalr0y: how's you experience", "with rex?" })
	t.equal(grid:row_text(4), "│bishalr0y: how's you experience      │")
end)

t.test("chat_pane: a row as wide as the feed keeps its last character and the border", function()
	local pane, grid = new_pane(23, 8) -- wraps at 20, one short of the inside, as twt does
	pane:handle_event_log_bytes(message_line("Viewer", "twelve chars"))
	t.equal(grid:row_text(4), "│Viewer: twelve chars │")
end)

t.test("chat_pane: an event log line split across reads is applied once it is whole", function()
	local pane, grid = new_pane(40, 7)
	local line = message_line("Viewer", "split line")
	pane:handle_event_log_bytes(line:sub(1, 20))
	t.equal(feed(grid), { "", "" })
	pane:handle_event_log_bytes(line:sub(21))
	t.equal(feed(grid), { "", "Viewer: split line" })
	-- a damaged line is skipped and the next one still shows
	pane:handle_event_log_bytes('{"seq":99999,"kind":"mess\n' .. message_line("Other", "fine"))
	t.equal(feed(grid), { "Viewer: split line", "Other: fine" })
end)

t.test("chat_pane: escape codes in chat text never reach the terminal", function()
	local pane, grid, calls = new_pane(50, 7)
	local before = #calls.raw
	pane:handle_event_log_bytes(message_line("Evil" .. ESC .. "[2J", "boo" .. ESC .. "]0;owned" .. string.char(7) .. ESC .. "[?1049l"))
	t.equal(feed(grid)[2], "Evil[2J: boo]0;owned[?1049l")
	t.equal(grid.modes["?1049"], true)
	local written = table.concat(calls.raw, "", before + 1)
	t.equal(written:find(string.char(7), 1, true), nil)
	t.equal(written:find(ESC .. "]", 1, true), nil)
end)

t.test("chat_pane: typing shows in the input box, which turns green, and Enter sends it", function()
	local pane, grid, calls = new_pane(40, 7)
	pane:handle_key_bytes("hello chat")
	t.equal(input_text(grid), "hello chat")
	t.equal({ grid.cursor_row, grid.cursor_column }, { 6, 12 })
	t.equal(grid:row_text(7), "└[ 10 / 500 ]" .. string.rep("─", 26) .. "┘")
	t.truthy(calls.raw[#calls.raw]:find(ESC .. "[32m┌", 1, true))
	pane:handle_key_bytes(string.char(127) .. string.char(127) .. string.char(127) .. string.char(127) .. "all\r")
	t.equal(calls.sent, { "hello all" })
	t.equal(input_text(grid), "")
	-- a blank line sends nothing
	pane:handle_key_bytes("   \r")
	t.equal(#calls.sent, 1)
end)

t.test("chat_pane: a message that could not be sent comes back, with the reason as a System line", function()
	local pane, grid = new_pane(50, 8, {
		send_message = function()
			return nil, "you are timed out"
		end,
	})
	pane:handle_key_bytes("please\r")
	t.equal(input_text(grid), "please")
	t.equal(feed(grid)[3], "System: Not sent: you are timed out")
end)

t.test("chat_pane: a line starting with / is a command, except /me", function()
	local pane, grid, calls = new_pane(50, 8)
	pane:handle_key_bytes("/title new title\r")
	t.equal(calls.commands, { "/title new title" })
	t.equal(#calls.sent, 0)
	t.equal(feed(grid)[3], "Twitch: ran /title new title")
	pane:handle_key_bytes("/me waves\r")
	t.equal(calls.sent, { "/me waves" })
end)

t.test("chat_pane: editing keys", function()
	local pane, grid = new_pane(40, 7)
	pane:handle_key_bytes("one two three")
	pane:handle_key_bytes(string.char(23)) -- Ctrl-W
	t.equal(input_text(grid), "one two")
	pane:handle_key_bytes(string.char(1) .. "X") -- Ctrl-A
	t.equal(input_text(grid), "Xone two")
	pane:handle_key_bytes(ESC .. "[C" .. ESC .. "[3~") -- right, delete
	t.equal(input_text(grid), "Xoe two")
	pane:handle_key_bytes(string.char(5) .. string.char(21)) -- Ctrl-E, Ctrl-U
	t.equal(input_text(grid), "")
	t.equal(grid:row_text(7):sub(1, 14), "└[ 0 / 500 ]")
end)

t.test("chat_pane: Up and Down recall sent messages", function()
	local pane, grid = new_pane(40, 7)
	pane:handle_key_bytes("first\rsecond\r")
	pane:handle_key_bytes(ESC .. "[A")
	t.equal(input_text(grid), "second")
	pane:handle_key_bytes(ESC .. "[A")
	t.equal(input_text(grid), "first")
	pane:handle_key_bytes(ESC .. "[B" .. ESC .. "[B")
	t.equal(input_text(grid), "")
end)

t.test("chat_pane: scrolling holds position, notes new messages on the box's edge, and Esc returns", function()
	local pane, grid = new_pane(30, 8) -- 3 feed rows
	local lines = {}
	for index = 1, 8 do
		lines[index] = message_line("V", "message " .. index)
	end
	pane:handle_event_log_bytes(table.concat(lines))
	t.equal(feed(grid)[3], "V: message 8")
	pane:handle_key_bytes(ESC .. "[5~") -- PageUp: 2 rows
	t.equal(feed(grid)[3], "V: message 6")
	t.equal(grid:row_text(5), "└" .. string.rep("─", 16) .. "[ Scrolled ]┘")
	pane:handle_event_log_bytes(message_line("V", "message 9"))
	t.equal(feed(grid)[3], "V: message 6")
	t.equal(grid:row_text(5), "└" .. string.rep("─", 19) .. "[ 1 new ]┘")
	pane:handle_key_bytes(ESC .. "[<64;5;5M") -- wheel up: 3 rows
	t.equal(feed(grid)[3], "V: message 3")
	pane:handle_key_bytes(ESC)
	t.equal(feed(grid)[3], "V: message 9")
	t.equal(grid:row_text(5), "└" .. string.rep("─", 28) .. "┘")
end)

t.test("chat_pane: sending jumps back to the newest message", function()
	local pane, grid = new_pane(30, 8)
	local lines = {}
	for index = 1, 8 do
		lines[index] = message_line("V", "message " .. index)
	end
	pane:handle_event_log_bytes(table.concat(lines))
	pane:handle_key_bytes(ESC .. "[5~")
	pane:handle_key_bytes("hi\r")
	t.equal(feed(grid)[3], "V: message 8")
end)

t.test("chat_pane: deleted messages disappear, and a clear says so in twt's words", function()
	local pane, grid = new_pane(70, 8)
	pane:handle_event_log_bytes(message_line("Viewer", "rude words", { id = "bad" }) .. message_line("Other", "hi"))
	pane:handle_event_log_bytes(log_line({ kind = "delete", message_id = "bad" }))
	t.equal(feed(grid), { "", "", "Other: hi" })
	pane:handle_event_log_bytes(log_line({ kind = "clear" }))
	t.equal(feed(grid), { "", "", "Twitch: Chat was cleared for non-Moderators viewing this room" })
end)

t.test("chat_pane: connection problems are System lines; joining is a Twitch line", function()
	local pane, grid = new_pane(60, 7)
	pane:handle_event_log_bytes(log_line({ kind = "status", level = "warn", text = "Twitch went silent. Retrying in 1s.", state = "reconnecting" }))
	t.equal(feed(grid)[2], "System: Twitch went silent. Retrying in 1s.")
	pane:handle_event_log_bytes(log_line({ kind = "status", level = "info", text = "Joined #dillon", state = "joined" }))
	t.equal(feed(grid)[2], "Twitch: Joined #dillon")
end)

t.test("chat_pane: resizing redraws to the new size", function()
	local pane, grid = new_pane(43, 8)
	pane:handle_event_log_bytes(message_line("Viewer", "a message that fits on one row at first"))
	-- textwrap's optimal fit, as twt: "at" goes down although it would fit
	t.equal(feed(grid), { "", "Viewer: a message that fits on one row", "at first" })
	grid:resize(20, 10)
	pane:handle_resize(20, 10)
	t.equal(feed(grid), { "", "", "Viewer: a message", "that fits on one", "row at first" })
	t.equal(grid:row_text(10):sub(1, 14), "└[ 0 / 500 ]")
end)

t.test("chat_pane: a long line being typed scrolls sideways inside the box", function()
	local pane, grid = new_pane(14, 6)
	pane:handle_key_bytes("abcdefghijklmnop")
	t.equal(input_text(grid), "ghijklmnop")
	t.equal(grid.cursor_column, 12)
	t.equal(grid:row_text(5), "│ghijklmnop  │")
end)

t.test("chat_pane: a pane too small for the boxes shows only the line being typed", function()
	local pane, grid = new_pane(20, 4)
	pane:handle_key_bytes("tiny")
	t.equal(grid:row_text(4), "tiny")
	t.equal(grid:row_text(1), "")
end)

t.test("chat_pane: Ctrl-C asks to quit; stop restores the terminal", function()
	local pane, grid, calls = new_pane(30, 7)
	pane:handle_key_bytes(string.char(3))
	t.equal(calls.quit, 1)
	pane:stop()
	t.equal(grid.modes["?1049"], false)
	t.equal(grid.modes["?7"], true)
	t.equal(grid.modes["?1000"], false)
end)

t.test("chat_pane: tiny sizes do not raise", function()
	local pane = new_pane(40, 7)
	for _, size in ipairs({ { 3, 1 }, { 10, 1 }, { 10, 2 }, { 7, 6 }, { 8, 6 }, { 1, 1 } }) do
		pane:handle_resize(size[1], size[2])
		pane:handle_key_bytes("x")
		pane:handle_event_log_bytes(message_line("Viewer", "hello"))
		pane:render_title()
	end
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
	local pane, grid = new_pane(40, 7, { emotes = emotes })
	pane:handle_event_log_bytes(message_line("Viewer", "hi Kappa", {
		parts = { { type = "text", text = "hi " }, { type = "emote", text = "Kappa", emote_id = "25" } },
	}))
	t.equal(feed(grid)[2], "Viewer: hi [25]")
end)
