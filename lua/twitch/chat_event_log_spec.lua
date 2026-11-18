local t = require("spec_helper")
local chat_event_log = require("twitch.chat_event_log")
local chat_events = require("twitch.chat_events")

local function read_events(path)
	local events = {}
	local file = io.open(path, "r")
	if file then
		for line in file:lines() do
			events[#events + 1] = chat_events.decode_chat_event_line(line)
		end
		file:close()
	end
	return events
end

t.test("chat_event_log: appends with rising seq and a timestamp", function()
	local path = os.tmpname()
	os.remove(path)
	local log = chat_event_log.open_chat_event_log(path, { now = function() return 1000 end })
	t.equal(log:append_chat_event({ kind = "status", text = "one" }), 1)
	t.equal(log:append_chat_event({ kind = "message", id = "m", text = "two" }), 2)
	local events = read_events(path)
	t.equal(#events, 2)
	t.equal(events[2].seq, 2)
	t.equal(events[2].at, 1000)
	t.equal(events[2].text, "two")
	os.remove(path)
end)

t.test("chat_event_log: reopening continues the sequence, past a damaged last line", function()
	local path = os.tmpname()
	os.remove(path)
	local first = chat_event_log.open_chat_event_log(path)
	first:append_chat_event({ kind = "status", text = "one" })
	first:append_chat_event({ kind = "status", text = "two" })
	local file = io.open(path, "a")
	file:write('{"seq":3,"kind":"mess')
	file:close()
	local second = chat_event_log.open_chat_event_log(path)
	t.equal(second:append_chat_event({ kind = "status", text = "three" }), 3)
	os.remove(path)
end)

t.test("chat_event_log: compaction keeps the newest lines and the file stays readable", function()
	local path = os.tmpname()
	os.remove(path)
	local log = chat_event_log.open_chat_event_log(path, { keep_lines = 3, compact_after_lines = 6 })
	for i = 1, 7 do
		log:append_chat_event({ kind = "status", text = "line " .. i })
	end
	local events = read_events(path)
	t.equal(#events, 3)
	t.equal(events[1].seq, 5)
	t.equal(events[3].text, "line 7")
	t.equal(log:append_chat_event({ kind = "status", text = "line 8" }), 8)
	t.equal(#read_events(path), 4)
	os.remove(path)
end)

t.test("chat_event_log: removing the file keeps sequence numbers rising", function()
	local path = os.tmpname()
	os.remove(path)
	local log = chat_event_log.open_chat_event_log(path)
	log:append_chat_event({ kind = "status", text = "one" })
	log:remove_event_log()
	t.equal(io.open(path, "r"), nil)
	t.equal(log:append_chat_event({ kind = "status", text = "two" }), 2)
	os.remove(path)
end)

t.test("chat_event_log: an unwritable path returns an error", function()
	local log = chat_event_log.open_chat_event_log("/nonexistent-dir/twitch-lua/events.ndjson")
	local seq, err = log:append_chat_event({ kind = "status", text = "x" })
	t.equal(seq, nil)
	t.truthy(err:find("cannot append", 1, true))
end)
