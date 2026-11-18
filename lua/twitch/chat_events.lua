-- Turns Twitch EventSub chat notifications into the small chat events that go in the
-- event log and that panes draw. No I/O.
--
--   local chat_events = require("twitch.chat_events")
--   local event = chat_events.chat_event_from_notification(subscription_type, twitch_event)
--   local line = chat_events.encode_chat_event_line(event)     -- one JSON line
--
-- Chat event kinds:
--   message     { id, user_id, login, name, color, badges, text, parts, action, reply,
--                 message_type, bits, source_channel }
--   notice      a sub, raid or other announcement: { id, notice_type, text, ... } plus the
--               message fields when the person wrote something with it
--   delete      { message_id }          one message was removed by a moderator
--   clear       {}                      the whole chat was cleared
--   clear_user  { user_id, login }      one person's messages were removed (ban or timeout)
--   status      { level, text, state }  from the connection, not from Twitch chat
-- parts: { type = "text" | "emote" | "mention" | "cheermote", text, ... }; an emote part
-- has emote_id and animated, a mention has user_id and login, a cheermote has bits.

local json_codec = require("twitch.json_codec")

local M = {}

-- "/me waves" arrives wrapped as "\1ACTION waves\1".
local ACTION_PREFIX = "\1ACTION "

local function has_value(list, wanted)
	for _, value in ipairs(list or {}) do
		if value == wanted then
			return true
		end
	end
	return false
end

local function non_empty(value)
	if value == nil or value == "" then
		return nil
	end
	return value
end

local function chat_parts_from_fragments(fragments)
	local parts = {}
	for _, fragment in ipairs(fragments or {}) do
		local part = { type = "text", text = fragment.text or "" }
		if fragment.type == "emote" and fragment.emote then
			part.type = "emote"
			part.emote_id = fragment.emote.id
			part.animated = has_value(fragment.emote.format, "animated") or nil
		elseif fragment.type == "mention" and fragment.mention then
			part.type = "mention"
			part.user_id = fragment.mention.user_id
			part.login = fragment.mention.user_login
		elseif fragment.type == "cheermote" and fragment.cheermote then
			part.type = "cheermote"
			part.bits = fragment.cheermote.bits
			part.prefix = fragment.cheermote.prefix
			part.tier = fragment.cheermote.tier
		end
		parts[#parts + 1] = part
	end
	return parts
end

local function badge_names(badges)
	local names = {}
	for _, badge in ipairs(badges or {}) do
		names[#names + 1] = tostring(badge.set_id) .. "/" .. tostring(badge.id)
	end
	return names
end

-- Removes the /me wrapper from the text and from the first and last text parts.
local function strip_action_wrapper(event)
	if not event.text or event.text:sub(1, #ACTION_PREFIX) ~= ACTION_PREFIX then
		return
	end
	event.action = true
	event.text = event.text:sub(#ACTION_PREFIX + 1):gsub("\1$", "")
	local first, last = event.parts[1], event.parts[#event.parts]
	if first and first.type == "text" and first.text:sub(1, #ACTION_PREFIX) == ACTION_PREFIX then
		first.text = first.text:sub(#ACTION_PREFIX + 1)
	end
	if last and last.type == "text" then
		last.text = last.text:gsub("\1$", "")
	end
end

local function add_chatter_fields(chat_event, event)
	chat_event.user_id = event.chatter_user_id
	chat_event.login = event.chatter_user_login
	chat_event.name = non_empty(event.chatter_user_name) or event.chatter_user_login
	chat_event.color = non_empty(event.color)
	chat_event.badges = badge_names(event.badges)
end

local function message_event(event)
	local message = event.message or {}
	local chat_event = {
		kind = "message",
		id = event.message_id,
		text = message.text or "",
		parts = chat_parts_from_fragments(message.fragments),
	}
	add_chatter_fields(chat_event, event)
	strip_action_wrapper(chat_event)
	if event.message_type and event.message_type ~= "text" then
		chat_event.message_type = event.message_type
	end
	if event.cheer then
		chat_event.bits = event.cheer.bits
	end
	if event.reply then
		chat_event.reply = {
			parent_message_id = event.reply.parent_message_id,
			name = event.reply.parent_user_name,
			text = event.reply.parent_message_body,
		}
	end
	-- Shared chat: the message was written in another channel's chat room.
	if event.source_broadcaster_user_id and event.source_broadcaster_user_id ~= event.broadcaster_user_id then
		chat_event.source_channel = event.source_broadcaster_user_login
	end
	return chat_event
end

local function notice_event(event)
	local message = event.message or {}
	local chat_event = {
		kind = "notice",
		id = event.message_id,
		notice_type = event.notice_type,
		text = event.system_message or "",
	}
	if event.chatter_is_anonymous then
		chat_event.name = "Anonymous"
	else
		add_chatter_fields(chat_event, event)
	end
	if non_empty(message.text) then
		chat_event.message_text = message.text
		chat_event.parts = chat_parts_from_fragments(message.fragments)
	end
	return chat_event
end

--- Converts one EventSub notification to a chat event, or nil for a subscription type
--- this library does not show.
function M.chat_event_from_notification(subscription_type, event)
	if subscription_type == "channel.chat.message" then
		return message_event(event)
	elseif subscription_type == "channel.chat.notification" then
		return notice_event(event)
	elseif subscription_type == "channel.chat.message_delete" then
		return { kind = "delete", message_id = event.message_id, user_id = event.target_user_id }
	elseif subscription_type == "channel.chat.clear" then
		return { kind = "clear" }
	elseif subscription_type == "channel.chat.clear_user_messages" then
		return { kind = "clear_user", user_id = event.target_user_id, login = event.target_user_login }
	end
	return nil
end

--- A status line from the connection. `level` is "info", "warn" or "error"; `state` is the
--- connection state it reports ("joined", "reconnecting", ...).
function M.chat_status_event(level, text, state)
	return { kind = "status", level = level, text = text, state = state }
end

--- One line of JSON for the event log (no newline).
function M.encode_chat_event_line(chat_event)
	return json_codec.encode_json(chat_event)
end

--- Reads a line of the event log. Returns nil for a blank or damaged line.
function M.decode_chat_event_line(line)
	if line == nil or line == "" then
		return nil
	end
	local chat_event = json_codec.decode_json(line)
	if type(chat_event) ~= "table" or type(chat_event.kind) ~= "string" then
		return nil
	end
	return chat_event
end

return M
