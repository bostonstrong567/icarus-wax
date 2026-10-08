-- Offline tests for engine.needs: when Wax checks itself, what it reports as gone and under which part, and what it keeps.
-- The game is a table of made-up classes, structs, enums and data tables. Nothing here reaches the real one.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\needs_test.lua [scratch dir]

local t = dofile("wax/tests/offline/harness.lua")

local function win(path) return (path:gsub("/", "\\")) end
local base = (arg[1] or "build/needs-test"):gsub("\\", "/")
os.execute(('rmdir /s /q "%s" >nul 2>nul'):format(win(base)))
os.execute(('mkdir "%s" >nul 2>nul'):format(win(base)))

local LIST = {
    { id = "hero", name = "Heroes", without = "Heroes are not listed.",
        classes = { { class = "/Script/Icarus.Hero", properties = { "Health" }, functions = { "Heal" } } },
        structs = { { struct = "/Script/Icarus.Handle", fields = { "RowName" } } },
        enums = { { enum = "/Script/Icarus.EState", values = { Alive = 0 } } } },
    { id = "items", name = "Items", without = "Items show nothing.",
        tables = { { table = "D_Items", fields = { "Title", "Inputs.Count", "Inputs.Element.RowName" }, meta = { "Level.RowName" } } } },
    { id = "menus", name = "Menus", without = "Menus do not open.",
        classes = { { class = "/Script/Icarus.Hero", properties = { "Health" } },
            { class = "/Game/UI/UMG_Menu.UMG_Menu_C", properties = { "List" } },
            { class = "/Game/UI/UMG_Bench.UMG_Bench_C", late = true, properties = { "Slots" } } } },
    { id = "copy", name = "Clipboard", without = "Nothing is copied.",
        classes = { { class = "/Script/Icarus.Library", functions = { "Copy" } } } },
}
local LOOKUPS = 7       -- Hero is named by two parts and looked up once

-- A game in which every name of the list is there.
local function whole_game()
    local handle = { fields = { RowName = true } }
    return {
        version = "3.0.30.1-SHIPPING", files = "100-200", prospect = true,
        objects = {
            ["/Script/Icarus.Hero"] = { members = { Health = "property", MaxHealth = "property", Heal = "function" } },
            ["/Script/Icarus.Handle"] = handle,
            ["/Script/Icarus.EState"] = { values = { Alive = 0, Dead = 1 } },
            ["/Script/Icarus.Library"] = { members = { Copy = "function" } },
            ["/Game/UI/UMG_Menu.UMG_Menu_C"] = { members = { List = "property" } },
            ["/Game/UI/UMG_Bench.UMG_Bench_C"] = { members = { Slots = "property" } },
            ["/Engine/Transient.D_Items"] = {
                row = { fields = { Title = true, Inputs = { fields = { Count = true, Element = handle } } } },
                meta = { row = { fields = { Level = handle } } },
            },
        },
    }
end

-- A fresh Wax whose needs module looks at `game`. `folder` keeps what it saves, nothing is kept without one.
local function fresh(game, folder, list, stamp)
    local Wax = t.new_wax()
    local sched = Wax.import("core.sched")
    local storage = Wax.import("core.storage")
    storage.directory = folder and (base .. "/" .. folder) or nil
    if folder then os.execute(('mkdir "%s" >nul 2>nul'):format(win(base .. "/" .. folder))) end
    local needs = Wax.import("engine.needs")
    local world = { Wax = Wax, needs = needs, sched = sched, storage = storage, game = game, now = 0, frame = 0, finds = {},
        notices = {}, real = {} }
    sched.clock = function() return world.now end
    needs.now = function() return 1000 + world.frame end
    needs.LOOK_FRAMES, needs.WAIT_SECONDS = 1, 1
    needs.read_list = function() return list or LIST, stamp or "list-1" end
    needs.notify = function(text, broken) world.notices[#world.notices + 1] = { text = text, broken = broken } end
    for name, fn in pairs(needs.engine) do world.real[name] = fn end
    local engine = needs.engine
    function engine.find(path)
        world.finds[#world.finds + 1] = { frame = world.frame, path = path }
        local found = game.objects[path]
        if found == "error" then error("the engine said no", 0) end
        return found
    end
    function engine.members(class) return class.members end
    function engine.fields(struct) return struct.fields end
    function engine.values(enum) return enum.values end
    function engine.row_struct(data) return data.row end
    function engine.meta(data) return data.meta end
    function engine.version() return game.version end
    function engine.files() return game.files end
    function engine.in_prospect() return game.prospect end
    function engine.on_map(fn)
        world.map_changed = fn
        return { Disconnect = function() end }
    end
    function world.frames(count)
        for _ = 1, count or 1 do
            world.now, world.frame = world.now + 1 / 60, world.frame + 1
            sched.step()
        end
    end
    -- Runs until the check is over, and says how many frames that took.
    function world.settle(limit)
        for count = 1, limit or 600 do
            world.frames(1)
            if needs.report().state == "done" then return count end
        end
        error("the check did not finish", 2)
    end
    return world
end

local function names(list)
    local out = {}
    for at, item in ipairs(list) do out[at] = item.kind .. " " .. item.name end
    table.sort(out)
    return table.concat(out, " | ")
end

local function part(report, id)
    for _, entry in ipairs(report.parts) do
        if entry.id == id then return entry end
    end
    error("no part " .. id, 2)
end

t.test("before it is started nothing is known and nothing raises", function()
    local needs = t.new_wax().import("engine.needs")
    t.eq(needs.ok("crafting"), nil)
    t.eq(needs.report().state, "off")
end)

t.test("a version not seen before is checked, and every part of a whole game is fine", function()
    local w = fresh(whole_game(), "whole")
    w.needs.start()
    t.eq(w.needs.report().state, "waiting")
    t.eq(w.needs.ok("hero"), nil, "nothing is known before the check")
    w.settle()
    t.eq(#w.finds, LOOKUPS)
    for _, id in ipairs({ "hero", "items", "menus", "copy" }) do t.eq(w.needs.ok(id), true, id) end
    t.eq(w.needs.ok("Heroes"), true, "a part is also known by the name shown to the player")
    local report = w.needs.report()
    t.eq(report.version, "3.0.30.1-SHIPPING")
    t.eq(report.files, "100-200")
    t.eq(report.lookups, LOOKUPS)
    t.eq(report.frames, LOOKUPS)
    t.eq(#part(report, "hero").missing, 0)
    t.eq(part(report, "hero").line, "Heroes: works")
    t.eq(#w.notices, 0, "a first check that finds nothing wrong says nothing")
end)

t.test("the same version is not checked again", function()
    local w = fresh(whole_game(), "same")
    w.needs.start()
    w.settle()
    local before = #w.finds
    w.needs.start()
    t.eq(w.needs.report().state, "done")
    t.eq(w.needs.ok("items"), true, "known at once, before any frame")
    w.frames(200)
    t.eq(#w.finds, before, "no lookup was made")
end)

t.test("what was found out is still there after the game is started again", function()
    local game = whole_game()
    game.objects["/Script/Icarus.Library"] = nil
    local w = fresh(game, "again")
    w.needs.start()
    w.settle()
    t.eq(w.needs.ok("copy"), false)
    w.storage.flush()

    local later = fresh(game, "again")
    later.needs.start()
    t.eq(later.needs.ok("copy"), false, "read from the saved file")
    t.eq(later.needs.ok("hero"), true)
    t.eq(names(part(later.needs.report(), "copy").missing), "class /Script/Icarus.Library")
    later.frames(200)
    t.eq(#later.finds, 0, "nothing is looked up a second time")
    t.eq(#later.notices, 0)
end)

t.test("an update of the game is checked, and the player is told when all is fine", function()
    local game = whole_game()
    local w = fresh(game, "updated")
    w.needs.start()
    w.settle()
    w.storage.flush()

    game.version, game.files = "3.0.31.2-SHIPPING", "101-207"
    local later = fresh(game, "updated")
    local fired = {}
    later.needs.Checked:Connect(function(report) fired[#fired + 1] = report end)
    later.needs.start()
    t.eq(later.needs.ok("hero"), nil, "the answers of the version before are not used")
    later.settle()
    t.eq(#later.finds, LOOKUPS)
    t.eq(#later.notices, 1)
    t.eq(later.notices[1].text, "ICARUS was updated. Wax checked itself and everything works.")
    t.eq(later.notices[1].broken, false)
    t.eq(later.needs.message(), later.notices[1].text)
    t.eq(#fired, 1, "the signal fires once, when the check is over")
    t.eq(fired[1].updated, true)
    t.eq(fired[1].version, "3.0.31.2-SHIPPING")
end)

t.test("each kind of name that is gone is reported under the part that uses it", function()
    local game = whole_game()
    local objects = game.objects
    objects["/Script/Icarus.Hero"].members = { Heath = "property", MaxHealth = "property", Heals = "function" }
    objects["/Script/Icarus.Library"] = nil
    objects["/Engine/Transient.D_Items"].row.fields.Inputs.fields = { Amount = true, Element = { fields = { RowName = true } } }
    objects["/Engine/Transient.D_Items"].meta = nil
    local w = fresh(game)
    w.needs.start()
    w.settle()
    local report = w.needs.report()
    t.eq(names(part(report, "hero").missing),
        "function /Script/Icarus.Hero:Heal | property /Script/Icarus.Hero:Health")
    t.eq(names(part(report, "menus").missing), "property /Script/Icarus.Hero:Health", "only what this part uses of the class")
    t.eq(names(part(report, "copy").missing), "class /Script/Icarus.Library")
    t.eq(names(part(report, "items").missing), "field D_Items (its meta table):Level.RowName | field D_Items:Inputs.Count")
    for _, id in ipairs({ "hero", "items", "menus", "copy" }) do t.eq(w.needs.ok(id), false, id) end
    local hints = {}
    for _, item in ipairs(part(report, "hero").missing) do hints[item.name] = item.hint end
    t.eq(hints["/Script/Icarus.Hero:Health"], "Heath", "the closest name the game has now")
    t.eq(hints["/Script/Icarus.Hero:Heal"], "Heals")
end)

t.test("a table that is gone takes its fields with it, and a struct, an enum value and a field of a plain value are told apart", function()
    local game = whole_game()
    game.objects["/Engine/Transient.D_Items"] = nil
    game.objects["/Script/Icarus.Handle"] = { fields = { Row = true } }
    game.objects["/Script/Icarus.EState"] = { values = { Dead = 0, Alive = 1 } }
    local w = fresh(game)
    w.needs.start()
    w.settle()
    local report = w.needs.report()
    t.eq(names(part(report, "items").missing), "table D_Items")
    t.eq(names(part(report, "hero").missing), "field /Script/Icarus.Handle:RowName | value /Script/Icarus.EState:Alive")
    local why = {}
    for _, item in ipairs(part(report, "hero").missing) do why[item.kind] = item.why end
    t.eq(why.value, "it is 1 now and Wax expects 0")

    local plain = whole_game()
    plain.objects["/Engine/Transient.D_Items"].row.fields.Inputs = true
    local other = fresh(plain)
    other.needs.start()
    other.settle()
    local missing = part(other.needs.report(), "items").missing
    t.eq(names(missing), "field D_Items:Inputs.Count | field D_Items:Inputs.Element.RowName")
    t.eq(missing[1].why, "Inputs has no fields")
end)

t.test("a property that became a function is gone as a property", function()
    local game = whole_game()
    game.objects["/Script/Icarus.Hero"].members.Health = "function"
    local w = fresh(game)
    w.needs.start()
    w.settle()
    local missing = part(w.needs.report(), "hero").missing
    t.eq(names(missing), "property /Script/Icarus.Hero:Health")
    t.eq(missing[1].why, "it is a function now")
end)

t.test("a part with nothing missing is fine while another is not", function()
    local game = whole_game()
    game.objects["/Game/UI/UMG_Menu.UMG_Menu_C"].members = {}
    local w = fresh(game)
    w.needs.start()
    w.settle()
    t.eq(w.needs.ok("menus"), false)
    t.eq(w.needs.ok("hero"), true)
    t.eq(w.needs.ok("items"), true)
    t.eq(w.needs.ok("copy"), true)
    local report = w.needs.report()
    t.eq(part(report, "menus").line, "Menus: needs an update. Menus do not open.")
    t.eq(part(report, "items").line, "Items: works")
end)

t.test("a blueprint that only loads with its screen is not called gone, and any other blueprint is", function()
    local game = whole_game()
    game.objects["/Game/UI/UMG_Bench.UMG_Bench_C"] = nil
    local w = fresh(game)
    w.needs.start()
    w.settle()
    t.eq(w.needs.ok("menus"), true)
    local menus = part(w.needs.report(), "menus")
    t.eq(#menus.missing, 0)
    t.eq(names(menus.unchecked), "class /Game/UI/UMG_Bench.UMG_Bench_C")
    t.eq(menus.unchecked[1].why, "not loaded right now")

    game = whole_game()
    game.objects["/Game/UI/UMG_Menu.UMG_Menu_C"] = nil
    local other = fresh(game)
    other.needs.start()
    other.settle()
    t.eq(other.needs.ok("menus"), false)
    t.eq(names(part(other.needs.report(), "menus").missing), "class /Game/UI/UMG_Menu.UMG_Menu_C")
end)

t.test("the check waits for a prospect, then some seconds, then makes one lookup a frame", function()
    local game = whole_game()
    game.prospect = false
    local w = fresh(game)
    w.needs.WAIT_SECONDS = 2
    w.needs.start()
    w.frames(300)
    t.eq(#w.finds, 0, "nothing is looked up at the title screen")
    t.eq(w.needs.report().state, "waiting")
    game.prospect = true
    local entered = w.frame
    w.frames(100)
    t.eq(#w.finds, 0, "nor in the first seconds of a prospect")
    w.settle()
    t.ok(w.finds[1].frame - entered >= 120, "the first lookup comes two seconds in")
    local per_frame = {}
    for _, find in ipairs(w.finds) do per_frame[find.frame] = (per_frame[find.frame] or 0) + 1 end
    for frame, count in pairs(per_frame) do t.eq(count, 1, "lookups in frame " .. frame) end
    t.eq(w.finds[#w.finds].frame - w.finds[1].frame, LOOKUPS - 1, "one frame after the other")
    local stats = w.needs.stats()
    t.eq(stats.frames, LOOKUPS)
    t.eq(stats.state, "done")
end)

t.test("leaving the prospect stops the check until the next one has loaded", function()
    local w = fresh(whole_game())
    w.needs.start()
    while #w.finds < 3 do w.frames(1) end
    w.game.prospect = false
    w.map_changed()
    w.frames(200)
    t.eq(#w.finds, 3, "nothing is looked up while there is no prospect")
    t.eq(w.needs.report().state, "checking")
    w.game.prospect = true
    w.settle()
    t.eq(#w.finds, LOOKUPS, "it went on where it stopped")
    t.eq(w.needs.ok("hero"), true)
end)

t.test("the player is told which parts need an update, by name and in the list's order", function()
    local game = whole_game()
    local w = fresh(game, "told")
    w.needs.start()
    w.settle()
    w.storage.flush()

    game.version = "3.0.31.2-SHIPPING"
    game.objects["/Script/Icarus.Library"] = nil
    game.objects["/Script/Icarus.EState"] = nil
    local later = fresh(game, "told")
    later.needs.start()
    later.settle()
    t.eq(#later.notices, 1)
    t.eq(later.notices[1].text, "ICARUS was updated. 2 parts of Wax need an update: Heroes, Clipboard. The rest works.")
    t.eq(later.notices[1].broken, true)
    later.storage.flush()

    game.version = "3.0.32.3-SHIPPING"
    game.objects["/Script/Icarus.EState"] = { values = { Alive = 0 } }
    local third = fresh(game, "told")
    third.needs.start()
    third.settle()
    t.eq(third.notices[1].text, "ICARUS was updated. 1 part of Wax needs an update: Clipboard. The rest works.")
end)

t.test("a first check that finds something gone does not say the game was updated", function()
    local game = whole_game()
    game.objects["/Script/Icarus.Library"] = nil
    local w = fresh(game)
    w.needs.start()
    w.settle()
    t.eq(w.notices[1].text, "1 part of Wax does not work with this version of ICARUS and needs an update: Clipboard. The rest works.")

    local nothing = whole_game()
    nothing.objects = {}
    local other = fresh(nothing)
    other.needs.start()
    other.settle()
    t.eq(other.notices[1].text, "4 parts of Wax do not work with this version of ICARUS and need an update: Heroes, Items, Menus, Clipboard.")
end)

t.test("a changed list is checked again without saying the game was updated", function()
    local game = whole_game()
    local w = fresh(game, "list")
    w.needs.start()
    w.settle()
    w.storage.flush()
    local later = fresh(game, "list", LIST, "list-2")
    later.needs.start()
    t.eq(later.needs.ok("hero"), nil)
    later.settle()
    t.eq(#later.finds, LOOKUPS)
    t.eq(#later.notices, 0)
    t.eq(later.needs.report().updated, false)
end)

t.test("a lookup that fails is neither fine nor gone, and such a check is not kept", function()
    local game = whole_game()
    game.objects["/Script/Icarus.Library"] = "error"
    local w = fresh(game, "failed")
    w.needs.start()
    w.settle()
    t.eq(w.needs.ok("copy"), nil)
    t.eq(w.needs.ok("hero"), true)
    local copy = part(w.needs.report(), "copy")
    t.eq(copy.unchecked[1].why, "the engine said no")
    t.eq(copy.line, "Clipboard: could not be checked")
    t.eq(#w.notices, 0, "it does not claim that everything works")
    w.storage.flush()

    game.objects["/Script/Icarus.Library"] = { members = { Copy = "function" } }
    local later = fresh(game, "failed")
    later.needs.start()
    later.settle()
    t.eq(#later.finds, LOOKUPS, "checked again at the next start")
    t.eq(later.needs.ok("copy"), true)
end)

t.test("when the version cannot be read at the start, the sizes of the game's files stand in until it can", function()
    local game = whole_game()
    local w = fresh(game, "late")
    w.needs.start()
    w.settle()
    w.storage.flush()

    local text = game.version
    game.version = nil
    local later = fresh(game, "late")
    later.needs.start()
    t.eq(later.needs.ok("hero"), true, "the files are the same size, so the kept answers are used")
    game.version = text
    later.frames(200)
    t.eq(#later.finds, 0, "and the version, once read, agrees")
    t.eq(later.needs.report().state, "done")

    game.version = nil
    local changed = fresh(game, "late")
    changed.needs.start()
    t.eq(changed.needs.ok("hero"), true)
    game.version = "3.0.31.2-SHIPPING"
    changed.frames(300)
    t.eq(changed.needs.report().state, "done")
    t.eq(#changed.finds, LOOKUPS, "another version behind files of the same size is checked")
    t.eq(changed.notices[1].text, "ICARUS was updated. Wax checked itself and everything works.")
end)

t.test("without a version the sizes of the files alone tell an update", function()
    local game = whole_game()
    game.version = nil
    local w = fresh(game, "files")
    w.needs.READ_VERSION = false
    w.needs.start()
    w.settle()
    w.storage.flush()
    local same = fresh(game, "files")
    same.needs.READ_VERSION = false
    same.needs.start()
    t.eq(same.needs.report().state, "done")
    t.eq(same.needs.ok("items"), true)

    game.files = "100-201"
    local later = fresh(game, "files")
    later.needs.READ_VERSION = false
    later.needs.start()
    later.settle()
    t.eq(#later.finds, LOOKUPS)
    t.eq(later.notices[1].text, "ICARUS was updated. Wax checked itself and everything works.")
end)

t.test("only the last few versions are kept", function()
    local game = whole_game()
    for round = 1, 5 do
        game.version = "3.0." .. round
        local w = fresh(game, "kept")
        w.needs.now = function() return 1000 + round end
        w.needs.start()
        w.settle()
        w.storage.flush()
    end
    local kept = fresh(game, "kept").storage.load("wax", "needs", {})
    local count = 0
    for _ in pairs(kept.versions) do count = count + 1 end
    t.eq(count, 3)
    t.eq(kept.last, "3.0.5 100-200")
    t.ok(kept.versions["3.0.4 100-200"] and kept.versions["3.0.3 100-200"], "the newest three")
end)

t.test("recheck looks everything up again, at once when in a prospect", function()
    local game = whole_game()
    local w = fresh(game, "recheck")
    w.needs.start()
    w.settle()
    game.objects["/Script/Icarus.Library"] = nil
    w.needs.recheck()
    t.eq(w.needs.ok("copy"), nil)
    t.eq(w.settle(), LOOKUPS + 1, "no wait this time")
    t.eq(w.needs.ok("copy"), false)
    t.eq(#w.finds, LOOKUPS * 2)
end)

t.test("a name that is no part raises with the closest one", function()
    local w = fresh(whole_game())
    w.needs.start()
    t.raises(function() w.needs.ok("heros") end, "'heros' is not a part of data/needs.lua. Did you mean 'hero'?")
    t.raises(function() w.needs.line("nothing") end, "is not a part")
    t.eq(w.needs.line("hero"), "Heroes: not checked yet. Wax checks it a few seconds after you enter a prospect.")
    t.eq(w.needs.report().headline, "Wax checks itself a few seconds after you enter a prospect.")
    w.settle()
    t.ok(w.needs.report().headline:find("^Checked with ICARUS 3%.0%.30%.1%-SHIPPING on %d+%-%d+%-%d+ %d+:%d+: 4 of 4 parts work%.$"),
        w.needs.report().headline)
end)

t.test("the list that ships loads: every part has an id, a name and what stops without it", function()
    local needs = t.new_wax().import("engine.needs")
    local list, stamp = needs.read_list()
    t.ok(#list >= 12, "parts")
    t.ok(stamp:match("^%d+%-%d+$"), "a stamp of the text")
    local seen = {}
    for _, entry in ipairs(list) do
        t.ok(type(entry.id) == "string" and not seen[entry.id], "an id of its own: " .. tostring(entry.id))
        seen[entry.id] = true
        t.ok(type(entry.name) == "string" and #entry.name > 0, entry.id .. " has a name")
        t.ok(type(entry.without) == "string" and entry.without:match("%.$"), entry.id .. " says what stops working")
        t.ok(entry.classes or entry.structs or entry.enums or entry.tables, entry.id .. " names something")
    end
    for _, id in ipairs({ "crafting", "research", "creatures", "players", "highlight", "tables", "fit", "menu", "clipboard",
        "tracking", "libraries", "recipe-browser", "workshop-write" }) do
        t.ok(seen[id], "the part " .. id)
    end

    -- and it is taken as it is: in a game that has nothing, every part is reported
    local game = whole_game()
    game.objects = {}
    local w = fresh(game)
    w.needs.read_list = function() return list, stamp end
    w.needs.start()
    w.settle(2000)
    local report = w.needs.report()
    t.eq(#report.parts, #list)
    t.ok(report.lookups > 100, "lookups: " .. report.lookups)
    for _, entry in ipairs(report.parts) do
        if entry.ok ~= false then
            t.eq(#entry.missing, 0)
            t.ok(#entry.unchecked > 0, entry.id .. " is only fine here because a blueprint was not loaded")
        end
    end
    t.eq(w.needs.ok("crafting"), false)
end)

t.test("classes and structs are read through the engine's own reflection", function()
    local fake = dofile("wax/tests/offline/fake_world.lua")
    fake.install()
    local w = fresh(whole_game())
    local engine = w.real
    local actor = fake.class("/Script/Engine.Actor", nil, { RootComponent = "ObjectProperty" }, { K2_GetActorLocation = {} })
    fake.class("/Script/Icarus.Hero", actor, { Health = "IntProperty", Handle = { "StructProperty", struct = "Handle" },
        Inputs = { "ArrayProperty", inner = "IntProperty" } }, { Heal = { { "Amount", "IntProperty" } } })
    t.eq(engine.find("/Script/Icarus.Nothing"), nil)
    local hero = engine.find("/Script/Icarus.Hero")
    t.ok(hero, "found by path")
    local members = engine.members(hero)
    t.eq(members.Health, "property")
    t.eq(members.Heal, "function")
    t.eq(members.RootComponent, "property", "the parent's members count")
    t.eq(members.K2_GetActorLocation, "function")
    t.eq(members.Missing, nil)
    local fields = engine.fields(hero)
    t.eq(fields.Health, true)
    t.eq(fields.Inputs, true, "an array of plain values has no fields to follow")
    t.eq(fields.Handle:GetFName():ToString(), "Handle", "the struct a field holds")
    t.eq(fields.RootComponent, true)
end)

t.finish("needs")
