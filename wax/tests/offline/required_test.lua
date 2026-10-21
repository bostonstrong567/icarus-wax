-- Sides and the mods a host requires: tools\lua\lua54\lua.exe wax\tests\offline\required_test.lua
local t = dofile("wax/tests/offline/harness.lua")

local authority = true
local logged, saved, notified = {}, {}, {}
local installed = {}
local modules = {}
local Wax = { import = function(name) return modules[name] end, mods = {
    list = function()
        local out = {}
        for id, mod in pairs(installed) do out[#out + 1] = { id = id, version = mod.version, status = mod.enabled and "loaded" or "disabled" } end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end,
    get = function(id) return installed[id] and { manifest = { name = installed[id].name } } or nil end,
    set_enabled = function(id, on)
        if not installed[id] then return false end
        installed[id].enabled = on
        return true
    end,
}, ui = { Notify = function(text, options) notified[#notified + 1] = { text = text, title = options and options.title } end } }
modules["core.log"] = { channel = function() return setmetatable({}, { __index = function() return function(_, text, ...) logged[#logged + 1] = text:format(...) end end }) end }
modules["core.scope"] = { enter = function() end, leave = function() end }
modules["core.sched"] = { clock = function() return 0 end, Signal = { new = function() return { Fire = function() end, Connect = function() end } end },
    task = { spawn = function(fn, ...) fn(...) return {} end, label = function(thread) return thread end, wait = function() end, cancel = function() end } }
modules["core.storage"] = { load = function(_, name, defaults) return saved[name] or defaults end, save = function(_, name, value) saved[name] = value end }
modules["mods.sides"] = assert(loadfile("wax/runtime/Scripts/wax/mods/sides.lua"))(Wax)
local sides = modules["mods.sides"]
Wax.mode = { kind = "client", IsAuthority = function() return authority end, HasScreen = function() return true end }
local required = assert(loadfile("wax/runtime/Scripts/wax/mods/required.lua"))(Wax)

t.test("a manifest's side and features are read, with the defaults", function()
    t.eq(sides.side_of({ side = "host" }), "host")
    t.eq(sides.side_of({ side = " Client " }), "client")
    t.eq(sides.side_of({ side = "server" }), "both", "an unknown word is both")
    t.eq(sides.side_of({}), "both")
    t.eq(sides.side_of(nil), "both")
    local features = sides.features_of({ features = { "host: Craft from containers", "client: Push all", { name = "Both ways", side = "both" }, "nothing", 7 } })
    t.eq(#features, 3)
    t.eq(features[1].name, "Craft from containers")
    t.eq(features[1].side, "host")
    t.eq(features[2].side, "client")
    t.eq(features[3].name, "Both ways")
    t.eq(#sides.features_of({}), 0)
end)

t.test("whether a side can run here follows Wax.mode", function()
    authority = true
    t.ok(sides.authority())
    t.eq(sides.kind(), "client", "the kind is what Wax.mode says")
    t.ok(sides.can_run("host"))
    t.ok(sides.can_run("both"))
    t.ok(sides.can_run("client"))
    t.eq(sides.tip("host"), nil)
    authority = false
    t.ok(not sides.can_run("host"))
    t.ok(sides.can_run("both"))
    t.eq(sides.tip("host"), sides.NEEDS_HOST)
    t.eq(sides.tip("both"), nil)
    t.ok(sides.can_run("host", true), "an authority given outright wins")
end)

t.test("the chat line names each mod with its version", function()
    local line = required.line({ { id = "Quartermaster", version = "1.0.0" }, { id = "Other" }, { id = "bad id", version = "1" }, { id = "X", version = "1 2" } })
    t.eq(line, "\1wax required Quartermaster@1.0.0,Other,X")
    t.eq(required.line({}), "\1wax required ")
end)

t.test("the line is read back, and other chat is not", function()
    local list = required.parse("\1wax required Quartermaster@1.0.0,Other, Third@2.1.0-beta ,Quartermaster@9")
    t.eq(#list, 3, "a repeated id counts once")
    t.eq(list[1].id, "Quartermaster")
    t.eq(list[1].version, "1.0.0")
    t.eq(list[2].id, "Other")
    t.eq(list[2].version, nil)
    t.eq(list[3].version, "2.1.0-beta")
    t.eq(required.parse("wax required Quartermaster"), nil, "without the first byte it is a player's words")
    t.eq(required.parse("hello"), nil)
    t.eq(required.parse(nil), nil)
    t.eq(#required.parse("\1wax required "), 0, "a host that requires nothing sends an empty list")
    t.eq(#required.parse("\1wax required ../x,9lives,ok_1"), 1, "ids that are no ids are dropped")
end)

t.test("versions compare as three numbers", function()
    t.ok(required.newer("1.2.0", "1.1.9"))
    t.ok(not required.newer("1.1.9", "1.2.0"))
    t.ok(not required.newer("1.0.0", "1.0.0"))
    t.ok(not required.newer("abc", "1.0.0"), "a version that is not numbers is never newer")
end)

t.test("each required mod gets one action", function()
    local here = { Fine = { version = "1.0.0", enabled = true }, Off = { version = "1.0.0", enabled = false }, Old = { version = "0.9.0", enabled = true } }
    local decisions = required.decide({ { id = "Fine", version = "1.0.0" }, { id = "Off" }, { id = "Old", version = "1.0.0" }, { id = "Gone", version = "2.0.0" },
        { id = "OldButOff", version = "1.0.0" } }, here)
    t.eq(decisions[1].action, "fine")
    t.eq(decisions[2].action, "enable")
    t.eq(decisions[3].action, "update")
    t.eq(decisions[4].action, "install")
    t.eq(decisions[5].action, "install", "a mod that is not here is installed whatever its version")
    t.eq(#required.open(decisions, "ignore"), 0, "ignore offers nothing")
    t.eq(#required.open(decisions, "ask"), 4)
    t.eq(#required.open(decisions, "install"), 4)
end)

t.test("hearing the line acts by the setting", function()
    installed = { Off = { version = "1.0.0", enabled = false, name = "Switched Off" } }
    notified, logged = {}, {}
    t.ok(not required.heard("just chat"), "a player's line is not ours")
    t.ok(required.heard("\1wax required Off@1.0.0", "ignore"))
    t.ok(not installed.Off.enabled, "ignore touches nothing")
    t.eq(#notified, 0)
    t.ok(required.heard("\1wax required Off@1.0.0", "ask"))
    t.ok(not installed.Off.enabled, "ask touches nothing either")
    t.eq(#notified, 1)
    t.ok(notified[1].text:find("The host requires Off 1.0.0", 1, true), notified[1].text)
    t.eq(#required.pending(), 1, "but the Mods page offers it")
    t.eq(required.pending()[1].action, "enable")
    t.ok(required.install_pending("Off"), "and the player can say yes there")
    t.ok(installed.Off.enabled)
    t.eq(#required.pending(), 0)
    t.ok(notified[2].text:find("Switched on Switched Off: the host requires it", 1, true), notified[2].text)
    installed.Off.enabled = false
    notified = {}
    t.ok(required.heard("\1wax required Off", "install"))
    t.ok(installed.Off.enabled, "install switches a mod that is here on at once")
    t.eq(required.asked().Off ~= nil, true)
    t.eq(#notified, 1)
end)

t.test("a mod that is not in the catalogue is named, not installed", function()
    installed = {}
    notified = {}
    modules["mods.browse"] = { refresh = function() end, state = function() return { loading = false } end, get = function() return nil end,
        standing = function() return "new" end, add = function() error("must not be called") end }
    t.ok(required.heard("\1wax required Missing@1.0.0", "install"))
    local waiting = required.pending()
    t.eq(#waiting, 1)
    t.eq(waiting[1].id, "Missing")
    t.ok(waiting[1].why:find("not in the catalogue", 1, true), waiting[1].why)
    t.ok(notified[1].text:find("ask the host", 1, true), notified[1].text)
end)

t.test("a mod that is in the catalogue is added without the new mark and switched on", function()
    installed = {}
    notified = {}
    local added = nil
    modules["mods.browse"] = { refresh = function() end, state = function() return { loading = false } end,
        get = function(id) return { id = id, name = "Supply Line", version = "1.2.0" } end, standing = function() return "new" end,
        add = function(id, options)
            added = options
            installed[id] = { version = "1.2.0", enabled = false, name = "Supply Line" }
            options.done(true)
            return true
        end }
    t.ok(required.heard("\1wax required SupplyLine@1.0.0", "install"))
    t.ok(added and added.required, "added as a required mod: no new mark")
    t.ok(installed.SupplyLine.enabled, "and switched on")
    for _, entry in ipairs(required.pending()) do t.ok(entry.id ~= "SupplyLine", "nothing waits for it") end
    t.ok(notified[1].text:find("Installed Supply Line 1.2.0: the host requires it", 1, true), notified[1].text)
    -- a version the catalogue does not have yet
    notified = {}
    installed = {}
    t.ok(required.heard("\1wax required SupplyLine@3.0.0", "install"))
    local why = nil
    for _, entry in ipairs(required.pending()) do
        if entry.id == "SupplyLine" then why = entry.why end
    end
    t.ok(why and why:find("only has 1.2.0", 1, true), tostring(why))
end)

t.test("the host's list is kept in wax.server and sent with the host's versions", function()
    installed = { Quartermaster = { version = "1.0.0", enabled = true, name = "Quartermaster" } }
    authority = true
    t.ok(required.set_required("Quartermaster", true))
    t.ok(required.is_required("Quartermaster"))
    t.ok(not required.set_required("Quartermaster", true), "already there")
    t.ok(required.set_required("Elsewhere", true))
    t.eq(#saved.server.required, 2)
    local list = required.required_list()
    t.eq(list[1].version, "1.0.0")
    t.eq(list[2].version, nil, "a required mod the host does not have is named alone")
    t.eq(required.line(list), "\1wax required Quartermaster@1.0.0,Elsewhere")
    t.ok(required.set_required("Quartermaster", false))
    t.eq(#saved.server.required, 1)
    t.raises(function() required.set_required("../x", true) end, "mod id")
end)

t.test("the setting is one of three words", function()
    required.set_mode("ask")
    t.eq(required.mode(), "ask")
    t.eq(saved.required.mode, "ask")
    t.raises(function() required.set_mode("maybe") end, "install")
end)

t.finish("required")
