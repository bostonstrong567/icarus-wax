-- Sent once a second while the game is running: new log lines and the list of mods
local core, after, seen_count, backlog = ...
if not (rawget(_G, "Wax") and Wax.log and Wax.mods) then return { core = false } end

local log = Wax.log
local newest = log.newest_id()
local now = tostring(Wax)
-- a restarted core counts its log from 1 again
if core ~= now or newest < after then after = -1 end
if after < 0 then
    after, seen_count = math.max(0, newest - backlog), math.huge
end

local entries = {}
for _, entry in ipairs(log.since(after - 1)) do
    if entry.id > after or entry.count > seen_count then
        entries[#entries + 1] = {
            id = entry.id, time = entry.time, level = entry.level, channel = entry.channel,
            message = entry.message, count = entry.count, again = entry.id <= after,
        }
    end
end

local mods = {}
for index, mod in ipairs(Wax.mods.list()) do
    local record = Wax.mods.get(mod.id)
    mod.dir = record and record.dir
    mods[index] = mod
end

return { core = now, newest = newest, entries = entries, mods = mods }
