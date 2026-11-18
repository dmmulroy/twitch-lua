-- Prototype: RFC 6455 client in Lua over `openssl s_client`, driven by rex.exec.start.
local HOST = "eventsub.wss.twitch.tv"
local t0 = os.clock()
local function out(s) print(string.format("%5.1fs %s", os.clock() - t0, s)) end
local function bxor(a, b)
  local r, p = 0, 1
  for _ = 1, 8 do
    local x, y = a % 2, b % 2
    if x ~= y then r = r + p end
    a, b, p = (a - x) / 2, (b - y) / 2, p * 2
  end
  return r
end
math.randomseed(os.time())
local h
local function send_frame(opcode, payload)
  local key = { math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
  local bytes = { string.char(0x80 + opcode, 0x80 + #payload, key[1], key[2], key[3], key[4]) }
  for i = 1, #payload do bytes[#bytes + 1] = string.char(bxor(payload:byte(i), key[(i - 1) % 4 + 1])) end
  return h:write(table.concat(bytes))
end
local function subscribe(session_id)
  local body = rex.json.encode({
    type = "channel.chat.message", version = "1",
    condition = { broadcaster_user_id = os.getenv("TW_UID"), user_id = os.getenv("TW_UID") },
    transport = { method = "websocket", session_id = session_id },
  })
  local config = table.concat({
    'url = "https://api.twitch.tv/helix/eventsub/subscriptions"', 'request = "POST"', "silent",
    'header = "Authorization: Bearer ' .. os.getenv("TW_TOKEN") .. '"',
    'header = "Client-Id: ' .. os.getenv("TW_CID") .. '"', 'header = "Content-Type: application/json"',
    "data = " .. string.format("%q", body), 'write-out = "\\nHTTP %{http_code}"',
  }, "\n")

  local r = rex.exec({ "/usr/bin/curl", "--config", "-" }, { stdin = config, timeout = 10 })
  out("subscribe -> " .. (r.stdout:match("HTTP %d+") or "?") .. " " .. (r.stdout:match('"status":"[^"]+"') or r.stdout:sub(1, 200)))
end
local buf, state, pieces = "", "handshake", 0
local function on_frame(fin, op, payload)
  if op == 1 then
    local msg = rex.json.decode(payload)
    local kind = msg and msg.metadata and msg.metadata.message_type
    out("text frame fin=" .. tostring(fin) .. " " .. #payload .. "B type=" .. tostring(kind)
      .. ((kind == "notification") and (" " .. msg.metadata.subscription_type .. " from " .. tostring(msg.payload.event.chatter_user_login)) or ""))
    if kind == "session_welcome" then
      out("  keepalive_timeout_seconds=" .. tostring(msg.payload.session.keepalive_timeout_seconds))
      if os.getenv("TW_TOKEN") then subscribe(msg.payload.session.id) end
    end
  elseif op == 9 then
    out("PING (" .. #payload .. "B) -> pong sent: " .. tostring(send_frame(10, payload)))
  elseif op == 8 then
    local a, b = payload:byte(1, 2)
    out("CLOSE code=" .. tostring(a and (a * 256 + b)) .. " reason=" .. payload:sub(3))
    rex.stop(0)
  else
    out("frame op=" .. op .. " len=" .. #payload)
  end
end
local function pump()
  if state == "handshake" then
    local e = buf:find("\r\n\r\n", 1, true)
    if not e then return end
    out("handshake: " .. buf:match("^[^\r]*"))
    buf, state = buf:sub(e + 4), "open"
  end
  while #buf >= 2 do
    local b1, b2 = buf:byte(1, 2)
    local len, pos = b2 % 128, 3
    if len == 126 then
      if #buf < 4 then return end
      local a, b = buf:byte(3, 4); len, pos = a * 256 + b, 5
    elseif len == 127 then
      if #buf < 10 then return end
      len = 0; for i = 3, 10 do len = len * 256 + buf:byte(i) end; pos = 11
    end
    if #buf < pos - 1 + len then return end
    local payload = buf:sub(pos, pos + len - 1)
    buf = buf:sub(pos + len)
    on_frame(b1 >= 128, b1 % 16, payload)
  end
end
local owner_pid = rex.exec({ "/bin/sh", "-c", "echo $PPID" }).stdout:match("%d+")
-- The helper ends when it exits, or within 2s of the script that owns it going away.
local GUARD = [[/usr/bin/openssl s_client -quiet -connect "$1:443" -servername "$1" <&0 & helper=$!
trap 'kill $helper 2>/dev/null' EXIT TERM INT
while kill -0 "$2" 2>/dev/null && kill -0 $helper 2>/dev/null; do sleep 2; done]]
h = assert(rex.exec.start({ "/bin/sh", "-c", GUARD, "sh", HOST, owner_pid }, {
  stdin = true, detach = true,
  stdout = function(data)
    pieces = pieces + 1; buf = buf .. data
    local ok, err = pcall(pump)
    if not ok then out("CALLBACK ERROR: " .. tostring(err)) end
  end,
  stderr = function() end,
}))
out("write handshake: " .. tostring(h:write("GET /ws HTTP/1.1\r\nHost: " .. HOST
  .. "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")))
rex.after(tonumber(rex.args.secs or 14), function() out("done; stdout pieces=" .. pieces .. " running=" .. tostring(h:running())); rex.stop(0) end)
