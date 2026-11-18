-- Lays chat entries out as rows of styled spans that fit a pane's width, and picks the
-- rows that are on screen. Copies twitch-tui's (twt's) look:
--   ⭐🔨Name: message text                 badges as emoji, then the name, then ": "
--   Twitch: Joined #dillon                  connection and Twitch notices; "System" for problems
-- Name colors are twt's pastel palette, picked from the name (Twitch's colors are not used).
-- Your own login inside a message is highlighted; /me messages are italic in the name's color.
-- No I/O and no escape codes: the pane turns spans into output.
--
--   local chat_feed_layout = require("twitch.tui.chat_feed_layout")
--   local rows = chat_feed_layout.layout_chat_entry(entry, width, opts)
--   local view = chat_feed_layout.new_chat_feed_view()
--   local visible = view:visible_feed_rows(store.entries, width, height, opts)
--
-- A row is a list of spans: { text, width, style, color, emote }.
--   style: "name", "text", "action", "self_mention", "system_author"
--   color: "#RRGGBB" for "name" and "action" spans
--   emote: { key, columns } when the span is an emote image; `text` is then its name
-- opts:
--   own_login       the person's login; where it appears in a message it is highlighted
--   resolve_emote   fn(emote_request) -> columns | nil. emote_request is
--                   { provider = "twitch", id, animated } for an emote part, or
--                   { word = "text" } for a plain word that may be a third-party emote.
--                   nil means "not an emote, or not ready": the name is drawn as text.
--   emote_revision  changes whenever resolve_emote's answers may have changed

local terminal_text = require("twitch.terminal_text")
local twt_text_wrap = require("twitch.tui.twt_text_wrap")

local M = {}

-- twt's badges: these four badge sets, as emoji, in the order Twitch lists them.
local BADGE_EMOJI = {
	vip = "💎",
	moderator = "🔨",
	subscriber = "⭐",
	premium = "👑",
}

-- twt's hsl_to_rgb (src/utils/colors.rs), including how it rounds and truncates.
local function hsl_to_rgb(hue, saturation, lightness)
	local chroma = (1 - math.abs(2 * lightness - 1)) * saturation
	local x = chroma * (1 - math.abs(math.fmod(hue / 60, 2) - 1))
	local m = lightness - chroma / 2
	local section = math.floor(hue + 0.5)
	local red, green, blue
	if section >= 61 and section <= 120 then
		red, green, blue = x, chroma, 0
	elseif section >= 121 and section <= 180 then
		red, green, blue = 0, chroma, x
	elseif section >= 181 and section <= 240 then
		red, green, blue = 0, x, chroma
	elseif section >= 241 and section <= 300 then
		red, green, blue = x, 0, chroma
	elseif section >= 301 and section <= 360 then
		red, green, blue = chroma, 0, x
	else
		red, green, blue = chroma, x, 0
	end
	local function channel(value)
		return math.max(0, math.min(255, math.floor((value + m) * 255)))
	end
	return channel(red), channel(green), channel(blue)
end

--- A name's color, as twt picks it with its default "pastel" palette: the sum of the
--- name's bytes picks the hue. The same name always gets the same color.
function M.name_color_from_author(name)
	local sum = 0
	for index = 1, #(name or "") do
		sum = sum + name:byte(index)
	end
	local red, green, blue = hsl_to_rgb(sum % 360 + 1, 0.5, 0.75)
	return string.format("#%02X%02X%02X", red, green, blue)
end

--- The emoji twt puts in front of a name for its badges ("moderator/1" -> "🔨").
function M.badge_emoji_prefix(badges)
	local parts = {}
	for _, badge in ipairs(badges or {}) do
		local emoji = BADGE_EMOJI[tostring(badge):match("^([^/]+)")]
		if emoji then
			parts[#parts + 1] = emoji
		end
	end
	return table.concat(parts)
end

-- A segment is a run of the message with one look: { text, style, color, emote }.
-- `emote` is the request for an emote image; the segment's text is the emote's name.
local function add_text_segments(segments, text, style, color, resolve_emote)
	if not resolve_emote then
		segments[#segments + 1] = { text = text, style = style, color = color }
		return
	end
	-- third-party emotes are whole words between spaces
	local position, length = 1, #text
	local plain_start = 1
	while position <= length do
		local word_start, word_end = text:find("[^ ]+", position)
		if not word_start then
			break
		end
		local word = text:sub(word_start, word_end)
		local columns = resolve_emote({ word = word })
		if columns then
			if word_start > plain_start then
				segments[#segments + 1] = { text = text:sub(plain_start, word_start - 1), style = style, color = color }
			end
			segments[#segments + 1] = { text = word, style = "text", emote = { word = word, columns = columns } }
			plain_start = word_end + 1
		end
		position = word_end + 1
	end
	if plain_start <= length then
		segments[#segments + 1] = { text = text:sub(plain_start), style = style, color = color }
	end
end

local function message_segments(entry, opts, style, color)
	local segments = {}
	local parts = entry.parts
	if not parts or #parts == 0 then
		parts = { { type = "text", text = entry.text or "" } }
	end
	for _, part in ipairs(parts) do
		local text = terminal_text.sanitize_chat_text(part.text or "")
		if part.type == "emote" then
			local request = { provider = "twitch", id = part.emote_id, animated = part.animated }
			local columns = opts.resolve_emote and opts.resolve_emote(request) or nil
			if columns then
				request.columns = columns
				segments[#segments + 1] = { text = text, style = "text", emote = request }
			else
				segments[#segments + 1] = { text = text, style = style, color = color }
			end
		elseif part.type == "text" then
			add_text_segments(segments, text, style, color, opts.resolve_emote)
		else
			-- mentions and cheers look like the rest of the message, as in twt
			segments[#segments + 1] = { text = text, style = style, color = color }
		end
	end
	return segments
end

-- Byte ranges of the payload to highlight as the person's login, as twt finds them: every
-- case-insensitive match, plus the "@" before the first one.
local function login_highlight_ranges(payload, own_login)
	local ranges = {}
	if not own_login or own_login == "" then
		return ranges
	end
	local lower_payload, lower_login = payload:lower(), own_login:lower()
	local position = 1
	while true do
		local first, last = lower_payload:find(lower_login, position, true)
		if not first then
			break
		end
		if #ranges == 0 and first > 1 and payload:sub(first - 1, first - 1) == "@" then
			first = first - 1
		end
		ranges[#ranges + 1] = { first, last }
		position = last + 1
	end
	return ranges
end

local function push_span(row, span)
	local last = row[#row]
	if last and not span.emote and not last.emote and last.style == span.style and last.color == span.color then
		last.text = last.text .. span.text
		last.width = last.width + span.width
	elseif span.width > 0 or span.emote then
		row[#row + 1] = span
	end
end

-- Lays a twt chat line out: "author: payload", wrapped where twt wraps it.
local function layout_twt_line(author_spans, author_bytes, segments, width, own_login)
	local parts, offsets = {}, {}
	local length = 0
	for index, segment in ipairs(segments) do
		parts[index] = segment.text
		offsets[index] = length + 1
		length = length + #segment.text
	end
	local payload = table.concat(parts)
	local highlights = login_highlight_ranges(payload, own_login)

	local emote_columns_at = {} -- first byte -> { last byte, columns }
	for index, segment in ipairs(segments) do
		if segment.emote then
			emote_columns_at[offsets[index]] = { offsets[index] + #segment.text - 1, segment.emote.columns }
		end
	end
	-- no wrapped line may come out wider than it is drawn
	local function word_width_floor(first, last)
		local emote = emote_columns_at[first]
		if emote and emote[1] == last then
			return emote[2]
		end
		return terminal_text.display_width(payload:sub(first, last))
	end

	-- twt reserves the prefix's length in bytes on the first line
	local lines = twt_text_wrap.wrap_text_like_twt(payload, width, author_bytes + 2, word_width_floor)

	local function is_highlighted(byte_position)
		for _, range in ipairs(highlights) do
			if byte_position >= range[1] and byte_position <= range[2] then
				return true
			end
		end
		return false
	end

	local rows = {}
	for line_index, line in ipairs(lines) do
		local row = {}
		if line_index == 1 then
			for _, span in ipairs(author_spans) do
				push_span(row, span)
			end
		end
		for index, segment in ipairs(segments) do
			local segment_first = offsets[index]
			local segment_last = segment_first + #segment.text - 1
			local first, last = math.max(segment_first, line.first), math.min(segment_last, line.last)
			if first <= last then
				if segment.emote and first == segment_first and last == segment_last then
					push_span(row, { text = segment.text, width = segment.emote.columns, style = "text", emote = segment.emote })
				else
					-- split by the login highlight
					local run_start = first
					local run_highlighted = not segment.emote and is_highlighted(first)
					for position = first + 1, last + 1 do
						local highlighted = position <= last and not segment.emote and is_highlighted(position)
						if position > last or highlighted ~= run_highlighted then
							local text = payload:sub(run_start, position - 1)
							push_span(row, {
								text = text,
								width = terminal_text.display_width(text),
								style = run_highlighted and "self_mention" or (segment.emote and "text" or segment.style),
								color = (not run_highlighted and not segment.emote) and segment.color or nil,
							})
							run_start, run_highlighted = position, highlighted
						end
					end
				end
			end
		end
		if line.penalty ~= "" then
			push_span(row, { text = line.penalty, width = 1, style = "text" })
		end
		rows[#rows + 1] = row
	end
	return rows
end

-- "Name: " with the badges in front, in the name's color; ": " is in the text color.
local function author_spans_of(name, badges)
	local display = terminal_text.sanitize_chat_text(name or "?")
	local author = M.badge_emoji_prefix(badges) .. display
	return {
		{ text = author, width = terminal_text.display_width(author), style = "name", color = M.name_color_from_author(display) },
		{ text = ": ", width = 2, style = "text" },
	}, #author
end

local function layout_message(entry, width, opts)
	local spans, author_bytes = author_spans_of(entry.name or entry.login, entry.badges)
	-- "/me waves": the message is italic in the name's color
	local style, color = "text", nil
	if entry.action then
		style, color = "action", spans[1].color
	end
	return layout_twt_line(spans, author_bytes, message_segments(entry, opts, style, color), width, opts.own_login)
end

-- "Twitch: text" or "System: text", the author in bold red.
local function layout_system_line(author, text, width)
	local spans = { { text = author, width = #author, style = "system_author" }, { text = ": ", width = 2, style = "text" } }
	return layout_twt_line(spans, #author, { { text = terminal_text.sanitize_chat_text(text or ""), style = "text" } }, width, nil)
end

--- Lays one chat entry out as rows no wider than `width` cells (twt's wrap width).
function M.layout_chat_entry(entry, width, opts)
	opts = opts or {}
	width = math.max(1, width)
	if entry.kind == "message" then
		return layout_message(entry, width, opts)
	elseif entry.kind == "notice" then
		local rows = layout_system_line("Twitch", entry.text, width)
		if entry.message_text then
			local message = {
				kind = "message", name = entry.name, login = entry.login, badges = entry.badges,
				parts = entry.parts, text = entry.message_text,
			}
			for _, row in ipairs(layout_message(message, width, opts)) do
				rows[#rows + 1] = row
			end
		end
		return rows
	elseif entry.kind == "status" then
		-- twt: notices from Twitch are "Twitch:", problems are "System:"
		local author = (entry.level == "warn" or entry.level == "error") and "System" or "Twitch"
		return layout_system_line(author, entry.text, width)
	end
	return {}
end

local function row_width(row)
	local width = 0
	for _, span in ipairs(row) do
		width = width + span.width
	end
	return width
end

local View = {}
View.__index = View

--- Creates the scrolling view of a chat feed. Keeps laid-out rows per entry so that only
--- new or changed entries are laid out again.
function M.new_chat_feed_view()
	return setmetatable({
		scroll_offset = 0, -- rows scrolled up from the newest row; 0 follows new messages
		unseen_entries = 0, -- entries that arrived while scrolled up
		cached_rows = {}, -- entry_id -> { rows, width, emote_revision, text }
		last_entry_id = nil,
	}, View)
end

local function entry_rows(self, entry, width, opts)
	local cached = self.cached_rows[entry.entry_id]
	if cached and cached.width == width and cached.emote_revision == opts.emote_revision and cached.text == entry.text then
		return cached.rows
	end
	local rows = M.layout_chat_entry(entry, width, opts)
	self.cached_rows[entry.entry_id] = {
		rows = rows, width = width, emote_revision = opts.emote_revision, text = entry.text,
	}
	return rows
end

--- Returns exactly `height` rows for the feed area, oldest at the top, blank rows first
--- when the chat is shorter than the area. Scrolled up, the view stays on the same rows as
--- new entries arrive and counts them in `unseen_entries`.
function View:visible_feed_rows(entries, width, height, opts)
	opts = opts or {}
	local newest = entries[#entries]
	local newest_id = newest and newest.entry_id or nil

	-- Entries that arrived since the last call push a scrolled-up view further from the bottom.
	if self.scroll_offset > 0 and self.last_entry_id and newest_id and newest_id > self.last_entry_id then
		for index = #entries, 1, -1 do
			local entry = entries[index]
			if entry.entry_id <= self.last_entry_id then
				break
			end
			self.scroll_offset = self.scroll_offset + #entry_rows(self, entry, width, opts)
			self.unseen_entries = self.unseen_entries + 1
		end
	end
	self.last_entry_id = newest_id or self.last_entry_id

	-- Walk back from the newest entry until the area and the scroll offset are covered.
	local needed = height + self.scroll_offset
	local collected, count = {}, 0
	local live_ids = {}
	for index = #entries, 1, -1 do
		local entry = entries[index]
		live_ids[entry.entry_id] = true
		if count < needed then
			local rows = entry_rows(self, entry, width, opts)
			for row_index = #rows, 1, -1 do
				count = count + 1
				collected[count] = rows[row_index]
			end
		end
	end
	for entry_id in pairs(self.cached_rows) do
		if not live_ids[entry_id] then
			self.cached_rows[entry_id] = nil
		end
	end

	-- Cannot scroll past the oldest row.
	local max_offset = math.max(0, count - height)
	if self.scroll_offset > max_offset then
		self.scroll_offset = max_offset
	end
	if self.scroll_offset == 0 then
		self.unseen_entries = 0
	end

	local visible = {}
	for row = 1, height do
		-- collected[1] is the newest row; the bottom screen row shows collected[scroll_offset + 1]
		local source = collected[self.scroll_offset + (height - row) + 1]
		visible[row] = source or {}
	end
	return visible
end

--- Scrolls by `rows` (positive is toward older messages). Returns true when it moved; the
--- next visible_feed_rows call clamps the offset to the chat's length.
function View:scroll_feed(rows)
	local target = math.max(0, self.scroll_offset + rows)
	if target == self.scroll_offset then
		return false
	end
	self.scroll_offset = target
	return true
end

--- Jumps back to the newest message.
function View:scroll_to_newest()
	local moved = self.scroll_offset ~= 0
	self.scroll_offset = 0
	self.unseen_entries = 0
	return moved
end

M.row_width = row_width

return M
