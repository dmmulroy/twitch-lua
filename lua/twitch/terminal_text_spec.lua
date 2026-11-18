local t = require("spec_helper")
local terminal_text = require("twitch.terminal_text")

local ESC = string.char(27)

t.test("terminal_text: sanitize removes escape sequences' control characters", function()
	local evil = "hi" .. ESC .. "[2J" .. ESC .. "]0;title" .. string.char(7) .. "there"
	local safe = terminal_text.sanitize_chat_text(evil)
	t.equal(safe, "hi[2J]0;titlethere")
	t.equal(safe:find(ESC, 1, true), nil)
end)

t.test("terminal_text: sanitize turns tabs and newlines into spaces and drops C1 controls", function()
	t.equal(terminal_text.sanitize_chat_text("a\tb\nc\rd"), "a b c d")
	-- U+009B is the one-byte CSI in C1
	t.equal(terminal_text.sanitize_chat_text("x" .. string.char(0xC2, 0x9B) .. "31my"), "x31my")
	t.equal(terminal_text.sanitize_chat_text("del" .. string.char(0x7F) .. "ete"), "delete")
end)

t.test("terminal_text: sanitize replaces bytes that are not UTF-8", function()
	local replacement = string.char(0xEF, 0xBF, 0xBD)
	t.equal(terminal_text.sanitize_chat_text("a" .. string.char(0xFF) .. "b"), "a" .. replacement .. "b")
	-- a truncated 3-byte sequence, an overlong encoding and a surrogate
	t.equal(terminal_text.sanitize_chat_text(string.char(0xE2, 0x82)), replacement .. replacement)
	t.equal(terminal_text.sanitize_chat_text(string.char(0xC0, 0xAF)), replacement .. replacement)
	t.equal(terminal_text.sanitize_chat_text(string.char(0xED, 0xA0, 0x80)), replacement .. replacement .. replacement)
	t.equal(terminal_text.sanitize_chat_text("héllo 日本 😀"), "héllo 日本 😀")
end)

t.test("terminal_text: display width of ASCII, accents, CJK and emoji", function()
	t.equal(terminal_text.display_width("hello"), 5)
	t.equal(terminal_text.display_width("héllo"), 5)
	t.equal(terminal_text.display_width("e" .. string.char(0xCC, 0x81)), 1) -- e + combining acute
	t.equal(terminal_text.display_width("日本語"), 6)
	t.equal(terminal_text.display_width("😀"), 2)
	t.equal(terminal_text.display_width(""), 0)
end)

t.test("terminal_text: emoji sequences are one cluster two cells wide", function()
	local family = "👨" .. string.char(0xE2, 0x80, 0x8D) .. "👩" .. string.char(0xE2, 0x80, 0x8D) .. "👧"
	local clusters = terminal_text.split_display_clusters(family)
	t.equal(#clusters, 1)
	t.equal(clusters[1].width, 2)
	t.equal(clusters[1].text, family)
	local thumbs_dark = "👍" .. string.char(0xF0, 0x9F, 0x8F, 0xBF)
	t.equal(terminal_text.display_width(thumbs_dark), 2)
	-- U+2764 is one cell; with the emoji variation selector it is drawn as an emoji
	local heart = string.char(0xE2, 0x9D, 0xA4)
	t.equal(terminal_text.display_width(heart), 1)
	t.equal(terminal_text.display_width(heart .. string.char(0xEF, 0xB8, 0x8F)), 2)
end)

t.test("terminal_text: a leading combining mark stands alone with no width", function()
	local clusters = terminal_text.split_display_clusters(string.char(0xCC, 0x81) .. "a")
	t.equal(#clusters, 2)
	t.equal(clusters[1].width, 0)
	t.equal(clusters[2], { text = "a", width = 1 })
end)

t.test("terminal_text: truncate_to_width never splits a cluster", function()
	t.equal({ terminal_text.truncate_to_width("hello world", 5) }, { "hello", 5 })
	t.equal({ terminal_text.truncate_to_width("日本語", 5) }, { "日本", 4 })
	t.equal({ terminal_text.truncate_to_width("a😀b", 2) }, { "a", 1 })
	t.equal({ terminal_text.truncate_to_width("abc", 0) }, { "", 0 })
end)

t.test("terminal_text: utf8_from_code_point matches decode", function()
	for _, code_point in ipairs({ 0x41, 0xE9, 0x20AC, 0x1F600, 0x10EEEE }) do
		local encoded = terminal_text.utf8_from_code_point(code_point)
		local decoded, size = terminal_text.decode_utf8_at(encoded, 1)
		t.equal(decoded, code_point)
		t.equal(size, #encoded)
	end
	t.equal(terminal_text.utf8_from_code_point(0x10EEEE), string.char(0xF4, 0x8E, 0xBB, 0xAE))
end)
