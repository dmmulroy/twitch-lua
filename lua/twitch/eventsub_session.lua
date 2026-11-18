-- Twitch EventSub WebSocket session state, with no I/O: one decoded message in, effects out.
-- One session object per websocket connection.
--
--   local eventsub_session = require("twitch.eventsub_session")
--   local session = eventsub_session.new_eventsub_session()
--   for _, effect in ipairs(session:handle_eventsub_message(decoded_json, now_seconds)) do ... end
--   if session:is_keepalive_overdue(now_seconds) then reconnect() end
--
-- Effects:
--   { kind = "session_welcome", session_id, keepalive_timeout_seconds }
--   { kind = "notification", subscription_type, event, message_id, message_timestamp }
--   { kind = "session_reconnect", reconnect_url }   -- connect there; subscriptions carry over
--   { kind = "revocation", subscription_type, status }
-- Keepalives and repeated message ids produce no effect.

local M = {}

local RECENT_MESSAGE_ID_LIMIT = 256
local KEEPALIVE_GRACE_SECONDS = 5

local Session = {}
Session.__index = Session

--- Creates the state for one EventSub websocket connection.
function M.new_eventsub_session()
	return setmetatable({
		session_id = nil,
		keepalive_timeout_seconds = nil,
		last_message_at = nil, -- monotonic seconds of the last message of any type
		recent_message_ids = {}, -- id -> true
		recent_message_order = {}, -- ring of ids, oldest overwritten
		recent_message_next = 1,
	}, Session)
end

-- Twitch delivers at least once; a repeated message id must be ignored.
local function is_repeated_message(self, message_id)
	if not message_id then
		return false
	end
	if self.recent_message_ids[message_id] then
		return true
	end
	local slot = self.recent_message_next
	local evicted = self.recent_message_order[slot]
	if evicted then
		self.recent_message_ids[evicted] = nil
	end
	self.recent_message_order[slot] = message_id
	self.recent_message_ids[message_id] = true
	self.recent_message_next = slot % RECENT_MESSAGE_ID_LIMIT + 1
	return false
end

--- Handles one decoded EventSub websocket message and returns the effects to carry out.
--- `now_seconds` is a monotonic clock; every message, keepalives included, resets the
--- keepalive timer.
function Session:handle_eventsub_message(message, now_seconds)
	local effects = {}
	local metadata = type(message) == "table" and message.metadata
	if type(metadata) ~= "table" then
		return effects
	end
	self.last_message_at = now_seconds
	if is_repeated_message(self, metadata.message_id) then
		return effects
	end
	local payload = message.payload or {}
	local message_type = metadata.message_type

	if message_type == "session_welcome" then
		local session = payload.session or {}
		self.session_id = session.id
		self.keepalive_timeout_seconds = session.keepalive_timeout_seconds
		effects[1] = {
			kind = "session_welcome",
			session_id = session.id,
			keepalive_timeout_seconds = session.keepalive_timeout_seconds,
		}
	elseif message_type == "notification" then
		effects[1] = {
			kind = "notification",
			subscription_type = metadata.subscription_type or (payload.subscription and payload.subscription.type),
			event = payload.event or {},
			message_id = metadata.message_id,
			message_timestamp = metadata.message_timestamp,
		}
	elseif message_type == "session_reconnect" then
		local session = payload.session or {}
		effects[1] = { kind = "session_reconnect", reconnect_url = session.reconnect_url }
	elseif message_type == "revocation" then
		local subscription = payload.subscription or {}
		effects[1] = {
			kind = "revocation",
			subscription_type = metadata.subscription_type or subscription.type,
			status = subscription.status,
		}
	end
	-- session_keepalive and unknown types: the timer reset above is all they do
	return effects
end

--- True when Twitch has been silent longer than its keepalive timeout plus a grace period,
--- which means the connection is lost. False before the welcome message.
function Session:is_keepalive_overdue(now_seconds)
	if not self.keepalive_timeout_seconds or not self.last_message_at then
		return false
	end
	return now_seconds - self.last_message_at > self.keepalive_timeout_seconds + KEEPALIVE_GRACE_SECONDS
end

M.KEEPALIVE_GRACE_SECONDS = KEEPALIVE_GRACE_SECONDS

return M
