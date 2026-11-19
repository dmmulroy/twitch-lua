local t = require("spec_helper")
local palette_actions = require("twitch.rex.palette_actions")

-- A session whose commands record calls; `opts.current_title` is what Twitch has now
-- (nil: reading it fails), `opts.set_result` what setting it returns.
local function fake_session(opts)
	local calls = {}
	local commands = {
		get_stream_title = function()
			calls[#calls + 1] = { "get_stream_title" }
			if opts.current_title == nil then
				return nil, "unreachable"
			end
			return opts.current_title
		end,
		set_stream_title = function(_, title)
			calls[#calls + 1] = { "set_stream_title", title }
			return opts.set_result or { level = "info", text = "Title set to: " .. title }
		end,
	}
	return { commands = commands, channel_login = "dillon" }, calls
end

-- rex.ui.input stand-in: returns `answer` (a list of return values) and records the request.
local function fake_ui(...)
	local answer = { n = select("#", ...), ... }
	local ui = { asked = {} }
	function ui.input(request)
		ui.asked[#ui.asked + 1] = request
		return (table.unpack or unpack)(answer, 1, answer.n)
	end
	return ui
end

local function run(args, session, ui, logs)
	return palette_actions.run_set_stream_title(args, {
		ui = ui,
		log = function(level, text)
			if logs then
				logs[#logs + 1] = { level, text }
			end
		end,
		open_session = function()
			return session
		end,
	})
end

t.test("palette_actions: asks with the current title filled in, then sets the answer", function()
	local session, calls = fake_session({ current_title = "Old title" })
	local ui = fake_ui("New title")
	local outcome = run({}, session, ui)
	t.equal(ui.asked[1], { title = "Stream title for #dillon", placeholder = "What's on stream?", value = "Old title", confirm = "Set title" })
	t.equal(calls, { { "get_stream_title" }, { "set_stream_title", "New title" } })
	t.equal(outcome, { title = "New title", text = "Title set to: New title" })
end)

t.test("palette_actions: title=... asks nothing, also without rex.ui", function()
	local session, calls = fake_session({ current_title = "Old" })
	t.equal(run({ title = "Given" }, session, nil).title, "Given")
	t.equal(calls, { { "set_stream_title", "Given" } })
end)

t.test("palette_actions: cancelling, an unchanged answer and an unreadable title", function()
	local session, calls = fake_session({ current_title = "Same" })
	t.equal(run({}, session, fake_ui(nil, "cancelled")), { cancelled = true })
	t.equal(run({}, session, fake_ui("Same")), { title = "Same", text = "Title unchanged: Same" })
	t.equal(#calls, 2) -- two reads, no set
	local unreadable = fake_session({ current_title = nil })
	local logs = {}
	local ui = fake_ui("Fresh")
	t.equal(run({}, unreadable, ui, logs).title, "Fresh")
	t.equal(ui.asked[1].value, "")
	t.equal(logs[1][1], "warn")
end)

t.test("palette_actions: problems come back as sentences", function()
	local _, no_session = palette_actions.run_set_stream_title({}, {
		open_session = function()
			return nil, "Twitch token is invalid or expired"
		end,
	})
	t.equal(no_session, "Title not changed: Twitch token is invalid or expired")
	local session = fake_session({ current_title = "x" })
	t.equal({ run({}, session, nil) }, { nil, palette_actions.NO_PROMPTS_PROBLEM })
	t.equal({ run({}, session, {}) }, { nil, palette_actions.NO_PROMPTS_PROBLEM })
	t.equal({ run({}, session, fake_ui(nil, "no_client")) }, { nil, "Title not changed: no answer (no_client)" })
	t.equal({ run({}, session, fake_ui(nil, "failed", "boom")) }, { nil, "Title not changed: no answer (failed: boom)" })
	local refused = fake_session({ current_title = "x", set_result = { level = "error", text = "Title not changed: forbidden" } })
	t.equal({ run({ title = "y" }, refused, nil) }, { nil, "Title not changed: forbidden" })
end)

t.test("palette_actions: rex_can_prompt looks for rex.ui.input", function()
	t.equal(palette_actions.rex_can_prompt({ ui = { input = function() end } }), true)
	t.equal(palette_actions.rex_can_prompt({}), false)
	t.equal(palette_actions.rex_can_prompt({ ui = {} }), false)
	t.equal(palette_actions.rex_can_prompt(nil), false)
end)

-- A `rex` stand-in that records rex.action definitions.
local function fake_rex(with_ui)
	local api = { defined = {}, log = function() end }
	function api.action(definition)
		api.defined[#api.defined + 1] = definition
	end
	if with_ui then
		api.ui = { input = function() end }
	end
	return api
end

t.test("palette_actions: registered with the prompt only when the server can prompt", function()
	local new_server = fake_rex(true)
	t.equal(palette_actions.register_twitch_palette_actions({ rex_api = new_server }), { can_prompt = true })
	t.equal(new_server.defined[1].name, "twitch_set_title")
	t.equal(new_server.defined[1].title, "Twitch: Set Stream Title…")
	t.equal(new_server.defined[1].args, { title = "string?" })

	local old_server = fake_rex(false)
	t.equal(palette_actions.register_twitch_palette_actions({ rex_api = old_server }), { can_prompt = false })
	t.equal(old_server.defined[1].title, "Twitch: Set Stream Title (pass title=)")
	t.equal(old_server.defined[1].args, { title = "string" })
	t.truthy(old_server.defined[1].description:find('title="..."', 1, true))
end)
