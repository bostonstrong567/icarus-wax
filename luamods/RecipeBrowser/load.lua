-- Reads the game's tables in three stages, a little each frame, and keeps the joined model across reloads of the mod.

local load = {}

load.READ_AT_START = false      -- the default of "Read the game's data when the game starts"
load.START_DELAY = 5            -- seconds after the mod loads, when that setting is on
load.IDLE_MS, load.WAITING_MS = 1, 4    -- a frame's share for reading: browser closed, browser showing
load.FAILED = "The game's data could not be read. The Log page of the Wax menu says why."

-- parts: data (game.Data), source, model, tags, search, unlock, text, task, kept (a table that survives reloads),
--        showing() (true while the browser is on screen), changed() (called whenever what the views show is out of date)
function load.new(parts)
    local data, source, model, unlock, search = parts.data, parts.source, parts.model, parts.unlock, parts.search
    local task, kept, text = parts.task, parts.kept, parts.text
    local showing = parts.showing or function() return false end
    local changed = parts.changed or function() end
    local self = { model = nil, find = nil, needs = nil, reading = false, failed = false, seconds = 0, runs = 0 }
    local thread, run, step = nil, 0, 0
    local item_fields, tables = {}, {}

    for _, entry in ipairs(source.lists()) do
        tables[entry.table:lower()] = true
        if entry.table == "ItemsStatic" and not entry.meta then item_fields = entry.fields end
    end

    local function budget()
        return showing() and load.WAITING_MS or load.IDLE_MS
    end

    -- The join pauses after a number of rows. With the browser showing it gets four times as many a frame.
    local skipped = 0
    local function pause()
        skipped = skipped + 1
        if skipped * load.IDLE_MS < budget() then return end
        skipped = 0
        task.wait()
    end

    local function publish(m, index)
        self.model, self.needs = m, index
        self.find = search.index(m, { lower = search.lower })
        changed()
    end

    -- Reading and joining never share a frame: each read is followed by a pause. `step` counts the six parts done.
    local function read(id)
        local started = os.clock()
        local src = source.new(data)
        local index = nil
        step = 0
        src.read(1, budget)
        step = 1
        task.wait()
        local b = model.begin(src, search.lower, parts.tags)
        local m = b.model
        model.items(b, pause)
        if run ~= id then return end
        if m.stage >= 1 then
            step = 2
            publish(m, nil)
            task.wait()
            src.read(2, budget)
            step = 3
            task.wait()
            model.recipes(b, pause)
            if run ~= id then return end
            step = 4
            publish(m, nil)
            task.wait()
            src.read(3, budget)
            step = 5
            task.wait()
            model.levels(b, pause)
            index = unlock.index(src, pause, text)
            if run ~= id then return end
        end
        self.seconds = os.clock() - started
        kept.version, kept.stamp, kept.model, kept.needs, kept.seconds = model.version, m.stamp, m, index, self.seconds
        self.reading = false
        publish(m, index)
    end

    local function start()
        if thread then pcall(task.cancel, thread) end
        run = run + 1
        local id = run
        kept.wanted = true
        self.reading, self.failed, self.runs = true, false, self.runs + 1
        kept.version, kept.stamp, kept.model, kept.needs = nil, nil, nil, nil
        thread = task.spawn(function()
            local ok, problem = xpcall(read, debug.traceback, id)
            if run ~= id then return end
            thread = nil
            if ok then return end
            self.reading, self.failed = false, true
            changed()
            error(problem, 0)
        end)
        if self.reading then changed() end
    end

    -- Starts the first read. Asking again does nothing.
    function self.want()
        if self.model or self.reading then return end
        start()
    end

    -- Reads everything again, whatever is there.
    function self.again()
        start()
    end

    -- game.Data.Changed: the game made a table again, or everything read so far was dropped.
    function self.data_changed(name)
        if not (self.model or self.reading) then return end
        if type(name) == "string" then
            local short = name:lower():gsub("^d_", ""):gsub("_metatable$", "")
            if not tables[short] then return end
        end
        start()
    end

    local function items_read()
        local ok, done, total = pcall(function() return data:Table("ItemsStatic"):Loaded(item_fields) end)
        if not ok then return 0, 0 end
        return tonumber(done) or 0, tonumber(total) or 0
    end

    -- A number for the status line while the items are read: rows so far, then the items the list holds.
    function self.count()
        local m = self.model
        if m and m.stage >= 1 and not m.off.list then return m.counts.shown end
        return (items_read())
    end

    -- What the model in hand holds: 0 nothing, 1 the items, 2 the recipes as well, 3 the needs lines and expansions too.
    function self.stage()
        return self.model and self.model.stage or 0
    end

    -- How far the read under way has come, 0 to 1. With nothing being read: 1 with a model, 0 without.
    function self.progress()
        if not self.reading then return self.model and 1 or 0 end
        local part = 0
        if step == 0 then
            local done, total = items_read()
            if total > 0 then part = math.min(1, done / total) end
        end
        return (step + part) / 6
    end

    -- What the model could not find in this version of the game: { { table, row, field } }
    function self.problems()
        return self.model and self.model.missing or {}
    end

    function self.stop()
        run = run + 1
        if thread then pcall(task.cancel, thread) end
        thread, self.reading = nil, false
    end

    -- A model kept from before the mod reloaded is used again while the game still has the tables it was read from.
    if kept.model then
        local same = kept.version == model.version and kept.stamp == source.new(data).stamps()
        if same then
            self.model, self.needs, self.seconds = kept.model, kept.needs, kept.seconds or 0
            if self.needs then unlock.rebind(self.needs, text) end
            self.find = search.index(self.model, { lower = search.lower })
        else
            start()
        end
    elseif kept.wanted then
        start()
    end

    return self
end

return load
