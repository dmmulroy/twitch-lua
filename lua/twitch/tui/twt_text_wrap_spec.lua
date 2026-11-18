local t = require("spec_helper")
local twt_text_wrap = require("twitch.tui.twt_text_wrap")

local function wrapped(text, width, indent)
	local lines = {}
	for index, line in ipairs(twt_text_wrap.wrap_text_like_twt(text, width, indent)) do
		lines[index] = text:sub(line.first, line.last) .. line.penalty
	end
	return lines
end

-- 1,900 messages wrapped by the real textwrap 0.16.2, the version twt uses
-- (scripts/check_wrap_against_textwrap.sh): plain chat, hyphens, URLs, long words, CJK,
-- emoji, combining marks, joiners, runs of spaces, random characters from many scripts.
t.test("twt_text_wrap: every recorded case wraps exactly as textwrap 0.16.2 does", function()
	local expected = {}
	for line in io.lines(SPEC_ROOT .. "/spec/fixtures/textwrap/expected.txt") do
		expected[#expected + 1] = line
	end
	local index, differences, first_difference = 0, 0, nil
	for case in io.lines(SPEC_ROOT .. "/spec/fixtures/textwrap/cases.txt") do
		index = index + 1
		local width, indent, text = case:match("^(%d+)\t(%d+)\t(.*)$")
		local got = table.concat(wrapped(text, tonumber(width), tonumber(indent)), "\31")
		if got ~= expected[index] then
			differences = differences + 1
			first_difference = first_difference or string.format("case %d: %q -> %q, textwrap %q", index, text, got, expected[index])
		end
	end
	t.equal(index, 1900)
	t.equal(differences, 0, first_difference)
end)

t.test("twt_text_wrap: optimal fit moves a word down to even the lines out", function()
	-- the case seen in a real twt pane 39 columns wide
	t.equal(wrapped("how's you experience with rex?", 36, 11), { "how's you experience", "with rex?" })
	-- first fit would keep "with" on the first line
	t.equal(wrapped("how's you experience with rex?", 37, 11), { "how's you experience with", "rex?" })
end)

t.test("twt_text_wrap: a word longer than a line starts a new line and is cut", function()
	t.equal(wrapped("aaaaaaaaaaaaaaaaaaaaaaaa b", 10, 8), { "", "aaaaaaaaaa", "aaaaaaaaaa", "aaaa b" })
end)

t.test("twt_text_wrap: hyphens between letters are break points; a leading -- is not", function()
	t.equal(wrapped("well-known --flag", 9, 0), { "well-", "known", "--flag" })
end)

t.test("twt_text_wrap: an empty message is one empty line", function()
	t.equal(wrapped("", 20, 8), { "" })
end)

t.test("twt_text_wrap: a wider floor for a word keeps the line inside the width", function()
	-- "Kappa" drawn as a 9-cell image no longer fits beside "aaaa"
	local text = "aaaa Kappa"
	t.equal(#twt_text_wrap.wrap_text_like_twt(text, 13, 0), 1) -- as text, it fits in 13
	local lines = twt_text_wrap.wrap_text_like_twt(text, 13, 0, function(first, last)
		if text:sub(first, last) == "Kappa" then
			return 9
		end
		return last - first + 1
	end)
	t.equal(#lines, 2)
end)

t.test("twt_text_wrap: character widths come from unicode-width", function()
	t.equal(twt_text_wrap.unicode_character_width(0x41), 1)
	t.equal(twt_text_wrap.unicode_character_width(0x65E5), 2) -- 日
	t.equal(twt_text_wrap.unicode_character_width(0x1F600), 2) -- 😀
	t.equal(twt_text_wrap.unicode_character_width(0x0301), 0) -- combining acute
end)
