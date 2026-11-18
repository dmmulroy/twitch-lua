-- Runs one chat pane inside a Rex terminal: wires the pane (twitch.tui.chat_pane) to the
-- terminal's keys, the event log and Rex's resize events, and sends through Helix.
--
-- Started in a pane as:  rex do <repo>/rex/chat_pane.lua tty="$(tty)" rex=<path to rex>
-- It never connects to Twitch chat itself; it makes sure the one connection process
-- (rex/chat_connection.lua) is running and reads what that writes.

local chat_commands = require("twitch.tui.chat_commands")
local chat_pane = require("twitch.tui.chat_pane")
local chat_paths = require("twitch.chat_paths")
local chat_settings = require("twitch.chat_settings")
local emote_images = require("twitch.tui.emote_images")
local json_codec = require("twitch.json_codec")
local rex_host = require("twitch.host.rex_host")
local twitch_auth = require("twitch.twitch_auth")

local M = {}

local CONNECTION_CHECK_SECONDS = 5
-- How often a pane looks for emotes it asked for, and for a new emote word index.
local PENDING_EMOTE_CHECK_SECONDS = 0.5
local EMOTE_INDEX_CHECK_SECONDS = 3
-- With animation = "lua": how often visible emotes are checked for their next frame.
local EMOTE_ANIMATION_TICK_SECONDS = 0.04
local TERMINAL_CREATOR = "com.superlogical.terminal"

local function read_file(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local text = file:read("*a")
	file:close()
	return text
end

--- Runs the pane until Ctrl-C. Call from the top level of a `rex do` script.
--- `repo_root` is the twitch-lua checkout, used to find the connection script.
function M.run_chat_pane(repo_root)
	local tty = rex.args.tty
	if type(tty) ~= "string" or tty == "" then
		error('chat pane: start it with tty="$(tty)" so it can read keys', 0)
	end
	local rex_cli = rex.args.rex or "rex"
	local paths = chat_paths.twitch_chat_paths()
	rex.exec({ "/bin/mkdir", "-p", paths.state_dir, paths.pane_registry_dir, paths.emote_cache_dir })
	local host = rex_host.new_rex_host({ log_path = paths.diagnostics_log, log_label = "pane" })
	local settings = chat_settings.read_chat_settings(paths.settings_file)

	local function terminal_size()
		local result = rex.exec({ "/bin/sh", "-c", 'stty size <"$0"', tty })
		local rows, columns = (result and result.stdout or ""):match("(%d+) (%d+)")
		return tonumber(columns or "80"), tonumber(rows or "24")
	end

	local process_id = host.own_process_id()
	local registry_file = process_id and (paths.pane_registry_dir .. "/" .. process_id) or nil
	local pane
	local commands, sending_problem -- set once the token has been checked

	local function quit_chat_pane()
		pane:stop()
		rex.exec({ "/bin/sh", "-c", 'stty sane <"$0"', tty })
		if registry_file then
			os.remove(registry_file)
		end
		rex.stop(0)
	end

	-- Emote images. Panes only read the emote cache; a missing emote is asked for through
	-- the request log, which the emote worker follows.
	local emotes
	if settings.emotes then
		local size = rex.block.call(TERMINAL_CREATOR, "size", {}) or {}
		emotes = emote_images.new_emote_images({
			cache_dir = paths.emote_cache_dir,
			animation = settings.animation,
			cell_width_px = size.cell_width_px,
			cell_height_px = size.cell_height_px,
			now_ms = function()
				return host.now_seconds() * 1000
			end,
			request_emote = function(request)
				local file = io.open(paths.emote_request_log, "a")
				if file then
					file:write(json_codec.encode_json(request), "\n")
					file:close()
				end
			end,
		})
	end

	local columns, rows = terminal_size()
	pane = chat_pane.new_chat_pane({
		write = function(bytes)
			io.write(bytes)
			io.flush()
		end,
		columns = columns,
		rows = rows,
		channel = settings.channel,
		max_messages = settings.max_messages,
		emotes = emotes,
		send_message = function(text)
			if not commands then
				return nil, sending_problem or "still starting"
			end
			return commands:send_chat_message(text)
		end,
		run_command = function(line)
			if not commands then
				return { level = "error", text = sending_problem or "still starting" }
			end
			return commands:run_chat_command(line)
		end,
		on_quit = quit_chat_pane,
	})

	-- Registered before the connection is started, so the connection sees a live pane.
	if registry_file then
		local file = io.open(registry_file, "w")
		if file then
			file:close()
		end
	end

	-- Rex reports the pane's size whenever it changes (also when a tab is first shown).
	rex.on("terminal.size_changed", host.guard("resize", function(_, event)
		if event.block_id ~= rex.block_id then
			return
		end
		local payload = event.payload or event
		if emotes and payload.cell_width_px and payload.cell_height_px then
			-- a tab that has never been shown reports a placeholder cell size until it is
			local unload = emotes:set_cell_size(payload.cell_width_px, payload.cell_height_px)
			if unload ~= "" then
				io.write(unload)
				pane:render_all()
			end
		end
		if payload.columns and payload.rows then
			pane:handle_resize(payload.columns, payload.rows)
		end
	end))

	-- Keys: a helper puts the terminal in raw mode and passes on every byte typed.
	local keys_helper, keys_err = host.start_helper({ "/bin/sh", "-c", 'stty raw -echo <"$0"; exec cat <"$0"', tty }, {
		on_output = function(bytes)
			pane:handle_key_bytes(bytes)
		end,
		on_exit = function()
			quit_chat_pane() -- the terminal went away
		end,
	})
	if not keys_helper then
		error("chat pane: " .. tostring(keys_err), 0)
	end

	pane:start()
	if settings.problem then
		pane:show_local_status("warn", settings.problem)
	end

	-- The event log: history first, then every new event. -F follows a replaced file.
	local log_file = io.open(paths.event_log, "a")
	if log_file then
		log_file:close()
	end
	host.start_helper({ "/usr/bin/tail", "-n", "+1", "-F", paths.event_log }, {
		ends_with_owner = true,
		on_output = function(bytes)
			pane:handle_event_log_bytes(bytes)
		end,
	})

	if emotes then
		host.start_repeating_timer(PENDING_EMOTE_CHECK_SECONDS, function()
			if emotes:has_pending_emotes() and emotes:check_pending_emotes() then
				pane:render_all()
			end
		end)
		-- The emote word index is rewritten by the worker when the channel is joined.
		local index_size
		local function load_emote_index()
			local text = read_file(paths.emote_index_file)
			local size = text and #text or 0
			if size == index_size then
				return
			end
			index_size = size
			local index = text and json_codec.decode_json(text) or nil
			emotes:set_emote_word_index(type(index) == "table" and index.words or {})
			pane:render_all()
		end
		load_emote_index()
		host.start_repeating_timer(EMOTE_INDEX_CHECK_SECONDS, load_emote_index)
		if settings.animation == "lua" then
			host.start_repeating_timer(EMOTE_ANIMATION_TICK_SECONDS, function()
				if emotes:advance_emote_animation() then
					pane:render_all()
				end
			end)
		end
	end

	-- Starts the connection process unless a live one is recorded in the status file.
	local function ensure_connection_running()
		local status = json_codec.decode_json(read_file(paths.connection_status_file) or "") or {}
		if status.pid then
			local alive = rex.exec({ "/bin/kill", "-0", tostring(status.pid) })
			if alive and alive.ok then
				return
			end
		end
		local handle, err = rex.exec.start(
			{ rex_cli, "do", "--all", repo_root .. "/rex/chat_connection.lua", "rex=" .. rex_cli },
			{ detach = true, stdout = false, stderr = false }
		)
		if not handle then
			host.log("error", "could not start the chat connection: " .. tostring(err))
		end
	end
	ensure_connection_running()
	host.start_repeating_timer(CONNECTION_CHECK_SECONDS, ensure_connection_running)

	-- Sending needs to know who the token belongs to.
	local function set_up_sending()
		local token, read_err = twitch_auth.read_twitch_token_file(paths.token_file)
		if not token then
			sending_problem = read_err
			return
		end
		local distilled_host = require("distilled.host.rex")()
		local identity, validate_err = twitch_auth.validate_twitch_token(distilled_host.transport, token)
		if not identity then
			sending_problem = validate_err.message
			return
		end
		local helix = require("twitch").new({
			host = distilled_host,
			access_token = token,
			client_id = identity.client_id,
			retry = "none",
			deadline_s = 10,
		})
		local channel_login = (settings.channel or identity.login):lower()
		local broadcaster_user_id = identity.user_id
		if channel_login ~= identity.login then
			local users = helix:get_users({ login = { channel_login } })
			local user = users and users.data and users.data[1]
			if not user then
				sending_problem = "Twitch channel not found: " .. channel_login
				return
			end
			broadcaster_user_id = user.id
		end
		commands = chat_commands.new_chat_commands({
			helix = helix,
			broadcaster_user_id = broadcaster_user_id,
			user_id = identity.user_id,
		})
		pane.channel = channel_login
		pane.own_login = identity.login
		pane:render_all()
	end
	host.start_timer(0, set_up_sending)
end

M.TERMINAL_CREATOR = TERMINAL_CREATOR

return M
