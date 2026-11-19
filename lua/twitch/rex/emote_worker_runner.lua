-- Downloads and decodes emotes in its own process, so that a pane or the connection never
-- waits on a download or on decoding a large GIF (the largest seen takes 1.5 seconds).
--
-- Started by the connection as:  rex do <scripts>/emote_worker.lua
-- It reads requests from the emote request log (one JSON object per line), which panes
-- and the connection append to:
--   { "kind": "emote", "provider": "twitch", "id": "25", "animated": false }
--   { "kind": "index", "channel_id": "209286766" }     fetch the third-party emote lists
-- and writes the emote cache (twitch.emote_cache) and the emote word index file.
-- URLs are built here from the provider and id; a request cannot name a URL.

local compat = require("distilled.compat")
local chat_paths = require("twitch.chat_paths")
local emote_cache = require("twitch.emote_cache")
local emote_sources = require("twitch.emote_sources")
local gif_decoder = require("twitch.gif_decoder")
local json_codec = require("twitch.json_codec")
local rex_host = require("twitch.host.rex_host")

local M = {}

local POLL_SECONDS = 0.25
local DOWNLOAD_TIMEOUT_SECONDS = 20
-- 7TV's and FFZ's APIs sometimes take 15 seconds or more to answer.
local LIST_TIMEOUT_SECONDS = 30
-- Lists that could not be fetched are tried again this much later, this many times.
local LIST_RETRY_SECONDS = 120
local LIST_MAX_ATTEMPTS = 4
local MAX_DOWNLOAD_BYTES = 8 * 1024 * 1024
-- Frames decoded before the cache's own limits are applied.
local MAX_DECODED_FRAMES = 600
-- The emote cache on disk is cut back to three quarters of this when it grows past it.
local MAX_EMOTE_CACHE_KILOBYTES = 256 * 1024

-- Removes the least recently read emotes (all files of each) until the cache is small enough.
local PRUNE_EMOTE_CACHE_SCRIPT = [[
dir="$1"; cap="$2"
used=$(du -sk "$dir" 2>/dev/null | cut -f1)
[ "${used:-0}" -le "$cap" ] && exit 0
ls -tur "$dir"/*/* 2>/dev/null | while IFS= read -r file; do
  base="${file%.*}"
  rm -f "$base.json" "$base.png" "$base.rgba" "$base.failed"
  used=$(du -sk "$dir" | cut -f1)
  [ "$used" -le $((cap * 3 / 4)) ] && break
done
echo pruned
]]

local function read_file(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local bytes = file:read("*a")
	file:close()
	return bytes
end

local function download_to_file(url, path)
	local result = rex.exec({
		"/usr/bin/curl", "--silent", "--show-error", "--fail", "--location",
		"--proto", "=https", "--proto-redir", "=https",
		"--max-time", tostring(DOWNLOAD_TIMEOUT_SECONDS),
		"--max-filesize", tostring(MAX_DOWNLOAD_BYTES),
		"--output", path, url,
	}, { timeout = DOWNLOAD_TIMEOUT_SECONDS + 5 })
	if result and result.ok then
		return true
	end
	return nil, (result and result.stderr or "curl did not run"):gsub("%s+$", "")
end

--- Runs the emote worker until its owner goes away. Call from the top level of a
--- `rex do` script.
function M.run_emote_worker()
	local paths = chat_paths.twitch_chat_paths()
	local host = rex_host.new_rex_host({ log_path = paths.diagnostics_log, log_label = "emotes" })
	local directories = { "/bin/mkdir", "-p", paths.state_dir }
	for _, provider in ipairs(emote_sources.EMOTE_PROVIDERS) do
		directories[#directories + 1] = paths.emote_cache_dir .. "/" .. provider
	end
	rex.exec(directories)
	local pruned = rex.exec({ "/bin/sh", "-c", PRUNE_EMOTE_CACHE_SCRIPT, "sh", paths.emote_cache_dir, tostring(MAX_EMOTE_CACHE_KILOBYTES) })
	if pruned and pruned.stdout:find("pruned", 1, true) then
		host.log("info", "emote cache was over its size limit; the least recently used emotes were removed")
	end

	local function fetch_emote(request)
		local provider, id = request.provider, request.id
		local cache_paths = emote_cache.emote_cache_paths(paths.emote_cache_dir, provider, id)
		if not cache_paths then
			return
		end
		if emote_cache.read_emote_meta(paths.emote_cache_dir, provider, id)
			or emote_cache.emote_failed_recently(paths.emote_cache_dir, provider, id, os.time()) then
			return
		end
		local function fail(reason)
			host.log("warn", "emote " .. provider .. "/" .. id .. " not cached: " .. tostring(reason))
			emote_cache.mark_emote_failed(paths.emote_cache_dir, provider, id, reason, os.time())
		end
		local source, source_err = emote_sources.emote_download_source(provider, id, request.animated)
		if not source then
			return fail(source_err)
		end
		local download_path = cache_paths.meta .. ".download"
		local ok, err = download_to_file(source.url, download_path)
		if not ok and source.fallback_url then
			ok, err = download_to_file(source.fallback_url, download_path)
		end
		if not ok then
			os.remove(download_path)
			return fail(err)
		end
		local bytes = read_file(download_path) or ""
		os.remove(download_path)
		-- Trust the bytes, not the expected format.
		local stored, store_err
		if bytes:sub(1, 4) == "GIF8" then
			local image, decode_err = gif_decoder.decode_gif(bytes, { max_frames = MAX_DECODED_FRAMES })
			if not image then
				return fail(decode_err)
			end
			stored, store_err = emote_cache.store_gif_emote(paths.emote_cache_dir, provider, id, image)
		else
			stored, store_err = emote_cache.store_png_emote(paths.emote_cache_dir, provider, id, bytes)
		end
		if not stored then
			return fail(store_err)
		end
	end

	-- The third-party emote lists of the joined channel. Fetching never blocks emote
	-- downloads: the curls run on their own and are collected by the main loop.
	local index_fetch -- { channel_id, attempt, fetched = { [url] = emotes }, running = { ... }, retry_at }

	local function write_emote_index()
		local lists = emote_sources.third_party_emote_lists(index_fetch.channel_id)
		local available, missing = {}, 0
		for _, list in ipairs(lists) do
			if index_fetch.fetched[list.url] then
				available[#available + 1] = index_fetch.fetched[list.url]
			else
				missing = missing + 1
			end
		end
		local index = emote_sources.build_emote_word_index(available)
		index.revision = os.time()
		index.channel_id = index_fetch.channel_id
		local temporary = paths.emote_index_file .. ".writing"
		local file = io.open(temporary, "w")
		if file then
			file:write(json_codec.encode_json(index))
			file:close()
			os.rename(temporary, paths.emote_index_file)
		end
		host.log("info", "emote index: " .. index.count .. " words from " .. (#lists - missing) .. " of " .. #lists .. " lists")
		return missing
	end

	local function start_emote_list_fetches()
		index_fetch.attempt = index_fetch.attempt + 1
		index_fetch.retry_at = nil
		for _, list in ipairs(emote_sources.third_party_emote_lists(index_fetch.channel_id)) do
			if not index_fetch.fetched[list.url] then
				local handle = rex.exec.start({
					"/usr/bin/curl", "--silent", "--show-error", "--location", "--proto", "=https",
					"--max-time", tostring(LIST_TIMEOUT_SECONDS), list.url,
				}, { detach = true })
				if handle then
					index_fetch.running[#index_fetch.running + 1] = { list = list, handle = handle }
				end
			end
		end
	end

	-- Called from the main loop: collects finished list fetches and schedules a retry.
	local function collect_emote_list_fetches()
		if not index_fetch then
			return
		end
		if index_fetch.retry_at and os.time() >= index_fetch.retry_at then
			start_emote_list_fetches()
		end
		local finished = false
		for position = #index_fetch.running, 1, -1 do
			local item = index_fetch.running[position]
			if not item.handle:running() then
				table.remove(index_fetch.running, position)
				finished = true
				local result = item.handle:wait(1)
				local body = result and result.ok and json_codec.decode_json(result.stdout or "") or nil
				if type(body) == "table" then
					-- a provider's "no such channel" answer is JSON too, and parses to no emotes
					index_fetch.fetched[item.list.url] = emote_sources.parse_third_party_emotes(item.list.provider, body)
					write_emote_index() -- panes get each list as soon as it arrives
				else
					host.log("warn", "emote list not fetched (attempt " .. index_fetch.attempt .. "): " .. item.list.url)
				end
			end
		end
		if finished and #index_fetch.running == 0 then
			if write_emote_index() > 0 and index_fetch.attempt < LIST_MAX_ATTEMPTS then
				index_fetch.retry_at = os.time() + LIST_RETRY_SECONDS
			end
		end
	end

	local function handle_request_line(line)
		local request = json_codec.decode_json(line)
		if type(request) ~= "table" then
			return
		end
		if request.kind == "emote" then
			fetch_emote(request)
		elseif request.kind == "index" then
			if type(request.channel_id) == "string" and request.channel_id:find("^%d+$") then
				for _, item in ipairs(index_fetch and index_fetch.running or {}) do
					item.handle:kill()
				end
				index_fetch = { channel_id = request.channel_id, attempt = 0, fetched = {}, running = {} }
				start_emote_list_fetches()
			end
		end
	end

	-- Follow the request log from its start. Only whole lines are consumed.
	local offset = 0
	while true do
		local file = io.open(paths.emote_request_log, "rb")
		if file then
			local size = file:seek("end")
			if size < offset then
				offset = 0 -- the log was replaced
			end
			file:seek("set", offset)
			local chunk = file:read("*a") or ""
			file:close()
			local position = 1
			while true do
				local line_end = chunk:find("\n", position, true)
				if not line_end then
					break
				end
				local line = chunk:sub(position, line_end - 1)
				local ok, err = compat.pcall(handle_request_line, line)
				if not ok then
					host.log("error", "emote request failed: " .. tostring(err))
				end
				position = line_end + 1
			end
			offset = offset + position - 1
		end
		local ok, err = compat.pcall(collect_emote_list_fetches)
		if not ok then
			index_fetch = nil
			host.log("error", "emote index fetch failed: " .. tostring(err))
		end
		rex.sleep(POLL_SECONDS)
	end
end

return M
