-- The one process per machine that is connected to Twitch chat. It appends chat events to
-- the event log; panes read the log and never connect themselves, so the number of tabs
-- does not change the number of Twitch connections (Twitch allows 3 per account).
--
-- Started by a pane (or by hand) as:  rex do --all <repo>/rex/chat_connection.lua
-- Exits by itself once no pane has been alive for a few seconds.

local chat_event_log = require("twitch.chat_event_log")
local chat_events = require("twitch.chat_events")
local chat_paths = require("twitch.chat_paths")
local chat_settings = require("twitch.chat_settings")
local eventsub_connection = require("twitch.eventsub_connection")
local json_codec = require("twitch.json_codec")
local rex_host = require("twitch.host.rex_host")
local twitch_auth = require("twitch.twitch_auth")

local M = {}

local PANE_CHECK_SECONDS = 5
-- With no live pane for this long, the connection closes and the process exits.
local IDLE_EXIT_SECONDS = 10
-- A pane starts the connection before it has registered itself.
local STARTUP_GRACE_SECONDS = 20
-- After a token problem, look at the token file again this often.
local TOKEN_RECHECK_SECONDS = 30
-- An emote worker that exits is started again after this long, at most this many times.
local EMOTE_WORKER_RESTART_SECONDS = 5
local EMOTE_WORKER_MAX_RESTARTS = 20

-- Counts live panes, removing registry entries whose process is gone.
local COUNT_LIVE_PANES_SCRIPT = [[
count=0
for entry in "$1"/*; do
  [ -e "$entry" ] || continue
  if kill -0 "${entry##*/}" 2>/dev/null; then count=$((count + 1)); else rm -f "$entry"; fi
done
echo "$count"
]]

--- Runs the chat connection until no pane needs it. Call from the top level of a
--- `rex do` script. `repo_root` is the twitch-lua checkout, used to find the emote worker.
function M.run_chat_connection(repo_root)
	local paths = chat_paths.twitch_chat_paths()
	rex.exec({ "/bin/mkdir", "-p", paths.state_dir, paths.pane_registry_dir, paths.emote_cache_dir })
	local host = rex_host.new_rex_host({ log_path = paths.diagnostics_log, log_label = "connection" })

	local process_id = host.own_process_id()
	-- shlock writes our pid and ignores a lock whose process is gone.
	local lock = rex.exec({ "/usr/bin/shlock", "-f", paths.connection_lock_file, "-p", tostring(process_id) })
	if not lock or not lock.ok then
		rex.stop(0) -- another connection is already running
		return
	end

	local distilled_host = require("distilled.host.rex")()
	local Twitch = require("twitch")
	local log = chat_event_log.open_chat_event_log(paths.event_log, { now = os.time })
	local started_at = host.now_seconds()
	local last_pane_seen_at = started_at
	local connection, tried_token, channel_login
	local token_problem_is_permanent = false

	local function write_connection_status(state, level, text)
		local file = io.open(paths.connection_status_file .. ".writing", "w")
		if not file then
			return
		end
		file:write(json_codec.encode_json({
			pid = tonumber(process_id or "0"),
			state = state,
			level = level,
			text = text,
			channel = channel_login,
			updated_at = os.time(),
		}), "\n")
		file:close()
		os.rename(paths.connection_status_file .. ".writing", paths.connection_status_file)
	end

	local function emit_status(level, text, state)
		host.log(level, text)
		write_connection_status(state, level, text)
		local _, err = log:append_chat_event(chat_events.chat_status_event(level, text, state))
		if err then
			host.log("error", err)
		end
	end

	local function on_connection_status(status)
		if status.state == "joined" then
			emit_status("info", "Joined #" .. tostring(channel_login), "joined")
		elseif status.state == "reconnecting" then
			emit_status("warn", tostring(status.text) .. ". Retrying in " .. tostring(status.retry_in_seconds) .. "s.", "reconnecting")
		elseif status.state == "stopped" then
			emit_status(status.level or "error", tostring(status.text), "stopped")
		elseif status.level == "warn" then
			emit_status("warn", tostring(status.text), status.state)
		else
			write_connection_status(status.state, status.level, status.text)
		end
	end

	-- The emote worker downloads and decodes emotes for every pane. It is started once the
	-- channel is known, and asked for the channel's third-party emote lists.
	local emote_worker, emote_worker_restarts = nil, 0
	local function start_emote_worker()
		local helper, err = host.start_helper({ rex.args.rex or "rex", "do", repo_root .. "/rex/emote_worker.lua" }, {
			ends_with_owner = true,
			on_exit = function(result)
				emote_worker = nil
				emote_worker_restarts = emote_worker_restarts + 1
				host.log("warn", "emote worker exited with status " .. tostring(result.code))
				if emote_worker_restarts <= EMOTE_WORKER_MAX_RESTARTS then
					host.start_timer(EMOTE_WORKER_RESTART_SECONDS, start_emote_worker)
				end
			end,
		})
		if not helper then
			host.log("error", "emote worker not started: " .. tostring(err))
		end
		emote_worker = helper
	end
	local function set_up_emotes(settings, broadcaster_user_id)
		if not settings.emotes then
			return
		end
		local file = io.open(paths.emote_request_log, "a")
		if file then
			file:write(json_codec.encode_json({ kind = "index", channel_id = broadcaster_user_id }), "\n")
			file:close()
		end
		if not emote_worker then
			start_emote_worker()
		end
	end

	local function on_notification(subscription_type, twitch_event)
		local chat_event = chat_events.chat_event_from_notification(subscription_type, twitch_event)
		if chat_event then
			local _, err = log:append_chat_event(chat_event)
			if err then
				host.log("error", err)
			end
		end
	end

	-- Reads the token, checks it with Twitch and opens the connection. Returns true when
	-- the connection was started.
	local function start_with_token_file()
		local token, read_err = twitch_auth.read_twitch_token_file(paths.token_file)
		tried_token = token
		if not token then
			token_problem_is_permanent = true
			emit_status("error", read_err, "stopped")
			return false
		end
		local identity, validate_err = twitch_auth.validate_twitch_token(distilled_host.transport, token)
		if not identity then
			-- No status means Twitch could not be reached: worth trying the same token again.
			token_problem_is_permanent = validate_err.status ~= nil
			emit_status("error", validate_err.message .. " (" .. paths.token_file .. ")", "stopped")
			return false
		end
		local missing = twitch_auth.missing_twitch_chat_scopes(identity)
		if #missing > 0 then
			token_problem_is_permanent = true
			emit_status("error", "Twitch token lacks the scopes: " .. table.concat(missing, ", ") .. " (" .. paths.token_file .. ")", "stopped")
			return false
		end

		local helix = Twitch.new({
			host = distilled_host,
			access_token = token,
			client_id = identity.client_id,
			retry = "none", -- the subscribe step has 10 seconds; the connection does its own retries
			deadline_s = 8,
		})
		local settings = chat_settings.read_chat_settings(paths.settings_file)
		channel_login = (settings.channel or identity.login):lower()
		local broadcaster_user_id = identity.user_id
		if channel_login ~= identity.login then
			local users, err = helix:get_users({ login = { channel_login } })
			local user = users and users.data and users.data[1]
			if not user then
				token_problem_is_permanent = false
				emit_status("error", "Twitch channel not found: " .. channel_login .. (err and (" (" .. tostring(err) .. ")") or ""), "stopped")
				return false
			end
			broadcaster_user_id = user.id
		end

		connection = eventsub_connection.new_eventsub_connection({
			host = host,
			helix = helix,
			broadcaster_user_id = broadcaster_user_id,
			user_id = identity.user_id,
			on_notification = on_notification,
			on_status = on_connection_status,
		})
		token_problem_is_permanent = false
		set_up_emotes(settings, broadcaster_user_id)
		connection:start()
		return true
	end

	local function shut_down()
		if connection then
			connection:stop()
		end
		if emote_worker then
			emote_worker:stop()
		end
		log:remove_event_log()
		os.remove(paths.connection_status_file)
		os.remove(paths.emote_request_log)
		os.remove(paths.emote_index_file)
		os.remove(paths.connection_lock_file)
		rex.stop(0)
	end

	host.start_repeating_timer(PANE_CHECK_SECONDS, function()
		local result = rex.exec({ "/bin/sh", "-c", COUNT_LIVE_PANES_SCRIPT, "sh", paths.pane_registry_dir })
		-- tonumber(nil) raises in Rex's Lua, so the match gets a fallback first
		local live_panes = tonumber(result and result.stdout and result.stdout:match("%d+") or "0") or 0
		local now = host.now_seconds()
		if live_panes > 0 then
			last_pane_seen_at = now
		elseif now - last_pane_seen_at >= IDLE_EXIT_SECONDS and now - started_at >= STARTUP_GRACE_SECONDS then
			shut_down()
		end
	end)

	-- After a token problem: start again once the token file changes, or, when Twitch
	-- could not be reached, with the same token.
	host.start_repeating_timer(TOKEN_RECHECK_SECONDS, function()
		if connection and connection:connection_state() ~= "stopped" then
			return
		end
		local token = twitch_auth.read_twitch_token_file(paths.token_file)
		if token ~= tried_token or not token_problem_is_permanent then
			if connection then
				connection:stop()
				connection = nil
			end
			start_with_token_file()
		end
	end)

	-- Twitch requires a running app to validate its token every hour.
	host.start_repeating_timer(twitch_auth.TOKEN_VALIDATION_INTERVAL_SECONDS, function()
		if not connection or not tried_token then
			return
		end
		local _, validate_err = twitch_auth.validate_twitch_token(distilled_host.transport, tried_token)
		if validate_err and validate_err.status == 401 then
			connection:stop()
			token_problem_is_permanent = true
			emit_status("error", "Twitch token is no longer valid (" .. paths.token_file .. ")", "stopped")
		end
	end)

	write_connection_status("connecting", "info", "Starting")
	start_with_token_file()
end

return M
