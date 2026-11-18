local t = require("spec_helper")
local eventsub_connection = require("twitch.eventsub_connection")
local fake_stream_host = require("fake_stream_host")

local function welcome(session_id)
	return '{"metadata":{"message_id":"w-' .. session_id .. '","message_type":"session_welcome"},"payload":{"session":{"id":"'
		.. session_id .. '","status":"connected","keepalive_timeout_seconds":10,"reconnect_url":null}}}'
end

local function keepalive(id)
	return '{"metadata":{"message_id":"k-' .. id .. '","message_type":"session_keepalive"},"payload":{}}'
end

local function chat_notification(id, text)
	return '{"metadata":{"message_id":"n-' .. id .. '","message_type":"notification","subscription_type":"channel.chat.message"},'
		.. '"payload":{"subscription":{"type":"channel.chat.message"},"event":{"message_id":"' .. id .. '","message":{"text":"' .. text .. '"}}}}'
end

local function new_connection(fake, opts)
	local seen = { notifications = {}, statuses = {} }
	local connection = eventsub_connection.new_eventsub_connection({
		host = fake.host,
		helix = fake.helix,
		broadcaster_user_id = "111",
		user_id = "222",
		url = opts and opts.url,
		on_notification = function(subscription_type, event)
			seen.notifications[#seen.notifications + 1] = { subscription_type, event }
		end,
		on_status = function(status)
			seen.statuses[#seen.statuses + 1] = status
		end,
	})
	return connection, seen
end

local function last_status(seen)
	return seen.statuses[#seen.statuses]
end

-- Starts a connection and brings it to "joined".
local function joined_connection()
	local fake = fake_stream_host.new_fake_stream_host()
	local connection, seen = new_connection(fake)
	connection:start()
	fake.server_accept(fake.streams[1])
	fake.server_send_json(fake.streams[1], welcome("S1"))
	return fake, connection, seen
end

t.test("eventsub_connection: parse_websocket_url", function()
	t.equal(eventsub_connection.parse_websocket_url("wss://eventsub.wss.twitch.tv/ws"), {
		hostname = "eventsub.wss.twitch.tv", port = 443, path = "/ws", secure = true,
	})
	t.equal(eventsub_connection.parse_websocket_url("wss://host.test:8443?challenge=a%2Fb"), {
		hostname = "host.test", port = 8443, path = "/?challenge=a%2Fb", secure = true,
	})
	t.equal(eventsub_connection.parse_websocket_url("ws://localhost:8080/ws?keepalive_timeout_seconds=30").path, "/ws?keepalive_timeout_seconds=30")
	t.equal(eventsub_connection.parse_websocket_url("https://nope"), nil)
end)

t.test("eventsub_connection: connects, then subscribes to the five chat types after the welcome", function()
	local fake, connection, seen = joined_connection()
	t.equal(fake.streams[1].hostname, "eventsub.wss.twitch.tv")
	t.equal(fake.streams[1].port, 443)
	t.truthy(fake.streams[1].written[1]:find("GET /ws HTTP/1.1", 1, true))
	t.equal(#fake.helix_calls, 5)
	t.equal(fake.helix_calls[1], {
		type = "channel.chat.message",
		version = "1",
		condition = { broadcaster_user_id = "111", user_id = "222" },
		transport = { method = "websocket", session_id = "S1" },
	})
	t.equal(fake.helix_calls[5].type, "channel.chat.clear_user_messages")
	t.equal(last_status(seen).state, "joined")
	t.equal(connection:connection_state(), "joined")
end)

t.test("eventsub_connection: delivers notifications and answers pings with a pong", function()
	local fake, _, seen = joined_connection()
	fake.server_send_json(fake.streams[1], chat_notification("m1", "hello"))
	t.equal(seen.notifications[1][1], "channel.chat.message")
	t.equal(seen.notifications[1][2].message.text, "hello")
	local written_before = #fake.streams[1].written
	fake.server_send_frame(fake.streams[1], 9, "abc")
	t.equal(#fake.streams[1].written, written_before + 1)
	-- a masked pong: opcode 10, 3 payload bytes
	t.equal(fake.streams[1].written[written_before + 1]:byte(1), 0x8a)
	t.equal(fake.streams[1].written[written_before + 1]:byte(2), 0x83)
end)

t.test("eventsub_connection: a 429 on subscribe retries with a doubling delay", function()
	local fake = fake_stream_host.new_fake_stream_host()
	fake.helix_errors["channel.chat.message"] = { status = 429, message = "too many" }
	local connection, seen = new_connection(fake)
	connection:start()
	fake.server_accept(fake.streams[1])
	fake.server_send_json(fake.streams[1], welcome("S1"))
	t.equal(last_status(seen).state, "reconnecting")
	t.truthy(last_status(seen).text:find("429", 1, true))
	t.equal(last_status(seen).retry_in_seconds, 1)
	t.equal(fake.streams[1].closed, true)
	t.equal(#fake.helix_calls, 1) -- stopped at the first refusal

	fake.advance(1)
	t.equal(#fake.streams, 2)
	fake.server_accept(fake.streams[2])
	fake.server_send_json(fake.streams[2], welcome("S2"))
	t.equal(last_status(seen).retry_in_seconds, 2)

	fake.helix_errors["channel.chat.message"] = nil
	fake.advance(2)
	fake.server_accept(fake.streams[3])
	fake.server_send_json(fake.streams[3], welcome("S3"))
	t.equal(last_status(seen).state, "joined")
	t.equal(connection:connection_state(), "joined")
end)

t.test("eventsub_connection: a 401 stops for good", function()
	local fake = fake_stream_host.new_fake_stream_host()
	fake.helix_errors["channel.chat.message"] = { status = 401 }
	local connection, seen = new_connection(fake)
	connection:start()
	fake.server_accept(fake.streams[1])
	fake.server_send_json(fake.streams[1], welcome("S1"))
	t.equal(last_status(seen).state, "stopped")
	t.equal(last_status(seen).level, "error")
	t.truthy(last_status(seen).text:find("401", 1, true))
	fake.advance(600)
	t.equal(#fake.streams, 1)
end)

t.test("eventsub_connection: a 403 stops only for the chat message subscription", function()
	local optional = fake_stream_host.new_fake_stream_host()
	optional.helix_errors["channel.chat.notification"] = { status = 403 }
	local _, optional_seen = new_connection(optional)
	_:start()
	optional.server_accept(optional.streams[1])
	optional.server_send_json(optional.streams[1], welcome("S1"))
	t.equal(#optional.helix_calls, 5)
	t.equal(last_status(optional_seen).state, "joined")

	local required = fake_stream_host.new_fake_stream_host()
	required.helix_errors["channel.chat.message"] = { status = 403 }
	local connection, required_seen = new_connection(required)
	connection:start()
	required.server_accept(required.streams[1])
	required.server_send_json(required.streams[1], welcome("S1"))
	t.equal(last_status(required_seen).state, "stopped")
	t.truthy(last_status(required_seen).text:find("user:read:chat", 1, true))
end)

t.test("eventsub_connection: a 409 (already subscribed) counts as success", function()
	local fake = fake_stream_host.new_fake_stream_host()
	fake.helix_errors["channel.chat.clear"] = { status = 409 }
	local connection, seen = new_connection(fake)
	connection:start()
	fake.server_accept(fake.streams[1])
	fake.server_send_json(fake.streams[1], welcome("S1"))
	t.equal(#fake.helix_calls, 5)
	t.equal(last_status(seen).state, "joined")
end)

t.test("eventsub_connection: silence past the keepalive timeout reconnects", function()
	local fake, _, seen = joined_connection()
	fake.advance(9)
	fake.server_send_json(fake.streams[1], keepalive("1"))
	fake.advance(14) -- 14s of silence: inside 10s + 5s grace
	t.equal(last_status(seen).state, "joined")
	fake.advance(3)
	t.equal(last_status(seen).state, "reconnecting")
	t.truthy(last_status(seen).text:find("silent", 1, true))
	t.equal(fake.streams[1].closed, true)
	fake.advance(1)
	t.equal(last_status(seen).state, "connecting")
	t.equal(#fake.streams, 2)
end)

t.test("eventsub_connection: no welcome within the timeout reconnects", function()
	local fake = fake_stream_host.new_fake_stream_host()
	local connection, seen = new_connection(fake)
	connection:start()
	fake.advance(17)
	t.equal(fake.streams[1].closed, true)
	t.truthy(#fake.streams >= 2)
	t.truthy(seen.statuses[2].text:find("did not answer", 1, true))
end)

t.test("eventsub_connection: a close frame reconnects, and the delay resets after a long join", function()
	local fake, _, seen = joined_connection()
	fake.server_send_frame(fake.streams[1], 8, string.char(0x0f, 0xa0) .. "internal server error")
	t.equal(last_status(seen).state, "reconnecting")
	t.truthy(last_status(seen).text:find("4000 internal server error", 1, true))
	t.equal(last_status(seen).retry_in_seconds, 1)
	fake.advance(1)
	fake.server_accept(fake.streams[2])
	fake.server_send_json(fake.streams[2], welcome("S2"))
	-- joined for under a minute: the next delay keeps doubling
	fake.server_send_frame(fake.streams[2], 8, string.char(0x0f, 0xa5))
	t.equal(last_status(seen).retry_in_seconds, 2)
	fake.advance(2)
	fake.server_accept(fake.streams[3])
	fake.server_send_json(fake.streams[3], welcome("S3"))
	for second = 1, 61 do
		fake.advance(1)
		fake.server_send_json(fake.streams[3], keepalive("long-" .. second))
	end
	fake.server_send_frame(fake.streams[3], 8, string.char(0x0f, 0xa5))
	t.equal(last_status(seen).retry_in_seconds, 1)
end)

t.test("eventsub_connection: the stream ending without a close frame reconnects", function()
	local fake, _, seen = joined_connection()
	fake.streams[1].handlers.on_closed("exit status 1")
	t.equal(last_status(seen).state, "reconnecting")
	t.truthy(last_status(seen).text:find("exit status 1", 1, true))
end)

t.test("eventsub_connection: a refused connection retries", function()
	local fake = fake_stream_host.new_fake_stream_host()
	fake.refuse_connect = true
	local connection, seen = new_connection(fake)
	connection:start()
	t.equal(last_status(seen).state, "reconnecting")
	fake.refuse_connect = false
	fake.advance(1)
	t.equal(#fake.streams, 1)
	t.equal(last_status(seen).state, "connecting")
end)

t.test("eventsub_connection: session_reconnect moves to the new URL without resubscribing", function()
	local fake, connection, seen = joined_connection()
	fake.server_send_json(
		fake.streams[1],
		'{"metadata":{"message_id":"r1","message_type":"session_reconnect"},"payload":{"session":{"id":"S1","status":"reconnecting","reconnect_url":"wss://edge.test/ws?challenge=xyz"}}}'
	)
	t.equal(#fake.streams, 2)
	t.equal(fake.streams[2].hostname, "edge.test")
	t.truthy(fake.streams[2].written[1]:find("GET /ws?challenge=xyz HTTP/1.1", 1, true))
	-- the old connection keeps delivering until the new one is welcomed
	fake.server_send_json(fake.streams[1], chat_notification("m1", "old"))
	t.equal(#seen.notifications, 1)
	t.equal(fake.streams[1].closed, false)

	fake.server_accept(fake.streams[2])
	fake.server_send_json(fake.streams[2], welcome("S1"))
	t.equal(fake.streams[1].closed, true)
	t.equal(#fake.helix_calls, 5) -- no second round of subscriptions
	fake.server_send_json(fake.streams[2], chat_notification("m2", "new"))
	t.equal(seen.notifications[2][2].message.text, "new")
	t.equal(connection:connection_state(), "joined")
	-- Twitch closing the old connection afterwards changes nothing
	fake.streams[1].handlers.on_closed(nil)
	t.equal(connection:connection_state(), "joined")
	-- well past the migration timeout, with Twitch still sending keepalives
	for second = 1, 40 do
		fake.advance(1)
		fake.server_send_json(fake.streams[2], keepalive("after-" .. second))
	end
	t.equal(#fake.streams, 2)
	t.equal(connection:connection_state(), "joined")
end)

t.test("eventsub_connection: a migration that never becomes ready falls back to a fresh connection", function()
	local fake, connection, seen = joined_connection()
	fake.server_send_json(
		fake.streams[1],
		'{"metadata":{"message_id":"r1","message_type":"session_reconnect"},"payload":{"session":{"id":"S1","reconnect_url":"wss://edge.test/ws"}}}'
	)
	-- Twitch closes the old connection after its grace time
	fake.streams[1].handlers.on_closed(nil)
	t.equal(connection:connection_state(), "joined")
	for second = 1, 31 do
		fake.advance(1)
	end
	t.equal(fake.streams[2].closed, true)
	t.equal(last_status(seen).state, "connecting")
	t.equal(fake.streams[#fake.streams].hostname, "eventsub.wss.twitch.tv")
end)

t.test("eventsub_connection: authorization revoked stops; other revocations warn", function()
	local fake, connection, seen = joined_connection()
	fake.server_send_json(
		fake.streams[1],
		'{"metadata":{"message_id":"v1","message_type":"revocation","subscription_type":"channel.chat.clear"},"payload":{"subscription":{"type":"channel.chat.clear","status":"version_removed"}}}'
	)
	t.equal(last_status(seen).level, "warn")
	t.equal(connection:connection_state(), "joined")
	fake.server_send_json(
		fake.streams[1],
		'{"metadata":{"message_id":"v2","message_type":"revocation","subscription_type":"channel.chat.message"},"payload":{"subscription":{"type":"channel.chat.message","status":"authorization_revoked"}}}'
	)
	t.equal(last_status(seen).state, "stopped")
	t.equal(fake.streams[1].closed, true)
end)

t.test("eventsub_connection: stop closes the stream and no timer reconnects", function()
	local fake, connection = joined_connection()
	connection:stop()
	t.equal(fake.streams[1].closed, true)
	fake.advance(300)
	t.equal(#fake.streams, 1)
	t.equal(connection:connection_state(), "stopped")
end)
