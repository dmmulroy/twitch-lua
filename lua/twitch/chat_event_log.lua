-- The chat event log file: the one connection appends chat events to it, and every pane
-- follows it with `tail -F`. One JSON object per line, each with a rising `seq`.
--
--   local chat_event_log = require("twitch.chat_event_log")
--   local log = chat_event_log.open_chat_event_log(path, { now = os.time })
--   log:append_chat_event({ kind = "status", text = "Joined chat" })   -- sets seq and at
--
-- The file is kept short: past `compact_after_lines` it is replaced (by rename) with its
-- last `keep_lines` lines. A pane's `tail -F` then replays the new file, and the pane
-- skips the sequence numbers it has already seen.

local chat_events = require("twitch.chat_events")

local M = {}

local DEFAULT_KEEP_LINES = 500
local DEFAULT_COMPACT_AFTER_LINES = 2000

local Log = {}
Log.__index = Log

local function read_lines(path)
	local lines = {}
	local file = io.open(path, "r")
	if not file then
		return lines
	end
	for line in file:lines() do
		if line ~= "" then
			lines[#lines + 1] = line
		end
	end
	file:close()
	return lines
end

--- Opens (or creates) the event log and continues its sequence numbers.
--- opts: now = fn() -> epoch seconds, keep_lines, compact_after_lines.
function M.open_chat_event_log(path, opts)
	opts = opts or {}
	local self = setmetatable({
		path = path,
		now = opts.now or os.time,
		keep_lines = opts.keep_lines or DEFAULT_KEEP_LINES,
		compact_after_lines = opts.compact_after_lines or DEFAULT_COMPACT_AFTER_LINES,
		last_seq = 0,
		line_count = 0,
	}, Log)
	local lines = read_lines(path)
	self.line_count = #lines
	for index = #lines, 1, -1 do
		local chat_event = chat_events.decode_chat_event_line(lines[index])
		if chat_event and type(chat_event.seq) == "number" then
			self.last_seq = chat_event.seq
			break
		end
	end
	return self
end

local function compact_event_log(self)
	local lines = read_lines(self.path)
	local first = math.max(1, #lines - self.keep_lines + 1)
	local temporary_path = self.path .. ".compacting"
	local file, err = io.open(temporary_path, "w")
	if not file then
		return nil, err
	end
	for index = first, #lines do
		file:write(lines[index], "\n")
	end
	file:close()
	local ok, rename_err = os.rename(temporary_path, self.path)
	if not ok then
		return nil, rename_err
	end
	self.line_count = #lines - first + 1
	return true
end

--- Appends one chat event, giving it the next `seq` and the current time as `at`.
--- Returns the seq, or nil and a message when the file cannot be written.
function Log:append_chat_event(chat_event)
	local seq = self.last_seq + 1
	chat_event.seq = seq
	chat_event.at = chat_event.at or self.now()
	local file, err = io.open(self.path, "a")
	if not file then
		return nil, "chat_event_log: cannot append to " .. self.path .. ": " .. tostring(err)
	end
	file:write(chat_events.encode_chat_event_line(chat_event), "\n")
	file:close()
	self.last_seq = seq
	self.line_count = self.line_count + 1
	if self.line_count > self.compact_after_lines then
		compact_event_log(self)
	end
	return seq
end

--- Deletes the log file; the next append starts a new one. Sequence numbers keep rising.
function Log:remove_event_log()
	os.remove(self.path)
	self.line_count = 0
end

return M
