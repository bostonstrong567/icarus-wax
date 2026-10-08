-- Offline tests for game.Data, on a stand-in that raises on what would crash or change the real game.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\data_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local fake = dofile("wax/tests/offline/fake_tables.lua")
local total = fake.sample()

-- one table for the shapes the sample lacks: wide numbers, a struct inside itself, a struct the game cannot find
fake.struct("/Script/Icarus.OddNode", nil, {
    { "Value", "IntProperty" },
    { "Children", "ArrayProperty", inner = "StructProperty", struct = "/Script/Icarus.OddNode" },
})
fake.struct("/Script/Icarus.OddRow", nil, {
    { "Big", "Int64Property" }, { "Small", "ByteProperty" }, { "Wide", "UInt32Property" }, { "Precise", "DoubleProperty" },
    { "Lost", "StructProperty", struct = "/Script/Icarus.NotThere" },
    { "Tree", "StructProperty", struct = "/Script/Icarus.OddNode" },
    { "Icons", "ArrayProperty", inner = "SoftObjectProperty" },
    { "Flags", "ArrayProperty", inner = "BoolProperty" },
    { "Tags", "SetProperty" },
})
fake.table("Odd", "/Script/Icarus.OddRow", {
    One = { Big = 1 << 40, Small = 7, Wide = 4000000000, Precise = 1.5, Icons = { "/Game/A.A", "None", "/Game/C.C" },
            Flags = { true, false, true },
            Tree = { Value = 1, Children = { { Value = 2, Children = { { Value = 3 } } }, { Value = 4 } } } },
}, { "One" })

fake.install()

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)

local sched = Wax.import("core.sched")
local guard = Wax.import("core.guard")
local log = Wax.import("core.log")
local game = Wax.import("engine.game")
local data = Wax.import("data.tables")
local task = sched.task

local now = 100
sched.clock = function() return now end
data.clock = function() return now end
data.start()
local Data = game.root.Data

-- One frame: whatever the engine handed out before must not be used again.
local function frame()
    now = now + 0.016
    fake.next_frame()
    sched.step()
end

-- Runs fn in a task until it ends. Returns what it returned, or raises what it raised.
local function in_task(fn, limit)
    local done, ok, a, b = false, nil, nil, nil
    task.spawn(function()
        ok, a, b = pcall(fn)
        done = true
    end)
    for _ = 1, limit or 5000 do
        if done then break end
        frame()
    end
    if not done then error("the task did not end", 2) end
    if not ok then error(a, 0) end
    return a, b
end

-- What must stay at zero through the whole suite, kept across the resets below.
local MISTAKES = { "stale", "grown", "crashes", "misuse", "unknown_names", "never_reads", "misses" }
local mistakes = {}
local function reset()
    for _, name in ipairs(MISTAKES) do mistakes[name] = (mistakes[name] or 0) + fake[name] end
    fake.reset()
end

local function is_plain(value)
    local kind = type(value)
    if kind == "table" then
        if getmetatable(value) then return false end
        for key, item in pairs(value) do
            if not (is_plain(key) and is_plain(item)) then return false end
        end
        return true
    end
    return kind == "string" or kind == "number" or kind == "boolean"
end

local function count(map)
    local n = 0
    for _ in pairs(map) do n = n + 1 end
    return n
end

local function sums(rows)
    local inputs, outputs, sets = 0, 0, 0
    for _, row in pairs(rows) do
        inputs, outputs, sets = inputs + #row.Inputs, outputs + #row.Outputs, sets + #row.RecipeSets
    end
    return inputs, outputs, sets
end

local function warnings()
    return #log.since(0, { level = "warn", channel = "wax.data" })
end

-- A list of what Changed fired with, and the connection to drop afterwards.
local function listen()
    local fired = {}
    return fired, Data.Changed:Connect(function(name) fired[#fired + 1] = name or "(everything)" end)
end

local RECIPE = { "Inputs.Element.RowName", "Inputs.Count", "Outputs.Element.RowName", "Outputs.Count", "RecipeSets.RowName",
                 "Requirement.RowName", "SessionRequirement.RowName", "RequiredMillijoules", "bForceDisableRecipe" }

t.test("game.Data is on game, and the tables are listed with one look at the engine", function()
    t.eq(Data, data.api)
    t.eq(tostring(Data), "Data")
    t.eq(game.root:GetService("Data"), Data)
    local names = Data:GetTables()
    t.eq(#names, fake.listed())
    t.eq(names[1], "Filler001", "sorted")
    t.ok(Data:Has("ProcessorRecipes") and Data:Has("D_ProcessorRecipes") and Data:Has("processorrecipes"), "any spelling")
    t.eq(Data:Has("ItemsStatic_METATABLE"), false, "meta tables are not listed")
    names[1] = "changed"
    t.eq(Data:GetTables()[1], "Filler001", "the list handed out is a copy")
    t.eq(fake.lists, 1)
    t.eq(fake.finds, 0, "nothing was looked up yet")
end)

local recipes

t.test("a table opens under any spelling of its name and is one object", function()
    recipes = Data:Table("ProcessorRecipes")
    t.eq(Data:Table("D_ProcessorRecipes"), recipes)
    t.eq(Data:Table("d_processorrecipes"), recipes)
    t.eq(recipes.Name, "ProcessorRecipes")
    t.eq(recipes.RowStruct, "ProcessorRecipe")
    t.eq(recipes:Count(), total.recipes)
    t.eq(#recipes:GetNames(), total.recipes)
    t.eq(recipes:GetNames()[12], "MADE_07", "names are spelled as the engine spells them")
    t.eq(tostring(recipes), "DataTable(ProcessorRecipes)")
    t.eq(next(recipes), nil, "the object holds nothing itself")
    t.eq(fake.finds, 1, "one look for the table")
    t.eq(fake.lists, 1)
end)

t.test("an unknown table is an error with a suggestion and asks the engine nothing", function()
    local before = fake.touches
    local err = t.raises(function() Data:Table("ProcessorRecipez") end, "the game has no table named ProcessorRecipez")
    t.ok(tostring(err):find("'ProcessorRecipes'", 1, true), "suggests the right name: " .. tostring(err))
    t.ok(tostring(err):find("data_test.lua", 1, true), "points at the caller: " .. tostring(err))
    t.eq(Data:Has("ProcessorRecipez"), false)
    t.raises(function() Data:Table(12) end, "a table name is a string")
    t.raises(function() Data:Has(nil) end, "a table name is a string")
    t.eq(fake.touches, before)
end)

t.test("a name the list lacks makes it be taken again, at most once every 5 seconds", function()
    local lists = fake.lists
    now = now + 6
    t.eq(Data:Has("Nope"), false)
    t.eq(fake.lists, lists + 1)
    t.eq(Data:Has("Nope"), false)
    t.raises(function() Data:Table("NopeAgain") end, "no table named")
    t.eq(fake.lists, lists + 1, "not again so soon")
    now = now + 6
    t.eq(Data:Has("Nope"), false)
    t.eq(fake.lists, lists + 2)
    t.eq(fake.misses, 0, "StaticFindObject was only given names from the list")
end)

t.test("a short table list is used but not kept", function()
    data.flush()
    fake.short_list(40)
    local lists = fake.lists
    t.eq(#Data:GetTables(), 40)
    t.eq(fake.lists, lists + 1)
    t.eq(Data:Table("Itemable"):Count(), 3, "a table in the short list opens")
    t.eq(Data:Has("Filler200"), false, "one that is not in it is not known yet")
    t.eq(fake.lists, lists + 1)
    fake.short_list(nil)
    now = now + 6
    t.eq(#Data:GetTables(), fake.listed(), "the list is taken again, because the short one was not kept")
    t.eq(fake.lists, lists + 2)
    t.eq(Data:Has("Filler200"), true)
    now = now + 60
    t.eq(#Data:GetTables(), fake.listed())
    t.eq(fake.lists, lists + 2, "a full list is kept")
    t.eq(fake.misses, 0)
end)

local knife

t.test("a row is plain values with defaults filled in, whatever the letter case of its name", function()
    reset()
    data.flush()
    knife = recipes:Row("bone_knife")
    t.eq(knife.Name, "Bone_Knife")
    t.eq(#knife.Inputs, 3)
    t.eq(knife.Inputs[3].Element.RowName, "bone")
    t.eq(knife.Inputs[3].Count, 20)
    t.eq(knife.Inputs[1].Element.DataTableName, "D_ItemsStatic")
    t.eq(knife.Requirement.RowName, "Bone_Knife")
    t.eq(knife.RequiredMillijoules, 3750)
    t.eq(knife.bForceDisableRecipe, false)
    t.eq(knife.ExperienceMultiplier, 1.0)
    t.eq(#knife.QueryInputs, 0, "an empty array is an empty list")
    t.eq(knife.SessionRequirement.RowName, "None")
    t.eq(knife.Outputs[1].Element.RowName, "Bone_Knife")
    t.ok(is_plain(knife), "only strings, numbers, booleans and tables")
    t.eq(recipes:Row("BONE_KNIFE"), knife, "the same table again")
    t.eq(fake.asked.ProcessorRecipes.Bone_Knife, 1, "asked once, in the engine's own spelling")
    t.eq(fake.rows_asked, 1)
end)

t.test("what is never read is left out, and an enum is read only when its path is named", function()
    for _, name in ipairs({ "Refundable", "RefundSteps", "Overrides", "OnCrafted", "Preview", "CachedHardReferences" }) do
        t.eq(knife[name], nil, name)
    end
    t.eq(knife.SessionRequirement.DataTableName, nil, "the enum inside a handle")
    t.eq(knife.Requirement.DataTablePtr, nil, "the weak pointer inside a handle")
    t.eq(fake.enum_reads, 0)
    t.eq(recipes:Row("Bone_Knife", { "Refundable", "SessionRequirement.DataTableName", "RefundSteps" }), knife)
    t.eq(knife.Refundable, 1)
    t.eq(knife.SessionRequirement.DataTableName, 0)
    t.eq(table.concat(knife.RefundSteps, ","), "3,1")
    t.eq(fake.enum_reads, 4)
    local gold = recipes:Row("Gold_Bed", { "SessionRequirement" })
    t.eq(gold.SessionRequirement.RowName, "Art_Deco_Pack")
    t.eq(gold.SessionRequirement.DataTableName, nil, "naming the handle does not name its enum")
    t.eq(fake.enum_reads, 4)
    -- a map and a reference to an object are read when named: data_maps_test.lua has those
    for path, kind in pairs({ OnCrafted = "a MulticastInlineDelegate field",
                              CachedHardReferences = "an array of Object", ["Requirement.DataTablePtr"] = "a WeakObject field" }) do
        local err = t.raises(function() recipes:Row("Bone_Knife", { path }) end, "which game.Data never reads", path)
        t.ok(tostring(err):find(kind, 1, true), path .. " names its kind: " .. tostring(err))
    end
    t.eq(fake.never_reads, 0)
end)

t.test("fields asked for later are read alone and merged into the same table", function()
    local stone = recipes:Row("Stone_Pickaxe", { "RequiredMillijoules" })
    t.eq(stone.RequiredMillijoules, 2500)
    t.eq(stone.Name, "Stone_Pickaxe")
    t.eq(stone.Inputs, nil)
    t.eq(count(stone), 2, "only what was asked for, and the name")
    t.eq(recipes:Row("Stone_Pickaxe", { "Inputs.Count" }), stone)
    local first = stone.Inputs[1]
    t.eq(first.Count, 10)
    t.eq(first.Element, nil)
    t.eq(recipes:Row("Stone_Pickaxe", { "Inputs.Element.RowName" }), stone)
    t.eq(stone.Inputs[1], first, "the element is the same table too")
    t.eq(first.Element.RowName, "Fiber")
    t.eq(first.Element.DataTableName, nil)
    t.eq(first.Count, 10)
    local before = fake.touches
    t.eq(recipes:Row("Stone_Pickaxe", { "RequiredMillijoules", "Inputs.Count" }), stone)
    t.eq(recipes:Row("Stone_Pickaxe", { "Inputs.Count", "Name" }), stone)
    t.eq(fake.touches, before, "what a row holds is not asked for again")
    t.eq(recipes:Row("Stone_Pickaxe"), stone, "no list means every readable field")
    t.eq(first.Element.DataTableName, "D_ItemsStatic")
    t.eq(stone.Outputs[1].Element.RowName, "Stone_Pickaxe")
    t.eq(stone.Requirement.DataTableName, "D_Talents")
    t.eq(stone.ExperienceMultiplier, 1.0)
    t.eq(fake.asked.ProcessorRecipes.Stone_Pickaxe, 4, "one look at the row for each read that needed one")
    before = fake.touches
    t.eq(recipes:Row("Stone_Pickaxe"), stone)
    t.eq(recipes:Row("Stone_Pickaxe", { "Outputs", "Requirement.RowName" }), stone)
    t.eq(fake.touches, before)
end)

t.test("a path goes through structs and arrays, and a wrong one is an error with a suggestion", function()
    local query = Data:Table("TagQueries"):Row("FieldGuide_Hide", { "Query.TagDictionary.TagName", "Query.QueryTokenStream" })
    t.eq(query.Query.TagDictionary[2].TagName, "FieldGuide.BlackList")
    t.eq(table.concat(query.Query.QueryTokenStream, ","), "0,1,5,2,1,6,0,1", "an array of bytes is a list of numbers")
    t.eq(query.Query.UserDescription, nil)
    local resource = recipes:Row("Dough_Bread", { "ResourceInputs.Type.Value", "ResourceInputs.RequiredUnits" }).ResourceInputs[1]
    t.eq(resource.Type.Value, "Water")
    t.eq(resource.RequiredUnits, 100)
    local before = fake.touches
    local err = t.raises(function() recipes:Row("Bone_Knife", { "Input.Count" }) end, "ProcessorRecipe has no field named 'Input'")
    t.ok(tostring(err):find("'Inputs'", 1, true), "suggests Inputs: " .. tostring(err))
    t.ok(tostring(err):find("data_test.lua", 1, true), "points at the caller: " .. tostring(err))
    err = t.raises(function() recipes:Row("Bone_Knife", { "Inputs.Amount" }) end, "CraftingInput has no field named 'Amount'")
    t.ok(tostring(err):find("in 'Inputs.Amount'", 1, true), tostring(err))
    t.raises(function() recipes:Row("Bone_Knife", { "Inputs.Count.More" }) end, "'Inputs.Count' is an Int field, so it has no fields")
    t.raises(function() recipes:Row("Bone_Knife", { 12 }) end, "a field path is a string")
    t.raises(function() recipes:Row("Bone_Knife", "Inputs") end, "the fields are a list of paths")
    t.raises(function() recipes:Row("Bone_Knife", { "" }) end, "a field path cannot be empty")
    t.eq(fake.touches, before, "none of those reached the engine")
end)

t.test("text is a string, a soft reference is its path or nil, and Name is always the row's own name", function()
    local items = Data:Table("Itemable")
    local wood = items:Row("Item_Wood")
    t.eq(wood.DisplayName, "Wood")
    t.eq(wood.Icon, "/Game/Assets/2DArt/UI/Items/Item_Icons/Resources/ITEM_Wood.ITEM_Wood")
    t.eq(wood.Behaviour, nil, "a reference to nothing")
    t.eq(table.concat(wood.FieldGuideKeywords, ","), "log,timber")
    t.eq(wood.Weight, 150)
    t.eq(wood.bAllowZeroWeight, false)
    t.eq(items:Row("Item_Fiber").Behaviour, "/Game/BP/Items/BP_Fiber.BP_Fiber_C")
    t.eq(items:Row("Item_Ghost").DisplayName, "")
    local category = Data:Table("LogCategories"):Row("LogTemp")
    t.eq(category.Name, "LogTemp", "not the field of the same name")
    t.eq(category.Verbosity, 3)
    t.eq(Data:Table("LogCategories"):Row("LogTemp", { "Name", "Verbosity" }), category)
    t.ok(is_plain(wood) and is_plain(category))
end)

t.test("numbers of every width are numbers, a list keeps its length, and a struct inside itself comes to an end", function()
    local odd = Data:Table("Odd")
    local logged, misses = warnings(), fake.misses
    local one = odd:Row("One")
    t.eq(one.Big, 1 << 40)
    t.eq(one.Small, 7)
    t.eq(one.Wide, 4000000000)
    t.eq(one.Precise, nil, "a double is not read")
    t.eq(one.Tags, nil, "nor a set")
    t.eq(#one.Icons, 3)
    t.eq(one.Icons[2], false, "a reference to nothing keeps its place in a list")
    t.eq(one.Icons[3], "/Game/C.C")
    t.eq(#one.Flags, 3)
    t.eq(one.Flags[2], false)
    t.eq(one.Tree.Value, 1)
    t.eq(one.Tree.Children, nil, "a struct is not followed into itself unless the path says so")
    t.eq(odd:Row("One", { "Tree.Children.Value" }), one)
    t.eq(#one.Tree.Children, 2)
    t.eq(one.Tree.Children[1].Value, 2)
    t.eq(one.Tree.Children[1].Children, nil)
    odd:Row("One", { "Tree.Children.Children.Value" })
    t.eq(one.Tree.Children[1].Children[1].Value, 3)
    t.eq(#one.Tree.Children[2].Children, 0)
    t.ok(is_plain(one))
    t.raises(function() odd:Row("One", { "Precise" }) end, "'Precise' is a Double field, which game.Data never reads")
    t.raises(function() odd:Row("One", { "Tags" }) end, "'Tags' is a Set field")
    -- a struct the game cannot find is left out of "everything", said once, and an error when asked for by name
    t.eq(one.Lost, nil)
    t.eq(warnings(), logged + 1)
    t.eq(fake.misses, misses + 1)
    local finds = fake.finds
    t.raises(function() odd:Row("One", { "Lost" }) end, "the fields of NotThere cannot be read from the game")
    t.raises(function() odd:Row("One", { "Lost.Deeper" }) end, "the fields of NotThere cannot be read from the game")
    t.eq(fake.finds, finds, "it is not looked for again")
    t.eq(warnings(), logged + 1)
    fake.misses = misses
    t.eq(fake.never_reads, 0)
end)

t.test("Fields lists what the game declares, for the row and for a struct inside it", function()
    local by = {}
    for _, field in ipairs(recipes:Fields()) do by[field.Name] = field end
    t.eq(by.Inputs.Kind, "Array")
    t.eq(by.Inputs.Inner, "Struct")
    t.eq(by.Inputs.Struct, "CraftingInput")
    t.eq(by.Requirement.Kind, "Struct")
    t.eq(by.Requirement.Struct, "TalentsRowHandle")
    t.eq(by.RequiredMillijoules.Kind, "Int")
    t.eq(by.RequiredMillijoules.Struct, nil)
    t.eq(by.Refundable.Kind, "Enum")
    t.eq(by.Overrides.Kind, "Map")
    t.eq(by.RefundSteps.Inner, "Enum")
    t.eq(by.CachedHardReferences.Inner, "Object", "fields of the parent struct are there")
    t.eq(recipes:Fields()[1].Name, "bForceDisableRecipe", "the row's own fields come first")
    local handle = {}
    for _, field in ipairs(recipes:Fields("Inputs.Element")) do handle[field.Name] = field.Kind end
    t.eq(handle.RowName, "Name")
    t.eq(handle.DataTableName, "Name")
    t.eq(handle.DataTablePtr, "WeakObject")
    t.raises(function() recipes:Fields("RequiredMillijoules") end, "so it has no fields")
    t.raises(function() recipes:Fields("Nope") end, "has no field named 'Nope'")
    by.Inputs.Kind = "changed"
    t.eq(recipes:Fields()[7].Kind, "Array", "the list handed out is a copy")
end)

t.test("an unknown row is nil without asking the engine, and a name that is not a string is refused in Lua", function()
    local before = fake.touches
    t.eq(recipes:Row("Definitely_Not_A_Row"), nil)
    t.eq(recipes:Row("Definitely_Not_A_Row", { "Inputs.Count" }), nil)
    t.eq(recipes:Has("Definitely_Not_A_Row"), false)
    t.eq(recipes:Has("made_07"), true)
    t.raises(function() recipes:Row(123) end, "a row name is a string")
    t.raises(function() recipes:Row(nil) end, "a row name is a string")
    t.raises(function() recipes:Has({}) end, "a row name is a string")
    t.eq(fake.touches, before)
    t.eq(fake.unknown_names, 0, "the engine was never asked for a name it did not list")
    t.eq(fake.crashes, 0)
end)

t.test("Resolve follows a row handle to its row and table", function()
    local row, items = Data:Resolve(knife.Inputs[1].Element)
    t.eq(row.Name, "Wood")
    t.eq(items, Data:Table("ItemsStatic"))
    t.eq(row.Itemable.RowName, "Item_Wood")
    local shown = Data:Resolve(row.Itemable, { "DisplayName" })
    t.eq(shown.DisplayName, "Wood")
    t.eq(Data:Resolve({ RowName = "WOOD", DataTableName = "d_itemsstatic" }), row, "letter case does not matter")
    t.eq(Data:Resolve(knife.CharacterRequirement), nil, "a handle to None")
    t.eq(Data:Resolve(knife.Inputs[3].Element), nil, "a handle to a row the table lacks")
    t.eq(Data:Resolve({ RowName = "Wood", DataTableName = "D_NoSuchTable" }), nil)
    t.raises(function() Data:Resolve(recipes:Row("Gold_Bed").SessionRequirement) end, "does not name its table")
    t.raises(function() Data:Resolve("Wood") end, "a row handle is a table")
    t.raises(function() Data:Resolve({ DataTableName = "D_ItemsStatic" }) end, "it has no RowName")
    t.eq(fake.unknown_names, 0)
end)

t.test("Meta is the table's meta table as a table object, or nil", function()
    local items = Data:Table("ItemsStatic")
    local meta = items:Meta()
    t.eq(meta.Name, "ItemsStatic_METATABLE")
    t.eq(meta.RowStruct, "RowMetadata")
    t.eq(meta:Count(), 3)
    t.eq(items:Meta(), meta, "one object")
    local radar = meta:Row("kit_radar")
    t.eq(radar.bIsDeprecated, true)
    t.eq(radar.RequiredFeatureLevel.RowName, "Core")
    t.eq(radar.ExtraMetadata, nil, "a map is only read when it is named")
    t.eq(meta:Row("Fish_03", { "RequiredFeatureLevel.RowName" }).RequiredFeatureLevel.RowName, "NewFrontiers")
    t.eq(meta:Row("Fish_03").Notes, "salt water")
    t.eq(meta:Meta(), nil)
    t.eq(recipes:Meta(), nil, "a table without one")
    t.eq(recipes:Meta(), nil)
    t.eq(meta.Raw:type(), "UDataTable")
    t.ok(meta:Stamp():find("^3:0x%x+$"), meta:Stamp())
    t.raises(function() Data:Table("ItemsStatic_METATABLE") end, "no table named")
    local rows = in_task(function() return meta:Load({ budget = 0 }) end)
    t.eq(count(rows), 3)
    t.eq(rows.Kit_Radar, radar)
    t.eq(fake.never_reads, 0)
end)

t.test("Stamp is the row count and the address, and Raw is found again on every read", function()
    local stamp = recipes:Stamp()
    t.ok(stamp:find("^" .. total.recipes .. ":0x%x+$"), stamp)
    t.eq(recipes:Stamp(), stamp)
    local finds = fake.finds
    local first, second = recipes.Raw, recipes.Raw
    t.eq(fake.finds, finds + 2)
    t.ok(first ~= second, "a new look each time")
    t.eq(first:type(), "UDataTable")
    t.eq(#first, total.recipes)
    t.eq(rawget(recipes, "Raw"), nil, "it is never stored")
    fake.hide("ProcessorRecipes")
    local misses = fake.misses
    t.eq(recipes.Raw, nil, "nil while the game does not have it")
    fake.hide("ProcessorRecipes", false)
    fake.misses = misses
end)

t.test("game.Data and its tables are read-only and name their members", function()
    local err = t.raises(function() return Data.Tabel end, "Tabel is not a member of game.Data")
    t.ok(tostring(err):find("'Table'", 1, true), tostring(err))
    t.raises(function() Data.Other = 1 end, "game.Data is read-only")
    err = t.raises(function() return recipes.Rows end, "Rows is not a member of a data table")
    t.ok(tostring(err):find("'Row'", 1, true), tostring(err))
    t.raises(function() recipes.Name = "x" end, "a data table is read-only")
    t.eq(getmetatable(Data).__names()[1], "Table")
    t.eq(getmetatable(recipes).__names()[1], "Name")
    t.raises(function() recipes.Row({}, "Bone_Knife") end, "this is not a data table")
end)

t.test("the live test passes on the stand-in, with its extra reads and with samples", function()
    Wax.perf = Wax.import("core.perf")
    Wax.game = game.root
    local live = assert(loadfile("wax/tests/live/data_rows.lua"))
    -- samples are always given here, so a file the workspace exported from the real game is never picked up
    -- shaped as scripts\recipe_check.py writes them: what each field path holds in the row, in order
    local samples = {
        { table = "ProcessorRecipes", row = "Bone_Knife", values = {
            ["Inputs.Element.RowName"] = { "Wood", "Leather", "Bone" }, ["Inputs.Count"] = { 2, 2, 20 },
            ["QueryInputs.Count"] = {}, ["Requirement.RowName"] = { "bone_knife" }, ["SessionRequirement.RowName"] = { "None" },
            RequiredMillijoules = { 3750 }, bForceDisableRecipe = { false } } },
        { table = "ProcessorRecipes", row = "Dough_Bread", values = {
            ["ResourceInputs.Type.Value"] = { "Water" }, ["ResourceInputs.RequiredUnits"] = { 100 },
            ["RecipeSets.RowName"] = { "Kitchen_Bench", "Advanced_Kitchen_Bench" } } },
        { table = "Itemable", row = "Item_Wood", values = { Weight = { 150 }, MaxStack = { 100 } } },
        { table = "TagQueries", row = "FieldGuide_Hide", values = { ["Query.QueryTokenStream"] = { 0, 1, 5, 2, 1, 6, 0, 1 },
            ["Query.TagDictionary.TagName"] = { "item.quest", "FieldGuide.BlackList" } } },
    }
    rawset(_G, "WaxDataSamples", samples)
    local result = live()
    t.eq(result.failed, 0, table.concat(result.failures, " | "))
    t.ok(result.passed >= 24, "it ran its checks: " .. result.passed)
    t.eq(result.handles_name_their_table, true)
    t.ok(table.concat(result.details, "\n"):find("4 rows, 26 values, from WaxDataSamples", 1, true), "the samples were compared")
    rawset(_G, "WaxDataRowsFull", true)
    local full = live()
    t.eq(full.failed, 0, table.concat(full.failures, " | "))
    t.eq(full.passed, result.passed + 2, "two more checks with the extra reads")
    samples[3].values.Weight = { 151 }
    local wrong = live()
    t.eq(wrong.failed, 1)
    t.ok(wrong.failures[1]:find("Itemable.Item_Wood.Weight: 151 in the samples, 150 in the game", 1, true), wrong.failures[1])
    samples[3].values.Weight = { 150 }
    samples[1].values["Inputs.Count"] = { 2, 2 }
    wrong = live()
    t.ok(wrong.failed == 1 and wrong.failures[1]:find("Inputs.Count: 2 values in the samples, 3 in the game", 1, true), wrong.failures[1])
    rawset(_G, "WaxDataSamples", nil)
    rawset(_G, "WaxDataRowsFull", nil)
    t.eq(fake.unknown_names, 0)
    t.eq(fake.grown, 0)
    t.eq(fake.never_reads, 0)
end)

t.test("Load reads every row a slice at a time and keeps nothing of the engine's over a pause", function()
    reset()
    data.flush()
    local pauses = data.pauses
    t.eq(select(1, recipes:Loaded(RECIPE)), 0)
    local rows = in_task(function() return recipes:Load({ fields = RECIPE, budget = 0 }) end)
    t.eq(count(rows), total.recipes, "every row")
    local inputs, outputs, sets = sums(rows)
    t.eq(inputs, total.inputs)
    t.eq(outputs, total.outputs)
    t.eq(sets, total.sets)
    t.ok(is_plain(rows), "only strings, numbers, booleans and tables")
    t.eq(rows.MADE_07.Name, "MADE_07", "keyed by the engine's spelling")
    t.eq(rows.Bone_Knife.Inputs[3].Element.RowName, "bone")
    t.eq(rows.Bone_Knife.ExperienceMultiplier, nil, "only the fields asked for")
    pauses = data.pauses - pauses
    t.eq(pauses, total.recipes - 1, "a budget of 0 gives the frame back between every two rows")
    t.ok(fake.finds >= pauses, "the table was found again after every pause: " .. fake.finds)
    t.eq(fake.stale, 0, "nothing was used after its frame")
    t.eq(fake.grown, 0, "no array was made longer")
    t.eq(fake.enum_reads, 0)
    local distinct, most = fake.asked_rows("ProcessorRecipes")
    t.eq(distinct, total.recipes)
    t.eq(most, 1, "each row was asked for once")
    local done, all, failed = recipes:Loaded(RECIPE)
    t.eq(done, total.recipes)
    t.eq(all, total.recipes)
    t.eq(failed, 0)
    t.eq(#guard.errors(), 0)
end)

t.test("a second Load asks the engine nothing", function()
    local before, pauses = fake.touches, data.pauses
    local first = in_task(function() return recipes:Load({ fields = RECIPE, budget = 0 }) end)
    local second = in_task(function() return recipes:Load({ fields = { "Inputs.Count", "RequiredMillijoules" } }) end)
    t.eq(count(first), total.recipes)
    t.eq(count(second), total.recipes)
    t.eq(first.Gold_Bed, second.Gold_Bed, "the same rows")
    t.eq(fake.touches, before)
    t.eq(data.pauses, pauses, "and never pauses")
    t.eq(recipes:Row("gold_bed", RECIPE), first.Gold_Bed)
    t.eq(fake.touches, before)
end)

t.test("Row without a field list after a partial Load holds everything", function()
    local row = recipes:Row("Made_03")
    t.eq(row.ExperienceMultiplier, 1.0)
    t.eq(row.CharacterRequirement.RowName, "None")
    t.eq(row.Inputs[1].Element.DataTableName, "D_ItemsStatic")
    t.eq(row.Outputs[2].Count, 2)
    t.eq(fake.asked.ProcessorRecipes.Made_03, 2, "one more look, for what was missing")
    local before = fake.touches
    t.eq(recipes:Row("Made_03"), row)
    t.eq(fake.touches, before)
    local partly = recipes:Row("Made_04", RECIPE)
    t.eq(partly.ExperienceMultiplier, nil, "a row nobody asked all of is still partial")
end)

t.test("a cancelled Load leaves nothing behind and the next one goes on where it stopped", function()
    reset()
    data.flush()
    local wait, paused_in = task.wait, nil
    task.wait = function(...)
        paused_in = paused_in or debug.traceback()
        return wait(...)
    end
    local thread = task.spawn(function() recipes:Load({ fields = RECIPE, budget = 0 }) end)
    for _ = 1, 9 do frame() end
    task.wait = wait
    t.ok(paused_in and not paused_in:find("pcall", 1, true), "Load pauses outside any pcall of its own: " .. tostring(paused_in))
    task.cancel(thread)
    for _ = 1, 3 do frame() end
    local done = recipes:Loaded(RECIPE)
    t.eq(done, 10, "ten rows were read before it was stopped")
    t.eq(fake.rows_asked, 10)
    local rows = in_task(function() return recipes:Load({ fields = RECIPE, budget = 0 }) end)
    t.eq(count(rows), total.recipes)
    local inputs, outputs, sets = sums(rows)
    t.ok(inputs == total.inputs and outputs == total.outputs and sets == total.sets, "the same counts")
    local distinct, most = fake.asked_rows("ProcessorRecipes")
    t.eq(distinct, total.recipes)
    t.eq(most, 1, "each row was asked for once in all")
    t.eq(fake.stale, 0)
    t.eq(#guard.errors(), 0)
end)

t.test("two Loads of one table at the same time ask the engine for each row once", function()
    reset()
    data.flush()
    local pauses = data.pauses
    local first, second
    task.spawn(function() first = recipes:Load({ fields = RECIPE, budget = 0 }) end)
    task.spawn(function() second = recipes:Load({ fields = RECIPE, budget = 0 }) end)
    for _ = 1, 500 do
        if first and second then break end
        frame()
    end
    t.ok(first and second, "both ended")
    t.eq(count(first), total.recipes)
    t.eq(count(second), total.recipes)
    for name, row in pairs(first) do t.eq(second[name], row, name) end
    local distinct, most = fake.asked_rows("ProcessorRecipes")
    t.eq(distinct, total.recipes)
    t.eq(most, 1)
    t.eq(data.pauses - pauses, total.recipes - 1, "one row a frame between them")
    t.eq(fake.stale, 0)
    t.eq(#guard.errors(), 0)
end)

t.test("a Flush while a Load is paused makes it start again, and it still ends with every row", function()
    reset()
    data.flush()
    local rows
    task.spawn(function() rows = recipes:Load({ fields = RECIPE, budget = 0 }) end)
    for _ = 1, 4 do frame() end
    t.eq(fake.rows_asked, 5)
    Data:Flush()
    t.eq(data.stats().rows, 0)
    for _ = 1, 500 do
        if rows then break end
        frame()
    end
    t.eq(count(rows), total.recipes)
    local inputs = sums(rows)
    t.eq(inputs, total.inputs)
    local distinct, most = fake.asked_rows("ProcessorRecipes")
    t.eq(distinct, total.recipes)
    t.eq(most, 2, "only the rows read before the flush were read twice")
    t.eq(fake.rows_asked, total.recipes + 5)
    t.eq(fake.stale, 0)
    t.eq(#guard.errors(), 0)
end)

t.test("a table the list has but the game cannot find is an error once, and then simply unknown", function()
    data.flush()
    t.eq(#Data:GetTables(), fake.listed())
    fake.hide("TagQueries")
    local misses, lists = fake.misses, fake.lists
    t.raises(function() Data:Table("TagQueries") end, "cannot be found right now")
    t.eq(fake.misses, misses + 1)
    t.raises(function() Data:Table("TagQueries") end, "the game has no table named TagQueries")
    t.eq(Data:Has("TagQueries"), false)
    t.eq(fake.misses, misses + 1, "the engine was not asked a second time")
    t.eq(fake.lists, lists)
    fake.hide("TagQueries", false)
    now = now + 6
    t.eq(Data:Table("TagQueries"):Count(), 1)
    fake.misses = misses
end)

t.test("Load is for tasks, checks its options, and reads only the rows named", function()
    reset()
    data.flush()
    t.raises(function() recipes:Load({ fields = RECIPE }) end, "Load can only be used inside a task")
    t.raises(function() in_task(function() recipes:Load({ budget = "fast" }) end) end, "`budget` is a number of milliseconds")
    t.raises(function() in_task(function() recipes:Load({ budget = -1 }) end) end, "`budget` is a number of milliseconds")
    t.raises(function() in_task(function() recipes:Load({ names = { "Bone_Knife", 7 } }) end) end, "a row name is a string")
    t.raises(function() in_task(function() recipes:Load({ names = "Bone_Knife" }) end) end, "`names` is a list of row names")
    t.raises(function() in_task(function() recipes:Load({ fields = { "Nope" } }) end) end, "has no field named 'Nope'")
    t.raises(function() in_task(function() recipes:Load("all") end) end, "the options are a table")
    t.eq(fake.rows_asked, 0)
    local rows = in_task(function()
        return recipes:Load({ fields = { "RequiredMillijoules" }, names = { "bone_knife", "No_Such_Row", "Gold_Bed", "BONE_KNIFE" } })
    end)
    t.eq(count(rows), 2)
    t.eq(rows.Bone_Knife.RequiredMillijoules, 3750)
    t.eq(rows.Gold_Bed.RequiredMillijoules, 5000)
    t.eq(fake.rows_asked, 2)
    t.eq(fake.unknown_names, 0)
    local done, all = recipes:Loaded({ "RequiredMillijoules" })
    t.eq(done, 2)
    t.eq(all, total.recipes)
    local everything = in_task(function() return recipes:Load() end)
    t.eq(count(everything), total.recipes, "no options means every row and every readable field")
    t.eq(everything.Bone_Knife, rows.Bone_Knife)
    t.eq(everything.Bone_Knife.Outputs[1].Count, 1)
end)

t.test("the budget is time since the task was resumed, shared by the Loads it makes in one frame", function()
    reset()
    data.flush()
    local small = { "Itemable", "ItemsStatic", "TagQueries", "LogCategories" }
    for _, name in ipairs(small) do Data:Table(name):Count() end
    t.eq(recipes:Count(), total.recipes)
    local tick = 0
    data.clock = function()
        tick = tick + 1 / 4096      -- every look at the clock costs about 0.24 ms, so 1 ms is five rows
        return tick
    end
    local pauses = data.pauses
    local rows = in_task(function() return recipes:Load({ fields = RECIPE, budget = 1 }) end)
    local taken = data.pauses - pauses
    -- four small tables, eight rows: no one of them uses up 1 ms, together they do
    pauses = data.pauses
    in_task(function()
        for _, name in ipairs(small) do Data:Table(name):Load({ budget = 1 }) end
    end)
    local shared = data.pauses - pauses
    -- many loads of one row each: the budget still ends the frame
    pauses = data.pauses
    in_task(function()
        for _, name in ipairs(recipes:GetNames()) do recipes:Load({ fields = { "ExperienceMultiplier" }, names = { name }, budget = 1 }) end
    end)
    local singles = data.pauses - pauses
    data.clock = function() return now end
    t.eq(count(rows), total.recipes)
    t.eq(taken, (total.recipes - 1) // 5, "five rows a slice, and no pause after the last row")
    t.eq(shared, 1, "one pause across the four")
    t.eq(singles, (total.recipes - 1) // 5, "five rows a slice across loads of one row")
    t.eq(fake.stale, 0)
end)

t.test("a table that is another one after a pause is read again from the start, and Changed says which", function()
    reset()
    data.flush()
    local fired, connection = listen()
    local rows
    task.spawn(function() rows = recipes:Load({ fields = RECIPE, budget = 0 }) end)
    for _ = 1, 5 do frame() end
    t.eq(fake.rows_asked, 6)
    fake.move("ProcessorRecipes")
    for _ = 1, 500 do
        if rows then break end
        frame()
    end
    t.eq(count(rows), total.recipes)
    local inputs = sums(rows)
    t.eq(inputs, total.inputs)
    t.eq(table.concat(fired, ","), "ProcessorRecipes")
    local distinct, most = fake.asked_rows("ProcessorRecipes")
    t.eq(distinct, total.recipes)
    t.eq(most, 2, "the rows read before the change were read again")
    t.eq(fake.rows_asked, total.recipes + 6)
    -- a row fewer: the same again, seen through the count this time
    local kept, order = {}, {}
    for _, name in ipairs(recipes:GetNames()) do
        if name ~= "Nothing_In" then
            order[#order + 1] = name
            kept[name] = { RequiredMillijoules = 7 }
        end
    end
    rows = nil
    task.spawn(function() rows = recipes:Load({ fields = { "ExperienceMultiplier" }, budget = 0 }) end)
    for _ = 1, 3 do frame() end
    fake.set_rows("ProcessorRecipes", kept, order)
    for _ = 1, 500 do
        if rows then break end
        frame()
    end
    t.eq(count(rows), total.recipes - 1)
    t.eq(rows.Nothing_In, nil)
    t.eq(recipes:Count(), total.recipes - 1)
    t.eq(table.concat(fired, ","), "ProcessorRecipes,ProcessorRecipes")
    connection:Disconnect()
    t.eq(fake.stale, 0)
    t.eq(#guard.errors(), 0)
end)

t.test("Row and Stamp notice a table that changed, drop what was read from it and say so", function()
    local fired, connection = listen()
    local stamp = recipes:Stamp()
    local before = recipes:Row("Bone_Knife", { "RequiredMillijoules" })
    t.eq(before.RequiredMillijoules, 7)
    fake.move("ProcessorRecipes")
    t.ok(recipes:Stamp() ~= stamp, "another stamp")
    t.eq(#fired, 0, "Changed waits for the end of the frame")
    frame()
    t.eq(table.concat(fired, ","), "ProcessorRecipes")
    local after = recipes:Row("Bone_Knife", { "RequiredMillijoules" })
    t.ok(after ~= before, "a new table, read again")
    fake.move("ProcessorRecipes")
    t.ok(recipes:Row("Bone_Knife", { "ExperienceMultiplier" }) ~= after, "Row sees it as well")
    frame()
    t.eq(#fired, 2)
    connection:Disconnect()
end)

t.test("after a map change a table that differs is dropped and named, and the others are kept", function()
    reset()
    data.flush()
    local items = Data:Table("Itemable")
    local wood, pick = items:Row("Item_Wood"), recipes:Row("Stone_Pickaxe")
    local meta_row = Data:Table("ItemsStatic"):Meta():Row("Wood")
    local fired, connection = listen()
    game.root.MapChanged:Fire("Somewhere")
    t.eq(#fired, 0, "nothing changed")
    fake.move("Itemable")
    game.root.MapChanged:Fire("Elsewhere")
    t.eq(table.concat(fired, ","), "Itemable")
    local before = fake.touches
    t.eq(recipes:Row("Stone_Pickaxe"), pick, "still cached")
    t.eq(Data:Table("ItemsStatic"):Meta():Row("Wood"), meta_row)
    t.eq(fake.touches, before)
    t.ok(items:Row("Item_Wood") ~= wood, "read again")
    fake.set_rows("Itemable", { Item_Wood = { DisplayName = "Wood" }, Item_Fiber = { DisplayName = "Fiber" } }, { "Item_Wood", "Item_Fiber" })
    game.root.MapChanged:Fire("Third")
    t.eq(table.concat(fired, ","), "Itemable,Itemable", "a different row count is a change too")
    t.eq(items:Count(), 2)
    fake.move("ItemsStatic_METATABLE")
    game.root.MapChanged:Fire("Fourth")
    t.eq(fired[3], "ItemsStatic_METATABLE")
    t.ok(Data:Table("ItemsStatic"):Meta():Row("Wood") ~= meta_row)
    connection:Disconnect()
    t.eq(fake.misses, 0)
end)

t.test("a table that is not found after a map change empties everything and fires Changed once, with no name", function()
    local fired, connection = listen()
    local pick = recipes:Row("Stone_Pickaxe")
    Data:Table("TagQueries"):Row("FieldGuide_Hide")
    t.ok(data.stats().tables >= 4, "several tables are cached")
    fake.hide("ProcessorRecipes")
    fake.hide("TagQueries")
    local misses = fake.misses
    game.root.MapChanged:Fire("Gone")
    t.eq(table.concat(fired, ","), "(everything)")
    t.eq(fake.misses, misses + 1, "it stopped at the first table that was not found")
    t.eq(data.stats().tables, 0)
    t.eq(data.stats().rows, 0)
    t.eq(Data:Has("ProcessorRecipes"), false, "the list was taken again and no longer has it")
    t.raises(function() recipes:Count() end, "the game has no table named ProcessorRecipes")
    fake.hide("ProcessorRecipes", false)
    fake.hide("TagQueries", false)
    now = now + 6
    t.eq(recipes:Count(), total.recipes - 1, "the object a mod kept works again")
    t.ok(recipes:Row("Stone_Pickaxe") ~= pick)
    connection:Disconnect()
    fake.misses = misses
end)

t.test("a table that goes away under a read is an error, not a crash", function()
    local fired, connection = listen()
    local pick = recipes:Row("Stone_Pickaxe")
    fake.hide("ProcessorRecipes")
    local misses = fake.misses
    t.eq(recipes:Row("Stone_Pickaxe"), pick, "what is held is still given, without a look")
    t.raises(function() recipes:Row("Bone_Knife") end, "the game no longer has the table ProcessorRecipes")
    t.eq(fake.misses, misses + 1)
    t.raises(function() recipes:Stamp() end, "the game has no table named ProcessorRecipes")
    t.eq(fake.misses, misses + 1, "the second ask did not reach StaticFindObject")
    frame()
    t.eq(table.concat(fired, ","), "(everything)")
    fake.hide("ProcessorRecipes", false)
    now = now + 6
    t.eq(recipes:Row("Bone_Knife").RequiredMillijoules, 7)
    connection:Disconnect()
    fake.misses = misses
end)

t.test("a row that cannot be read is left out, logged once for its table, and not asked for again", function()
    reset()
    data.flush()
    fake.set_rows("Itemable", {
        Item_Wood = { DisplayName = "Wood", Weight = 150 }, Item_Fiber = { DisplayName = "Fiber", Weight = 10 },
        Item_Ghost = { DisplayName = "", Weight = 0 },
    }, { "Item_Wood", "Item_Fiber", "Item_Ghost" })
    fake.poison("Itemable", "Item_Fiber", "Weight")
    fake.poison("Itemable", "Item_Ghost", "MaxStack")
    local items = Data:Table("Itemable")
    local logged = warnings()
    local rows = in_task(function() return items:Load({ budget = 0 }) end)
    t.eq(count(rows), 1)
    t.eq(rows.Item_Wood.Weight, 150)
    t.eq(warnings(), logged + 1, "one line for the table, not one per row")
    local entries = log.since(0, { level = "warn", channel = "wax.data" })
    local message = entries[#entries].message
    t.ok(message:find("Item_Fiber", 1, true) and message:find("Weight", 1, true), message)
    local done, all, failed = items:Loaded()
    t.eq(done, 1)
    t.eq(all, 3)
    t.eq(failed, 2)
    local before = fake.touches
    t.eq(items:Row("Item_Fiber"), nil)
    in_task(function() return items:Load({ budget = 0 }) end)
    t.eq(fake.touches, before, "a row that failed is not asked for again")
    t.eq(items:Row("Item_Fiber", { "DisplayName" }).DisplayName, "Fiber", "other fields of it can still be read")
    fake.poison("Itemable", "Item_Fiber", nil)
    fake.poison("Itemable", "Item_Ghost", nil)
    Data:Flush()
    t.eq(items:Row("Item_Fiber").Weight, 10, "after a flush it is tried again")
    t.eq(#guard.errors(), 0)
end)

t.test("text stays as it was read until Flush, and Flush fires Changed once with no name", function()
    frame()     -- what the flush of the test before announced is out of the way
    local fired, connection = listen()
    local items = Data:Table("Itemable")
    local wood = items:Row("Item_Wood", { "DisplayName" })
    t.eq(wood.DisplayName, "Wood")
    fake.set_rows("Itemable", { Item_Wood = { DisplayName = "Holz" } }, { "Item_Wood" })
    fake.move("Itemable")
    fake.move("Itemable")
    t.eq(items:Row("Item_Wood", { "DisplayName" }).DisplayName, "Wood", "nothing is asked again for a row that holds the field")
    local lists = fake.lists
    Data:Flush()
    t.eq(data.stats().tables, 0)
    local again = items:Row("Item_Wood", { "DisplayName" })
    t.eq(again.DisplayName, "Holz")
    t.ok(again ~= wood, "rows handed out before a flush are not filled in any more")
    t.eq(fake.lists, lists + 1, "the list of tables is taken again as well")
    t.eq(#fired, 0, "not in the middle of the frame")
    frame()
    t.eq(#fired, 1)
    t.eq(fired[1], "(everything)", "everything was dropped, so no table is named")
    connection:Disconnect()
end)

t.test("in the whole suite nothing was done that the game could not take", function()
    reset()
    for _, name in ipairs(MISTAKES) do t.eq(mistakes[name], 0, name) end
    t.eq(#guard.errors(), 0, "no task raised")
end)

t.finish("data")
