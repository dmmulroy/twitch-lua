-- Entry point: one chat pane. Run it in a Rex terminal with
--   rex do <this file> tty="$(tty)" rex=<path to rex>
-- See lua/twitch/rex/chat_pane_runner.lua.

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = source:match("^(.*)/rex/[^/]+$")
package.path = root .. "/lua/?.lua;" .. root .. "/vendor/?.lua;" .. root .. "/vendor/?/init.lua;" .. package.path

require("twitch.rex.chat_pane_runner").run_chat_pane(root)
