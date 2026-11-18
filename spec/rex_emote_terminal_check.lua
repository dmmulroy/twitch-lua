-- Checks, in a real Rex terminal, that the terminal accepts every graphics command
-- twitch.tui.emote_images sends, in each animation mode. Not part of run_specs.lua: it
-- needs a terminal and emotes in the cache (run a chat pane first, or the emote worker).
--
--   rex do spec/rex_emote_terminal_check.lua tty="$(tty)" out=/tmp/emote_check.txt
--
-- The terminal's answers arrive as input, so a raw-mode reader collects them. The result
-- file lists, per mode, how many commands were sent and how many were answered OK.

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = source:match("^(.*)/spec/[^/]+$")
package.path = root .. "/lua/?.lua;" .. root .. "/vendor/?.lua;" .. root .. "/vendor/?/init.lua;" .. package.path

local chat_paths = require("twitch.chat_paths")
local emote_images = require("twitch.tui.emote_images")

local ESC = string.char(27)
local paths = chat_paths.twitch_chat_paths()
local tty = rex.args.tty

-- Every emote in the cache, as requests.
local requests = {}
local listing = rex.exec({ "/bin/sh", "-c", 'cd "$0" && ls */*.json', paths.emote_cache_dir }).stdout
for provider, id in listing:gmatch("([%w]+)/([%w_%-]+)%.json") do
	requests[#requests + 1] = { provider = provider, id = id, animated = true }
end

local replies = ""
rex.exec.start({ "/bin/sh", "-c", 'stty raw -echo <"$0"; exec cat <"$0"', tty }, {
	detach = true,
	stdout = function(data)
		replies = replies .. data
	end,
})

local results = {}
local function count_replies()
	local ok, failed, errors = 0, 0, {}
	for body in replies:gmatch(ESC .. "_G(.-)" .. ESC .. "\\") do
		if body:match(";OK$") then
			ok = ok + 1
		else
			failed = failed + 1
			errors[#errors + 1] = body
		end
	end
	replies = ""
	return ok, failed, errors
end

-- Output callbacks only run between timers, never during rex.sleep, so every step is a timer.
local MODES = { "terminal", "lua", "off" }
local run_mode

local function finish()
	local file = assert(io.open(rex.args.out, "w"))
	file:write(table.concat(results, "\n"), "\n")
	file:close()
	rex.exec({ "/bin/sh", "-c", 'stty sane <"$0"; pkill -f "cat <$0" 2>/dev/null; true', tty })
	rex.stop(0)
end

run_mode = function(index)
	local mode = MODES[index]
	if not mode then
		return finish()
	end
	local emotes = emote_images.new_emote_images({
		cache_dir = paths.emote_cache_dir,
		animation = mode,
		quiet = false,
		cell_width_px = 23,
		cell_height_px = 50,
		now_ms = function()
			return os.clock() * 1000
		end,
	})
	emotes:begin_render()
	local cells = {}
	for _, request in ipairs(requests) do
		if emotes:emote_columns(request) then
			cells[#cells + 1] = emotes:draw_emote(request)
		end
	end
	local setup = emotes:end_render()
	local _, sent = setup:gsub(ESC .. "_G", "")
	io.write(setup)
	io.write(ESC .. "[" .. (index * 2) .. ";1H" .. mode .. ": " .. table.concat(cells, " "))
	io.flush()
	rex.after(2, function()
		local ok, failed, errors = count_replies()
		results[#results + 1] = string.format("%s: %d emotes, %d commands sent, %d OK, %d errors", mode, #cells, sent, ok, failed)
		for error_index = 1, math.min(#errors, 5) do
			results[#results + 1] = "  error: " .. errors[error_index]
		end
		local unload = emotes:release_all_images()
		local _, unloads = unload:gsub(ESC .. "_G", "")
		io.write(unload)
		io.flush()
		rex.after(1, function()
			local _, unload_failed, unload_errors = count_replies()
			results[#results + 1] = string.format("  unload: %d commands, %d errors %s", unloads, unload_failed, unload_errors[1] or "")
			run_mode(index + 1)
		end)
	end)
end

io.write(ESC .. "[2J")
rex.after(0.5, function()
	run_mode(1)
end)
