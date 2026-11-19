-- The Twitch user access token: read it from its file and ask Twitch who it belongs to.
--
--   local twitch_auth = require("twitch.twitch_auth")
--   local token, err = twitch_auth.read_twitch_token_file(path)
--   local identity, err = twitch_auth.validate_twitch_token(transport, token)
--   identity = { client_id, user_id, login, scopes = { ... }, expires_in }
--
-- `transport` is distilled's host transport: fn({ method, url, headers, timeout })
-- -> { status, headers, body } | nil, err. Twitch requires a validation at start and
-- then every hour (https://dev.twitch.tv/docs/authentication/validate-tokens).

local json_codec = require("twitch.json_codec")

local M = {}

M.TWITCH_VALIDATE_URL = "https://id.twitch.tv/oauth2/validate"
M.TOKEN_VALIDATION_INTERVAL_SECONDS = 3600

--- Scopes chat needs: reading messages over EventSub and sending them through Helix.
M.REQUIRED_CHAT_SCOPES = { "user:read:chat", "user:write:chat" }

--- Reads the token file. Accepts a leading "oauth:" and surrounding whitespace.
--- Returns nil and a message when the file is missing or empty; never quotes the token.
function M.read_twitch_token_file(path)
	local file = io.open(path, "r")
	if not file then
		return nil, "Twitch token file not found: " .. path
	end
	local text = file:read("*a") or ""
	file:close()
	local token = text:match("^%s*(.-)%s*$"):gsub("^oauth:", "")
	if token == "" then
		return nil, "Twitch token file is empty: " .. path
	end
	if token:find("%s") then
		return nil, "Twitch token file must hold one token and nothing else: " .. path
	end
	return token
end

--- Asks Twitch whose token this is. On failure returns nil and { status, message };
--- status 401 means the token is invalid or expired. `timeout_seconds` defaults to 15.
function M.validate_twitch_token(transport, token, timeout_seconds)
	local response, err = transport({
		method = "GET",
		url = M.TWITCH_VALIDATE_URL,
		headers = { authorization = "OAuth " .. token },
		timeout = timeout_seconds or 15,
	})
	if not response then
		return nil, { status = nil, message = "Could not reach Twitch to validate the token: " .. tostring(err) }
	end
	if response.status == 401 then
		return nil, { status = 401, message = "Twitch token is invalid or expired" }
	end
	if response.status ~= 200 then
		return nil, { status = response.status, message = "Twitch token validation failed with HTTP " .. tostring(response.status) }
	end
	local body = json_codec.decode_json(response.body or "")
	if type(body) ~= "table" or not body.user_id or not body.client_id then
		return nil, { status = 200, message = "Twitch token validation returned no user (is this an app token?)" }
	end
	return {
		client_id = body.client_id,
		user_id = body.user_id,
		login = body.login,
		scopes = body.scopes or {},
		expires_in = body.expires_in,
	}
end

--- The required chat scopes this identity lacks, as a list (empty when all are present).
function M.missing_twitch_chat_scopes(identity)
	local held = {}
	for _, scope in ipairs(identity.scopes or {}) do
		held[scope] = true
	end
	local missing = {}
	for _, scope in ipairs(M.REQUIRED_CHAT_SCOPES) do
		if not held[scope] then
			missing[#missing + 1] = scope
		end
	end
	return missing
end

return M
