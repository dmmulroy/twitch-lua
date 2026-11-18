-- Animated emotes from pure Lua, shown three ways. Run it in a Rex pane:
--
--   rex do "$TMPDIR/twitch-lua-spike/emotes/emote_demo.lua"
--
-- Row 1 is a still frame. Row 2 hands every frame to the terminal and lets it play them
-- (the Kitty animation protocol, what twt does). Row 3 loads every frame as its own image
-- and a Lua timer switches which one the cells point at.
-- It stops by itself after `secs` (default 60), or press Ctrl-C.
--
-- With verify=<file> tty=<tty> it asks the terminal to answer every command and writes a
-- count of the answers to <file> (used to check the commands without looking at the pane).

-- Rex gives the path with no leading "@"; stock Lua has one.
local dir = rex.args.dir or (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/[^/]+$"))
package.path = dir .. "/?.lua;" .. package.path
local gif = require("gif")

local ESC = string.char(27)
local PLACEHOLDER = string.char(0xF4, 0x8E, 0xBB, 0xAE) -- U+10EEEE
local SAMPLES = {
	"tw_g_emotesv2_cb4c93c8bef44ae6888cf239f98754b7.gif",
	"tw_g_emotesv2_ba5ae4be5c724ca59d649fa713ff0730.gif",
	"tw_g_emotesv2_3205787cb443439cbeb4dd83740f47c7.gif",
	"tw_g_emotesv2_91417441b2f24a5299ed7b2a1ce8e7b9.gif",
}
local COLS = 2 -- cells per emote, one row high, as in chat
local TICK_SECONDS = 0.04
local verify = rex.args.verify
local QUIET = verify and "" or ",q=2"

local function base64(s)
	return (rex.exec({ "/usr/bin/base64" }, { stdin = s }).stdout:gsub("%s", ""))
end

-- verify mode: collect what the terminal answers. The reader starts before any command is
-- sent, because the tty's input queue holds only about 1 KB of unread replies.
local replies = ""
if verify then
	rex.exec.start({ "/bin/sh", "-c", 'stty raw -echo <"$0"; exec cat <"$0"', rex.args.tty }, {
		detach = true,
		stdout = function(data)
			replies = replies .. data
		end,
	})
	rex.sleep(0.5)
end

local out = {}
local function emit(s)
	out[#out + 1] = s
end
local function flush()
	io.write(table.concat(out))
	io.flush()
	out = {}
end
local function graphics(control, payload)
	emit(ESC .. "_G" .. control .. QUIET .. ";" .. (payload or "") .. ESC .. "\\")
end

-- Cells that show image `id`: the id is the foreground color, the placement the underline color.
local function cells(id)
	local r = math.floor(id / 65536)
	local g = math.floor(id / 256) % 256
	local b = id % 256
	return ESC .. "[38;2;" .. r .. ";" .. g .. ";" .. b .. "m" .. ESC .. "[58;2;0;0;1m"
		.. string.rep(PLACEHOLDER, COLS) .. ESC .. "[39m" .. ESC .. "[59m"
end

-- Decode each sample once and write its frames to one file, back to back.
local emotes = {}
local decode_started = os.clock()
for index, name in ipairs(SAMPLES) do
	local file = assert(io.open(dir .. "/samples/" .. name, "rb"))
	local image = assert(gif.decode(file:read("*a")))
	file:close()
	local strip_path = dir .. "/cache/demo_" .. index .. ".rgba"
	local strip = assert(io.open(strip_path, "wb"))
	local delays = {}
	for k, frame in ipairs(image.frames) do
		strip:write(frame.rgba)
		delays[k] = (frame.delay_cs <= 1 and 10 or frame.delay_cs) * 10 -- ms; browsers show <=1cs as 100ms
	end
	strip:close()
	emotes[index] = {
		width = image.width,
		height = image.height,
		frame_bytes = image.width * image.height * 4,
		frame_count = #image.frames,
		delays_ms = delays,
		path_b64 = base64(strip_path),
	}
end
local decode_seconds = os.clock() - decode_started

local function frame_source(emote, k)
	return string.format(
		"t=f,f=32,s=%d,v=%d,S=%d,O=%d",
		emote.width,
		emote.height,
		emote.frame_bytes,
		(k - 1) * emote.frame_bytes
	)
end

local STILL_ID, TERMINAL_ID, LUA_ID = 1000, 2000, 10000
local commands = 0
for index, emote in ipairs(emotes) do
	-- 1. still
	graphics("a=t,i=" .. (STILL_ID + index) .. "," .. frame_source(emote, 1), emote.path_b64)
	graphics("a=p,U=1,i=" .. (STILL_ID + index) .. ",p=1,r=1,c=" .. COLS)
	-- 2. the terminal plays it
	local id = TERMINAL_ID + index
	graphics("a=t,i=" .. id .. "," .. frame_source(emote, 1), emote.path_b64)
	graphics("a=a,i=" .. id .. ",r=1,z=" .. emote.delays_ms[1])
	for k = 2, emote.frame_count do
		graphics("a=f,i=" .. id .. ",z=" .. emote.delays_ms[k] .. "," .. frame_source(emote, k), emote.path_b64)
	end
	graphics("a=a,i=" .. id .. ",s=3,v=1")
	graphics("a=p,U=1,i=" .. id .. ",p=1,r=1,c=" .. COLS)
	-- 3. Lua switches frames: one image per frame
	for k = 1, emote.frame_count do
		local frame_id = LUA_ID + index * 1000 + k
		graphics("a=t,i=" .. frame_id .. "," .. frame_source(emote, k), emote.path_b64)
		graphics("a=p,U=1,i=" .. frame_id .. ",p=1,r=1,c=" .. COLS)
	end
	commands = commands + 6 + (emote.frame_count - 1) + emote.frame_count * 2
	emote.loop_ms = 0
	for _, ms in ipairs(emote.delays_ms) do
		emote.loop_ms = emote.loop_ms + ms
	end
end

local LABEL_WIDTH = 34
local ROW_STILL, ROW_TERMINAL, ROW_LUA = 3, 5, 7
local function row(y, label, id_of)
	emit(ESC .. "[" .. y .. ";1H" .. ESC .. "[2K" .. label .. string.rep(" ", LABEL_WIDTH - #label))
	for index in ipairs(emotes) do
		emit(cells(id_of(index)) .. "  ")
	end
end

emit(ESC .. "[2J" .. ESC .. "[1;1HAnimated emote demo (stops by itself, or Ctrl-C)")
row(ROW_STILL, "1. Still frame", function(index)
	return STILL_ID + index
end)
row(ROW_TERMINAL, "2. The terminal plays the frames", function(index)
	return TERMINAL_ID + index
end)
row(ROW_LUA, "3. Lua switches the frames", function(index)
	return LUA_ID + index * 1000 + 1
end)
emit(ESC .. "[9;1H" .. string.format("decoded %d GIFs in %.0f ms; sent %d graphics commands", #emotes, decode_seconds * 1000, commands))
emit(ESC .. "[10;1H")
flush()

-- Frame k is on screen while elapsed-in-loop is inside its delay.
local function frame_at(emote, elapsed_ms)
	local t = elapsed_ms % emote.loop_ms
	for k, ms in ipairs(emote.delays_ms) do
		if t < ms then
			return k
		end
		t = t - ms
	end
	return 1
end

local started = os.clock()
local shown = {}
local ticks, redraws = 0, 0
rex.every(TICK_SECONDS, function()
	ticks = ticks + 1
	local elapsed_ms = (os.clock() - started) * 1000
	local changed = false
	for index, emote in ipairs(emotes) do
		local k = frame_at(emote, elapsed_ms)
		if shown[index] ~= k then
			shown[index] = k
			changed = true
		end
	end
	if changed then
		redraws = redraws + 1
		emit(ESC .. "7" .. ESC .. "[?2026h") -- save cursor; hold the screen until the row is whole
		emit(ESC .. "[" .. ROW_LUA .. ";" .. (LABEL_WIDTH + 1) .. "H")
		for index in ipairs(emotes) do
			emit(cells(LUA_ID + index * 1000 + shown[index]) .. "  ")
		end
		emit(ESC .. "[?2026l" .. ESC .. "8")
		flush()
	end
end)

rex.after(tonumber(rex.args.secs or 60), function()
	if verify then
		local ok, failed, errors = 0, 0, {}
		for body in replies:gmatch(ESC .. "_G(.-)" .. ESC .. "\\") do
			if body:match(";OK$") then
				ok = ok + 1
			else
				failed = failed + 1
				errors[#errors + 1] = body
			end
		end
		local file = assert(io.open(verify, "w"))
		file:write(string.format(
			"decode %.0f ms; %d commands sent; replies: %d OK, %d errors; %d ticks, %d redraws in %.1fs\n",
			decode_seconds * 1000, commands, ok, failed, ticks, redraws, os.clock() - started
		))
		for i = 1, math.min(#errors, 12) do
			file:write("  error: " .. errors[i] .. "\n")
		end
		file:close()
		rex.exec({ "/bin/sh", "-c", 'stty sane <"$0"; pkill -f "cat <$0" 2>/dev/null; true', rex.args.tty })
	end
	for index, emote in ipairs(emotes) do
		graphics("a=d,d=I,i=" .. (STILL_ID + index))
		graphics("a=d,d=I,i=" .. (TERMINAL_ID + index))
		for k = 1, emote.frame_count do
			graphics("a=d,d=I,i=" .. (LUA_ID + index * 1000 + k))
		end
	end
	emit(ESC .. "[11;1Hdone\r\n")
	flush()
	rex.stop(0)
end)
