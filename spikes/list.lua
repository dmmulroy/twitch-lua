package.path = arg[1] .. "/?.lua;" .. package.path
local gif = require("gif")
for i = 2, #arg do
  local f = io.open(arg[i], "rb"); local im = gif.decode(f:read("*a")); f:close()
  local total = 0; for _, fr in ipairs(im.frames) do total = total + (fr.delay_cs <= 1 and 10 or fr.delay_cs) end
  print(string.format("%-52s %3dx%-3d %3d frames  loop %.1fs  first delay %dcs", arg[i]:match("[^/]+$"), im.width, im.height, #im.frames, total / 100, im.frames[1].delay_cs))
end
