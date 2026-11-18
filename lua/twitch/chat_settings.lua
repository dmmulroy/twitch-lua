-- Optional settings for twitch-lua, read from ~/.config/twitch-lua/settings.json.
--
--   local settings = require("twitch.chat_settings").read_chat_settings(paths.settings_file)
--
-- {
--   "channel": "somelogin",       // chat room to join; default: the token's own channel
--   "animation": "terminal",      // animated emotes: "terminal", "lua" or "off"
--   "emotes": true,               // false shows emote names as text
--   "max_messages": 500           // how many messages a pane keeps
-- }
-- A missing file, or a missing key, means the default. A file that is not valid JSON is
-- reported in `settings.problem` and otherwise ignored.

local json_codec = require("twitch.json_codec")

local M = {}

M.DEFAULT_CHAT_SETTINGS = {
	channel = nil,
	animation = "terminal",
	emotes = true,
	max_messages = 500,
}

local ANIMATION_MODES = { terminal = true, lua = true, off = true }

--- Reads the settings file and fills in defaults.
function M.read_chat_settings(path)
	local settings = {}
	for key, value in pairs(M.DEFAULT_CHAT_SETTINGS) do
		settings[key] = value
	end
	local file = io.open(path, "r")
	if not file then
		return settings
	end
	local text = file:read("*a")
	file:close()
	local parsed, err = json_codec.decode_json(text or "")
	if type(parsed) ~= "table" then
		settings.problem = "chat_settings: " .. path .. " is not valid JSON: " .. tostring(err)
		return settings
	end
	if type(parsed.channel) == "string" and parsed.channel ~= "" then
		settings.channel = parsed.channel:gsub("^#", "")
	end
	if ANIMATION_MODES[parsed.animation] then
		settings.animation = parsed.animation
	end
	if type(parsed.emotes) == "boolean" then
		settings.emotes = parsed.emotes
	end
	if type(parsed.max_messages) == "number" and parsed.max_messages >= 10 then
		settings.max_messages = math.floor(parsed.max_messages)
	end
	return settings
end

return M
