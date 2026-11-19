-- Runs every spec. From the repo root:
--   lua spec/run_specs.lua        luajit spec/run_specs.lua        rex do spec/run_specs.lua
-- Pass a name to run one file: lua spec/run_specs.lua websocket_client

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = source:match("^(.*)/spec/[^/]+$") or "."
package.path = root .. "/lua/?.lua;" .. root .. "/vendor/?.lua;" .. root .. "/vendor/?/init.lua;" .. root .. "/spec/?.lua;" .. package.path

SPEC_ROOT = root

local SPEC_MODULES = {
	"twitch.json_codec_spec",
	"twitch.websocket_client_spec",
	"twitch.eventsub_session_spec",
	"twitch.eventsub_connection_spec",
	"twitch.chat_events_spec",
	"twitch.chat_store_spec",
	"twitch.chat_event_log_spec",
	"twitch.twitch_auth_spec",
	"twitch.helix_client_spec",
	"twitch.chat_commands_spec",
	"twitch.channel_session_spec",
	"twitch.rex.palette_actions_spec",
	"twitch.gif_decoder_spec",
	"twitch.emote_cache_spec",
	"twitch.emote_sources_spec",
	"twitch.terminal_text_spec",
	"twitch.chat_links_spec",
	"twitch.tui.terminal_keys_spec",
	"twitch.tui.message_input_spec",
	"twitch.tui.twt_text_wrap_spec",
	"twitch.tui.chat_feed_layout_spec",
	"twitch.tui.emote_images_spec",
	"twitch.tui.chat_pane_spec",
}

local only = (rawget(_G, "rex") and rex.args and rex.args.only) or (arg and arg[1])
local t = require("spec_helper")
local ran = 0
for _, name in ipairs(SPEC_MODULES) do
	if not only or name:find(only, 1, true) then
		local path = root .. "/lua/" .. name:gsub("%.", "/") .. ".lua"
		local file = io.open(path, "r")
		if file then
			file:close()
			local before = t.failed
			require(name)
			ran = ran + 1
			if t.failed > before then
				print("FAIL " .. name)
			end
		else
			print("MISSING " .. name)
		end
	end
end

for _, failure in ipairs(t.failures) do
	print("  x " .. failure)
end
print(string.format("%d spec files, %d passed, %d failed", ran, t.passed, t.failed))
if t.failed > 0 then
	if rawget(_G, "rex") then
		rex.stop(1)
	else
		os.exit(1)
	end
end
