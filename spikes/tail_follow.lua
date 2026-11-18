local log = rex.args.log
local got, partial = {}, ""
local h = rex.exec.start({ "/usr/bin/tail", "-n", "+1", "-F", log }, {
  stdout = function(data)
    partial = partial .. data
    for line in partial:gmatch("([^\n]*)\n") do got[#got + 1] = line end
    partial = partial:match("([^\n]*)$")
  end,
  stderr = function(data) got[#got + 1] = "[stderr " .. data:gsub("\n", "") .. "]" end,
})
local function append(s) local f = io.open(log, "a"); f:write(s); f:close() end
rex.after(0.5, function() append("seq3\nseq4-part") end)
rex.after(1.0, function() append("ial\n") end)
rex.after(1.5, function() -- compaction: write a new file, rename over the old one
  local f = io.open(log .. ".new", "w"); f:write("seq3\nseq4-partial\n"); f:close()
  os.rename(log .. ".new", log)
end)
rex.after(3.0, function() append("seq5\n") end)
rex.after(4.5, function() print(table.concat(got, " | ")); h:kill(); rex.stop(0) end)
