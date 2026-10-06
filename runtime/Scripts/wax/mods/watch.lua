-- Notices saved mod files from inside the game, so saving a file reloads its mod with nothing else running

local Wax = ...
local sched = Wax.import("core.sched")

local watch = {}

local IDLE_FRAMES, ACTIVE_FRAMES = 10, 2    -- one file is looked at every this many frames
local ACTIVE_SECONDS = 60                   -- how long after a change the faster pace is kept
local SETTLE_SECONDS = 0.12                 -- editors save in several steps, so wait for them to finish

local files, by_path = {}, {}               -- { mod, path, content }
local cursor, frame = 0, 0
local last_change, hot = -math.huge, nil
local dirty = {}                            -- mod id -> when its last change was seen
local enabled = true

watch.on_change = nil                       -- function(mod_id), set by the loader
watch.checks = 0

-- list: { id, dir, files = { ["relative/path.lua"] = true } } for every mod to watch
function watch.track(list)
    local kept = {}
    files = {}
    for _, mod in ipairs(list) do
        for relative in pairs(mod.files) do
            if relative:match("%.lua$") then
                local path = mod.dir .. "/" .. relative
                local entry = by_path[path] or { path = path }
                entry.mod = mod.id
                kept[path] = entry
                files[#files + 1] = entry
            end
        end
    end
    by_path = kept
    table.sort(files, function(a, b) return a.path < b.path end)
    if cursor > #files then cursor = 0 end
end

-- The loader reports what it read, so the comparison starts from exactly what is running.
function watch.loaded(path, content)
    local entry = by_path[path]
    if entry then entry.content = content end
end

local function check(entry)
    watch.checks = watch.checks + 1
    local file = io.open(entry.path, "rb")
    if not file then return end
    local content = file:read("a")
    file:close()
    if entry.content == nil then
        entry.content = content
    elseif content ~= entry.content then
        entry.content = content
        local now = sched.clock()
        dirty[entry.mod], last_change, hot = now, now, entry
    end
end

function watch.step()
    if not enabled or #files == 0 then return end
    frame = frame + 1
    local now = sched.clock()
    local active = now - last_change < ACTIVE_SECONDS
    if frame % (active and ACTIVE_FRAMES or IDLE_FRAMES) ~= 0 then return end
    -- the file being edited is looked at every other time
    if active and hot and by_path[hot.path] and frame % (ACTIVE_FRAMES * 2) == 0 then
        check(hot)
    else
        cursor = cursor % #files + 1
        check(files[cursor])
    end
    for id, at in pairs(dirty) do
        if now - at >= SETTLE_SECONDS then
            dirty[id] = nil
            if watch.on_change then watch.on_change(id) end
        end
    end
end

function watch.set_enabled(on) enabled = on and true or false end
function watch.enabled() return enabled end
function watch.count() return #files end

return watch
