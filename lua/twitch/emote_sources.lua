-- Where emote images and third-party emote lists come from: Twitch, BetterTTV, 7TV and
-- FrankerFaceZ. Builds URLs and reads the providers' JSON; does no I/O itself.
--
--   local emote_sources = require("twitch.emote_sources")
--   local source = emote_sources.emote_download_source("twitch", "25", false)
--   -- { url = "https://static-cdn.jtvnw.net/emoticons/v2/25/static/dark/2.0", format = "png" }
--   local lists = emote_sources.third_party_emote_lists("209286766")   -- what to fetch
--   local emotes = emote_sources.parse_third_party_emotes("bttv", decoded_json)
--   local index = emote_sources.build_emote_word_index({ emotes_a, emotes_b })
--
-- Images are fetched at 2x, which is sharp at one text row on a high-density display.
-- Animated emotes are always fetched as GIF: every provider serves one, so no WebP
-- decoder is needed.

local M = {}

M.EMOTE_PROVIDERS = { "twitch", "bttv", "7tv", "ffz" }

--- Emote ids come from chat and from third-party APIs. Only ids made of letters, digits,
--- "_" and "-" are used, so an id can never change a URL's path or a cache file's name.
function M.is_safe_emote_id(id)
	return type(id) == "string" and #id > 0 and #id <= 128 and id:find("^[%w_%-]+$") ~= nil
end

--- The URL and format ("png" or "gif") of an emote image, or nil and a message.
--- `fallback_url` is tried when the first URL is not found.
function M.emote_download_source(provider, id, animated)
	if not M.is_safe_emote_id(id) then
		return nil, "emote_sources: unsafe emote id"
	end
	if provider == "twitch" then
		local kind = animated and "animated" or "static"
		return {
			url = "https://static-cdn.jtvnw.net/emoticons/v2/" .. id .. "/" .. kind .. "/dark/2.0",
			format = animated and "gif" or "png",
		}
	elseif provider == "bttv" then
		local format = animated and "gif" or "png"
		return { url = "https://cdn.betterttv.net/emote/" .. id .. "/2x." .. format, format = format }
	elseif provider == "7tv" then
		if animated then
			return { url = "https://cdn.7tv.app/emote/" .. id .. "/2x.gif", format = "gif" }
		end
		return {
			url = "https://cdn.7tv.app/emote/" .. id .. "/2x.png",
			fallback_url = "https://cdn.7tv.app/emote/" .. id .. "/2x_static.png",
			format = "png",
		}
	elseif provider == "ffz" then
		-- FFZ's animated format could not be checked (their API did not answer), so its
		-- emotes are always shown as still images.
		return { url = "https://cdn.frankerfacez.com/emote/" .. id .. "/2", fallback_url = "https://cdn.frankerfacez.com/emote/" .. id .. "/1", format = "png" }
	end
	return nil, "emote_sources: unknown emote provider " .. tostring(provider)
end

--- The third-party emote lists for a channel, lowest priority first: when two lists
--- define the same word, the later one wins (channel over global, 7TV over BTTV over FFZ).
function M.third_party_emote_lists(channel_user_id)
	local channel = tostring(channel_user_id)
	return {
		{ provider = "ffz", url = "https://api.frankerfacez.com/v1/set/global" },
		{ provider = "bttv", url = "https://api.betterttv.net/3/cached/emotes/global" },
		{ provider = "7tv", url = "https://7tv.io/v3/emote-sets/global" },
		{ provider = "ffz", url = "https://api.frankerfacez.com/v1/room/id/" .. channel },
		{ provider = "bttv", url = "https://api.betterttv.net/3/cached/users/twitch/" .. channel },
		{ provider = "7tv", url = "https://7tv.io/v3/users/twitch/" .. channel },
	}
end

-- Provider JSON is untrusted: anything that should be a list but is not reads as empty.
local function list_or_empty(value)
	if type(value) == "table" then
		return value
	end
	return {}
end

local function add_emote(emotes, word, provider, id, animated)
	if type(id) == "number" then
		id = string.format("%d", id)
	end
	-- an emote word is one chat word: no spaces, and not absurdly long
	if type(word) == "string" and word ~= "" and #word <= 100 and not word:find("%s") and M.is_safe_emote_id(id) then
		emotes[#emotes + 1] = { word = word, provider = provider, id = id, animated = animated and true or nil }
	end
end

local function parse_bttv(body, emotes)
	local groups = { body }
	if body.channelEmotes or body.sharedEmotes then
		groups = { list_or_empty(body.channelEmotes), list_or_empty(body.sharedEmotes) }
	end
	for _, group in ipairs(groups) do
		for _, emote in ipairs(list_or_empty(group)) do
			if type(emote) == "table" then
				add_emote(emotes, emote.code, "bttv", emote.id, emote.animated or emote.imageType == "gif")
			end
		end
	end
end

local function parse_7tv(body, emotes)
	local set = body.emote_set or body
	for _, emote in ipairs(list_or_empty(list_or_empty(set).emotes)) do
		if type(emote) == "table" then
			local data = type(emote.data) == "table" and emote.data or {}
			add_emote(emotes, emote.name, "7tv", emote.id or data.id, data.animated)
		end
	end
end

local function parse_ffz(body, emotes)
	for _, set in pairs(list_or_empty(body.sets)) do
		for _, emote in ipairs(list_or_empty(list_or_empty(set).emoticons)) do
			if type(emote) == "table" then
				add_emote(emotes, emote.name, "ffz", emote.id, false)
			end
		end
	end
end

--- Reads one provider's decoded JSON list (global or channel) into a list of
--- { word, provider, id, animated }. Anything unexpected in the JSON is skipped.
function M.parse_third_party_emotes(provider, body)
	local emotes = {}
	if type(body) ~= "table" then
		return emotes
	end
	if provider == "bttv" then
		parse_bttv(body, emotes)
	elseif provider == "7tv" then
		parse_7tv(body, emotes)
	elseif provider == "ffz" then
		parse_ffz(body, emotes)
	end
	return emotes
end

--- Merges emote lists (lowest priority first) into { words = { [word] = emote }, count }.
function M.build_emote_word_index(emote_lists)
	local words, count = {}, 0
	for _, emotes in ipairs(emote_lists) do
		for _, emote in ipairs(emotes) do
			if words[emote.word] == nil then
				count = count + 1
			end
			words[emote.word] = { provider = emote.provider, id = emote.id, animated = emote.animated }
		end
	end
	return { words = words, count = count }
end

return M
