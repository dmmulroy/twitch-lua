local t = require("spec_helper")
local chat_feed_layout = require("twitch.tui.chat_feed_layout")

-- Rows as plain strings, emotes shown as <name>.
local function row_texts(rows)
	local lines = {}
	for index, row in ipairs(rows) do
		local parts = {}
		for _, span in ipairs(row) do
			parts[#parts + 1] = span.emote and ("<" .. span.text .. ">") or span.text
		end
		lines[index] = table.concat(parts)
	end
	return lines
end

local function message(text, extra)
	local entry = { kind = "message", entry_id = 1, name = "Viewer", login = "viewer", color = "#5B99FF", text = text, parts = { { type = "text", text = text } } }
	for key, value in pairs(extra or {}) do
		entry[key] = value
	end
	return entry
end

t.test("chat_feed_layout: wraps at word boundaries and never exceeds the width", function()
	local rows = chat_feed_layout.layout_chat_entry(message("hello there this is a long message that wraps"), 20)
	t.equal(row_texts(rows), { "Viewer: hello there", "this is a long", "message that wraps" })
	for _, row in ipairs(rows) do
		t.truthy(chat_feed_layout.row_width(row) <= 20)
	end
	t.equal(rows[1][1], { text = "Viewer", width = 6, style = "name", color = "#BC9FDF" })
	t.equal(rows[1][2].text, ": hello there")
	t.equal(rows[1][2].style, "text")
end)

t.test("chat_feed_layout: like twt, a word wider than the pane moves to the next row and is cut there; CJK by whole characters", function()
	t.equal(row_texts(chat_feed_layout.layout_chat_entry(message("aaaaaaaaaaaaaaaaaaaaaaaa b"), 10)), {
		"Viewer: ", "aaaaaaaaaa", "aaaaaaaaaa", "aaaa b",
	})
	local rows = chat_feed_layout.layout_chat_entry(message("日本語日本語"), 9)
	t.equal(row_texts(rows), { "Viewer: ", "日本語日", "本語" })
	t.equal(chat_feed_layout.row_width(rows[2]), 8)
end)

t.test("chat_feed_layout: like twt, spaces inside a row are kept and a row never ends in one", function()
	local rows = chat_feed_layout.layout_chat_entry(message("a   b      c"), 9)
	t.equal(row_texts(rows), { "Viewer: a", "b      c" })
end)

t.test("chat_feed_layout: escape codes in a message or a name cannot reach the terminal", function()
	local entry = message("x" .. string.char(27) .. "[2Jy", { name = "Bad" .. string.char(27) .. "]0;t" .. string.char(7) })
	local text = table.concat(row_texts(chat_feed_layout.layout_chat_entry(entry, 40)))
	t.equal(text:find(string.char(27), 1, true), nil)
	t.equal(text:find(string.char(7), 1, true), nil)
end)

t.test("chat_feed_layout: Twitch emote parts become emote spans when the emote is ready", function()
	local entry = message("hi Kappa there", {
		parts = {
			{ type = "text", text = "hi " },
			{ type = "emote", text = "Kappa", emote_id = "25" },
			{ type = "text", text = " there" },
		},
	})
	local asked = {}
	local ready = chat_feed_layout.layout_chat_entry(entry, 40, {
		resolve_emote = function(request)
			asked[#asked + 1] = request
			if request.id == "25" then
				return 2
			end
		end,
	})
	t.equal(row_texts(ready), { "Viewer: hi <Kappa> there" })
	local emote_span = ready[1][3]
	t.equal(emote_span.width, 2)
	t.equal(emote_span.emote.provider, "twitch")
	t.equal(emote_span.emote.id, "25")
	t.equal(chat_feed_layout.row_width(ready[1]), 8 + 3 + 2 + 6)
	-- not ready: the name is plain text
	local pending = chat_feed_layout.layout_chat_entry(entry, 40, { resolve_emote = function() end })
	t.equal(row_texts(pending), { "Viewer: hi Kappa there" })
end)

t.test("chat_feed_layout: plain words can be third-party emotes; names and mentions cannot", function()
	local entry = message("catJAM @catJAM nice", {
		name = "catJAM",
		parts = {
			{ type = "text", text = "catJAM " },
			{ type = "mention", text = "@catJAM", login = "catjam" },
			{ type = "text", text = " nice" },
		},
	})
	local rows = chat_feed_layout.layout_chat_entry(entry, 60, {
		resolve_emote = function(request)
			if request.word == "catJAM" or request.word == "@catJAM" then
				return 3
			end
		end,
	})
	t.equal(row_texts(rows), { "catJAM: <catJAM> @catJAM nice" })
end)

t.test("chat_feed_layout: an emote that does not fit moves to the next row whole", function()
	local entry = message("aaaa Kappa", { parts = { { type = "text", text = "aaaa " }, { type = "emote", text = "Kappa", emote_id = "25" } } })
	local rows = chat_feed_layout.layout_chat_entry(entry, 13, {
		resolve_emote = function(request)
			if request.id then
				return 2
			end
		end,
	})
	t.equal(row_texts(rows), { "Viewer: aaaa", "<Kappa>" })
end)

local function span_styles(row)
	local styles = {}
	for _, span in ipairs(row) do
		styles[#styles + 1] = span.style .. "=" .. span.text
	end
	return styles
end

t.test("chat_feed_layout: like twt, the person's login is highlighted and mentions and cheers look like text", function()
	local entry = message("@Other @Me Cheer100", {
		parts = {
			{ type = "mention", text = "@Other", login = "other" },
			{ type = "text", text = " " },
			{ type = "mention", text = "@Me", login = "me" },
			{ type = "text", text = " " },
			{ type = "cheermote", text = "Cheer100", bits = 100 },
		},
	})
	local rows = chat_feed_layout.layout_chat_entry(entry, 60, { own_login = "me" })
	t.equal(span_styles(rows[1]), { "name=Viewer", "text=: @Other ", "self_mention=@Me", "text= Cheer100" })
end)

t.test("chat_feed_layout: like twt, the login is found anywhere and in any case; only the first match takes its @", function()
	local entry = message("hi DILLON and xdillonx @dillon")
	local rows = chat_feed_layout.layout_chat_entry(entry, 80, { own_login = "dillon" })
	t.equal(span_styles(rows[1]), {
		"name=Viewer", "text=: hi ", "self_mention=DILLON", "text= and x", "self_mention=dillon", "text=x @", "self_mention=dillon",
	})
	local first = chat_feed_layout.layout_chat_entry(message("@dillon hi"), 80, { own_login = "dillon" })
	t.equal(span_styles(first[1]), { "name=Viewer", "text=: ", "self_mention=@dillon", "text= hi" })
	-- a highlighted word is still one word when wrapping
	local narrow = chat_feed_layout.layout_chat_entry(message("aaaa xdillonx"), 15, { own_login = "dillon" })
	t.equal(row_texts(narrow), { "Viewer: aaaa", "xdillonx" }) -- the highlight does not change where it wraps
	t.equal(chat_feed_layout.layout_chat_entry(message("dillon"), 40)[1][2].style, "text") -- no own_login, no highlight
end)

t.test("chat_feed_layout: badges are twt's emoji in front of the name", function()
	local rows = chat_feed_layout.layout_chat_entry(message("hi", { badges = { "subscriber/12", "moderator/1", "bot-badge/1", "vip/1", "premium/1" } }), 40)
	t.equal(row_texts(rows), { "⭐🔨💎👑Viewer: hi" })
	t.equal(rows[1][1].style, "name")
	t.equal(chat_feed_layout.row_width(rows[1]), 8 + 6 + 4)
	t.equal(chat_feed_layout.badge_emoji_prefix({ "broadcaster/1", "partner/1" }), "")
end)

t.test("chat_feed_layout: /me messages keep the name and are italic in its color", function()
	local rows = chat_feed_layout.layout_chat_entry(message("waves hello", { action = true }), 40)
	t.equal(row_texts(rows), { "Viewer: waves hello" })
	t.equal(rows[1][3], { text = "waves hello", width = 11, style = "action", color = "#BC9FDF" })
end)

t.test("chat_feed_layout: notices and status lines are Twitch: and System: lines", function()
	local notice = chat_feed_layout.layout_chat_entry({
		kind = "notice", text = "Viewer subscribed for 3 months!", name = "Viewer", login = "viewer",
		message_text = "love it", parts = { { type = "text", text = "love it" } },
	}, 50)
	t.equal(row_texts(notice), { "Twitch: Viewer subscribed for 3 months!", "Viewer: love it" })
	t.equal(notice[1][1], { text = "Twitch", width = 6, style = "system_author" })
	t.equal(row_texts(chat_feed_layout.layout_chat_entry({ kind = "status", level = "info", text = "Joined #dillon" }, 40)), { "Twitch: Joined #dillon" })
	local warning = chat_feed_layout.layout_chat_entry({ kind = "status", level = "warn", text = "Retrying in 2s." }, 40)
	t.equal(row_texts(warning), { "System: Retrying in 2s." })
	t.equal(warning[1][1].style, "system_author")
	t.equal(row_texts(chat_feed_layout.layout_chat_entry({ kind = "status", level = "error", text = "bad token" }, 40)), { "System: bad token" })
	t.equal(chat_feed_layout.layout_chat_entry({ kind = "delete" }, 40), {})
end)

t.test("chat_feed_layout: name colors are twt's pastel palette, picked by the name", function()
	-- these match twt's own hsl_to_rgb (checked against the Rust code for 311 names)
	t.equal(chat_feed_layout.name_color_from_author("StreamElements"), "#DFAA9F")
	t.equal(chat_feed_layout.name_color_from_author("Viewer"), "#BC9FDF")
	t.equal(chat_feed_layout.name_color_from_author("dillon"), "#CD9FDF")
	t.equal(chat_feed_layout.name_color_from_author("Nightbot"), "#A7DF9F")
	-- Twitch's own color is not used
	local rows = chat_feed_layout.layout_chat_entry(message("hi", { color = "#FF0000" }), 40)
	t.equal(rows[1][1].color, "#BC9FDF")
end)

local function entries_of(count)
	local entries = {}
	for index = 1, count do
		entries[index] = { kind = "status", entry_id = index, text = "line " .. index }
	end
	return entries
end

t.test("chat_feed_view: fills from the bottom, blank rows first", function()
	local view = chat_feed_layout.new_chat_feed_view()
	t.equal(row_texts(view:visible_feed_rows(entries_of(2), 30, 4)), { "", "", "Twitch: line 1", "Twitch: line 2" })
	t.equal(row_texts(view:visible_feed_rows(entries_of(6), 30, 3)), { "Twitch: line 4", "Twitch: line 5", "Twitch: line 6" })
end)

t.test("chat_feed_view: scrolling up holds its place as messages arrive and counts them", function()
	local view = chat_feed_layout.new_chat_feed_view()
	local entries = entries_of(10)
	view:visible_feed_rows(entries, 30, 3)
	t.equal(view:scroll_feed(2), true)
	t.equal(row_texts(view:visible_feed_rows(entries, 30, 3)), { "Twitch: line 6", "Twitch: line 7", "Twitch: line 8" })
	entries[11] = { kind = "status", entry_id = 11, text = "line 11" }
	entries[12] = { kind = "status", entry_id = 12, text = "long status that wraps here" } -- two rows at 30 wide
	t.equal(row_texts(view:visible_feed_rows(entries, 30, 3)), { "Twitch: line 6", "Twitch: line 7", "Twitch: line 8" })
	t.equal(view.unseen_entries, 2)
	t.equal(view:scroll_to_newest(), true)
	local rows = row_texts(view:visible_feed_rows(entries, 30, 3))
	t.equal(rows[1], "Twitch: line 11")
	t.equal(view.unseen_entries, 0)
end)

t.test("chat_feed_view: cannot scroll past the oldest row", function()
	local view = chat_feed_layout.new_chat_feed_view()
	local entries = entries_of(5)
	view:scroll_feed(100)
	t.equal(row_texts(view:visible_feed_rows(entries, 30, 3)), { "Twitch: line 1", "Twitch: line 2", "Twitch: line 3" })
	t.equal(view.scroll_offset, 2)
	t.equal(view:scroll_feed(-100), true)
	t.equal(view.scroll_offset, 0)
	t.equal(view:scroll_feed(-1), false)
end)

t.test("chat_feed_view: a changed width or new emotes lay the entry out again", function()
	local view = chat_feed_layout.new_chat_feed_view()
	local entry = message("one two three four five")
	t.equal(#view:visible_feed_rows({ entry }, 40, 2)[2], 2)
	t.equal(row_texts(view:visible_feed_rows({ entry }, 16, 2)), { "Viewer: one two", "three four five" })
	local calls = 0
	local opts = { emote_revision = 1, resolve_emote = function() calls = calls + 1 end }
	view:visible_feed_rows({ entry }, 40, 2, opts)
	local after_first = calls
	view:visible_feed_rows({ entry }, 40, 2, opts)
	t.equal(calls, after_first) -- cached
	opts.emote_revision = 2
	view:visible_feed_rows({ entry }, 40, 2, opts)
	t.truthy(calls > after_first)
end)
