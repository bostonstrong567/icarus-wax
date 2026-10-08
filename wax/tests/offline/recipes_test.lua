-- Offline tests for world.recipes (game.Recipes) and for game.Crafting:Refresh, on the stand-in tables with UE4SS's write rules.
-- The crafting screen is a stand-in too: a list built again frees its tiles, a read past the end of an array is a fault,
-- and the tab only looks at its recipes again while it is the tab that shows.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\recipes_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local fake = dofile("wax/tests/offline/fake_tables.lua")
local wording = dofile("wax/tests/offline/wording.lua")
local S, U = "/Script/Icarus.", "/Script/IcarusUtilities."

-- every error a test asks for is kept, so that the last test can read them as a mod author would
local said, raises = {}, t.raises
function t.raises(fn, fragment, what)
    local ok, err = pcall(raises, fn, fragment, what)
    if not ok then error(err, 2) end
    said[#said + 1] = (tostring(err):gsub("^.-%.lua:%d+: ", ""))
    return err
end

fake.struct("/Script/Engine.TableRowBase", nil, {}, { lead = 8 })
fake.struct(U .. "IcarusTableRowBase", "/Script/Engine.TableRowBase", { { "CachedHardReferences", "ArrayProperty", inner = "ObjectProperty" } })
fake.struct(U .. "RowHandle", nil,
    { { "DataTablePtr", "WeakObjectProperty" }, { "RowName", "NameProperty" }, { "DataTableName", "NameProperty" } })
for _, name in ipairs({ "ItemsStatic", "ItemTemplate", "Talents", "RecipeSets", "CraftingTags", "Processing", "Alterations" }) do
    fake.struct(S .. name .. "RowHandle", U .. "RowHandle", {})
end
fake.struct(U .. "RowEnum", nil, { { "Value", "NameProperty" } }, { lead = 8 })
fake.struct(S .. "IcarusResourcesEnum", U .. "RowEnum", {})
fake.struct(S .. "CraftingInput", nil, { { "Element", "StructProperty", struct = S .. "ItemsStaticRowHandle" }, { "Count", "IntProperty" } })
fake.struct(S .. "QueryInput", nil, { { "Query", "StructProperty", struct = S .. "CraftingTagsRowHandle" }, { "Count", "IntProperty" } })
fake.struct(S .. "ResourceItem", nil,
    { { "Type", "StructProperty", struct = S .. "IcarusResourcesEnum" }, { "RequiredUnits", "IntProperty" } })
fake.struct(S .. "ItemDynamicData", nil,
    { { "PropertyType", "EnumProperty", enum = { "DynamicState", "Durability", "ItemableStack", "Fillable_StoredUnits" } }, { "Value", "IntProperty" } })
fake.struct(S .. "CraftingOutput", nil, {
    { "Element", "StructProperty", struct = S .. "ItemTemplateRowHandle" }, { "Count", "IntProperty" },
    { "DynamicProperties", "ArrayProperty", inner = "StructProperty", struct = S .. "ItemDynamicData" },
    { "Alterations", "ArrayProperty", inner = "StructProperty", struct = S .. "AlterationsRowHandle" },
})
fake.struct(S .. "ProcessorRecipe", U .. "IcarusTableRowBase", {
    { "bForceDisableRecipe", "BoolProperty" },
    { "Requirement", "StructProperty", struct = S .. "TalentsRowHandle" },
    { "RequiredMillijoules", "IntProperty" },
    { "RecipeSets", "ArrayProperty", inner = "StructProperty", struct = S .. "RecipeSetsRowHandle" },
    { "Inputs", "ArrayProperty", inner = "StructProperty", struct = S .. "CraftingInput" },
    { "QueryInputs", "ArrayProperty", inner = "StructProperty", struct = S .. "QueryInput" },
    { "ResourceInputs", "ArrayProperty", inner = "StructProperty", struct = S .. "ResourceItem" },
    { "Outputs", "ArrayProperty", inner = "StructProperty", struct = S .. "CraftingOutput" },
})
fake.struct(S .. "ItemStaticData", U .. "IcarusTableRowBase", { { "Processing", "StructProperty", struct = S .. "ProcessingRowHandle" } })
fake.struct(S .. "ItemTemplate", U .. "IcarusTableRowBase", { { "ItemStaticData", "StructProperty", struct = S .. "ItemsStaticRowHandle" } })
fake.struct(S .. "RecipeSet", U .. "IcarusTableRowBase", { { "ExperienceMultiplier", "FloatProperty" } })
fake.struct(S .. "ProcessingData", U .. "IcarusTableRowBase",
    { { "DefaultRecipeSet", "StructProperty", struct = S .. "RecipeSetsRowHandle" }, { "MaxMilliwattage", "IntProperty" } })
fake.struct(S .. "Small", U .. "IcarusTableRowBase", { { "Level", "IntProperty" } })

local function item(name) return { RowName = name, DataTableName = "D_ItemsStatic" } end
local function set(name) return { RowName = name, DataTableName = "D_RecipeSets" } end
local function talent(name) return { RowName = name, DataTableName = "D_Talents" } end
local function takes(name, count) return { Element = item(name), Count = count } end
local function gives(name, count, properties)
    return { Element = { RowName = name, DataTableName = "D_ItemTemplate" }, Count = count or 1, DynamicProperties = properties or {},
             Alterations = {} }
end
local function sets(...)
    local out = {}
    for index, name in ipairs({ ... }) do out[index] = set(name) end
    return out
end

-- The recipes as the game makes them. Each call gives new data, so a put-back can be held against it.
local function recipe_rows()
    local function recipe(row)
        row.bForceDisableRecipe = row.bForceDisableRecipe or false
        row.Requirement = row.Requirement or talent("None")
        row.RequiredMillijoules = row.RequiredMillijoules or 2500
        row.Inputs, row.QueryInputs, row.ResourceInputs = row.Inputs or {}, row.QueryInputs or {}, row.ResourceInputs or {}
        row.Outputs, row.RecipeSets = row.Outputs or {}, row.RecipeSets or {}
        return row
    end
    return {
        -- the engine spells this input "fiber": names keep the letter case they were first seen with
        Stone_Axe = recipe({ Requirement = talent("Stone_Axe"), RecipeSets = sets("Character"),
            Inputs = { takes("fiber", 10), takes("Stick", 4), takes("Stone", 6) }, Outputs = { gives("Stone_Axe") } }),
        Stone_Knife = recipe({ Requirement = talent("Stone_Knife"), RecipeSets = sets("Character"),
            Inputs = { takes("Fiber", 2), takes("Stick", 2), takes("Stone", 4) }, Outputs = { gives("Stone_Knife") } }),
        Rope = recipe({ RequiredMillijoules = 1500,
            RecipeSets = sets("Crafting_Bench", "Machining_Bench", "Fabricator", "Manufacturer", "Armor_Bench"),
            Inputs = { takes("Fiber", 12) }, Outputs = { gives("Rope") } }),
        Rope_Hand = recipe({ RequiredMillijoules = 3000, RecipeSets = sets("Character"),
            Inputs = { takes("Fiber", 20) }, Outputs = { gives("Rope") } }),
        Cooked_Meat = recipe({ RequiredMillijoules = 7500, RecipeSets = sets("Campfire", "Kitchen_Stove"),
            Inputs = { takes("Raw_Meat", 1) }, Outputs = { gives("Cooked_Meat") } }),
        Frag_Grenade = recipe({ Requirement = talent("Frag_Grenade"), RecipeSets = sets("Machining_Bench", "Fabricator"),
            Inputs = { takes("Refined_Metal", 1), takes("Gunpowder", 2), takes("Volatile_Substance", 3) },
            ResourceInputs = { { Type = { Value = "Biofuel" }, RequiredUnits = 100 } }, Outputs = { gives("Frag_Grenade") } }),
        Animal_Feed = recipe({ RecipeSets = sets("Crafting_Bench"), Inputs = { takes("Fiber", 5) },
            QueryInputs = { { Query = { RowName = "Any_Raw_Meat", DataTableName = "D_CraftingTags" }, Count = 3 } },
            Outputs = { gives("Animal_Feed") } }),
        Ore_Meta = recipe({ RecipeSets = sets("Fabricator"), Outputs = { gives("Stone_Stack", 1) } }),
        Water_Fill = recipe({ RecipeSets = sets("Character"), Inputs = { takes("Waterskin", 1) },
            ResourceInputs = { { Type = { Value = "Water" }, RequiredUnits = 500 } },
            Outputs = { gives("Waterskin_Full", 1, { { PropertyType = 3, Value = 500 } }) } }),
        Big_Kit = recipe({ RecipeSets = sets("Fabricator"),
            Inputs = { takes("Fiber", 1), takes("Stick", 2), takes("Stone", 3), takes("Wood", 4), takes("Rope", 5) },
            Outputs = { gives("Kit") } }),
        Seed_Pack = recipe({ RecipeSets = sets("Character"), Inputs = { takes("Fiber", 1) },
            Outputs = { gives("Seed_Carrot"), gives("Seed_Wheat", 2) } }),
        Roast = recipe({ RecipeSets = sets("Campfire"),
            QueryInputs = { { Query = { RowName = "Any_Raw_Meat", DataTableName = "D_CraftingTags" }, Count = 1 } },
            Outputs = { gives("Cooked_Meat") } }),
        Repair_Kit = recipe({ RecipeSets = sets("Repair_Bench"), Inputs = { takes("Fiber", 2) }, Outputs = { gives("Kit") } }),
        Ingot = recipe({ RecipeSets = sets("Smelting"), Inputs = { takes("Stone", 2) }, Outputs = { gives("Refined_Metal") } }),
    }
end
local ORDER = { "Stone_Axe", "Stone_Knife", "Rope", "Rope_Hand", "Cooked_meat", "Frag_Grenade", "Animal_Feed", "Ore_Meta", "Water_Fill",
                "Big_Kit", "Seed_Pack", "Roast", "Repair_Kit", "Ingot" }
fake.table("ProcessorRecipes", S .. "ProcessorRecipe", recipe_rows(), ORDER)

local function named(names, make)
    local rows = {}
    for _, name in ipairs(names) do rows[name] = make(name) end
    return rows, names
end
local BENCH_ITEMS = { Crafting_Bench = "Crafting_Bench", Fabricator = "Fabricator", Campfire = "Campfire", FirePit = "FirePit",
                      Machining_Bench = "Machining_Bench" }
local ITEMS = { "Fiber", "Stick", "Stone", "Wood", "Rope", "Raw_Meat", "Cooked_Meat", "Refined_Metal", "Gunpowder", "Volatile_Substance",
                "Stone_Axe", "Stone_Knife", "Frag_Grenade", "Animal_Feed", "Waterskin", "Kit", "Seed", "Ghost", "Crafting_Bench",
                "Fabricator", "Campfire", "FirePit", "Machining_Bench" }
fake.table("ItemsStatic", S .. "ItemStaticData", named(ITEMS, function(name)
    return { Processing = { RowName = BENCH_ITEMS[name] or "None", DataTableName = "D_Processing" } }
end))
-- most items have a template of their own name. Stone and Waterskin have a second one, Seed has two and none of its own, Ghost none
local TEMPLATES = { "Fiber", "Stick", "Stone", "Wood", "Rope", "Raw_Meat", "Cooked_Meat", "Refined_Metal", "Gunpowder", "Volatile_Substance",
                    "Stone_Axe", "Stone_Knife", "Frag_Grenade", "Animal_Feed", "Waterskin", "Kit", "Waterskin_Full", "Stone_Stack",
                    "Seed_Carrot", "Seed_Wheat" }
local TEMPLATE_ITEMS = { Waterskin_Full = "Waterskin", Stone_Stack = "Stone", Seed_Carrot = "Seed", Seed_Wheat = "Seed" }
fake.table("ItemTemplate", S .. "ItemTemplate", named(TEMPLATES, function(name)
    return { ItemStaticData = item(TEMPLATE_ITEMS[name] or name) }
end))
fake.table("RecipeSets", S .. "RecipeSet", named({ "Character", "Crafting_Bench", "Machining_Bench", "Fabricator", "Manufacturer",
    "Armor_Bench", "Campfire", "Firepit", "Kitchen_Stove", "Repair_Bench", "Smelting" }, function() return { ExperienceMultiplier = 1.0 } end))
local SPEEDS = { PlayerCrafting = { "Character", 1000 }, Crafting_Bench = { "Crafting_Bench", 1000 }, Great_Hunt_Device = { "Crafting_Bench", 2500 },
                 Fabricator = { "Fabricator", 2500 }, Machining_Bench = { "Machining_Bench", 1500 }, Campfire = { "Campfire", 250 },
                 FirePit = { "Campfire", 275 }, Kitchen_Stove = { "Kitchen_Stove", 500 }, Manufacturer = { "Manufacturer", 2500 },
                 Armor_Bench = { "Armor_Bench", 2500 }, Furnace = { "Smelting", 500 }, Blast_Furnace = { "Smelting", 750 },
                 WaterPurifier = { "None", 0 } }
fake.table("Processing", S .. "ProcessingData", named({ "PlayerCrafting", "Crafting_Bench", "Great_Hunt_Device", "Fabricator",
    "Machining_Bench", "Campfire", "FirePit", "Kitchen_Stove", "Manufacturer", "Armor_Bench", "Furnace", "Blast_Furnace", "WaterPurifier" },
    function(name) return { DefaultRecipeSet = set(SPEEDS[name][1]), MaxMilliwattage = SPEEDS[name][2] } end))
fake.table("Talents", S .. "Small", named({ "Stone_Axe", "Stone_Knife", "Frag_Grenade", "Rope" }, function() return { Level = 1 } end))
fake.table("CraftingTags", S .. "Small", named({ "Any_Raw_Meat", "Any_Fruit" }, function() return { Level = 1 } end))
fake.table("IcarusResources", S .. "Small", named({ "Water", "Biofuel", "Milk" }, function() return { Level = 1 } end))
fake.install()
fake.allow_writes(true)

local function row(name) return fake.row("ProcessorRecipes", name) end

-- The game's own list of a set's recipes: it walks the table each time, leaves hidden recipes out and takes names as FNames only.
local library = { present = true, calls = 0 }
local engine_find = StaticFindObject
function StaticFindObject(path)
    if path ~= "/Script/Icarus.Default__ProcessingFunctionLibrary" then return engine_find(path) end
    if not library.present then return { IsValid = function() return false end } end
    return {
        IsValid = function() return true end,
        GetAllRecipeRowsForSet = function(_, handle)
            library.calls = library.calls + 1
            if type(handle.RowName) ~= "table" or type(handle.DataTableName) ~= "table" then
                error("CRASH: GetAllRecipeRowsForSet was given a string where an FName belongs", 2)
            end
            local wanted, out = handle.RowName:ToString():lower(), {}
            for _, name in ipairs(ORDER) do
                local held = row(name)
                if held and not held.bForceDisableRecipe then
                    for _, entry in ipairs(held.RecipeSets) do
                        if entry.RowName:lower() == wanted then
                            out[#out + 1] = { get = function() return { RowName = { ToString = function() return name end } } end }
                            break
                        end
                    end
                end
            end
            return out
        end,
    }
end

-- The game's interface as far as game.Crafting looks at it.
local ui = { mouse = true, tab = 1, chosen = nil, generation = 0, refreshes = 0, full_updates = 0, selections = {}, misuse = 0, crashes = 0,
             bench = nil, bench_calls = {}, needs = nil, built = 0 }
local function handle_for(name) return { RowName = { ToString = function() return name or "None" end } } end
local function array_of(items)
    return setmetatable({}, { __index = function(_, key)
        if key == "GetArrayNum" then return function() return #items end end
        if math.type(key) ~= "integer" or key < 1 or key > #items then
            ui.misuse = ui.misuse + 1
            error("MISUSE: a read past the end makes the game's array longer (" .. tostring(key) .. ")", 2)
        end
        return items[key]
    end })
end
local function tile_for(name, generation)
    return setmetatable({}, { __index = function(_, key)
        -- on freed memory IsValid can answer true
        if key == "IsValid" then return function() return true end end
        if generation ~= ui.generation then
            ui.crashes = ui.crashes + 1
            error("CRASH: a tile was used after its list was built again", 2)
        end
        if key == "ProcessorRecipe" then return handle_for(name) end
        if key == "Valid" then return true end
        error("MISUSE: a tile was asked for " .. tostring(key), 2)
    end })
end
local function tiles_of(set_name)
    local tiles = {}
    for _, name in ipairs(ORDER) do
        local held = row(name)
        if held and not held.bForceDisableRecipe then
            for _, entry in ipairs(held.RecipeSets) do
                if entry.RowName:lower() == set_name:lower() then tiles[#tiles + 1] = tile_for(name, ui.generation) end
            end
        end
    end
    return array_of(tiles)
end
local function valid() return true end
local tab_list = { IsValid = valid, GetAddress = function() return 0x2000 end, RecipeElementsMulti = array_of({}),
                   RecipeElementNonInteractives = array_of({}), RecipeElements = array_of({}) }
tab_list["On Recipe Selected"] = function(_, handle)
    local name = handle.RowName:ToString()
    -- as in the game: the row of what a recipe needs is only built for another recipe than the tab holds
    if name ~= ui.chosen then
        local parts = {}
        for index, entry in ipairs(row(name).Inputs) do parts[index] = entry.Element.RowName:lower() .. " x" .. entry.Count end
        ui.needs, ui.built = table.concat(parts, ", "), ui.built + 1
    end
    ui.chosen = name
    ui.selections[#ui.selections + 1] = ui.chosen
end
local tab = setmetatable({ IsValid = valid, GetAddress = function() return 0x1000 end, FullUpdateRequested = false }, {
    __index = function(_, key)
        if key == "Recipe" then return handle_for(ui.chosen) end
        if key == "UMG_RecipeList" then return tab_list end
        return nil
    end,
})
-- the game's own way to build the tab's list: every tile is made again, and nothing is chosen afterwards
function tab.RefreshRecipes()
    ui.refreshes = ui.refreshes + 1
    ui.generation = ui.generation + 1
    tab_list.RecipeElements = tiles_of("Character")
    ui.chosen, ui.needs = nil, nil
end
local bench_list = { IsValid = valid, GetAddress = function() return 0x4000 end, RecipeElementsMulti = array_of({}),
                     RecipeElementNonInteractives = array_of({}), RecipeElements = array_of({}), CachedRecipeSet = { "the bench's own set" } }
function bench_list.Initialise(self, cached, auto, input)
    ui.bench_calls[#ui.bench_calls + 1] = ("Initialise(%s, %s, %s)"):format(cached == self.CachedRecipeSet and "own set" or "?",
        tostring(auto), tostring(input))
    ui.generation = ui.generation + 1
    bench_list.RecipeElements = tiles_of("Fabricator")
end
bench_list["On Recipe Selected"] = function(_, handle) ui.bench_calls[#ui.bench_calls + 1] = "chose " .. handle.RowName:ToString() end
local bench = { IsValid = valid, GetAddress = function() return 0x3000 end, GetParent = function() return { IsValid = valid } end,
                GetVisibility = function() return 0 end, UMG_RecipeList = bench_list, LastSelected = handle_for("Big_Kit"),
                AutoSelect = false, UseInput = true,
                UpdateAllRecipeStates = function() ui.bench_calls[#ui.bench_calls + 1] = "UpdateAllRecipeStates" end }
local main = { IsValid = valid, GetVisibility = function() return 0 end, UMG_Crafting = tab,
               MenuSwitcher = { IsValid = valid, GetActiveWidgetIndex = function() return ui.tab end } }
local interface = setmetatable({ IsValid = valid, UMG_MainMenu = main }, { __index = function(_, key)
    if key == "CurrentDynamicWidget" then return ui.bench or { IsValid = function() return false end } end
    return nil
end })
local controller = setmetatable({}, { __index = function(_, key)
    if key == "bShowMouseCursor" then return ui.mouse end
    if key == "UserInterface" then return interface end
    return nil
end })
-- the tab only looks at its recipes again while it is the tab that shows
function ui.tick()
    if ui.mouse and ui.tab == 1 and not ui.bench and tab.FullUpdateRequested then
        ui.full_updates = ui.full_updates + 1
        tab.FullUpdateRequested = false
    end
end
function ui.reset()
    ui.refreshes, ui.full_updates, ui.selections, ui.bench_calls, ui.built = 0, 0, {}, {}, 0
end

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)
rawset(Wax, "game", { LocalPlayer = { Raw = controller } })
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local log = Wax.import("core.log")
local game = Wax.import("engine.game")
local data = Wax.import("data.tables")
local journal = Wax.import("data.journal")
journal.clear()
local task = sched.task

local now = 100
sched.clock = function() return now end
data.clock = function() return now end
data.min_tables = 1
data.start()
local patch = Wax.import("data.patch")
patch.clock = function() return now end
patch.start()
local running = {}
patch.loaded = function(name) return running[name] == true end
rawset(Wax, "mods", { list = function() return { { id = "ModA" }, { id = "ModB" } } end })
local crafting = Wax.import("world.crafting")
crafting.start()
local module = Wax.import("world.recipes")
module.clock = function() return now end
local in_prospect = true
module.in_prospect = function() return in_prospect end
module.start()
local Data = game.root.Data
local Recipes = game.root.Recipes
local Crafting = game.root.Crafting
tab.RefreshRecipes()
ui.reset()

-- One frame: whatever the engine handed out before must not be used again.
local function frame()
    now = now + 0.016
    fake.next_frame()
    ui.tick()
    sched.step()
end

local function mod(name) return scope.new(name) end
local function as(owner, fn, ...) return scope.run(owner, fn, ...) end
local function unload(owner) owner:destroy() end

-- Runs fn in a task until it ends. Returns what it returned and how many frames it took, or raises what it raised.
local function in_task(owner, fn)
    local done, ok, result, frames = false, nil, nil, 0
    as(owner, function()
        task.spawn(function()
            ok, result = pcall(fn)
            done = true
        end)
    end)
    while not done do
        frames = frames + 1
        if frames > 2000 then error("the task did not end", 2) end
        frame()
    end
    if not ok then error(result, 0) end
    return result, frames
end

local function at(err, what)
    t.ok(tostring(err):find("recipes_test.lua:%d+:"), (what or "the error") .. " should name the line that asked: " .. tostring(err))
end

local function same(a, b)
    -- names keep the letter case the game first saw them in, so they are held against each other without it
    if type(a) == "string" and type(b) == "string" then return a:lower() == b:lower() end
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for key, value in pairs(a) do
        if not same(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

-- What the game's own data says a recipe takes, gives, and where it is made, as text. A name keeps the letter case the game
-- first saw it in, whoever wrote it last, so names are shown as their tables spell them.
local SPELLED = {}
for _, list in ipairs({ ITEMS, TEMPLATES }) do
    for _, name in ipairs(list) do SPELLED[name:lower()] = name end
end
local function inputs(name)
    local out = {}
    for index, entry in ipairs(row(name).Inputs) do out[index] = SPELLED[entry.Element.RowName:lower()] .. " x" .. entry.Count end
    return table.concat(out, ", ")
end
local function outputs(name)
    local out = {}
    for index, entry in ipairs(row(name).Outputs) do out[index] = SPELLED[entry.Element.RowName:lower()] .. " x" .. entry.Count end
    return table.concat(out, ", ")
end
local function benches(name)
    local out = {}
    for index, entry in ipairs(row(name).RecipeSets) do out[index] = entry.RowName end
    return table.concat(out, ", ")
end
local function names(list) return table.concat(list:GetNames(), ", ") end
local function untouched(what)
    local fresh = recipe_rows()
    for _, name in ipairs(ORDER) do
        t.ok(same(row(name), fresh[name:sub(1, 1) .. name:sub(2)] or fresh.Cooked_Meat), (what or "") .. ": " .. name .. " is not as the game made it")
    end
end

local A, B = mod("ModA"), mod("ModB")
local function fresh_mods()
    unload(A)
    unload(B)
    frame()
    now = now + 3
    frame()
    A, B = mod("ModA"), mod("ModB")
end

t.test("Get gives a recipe at once: by any letter case, the same one each time, and reads nothing", function()
    local asked = fake.rows_asked
    local axe = Recipes:Get("Stone_Axe")
    t.eq(axe.Name, "Stone_Axe")
    t.ok(Recipes:Get("stone_axe") == axe, "the same recipe")
    t.eq(Recipes:Get("COOKED_MEAT").Name, "Cooked_meat", "spelled as the game spells it")
    t.eq(fake.rows_asked, asked, "no row was read")
    t.eq(tostring(axe), "Recipe(Stone_Axe)")
    t.ok(Recipes:Has("rope") and not Recipes:Has("Ropes") and not Recipes:Has(5))
    local err = t.raises(function() Recipes:Get("Stone_Ax") end, "there is no recipe named 'Stone_Ax'. Did you mean 'Stone_Axe'")
    at(err)
    t.raises(function() Recipes:Get(5) end, "a recipe is named by a string such as \"Stone_Axe\", got 5")
    t.raises(function() Recipes.Get("Stone_Axe") end, "call Get with a colon: game.Recipes:Get(...)")
    t.raises(function() return Recipes.Gte end, "Gte is not a member of game.Recipes. Did you mean 'Get'")
    t.raises(function() Recipes.Get = nil end, "game.Recipes.Get cannot be assigned")
end)

t.test("a recipe reads as plain values: what it takes and gives, where and how long, and what it needs", function()
    local axe = Recipes:Get("Stone_Axe")
    local takes_now = axe.Inputs
    t.eq(#takes_now, 3)
    t.eq(takes_now[1].Item, "Fiber", "spelled as the item table spells it, not as the row does")
    t.eq(takes_now[1].Count, 10)
    t.eq(takes_now[3].Item .. takes_now[3].Count, "Stone6")
    takes_now[1].Count = 99
    t.eq(axe.Inputs[1].Count, 10, "the list is the mod's own")
    t.eq(axe.Outputs[1].Item, "Stone_Axe")
    t.eq(axe.Outputs[1].Template, "Stone_Axe")
    t.eq(axe.Outputs[1].Count, 1)
    t.eq(table.concat(axe.Benches, ","), "Character")
    t.eq(axe.Work, 2500)
    t.eq(axe.Requirement, "Stone_Axe")
    t.eq(axe.Hidden, false)
    t.eq(Recipes:Get("Rope").Requirement, nil, "no research")
    t.eq(Recipes:Get("Water_Fill").Outputs[1].Item, "Waterskin", "the item of the template")
    t.eq(Recipes:Get("Water_Fill").Outputs[1].Template, "Waterskin_Full")
    local feed = Recipes:Get("Animal_Feed")
    t.eq(feed.Tags[1].Tag .. feed.Tags[1].Count, "Any_Raw_Meat3")
    local grenade = Recipes:Get("Frag_Grenade")
    t.eq(grenade.Resources[1].Resource .. grenade.Resources[1].Units, "Biofuel100")
    t.eq(#axe.Tags + #axe.Resources, 0)
    local err = t.raises(function() return axe.Input end, "Input is not a member of a recipe. Did you mean")
    t.ok(tostring(err):find("'Inputs'", 1, true), tostring(err))
    at(err)
    t.raises(function() axe.Work = 5 end, "recipe.Work cannot be assigned. A recipe is changed with its functions")
end)

t.test("changing anything belongs to a mod: outside one it is refused, and reading still works", function()
    t.raises(function() Recipes:Get("Stone_Axe"):SetWork(100) end, "belongs to a mod, which puts it back when it unloads")
    t.eq(row("Stone_Axe").RequiredMillijoules, 2500)
    t.eq(fake.writes, 0)
end)

t.test("SetInputs sets the items a recipe takes, at once, and returns the recipe", function()
    as(A, function()
        local axe = Recipes:Get("Stone_Axe")
        t.ok(axe:SetInputs({ Stone = 1 }) == axe, "the recipe comes back")
        t.eq(inputs("Stone_Axe"), "Stone x1")
        t.eq(row("Stone_Axe").Inputs[1].Element.DataTableName, "D_ItemsStatic")
        t.eq(axe.Inputs[1].Item .. axe.Inputs[1].Count, "Stone1", "a read right after sees it")
        axe:SetInputs({ wood = 2, Fiber = 4, STICK = 1 })
        t.eq(inputs("Stone_Axe"), "Fiber x4, Stick x1, Wood x2", "in the order of their names, spelled as the game spells them")
        axe:SetInputs({ { "Wood", 3 }, { Item = "Fiber", Count = 2 } })
        t.eq(inputs("Stone_Axe"), "Wood x3, Fiber x2", "a list keeps its order")
    end)
    local change = Data:Changes()[1]
    t.eq(change.Table .. "." .. change.Row .. "." .. change.Field .. " by " .. change.By, "ProcessorRecipes.Stone_Axe.Inputs by ModA")
    t.eq(change.Was[1].Count, 10)
    t.eq(#Data:Changes(), 1)
end)

t.test("what SetInputs is given is checked in plain words, and nothing is written for a wrong one", function()
    local writes = fake.writes
    as(A, function()
        local axe = Recipes:Get("Stone_Axe")
        local err = t.raises(function() axe:SetInputs({ Stne = 1 }) end, "there is no item, tag or resource named 'Stne'. Did you mean 'Stone'")
        at(err)
        t.raises(function() axe:SetInputs({ Stone = 0 }) end, "the count of Stone is a whole number of 1 or more, got 0")
        t.raises(function() axe:SetInputs({ Stone = 1.5 }) end, "the count of Stone is a whole number of 1 or more, got 1.5")
        t.raises(function() axe:SetInputs({ Stone = "two" }) end, "got \"two\"")
        t.raises(function() axe:SetInputs({ { "Stone", 1 }, { "stone", 2 } }) end, "SetInputs names Stone twice")
        t.raises(function() axe:SetInputs({ Any_Raw_Meat = 1 }) end,
            "Any_Raw_Meat is a tag, not an item. SetInputs sets the items a recipe takes. For this one use SetInput(\"Any_Raw_Meat\", count)")
        t.raises(function() axe:SetInputs({ Water = 1 }) end, "Water is a resource, not an item")
        t.raises(function() axe:SetInputs("Stone") end, "SetInputs takes a table such as { Wood = 2, Fiber = 4 }, got \"Stone\"")
        t.raises(function() axe:SetInputs({ { "Stone", 1 }, extra = 2 }) end, "a list, which has no place for the key \"extra\"")
        t.raises(function() axe:SetInputs({ { 1, "Stone" } }) end, "entry 1 names no item")
        t.raises(function() axe:SetInputs({}) end, "Stone_Axe would take nothing. A recipe has to take at least one item, tag or resource")
        t.raises(function() axe.SetInputs({ Stone = 1 }) end, "call SetInputs with a colon: recipe:SetInputs(...)")
    end)
    t.eq(fake.writes, writes, "not one write")
    t.eq(inputs("Stone_Axe"), "Wood x3, Fiber x2")
    as(A, function()
        Recipes:Get("Animal_Feed"):SetInputs({})
        t.eq(#row("Animal_Feed").Inputs, 0, "a recipe that still takes a tag may take no item")
        Recipes:Get("Ore_Meta"):SetInputs({})
        t.eq(#row("Ore_Meta").Inputs, 0, "and one that takes nothing already may stay so")
    end)
end)

t.test("everything a mod changed is put back when the mod unloads, at the end of the frame", function()
    unload(A)
    t.eq(inputs("Stone_Axe"), "Wood x3, Fiber x2", "until the frame ends")
    frame()
    now = now + 3
    frame()
    untouched("after the unload")
    t.eq(#Data:Changes(), 0)
    t.eq(journal.stats().entries, 0)
    A = mod("ModA")
end)

t.test("SetInput sets one count and adds what is not taken yet: an item, a tag, or a resource the recipe has", function()
    as(A, function()
        local axe = Recipes:Get("Stone_Axe")
        axe:SetInput("FIBER", 3)
        t.eq(inputs("Stone_Axe"), "Fiber x3, Stick x4, Stone x6", "in its place, spelled as the item table spells it")
        axe:SetInput("Wood", 2)
        t.eq(inputs("Stone_Axe"), "Fiber x3, Stick x4, Stone x6, Wood x2", "a new one goes last")
        local feed = Recipes:Get("Animal_Feed")
        feed:SetInput("Any_Raw_Meat", 1):SetInput("any_fruit", 2)
        t.eq(row("Animal_Feed").QueryInputs[1].Count, 1)
        t.eq(row("Animal_Feed").QueryInputs[2].Query.RowName, "Any_Fruit")
        t.eq(row("Animal_Feed").QueryInputs[2].Query.DataTableName, "D_CraftingTags")
        Recipes:Get("Frag_Grenade"):SetInput("biofuel", 40)
        t.eq(row("Frag_Grenade").ResourceInputs[1].RequiredUnits, 40)
        t.eq(row("Frag_Grenade").ResourceInputs[1].Type.Value, "Biofuel")
        local err = t.raises(function() axe:SetInput("Water", 5) end,
            "Stone_Axe takes 0 resources and would take 1. This version of Wax cannot add a resource to a recipe or take one away. "
            .. "It can change how much of a resource a recipe takes")
        at(err)
        t.raises(function() axe:SetInput("Stone", 0) end, "the count of Stone is a whole number of 1 or more")
        t.raises(function() axe:SetInput("Rock", 1) end, "there is no item, tag or resource named 'Rock'")
        t.raises(function() axe:SetInput(nil, 1) end, "an item is named by a string")
    end)
    t.eq(#row("Stone_Axe").ResourceInputs, 0)
end)

t.test("RemoveInput takes one thing out, and refuses what the recipe does not take or cannot lose", function()
    as(A, function()
        local axe = Recipes:Get("Stone_Axe")
        axe:RemoveInput("stick")
        t.eq(inputs("Stone_Axe"), "Fiber x3, Stone x6, Wood x2")
        local err = t.raises(function() axe:RemoveInput("Stick") end, "Stone_Axe takes no Stick. It takes Fiber, Stone and Wood")
        at(err)
        t.raises(function() Recipes:Get("Rope"):RemoveInput("Fiber") end, "Rope would take nothing")
        t.raises(function() Recipes:Get("Frag_Grenade"):RemoveInput("Biofuel") end,
            "Frag_Grenade takes 1 resource and would take 0. This version of Wax cannot add a resource to a recipe or take one away")
        Recipes:Get("Animal_Feed"):RemoveInput("Fiber")
        t.eq(#row("Animal_Feed").Inputs, 0, "the tags are still taken")
        t.raises(function() Recipes:Get("Roast"):RemoveInput("Any_Raw_Meat") end, "Roast would take nothing")
    end)
    t.eq(row("Frag_Grenade").ResourceInputs[1].RequiredUnits, 40)
end)

t.test("ScaleInputs and ScaleInput multiply counts: rounded up, never under 1, tags and resources too", function()
    fresh_mods()
    as(A, function()
        Recipes:Get("Stone_Axe"):ScaleInputs(0.5)
        t.eq(inputs("Stone_Axe"), "Fiber x5, Stick x2, Stone x3")
        Recipes:Get("Stone_Axe"):ScaleInputs(0.3)
        t.eq(inputs("Stone_Axe"), "Fiber x2, Stick x1, Stone x1", "1.5 is 2, 0.6 and 0.9 are 1")
        Recipes:Get("Animal_Feed"):ScaleInputs(2)
        t.eq(inputs("Animal_Feed"), "Fiber x10")
        t.eq(row("Animal_Feed").QueryInputs[1].Count, 6)
        Recipes:Get("Frag_Grenade"):ScaleInputs(0.1)
        t.eq(inputs("Frag_Grenade"), "Refined_Metal x1, Gunpowder x1, Volatile_Substance x1")
        t.eq(row("Frag_Grenade").ResourceInputs[1].RequiredUnits, 10)
        Recipes:Get("Stone_Knife"):ScaleInput("stone", 3)
        t.eq(inputs("Stone_Knife"), "Fiber x2, Stick x2, Stone x12")
        Recipes:Get("Ore_Meta"):ScaleInputs(2)
        t.raises(function() Recipes:Get("Stone_Knife"):ScaleInput("Wood", 2) end, "Stone_Knife takes no Wood. It takes Fiber, Stick and Stone")
        for _, wrong in ipairs({ 0, -1, "half", 1 / 0 }) do
            t.raises(function() Recipes:Get("Stone_Knife"):ScaleInputs(wrong) end, "a factor is a number above 0, such as 0.5 for half")
        end
    end)
    t.eq(#Data:Table("ProcessorRecipes"):Changes(), 6, "a list with nothing in it is not touched")
end)

t.test("a list of more than four entries keeps its length in this version, said in a mod author's words", function()
    fresh_mods()
    t.eq(patch.WRITES.long_lists, false)
    as(A, function()
        local kit = Recipes:Get("Big_Kit")
        local err = t.raises(function() kit:SetInputs({ Stone = 1 }) end,
            "Big_Kit takes 5 items and would take 1. This version of Wax only makes such a list longer or shorter while it has 4 entries "
            .. "or fewer, before and after")
        at(err)
        t.raises(function() kit:RemoveInput("Wood") end, "Big_Kit takes 5 items and would take 4")
        t.raises(function() kit:SetInput("Kit", 1) end, "Big_Kit takes 5 items and would take 6")
        t.raises(function() Recipes:Get("Stone_Axe"):SetInputs({ Fiber = 1, Stick = 1, Stone = 1, Wood = 1, Rope = 1 }) end,
            "Stone_Axe takes 3 items and would take 5")
        kit:SetInput("Wood", 9):ScaleInput("Rope", 2)
        t.eq(inputs("Big_Kit"), "Fiber x1, Stick x2, Stone x3, Wood x9, Rope x10", "its entries change where they are")
        kit:SetInputs({ { "Stone", 1 }, { "Stone_Axe", 1 }, { "Wood", 1 }, { "Rope", 1 }, { "Kit", 2 } })
        t.eq(inputs("Big_Kit"), "Stone x1, Stone_Axe x1, Wood x1, Rope x1, Kit x2", "and five can become five others")
        -- the write path decides: once it writes long lists, the same sentence works
        patch.WRITES.long_lists = true
        local ok, problem = pcall(function() kit:SetInputs({ Stone = 1 }) end)
        patch.WRITES.long_lists = false
        t.ok(ok, tostring(problem))
        t.eq(inputs("Big_Kit"), "Stone x1")
    end)
end)

t.test("SetOutputs and SetOutput change what comes out where it is: another count, another item, and the rest of an output kept", function()
    fresh_mods()
    as(A, function()
        local axe = Recipes:Get("Stone_Axe")
        axe:SetOutputs({ Stone_Axe = 2 })
        t.eq(outputs("Stone_Axe"), "Stone_Axe x2")
        axe:SetOutputs({ stone_knife = 3 })
        t.eq(outputs("Stone_Axe"), "Stone_Knife x3", "another item in the same place")
        t.eq(row("Stone_Axe").Outputs[1].Element.DataTableName, "D_ItemTemplate")
        axe:SetOutput("Stone_Knife", 1):ScaleOutputs(4)
        t.eq(outputs("Stone_Axe"), "Stone_Knife x4")
        local fill = Recipes:Get("Water_Fill")
        fill:SetOutput("Waterskin", 2)
        t.eq(outputs("Water_Fill"), "Waterskin_Full x2", "an item fits whichever of its templates the recipe gives")
        t.eq(row("Water_Fill").Outputs[1].DynamicProperties[1].Value, 500, "what else the output holds is kept")
        t.eq(row("Water_Fill").Outputs[1].DynamicProperties[1].PropertyType, 3)
        fill:SetOutputs({ { Template = "waterskin_full", Count = 5 } })
        t.eq(outputs("Water_Fill"), "Waterskin_Full x5")
        t.eq(#row("Water_Fill").Outputs[1].DynamicProperties, 1)
        local pack = Recipes:Get("Seed_Pack")
        pack:SetOutputs({ { Template = "Seed_Wheat", Count = 7 }, { "Fiber", 1 } })
        t.eq(outputs("Seed_Pack"), "Fiber x1, Seed_Wheat x7", "an output that stays keeps its place, and the new one takes the place that is left")
        Recipes:Get("Ore_Meta"):SetOutputs({ Stone = 3 })
        t.eq(outputs("Ore_Meta"), "Stone x3", "an item is written as the template of its own name")
    end)
end)

t.test("outputs keep their number in this version, and a wrong output is refused in plain words", function()
    local writes = fake.writes
    as(A, function()
        local axe = Recipes:Get("Stone_Axe")
        local err = t.raises(function() axe:SetOutputs({ Stone_Axe = 1, Wood = 2 }) end,
            "Stone_Axe gives 1 item and would give 2. This version of Wax cannot add an item it gives to a recipe or take one away. "
            .. "It can change the ones that are there")
        at(err)
        t.raises(function() axe:SetOutput("Wood", 1) end, "Stone_Axe gives 1 item and would give 2")
        t.raises(function() Recipes:Get("Seed_Pack"):SetOutputs({ Fiber = 1 }) end, "Seed_Pack gives 2 items and would give 1")
        t.raises(function() axe:SetOutputs({}) end, "SetOutputs was given nothing. A recipe has to give something")
        t.raises(function() axe:SetOutputs({ Stone_Axe = 0 }) end, "the count of Stone_Axe is a whole number of 1 or more")
        t.raises(function() axe:SetOutputs({ Stone_Ax = 1 }) end, "there is no item named 'Stone_Ax'. Did you mean 'Stone_Axe'")
        t.raises(function() axe:SetOutputs({ { Template = "Stone_Stak", Count = 1 } }) end,
            "there is no template named 'Stone_Stak'. Did you mean 'Stone_Stack'")
        t.raises(function() axe:SetOutputs({ Ghost = 1 }) end, "Ghost cannot come out of a recipe: the game has no template for it")
        t.raises(function() axe:SetOutputs({ Seed = 1 }) end,
            "Seed has 2 templates and none of its own name: Seed_Carrot and Seed_Wheat. Name the one you mean, as in "
            .. "{ Template = \"Seed_Carrot\", Count = 1 }")
        t.raises(function() axe:SetOutputs({ { "Stone", 1 }, { Template = "Stone", Count = 2 } }) end, "SetOutputs names Stone twice")
        -- the output that would go holds a list of its own, which the write path does not give back in this version
        t.raises(function() Recipes:Get("Water_Fill"):SetOutputs({ Waterskin = 1 }) end, "Water_Fill: Outputs")
    end)
    t.eq(fake.writes, writes, "not one write")
    t.eq(outputs("Water_Fill"), "Waterskin_Full x5")
    -- the write path decides: once it writes such lists, the same sentences work
    patch.WRITES.owning_lists = true
    local ok, problem = pcall(as, A, function()
        Recipes:Get("Stone_Knife"):SetOutputs({ Stone_Knife = 1, Wood = 2 }):SetOutput("Fiber", 3)
        Recipes:Get("Seed_Pack"):SetOutputs({ Fiber = 1 })
    end)
    patch.WRITES.owning_lists = false
    t.ok(ok, tostring(problem))
    t.eq(outputs("Stone_Knife"), "Stone_Knife x1, Wood x2, Fiber x3")
    t.eq(#row("Stone_Knife").Outputs[2].DynamicProperties, 0, "a new output starts with nothing else in it")
    t.eq(outputs("Seed_Pack"), "Fiber x1")
end)

t.test("time: work in millijoules, seconds at a bench, and a factor", function()
    fresh_mods()
    as(A, function()
        local axe = Recipes:Get("Stone_Axe")
        axe:SetWork(5000)
        t.eq(row("Stone_Axe").RequiredMillijoules, 5000)
        t.eq(axe:GetSeconds(), 5, "by hand, at 1000 milliwatts")
        axe:SetSeconds(1.5)
        t.eq(row("Stone_Axe").RequiredMillijoules, 1500, "its only bench is the hand")
        axe:SetSeconds(2, "Fabricator")
        t.eq(row("Stone_Axe").RequiredMillijoules, 5000, "two seconds at a bench that works at 2500")
        t.eq(axe:GetSeconds("fabricator"), 2)
        axe:SetSeconds(4, "hand")
        t.eq(axe.Work, 4000)
        axe:ScaleTime(0.5)
        t.eq(axe.Work, 2000)
        axe:ScaleTime(0.0001)
        t.eq(axe.Work, 1, "never under 1")
        local rope = Recipes:Get("Rope")
        local err = t.raises(function() rope:SetSeconds(5) end,
            "Rope is made at benches that work at 1000, 1500 and 2500 milliwatts. Say which bench the seconds are for, as in "
            .. "SetSeconds(5, \"Crafting_Bench\"), or use ScaleTime")
        at(err)
        t.raises(function() rope:GetSeconds() end, "Rope is made at benches that work at 1000, 1500 and 2500 milliwatts")
        rope:SetSeconds(2, "Machining_Bench")
        t.eq(rope.Work, 3000)
        t.eq(rope:GetSeconds("Machining_Bench"), 2)
        -- the item Crafting_Bench is one bench. Its recipe set is used by a faster device too, which the item does not mean
        rope:SetSeconds(3, "Crafting_Bench")
        t.eq(rope.Work, 3000)
        Recipes:Get("Cooked_Meat"):SetSeconds(10, "FirePit")
        t.eq(row("Cooked_Meat").RequiredMillijoules, 2750)
        t.raises(function() rope:SetSeconds(5, "Smelting") end,
            "the benches of Smelting work at 500 and 750 milliwatts. Name the bench by its item, or use SetWork(millijoules)")
        rope:SetSeconds(2, "Blast_Furnace")
        t.eq(rope.Work, 1500, "a bench the items do not have is named by its own row")
        t.raises(function() rope:SetSeconds(5, "Repair_Bench") end,
            "Wax does not know how fast Repair_Bench works, so seconds cannot be turned into work for it. Use SetWork(millijoules)")
        t.raises(function() Recipes:Get("Repair_Kit"):SetSeconds(5) end, "Repair_Kit is on no bench whose speed Wax knows")
        t.raises(function() Recipes:Get("Ingot"):SetSeconds(5) end, "Ingot is made at benches that work at 500 and 750 milliwatts")
        for _, wrong in ipairs({ 0, -2, "fast" }) do
            t.raises(function() axe:SetSeconds(wrong) end, "the time is a number of seconds above 0")
        end
        t.raises(function() axe:SetWork(0) end, "the work, in millijoules, is a whole number of 1 or more, got 0")
        t.raises(function() axe:SetWork(2.5) end, "the work, in millijoules, is a whole number of 1 or more")
        t.raises(function() axe:SetSeconds(1e9) end, "more work than the game can hold")
    end)
end)

t.test("a bench is named by its item, its recipe set, its own row or Hand, and a wrong name gets the nearest", function()
    fresh_mods()
    as(A, function()
        local axe = Recipes:Get("Stone_Axe")
        axe:SetBenches({ "hand", "Crafting_Bench", "HAND" })
        t.eq(benches("Stone_Axe"), "Character, Crafting_Bench", "the same bench twice is one")
        t.eq(row("Stone_Axe").RecipeSets[2].DataTableName, "D_RecipeSets")
        axe:SetBenches("Fabricator")
        t.eq(benches("Stone_Axe"), "Fabricator")
        -- the item FirePit works from the set Campfire, though a set named Firepit exists
        axe:MoveTo("firepit")
        t.eq(benches("Stone_Axe"), "Campfire")
        axe:MoveTo("Great_Hunt_Device")
        t.eq(benches("Stone_Axe"), "Crafting_Bench", "a device no item names, by its own row")
        axe:MoveTo("Kitchen_Stove")
        t.eq(benches("Stone_Axe"), "Kitchen_Stove", "a recipe set by its name")
        local err = t.raises(function() axe:MoveTo("Fabricater") end, "there is no bench named 'Fabricater'. Did you mean 'Fabricator'")
        at(err)
        t.ok(tostring(err):find("A bench is named by its recipe set, by the item that is the bench, or \"Hand\"", 1, true), tostring(err))
        t.raises(function() axe:MoveTo("Hnad") end, "Did you mean 'Hand'")
        t.raises(function() axe:MoveTo("WaterPurifier") end, "there is no bench named 'WaterPurifier'")
        t.raises(function() axe:MoveTo(7) end, "a bench is named by a string such as \"Fabricator\" or \"Hand\", got 7")
        t.raises(function() axe:SetBenches({}) end, "SetBenches was given no bench. To take a recipe off every list, use Hide()")
        t.raises(function() axe:SetBenches({ Hand = true }) end, "SetBenches takes a list, which has no place for the key \"Hand\"")
        t.raises(function() axe:SetBenches(5) end, "SetBenches takes a list of benches")
    end)
end)

t.test("AddBench and RemoveBench change where a recipe is made, and a recipe is never left on no bench", function()
    as(A, function()
        local axe = Recipes:Get("Stone_Axe")
        axe:AddBench("Hand"):AddBench("Fabricator")
        t.eq(benches("Stone_Axe"), "Kitchen_Stove, Character, Fabricator")
        local writes = fake.writes
        axe:AddBench("hand")
        t.eq(fake.writes, writes, "it is made there already: nothing is done")
        axe:RemoveBench("Kitchen_Stove")
        t.eq(benches("Stone_Axe"), "Character, Fabricator")
        local err = t.raises(function() axe:RemoveBench("Campfire") end, "Stone_Axe is not made at Campfire. It is made at Character and Fabricator")
        at(err)
        axe:RemoveBench("Fabricator")
        t.raises(function() axe:RemoveBench("Hand") end, "Stone_Axe would be on no bench. To take a recipe off every list, use Hide()")
        t.eq(benches("Stone_Axe"), "Character")
        -- Rope is on five benches: more than this version makes longer or shorter
        local rope = Recipes:Get("Rope")
        t.raises(function() rope:AddBench("Hand") end,
            "Rope is on 5 benches and would be on 6. This version of Wax only makes such a list longer or shorter while it has 4 entries "
            .. "or fewer, before and after")
        t.raises(function() rope:RemoveBench("Fabricator") end, "Rope is on 5 benches and would be on 4")
        t.raises(function() rope:MoveTo("Hand") end, "Rope is on 5 benches and would be on 1")
        rope:SetBenches({ "Hand", "Crafting_Bench", "Fabricator", "Campfire", "Kitchen_Stove" })
        t.eq(benches("Rope"), "Character, Crafting_Bench, Fabricator, Campfire, Kitchen_Stove", "five can become five others")
    end)
end)

t.test("SetRequirement, Hide and Show, and Reset", function()
    fresh_mods()
    as(A, function()
        local axe = Recipes:Get("Stone_Axe")
        axe:SetRequirement("stone_knife")
        t.eq(row("Stone_Axe").Requirement.RowName, "Stone_Knife")
        t.eq(row("Stone_Axe").Requirement.DataTableName, "D_Talents")
        t.eq(axe.Requirement, "Stone_Knife")
        axe:SetRequirement(nil)
        t.eq(row("Stone_Axe").Requirement.RowName, "None")
        t.eq(axe.Requirement, nil)
        local err = t.raises(function() axe:SetRequirement("Stone_Knive") end, "the tech tree has no node named 'Stone_Knive'. Did you mean 'Stone_Knife'")
        at(err)
        t.raises(function() axe:SetRequirement(4) end, "a node of the tech tree is named by a string")
        axe:Hide()
        t.eq(row("Stone_Axe").bForceDisableRecipe, true)
        t.eq(axe.Hidden, true)
        axe:Show()
        t.eq(row("Stone_Axe").bForceDisableRecipe, false)
        axe:Hide():SetWork(9)
        t.eq(axe:Reset(), 3, "three fields were taken back")
        t.eq(axe:Reset(), 0)
    end)
    untouched("after Reset")
    t.eq(#Data:Changes(), 0)
end)

t.test("All, At, Using, Making and Find give lists of recipes in the game's order", function()
    local all = Recipes:All()
    t.eq(#all, #ORDER)
    t.eq(all[1].Name, "Stone_Axe")
    t.eq(all[#ORDER + 1], nil)
    t.eq(tostring(all), "Recipes(14)")
    local seen = {}
    t.ok(all:Each(function(recipe) seen[#seen + 1] = recipe.Name end) == all)
    t.eq(table.concat(seen, ","), table.concat(ORDER, ","))
    local got = all:GetNames()
    got[1] = "changed"
    t.eq(all[1].Name, "Stone_Axe", "the names it gives are a copy")
    t.eq(names(Recipes:Using("fiber")), "Stone_Axe, Stone_Knife, Rope, Rope_Hand, Animal_Feed, Big_Kit, Seed_Pack, Repair_Kit")
    t.eq(names(Recipes:Using("Any_Raw_Meat")), "Animal_Feed, Roast", "by tag")
    t.eq(names(Recipes:Using("water")), "Water_Fill", "by resource")
    t.eq(#Recipes:Using("Ghost"), 0)
    t.eq(names(Recipes:Making("rope")), "Rope, Rope_Hand")
    t.eq(names(Recipes:Making("Stone")), "Ore_Meta", "through another template of the item")
    t.eq(names(Recipes:Making("Waterskin_Full")), "Water_Fill", "by the template itself")
    t.eq(names(Recipes:Making("Kit")), "Big_Kit, Repair_Kit")
    t.eq(names(Recipes:Find(function(recipe) return recipe.Work > 2500 end)), "Rope_Hand, Cooked_meat")
    t.eq(names(Recipes:Find(function(recipe) return #recipe.Outputs == 2 end)), "Seed_Pack")
    local err = t.raises(function() Recipes:Using("Fibre") end, "there is no item, tag or resource named 'Fibre'. Did you mean 'Fiber'")
    at(err)
    err = t.raises(function() Recipes:Making("Roope") end, "there is no item named 'Roope'. Did you mean 'Rope'")
    at(err)
    t.raises(function() Recipes:Find("Rope") end, "Find takes a function that gets a recipe")
    t.raises(function() return all.Count end, "Count is not a member of a list of recipes")
    t.raises(function() all[1] = nil end, "a list of recipes cannot be assigned to")
    t.raises(function() all.Each(print) end, "call Each with a colon")
end)

t.test("At asks the game, which costs no read of a row, and gives the same as the table does", function()
    local asked, calls = fake.rows_asked, library.calls
    local by_hand = Recipes:At("Hand")
    t.eq(names(by_hand), "Stone_Axe, Stone_Knife, Rope_Hand, Water_Fill, Seed_Pack")
    t.eq(library.calls, calls + 1, "one call")
    t.eq(fake.rows_asked, asked, "and no row")
    -- UE4SS never frees the list the game hands over, so the answer is kept until a recipe is written
    t.eq(names(Recipes:At("hand")), names(by_hand))
    t.eq(library.calls, calls + 1, "asked again with nothing written: the game is not asked")
    t.eq(names(Recipes:At("Fabricator")), "Rope, Frag_Grenade, Ore_Meta, Big_Kit")
    t.eq(names(Recipes:At("campfire")), "Cooked_meat, Roast")
    t.eq(names(Recipes:At("FirePit")), "Cooked_meat, Roast", "the bench that works from the set Campfire")
    t.eq(#Recipes:At("Manufacturer"), 1)
    local err = t.raises(function() Recipes:At("Fabricater") end, "there is no bench named 'Fabricater'")
    at(err)
    module.ASK_GAME = false
    t.eq(names(Recipes:At("Hand")), names(by_hand), "from the table")
    t.eq(names(Recipes:At("Fabricator")), "Rope, Frag_Grenade, Ore_Meta, Big_Kit")
    module.ASK_GAME = true
    -- the game was only ever asked in a prospect: at the title screen, where mods load, the table is read
    t.eq(module.ASK_ANYWHERE, false)
    calls, in_prospect = library.calls, false
    t.eq(names(Recipes:At("Hand")), names(by_hand))
    t.eq(library.calls, calls, "the game was not asked")
    in_prospect = true
    -- a hidden recipe is on no bench's list, whichever way it is asked
    calls = library.calls
    as(A, function() Recipes:Get("Stone_Knife"):Hide() end)
    t.eq(names(Recipes:At("Hand")), "Stone_Axe, Rope_Hand, Water_Fill, Seed_Pack")
    t.eq(library.calls, calls + 1, "a write in the same frame: the game is asked again")
    module.ASK_GAME = false
    t.eq(names(Recipes:At("Hand")), "Stone_Axe, Rope_Hand, Water_Fill, Seed_Pack")
    module.ASK_GAME = true
    t.eq(names(Recipes:Using("Stick")), "Stone_Axe, Stone_Knife, Big_Kit", "the other lists still have it")
    as(A, function() Recipes:Get("Stone_Knife"):Show() end)
end)

t.test("a list does a change to each of its recipes and comes back", function()
    fresh_mods()
    as(A, function()
        local by_hand = Recipes:At("Hand")
        t.ok(by_hand:ScaleTime(0.5) == by_hand)
        t.eq(row("Stone_Axe").RequiredMillijoules, 1250)
        t.eq(row("Rope_Hand").RequiredMillijoules, 1500)
        t.eq(row("Rope").RequiredMillijoules, 1500, "not on that bench")
        Recipes:Using("Fiber"):ScaleInput("Fiber", 0.5)
        t.eq(inputs("Stone_Axe"), "Fiber x5, Stick x4, Stone x6")
        t.eq(inputs("Rope"), "Fiber x6")
        t.eq(inputs("Big_Kit"), "Fiber x1, Stick x2, Stone x3, Wood x4, Rope x5")
        Recipes:Making("Rope"):SetOutput("Rope", 2):Hide()
        t.eq(outputs("Rope") .. " / " .. outputs("Rope_Hand"), "Rope x2 / Rope x2")
        t.eq(row("Rope").bForceDisableRecipe and row("Rope_Hand").bForceDisableRecipe, true)
        Recipes:Making("Rope"):Show()
        -- what does not apply to a recipe is passed over
        Recipes:At("Hand"):RemoveInput("Stick")
        Recipes:All():ScaleInput("Raw_Meat", 3)
        t.eq(inputs("Stone_Axe"), "Fiber x5, Stone x6")
        t.eq(inputs("Stone_Knife"), "Fiber x1, Stone x4")
        t.eq(inputs("Cooked_Meat"), "Raw_Meat x3")
        t.eq(inputs("Rope"), "Fiber x6")
        Recipes:At("Campfire"):AddBench("Kitchen_Stove"):RemoveBench("Fabricator")
        t.eq(benches("Roast"), "Campfire, Kitchen_Stove")
        t.eq(benches("Cooked_Meat"), "Campfire, Kitchen_Stove")
        t.eq(Recipes:Making("Rope"):Reset(), 7, "three fields of Rope and four of Rope_Hand")
        t.eq(outputs("Rope") .. " / " .. inputs("Rope_Hand"), "Rope x1 / Fiber x20")
        t.eq(row("Rope_Hand").RequiredMillijoules, 3000)
    end)
end)

t.test("when a change is refused for some recipes of a list the others are changed, and one error says how many were not", function()
    fresh_mods()
    as(A, function()
        local err = t.raises(function() Recipes:All():RemoveBench("Campfire") end,
            "RemoveBench could not change 1 of 14 recipes. The first: Roast would be on no bench. To take a recipe off every list, use Hide()")
        at(err)
        t.eq(benches("Cooked_Meat"), "Kitchen_Stove", "the one that could be changed was")
        t.eq(benches("Roast"), "Campfire")
        err = t.raises(function() Recipes:Using("Fiber"):SetInputs({ Stone = 1 }) end, "SetInputs could not change 1 of 8 recipes. The first: Big_Kit takes 5 items")
        t.eq(inputs("Rope"), "Stone x1")
        t.eq(inputs("Big_Kit"), "Fiber x1, Stick x2, Stone x3, Wood x4, Rope x5")
        -- what the mod wrote is checked once, before any recipe is touched
        local writes = fake.writes
        t.raises(function() Recipes:All():SetInput("Stne", 1) end, "there is no item, tag or resource named 'Stne'")
        t.raises(function() Recipes:All():ScaleTime(0) end, "a factor is a number above 0")
        t.raises(function() Recipes:All().Hide() end, "call Hide with a colon: list:Hide(...)")
        t.eq(fake.writes, writes)
    end)
end)

t.test("outside a task a list does its work in that frame, inside one it pauses and nothing of the engine is kept over a pause", function()
    fresh_mods()
    local pauses = module.stats().pauses
    as(A, function() Recipes:All():ScaleTime(2) end)
    t.eq(row("Ingot").RequiredMillijoules, 5000, "done before the call returns")
    t.eq(module.stats().pauses, pauses)
    -- a clock that moves half a millisecond each time it is read: a pause after every other recipe
    local clock = module.clock
    local ticks = 0
    module.clock = function()
        ticks = ticks + 1
        return ticks * 0.0005
    end
    local _, frames = in_task(A, function()
        Recipes:All():ScaleTime(0.5)
        Recipes:Find(function(recipe) return recipe.Hidden end)
    end)
    module.clock = clock
    t.ok(frames > 5, "it took frames: " .. frames)
    t.ok(module.stats().pauses > pauses + 5, "and paused: " .. module.stats().pauses)
    t.eq(row("Ingot").RequiredMillijoules, 2500)
    t.eq(row("Stone_Axe").RequiredMillijoules, 2500)
    t.eq(fake.stale, 0, "nothing was used after its frame")
    -- reading every recipe and every template pauses too, inside a task
    data.api:Flush()
    frame()
    local loads = data.pauses
    local slow = data.clock
    local reads = 0
    data.clock = function()
        reads = reads + 1
        return now + reads * 0.0004
    end
    local found = in_task(A, function() return names(Recipes:Making("Stone")) .. " / " .. names(Recipes:Using("Stone")) end)
    data.clock = slow
    t.eq(found, "Ore_Meta / Stone_Axe, Stone_Knife, Big_Kit, Ingot")
    t.ok(data.pauses > loads, "the read gave frames back: " .. (data.pauses - loads))
    t.eq(fake.stale, 0)
    -- rows that were read before are handed over without a pause, so the search gives frames back itself
    loads, pauses = data.pauses, module.stats().pauses
    local piece = module.PIECE
    module.PIECE = 2
    ticks = 0
    module.clock = function()
        ticks = ticks + 1
        return ticks * 0.0005
    end
    local again, took = in_task(A, function() return names(Recipes:Using("Stone")) end)
    module.clock, module.PIECE = clock, piece
    t.eq(again, "Stone_Axe, Stone_Knife, Big_Kit, Ingot")
    t.eq(data.pauses, loads, "nothing had to be read from the game")
    t.ok(module.stats().pauses > pauses + 2 and took > 3, ("it paused all the same: %d pauses, %d frames"):format(module.stats().pauses - pauses, took))
    t.eq(fake.stale, 0)
end)

t.test("a mod that is loaded again says the same things and nothing is written, though the table still holds what it wrote", function()
    fresh_mods()
    local function tune()
        Recipes:At("Hand"):MoveTo("Crafting_Bench")
        Recipes:Using("Gunpowder"):RemoveInput("Gunpowder")
        Recipes:Find(function(recipe) return recipe.Work > 2600 end):SetWork(2600)
        local rope = Recipes:Get("Rope_Hand")
        if rope.Inputs[1].Count > 10 then rope:SetInputs({ Fiber = 10 }) end
        Recipes:Making("Kit"):Hide()
        Recipes:At("Campfire"):ScaleInputs(2)
    end
    for _, ask in ipairs({ true, false }) do
        module.ASK_GAME = ask
        as(A, tune)
        frame()
        t.eq(benches("Stone_Axe"), "Crafting_Bench")
        t.eq(inputs("Frag_Grenade"), "Refined_Metal x1, Volatile_Substance x3")
        t.eq(row("Cooked_Meat").RequiredMillijoules, 2600)
        t.eq(inputs("Cooked_Meat"), "Raw_Meat x2")
        t.eq(row("Roast").QueryInputs[1].Count, 2)
        t.eq(inputs("Rope_Hand"), "Fiber x10")
        t.eq(row("Big_Kit").bForceDisableRecipe, true)
        local changed = #Data:Changes()
        -- a file save: the mod unloads and loads, and the table still holds everything it wrote
        local writes = fake.writes
        running.ModA = true
        unload(A)
        A = mod("ModA")
        t.eq(#Recipes:At("Hand"), 0, "to anyone else, nothing is made by hand right now")
        as(A, function()
            t.eq(#Recipes:At("Hand"), 5, "to the mod itself, what it wrote before does not count")
            t.eq(Recipes:Get("Cooked_Meat").Work, 7500)
            t.eq(Recipes:Get("Big_Kit").Hidden, false)
            tune()
        end)
        frame()
        now = now + 3
        frame()
        frame()
        t.eq(fake.writes, writes, "not one write (asking the game: " .. tostring(ask) .. ")")
        t.eq(#Data:Changes(), changed, "and every change still stands")
        t.eq(benches("Stone_Axe"), "Crafting_Bench")
        t.eq(inputs("Frag_Grenade"), "Refined_Metal x1, Volatile_Substance x3")
        t.eq(row("Cooked_Meat").RequiredMillijoules, 2600)
        t.eq(inputs("Cooked_Meat"), "Raw_Meat x2", "not doubled a second time")
        t.eq(row("Roast").QueryInputs[1].Count, 2)
        t.eq(inputs("Rope_Hand"), "Fiber x10")
        t.eq(row("Repair_Kit").bForceDisableRecipe, true)
        running.ModA = false
        unload(A)
        frame()
        now = now + 3
        frame()
        untouched("after the mod is switched off")
        A = mod("ModA")
    end
    module.ASK_GAME = true
end)

t.test("changes of two mods to one recipe both hold where they build on each other, and a Set over another's is a conflict", function()
    fresh_mods()
    as(A, function() Recipes:Get("Stone_Axe"):SetInput("Wood", 1):SetWork(1000) end)
    as(B, function() Recipes:Get("Stone_Axe"):ScaleInputs(2):ScaleTime(3) end)
    t.eq(inputs("Stone_Axe"), "Fiber x20, Stick x8, Stone x12, Wood x2")
    t.eq(row("Stone_Axe").RequiredMillijoules, 3000)
    t.eq(#Data:Conflicts(), 0, "building on another mod's change is no conflict")
    as(B, function() Recipes:Get("Stone_Axe"):SetWork(700) end)
    frame()
    local conflict = Data:Conflicts()[1]
    t.eq(conflict.Field .. " used " .. conflict.Used .. " over " .. conflict.Covered[1], "RequiredMillijoules used ModB over ModA")
    unload(A)
    frame()
    now = now + 3
    frame()
    t.eq(inputs("Stone_Axe"), "Fiber x20, Stick x8, Stone x12", "ModB's doubling is worked out again without ModA's wood")
    t.eq(row("Stone_Axe").RequiredMillijoules, 700)
    A = mod("ModA")
end)

t.test("a change that stops working when a mod underneath leaves is left out and said once, and the game is not written wrongly", function()
    fresh_mods()
    as(A, function() Recipes:Get("Roast"):AddBench("Kitchen_Stove") end)
    as(B, function() Recipes:Get("Roast"):RemoveBench("Campfire") end)
    t.eq(benches("Roast"), "Kitchen_Stove")
    local errors = #log.since(0, { level = "error", channel = "wax.data" })
    unload(A)
    frame()
    now = now + 3
    frame()
    t.eq(benches("Roast"), "Campfire", "ModB's change would leave the recipe on no bench now, so it is left out")
    local said = log.since(0, { level = "error", channel = "wax.data" })
    t.eq(#said, errors + 1)
    t.ok(tostring(said[#said].message):find("Roast would be on no bench", 1, true), tostring(said[#said].message))
    A = mod("ModA")
end)

t.test("Add is switched off with the write path's rows switch, and says so", function()
    fresh_mods()
    t.eq(patch.WRITES.rows, false)
    as(A, function()
        local err = t.raises(function() Recipes:Add("ModA_Quick_Axe", { like = "Stone_Axe", inputs = { Stone = 1 } }) end,
            "game.Recipes:Add is switched off in this version of Wax: adding a row to the game's tables while the game runs has not been "
            .. "seen working yet. Recipes the game has can be changed, and Hide takes one off the lists")
        at(err)
    end)
    t.eq(fake.rows_added, 0)
end)

t.test("with the rows switch on, Add makes a recipe from another one and the options, and unloading switches it off", function()
    patch.WRITES.rows = true
    local ok, problem = pcall(function()
        as(A, function()
            t.raises(function() Recipes:Add("ModA_Quick_Axe", { inputs = { Stone = 1 } }) end, "Add needs a recipe to start from, such as { like = \"Stone_Axe\" }")
            t.raises(function() Recipes:Add("ModA_Quick_Axe", { like = "Stone_Ax" }) end, "there is no recipe named 'Stone_Ax'")
            t.raises(function() Recipes:Add("ModA_Quick_Axe", { like = "Stone_Axe", input = {} }) end, "Add has no option named \"input\". Did you mean 'inputs'")
            t.raises(function() Recipes:Add("ModA_Quick_Axe", { like = "Stone_Axe", seconds = 1, work = 5 }) end, "Add takes seconds or work, not both")
            t.raises(function() Recipes:Add("ModA_Quick_Axe", "Stone_Axe") end, "Add takes the new recipe's name and a table")
            t.raises(function() Recipes:Add("Quick_Axe", { like = "Stone_Axe" }) end, "a row that ModA adds has a name that begins with \"ModA_\"")
            t.raises(function() Recipes:Add("ModA_Quick_Axe", { like = "Stone_Axe", inputs = { Stne = 1 } }) end, "there is no item, tag or resource named 'Stne'")
            t.eq(fake.rows_added, 0, "none of that reached the game")
            local quick = Recipes:Add("ModA_Quick_Axe", { like = "Stone_Axe", inputs = { Stone = 1, Stick = 1 }, outputs = { Stone_Axe = 2 },
                benches = { "Hand", "Crafting_Bench" }, work = 1000, requirement = false })
            t.eq(quick.Name, "ModA_Quick_Axe")
            t.ok(Recipes:Get("moda_quick_axe") == quick)
            t.eq(inputs("ModA_Quick_Axe"), "Stick x1, Stone x1")
            t.eq(outputs("ModA_Quick_Axe"), "Stone_Axe x2")
            t.eq(benches("ModA_Quick_Axe"), "Character, Crafting_Bench")
            t.eq(row("ModA_Quick_Axe").RequiredMillijoules, 1000)
            t.eq(row("ModA_Quick_Axe").Requirement.RowName, "None")
            t.eq(#Recipes:All(), #ORDER + 1)
            t.eq(inputs("Stone_Axe"), "Fiber x10, Stick x4, Stone x6", "the recipe it started from is as it was")
            -- an option that is refused leaves no half-made recipe on the lists
            t.raises(function() Recipes:Add("ModA_Bad", { like = "Stone_Axe", benches = "Hand", outputs = { Stone = 1, Wood = 1 } }) end,
                "ModA_Bad gives 1 item and would give 2")
            t.eq(row("ModA_Bad").bForceDisableRecipe, true, "switched off")
            t.eq(#row("ModA_Bad").RecipeSets, 0)
        end)
        unload(A)
        frame()
        now = now + 3
        frame()
        t.eq(row("ModA_Quick_Axe").bForceDisableRecipe, true, "a row is not taken out while the game runs: it is switched off")
        t.eq(#row("ModA_Quick_Axe").RecipeSets, 0)
        A = mod("ModA")
    end)
    patch.WRITES.rows = false
    if not ok then error(problem, 0) end
end)

t.test("a changed recipe makes the crafting tab follow at the end of the frame: its recipes asked again, once", function()
    fresh_mods()
    frame()
    ui.mouse, ui.tab, ui.bench = true, 1, nil
    tab.RefreshRecipes()
    ui.reset()
    tab_list["On Recipe Selected"](tab_list, handle_for("Stone_Knife"))
    ui.reset()
    as(A, function()
        Recipes:Get("Stone_Axe"):SetInputs({ Stone = 1 }):SetWork(100):SetOutputs({ Stone_Axe = 2 })
        Recipes:Get("Rope_Hand"):ScaleTime(2)
    end)
    t.eq(tab.FullUpdateRequested, false, "not before the frame ends")
    frame()
    t.eq(tab.FullUpdateRequested, true, "the game's own way to make its tiles ask again")
    t.eq(ui.refreshes, 0, "the list was not built again: which recipes it has did not change")
    t.eq(#ui.selections, 0, "and the chosen recipe was not one of the changed ones")
    frame()
    t.eq(ui.full_updates, 1, "once, however many recipes changed")
    as(A, function() Recipes:Get("Stone_Knife"):SetInput("Stone", 1) end)
    frame()
    t.eq(table.concat(ui.selections, ","), "Stone_Axe,Stone_Knife", "the chosen recipe changed: another tile is chosen first, then it again")
    t.eq(ui.chosen, "Stone_Knife")
    t.ok(tostring(ui.needs):find("stone x1", 1, true), "so the tab shows its new cost, which choosing it alone would not have built: " .. tostring(ui.needs))
    t.eq(ui.built, 2)
    t.eq(ui.refreshes, 0)
end)

t.test("a change of which recipes a list has builds the tab's list again, once, and chooses again what was chosen", function()
    frame()
    ui.reset()
    local generation = ui.generation
    as(A, function()
        Recipes:Get("Rope_Hand"):Hide()
        Recipes:Get("Seed_Pack"):MoveTo("Fabricator")
        Recipes:Get("Water_Fill"):SetRequirement("Rope")
        Recipes:Get("Stone_Axe"):SetWork(50)
    end)
    frame()
    t.eq(ui.refreshes, 1, "one rebuild for three changes of that kind")
    t.eq(ui.generation, generation + 1)
    t.eq(tab.FullUpdateRequested, true)
    t.eq(table.concat(ui.selections, ","), "Stone_Knife", "the rebuild drops the selection, and it is made again on the new tile")
    t.eq(ui.chosen, "Stone_Knife")
    t.eq(tab_list.RecipeElements:GetArrayNum(), 3, "Stone_Axe, Stone_Knife and Water_Fill are left")
    -- when the chosen recipe is the one that went, nothing is chosen
    ui.reset()
    as(A, function() Recipes:Get("Stone_Knife"):Hide() end)
    frame()
    t.eq(ui.refreshes, 1)
    t.eq(#ui.selections, 0)
    t.eq(ui.chosen, nil)
    -- a mod that unloads puts its recipes back, and the tab follows that too
    ui.reset()
    unload(A)
    frame()
    now = now + 3
    frame()
    t.eq(ui.refreshes, 1)
    t.eq(tab_list.RecipeElements:GetArrayNum(), 5)
    A = mod("ModA")
    t.eq(ui.crashes, 0, "no tile was used after its list was built again")
    t.eq(ui.misuse, 0)
end)

t.test("nothing is done to a screen that does not show the crafting tab, and a bench is left alone in this version", function()
    frame()
    ui.reset()
    local function change() as(A, function() Recipes:Get("Stone_Axe"):Hide():SetWork(77) end) end
    local function back() as(A, function() Recipes:Get("Stone_Axe"):Reset() end) end
    ui.tab = 0
    change()
    frame()
    t.eq(ui.refreshes, 0, "another tab of the menu: the game builds the list itself when the crafting tab is opened")
    t.eq(tab.FullUpdateRequested, false)
    ui.tab, ui.mouse = 1, false
    back()
    frame()
    t.eq(ui.refreshes, 0, "no screen is open")
    ui.mouse, ui.bench = true, bench
    t.eq(crafting.REFRESH_BENCH, false, "off until it was tried at a real bench")
    change()
    frame()
    t.eq(#ui.bench_calls, 0, "a bench is not rebuilt")
    t.eq(ui.refreshes, 0)
    crafting.REFRESH_BENCH = true
    back()
    frame()
    crafting.REFRESH_BENCH = false
    t.eq(table.concat(ui.bench_calls, "; "), "Initialise(own set, false, true); UpdateAllRecipeStates; chose Big_Kit",
        "with the switch on: the list's own set and the screen's two switches, then the selection")
    ui.bench = nil
    t.eq(#guard.errors(), 0)
end)

t.test("game.Crafting:Refresh can be asked for by anyone, checks its options, and runs once when the frame ends", function()
    frame()
    ui.mouse, ui.tab, ui.bench = true, 1, nil
    tab.RefreshRecipes()
    tab_list["On Recipe Selected"](tab_list, handle_for("Rope_Hand"))
    ui.reset()
    local owner = mod("Gone")
    as(owner, function()
        Crafting:Refresh()
        Crafting:Refresh({ lists = false })
        Crafting:Refresh({ lists = false, recipes = { "Stone_Axe" } })
    end)
    unload(owner)
    t.eq(ui.refreshes, 0, "not before the frame ends")
    frame()
    t.eq(ui.refreshes, 1, "three asks, one rebuild, though the mod that asked is gone")
    t.eq(table.concat(ui.selections, ","), "Rope_Hand")
    ui.reset()
    Crafting:Refresh({ lists = false, recipes = { "Stone_Axe" } })
    frame()
    t.eq(ui.refreshes .. "/" .. #ui.selections, "0/0", "only the tiles are asked, and another recipe is chosen")
    t.eq(tab.FullUpdateRequested, true)
    Crafting:Refresh({ lists = false, recipes = { "rope_hand" } })
    frame()
    t.eq(table.concat(ui.selections, ","), "Stone_Axe,Rope_Hand", "the chosen recipe is among them: another tile first, then it again")
    Crafting:Refresh({ lists = false })
    frame()
    t.eq(#ui.selections, 4, "no recipes named: the chosen one is chosen again whichever it is")
    t.eq(ui.chosen, "Rope_Hand")
    local err = t.raises(function() Crafting:Refresh({ list = false }) end, "game.Crafting:Refresh has no option named list. Did you mean 'lists'")
    at(err)
    t.raises(function() Crafting:Refresh("lists") end, "game.Crafting:Refresh takes a table of options such as { lists = false }, or nothing")
    t.raises(function() Crafting:Refresh({ lists = 1 }) end, "lists is true or false")
    t.raises(function() Crafting:Refresh({ recipes = "Stone_Axe" }) end, "recipes is a list of recipe names")
    frame()
end)

t.test("what was worked out from other tables follows when a mod changes them", function()
    fresh_mods()
    as(A, function()
        local axe = Recipes:Get("Stone_Axe")
        axe:SetSeconds(2, "Fabricator")
        t.eq(axe.Work, 5000)
        Data:Table("Processing"):Set("Fabricator", "MaxMilliwattage", 4000)
    end)
    frame()
    as(A, function()
        local axe = Recipes:Get("Stone_Axe")
        axe:SetSeconds(2, "Fabricator")
        t.eq(axe.Work, 8000, "the bench is faster now")
        Data:Table("ItemTemplate"):Set("Stone_Stack", "ItemStaticData", { RowName = "Wood" })
    end)
    frame()
    t.eq(names(Recipes:Making("Wood")), "Ore_Meta")
    t.eq(#Recipes:Making("Stone"), 0)
    -- when the game no longer answers for a bench, the table is read, and it is said once
    library.present = false
    data.api:Flush()
    frame()
    local warned = #log.since(0, { level = "warn", channel = "wax.recipes" })
    t.eq(names(Recipes:At("Hand")), "Stone_Axe, Stone_Knife, Rope_Hand, Water_Fill, Seed_Pack")
    t.eq(names(Recipes:At("Fabricator")), "Rope, Frag_Grenade, Ore_Meta, Big_Kit")
    t.eq(#log.since(0, { level = "warn", channel = "wax.recipes" }), warned + 1)
    library.present = true
end)

t.test("what a mod author reads is plain, and every function is described in the types", function()
    local unwanted = wording.unwanted()
    if unwanted then t.ok(wording.complete(unwanted), "the owner's list was read whole from " .. wording.SOURCE) end
    local file = assert(io.open("wax/types/recipes.lua", "rb"))
    local text = file:read("a")
    file:close()
    local lines = 0
    for line in text:gmatch("[^\r\n]+") do
        if line:sub(1, 3) == "---" then
            lines = lines + 1
            t.eq(wording.wrong_with(line:sub(4), unwanted), nil, "wax/types/recipes.lua: " .. line:sub(1, 70))
        end
    end
    t.ok(lines > 150, "the type file was read: " .. lines)
    t.ok(#said > 80, "the messages of this suite were gathered: " .. #said)
    for _, message in ipairs(said) do t.eq(wording.wrong_with(message, unwanted), nil, message) end
    for _, name in ipairs(getmetatable(Recipes).__names()) do
        t.ok(text:find("function Recipes:" .. name .. "(", 1, true), "game.Recipes:" .. name .. " is described")
    end
    local fields = { Name = true, Inputs = true, Tags = true, Resources = true, Outputs = true, Benches = true, Work = true,
                     Requirement = true, Hidden = true }
    for _, name in ipairs(getmetatable(Recipes:Get("Rope")).__names()) do
        if fields[name] then
            t.ok(text:find("---@field " .. name .. " ", 1, true), "recipe." .. name .. " is described")
        else
            t.ok(text:find("function Recipe:" .. name .. "(", 1, true), "recipe:" .. name .. " is described")
        end
    end
    for _, name in ipairs(getmetatable(Recipes:All()).__names()) do
        t.ok(text:find("function RecipeList:" .. name .. "(", 1, true), "list:" .. name .. " is described")
    end
end)

t.test("in the whole suite nothing was done that the game could not take", function()
    fresh_mods()
    untouched("at the end")
    for _, name in ipairs({ "crashes", "misuse", "sloppy", "silent", "grown", "stale", "leaks", "never_reads", "unknown_names" }) do
        t.eq(fake[name], 0, name)
    end
    t.eq(ui.crashes + ui.misuse, 0, "the crafting screen")
    local raised = guard.errors()
    t.eq(#raised, 0, "no task raised: " .. tostring(raised[1] and (raised[1].message or raised[1].trace)))
    -- the two recipes that were added stay in the table, switched off: two fields each hold that
    t.eq(journal.stats().rows, 2)
    t.eq(journal.stats().entries, 4)
end)

t.finish("recipes")
