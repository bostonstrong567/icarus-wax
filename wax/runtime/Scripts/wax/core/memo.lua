-- Small caches for hot paths: one that forgets everything when the frame changes, one that forgets an entry after a
-- time. A hook that the game calls hundreds of times a frame answers the same question from here after the first.

local Wax = ...
local sched = Wax.import("core.sched")

local M = {}

local function clock() return os.clock() end

-- A cache that holds its entries for the rest of the current frame. get(key) answers the value or nil, set(key, value)
-- keeps one (false is kept as a value too), has(key) tells whether one is there. Keys are any Lua value.
local Frame = {}
Frame.__index = Frame

local function current_frame()
    local stats = sched.stats
    return stats and stats.frame or 0
end

local function fresh(self)
    local frame = current_frame()
    if frame ~= self.frame then
        self.frame = frame
        self.entries = {}
        self.count = 0
    end
end

function Frame:get(key)
    fresh(self)
    local value = self.entries[key]
    if value == nil then return nil end
    self.hits = self.hits + 1
    return value
end

function Frame:has(key)
    fresh(self)
    return self.entries[key] ~= nil
end

function Frame:set(key, value)
    fresh(self)
    if self.entries[key] == nil then self.count = self.count + 1 end
    self.entries[key] = value
    return value
end

-- get(key) or, when nothing is there, set(key, fn(...)).
function Frame:take(key, fn, ...)
    fresh(self)
    local value = self.entries[key]
    if value ~= nil then
        self.hits = self.hits + 1
        return value
    end
    value = fn(...)
    if value == nil then return nil end
    self:set(key, value)
    return value
end

function Frame:clear()
    self.entries, self.count = {}, 0
end

function M.frame()
    return setmetatable({ frame = -1, entries = {}, count = 0, hits = 0 }, Frame)
end

-- A cache whose entries last `seconds` from when they were set. The same get, has, set, take and clear; stale entries
-- are dropped as they are met, and sweep() drops them all.
local Timed = {}
Timed.__index = Timed

function Timed:get(key)
    local entry = self.entries[key]
    if entry == nil then return nil end
    if clock() - entry.at >= self.seconds then
        self.entries[key] = nil
        self.count = self.count - 1
        return nil
    end
    self.hits = self.hits + 1
    return entry.value
end

function Timed:has(key) return self:get(key) ~= nil end

function Timed:set(key, value)
    if self.entries[key] == nil then self.count = self.count + 1 end
    self.entries[key] = { at = clock(), value = value }
    return value
end

function Timed:take(key, fn, ...)
    local value = self:get(key)
    if value ~= nil then return value end
    value = fn(...)
    if value == nil then return nil end
    self:set(key, value)
    return value
end

function Timed:clear()
    self.entries, self.count = {}, 0
end

function Timed:sweep()
    local now = clock()
    for key, entry in pairs(self.entries) do
        if now - entry.at >= self.seconds then
            self.entries[key] = nil
            self.count = self.count - 1
        end
    end
end

function M.timed(seconds)
    if type(seconds) ~= "number" or seconds <= 0 then error("memo.timed expects how many seconds an entry lasts, got " .. tostring(seconds), 2) end
    return setmetatable({ seconds = seconds, entries = {}, count = 0, hits = 0 }, Timed)
end

-- What a mod sees as `memo`.
M.api = { frame = M.frame, timed = M.timed }

return M
