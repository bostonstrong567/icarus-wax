-- Recipe Browser: every item of the game, how it is made, what it is used in and at which station.
-- This file is what the view needs: the check for game.Data, the settings, the open key and the read of the game's
-- tables. The view itself is view.lua, started at the end.

local text = require(mod.text)

local NEEDS = "0.2.0"       -- the first Wax with the game's tables and the panels this mod is made of

if not ui then return end
local found, data = pcall(function() return game.Data end)
if not found or not data then
    ui.Notify(text.problem.needs_wax(NEEDS), { kind = "bad", seconds = 10 })
    return
end

local source, tags, model, unlock = require(mod.source), require(mod.tags), require(mod.model), require(mod.unlock)
local format, search = require(mod.format), require(mod.search)
local loading = require(mod.load)

local settings = storage.Load("settings", { key = "F7", internal_names = false, welcomed = false })

-- What a view is given.
local app = { text = text, settings = settings, search = search, format = format, failed = loading.FAILED, needs = NEEDS }

app.rows = require(mod.rows).new({ text = text, format = format, unlock = unlock })
app.history = require(mod.history).new(20)
app.tree, app.gather, app.unlock = require(mod.tree), require(mod.gather), unlock

-- What is read for one item when it is looked at: its numbers, and the game's own words about it.
local function details()
    local detail = source.new(data)
    app.stats = require(mod.stats).new(detail, text, format)
    -- The description and the line under it, from the item's row name in D_ItemsStatic. Either may be missing.
    function app.describe(row)
        local static = detail.detail("ItemsStatic", row)
        local handle = static and static.Itemable
        local name = type(handle) == "table" and handle.RowName or handle
        local about = type(name) == "string" and detail.detail("Itemable", name) or nil
        if not about then return nil, nil end
        local function words(value) return type(value) == "string" and value ~= "" and value or nil end
        return words(about.Description), words(about.FlavorText)
    end
end
details()
app.favourites = require(mod.favourites).new(function() return storage.Load("favourites", {}) end,
    function(list) storage.Save("favourites", list) end)

function app.save() storage.Save("settings", settings) end

function app.read_at_start()
    if settings.read_at_start == nil then return loading.READ_AT_START end
    return settings.read_at_start == true
end

-- What the view's start gave back: any of refresh(), toggle(), showing(), key(key, refused).
local view = nil

-- The read of the tables. A view starts it with app.job.want() and is told through refresh() how far it has come.
app.job = loading.new({ data = data, source = source, model = model, tags = tags, search = search, unlock = unlock, text = text,
    task = task, kept = persist("model"),
    showing = function() return view ~= nil and view.showing ~= nil and view.showing() == true end,
    -- in a task of its own, so a view that takes its time does not hold the reading up
    changed = function() if view and view.refresh then task.spawn(view.refresh) end end })

-- A key the Wax menu uses cannot be the open key as well: one press would open and close again.
local function bind(key)
    if app.hotkey then
        app.hotkey.Disconnect()
        app.hotkey = nil
    end
    local refused = key == nil or key == ui.GetToggleKey()
    if not refused then
        app.hotkey = ui.Hotkey(key, function() if view and view.toggle then view.toggle() end end, { in_menu = true })
    end
    if view and view.key then view.key(key, refused) end
end

-- Changes the open key. False when the key is the Wax menu's: the key then stays what it was.
function app.set_key(key)
    if key == ui.GetToggleKey() then
        if view and view.key then view.key(settings.key, true) end
        return false
    end
    settings.key = key
    app.save()
    bind(key)
    return true
end

-- The view is the panels beside the game's screens (view.lua). Its start runs in a task and gives back refresh(),
-- toggle() and showing(), and may give key(key, refused).
task.spawn(function()
    view = require(mod.view).start(app) or {}
    bind(settings.key)
    ui.KeyChanged:Connect(function() bind(settings.key) end)
    data.Changed:Connect(function(name)
        details()
        app.job.data_changed(name)
    end)
    if not settings.welcomed then
        settings.welcomed = true
        app.save()
        if app.hotkey then ui.Notify(text.first_load(settings.key), { icon = "book-open", seconds = 8 }) end
    end
    if app.read_at_start() then task.delay(loading.START_DELAY, app.job.want) end
end)

return app
