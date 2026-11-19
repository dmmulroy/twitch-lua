local t = require("spec_helper")
local chat_commands = require("twitch.chat_commands")

-- A Helix client that records calls. `answers[method]` is { value, err } or a function.
local function fake_helix(answers)
	answers = answers or {}
	local calls = {}
	local helix = setmetatable({}, {
		__index = function(_, method)
			return function(_, input)
				calls[#calls + 1] = { method, input }
				local answer = answers[method]
				if type(answer) == "function" then
					return answer(input)
				elseif answer then
					return answer[1], answer[2]
				end
				return {}
			end
		end,
	})
	return helix, calls
end

local function commands_with(answers)
	local helix, calls = fake_helix(answers)
	return chat_commands.new_chat_commands({ helix = helix, broadcaster_user_id = "100", user_id = "200" }), calls
end

local USER_FOUND = { { data = { { id = "555", login = "someone", display_name = "Someone" } } } }

t.test("chat_commands: send_chat_message posts as the user to the channel", function()
	local commands, calls = commands_with({ send_chat_message = { { data = { { message_id = "m", is_sent = true } } } } })
	t.equal(commands:send_chat_message("hello"), true)
	t.equal(calls[1], { "send_chat_message", { broadcaster_id = "100", sender_id = "200", message = "hello" } })
end)

t.test("chat_commands: a dropped or refused message gives the reason", function()
	local dropped = commands_with({
		send_chat_message = { { data = { { is_sent = false, drop_reason = { code = "msg_duplicate", message = "Your message is identical to the last one." } } } } },
	})
	t.equal({ dropped:send_chat_message("x") }, { nil, "Your message is identical to the last one." })
	local refused = commands_with({ send_chat_message = { nil, { status = 403, message = "forbidden" } } })
	local sent, reason = refused:send_chat_message("x")
	t.equal(sent, nil)
	t.truthy(reason:find("forbidden", 1, true) and reason:find("permission", 1, true))
end)

t.test("chat_commands: parse_chat_command", function()
	t.equal({ chat_commands.parse_chat_command("/Timeout  someone 60 spam  ") }, { "timeout", "someone 60 spam" })
	t.equal({ chat_commands.parse_chat_command("/clear") }, { "clear", "" })
	t.equal(chat_commands.parse_chat_command("not a command"), nil)
end)

t.test("chat_commands: /timeout looks the user up and bans with a duration and reason", function()
	local commands, calls = commands_with({ get_users = USER_FOUND })
	local result = commands:run_chat_command("/timeout @Someone 60 being rude")
	t.equal(calls[1], { "get_users", { login = { "someone" } } })
	t.equal(calls[2], { "ban_user", { broadcaster_id = "100", moderator_id = "200", data = { user_id = "555", duration = 60, reason = "being rude" } } })
	t.equal(result, { level = "info", text = "Someone timed out for 60s" })
	-- no number: the default length, and the rest is the reason
	local default_commands, default_calls = commands_with({ get_users = USER_FOUND })
	default_commands:run_chat_command("/timeout someone spam")
	t.equal(default_calls[2][2].data, { user_id = "555", duration = 600, reason = "spam" })
end)

t.test("chat_commands: /ban has no duration; /unban removes it", function()
	local commands, calls = commands_with({ get_users = USER_FOUND })
	t.equal(commands:run_chat_command("/ban someone").text, "Someone banned")
	t.equal(calls[2][2].data, { user_id = "555" })
	t.equal(commands:run_chat_command("/unban someone").text, "Someone unbanned")
	t.equal(calls[4], { "unban_user", { broadcaster_id = "100", moderator_id = "200", user_id = "555" } })
end)

t.test("chat_commands: an unknown user or a refused ban is an error line", function()
	local unknown = commands_with({ get_users = { { data = {} } } })
	t.equal(unknown:run_chat_command("/ban ghost"), { level = "error", text = "Not banned: no Twitch user named ghost" })
	local refused = commands_with({ get_users = USER_FOUND, ban_user = { nil, { status = 400, message = "user is already banned" } } })
	t.equal(refused:run_chat_command("/ban someone"), { level = "error", text = "Not banned: user is already banned" })
	t.equal(commands_with():run_chat_command("/ban").level, "error")
end)

t.test("chat_commands: /title and /category change the channel", function()
	local commands, calls = commands_with({ get_games = { { data = { { id = "1469308723", name = "Software and Game Development" } } } } })
	t.equal(commands:run_chat_command("/title Building a chat client").text, "Title set to: Building a chat client")
	t.equal(calls[1], { "modify_channel_information", { broadcaster_id = "100", title = "Building a chat client" } })
	t.equal(commands:run_chat_command("/category Software and Game Development").text, "Category set to: Software and Game Development")
	t.equal(calls[2], { "get_games", { name = { "Software and Game Development" } } })
	t.equal(calls[3], { "modify_channel_information", { broadcaster_id = "100", game_id = "1469308723" } })
	t.equal(commands:run_chat_command("/title").level, "error")
	local missing = commands_with({ get_games = { { data = {} } } })
	t.equal(missing:run_chat_command("/game Nope").text, "Category not changed: no category named Nope")
end)

t.test("chat_commands: get_stream_title reads the channel; set_stream_title refuses an empty title", function()
	local commands, calls = commands_with({ get_channel_information = { { data = { { broadcaster_id = "100", title = "Old title" } } } } })
	t.equal(commands:get_stream_title(), "Old title")
	t.equal(calls[1], { "get_channel_information", { broadcaster_id = { "100" } } })
	t.equal(commands:set_stream_title("   "), { level = "error", text = "Title not changed: the title is empty" })
	t.equal(#calls, 1)
	local never_streamed = commands_with({ get_channel_information = { { data = { { broadcaster_id = "100" } } } } })
	t.equal(never_streamed:get_stream_title(), "")
	local refused = commands_with({ get_channel_information = { nil, { status = 401, message = "invalid token" } } })
	local title, reason = refused:get_stream_title()
	t.equal(title, nil)
	t.truthy(reason:find("invalid token", 1, true))
end)

t.test("chat_commands: the operations take plain values", function()
	local commands, calls = commands_with({ get_users = USER_FOUND })
	t.equal(commands:timeout_chat_user("someone").text, "Someone timed out for 600s")
	t.equal(calls[2][2].data, { user_id = "555", duration = 600 })
	t.equal(commands:ban_chat_user("@someone", "spam").text, "Someone banned")
	t.equal(calls[4][2].data, { user_id = "555", reason = "spam" })
	t.equal(commands:update_chat_settings({ emote_mode = true }).text, "Chat settings changed")
	t.equal(calls[5], { "update_chat_settings", { broadcaster_id = "100", moderator_id = "200", emote_mode = true } })
end)

t.test("chat_commands: /clear, /announce and /shoutout", function()
	local commands, calls = commands_with({ get_users = USER_FOUND })
	t.equal(commands:run_chat_command("/clear").text, "Chat cleared")
	t.equal(calls[1], { "delete_chat_messages", { broadcaster_id = "100", moderator_id = "200" } })
	t.equal(commands:run_chat_command("/announce stream ends soon"), nil)
	t.equal(calls[2], { "send_chat_announcement", { broadcaster_id = "100", moderator_id = "200", message = "stream ends soon" } })
	t.equal(commands:run_chat_command("/shoutout someone").text, "Shoutout sent to Someone")
	t.equal(calls[4], { "send_a_shoutout", { from_broadcaster_id = "100", to_broadcaster_id = "555", moderator_id = "200" } })
end)

t.test("chat_commands: chat mode commands", function()
	local commands, calls = commands_with()
	t.equal(commands:run_chat_command("/slow 10").text, "Slow mode on: 10s between messages")
	t.equal(calls[1], { "update_chat_settings", { broadcaster_id = "100", moderator_id = "200", slow_mode = true, slow_mode_wait_time = 10 } })
	commands:run_chat_command("/slow")
	t.equal(calls[2][2].slow_mode_wait_time, 30)
	commands:run_chat_command("/slowoff")
	t.equal(calls[3][2].slow_mode, false)
	commands:run_chat_command("/followers 5")
	t.equal({ calls[4][2].follower_mode, calls[4][2].follower_mode_duration }, { true, 5 })
	commands:run_chat_command("/emoteonly")
	t.equal(calls[5][2].emote_mode, true)
	commands:run_chat_command("/subscribersoff")
	t.equal(calls[6][2].subscriber_mode, false)
	commands:run_chat_command("/uniquechat")
	t.equal(calls[7][2].unique_chat_mode, true)
	local refused = commands_with({ update_chat_settings = { nil, { status = 401, message = "missing scope" } } })
	local result = refused:run_chat_command("/emoteonly")
	t.equal(result.level, "error")
	t.truthy(result.text:find("permission", 1, true))
end)

t.test("chat_commands: unknown commands and /help", function()
	local commands = commands_with()
	t.equal(commands:run_chat_command("/dance"), { level = "error", text = "Unknown command /dance. Try /help" })
	t.equal(commands:run_chat_command("/help").text, chat_commands.CHAT_COMMAND_HELP)
end)
