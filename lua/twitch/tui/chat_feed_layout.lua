-- Lays chat entries out as rows of styled spans that fit a pane's width, and picks the
-- rows that are on screen. No I/O and no escape codes: the pane turns spans into output.
--
--   local chat_feed_layout = require("twitch.tui.chat_feed_layout")
--   local rows = chat_feed_layout.layout_chat_entry(entry, width, opts)
--   local view = chat_feed_layout.new_chat_feed_view()
--   local visible = view:visible_feed_rows(store.entries, width, height, opts)
--
-- A row is a list of spans: { text, width, style, color, emote }.
--   style: "name", "text", "mention", "self_mention", "cheer", "notice", "deleted",
--          "status_info", "status_warn", "status_error", "action", "marker"
--   color: "#RRGGBB" for "name" and "action" spans
--   emote: { key, columns } when the span is an emote image; `text` is then its name
-- opts:
--   own_login       the person's login; a message that mentions it is marked
--   resolve_emote   fn(emote_request) -> columns | nil. emote_request is
--                   { provider = "twitch", id, animated } for an emote part, or
--                   { word = "text" } for a plain word that may be a third-party emote.
--                   nil means "not an emote, or not ready": the name is drawn as text.
--   emote_revision  changes whenever resolve_emote's answers may have changed

local terminal_text = require("twitch.terminal_text")

local M = {}

-- Twitch gives people without a chosen color one of these, picked by their name.
local DEFAULT_NAME_COLORS = {
	"#FF0000", "#0000FF", "#008000", "#B22222", "#FF7F50", "#9ACD32", "#FF4500", "#2E8B57",
	"#DAA520", "#D2691E", "#5F9EA0", "#1E90FF", "#FF69B4", "#8A2BE2", "#00FF7F",
}
-- Name colors darker than this are lightened so they can be read on a dark background.
local MIN_NAME_BRIGHTNESS = 110
local DELETED_MESSAGE_TEXT = "<message deleted>"

local function parse_hex_color(color)
	local red, green, blue = tostring(color):match("^#(%x%x)(%x%x)(%x%x)$")
	if not red then
		return nil
	end
	return tonumber(red, 16), tonumber(green, 16), tonumber(blue, 16)
end

--- A name color that is readable on a dark background: the person's own color, lightened
--- if it is too dark, or a default picked from their login when they have none.
function M.readable_name_color(color, login)
	local red, green, blue = parse_hex_color(color)
	if not red then
		local hash = 0
		for index = 1, #(login or "") do
			hash = (hash * 31 + login:byte(index)) % 65536
		end
		red, green, blue = parse_hex_color(DEFAULT_NAME_COLORS[hash % #DEFAULT_NAME_COLORS + 1])
	end
	for _ = 1, 12 do
		if 0.299 * red + 0.587 * green + 0.114 * blue >= MIN_NAME_BRIGHTNESS then
			break
		end
		red = math.floor(red + (255 - red) * 0.25)
		green = math.floor(green + (255 - green) * 0.25)
		blue = math.floor(blue + (255 - blue) * 0.25)
	end
	return string.format("#%02X%02X%02X", red, green, blue)
end

-- A token is one unbreakable piece: a word, a run of spaces, or an emote.
local function word_token(text, style, color)
	return { text = text, width = terminal_text.display_width(text), style = style, color = color }
end

local function add_text_tokens(tokens, text, style, color, resolve_emote)
	local position, length = 1, #text
	while position <= length do
		local space_end = text:match("^ +()", position)
		if space_end then
			tokens[#tokens + 1] = { text = " ", width = 1, style = style, color = color, space = true }
			position = space_end
		else
			local word_end = text:find(" ", position, true) or (length + 1)
			local word = text:sub(position, word_end - 1)
			local columns = resolve_emote and style == "text" and resolve_emote({ word = word }) or nil
			if columns then
				tokens[#tokens + 1] = { text = word, width = columns, style = "text", emote = { word = word, columns = columns } }
			else
				tokens[#tokens + 1] = word_token(word, style, color)
			end
			position = word_end
		end
	end
end

local function add_part_tokens(tokens, parts, opts, text_style, color)
	local resolve_emote = opts.resolve_emote
	for _, part in ipairs(parts or {}) do
		local text = terminal_text.sanitize_chat_text(part.text or "")
		if part.type == "emote" then
			local request = { provider = "twitch", id = part.emote_id, animated = part.animated }
			local columns = resolve_emote and resolve_emote(request) or nil
			if columns then
				request.columns = columns
				tokens[#tokens + 1] = { text = text, width = columns, style = "text", emote = request }
			else
				add_text_tokens(tokens, text, text_style, color, nil)
			end
		elseif part.type == "mention" then
			local is_self = opts.own_login and part.login == opts.own_login
			add_text_tokens(tokens, text, is_self and "self_mention" or "mention", nil, nil)
		elseif part.type == "cheermote" then
			add_text_tokens(tokens, text, "cheer", nil, nil)
		else
			add_text_tokens(tokens, text, text_style, color, text_style == "text" and resolve_emote or nil)
		end
	end
end

local function push_span(row, token, text, width)
	local last = row[#row]
	if last and not token.emote and not last.emote and last.style == token.style and last.color == token.color then
		last.text = last.text .. text
		last.width = last.width + width
	else
		row[#row + 1] = { text = text, width = width, style = token.style, color = token.color, emote = token.emote }
	end
end

local function row_width(row)
	local width = 0
	for _, span in ipairs(row) do
		width = width + span.width
	end
	return width
end

-- Greedy word wrap. A word wider than the pane is split between clusters.
local function wrap_tokens(tokens, width)
	local rows = { {} }
	local used = 0
	local function new_row()
		-- drop a trailing space span before leaving the row
		local row = rows[#rows]
		local last = row[#row]
		if last and last.text:sub(-1) == " " and not last.emote then
			last.text = last.text:sub(1, -2)
			last.width = last.width - 1
			if last.width <= 0 then
				row[#row] = nil
			end
		end
		rows[#rows + 1] = {}
		used = 0
	end
	for _, token in ipairs(tokens) do
		if token.space then
			if used > 0 and used < width then
				push_span(rows[#rows], token, " ", 1)
				used = used + 1
			end
		elseif token.width <= width - used then
			push_span(rows[#rows], token, token.text, token.width)
			used = used + token.width
		elseif token.width <= width then
			-- it did not fit in what is left of this row, so the row is not empty
			new_row()
			push_span(rows[#rows], token, token.text, token.width)
			used = token.width
		else
			-- Wider than the whole pane: split between clusters. An emote that wide is
			-- drawn as its name.
			local piece = token
			if token.emote then
				piece = { text = token.text, style = "text" }
			end
			for _, cluster in ipairs(terminal_text.split_display_clusters(piece.text)) do
				if cluster.width > width - used and used > 0 then
					new_row()
				end
				if cluster.width <= width then
					push_span(rows[#rows], piece, cluster.text, cluster.width)
					used = used + cluster.width
				end
			end
		end
	end
	-- trailing space on the last row
	local row = rows[#rows]
	local last = row[#row]
	if last and not last.emote and last.text:sub(-1) == " " then
		last.text = last.text:sub(1, -2)
		last.width = last.width - 1
		if last.width <= 0 then
			row[#row] = nil
		end
	end
	if #rows > 1 and #rows[#rows] == 0 then
		rows[#rows] = nil
	end
	return rows
end

local function mentions_login(entry, own_login)
	if not own_login then
		return false
	end
	for _, part in ipairs(entry.parts or {}) do
		if part.type == "mention" and part.login == own_login then
			return true
		end
	end
	return false
end

local function message_tokens(entry, opts)
	local tokens = {}
	local color = M.readable_name_color(entry.color, entry.login or entry.name)
	local name = terminal_text.sanitize_chat_text(entry.name or entry.login or "?")
	if mentions_login(entry, opts.own_login) then
		tokens[#tokens + 1] = word_token("▎", "marker")
	end
	if entry.deleted then
		tokens[#tokens + 1] = word_token(name .. ":", "name", color)
		tokens[#tokens + 1] = { text = " ", width = 1, style = "deleted", space = true }
		add_text_tokens(tokens, DELETED_MESSAGE_TEXT, "deleted", nil, nil)
		return tokens
	end
	if entry.action then
		-- "/me waves": the whole line is in the person's color, with no colon
		tokens[#tokens + 1] = word_token(name, "name", color)
		tokens[#tokens + 1] = { text = " ", width = 1, style = "action", color = color, space = true }
		add_part_tokens(tokens, entry.parts, opts, "action", color)
		return tokens
	end
	tokens[#tokens + 1] = word_token(name .. ":", "name", color)
	tokens[#tokens + 1] = { text = " ", width = 1, style = "text", space = true }
	if entry.parts and #entry.parts > 0 then
		add_part_tokens(tokens, entry.parts, opts, "text", nil)
	else
		add_text_tokens(tokens, terminal_text.sanitize_chat_text(entry.text or ""), "text", nil, opts.resolve_emote)
	end
	return tokens
end

--- Lays one chat entry out as rows no wider than `width` cells.
function M.layout_chat_entry(entry, width, opts)
	opts = opts or {}
	width = math.max(1, width)
	if entry.kind == "message" then
		return wrap_tokens(message_tokens(entry, opts), width)
	elseif entry.kind == "notice" then
		local tokens = {}
		add_text_tokens(tokens, "✦ " .. terminal_text.sanitize_chat_text(entry.text or ""), "notice", nil, nil)
		local rows = wrap_tokens(tokens, width)
		if entry.message_text then
			local message = {
				kind = "message", name = entry.name, login = entry.login, color = entry.color,
				parts = entry.parts, text = entry.message_text, deleted = entry.deleted,
			}
			for _, row in ipairs(wrap_tokens(message_tokens(message, opts), width)) do
				rows[#rows + 1] = row
			end
		end
		return rows
	elseif entry.kind == "status" then
		local style = (entry.level == "error" and "status_error") or (entry.level == "warn" and "status_warn") or "status_info"
		local tokens = {}
		add_text_tokens(tokens, "· " .. terminal_text.sanitize_chat_text(entry.text or ""), style, nil, nil)
		return wrap_tokens(tokens, width)
	end
	return {}
end

local View = {}
View.__index = View

--- Creates the scrolling view of a chat feed. Keeps laid-out rows per entry so that only
--- new or changed entries are laid out again.
function M.new_chat_feed_view()
	return setmetatable({
		scroll_offset = 0, -- rows scrolled up from the newest row; 0 follows new messages
		unseen_entries = 0, -- entries that arrived while scrolled up
		cached_rows = {}, -- entry_id -> { rows, width, deleted, emote_revision, text }
		last_entry_id = nil,
	}, View)
end

local function entry_rows(self, entry, width, opts)
	local cached = self.cached_rows[entry.entry_id]
	if cached and cached.width == width and cached.deleted == entry.deleted
		and cached.emote_revision == opts.emote_revision and cached.text == entry.text then
		return cached.rows
	end
	local rows = M.layout_chat_entry(entry, width, opts)
	self.cached_rows[entry.entry_id] = {
		rows = rows, width = width, deleted = entry.deleted, emote_revision = opts.emote_revision, text = entry.text,
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
