local t = require("spec_helper")

-- The newest rockspecs/twitch-lua-*.rockspec must list every module under lua/twitch/ (and
-- nothing else), or the rock would install without it. Needs io.popen to list files, so
-- it runs under lua and luajit; Rex cannot list a directory.
local function rockspec_modules(path)
	local env = {}
	local chunk
	if rawget(_G, "setfenv") then
		chunk = assert(loadfile(path))
		setfenv(chunk, env)
	else
		chunk = assert(loadfile(path, "t", env))
	end
	chunk()
	return env
end

local function lines_of(command)
	local pipe = io.popen(command)
	local lines = {}
	for line in pipe:lines() do
		lines[#lines + 1] = line
	end
	pipe:close()
	return lines
end

local can_list = not rawget(_G, "rex") and type(io.popen) == "function"

t.test("rockspec: the newest rockspec lists every module under lua/twitch, and the scripts", function()
	if not can_list then
		return
	end
	local root = SPEC_ROOT
	local specs = lines_of("ls " .. root .. "/rockspecs/twitch-lua-*.rockspec | sort -V | tail -1")
	t.truthy(specs[1], "a rockspec in rockspecs/ (scripts/write_rockspec.sh)")
	local spec = rockspec_modules(specs[1])
	local want = {}
	for _, file in ipairs(lines_of("cd " .. root .. " && find lua/twitch -type f -name '*.lua' ! -name '*_spec.lua' | sort")) do
		local module = file:gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")
		want[module] = file
	end
	t.equal(spec.build.modules, want, "run scripts/write_rockspec.sh <version> after adding or removing a module")
	t.truthy(spec.build.modules["twitch.rex.scripts.chat_pane"])
	t.equal(spec.package, "twitch-lua")
	local depends = table.concat(spec.dependencies, " ")
	t.truthy(depends:find("distilled-twitch", 1, true))
end)
