-- Tiny test helper that runs the same under lua, luajit and Rex (rex do spec/run_specs.lua).
--
--   local t = require("spec_helper")
--   t.test("name", function() t.equal(got, want) end)

local compat = require("distilled.compat")

local t = { passed = 0, failed = 0, failures = {} }

local function describe_value(value, depth)
	depth = depth or 0
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) ~= "table" or depth > 4 then
		return tostring(value)
	end
	local keys = {}
	for key in pairs(value) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, key in ipairs(keys) do
		parts[#parts + 1] = tostring(key) .. "=" .. describe_value(value[key], depth + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function deep_equal(a, b)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in pairs(a) do
		if not deep_equal(value, b[key]) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

function t.equal(got, want, label)
	if not deep_equal(got, want) then
		error((label and (label .. ": ") or "") .. "expected " .. describe_value(want) .. ", got " .. describe_value(got), 0)
	end
end

function t.truthy(value, label)
	if not value then
		error((label or "value") .. " should be truthy, got " .. describe_value(value), 0)
	end
end

function t.test(name, fn)
	local ok, err = compat.pcall(fn)
	if ok then
		t.passed = t.passed + 1
	else
		t.failed = t.failed + 1
		t.failures[#t.failures + 1] = name .. ": " .. tostring(err)
	end
end

t.describe_value = describe_value

--- Makes directories for a spec (pure Lua cannot). Works under lua, luajit and Rex.
function t.make_directories(...)
	local paths = { ... }
	if rawget(_G, "rex") then
		local argv = { "/bin/mkdir", "-p" }
		for _, path in ipairs(paths) do
			argv[#argv + 1] = path
		end
		rex.exec(argv)
	else
		for _, path in ipairs(paths) do
			os.execute('mkdir -p "' .. path .. '"')
		end
	end
end

--- A fresh empty directory under the system temp folder.
function t.temporary_directory()
	local path = os.tmpname()
	os.remove(path)
	t.make_directories(path)
	return path
end

return t
