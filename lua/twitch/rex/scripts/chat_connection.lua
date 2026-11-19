-- Entry point: the one Twitch chat connection. Run with
--   rex do --all <this file> rex=<path to rex>
-- See lua/twitch/rex/chat_connection_runner.lua.
--
-- The same file runs from a checkout (lua/twitch/rex/scripts/) and from a LuaRocks tree
-- (share/lua/5.1/twitch/rex/scripts/): modules are found from this file's own path.
-- A checkout's vendor/ (distilled-lua's runtime and Twitch client) comes after lua/; in a
-- tree those are rocks next to this one.

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_dir = source:match("^(.*)/[^/]+$")
local module_root = script_dir:match("^(.*)/twitch/rex/scripts$")
local vendor = module_root .. "/../vendor"
package.path = module_root .. "/?.lua;" .. module_root .. "/?/init.lua;"
	.. vendor .. "/?.lua;" .. vendor .. "/?/init.lua;" .. package.path

require("twitch.rex.chat_connection_runner").run_chat_connection(script_dir)
