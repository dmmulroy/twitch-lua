-- Emote images in a chat pane: decides which words are emotes, asks for the ones that are
-- not cached yet, loads cached ones into the terminal (Kitty graphics protocol) and
-- returns the cells that show them. No I/O except reading the emote cache's small meta
-- files; everything it wants written to the terminal is returned as a string.
--
--   local emote_images = require("twitch.tui.emote_images")
--   local emotes = emote_images.new_emote_images({
--     cache_dir = paths.emote_cache_dir,
--     request_emote = function(request) end,   -- { kind = "emote", provider, id, animated }
--     now_ms = function() return milliseconds end,
--     animation = "terminal",                  -- "terminal", "lua" or "off"
--     cell_width_px = 23, cell_height_px = 50,
--   })
--
-- The chat pane calls, for every redraw:
--   emotes:begin_render()
--   emotes:emote_columns(request) -> columns | nil     (while laying rows out)
--   emotes:draw_emote(request) -> cells                (while writing rows)
--   emotes:end_render() -> bytes to write before the rows (image loads and unloads)
-- `request` is { provider = "twitch", id, animated } or { word = "catJAM" }.
-- `emotes.revision` changes whenever emote_columns may answer differently.
--
-- Animation:
--   "terminal"  every frame is added to one image and the terminal plays it
--   "lua"       every frame is its own image; advance_emote_animation() says when a
--               visible emote should show another frame, and the pane redraws
--   "off"       the first frame only

local base64 = require("distilled.crypto.base64")
local emote_cache = require("twitch.emote_cache")
local emote_sources = require("twitch.emote_sources")

local M = {}

local ESC = string.char(27)
-- U+10EEEE: a cell with this character shows part of an image (Kitty "Unicode placeholder").
local IMAGE_PLACEHOLDER = string.char(0xF4, 0x8E, 0xBB, 0xAE)
local MAX_EMOTE_COLUMNS = 12
local DEFAULT_EMOTE_COLUMNS = 2
-- Image data kept in the pane's terminal. Past this, emotes that are not on screen are unloaded.
local MAX_LOADED_IMAGE_BYTES = 48 * 1024 * 1024
-- An emote that never arrives stops being polled for after this long ...
local PENDING_GIVE_UP_SECONDS = 120
-- ... and is asked for again after this long.
local RETRY_AFTER_SECONDS = 600
local MAX_IMAGE_ID = 16777215 -- ids travel in a 24-bit foreground color

local Emotes = {}
Emotes.__index = Emotes

--- Creates the emote helper for one pane.
function M.new_emote_images(opts)
	assert(opts.cache_dir, "emote_images: cache_dir is required")
	return setmetatable({
		cache_dir = opts.cache_dir,
		request_emote = opts.request_emote or function() end,
		now_ms = opts.now_ms or function()
			return os.time() * 1000
		end,
		animation = opts.animation or "terminal",
		cell_width_px = opts.cell_width_px,
		cell_height_px = opts.cell_height_px,
		-- "q=2" tells the terminal not to answer; an answer would arrive as key presses.
		quiet = (opts.quiet == false) and "" or ",q=2",
		revision = 0,
		word_index = {}, -- word -> { provider, id, animated }
		known = {}, -- "provider/id" -> { state = "ready" | "pending" | "failed", meta, columns, ... }
		loaded = {}, -- "provider/id" -> { first_image_id, image_count, bytes, used_in_render }
		loaded_bytes = 0,
		next_image_id = 1,
		render_number = 0,
		setup_output = {},
	}, Emotes)
end

local function now_seconds(self)
	return self.now_ms() / 1000
end

-- How many cells wide an image is when it is scaled to one row high.
local function columns_for_image(self, width, height)
	if not self.cell_width_px or not self.cell_height_px or self.cell_width_px <= 0 or height <= 0 then
		return DEFAULT_EMOTE_COLUMNS
	end
	local scaled_width = width * (self.cell_height_px / height)
	return math.max(1, math.min(MAX_EMOTE_COLUMNS, math.ceil(scaled_width / self.cell_width_px - 0.01)))
end

-- Turns a request into provider, id, animated; nil when it is not an emote.
local function resolve_request(self, request)
	if request.word then
		local emote = self.word_index[request.word]
		if not emote then
			return nil
		end
		return emote.provider, emote.id, emote.animated
	end
	return request.provider, request.id, request.animated
end

local function known_emote(self, provider, id, animated)
	if not emote_sources.is_safe_emote_id(id) then
		return nil
	end
	local key = provider .. "/" .. id
	local entry = self.known[key]
	if entry and entry.state == "failed" and now_seconds(self) >= entry.retry_at then
		entry = nil -- time to try again
	end
	if not entry then
		local meta = emote_cache.read_emote_meta(self.cache_dir, provider, id)
		if meta then
			entry = { state = "ready", meta = meta, columns = columns_for_image(self, meta.width, meta.height) }
		elseif emote_cache.emote_failed_recently(self.cache_dir, provider, id, os.time()) then
			entry = { state = "failed", retry_at = now_seconds(self) + RETRY_AFTER_SECONDS }
		else
			entry = { state = "pending", provider = provider, id = id, since = now_seconds(self) }
			self.request_emote({ kind = "emote", provider = provider, id = id, animated = animated and true or false })
		end
		self.known[key] = entry
	end
	return entry, key
end

--- The width in cells of the emote a request names, or nil when it is not an emote or its
--- image is not ready (the caller then draws the name as text). Asks for a missing image.
function Emotes:emote_columns(request)
	local provider, id, animated = resolve_request(self, request)
	if not provider then
		return nil
	end
	local entry = known_emote(self, provider, id, animated)
	if entry and entry.state == "ready" then
		return entry.columns
	end
	return nil
end

--- Looks again for emotes that were asked for. Returns true when one arrived (or was
--- given up on), after which `revision` has changed and the pane should redraw.
function Emotes:check_pending_emotes()
	local changed = false
	for key, entry in pairs(self.known) do
		if entry.state == "pending" then
			local meta = emote_cache.read_emote_meta(self.cache_dir, entry.provider, entry.id)
			if meta then
				self.known[key] = { state = "ready", meta = meta, columns = columns_for_image(self, meta.width, meta.height) }
				changed = true
			elseif now_seconds(self) - entry.since > PENDING_GIVE_UP_SECONDS
				or emote_cache.emote_failed_recently(self.cache_dir, entry.provider, entry.id, os.time()) then
				self.known[key] = { state = "failed", retry_at = now_seconds(self) + RETRY_AFTER_SECONDS }
			end
		end
	end
	if changed then
		self.revision = self.revision + 1
	end
	return changed
end

--- True while at least one emote has been asked for and has not arrived.
function Emotes:has_pending_emotes()
	for _, entry in pairs(self.known) do
		if entry.state == "pending" then
			return true
		end
	end
	return false
end

--- Replaces the third-party emote words (from the emote index file): word -> { provider, id, animated }.
function Emotes:set_emote_word_index(words)
	self.word_index = type(words) == "table" and words or {}
	self.revision = self.revision + 1
end

local function graphics_command(self, control, payload)
	return ESC .. "_G" .. control .. self.quiet .. ";" .. (payload or "") .. ESC .. "\\"
end

local function allocate_image_ids(self, count)
	if self.next_image_id + count > MAX_IMAGE_ID then
		self.next_image_id = 1
	end
	local first = self.next_image_id
	self.next_image_id = first + count
	return first
end

local function frame_source(meta, frame)
	return string.format("t=f,f=32,s=%d,v=%d,S=%d,O=%d", meta.width, meta.height, meta.frame_bytes, (frame - 1) * meta.frame_bytes)
end

local function virtual_placement(self, image_id, columns)
	return graphics_command(self, "a=p,U=1,i=" .. image_id .. ",p=1,r=1,c=" .. columns)
end

-- Queues the commands that load an emote into the terminal and returns its loaded record.
local function load_emote(self, key, entry)
	local meta = entry.meta
	local out = self.setup_output
	local path = base64.encode(meta.file)
	local record
	if meta.kind == "png" then
		local image_id = allocate_image_ids(self, 1)
		out[#out + 1] = graphics_command(self, "a=t,t=f,f=100,i=" .. image_id, path)
		out[#out + 1] = virtual_placement(self, image_id, entry.columns)
		record = { first_image_id = image_id, image_count = 1, bytes = meta.width * meta.height * 4 }
	elseif self.animation == "lua" and meta.frame_count > 1 then
		local first = allocate_image_ids(self, meta.frame_count)
		for frame = 1, meta.frame_count do
			out[#out + 1] = graphics_command(self, "a=t,i=" .. (first + frame - 1) .. "," .. frame_source(meta, frame), path)
			out[#out + 1] = virtual_placement(self, first + frame - 1, entry.columns)
		end
		local loop_ms = 0
		for _, delay in ipairs(meta.delays_ms) do
			loop_ms = loop_ms + delay
		end
		record = {
			first_image_id = first, image_count = meta.frame_count, bytes = meta.frame_bytes * meta.frame_count,
			delays_ms = meta.delays_ms, loop_ms = math.max(1, loop_ms), shown_frame = 1,
		}
	else
		local image_id = allocate_image_ids(self, 1)
		local frames = (self.animation == "terminal") and meta.frame_count or 1
		out[#out + 1] = graphics_command(self, "a=t,i=" .. image_id .. "," .. frame_source(meta, 1), path)
		if frames > 1 then
			out[#out + 1] = graphics_command(self, "a=a,i=" .. image_id .. ",r=1,z=" .. meta.delays_ms[1])
			for frame = 2, frames do
				out[#out + 1] = graphics_command(self, "a=f,i=" .. image_id .. ",z=" .. meta.delays_ms[frame] .. "," .. frame_source(meta, frame), path)
			end
			-- s=3: run the animation; v=1: loop forever
			out[#out + 1] = graphics_command(self, "a=a,i=" .. image_id .. ",s=3,v=1")
		end
		out[#out + 1] = virtual_placement(self, image_id, entry.columns)
		record = { first_image_id = image_id, image_count = 1, bytes = meta.frame_bytes * frames }
	end
	self.loaded[key] = record
	self.loaded_bytes = self.loaded_bytes + record.bytes
	return record
end

-- The frame of a Lua-animated emote that should be on screen now.
local function current_frame(record, now_ms)
	local position = now_ms % record.loop_ms
	for frame, delay in ipairs(record.delays_ms) do
		if position < delay then
			return frame
		end
		position = position - delay
	end
	return 1
end

-- The cells that show an image: its id is the foreground color, its placement the underline color.
local function placeholder_cells(image_id, columns)
	local red = math.floor(image_id / 65536) % 256
	local green = math.floor(image_id / 256) % 256
	local blue = image_id % 256
	return ESC .. "[38;2;" .. red .. ";" .. green .. ";" .. blue .. "m" .. ESC .. "[58;2;0;0;1m"
		.. string.rep(IMAGE_PLACEHOLDER, columns) .. ESC .. "[39m" .. ESC .. "[59m"
end

--- Call before laying out and writing a redraw.
function Emotes:begin_render()
	self.render_number = self.render_number + 1
end

--- The cells for an emote that emote_columns said is ready. Loads the image on first use.
function Emotes:draw_emote(request)
	local provider, id, animated = resolve_request(self, request)
	local entry, key
	if provider then
		entry, key = known_emote(self, provider, id, animated)
	end
	if not entry or entry.state ~= "ready" then
		-- It was ready when the row was laid out; keep the row's width.
		return string.rep(" ", request.columns or DEFAULT_EMOTE_COLUMNS)
	end
	local record = self.loaded[key] or load_emote(self, key, entry)
	record.used_in_render = self.render_number
	local image_id = record.first_image_id
	if record.delays_ms then
		record.shown_frame = current_frame(record, self.now_ms())
		image_id = image_id + record.shown_frame - 1
	end
	return placeholder_cells(image_id, entry.columns)
end

local function unload_emote(self, key, out)
	local record = self.loaded[key]
	for offset = 0, record.image_count - 1 do
		out[#out + 1] = graphics_command(self, "a=d,d=I,i=" .. (record.first_image_id + offset))
	end
	self.loaded_bytes = self.loaded_bytes - record.bytes
	self.loaded[key] = nil
end

--- Call after writing a redraw's rows into a buffer. Returns what must be written to the
--- terminal before those rows: loads for emotes that are new on screen, and unloads of
--- emotes that are off screen once too much image data is held.
function Emotes:end_render()
	local out = self.setup_output
	self.setup_output = {}
	if self.loaded_bytes > MAX_LOADED_IMAGE_BYTES then
		local idle = {}
		for key, record in pairs(self.loaded) do
			if record.used_in_render ~= self.render_number then
				idle[#idle + 1] = { key = key, used = record.used_in_render or 0 }
			end
		end
		table.sort(idle, function(a, b)
			return a.used < b.used
		end)
		for _, item in ipairs(idle) do
			if self.loaded_bytes <= MAX_LOADED_IMAGE_BYTES then
				break
			end
			unload_emote(self, item.key, out)
		end
	end
	return table.concat(out)
end

--- For "lua" animation: true when an emote drawn in the last redraw should now show
--- another frame, so the pane should redraw.
function Emotes:advance_emote_animation()
	local now = self.now_ms()
	for _, record in pairs(self.loaded) do
		if record.delays_ms and record.used_in_render == self.render_number and current_frame(record, now) ~= record.shown_frame then
			return true
		end
	end
	return false
end

--- Unloads every image from the terminal. Returns the bytes to write.
function Emotes:release_all_images()
	local out = {}
	local keys = {}
	for key in pairs(self.loaded) do
		keys[#keys + 1] = key
	end
	for _, key in ipairs(keys) do
		unload_emote(self, key, out)
	end
	return table.concat(out)
end

--- Sets the size of a terminal cell in pixels, which decides how many cells an emote takes.
--- Returns the bytes to write (images are unloaded so they load again at the new size).
function Emotes:set_cell_size(cell_width_px, cell_height_px)
	if cell_width_px == self.cell_width_px and cell_height_px == self.cell_height_px then
		return ""
	end
	self.cell_width_px, self.cell_height_px = cell_width_px, cell_height_px
	for _, entry in pairs(self.known) do
		if entry.state == "ready" then
			entry.columns = columns_for_image(self, entry.meta.width, entry.meta.height)
		end
	end
	self.revision = self.revision + 1
	return self:release_all_images()
end

M.IMAGE_PLACEHOLDER = IMAGE_PLACEHOLDER
M.MAX_LOADED_IMAGE_BYTES = MAX_LOADED_IMAGE_BYTES

return M
