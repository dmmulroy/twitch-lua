local t = require("spec_helper")
local eventsub_session = require("twitch.eventsub_session")
local json_codec = require("twitch.json_codec")

-- The message shapes are the examples from Twitch's "Handling WebSocket Events" page.
local WELCOME = [[{"metadata":{"message_id":"96a3f3b5-5dec-4eed-908e-e11ee657416c","message_type":"session_welcome","message_timestamp":"2023-07-19T14:56:51.634234626Z"},"payload":{"session":{"id":"AQoQILE98gtqShGmLD7AM6yJThAB","status":"connected","connected_at":"2023-07-19T14:56:51.616329898Z","keepalive_timeout_seconds":10,"reconnect_url":null}}}]]
local KEEPALIVE = [[{"metadata":{"message_id":"84c1e79a-2a4b-4c13-ba0b-4312293e9308","message_type":"session_keepalive","message_timestamp":"2023-07-19T10:11:12.634234626Z"},"payload":{}}]]
local NOTIFICATION = [[{"metadata":{"message_id":"befa7b53-d79d-478f-86b9-120f112b044e","message_type":"notification","message_timestamp":"2022-11-16T10:11:12.464757833Z","subscription_type":"channel.follow","subscription_version":"1"},"payload":{"subscription":{"id":"f1c2a387-161a-49f9-a165-0f21d7a4e1c4","status":"enabled","type":"channel.follow","version":"2","cost":0,"condition":{"broadcaster_user_id":"12826","moderator_user_id":"12826"},"transport":{"method":"websocket","session_id":"AQoQexAWVYKSTIu4ec_2VAxyuhAB"},"created_at":"2022-11-16T10:11:12.464757833Z"},"event":{"user_id":"1337","user_login":"awesome_user","user_name":"Awesome_User","broadcaster_user_id":"12826","broadcaster_user_login":"twitch","broadcaster_user_name":"Twitch","followed_at":"2023-07-15T18:16:11.17106713Z"}}}]]
local RECONNECT = [[{"metadata":{"message_id":"84c1e79a-2a4b-4c13-ba0b-4312293e9309","message_type":"session_reconnect","message_timestamp":"2022-11-18T09:10:11.634234626Z"},"payload":{"session":{"id":"AQoQexAWVYKSTIu4ec_2VAxyuhAB","status":"reconnecting","keepalive_timeout_seconds":null,"reconnect_url":"wss://eventsub.wss.twitch.tv?challenge=abc","connected_at":"2022-11-16T10:11:12.634234626Z"}}}]]
local REVOCATION = [[{"metadata":{"message_id":"84c1e79a-2a4b-4c13-ba0b-4312293e9310","message_type":"revocation","message_timestamp":"2022-11-16T10:11:12.464757833Z","subscription_type":"channel.follow","subscription_version":"1"},"payload":{"subscription":{"id":"f1c2a387-161a-49f9-a165-0f21d7a4e1c4","status":"authorization_revoked","type":"channel.follow","version":"2","cost":0,"condition":{"broadcaster_user_id":"12826"},"transport":{"method":"websocket","session_id":"AQoQexAWVYKSTIu4ec_2VAxyuhAB"},"created_at":"2022-11-16T10:11:12.464757833Z"}}}]]

local function decode(text)
	return assert(json_codec.decode_json(text))
end

t.test("eventsub_session: welcome gives the session id and keepalive timeout", function()
	local session = eventsub_session.new_eventsub_session()
	t.equal(session:handle_eventsub_message(decode(WELCOME), 100), {
		{ kind = "session_welcome", session_id = "AQoQILE98gtqShGmLD7AM6yJThAB", keepalive_timeout_seconds = 10 },
	})
end)

t.test("eventsub_session: notification carries the subscription type and event", function()
	local session = eventsub_session.new_eventsub_session()
	local effects = session:handle_eventsub_message(decode(NOTIFICATION), 1)
	t.equal(#effects, 1)
	t.equal(effects[1].kind, "notification")
	t.equal(effects[1].subscription_type, "channel.follow")
	t.equal(effects[1].event.user_login, "awesome_user")
	t.equal(effects[1].message_id, "befa7b53-d79d-478f-86b9-120f112b044e")
end)

t.test("eventsub_session: a repeated message id is ignored", function()
	local session = eventsub_session.new_eventsub_session()
	t.equal(#session:handle_eventsub_message(decode(NOTIFICATION), 1), 1)
	t.equal(#session:handle_eventsub_message(decode(NOTIFICATION), 2), 0)
end)

t.test("eventsub_session: old message ids are forgotten after the recent limit", function()
	local session = eventsub_session.new_eventsub_session()
	local message = decode(NOTIFICATION)
	message.metadata.message_id = "first"
	t.equal(#session:handle_eventsub_message(message, 1), 1)
	for i = 1, 256 do
		message.metadata.message_id = "filler-" .. i
		session:handle_eventsub_message(message, 1)
	end
	message.metadata.message_id = "first"
	t.equal(#session:handle_eventsub_message(message, 1), 1)
end)

t.test("eventsub_session: reconnect and revocation", function()
	local session = eventsub_session.new_eventsub_session()
	t.equal(session:handle_eventsub_message(decode(RECONNECT), 1), {
		{ kind = "session_reconnect", reconnect_url = "wss://eventsub.wss.twitch.tv?challenge=abc" },
	})
	t.equal(session:handle_eventsub_message(decode(REVOCATION), 1), {
		{ kind = "revocation", subscription_type = "channel.follow", status = "authorization_revoked" },
	})
end)

t.test("eventsub_session: keepalive is overdue only after timeout plus grace of silence", function()
	local session = eventsub_session.new_eventsub_session()
	t.equal(session:is_keepalive_overdue(1000), false) -- before welcome
	session:handle_eventsub_message(decode(WELCOME), 100)
	t.equal(session:is_keepalive_overdue(100 + 10 + eventsub_session.KEEPALIVE_GRACE_SECONDS), false)
	t.equal(session:is_keepalive_overdue(100 + 10 + eventsub_session.KEEPALIVE_GRACE_SECONDS + 0.1), true)
	t.equal(#session:handle_eventsub_message(decode(KEEPALIVE), 110), 0)
	t.equal(session:is_keepalive_overdue(120), false)
end)

t.test("eventsub_session: junk input produces no effects", function()
	local session = eventsub_session.new_eventsub_session()
	t.equal(session:handle_eventsub_message({}, 1), {})
	t.equal(session:handle_eventsub_message("nope", 1), {})
end)
