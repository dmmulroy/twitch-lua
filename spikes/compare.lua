package.path = arg[1] .. "/?.lua;" .. package.path
local gif = require("gif")
local total, bad_files = 0, 0
local stats = { frames = 0, interlaced = 0, max_frames = 0, seconds = 0 }
for i = 2, #arg do
  local path = arg[i]
  local f = assert(io.open(path, "rb")); local bytes = f:read("*a"); f:close()
  local t0 = os.clock()
  local image, err = gif.decode(bytes)
  stats.seconds = stats.seconds + (os.clock() - t0)
  total = total + 1
  local name = path:match("[^/]+$")
  if not image then
    bad_files = bad_files + 1
    print("FAIL decode", name, err)
  else
    local r = io.open(arg[1] .. "/ref/" .. name .. ".raw", "rb")
    local ref = r and r:read("*a") or ""; if r then r:close() end
    local frame_bytes = image.width * image.height * 4
    local ref_frames = #ref / frame_bytes
    local mismatched_pixels, compared = 0, 0
    for k, frame in ipairs(image.frames) do
      local expect = ref:sub((k - 1) * frame_bytes + 1, k * frame_bytes)
      if #expect == frame_bytes and expect ~= frame.rgba then
        for p = 1, frame_bytes, 4 do
          local r1, g1, b1, a1 = frame.rgba:byte(p, p + 3)
          local r2, g2, b2, a2 = expect:byte(p, p + 3)
          if not ((a1 == 0 and a2 == 0) or (r1 == r2 and g1 == g2 and b1 == b2 and a1 == a2)) then
            mismatched_pixels = mismatched_pixels + 1
          end
        end
      end
      compared = compared + 1
    end
    stats.frames = stats.frames + #image.frames
    if #image.frames > stats.max_frames then stats.max_frames = #image.frames end
    if ref_frames ~= #image.frames or mismatched_pixels > 0 then
      bad_files = bad_files + 1
      print("MISMATCH", name, image.width .. "x" .. image.height, "frames lua=" .. #image.frames .. " ffmpeg=" .. ref_frames, "bad pixels=" .. mismatched_pixels)
    end
  end
end
print(string.format("%d files, %d frames (largest file %d frames), %d files differ from ffmpeg, decode time %.2fs", total, stats.frames, stats.max_frames, bad_files, stats.seconds))
