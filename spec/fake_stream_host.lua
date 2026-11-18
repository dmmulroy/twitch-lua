-- A scripted host for eventsub_connection specs: manual clock, timers and TLS streams, and
-- a helix client whose answers the test sets.
--
--   local fake = require("fake_stream_host").new_fake_stream_host()
--   fake.server_accept(stream)             -- answer the websocket handshake
--   fake.server_send_json(stream, text)    -- one unmasked text frame
--   fake.advance(seconds)                  -- run the timers that come due

local base64 = require("distilled.crypto.base64")
local sha1 = require("distilled.crypto.sha1")

local M = {}

local function unmasked_frame(opcode, payload)
	local length = #payload
	if length < 126 then
		return string.char(0x80 + opcode, length) .. payload
	end
	return string.char(0x80 + opcode, 126, (length - length % 256) / 256, length % 256) .. payload
end

function M.new_fake_stream_host()
	local fake = { now = 0, timers = {}, streams = {}, refuse_connect = false }

	fake.host = {
		now_seconds = function()
			return fake.now
		end,
		random_byte = function()
			return 7
		end,
		start_timer = function(seconds, fn)
			local timer = { at = fake.now + seconds, fn = fn, cancelled = false }
			function timer:cancel()
				self.cancelled = true
			end
			fake.timers[#fake.timers + 1] = timer
			return timer
		end,
		open_stream = function(hostname, port, handlers)
			if fake.refuse_connect then
				return nil, "connection refused"
			end
			local stream = { hostname = hostname, port = port, handlers = handlers, written = {}, closed = false }
			function stream:write(bytes)
				self.written[#self.written + 1] = bytes
			end
			function stream:close()
				self.closed = true
			end
			fake.streams[#fake.streams + 1] = stream
			return stream
		end,
	}

	-- Runs due timers in time order, moving the clock to each one.
	function fake.advance(seconds)
		local target = fake.now + seconds
		while true do
			local next_index
			for index, timer in ipairs(fake.timers) do
				if not timer.cancelled and timer.at <= target and (not next_index or timer.at < fake.timers[next_index].at) then
					next_index = index
				end
			end
			if not next_index then
				break
			end
			local timer = table.remove(fake.timers, next_index)
			fake.now = timer.at
			timer.fn()
		end
		fake.now = target
	end

	function fake.server_accept(stream)
		local key = stream.written[1]:match("Sec%-WebSocket%-Key: ([^\r\n]+)")
		local accept = base64.encode(sha1.digest(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
		stream.handlers.on_bytes("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: " .. accept .. "\r\n\r\n")
	end

	function fake.server_send_json(stream, text)
		stream.handlers.on_bytes(unmasked_frame(1, text))
	end

	function fake.server_send_frame(stream, opcode, payload)
		stream.handlers.on_bytes(unmasked_frame(opcode, payload))
	end

	-- helix: records calls; `fake.helix_errors[subscription_type]` makes that call fail.
	fake.helix_calls = {}
	fake.helix_errors = {}
	fake.helix = {}
	function fake.helix:create_eventsub_subscription(input)
		fake.helix_calls[#fake.helix_calls + 1] = input
		local err = fake.helix_errors[input.type]
		if err then
			return nil, err
		end
		return { data = { { id = "sub-" .. #fake.helix_calls } } }
	end

	return fake
end

return M
