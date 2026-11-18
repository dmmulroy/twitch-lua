-- Which GIF features do the samples use? (so we know what the comparison covered)
local disposal, interlaced, local_tables, transparent, partial = {}, 0, 0, 0, 0
for i = 1, #arg do
  local f = assert(io.open(arg[i], "rb")); local s = f:read("*a"); f:close()
  local function u16(p) local a, b = s:byte(p, p + 1); return a + b * 256 end
  local W, H = u16(7), u16(9)
  local pos = 14 + ((s:byte(11) >= 128) and 3 * 2 ^ (s:byte(11) % 8 + 1) or 0)
  local function skip(p) while true do local n = s:byte(p); if n == 0 then return p + 1 end; p = p + 1 + n end end
  while true do
    local b = s:byte(pos)
    if b == 0x21 then
      if s:byte(pos + 1) == 0xF9 then
        local fl = s:byte(pos + 3); local d = ((fl - fl % 4) / 4) % 8
        disposal[d] = (disposal[d] or 0) + 1; if fl % 2 == 1 then transparent = transparent + 1 end
        pos = pos + 8
      else pos = skip(pos + 2) end
    elseif b == 0x2C then
      local fl = s:byte(pos + 9)
      if u16(pos + 5) ~= W or u16(pos + 7) ~= H then partial = partial + 1 end
      if fl % 128 >= 64 then interlaced = interlaced + 1 end
      pos = pos + 10
      if fl >= 128 then local_tables = local_tables + 1; pos = pos + 3 * 2 ^ (fl % 8 + 1) end
      pos = skip(pos + 1)
    else break end
  end
end
local d = {}; for k, v in pairs(disposal) do d[#d + 1] = "disposal " .. k .. ": " .. v end; table.sort(d)
print(table.concat(d, ", ")); print("frames with transparency: " .. transparent .. ", smaller than canvas: " .. partial .. ", local color table: " .. local_tables .. ", interlaced: " .. interlaced)
