-- Reads the game's creature tables a little each frame once the items are read, and keeps the joined model across reloads.

local creature_load = {}

creature_load.IDLE_MS, creature_load.WAITING_MS = 1, 4      -- a frame's share for reading: browser closed, browser showing
creature_load.ITEMS_DONE = 3                                -- the item model's last stage: the read starts by itself then

-- parts: data, source, creatures, task, kept (survives reloads), lower, words, items(), showing(), changed()
function creature_load.new(parts)
    local data, source, creatures, task, kept = parts.data, parts.source, parts.creatures, parts.task, parts.kept
    local items = parts.items or function() return nil end
    local showing = parts.showing or function() return false end
    local changed = parts.changed or function() end
    local self = { model = nil, source = nil, reading = false, failed = false, seconds = 0, runs = 0 }
    local thread, run, asked, built_on, reading_for = nil, 0, false, nil, nil
    local tables = {}

    for _, entry in ipairs(creatures.TABLES) do tables[entry.table:lower()] = true end

    local function budget()
        return showing() and creature_load.WAITING_MS or creature_load.IDLE_MS
    end

    -- The join pauses after a number of rows. With the browser showing it gets four times as many a frame.
    local skipped = 0
    local function pause()
        skipped = skipped + 1
        if skipped * creature_load.IDLE_MS < budget() then return end
        skipped = 0
        task.wait()
    end

    -- What of the item model the creature model stands on: built again when this changes.
    local function mark_of(m)
        return tostring(m.version) .. ":" .. tostring(m.stamp)
    end

    local function ready(m)
        return type(m) == "table" and (m.stage or 0) >= 1 and not m.off.list and type(m.templates) == "table"
    end

    local function read(id, m)
        local started = os.clock()
        local src = source.new(data, creatures.TABLES)
        -- a table game.Data still holds comes back at once, so the frame is given back between tables too
        src.read(1, budget, pause)
        task.wait()
        local c = creatures.build(src, m, { lower = parts.lower, words = parts.words, pause = pause })
        if run ~= id then return end
        self.seconds = os.clock() - started
        kept.version, kept.stamp, kept.items, kept.model, kept.seconds = creatures.version, c.stamp, mark_of(m), c, self.seconds
        self.reading, self.model, self.source, built_on, reading_for = false, c, src, m, nil
        changed()
    end

    local function start(m)
        if thread then pcall(task.cancel, thread) end
        run = run + 1
        local id = run
        reading_for = m
        self.reading, self.failed, self.runs = true, false, self.runs + 1
        kept.version, kept.stamp, kept.items, kept.model = nil, nil, nil, nil
        thread = task.spawn(function()
            local ok, problem = xpcall(read, debug.traceback, id, m)
            if run ~= id then return end
            thread = nil
            if ok then return end
            self.reading, self.failed, reading_for = false, true, nil
            changed()
            error(problem, 0)
        end)
        if self.reading then changed() end
    end

    -- Starts the read when the items are there. Asked before that, it starts with them. Asking again does nothing.
    function self.want()
        asked = true
        if self.model or self.reading then return end
        local m = items()
        if ready(m) then start(m) end
    end

    -- The item model has more, or is another one. Call it whenever the item read tells the views.
    function self.items_changed()
        local m = items()
        if not ready(m) then return end
        if self.reading and reading_for == m then return end
        if self.model and not self.reading and (built_on == m or kept.items == mark_of(m)) then
            built_on = m
            return
        end
        if self.model or self.reading or asked or (m.stage or 0) >= creature_load.ITEMS_DONE then start(m) end
    end

    function self.again()
        local m = items()
        if ready(m) then start(m) end
    end

    -- game.Data.Changed: the game made a table again, or everything read so far was dropped.
    function self.data_changed(name)
        if not (self.model or self.reading) then return end
        if type(name) == "string" then
            local short = name:lower():gsub("^d_", ""):gsub("_metatable$", "")
            if not tables[short] then return end
        end
        self.model, self.source, built_on = nil, nil, nil
        local m = items()
        if ready(m) then start(m) else changed() end
    end

    -- What one page needs beyond the list: the field guide's texts, experience, and the numbers while they are served.
    function self.detail(id, position)
        if not self.model or not self.source then return nil end
        return creatures.detail(self.model, self.source, id, position)
    end

    -- True while the game serves the map and curve fields a creature's numbers are read from.
    function self.numbers()
        return self.model ~= nil and self.source ~= nil and self.source.serves("AIGrowth", "Base") == true
    end

    -- The figures a list can be put in order by, of a group's first variant, health and damage at one level.
    function self.figures(id, level)
        if not self.model or not self.source then return nil end
        return creatures.figures(self.model, self.source, id, level)
    end

    -- True when this version of the game lost a table the list stands on.
    function self.off()
        return self.model ~= nil and self.model.off.list == true
    end

    function self.problems()
        return self.model and self.model.missing or {}
    end

    function self.stop()
        run = run + 1
        if thread then pcall(task.cancel, thread) end
        thread, self.reading, reading_for = nil, false, nil
    end

    -- A model kept from before the mod reloaded is used again while the game has the tables and the items it was built on.
    if kept.model then
        local m = items()
        local src = source.new(data, creatures.TABLES)
        if kept.version == creatures.version and ready(m) and kept.items == mark_of(m) and kept.stamp == src.stamps() then
            self.model, self.source, self.seconds, built_on, asked = kept.model, src, kept.seconds or 0, m, true
        else
            kept.version, kept.stamp, kept.items, kept.model = nil, nil, nil, nil
            asked = true
            if ready(m) then start(m) end
        end
    end

    return self
end

return creature_load
