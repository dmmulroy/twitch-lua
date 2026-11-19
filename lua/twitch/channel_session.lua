-- Everything needed to act in one channel as the token's user: reads the token, asks
-- Twitch who it belongs to, builds the Helix client and finds the channel's broadcaster.
-- The chat pane and the Rex palette actions both start here.
--
--   local channel_session = require("twitch.channel_session")
--   local session, problem = channel_session.open_channel_session({
--     token_file = paths.token_file,
--     channel = settings.channel,        -- nil: the token's own channel
--   })
--   session.commands:set_stream_title("hello")   -- twitch.chat_commands
--   session = { commands, helix, channel_login, own_login, broadcaster_user_id, user_id }
--
-- `problem` is a sentence to show, never the token.

local chat_commands = require("twitch.chat_commands")
local twitch_auth = require("twitch.twitch_auth")

local M = {}

M.DEFAULT_REQUEST_DEADLINE_SECONDS = 10

--- Opens the session. Options:
---   token_file (required), channel (login, optional),
---   deadline_s: seconds each Twitch request may take (default: 10 for Helix, 15 for the
---     token check),
---   distilled_host: distilled-lua host (default distilled.host.rex),
---   new_helix_client: fn(opts) -> helix (default twitch.helix_client; specs replace it).
--- Returns the session, or nil and a problem.
function M.open_channel_session(opts)
	assert(opts.token_file, "channel_session: token_file is required")
	local deadline_s = opts.deadline_s or M.DEFAULT_REQUEST_DEADLINE_SECONDS
	local token, read_err = twitch_auth.read_twitch_token_file(opts.token_file)
	if not token then
		return nil, read_err
	end
	local distilled_host = opts.distilled_host or require("distilled.host.rex")()
	local identity, validate_err = twitch_auth.validate_twitch_token(distilled_host.transport, token, opts.deadline_s)
	if not identity then
		return nil, validate_err.message
	end
	local new_helix_client = opts.new_helix_client or require("twitch.helix_client").new_helix_client
	local helix = new_helix_client({
		host = distilled_host,
		access_token = token,
		client_id = identity.client_id,
		retry = "none",
		deadline_s = deadline_s,
	})
	local channel_login = (opts.channel or identity.login):lower()
	local broadcaster_user_id = identity.user_id
	if channel_login ~= identity.login then
		local users = helix:get_users({ login = { channel_login } })
		local user = users and users.data and users.data[1]
		if not user then
			return nil, "Twitch channel not found: " .. channel_login
		end
		broadcaster_user_id = user.id
	end
	return {
		commands = chat_commands.new_chat_commands({
			helix = helix,
			broadcaster_user_id = broadcaster_user_id,
			user_id = identity.user_id,
		}),
		helix = helix,
		channel_login = channel_login,
		own_login = identity.login,
		broadcaster_user_id = broadcaster_user_id,
		user_id = identity.user_id,
	}
end

return M
