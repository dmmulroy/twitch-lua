local t = require("spec_helper")
local terminal_keys = require("twitch.tui.terminal_keys")

local ESC = string.char(27)

local function parse(bytes)
	return terminal_keys.new_key_parser():parse_key_bytes(bytes)
end

t.test("terminal_keys: typed text is grouped, and Enter, Backspace and Tab are keys", function()
	t.equal(parse("hi é😀"), { { key = "text", text = "hi é😀" } })
	t.equal(parse("a\rb" .. string.char(127) .. "\t"), {
		{ key = "text", text = "a" }, { key = "enter" }, { key = "text", text = "b" }, { key = "backspace" }, { key = "tab" },
	})
end)

t.test("terminal_keys: arrows, home, end, page keys and delete", function()
	t.equal(parse(ESC .. "[A" .. ESC .. "[B" .. ESC .. "[C" .. ESC .. "[D"), {
		{ key = "up" }, { key = "down" }, { key = "right" }, { key = "left" },
	})
	t.equal(parse(ESC .. "[H" .. ESC .. "[F" .. ESC .. "[5~" .. ESC .. "[6~" .. ESC .. "[3~" .. ESC .. "[1~" .. ESC .. "[4~"), {
		{ key = "home" }, { key = "end" }, { key = "pageup" }, { key = "pagedown" }, { key = "delete" }, { key = "home" }, { key = "end" },
	})
	t.equal(parse(ESC .. "OA" .. ESC .. "OD"), { { key = "up" }, { key = "left" } })
end)

t.test("terminal_keys: word movement and word delete", function()
	t.equal(parse(ESC .. "b" .. ESC .. "f" .. ESC .. string.char(127)), {
		{ key = "word_left" }, { key = "word_right" }, { key = "delete_word" },
	})
	t.equal(parse(ESC .. "[1;5D" .. ESC .. "[1;3C"), { { key = "word_left" }, { key = "word_right" } })
end)

t.test("terminal_keys: control letters", function()
	t.equal(parse(string.char(3, 21, 12)), {
		{ key = "ctrl", char = "c" }, { key = "ctrl", char = "u" }, { key = "ctrl", char = "l" },
	})
end)

t.test("terminal_keys: a lone ESC is Escape; an unfinished sequence waits for the rest", function()
	t.equal(parse(ESC), { { key = "escape" } })
	local parser = terminal_keys.new_key_parser()
	t.equal(parser:parse_key_bytes("x" .. ESC .. "["), { { key = "text", text = "x" } })
	t.equal(parser:parse_key_bytes("5"), {})
	t.equal(parser:parse_key_bytes("~y"), { { key = "pageup" }, { key = "text", text = "y" } })
end)

t.test("terminal_keys: a character split across chunks is put back together", function()
	local parser = terminal_keys.new_key_parser()
	local emoji = "😀"
	t.equal(parser:parse_key_bytes("a" .. emoji:sub(1, 2)), { { key = "text", text = "a" } })
	t.equal(parser:parse_key_bytes(emoji:sub(3)), { { key = "text", text = emoji } })
end)

t.test("terminal_keys: bracketed paste is one event with control characters removed", function()
	t.equal(parse(ESC .. "[200~line one\nline" .. ESC .. "[31m two" .. ESC .. "[201~z"), {
		{ key = "paste", text = "line one line[31m two" }, { key = "text", text = "z" },
	})
end)

t.test("terminal_keys: a paste split across chunks, even inside its end marker", function()
	local parser = terminal_keys.new_key_parser()
	t.equal(parser:parse_key_bytes(ESC .. "[200~hello "), {})
	t.equal(parser:parse_key_bytes("wor"), {})
	t.equal(parser:parse_key_bytes("ld" .. ESC .. "[20"), {})
	t.equal(parser:parse_key_bytes("1~!"), { { key = "paste", text = "hello world" }, { key = "text", text = "!" } })
end)

t.test("terminal_keys: mouse wheel in SGR mode; other mouse events are ignored", function()
	t.equal(parse(ESC .. "[<64;10;5M" .. ESC .. "[<65;10;5M"), { { key = "scroll_up" }, { key = "scroll_down" } })
	t.equal(parse(ESC .. "[<0;10;5M" .. ESC .. "[<0;10;5m"), {})
end)

t.test("terminal_keys: unknown sequences and terminal replies are dropped quietly", function()
	t.equal(parse(ESC .. "[I" .. ESC .. "[?62;c" .. "ok"), { { key = "text", text = "ok" } })
	t.equal(parse(ESC .. "x"), {})
end)
