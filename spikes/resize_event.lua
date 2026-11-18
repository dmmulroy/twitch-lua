local tty = rex.args.tty
local function size() return (rex.exec({ "/bin/sh", "-c", 'stty size <"$0"', tty }).stdout:gsub("\n", "")) end
print("start block=" .. tostring(rex.block_id):sub(-6) .. " stty=" .. size())
rex.on("block_event", function(ctx, ev)
  if ev.block_id ~= rex.block_id then return end
  local p = ev.payload or {}
  print("event " .. tostring(ev.name) .. " cols=" .. tostring(p.columns) .. " rows=" .. tostring(p.rows) .. " owner=" .. tostring(p.owner and "yes") .. " stty=" .. size())
end)
