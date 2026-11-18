local tty, png = rex.args.tty, rex.args.png
local ESC = string.char(27)
local b64 = rex.exec({ "/bin/sh", "-c", 'printf %s "$0" | /usr/bin/base64', png }).stdout:gsub("%s", "")
local reply = ""
rex.exec.start({ "/bin/sh", "-c", 'stty raw -echo <"$0"; exec cat <"$0"', tty }, { stdout = function(data) reply = reply .. data end })
rex.after(0.3, function()
  io.write(ESC .. "_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA" .. ESC .. "\\")             -- twt's probe: 1 RGB pixel
  io.write(ESC .. "_Gi=32,a=q,f=100,t=f;" .. b64 .. ESC .. "\\")                  -- PNG from a file path
  io.write(ESC .. "_Gi=33,a=q,f=100,t=f;" .. "L25vcGUucG5n" .. ESC .. "\\")       -- /nope.png (should fail)
  io.flush()
end)
rex.after(1.2, function()
  local shown = reply:gsub(ESC, "<ESC>")
  local f = io.open(rex.args.out, "w"); f:write(shown); f:close()
  rex.exec({ "/bin/sh", "-c", 'stty sane <"$0"', tty })
  rex.stop(0)
end)
