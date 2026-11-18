local t0 = os.clock()
local function out(s) print(string.format("%4.1fs %s", os.clock() - t0, s)) end
local TICKER = { "/bin/sh", "-c", "i=0; while [ $i -lt 40 ]; do i=$((i+1)); echo n$i; sleep 0.25; done" }
local case = rex.args.case
local seen = 0
local h

if case == "error_in_callback" then
  h = rex.exec.start(TICKER, { stdout = function(d)
    seen = seen + 1
    if seen == 2 then error("boom in callback") end
  end })
elseif case == "exec_in_callback" then
  h = rex.exec.start(TICKER, { stdout = function(d)
    seen = seen + 1
    if seen == 2 then
      local ok, r = pcall(rex.exec, { "/bin/echo", "inner" })
      out("inner rex.exec: pcall=" .. tostring(ok) .. " -> " .. tostring(type(r) == "table" and r.stdout or r))
    end
  end })
elseif case == "after_in_callback" then
  h = rex.exec.start(TICKER, { stdout = function(d)
    seen = seen + 1
    if seen == 2 then
      rex.after(0, function()
        local r = rex.exec({ "/bin/echo", "inner" })
        out("timer rex.exec -> " .. tostring(r and r.stdout))
      end)
    end
  end })
elseif case == "start_in_timer" or case == "start_in_timer_detached" then
  rex.after(0.2, function()
    h = rex.exec.start(TICKER, { stdin = true, detach = (case == "start_in_timer_detached") or nil,
      stdout = function(d) seen = seen + 1 end })
    out("started in timer, pid " .. tostring(h and h.pid))
  end)
elseif case == "start_in_callback_detached" then
  rex.exec.start({ "/bin/sh", "-c", "sleep 0.3; echo go" }, { stdout = function()
    h = rex.exec.start(TICKER, { detach = true, stdout = function(d) seen = seen + 1 end })
    out("started in callback, pid " .. tostring(h and h.pid))
  end })
end

rex.after(1.5, function() out("t=1.5 seen=" .. seen .. " running=" .. tostring(h and h:running())) end)
rex.after(3.0, function()
  out("t=3.0 seen=" .. seen .. " running=" .. tostring(h and h:running()))
  if h and h:running() then h:kill() end
  rex.stop(0)
end)
