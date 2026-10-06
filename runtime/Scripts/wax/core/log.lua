-- Logging: levels, per-source channels, a ring buffer the debugger reads, and sinks

local log = {}

local LEVELS = { trace = 1, debug = 2, info = 3, warn = 4, error = 5 }
local LEVEL_NAMES = { "trace", "debug", "info", "warn", "error" }
log.LEVELS = LEVELS

log.capacity = 2000         -- entries kept in memory
log.level = LEVELS.debug    -- entries below this are dropped

local entries = {}          -- ring buffer, 1..capacity
local head = 0              -- index of the newest entry
local total = 0             -- entries ever stored, which is also the id of the newest
local sinks = {}
local clock = os.time

local function emit(entry, repeated)
    for i = 1, #sinks do
        -- A sink must never be able to break logging, or an error inside a sink would log forever.
        pcall(sinks[i], entry, repeated)
    end
end

local function store(level, channel, message)
    local newest = entries[head]
    if newest and newest.message == message and newest.channel == channel and newest.level == level then
        newest.count = newest.count + 1
        newest.time = clock()
        emit(newest, true)
        return newest
    end
    total = total + 1
    head = head % log.capacity + 1
    local entry = { id = total, time = clock(), level = level, channel = channel, message = message, count = 1 }
    entries[head] = entry
    emit(entry, false)
    return entry
end

local function format_message(fmt, ...)
    if select("#", ...) == 0 then return tostring(fmt) end
    local ok, text = pcall(string.format, fmt, ...)
    if ok then return text end
    -- A bad format string must still produce a readable line.
    local parts = { tostring(fmt) }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, " ")
end

function log.write(level, channel, fmt, ...)
    local n = type(level) == "number" and level or LEVELS[level]
    if not n then error("unknown log level: " .. tostring(level), 2) end
    if n < log.level then return nil end
    return store(LEVEL_NAMES[n], channel or "wax", format_message(fmt, ...))
end

local Logger = {}
Logger.__index = Logger
for name in pairs(LEVELS) do
    Logger[name] = function(self, fmt, ...) return log.write(name, self.channel, fmt, ...) end
end

-- A logger bound to one channel (a mod id, or a core subsystem name).
function log.channel(name) return setmetatable({ channel = name }, Logger) end

-- print() for mod code: arguments joined by tabs, logged at info on the mod's channel.
function log.printer(channel)
    return function(...)
        local parts = table.pack(...)
        for i = 1, parts.n do parts[i] = tostring(parts[i]) end
        log.write("info", channel, "%s", table.concat(parts, "\t"))
    end
end

-- sink(entry, repeated): repeated is true when an existing entry's count went up.
function log.add_sink(sink)
    sinks[#sinks + 1] = sink
    return function()
        for i = #sinks, 1, -1 do
            if sinks[i] == sink then table.remove(sinks, i) end
        end
    end
end

-- Entries with id > after_id, oldest first, optionally filtered. filter = { level = "warn", channel = "x", text = "y" }.
function log.since(after_id, filter)
    after_id = after_id or 0
    local min_level = filter and filter.level and LEVELS[filter.level] or 1
    local channel = filter and filter.channel
    local text = filter and filter.text and filter.text:lower()
    local out = {}
    local stored = math.min(total, log.capacity)
    for back = stored - 1, 0, -1 do
        local entry = entries[(head - back - 1) % log.capacity + 1]
        if entry and entry.id > after_id and LEVELS[entry.level] >= min_level
            and (not channel or entry.channel == channel)
            and (not text or entry.message:lower():find(text, 1, true)) then
            out[#out + 1] = entry
        end
    end
    return out
end

function log.newest_id() return total end

function log.clear()
    entries, head = {}, 0
end

function log.set_clock(fn) clock = fn end

return log
