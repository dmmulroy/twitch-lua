local dir = rex.args.dir
package.path = dir .. "/?.lua;" .. package.path
local gif = require("gif")
local names = {}
local listing = rex.exec({ "/bin/ls", dir .. "/samples" }).stdout
for name in listing:gmatch("[^\n]+") do names[#names + 1] = name end
local total, frames, bad, slowest, slowest_name, slowest_frames = 0, 0, 0, 0, "", 0
local per_frame_ms = {}
for _, name in ipairs(names) do
  local f = io.open(dir .. "/samples/" .. name, "rb"); local bytes = f:read("*a"); f:close()
  local t0 = os.clock()
  local image, err = gif.decode(bytes)
  local dt = os.clock() - t0
  total = total + dt
  if not image then bad = bad + 1; print("FAIL", name, err) else
    frames = frames + #image.frames
    local r = io.open(dir .. "/ref/" .. name .. ".raw", "rb"); local ref = r:read("*a"); r:close()
    local got = {}
    for k, fr in ipairs(image.frames) do got[k] = fr.rgba end
    -- exact byte equality first; fall back to counting only when it differs
    local frame_bytes = image.width * image.height * 4
    for k, fr in ipairs(image.frames) do
      local expect = ref:sub((k - 1) * frame_bytes + 1, k * frame_bytes)
      if expect ~= fr.rgba then
        local diff = 0
        for p = 1, frame_bytes, 4 do
          local r1, g1, b1, a1 = fr.rgba:byte(p, p + 3); local r2, g2, b2, a2 = expect:byte(p, p + 3)
          if not ((a1 == 0 and a2 == 0) or (r1 == r2 and g1 == g2 and b1 == b2 and a1 == a2)) then diff = diff + 1 end
        end
        if diff > 0 then bad = bad + 1; print("MISMATCH", name, "frame " .. k, diff); break end
      end
    end
    if dt > slowest then slowest, slowest_name, slowest_frames = dt, name .. " " .. image.width .. "x" .. image.height, #image.frames end
  end
end
print(string.format("rex (gopher-lua): %d files, %d frames, %d bad, decode %.2fs total, %.1f ms/frame avg", #names, frames, bad, total, total / frames * 1000))
print(string.format("slowest: %s, %d frames, %.2fs", slowest_name, slowest_frames, slowest))
