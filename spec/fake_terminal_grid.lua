-- A minimal terminal for pane specs: applies the escape sequences chat_pane writes and
-- keeps the resulting screen as rows of text.
--
--   local grid = require("fake_terminal_grid").new_fake_terminal_grid(40, 10)
--   grid:write(bytes)
--   grid:row_text(3)      -- the text on row 3, trailing spaces removed
--   grid.cursor_row, grid.cursor_column, grid.modes["?1049"]
--   grid:link_at(3, 10)   -- { url, id } of the OSC 8 hyperlink drawn in that cell, or nil

local terminal_text = require("twitch.terminal_text")

local M = {}

local Grid = {}
Grid.__index = Grid

function M.new_fake_terminal_grid(columns, rows)
	local self = setmetatable({ columns = columns, rows = rows, cursor_row = 1, cursor_column = 1, cells = {}, links = {}, modes = {}, graphics = {} }, Grid)
	self:clear()
	return self
end

function Grid:clear()
	for row = 1, self.rows do
		self.cells[row] = {}
		self.links[row] = {}
	end
end

function Grid:link_at(row, column)
	return (self.links[row] or {})[column]
end

function Grid:resize(columns, rows)
	self.columns, self.rows = columns, rows
	self:clear()
end

function Grid:row_text(row)
	local parts = {}
	local cells = self.cells[row] or {}
	for column = 1, self.columns do
		parts[column] = cells[column] or " "
	end
	return (table.concat(parts):gsub(" +$", ""))
end

function Grid:screen_text()
	local lines = {}
	for row = 1, self.rows do
		lines[row] = self:row_text(row)
	end
	return table.concat(lines, "\n")
end

local function put_cluster(self, cluster)
	if cluster.width == 0 then
		return
	end
	-- line wrapping is off: text past the right edge is dropped
	if self.cursor_column + cluster.width - 1 <= self.columns and self.cells[self.cursor_row] then
		self.cells[self.cursor_row][self.cursor_column] = cluster.text
		self.links[self.cursor_row][self.cursor_column] = self.hyperlink
		for extra = 1, cluster.width - 1 do
			self.cells[self.cursor_row][self.cursor_column + extra] = ""
			self.links[self.cursor_row][self.cursor_column + extra] = self.hyperlink
		end
	end
	-- with wrapping off, a real terminal leaves the cursor on the last column
	self.cursor_column = math.min(self.columns, self.cursor_column + cluster.width)
end

function Grid:write(bytes)
	local position, length = 1, #bytes
	while position <= length do
		local byte = bytes:byte(position)
		if byte == 27 then
			local next_char = bytes:sub(position + 1, position + 1)
			if next_char == "[" then
				local finish = bytes:find("[@-~]", position + 2)
				local parameters = bytes:sub(position + 2, finish - 1)
				local final = bytes:sub(finish, finish)
				if final == "H" then
					local row, column = parameters:match("^(%d+);(%d+)$")
					self.cursor_row, self.cursor_column = tonumber(row), tonumber(column)
				elseif final == "K" then
					local first = (parameters == "2") and 1 or self.cursor_column
					for column = first, self.columns do
						self.cells[self.cursor_row][column] = nil
						self.links[self.cursor_row][column] = nil
					end
				elseif final == "J" then
					self:clear()
				elseif final == "h" or final == "l" then
					self.modes[parameters] = final == "h"
				end
				position = finish + 1
			elseif next_char == "]" then
				-- OSC, ended by ST (ESC \\) or BEL; only OSC 8 hyperlinks are kept
				local st = bytes:find(string.char(27) .. "\\", position + 2, true)
				local bel = bytes:find(string.char(7), position + 2, true)
				local finish, terminator = st, 2
				if bel and (not st or bel < st) then
					finish, terminator = bel, 1
				end
				assert(finish, "fake_terminal_grid: unterminated OSC")
				local body = bytes:sub(position + 2, finish - 1)
				local parameters, url = body:match("^8;([^;]*);(.*)$")
				if parameters then
					self.hyperlink = url ~= "" and { url = url, id = parameters:match("id=([^:]*)") } or nil
				end
				position = finish + terminator
			elseif next_char == "_" then
				local finish = bytes:find(string.char(27) .. "\\", position + 2, true)
				self.graphics[#self.graphics + 1] = bytes:sub(position + 2, finish - 1)
				position = finish + 2
			else
				position = position + 2 -- ESC 7, ESC 8
			end
		elseif byte == 13 then
			self.cursor_column = 1
			position = position + 1
		elseif byte == 10 then
			self.cursor_row = self.cursor_row + 1
			position = position + 1
		else
			local finish = bytes:find(string.char(27), position, true) or (length + 1)
			for _, cluster in ipairs(terminal_text.split_display_clusters(bytes:sub(position, finish - 1))) do
				put_cluster(self, cluster)
			end
			position = finish
		end
	end
end

return M
