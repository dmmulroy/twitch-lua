local t = require("spec_helper")
local base64 = require("distilled.crypto.base64")
local chat_events = require("twitch.chat_events")
local chat_pane = require("twitch.tui.chat_pane")
local emote_cache = require("twitch.emote_cache")
local emote_images = require("twitch.tui.emote_images")
local fake_terminal_grid = require("fake_terminal_grid")

local ESC = string.char(27)
local PLACEHOLDER = emote_images.IMAGE_PLACEHOLDER

local function png_header(width, height)
	local function u32(value)
		return string.char(math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256, math.floor(value / 256) % 256, value % 256)
	end
	return "\137PNG\r\n\26\n" .. u32(13) .. "IHDR" .. u32(width) .. u32(height) .. string.char(8, 6, 0, 0, 0) .. "crc!"
end

-- An animation of `count` 2x2 frames, each shown for the given delays (hundredths of a second).
local function animation(delays_cs)
	local frames = {}
	for index, delay in ipairs(delays_cs) do
		frames[index] = { delay_cs = delay, rgba = string.rep(string.char(index, 0, 0, 255), 4) }
	end
	return { width = 2, height = 2, frames = frames }
end

local function new_emotes(opts)
	opts = opts or {}
	local dir = t.temporary_directory()
	t.make_directories(dir .. "/twitch", dir .. "/bttv", dir .. "/7tv", dir .. "/ffz")
	local state = { dir = dir, requests = {}, now_ms = 1000000 }
	local emotes = emote_images.new_emote_images({
		cache_dir = dir,
		request_emote = function(request)
			state.requests[#state.requests + 1] = request
		end,
		now_ms = function()
			return state.now_ms
		end,
		animation = opts.animation,
		cell_width_px = opts.cell_width_px or 23,
		cell_height_px = opts.cell_height_px or 50,
	})
	return emotes, state
end

-- The Kitty graphics commands in some output, as "control;payload" strings.
local function graphics_commands(output)
	local commands = {}
	for body in output:gmatch(ESC .. "_G(.-)" .. ESC .. "\\") do
		commands[#commands + 1] = body
	end
	return commands
end

local KAPPA = { provider = "twitch", id = "25" }

t.test("emote_images: an emote that is not cached is asked for once and drawn as text meanwhile", function()
	local emotes, state = new_emotes()
	t.equal(emotes:emote_columns(KAPPA), nil)
	t.equal(emotes:emote_columns(KAPPA), nil)
	t.equal(state.requests, { { kind = "emote", provider = "twitch", id = "25", animated = false } })
	t.equal(emotes:has_pending_emotes(), true)
	t.equal(emotes:check_pending_emotes(), false)
end)

t.test("emote_images: once the worker has cached it, the revision changes and it has a width", function()
	local emotes, state = new_emotes()
	emotes:emote_columns(KAPPA)
	local revision = emotes.revision
	emote_cache.store_png_emote(state.dir, "twitch", "25", png_header(50, 56))
	t.equal(emotes:check_pending_emotes(), true)
	t.truthy(emotes.revision > revision)
	t.equal(emotes:has_pending_emotes(), false)
	-- 50x56 scaled to a 50px-high row is 44.6px wide: 2 cells of 23px
	t.equal(emotes:emote_columns(KAPPA), 2)
	t.equal(#state.requests, 1)
end)

t.test("emote_images: width in cells follows the image's shape and the cell size", function()
	local emotes, state = new_emotes()
	emote_cache.store_png_emote(state.dir, "twitch", "square", png_header(56, 56))
	emote_cache.store_png_emote(state.dir, "twitch", "wide", png_header(168, 56))
	emote_cache.store_png_emote(state.dir, "twitch", "huge", png_header(4000, 56))
	t.equal(emotes:emote_columns({ provider = "twitch", id = "square" }), 3) -- 50px over 23px cells
	t.equal(emotes:emote_columns({ provider = "twitch", id = "wide" }), 7)
	t.equal(emotes:emote_columns({ provider = "twitch", id = "huge" }), 12) -- capped
	local unknown_cell = emote_images.new_emote_images({ cache_dir = state.dir })
	t.equal(unknown_cell:emote_columns({ provider = "twitch", id = "square" }), 2)
end)

t.test("emote_images: unsafe ids are never asked for", function()
	local emotes, state = new_emotes()
	t.equal(emotes:emote_columns({ provider = "twitch", id = "../../etc/passwd" }), nil)
	t.equal(emotes:emote_columns({ provider = "twitch", id = "" }), nil)
	t.equal(#state.requests, 0)
end)

t.test("emote_images: words are emotes only when the emote index lists them", function()
	local emotes, state = new_emotes()
	t.equal(emotes:emote_columns({ word = "catJAM" }), nil)
	t.equal(#state.requests, 0)
	local revision = emotes.revision
	emotes:set_emote_word_index({ catJAM = { provider = "7tv", id = "01ABC", animated = true } })
	t.truthy(emotes.revision > revision)
	t.equal(emotes:emote_columns({ word = "catJAM" }), nil)
	t.equal(state.requests, { { kind = "emote", provider = "7tv", id = "01ABC", animated = true } })
	t.equal(emotes:emote_columns({ word = "hello" }), nil)
end)

t.test("emote_images: a still emote is loaded from its file once and drawn as placeholder cells", function()
	local emotes, state = new_emotes()
	local meta = emote_cache.store_png_emote(state.dir, "twitch", "25", png_header(50, 56))
	emotes:begin_render()
	t.equal(emotes:emote_columns(KAPPA), 2)
	local cells = emotes:draw_emote(KAPPA)
	-- image id 1 as the foreground color, placement 1 as the underline color
	t.equal(cells, ESC .. "[38;2;0;0;1m" .. ESC .. "[58;2;0;0;1m" .. PLACEHOLDER .. PLACEHOLDER .. ESC .. "[39m" .. ESC .. "[59m")
	t.equal(graphics_commands(emotes:end_render()), {
		"a=t,t=f,f=100,i=1,q=2;" .. base64.encode(meta.file),
		"a=p,U=1,i=1,p=1,r=1,c=2,q=2;",
	})
	-- the second redraw loads nothing
	emotes:begin_render()
	t.equal(emotes:draw_emote(KAPPA), cells)
	t.equal(emotes:end_render(), "")
end)

t.test("emote_images: terminal animation adds every frame with its delay and starts the loop", function()
	local emotes, state = new_emotes({ animation = "terminal" })
	local meta = emote_cache.store_gif_emote(state.dir, "twitch", "dance", animation({ 3, 5, 10 }))
	local request = { provider = "twitch", id = "dance", animated = true }
	emotes:begin_render()
	emotes:emote_columns(request)
	emotes:draw_emote(request)
	local path = base64.encode(meta.file)
	t.equal(graphics_commands(emotes:end_render()), {
		"a=t,i=1,t=f,f=32,s=2,v=2,S=16,O=0,q=2;" .. path,
		"a=a,i=1,r=1,z=30,q=2;",
		"a=f,i=1,z=50,t=f,f=32,s=2,v=2,S=16,O=16,q=2;" .. path,
		"a=f,i=1,z=100,t=f,f=32,s=2,v=2,S=16,O=32,q=2;" .. path,
		"a=a,i=1,s=3,v=1,q=2;",
		"a=p,U=1,i=1,p=1,r=1,c=3,q=2;",
	})
	t.equal(emotes:advance_emote_animation(), false) -- the terminal does the work
end)

t.test("emote_images: animation off loads only the first frame", function()
	local emotes, state = new_emotes({ animation = "off" })
	emote_cache.store_gif_emote(state.dir, "twitch", "dance", animation({ 3, 5, 10 }))
	local request = { provider = "twitch", id = "dance", animated = true }
	emotes:begin_render()
	emotes:draw_emote(request)
	local commands = graphics_commands(emotes:end_render())
	t.equal(#commands, 2)
	t.truthy(commands[1]:find("a=t,i=1,t=f,f=32,s=2,v=2,S=16,O=0", 1, true))
end)

t.test("emote_images: Lua animation loads one image per frame and switches by the clock", function()
	local emotes, state = new_emotes({ animation = "lua" })
	emote_cache.store_gif_emote(state.dir, "twitch", "dance", animation({ 3, 5, 10 })) -- 30, 50, 100 ms
	local request = { provider = "twitch", id = "dance", animated = true }
	local function image_id_drawn()
		emotes:begin_render()
		local cells = emotes:draw_emote(request)
		emotes:end_render()
		return tonumber(cells:match("%[38;2;0;0;(%d+)m"))
	end
	state.now_ms = 180 * 1000 -- a multiple of the 180 ms loop: frame 1
	emotes:begin_render()
	emotes:draw_emote(request)
	local commands = graphics_commands(emotes:end_render())
	t.equal(#commands, 6) -- three frames, each transmitted and placed
	t.truthy(commands[3]:find("a=t,i=2,t=f,f=32,s=2,v=2,S=16,O=16", 1, true))
	t.equal(commands[6], "a=p,U=1,i=3,p=1,r=1,c=3,q=2;")
	t.equal(image_id_drawn(), 1)
	t.equal(emotes:advance_emote_animation(), false)
	state.now_ms = state.now_ms + 29
	t.equal(emotes:advance_emote_animation(), false)
	state.now_ms = state.now_ms + 1 -- 30 ms in: frame 2
	t.equal(emotes:advance_emote_animation(), true)
	t.equal(image_id_drawn(), 2)
	t.equal(emotes:advance_emote_animation(), false)
	state.now_ms = state.now_ms + 50 -- 80 ms in: frame 3
	t.equal(image_id_drawn(), 3)
	state.now_ms = state.now_ms + 100 -- the loop starts again
	t.equal(image_id_drawn(), 1)
	-- an emote that is no longer drawn does not ask for redraws
	emotes:begin_render()
	emotes:end_render()
	state.now_ms = state.now_ms + 30
	t.equal(emotes:advance_emote_animation(), false)
end)

t.test("emote_images: emotes off screen are unloaded once too much image data is held", function()
	local emotes, state = new_emotes({ animation = "off" })
	-- each image counts 4096 * 4096 * 4 bytes = 64 MB, over the 48 MB budget on its own
	for _, id in ipairs({ "a", "b", "c" }) do
		emote_cache.store_png_emote(state.dir, "twitch", id, png_header(4096, 4096))
	end
	local function render(ids)
		emotes:begin_render()
		for _, id in ipairs(ids) do
			emotes:draw_emote({ provider = "twitch", id = id })
		end
		return graphics_commands(emotes:end_render())
	end
	t.equal(#render({ "a" }), 2) -- on screen: kept even though it is over the budget
	local second = render({ "b" })
	t.equal(second[#second], "a=d,d=I,i=1,q=2;") -- "a" is off screen now: unloaded
	local third = render({ "a", "b" })
	t.truthy(third[1]:find("a=t,t=f,f=100,i=3", 1, true)) -- "a" loads again under a new id
	t.equal(#third, 2) -- and nothing on screen is unloaded
end)

t.test("emote_images: release_all_images deletes every loaded image", function()
	local emotes, state = new_emotes({ animation = "lua" })
	emote_cache.store_png_emote(state.dir, "twitch", "25", png_header(50, 56))
	emote_cache.store_gif_emote(state.dir, "twitch", "dance", animation({ 3, 5 }))
	emotes:begin_render()
	emotes:draw_emote(KAPPA)
	emotes:draw_emote({ provider = "twitch", id = "dance", animated = true })
	emotes:end_render()
	local deletes = graphics_commands(emotes:release_all_images())
	table.sort(deletes)
	t.equal(deletes, { "a=d,d=I,i=1,q=2;", "a=d,d=I,i=2,q=2;", "a=d,d=I,i=3,q=2;" })
	t.equal(emotes:release_all_images(), "")
end)

t.test("emote_images: a new cell size changes widths and reloads images", function()
	local emotes, state = new_emotes()
	emote_cache.store_png_emote(state.dir, "twitch", "sq", png_header(56, 56))
	local request = { provider = "twitch", id = "sq" }
	emotes:begin_render()
	t.equal(emotes:emote_columns(request), 3)
	emotes:draw_emote(request)
	emotes:end_render()
	local revision = emotes.revision
	t.equal(emotes:set_cell_size(23, 50), "")
	local output = emotes:set_cell_size(10, 20)
	t.equal(graphics_commands(output), { "a=d,d=I,i=1,q=2;" })
	t.truthy(emotes.revision > revision)
	t.equal(emotes:emote_columns(request), 2)
end)

t.test("emote_images: an emote the worker could not fetch is given up on, then retried later", function()
	local emotes, state = new_emotes()
	emotes:emote_columns(KAPPA)
	emote_cache.mark_emote_failed(state.dir, "twitch", "25", "HTTP 404", os.time())
	t.equal(emotes:check_pending_emotes(), false)
	t.equal(emotes:has_pending_emotes(), false)
	t.equal(emotes:emote_columns(KAPPA), nil)
	t.equal(#state.requests, 1)
	-- ten minutes later the failure file is stale (removed here) and it is asked for again
	os.remove(state.dir .. "/twitch/25.failed")
	state.now_ms = state.now_ms + 601 * 1000
	t.equal(emotes:emote_columns(KAPPA), nil)
	t.equal(#state.requests, 2)
end)

t.test("emote_images: an emote that never arrives stops being waited for", function()
	local emotes, state = new_emotes()
	emotes:emote_columns(KAPPA)
	state.now_ms = state.now_ms + 121 * 1000
	emotes:check_pending_emotes()
	t.equal(emotes:has_pending_emotes(), false)
end)

t.test("emote_images: in a pane, the image loads before the row that shows it, and the row keeps its width", function()
	local emotes, state = new_emotes()
	local grid = fake_terminal_grid.new_fake_terminal_grid(40, 8)
	local writes = {}
	local pane = chat_pane.new_chat_pane({
		write = function(bytes)
			writes[#writes + 1] = bytes
			grid:write(bytes)
		end,
		columns = 40, rows = 8, channel = "dillon", emotes = emotes,
	})
	pane:start()
	local line = chat_events.encode_chat_event_line({
		seq = 1, kind = "message", id = "m1", name = "Viewer", login = "viewer", text = "hi Kappa !",
		parts = { { type = "text", text = "hi " }, { type = "emote", text = "Kappa", emote_id = "25" }, { type = "text", text = " !" } },
	}) .. "\n"
	pane:handle_event_log_bytes(line)
	t.equal(grid:row_text(4), "│Viewer: hi Kappa !" .. string.rep(" ", 20) .. "│") -- not cached yet: the name as text
	t.equal(#state.requests, 1)

	emote_cache.store_png_emote(state.dir, "twitch", "25", png_header(50, 56))
	t.equal(emotes:check_pending_emotes(), true)
	pane:render_all()
	t.equal(grid:row_text(4), "│Viewer: hi " .. PLACEHOLDER .. PLACEHOLDER .. " !" .. string.rep(" ", 23) .. "│")
	local last = writes[#writes]
	local load_at = last:find("a=t,t=f,f=100,i=1", 1, true)
	local cells_at = last:find(PLACEHOLDER, 1, true)
	t.truthy(load_at and cells_at and load_at < cells_at)

	pane:stop()
	t.truthy(writes[#writes]:find("a=d,d=I,i=1", 1, true))
end)
