-- The emote cache on disk, shared by every pane: one small JSON "meta" file per emote plus
-- its image. A pane never reads the pixels; it hands the terminal the image file's path.
--
--   local emote_cache = require("twitch.emote_cache")
--   local meta = emote_cache.read_emote_meta(cache_dir, "twitch", "25")
--   -- { kind = "png", width, height, file }                       a still image
--   -- { kind = "frames", width, height, frame_count, frame_bytes, delays_ms, file }
--   --   an animation: `file` holds the frames back to back as raw RGBA, frame k at byte
--   --   offset (k - 1) * frame_bytes
--   emote_cache.store_png_emote(cache_dir, "twitch", "25", png_bytes)
--   emote_cache.store_gif_emote(cache_dir, "7tv", id, decoded_gif)
--
-- Layout: <cache_dir>/<provider>/<id>.json, .png, .rgba, .failed. The directories must
-- exist (the emote worker makes them). The meta file is written last, by rename, so an
-- emote with a meta file is complete.

local emote_sources = require("twitch.emote_sources")
local json_codec = require("twitch.json_codec")

local M = {}

--- An animation keeps at most this many frames ...
M.MAX_EMOTE_FRAMES = 120
--- ... and at most this many bytes of raw RGBA. Past either, frames are dropped evenly.
M.MAX_EMOTE_ANIMATION_BYTES = 4 * 1024 * 1024
--- After a failed download the emote is not tried again for this long.
M.FAILED_EMOTE_RETRY_SECONDS = 600
-- Browsers show a GIF frame with a delay of 0 or 1 hundredths as a tenth of a second.
local MIN_GIF_DELAY_CS = 2
local DEFAULT_GIF_DELAY_MS = 100

local PNG_SIGNATURE = "\137PNG\r\n\26\n"

--- The cache files of one emote, or nil when the provider or id is not safe to use in a path.
function M.emote_cache_paths(cache_dir, provider, id)
	local known = false
	for _, name in ipairs(emote_sources.EMOTE_PROVIDERS) do
		known = known or name == provider
	end
	if not known or not emote_sources.is_safe_emote_id(id) then
		return nil
	end
	local base = cache_dir .. "/" .. provider .. "/" .. id
	return { meta = base .. ".json", png = base .. ".png", frames = base .. ".rgba", failed = base .. ".failed" }
end

local function read_file(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local bytes = file:read("*a")
	file:close()
	return bytes
end

-- Writes a file so that it is either absent or complete.
local function write_file_atomically(path, bytes)
	local temporary = path .. ".writing"
	local file, err = io.open(temporary, "wb")
	if not file then
		return nil, "emote_cache: cannot write " .. path .. ": " .. tostring(err)
	end
	file:write(bytes)
	file:close()
	local ok, rename_err = os.rename(temporary, path)
	if not ok then
		return nil, "emote_cache: cannot write " .. path .. ": " .. tostring(rename_err)
	end
	return true
end

--- The meta of a cached emote, or nil when it is not in the cache (or its meta is damaged).
function M.read_emote_meta(cache_dir, provider, id)
	local paths = M.emote_cache_paths(cache_dir, provider, id)
	local text = paths and read_file(paths.meta)
	if not text then
		return nil
	end
	local meta = json_codec.decode_json(text)
	if type(meta) ~= "table" or type(meta.width) ~= "number" or type(meta.height) ~= "number" or type(meta.file) ~= "string" then
		return nil
	end
	if meta.kind == "frames" and (type(meta.frame_count) ~= "number" or type(meta.delays_ms) ~= "table") then
		return nil
	end
	return meta
end

--- The width and height of a PNG from its header, or nil when the bytes are not a PNG.
function M.png_image_size(bytes)
	if type(bytes) ~= "string" or #bytes < 24 or bytes:sub(1, 8) ~= PNG_SIGNATURE or bytes:sub(13, 16) ~= "IHDR" then
		return nil
	end
	local function u32(position)
		local a, b, c, d = bytes:byte(position, position + 3)
		return ((a * 256 + b) * 256 + c) * 256 + d
	end
	local width, height = u32(17), u32(21)
	if width == 0 or height == 0 or width > 4096 or height > 4096 then
		return nil
	end
	return width, height
end

--- Stores a still emote. Returns its meta, or nil and a message.
function M.store_png_emote(cache_dir, provider, id, png_bytes)
	local paths = M.emote_cache_paths(cache_dir, provider, id)
	if not paths then
		return nil, "emote_cache: unsafe emote provider or id"
	end
	local width, height = M.png_image_size(png_bytes)
	if not width then
		return nil, "emote_cache: the download is not a PNG image"
	end
	local ok, err = write_file_atomically(paths.png, png_bytes)
	if not ok then
		return nil, err
	end
	local meta = { kind = "png", width = width, height = height, file = paths.png }
	ok, err = write_file_atomically(paths.meta, json_codec.encode_json(meta))
	if not ok then
		return nil, err
	end
	return meta
end

--- Reduces an animation to the frame and byte limits by keeping every n-th frame; a kept
--- frame takes over the time of the frames dropped after it, so the loop lasts as long.
--- `frames` is a list of { delay_ms, rgba }. Returns a new list.
function M.limit_emote_frames(frames, frame_bytes, max_frames, max_bytes)
	max_frames = max_frames or M.MAX_EMOTE_FRAMES
	max_bytes = max_bytes or M.MAX_EMOTE_ANIMATION_BYTES
	local allowed = math.max(1, math.min(max_frames, math.floor(max_bytes / math.max(1, frame_bytes))))
	if #frames <= allowed then
		return frames
	end
	local stride = math.ceil(#frames / allowed)
	local kept = {}
	for index = 1, #frames, stride do
		local delay = 0
		for dropped = index, math.min(index + stride - 1, #frames) do
			delay = delay + frames[dropped].delay_ms
		end
		kept[#kept + 1] = { delay_ms = delay, rgba = frames[index].rgba }
	end
	return kept
end

--- Stores an animated emote from a decoded GIF (twitch.gif_decoder). A GIF with a single
--- frame is stored as a one-frame animation. Returns its meta, or nil and a message.
function M.store_gif_emote(cache_dir, provider, id, image)
	local paths = M.emote_cache_paths(cache_dir, provider, id)
	if not paths then
		return nil, "emote_cache: unsafe emote provider or id"
	end
	local frame_bytes = image.width * image.height * 4
	local frames = {}
	for index, frame in ipairs(image.frames) do
		local delay_ms = (frame.delay_cs >= MIN_GIF_DELAY_CS) and frame.delay_cs * 10 or DEFAULT_GIF_DELAY_MS
		frames[index] = { delay_ms = delay_ms, rgba = frame.rgba }
	end
	frames = M.limit_emote_frames(frames, frame_bytes)

	local temporary = paths.frames .. ".writing"
	local file, err = io.open(temporary, "wb")
	if not file then
		return nil, "emote_cache: cannot write " .. paths.frames .. ": " .. tostring(err)
	end
	local delays_ms = {}
	for index, frame in ipairs(frames) do
		file:write(frame.rgba)
		delays_ms[index] = frame.delay_ms
	end
	file:close()
	local ok, rename_err = os.rename(temporary, paths.frames)
	if not ok then
		return nil, "emote_cache: cannot write " .. paths.frames .. ": " .. tostring(rename_err)
	end
	local meta = {
		kind = "frames",
		width = image.width,
		height = image.height,
		frame_count = #frames,
		frame_bytes = frame_bytes,
		delays_ms = json_codec.json_array(delays_ms),
		file = paths.frames,
	}
	ok, err = write_file_atomically(paths.meta, json_codec.encode_json(meta))
	if not ok then
		return nil, err
	end
	return meta
end

--- Records that an emote could not be fetched, so it is not requested again right away.
function M.mark_emote_failed(cache_dir, provider, id, reason, now_seconds)
	local paths = M.emote_cache_paths(cache_dir, provider, id)
	if paths then
		write_file_atomically(paths.failed, json_codec.encode_json({ at = now_seconds, reason = tostring(reason) }))
	end
end

--- True when the emote failed less than FAILED_EMOTE_RETRY_SECONDS ago.
function M.emote_failed_recently(cache_dir, provider, id, now_seconds)
	local paths = M.emote_cache_paths(cache_dir, provider, id)
	local text = paths and read_file(paths.failed)
	local failure = text and json_codec.decode_json(text)
	return type(failure) == "table" and type(failure.at) == "number" and now_seconds - failure.at < M.FAILED_EMOTE_RETRY_SECONDS
end

return M
