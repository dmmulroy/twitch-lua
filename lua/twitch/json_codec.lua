-- JSON for Twitch payloads and the chat event log: decode drops JSON null, so a missing
-- field and a null field both read as nil.
--
--   local json_codec = require("twitch.json_codec")
--   local value, err = json_codec.decode_json(text)   -- nil, "message" on bad JSON
--   local text = json_codec.encode_json(value)        -- one line, no trailing newline
--
-- The default backend is distilled.json (pure Lua, works everywhere). A host with a
-- native codec can swap it in with use_json_backend; Rex's rex.json drops nulls itself.

local distilled_json = require("distilled.json")

local M = {}

local NULL = distilled_json.null

-- Removes json.null everywhere in a decoded value, without recursion (Rex's Lua has a
-- call stack of about 250 frames). A null inside an array is removed and the array closes up.
local function strip_json_nulls(root)
	if root == NULL then
		return nil
	end
	if type(root) ~= "table" then
		return root
	end
	local stack, depth = { root }, 1
	while depth > 0 do
		local node = stack[depth]
		stack[depth] = nil
		depth = depth - 1
		if distilled_json.is_array(node) then
			local kept = 0
			local count = #node
			for i = 1, count do
				local item = node[i]
				node[i] = nil
				if item ~= NULL and item ~= nil then
					kept = kept + 1
					node[kept] = item
					if type(item) == "table" then
						depth = depth + 1
						stack[depth] = item
					end
				end
			end
		else
			for key, item in pairs(node) do
				if item == NULL then
					node[key] = nil
				elseif type(item) == "table" then
					depth = depth + 1
					stack[depth] = item
				end
			end
		end
	end
	return root
end

local function default_decode(text)
	local value, err = distilled_json.decode(text)
	if value == nil and err ~= nil then
		return nil, tostring(err)
	end
	return strip_json_nulls(value)
end

local function default_encode(value)
	return distilled_json.encode(value)
end

local decode_backend, encode_backend = default_decode, default_encode

--- Decodes JSON text; JSON null becomes nil. Returns nil and a message on bad JSON.
function M.decode_json(text)
	if type(text) ~= "string" or text == "" then
		return nil, "json_codec: empty input"
	end
	return decode_backend(text)
end

--- Encodes a Lua value as one line of JSON.
function M.encode_json(value)
	return encode_backend(value)
end

--- Replaces the JSON backend, e.g. with Rex's native rex.json. Both functions must return
--- nil and a message on failure, and decode must drop nulls.
function M.use_json_backend(decode, encode)
	decode_backend, encode_backend = decode, encode
end

--- Marks a table as a JSON array so that an empty one encodes as [] with the default backend.
function M.json_array(list)
	return distilled_json.array(list)
end

return M
