local t = require("spec_helper")
local twitch_auth = require("twitch.twitch_auth")
local chat_paths = require("twitch.chat_paths")

local function write_temp(text)
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	file:write(text)
	file:close()
	return path
end

t.test("twitch_auth: reads a token, trimming whitespace and an oauth: prefix", function()
	local plain = write_temp("abc123\n")
	t.equal(twitch_auth.read_twitch_token_file(plain), "abc123")
	local prefixed = write_temp("  oauth:abc123  \n\n")
	t.equal(twitch_auth.read_twitch_token_file(prefixed), "abc123")
	os.remove(plain)
	os.remove(prefixed)
end)

t.test("twitch_auth: missing, empty and multi-token files are errors that never quote the token", function()
	local token, err = twitch_auth.read_twitch_token_file("/nonexistent/twitch-lua/token")
	t.equal(token, nil)
	t.truthy(err:find("not found", 1, true))
	local empty = write_temp("\n")
	t.equal(twitch_auth.read_twitch_token_file(empty), nil)
	local two = write_temp("secretone secrettwo\n")
	local _, two_err = twitch_auth.read_twitch_token_file(two)
	t.truthy(two_err and not two_err:find("secretone", 1, true))
	os.remove(empty)
	os.remove(two)
end)

t.test("twitch_auth: validate sends the token as OAuth and returns the identity", function()
	local seen
	local identity = twitch_auth.validate_twitch_token(function(request)
		seen = request
		return {
			status = 200,
			body = '{"client_id":"cid","login":"dillon","scopes":["user:read:chat","user:write:chat","chat:read"],"user_id":"209286766","expires_in":0}',
		}
	end, "tok")
	t.equal(seen.url, "https://id.twitch.tv/oauth2/validate")
	t.equal(seen.headers.authorization, "OAuth tok")
	t.equal(identity.user_id, "209286766")
	t.equal(identity.login, "dillon")
	t.equal(identity.client_id, "cid")
	t.equal(twitch_auth.missing_twitch_chat_scopes(identity), {})
end)

t.test("twitch_auth: validate failures carry the status", function()
	local _, expired = twitch_auth.validate_twitch_token(function()
		return { status = 401, body = '{"status":401,"message":"invalid access token"}' }
	end, "tok")
	t.equal(expired.status, 401)
	local _, offline = twitch_auth.validate_twitch_token(function()
		return nil, "curl: (6) could not resolve host"
	end, "tok")
	t.equal(offline.status, nil)
	t.truthy(offline.message:find("could not resolve host", 1, true))
	local _, app_token = twitch_auth.validate_twitch_token(function()
		return { status = 200, body = '{"client_id":"cid","scopes":null,"expires_in":5000}' }
	end, "tok")
	t.truthy(app_token.message:find("no user", 1, true))
end)

t.test("twitch_auth: missing scopes are listed", function()
	t.equal(
		twitch_auth.missing_twitch_chat_scopes({ scopes = { "chat:read", "user:write:chat" } }),
		{ "user:read:chat" }
	)
end)

t.test("chat_paths: derived from HOME, with XDG overrides", function()
	local env = { HOME = "/Users/someone" }
	local paths = chat_paths.twitch_chat_paths(function(name)
		return env[name]
	end)
	t.equal(paths.token_file, "/Users/someone/.config/twitch-lua/token")
	t.equal(paths.event_log, "/Users/someone/.local/state/twitch-lua/events.ndjson")
	t.equal(paths.emote_cache_dir, "/Users/someone/.cache/twitch-lua/emotes")
	env.XDG_STATE_HOME = "/state"
	env.XDG_CONFIG_HOME = ""
	local overridden = chat_paths.twitch_chat_paths(function(name)
		return env[name]
	end)
	t.equal(overridden.event_log, "/state/twitch-lua/events.ndjson")
	t.equal(overridden.token_file, "/Users/someone/.config/twitch-lua/token")
end)
