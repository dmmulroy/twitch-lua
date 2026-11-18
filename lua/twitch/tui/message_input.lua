-- The line being typed in a chat pane: editing, history, and the part that fits on screen.
-- No I/O.
--
--   local message_input = require("twitch.tui.message_input")
--   local input = message_input.new_message_input({ max_characters = 500 })
--   input:insert_text("hello")
--   local text = input:take_message()          -- returns the text and clears the line
--   local visible, cursor_column = input:visible_window(width)

local terminal_text = require("twitch.terminal_text")

local M = {}

-- Twitch refuses chat messages longer than 500 characters.
M.TWITCH_MESSAGE_CHARACTER_LIMIT = 500
local HISTORY_LIMIT = 50

local Input = {}
Input.__index = Input

--- Creates an empty input line.
function M.new_message_input(opts)
	opts = opts or {}
	return setmetatable({
		clusters = {}, -- display clusters of the line, in order
		cursor = 0, -- number of clusters before the cursor
		max_characters = opts.max_characters or M.TWITCH_MESSAGE_CHARACTER_LIMIT,
		history = {}, -- sent messages, oldest first
		history_position = nil, -- index into history while browsing it
		draft = nil, -- the unsent line saved while browsing history
	}, Input)
end

local function clusters_text(clusters, first, last)
	local parts = {}
	for index = first or 1, last or #clusters do
		parts[#parts + 1] = clusters[index].text
	end
	return table.concat(parts)
end

--- The whole line as text.
function Input:text()
	return clusters_text(self.clusters)
end

function Input:is_empty()
	return #self.clusters == 0
end

--- Inserts text at the cursor. Control characters are removed; text past the character
--- limit is dropped. Returns true when anything was inserted.
function Input:insert_text(text)
	local incoming = terminal_text.split_display_clusters(terminal_text.sanitize_chat_text(text))
	local room = self.max_characters - #self.clusters
	local inserted = 0
	for _, cluster in ipairs(incoming) do
		if inserted >= room then
			break
		end
		inserted = inserted + 1
		table.insert(self.clusters, self.cursor + inserted, cluster)
	end
	self.cursor = self.cursor + inserted
	return inserted > 0
end

local function replace_line(self, text)
	self.clusters = terminal_text.split_display_clusters(text)
	self.cursor = #self.clusters
end

function Input:delete_before_cursor()
	if self.cursor == 0 then
		return false
	end
	table.remove(self.clusters, self.cursor)
	self.cursor = self.cursor - 1
	return true
end

function Input:delete_at_cursor()
	if self.cursor >= #self.clusters then
		return false
	end
	table.remove(self.clusters, self.cursor + 1)
	return true
end

function Input:move_cursor(delta)
	self.cursor = math.max(0, math.min(#self.clusters, self.cursor + delta))
end

function Input:move_cursor_to_start()
	self.cursor = 0
end

function Input:move_cursor_to_end()
	self.cursor = #self.clusters
end

local function is_space(cluster)
	return cluster.text == " "
end

-- The cursor position one word to the left.
local function word_start_before(self)
	local position = self.cursor
	while position > 0 and is_space(self.clusters[position]) do
		position = position - 1
	end
	while position > 0 and not is_space(self.clusters[position]) do
		position = position - 1
	end
	return position
end

function Input:move_cursor_word_left()
	self.cursor = word_start_before(self)
end

function Input:move_cursor_word_right()
	local position, count = self.cursor, #self.clusters
	while position < count and is_space(self.clusters[position + 1]) do
		position = position + 1
	end
	while position < count and not is_space(self.clusters[position + 1]) do
		position = position + 1
	end
	self.cursor = position
end

--- Deletes the word before the cursor (Ctrl-W).
function Input:delete_word_before_cursor()
	local start = word_start_before(self)
	if start == self.cursor then
		return false
	end
	for _ = start + 1, self.cursor do
		table.remove(self.clusters, start + 1)
	end
	self.cursor = start
	return true
end

--- Deletes from the start of the line to the cursor (Ctrl-U).
function Input:delete_to_line_start()
	if self.cursor == 0 then
		return false
	end
	for _ = 1, self.cursor do
		table.remove(self.clusters, 1)
	end
	self.cursor = 0
	return true
end

--- Deletes from the cursor to the end of the line (Ctrl-K).
function Input:delete_to_line_end()
	if self.cursor >= #self.clusters then
		return false
	end
	for _ = self.cursor + 1, #self.clusters do
		table.remove(self.clusters)
	end
	return true
end

--- Returns the trimmed line and clears it, remembering it in the history. Returns nil
--- when the line is blank.
function Input:take_message()
	local text = self:text():match("^%s*(.-)%s*$")
	self.clusters, self.cursor = {}, 0
	self.history_position, self.draft = nil, nil
	if text == "" then
		return nil
	end
	if self.history[#self.history] ~= text then
		self.history[#self.history + 1] = text
		if #self.history > HISTORY_LIMIT then
			table.remove(self.history, 1)
		end
	end
	return text
end

--- Puts text back on the line, for a message that could not be sent.
function Input:restore_message(text)
	replace_line(self, text)
end

--- Steps through sent messages: -1 is older, +1 is newer. The unsent line comes back
--- after the newest. Returns true when the line changed.
function Input:browse_history(direction)
	if #self.history == 0 then
		return false
	end
	if not self.history_position then
		if direction > 0 then
			return false
		end
		self.draft = self:text()
		self.history_position = #self.history
	else
		local position = self.history_position + direction
		if position < 1 then
			return false
		end
		if position > #self.history then
			self.history_position = nil
			replace_line(self, self.draft or "")
			self.draft = nil
			return true
		end
		self.history_position = position
	end
	replace_line(self, self.history[self.history_position])
	return true
end

--- The part of the line that fits in `width` cells with the cursor kept in view.
--- Returns the visible text and the cursor's column within it (0 is the first cell).
function Input:visible_window(width)
	if width <= 0 then
		return "", 0
	end
	-- cells before the cursor
	local before = 0
	for index = 1, self.cursor do
		before = before + self.clusters[index].width
	end
	-- scroll so the cursor sits inside the window, with one cell spare for the cursor itself
	local first, skipped = 1, 0
	while before - skipped > width - 1 and first <= self.cursor do
		skipped = skipped + self.clusters[first].width
		first = first + 1
	end
	local parts, used = {}, 0
	for index = first, #self.clusters do
		local cluster = self.clusters[index]
		if used + cluster.width > width then
			break
		end
		used = used + cluster.width
		parts[#parts + 1] = cluster.text
	end
	return table.concat(parts), before - skipped
end

return M
