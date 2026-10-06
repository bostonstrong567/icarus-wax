-- Measures what the old bridge did every frame, without leaving anything running: 20 heartbeat-style writes and 160 idle probes.
local now = Wax.perf.now
local run = Wax.root .. "/run"

local function timed(count, fn)
    local total, worst = 0, 0
    for i = 1, count do
        local started = now()
        fn(i)
        local took = now() - started
        total = total + took
        if took > worst then worst = took end
    end
    return { avg_ms = total / count * 1000, worst_ms = worst * 1000, total_ms = total * 1000 }
end

local heartbeat = timed(20, function(i)
    local path = run .. "/probe.json"
    local f = io.open(path .. ".part", "wb")
    f:write('{"time":1,"frame":' .. i .. ',"lua":"Lua 5.4","thread":"game"}')
    f:close()
    os.remove(path)
    os.rename(path .. ".part", path)
end)
os.remove(run .. "/probe.json")

local probe = timed(160, function(i)
    local f = io.open(run .. "/in/" .. (i % 8) .. ".lua", "rb")
    if f then f:close() end
end)

return { heartbeat_write = heartbeat, failed_open = probe, map = Wax.game.MapName }
