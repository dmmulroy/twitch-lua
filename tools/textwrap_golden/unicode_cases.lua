package.path = "lua/?.lua;vendor/?.lua;vendor/?/init.lua;" .. package.path
local terminal_text = require("twitch.terminal_text")
local seed = 777
local function rand(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n end
local blocks = { {0x20,0x7E}, {0x20,0x7E}, {0x20,0x7E}, {0xA0,0x24F}, {0x300,0x36F}, {0x370,0x3FF}, {0x400,0x4FF}, {0x590,0x6FF},
  {0x900,0x97F}, {0xE00,0xE7F}, {0x1100,0x11FF}, {0x2000,0x206F}, {0x2190,0x23FF}, {0x2500,0x27BF}, {0x3000,0x30FF}, {0x4E00,0x4FFF},
  {0xAC00,0xACFF}, {0xFE00,0xFE0F}, {0xFF00,0xFFEF}, {0x1F300,0x1F64F}, {0x1F680,0x1F6FF}, {0x1F900,0x1F9FF}, {0x200D,0x200D}, {0x2D,0x2D} }
local out = {}
for case = 1, 1500 do
  local cps = {}
  for _ = 1, 1 + rand(70) do
    local b = blocks[rand(#blocks) + 1]
    local cp = b[1] + rand(b[2] - b[1] + 1)
    if rand(5) == 0 then cp = 32 end
    cps[#cps + 1] = terminal_text.utf8_from_code_point(cp)
  end
  local text = terminal_text.sanitize_chat_text(table.concat(cps))
  local width = 5 + rand(60)
  out[#out + 1] = width .. "\t" .. rand(width + 3) .. "\t" .. text
end
io.write(table.concat(out, "\n"), "\n")
