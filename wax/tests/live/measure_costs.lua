-- Micro-benchmarks of the things Wax does every frame. Returns microseconds per call.
local now = Wax.perf.now

local function per_call(count, fn)
    local started = now()
    for _ = 1, count do fn() end
    return (now() - started) / count * 1e6
end

local out = {}
out.clock = per_call(20000, now)
out.os_clock = per_call(20000, os.clock)
out.empty_guard_call = per_call(5000, function() Wax.guard.call("bench", function() end) end)

local wake = Wax.root:gsub("/", "\\") .. "\\run\\in\\wake"
out.wake_probe = per_call(300, function()
    local f = io.open(wake, "rb")
    if f then f:close() end
end)

local engine = FindFirstOf("Engine")
out.is_valid = per_call(5000, function() return engine:IsValid() end)
out.property_read = per_call(5000, function() return engine.GameViewport end)
out.get_address = per_call(5000, function() return engine:GetAddress() end)

local game = Wax.game
out.game_step = per_call(2000, Wax.import("engine.game").step)
out.local_player = per_call(2000, function() return game.LocalPlayer end)

local controller = game.LocalPlayer
if controller then
    local raw = controller.Raw
    local key = { KeyName = FName("F8") }
    out.key_check_cached = per_call(2000, function() return raw:WasInputKeyJustPressed(key) end)
    out.key_check_fresh = per_call(2000, function() return raw:WasInputKeyJustPressed({ KeyName = FName("F8") }) end)
    out.controller_class = controller.ClassName
end
out.gui_step = per_call(2000, Wax.ui.step)
out.sched_step = per_call(2000, Wax.sched.step)
return out
