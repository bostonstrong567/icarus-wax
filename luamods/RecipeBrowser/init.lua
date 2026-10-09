-- Prospector's Codex: every item of the game, how it is made, what it is used in and at which station.
-- This file is what the view needs: the check for game.Data, the settings, the open key and the read of the game's
-- tables. The view itself is view.lua, started at the end.

local text = require(mod.text)
require(mod.text_creatures)(text)

local NEEDS = "0.3.0"       -- the first Wax with everything this mod is made of

if not ui then return end
local found, data = pcall(function() return game.Data end)
-- an older Wax has no way to measure text
if not found or not data or type(ui.TextWidth) ~= "function" then
    ui.Notify(text.problem.needs_wax(NEEDS), { kind = "bad", seconds = 10 })
    return
end

local source, tags, model, unlock = require(mod.source), require(mod.tags), require(mod.model), require(mod.unlock)
local format, search = require(mod.format), require(mod.search)
local loading = require(mod.load)
local creatures = require(mod.creatures)

local settings = storage.Load("settings", { internal_names = false, welcomed = false })

-- What a view is given.
local app = { text = text, settings = settings, search = search, format = format, failed = loading.FAILED, needs = NEEDS }

app.rows = require(mod.rows).new({ text = text, format = format, unlock = unlock })
app.history = require(mod.history).new(20)
app.tree, app.gather, app.unlock = require(mod.tree), require(mod.gather), unlock

-- What is read for one item when it is looked at: its numbers, and the game's own words about it.
local function details()
    local detail = source.new(data)
    app.stats = require(mod.stats).new(detail, text, format)
    app.page = require(mod.creature_page).new({ beasts = text.beasts, text = text, creatures = creatures, stats = app.stats })
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
-- The creatures the player keeps, as the favourites are kept.
app.kept = require(mod.favourites).new(function() return storage.Load("creatures", {}) end,
    function(list) storage.Save("creatures", list) end)

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
    changed = function()
        if app.beasts then app.beasts.items_changed() end
        if view and view.refresh then task.spawn(view.refresh) end
    end })

-- The read of the creature tables, for the Bestiary side. It starts by itself once the items are read.
app.beasts = require(mod.creature_load).new({ data = data, source = source, creatures = creatures, task = task,
    kept = persist("creatures"), lower = search.lower, words = text.beasts.search_words(),
    items = function() return app.job.model end,
    showing = function() return view ~= nil and view.showing ~= nil and view.showing() == true end,
    -- only a view that has a Bestiary side is told
    changed = function() if view and view.creatures then task.spawn(view.creatures) end end })
-- items kept from before a reload tell nobody that they are there
app.beasts.items_changed()

-- The key that shows and hides the panels. The player changes it on the mod's card of the Mods page.
local OPEN_KEY = "F10"
local function toggle() if view and view.toggle then view.toggle() end end
local function bind()
    if ui.Bind then
        app.hotkey = ui.Bind("Show or hide the panels", OPEN_KEY, toggle, { in_menu = true })
    else
        app.hotkey = ui.Hotkey(OPEN_KEY, toggle, { in_menu = true })
    end
end
local function open_key() return app.hotkey and app.hotkey.Get and app.hotkey:Get() or OPEN_KEY end

-- The view is the panels beside the game's screens (view.lua). Its start runs in a task and gives back refresh(),
-- toggle() and showing(), and may give key(key, refused).
task.spawn(function()
    view = require(mod.view).start(app) or {}
    app.view = view
    bind()
    data.Changed:Connect(function(name)
        details()
        app.job.data_changed(name)
        app.beasts.data_changed(name)
    end)
    if not settings.welcomed then
        settings.welcomed = true
        app.save()
        if app.hotkey then ui.Notify(text.first_load(open_key()), { icon = "book-open", seconds = 8 }) end
    end
    if app.read_at_start() then task.delay(loading.START_DELAY, app.job.want) end
end)

return app
