-- The chat a pane shows: applies chat events in order and keeps the most recent entries.
-- No I/O.
--
--   local chat_store = require("twitch.chat_store")
--   local store = chat_store.new_chat_store({ max_entries = 500 })
--   if store:apply_chat_event(event) then redraw() end
--   store.entries            -- oldest first; each has a unique `entry_id`
--   store.connection_state   -- "joined", "reconnecting", ... from status events
--
-- An entry is the chat event itself (kind "message", "notice" or "status") plus entry_id,
-- and `deleted = true` once a moderator removed it.

local M = {}

local DEFAULT_MAX_ENTRIES = 500

local Store = {}
Store.__index = Store

--- Creates an empty chat store.
function M.new_chat_store(opts)
	opts = opts or {}
	return setmetatable({
		entries = {},
		max_entries = opts.max_entries or DEFAULT_MAX_ENTRIES,
		connection_state = nil,
		last_seq = 0, -- highest event sequence number applied; older ones are replays
		revision = 0, -- changes whenever what should be drawn changes
		next_entry_id = 1,
		message_ids = {}, -- Twitch message id -> entry
	}, Store)
end

local function add_entry(self, chat_event)
	chat_event.entry_id = self.next_entry_id
	self.next_entry_id = self.next_entry_id + 1
	self.entries[#self.entries + 1] = chat_event
	if chat_event.id then
		self.message_ids[chat_event.id] = chat_event
	end
	while #self.entries > self.max_entries do
		local removed = table.remove(self.entries, 1)
		if removed.id and self.message_ids[removed.id] == removed then
			self.message_ids[removed.id] = nil
		end
	end
end

--- Applies one chat event. Returns true when the entries changed and the pane should
--- redraw. An event whose `seq` was already applied (a replay of the log) is ignored.
function Store:apply_chat_event(chat_event)
	if type(chat_event) ~= "table" then
		return false
	end
	if chat_event.seq then
		if chat_event.seq <= self.last_seq then
			return false
		end
		self.last_seq = chat_event.seq
	end
	local kind = chat_event.kind

	if kind == "message" or kind == "notice" then
		if chat_event.id and self.message_ids[chat_event.id] then
			return false -- the same Twitch message delivered twice
		end
		add_entry(self, chat_event)
	elseif kind == "status" then
		local changed = self.connection_state ~= chat_event.state
		self.connection_state = chat_event.state or self.connection_state
		local last = self.entries[#self.entries]
		if last and last.kind == "status" then
			-- Reconnect attempts would fill the screen: keep only the latest status line.
			if last.text == chat_event.text and not changed then
				return false
			end
			chat_event.entry_id = last.entry_id
			self.entries[#self.entries] = chat_event
		else
			add_entry(self, chat_event)
		end
	elseif kind == "delete" then
		local entry = self.message_ids[chat_event.message_id]
		if not entry or entry.deleted then
			return false
		end
		entry.deleted = true
	elseif kind == "clear_user" then
		local any = false
		for _, entry in ipairs(self.entries) do
			if entry.user_id == chat_event.user_id and entry.kind == "message" and not entry.deleted then
				entry.deleted = true
				any = true
			end
		end
		if not any then
			return false
		end
	elseif kind == "clear" then
		self.entries = {}
		self.message_ids = {}
		add_entry(self, { kind = "status", level = "info", text = "Chat was cleared by a moderator" })
	else
		return false
	end
	self.revision = self.revision + 1
	return true
end

return M
