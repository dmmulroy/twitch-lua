-- What the token's user can do in one channel, on top of the Helix client: send chat
-- messages, moderate, change the channel, and run the "/commands" a chat pane understands.
-- No terminal code; the pane and the Rex palette actions both use it.
--
--   local chat_commands = require("twitch.chat_commands")
--   local commands = chat_commands.new_chat_commands({
--     helix = helix_client, broadcaster_user_id = "1", user_id = "1",
--   })
--   local sent, reason = commands:send_chat_message("hello")
--   local result = commands:set_stream_title("Building a chat client")   -- { level, text }
--   local result = commands:run_chat_command("/timeout someone 60 spam") -- the same, parsed
--
-- Each operation (ban_chat_user, set_stream_title, ...) takes plain values and returns
-- { level = "info" | "error", text } to show; the "/command" handlers only parse a line
-- and call one.
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

-- Bans `login`, for `seconds` when given (a timeout). `reason` may be nil or "".
local function ban_or_timeout(self, login, seconds, reason)
	local user_id, name = find_user_id(self, login)
	if not user_id then
		return failed("Not banned: " .. tostring(name))
	end
	local data = { user_id = user_id, duration = seconds }
	if reason and reason ~= "" then
		data.reason = reason
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

--- Bans a user for good. `reason` is optional.
function Commands:ban_chat_user(login, reason)
	return ban_or_timeout(self, login, nil, reason)
end

--- Times a user out. `seconds` defaults to 600; `reason` is optional.
function Commands:timeout_chat_user(login, seconds, reason)
	return ban_or_timeout(self, login, seconds or DEFAULT_TIMEOUT_SECONDS, reason)
end

--- Lifts a ban or a timeout.
function Commands:unban_chat_user(login)
	local user_id, name = find_user_id(self, login)
	if not user_id then
		return failed("Not unbanned: " .. tostring(name))
	end
	local _, err = self.helix:unban_user({ broadcaster_id = self.broadcaster_user_id, moderator_id = self.user_id, user_id = user_id })
	if err then
		return failed("Not unbanned: " .. describe_helix_error(err))
	end
	return ok(name .. " unbanned")
end

--- Deletes every message in the chat room.
function Commands:clear_chat()
	local _, err = self.helix:delete_chat_messages({ broadcaster_id = self.broadcaster_user_id, moderator_id = self.user_id })
	if err then
		return failed("Chat not cleared: " .. describe_helix_error(err))
	end
	return ok("Chat cleared")
end

--- The channel's current stream title ("" if it never had one), or nil and why not.
function Commands:get_stream_title()
	local response, err = self.helix:get_channel_information({ broadcaster_id = { self.broadcaster_user_id } })
	local channel = response and response.data and response.data[1]
	if not channel then
		return nil, err and describe_helix_error(err) or "channel not found"
	end
	return channel.title or ""
end

--- Sets the stream title. Twitch refuses an empty one, so that is refused here first.
function Commands:set_stream_title(title)
	title = tostring(title or "")
	if not title:find("%S") then
		return failed("Title not changed: the title is empty")
	end
	local _, err = self.helix:modify_channel_information({ broadcaster_id = self.broadcaster_user_id, title = title })
	if err then
		return failed("Title not changed: " .. describe_helix_error(err))
	end
	return ok("Title set to: " .. title)
end

--- Sets the stream category (game) by its exact name.
function Commands:set_stream_category(category_name)
	local response, err = self.helix:get_games({ name = { category_name } })
	local game = response and response.data and response.data[1]
	if not game then
		return failed("Category not changed: " .. (err and describe_helix_error(err) or ("no category named " .. category_name)))
	end
	local _, update_err = self.helix:modify_channel_information({ broadcaster_id = self.broadcaster_user_id, game_id = game.id })
	if update_err then
		return failed("Category not changed: " .. describe_helix_error(update_err))
	end
	return ok("Category set to: " .. tostring(game.name))
end

--- Sends an announcement. Returns nil on success: the announcement itself appears in chat.
function Commands:send_announcement(text)
	local _, err = self.helix:send_chat_announcement({ broadcaster_id = self.broadcaster_user_id, moderator_id = self.user_id, message = text })
	if err then
		return failed("Announcement not sent: " .. describe_helix_error(err))
	end
	return nil
end

--- Gives another broadcaster a shoutout.
function Commands:send_shoutout(login)
	local user_id, name = find_user_id(self, login)
	if not user_id then
		return failed("No shoutout: " .. tostring(name))
	end
	local _, err = self.helix:send_a_shoutout({ from_broadcaster_id = self.broadcaster_user_id, to_broadcaster_id = user_id, moderator_id = self.user_id })
	if err then
		return failed("No shoutout: " .. describe_helix_error(err))
	end
	return ok("Shoutout sent to " .. name)
end

--- Changes chat modes. `changes` holds Helix's fields (slow_mode, emote_mode, ...);
--- `done_text` is what to show when Twitch accepts them.
function Commands:update_chat_settings(changes, done_text)
	local request = { broadcaster_id = self.broadcaster_user_id, moderator_id = self.user_id }
	for key, value in pairs(changes) do
		request[key] = value
	end
	local _, err = self.helix:update_chat_settings(request)
	if err then
		return failed("Chat settings not changed: " .. describe_helix_error(err))
	end
	return ok(done_text or "Chat settings changed")
end

-- "/command" handlers: each parses its arguments and calls one operation above.
local COMMAND_HANDLERS = {}

function COMMAND_HANDLERS.help()
	return ok(M.CHAT_COMMAND_HELP)
end

function COMMAND_HANDLERS.clear(self)
	return self:clear_chat()
end

function COMMAND_HANDLERS.ban(self, arguments)
	local login, reason = arguments:match("^(%S*)%s*(.*)$")
	return self:ban_chat_user(login, reason)
end

function COMMAND_HANDLERS.timeout(self, arguments)
	local login, rest = arguments:match("^(%S*)%s*(.*)$")
	local seconds, reason = rest:match("^(%d+)%s*(.*)$")
	if not seconds then
		reason = rest
	end
	return self:timeout_chat_user(login, tonumber(seconds), reason)
end

function COMMAND_HANDLERS.unban(self, arguments)
	return self:unban_chat_user(arguments:match("^(%S*)"))
end
COMMAND_HANDLERS.untimeout = COMMAND_HANDLERS.unban

function COMMAND_HANDLERS.title(self, arguments)
	if arguments == "" then
		return failed("Usage: /title new stream title")
	end
	return self:set_stream_title(arguments)
end

function COMMAND_HANDLERS.category(self, arguments)
	if arguments == "" then
		return failed("Usage: /category exact category name")
	end
	return self:set_stream_category(arguments)
end
COMMAND_HANDLERS.game = COMMAND_HANDLERS.category

function COMMAND_HANDLERS.announce(self, arguments)
	if arguments == "" then
		return failed("Usage: /announce text")
	end
	return self:send_announcement(arguments)
end

function COMMAND_HANDLERS.shoutout(self, arguments)
	return self:send_shoutout(arguments:match("^(%S*)"))
end

function COMMAND_HANDLERS.slow(self, arguments)
	local seconds = tonumber(arguments:match("^(%d+)") or DEFAULT_SLOW_MODE_SECONDS)
	return self:update_chat_settings({ slow_mode = true, slow_mode_wait_time = seconds }, "Slow mode on: " .. seconds .. "s between messages")
end

function COMMAND_HANDLERS.slowoff(self)
	return self:update_chat_settings({ slow_mode = false }, "Slow mode off")
end

function COMMAND_HANDLERS.emoteonly(self)
	return self:update_chat_settings({ emote_mode = true }, "Emote-only mode on")
end

function COMMAND_HANDLERS.emoteonlyoff(self)
	return self:update_chat_settings({ emote_mode = false }, "Emote-only mode off")
end

function COMMAND_HANDLERS.subscribers(self)
	return self:update_chat_settings({ subscriber_mode = true }, "Subscribers-only mode on")
end

function COMMAND_HANDLERS.subscribersoff(self)
	return self:update_chat_settings({ subscriber_mode = false }, "Subscribers-only mode off")
end

function COMMAND_HANDLERS.followers(self, arguments)
	local minutes = tonumber(arguments:match("^(%d+)") or 0)
	return self:update_chat_settings({ follower_mode = true, follower_mode_duration = minutes }, "Followers-only mode on (" .. minutes .. " min)")
end

function COMMAND_HANDLERS.followersoff(self)
	return self:update_chat_settings({ follower_mode = false }, "Followers-only mode off")
end

function COMMAND_HANDLERS.uniquechat(self)
	return self:update_chat_settings({ unique_chat_mode = true }, "Unique-chat mode on")
end

function COMMAND_HANDLERS.uniquechatoff(self)
	return self:update_chat_settings({ unique_chat_mode = false }, "Unique-chat mode off")
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
