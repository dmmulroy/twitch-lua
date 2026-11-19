local t = require("spec_helper")
local channel_session = require("twitch.channel_session")

local function write_temp(text)
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	file:write(text)
	file:close()
	return path
end

-- A distilled host whose transport answers the token check, and a Helix factory that
-- records how it was built and answers get_users.
local function fakes(opts)
	local seen = {}
	local distilled_host = {
		transport = function(request)
			seen.validate_request = request
			return { status = opts.validate_status or 200, body = '{"client_id":"cid","user_id":"200","login":"dillon","scopes":[]}' }
		end,
	}
	local function new_helix_client(helix_opts)
		seen.helix_opts = helix_opts
		return {
			get_users = function(_, input)
				seen.get_users = input
				return { data = opts.users or {} }
			end,
		}
	end
	return distilled_host, new_helix_client, seen
end

t.test("channel_session: the token's own channel by default", function()
	local token_file = write_temp("secret\n")
	local distilled_host, new_helix_client, seen = fakes({})
	local session = channel_session.open_channel_session({
		token_file = token_file,
		distilled_host = distilled_host,
		new_helix_client = new_helix_client,
	})
	os.remove(token_file)
	t.equal({ session.channel_login, session.own_login, session.broadcaster_user_id, session.user_id }, { "dillon", "dillon", "200", "200" })
	t.equal(seen.validate_request.headers.authorization, "OAuth secret")
	t.equal(seen.validate_request.timeout, 15)
	t.equal({ seen.helix_opts.access_token, seen.helix_opts.client_id, seen.helix_opts.deadline_s }, { "secret", "cid", 10 })
	t.equal(seen.get_users, nil)
	t.equal(session.commands.broadcaster_user_id, "200")
end)

t.test("channel_session: another channel is looked up; deadline_s applies to every request", function()
	local token_file = write_temp("secret\n")
	local distilled_host, new_helix_client, seen = fakes({ users = { { id = "999", login = "other" } } })
	local session = channel_session.open_channel_session({
		token_file = token_file,
		channel = "Other",
		deadline_s = 6,
		distilled_host = distilled_host,
		new_helix_client = new_helix_client,
	})
	os.remove(token_file)
	t.equal(seen.get_users, { login = { "other" } })
	t.equal({ session.channel_login, session.broadcaster_user_id, session.user_id }, { "other", "999", "200" })
	t.equal({ seen.validate_request.timeout, seen.helix_opts.deadline_s }, { 6, 6 })
end)

t.test("channel_session: problems are sentences", function()
	local _, missing = channel_session.open_channel_session({ token_file = "/nonexistent/twitch-lua/token" })
	t.truthy(missing:find("not found", 1, true))
	local token_file = write_temp("secret\n")
	local distilled_host, new_helix_client = fakes({ validate_status = 401 })
	local _, invalid = channel_session.open_channel_session({ token_file = token_file, distilled_host = distilled_host, new_helix_client = new_helix_client })
	t.equal(invalid, "Twitch token is invalid or expired")
	local host2, factory2 = fakes({ users = {} })
	local _, unknown = channel_session.open_channel_session({ token_file = token_file, channel = "ghost", distilled_host = host2, new_helix_client = factory2 })
	t.equal(unknown, "Twitch channel not found: ghost")
	os.remove(token_file)
end)
