-- Sending chat messages and the "/commands" a chat pane understands, on top of the Helix
-- client. No terminal code.
--
--   local chat_commands = require("twitch.tui.chat_commands")
--   local commands = chat_commands.new_chat_commands({
--     helix = helix_client, broadcaster_user_id = "1", user_id = "1",
--   })
--   local sent, reason = commands:send_chat_message("hello")
--   local result = commands:run_chat_command("/timeout someone 60 spam")   -- { level, text }
--
-- Commands: /help /clear /ban /timeout /unban /title /category /announce /shoutout
-- /slow /slowoff /emoteonly /emoteonlyoff /subscribers /subscribersoff
-- /followers /followersoff /uniquechat /uniquechatoff

local M = {}

local DEFAULT_TIMEOUT_SECONDS = 600
local DEFAULT_SLOW_MODE_SECONDS = 30

M.CHAT_COMMAND_HELP = "Commands: /clear /ban user [reason] /timeout user [seconds] [reason] /unban user "
	.. "/title text /category name /announce text /shoutout user /slow [seconds] /slowoff "
	.. "/emoteonly /emoteonlyoff /subscribers /subscribersoff /followers [minutes] /followersoff "
	.. "/uniquechat /uniquechatoff"

local Commands = {}
Commands.__index = Commands

--- Creates the command runner for one channel.
function M.new_chat_commands(opts)
	assert(opts.helix, "chat_commands: helix client is required")
	return setmetatable({
		helix = opts.helix,
		broadcaster_user_id = opts.broadcaster_user_id,
		user_id = opts.user_id,
	}, Commands)
end

local function describe_helix_error(err)
	if type(err) ~= "table" then
		return tostring(err)
	end
	local text = tostring(err.message or err.tag or "request failed")
	if err.status == 401 or err.status == 403 then
		text = text .. " (the Twitch token may lack the permission for this)"
	end
	return text
end

local function ok(text)
	return { level = "info", text = text }
end

local function failed(text)
	return { level = "error", text = text }
end

--- Sends a chat message as the token's user. Returns true, or nil and why it was not sent.
function Commands:send_chat_message(text)
	local response, err = self.helix:send_chat_message({
		broadcaster_id = self.broadcaster_user_id,
		sender_id = self.user_id,
		message = text,
	})
	if not response then
		return nil, describe_helix_error(err)
	end
	local result = response.data and response.data[1]
	if result and result.is_sent == false then
		return nil, (result.drop_reason and result.drop_reason.message) or "Twitch dropped the message"
	end
	return true
end

-- Twitch user id for a login, with or without a leading "@".
local function find_user_id(self, login)
	login = tostring(login or ""):gsub("^@", ""):lower()
	if login == "" then
		return nil, "a user name is needed"
	end
	local response, err = self.helix:get_users({ login = { login } })
	local user = response and response.data and response.data[1]
	if not user then
		return nil, err and describe_helix_error(err) or ("no Twitch user named " .. login)
	end
	return user.id, user.display_name or login
end

local function update_chat_settings(self, changes, done_text)
	changes.broadcaster_id = self.broadcaster_user_id
	changes.moderator_id = self.user_id
	local _, err = self.helix:update_chat_settings(changes)
	if err then
		return failed("Chat settings not changed: " .. describe_helix_error(err))
	end
	return ok(done_text)
end

local function ban_or_timeout(self, arguments, seconds)
	local login, rest = arguments:match("^(%S+)%s*(.*)$")
	local user_id, name = find_user_id(self, login)
	if not user_id then
		return failed("Not banned: " .. tostring(name))
	end
	local data = { user_id = user_id }
	if seconds then
		local custom, reason = rest:match("^(%d+)%s*(.*)$")
		if custom then
			-- Two statements on purpose: `seconds, rest = tonumber(custom), reason` crashes
			-- Rex's Lua here with a nil pointer dereference (it runs in stock Lua and LuaJIT).
			seconds = tonumber(custom)
			rest = reason
		end
		data.duration = seconds
	end
	if rest ~= "" then
		data.reason = rest
	end
	local _, err = self.helix:ban_user({ broadcaster_id = self.broadcaster_user_id, moderator_id = self.user_id, data = data })
	if err then
		return failed("Not banned: " .. describe_helix_error(err))
	end
	if seconds then
		return ok(name .. " timed out for " .. seconds .. "s")
	end
	return ok(name .. " banned")
end

local COMMAND_HANDLERS = {}

function COMMAND_HANDLERS.help()
	return ok(M.CHAT_COMMAND_HELP)
end

function COMMAND_HANDLERS.clear(self)
	local _, err = self.helix:delete_chat_messages({ broadcaster_id = self.broadcaster_user_id, moderator_id = self.user_id })
	if err then
		return failed("Chat not cleared: " .. describe_helix_error(err))
	end
	return ok("Chat cleared")
end

function COMMAND_HANDLERS.ban(self, arguments)
	return ban_or_timeout(self, arguments, nil)
end

function COMMAND_HANDLERS.timeout(self, arguments)
	return ban_or_timeout(self, arguments, DEFAULT_TIMEOUT_SECONDS)
end

function COMMAND_HANDLERS.unban(self, arguments)
	local user_id, name = find_user_id(self, arguments:match("^(%S+)"))
	if not user_id then
		return failed("Not unbanned: " .. tostring(name))
	end
	local _, err = self.helix:unban_user({ broadcaster_id = self.broadcaster_user_id, moderator_id = self.user_id, user_id = user_id })
	if err then
		return failed("Not unbanned: " .. describe_helix_error(err))
	end
	return ok(name .. " unbanned")
end
COMMAND_HANDLERS.untimeout = COMMAND_HANDLERS.unban

function COMMAND_HANDLERS.title(self, arguments)
	if arguments == "" then
		return failed("Usage: /title new stream title")
	end
	local _, err = self.helix:modify_channel_information({ broadcaster_id = self.broadcaster_user_id, title = arguments })
	if err then
		return failed("Title not changed: " .. describe_helix_error(err))
	end
	return ok("Title set to: " .. arguments)
end

function COMMAND_HANDLERS.category(self, arguments)
	if arguments == "" then
		return failed("Usage: /category exact category name")
	end
	local response, err = self.helix:get_games({ name = { arguments } })
	local game = response and response.data and response.data[1]
	if not game then
		return failed("Category not changed: " .. (err and describe_helix_error(err) or ("no category named " .. arguments)))
	end
	local _, update_err = self.helix:modify_channel_information({ broadcaster_id = self.broadcaster_user_id, game_id = game.id })
	if update_err then
		return failed("Category not changed: " .. describe_helix_error(update_err))
	end
	return ok("Category set to: " .. tostring(game.name))
end
COMMAND_HANDLERS.game = COMMAND_HANDLERS.category

function COMMAND_HANDLERS.announce(self, arguments)
	if arguments == "" then
		return failed("Usage: /announce text")
	end
	local _, err = self.helix:send_chat_announcement({ broadcaster_id = self.broadcaster_user_id, moderator_id = self.user_id, message = arguments })
	if err then
		return failed("Announcement not sent: " .. describe_helix_error(err))
	end
	return nil -- the announcement itself appears in chat
end

function COMMAND_HANDLERS.shoutout(self, arguments)
	local user_id, name = find_user_id(self, arguments:match("^(%S+)"))
	if not user_id then
		return failed("No shoutout: " .. tostring(name))
	end
	local _, err = self.helix:send_a_shoutout({ from_broadcaster_id = self.broadcaster_user_id, to_broadcaster_id = user_id, moderator_id = self.user_id })
	if err then
		return failed("No shoutout: " .. describe_helix_error(err))
	end
	return ok("Shoutout sent to " .. name)
end

function COMMAND_HANDLERS.slow(self, arguments)
	local seconds = tonumber(arguments:match("^(%d+)") or DEFAULT_SLOW_MODE_SECONDS)
	return update_chat_settings(self, { slow_mode = true, slow_mode_wait_time = seconds }, "Slow mode on: " .. seconds .. "s between messages")
end

function COMMAND_HANDLERS.slowoff(self)
	return update_chat_settings(self, { slow_mode = false }, "Slow mode off")
end

function COMMAND_HANDLERS.emoteonly(self)
	return update_chat_settings(self, { emote_mode = true }, "Emote-only mode on")
end

function COMMAND_HANDLERS.emoteonlyoff(self)
	return update_chat_settings(self, { emote_mode = false }, "Emote-only mode off")
end

function COMMAND_HANDLERS.subscribers(self)
	return update_chat_settings(self, { subscriber_mode = true }, "Subscribers-only mode on")
end

function COMMAND_HANDLERS.subscribersoff(self)
	return update_chat_settings(self, { subscriber_mode = false }, "Subscribers-only mode off")
end

function COMMAND_HANDLERS.followers(self, arguments)
	local minutes = tonumber(arguments:match("^(%d+)") or 0)
	return update_chat_settings(self, { follower_mode = true, follower_mode_duration = minutes }, "Followers-only mode on (" .. minutes .. " min)")
end

function COMMAND_HANDLERS.followersoff(self)
	return update_chat_settings(self, { follower_mode = false }, "Followers-only mode off")
end

function COMMAND_HANDLERS.uniquechat(self)
	return update_chat_settings(self, { unique_chat_mode = true }, "Unique-chat mode on")
end

function COMMAND_HANDLERS.uniquechatoff(self)
	return update_chat_settings(self, { unique_chat_mode = false }, "Unique-chat mode off")
end

--- Splits "/name rest of line" into the lowercase name and the trimmed rest.
function M.parse_chat_command(line)
	local name, arguments = tostring(line):match("^/(%S+)%s*(.-)%s*$")
	if not name then
		return nil
	end
	return name:lower(), arguments
end

--- Runs one "/command". Returns { level = "info" | "error", text } to show in the pane, or
--- nil when there is nothing to say.
function Commands:run_chat_command(line)
	local name, arguments = M.parse_chat_command(line)
	local handler = name and COMMAND_HANDLERS[name]
	if not handler then
		return failed("Unknown command /" .. tostring(name or "") .. ". Try /help")
	end
	return handler(self, arguments)
end

return M
