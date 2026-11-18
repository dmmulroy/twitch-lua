-- What does Rex's terminal accept for raw RGBA frames, placeholders and animation?
local dir, tty = rex.args.dir, rex.args.tty
package.path = dir .. "/?.lua;" .. package.path
local gif = require("gif")
local ESC = string.char(27)
local function b64(s) return (rex.exec({ "/usr/bin/base64" }, { stdin = s }).stdout:gsub("%s", "")) end
local function write_file(path, data) local f = assert(io.open(path, "wb")); f:write(data); f:close() end

local f = assert(io.open(dir .. "/samples/" .. rex.args.sample, "rb")); local image = assert(gif.decode(f:read("*a"))); f:close()
local W, H, frame_bytes = image.width, image.height, image.width * image.height * 4
local all = {}
for k, frame in ipairs(image.frames) do all[k] = frame.rgba end
local f1, f2, strip, short = dir .. "/cache/f1.rgba", dir .. "/cache/f2.rgba", dir .. "/cache/all.rgba", dir .. "/cache/short.rgba"
write_file(f1, all[1]); write_file(f2, all[2]); write_file(strip, table.concat(all)); write_file(short, all[1]:sub(1, 100))

local size = string.format("s=%d,v=%d", W, H)
local tests = {
  { "1 transmit RGBA from file          ", "a=t,t=f,f=32," .. size .. ",i=101", f1 },
  { "2 frame 2 via offset in one file   ", "a=t,t=f,f=32," .. size .. ",i=102,S=" .. frame_bytes .. ",O=" .. frame_bytes, strip },
  { "3 virtual placement (placeholder)  ", "a=p,U=1,i=101,c=2,r=1", "" },
  { "4 second virtual placement, id 102 ", "a=p,U=1,i=102,c=2,r=1", "" },
  { "5 file too short                   ", "a=t,t=f,f=32," .. size .. ",i=103", short },
  { "6 replace image 101 with frame 2   ", "a=t,t=f,f=32," .. size .. ",i=101", f2 },
  { "7 animation: add frame (a=f)       ", "a=f,t=f,f=32," .. size .. ",i=102,z=100", f2 },
  { "8 animation: start (a=a)           ", "a=a,i=102,s=3,v=1", "" },
  { "9 delete image 102                 ", "a=d,d=I,i=102", "" },
  { "10 place deleted image 102         ", "a=p,U=1,i=102,c=2,r=1", "" },
  { "11 direct data, 1 RGBA pixel       ", "a=t,t=d,f=32,s=1,v=1,i=104", nil },
}
local replies, current = {}, 0
rex.exec.start({ "/bin/sh", "-c", 'stty raw -echo <"$0"; exec cat <"$0"', tty }, { detach = true, stdout = function(data)
  replies[current] = (replies[current] or "") .. data
end })
local step = 0
local timer
timer = rex.every(0.25, function()
  step = step + 1
  local t = tests[step]
  if not t then
    timer:cancel()
    local out = { string.format("sample %s: %dx%d, %d frames, %d bytes per frame", rex.args.sample, W, H, #image.frames, frame_bytes) }
    for k, test in ipairs(tests) do
      local r = (replies[k] or ""):gsub(ESC .. "_G", ""):gsub(ESC .. "\\", " "):gsub("%c", "?")
      out[#out + 1] = test[1] .. " -> " .. (r ~= "" and r or "(no reply)")
    end
    write_file(rex.args.out, table.concat(out, "\n") .. "\n")
    rex.exec({ "/bin/sh", "-c", 'stty sane <"$0"; pkill -f "cat <$0" 2>/dev/null; true', tty })
    rex.stop(0)
    return
  end
  current = step
  local payload = t[3] == nil and "AAAA/w==" or (t[3] ~= "" and b64(t[3]) or "")
  io.write(ESC .. "_G" .. t[2] .. ";" .. payload .. ESC .. "\\"); io.flush()
end)
