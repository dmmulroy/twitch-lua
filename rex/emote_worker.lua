-- Entry point: the emote download and decode worker. Started by the chat connection.
-- See lua/twitch/rex/emote_worker_runner.lua.

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = source:match("^(.*)/rex/[^/]+$")
package.path = root .. "/lua/?.lua;" .. root .. "/vendor/?.lua;" .. root .. "/vendor/?/init.lua;" .. package.path

require("twitch.rex.emote_worker_runner").run_emote_worker()
