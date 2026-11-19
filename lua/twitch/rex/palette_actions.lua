-- Rex palette actions for twitch-lua, registered from a Rex configuration file:
--
--   package.path = repo .. "/lua/?.lua;" .. repo .. "/vendor/?.lua;" .. repo .. "/vendor/?/init.lua;" .. package.path
--   require("twitch.rex.palette_actions").register_twitch_palette_actions()
--
-- Actions:
--   twitch_set_title  "Twitch: Set Stream Title…" asks for the title in the command
--                     palette (rex.ui.input), starting from the current one. With
--                     title=... it asks nothing: `rex do twitch_set_title title="Hello"`.
--
-- Rules these follow (https://www.superlogical.com/rex/docs/customize/custom-ui):
-- * rex.ui only works in the action's own call chain, never under pcall, xpcall, a rex.on
--   handler or twitch.host.rex_host's host.guard; so the prompt is asked from run_* here,
--   outside any protected call. (distilled's compat.pcall around each Helix request is
--   fine: no prompt is asked inside a request.)
-- * An action has 30 seconds, not counting the time a prompt is open. Up to three Twitch
--   requests run before the prompt (token check, channel lookup, current title) and one
--   after, so each gets ACTION_REQUEST_DEADLINE_SECONDS.
-- * Servers older than control API revision 17 have no rex.ui. That is checked once, when
--   the configuration loads (rex_can_prompt): on such a server the action is registered
--   without the prompt, takes a required title=..., and never touches rex.ui.

local chat_paths = require("twitch.chat_paths")
local chat_settings = require("twitch.chat_settings")

local M = {}

M.SET_STREAM_TITLE_ACTION = "twitch_set_title"
M.ACTION_REQUEST_DEADLINE_SECONDS = 6

M.NO_PROMPTS_PROBLEM = "This Rex server can't show prompts (rex.ui needs a newer server; restart the Rex server "
	.. "to finish updating it). Meanwhile pass the title: rex do " .. M.SET_STREAM_TITLE_ACTION .. ' title="..."'

--- The set-title flow, without Rex globals. `args.title` skips the prompt. `deps`:
---   open_session: fn() -> session (twitch.channel_session) | nil, problem
---   ui: rex.ui, or nil on servers without prompts
---   log: fn(level, text), optional
--- Returns { title, text } when the title was set or left as it was, { cancelled = true }
--- when the person closed the prompt, or nil and a problem.
function M.run_set_stream_title(args, deps)
	local log = deps.log or function() end
	local session, problem = deps.open_session()
	if not session then
		return nil, "Title not changed: " .. tostring(problem)
	end
	local commands = session.commands
	local title = args and args.title
	if title == nil then
		if type(deps.ui) ~= "table" or type(deps.ui.input) ~= "function" then
			return nil, M.NO_PROMPTS_PROBLEM
		end
		local current_title, read_problem = commands:get_stream_title()
		if not current_title then
			log("warn", "twitch_set_title: could not read the current title: " .. tostring(read_problem))
		end
		local answer, reason, detail = deps.ui.input({
			title = "Stream title for #" .. session.channel_login,
			placeholder = "What's on stream?",
			value = current_title or "",
			confirm = "Set title",
		})
		if answer == nil then
			if reason == "cancelled" then
				return { cancelled = true }
			end
			return nil, "Title not changed: no answer (" .. tostring(reason) .. (detail and (": " .. detail) or "") .. ")"
		end
		if answer == current_title then
			return { title = answer, text = "Title unchanged: " .. answer }
		end
		title = answer
	end
	local result = commands:set_stream_title(title)
	if result.level == "error" then
		return nil, result.text
	end
	return { title = title, text = result.text }
end

--- True when this Rex server can ask questions in the command palette (rex.ui.input;
--- control API revision 17 and later). `rex_api` is the `rex` global.
function M.rex_can_prompt(rex_api)
	return type(rex_api) == "table" and type(rex_api.ui) == "table" and type(rex_api.ui.input) == "function"
end

--- Defines the actions with rex.action. Call from the Rex configuration file.
--- `opts.category` is the palette group (default "Twitch"); `opts.rex_api` replaces the
--- `rex` global (specs). Returns { can_prompt } so the caller can tell which kind it got.
function M.register_twitch_palette_actions(opts)
	opts = opts or {}
	local rex_api = opts.rex_api or rex
	local can_prompt = M.rex_can_prompt(rex_api)
	rex_api.action({
		name = M.SET_STREAM_TITLE_ACTION,
		title = can_prompt and "Twitch: Set Stream Title…" or "Twitch: Set Stream Title (pass title=)",
		description = can_prompt and "Change the stream title, starting from the current one"
			or ("This Rex server can't show prompts; run: rex do " .. M.SET_STREAM_TITLE_ACTION .. ' title="..."'),
		category = opts.category or "Twitch",
		keywords = "twitch stream title rename",
		args = { title = can_prompt and "string?" or "string" },
		run = function(_, args)
			local paths = chat_paths.twitch_chat_paths()
			local settings = chat_settings.read_chat_settings(paths.settings_file)
			local outcome, problem = M.run_set_stream_title(args, {
				ui = can_prompt and rex_api.ui or nil,
				log = rex_api.log,
				open_session = function()
					return require("twitch.channel_session").open_channel_session({
						token_file = paths.token_file,
						channel = settings.channel,
						deadline_s = M.ACTION_REQUEST_DEADLINE_SECONDS,
					})
				end,
			})
			if not outcome then
				error(problem, 0)
			end
			if outcome.cancelled then
				return nil
			end
			rex_api.log("info", outcome.text)
			return { title = outcome.title }
		end,
	})
	return { can_prompt = can_prompt }
end

return M
