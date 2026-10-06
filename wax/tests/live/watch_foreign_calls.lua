-- Development aid: records which hooked receiver function is being called by something other than Wax, and when.
-- Send once to start; send again to read what was seen.
local handlers = Wax.gui_event_handlers
local seen = rawget(_G, "WaxForeignWatch")
if not seen or seen.handlers ~= handlers then
    seen = { handlers = handlers, by_hook = {}, total = 0, started = os.time(), first = nil, last = nil, bursts = {} }
    WaxForeignWatch = seen
    setmetatable(handlers, { __index = function(_, address)
        local info = debug.getinfo(2, "f")
        local id = "?"
        if info and info.func then
            for index = 1, 8 do
                local name, value = debug.getupvalue(info.func, index)
                if not name then break end
                if name == "decode" then id = tostring(value) end
            end
        end
        seen.by_hook[id] = (seen.by_hook[id] or 0) + 1
        seen.total = seen.total + 1
        local now = os.time()
        seen.first = seen.first or now
        if seen.last ~= now then seen.bursts[#seen.bursts + 1] = { at = now - seen.started, count = 0 } end
        seen.bursts[#seen.bursts].count = seen.bursts[#seen.bursts].count + 1
        seen.last = now
        return nil
    end })
    return { started = true, foreign_so_far = WaxGuiHookCalls.foreign }
end
local bursts = {}
for index = math.max(1, #seen.bursts - 11), #seen.bursts do bursts[#bursts + 1] = seen.bursts[index] end
return { watching_seconds = os.time() - seen.started, total = seen.total, by_hook = seen.by_hook, recent_bursts = bursts,
    counters = WaxGuiHookCalls, map = Wax.game.MapName }
