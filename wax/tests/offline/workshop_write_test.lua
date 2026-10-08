-- Offline tests for the writing side of game.Workshop: world.workshop_rows on data.patch, over the store's real rows in a
-- stand-in engine with UE4SS's write rules, and a stand-in for the store's screen whose freed widgets raise on any use.
-- workshop_fixture.lua holds the store's rows of the game build it was taken from, so the numbers here are that build's.
-- Nothing here reaches the game.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\workshop_write_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local fake = dofile("wax/tests/offline/fake_world.lua")
local tables = dofile("wax/tests/offline/fake_tables.lua")
local wording = dofile("wax/tests/offline/wording.lua")
fake.install()
tables.install()
local find_table = StaticFindObject
function StaticFindObject(path) return fake.static[path] or find_table(path) end

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)
local sched = Wax.import("core.sched")
local guard = Wax.import("core.guard")
local scope = Wax.import("core.scope")
local log = Wax.import("core.log")
local instance = Wax.import("engine.instance")
local game = Wax.import("engine.game")
local data = Wax.import("data.tables")
local journal = Wax.import("data.journal")
journal.clear()
local workshop = Wax.import("world.workshop")
local layout = Wax.import("world.workshop_layout")

local function fold(name) return (tostring(name):lower()) end

-- ---------------------------------------------------------------- the store's tables, with the shapes the game gives them

local S, U, C = "/Script/Icarus.", "/Script/IcarusUtilities.", "/Script/CoreUObject."
-- a row and a multi row handle start with a pointer that nothing reflects, so Lua cannot make one
tables.struct("/Script/Engine.TableRowBase", nil, {}, { lead = 8 })
tables.struct(U .. "IcarusTableRowBase", "/Script/Engine.TableRowBase", { { "CachedHardReferences", "ArrayProperty", inner = "ObjectProperty" } })
tables.struct(U .. "RowHandle", nil, { { "DataTablePtr", "WeakObjectProperty" }, { "RowName", "NameProperty" }, { "DataTableName", "NameProperty" } })
for _, name in ipairs({ "TalentModels", "TalentArchetypes", "TalentTrees", "Talents", "TalentRanks", "ItemTemplate", "ItemsStatic", "Itemable",
    "MetaCurrency" }) do
    tables.struct(S .. name .. "RowHandle", U .. "RowHandle", {})
end
tables.struct(U .. "MultiRowHandle", nil, { { "RowName", "NameProperty" } }, { lead = 8 })
tables.struct(S .. "FlagsMultiRowHandle", U .. "MultiRowHandle", { { "DataTableName", "EnumProperty" } })
tables.struct(C .. "Vector2D", nil, { { "X", "FloatProperty" }, { "Y", "FloatProperty" } })
tables.struct(S .. "TalentReward", nil, { { "GrantedStats", "MapProperty" },
    { "GrantedFlags", "ArrayProperty", inner = "StructProperty", struct = S .. "FlagsMultiRowHandle" } })
tables.struct(S .. "Talent", U .. "IcarusTableRowBase", {
    { "TalentType", "EnumProperty" }, { "DisplayName", "TextProperty" }, { "Description", "TextProperty" }, { "Icon", "SoftObjectProperty" },
    { "ExtraData", "StructProperty", struct = U .. "RowHandle" }, { "TalentTree", "StructProperty", struct = S .. "TalentTreesRowHandle" },
    { "position", "StructProperty", struct = C .. "Vector2D" }, { "Size", "StructProperty", struct = C .. "Vector2D" },
    { "Rewards", "ArrayProperty", inner = "StructProperty", struct = S .. "TalentReward" },
    { "RequiredTalents", "ArrayProperty", inner = "StructProperty", struct = S .. "TalentsRowHandle" },
    { "RequiredFlags", "ArrayProperty", inner = "StructProperty", struct = S .. "FlagsMultiRowHandle" },
    { "ForbiddenFlags", "ArrayProperty", inner = "StructProperty", struct = S .. "FlagsMultiRowHandle" },
    { "RequiredRank", "StructProperty", struct = S .. "TalentRanksRowHandle" }, { "RequiredLevel", "IntProperty" },
    { "bDefaultUnlocked", "BoolProperty" }, { "DrawMethodOverride", "EnumProperty" } })
tables.struct(S .. "TalentModel", U .. "IcarusTableRowBase", { { "bEnabled", "BoolProperty" } })
tables.struct(S .. "TalentArchetype", U .. "IcarusTableRowBase", { { "Model", "StructProperty", struct = S .. "TalentModelsRowHandle" },
    { "DisplayName", "TextProperty" }, { "BackgroundTexture", "SoftObjectProperty" }, { "Icon", "SoftObjectProperty" },
    { "RequiredLevel", "IntProperty" } })
tables.struct(S .. "TalentTree", U .. "IcarusTableRowBase", { { "DisplayName", "TextProperty" }, { "BackgroundTexture", "SoftObjectProperty" },
    { "Icon", "SoftObjectProperty" }, { "Archetype", "StructProperty", struct = S .. "TalentArchetypesRowHandle" },
    { "FirstRank", "StructProperty", struct = S .. "TalentRanksRowHandle" }, { "RequiredLevel", "IntProperty" } })
tables.struct(S .. "WorkshopCost", nil, { { "Meta", "StructProperty", struct = S .. "MetaCurrencyRowHandle" }, { "Amount", "IntProperty" } })
tables.struct(S .. "WorkshopItem", U .. "IcarusTableRowBase", { { "Item", "StructProperty", struct = S .. "ItemTemplateRowHandle" },
    { "ResearchCost", "ArrayProperty", inner = "StructProperty", struct = S .. "WorkshopCost" },
    { "ReplicationCost", "ArrayProperty", inner = "StructProperty", struct = S .. "WorkshopCost" },
    { "RequiredMission", "StructProperty", struct = S .. "TalentsRowHandle" } })
tables.struct(S .. "ItemDynamicData", nil, { { "PropertyType", "EnumProperty" }, { "Value", "IntProperty" } })
tables.struct(S .. "ItemData", U .. "IcarusTableRowBase", { { "ItemStaticData", "StructProperty", struct = S .. "ItemsStaticRowHandle" },
    { "ItemDynamicData", "ArrayProperty", inner = "StructProperty", struct = S .. "ItemDynamicData" },
    { "CachedStats", "MapProperty" }, { "DatabaseGUID", "StrProperty" } })
tables.struct(S .. "ItemStaticData", U .. "IcarusTableRowBase", { { "Itemable", "StructProperty", struct = S .. "ItemableRowHandle" },
    { "AdditionalStats", "MapProperty" } })
tables.struct(S .. "ItemableData", U .. "IcarusTableRowBase", { { "DisplayName", "TextProperty" }, { "Icon", "SoftObjectProperty" },
    { "Description", "TextProperty" }, { "Weight", "IntProperty" }, { "MaxStack", "IntProperty" } })
tables.struct(S .. "MetaCurrency", U .. "IcarusTableRowBase", { { "DisplayName", "TextProperty" }, { "Icon", "SoftObjectProperty" },
    { "Description", "TextProperty" }, { "DecoratorText", "StrProperty" }, { "bDisplayOnMainScreen", "BoolProperty" } })
tables.struct(S .. "AccountFlag", U .. "IcarusTableRowBase", { { "WorkshopUnlocks", "ArrayProperty", inner = "ObjectProperty" } })
tables.struct(S .. "DLCPackageData", U .. "IcarusTableRowBase", { { "DLCName", "TextProperty" } })

local STRUCTS = { TalentArchetypes = "TalentArchetype", TalentTrees = "TalentTree", Talents = "Talent", WorkshopItems = "WorkshopItem",
    ItemTemplate = "ItemData", ItemsStatic = "ItemStaticData", Itemable = "ItemableData", MetaCurrency = "MetaCurrency",
    AccountFlags = "AccountFlag", DLCPackageData = "DLCPackageData" }
-- The fixture leaves a handle's table name out where the game's data files do. In the running game every handle that names a row names its table.
local HANDLES = {
    Talents = { ExtraData = "D_WorkshopItems", TalentTree = "D_TalentTrees", RequiredTalents = "D_Talents" },
    WorkshopItems = { Item = "D_ItemTemplate", ResearchCost = "D_MetaCurrency", ReplicationCost = "D_MetaCurrency" },
    TalentArchetypes = { Model = "D_TalentModels" },
    TalentTrees = { Archetype = "D_TalentArchetypes" },
    ItemTemplate = { ItemStaticData = "D_ItemsStatic" },
    ItemsStatic = { Itemable = "D_Itemable" },
}
local function name_table(handle, home)
    if type(handle) == "table" and type(handle.RowName) == "string" and handle.RowName ~= "None" then handle.DataTableName = home end
end
do
    local plain = workshop.plain(dofile("wax/tests/offline/workshop_fixture.lua"))
    for name, struct in pairs(STRUCTS) do
        local order, rows = plain.names(name), {}
        for _, row in ipairs(order) do
            local filled = plain.row(name, row)
            for field, home in pairs(HANDLES[name] or {}) do
                local value = filled[field]
                name_table(value, home)
                for _, entry in ipairs(type(value) == "table" and value or {}) do
                    name_table(entry, home)
                    name_table(entry.Meta, home)
                end
            end
            rows[row] = filled
        end
        tables.table(name, S .. struct, rows, order)
    end
    local models = { "Player", "Blueprint", "Prospect", "Outpost", "Solo", "Creature", "Great_Hunt", "Workshop" }
    local rows = {}
    for _, name in ipairs(models) do rows[name] = { bEnabled = true } end
    tables.table("TalentModels", S .. "TalentModel", rows, models)
end

instance.start()
game.start()
Wax.game = game.root
local now = 100
sched.clock = function() return now end
data.clock = function() return now end
data.start()
local patch = Wax.import("data.patch")
patch.clock = function() return now end
patch.is_client = function() return false end
patch.start()
workshop.start()
local Workshop = game.root.Workshop
tables.allow_writes(true)
tables.reset()

fake.possess(nil)
rawset(fake.controller, "__class", fake.class("/Script/Icarus.IcarusPlayerController", fake.class("/Script/CoreUObject.Object")))
fake.controller.PlayerState = fake.object("PlayerState", {})

local function frames(count)
    for _ = 1, count or 1 do
        now = now + 1 / 60
        tables.next_frame()
        sched.step()
    end
end

-- Mods as the loader has them: an id, the scope its code runs under, and whether it is running.
local loaded, load_order = {}, {}
rawset(Wax, "mods", { get = function(id) return loaded[id] end, ids = function() return load_order end })
local function mod(id)
    loaded[id] = { id = id, scope = scope.new(id), status = "loaded" }
    local listed = false
    for _, known in ipairs(load_order) do listed = listed or known == id end
    if not listed then load_order[#load_order + 1] = id end
    return loaded[id].scope
end
local function unload(id)
    local gone = loaded[id]
    loaded[id] = nil
    gone.scope:destroy()
end
local function as(owner, fn, ...) return scope.run(owner, fn, ...) end

local function raw(name, row) return tables.row(name, row) end

local function price(item, field)
    local parts = {}
    for at, cost in ipairs(raw("WorkshopItems", item)[field]) do parts[at] = cost.Meta.RowName .. " " .. math.tointeger(cost.Amount) end
    return table.concat(parts, ", ")
end

local function place(node)
    local at = raw("Talents", node).position
    return ("%d,%d"):format(at.X, at.Y)
end

local function parents(node)
    local parts = {}
    for at, parent in ipairs(raw("Talents", node).RequiredTalents) do parts[at] = parent.RowName end
    return table.concat(parts, "|")
end

local function codes(problems)
    local out = {}
    for _, problem in ipairs(problems) do out[problem.Code] = (out[problem.Code] or 0) + 1 end
    return out
end

local function errors() return #guard.errors() end
local function warnings() return log.since(0, { level = "warn", channel = "wax.workshop" }) end

local function clean()
    for _, name in ipairs({ "stale", "grown", "crashes", "misuse", "unknown_names", "sloppy", "silent", "leaks" }) do
        t.eq(tables[name], 0, "the engine counted " .. name)
    end
    t.eq(errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
end

local SUIT, SUIT_ITEM = "Workshop_Envirosuit_1", "Meta_Envirosuit2"

-- ---------------------------------------------------------------- before the writing side starts

t.test("until the writing side starts, game.Workshop only reads", function()
    for _, name in ipairs({ "Node", "Category", "AddCategory", "Define", "Reset" }) do
        t.raises(function() return Workshop[name] end, name .. " is not a member of game.Workshop")
    end
    t.eq(patch.OFF.talents, nil, "data.patch knows nothing of the store yet")
end)

local rows = Wax.import("world.workshop_rows")
rows.start()
local A, B = mod("ModA"), mod("ModB")

t.test("once it has started the calls are members, and data.patch knows how a row of the store is switched off", function()
    local names = table.concat(getmetatable(Workshop).__names(), " ")
    for _, name in ipairs({ "Node", "Category", "AddCategory", "Define", "Reset" }) do
        t.eq(type(Workshop[name]), "function", name)
        t.ok(names:find(name, 1, true), name .. " is named")
    end
    t.eq(patch.OFF.talents.TalentTree.RowName, "None", "a node is taken off its tree")
    t.eq(patch.OFF.talentarchetypes.Model.RowName, "None", "a category is taken off the store")
    t.eq(patch.OFF.talenttrees.Archetype.RowName, "None")
    t.ok(patch.OFF.processorrecipes, "what was there stays")
    -- starting again changes nothing and adds no second listener
    local listeners = data.api.Patched.count
    rows.start()
    t.eq(data.api.Patched.count, listeners)
    t.raises(function() Workshop.Other = 1 end, "read-only")
    t.raises(function() return Workshop.Nod end, "Nod is not a member of game.Workshop. Did you mean 'Node'?")
    t.eq(tables.writes, 0)
end)

-- ---------------------------------------------------------------- one node: price, place, parents, line, level

t.test("a price is written in place, in the game's order of currencies, and read again at once", function()
    as(A, function()
        local node = Workshop:Node("workshop_envirosuit_1")
        t.eq(node.Id, SUIT, "as the game spells it")
        t.eq(tostring(node), SUIT)
        t.eq(price(SUIT_ITEM, "ResearchCost"), "Credits 100")
        local writes = tables.writes
        local found = node:Set({ research = { Credits = 101 } })
        t.eq(#found, 0, "nothing to warn about")
        t.eq(price(SUIT_ITEM, "ResearchCost"), "Credits 101", "written before Set returns")
        t.ok(tables.writes > writes and tables.writes <= writes + 2, "one entry was written where it is")
        t.eq(tables.empties, 0, "the list was not made again")
        t.eq(price(SUIT_ITEM, "ReplicationCost"), "Credits 50", "the other price is left alone")
        t.eq(Workshop:GetNode(SUIT).Research.Credits, 101, "game.Workshop reads the new price in the same frame")
        -- two currencies, written in another letter case and order, and a price of nothing
        node:Set({ research = { Exotic1 = 5, credits = 10 }, replicate = {} })
        t.eq(price(SUIT_ITEM, "ResearchCost"), "Credits 10, Exotic1 5")
        t.eq(price(SUIT_ITEM, "ReplicationCost"), "Credits 0", "no price is one entry of nothing, as the game writes it")
        local record = Workshop:GetNode(SUIT)
        t.eq(record.Research.Exotic1, 5)
        t.eq(record.Replicate.Credits, 0)
        -- three currencies are written and warned about
        found = node:Set({ research = { Credits = 1, Exotic1 = 2, Biomass = 3 } })
        t.eq(codes(found)["price-many"], 1)
        t.eq(price(SUIT_ITEM, "ResearchCost"), "Credits 1, Exotic1 2, Biomass 3")
        t.eq(Workshop:Reset(), 2, "two fields are taken back")
    end)
    t.eq(price(SUIT_ITEM, "ResearchCost"), "Credits 100")
    t.eq(price(SUIT_ITEM, "ReplicationCost"), "Credits 50")
    frames(1)
    clean()
end)

t.test("a place is the node's middle, rounded, and what it then lies on is said", function()
    as(A, function()
        local node = Workshop:Node(SUIT)
        t.eq(place(SUIT), "1000,1150")
        local found = node:Set({ at = { 1000.4, 1210 } })
        t.eq(place(SUIT), "1000,1210")
        t.eq(Workshop:GetNode(SUIT).At.Y, 1210)
        t.eq(#found, 0)
        node:Set({ at = { x = 1010, y = 1200 } })
        t.eq(place(SUIT), "1010,1200")
        -- on top of another node of its category: written, with a warning
        local other = nil
        for _, record in ipairs(Workshop:GetNodes("Workshop_Envirosuits")) do
            if record.Id ~= SUIT and not record.Joint then other = other or record end
        end
        found = node:Set({ at = { other.At.X + 10, other.At.Y } })
        t.eq(codes(found).overlap, 1, "it lies on " .. other.Id)
        t.ok(found[1].Text:find(SUIT, 1, true) and found[1].Text:find(other.Id, 1, true), found[1].Text)
        t.eq(found[1].Level, "warning")
        t.eq(place(SUIT), ("%d,%d"):format(other.At.X + 10, other.At.Y))
        found = node:Set({ at = { 1000, 200 } })
        t.eq(codes(found)["off-screen"], 1)
        found = node:Set({ at = { 1000, 100 } })
        t.eq(codes(found)["off-canvas"], 1)
        local writes = tables.writes
        t.raises(function() node:Set({ at = { 1 / 0, 800 } }) end, "No place in the store is further than 1000000 from 0, 0")
        t.raises(function() node:Set({ at = "here" }) end, SUIT .. ": at is the middle of the node")
        t.raises(function() node:Set({ at = { 500 } }) end, "at is the middle of the node")
        t.eq(tables.writes, writes)
        t.eq(node:Reset(), 1)
    end)
    t.eq(place(SUIT), "1000,1150")
    frames(1)
    clean()
end)

t.test("what a node needs: one node, a list of which one is enough, none, and names as the game spells them", function()
    local node_id = "Workshop_Axe_Inaris_Bravo"
    as(A, function()
        local node = Workshop:Node(node_id)
        t.eq(parents(node_id), "Workshop_Axe_Shengong_Reroute")
        t.eq(#node:Set({ needs = "workshop_axe_larkwell" }), 0)
        t.eq(parents(node_id), "Workshop_Axe_Larkwell")
        t.eq(raw("Talents", node_id).RequiredTalents[1].DataTableName, "D_Talents")
        t.eq(Workshop:GetNode(node_id).Needs[1], "Workshop_Axe_Larkwell")
        node:Set({ needs = { "Workshop_Axe_Larkwell", "Workshop_Axe_Printed", "WORKSHOP_AXE_LARKWELL" } })
        t.eq(parents(node_id), "Workshop_Axe_Larkwell|Workshop_Axe_Printed", "a node named twice is one parent")
        node:Set({ needs = { any = "Workshop_Axe_Printed" } })
        t.eq(parents(node_id), "Workshop_Axe_Printed")
        node:Set({ needs = {} })
        t.eq(parents(node_id), "", "no parents")
        -- a parent in another category is written and warned about
        local found = node:Set({ needs = SUIT })
        t.eq(codes(found)["cross-category"], 1)
        t.eq(parents(node_id), SUIT)
        t.eq(node:Reset(), 1)
    end)
    t.eq(parents(node_id), "Workshop_Axe_Shengong_Reroute")
    frames(1)
    clean()
end)

t.test("needs that could never be met are refused, and nothing is written", function()
    local writes = tables.writes
    as(A, function()
        local first = Workshop:Node("Workshop_Axe_Printed")
        t.raises(function() first:Set({ needs = "Workshop_Axe_Printed" }) end, "Workshop_Axe_Printed needs itself, so it can never be bought.")
        local err = t.raises(function() first:Set({ needs = "Workshop_Axe_Shengong_Alpha" }) end, "These nodes wait for each other")
        t.ok(tostring(err):find("workshop_write_test.lua", 1, true), "the error points at the mod's line: " .. tostring(err))
        err = t.raises(function() first:Set({ needs = "Workshop_Axe_Larkwel" }) end,
            "Workshop_Axe_Printed needs \"Workshop_Axe_Larkwel\", and the store has no node of that name.")
        t.ok(tostring(err):find("'Workshop_Axe_Larkwell'", 1, true), "the nearest name is offered: " .. tostring(err))
        t.raises(function() first:Set({ needs = "Stone_Axe" }) end, "the store has no node of that name")
        t.raises(function() first:Set({ needs = 5 }) end, "needs is the row name of a node, a list of names of which one is enough")
        t.raises(function() first:Set({ needs = { "Workshop_Axe_Larkwell", any = "Workshop_Axe_Larkwell" } }) end, "needs is the row name of a node")
        t.raises(function() first:Set({ needs = { 5 } }) end, "needs is the row name of a node")
        t.raises(function() first:Set({ needs = { ane = "Workshop_Axe_Larkwell" } }) end, "needs has no option named 'ane'. Did you mean 'any'?")
        t.raises(function() first:Set({ needs = { flags = "Pet_Companions" } }) end, "the flags a node of the game asks for cannot be changed")
        -- "all of" is a rule the game does not have, and this version keeps none for it
        err = t.raises(function() first:Set({ needs = { all = { "Workshop_Axe_Larkwell", "Workshop_Axe_Inaris_Alpha" } } }) end,
            "Workshop_Axe_Printed needs all of Workshop_Axe_Larkwell and Workshop_Axe_Inaris_Alpha.")
        t.ok(tostring(err):find("needs = { \"Workshop_Axe_Larkwell\", \"Workshop_Axe_Inaris_Alpha\" }", 1, true), tostring(err))
    end)
    t.eq(tables.writes, writes)
    t.eq(#game.root.Data:Changes(), 0)
    clean()
end)

t.test("a line style and a level are written as the game keeps them", function()
    local node_id = "Workshop_Axe_Larkwell"
    as(A, function()
        local node = Workshop:Node(node_id)
        local before = raw("Talents", node_id).DrawMethodOverride
        node:Set({ line = "straight", level = 5 })
        t.eq(raw("Talents", node_id).DrawMethodOverride, 2, "ShortestDistance")
        t.eq(raw("Talents", node_id).RequiredLevel, 5)
        local record = Workshop:GetNode(node_id)
        t.eq(record.Line, "straight")
        t.eq(record.Level, 5)
        node:Set({ line = "none" })
        t.eq(raw("Talents", node_id).DrawMethodOverride, 1)
        -- the level inside needs is the same level, and leaves the parents alone
        node:Set({ needs = { level = 7 } })
        t.eq(raw("Talents", node_id).RequiredLevel, 7)
        t.eq(parents(node_id), "Workshop_Axe_Shengong_Charlie")
        node:Set({ level = 7, needs = { level = 7, any = "Workshop_Axe_Printed" } })
        t.eq(parents(node_id), "Workshop_Axe_Printed")
        t.raises(function() node:Set({ level = 3, needs = { level = 4 } }) end, "level is given twice, as 3 and inside needs as 4")
        t.raises(function() node:Set({ line = "strait" }) end, "Did you mean 'straight'?")
        t.raises(function() node:Set({ level = -1 }) end, node_id .. ": level is a whole number of 0 or more.")
        t.raises(function() node:Set({ level = 2.5 }) end, "level is a whole number of 0 or more.")
        t.eq(node:Reset(), 3)
        t.eq(raw("Talents", node_id).DrawMethodOverride, before)
    end)
    t.eq(raw("Talents", node_id).RequiredLevel, 0)
    -- a straight line that would run over another node is said
    as(A, function()
        local found = Workshop:Node("Workshop_Axe_Shengong_Echo"):Set({ needs = "Workshop_Axe_Larkwell", line = "straight", at = { 4000, 450 } })
        t.eq(codes(found)["line-through"], 2, "two nodes lie between them")
        t.ok(found[1].Text:find("The straight line from Workshop_Axe_Larkwell to Workshop_Axe_Shengong_Echo runs through", 1, true), found[1].Text)
        t.eq(Workshop:Reset(), 3)
    end)
    frames(1)
    clean()
end)

t.test("everything is checked before anything is written, and a refused write takes back what the call wrote before it", function()
    local writes = tables.writes
    as(A, function()
        local node = Workshop:Node(SUIT)
        t.raises(function() node:Set({ at = { 700, 700 }, research = { Gold = 1 } }) end, "the research price names the currency \"Gold\"")
        t.raises(function() node:Set({ at = { 700, 700 }, line = "bent" }) end, "line is")
        t.eq(tables.writes, writes, "the place was not written")
        -- the engine refuses the price after the place went in
        tables.break_write("WorkshopItems", SUIT_ITEM, "ResearchCost", 0, true)
        local err = t.raises(function() node:Set({ at = { 700, 700 }, research = { Credits = 7 } }) end, SUIT .. " was not changed: ")
        tables.break_write("WorkshopItems", SUIT_ITEM, "ResearchCost", nil)
        t.ok(tostring(err):find("ResearchCost", 1, true), tostring(err))
        t.eq(place(SUIT), "1000,1150", "the place is back")
        t.eq(price(SUIT_ITEM, "ResearchCost"), "Credits 100")
        t.eq(#game.root.Data:Changes(), 0, "and nothing counts as changed")
        -- what the mod had set before such a call is what comes back, not the game's own value
        node:Set({ at = { 900, 900 } })
        tables.break_write("WorkshopItems", SUIT_ITEM, "ResearchCost", 0, true)
        t.raises(function() node:Set({ at = { 700, 700 }, research = { Credits = 7 } }) end, "was not changed")
        tables.break_write("WorkshopItems", SUIT_ITEM, "ResearchCost", nil)
        t.eq(place(SUIT), "900,900")
        t.eq(Workshop:Reset(), 1)
    end)
    t.eq(place(SUIT), "1000,1150")
    frames(1)
    t.eq(tables.crashes, 0)
    t.eq(errors(), 0)
end)

t.test("a wrong call says what the right one is", function()
    local writes = tables.writes
    as(A, function()
        local err = t.raises(function() Workshop:Node("Workshop_Envirosuit_11") end, "the store has no node named 'Workshop_Envirosuit_11'.")
        t.ok(tostring(err):find("Did you mean", 1, true) and tostring(err):find("workshop_write_test.lua", 1, true), tostring(err))
        t.raises(function() Workshop:Node("Stone_Axe") end, "the store has no node named 'Stone_Axe'")
        t.raises(function() Workshop:Node(5) end, "game.Workshop:Node expects a node's row name such as \"Workshop_Axe_Printed\", got number")
        t.raises(function() Workshop:Node("") end, "got an empty text")
        local node = Workshop:Node(SUIT)
        t.raises(function() node:Set() end, "Set expects a table of what to change, such as { research = { Credits = 10 } }, got nil")
        t.raises(function() node:Set({}) end, "Set was given nothing to change. It takes research, replicate, needs, at, line and level")
        t.raises(function() node:Set({ reserch = { Credits = 1 } }) end, "Set has no option named 'reserch'. Did you mean 'research'?")
        t.raises(function() node:Set({ Research = { Credits = 1 } }) end, "Did you mean 'research'?")
        t.raises(function() node.Set({ research = { Credits = 1 } }) end, "Set is called with a colon, as in node:Set({ research = { Credits = 10 } })")
        t.raises(function() return node.Sett end, "Sett is not a member of a node of the store. Did you mean 'Set'?")
        t.raises(function() node.Id = "Other" end, "Id cannot be assigned because a node of the store is read-only")
        t.eq(table.concat(getmetatable(node).__names(), " "), "Id Set Hide Show Reset")
        t.raises(function() node:Set({ research = 50 }) end, SUIT .. ": research is a price such as { Credits = 50 }")
        t.raises(function() node:Set({ research = { Credits = -1 } }) end, "A price cannot be below 0.")
        t.raises(function() node:Set({ research = { Credits = 1.5 } }) end, "A price is a whole number, such as 50.")
        t.raises(function() node:Set({ research = { Credits = "50" } }) end, "the research price in Credits is \"50\"")
        t.raises(function() node:Set({ replicate = { Credits = 2 ^ 31 } }) end, "The largest price the game can keep is 2147483647.")
        err = t.raises(function() node:Set({ research = { Credit = 5 } }) end, "D_MetaCurrency has no row of that name.")
        t.ok(tostring(err):find("'Credits'", 1, true), tostring(err))
        -- a joint sells nothing
        t.raises(function() Workshop:Node("Workshop_Axe_Shengong_Reroute"):Set({ research = { Credits = 1 } }) end,
            "Workshop_Axe_Shengong_Reroute sells nothing, so it has no price to change")
        t.raises(function() Workshop:Category("Workshop_Axs") end, "the store has no category named 'Workshop_Axs'. Did you mean 'Workshop_Axes'")
        t.raises(function() return Workshop:Category("Workshop_Axes").Arange end, "Arange is not a member of a category of the store. Did you mean 'Arrange'?")
    end)
    -- a change belongs to a mod
    t.raises(function() Workshop:Node(SUIT):Set({ research = { Credits = 1 } }) end,
        "a change of the store belongs to a mod, which puts it back when it unloads. This code runs outside any mod")
    t.raises(function() Workshop:Reset() end, "belongs to a mod")
    t.raises(function() Workshop:Category("Workshop_Axes"):Arrange("ring") end, "belongs to a mod")
    t.eq(tables.writes, writes)
    t.eq(#game.root.Data:Changes(), 0)
    clean()
end)

-- ---------------------------------------------------------------- a category in a shape

local AXES = "Workshop_Axes"

-- The places a shape gives the nodes of a category, as Arrange hands them to the shapes.
local function expected(category, shape, options)
    local records, inside, items = Workshop:GetNodes(category), {}, {}
    for _, record in ipairs(records) do inside[fold(record.Id)] = true end
    for at, record in ipairs(records) do
        local needs = {}
        for _, parent in ipairs(record.Needs) do
            if inside[fold(parent)] then needs[#needs + 1] = fold(parent) end
        end
        items[at] = { id = fold(record.Id), needs = needs }
    end
    return records, layout.place(shape, items, options)
end

t.test("Arrange lays a category out in a shape and writes the places that differ", function()
    local before = {}
    for _, record in ipairs(Workshop:GetNodes(AXES)) do before[record.Id] = place(record.Id) end
    as(A, function()
        local category = Workshop:Category("workshop_axes")
        t.eq(category.Id, AXES)
        t.eq(table.concat(getmetatable(category).__names(), " "), "Id Add Arrange")
        local records, places = expected(AXES, "ring", { center = { 2000, 850 }, radius = 700 })
        local found = category:Arrange("ring", { center = { 2000, 850 }, radius = 700 })
        t.eq(#records, 11)
        for at, record in ipairs(records) do
            t.eq(place(record.Id), ("%d,%d"):format(places[at].x, places[at].y), record.Id)
        end
        t.eq(type(found), "table")
        for _, problem in ipairs(found) do t.eq(problem.Level, "warning") end
        t.eq(#game.root.Data:Table("Talents"):Changes(), 11, "each node's place is a change of this mod")
        -- the same shape again writes nothing
        local writes = tables.writes
        category:Arrange("ring", { center = { 2000, 850 }, radius = 700 })
        t.eq(tables.writes, writes)
        -- a tree goes by what each node needs: a node stands one step right of the furthest node it needs
        records, places = expected(AXES, "tree")
        category:Arrange("tree")
        local by = {}
        for at, record in ipairs(records) do by[record.Id] = places[at] end
        t.eq(place("Workshop_Axe_Printed"), "500,850")
        t.ok(by.Workshop_Axe_Shengong_Charlie.x > by.Workshop_Axe_Shengong_Alpha.x, "a child is right of its parent")
        t.ok(by.Workshop_Axe_Shengong_Echo.x > by.Workshop_Axe_Shengong_Reroute.x, "a joint is a node of the tree")
        for at, record in ipairs(records) do t.eq(place(record.Id), ("%d,%d"):format(places[at].x, places[at].y), record.Id) end
        -- a function of the mod's own gets the row names
        local seen = {}
        category:Arrange(function(index, id, count)
            seen[index] = id .. " of " .. count
            return 400 + index * 400, 850
        end)
        t.eq(seen[2], "Workshop_Axe_Printed of 11")
        t.eq(place("Workshop_Axe_Printed"), "1200,850")
        -- nodes put on top of each other are written and warned about
        found = category:Arrange("line", { from = { 500, 850 }, step = 100 })
        t.ok(codes(found).overlap >= 10, "ten neighbours overlap")
        writes = tables.writes
        t.raises(function() category:Arrange("rnig") end, "the store has no shape named 'rnig'. Did you mean 'ring'?")
        t.raises(function() category:Arrange("ring", { radios = 5 }) end, "the shape \"ring\" has no option named 'radios'. Did you mean 'radius'?")
        t.raises(function() category:Arrange("ring", "wide") end, "the options of a shape are a table")
        t.raises(function() category.Arrange("ring") end, "Arrange is called with a colon, as in category:Arrange(\"ring\")")
        t.eq(tables.writes, writes, "a wrong shape writes nothing")
        t.eq(Workshop:Reset(), 11)
    end)
    for id, was in pairs(before) do t.eq(place(id), was, id .. " is back") end
    frames(1)
    clean()
end)

t.test("which rows are the nodes of a category is kept across changes of places, and read again when it may have changed", function()
    local talents = game.root.Data:Table("Talents")
    as(A, function() Workshop:Category(AXES):Arrange("grid") end)
    frames(1)
    t.eq(rows.stats().categories_kept, 1)
    -- a place does not change which category a node is in: the next change asks for no row of another category
    tables.asked = {}
    as(A, function() Workshop:Node("Workshop_Axe_Larkwell"):Set({ at = { 3000, 300 } }) end)
    local others = 0
    for name in pairs(tables.asked.Talents or {}) do
        if not name:lower():find("^workshop_axe") then others = others + 1 end
    end
    t.eq(others, 0, "no row outside the category was asked for")
    frames(1)
    t.eq(rows.stats().categories_kept, 1)
    -- a node that is taken off its tree by another mod, through game.Data, is no longer placed
    as(B, function() talents:Set("Workshop_Axe_Larkwell", "TalentTree", { RowName = "None" }) end)
    frames(1)
    t.eq(rows.stats().categories_kept, 0, "a node changed tree")
    local larkwell = place("Workshop_Axe_Larkwell")
    as(A, function() Workshop:Category(AXES):Arrange("line", { from = { 500, 600 }, step = 400 }) end)
    t.eq(place("Workshop_Axe_Larkwell"), larkwell, "it is in no category now")
    t.eq(#game.root.Data:Table("Talents"):Changes(), 12, "ten places, and the two changes of the node that left")
    as(B, function() talents:Reset() end)
    frames(1)
    -- everything game.Data read is dropped: nothing kept is trusted
    as(A, function() Workshop:Category(AXES):Arrange("grid") end)
    frames(1)
    t.eq(rows.stats().categories_kept, 1)
    game.root.Data:Flush()
    frames(1)
    t.eq(rows.stats().categories_kept, 0)
    as(A, function() t.eq(Workshop:Reset(), 11) end)
    frames(1)
    t.eq(#game.root.Data:Changes(), 0)
    clean()
end)

t.test("a Reset and the end of its frame leave in place what was read of the store", function()
    as(A, function() Workshop:Node("Workshop_Axe_Larkwell"):Set({ at = { 3000, 300 } }) end)
    frames(1)
    as(A, function() t.eq(Workshop:Reset(), 1) end)
    frames(1)
    tables.asked = {}
    as(A, function() Workshop:Node("Workshop_Axe_Larkwell"):Set({ at = { 3000, 300 } }) end)
    local others = 0
    for name in pairs(tables.asked.Talents or {}) do
        if not name:lower():find("^workshop_axe") then others = others + 1 end
    end
    t.eq(others, 0, "no row outside the category was asked for")
    as(A, function() t.eq(Workshop:Reset(), 1) end)
    frames(1)
    t.eq(#game.root.Data:Changes(), 0)
    clean()
end)

-- ---------------------------------------------------------------- whose change it is

t.test("Reset takes back what this mod changed through the store, and nothing else of it or of others", function()
    local level = raw("Talents", "Workshop_Axe_Larkwell").RequiredLevel
    as(A, function()
        Workshop:Node(SUIT):Set({ at = { 1100, 1150 }, research = { Credits = 5 } })
        Workshop:Node("Workshop_Axe_Larkwell"):Set({ level = 9 })
        -- a change the same mod made through game.Data is not the store's to take back
        game.root.Data:Table("Talents"):Set("Workshop_Axe_Printed", "RequiredLevel", 3)
    end)
    as(B, function()
        Workshop:Node("Workshop_Axe_Inaris_Alpha"):Set({ level = 4 })
        t.eq(Workshop:Node(SUIT):Reset(), 0, "ModB changed nothing of that node")
    end)
    as(A, function()
        t.eq(Workshop:Node(SUIT):Reset(), 2, "the place and the price of one node")
        t.eq(place(SUIT), "1000,1150")
        t.eq(price(SUIT_ITEM, "ResearchCost"), "Credits 100")
        t.eq(raw("Talents", "Workshop_Axe_Larkwell").RequiredLevel, 9, "another node stays")
        t.eq(Workshop:Reset(), 1)
        t.eq(Workshop:Reset(), 0, "nothing is left")
    end)
    t.eq(raw("Talents", "Workshop_Axe_Larkwell").RequiredLevel, level)
    t.eq(raw("Talents", "Workshop_Axe_Printed").RequiredLevel, 3, "what went through game.Data stays")
    t.eq(raw("Talents", "Workshop_Axe_Inaris_Alpha").RequiredLevel, 4, "and so does another mod's change")
    as(A, function() game.root.Data:Table("Talents"):Reset("Workshop_Axe_Printed") end)
    as(B, function() t.eq(Workshop:Reset(), 1) end)
    t.eq(#game.root.Data:Changes(), 0)
    frames(1)
    clean()
end)

t.test("when a mod unloads everything it changed in the store is put back, and two mods on one price stand in load order", function()
    local C1 = mod("ModC")
    as(C1, function()
        Workshop:Node(SUIT):Set({ at = { 1300, 900 }, research = { Credits = 1, Exotic1 = 2 }, line = "straight" })
        Workshop:Category(AXES):Arrange("grid")
    end)
    as(A, function() Workshop:Node(SUIT):Set({ research = { Credits = 60 } }) end)
    t.eq(price(SUIT_ITEM, "ResearchCost"), "Credits 1, Exotic1 2", "ModC loads after ModA, so its price shows")
    t.eq(#game.root.Data:Conflicts(), 1, "and game.Data lists the field as a conflict")
    unload("ModC")
    frames(2)
    t.eq(price(SUIT_ITEM, "ResearchCost"), "Credits 60", "ModA's price shows once ModC is gone")
    t.eq(place(SUIT), "1000,1150")
    t.eq(place("Workshop_Axe_Shengong_Alpha"), "1000,1150")
    t.eq(place("Workshop_Axe_Printed"), "500,800")
    for _, change in ipairs(game.root.Data:Changes()) do t.eq(change.By, "ModA", change.Row .. "." .. tostring(change.Field)) end
    as(A, function() t.eq(Workshop:Reset(), 1) end)
    t.eq(price(SUIT_ITEM, "ResearchCost"), "Credits 100")
    t.eq(#game.root.Data:Changes(), 0)
    frames(1)
    clean()
end)

-- ---------------------------------------------------------------- the store's screen

local screen = { forced = 0, calls = {}, graphs = {}, children = 0 }

local function widget_for(row)
    local seen = { row = row }
    seen.widget = fake.object("UMG_Talent_Workshop_C", {
        Talent = { RowName = FName(row) },
        -- the node's own copies of its row and its store item
        OnTalentSet = function()
            local node = raw("Talents", row)
            local item = node and raw("WorkshopItems", node.ExtraData.RowName)
            seen.research = item and price(node.ExtraData.RowName, "ResearchCost") or nil
            seen.size = node and node.Size.X
            screen.calls[#screen.calls + 1] = "set " .. row
        end,
        -- its place from the live row
        RefreshState = function()
            seen.slot = place(row)
            screen.calls[#screen.calls + 1] = "refresh " .. row
        end,
    })
    return seen
end

-- A store's screen as the game builds it for a player state: a graph for each category, a widget for each node.
local function new_store(reversed)
    local made = { objects = {}, widgets = {} }
    local function keep(object)
        made.objects[#made.objects + 1] = object
        return object
    end
    local graphs = {}
    for _, category in ipairs(Workshop:GetCategories()) do
        local children = {}
        for _, node in ipairs(Workshop:GetNodes(category.Id)) do
            local seen = widget_for(node.Id)
            keep(seen.widget)
            made.widgets[node.Id] = seen
            children[#children + 1] = seen.widget
        end
        local canvas = keep(fake.object("CanvasPanel", {
            GetChildrenCount = function() return #children end,
            GetChildAt = function(_, at)
                screen.children = screen.children + 1
                return children[at + 1]
            end,
        }))
        local tree = keep(fake.object("UMG_TalentTree_C", { Canvas = canvas }))
        graphs[#graphs + 1] = keep(fake.object("UMG_TalentGraph_C", { TalentTreeWidgets = keep(fake.array({ tree })) }))
    end
    if reversed then
        for at = 1, #graphs // 2 do graphs[at], graphs[#graphs + 1 - at] = graphs[#graphs + 1 - at], graphs[at] end
    end
    local switcher = keep(fake.object("WidgetSwitcher", {
        GetChildrenCount = function() return #graphs end,
        GetChildAt = function(_, at)
            screen.graphs[#screen.graphs + 1] = at
            return graphs[at + 1]
        end,
    }))
    local view = keep(fake.object("UMG_TalentView_Workshop_C", { GraphWidgetSwitcher = switcher }))
    local model = keep(fake.object("WorkshopTalentModel", {}))
    made.component = keep(fake.object("WorkshopTalentController", { Model = model, View = view,
        BP_ForceRefresh = function() screen.forced = screen.forced + 1 end }))
    made.state = keep(fake.object("BP_IcarusPlayerState_C", { WorkshopTalentController = made.component }))
    fake.controller.PlayerState = made.state
    return made
end

local function quiet()
    screen.forced, screen.calls, screen.graphs, screen.children = 0, {}, {}, 0
end

t.test("with no store, as at the title screen, a change costs no call and nothing waits", function()
    quiet()
    as(A, function() Workshop:Node(SUIT):Set({ research = { Credits = 3 } }) end)
    frames(3)
    t.eq(screen.forced, 0)
    t.eq(rows.stats().waiting, 0)
    t.eq(sched.Frame.count, 0, "nothing runs each frame")
    as(A, function() Workshop:Reset() end)
    frames(2)
    clean()
end)

local player = new_store()

t.test("after a change the store is asked to refresh, and the changed node reads its row and its item again", function()
    quiet()
    local suit = player.widgets[SUIT]
    as(A, function() Workshop:Node(SUIT):Set({ research = { Credits = 101 }, at = { 1000, 1210 } }) end)
    t.eq(#screen.calls, 0, "the screen is brought up to date when the frame ends")
    frames(1)
    t.eq(screen.forced, 1, "the game's own refresh is asked once")
    t.eq(table.concat(screen.calls, ", "), "set " .. SUIT .. ", refresh " .. SUIT, "the node alone, its copies first and then its place")
    t.eq(suit.research, "Credits 101", "the price the node keeps for its own check")
    t.eq(suit.slot, "1000,1210")
    t.eq(table.concat(screen.graphs, " "), "0", "only the graph of its category was looked through")
    t.ok(screen.children <= 20, "and no widget of another category was asked for (" .. screen.children .. ")")
    frames(30)
    t.eq(#screen.calls, 2, "once: the node read its new price when it read its new place")
    t.eq(sched.Frame.count, 0, "nothing is left running each frame")
    t.eq(rows.stats().waiting, 0)
    -- the same again writes nothing, so nothing is refreshed
    quiet()
    as(A, function() Workshop:Node(SUIT):Set({ research = { Credits = 101 } }) end)
    frames(2)
    t.eq(#screen.calls, 0)
    t.eq(screen.forced, 0)
    -- taking it back is a write as well
    as(A, function() Workshop:Reset() end)
    frames(1)
    t.eq(suit.research, "Credits 100")
    t.eq(suit.slot, "1000,1150")
    t.eq(screen.forced, 1)
    clean()
end)

t.test("a write that did not come through the store reaches the node too, and a table that is not the store's reaches nothing", function()
    quiet()
    local chicken = player.widgets.Workshop_Creature_Chicken
    as(B, function()
        -- the store item of a node nobody changed through the store: which node sells it has to be found
        local found = game.root.Data:Table("WorkshopItems")
        found:Change("Meta_Chicken", "ResearchCost", function(list)
            list[1].Amount = 499
        end)
    end)
    for _ = 1, 40 do
        if chicken.research then break end
        frames(1)
    end
    t.eq(chicken.research, "Credits 499, Exotic1 250")
    t.eq(table.concat(screen.calls, ", "), "set Workshop_Creature_Chicken, refresh Workshop_Creature_Chicken")
    quiet()
    as(B, function()
        -- a talent that is no node of the store, and a table the store does not use
        game.root.Data:Table("Talents"):Set("Stone_Axe", "RequiredLevel", 2)
    end)
    frames(2)
    t.eq(#screen.calls, 0)
    t.eq(screen.forced, 0, "the store is not asked to refresh for a row that is not its own")
    unload("ModB")
    frames(3)
    t.eq(chicken.research, "Credits 500, Exotic1 250", "the put-back of an unloaded mod is a write like any other")
    B = mod("ModB")
    t.eq(#game.root.Data:Changes(), 0)
    clean()
end)

t.test("every node that sells a changed store item follows, once the store was read for who sells what", function()
    local other = "Workshop_Envirosuit_3"
    as(B, function()
        -- a second node sells the same store item, which no node of the game's own store does
        game.root.Data:Table("Talents"):Set(other, "ExtraData", { RowName = SUIT_ITEM, DataTableName = "D_WorkshopItems" })
    end)
    frames(2)
    quiet()
    as(A, function() Workshop:Node(SUIT):Set({ research = { Credits = 77 } }) end)
    t.eq(Workshop:GetNode(other).Research.Credits, 77, "game.Workshop reads the new price for the other node in the same frame")
    frames(1)
    t.eq(#screen.calls, 0, "who sells the item is read from the store first, a slice a frame")
    for _ = 1, 60 do
        if #screen.calls >= 4 then break end
        frames(1)
    end
    table.sort(screen.calls)
    t.eq(table.concat(screen.calls, ", "), "refresh " .. SUIT .. ", refresh " .. other .. ", set " .. SUIT .. ", set " .. other)
    t.eq(player.widgets[other].research, "Credits 77")
    t.eq(player.widgets[SUIT].research, "Credits 77")
    frames(30)
    t.eq(#screen.calls, 4, "each of them once")
    -- from then on it is known, and both follow when the frame ends
    quiet()
    as(A, function() Workshop:Node(SUIT):Set({ research = { Credits = 78 } }) end)
    frames(1)
    t.eq(#screen.calls, 4)
    t.eq(player.widgets[other].research, "Credits 78")
    as(A, function() Workshop:Reset() end)
    unload("ModB")
    frames(3)
    B = mod("ModB")
    t.eq(player.widgets[other].research, price("Meta_Envirosuit4", "ResearchCost"), "the node sells its own item again and shows its price")
    -- who sells what changed with that, so the store is read once more before the first node follows its price back
    frames(30)
    t.eq(player.widgets[SUIT].research, "Credits 100")
    t.eq(rows.stats().waiting, 0)
    t.eq(#game.root.Data:Changes(), 0)
    clean()
end)

t.test("many nodes are brought up to date a few a frame, and each one once", function()
    quiet()
    local budget = rows.BUDGET
    rows.BUDGET = 0
    as(A, function() Workshop:Category(AXES):Arrange("ring", { center = { 2000, 850 }, radius = 700 }) end)
    frames(1)
    t.eq(#screen.calls, 2, "with no time to spare, one node a frame")
    frames(5)
    t.eq(#screen.calls, 12)
    frames(20)
    t.eq(#screen.calls, 22, "all eleven, and then it stops")
    t.eq(screen.forced, 1)
    local times = {}
    for _, call in ipairs(screen.calls) do times[call] = (times[call] or 0) + 1 end
    for call, count in pairs(times) do t.eq(count, 1, call) end
    for id, seen in pairs(player.widgets) do
        if seen.slot then t.eq(seen.slot, place(id), id .. " shows where its row says") end
    end
    t.eq(sched.Frame.count, 0)
    rows.BUDGET = budget
    quiet()
    as(A, function() Workshop:Reset() end)
    frames(2)
    t.eq(#screen.calls, 22, "with time to spare, all of them in one frame")
    t.eq(player.widgets.Workshop_Axe_Printed.slot, "500,800")
    clean()
end)

t.test("a node whose widget is not where its category should be is found once, and looked for there the next time", function()
    local old = player
    player = new_store(true)
    for _, object in ipairs(old.objects) do rawset(object, "__freed", true) end
    game.root.MapChanged:Fire("Mirror")
    quiet()
    as(A, function() Workshop:Node(SUIT):Set({ at = { 1000, 1300 } }) end)
    frames(3)
    t.eq(player.widgets[SUIT].slot, "1000,1300")
    t.eq(#screen.graphs, 23, "every graph was looked through, the one it should be in first")
    t.eq(screen.graphs[1], 0)
    quiet()
    as(A, function() Workshop:Node(SUIT):Set({ at = { 1000, 1350 } }) end)
    frames(2)
    t.eq(table.concat(screen.graphs, " "), "22", "the second time only the graph it was found in")
    as(A, function() Workshop:Reset() end)
    frames(2)
    t.eq(fake.dead_touches, 0, fake.dead_where)
    clean()
end)

t.test("after a change of map nothing of the old screen is touched, and what waited is dropped", function()
    local old = player
    quiet()
    as(A, function() Workshop:Node(SUIT):Set({ research = { Credits = 44 } }) end)
    -- the map changes before the frame ends: the old widgets are freed, and the new ones were built from the rows as they are
    player = new_store()
    for _, object in ipairs(old.objects) do rawset(object, "__freed", true) end
    game.root.MapChanged:Fire("Next")
    frames(3)
    t.eq(fake.dead_touches, 0, fake.dead_where)
    t.eq(player.widgets[SUIT].research, "Credits 44", "the new screen's node was brought up to date")
    quiet()
    as(A, function() Workshop:Node(SUIT):Set({ research = { Credits = 45 } }) end)
    frames(1)
    t.eq(table.concat(screen.graphs, " "), "0", "what was learned of the old screen is forgotten")
    t.eq(player.widgets[SUIT].research, "Credits 45")
    -- a map change in the middle of a long refresh
    local budget = rows.BUDGET
    rows.BUDGET = 0
    as(A, function() Workshop:Category(AXES):Arrange("grid") end)
    frames(2)
    old, player = player, new_store()
    for _, object in ipairs(old.objects) do rawset(object, "__freed", true) end
    game.root.MapChanged:Fire("Third")
    frames(30)
    rows.BUDGET = budget
    t.eq(fake.dead_touches, 0, fake.dead_where)
    t.eq(sched.Frame.count, 0)
    as(A, function() Workshop:Reset() end)
    frames(2)
    t.eq(#warnings(), 0, warnings()[1] and warnings()[1].message or "")
    clean()
end)

t.test("a node without a widget is counted and skipped, and a call the game no longer answers is logged once", function()
    quiet()
    local missing = rows.stats().missing
    -- this player's screen has no widget for one node, as for a row added after the screen was built
    local seen = player.widgets.Workshop_Axe_Larkwell
    rawset(seen.widget, "__props", { Talent = { RowName = FName("Somebody_Else") }, OnTalentSet = function() end, RefreshState = function() end })
    as(A, function() Workshop:Node("Workshop_Axe_Larkwell"):Set({ level = 2 }) end)
    frames(30)
    t.eq(rows.stats().missing, missing + 1)
    t.eq(rows.stats().waiting, 0)
    t.eq(sched.Frame.count, 0)
    t.eq(#warnings(), 0)
    -- the refresh the game is asked for raises
    local props = rawget(player.component, "__props")
    local refresh = props.BP_ForceRefresh
    props.BP_ForceRefresh = function() error("no such function") end
    as(A, function() Workshop:Node(SUIT):Set({ level = 1 }) end)
    frames(3)
    as(A, function() Workshop:Node(SUIT):Set({ level = 2 }) end)
    frames(3)
    props.BP_ForceRefresh = refresh
    local logged = warnings()
    t.eq(#logged, 1, "logged once")
    t.ok(logged[1].message:find("bringing the store's screen up to date failed", 1, true), logged[1].message)
    t.eq(raw("Talents", SUIT).RequiredLevel, 2, "the rows were written all the same")
    t.eq(errors(), 0, "and no error reached the frame loop")
    as(A, function() Workshop:Reset() end)
    frames(2)
    t.eq(rows.stats().waiting, 0)
end)

-- ---------------------------------------------------------------- hiding a node: built, and switched off

t.test("hiding a node is switched off in this version, and takes the node off its tree when it is on", function()
    t.eq(rows.WRITES.hide, false, "off until it is known what a save does with the research of a node in no tree")
    local writes = tables.writes
    as(A, function()
        local node = Workshop:Node("Workshop_Axe_Larkwell")
        t.raises(function() node:Hide() end, "hiding a node of the store is not switched on in this version of Wax")
        t.raises(function() node:Show() end, "hiding a node of the store is not switched on in this version of Wax")
        t.eq(tables.writes, writes)
        rows.WRITES.hide = true
        node:Hide()
        t.eq(raw("Talents", "Workshop_Axe_Larkwell").TalentTree.RowName, "None")
        t.eq(Workshop:GetNode("Workshop_Axe_Larkwell"), nil, "it is no node of the store while it is hidden")
        t.eq(#Workshop:GetNodes(AXES), 10)
        node:Hide()
        t.raises(function() node:Set({ level = 1 }) end, "Workshop_Axe_Larkwell is hidden. Show it before changing it")
        -- the mod that hid it still finds it by name
        local again = Workshop:Node("workshop_axe_larkwell")
        t.eq(again.Id, "Workshop_Axe_Larkwell")
        t.eq(again:Show(), true)
        t.eq(raw("Talents", "Workshop_Axe_Larkwell").TalentTree.RowName, "Workshop_Axes")
        t.eq(again:Show(), false, "it was not hidden any more")
        t.eq(#Workshop:GetNodes(AXES), 11)
        node:Hide()
    end)
    as(B, function() t.raises(function() Workshop:Node("Workshop_Axe_Larkwell") end, "the store has no node named") end)
    unload("ModA")
    frames(2)
    t.eq(raw("Talents", "Workshop_Axe_Larkwell").TalentTree.RowName, "Workshop_Axes", "an unloaded mod's hidden node is back")
    A = mod("ModA")
    rows.WRITES.hide = false
    t.eq(#game.root.Data:Changes(), 0)
    clean()
end)

-- ---------------------------------------------------------------- a described store: new rows

local function described()
    return { categories = { { into = "Workshop_Axes", nodes = {
        { id = "Gold_Axe", gives = "Meta_Axe_Larkwell", research = { Credits = 300, Exotic1 = 20 }, replicate = { Credits = 40 },
            needs = "Workshop_Axe_Larkwell", at = { 4500, 1150 }, line = "straight" },
        { id = "Fire_Pack", gives = { item = "Meta_Campfire_Printed", count = 3 }, research = { Credits = 50 }, needs = { "Gold_Axe" },
            at = { 5000, 1150 } },
        { id = "Dog", gives = "Workshop_Dog_A1", needs = { any = "Fire_Pack", level = 10 }, at = { 5500, 1150 }, free = true },
    } } } }
end

t.test("while data.patch adds no rows, a described store is checked and then refused in plain words", function()
    -- the switch is on since 0.3.6; with it off the refusal has to stay plain
    local rows_were = patch.WRITES.rows
    patch.WRITES.rows = false
    local F = mod("FieldKit")
    local added, writes = tables.rows_added, tables.writes
    as(F, function()
        t.raises(function() Workshop:Define(described()) end, "adding rows to the game's tables is not switched on in this version of Wax")
        -- what is wrong with the description comes first
        local broken = described()
        broken.categories[1].nodes[1].gives = "Meta_Nothing"
        broken.categories[1].nodes[2].research = { Credits = -5 }
        local err = t.raises(function() Workshop:Define(broken) end, "this store cannot be put into the game: Gold_Axe gives \"Meta_Nothing\"")
        t.ok(tostring(err):find("(and 1 more, which game.Workshop:Check lists)", 1, true), tostring(err))
        t.ok(tostring(err):find("workshop_write_test.lua", 1, true), tostring(err))
        t.raises(function() Workshop:Define("store") end, "A store is a table with a list named categories.")
        t.raises(function() Workshop:AddCategory({ id = "Kit", name = "Field Kit" }) end, "a new category is not switched on in this version of Wax")
        t.raises(function() Workshop:AddCategory("Kit") end, "AddCategory expects a table such as { id = \"FieldKit\", name = \"Field Kit\" }, got string")
        t.raises(function() Workshop:AddCategory({ id = "Kit", nam = "Field Kit" }) end, "AddCategory has no option named 'nam'. Did you mean 'name'?")
        t.raises(function() Workshop:Category(AXES):Add({ id = "Gold_Axe", gives = "Meta_Axe_Larkwell" }) end,
            "adding rows to the game's tables is not switched on in this version of Wax")
        t.raises(function() Workshop:Category(AXES):Add("Gold_Axe") end, "Add expects a node such as { id = \"Rope\", gives = \"Meta_Cot_Printed\" }, got string")
        t.eq(Workshop:Reset(), 0)
    end)
    t.eq(tables.rows_added, added)
    t.eq(tables.writes, writes)
    t.eq(#game.root.Data:Changes(), 0)
    unload("FieldKit")
    frames(1)
    clean()
    patch.WRITES.rows = rows_were
end)

t.test("a checked plan is rows and their whole fields, each a copy of a row of the game to start from", function()
    local plan = as(mod("FieldKit"), function() return workshop.plan(described()) end)
    t.eq(plan.ok, true)
    local ops = rows.rows_of(plan)
    local by = {}
    for at, op in ipairs(ops) do by[at] = op.home .. "." .. op.row end
    t.eq(table.concat(by, " "), "WorkshopItems.FieldKit_Gold_Axe Talents.FieldKit_Gold_Axe ItemTemplate.FieldKit_Fire_Pack "
        .. "WorkshopItems.FieldKit_Fire_Pack Talents.FieldKit_Fire_Pack WorkshopItems.FieldKit_Dog Talents.FieldKit_Dog")
    local item, node = ops[1], ops[2]
    t.eq(item.like, "Meta_Envirosuit2", "the store item of the game's first node that sells something")
    t.eq(item.fields.Item.RowName, "Meta_Axe_Larkwell")
    t.eq(item.fields.ResearchCost[1].Meta.RowName .. " " .. item.fields.ResearchCost[1].Amount, "Credits 300")
    t.eq(item.fields.ResearchCost[2].Meta.RowName .. " " .. item.fields.ResearchCost[2].Amount, "Exotic1 20")
    t.eq(item.fields.ResearchCost[1].Meta.DataTableName, "D_MetaCurrency")
    t.eq(node.like, SUIT)
    t.eq(node.fields.ExtraData.RowName .. " " .. node.fields.ExtraData.DataTableName, "FieldKit_Gold_Axe D_WorkshopItems")
    t.eq(node.fields.TalentTree.RowName, "Workshop_Axes")
    t.eq(node.fields.position.X .. "," .. node.fields.position.Y, "4500,1150")
    t.eq(node.fields.Size.X .. "," .. node.fields.Size.Y, "250,250")
    t.eq(node.fields.DrawMethodOverride, 2)
    t.eq(node.fields.TalentType, 0)
    t.eq(node.fields.bDefaultUnlocked, false)
    t.eq(#node.fields.RequiredTalents, 0, "parents are written once every node is there")
    t.eq(node.later.RequiredTalents[1].RowName, "Workshop_Axe_Larkwell")
    t.eq(node.fields.RequiredFlags, nil, "a node without flags leaves that list alone")
    -- an item and a count is a template of its own
    local template = ops[3]
    t.eq(template.fields.ItemStaticData.RowName, "Meta_Campfire_Printed")
    t.eq(template.fields.ItemDynamicData[1].PropertyType .. " " .. template.fields.ItemDynamicData[1].Value, "7 3")
    t.eq(ops[4].fields.Item.RowName, "FieldKit_Fire_Pack")
    t.eq(ops[4].fields.ReplicationCost[1].Meta.RowName .. " " .. ops[4].fields.ReplicationCost[1].Amount, "Credits 0")
    t.eq(ops[5].later.RequiredTalents[1].RowName, "FieldKit_Gold_Axe")
    -- what the game only sells to owners of a DLC keeps that rule: the node starts from one of the game's with one flag
    local dog = ops[7]
    t.eq(#raw("Talents", dog.like).RequiredFlags, 1)
    t.eq(dog.fields.RequiredFlags[1].RowName .. " " .. dog.fields.RequiredFlags[1].DataTableName, "Pet_Companions 3")
    t.eq(dog.fields.RequiredLevel, 10)
    t.eq(dog.fields.bDefaultUnlocked, true)
    -- a new category is a row of the categories and a row of the trees
    local fresh = as(loaded.FieldKit.scope, function()
        return workshop.plan({ categories = { { id = "Kit", name = "Field Kit", level = 5,
            icon = "/Game/Assets/2DArt/UI/Icons/Icon_Hammer.Icon_Hammer", nodes = { { id = "Cot", gives = "Meta_Cot_Printed" } } } } })
    end)
    ops = rows.rows_of(fresh)
    t.eq(ops[1].home .. "." .. ops[1].row .. " like " .. ops[1].like, "TalentArchetypes.FieldKit_Kit like Workshop_Envirosuits")
    t.eq(ops[1].fields.Model.RowName, "Workshop")
    t.eq(ops[1].fields.DisplayName, "Field Kit")
    t.eq(ops[1].fields.Icon, "/Game/Assets/2DArt/UI/Icons/Icon_Hammer.Icon_Hammer")
    t.eq(ops[1].fields.RequiredLevel, 5)
    t.eq(ops[2].home .. "." .. ops[2].row .. " like " .. ops[2].like, "TalentTrees.FieldKit_Kit like Workshop_Envirosuits")
    t.eq(ops[2].fields.Archetype.RowName, "FieldKit_Kit")
    t.eq(ops[4].fields.TalentTree.RowName, "FieldKit_Kit")
    unload("FieldKit")
    frames(1)
    clean()
end)

t.test("with the write path's switch on, a described store is added, read back, left alone when said again, and switched off with its mod", function()
    patch.WRITES.rows = true
    local F = mod("FieldKit")
    local found = as(F, function() return Workshop:Define(described()) end)
    t.eq(codes(found).dlc, 1, "what Check warns about is handed back")
    t.eq(tables.rows_added, 7)
    t.eq(tables.refreshes, 7, "the game's own index was told of each row at once")
    local gold = Workshop:GetNode("FieldKit_Gold_Axe")
    t.eq(gold.Category, AXES)
    t.eq(gold.Gives, "Meta_Axe_Larkwell")
    t.eq(gold.Research.Credits .. " " .. gold.Research.Exotic1 .. " " .. gold.Replicate.Credits, "300 20 40")
    t.eq(gold.Needs[1], "Workshop_Axe_Larkwell")
    t.eq(gold.At.X .. "," .. gold.At.Y, "4500,1150")
    t.eq(gold.Line, "straight")
    t.eq(gold.Size, 250)
    t.eq(gold.Free, false)
    local pack = Workshop:GetNode("FieldKit_Fire_Pack")
    t.eq(pack.Gives, "FieldKit_Fire_Pack")
    t.eq(pack.Item, "Meta_Campfire_Printed")
    t.eq(raw("ItemTemplate", "FieldKit_Fire_Pack").ItemDynamicData[1].Value, 3)
    t.eq(pack.Needs[1], "FieldKit_Gold_Axe")
    local dog = Workshop:GetNode("FieldKit_Dog")
    t.eq(dog.Flags[1].Id .. " " .. tostring(dog.Flags[1].Kind), "Pet_Companions dlc")
    t.eq(dog.Level, 10)
    t.eq(dog.Free, true)
    t.eq(#Workshop:GetNodes(AXES), 14)
    t.eq(select(2, tables.indexed("Talents", "FieldKit_Gold_Axe")), true, "the game knows the row")
    -- the same store again, from the same code: its own rows are no clash, and nothing is added or written
    local added, writes = tables.rows_added, tables.writes
    t.eq(codes(as(F, function() return Workshop:Define(described()) end)).dlc, 1)
    t.eq(tables.rows_added, added)
    t.eq(tables.writes, writes)
    -- a changed price writes that price
    local cheaper = described()
    cheaper.categories[1].nodes[1].research = { Credits = 250 }
    as(F, function() Workshop:Define(cheaper) end)
    t.eq(tables.rows_added, added)
    t.eq(price("FieldKit_Gold_Axe", "ResearchCost"), "Credits 250")
    -- a node of the mod's own is changed like any other
    as(F, function() Workshop:Node("FieldKit_Gold_Axe"):Set({ at = { 4600, 1150 } }) end)
    t.eq(place("FieldKit_Gold_Axe"), "4600,1150")
    frames(1)
    -- the mod unloads: its nodes are taken off their tree, and the rows stay in the tables
    unload("FieldKit")
    frames(3)
    t.eq(Workshop:GetNode("FieldKit_Gold_Axe"), nil)
    t.eq(#Workshop:GetNodes(AXES), 11)
    t.eq(raw("Talents", "FieldKit_Gold_Axe").TalentTree.RowName, "None")
    t.eq(tables.rows_removed, 0, "no row is taken out while the game runs")
    -- the mod is back and says the same: the rows that are there are used
    F = mod("FieldKit")
    as(F, function() Workshop:Define(described()) end)
    t.eq(tables.rows_added, added, "nothing was added a second time")
    t.eq(#Workshop:GetNodes(AXES), 14)
    t.eq(Workshop:GetNode("FieldKit_Gold_Axe").Research.Credits, 300)
    t.eq(Workshop:GetNode("FieldKit_Gold_Axe").At.X, 4500)
    -- in the very frame they are back, the mod's nodes are nodes of their category
    as(F, function() Workshop:Category(AXES):Arrange("line", { from = { 500, 300 }, step = 400 }) end)
    t.eq(place("FieldKit_Dog"), "5700,300", "the fourteenth node of the category")
    -- Reset switches the rows off as an unload does
    as(F, function() t.ok(Workshop:Reset() >= 3, "the mod's rows were switched off") end)
    t.eq(#Workshop:GetNodes(AXES), 11)
    unload("FieldKit")
    frames(3)
    patch.WRITES.rows = false
    t.eq(tables.crashes, 0)
    t.eq(tables.misuse, 0)
    t.eq(errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
end)

t.test("nodes are added one at a time through a category, and a node that is wrong leaves the store as it was", function()
    patch.WRITES.rows = true
    local K = mod("Kit")
    local added = tables.rows_added
    as(K, function()
        local axes = Workshop:Category(AXES)
        local found = axes:Add({ id = "Gold_Axe", gives = "Meta_Axe_Larkwell", research = { Credits = 300 }, needs = "Workshop_Axe_Larkwell",
            at = { 4500, 1150 } })
        t.eq(#found, 0)
        t.eq(tables.rows_added, added + 2, "a store item and a node")
        axes:Add({ id = "Silver_Axe", gives = "Meta_Axe_Larkwell", needs = "Gold_Axe", at = { 5000, 1150 } })
        t.eq(tables.rows_added, added + 4, "the first node was not added again")
        t.eq(Workshop:GetNode("Kit_Silver_Axe").Needs[1], "Kit_Gold_Axe")
        local writes = tables.writes
        t.raises(function() axes:Add({ id = "Gold_Axe", gives = "Meta_Axe_Larkwell" }) end, "Two nodes have the id Gold_Axe")
        t.raises(function() axes:Add({ id = "Bad", gives = "Meta_Nothing" }) end, "Bad gives \"Meta_Nothing\"")
        t.raises(function() axes:Add({ id = "Both", gives = "Meta_Axe_Larkwell", needs = { all = { "Gold_Axe", "Silver_Axe" } } }) end,
            "Both needs all of Kit_Gold_Axe and Kit_Silver_Axe.")
        t.eq(tables.writes, writes)
        axes:Add({ id = "Third_Axe", gives = "Meta_Axe_Larkwell", needs = "Silver_Axe", at = { 5500, 1150 } })
        t.eq(tables.rows_added, added + 6, "the nodes that were refused are not part of the store")
        t.eq(#Workshop:GetNodes(AXES), 14)
        -- a new category waits for text and pictures in the write path
        t.raises(function() Workshop:AddCategory({ id = "Camp", name = "Camp" }) end, "a new category is not switched on in this version of Wax")
        t.raises(function() Workshop:Define({ categories = { { id = "Camp", name = "Camp", nodes = { { id = "Cot", gives = "Meta_Cot_Printed" } } } } }) end,
            "a new category is not switched on in this version of Wax")
        -- with that switch on too, the write path itself says what it cannot write yet, and nothing is left behind
        rows.WRITES.categories = true
        local rows_before = tables.rows_added
        local err = t.raises(function() Workshop:Define({ categories = { { id = "Camp", name = "Camp", nodes = { { id = "Cot", gives = "Meta_Cot_Printed" } } } } }) end,
            "the store was not added: ")
        t.ok(tostring(err):find("DisplayName is text, which this version of Wax cannot change", 1, true), tostring(err))
        t.eq(tables.rows_added, rows_before)
        local camp = Workshop:AddCategory({ id = "Camp", name = "Camp" })
        t.eq(camp.Id, "Kit_Camp")
        t.raises(function() Workshop:AddCategory({ id = "camp", name = "Again" }) end, "this mod already added a category with the id camp")
        t.raises(function() Workshop:AddCategory({ id = "Bad id", name = "Bad" }) end, "The id 'Bad id' can only use letters, digits and _.")
        t.eq(#camp:Arrange("grid", { columns = 2 }), 0, "a shape for nodes that are still to come")
        t.raises(function() camp:Add({ id = "Cot", gives = "Meta_Cot_Printed" }) end, "DisplayName is text")
        t.eq(tables.rows_added, rows_before)
        rows.WRITES.categories = false
        t.ok(Workshop:Reset() >= 3)
        t.raises(function() camp:Add({ id = "Cot", gives = "Meta_Cot_Printed" }) end,
            "this category is no longer part of the mod's store. Add it again with AddCategory")
    end)
    -- rows are named after the mod whose code adds them
    local console = scope.new("console")
    t.raises(function() as(console, function() Workshop:Define(described()) end) end, "The store does not say which mod it belongs to.")
    local window = scope.new("window", K)
    t.raises(function() as(window, function() Workshop:Define(described()) end) end,
        "the rows of this store are named after Kit, and this code runs as window. A store is added by its own mod's code")
    -- in a game someone else hosts the host would not have the rows
    patch.is_client = function() return true end
    t.raises(function() as(K, function() Workshop:Define(described()) end) end, "the store was not added: a row cannot be added in a game that someone else hosts")
    patch.is_client = function() return false end
    unload("Kit")
    frames(3)
    patch.WRITES.rows = false
    t.eq(#Workshop:GetNodes(AXES), 11)
    t.eq(tables.crashes, 0)
    t.eq(tables.misuse, 0)
    t.eq(errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
end)

-- ---------------------------------------------------------------- what the files say

local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("a")
    file:close()
    return text
end

t.test("nothing in the writing side buys, and all it asks of the store's screen is to read again or be built again", function()
    local spending = { "UnlockNextTalentRank", "Client_ResearchWorkshopItem", "Client_PurchaseWorkshopItem", "PurchaseMetaItem",
        "GrantMetaResource", "ConsumeMetaResource", "ConvertCurrency", "ClientGrantAccountTalents", "SetModelView",
        "ResetTalents", "RefundTalent" }
    local direct = { "AddRow", "RemoveRow", "ImportText", "RefreshConstants", "FindRow", "StaticFindObject" }
    for _, path in ipairs({ "wax/runtime/Scripts/wax/world/workshop_rows.lua", "wax/runtime/Scripts/wax/world/workshop.lua",
        "wax/tests/live/workshop_write.lua" }) do
        local text = read(path)
        for _, word in ipairs(spending) do t.ok(not text:find(word, 1, true), path .. " names " .. word) end
    end
    local text = read("wax/runtime/Scripts/wax/world/workshop_rows.lua")
    -- every row is written through game.Data, which checks it, reads it back and puts it back
    for _, word in ipairs(direct) do t.ok(not text:find(word, 1, true), "workshop_rows.lua names " .. word) end
    local calls = {}
    for call in text:gmatch("[%w_]+:([%u][%w_]*)%(") do calls[call] = true end
    for _, allowed in ipairs({ "Table", "Has", "Add", "Set", "Changes", "Connect", "Disconnect", "IsValid", "GetArrayNum",
        "GetChildrenCount", "GetChildAt", "ToString", "BP_ForceRefresh", "OnTalentSet", "RefreshState",
        -- building the store again when a node joins or leaves it: the game's own set-up, and the new view put on the screen
        "DoesModelContainTalent", "GetParent", "GetActiveWidget", "Setup", "GetAddress", "GetClass", "GetFName", "SetContent",
        "OnClick" }) do
        calls[allowed] = nil
    end
    t.eq(next(calls), nil, "workshop_rows.lua calls " .. tostring(next(calls)) .. " on something")
end)

t.test("every sentence a mod author reads is plain", function()
    local list = wording.unwanted()
    if list then
        t.ok(wording.complete(list), "the owner's list was read whole from " .. wording.SOURCE)
    else
        print("workshop_write: the list of unwanted words is not here, so only the marks were checked")
    end
    local sentences = 0
    for code, text in pairs(rows.TEXT) do
        sentences = sentences + 1
        t.eq(wording.wrong_with(text, list), nil, "the sentence for " .. code)
        for index = 1, #text do t.ok(text:byte(index) < 128, code .. " is plain ASCII") end
    end
    t.ok(sentences >= 30, "the sentences were looked at (" .. sentences .. ")")
    t.eq(rows.TEXT.rows, "adding rows to the game's tables is not switched on in this version of Wax")
end)

t.test("the editor's types and the check against game updates name what the writing side has and uses", function()
    local types = read("wax/types/workshop.lua")
    for _, name in ipairs({ "function Workshop:Node(", "function Workshop:Category(", "function Workshop:AddCategory(", "function Workshop:Define(",
        "function Workshop:Reset(", "function StoreNode:Set(", "function StoreNode:Hide(", "function StoreNode:Show(", "function StoreNode:Reset(",
        "function StoreCategory:Add(", "function StoreCategory:Arrange(" }) do
        t.ok(types:find(name, 1, true), "wax/types/workshop.lua has " .. name)
    end
    local part = nil
    for _, entry in ipairs(assert(loadfile("wax/runtime/data/needs.lua"))()) do
        if entry.id == "workshop-write" then part = entry end
    end
    t.ok(part, "data/needs.lua has a part with the id workshop-write")
    local function names(class, kind, name)
        for _, entry in ipairs(part.classes) do
            if entry.class == class then
                for _, known in ipairs(entry[kind] or {}) do
                    if known == name then return true end
                end
            end
        end
        return false
    end
    t.ok(names("/Script/Icarus.TalentControllerComponent", "functions", "BP_ForceRefresh"))
    t.ok(names("/Script/Icarus.TalentControllerComponent", "properties", "View"))
    t.ok(names("/Script/Icarus.TalentGraphWidget", "properties", "TalentTreeWidgets"))
    t.ok(names("/Script/Icarus.TalentWidget", "properties", "Talent"))
    t.ok(names("/Game/BP/UI/Talents/Base/UMG_Talent_Base.UMG_Talent_Base_C", "functions", "RefreshState"))
    t.ok(names("/Game/BP/UI/Talents/Workshop/UMG_Talent_Workshop.UMG_Talent_Workshop_C", "functions", "OnTalentSet"))
    -- the switches as this version ships them
    local shipped = assert(loadfile("wax/runtime/Scripts/wax/world/workshop_rows.lua"))
    t.ok(shipped, "the module compiles")
    local text = read("wax/runtime/Scripts/wax/world/workshop_rows.lua")
    t.ok(text:find("hide = false", 1, true) and text:find("categories = false", 1, true), "hiding and new categories ship switched off")
end)

t.finish("workshop_write")
