local t = require("spec_helper")
local chat_events = require("twitch.chat_events")
local json_codec = require("twitch.json_codec")

-- A real channel.chat.message event recorded from Twitch, with the names changed.
local RECORDED_MESSAGE = [[{"broadcaster_user_id":"209286766","broadcaster_user_login":"streamer","broadcaster_user_name":"streamer","source_broadcaster_user_id":null,"source_broadcaster_user_login":null,"source_broadcaster_user_name":null,"chatter_user_id":"100135110","chatter_user_login":"helperbot","chatter_user_name":"HelperBot","message_id":"9bf632e3-4b8e-4e19-b40f-ed975589348f","source_message_id":null,"is_source_only":null,"message":{"text":"Thank you for following someone :)","fragments":[{"type":"text","text":"Thank you for following someone ","cheermote":null,"emote":null,"mention":null,"gif":null},{"type":"emote","text":":)","cheermote":null,"emote":{"id":"1","emote_set_id":"0","owner_id":"0","format":["static"]},"mention":null,"gif":null}]},"color":"#5B99FF","badges":[{"set_id":"moderator","id":"1","info":""},{"set_id":"bot-badge","id":"1","info":""}],"source_badges":null,"message_type":"text","cheer":null,"reply":null,"channel_points_custom_reward_id":null,"channel_points_animation_id":null}]]

local function decode(text)
	return assert(json_codec.decode_json(text))
end

t.test("chat_events: a recorded chat message", function()
	local event = chat_events.chat_event_from_notification("channel.chat.message", decode(RECORDED_MESSAGE))
	t.equal(event, {
		kind = "message",
		id = "9bf632e3-4b8e-4e19-b40f-ed975589348f",
		user_id = "100135110",
		login = "helperbot",
		name = "HelperBot",
		color = "#5B99FF",
		badges = { "moderator/1", "bot-badge/1" },
		text = "Thank you for following someone :)",
		parts = {
			{ type = "text", text = "Thank you for following someone " },
			{ type = "emote", text = ":)", emote_id = "1" },
		},
	})
end)

t.test("chat_events: animated emote, mention, cheermote, reply, bits and an empty color", function()
	local event = chat_events.chat_event_from_notification("channel.chat.message", {
		broadcaster_user_id = "1",
		chatter_user_id = "2",
		chatter_user_login = "viewer",
		chatter_user_name = "",
		color = "",
		message_id = "m1",
		message_type = "channel_points_highlighted",
		cheer = { bits = 100 },
		reply = { parent_message_id = "p1", parent_user_name = "Streamer", parent_message_body = "hi all" },
		message = {
			text = "@Streamer Cheer100 dance",
			fragments = {
				{ type = "mention", text = "@Streamer", mention = { user_id = "1", user_login = "streamer", user_name = "Streamer" } },
				{ type = "text", text = " " },
				{ type = "cheermote", text = "Cheer100", cheermote = { prefix = "cheer", bits = 100, tier = 100 } },
				{ type = "text", text = " " },
				{ type = "emote", text = "dance", emote = { id = "emotesv2_abc", format = { "static", "animated" } } },
			},
		},
	})
	t.equal(event.name, "viewer")
	t.equal(event.color, nil)
	t.equal(event.badges, {})
	t.equal(event.message_type, "channel_points_highlighted")
	t.equal(event.bits, 100)
	t.equal(event.reply, { parent_message_id = "p1", name = "Streamer", text = "hi all" })
	t.equal(event.parts[1], { type = "mention", text = "@Streamer", user_id = "1", login = "streamer" })
	t.equal(event.parts[3], { type = "cheermote", text = "Cheer100", bits = 100, prefix = "cheer", tier = 100 })
	t.equal(event.parts[5], { type = "emote", text = "dance", emote_id = "emotesv2_abc", animated = true })
end)

t.test("chat_events: /me messages lose their wrapper and are marked as actions", function()
	local event = chat_events.chat_event_from_notification("channel.chat.message", {
		message_id = "m2",
		chatter_user_login = "viewer",
		message = {
			text = "\1ACTION waves hello\1",
			fragments = { { type = "text", text = "\1ACTION waves hello\1" } },
		},
	})
	t.equal(event.action, true)
	t.equal(event.text, "waves hello")
	t.equal(event.parts, { { type = "text", text = "waves hello" } })
end)

t.test("chat_events: shared chat messages name the channel they came from", function()
	local own = chat_events.chat_event_from_notification("channel.chat.message", {
		broadcaster_user_id = "1", source_broadcaster_user_id = "1", source_broadcaster_user_login = "me", message = {},
	})
	t.equal(own.source_channel, nil)
	local other = chat_events.chat_event_from_notification("channel.chat.message", {
		broadcaster_user_id = "1", source_broadcaster_user_id = "9", source_broadcaster_user_login = "friend", message = {},
	})
	t.equal(other.source_channel, "friend")
end)

t.test("chat_events: notices, with and without a message from the person", function()
	local raid = chat_events.chat_event_from_notification("channel.chat.notification", {
		message_id = "n1",
		notice_type = "raid",
		system_message = "5 raiders from Friend have joined!",
		chatter_user_id = "9", chatter_user_login = "friend", chatter_user_name = "Friend", color = "#FF0000",
		message = { text = "", fragments = {} },
	})
	t.equal(raid.kind, "notice")
	t.equal(raid.text, "5 raiders from Friend have joined!")
	t.equal(raid.notice_type, "raid")
	t.equal(raid.message_text, nil)
	local resub = chat_events.chat_event_from_notification("channel.chat.notification", {
		message_id = "n2",
		notice_type = "resub",
		system_message = "Viewer subscribed for 3 months!",
		chatter_user_login = "viewer", chatter_user_name = "Viewer",
		message = { text = "love the stream", fragments = { { type = "text", text = "love the stream" } } },
	})
	t.equal(resub.message_text, "love the stream")
	t.equal(resub.parts, { { type = "text", text = "love the stream" } })
	local anonymous = chat_events.chat_event_from_notification("channel.chat.notification", {
		message_id = "n3", notice_type = "sub_gift", system_message = "An anonymous user gifted a sub!",
		chatter_is_anonymous = true, chatter_user_login = "ananonymousgifter", message = {},
	})
	t.equal(anonymous.name, "Anonymous")
	t.equal(anonymous.login, nil)
end)

t.test("chat_events: delete, clear and clear_user", function()
	t.equal(
		chat_events.chat_event_from_notification("channel.chat.message_delete", { message_id = "m1", target_user_id = "2" }),
		{ kind = "delete", message_id = "m1", user_id = "2" }
	)
	t.equal(chat_events.chat_event_from_notification("channel.chat.clear", { broadcaster_user_id = "1" }), { kind = "clear" })
	t.equal(
		chat_events.chat_event_from_notification("channel.chat.clear_user_messages", { target_user_id = "2", target_user_login = "viewer" }),
		{ kind = "clear_user", user_id = "2", login = "viewer" }
	)
	t.equal(chat_events.chat_event_from_notification("channel.follow", {}), nil)
end)

t.test("chat_events: event log lines round-trip, and damaged lines read as nil", function()
	local event = chat_events.chat_event_from_notification("channel.chat.message", decode(RECORDED_MESSAGE))
	event.seq = 12
	local line = chat_events.encode_chat_event_line(event)
	t.truthy(not line:find("\n", 1, true))
	t.equal(chat_events.decode_chat_event_line(line), event)
	t.equal(chat_events.decode_chat_event_line(""), nil)
	t.equal(chat_events.decode_chat_event_line('{"seq":1'), nil)
	t.equal(chat_events.decode_chat_event_line('{"seq":1}'), nil)
	t.equal(chat_events.decode_chat_event_line(chat_events.encode_chat_event_line(chat_events.chat_status_event("warn", "x", "reconnecting"))).state, "reconnecting")
end)
