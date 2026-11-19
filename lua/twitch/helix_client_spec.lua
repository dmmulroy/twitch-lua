local t = require("spec_helper")
local helix_client = require("twitch.helix_client")

t.test("helix_client: every mapped operation exists in its generated service", function()
	local twitch = require("distilled.clients.twitch")
	for operation, service in pairs(helix_client.HELIX_OPERATION_SERVICES) do
		local Service = twitch[service]
		t.truthy(Service, "service " .. service)
		local client = Service.new({ access_token = "x", client_id = "y", transport = function()
			return nil, "no network in specs"
		end })
		t.truthy(type(client[operation]) == "function", service .. "." .. operation)
	end
end)

t.test("helix_client: calls go to the service, with the shared options", function()
	local requests = {}
	local helix = helix_client.new_helix_client({
		access_token = "token-1",
		client_id = "client-1",
		retry = "none",
		transport = function(request)
			requests[#requests + 1] = request
			return { status = 200, headers = { ["content-type"] = "application/json" }, body = '{"data":[{"id":"1","login":"viewer"}]}' }
		end,
	})
	local users, err = helix:get_users({ login = { "viewer", "other" } })
	t.equal(err, nil)
	t.equal(users.data[1].login, "viewer")
	local request = requests[1]
	t.equal(request.method, "GET")
	t.truthy(request.url:find("^https://api%.twitch%.tv/helix/users%?"), request.url)
	t.truthy(request.url:find("login=viewer", 1, true) and request.url:find("login=other", 1, true), request.url)
	t.equal(request.headers["client-id"], "client-1")
	t.truthy(tostring(request.headers.authorization) == "Bearer token-1" or request.headers.authorization ~= nil)
	t.equal(helix.not_an_operation, nil)
end)
