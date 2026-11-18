-- Entry point: the one Twitch chat connection. Run with
--   rex do --all <this file>
-- See lua/twitch/rex/chat_connection_runner.lua.

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = source:match("^(.*)/rex/[^/]+$")
package.path = root .. "/lua/?.lua;" .. root .. "/vendor/?.lua;" .. root .. "/vendor/?/init.lua;" .. package.path

require("twitch.rex.chat_connection_runner").run_chat_connection()
