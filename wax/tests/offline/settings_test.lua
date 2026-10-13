-- Offline tests for ui.Settings: a settings window from a list of fields, with presets and saved values.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\settings_test.lua <scratch folder>

local t = dofile("wax/tests/offline/harness.lua")
local fake = dofile("wax/tests/offline/fake_engine.lua")
fake.install()

local root = arg and arg[1] or "build/_settings-test"
local function mkdir(path) os.execute('mkdir "' .. path:gsub("/", "\\") .. '" >nul 2>nul') end
mkdir(root)
mkdir(root .. "/saved")

local Wax = t.new_wax()
_G.Wax = Wax
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local log = Wax.import("core.log")
local sched = Wax.import("core.sched")
Wax.log, Wax.guard, Wax.sched = log, guard, sched
local owner = scope.new("Stacks")
Wax.mods = {
    list = function() return { { id = "Stacks", name = "Stacks", version = "1.0.0", status = "loaded", generation = 1, loadMs = 1 } } end,
    get = function(id) if id == "Stacks" then return { scope = owner } end end,
    request_reload = function() end,
    request_sync = function() end,
}
local storage = Wax.import("core.storage")
storage.directory = root .. "/saved"
local ui = Wax.import("gui.init")
local events = Wax.import("gui.events")
ui.start()
Wax.ui = ui
ui.Theme().animation = 0

local function frames(count)
    for _ = 1, count or 1 do
        sched.step()
        ui.step()
    end
end

local function as(fn, ...) return scope.run(owner, fn, ...) end

local SPEC = {
    title = "Stacks",
    icon = "layers",
    presets = {
        { "Balanced", { multiplier = 2, weight = 0.5 } },
        { "Caramel", { multiplier = 10, weight = 1, ammo = true } },
    },
    fields = {
        { "multiplier", "Stack multiplier", slider = { min = 1, max = 50, step = 1 }, default = 2, help = "How many times the game's stack." },
        { "weight", "Weight", slider = { min = 0.1, max = 1, step = 0.1 }, default = 0.5 },
        { heading = "Kinds" },
        { "ammo", "Ammo too", toggle = true, default = false },
        { "mode", "Mode", choices = { "Slow", "Normal", "Fast" }, default = "Normal" },
        { "label", "Label", text = { hint = "a name" }, default = "" },
    },
}

local settings, heard

local function listen(created)
    heard = {}
    created.Changed:Connect(function(key, value) heard[#heard + 1] = key .. "=" .. tostring(value) end)
end

t.test("a settings window builds with the defaults and names the preset they match", function()
    settings = as(function() return ui.Settings(SPEC) end)
    t.eq(settings.values.multiplier, 2)
    t.eq(settings.values.weight, 0.5)
    t.eq(settings.values.ammo, false)
    t.eq(settings.values.mode, "Normal")
    t.eq(settings.values.label, "")
    t.eq(settings:Preset(), "Balanced")
    t.ok(settings.window, "it has a window")
    t.ok(settings.controls.multiplier and settings.controls.ammo and settings.controls.mode and settings.controls.label, "every field has a control")
    t.eq(settings.controls.multiplier:Get(), 2)
    listen(settings)
end)

t.test("a control the user moves changes the value, saves it, fires Changed, and the preset reads Custom", function()
    events.simulate(settings.controls.multiplier.source, "OnValueChanged", 7.3)
    events.simulate(settings.controls.multiplier.source, "OnMouseCaptureEnd")
    frames(2)
    t.eq(settings.values.multiplier, 7)
    t.eq(table.concat(heard, ","), "multiplier=7")
    t.eq(settings:Preset(), "Custom")
    storage.flush()
    local file = io.open(root .. "/saved/Stacks.settings.lua", "rb")
    t.ok(file, "the values are on disk under the mod's name")
    local text = file:read("a")
    file:close()
    t.ok(text:find("multiplier", 1, true) and text:find("7", 1, true), text)
end)

t.test("a preset sets its fields, moves the controls, and fires Changed once per field that moved", function()
    heard = {}
    t.eq(settings:UsePreset("Caramel"), true)
    frames(2)
    t.eq(settings.values.multiplier, 10)
    t.eq(settings.values.weight, 1)
    t.eq(settings.values.ammo, true)
    t.eq(settings.controls.multiplier:Get(), 10)
    t.eq(settings.controls.ammo:Get(), true)
    t.eq(table.concat(heard, ","), "ammo=true,multiplier=10,weight=1")
    t.eq(settings:Preset(), "Caramel")
    t.eq(settings:UsePreset("Caramel"), false, "nothing moved the second time")
    t.raises(function() settings:UsePreset("Nope") end, "there is no preset named Nope")
end)

t.test("Set, Get and Reset check their keys and values", function()
    heard = {}
    t.eq(settings:Set("mode", "Fast"), true)
    frames(1)
    t.eq(settings:Get("mode"), "Fast")
    t.eq(settings.controls.mode:Get(), "Fast")
    t.eq(settings:Set("mode", "Fast"), false)
    t.raises(function() settings:Set("mode", "Sideways") end, "mode cannot be Sideways")
    t.raises(function() settings:Set("nope", 1) end, "nope is not a setting here")
    t.raises(function() settings:Get("nope") end, "nope is not a setting here")
    t.eq(settings:Set("multiplier", 500), true, "a number past the range is kept inside it")
    t.eq(settings:Get("multiplier"), 50)
    t.eq(settings:Reset(), true)
    frames(1)
    t.eq(settings:Preset(), "Balanced")
    t.eq(settings.values.mode, "Normal")
    t.eq(settings.controls.multiplier:Get(), 2)
end)

t.test("saved values come back on the next load, and one of the wrong kind falls back to the default", function()
    settings:Set("weight", 0.8)
    settings:Set("label", "mine")
    storage.flush()
    local saved = storage.load("Stacks", "settings", {})
    saved.mode = 42
    storage.save("Stacks", "settings", saved)
    storage.flush()
    local again = as(function() return ui.Settings(SPEC) end)
    t.eq(again.values.weight, 0.8)
    t.eq(again.values.label, "mine")
    t.eq(again.values.mode, "Normal")
    t.eq(again:Preset(), "Custom")
end)

t.test("a wrong spec is refused with a plain message", function()
    local function spec(fields, presets) return { title = "X", fields = fields, presets = presets } end
    t.raises(function() as(function() return ui.Settings("x") end) end, "ui.Settings takes a table")
    t.raises(function() as(function() return ui.Settings(spec({})) end) end, "needs fields")
    t.raises(function() as(function() return ui.Settings(spec({ { "a", "A", toggle = true } })) end) end, "field a needs a default")
    t.raises(function() as(function() return ui.Settings(spec({ { "a", "A", default = 1 } })) end) end, "field a needs one of slider")
    t.raises(function() as(function() return ui.Settings(spec({ { "a", "A", toggle = true, default = false }, { "a", "B", toggle = true, default = true } })) end) end, "two fields are named a")
    t.raises(function() as(function() return ui.Settings(spec({ { "a", "A", choices = { "x", "y" }, default = "z" } })) end) end, "the default z does not fit")
    t.raises(function() as(function() return ui.Settings(spec({ { "a", "A", toggle = true, default = false } }, { { "P", { b = 1 } } })) end) end, "preset P sets b, which is not a field")
    t.raises(function() as(function() return ui.Settings(spec({ { "a", "A", toggle = true, default = false } }, { { "Custom", { a = true } } })) end) end, "cannot be named Custom")
end)

t.finish()
