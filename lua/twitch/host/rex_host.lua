-- The Rex side of twitch-lua: timers, helper processes, a TLS byte stream and logging, built
-- on Rex's Lua API (rex.exec.start, rex.after, rex.every). Only works inside `rex do`.
--
--   local host = require("twitch.host.rex_host").new_rex_host({ log_path = paths.diagnostics_log })
--   host.start_timer(1.5, fn)                          -- one-shot; timer:cancel()
--   host.open_stream("eventsub.wss.twitch.tv", 443, { on_bytes = fn, on_closed = fn })
--   host.start_helper({ "/usr/bin/tail", "-F", path }, { on_output = fn, ends_with_owner = true })
--
-- Rules this file exists to enforce (all measured in Rex):
-- * An error inside an output callback is swallowed and stops that command's output for
--   good, so every callback goes through host.guard, which logs the error instead.
-- * A command started from a timer or handler must be detached to outlive it, and a
--   detached command outlives the script. So every helper is detached and is made to end
--   when this script ends: it either reads stdin itself (and stops at end of input) or is
--   wrapped in ENDS_WITH_OWNER_SCRIPT, which watches the stdin pipe for it.
-- * rex.exec.start has no exit callback, so one timer polls the helpers.

local compat = require("distilled.compat")
local json_codec = require("twitch.json_codec")

local M = {}

local HELPER_POLL_SECONDS = 1
local MAX_LOG_BYTES = 1024 * 1024
local STDERR_TAIL_BYTES = 600

-- Runs "$@" with no stdin of its own and ends it when our stdin closes, which happens when
-- the script that started us exits or is killed. Exits with the command's status.
local ENDS_WITH_OWNER_SCRIPT = [[
"$@" </dev/null & child=$!
( cat >/dev/null; kill "$child" 2>/dev/null ) <&0 >/dev/null 2>&1 & watcher=$!
wait "$child"; status=$?
kill "$watcher" 2>/dev/null
exit "$status"
]]

-- OpenSSL's s_client must be able to check the certificate against the hostname
-- (-verify_hostname). macOS's /usr/bin/openssl is LibreSSL, which cannot, so it is skipped.
local OPENSSL_CANDIDATES = { "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl", "/usr/bin/openssl", "openssl" }

--- Finds an OpenSSL (1.1 or newer, not LibreSSL) whose s_client verifies hostnames.
--- Returns its path, or nil and a message. `exec` is rex.exec.
function M.find_verifying_openssl(exec, override)
	local candidates = OPENSSL_CANDIDATES
	if override and override ~= "" then
		candidates = { override }
	end
	for _, path in ipairs(candidates) do
		local result = exec({ path, "version" }, { timeout = 5 })
		if result and result.ok then
			local major, minor = result.stdout:match("^OpenSSL (%d+)%.(%d+)")
			if major and (tonumber(major) > 1 or (tonumber(major) == 1 and tonumber(minor) >= 1)) then
				return path
			end
		end
	end
	return nil,
		"rex_host: no OpenSSL that can verify hostnames was found (macOS's own openssl is LibreSSL and cannot). Install one: brew install openssl"
end

--- Creates the host. `opts.log_path` receives errors and warnings; `opts.openssl` overrides
--- the OpenSSL binary.
function M.new_rex_host(opts)
	opts = opts or {}
	if rawget(_G, "rex") == nil then
		error("rex_host: this module only works inside Rex (rex do)", 0)
	end

	local host = {}
	math.randomseed(os.time() + math.floor(os.clock() * 1000000) % 1000000)

	-- os.clock is wall time in Rex's Lua, in fractional seconds.
	host.now_seconds = os.clock
	host.epoch_seconds = os.time
	host.exec = rex.exec
	function host.random_byte()
		return math.random(0, 255)
	end

	--- Appends a line to the diagnostics log. Never raises.
	function host.log(level, message)
		if not opts.log_path then
			return
		end
		local file = io.open(opts.log_path, "a")
		if not file then
			return
		end
		if file:seek("end") > MAX_LOG_BYTES then
			file:close()
			file = io.open(opts.log_path, "w") -- start over; the log is for recent problems
			if not file then
				return
			end
		end
		file:write(os.date("%Y-%m-%d %H:%M:%S"), " ", level, " ", (opts.log_label or "twitch-lua"), ": ", tostring(message), "\n")
		file:close()
	end

	--- Wraps a callback so that an error in it is logged instead of lost.
	function host.guard(label, fn)
		return function(...)
			local ok, err = compat.pcall(fn, ...)
			if not ok then
				host.log("error", label .. " failed: " .. tostring(err))
			end
		end
	end

	function host.start_timer(seconds, fn)
		return rex.after(seconds, host.guard("timer", fn))
	end

	function host.start_repeating_timer(seconds, fn)
		return rex.every(seconds, host.guard("repeating timer", fn))
	end

	local helpers = {}
	local helper_poll_timer

	local function poll_helpers()
		for index = #helpers, 1, -1 do
			local helper = helpers[index]
			if not helper.handle:running() then
				table.remove(helpers, index)
				helper.finished = true
				helper.handle:close_stdin() -- lets the wrapper's stdin watcher go too
				local result = helper.handle:wait(0.2)
				if helper.on_exit and not helper.stopped_by_us then
					helper.on_exit(result or {}, helper.stderr_tail)
				end
			end
		end
	end

	--- Starts a long-running command. `helper_opts`:
	---   on_output = fn(bytes)          stdout as it arrives (a piece may end mid-line)
	---   on_exit = fn(result, stderr)   called once after it exits by itself
	---   ends_with_owner = true         for a command that does not read stdin
	--- Returns a helper with :write(bytes), :stop() and .finished, or nil and a message.
	function host.start_helper(argv, helper_opts)
		helper_opts = helper_opts or {}
		local command = argv
		if helper_opts.ends_with_owner then
			command = { "/bin/sh", "-c", ENDS_WITH_OWNER_SCRIPT, "sh" }
			for _, word in ipairs(argv) do
				command[#command + 1] = word
			end
		end
		local helper = { stderr_tail = "", finished = false, stopped_by_us = false, on_exit = helper_opts.on_exit }
		local handle, err = rex.exec.start(command, {
			stdin = true,
			detach = true,
			stdout = helper_opts.on_output and host.guard("helper output", helper_opts.on_output) or false,
			stderr = function(data)
				helper.stderr_tail = (helper.stderr_tail .. data):sub(-STDERR_TAIL_BYTES)
			end,
		})
		if not handle then
			return nil, "rex_host: could not start " .. tostring(argv[1]) .. ": " .. tostring(err)
		end
		helper.handle = handle
		function helper:write(bytes)
			return handle:write(bytes)
		end
		function helper:stop()
			if not self.finished then
				self.stopped_by_us = true
				handle:close_stdin()
				handle:kill()
			end
		end
		helpers[#helpers + 1] = helper
		if not helper_poll_timer then
			helper_poll_timer = rex.every(HELPER_POLL_SECONDS, host.guard("helper poll", poll_helpers))
		end
		return helper
	end

	local openssl_path, openssl_error
	--- Opens a TLS connection with certificate and hostname verification, as a byte stream.
	--- handlers: on_bytes(bytes), on_closed(reason). Returns a stream with :write and :close.
	function host.open_stream(hostname, port, handlers)
		if not openssl_path and not openssl_error then
			openssl_path, openssl_error = M.find_verifying_openssl(rex.exec, opts.openssl)
		end
		if not openssl_path then
			return nil, openssl_error
		end
		-- -quiet turns on "ignore end of input"; -no_ign_eof turns it back off, so openssl
		-- exits when this script goes away.
		local helper, err = host.start_helper({
			openssl_path, "s_client", "-quiet", "-no_ign_eof",
			"-verify_return_error", "-verify_hostname", hostname,
			"-connect", hostname .. ":" .. tostring(port), "-servername", hostname,
		}, {
			on_output = handlers.on_bytes,
			on_exit = function(result, stderr)
				local detail = stderr:match("verify error:[^\r\n]*") or stderr:match("([^\r\n]+)[\r\n]*$") or ""
				handlers.on_closed("TLS helper exited with status " .. tostring(result.code) .. (detail ~= "" and (": " .. detail) or ""))
			end,
		})
		if not helper then
			return nil, err
		end
		local stream = {}
		function stream:write(bytes)
			local ok, write_err = helper:write(bytes)
			if not ok then
				host.log("warn", "TLS stream write failed: " .. tostring(write_err))
			end
			return ok, write_err
		end
		function stream:close()
			helper:stop()
		end
		return stream
	end

	--- This script's process id, for lock files and the pane registry. Nil if it cannot be read.
	function host.own_process_id()
		local result = rex.exec({ "/bin/sh", "-c", "echo $PPID" })
		local pid = result and result.stdout and result.stdout:match("%d+")
		return pid
	end

	-- Rex's native JSON is far faster than the pure-Lua codec, and it drops nulls too.
	json_codec.use_json_backend(function(text)
		local value, err = rex.json.decode(text)
		if value == nil then
			return nil, err or "json_codec: not JSON"
		end
		return value
	end, function(value)
		return rex.json.encode(value)
	end)

	return host
end

M.ENDS_WITH_OWNER_SCRIPT = ENDS_WITH_OWNER_SCRIPT

return M
