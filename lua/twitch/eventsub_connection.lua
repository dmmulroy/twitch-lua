-- Keeps one Twitch EventSub WebSocket connection alive: connect, subscribe, answer pings,
-- follow Twitch's reconnect messages, and reconnect with backoff when the connection is
-- lost. All I/O goes through an injected host, so this runs under any Lua and in tests.
--
--   local eventsub_connection = require("twitch.eventsub_connection")
--   local connection = eventsub_connection.new_eventsub_connection({
--     host = host, helix = helix_client,
--     broadcaster_user_id = "123", user_id = "123",
--     on_notification = function(subscription_type, event, metadata) end,
--     on_status = function(status) end,
--   })
--   connection:start()
--
-- host:
--   open_stream(hostname, port, { on_bytes = fn(bytes), on_closed = fn(reason) })
--       -> stream | nil, err      a TLS byte stream; stream:write(bytes), stream:close()
--   start_timer(seconds, fn) -> timer   one-shot; timer:cancel()
--   now_seconds() -> monotonic seconds
--   random_byte() -> 0..255
--
-- on_status receives { state, level, text, retry_in_seconds }. States: "connecting",
-- "subscribing", "joined", "reconnecting", "stopped".

local eventsub_session = require("twitch.eventsub_session")
local json_codec = require("twitch.json_codec")
local websocket_client = require("twitch.websocket_client")

local M = {}

M.EVENTSUB_WEBSOCKET_URL = "wss://eventsub.wss.twitch.tv/ws"

--- The chat subscriptions, all read as `user_id` in `broadcaster_user_id`'s channel.
--- The first one is required; a missing permission on the others is only a warning.
M.CHAT_SUBSCRIPTION_TYPES = {
	"channel.chat.message",
	"channel.chat.notification",
	"channel.chat.message_delete",
	"channel.chat.clear",
	"channel.chat.clear_user_messages",
}
local REQUIRED_SUBSCRIPTION_TYPE = "channel.chat.message"

local RETRY_MIN_SECONDS = 1
local RETRY_MAX_SECONDS = 60
-- A connection that stayed joined this long resets the retry delay.
local RETRY_RESET_AFTER_JOINED_SECONDS = 60
local KEEPALIVE_CHECK_SECONDS = 2
local WELCOME_TIMEOUT_SECONDS = 15
-- Twitch closes the old connection 30 seconds after a session_reconnect message.
local MIGRATION_TIMEOUT_SECONDS = 30

--- Splits a wss:// URL into hostname, port and path (with its query string).
function M.parse_websocket_url(url)
	local scheme, authority, path = tostring(url):match("^(wss?)://([^/?#]+)([^#]*)")
	if not scheme then
		return nil, "eventsub_connection: not a websocket URL: " .. tostring(url)
	end
	local hostname, port = authority:match("^(.-):(%d+)$")
	if not hostname then
		hostname, port = authority, (scheme == "wss") and 443 or 80
	end
	if path == "" then
		path = "/"
	elseif path:sub(1, 1) == "?" then
		path = "/" .. path
	end
	return { hostname = hostname, port = tonumber(port), path = path, secure = scheme == "wss" }
end

local Connection = {}
Connection.__index = Connection

--- Creates a connection manager. Nothing is opened until start().
function M.new_eventsub_connection(opts)
	assert(opts.host, "eventsub_connection: host is required")
	assert(opts.helix, "eventsub_connection: helix client is required")
	assert(opts.broadcaster_user_id and opts.user_id, "eventsub_connection: broadcaster_user_id and user_id are required")
	return setmetatable({
		host = opts.host,
		helix = opts.helix,
		broadcaster_user_id = opts.broadcaster_user_id,
		user_id = opts.user_id,
		subscription_types = opts.subscription_types or M.CHAT_SUBSCRIPTION_TYPES,
		url = opts.url or M.EVENTSUB_WEBSOCKET_URL,
		on_notification = opts.on_notification or function() end,
		on_status = opts.on_status or function() end,
		current = nil, -- the link whose events we deliver
		migrating = nil, -- a link being opened because Twitch sent session_reconnect
		retry_delay = RETRY_MIN_SECONDS,
		joined_at = nil,
		stopped = true,
		retry_timer = nil,
		keepalive_timer = nil,
		migration_timer = nil,
	}, Connection)
end

local function report_status(self, state, level, text, retry_in_seconds)
	self.state = state
	self.on_status({ state = state, level = level, text = text, retry_in_seconds = retry_in_seconds })
end

local function cancel_timer(timer)
	if timer then
		timer:cancel()
	end
end

local function close_link(link)
	if not link.closed then
		link.closed = true
		if link.stream then
			link.stream:close()
		end
	end
end

local schedule_retry, connect_fresh

-- A link stopped working. `reason` is shown to the person.
local function link_closed(self, link, reason)
	if link.closed then
		return
	end
	close_link(link)
	if link == self.migrating then
		self.migrating = nil
		cancel_timer(self.migration_timer)
		self.migration_timer = nil
		if self.current == nil then
			schedule_retry(self, reason)
		end
		return
	end
	if link == self.current then
		self.current = nil
		-- While a migration is in flight, its welcome makes it the current link.
		if not self.migrating then
			schedule_retry(self, reason)
		end
	end
end

local function stop_with_error(self, text)
	self:stop()
	report_status(self, "stopped", "error", text)
end

local function describe_helix_error(err)
	if type(err) == "table" then
		return tostring(err.message or err.tag or err.status or "unknown error")
	end
	return tostring(err)
end

-- Twitch gives 10 seconds after the welcome to create a subscription.
local function subscribe_to_chat(self, link, session_id)
	report_status(self, "subscribing", "info", "Joining chat")
	for _, subscription_type in ipairs(self.subscription_types) do
		local _, err = self.helix:create_eventsub_subscription({
			type = subscription_type,
			version = "1",
			condition = { broadcaster_user_id = self.broadcaster_user_id, user_id = self.user_id },
			transport = { method = "websocket", session_id = session_id },
		})
		if self.stopped or link.closed then
			return
		end
		if err ~= nil then
			local status = type(err) == "table" and err.status or nil
			if status == 409 then
				-- already subscribed on this session
			elseif status == 401 then
				return stop_with_error(self, "Twitch token is invalid or expired (401). Replace it and turn chat on again.")
			elseif status == 403 then
				if subscription_type == REQUIRED_SUBSCRIPTION_TYPE then
					return stop_with_error(self, "Twitch token may not read chat (403): it needs the user:read:chat scope.")
				end
				report_status(self, "subscribing", "warn", "No permission for " .. subscription_type .. " (403); continuing without it")
			elseif status == 429 then
				return link_closed(
					self,
					link,
					"Twitch refused the subscription (429): this account already has its 3 EventSub connections"
				)
			else
				return link_closed(self, link, "Subscribing to " .. subscription_type .. " failed: " .. describe_helix_error(err))
			end
		end
	end
	self.joined_at = self.host.now_seconds()
	report_status(self, "joined", "info", "Joined chat")
end

local open_link

local function apply_session_effect(self, link, effect)
	if effect.kind == "session_welcome" then
		if link.is_migration then
			local previous = self.current
			self.current = link
			self.migrating = nil
			link.is_migration = false
			cancel_timer(self.migration_timer)
			self.migration_timer = nil
			if previous then
				close_link(previous)
			end
			self.joined_at = self.joined_at or self.host.now_seconds()
			report_status(self, "joined", "info", "Joined chat")
		else
			subscribe_to_chat(self, link, effect.session_id)
		end
	elseif effect.kind == "notification" then
		self.on_notification(effect.subscription_type, effect.event, effect)
	elseif effect.kind == "session_reconnect" then
		if self.migrating or not effect.reconnect_url then
			return
		end
		local migrating, err = open_link(self, effect.reconnect_url, true)
		if not migrating then
			return link_closed(self, link, "Twitch asked to reconnect, and that failed: " .. tostring(err))
		end
		self.migrating = migrating
		self.migration_timer = self.host.start_timer(MIGRATION_TIMEOUT_SECONDS, function()
			self.migration_timer = nil
			if self.migrating == migrating then
				link_closed(self, migrating, "Twitch asked to reconnect, and the new connection never became ready")
			end
		end)
	elseif effect.kind == "revocation" then
		local text = "Twitch revoked " .. tostring(effect.subscription_type) .. " (" .. tostring(effect.status) .. ")"
		if effect.status == "authorization_revoked" or effect.status == "user_removed" then
			return stop_with_error(self, text)
		end
		report_status(self, self.state, "warn", text)
	end
end

local function link_received_bytes(self, link, bytes)
	if link.closed then
		return
	end
	for _, event in ipairs(link.websocket:receive_bytes(bytes)) do
		if link.closed or self.stopped then
			return
		end
		if event.kind == "text" then
			local message, err = json_codec.decode_json(event.data)
			if message then
				for _, effect in ipairs(link.session:handle_eventsub_message(message, self.host.now_seconds())) do
					apply_session_effect(self, link, effect)
					if link.closed or self.stopped then
						return
					end
				end
			else
				report_status(self, self.state, "warn", "Ignored a message from Twitch that is not JSON: " .. tostring(err))
			end
		elseif event.kind == "ping" then
			link.stream:write(link.websocket:pong_frame(event.data))
		elseif event.kind == "close" then
			return link_closed(
				self,
				link,
				"Twitch closed the connection (" .. tostring(event.code) .. " " .. tostring(event.reason) .. ")"
			)
		elseif event.kind == "protocol_error" then
			return link_closed(self, link, event.message)
		end
	end
end

open_link = function(self, url, is_migration)
	local target, parse_err = M.parse_websocket_url(url)
	if not target then
		return nil, parse_err
	end
	local link = {
		is_migration = is_migration,
		closed = false,
		opened_at = self.host.now_seconds(),
		session = eventsub_session.new_eventsub_session(),
		websocket = websocket_client.new_websocket_client({
			host = target.hostname,
			path = target.path,
			random_byte = self.host.random_byte,
		}),
	}
	local stream, err = self.host.open_stream(target.hostname, target.port, {
		on_bytes = function(bytes)
			link_received_bytes(self, link, bytes)
		end,
		on_closed = function(reason)
			link_closed(self, link, "Connection to Twitch ended" .. (reason and (": " .. tostring(reason)) or ""))
		end,
	})
	if not stream then
		return nil, err
	end
	link.stream = stream
	stream:write(link.websocket:handshake_request())
	return link
end

schedule_retry = function(self, reason)
	if self.stopped then
		return
	end
	local now = self.host.now_seconds()
	if self.joined_at and now - self.joined_at >= RETRY_RESET_AFTER_JOINED_SECONDS then
		self.retry_delay = RETRY_MIN_SECONDS
	end
	self.joined_at = nil
	local delay = self.retry_delay
	self.retry_delay = math.min(delay * 2, RETRY_MAX_SECONDS)
	report_status(self, "reconnecting", "warn", reason, delay)
	cancel_timer(self.retry_timer)
	self.retry_timer = self.host.start_timer(delay, function()
		self.retry_timer = nil
		if not self.stopped then
			connect_fresh(self)
		end
	end)
end

connect_fresh = function(self)
	report_status(self, "connecting", "info", "Connecting to Twitch")
	local link, err = open_link(self, self.url, false)
	if not link then
		return schedule_retry(self, "Could not connect to Twitch: " .. tostring(err))
	end
	self.current = link
end

local function check_keepalive(self)
	self.keepalive_timer = self.host.start_timer(KEEPALIVE_CHECK_SECONDS, function()
		if self.stopped then
			return
		end
		check_keepalive(self)
		local link = self.current
		if not link or link.closed then
			return
		end
		local now = self.host.now_seconds()
		if link.session:is_keepalive_overdue(now) then
			link_closed(self, link, "Twitch went silent (no keepalive)")
		elseif not link.session.session_id and now - link.opened_at > WELCOME_TIMEOUT_SECONDS then
			link_closed(self, link, "Twitch did not answer the connection")
		end
	end)
end

--- Opens the connection and keeps it open until stop().
function Connection:start()
	if not self.stopped then
		return
	end
	self.stopped = false
	self.retry_delay = RETRY_MIN_SECONDS
	check_keepalive(self)
	connect_fresh(self)
end

--- Closes the connection and cancels every timer. start() may be called again.
function Connection:stop()
	self.stopped = true
	cancel_timer(self.retry_timer)
	cancel_timer(self.keepalive_timer)
	cancel_timer(self.migration_timer)
	self.retry_timer, self.keepalive_timer, self.migration_timer = nil, nil, nil
	if self.current then
		close_link(self.current)
	end
	if self.migrating then
		close_link(self.migrating)
	end
	self.current, self.migrating = nil, nil
	self.state = "stopped"
end

--- "connecting", "subscribing", "joined", "reconnecting" or "stopped".
function Connection:connection_state()
	return self.state or "stopped"
end

return M
