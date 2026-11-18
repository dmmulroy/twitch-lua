-- WebSocket client protocol (RFC 6455) with no I/O: bytes in, events out.
--
--   local websocket_client = require("twitch.websocket_client")
--   local client = websocket_client.new_websocket_client({
--     host = "eventsub.wss.twitch.tv", path = "/ws", random_byte = function() return 0..255 end,
--   })
--   stream_write(client:handshake_request())
--   for _, event in ipairs(client:receive_bytes(bytes_from_stream)) do ... end
--
-- Events: { kind = "open" }, { kind = "text", data }, { kind = "binary", data },
-- { kind = "ping", data }, { kind = "pong", data }, { kind = "close", code, reason },
-- { kind = "protocol_error", message } (after which the client stays closed).
-- The caller answers a ping by writing client:pong_frame(event.data).

local base64 = require("distilled.crypto.base64")
local sha1 = require("distilled.crypto.sha1")

local M = {}

local WEBSOCKET_ACCEPT_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
local MAX_HANDSHAKE_BYTES = 16 * 1024
local MAX_MESSAGE_BYTES = 8 * 1024 * 1024

local OPCODE_CONTINUATION, OPCODE_TEXT, OPCODE_BINARY = 0, 1, 2
local OPCODE_CLOSE, OPCODE_PING, OPCODE_PONG = 8, 9, 10

-- XOR of two 4-bit values; Lua 5.1 has no bit operators.
local XOR_NIBBLE = {}
for a = 0, 15 do
	XOR_NIBBLE[a] = {}
	for b = 0, 15 do
		local result, bit = 0, 1
		local x, y = a, b
		for _ = 1, 4 do
			if x % 2 ~= y % 2 then
				result = result + bit
			end
			x, y, bit = (x - x % 2) / 2, (y - y % 2) / 2, bit * 2
		end
		XOR_NIBBLE[a][b] = result
	end
end

local function xor_byte(a, b)
	local a_low, b_low = a % 16, b % 16
	return XOR_NIBBLE[(a - a_low) / 16][(b - b_low) / 16] * 16 + XOR_NIBBLE[a_low][b_low]
end

local function mask_payload(payload, key)
	local out = {}
	for i = 1, #payload do
		out[i] = string.char(xor_byte(payload:byte(i), key[(i - 1) % 4 + 1]))
	end
	return table.concat(out)
end

local Client = {}
Client.__index = Client

--- Creates a WebSocket client for one connection. `random_byte` supplies the handshake key
--- and frame masks; it must return an integer from 0 to 255.
function M.new_websocket_client(opts)
	assert(type(opts.host) == "string", "websocket_client: host is required")
	assert(type(opts.random_byte) == "function", "websocket_client: random_byte is required")
	local key_bytes = {}
	for i = 1, 16 do
		key_bytes[i] = string.char(opts.random_byte())
	end
	local self = setmetatable({
		host = opts.host,
		path = opts.path or "/",
		random_byte = opts.random_byte,
		handshake_key = base64.encode(table.concat(key_bytes)),
		state = "handshake", -- handshake -> open -> closed
		buffer = "",
		message_opcode = nil, -- opcode of a fragmented message in progress
		message_parts = nil,
		message_bytes = 0,
	}, Client)
	return self
end

--- The HTTP upgrade request to write first.
function Client:handshake_request()
	return "GET " .. self.path .. " HTTP/1.1\r\n"
		.. "Host: " .. self.host .. "\r\n"
		.. "Upgrade: websocket\r\n"
		.. "Connection: Upgrade\r\n"
		.. "Sec-WebSocket-Key: " .. self.handshake_key .. "\r\n"
		.. "Sec-WebSocket-Version: 13\r\n\r\n"
end

--- A masked client frame. Opcodes: 1 text, 2 binary, 8 close, 9 ping, 10 pong.
function Client:encode_frame(opcode, payload)
	payload = payload or ""
	local length = #payload
	local header
	if length < 126 then
		header = string.char(0x80 + opcode, 0x80 + length)
	elseif length < 65536 then
		header = string.char(0x80 + opcode, 0x80 + 126, (length - length % 256) / 256, length % 256)
	else
		local bytes = {}
		local rest = length
		for i = 8, 1, -1 do
			bytes[i] = rest % 256
			rest = (rest - rest % 256) / 256
		end
		header = string.char(0x80 + opcode, 0x80 + 127) .. string.char(bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8])
	end
	local key = { self.random_byte(), self.random_byte(), self.random_byte(), self.random_byte() }
	return header .. string.char(key[1], key[2], key[3], key[4]) .. mask_payload(payload, key)
end

--- The answer to a ping: a pong carrying the same data.
function Client:pong_frame(data)
	return self:encode_frame(OPCODE_PONG, data)
end

function Client:text_frame(text)
	return self:encode_frame(OPCODE_TEXT, text)
end

--- A close frame with a status code (1000 is a normal close).
function Client:close_frame(code, reason)
	code = code or 1000
	return self:encode_frame(OPCODE_CLOSE, string.char((code - code % 256) / 256, code % 256) .. (reason or ""))
end

local function fail(self, events, message)
	self.state = "closed"
	self.buffer = ""
	events[#events + 1] = { kind = "protocol_error", message = message }
end

-- Reads the HTTP response to the upgrade request. Returns true when it is complete and valid.
local function read_handshake_response(self, events)
	local head_end = self.buffer:find("\r\n\r\n", 1, true)
	if not head_end then
		if #self.buffer > MAX_HANDSHAKE_BYTES then
			fail(self, events, "websocket handshake response is too large")
		end
		return false
	end
	local head = self.buffer:sub(1, head_end + 1)
	self.buffer = self.buffer:sub(head_end + 4)
	local status = head:match("^HTTP/%d%.%d (%d%d%d)")
	if status ~= "101" then
		fail(self, events, "websocket handshake refused: " .. (head:match("^[^\r\n]*") or "no status line"))
		return false
	end
	local accept
	for name, value in head:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do
		if name:lower() == "sec-websocket-accept" then
			accept = value
		end
	end
	local expected = base64.encode(sha1.digest(self.handshake_key .. WEBSOCKET_ACCEPT_GUID))
	if accept ~= expected then
		fail(self, events, "websocket handshake has a wrong Sec-WebSocket-Accept")
		return false
	end
	self.state = "open"
	events[#events + 1] = { kind = "open" }
	return true
end

local function finish_message(self, events, opcode, data)
	events[#events + 1] = { kind = (opcode == OPCODE_TEXT) and "text" or "binary", data = data }
end

-- Takes one whole frame off the buffer. Returns false when more bytes are needed.
local function read_frame(self, events)
	local buffer = self.buffer
	if #buffer < 2 then
		return false
	end
	local first, second = buffer:byte(1, 2)
	local fin = first >= 128
	local reserved = (first % 128 - first % 16) / 16
	local opcode = first % 16
	local masked = second >= 128
	local length = second % 128
	local position = 3
	if length == 126 then
		if #buffer < 4 then
			return false
		end
		local high, low = buffer:byte(3, 4)
		length = high * 256 + low
		position = 5
	elseif length == 127 then
		if #buffer < 10 then
			return false
		end
		length = 0
		for i = 3, 10 do
			length = length * 256 + buffer:byte(i)
		end
		position = 11
	end
	if reserved ~= 0 then
		fail(self, events, "websocket frame uses reserved bits")
		return false
	end
	if length > MAX_MESSAGE_BYTES then
		fail(self, events, "websocket frame is too large: " .. length .. " bytes")
		return false
	end
	local mask_key
	if masked then
		if #buffer < position + 3 then
			return false
		end
		mask_key = { buffer:byte(position, position + 3) }
		position = position + 4
	end
	if #buffer < position - 1 + length then
		return false
	end
	local payload = buffer:sub(position, position + length - 1)
	self.buffer = buffer:sub(position + length)
	if mask_key then
		payload = mask_payload(payload, mask_key)
	end

	if opcode >= 8 then
		if not fin or length > 125 then
			fail(self, events, "websocket control frame is fragmented or too long")
			return false
		end
		if opcode == OPCODE_PING then
			events[#events + 1] = { kind = "ping", data = payload }
		elseif opcode == OPCODE_PONG then
			events[#events + 1] = { kind = "pong", data = payload }
		elseif opcode == OPCODE_CLOSE then
			local code
			if length >= 2 then
				local high, low = payload:byte(1, 2)
				code = high * 256 + low
			end
			self.state = "closed"
			self.buffer = ""
			events[#events + 1] = { kind = "close", code = code, reason = payload:sub(3) }
			return false
		else
			fail(self, events, "websocket control frame has unknown opcode " .. opcode)
			return false
		end
		return true
	end

	if opcode == OPCODE_CONTINUATION then
		if not self.message_opcode then
			fail(self, events, "websocket continuation frame without a message")
			return false
		end
		self.message_parts[#self.message_parts + 1] = payload
		self.message_bytes = self.message_bytes + length
		if self.message_bytes > MAX_MESSAGE_BYTES then
			fail(self, events, "websocket message is too large")
			return false
		end
		if fin then
			local data = table.concat(self.message_parts)
			local message_opcode = self.message_opcode
			self.message_opcode, self.message_parts, self.message_bytes = nil, nil, 0
			finish_message(self, events, message_opcode, data)
		end
	elseif opcode == OPCODE_TEXT or opcode == OPCODE_BINARY then
		if self.message_opcode then
			fail(self, events, "websocket data frame inside a fragmented message")
			return false
		end
		if fin then
			finish_message(self, events, opcode, payload)
		else
			self.message_opcode, self.message_parts, self.message_bytes = opcode, { payload }, length
		end
	else
		fail(self, events, "websocket frame has unknown opcode " .. opcode)
		return false
	end
	return true
end

--- Feeds bytes read from the stream and returns the events they complete, in order.
function Client:receive_bytes(bytes)
	local events = {}
	if self.state == "closed" then
		return events
	end
	self.buffer = self.buffer .. bytes
	if self.state == "handshake" and not read_handshake_response(self, events) then
		return events
	end
	while self.state == "open" and read_frame(self, events) do
	end
	return events
end

--- True once the handshake is done and no close or error has been seen.
function Client:is_open()
	return self.state == "open"
end

M.OPCODE_TEXT, M.OPCODE_CLOSE, M.OPCODE_PING, M.OPCODE_PONG = OPCODE_TEXT, OPCODE_CLOSE, OPCODE_PING, OPCODE_PONG

return M
