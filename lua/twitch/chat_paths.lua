-- Where twitch-lua keeps its files. Every process (connection, panes, emote worker) derives
-- the same paths from HOME, so none of them depends on TMPDIR being the same.
--
--   local paths = require("twitch.chat_paths").twitch_chat_paths()
--   paths.token_file  -> ~/.config/twitch-lua/token

local M = {}

--- Returns the table of paths. `getenv` defaults to os.getenv; XDG_CONFIG_HOME,
--- XDG_STATE_HOME and XDG_CACHE_HOME are honoured.
function M.twitch_chat_paths(getenv)
	getenv = getenv or os.getenv
	local home = getenv("HOME") or ""
	local function base(variable, fallback)
		local value = getenv(variable)
		if value == nil or value == "" then
			value = home .. fallback
		end
		return value .. "/twitch-lua"
	end
	local config_dir = base("XDG_CONFIG_HOME", "/.config")
	local state_dir = base("XDG_STATE_HOME", "/.local/state")
	local cache_dir = base("XDG_CACHE_HOME", "/.cache")
	return {
		config_dir = config_dir,
		-- The Twitch user access token, alone on one line. Keep it mode 0600.
		token_file = config_dir .. "/token",
		-- Optional JSON settings: channel, animation, emotes, max_messages.
		settings_file = config_dir .. "/settings.json",

		state_dir = state_dir,
		-- Chat events, one JSON object per line, appended by the connection and read by panes.
		event_log = state_dir .. "/events.ndjson",
		-- { pid, state, text, updated_at } written by the connection.
		connection_status_file = state_dir .. "/connection.json",
		connection_lock_file = state_dir .. "/connection.lock",
		-- One empty file per live pane, named after its process id.
		pane_registry_dir = state_dir .. "/panes",
		-- Emotes that panes want downloaded, one JSON object per line.
		emote_request_log = state_dir .. "/emote_requests.ndjson",
		-- Third-party emote names for the joined channel: word -> emote.
		emote_index_file = state_dir .. "/emote_index.json",
		diagnostics_log = state_dir .. "/twitch-lua.log",

		cache_dir = cache_dir,
		emote_cache_dir = cache_dir .. "/emotes",
	}
end

return M
