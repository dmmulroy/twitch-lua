-- Finds web links in one word of chat. Twitch sends no link fragments, so the pane finds
-- them itself. Pure functions; no escape codes.
--
--   local chat_links = require("twitch.chat_links")
--   local link = chat_links.find_chat_link_in_word("(https://twitch.tv/dillon).")
--   -- { first = 2, last = 25, url = "https://twitch.tv/dillon" }
--   chat_links.find_chat_link_in_word("twitch.tv/dillon")
--   -- { first = 1, last = 16, url = "https://twitch.tv/dillon" }
--
-- Two kinds of word are links:
--   * http:// or https:// followed by a host;
--   * a bare host such as twitch.tv or youtu.be/abc, when its last label is a real
--     top-level domain (twitch.top_level_domains, IANA's full list). Some of those are
--     also file extensions (.rs, .py, .md, .sh, .zip), so "main.rs" is a link too.
--     Bare links are opened as https://.
-- A link holds only printable ASCII URL characters, so the URL can go inside an escape
-- sequence (OSC 8) as it is: it can never contain ESC, BEL, spaces or non-ASCII bytes.
-- Punctuation around a link is not part of it: "(", quotes before; ".", ",", "!", "?",
-- ":", ";", quotes and an unbalanced ")" after.

local M = {}

M.MAX_CHAT_LINK_BYTES = 2048

-- Every top-level domain, lowercase (generated from IANA's list).
M.TOP_LEVEL_DOMAINS = require("twitch.top_level_domains")

-- RFC 3986's unreserved, reserved and percent characters.
local URL_CHARACTERS = "[%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]"
local URL_RUN = "^" .. URL_CHARACTERS .. "+"
local LEADING_PUNCTUATION = "^[%(%[<\"'`]+"
local TRAILING_PUNCTUATION = "[%.,!%?:;\"'`>%]]$"

local function count_of(text, character)
	local _, count = text:gsub("%" .. character, "")
	return count
end

-- Takes trailing punctuation off; ")" only when it has no "(" to close inside the link.
local function trim_link_end(candidate)
	while #candidate > 0 do
		local last = candidate:sub(-1)
		if last:match(TRAILING_PUNCTUATION) then
			candidate = candidate:sub(1, -2)
		elseif last == ")" and count_of(candidate, ")") > count_of(candidate, "(") then
			candidate = candidate:sub(1, -2)
		else
			break
		end
	end
	return candidate
end

-- "host" part of a candidate without a scheme, or nil when it is not a linkable host.
local function bare_link_host(candidate)
	local host = candidate:match("^([%w%-%.]+)")
	if not host then
		return nil
	end
	local rest = candidate:sub(#host + 1)
	if rest ~= "" and not rest:match("^[:/%?#]") then
		return nil -- "user@host.com" and the like
	end
	local labels = {}
	for label in (host .. "."):gmatch("([^%.]*)%.") do
		if label == "" or label:sub(1, 1) == "-" or label:sub(-1) == "-" then
			return nil
		end
		labels[#labels + 1] = label
	end
	if #labels < 2 or not M.TOP_LEVEL_DOMAINS[labels[#labels]:lower()] then
		return nil
	end
	return host
end

--- Finds the link in a word (text without spaces). Returns { first, last, url } with the
--- link's byte range in the word, or nil when the word holds no link.
function M.find_chat_link_in_word(word)
	local leading = word:match(LEADING_PUNCTUATION) or ""
	local first = #leading + 1
	local candidate = word:sub(first):match(URL_RUN)
	if not candidate then
		return nil
	end
	candidate = trim_link_end(candidate)
	if #candidate > M.MAX_CHAT_LINK_BYTES then
		return nil
	end

	local url
	local scheme = candidate:match("^([Hh][Tt][Tt][Pp][Ss]?)://")
	if scheme then
		-- with a scheme any host is fine (localhost, an IP); "https://" alone is not a link
		if not candidate:sub(#scheme + 4):match("^%w") then
			return nil
		end
		url = candidate
	else
		if not bare_link_host(candidate) then
			return nil
		end
		url = "https://" .. candidate
	end
	return { first = first, last = first + #candidate - 1, url = url }
end

return M
