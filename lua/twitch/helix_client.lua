-- The Twitch Helix API as one client object, for the operations this library calls.
--
--   local helix_client = require("twitch.helix_client")
--   local helix = helix_client.new_helix_client({
--     host = require("distilled.host.rex")(), access_token = token, client_id = id,
--   })
--   local users, err = helix:get_users({ login = { "dillon" } })
--
-- The generated client, distilled.clients.twitch (the rock distilled-twitch, or the copy in
-- vendor/distilled/clients/twitch), has one service per page of Twitch's API reference
-- (`users`, `chat`, ...); this forwards each operation to its service, so callers need
-- not know which page documents it. Options are passed to every
-- service client (distilled-lua's common options: host, retry, deadline_s, ...).

local M = {}

-- Operation -> the service (reference page) that has it.
M.HELIX_OPERATION_SERVICES = {
	get_users = "users",
	create_eventsub_subscription = "eventsub",
	delete_eventsub_subscription = "eventsub",
	get_eventsub_subscriptions = "eventsub",
	send_chat_message = "chat",
	send_chat_announcement = "chat",
	send_a_shoutout = "chat",
	update_chat_settings = "chat",
	get_chat_settings = "chat",
	get_global_chat_badges = "chat",
	get_channel_chat_badges = "chat",
	get_channel_emotes = "chat",
	get_global_emotes = "chat",
	get_emote_sets = "chat",
	get_user_chat_color = "chat",
	ban_user = "moderation",
	unban_user = "moderation",
	delete_chat_messages = "moderation",
	modify_channel_information = "channels",
	get_channel_information = "channels",
	get_games = "games",
}

--- Creates the client. A service is loaded the first time one of its operations is called.
function M.new_helix_client(opts)
	local services = require("distilled.clients.twitch").new(opts)
	return setmetatable({}, {
		__index = function(self, operation)
			local service_name = M.HELIX_OPERATION_SERVICES[operation]
			if not service_name then
				return nil
			end
			local method = function(_, input)
				local service = services[service_name]
				return service[operation](service, input)
			end
			rawset(self, operation, method)
			return method
		end,
	})
end

return M
