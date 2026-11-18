local t = require("spec_helper")
local websocket_client = require("twitch.websocket_client")

-- RFC 6455 section 1.3: this key must produce this accept value.
local RFC_KEY_BYTES = "the sample nonce"
local RFC_ACCEPT = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

local function byte_source(bytes)
	local position = 0
	return function()
		position = position % #bytes + 1
		return bytes:byte(position)
	end
end

local function new_client(mask_bytes)
	return websocket_client.new_websocket_client({
		host = "example.test",
		path = "/ws?x=1",
		random_byte = byte_source(RFC_KEY_BYTES .. (mask_bytes or "")),
	})
end

local function handshake_response(accept)
	return "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
		.. accept .. "\r\n\r\n"
end

local function open_client(mask_bytes)
	local client = new_client(mask_bytes)
	client:handshake_request()
	local events = client:receive_bytes(handshake_response(RFC_ACCEPT))
	t.equal(events, { { kind = "open" } })
	return client
end

t.test("websocket_client: handshake request carries the key, host and path", function()
	local request = new_client():handshake_request()
	t.truthy(request:find("GET /ws?x=1 HTTP/1.1\r\n", 1, true))
	t.truthy(request:find("Host: example.test\r\n", 1, true))
	t.truthy(request:find("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n", 1, true))
	t.truthy(request:sub(-4) == "\r\n\r\n")
end)

t.test("websocket_client: accepts the RFC accept value and rejects a wrong one", function()
	open_client()
	local client = new_client()
	local events = client:receive_bytes(handshake_response("AAAAAAAAAAAAAAAAAAAAAAAAAAA="))
	t.equal(events[1].kind, "protocol_error")
	t.equal(client:is_open(), false)
end)

t.test("websocket_client: a refused upgrade is a protocol error naming the status line", function()
	local client = new_client()
	local events = client:receive_bytes("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
	t.equal(events[1].kind, "protocol_error")
	t.truthy(events[1].message:find("403 Forbidden", 1, true))
end)

t.test("websocket_client: frames that arrive with the handshake are read too", function()
	local client = new_client()
	local events = client:receive_bytes(handshake_response(RFC_ACCEPT) .. string.char(0x89, 0x00, 0x81, 0x02) .. "hi")
	t.equal(events, { { kind = "open" }, { kind = "ping", data = "" }, { kind = "text", data = "hi" } })
end)

t.test("websocket_client: text, masked text, fragments, ping and pong (RFC 5.7 examples)", function()
	local client = open_client()
	t.equal(client:receive_bytes(string.char(0x81, 0x05) .. "Hello"), { { kind = "text", data = "Hello" } })
	t.equal(
		client:receive_bytes(string.char(0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58)),
		{ { kind = "text", data = "Hello" } }
	)
	t.equal(client:receive_bytes(string.char(0x01, 0x03) .. "Hel"), {})
	-- a ping may sit between the fragments of a message
	t.equal(client:receive_bytes(string.char(0x89, 0x05) .. "Hello"), { { kind = "ping", data = "Hello" } })
	t.equal(client:receive_bytes(string.char(0x80, 0x02) .. "lo"), { { kind = "text", data = "Hello" } })
	t.equal(client:receive_bytes(string.char(0x8a, 0x00)), { { kind = "pong", data = "" } })
end)

t.test("websocket_client: 16-bit and 64-bit lengths, fed one byte at a time", function()
	local client = open_client()
	local medium = string.rep("m", 300)
	local large = string.rep("L", 70000)
	local wire = string.char(0x81, 126, 1, 44) .. medium .. string.char(0x82, 127, 0, 0, 0, 0, 0, 1, 0x11, 0x70) .. large
	local events = {}
	for i = 1, 400 do
		for _, event in ipairs(client:receive_bytes(wire:sub(i, i))) do
			events[#events + 1] = event
		end
	end
	for _, event in ipairs(client:receive_bytes(wire:sub(401))) do
		events[#events + 1] = event
	end
	t.equal(#events, 2)
	t.equal(events[1], { kind = "text", data = medium })
	t.equal(events[2].kind, "binary")
	t.equal(#events[2].data, 70000)
end)

t.test("websocket_client: close carries the code and reason, then nothing more is read", function()
	local client = open_client()
	local events = client:receive_bytes(string.char(0x88, 0x13, 0x0f, 0xa3) .. "connection unused" .. string.char(0x81, 0x01) .. "x")
	t.equal(events, { { kind = "close", code = 4003, reason = "connection unused" } })
	t.equal(client:is_open(), false)
	t.equal(client:receive_bytes(string.char(0x81, 0x01) .. "x"), {})
end)

t.test("websocket_client: client frames are masked (RFC 5.7 masked Hello)", function()
	local client = open_client(string.char(0x37, 0xfa, 0x21, 0x3d))
	-- the key source wraps: after 16 key bytes come the 4 mask bytes
	local frame = client:encode_frame(websocket_client.OPCODE_TEXT, "Hello")
	t.equal(frame, string.char(0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58))
end)

t.test("websocket_client: pong and close frames decode back to what was sent", function()
	local sender = open_client("\1\2\3\4")
	local receiver = open_client()
	t.equal(receiver:receive_bytes(sender:pong_frame("abc")), { { kind = "pong", data = "abc" } })
	local long = string.rep("z", 1000)
	t.equal(receiver:receive_bytes(sender:text_frame(long)), { { kind = "text", data = long } })
	t.equal(receiver:receive_bytes(sender:close_frame(1000, "bye")), { { kind = "close", code = 1000, reason = "bye" } })
end)

t.test("websocket_client: protocol violations stop the client", function()
	local reserved = open_client()
	t.equal(reserved:receive_bytes(string.char(0xc1, 0x00))[1].kind, "protocol_error")
	local stray = open_client()
	t.equal(stray:receive_bytes(string.char(0x80, 0x01) .. "x")[1].kind, "protocol_error")
	local fragmented_ping = open_client()
	t.equal(fragmented_ping:receive_bytes(string.char(0x09, 0x00))[1].kind, "protocol_error")
end)
