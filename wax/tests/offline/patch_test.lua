-- Offline tests for data.patch: changing rows of the game's tables through game.Data, on a stand-in with UE4SS's write rules.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\patch_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local fake = dofile("wax/tests/offline/fake_tables.lua")
local total = fake.sample()
local S, U = "/Script/Icarus.", "/Script/IcarusUtilities."

-- the tables the sample's handles point at, and one table with a field of every kind
fake.struct(S .. "TalentRow", U .. "IcarusTableRowBase", { { "RequiredLevel", "IntProperty" } })
fake.table("Talents", S .. "TalentRow", { Stone_Pickaxe = {}, Bone_Knife = {}, Dough_Bread = {} }, { "Stone_Pickaxe", "Bone_Knife", "Dough_Bread" })
fake.struct(S .. "ItemTemplateRow", U .. "IcarusTableRowBase", { { "Weight", "IntProperty" } })
fake.table("ItemTemplate", S .. "ItemTemplateRow", { Plank = {}, Nail = {}, Glue = {} }, { "Plank", "Nail", "Glue" })
fake.struct(S .. "ResourceRow", U .. "IcarusTableRowBase", { { "Units", "IntProperty" } })
fake.table("IcarusResources", S .. "ResourceRow", { Water = {}, Milk = {}, Oxygen = {} }, { "Water", "Milk", "Oxygen" })
fake.struct(S .. "CraftOut", nil, {
    { "Element", "StructProperty", struct = S .. "ItemTemplateRowHandle" }, { "Count", "IntProperty" },
    { "Notes", "ArrayProperty", inner = "StrProperty" },
    { "Parts", "ArrayProperty", inner = "StructProperty", struct = S .. "CraftingInput" },
    { "Tag", "StrProperty" },
})
fake.struct(S .. "CraftPage", nil, { { "Title", "TextProperty" }, { "Number", "IntProperty" } })
fake.struct(S .. "CraftInfo", nil, { { "Title", "TextProperty" }, { "Weight", "IntProperty" },
    { "Maker", "StructProperty", struct = S .. "RecipeSetsRowHandle" } })
-- entries only the game can make: one holds a reference to an asset, one a map
fake.struct(S .. "CraftSound", nil, { { "Sound", "SoftObjectProperty" }, { "Volume", "IntProperty" } })
fake.struct(S .. "CraftReward", nil, { { "Extras", "MapProperty" }, { "Amount", "IntProperty" } })
fake.struct(S .. "CraftMark", nil, { { "Level", "EnumProperty", enum = { "Bronze", "Silver" } }, { "Points", "IntProperty" } })
fake.struct(S .. "CraftRow", U .. "IcarusTableRowBase", {
    { "bFlag", "BoolProperty" }, { "Small", "ByteProperty" }, { "Tiny", "Int8Property" }, { "Count", "IntProperty" },
    { "Big", "Int64Property" }, { "Wide", "UInt32Property" }, { "Ratio", "FloatProperty" },
    { "Mode", "EnumProperty", enum = { "Slow", "Fast", "Instant" } }, { "Plain", "EnumProperty" },
    { "Label", "NameProperty" }, { "Note", "StrProperty" }, { "Title", "TextProperty" }, { "Icon", "SoftObjectProperty" },
    { "Precise", "DoubleProperty" }, { "Extras", "MapProperty" }, { "Preview", "ObjectProperty" },
    { "Bench", "StructProperty", struct = S .. "RecipeSetsRowHandle" },
    { "Resource", "StructProperty", struct = S .. "IcarusResourcesEnum" },
    { "Gate", "StructProperty", struct = S .. "FlagsMultiRowHandle" },
    { "Loose", "StructProperty", struct = U .. "RowHandle" },
    { "Inputs", "ArrayProperty", inner = "StructProperty", struct = S .. "CraftingInput" },
    { "Outputs", "ArrayProperty", inner = "StructProperty", struct = S .. "CraftOut" },
    { "Costs", "ArrayProperty", inner = "StructProperty", struct = S .. "ResourceItem" },
    { "Pages", "ArrayProperty", inner = "StructProperty", struct = S .. "CraftPage" },
    { "Tags", "ArrayProperty", inner = "NameProperty" }, { "Steps", "ArrayProperty", inner = "IntProperty" },
    { "Lines", "ArrayProperty", inner = "StrProperty" }, { "Flags", "ArrayProperty", inner = "BoolProperty" },
    { "Kinds", "ArrayProperty", inner = "EnumProperty", enum = { "Soft", "Hard" } },
    { "Titles", "ArrayProperty", inner = "TextProperty" }, { "Icons", "ArrayProperty", inner = "SoftObjectProperty" },
    { "Info", "StructProperty", struct = S .. "CraftInfo" },
    { "position", "IntProperty" },
    { "Odd", "StructProperty", struct = S .. "RecipeSetsRowHandle" },
    { "Sounds", "ArrayProperty", inner = "StructProperty", struct = S .. "CraftSound" },
    { "Rewards", "ArrayProperty", inner = "StructProperty", struct = S .. "CraftReward" },
    { "Grades", "ArrayProperty", inner = "EnumProperty", enum = { "Low", "High" } },
    { "Marks", "ArrayProperty", inner = "StructProperty", struct = S .. "CraftMark" },
})

local function item(name) return { RowName = name, DataTableName = "D_ItemsStatic" } end
local function bench(name) return { RowName = name, DataTableName = "D_RecipeSets" } end

-- The rows of Crafts as the game makes them. Each call gives new data, as when the game makes the table again.
local function craft_rows()
    return {
        Chair = { bFlag = false, Small = 7, Tiny = -3, Count = 2, Big = 1 << 40, Wide = 4000000000, Ratio = 0.5, Mode = 1, Plain = 1,
            Label = "Seat", Note = "four legs", Title = "Chair", Icon = "/Game/Icons/Chair.Chair", Precise = 1.5,
            Bench = bench("Character"), Resource = { Value = "Water" }, Gate = { RowName = "Some_Flag", DataTableName = 1 },
            Loose = item("Wood"),
            Inputs = { { Element = item("Wood"), Count = 4 }, { Element = item("Fish_03"), Count = 1 } },
            Outputs = { { Element = { RowName = "Plank", DataTableName = "D_ItemTemplate" }, Count = 1, Notes = { "sand it" },
                Parts = { { Element = item("Wood"), Count = 2 } }, Tag = "main" } },
            Costs = { { Type = { Value = "Water" }, RequiredUnits = 10 }, { Type = { Value = "Milk" }, RequiredUnits = 5 } },
            Pages = { { Title = "One", Number = 1 }, { Title = "Two", Number = 2 } },
            Tags = { "Wooden", "Seat" }, Steps = { 1, 2, 3 }, Lines = { "cut", "glue" }, Flags = { true, false }, Kinds = { 0, 1 },
            Titles = { "First", "Second" }, Icons = { "/Game/A.A", "None" },
            Info = { Title = "A chair", Weight = 12, Maker = bench("Kitchen_Bench") }, position = 3,
            -- a typed handle that names another table than its own, as three of the game's items do
            Odd = { RowName = "None", DataTableName = "D_Talents" },
            Sounds = { { Sound = "/Game/Sounds/Saw.Saw", Volume = 3 } }, Rewards = { { Amount = 2 } } },
        Table = { Count = 4, Note = "flat", Ratio = 1.5, Bench = bench("Character"), Resource = { Value = "None" },
            Inputs = { { Element = item("Wood"), Count = 8 }, { Element = item("Kit_Radar"), Count = 1 } },
            Outputs = { { Element = { RowName = "Nail", DataTableName = "D_ItemTemplate" }, Count = 1 } },
            Steps = { 10, 20 }, Info = { Title = "A table", Weight = 30, Maker = bench("Character") } },
        -- Mode and Kinds hold numbers their enums have no name for, as the game's own data does here and there
        Stool = { Count = 1, Note = "small", Steps = { 7 }, Inputs = { { Element = item("Wood"), Count = 1 } },
            Lines = { "saw", "plane", "drill", "glue", "sand" }, Mode = 7, Kinds = { 5 } },
        -- a row of the game that names an item the items table lacks, as about 500 of the real ones do
        Ghost = { Count = 1, Inputs = { { Element = item("Phantom_Wood"), Count = 1 } } },
    }
end
local CRAFT_ORDER = { "Chair", "Table", "Stool", "Ghost" }
fake.table("Crafts", S .. "CraftRow", craft_rows(), CRAFT_ORDER)
fake.install()
fake.allow_writes(true)

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local log = Wax.import("core.log")
local game = Wax.import("engine.game")
local data = Wax.import("data.tables")
local journal = Wax.import("data.journal")
journal.clear()

local now = 100
sched.clock = function() return now end
data.clock = function() return now end
data.start()
local patch = Wax.import("data.patch")
patch.clock = function() return now end
-- a stand-in for the loader, so the order is worked out by the module's own code. Names differ from ids and sort the other way
local load_order = { "ModA", "ModB", "ModC" }
local shown_names = { ModA = "Zulu", ModB = "Able" }
rawset(Wax, "mods", { list = function()
    local out = {}
    for index, id in ipairs(load_order) do out[index] = { id = id, name = shown_names[id] or id } end
    return out
end })
local Data = game.root.Data
local recipes, crafts = Data:Table("ProcessorRecipes"), Data:Table("Crafts")

-- One frame: whatever the engine handed out before must not be used again.
local function frame()
    now = now + 0.016
    fake.next_frame()
    sched.step()
end

local function mod(name) return scope.new(name) end
local function as(owner, fn, ...) return scope.run(owner, fn, ...) end
local function unload(owner) owner:destroy() end
local function chair() return fake.row("Crafts", "Chair") end
local function desk() return fake.row("Crafts", "Table") end

local function warnings(text)
    return #log.since(0, { level = "warn", channel = "wax.data", text = text })
end

local function join(list, key)
    local out = {}
    for index, entry in ipairs(list) do out[index] = tostring(key and entry[key] or entry) end
    return table.concat(out, ",")
end

-- The changes of one row, by field.
local function changes_of(found, row)
    local out = {}
    for _, change in ipairs(found:Changes()) do
        if change.Row == row then out[change.Field or "(row)"] = change end
    end
    return out
end

t.test("until data.patch has started nothing can be changed, and reading is as it was", function()
    local stamp = recipes:Stamp()
    t.ok(stamp:find("^" .. total.recipes .. ":0x%x+$"), stamp)
    for _, call in ipairs({
        function() recipes:Set("Bone_Knife", "RequiredMillijoules", 1) end,
        function() recipes:Change("Bone_Knife", "RequiredMillijoules", function(value) return value end) end,
        function() recipes:Add("ModA_Row", {}, { like = "Bone_Knife" }) end,
        function() recipes:Reset() end,
    }) do
        local err = t.raises(call, "changing the game's tables is not switched on in this version of Wax")
        t.ok(tostring(err):find("patch_test.lua", 1, true), "points at the caller: " .. tostring(err))
    end
    t.eq(#recipes:Changes(), 0)
    t.eq(#recipes:Conflicts(), 0)
    t.eq(#Data:Changes(), 0)
    t.eq(#Data:Conflicts(), 0)
    t.eq(fake.writes, 0)
    t.eq(getmetatable(recipes).__names()[13], "Set", "the new members are named")
    t.eq(getmetatable(Data).__names()[9], "Patched")
end)

patch.start()
local A, B = mod("ModA"), mod("ModB")

t.test("a change belongs to a mod: code outside one is refused", function()
    t.raises(function() recipes:Set("Bone_Knife", "RequiredMillijoules", 1) end, "belongs to a mod, which puts it back when it unloads")
    t.eq(fake.writes, 0)
end)

t.test("a wrong table object, row, field or argument is an error with the nearest name, and nothing is written", function()
    as(A, function()
        local err = t.raises(function() recipes:Set("Bone_Knif", "RequiredMillijoules", 1) end, "ProcessorRecipes has no row named 'Bone_Knif'")
        t.ok(tostring(err):find("'Bone_Knife'", 1, true), "suggests the row: " .. tostring(err))
        t.ok(tostring(err):find("patch_test.lua", 1, true), "points at the caller: " .. tostring(err))
        err = t.raises(function() recipes:Set("Bone_Knife", "RequiredMilijoules", 1) end, "ProcessorRecipe has no field named 'RequiredMilijoules'")
        t.ok(tostring(err):find("'RequiredMillijoules'", 1, true), "suggests the field: " .. tostring(err))
        t.raises(function() recipes:Set("Bone_Knife", "Inputs.Count", 1) end, "'Inputs.Count' is a part of a field")
        t.raises(function() Data:Table("LogCategories"):Set("LogTemp", "Name", "x") end, "Name is the row's own name")
        t.raises(function() Data:Table("ItemsStatic"):Meta():Set("Wood", "bIsDeprecated", true) end, "a meta table cannot be changed")
        t.raises(function() recipes:Set(12, "RequiredMillijoules", 1) end, "a row name is a string")
        t.raises(function() recipes:Set("Bone_Knife", 12, 1) end, "a field name is a string")
        t.raises(function() recipes:Set("Bone_Knife", "RequiredMillijoules") end, "Set needs the new value")
        t.raises(function() recipes:Set("Bone_Knife", { [1] = 5 }) end, "a field name is a string")
        t.raises(function() recipes:Change("Bone_Knife", "RequiredMillijoules", 5) end, "Change takes a function")
        t.raises(function() recipes.Set({}, "Bone_Knife", "RequiredMillijoules", 1) end, "this is not a data table")
    end)
    t.eq(fake.writes, 0)
    t.eq(#Data:Changes(), 0)
    t.eq(journal.stats().entries, 0)
end)

t.test("numbers, a switch, an enum and a string are written at once, and Row, Stamp, Patched and Changed follow", function()
    local fired, patched = {}, {}
    local on_changed = Data.Changed:Connect(function(name) fired[#fired + 1] = name or "(everything)" end)
    local on_patched = Data.Patched:Connect(function(name, row, field) patched[#patched + 1] = name .. "." .. row .. "." .. tostring(field) end)
    local before = crafts:Row("Chair")
    t.eq(before.Count, 2)
    t.ok(crafts:Stamp():find("^4:0x%x+$"), crafts:Stamp())
    as(A, function()
        crafts:Set("Chair", "bFlag", true)
        crafts:Set("Chair", "Small", 255)
        crafts:Set("Chair", "Tiny", -128)
        crafts:Set("Chair", "Count", 10)
        crafts:Set("Chair", "Big", 1 << 41)
        crafts:Set("Chair", "Wide", 4294967295)
        crafts:Set("Chair", "Ratio", 0.1)
        crafts:Set("Chair", "Mode", 2)
        crafts:Set("Chair", "Note", "three legs")
        t.eq(chair().Count, 10, "written before Set returns")
        crafts:Set("Chair", "Count", 10.0)
    end)
    local row = chair()
    t.eq(row.bFlag, true)
    t.eq(row.Small, 255)
    t.eq(row.Tiny, -128)
    t.eq(row.Count, 10)
    t.eq(math.type(row.Count), "integer", "a whole number given as a float is written as a whole number")
    t.eq(row.Big, 1 << 41)
    t.eq(row.Wide, 4294967295)
    t.ok(math.abs(row.Ratio - 0.1) < 1e-7, "a float is kept as the game keeps it: " .. row.Ratio)
    t.eq(row.Mode, 2)
    t.eq(row.Note, "three legs")
    t.eq(fake.writes, 9, "one write a field, and none for saying the same again")
    local after = crafts:Row("Chair")
    t.ok(after ~= before, "a changed row is read again")
    t.eq(after.Count, 10)
    t.eq(before.Count, 2, "a row handed out before keeps what it held")
    t.ok(crafts:Stamp():find("^4:0x%x+:9$"), "the stamp counts the changes: " .. crafts:Stamp())
    t.eq(#fired, 0, "Changed waits for the end of the frame")
    t.eq(#patched, 0)
    frame()
    t.eq(table.concat(fired, ","), "Crafts", "once for the table")
    t.eq(#patched, 9, "once for each field")
    t.eq(patched[1], "Crafts.Chair.bFlag")
    t.eq(patched[9], "Crafts.Chair.Note")
    local changes = changes_of(crafts, "Chair")
    t.eq(changes.Count.Was, 2)
    t.eq(changes.Count.Now, 10)
    t.eq(changes.Count.By, "ModA")
    t.eq(#changes.Count.Others, 0)
    t.eq(changes.Count.Table, "Crafts")
    t.eq(#crafts:Changes(), 9)
    t.eq(#Data:Changes(), 9)
    t.eq(#recipes:Changes(), 0, "another table has none")
    on_changed:Disconnect()
    on_patched:Disconnect()
end)

t.test("a value of the wrong kind is refused in Lua, with the place and what it has to be", function()
    local writes = fake.writes
    as(A, function()
        t.raises(function() crafts:Set("Chair", "Count", 1.5) end, "Count is a whole number, got 1.5")
        t.raises(function() crafts:Set("Chair", "Count", "3") end, "Count is a whole number, got \"3\"")
        t.raises(function() crafts:Set("Chair", "Count", {}) end, "Count is a whole number, got a table")
        t.raises(function() crafts:Set("Chair", "bFlag", 0) end, "bFlag is true or false, got 0")
        t.raises(function() crafts:Set("Chair", "Small", 256) end, "Small holds 0 to 255, got 256")
        t.raises(function() crafts:Set("Chair", "Tiny", -129) end, "Tiny holds -128 to 127, got -129")
        t.raises(function() crafts:Set("Chair", "Wide", -1) end, "Wide holds 0 to 4294967295, got -1")
        t.raises(function() crafts:Set("Chair", "Ratio", 0 / 0) end, "Ratio is a number")
        t.raises(function() crafts:Set("Chair", "Ratio", "fast") end, "Ratio is a number, got \"fast\"")
        t.raises(function() crafts:Set("Chair", "Note", 5) end, "Note is a string, got 5")
        t.raises(function() crafts:Set("Chair", "Label", 5) end, "Label is a name, given as a string, got 5")
        t.raises(function() crafts:Set("Chair", "Mode", -1) end, "Mode is an enum")
        t.raises(function() crafts:Set("Chair", "Mode", 1.5) end, "Mode is an enum")
        -- a number the enum does not have, also one that would be cut to fit the field
        t.raises(function() crafts:Set("Chair", "Mode", 3) end, "Mode has no value with the number 3. It takes Slow (0), Fast (1), Instant (2)")
        t.raises(function() crafts:Set("Chair", "Mode", 99) end, "Mode has no value with the number 99")
        t.raises(function() crafts:Set("Chair", "Mode", 300) end, "Mode has no value with the number 300")
        t.raises(function() crafts:Set("Chair", "Kinds", { 0, 9 }) end, "Kinds[2] has no value with the number 9. It takes Soft (0), Hard (1)")
        t.raises(function() crafts:Set("Chair", "Kinds", { 0, 1, 9 }) end, "Kinds[3] has no value with the number 9")
        -- a float is kept in single precision: a number past its range would be stored as infinity
        t.raises(function() crafts:Set("Chair", "Ratio", 1e39) end, "Ratio holds numbers up to 3.4e38 either side of zero, got 1e+39")
        t.raises(function() crafts:Set("Chair", "Ratio", -1e39) end, "Ratio holds numbers up to 3.4e38")
        t.raises(function() crafts:Set("Chair", "Ratio", math.huge) end, "Ratio is a number")
    end)
    t.eq(fake.writes, writes, "nothing reached the game")
    t.eq(fake.sloppy, 0)
end)

t.test("a number an enum already holds may stay although it has no name, and the largest float is taken and put back", function()
    local ratio, writes = chair().Ratio, fake.writes
    as(B, function()
        crafts:Set("Stool", "Mode", 7)
        t.eq(fake.writes, writes, "what the field holds already is not written")
        crafts:Set("Stool", "Kinds", { 5, 0 })
        t.eq(table.concat(fake.row("Crafts", "Stool").Kinds, ","), "5,0", "also in a list that gets longer")
        t.raises(function() crafts:Set("Stool", "Kinds", { 5, 6 }) end, "Kinds[2] has no value with the number 6")
        t.raises(function() crafts:Set("Stool", "Mode", 8) end, "Mode has no value with the number 8")
        crafts:Set("Chair", "Ratio", 0x1.fffffep127)
        t.eq(chair().Ratio, 0x1.fffffep127, "the largest float")
        t.eq(crafts:Reset("Chair", "Ratio"), 1)
        t.eq(chair().Ratio, ratio)
        t.eq(crafts:Reset("Stool"), 2)
    end)
    t.eq(table.concat(fake.row("Crafts", "Stool").Kinds, ","), "5")
    -- a field that holds infinity is not the same as every number: it can be changed and put back
    local kept = fake.row("Crafts", "Table").Ratio
    fake.row("Crafts", "Table").Ratio = math.huge
    as(B, function()
        crafts:Set("Table", "Ratio", 2.5)
        t.eq(desk().Ratio, 2.5)
        t.eq(crafts:Reset("Table", "Ratio"), 1)
    end)
    t.eq(desk().Ratio, math.huge, "the game's own value is back")
    fake.row("Crafts", "Table").Ratio = kept
    frame()
end)

t.test("text, references to assets, maps, objects and doubles cannot be changed in this version, and the error says so", function()
    local writes = fake.writes
    as(A, function()
        t.raises(function() crafts:Set("Chair", "Title", "Stool") end, "Title is text, which this version of Wax cannot change")
        t.raises(function() crafts:Set("Chair", "Icon", "/Game/B.B") end, "Icon is a reference to an asset, which this version of Wax cannot change")
        t.raises(function() crafts:Set("Chair", "Extras", {}) end, "Extras is a Map field, which this version of Wax cannot change")
        t.raises(function() crafts:Set("Chair", "Preview", {}) end, "Preview is an Object field")
        t.raises(function() crafts:Set("Chair", "Precise", 2.5) end, "Precise is a Double field")
        t.raises(function() crafts:Set("Chair", "Titles", { "A", "B" }) end, "Titles is text")
        t.raises(function() crafts:Set("Chair", "Icons", { "/Game/A.A", false }) end, "Icons is a reference to an asset")
        t.raises(function() crafts:Set("Chair", "CachedHardReferences", {}) end, "CachedHardReferences is an array of Object")
        t.raises(function() crafts:Change("Chair", "Title", function(value) return value end) end, "Title is text")
    end)
    t.eq(fake.writes, writes)
    t.eq(fake.never_reads, 0, "none of them was even read")
end)

t.test("an enum takes its number or its name, and the global UE4SS leaves behind is taken away", function()
    as(A, function()
        crafts:Set("Chair", "Mode", "Instant")
        t.eq(chair().Mode, 2)
        crafts:Set("Chair", "Mode", "fast")
        t.eq(chair().Mode, 1)
        crafts:Set("Chair", "Mode", "EMode::Slow")
        t.eq(chair().Mode, 0)
        Data:Flush()
        crafts:Set("Chair", "Mode", "Instant")
        t.eq(chair().Mode, 2, "the names are still known after game.Data forgot what it had read")
        local err = t.raises(function() crafts:Set("Chair", "Mode", "Fas") end, "Mode has no value named 'Fas'")
        t.ok(tostring(err):find("'Fast'", 1, true), "suggests the name: " .. tostring(err))
        t.raises(function() crafts:Set("Chair", "Mode", "EMode_MAX") end, "Mode has no value named 'EMode_MAX'")
        t.raises(function() crafts:Set("Chair", "Plain", "Anything") end, "Plain is an enum and takes its number here")
        crafts:Set("Chair", "Plain", 3)
        t.eq(chair().Plain, 3, "an enum whose names are not known takes any number")
    end)
    t.eq(rawget(_G, "Enum_Mode"), nil)
    t.eq(rawget(_G, "Enum_Plain"), nil)
end)

t.test("an enum that was never read takes its number only, until the game may be asked for the enum itself", function()
    t.eq(patch.FIND_ENUMS, false, "off until GetEnum has been seen to work for a list")
    local finds = fake.enum_finds
    as(A, function()
        -- no row has an entry in Grades or Marks, so no value of these enums was ever handed out
        t.raises(function() crafts:Set("Table", "Grades", { "High" }) end, "Grades[1] is an enum and takes its number here, got \"High\"")
        t.raises(function() crafts:Set("Table", "Marks", { { Level = "Silver", Points = 3 } }) end,
            "Marks[1].Level is an enum and takes its number here")
        t.eq(fake.enum_finds, finds, "the game was not asked")
        patch.FIND_ENUMS = true
        crafts:Set("Table", "Grades", { "High", "low" })
        t.eq(table.concat(desk().Grades, ","), "1,0")
        crafts:Set("Table", "Marks", { { Level = "Silver", Points = 3 } })
        t.eq(desk().Marks[1].Level, 1)
        t.eq(desk().Marks[1].Points, 3)
        t.eq(fake.enum_finds, finds + 2, "each enum was asked for once")
        t.raises(function() crafts:Set("Table", "Grades", { "Middling" }) end, "Grades[1] has no value named 'Middling'")
        t.raises(function() crafts:Set("Table", "Grades", { 2 }) end, "Grades[1] has no value with the number 2. It takes Low (0), High (1)")
        t.raises(function() crafts:Set("Chair", "Plain", "Anything") end, "Plain is an enum and takes its number here")
        patch.FIND_ENUMS = false
        t.eq(crafts:Reset("Table"), 2)
    end)
    t.eq(#desk().Grades, 0)
    t.eq(#desk().Marks, 0)
    t.eq(rawget(_G, "Enum_Grades"), nil)
    t.eq(rawget(_G, "Enum_Level"), nil)
    t.eq(fake.misuse + fake.stale + fake.crashes, 0)
end)

t.test("field names are matched without regard to letter case and written as the game spells them", function()
    as(A, function()
        crafts:Set("Chair", "Position", 9)
        t.eq(chair().position, 9)
        t.eq(changes_of(crafts, "Chair").position.Now, 9, "listed under the game's spelling")
        crafts:Set("chair", "NOTE", "any case")
        t.eq(chair().Note, "any case")
        crafts:Set("Chair", "Bench", { rowname = "Kitchen_Bench" })
        t.eq(chair().Bench.RowName, "Kitchen_Bench", "a key inside a value too")
        t.raises(function() crafts:Set("Chair", "Bench", { RowName = "Character", rowname = "Kitchen_Bench" }) end, "Bench names RowName twice")
        -- the same mistake in a table of fields: two keys that mean one field
        local count = chair().Count
        t.raises(function() crafts:Set("Chair", { Count = 1, count = 2 }) end, "Count is named twice, as \"Count\" and \"count\"")
        t.raises(function() crafts:Set("Chair", { NOTE = "a", Note = "b", Count = 1 }) end, "Note is named twice, as \"NOTE\" and \"Note\"")
        t.eq(chair().Count, count, "and nothing was written")
    end)
    t.eq(crafts:Row("Chair", { "Position" }).position, 9, "and read the same way")
    t.eq(crafts:Row("Chair", { "POSITION", "bench.ROWNAME" }).Bench.RowName, "Kitchen_Bench")
    t.eq(crafts:Fields("INFO")[2].Name, "Weight")
    t.eq(fake.silent, 0, "no key was dropped by the game without a word")
end)

t.test("a row handle names its own table and no other, its row is checked, and both are written as the game spells them", function()
    as(A, function()
        crafts:Set("Chair", "Bench", { RowName = "character" })
        t.eq(chair().Bench.RowName, "Character")
        t.eq(chair().Bench.DataTableName, "D_RecipeSets")
        local err = t.raises(function() crafts:Set("Chair", "Bench", { RowName = "Kitchen_Bnch" }) end,
            "Bench.RowName: RecipeSets has no row named 'Kitchen_Bnch'")
        t.ok(tostring(err):find("'Kitchen_Bench'", 1, true), "suggests the row: " .. tostring(err))
        crafts:Set("Chair", "Bench", { RowName = "None" })
        t.eq(chair().Bench.RowName, "None")
        crafts:Set("Chair", "Bench", { RowName = "" })
        t.eq(chair().Bench.RowName, "None", "an empty name is None")
        -- its own table may be given, in any spelling, and is written as the game lists it
        for _, spelling in ipairs({ "D_RecipeSets", "RecipeSets", "d_recipesets" }) do
            crafts:Set("Chair", "Bench", { RowName = "Kitchen_Bench", DataTableName = spelling })
            t.eq(chair().Bench.DataTableName, "D_RecipeSets", spelling)
        end
        t.eq(chair().Bench.RowName, "Kitchen_Bench")
        -- another table is refused, whether the game has it or not, and whatever the row
        t.raises(function() crafts:Set("Chair", "Bench", { RowName = "Wood", DataTableName = "D_ItemsStatic" }) end,
            "Bench is a handle into D_RecipeSets and cannot name the table D_ItemsStatic. Leave DataTableName out, or give D_RecipeSets")
        t.raises(function() crafts:Set("Chair", "Bench", { RowName = "None", DataTableName = "D_ItemsStatic" }) end,
            "Bench is a handle into D_RecipeSets and cannot name the table D_ItemsStatic")
        t.raises(function() crafts:Set("Chair", "Bench", { RowName = "Character", DataTableName = "D_NoSuchTable" }) end,
            "Bench is a handle into D_RecipeSets and cannot name the table D_NoSuchTable")
        t.raises(function() crafts:Set("Chair", "Bench", { RowName = "Character", DataTableName = "None" }) end,
            "Bench.RowName names the row 'Character' but no table")
        crafts:Set("Chair", "Bench", { RowName = "None", DataTableName = "None" })
        t.eq(chair().Bench.DataTableName, "D_RecipeSets", "a typed handle that points at nothing keeps the table it names")
        t.raises(function() crafts:Set("Chair", "Bench", { RowName = "Character", DataTablePtr = 1 }) end,
            "Bench.DataTablePtr is a WeakObject field, which this version of Wax cannot change")
        -- in a list as well: the handle of an output, which names the template table, is no input
        t.raises(function()
            crafts:Set("Chair", "Inputs", { { Element = { RowName = "Plank", DataTableName = "D_ItemTemplate" }, Count = 1 },
                { Element = { RowName = "Fish_03" }, Count = 1 } })
        end, "Inputs[1].Element is a handle into D_ItemsStatic and cannot name the table D_ItemTemplate")
        t.raises(function()
            recipes:Set("Bone_Knife", "Requirement", { RowName = "Wood", DataTableName = "D_ItemsStatic" })
        end, "Requirement is a handle into D_Talents and cannot name the table D_ItemsStatic")
        -- the pair of table and row a field of the game already holds may be written back, and nothing else under that table
        crafts:Set("Chair", "Odd", { RowName = "None", DataTableName = "D_Talents" })
        t.eq(chair().Odd.DataTableName, "D_Talents")
        t.raises(function() crafts:Set("Chair", "Odd", { RowName = "Bone_Knife", DataTableName = "D_Talents" }) end,
            "Odd is a handle into D_RecipeSets and cannot name the table D_Talents")
        t.raises(function() crafts:Set("Chair", "Odd", { RowName = "Character" }) end,
            "Odd: pointing a row handle at another table than it names now is switched off in this version of Wax")
    end)
    t.eq(fake.crashes, 0, "no string ever reached a name slot")
end)

t.test("a handle of no one table takes any table the game has, spelled as the game lists it, and a wrong one gets the nearest", function()
    as(A, function()
        crafts:Set("Chair", "Loose", { RowName = "Kit_Radar" })
        t.eq(chair().Loose.RowName, "Kit_Radar")
        t.eq(chair().Loose.DataTableName, "D_ItemsStatic", "it keeps the table it names")
        crafts:Set("Chair", "Loose", { RowName = "Wood", DataTableName = "itemsstatic" })
        t.eq(chair().Loose.RowName, "Wood")
        t.eq(chair().Loose.DataTableName, "D_ItemsStatic", "the same table in another spelling is no other table")
        local err = t.raises(function() crafts:Set("Chair", "Loose", { RowName = "Wood", DataTableName = "D_ItemStatic" }) end,
            "Loose.DataTableName names the table D_ItemStatic, which the game does not have. Did you mean 'D_ItemsStatic'?")
        t.ok(tostring(err):find("patch_test.lua", 1, true), "points at the caller: " .. tostring(err))
        t.raises(function() crafts:Set("Chair", "Loose", { RowName = "Wood", DataTableName = "itemstatic" }) end, "Did you mean 'D_ItemsStatic'?")
        err = t.raises(function() crafts:Set("Chair", "Loose", { RowName = "Character", DataTableName = "D_NoSuchTable" }) end,
            "Loose.DataTableName names the table D_NoSuchTable, which the game does not have")
        t.ok(not tostring(err):find("Did you mean", 1, true), "nothing is near: " .. tostring(err))
        t.raises(function() crafts:Set("Chair", "Loose", { RowName = "None", DataTableName = "D_NoSuchTable" }) end,
            "Loose.DataTableName names the table D_NoSuchTable", "a made-up table is refused also for a handle that points at nothing")
        t.raises(function() crafts:Set("Chair", "Loose", { RowName = "Character", DataTableName = "None" }) end,
            "Loose.RowName names the row 'Character' but no table")
        t.raises(function() crafts:Set("Chair", "Outputs", { { Element = { RowName = "Plank", DataTableName = "D_ItemTemplte" }, Count = 1,
            Notes = { "sand it" }, Parts = { { Element = { RowName = "Wood" }, Count = 2 } }, Tag = "main" } }) end,
            "Outputs[1].Element is a handle into D_ItemTemplate and cannot name the table D_ItemTemplte")
        -- another table for a handle that names one already: the pointer the handle keeps is not written, so that waits for its switch
        t.eq(patch.WRITES.handle_tables, false, "off until the game has shown which of the two it reads")
        t.raises(function() crafts:Set("Chair", "Loose", { RowName = "Kitchen_Bench", DataTableName = "d_recipesets" }) end,
            "Loose: pointing a row handle at another table than it names now is switched off in this version of Wax")
        t.eq(chair().Loose.DataTableName, "D_ItemsStatic")
        patch.WRITES.handle_tables = true
        crafts:Set("Chair", "Loose", { RowName = "Kitchen_Bench", DataTableName = "d_recipesets" })
        t.eq(chair().Loose.RowName, "Kitchen_Bench")
        t.eq(chair().Loose.DataTableName, "D_RecipeSets", "written as the game lists the table")
        patch.WRITES.handle_tables = false
    end)
    t.eq(fake.crashes, 0)
end)

t.test("a row enum is checked against its table, and a multi row handle takes any name with its table as a number or a name", function()
    as(A, function()
        crafts:Set("Chair", "Resource", { Value = "milk" })
        t.eq(chair().Resource.Value, "Milk")
        t.raises(function() crafts:Set("Chair", "Resource", { Value = "Beer" }) end, "Resource.Value: IcarusResources has no row named 'Beer'")
        crafts:Set("Chair", "Gate", { RowName = "Any_Flag_At_All", DataTableName = 2 })
        t.eq(chair().Gate.RowName, "Any_Flag_At_All")
        t.eq(chair().Gate.DataTableName, 2)
        crafts:Set("Chair", "Gate", { RowName = "Any_Flag_At_All", DataTableName = "D_DLCPackageData" })
        t.eq(chair().Gate.DataTableName, 3)
        -- Row leaves an enum inside a struct out, so a value copied from Row lacks it. The error says why
        local read = crafts:Row("Chair").Gate
        t.eq(read.DataTableName, nil)
        t.raises(function() crafts:Set("Chair", "Gate", { RowName = read.RowName }) end,
            "Gate lacks DataTableName. Give the whole value, or use Change to alter a part of it (Row reads an enum only when its path is named)")
        t.eq(crafts:Row("Chair", { "Gate.DataTableName" }).Gate.DataTableName, 3, "and its own path gives it")
        t.raises(function() crafts:Set("Chair", "Gate", { RowName = "X", DataTableName = 9 }) end,
            "Gate.DataTableName has no value with the number 9")
    end)
end)

t.test("a name the game's own row already holds may stay although its table has no such row, and no new one may come", function()
    as(A, function()
        crafts:Change("Ghost", "Inputs", function(inputs)
            inputs[1].Count = 5
            return inputs
        end)
        t.eq(fake.row("Crafts", "Ghost").Inputs[1].Count, 5)
        t.eq(fake.row("Crafts", "Ghost").Inputs[1].Element.RowName, "Phantom_Wood")
        t.raises(function() crafts:Set("Ghost", "Inputs", { { Element = { RowName = "Phantom_Stone" }, Count = 1 } }) end,
            "Inputs[1].Element.RowName: ItemsStatic has no row named 'Phantom_Stone'")
    end)
end)

t.test("a struct is given whole: a part left out, a key it does not have and text that differs are errors", function()
    as(A, function()
        t.raises(function() crafts:Set("Chair", "Info", { Weight = 5 }) end, "Info lacks Maker. Give the whole value, or use Change")
        crafts:Set("Chair", "Info", { Weight = 5, Maker = { RowName = "Character" } })
        t.eq(chair().Info.Weight, 5)
        t.eq(chair().Info.Maker.RowName, "Character")
        t.eq(chair().Info.Title, "A chair", "the text inside stays")
        crafts:Set("Chair", "Info", { Title = "A chair", Weight = 6, Maker = { RowName = "Character" } })
        t.eq(chair().Info.Weight, 6, "text given as it is, is fine")
        t.raises(function() crafts:Set("Chair", "Info", { Title = "A stool", Weight = 6, Maker = { RowName = "Character" } }) end,
            "Info.Title is text, which this version of Wax cannot change")
        local err = t.raises(function() crafts:Set("Chair", "Info", { Weight = 6, Maker = { RowName = "Character" }, Wieght = 1 }) end,
            "Info has no field named \"Wieght\"")
        t.ok(tostring(err):find("'Weight'", 1, true), tostring(err))
        t.raises(function() crafts:Set("Chair", "Info", "heavy") end, "Info is a table of fields, got \"heavy\"")
        t.raises(function() crafts:Set("Chair", "Info", { Weight = 6, Maker = "Character" }) end, "Info.Maker is a table of fields")
        local changed = changes_of(crafts, "Chair").Info
        t.eq(changed.Now.Title, "A chair", "what Changes shows is the whole value")
        t.eq(changed.Was.Weight, 12)
        changed.Now.Weight = 999
        t.eq(changes_of(crafts, "Chair").Info.Now.Weight, 6, "and a copy")
    end)
end)

t.test("a list of the same length is changed in place, and only what differs is written", function()
    local writes, appends, empties = fake.writes, fake.appends, fake.empties
    as(A, function()
        crafts:Change("Chair", "Inputs", function(inputs)
            inputs[2].Count = 9
            return inputs
        end)
        t.eq(fake.writes, writes + 1, "one number")
        crafts:Set("Chair", "Inputs", { { Element = { RowName = "Kit_Radar" }, Count = 4 }, { Element = { RowName = "Fish_03" }, Count = 9 } })
        t.eq(fake.writes, writes + 2, "and one name")
    end)
    t.eq(chair().Inputs[1].Element.RowName, "Kit_Radar")
    t.eq(chair().Inputs[1].Element.DataTableName, "D_ItemsStatic")
    t.eq(chair().Inputs[2].Count, 9)
    t.eq(fake.appends, appends, "no entry was added")
    t.eq(fake.empties, empties, "and the list was not emptied")
end)

t.test("making a list longer or shorter is behind its own switch, as plain fields and names are", function()
    t.eq(patch.WRITES.lists, true, "the game was seen to take it")
    patch.WRITES.lists = false
    local writes = fake.writes
    as(A, function()
        t.raises(function() crafts:Set("Chair", "Steps", { 1, 2 }) end,
            "Steps: making a list longer or shorter is switched off in this version of Wax")
        t.raises(function() crafts:Change("Chair", "Inputs", function(inputs)
            inputs[3] = { Element = { RowName = "Wood" }, Count = 1 }
            return inputs
        end) end, "Inputs: making a list longer or shorter is switched off")
        crafts:Set("Chair", "Steps", { 3, 2, 1 })
    end)
    t.eq(table.concat(chair().Steps, ","), "3,2,1", "the same length is still fine")
    t.eq(fake.writes, writes + 2, "3 and 1 changed places, 2 stayed")
    patch.WRITES.plain = false
    as(A, function()
        t.raises(function() crafts:Set("Chair", "Count", 11) end, "Count: changing numbers, switches and strings is switched off")
    end)
    patch.WRITES.plain, patch.WRITES.names = true, false
    as(A, function()
        t.raises(function() crafts:Set("Chair", "Label", "Bench") end, "Label: changing names and row handles is switched off")
        crafts:Set("Chair", "Count", 11)
    end)
    patch.WRITES.names, patch.WRITES.lists = true, true
    t.eq(chair().Count, 11)
    t.eq(chair().Label, "Seat")
end)

t.test("more than four entries, entries that can own memory, and a list inside another value are behind switches of their own", function()
    t.eq(patch.WRITES.long_lists, false, "off until the game has shown that it works")
    t.eq(patch.WRITES.owning_lists, false, "the game was only seen to take entries of numbers, names and handles")
    t.eq(patch.WRITES.nested_lists, true, "on since a tag list of a new row was grown in the game")
    patch.WRITES.nested_lists = false
    local writes, assigns = fake.writes, fake.assigns
    as(A, function()
        t.raises(function() crafts:Set("Chair", "Steps", { 1, 2, 3, 4, 5 }) end,
            "Steps: making a list longer or shorter while it has more than 4 entries, before or after, is switched off")
        t.raises(function() crafts:Set("Stool", "Lines", { "one" }) end,
            "Lines: making a list longer or shorter while it has more than 4 entries")
        -- a list of strings, and a list whose entries can hold a string or lists, however empty those are before and after
        t.raises(function() crafts:Set("Chair", "Lines", { "cut" }) end,
            "Lines: making a list longer or shorter whose entries are strings, or can hold strings or lists of their own, is switched off")
        t.raises(function()
            crafts:Set("Table", "Outputs", { { Element = { RowName = "Plank" }, Count = 2, Notes = {}, Parts = {}, Tag = "" },
                { Element = { RowName = "Glue" }, Count = 3, Notes = {}, Parts = {}, Tag = "" } })
        end, "Outputs: making a list longer or shorter whose entries are strings, or can hold strings or lists of their own")
        t.raises(function()
            crafts:Set("Chair", "Outputs", { { Element = { RowName = "Nail" }, Count = 1, Notes = {}, Parts = {}, Tag = "" },
                { Element = { RowName = "Glue" }, Count = 1, Notes = {}, Parts = {}, Tag = "" } })
        end, "Outputs: making a list longer or shorter whose entries are strings, or can hold strings or lists of their own")
        -- a list inside an entry that stays
        t.raises(function()
            crafts:Change("Chair", "Outputs", function(outputs)
                outputs[1].Notes[2] = "oil it"
                return outputs
            end)
        end, "Outputs: making a list longer or shorter inside another value")
        patch.WRITES.owning_lists = true
        -- the entry of Chair's Outputs holds lists of its own, which would have to be emptied first
        t.raises(function()
            crafts:Set("Chair", "Outputs", { { Element = { RowName = "Nail" }, Count = 1, Notes = {}, Parts = {}, Tag = "" },
                { Element = { RowName = "Glue" }, Count = 1, Notes = {}, Parts = {}, Tag = "" } })
        end, "Outputs: making a list longer or shorter inside another value, or while its entries hold lists of their own, is switched off")
        t.eq(fake.writes, writes, "nothing was written")
        -- entries whose own lists are empty before and after go in as one table each
        crafts:Set("Table", "Outputs", { { Element = { RowName = "Plank" }, Count = 2, Notes = {}, Parts = {}, Tag = "a" },
            { Element = { RowName = "Glue" }, Count = 3, Notes = {}, Parts = {}, Tag = "" } })
        crafts:Set("Chair", "Steps", { 1, 2, 3, 4 })
    end)
    local outputs = desk().Outputs
    t.eq(#outputs, 2)
    t.eq(outputs[1].Element.RowName, "Plank")
    t.eq(outputs[1].Element.DataTableName, "D_ItemTemplate")
    t.eq(outputs[1].Count, 2)
    t.eq(outputs[1].Tag, "a")
    t.eq(outputs[2].Element.RowName, "Glue")
    t.eq(outputs[2].Count, 3)
    t.eq(fake.assigns, assigns + 8, "Empty and one assignment an entry: three for the two outputs, five for the four steps")
    t.eq(table.concat(chair().Steps, ","), "1,2,3,4")
    as(A, function()
        t.eq(crafts:Reset("Table", "Outputs"), 1)
        t.eq(crafts:Reset("Chair", "Steps"), 1)
    end)
    t.eq(#desk().Outputs, 1)
    t.eq(desk().Outputs[1].Element.RowName, "Nail")
    t.eq(table.concat(chair().Steps, ","), "1,2,3")
    t.eq(fake.leaks, 0)
    t.eq(fake.crashes, 0)
    patch.WRITES.owning_lists = false
end)

t.test("a list whose entries hold a reference to an asset or a map keeps its length, as one of row enums or text does", function()
    as(A, function()
        crafts:Change("Chair", "Sounds", function(sounds)
            sounds[1].Volume = 9
            return sounds
        end)
        t.eq(chair().Sounds[1].Volume, 9)
        t.eq(chair().Sounds[1].Sound, "/Game/Sounds/Saw.Saw", "the reference stays")
        t.raises(function()
            crafts:Change("Chair", "Sounds", function(sounds)
                sounds[2] = { Volume = 1 }
                sounds[3] = { Volume = 2 }
                return sounds
            end)
        end, "Sounds has 1 entry and would get 3. Wax cannot make or remove entries of this kind yet")
        t.raises(function() crafts:Set("Chair", "Sounds", {}) end, "Sounds has 1 entry and would get 0")
        crafts:Set("Chair", "Rewards", { { Amount = 5 } })
        t.eq(chair().Rewards[1].Amount, 5)
        t.raises(function() crafts:Set("Chair", "Rewards", { { Amount = 5 }, { Amount = 6 }, { Amount = 7 } }) end,
            "Rewards has 1 entry and would get 3")
        t.raises(function() crafts:Set("Chair", "Rewards", { { Amount = 5, Extras = {} } }) end,
            "Rewards[1].Extras is a Map field, which this version of Wax cannot change")
        t.raises(function() crafts:Set("Table", "Sounds", { { Volume = 1 } }) end,
            "Sounds has 0 entries and would get 1")
    end)
    t.eq(#chair().Sounds, 1)
    t.eq(#chair().Rewards, 1)
    t.eq(fake.crashes + fake.misuse + fake.never_reads, 0, "the game was never asked to make or read such an entry")
end)

patch.WRITES.long_lists, patch.WRITES.owning_lists, patch.WRITES.nested_lists = true, true, true

t.test("a list of plain structs that changes length is emptied and filled entry by entry", function()
    local empties, appends = fake.empties, fake.appends
    as(A, function()
        crafts:Change("Chair", "Inputs", function(inputs)
            inputs[#inputs + 1] = { Element = { RowName = "Wood" }, Count = 2 }
            return inputs
        end)
    end)
    local inputs = chair().Inputs
    t.eq(#inputs, 3)
    t.eq(inputs[1].Element.RowName, "Kit_Radar", "what was there is written again")
    t.eq(inputs[3].Element.RowName, "Wood")
    t.eq(inputs[3].Element.DataTableName, "D_ItemsStatic", "a new entry starts as zeroes, so its table name is written too")
    t.eq(inputs[3].Count, 2)
    t.eq(fake.empties, empties + 1)
    t.eq(fake.appends, appends + 3)
    as(A, function() crafts:Set("Chair", "Inputs", { { Element = { RowName = "Wood" }, Count = 1 } }) end)
    t.eq(#chair().Inputs, 1, "shorter")
    as(A, function() crafts:Set("Chair", "Inputs", {}) end)
    t.eq(#chair().Inputs, 0, "empty")
    empties = fake.empties
    as(A, function()
        crafts:Set("Chair", "Inputs", { { Element = { RowName = "Fish_03" }, Count = 3 }, { Element = { RowName = "Wood" }, Count = 4 } })
    end)
    t.eq(#chair().Inputs, 2)
    t.eq(chair().Inputs[2].Count, 4)
    t.eq(fake.empties, empties, "an empty list is not emptied again")
    t.eq(fake.grown, 0, "no list was ever made longer by reading past its end")
    t.eq(fake.crashes, 0)
end)

t.test("entries that hold lists of their own give them back before the list is emptied, and get theirs filled after", function()
    as(A, function()
        crafts:Set("Chair", "Outputs", {
            { Element = { RowName = "Plank" }, Count = 2, Notes = { "a", "b" }, Parts = { { Element = { RowName = "Wood" }, Count = 1 } }, Tag = "x" },
            { Element = { RowName = "Nail" }, Count = 8, Notes = {}, Parts = {}, Tag = "" },
        })
    end)
    local outputs = chair().Outputs
    t.eq(#outputs, 2)
    t.eq(outputs[1].Element.RowName, "Plank")
    t.eq(outputs[1].Element.DataTableName, "D_ItemTemplate")
    t.eq(table.concat(outputs[1].Notes, ","), "a,b")
    t.eq(outputs[1].Parts[1].Element.RowName, "Wood")
    t.eq(outputs[1].Parts[1].Count, 1)
    t.eq(outputs[1].Tag, "x")
    t.eq(outputs[2].Count, 8)
    t.eq(#outputs[2].Notes, 0)
    t.eq(#outputs[2].Parts, 0)
    t.eq(fake.leaks, 0, "Empty frees a list without what its entries own, so that was given back first")
    as(A, function()
        crafts:Change("Chair", "Outputs", function(list)
            list[1].Notes[3] = "c"
            list[2].Parts[1] = { Element = { RowName = "Fish_03" }, Count = 5 }
            return list
        end)
    end)
    outputs = chair().Outputs
    t.eq(table.concat(outputs[1].Notes, ","), "a,b,c", "a list inside an entry that stays is changed where it is")
    t.eq(outputs[2].Parts[1].Element.RowName, "Fish_03")
    t.eq(outputs[1].Count, 2)
    t.eq(fake.leaks, 0)
    t.eq(fake.crashes, 0)
end)

t.test("every entry of a list is whole, and a list is a list", function()
    local writes = fake.writes
    as(A, function()
        t.raises(function() crafts:Set("Chair", "Inputs", { { Element = { RowName = "Wood" } } }) end, "Inputs[1] lacks Count")
        t.raises(function() crafts:Set("Chair", "Inputs", { { Count = 1 } }) end, "Inputs[1] lacks Element")
        t.raises(function() crafts:Set("Chair", "Inputs", { { Element = { RowName = "Wood" }, Count = 1, Extra = 1 } }) end,
            "Inputs[1] has no field named \"Extra\"")
        t.raises(function() crafts:Set("Chair", "Inputs", { first = {} }) end, "Inputs is a list, which has no place for the key \"first\"")
        t.raises(function() crafts:Set("Chair", "Inputs", "none") end, "Inputs is a list, got \"none\"")
        t.raises(function() crafts:Set("Chair", "Steps", { 1, "two" }) end, "Steps[2] is a whole number, got \"two\"")
        local err = t.raises(function() crafts:Set("Chair", "Steps", { 1, nil, 3 }) end)
        t.ok(tostring(err):find("Steps has no entry 2", 1, true) or tostring(err):find("no place for the key 3", 1, true), tostring(err))
        t.raises(function() crafts:Set("Chair", "Outputs", { { Element = { RowName = "Plank" }, Count = 1, Notes = {}, Tag = "" } }) end,
            "Outputs[1] lacks Parts")
    end)
    t.eq(fake.writes, writes)
end)

t.test("a list whose entries start with a vtable pointer keeps its length: its entries change in place, and no more", function()
    as(A, function()
        crafts:Change("Chair", "Costs", function(costs)
            costs[1].RequiredUnits = 99
            costs[2].Type.Value = "oxygen"
            return costs
        end)
        t.eq(chair().Costs[1].RequiredUnits, 99)
        t.eq(chair().Costs[2].Type.Value, "Oxygen")
        local err = t.raises(function()
            crafts:Change("Chair", "Costs", function(costs)
                costs[3] = { Type = { Value = "Water" }, RequiredUnits = 1 }
                return costs
            end)
        end, "Costs has 2 entries and would get 3. Wax cannot make or remove entries of this kind yet, only change the ones that are there")
        t.ok(tostring(err):find("patch_test.lua", 1, true), "points at the caller: " .. tostring(err))
        t.raises(function() crafts:Set("Chair", "Costs", {}) end, "Costs has 2 entries and would get 0")
        t.raises(function() crafts:Set("Chair", "Costs", { { Type = { Value = "Water" }, RequiredUnits = 1 } }) end,
            "Costs has 2 entries and would get 1")
    end)
    t.eq(#chair().Costs, 2)
    t.eq(fake.crashes, 0, "the game was never asked to make such an entry")
    t.eq(fake.misuse, 0)
end)

t.test("a list of structs that hold text keeps its length too, and its numbers still change", function()
    as(A, function()
        crafts:Change("Chair", "Pages", function(pages)
            pages[2].Number = 20
            return pages
        end)
        t.eq(chair().Pages[2].Number, 20)
        t.eq(chair().Pages[2].Title, "Two")
        t.raises(function()
            crafts:Change("Chair", "Pages", function(pages)
                pages[1].Title = "Uno"
                return pages
            end)
        end, "Pages[1].Title is text, which this version of Wax cannot change")
        t.raises(function()
            crafts:Change("Chair", "Pages", function(pages)
                pages[3] = { Number = 3 }
                return pages
            end)
        end, "Pages has 2 entries and would get 3")
    end)
end)

t.test("lists of names, numbers, strings, switches and enums grow and shrink", function()
    as(A, function()
        crafts:Set("Chair", "Tags", { "Wooden", "Seat", "Brown" })
        crafts:Set("Chair", "Steps", { 5 })
        crafts:Set("Chair", "Lines", { "cut", "glue", "paint" })
        crafts:Set("Chair", "Flags", {})
        crafts:Set("Chair", "Kinds", { 1, "Soft", "hard" })
    end)
    local row = chair()
    t.eq(table.concat(row.Tags, ","), "Wooden,Seat,Brown")
    t.eq(table.concat(row.Steps, ","), "5")
    t.eq(table.concat(row.Lines, ","), "cut,glue,paint")
    t.eq(#row.Flags, 0)
    t.eq(table.concat(row.Kinds, ","), "1,0,1")
    t.eq(fake.leaks, 0, "the strings of a list were given back before it was emptied")
    t.eq(rawget(_G, "Enum_Kinds"), nil)
end)

t.test("when the game does not take a write, the old value is put back and the error says what differed", function()
    local before = desk().Count
    fake.deaf("Crafts", "Table", "Count")
    as(A, function()
        t.raises(function() crafts:Set("Table", "Count", 77) end,
            "the game did not take the change of Crafts.Table.Count: Count reads " .. before .. ", not 77. The old value was put back")
    end)
    fake.deaf("Crafts", "Table", "Count", false)
    t.eq(desk().Count, before)
    t.eq(changes_of(crafts, "Table").Count, nil, "nothing is recorded for a change that did not happen")
    as(A, function() crafts:Set("Table", "Count", 77) end)
    t.eq(desk().Count, 77)
    as(A, function() t.eq(crafts:Reset("Table", "Count"), 1) end)
    t.eq(desk().Count, before)
    t.eq(patch.stats().put_back, 1)
end)

t.test("a write that fails half way through a list leaves the list as it was", function()
    local function names()
        local out = {}
        for index, entry in ipairs(desk().Inputs) do out[index] = entry.Element.RowName .. "x" .. entry.Count end
        return table.concat(out, ",")
    end
    t.eq(names(), "Woodx8,Kit_Radarx1")
    -- lets through: Empty and the first two entries. The fourth write, the third entry, raises
    fake.break_write("Crafts", "Table", "Inputs", 3)
    as(A, function()
        local err = t.raises(function()
            crafts:Set("Table", "Inputs", { { Element = { RowName = "Fish_03" }, Count = 1 }, { Element = { RowName = "Wood" }, Count = 2 },
                { Element = { RowName = "Kit_Radar" }, Count = 3 } })
        end, "the game did not take the change of Crafts.Table.Inputs: the engine refused to write")
        t.ok(tostring(err):find("The old value was put back", 1, true), tostring(err))
    end)
    fake.break_write("Crafts", "Table", "Inputs", nil)
    t.eq(names(), "Woodx8,Kit_Radarx1")
    t.eq(desk().Inputs[1].Element.DataTableName, "D_ItemsStatic")
    t.eq(changes_of(crafts, "Table").Inputs, nil)
end)

t.test("when the game refuses the way back as well, what the field held at first is kept and put back as soon as it can be", function()
    local logged = #log.since(0, { level = "error", channel = "wax.data" })
    local entries, stamp = journal.stats().entries, crafts:Stamp()
    t.eq(table.concat(crafts:Row("Table", { "Steps" }).Steps, ","), "10,20")
    fake.break_write("Crafts", "Table", "Steps", 1, true)
    as(A, function()
        t.raises(function() crafts:Set("Table", "Steps", { 11, 21 }) end, "The old value could not be put back")
    end)
    t.eq(table.concat(desk().Steps, ","), "11,20", "half written")
    t.eq(#log.since(0, { level = "error", channel = "wax.data" }), logged + 1)
    t.eq(table.concat(crafts:Row("Table", { "Steps" }).Steps, ","), "11,20", "Row says what the game holds")
    t.ok(crafts:Stamp() ~= stamp, "and the stamp moved on")
    local change = changes_of(crafts, "Table").Steps
    t.eq(change.Stuck, true, "listed as not put back")
    t.eq(change.By, "ModA")
    t.eq(table.concat(change.Was, ","), "10,20", "with the game's own value")
    -- the end of the frame tries, and the game still refuses: after that it is tried a few times, further apart
    frame()
    t.eq(table.concat(desk().Steps, ","), "11,20")
    t.eq(patch.stats().stuck, 1)
    t.eq(warnings("Crafts.Table.Steps could not be put back yet, and is tried again"), 1)
    for _ = 1, 30 do frame() end
    t.eq(warnings("could not be put back yet"), 1, "said once, and not tried in every frame")
    fake.break_write("Crafts", "Table", "Steps", nil)
    now = now + 1
    frame()
    t.eq(table.concat(desk().Steps, ","), "10,20", "the game's own value is back")
    t.eq(patch.stats().stuck, 0)
    t.eq(journal.stats().entries, entries, "and nothing is kept of the field")
    t.eq(changes_of(crafts, "Table").Steps, nil)
    t.eq(#log.since(0, { level = "info", channel = "wax.data", text = "Crafts.Table.Steps holds what it should again" }), 1)
end)

t.test("a change that fails over another mod's change leaves that one standing, and the game gets it back", function()
    as(A, function() crafts:Set("Table", "Steps", { 5, 6 }) end)
    fake.break_write("Crafts", "Table", "Steps", 1, true)
    local raised, problem = pcall(as, B, function() crafts:Set("Table", "Steps", { 11, 21 }) end)
    fake.break_write("Crafts", "Table", "Steps", nil)
    t.ok(not raised and tostring(problem):find("The old value could not be put back", 1, true), tostring(problem))
    t.eq(table.concat(desk().Steps, ","), "11,6", "half written")
    frame()
    t.eq(table.concat(desk().Steps, ","), "5,6", "the other mod's value is back at the end of the frame")
    local change = changes_of(crafts, "Table").Steps
    t.eq(change.By, "ModA")
    t.eq(change.Stuck, nil)
    t.eq(table.concat(change.Was, ","), "10,20")
    as(A, function() t.eq(crafts:Reset("Table", "Steps"), 1) end)
    t.eq(table.concat(desk().Steps, ","), "10,20")
    frame()
end)

t.test("everything a mod changed is put back when the mod unloads, at the end of the frame", function()
    local fired = {}
    local connection = Data.Changed:Connect(function(name) fired[#fired + 1] = name or "(everything)" end)
    frame()
    fired = {}
    t.ok(#crafts:Changes() > 10, "ModA changed a lot of Chair: " .. #crafts:Changes())
    local stamp = crafts:Stamp()
    unload(A)
    t.eq(chair().Count, 11, "still there until the frame ends")
    frame()
    local now_rows, fresh = fake.row("Crafts", "Chair"), craft_rows().Chair
    for _, name in ipairs({ "bFlag", "Small", "Tiny", "Count", "Big", "Wide", "Mode", "Plain", "Label", "Note", "position" }) do
        t.eq(now_rows[name], fresh[name], name)
    end
    t.ok(math.abs(now_rows.Ratio - 0.5) < 1e-7)
    t.eq(now_rows.Bench.RowName, "Character")
    t.eq(now_rows.Resource.Value, "Water")
    t.eq(now_rows.Gate.RowName, "Some_Flag")
    t.eq(now_rows.Gate.DataTableName, 1)
    t.eq(now_rows.Loose.RowName, "Wood")
    t.eq(#now_rows.Inputs, 2)
    t.eq(now_rows.Inputs[1].Element.RowName, "Wood")
    t.eq(now_rows.Inputs[2].Count, 1)
    t.eq(#now_rows.Outputs, 1)
    t.eq(now_rows.Outputs[1].Notes[1], "sand it")
    t.eq(now_rows.Outputs[1].Parts[1].Count, 2)
    t.eq(now_rows.Outputs[1].Tag, "main")
    t.eq(now_rows.Costs[1].RequiredUnits, 10)
    t.eq(now_rows.Costs[2].Type.Value, "Milk")
    t.eq(now_rows.Pages[2].Number, 2)
    t.eq(table.concat(now_rows.Tags, ","), "Wooden,Seat")
    t.eq(table.concat(now_rows.Steps, ","), "1,2,3")
    t.eq(table.concat(now_rows.Lines, ","), "cut,glue")
    t.eq(#now_rows.Flags, 2)
    t.eq(table.concat(now_rows.Kinds, ","), "0,1")
    t.eq(now_rows.Info.Weight, 12)
    t.eq(now_rows.Info.Maker.RowName, "Kitchen_Bench")
    t.eq(fake.row("Crafts", "Ghost").Inputs[1].Count, 1)
    t.eq(#Data:Changes(), 0)
    t.eq(journal.stats().entries, 0, "nothing is kept of a field that is as the game made it")
    t.ok(crafts:Stamp() ~= stamp, "the stamp moved on")
    t.eq(table.concat(fired, ","), "Crafts", "Changed once for the table")
    t.eq(crafts:Row("Chair").Count, 2, "and Row reads the game's own value again")
    t.eq(fake.leaks, 0)
    connection:Disconnect()
    A = mod("ModA")
end)

local function tune()
    crafts:Set("Table", "Count", 40)
    crafts:Set("Table", "Inputs", { { Element = { RowName = "Fish_03" }, Count = 2 } })
    crafts:Change("Table", "Steps", function(steps)
        steps[#steps + 1] = 30
        return steps
    end)
end

t.test("a mod that reloads and says the same again writes nothing", function()
    as(A, tune)
    t.eq(desk().Count, 40)
    t.eq(table.concat(desk().Steps, ","), "10,20,30")
    frame()
    local writes, reads = fake.writes, patch.stats().reads
    unload(A)
    A = mod("ModA")
    as(A, tune)
    frame()
    t.eq(fake.writes, writes, "not one write")
    t.eq(patch.stats().reads, reads, "and the game was not even read")
    t.eq(desk().Count, 40)
    t.eq(#desk().Inputs, 1)
    t.eq(table.concat(desk().Steps, ","), "10,20,30", "the function from before the reload is not run on top of the new one")
    t.eq(changes_of(crafts, "Table").Steps.By, "ModA")
end)

t.test("what a reloaded mod no longer says is put back, and the rest stays", function()
    unload(A)
    A = mod("ModA")
    as(A, function() crafts:Set("Table", "Count", 40) end)
    t.eq(#desk().Inputs, 1, "until the frame ends")
    frame()
    t.eq(desk().Count, 40)
    t.eq(#desk().Inputs, 2)
    t.eq(desk().Inputs[1].Element.RowName, "Wood")
    t.eq(table.concat(desk().Steps, ","), "10,20")
    t.eq(#crafts:Changes(), 1)
end)

t.test("layers stand in the order the mods load in: the later mod's Set wins, whoever spoke last", function()
    as(B, function() crafts:Set("Table", "Count", 60) end)
    t.eq(desk().Count, 60, "ModB loads after ModA")
    as(A, function() crafts:Set("Table", "Count", 41) end)
    t.eq(desk().Count, 60, "ModA spoke last and still stands below")
    local change = changes_of(crafts, "Table").Count
    t.eq(change.By, "ModB")
    t.eq(join(change.Others), "ModA")
    t.eq(change.Was, 4)
    -- a reload of the lower mod does not move it to the top
    unload(A)
    A = mod("ModA")
    as(A, function() crafts:Set("Table", "Count", 41) end)
    frame()
    t.eq(desk().Count, 60)
    t.eq(changes_of(crafts, "Table").Count.By, "ModB")
    -- a mod the order does not know stands on top, in the order it came
    local C = mod("Unlisted")
    as(C, function() crafts:Set("Table", "Count", 70) end)
    t.eq(desk().Count, 70)
    unload(C)
    frame()
    t.eq(desk().Count, 60)
end)

t.test("a Set over another mod's different value is a conflict: logged once, listed, and gone when they agree", function()
    local before = warnings("both change")
    local conflicts = crafts:Conflicts()
    t.eq(#conflicts, 1)
    t.eq(conflicts[1].Table, "Crafts")
    t.eq(conflicts[1].Row, "Table")
    t.eq(conflicts[1].Field, "Count")
    t.eq(conflicts[1].Used, "ModB")
    t.eq(join(conflicts[1].Covered), "ModA")
    t.eq(#Data:Conflicts(), 1)
    t.eq(#recipes:Conflicts(), 0)
    t.eq(warnings("ModA and ModB both change Crafts.Table.Count. ModB's value is used"), 1, "said in plain words, once")
    as(B, function() crafts:Set("Table", "Count", 60) end)
    as(A, function() crafts:Set("Table", "Count", 42) end)
    t.eq(warnings("both change"), before, "the pair was said once, however often they set")
    as(A, function() crafts:Set("Table", "Count", 60) end)
    t.eq(#crafts:Conflicts(), 0, "two mods that set the same value are in no conflict")
    as(A, function() crafts:Set("Table", "Count", 42) end)
    t.eq(#crafts:Conflicts(), 1)
    unload(B)
    frame()
    t.eq(#crafts:Conflicts(), 0, "nor is a mod alone")
    t.eq(desk().Count, 42)
    B = mod("ModB")
end)

t.test("relative changes of two mods both hold, and the one that stays is worked out again when the other leaves", function()
    as(A, function()
        crafts:Change("Table", "Steps", function(steps)
            steps[#steps + 1] = 100
            return steps
        end)
    end)
    as(B, function()
        crafts:Change("Table", "Steps", function(steps)
            steps[#steps + 1] = 200
            return steps
        end)
    end)
    t.eq(table.concat(desk().Steps, ","), "10,20,100,200")
    t.eq(#crafts:Conflicts(), 0, "a change builds on what is there")
    local change = changes_of(crafts, "Table").Steps
    t.eq(change.By, "ModB")
    t.eq(join(change.Others), "ModA")
    t.eq(table.concat(change.Was, ","), "10,20")
    unload(A)
    frame()
    t.eq(table.concat(desk().Steps, ","), "10,20,200", "ModB's function ran again on the game's own value")
    A = mod("ModA")
    as(A, function()
        crafts:Change("Table", "Steps", function(steps)
            steps[#steps + 1] = 100
            return steps
        end)
    end)
    t.eq(table.concat(desk().Steps, ","), "10,20,100,200", "back in its place below ModB")
    -- a Set on top of another mod's change hides it, and that is a conflict
    as(B, function() crafts:Set("Table", "Steps", { 1 }) end)
    t.eq(table.concat(desk().Steps, ","), "1")
    t.eq(crafts:Conflicts()[1].Field, "Steps")
    as(B, function() t.eq(crafts:Reset("Table", "Steps"), 1) end)
    as(A, function() t.eq(crafts:Reset("Table", "Steps"), 1) end)
    t.eq(table.concat(desk().Steps, ","), "10,20")
    t.eq(#crafts:Conflicts(), 0)
end)

t.test("one mod's changes of a field pile up in the order it made them, and a Set starts over", function()
    as(A, function()
        crafts:Change("Stool", "Count", function(count) return count + 1 end)
        crafts:Change("Stool", "Count", function(count) return count * 10 end)
        t.eq(fake.row("Crafts", "Stool").Count, 20)
        crafts:Set("Stool", "Count", 3)
        crafts:Change("Stool", "Count", function(count) return count + 1 end)
        t.eq(fake.row("Crafts", "Stool").Count, 4)
        -- a function may change the list it is handed and return nothing
        crafts:Change("Stool", "Steps", function(steps) steps[1] = 42 end)
        t.eq(fake.row("Crafts", "Stool").Steps[1], 42)
        for _ = 1, journal.MAX_STEPS - 1 do crafts:Change("Stool", "Steps", function(steps) return steps end) end
        t.raises(function() crafts:Change("Stool", "Steps", function(steps) return steps end) end,
            "Crafts.Stool.Steps was changed " .. journal.MAX_STEPS .. " times by ModA without a Set or a Reset in between")
        t.eq(crafts:Reset("Stool"), 2)
    end)
    t.eq(fake.row("Crafts", "Stool").Count, 1)
    t.eq(fake.row("Crafts", "Stool").Steps[1], 7)
end)

t.test("a function that raises, returns nothing for a number or returns a wrong value is the caller's error, and changes nothing", function()
    local writes = fake.writes
    as(A, function()
        local err = t.raises(function() crafts:Change("Stool", "Count", function() error("boom") end) end, "the function given to Change raised")
        t.ok(tostring(err):find("boom", 1, true), tostring(err))
        t.ok(tostring(err):find("patch_test.lua", 1, true), tostring(err))
        t.raises(function() crafts:Change("Stool", "Count", function() end) end,
            "the function given to Change returned nothing. It returns the new value")
        t.raises(function() crafts:Change("Stool", "Count", function() return "many" end) end, "Count is a whole number, got \"many\"")
        t.raises(function() crafts:Change("Stool", "Inputs", function(inputs)
            inputs[1].Element.RowName = "No_Such_Item"
            return inputs
        end) end, "ItemsStatic has no row named 'No_Such_Item'")
    end)
    t.eq(fake.writes, writes)
    t.eq(changes_of(crafts, "Stool").Count, nil)
    t.eq(#guard.errors(), 0, "the error went to the caller, not to the log")
end)

t.test("a kept function that stops working when a mod below leaves is left out, and said once", function()
    as(A, function() crafts:Set("Stool", "Steps", { 1, 2, 3 }) end)
    as(B, function()
        crafts:Change("Stool", "Steps", function(steps)
            steps[3] = steps[3] + 1
            return steps
        end)
    end)
    t.eq(table.concat(fake.row("Crafts", "Stool").Steps, ","), "1,2,4")
    local errors = #log.since(0, { level = "error", channel = "wax.data" })
    unload(A)
    frame()
    t.eq(table.concat(fake.row("Crafts", "Stool").Steps, ","), "7", "the game's own value, with ModB's change left out")
    local entries = log.since(0, { level = "error", channel = "wax.data" })
    t.eq(#entries, errors + 1)
    t.ok(entries[#entries].message:find("ModB's change of Crafts.Stool.Steps no longer works and is left out", 1, true), entries[#entries].message)
    t.eq(changes_of(crafts, "Stool").Steps.By, "ModB", "it is still listed")
    A = mod("ModA")
    as(A, function() crafts:Set("Stool", "Steps", { 5, 6, 7 }) end)
    t.eq(table.concat(fake.row("Crafts", "Stool").Steps, ","), "5,6,8", "and works again when it can")
    unload(A)
    unload(B)
    frame()
    A, B = mod("ModA"), mod("ModB")
    t.eq(table.concat(fake.row("Crafts", "Stool").Steps, ","), "7")
end)

t.test("Set with a table of fields checks every one before it writes any", function()
    as(A, function()
        t.raises(function() crafts:Set("Stool", { Count = 3, Note = 5 }) end, "Note is a string, got 5")
        t.eq(fake.row("Crafts", "Stool").Count, 1, "the first field was not written either")
        crafts:Set("Stool", { Count = 3, Note = "tall", bFlag = true })
        t.eq(fake.row("Crafts", "Stool").Count, 3)
        t.eq(fake.row("Crafts", "Stool").Note, "tall")
        t.eq(fake.row("Crafts", "Stool").bFlag, true)
    end)
end)

t.test("Reset takes back this mod's change of a field, of a row or of the table, and says how many", function()
    as(B, function() crafts:Set("Stool", "Count", 9) end)
    t.eq(fake.row("Crafts", "Stool").Count, 9)
    as(A, function()
        t.eq(crafts:Reset("Stool", "Count"), 1)
        t.eq(fake.row("Crafts", "Stool").Count, 9, "ModB's change stays")
        t.eq(crafts:Reset("Stool", "Count"), 0, "there is nothing more of this mod there")
        t.eq(crafts:Reset("stool"), 2)
        t.eq(fake.row("Crafts", "Stool").Note, "small")
        crafts:Set("Stool", "Note", "x")
        crafts:Set("Chair", "Note", "y")
        t.eq(crafts:Reset(), 2, "Stool.Note and Chair.Note")
        t.eq(chair().Note, "four legs")
        t.raises(function() crafts:Reset(nil, "Count") end, "Reset of a field needs the row it is in")
        t.raises(function() crafts:Reset("Stol") end, "Crafts has no row named 'Stol'")
        t.raises(function() crafts:Reset("Stool", "Cuont") end, "CraftRow has no field named 'Cuont'")
    end)
    as(B, function() t.eq(crafts:Reset(), 1) end)
    t.eq(fake.row("Crafts", "Stool").Count, 1)
    t.eq(#Data:Changes(), 0)
end)

t.test("many fields are put back a slice of a frame at a time", function()
    as(A, function()
        for index, row in ipairs(CRAFT_ORDER) do crafts:Set(row, "Count", 500 + index) end
        crafts:Set("Chair", "Note", "sliced")
    end)
    frame()
    patch.budget = 0
    unload(A)
    A = mod("ModA")
    local function left()
        local count = 0
        for index, row in ipairs(CRAFT_ORDER) do
            if fake.row("Crafts", row).Count == 500 + index then count = count + 1 end
        end
        return count + (chair().Note == "sliced" and 1 or 0)
    end
    t.eq(left(), 5)
    frame()
    t.eq(left(), 4, "one in the first frame")
    frame()
    t.eq(left(), 3)
    for _ = 1, 3 do frame() end
    t.eq(left(), 0)
    t.eq(#Data:Changes(), 0)
    patch.budget = 0.001
end)

local task = sched.task
local function stool() return fake.row("Crafts", "Stool") end
local function errors(text) return #log.since(0, { level = "error", channel = "wax.data", text = text }) end

t.test("with the clock running, many put-backs take a few frames, and whoever listens hears of the table once", function()
    as(A, function()
        for index, row in ipairs(CRAFT_ORDER) do
            crafts:Set(row, "Count", 700 + index)
            crafts:Set(row, "Note", "n" .. index)
        end
    end)
    frame()
    local fired, patched = 0, 0
    local on_changed = Data.Changed:Connect(function(name) if name == "Crafts" then fired = fired + 1 end end)
    local on_patched = Data.Patched:Connect(function() patched = patched + 1 end)
    t.eq(patch.budget, 0.001, "a millisecond a frame")
    -- every look at the clock takes 0.4 ms, so a frame's share is used up after a field or two
    patch.clock = function()
        now = now + 0.0004
        return now
    end
    unload(A)
    A = mod("ModA")
    local frames = 0
    while #Data:Changes() > 0 and frames < 50 do
        frame()
        frames = frames + 1
    end
    patch.clock = function() return now end
    t.ok(frames >= 3 and frames <= 10, "eight fields, a few frames: " .. frames)
    frame()
    t.eq(fired, 1, "Changed once, when the put-back was done, and not in each of its frames")
    t.eq(patched, 8, "and Patched once for each field")
    t.eq(chair().Count, 2)
    t.eq(chair().Note, "four legs")
    on_changed:Disconnect()
    on_patched:Disconnect()
end)

t.test("Reset of a field or of a row finds its entries by their keys, not by a walk of everything the table has changed", function()
    as(A, function()
        for _, row in ipairs(CRAFT_ORDER) do crafts:Set(row, "Count", 900) end
        crafts:Set("Chair", "Note", "keyed")
    end)
    frame()
    local walks, row_walks = 0, 0
    local entries, rows = journal.entries, journal.rows
    journal.entries = function(...)
        walks = walks + 1
        return entries(...)
    end
    journal.rows = function(...)
        row_walks = row_walks + 1
        return rows(...)
    end
    local patched = {}
    local connection = Data.Patched:Connect(function(_, row, field) patched[#patched + 1] = row .. "." .. tostring(field) end)
    local ok, problem = pcall(as, A, function()
        t.eq(crafts:Reset("Stool", "Count"), 1)
        t.eq(crafts:Reset("Chair"), 2)
        t.eq(crafts:Reset("Ghost", "Note"), 0, "a field this mod did not change")
    end)
    journal.entries, journal.rows = entries, rows
    t.ok(ok, tostring(problem))
    t.eq(walks, 0, "no walk of the table's entries")
    t.eq(row_walks, 0, "nor of the rows mods added")
    frame()
    t.eq(table.concat(patched, ","), "Stool.Count,Chair.Count,Chair.Note", "a row's fields are put back in the order of their names")
    connection:Disconnect()
    as(A, function() t.eq(crafts:Reset(), 2, "the whole table: Table.Count and Ghost.Count") end)
    frame()
    t.eq(#Data:Changes(), 0)
end)

t.test("a put-back the scheduler dropped, with a chain of deferred tasks it cut, is still made", function()
    local C = mod("ModC")
    local rounds, before = 0, #guard.errors()
    local function again()
        rounds = rounds + 1
        crafts:Set("Stool", "Count", 2000 + rounds)
        task.defer(again)
    end
    as(C, function() task.defer(again) end)
    frame()
    t.ok(rounds >= sched.max_defer_passes, "the chain ran until the scheduler cut it: " .. rounds)
    t.eq(#guard.errors(), before + 1, "which the scheduler said")
    guard.forget("wax")
    t.eq(stool().Count, 2000 + rounds)
    unload(C)
    frame()
    t.eq(stool().Count, 1, "the frame after the mod unloaded, the row holds the game's own value")
    t.eq(#Data:Changes(), 0)
    -- and what comes later is put back as ever
    local D = mod("ModD")
    as(D, function() crafts:Set("Chair", "Note", "later") end)
    frame()
    unload(D)
    frame()
    t.eq(chair().Note, "four legs")
    t.eq(patch.stats().pending, 0)
end)

t.test("a text that reads differently later, as after a change of language, stops neither a change nor its put-back", function()
    local logged = errors("")
    as(A, function()
        crafts:Set("Chair", "Info", { Weight = 99, Maker = { RowName = "Character" } })
        crafts:Change("Chair", "Pages", function(pages)
            pages[2].Number = 22
            return pages
        end)
    end)
    as(B, function()
        crafts:Change("Chair", "Info", function(info)
            info.Weight = info.Weight + 1
            return info
        end)
    end)
    t.eq(chair().Info.Weight, 100)
    -- the player picks another language: every text of the game reads differently from now on
    chair().Info.Title = "Ein Stuhl"
    chair().Pages[1].Title, chair().Pages[2].Title = "Eins", "Zwei"
    unload(A)
    frame()
    t.eq(chair().Info.Weight, 13, "the game's own 12, and the other mod's change on it")
    t.eq(chair().Info.Maker.RowName, "Kitchen_Bench")
    t.eq(chair().Pages[2].Number, 2)
    t.eq(chair().Info.Title, "Ein Stuhl", "a text is never written")
    -- a change made after the switch is handed the text the game shows now, so what it returns is taken
    A = mod("ModA")
    as(A, function()
        crafts:Change("Chair", "Info", function(info)
            t.eq(info.Title, "Ein Stuhl")
            info.Weight = info.Weight + 10
            return info
        end)
        crafts:Set("Chair", "Pages", { { Number = 5 }, { Title = "Zwei", Number = 6 } })
    end)
    t.eq(chair().Info.Weight, 23, "12, plus ModA's 10, plus ModB's 1")
    t.eq(chair().Pages[2].Number, 6)
    as(B, function()
        t.raises(function() crafts:Set("Chair", "Info", { Title = "A stool", Weight = 1, Maker = { RowName = "Character" } }) end,
            "Info.Title is text, which this version of Wax cannot change")
        t.eq(crafts:Reset("Chair", "Info"), 1)
    end)
    t.eq(chair().Info.Weight, 22)
    unload(A)
    frame()
    t.eq(chair().Info.Weight, 12)
    t.eq(chair().Pages[1].Number, 1)
    t.eq(errors(""), logged, "no put-back failed")
    t.eq(#Data:Changes(), 0)
    chair().Info.Title = "A chair"
    chair().Pages[1].Title, chair().Pages[2].Title = "One", "Two"
    A = mod("ModA")
end)

t.test("a put-back that fails when its mod unloads is owed, listed and tried again, and made when the game takes it", function()
    as(A, function() crafts:Set("Table", "Count", 77) end)
    frame()
    fake.deaf("Crafts", "Table", "Count")
    unload(A)
    A = mod("ModA")
    frame()
    t.eq(desk().Count, 77, "the game did not take the game's own value back")
    local change = changes_of(crafts, "Table").Count
    t.ok(change, "the field is still listed")
    t.eq(change.Stuck, true)
    t.eq(change.By, "ModA", "under the mod that left it so")
    t.eq(change.Was, 4)
    t.eq(change.Now, 77)
    t.eq(warnings("Crafts.Table.Count could not be put back yet, and is tried again: the game did not take the change of Crafts.Table.Count: Count reads 77, not 4"), 1)
    local settled = patch.stats().settled
    for _ = 1, 20 do frame() end
    t.eq(patch.stats().settled, settled, "not tried in every frame")
    fake.deaf("Crafts", "Table", "Count", false)
    now = now + 1
    frame()
    t.eq(desk().Count, 4, "a second later it is tried again, and the game takes it")
    t.eq(#Data:Changes(), 0)
    t.eq(journal.stats().entries, 0)
    t.eq(patch.stats().stuck, 0)
end)

t.test("a field that never takes its put-back is tried four times, then on every new map, and keeps the game's own value", function()
    as(A, function() crafts:Set("Table", "Count", 77) end)
    frame()
    fake.deaf("Crafts", "Table", "Count")
    unload(A)
    A = mod("ModA")
    local settled = patch.stats().settled
    frame()
    for _, wait in ipairs({ 1, 5, 30 }) do
        now = now + wait
        frame()
    end
    t.eq(patch.stats().settled, settled + 4, "at once, then after 1, 5 and 30 seconds")
    t.eq(errors("Crafts.Table.Count is not as it should be: what ModA changed there could not be put back"), 1)
    now = now + 120
    for _ = 1, 10 do frame() end
    t.eq(patch.stats().settled, settled + 4, "and then it is left alone")
    game.root.MapChanged:Fire("Terrain_021")
    frame()
    t.eq(patch.stats().settled, settled + 5, "until the map changes")
    t.eq(errors("Crafts.Table.Count is not as it should be"), 1, "said once")
    t.eq(changes_of(crafts, "Table").Count.Stuck, true)
    -- another mod's change that fails does not throw the game's own value away
    as(B, function()
        t.raises(function() crafts:Change("Table", "Count", function() error("boom") end) end, "boom")
    end)
    t.eq(changes_of(crafts, "Table").Count.Was, 4)
    fake.deaf("Crafts", "Table", "Count", false)
    as(B, function() crafts:Set("Table", "Count", 5) end)
    t.eq(desk().Count, 5, "a change by any mod puts the field right")
    t.eq(changes_of(crafts, "Table").Count.Was, 4, "and still knows what the game made")
    t.eq(changes_of(crafts, "Table").Count.Stuck, nil)
    unload(B)
    B = mod("ModB")
    frame()
    t.eq(desk().Count, 4)
    t.eq(#Data:Changes(), 0)
    game.root.MapChanged:Fire("Terrain_016")
    frame()
end)

t.test("a Reset that fails leaves the mod's change standing, so it can be called again", function()
    as(A, function() crafts:Set("Table", "Count", 88) end)
    fake.deaf("Crafts", "Table", "Count")
    as(A, function()
        t.raises(function() crafts:Reset("Table", "Count") end, "the game did not take the change of Crafts.Table.Count")
    end)
    local change = changes_of(crafts, "Table").Count
    t.eq(change.By, "ModA", "the change is listed as before")
    t.eq(change.Stuck, nil)
    t.eq(change.Now, 88)
    fake.deaf("Crafts", "Table", "Count", false)
    as(A, function() t.eq(crafts:Reset("Table", "Count"), 1) end)
    t.eq(desk().Count, 4)
    frame()
    t.eq(#Data:Changes(), 0)
end)

t.test("a table that cannot be found when a mod unloads gets the put-back once it is there again", function()
    as(A, function()
        crafts:Set("Table", "Count", 50)
        crafts:Set("Chair", "Note", "patched")
    end)
    frame()
    fake.hide("Crafts")
    unload(A)
    A = mod("ModA")
    frame()
    fake.hide("Crafts", false)
    t.eq(desk().Count, 50, "nothing could be written")
    t.eq(warnings("Crafts.Chair.Note could not be put back yet (and 1 more), and is tried again"), 1, "one line for the two fields")
    t.eq(#Data:Changes(), 2, "both are still listed")
    t.eq(Data:Changes()[1].Stuck, true)
    now = now + 6
    for _ = 1, 3 do frame() end
    t.eq(desk().Count, 4)
    t.eq(chair().Note, "four legs")
    t.eq(#Data:Changes(), 0)
    t.eq(journal.stats().entries, 0)
    t.eq(patch.stats().stuck, 0)
    t.eq(crafts:Row("Table").Count, 4)
end)

t.test("a function given to Change must not wait: one that does is an error, and never holds a put-back up", function()
    local waits, signal = false, sched.Signal.new("never")
    as(A, function()
        crafts:Set("Stool", "Count", 10)
        crafts:Set("Stool", "Note", "below")
        crafts:Set("Chair", "Note", "below")
        crafts:Set("Table", "Note", "below")
    end)
    as(B, function()
        crafts:Change("Stool", "Count", function(count)
            if waits then task.wait(1) end
            return count + 1
        end)
        crafts:Change("Stool", "Note", function(note)
            if waits then signal:Wait() end
            return note .. "!"
        end)
    end)
    t.eq(stool().Count, 11)
    t.eq(stool().Note, "below!")
    -- the mod below leaves: the kept functions are run again at the end of the frame, and now they wait
    waits = true
    local logged = errors("the function given to Change must not wait")
    unload(A)
    A = mod("ModA")
    frame()
    t.eq(stool().Count, 1, "the game's own value, with the function that waited left out")
    t.eq(stool().Note, "small")
    t.eq(chair().Note, "four legs", "the put-back before them was made")
    t.eq(desk().Note, "flat", "and the one after them, in the same frame")
    t.eq(errors("ModB's change of Crafts.Stool.Count no longer works and is left out: the function given to Change must not wait"), 1)
    t.eq(errors("the function given to Change must not wait"), logged + 2, "once for each function")
    -- the mod that waited unloads, and another one's put-back goes on as ever
    unload(B)
    B = mod("ModB")
    as(A, function() crafts:Set("Table", "Note", "after") end)
    frame()
    unload(A)
    A = mod("ModA")
    for _ = 1, 3 do frame() end
    t.eq(desk().Note, "flat")
    t.eq(errors("the function given to Change must not wait"), logged + 2)
    t.eq(#Data:Changes(), 0)
    -- called from a task, a function that waits is the caller's error, whatever it waits with
    waits = false
    local said = {}
    as(B, function()
        task.spawn(function()
            for index, wait in ipairs({ function() task.wait() end, function() signal:Wait() end, function() coroutine.yield() end,
                                        function() crafts:Load() end }) do
                local ok, problem = pcall(function()
                    crafts:Change("Chair", "Count", function(count)
                        wait()
                        return count + 1
                    end)
                end)
                said[index] = ok and "no error" or tostring(problem)
            end
        end)
    end)
    for index = 1, 4 do
        t.ok(tostring(said[index]):find("the function given to Change must not wait. It gets the value and returns the new one at once", 1, true),
            index .. ": " .. tostring(said[index]))
    end
    t.eq(chair().Count, 2, "nothing was written")
    t.eq(journal.stats().entries, 0, "and nothing is kept")
    t.eq(#guard.errors(), 0, "the errors went to the caller")
    frame()
end)

t.test("when the order of the mods changes, every field follows: the mod that loads later now wins everywhere", function()
    as(A, function() crafts:Set("Table", "Count", 41) end)
    as(B, function() crafts:Set("Table", "Count", 60) end)
    frame()
    t.eq(desk().Count, 60, "ModB loads after ModA")
    -- the player drags ModB above ModA in the Mods page
    load_order = { "ModB", "ModA", "ModC" }
    frame()
    as(A, function() crafts:Set("Table", "Note", "alpha") end)
    as(B, function() crafts:Set("Table", "Note", "beta") end)
    t.eq(desk().Note, "alpha", "a field first changed after the move: ModA loads later now")
    frame()
    t.eq(desk().Count, 41, "and the field both had changed before the move says the same")
    local change = changes_of(crafts, "Table").Count
    t.eq(change.By, "ModA")
    t.eq(join(change.Others), "ModB")
    -- the loader can say that the order changed, and then it happens in that frame
    load_order = { "ModA", "ModB", "ModC" }
    local writes = fake.writes
    patch.reordered()
    frame()
    t.eq(desk().Count, 60)
    t.eq(desk().Note, "beta")
    t.eq(changes_of(crafts, "Table").Note.By, "ModB")
    t.eq(fake.writes, writes + 2, "one write for each field that changed hands")
    -- a reload in the new order writes nothing
    unload(A)
    A = mod("ModA")
    as(A, function()
        crafts:Set("Table", "Count", 41)
        crafts:Set("Table", "Note", "alpha")
    end)
    frame()
    t.eq(fake.writes, writes + 2)
    as(A, function() t.eq(crafts:Reset(), 2) end)
    as(B, function() t.eq(crafts:Reset(), 2) end)
    -- a mod that is put in while the game runs, between two that are there
    load_order = { "ModA", "ModC" }
    frame()
    local C = mod("ModC")
    as(A, function() crafts:Set("Stool", "Note", "a") end)
    as(C, function() crafts:Set("Stool", "Note", "c") end)
    load_order = { "ModA", "ModB", "ModC" }
    frame()
    as(B, function() crafts:Set("Stool", "Note", "b") end)
    t.eq(stool().Note, "c", "ModC still loads last")
    t.eq(join(changes_of(crafts, "Stool").Note.Others), "ModA,ModB")
    unload(C)
    as(A, function() crafts:Reset() end)
    as(B, function() crafts:Reset() end)
    frame()
    t.eq(stool().Note, "small")
    t.eq(#Data:Changes(), 0)
end)

t.test("a mod that is loading again has a moment to make its changes again before they are put back", function()
    local running = {}
    local loaded = patch.loaded
    patch.loaded = function(name) return running[name] == true end
    t.eq(patch.grace, 2, "seconds")
    local function tune()
        crafts:Set("Stool", "Count", 9)
        crafts:Set("Stool", "Note", "held")
    end
    as(A, tune)
    frame()
    local changed, writes = 0, fake.writes
    local connection = Data.Changed:Connect(function() changed = changed + 1 end)
    -- a file save: the mod unloads and loads, and makes its changes from a task two frames later
    unload(A)
    A = mod("ModA")
    running.ModA = true
    frame()
    t.eq(stool().Count, 9, "nothing is put back while the mod is loading")
    t.eq(patch.stats().pending, 2, "the two fields wait")
    frame()
    as(A, tune)
    for _ = 1, 3 do frame() end
    now = now + 3
    for _ = 1, 3 do frame() end
    t.eq(fake.writes, writes, "said again in time: not one write")
    t.eq(changed, 0, "and nobody was told of a change")
    t.eq(patch.stats().pending, 0)
    -- a reload that no longer makes one of the changes: that one is put back when the moment is over, and not before
    unload(A)
    A = mod("ModA")
    as(A, function() crafts:Set("Stool", "Count", 9) end)
    frame()
    now = now + 1.5
    frame()
    t.eq(stool().Note, "held", "after a second and a half")
    now = now + 0.6
    frame()
    t.eq(stool().Note, "small", "after two")
    t.eq(stool().Count, 9)
    -- two mods on one field, one loading again and one switched off: only the first is waited for
    as(B, function() crafts:Set("Stool", "Count", 12) end)
    t.eq(stool().Count, 12)
    unload(A)
    A = mod("ModA")
    unload(B)
    B = mod("ModB")
    frame()
    t.eq(stool().Count, 9, "the mod that was switched off is put back at once, down to the value of the one that is loading")
    t.eq(changes_of(crafts, "Stool").Count.By, "ModA")
    -- and a mod that is switched off while it is waited for is put back at once too
    as(A, function() crafts:Set("Stool", "Note", "again") end)
    unload(A)
    A = mod("ModA")
    as(A, function() crafts:Set("Stool", "Count", 9) end)
    frame()
    t.eq(stool().Note, "again", "waited for")
    running.ModA = false
    unload(A)
    A = mod("ModA")
    frame()
    t.eq(stool().Note, "small")
    t.eq(stool().Count, 1)
    t.eq(#Data:Changes(), 0)
    now = now + 3
    frame()
    t.eq(patch.stats().pending, 0)
    connection:Disconnect()
    patch.loaded = loaded
end)

t.test("a Load that is under way still returns the rows a change made it forget", function()
    Data:Flush()
    frame()
    -- with no budget a Load reads one row a frame: Chair now, Table in the next frame
    local result = nil
    task.spawn(function() result = crafts:Load({ budget = 0 }) end)
    frame()
    as(A, function() crafts:Set("Chair", "Count", 77) end)
    for _ = 1, 8 do frame() end
    t.ok(result, "the Load ended")
    t.ok(result.Chair, "with the row that was changed while it ran")
    t.eq(result.Chair.Count, 77)
    t.ok(result.Table and result.Stool and result.Ghost, "and the others")
    local done, total_rows = crafts:Loaded()
    t.eq(done, total_rows)
    -- the same when the change is a put-back: the mod unloads while the Load runs
    Data:Flush()
    frame()
    result = nil
    task.spawn(function() result = crafts:Load({ budget = 0 }) end)
    frame()
    unload(A)
    A = mod("ModA")
    for _ = 1, 8 do frame() end
    t.ok(result and result.Chair, "the row that was put back is there")
    t.eq(result.Chair.Count, 2)
    -- a mod that changes two rows in every frame does not keep a Load from ending
    Data:Flush()
    frame()
    result = nil
    task.spawn(function() result = crafts:Load({ budget = 0 }) end)
    local frames = 0
    while not result and frames < 30 do
        frames = frames + 1
        as(A, function()
            crafts:Set("Chair", "Count", 100 + frames)
            crafts:Set("Table", "Count", 100 + frames)
        end)
        frame()
    end
    t.ok(result, "the Load ended")
    t.ok(frames <= 16, "within a few frames: " .. frames)
    t.ok(result.Chair and result.Table and result.Stool and result.Ghost, "with every row")
    as(A, function() crafts:Reset() end)
    frame()
    t.eq(#Data:Changes(), 0)
end)

t.test("adding rows is behind its own switch, and a new row's name and start are checked", function()
    t.eq(patch.WRITES.rows, true, "on since six rows of a new item were added in the game")
    patch.WRITES.rows = false
    as(A, function()
        t.raises(function() recipes:Add("ModA_Quick_Knife", {}, { like = "Bone_Knife" }) end,
            "adding rows to the game's tables is switched off in this version of Wax")
    end)
    patch.WRITES.rows = true
    as(A, function()
        t.raises(function() recipes:Add("Quick_Knife", {}, { like = "Bone_Knife" }) end,
            "a row that ModA adds has a name that begins with \"ModA_\", such as \"ModA_Quick_Knife\"")
        t.raises(function() recipes:Add("ModA_", {}, { like = "Bone_Knife" }) end, "has a name that begins with \"ModA_\"")
        t.raises(function() recipes:Add("ModA_Quick Knife", {}, { like = "Bone_Knife" }) end, "letters, digits and underscores")
        t.raises(function() recipes:Add(5, {}, { like = "Bone_Knife" }) end, "a row name is a string")
        t.raises(function() recipes:Add("ModA_Quick_Knife", {}, {}) end, "Add needs a row of the table to start from")
        t.raises(function() recipes:Add("ModA_Quick_Knife") end, "Add needs a row of the table to start from")
        local err = t.raises(function() recipes:Add("ModA_Quick_Knife", {}, { like = "Bone_Knif" }) end,
            "ProcessorRecipes has no row named 'Bone_Knif' to start from")
        t.ok(tostring(err):find("'Bone_Knife'", 1, true), tostring(err))
        err = t.raises(function() recipes:Add("ModA_Quick_Knife", {}, { lik = "Bone_Knife" }) end, "Add has no option named \"lik\"")
        t.ok(tostring(err):find("'like'", 1, true), tostring(err))
        t.raises(function() recipes:Add("ModA_Quick_Knife", "fast", { like = "Bone_Knife" }) end, "the values are a table")
        t.raises(function() recipes:Add("ModA_Quick_Knife", {}, "Bone_Knife") end, "the options are a table")
        t.raises(function() recipes:Add("ModA_Quick_Knife", { RequiredMillijoules = "fast" }, { like = "Bone_Knife" }) end,
            "RequiredMillijoules is a whole number")
        t.raises(function() recipes:Add("ModA_Quick_Knife", { Speed = 1 }, { like = "Bone_Knife" }) end, "has no field named 'Speed'")
        t.raises(function() crafts:Add("ModA_Bench", {}, { like = "Chair" }) end,
            "Wax does not know the game's own index of Crafts, so rows cannot be added to it")
        t.raises(function()
            recipes:Add("ModA_Quick_Knife", { REQUIREDMILLIJOULES = 900, RequiredMillijoules = 500 }, { like = "Bone_Knife" })
        end, "RequiredMillijoules is named twice, as \"REQUIREDMILLIJOULES\" and \"RequiredMillijoules\"")
    end)
    as(mod("my-mod"), function()
        t.raises(function() recipes:Add("Axe", {}, { like = "Bone_Knife" }) end, "begins with \"my_mod_\"")
    end)
    as(mod("Made"), function()
        t.raises(function() recipes:Add("Made_01", {}, { like = "Bone_Knife" }) end, "ProcessorRecipes already has a row named Made_01")
    end)
    t.eq(fake.rows_added, 0, "none of that reached the game")
    t.eq(fake.crashes, 0)
end)

t.test("a row that could not be switched off again is not a row to start from", function()
    -- a recipe on five benches, as 53 of the game's are: taking it off them means emptying a list of more than four
    local benches = fake.row("ProcessorRecipes", "Dough_Bread").RecipeSets
    for index = 3, 5 do benches[index] = { RowName = "Bench_" .. index, DataTableName = "D_RecipeSets" } end
    patch.WRITES.long_lists = false
    t.ok(not patch.WRITES.long_lists and patch.WRITES.rows, "rows on, long lists off")
    as(A, function()
        t.raises(function() recipes:Add("ModA_Bread", {}, { like = "Dough_Bread" }) end,
            "Dough_Bread cannot be the row to start from: a copy of it could not be switched off again when ModA unloads "
            .. "(RecipeSets: making a list longer or shorter while it has more than 4 entries")
    end)
    t.eq(fake.rows_added, 0, "refused before anything was added")
    t.eq(recipes:Has("ModA_Bread"), false)
    patch.WRITES.long_lists = true
    for index = 5, 3, -1 do benches[index] = nil end
    t.eq(#Data:Changes(), 0)
end)

local QUICK = { RequiredMillijoules = 500, Inputs = { { Element = { RowName = "Wood" }, Count = 1 } } }

t.test("Add copies a row of the game, writes the values over the copy and tells the game's own index", function()
    local fired, patched = {}, {}
    local on_changed = Data.Changed:Connect(function(name) fired[#fired + 1] = name or "(everything)" end)
    local on_patched = Data.Patched:Connect(function(name, row, field) patched[#patched + 1] = name .. "." .. row .. "." .. tostring(field) end)
    local knife = fake.row("ProcessorRecipes", "Bone_Knife")
    local stamp = recipes:Stamp()
    as(A, function() t.eq(recipes:Add("ModA_Quick_Knife", QUICK, { like = "bone_knife" }), "ModA_Quick_Knife") end)
    local row = fake.row("ProcessorRecipes", "ModA_Quick_Knife")
    t.ok(row and row ~= knife, "a row of its own")
    t.eq(row.RequiredMillijoules, 500)
    t.eq(#row.Inputs, 1)
    t.eq(row.Inputs[1].Element.RowName, "Wood")
    t.eq(row.Outputs[1].Element.RowName, "Bone_Knife", "what was not given is the copy's")
    t.eq(row.Requirement.RowName, "Bone_Knife")
    t.eq(knife.RequiredMillijoules, 3750, "the row it copied is untouched")
    t.eq(#knife.Inputs, 3)
    t.eq(fake.rows_added, 1)
    t.eq(fake.refreshes, 1)
    local count, known = fake.indexed("ProcessorRecipes", "ModA_Quick_Knife")
    t.eq(count, total.recipes + 1)
    t.eq(known, true, "the game's own index knows the row at once")
    t.eq(recipes:Count(), total.recipes + 1)
    t.eq(recipes:Has("moda_quick_knife"), true)
    t.eq(recipes:GetNames()[total.recipes + 1], "ModA_Quick_Knife")
    t.eq(recipes:Row("ModA_Quick_Knife").RequiredMillijoules, 500)
    t.eq(recipes:Row("Bone_Knife").RequiredMillijoules, 3750, "rows read before are still good")
    t.ok(recipes:Stamp() ~= stamp and recipes:Stamp():find("^" .. (total.recipes + 1) .. ":"), recipes:Stamp())
    frame()
    t.eq(table.concat(fired, ","), "ProcessorRecipes")
    t.eq(patched[1], "ProcessorRecipes.ModA_Quick_Knife.nil", "Patched without a field is about the row itself")
    local changes = changes_of(recipes, "ModA_Quick_Knife")
    t.eq(changes["(row)"].Added, true)
    t.eq(changes["(row)"].By, "ModA")
    t.eq(changes["(row)"].Like, "Bone_Knife")
    t.eq(changes["(row)"].Off, nil)
    t.eq(changes.RequiredMillijoules.Was, 3750, "its fields are changes like any other")
    t.eq(changes.RequiredMillijoules.Now, 500)
    on_changed:Disconnect()
    on_patched:Disconnect()
    -- other tables: a row with a meta row gets a copy of that too
    local items = Data:Table("ItemsStatic")
    local meta = items:Meta()
    t.eq(meta:Count(), 3)
    as(A, function() items:Add("ModA_Plank", { Itemable = { RowName = "Item_Fiber" } }, { like = "Wood" }) end)
    t.eq(fake.row("ItemsStatic", "ModA_Plank").Itemable.RowName, "Item_Fiber")
    t.eq(fake.row("ItemsStatic", "ModA_Plank").Generated_Tags.GameplayTags[1].TagName, "Item.Resource.Wood")
    t.eq(fake.row("ItemsStatic_METATABLE", "ModA_Plank").RequiredFeatureLevel.RowName, "Core")
    t.eq(meta:Count(), 4, "the meta table that was read before knows it")
    t.eq(meta:Row("ModA_Plank").RequiredFeatureLevel.RowName, "Core")
    t.eq(fake.unknown_names, 0, "the game was never asked for a name it does not have")
end)

t.test("a row belongs to the mod that added it, and the same call again uses the row that is there", function()
    local added = fake.rows_added
    as(mod("ModA_Quick"), function()
        t.raises(function() recipes:Add("ModA_Quick_Knife", {}, { like = "Bone_Knife" }) end,
            "the row ModA_Quick_Knife of ProcessorRecipes was added by ModA")
    end)
    local writes = fake.writes
    as(A, function() t.eq(recipes:Add("ModA_Quick_Knife", QUICK, { like = "Bone_Knife" }), "ModA_Quick_Knife") end)
    t.eq(fake.rows_added, added, "not added twice")
    t.eq(fake.writes, writes, "and the same values write nothing")
    as(A, function() recipes:Set("ModA_Quick_Knife", "RequiredMillijoules", 600) end)
    t.eq(fake.row("ProcessorRecipes", "ModA_Quick_Knife").RequiredMillijoules, 600, "it is changed like any row")
    as(A, function() recipes:Add("ModA_Quick_Knife", QUICK, { like = "Stone_Pickaxe" }) end)
    t.eq(fake.row("ProcessorRecipes", "ModA_Quick_Knife").RequiredMillijoules, 500)
    t.eq(fake.row("ProcessorRecipes", "ModA_Quick_Knife").Requirement.RowName, "Bone_Knife", "another row to start from is not looked at again")
end)

t.test("when its mod unloads, an added row is switched off and kept: a row is not taken out while the game runs", function()
    local added, removed = fake.rows_added, fake.rows_removed
    unload(A)
    frame()
    local row = fake.row("ProcessorRecipes", "ModA_Quick_Knife")
    t.ok(row, "still in the table")
    t.eq(row.bForceDisableRecipe, true, "switched off as a recipe is")
    t.eq(#row.RecipeSets, 0, "and on no bench")
    t.eq(row.RequiredMillijoules, 3750, "what the mod wrote into it is back to the copy's")
    t.eq(#row.Inputs, 3)
    t.eq(fake.rows_removed, removed)
    t.eq(recipes:Has("ModA_Quick_Knife"), true)
    local changes = changes_of(recipes, "ModA_Quick_Knife")
    t.eq(changes["(row)"].Off, true)
    t.eq(changes.bForceDisableRecipe, nil, "the switching off is not listed as a mod's change")
    t.eq(#recipes:Changes(), 1)
    t.ok(fake.row("ItemsStatic", "ModA_Plank"), "a table Wax has no way to switch a row off in keeps the row as it is")
    -- the mod loads again: the row is found, switched on and filled again
    A = mod("ModA")
    as(A, function() recipes:Add("ModA_Quick_Knife", QUICK, { like = "Bone_Knife" }) end)
    row = fake.row("ProcessorRecipes", "ModA_Quick_Knife")
    t.eq(fake.rows_added, added, "not added again")
    t.eq(row.bForceDisableRecipe, false)
    t.eq(#row.RecipeSets, 1)
    t.eq(row.RecipeSets[1].RowName, "Character")
    t.eq(row.RequiredMillijoules, 500)
    t.eq(changes_of(recipes, "ModA_Quick_Knife")["(row)"].Off, nil)
    -- a reload in one frame never switches it off
    local writes = fake.writes
    unload(A)
    A = mod("ModA")
    as(A, function() recipes:Add("ModA_Quick_Knife", QUICK, { like = "Bone_Knife" }) end)
    frame()
    t.eq(fake.writes, writes, "nothing was written")
    t.eq(fake.row("ProcessorRecipes", "ModA_Quick_Knife").bForceDisableRecipe, false)
end)

t.test("Reset of an added row switches it off, and Add brings it back", function()
    as(A, function()
        t.eq(recipes:Reset("ModA_Quick_Knife"), 3, "two fields and the row")
        t.eq(fake.row("ProcessorRecipes", "ModA_Quick_Knife").bForceDisableRecipe, true)
        t.eq(changes_of(recipes, "ModA_Quick_Knife")["(row)"].Off, true)
        recipes:Add("ModA_Quick_Knife", QUICK, { like = "Bone_Knife" })
        t.eq(fake.row("ProcessorRecipes", "ModA_Quick_Knife").bForceDisableRecipe, false)
        t.eq(fake.row("ProcessorRecipes", "ModA_Quick_Knife").RequiredMillijoules, 500)
    end)
end)

t.test("switched-off rows are taken out at the title screen, once that is switched on", function()
    unload(A)
    frame()
    t.eq(fake.row("ProcessorRecipes", "ModA_Quick_Knife").bForceDisableRecipe, true)
    t.eq(patch.WRITES.remove, false, "off until the game has shown that it works")
    game.root.MapChanged:Fire("TitleScreen")
    frame()
    t.ok(fake.row("ProcessorRecipes", "ModA_Quick_Knife"), "kept")
    game.root.MapChanged:Fire("Terrain_016")
    patch.WRITES.remove = true
    frame()
    t.ok(fake.row("ProcessorRecipes", "ModA_Quick_Knife"), "not in a prospect")
    local refreshes = fake.refreshes
    game.root.MapChanged:Fire("TitleScreen")
    frame()
    t.eq(fake.row("ProcessorRecipes", "ModA_Quick_Knife"), nil, "taken out")
    t.eq(fake.row("ItemsStatic", "ModA_Plank"), nil)
    t.eq(fake.row("ItemsStatic_METATABLE", "ModA_Plank"), nil, "with its meta row")
    t.eq(fake.rows_removed, 3)
    t.eq(fake.refreshes, refreshes + 2, "the game's own index was told for each table")
    local count, known = fake.indexed("ProcessorRecipes", "ModA_Quick_Knife")
    t.eq(count, total.recipes)
    t.eq(known, false)
    t.eq(recipes:Count(), total.recipes)
    t.eq(recipes:Has("ModA_Quick_Knife"), false)
    t.eq(Data:Table("ItemsStatic"):Meta():Count(), 3)
    t.eq(#Data:Changes(), 0)
    t.eq(journal.stats().rows, 0)
    t.eq(fake.crashes, 0, "no row of the game was ever replaced or removed")
    game.root.MapChanged:Fire("Terrain_016")
    A = mod("ModA")
end)

t.test("the live test passes on the stand-in: with every kind of write on, with a row added, as shipped, and with lists off", function()
    Wax.perf = Wax.import("core.perf")
    Wax.game = game.root
    local live = assert(loadfile("wax/tests/live/patch_rows.lua"))
    local refreshes, added_rows = fake.refreshes, fake.rows_added
    -- it puts a row in and takes it out with the engine's own calls, so it refuses to run away from the title screen
    local refused = live()
    t.eq(refused.failed, 1)
    t.eq(refused.passed, 0)
    t.ok(refused.failures[1]:find("only seen to take at the title screen, and the map is not known: send this there", 1, true),
        refused.failures[1])
    t.eq(fake.rows_added, added_rows, "and nothing was added")
    rawset(_G, "WaxPatchRowsAnywhere", true)
    local result = live()
    t.eq(result.failed, 0, table.concat(result.failures, " | "))
    t.ok(result.passed >= 18, "it ran its checks: " .. result.passed)
    t.eq(fake.row("ProcessorRecipes", "WaxPatchTest_Scratch"), nil, "the scratch row is gone")
    t.eq(recipes:Count(), total.recipes)
    t.eq(#Data:Changes(), 0)
    t.eq(fake.refreshes, refreshes, "the game's own index never heard of the scratch row")
    t.eq(fake.row("ProcessorRecipes", "Dough_Bread").RequiredMillijoules, 2500, "and the row it copied is as it was")
    rawset(_G, "WaxPatchRowsAdd", true)
    local with_row = live()
    t.eq(with_row.failed, 0, table.concat(with_row.failures, " | "))
    t.eq(with_row.passed, result.passed + 2, "two more checks for the row")
    local left = fake.row("ProcessorRecipes", "WaxPatchTest_Added")
    t.ok(left and left.bForceDisableRecipe == true and #left.RecipeSets == 0, "added, then switched off")
    -- with the switches as they ship: lists of the row itself change length, longer and nested ones and new rows do not
    patch.WRITES.long_lists, patch.WRITES.owning_lists, patch.WRITES.nested_lists, patch.WRITES.rows = false, false, false, false
    local shipped = live()
    t.eq(shipped.failed, 0, table.concat(shipped.failures, " | "))
    t.eq(shipped.passed, result.passed + 1, "the same checks, and Add refused")
    patch.WRITES.lists = false
    local careful = live()
    patch.WRITES.lists, patch.WRITES.long_lists, patch.WRITES.owning_lists, patch.WRITES.nested_lists = true, true, true, true
    patch.WRITES.rows = true
    rawset(_G, "WaxPatchRowsAdd", nil)
    rawset(_G, "WaxPatchRowsAnywhere", nil)
    t.eq(careful.failed, 0, table.concat(careful.failures, " | "))
    local said = table.concat(careful.details, "\n")
    t.ok(said:find("ok   a list is not made longer while that is switched off", 1, true), said)
    t.ok(said:find("ok   Add is refused while adding rows is switched off", 1, true), said)
    game.root.MapChanged:Fire("TitleScreen")
    frame()
    game.root.MapChanged:Fire("Terrain_016")
    t.eq(fake.row("ProcessorRecipes", "WaxPatchTest_Added"), nil, "the row it added is taken out at the title screen")
    t.eq(journal.stats().rows, 0)
    t.eq(journal.stats().entries, 0)
end)

t.test("when the game makes a table again, every change of it is written again and added rows are added again", function()
    local sets = Data:Table("RecipeSets")
    as(A, function()
        crafts:Set("Table", "Count", 50)
        crafts:Change("Table", "Steps", function(steps)
            steps[#steps + 1] = 30
            return steps
        end)
        sets:Add("ModA_Bench", { ExperienceMultiplier = 3 }, { like = "Character" })
    end)
    frame()
    fake.set_rows("Crafts", craft_rows(), CRAFT_ORDER)
    fake.move("Crafts")
    fake.set_rows("RecipeSets", {
        Character = { RecipeSetName = "Character", ExperienceMultiplier = 0.25 },
        Kitchen_Bench = { RecipeSetName = "Kitchen Bench", ExperienceMultiplier = 10.0, bAllowRefundOfRecipesOnDestroy = true },
    }, { "Character", "Kitchen_Bench" })
    fake.move("RecipeSets")
    t.eq(desk().Count, 4, "the new table holds the game's own values")
    local added = fake.rows_added
    game.root.MapChanged:Fire("Terrain_017")
    frame()
    t.eq(desk().Count, 50)
    t.eq(table.concat(desk().Steps, ","), "10,20,30")
    t.eq(fake.rows_added, added + 1)
    t.ok(math.abs(fake.row("RecipeSets", "ModA_Bench").ExperienceMultiplier - 3) < 1e-6)
    t.eq(fake.row("RecipeSets", "ModA_Bench").RecipeSetName, "Character")
    t.eq(sets:Has("ModA_Bench"), true)
    unload(A)
    frame()
    A = mod("ModA")
    t.eq(desk().Count, 4)
    t.ok(fake.row("RecipeSets", "ModA_Bench"), "kept, and this table has no way to switch a row off")
    game.root.MapChanged:Fire("TitleScreen")
    frame()
    game.root.MapChanged:Fire("Terrain_016")
    t.eq(fake.row("RecipeSets", "ModA_Bench"), nil)
    t.eq(#Data:Changes(), 0)
end)

t.test("a table that was away when the map changed gets its changes back once it is there again", function()
    as(A, function()
        crafts:Set("Table", "Count", 50)
        crafts:Set("Chair", "Note", "patched")
    end)
    frame()
    local logged = warnings("")
    -- the game makes the table again, and for a moment there is none
    fake.hide("Crafts")
    game.root.MapChanged:Fire("Terrain_018")
    frame()
    fake.set_rows("Crafts", craft_rows(), CRAFT_ORDER)
    fake.move("Crafts")
    fake.hide("Crafts", false)
    t.eq(desk().Count, 4, "the new table holds the game's own values")
    now = now + 6
    for _ = 1, 3 do frame() end
    t.eq(desk().Count, 50, "nobody asked for the table, and the changes are in it again")
    t.eq(chair().Note, "patched")
    t.eq(changes_of(crafts, "Table").Count.Now, 50)
    -- a new table that landed on the address of the old one
    fake.hide("Crafts")
    game.root.MapChanged:Fire("Terrain_019")
    frame()
    fake.set_rows("Crafts", craft_rows(), CRAFT_ORDER)
    fake.hide("Crafts", false)
    now = now + 6
    for _ = 1, 3 do frame() end
    t.eq(desk().Count, 50, "the address says nothing about a table that was away")
    -- the first read of the table tells as well, before the next look is due
    fake.hide("Crafts")
    game.root.MapChanged:Fire("Terrain_020")
    frame()
    fake.set_rows("Crafts", craft_rows(), CRAFT_ORDER)
    fake.hide("Crafts", false)
    now = now + 6
    t.eq(crafts:Row("Table").Count, 4, "this read is what finds the table")
    frame()
    t.eq(desk().Count, 50, "and the frame it was read in puts the changes back")
    -- the same table, only out of sight for a moment: nothing is written
    local writes = fake.writes
    fake.hide("Crafts")
    game.root.MapChanged:Fire("Terrain_021")
    frame()
    fake.hide("Crafts", false)
    now = now + 6
    for _ = 1, 3 do frame() end
    t.eq(desk().Count, 50)
    t.eq(fake.writes, writes)
    t.eq(warnings(""), logged, "none of that is worth a warning")
    as(A, function() crafts:Reset() end)
    frame()
    t.eq(desk().Count, 4)
    t.eq(#Data:Changes(), 0)
    game.root.MapChanged:Fire("Terrain_016")
    frame()
end)

t.test("a handler that changes a table whenever it hears of a change does not hold a frame up", function()
    local heard = 0
    local connection
    as(B, function()
        connection = Data.Patched:Connect(function(_, row, field)
            if row == "Stool" and field == "Count" then
                heard = heard + 1
                crafts:Set("Stool", "Count", 1000 + heard)
            end
        end)
        crafts:Set("Stool", "Count", 1000)
    end)
    frame()
    t.ok(heard >= 1 and heard <= 4, "a few rounds in one frame, then the next frame: " .. heard)
    connection:Disconnect()
    frame()
    as(B, function() crafts:Reset("Stool") end)
    frame()
    t.eq(fake.row("Crafts", "Stool").Count, 1)
end)

t.test("the log says once what a mod changed, when it has been quiet for a moment", function()
    local before = #log.since(0, { level = "info", channel = "wax.data", text = "ModC changed" })
    local C = mod("ModC")
    as(C, function()
        crafts:Set("Chair", "Count", 5)
        crafts:Set("Chair", "Note", "logged")
        crafts:Set("Table", "Count", 6)
    end)
    for _ = 1, 80 do frame() end
    local entries = log.since(0, { level = "info", channel = "wax.data", text = "ModC changed" })
    t.eq(#entries, before + 1)
    t.eq(entries[#entries].message, "ModC changed 3 fields of 2 rows in Crafts")
    unload(C)
    frame()
end)

t.test("a core that starts again finds what the last one wrote: a mod that says it again keeps it, the rest is put back", function()
    as(A, function()
        crafts:Set("Chair", "Count", 123)
        crafts:Set("Chair", "Note", "from the first core")
        crafts:Set("Chair", "Mode", "Instant")
    end)
    -- a row a mod added and left behind: it is switched off, and a new core must leave it so
    local R = mod("ModR")
    as(R, function() recipes:Add("ModR_Knife", QUICK, { like = "Bone_Knife" }) end)
    unload(R)
    frame()
    t.eq(fake.row("ProcessorRecipes", "ModR_Knife").bForceDisableRecipe, true)
    local stamp = crafts:Stamp()
    local second = t.new_wax()
    rawset(_G, "Wax", second)
    local sched2, scope2 = second.import("core.sched"), second.import("core.scope")
    local data2 = second.import("data.tables")
    sched2.clock = function() return now end
    data2.clock = function() return now end
    data2.start()
    local patch2 = second.import("data.patch")
    patch2.clock = function() return now end
    patch2.WRITES.rows, patch2.WRITES.remove = true, true
    patch2.start()
    local game2 = second.import("engine.game")
    local Data2 = game2.root.Data
    local crafts2, recipes2 = Data2:Table("Crafts"), Data2:Table("ProcessorRecipes")
    local function step()
        now = now + 0.016
        fake.next_frame()
        sched2.step()
    end
    local function knife() return fake.row("ProcessorRecipes", "ModR_Knife") end
    t.eq(crafts2:Stamp(), stamp, "the stamp goes on where it was")
    t.eq(#Data2:Changes(), 4, "three fields and the row: the journal is the same one")
    local again = scope2.new("ModA")
    local writes = fake.writes
    scope2.run(again, function()
        crafts2:Set("Chair", "Count", 123)
        -- by its name, which the new core never read from the game: the names of enums are kept with the journal
        crafts2:Set("Chair", "Mode", "Instant")
    end)
    step()
    t.eq(chair().Count, 123, "said again: kept")
    t.eq(chair().Mode, 2)
    t.eq(chair().Note, "four legs", "not said again: put back")
    t.eq(fake.writes, writes + 1, "one write, for the note")
    t.eq(#Data2:Changes(), 3)
    t.eq(knife().bForceDisableRecipe, true, "the row is still switched off")
    t.eq(#knife().RecipeSets, 0)
    t.eq(changes_of(recipes2, "ModR_Knife")["(row)"].Off, true)
    -- the game makes the table again: the row is added again, and switched off again
    local rows, order = {}, {}
    local function deep(value)
        if type(value) ~= "table" then return value end
        local out = {}
        for key, item in pairs(value) do out[key] = deep(item) end
        return out
    end
    for _, name in ipairs(recipes2:GetNames()) do
        if name ~= "ModR_Knife" then
            rows[name] = deep(fake.row("ProcessorRecipes", name))
            order[#order + 1] = name
        end
    end
    fake.set_rows("ProcessorRecipes", rows, order)
    fake.move("ProcessorRecipes")
    game2.root.MapChanged:Fire("Terrain_040")
    step()
    t.ok(knife(), "added again")
    t.eq(knife().bForceDisableRecipe, true, "and off")
    t.eq(#knife().RecipeSets, 0)
    -- its mod comes back, and leaves again
    local back = scope2.new("ModR")
    scope2.run(back, function() recipes2:Add("ModR_Knife", QUICK, { like = "Bone_Knife" }) end)
    t.eq(knife().bForceDisableRecipe, false)
    t.eq(#knife().RecipeSets, 1)
    t.eq(knife().RequiredMillijoules, 500)
    back:destroy()
    step()
    t.eq(knife().bForceDisableRecipe, true, "switched off once more")
    t.eq(#knife().RecipeSets, 0)
    t.eq(knife().RequiredMillijoules, 3750)
    again:destroy()
    step()
    t.eq(chair().Count, 2)
    t.eq(chair().Mode, 1)
    game2.root.MapChanged:Fire("TitleScreen")
    step()
    t.eq(knife(), nil, "taken out at the title screen")
    t.eq(#Data2:Changes(), 0)
    t.eq(#second.import("core.guard").errors(), 0)
    rawset(_G, "Wax", Wax)
end)

t.test("in the whole suite nothing was done that the game could not take", function()
    for _, name in ipairs({ "crashes", "misuse", "sloppy", "silent", "grown", "stale", "leaks", "never_reads", "unknown_names" }) do
        t.eq(fake[name], 0, name)
    end
    t.eq(#guard.errors(), 0, "no task raised")
    t.eq(journal.stats().entries, 0)
    t.eq(journal.stats().rows, 0)
end)

t.finish("patch")
