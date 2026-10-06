-- Offline tests for the Recipe Browser's item statistics: stats.lua and the stage 4 lists of source.lua.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\recipe_stats_test.lua luamods\RecipeBrowser
-- With build\recipe-browser\check\tables.lua there (python scripts\recipe_check.py writes it), every shown item of the
-- game's own tables is asked for as well, and the numbers of that run are printed.

local t = dofile("wax/tests/offline/harness.lua")

local folder = arg and arg[1]
if folder then folder = folder:gsub("\\", "/"):gsub("/+$", "") end

local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil
end

if not folder or not exists(folder .. "/stats.lua") then
    print("recipe-stats: 0 passed (skipped: Recipe Browser is not here)")
    os.exit(0)
end

-- The files get the standard library and nothing else, so a use of Wax or the engine fails here.
local function part(name)
    local env = { string = string, table = table, math = math, select = select, type = type, pairs = pairs, ipairs = ipairs,
        next = next, tostring = tostring, tonumber = tonumber, setmetatable = setmetatable, getmetatable = getmetatable,
        error = error, pcall = pcall, rawget = rawget, rawset = rawset }
    setmetatable(env, { __index = function(_, key) error(name .. ".lua reads the global '" .. tostring(key) .. "'", 2) end })
    local chunk = assert(loadfile(folder .. "/" .. name .. ".lua", "t", env))
    local value = chunk()
    assert(type(value) == "table", name .. ".lua must return a table")
    return value
end

local source, stats, format = part("source"), part("stats"), part("format")
local fixture = dofile("wax/tests/offline/recipe_fixture.lua")

-- ---------------------------------------------------------------- a small game

local NONE = { RowName = "None" }
local function h(name) return { RowName = name } end
local function stat(name) return '(Value="' .. name .. '")' end

local function described(name, positive, negative, extra)
    local row = { Name = name, PositiveDescription = positive, NegativeDescription = negative }
    for key, value in pairs(extra or {}) do row[key] = value end
    return row
end

local T = {
    ItemsStatic = {
        defaults = { Itemable = NONE, Processing = NONE, Manual_Tags = { GameplayTags = {} }, Generated_Tags = { GameplayTags = {} },
            Durable = NONE, Decayable = NONE, ToolDamage = NONE, FirearmData = NONE, AmmoType = NONE, Ballistic = NONE,
            Armour = NONE, Equippable = NONE, Consumable = NONE, Buildable = NONE, Inventory = NONE, Fillable = NONE,
            AdditionalStats = {} },
        rows = {
            { Name = "Cloth_Chest", Itemable = h("Item_Cloth_Chest"), Durable = h("Armor_Cloth"), Armour = h("Cloth_Chest") },
            { Name = "Stone_Pickaxe", Itemable = h("Item_Stone_Pickaxe"), Durable = h("Stone_Pickaxe"), ToolDamage = h("Stone_Pickaxe"),
                AdditionalStats = { [stat("BaseArmorDamageModifier_+%")] = 500 } },
            { Name = "Stone_Axe", Itemable = h("Item_Stone_Axe"), ToolDamage = h("Stone_Axe") },
            { Name = "Bone_Knife", Itemable = h("Item_Bone_Knife"), ToolDamage = h("Bone_Knife") },
            { Name = "Wood_Bow", Itemable = h("Item_Wood_Bow"), FirearmData = h("Wood_Bow") },
            { Name = "Rifle_Hunting", Itemable = h("Item_Rifle_Hunting"), FirearmData = h("Rifle_Hunting") },
            { Name = "Rifle_Round", Itemable = h("Item_Rifle_Round"), AmmoType = h("Rifle_Round"), Ballistic = h("Rifle_Round") },
            { Name = "Buckshot", Itemable = h("Item_Buckshot"), AmmoType = h("Shell_Explosive"), Ballistic = h("Rifle_Round") },
            { Name = "Stone_Arrow", Itemable = h("Item_Stone_Arrow"), Ballistic = h("Stone_Arrow") },
            { Name = "Cooked_Meat", Itemable = h("Item_Cooked_Meat"), Consumable = h("Cooked_Meat"), Decayable = h("Decay_Cooked") },
            { Name = "Spoiled_Meat", Itemable = h("Item_Spoiled_Meat") },
            { Name = "Beer", Itemable = h("Item_Beer"), Consumable = h("Drink_Beer") },
            { Name = "Glass_Bottle", Itemable = h("Item_Glass_Bottle") },
            { Name = "Bandage", Itemable = h("Item_Bandage"), Consumable = h("Bandage") },
            { Name = "Wood_Floor", Itemable = h("Item_Wood_Floor"), Durable = h("Wood_Building"), Buildable = h("Wood_Floor") },
            { Name = "Furnace", Itemable = h("Item_Furnace"), Durable = h("Wood_Building"), Inventory = h("Furnace") },
            { Name = "Canteen", Itemable = h("Item_Canteen"), Fillable = h("Canteen") },
            { Name = "Backpack", Itemable = h("Item_Backpack"), Equippable = h("Backpack_Basic") },
            { Name = "Fiber", Itemable = h("Item_Fiber") },
            { Name = "Stone", Itemable = h("Item_Stone") },
            { Name = "Odd", Itemable = h("Item_Odd"), Durable = h("Gone"),
                AdditionalStats = { [stat("IsScorpionItem_?")] = 1, [stat("IsInvulnerable_?")] = 1, [stat("BaseMaximumHealth_+")] = 25,
                    [stat("Not_A_Stat_+")] = 3, [stat("BaseHeatResistance_%")] = 0, [stat("CanCraftAnywhere_?")] = 1,
                    [stat("BaseReloadSpeedMilliseconds_+")] = 1500, [stat("OnlyNegative_+")] = 2 } },
            { Name = "Plain", Itemable = h("Item_Plain") },
            { Name = "Bare" },
        },
    },
    Itemable = {
        defaults = { DisplayName = "", Icon = "None", Weight = 0, MaxStack = 1 },
        rows = {
            { Name = "Item_Cloth_Chest", DisplayName = "Cloth Chest Armor", Weight = 750 },
            { Name = "Item_Stone_Pickaxe", DisplayName = "Stone Pickaxe", Weight = 500 },
            { Name = "Item_Stone_Axe", DisplayName = "Stone Axe", Weight = 500 },
            { Name = "Item_Bone_Knife", DisplayName = "Bone Knife", Weight = 500 },
            { Name = "Item_Wood_Bow", DisplayName = "Wood Bow", Weight = 1000 },
            { Name = "Item_Rifle_Hunting", DisplayName = "Hunting Rifle", Weight = 4000 },
            { Name = "Item_Rifle_Round", DisplayName = "7.62mm Round", Weight = 10, MaxStack = 100 },
            { Name = "Item_Buckshot", DisplayName = "Explosive Shell", Weight = 20, MaxStack = 50 },
            { Name = "Item_Stone_Arrow", DisplayName = "Stone Arrow", Weight = 10, MaxStack = 100 },
            { Name = "Item_Cooked_Meat", DisplayName = "Cooked Meat", Weight = 50, MaxStack = 20 },
            { Name = "Item_Spoiled_Meat", DisplayName = "Spoiled Meat", Weight = 50, MaxStack = 20 },
            { Name = "Item_Beer", DisplayName = "Beer", Weight = 300 },
            { Name = "Item_Glass_Bottle", DisplayName = "Glass Bottle", Weight = 100 },
            { Name = "Item_Bandage", DisplayName = "Basic Bandage", Weight = 100, MaxStack = 10 },
            { Name = "Item_Wood_Floor", DisplayName = "Wood Floor", Weight = 500, MaxStack = 20 },
            { Name = "Item_Furnace", DisplayName = "Stone Furnace", Weight = 25000 },
            { Name = "Item_Canteen", DisplayName = "Canteen", Weight = 250 },
            { Name = "Item_Backpack", DisplayName = "Leather Backpack", Weight = 500 },
            { Name = "Item_Fiber", DisplayName = "Fiber", Weight = 5, MaxStack = 200 },
            { Name = "Item_Stone", DisplayName = "Stone", Weight = 1000, MaxStack = 100 },
            { Name = "Item_Odd", DisplayName = "Odd Thing", Weight = 12345 },
            { Name = "Item_Plain", DisplayName = "Plain Thing" },
        },
    },
    ItemTemplate = {
        defaults = { ItemStaticData = NONE, ItemCustomStats = {} },
        rows = {
            { Name = "Spoiled_Meat", ItemStaticData = h("Spoiled_Meat") },
            { Name = "Glass_Bottle", ItemStaticData = h("Glass_Bottle") },
        },
    },
    IcarusResources = {
        defaults = { DisplayName = "", Units = "", Recipe_Icon = "None" },
        rows = { { Name = "Water", DisplayName = "Water", Units = "L" }, { Name = "Energy", DisplayName = "Electricity", Units = "kJ" } },
    },
    Durable = {
        defaults = { Max_Durability = 100, ItemsForRepair = {} },
        rows = {
            { Name = "Armor_Cloth", Max_Durability = 1000, ItemsForRepair = { { Item = h("Fiber"), Amount = 1 } } },
            { Name = "Stone_Pickaxe", Max_Durability = 20000, ItemsForRepair = { { Item = h("Stone"), Amount = 2 }, { Item = h("FIBER"), Amount = 1 } } },
            { Name = "Wood_Building", Max_Durability = 2500 },
        },
    },
    Decayable = {
        defaults = { SpoilTime = 0, SpoiledItem = NONE },
        rows = { { Name = "Decay_Cooked", SpoilTime = 1600, SpoiledItem = h("Spoiled_Meat") }, { Name = "Decay_General" } },
    },
    ToolDamage = {
        defaults = { Melee_Damage = 0, DamageVariationPercentage = 0, Felling_Damage = 0, Felling_Efficiency = 0, Mining_Radius = 0,
            Mining_Efficiency = 0, Skinning_Efficiency = 0, Reaping_Efficiency = 0, Shattering_Damage = 0, Shattering_Efficiency = 0 },
        rows = {
            { Name = "Stone_Pickaxe", Melee_Damage = 30, DamageVariationPercentage = 10, Mining_Radius = 50, Mining_Efficiency = 1 },
            { Name = "Stone_Axe", Melee_Damage = 30, DamageVariationPercentage = 10, Felling_Damage = 25, Felling_Efficiency = 1.2999999523162842 },
            { Name = "Bone_Knife", DamageVariationPercentage = 10, Skinning_Efficiency = 1.5 },
        },
    },
    FirearmData = {
        defaults = { ValidAmmoTypes = NONE, AmmoCapacity = 1, RoundsPerMinute = 120, ReloadTime = 2, DamageMultiplier = 1, LaunchForce = 200 },
        rows = {
            { Name = "Wood_Bow", ValidAmmoTypes = h("AllArrows"), RoundsPerMinute = 300, ReloadTime = 0.699999988079071, LaunchForce = 650,
                DamageMultiplier = 1.25 },
            { Name = "Rifle_Hunting", ValidAmmoTypes = h("AllRifle"), AmmoCapacity = 6, RoundsPerMinute = 60, ReloadTime = 1, LaunchForce = 600 },
        },
    },
    ValidAmmoTypes = {
        defaults = { Description = "" },
        rows = { { Name = "AllArrows", Description = "Arrows" }, { Name = "AllRifle", Description = "7.62mm Rounds" } },
    },
    AmmoTypes = {
        defaults = { ProjectileDamage = 5, ProjectileCount = 1, Stats = {} },
        rows = {
            { Name = "Rifle_Round", ProjectileDamage = 300, Stats = { [stat("BaseChanceProjectilesBreak_%")] = 100 } },
            { Name = "Shell_Explosive", ProjectileDamage = 20, ProjectileCount = 6,
                Stats = { [stat("BaseExplosiveDamageRadius_+")] = 350, [stat("BaseChanceProjectilesBreak_%")] = 100 } },
        },
    },
    Ballistic = {
        defaults = { Damage = 0, DamageVariationPercentage = 0, BreakChance = 0.25 },
        rows = {
            { Name = "Rifle_Round", DamageVariationPercentage = 10, BreakChance = 1 },
            { Name = "Stone_Arrow", Damage = 35, DamageVariationPercentage = 10, BreakChance = 0.5 },
        },
    },
    Armour = {
        defaults = { ArmourStats = {}, ArmourSet = NONE },
        rows = {
            { Name = "Cloth_Chest", ArmourSet = h("Cloth"), ArmourStats = { [stat("BaseColdResistance_%")] = 2,
                [stat("BasePhysicalDamageResistance_%")] = 4, [stat("BaseHeatResistance_%")] = 20, [stat("BaseMovementSpeed_+%")] = -3 } },
        },
    },
    ArmourSets = { defaults = { SetBonus = {} }, rows = { { Name = "Cloth", SetBonus = { h("Cloth_5"), h("Cloth_Missing") } } } },
    ArmourSetBonus = {
        defaults = { RequiredGear = 0, Description = "", StatsGranted = {} },
        rows = { { Name = "Cloth_5", RequiredGear = 5, Description = "Cloth Armor Set", StatsGranted = { [stat("BaseMovementSpeed_+%")] = 5 } } },
    },
    Equippable = {
        defaults = { GrantedStats = {} },
        rows = { { Name = "Backpack_Basic", GrantedStats = { [stat("BaseOreCarryWeight_+%")] = -10, [stat("BaseBackpackSlots_+")] = 6,
            [stat("BaseWeightCapacity_+")] = 5 } } },
    },
    Consumable = {
        defaults = { Stats = {}, Modifier = { Modifier = NONE, ModifierLifetime = 10 }, Byproducts = {} },
        rows = {
            { Name = "Cooked_Meat", Stats = { [stat("BaseHealthRecovery_+")] = 20, [stat("BaseFoodRecovery_+")] = 100 },
                Modifier = { Modifier = h("CookedMeat"), ModifierLifetime = 900 } },
            { Name = "Drink_Beer", Stats = { [stat("BaseWaterRecovery_+")] = 40 }, Byproducts = { h("Glass_Bottle") } },
            { Name = "Bandage", Modifier = { Modifier = h("Bandage"), ModifierLifetime = 1 } },
        },
    },
    ModifierStates = {
        defaults = { ModifierName = "Name", ModifierDescription = "Description", GrantedStats = {} },
        rows = {
            { Name = "CookedMeat", ModifierName = "Cooked Meat", ModifierDescription = "Boosts your health and health regeneration.",
                GrantedStats = { [stat("BaseHealthRegen_+%")] = 20, [stat("BaseMaximumHealth_+")] = 75 } },
            { Name = "Bandage", ModifierName = "Bandage", ModifierDescription = "[DNT]Healing bleeding and wounds." },
        },
    },
    Buildable = { defaults = { Type = NONE }, rows = { { Name = "Wood_Floor", Type = h("Wood") } } },
    BuildingTypes = {
        defaults = { Stats = {} },
        rows = { { Name = "Wood", Stats = { [stat("BaseBuildingInsulation_+")] = 3, [stat("BaseMeleeDamageResistance_%")] = -50 } } },
    },
    Inventory = {
        defaults = { Inventories = {} },
        rows = { { Name = "Furnace", Inventories = { h("Processor"), h("Fuel"), h("Hidden_Slots") } } },
    },
    InventoryInfo = {
        defaults = { StartingSlots = 0 },
        rows = { { Name = "Processor", StartingSlots = 30 }, { Name = "Fuel", StartingSlots = 1 }, { Name = "Hidden_Slots" } },
    },
    Fillable = {
        defaults = { ResourceTypes = {}, MaximumStoredUnits = 0 },
        rows = { { Name = "Canteen", ResourceTypes = { { Value = "Water" } }, MaximumStoredUnits = 1500 } },
    },
    Stats = {
        defaults = { PositiveDescription = "", NegativeDescription = "", DisplayOperations = {}, bHideStatInUserInterface = false,
            bShowStatOnModifiers = false },
        rows = {
            described("BaseMaximumHealth_+", "+{0} Maximum Health", "-{0} Maximum Health",
                { bHideStatInUserInterface = true, bShowStatOnModifiers = true }),
            described("BaseHealthRegen_+%", "+{0}% Health Regeneration", "-{0}% Health Regeneration"),
            described("BaseMovementSpeed_+%", "+{0}% Movement Speed", "-{0}% Movement Speed"),
            described("BasePhysicalDamageResistance_%", "+{0} Physical Resistance", "-{0} Physical Resistance"),
            described("BaseHeatResistance_%", "+{0}% Heat Resistance", "-{0}% Heat Resistance"),
            described("BaseColdResistance_%", "+{0}% Cold Resistance", "-{0}% Cold Resistance"),
            described("BaseFoodRecovery_+", "+{0} Food when Consumed", "-{0} Food when Consumed"),
            described("BaseWaterRecovery_+", "+{0} Water when Consumed", "-{0} Water when Consumed"),
            described("BaseHealthRecovery_+", "+{0} Health when Consumed", "-{0} Health when Consumed"),
            described("BaseBackpackSlots_+", "+{0} Suit Inventory Slots", "-{0} Suit Inventory Slots"),
            described("BaseWeightCapacity_+", "+{0}kg Weight Capacity", "-{0}kg Weight Capacity"),
            described("BaseOreCarryWeight_+%", "+{0}% Carry Weight of Ores", "-{0}% Carry Weight of Ores"),
            described("BaseArmorDamageModifier_+%", "+{0}% Damage To Armor", "-{0}% Damage To Armor"),
            described("BaseChanceProjectilesBreak_%", "{0}% Projectile Break Chance", "-{0}% Projectile Break Chance"),
            described("BaseExplosiveDamageRadius_+", "{0}m Explosive Damage Radius", "-{0}m Explosive Damage Radius",
                { DisplayOperations = { { Operation = "Division", Value = 100 } } }),
            described("BaseReloadSpeedMilliseconds_+", "{0} seconds to Reload", "-{0} seconds to Reload",
                { DisplayOperations = { { Operation = 2, Value = 1000 } } }),
            described("BaseBuildingInsulation_+", "+{0} Insulation from Temperature", "-{0} Insulation from Temperature"),
            described("BaseMeleeDamageResistance_%", "+{0} Melee Resistance", "-{0} Melee Resistance"),
            described("IsInvulnerable_?", "Will Not Take Damage From Any Source", "", { bHideStatInUserInterface = true }),
            { Name = "IsScorpionItem_?" },
            described("CanCraftAnywhere_?", "Can Craft Anywhere", ""),
            described("OnlyNegative_+", "", "-{0} Something"),
        },
    },
}

local function clone(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, inner in pairs(value) do out[key] = clone(inner) end
    return out
end

local function world(tables, options)
    local provider = fixture.serve(tables or T, options)
    local src = source.new(provider)
    return stats.new(src, nil, format), src, provider
end

-- "Title: line | line // Title: line"
local function flat(groups, field)
    local out = {}
    for index, group in ipairs(groups) do
        local lines = {}
        for position, line in ipairs(group.lines) do lines[position] = line[field or "text"] end
        out[index] = group.title .. ": " .. table.concat(lines, " | ")
    end
    return table.concat(out, " // ")
end

local function group_of(groups, id)
    for _, group in ipairs(groups) do
        if group.id == id then return group end
    end
    return nil
end

local function has(list, value)
    for _, entry in ipairs(list) do
        if entry == value then return true end
    end
    return false
end

-- A provider that refuses map fields, the way game.Data does today.
local MAPS = { AdditionalStats = true, ArmourStats = true, GrantedStats = true, StatsGranted = true, Stats = true }
local function without_maps(inner)
    return {
        Has = function(_, name) return inner:Has(name) end,
        Table = function(_, name)
            local object = inner:Table(name)
            return setmetatable({ Row = function(_, row, fields)
                for _, field in ipairs(fields or {}) do
                    if MAPS[field] then error("'" .. field .. "' is a Map field, which game.Data never reads", 0) end
                end
                return object:Row(row, fields)
            end }, { __index = object })
        end,
    }
end

-- ---------------------------------------------------------------- the lists

t.test("lists: stage 4 is listed only when asked for, and every one of its entries is read on request", function()
    local ahead, every = source.lists(), source.lists(true)
    t.ok(#every > #ahead, "stage 4 adds entries")
    for _, entry in ipairs(ahead) do t.ok(entry.stage <= source.STAGES, entry.table .. " is read ahead") end
    local seen = {}
    for _, entry in ipairs(every) do
        if entry.stage > source.STAGES then
            t.eq(entry.stage, 4)
            t.eq(entry.rows, "request", entry.table)
            t.ok(not entry.meta, entry.table)
            t.ok(not seen[entry.table], entry.table .. " is listed once in stage 4")
            seen[entry.table] = true
            for _, field in ipairs(entry.fields) do
                t.ok(not field:find("DataTableName", 1, true), entry.table .. " never reads a handle's table: " .. field)
            end
        end
    end
    for _, name in ipairs({ "ItemsStatic", "Durable", "Decayable", "ToolDamage", "FirearmData", "ValidAmmoTypes", "AmmoTypes", "Ballistic",
        "Armour", "ArmourSets", "ArmourSetBonus", "Equippable", "Consumable", "ModifierStates", "Buildable", "BuildingTypes",
        "Inventory", "InventoryInfo", "Fillable", "Stats" }) do
        t.ok(seen[name], name .. " is in stage 4")
    end
end)

t.test("lists: reading the stages ahead opens no stage 4 table, and the stamp does not name them", function()
    local provider = fixture.provider()
    local src = source.new(provider)
    src.read_all(1)
    t.eq(#src.problems, 0, "the plan's fixture has none of the stage 4 tables, and nothing asked for them")
    t.ok(not src.stamps():find("Durable=", 1, true))
    t.ok(not src.stamps():find("Stats=", 1, true))
    t.ok(src.stamps():find("ItemsStatic=", 1, true))
end)

t.test("detail: one row at a time, in any letter case, kept, and nothing for a name or a table that is not there", function()
    local _, src, provider = world()
    t.eq(provider.calls, 0, "making the two asks the provider nothing")
    t.eq(src.detail("Durable", "armor_cloth").Max_Durability, 1000)
    local calls = provider.calls
    t.eq(src.detail("Durable", "ARMOR_CLOTH"), src.detail("Durable", "Armor_Cloth"), "one table per row")
    t.eq(provider.calls, calls, "kept")
    t.eq(src.detail("Durable", "Nothing"), nil)
    t.eq(src.detail("Durable", nil), nil)
    t.eq(src.detail("Talents", "Anything"), nil, "Talents is not a stage 4 table")
    t.eq(src.detail("NotATable", "Row"), nil)
    t.eq(provider.asked.Load, nil, "no table is loaded whole")
    t.eq(#src.problems, 0)
end)

t.test("detail: the row of an item holds the stage 4 fields beside the ones read ahead", function()
    local provider = fixture.serve(T)
    local src = source.new(provider)
    src.load("ItemsStatic")
    t.raises(function() return src.row("ItemsStatic", "Cloth_Chest").Durable end, "not in source.lua's lists")
    t.eq(src.detail("ItemsStatic", "Cloth_Chest").Durable.RowName, "Armor_Cloth")
    t.eq(src.row("ItemsStatic", "Cloth_Chest").Itemable.RowName, "Item_Cloth_Chest")
end)

-- ---------------------------------------------------------------- each kind of item

t.test("armour: durability, the repair item by its name, the game's sentences in D_Stats order, and the set", function()
    local s = world()
    local groups = s.of("Cloth_Chest")
    t.eq(flat(groups), "Durability: Durability 1,000 | Repaired with Fiber"
        .. " // Armor: -3% Movement Speed | +4 Physical Resistance | +20% Heat Resistance | +2% Cold Resistance"
        .. " // Set bonus: Cloth Armor Set 5 pieces | +5% Movement Speed"
        .. " // Carrying: Weight 750 g")
    local armor = group_of(groups, "armor")
    t.eq(armor.lines[2].label, "Physical Resistance")
    t.eq(armor.lines[2].value, "+4")
    t.eq(armor.lines[1].label, "Movement Speed")
    t.eq(armor.lines[1].value, "-3%")
    local set = group_of(groups, "set")
    t.eq(set.lines[1].label, "Cloth Armor Set")
    t.eq(set.lines[1].value, "5 pieces")
    t.eq(s.left.missing["ArmourSetBonus.Cloth_Missing"], 1, "a set bonus that is not there is counted")
end)

t.test("tools: melee damage and its spread, harvesting figures, an efficiency as a percentage", function()
    local s = world()
    t.eq(flat(s.of("Stone_Pickaxe")), "Durability: Durability 20,000 | Repaired with 2 Stone, Fiber"
        .. " // Melee and harvesting: Melee damage 30 | Damage varies by 10% | Mining radius 50 | Mining efficiency 100%"
        .. " // Properties: +500% Damage To Armor // Carrying: Weight 500 g")
    t.eq(flat(group_of(s.of("Stone_Axe"), "melee") and { group_of(s.of("Stone_Axe"), "melee") } or {}),
        "Melee and harvesting: Melee damage 30 | Damage varies by 10% | Felling damage 25 | Felling efficiency 130%")
    t.eq(flat({ group_of(s.of("Bone_Knife"), "melee") }), "Melee and harvesting: Skinning efficiency 150%",
        "no spread without a damage")
end)

t.test("ranged weapons: ammunition by the game's name, capacity and rate only for a magazine, reload, multiplier", function()
    local s = world()
    t.eq(flat({ group_of(s.of("Wood_Bow"), "ranged") }),
        "Ranged weapon: Ammunition Arrows | Reload time 0.7 s | Damage multiplier 125% | Launch force 650")
    t.eq(flat({ group_of(s.of("Rifle_Hunting"), "ranged") }),
        "Ranged weapon: Ammunition 7.62mm Rounds | Ammo capacity 6 | Rate of fire 60 per minute | Reload time 1 s | Launch force 600")
end)

t.test("projectiles: a round's damage and stats, pellets, an arrow's damage and its chance to break", function()
    local s = world()
    t.eq(flat({ group_of(s.of("Rifle_Round"), "projectile") }),
        "Projectile: Projectile damage 300 | Damage varies by 10% | 100% Projectile Break Chance")
    t.eq(flat({ group_of(s.of("Buckshot"), "projectile") }),
        "Projectile: Projectile damage 20 | Projectiles 6 | Damage varies by 10% | 100% Projectile Break Chance | 3.5m Explosive Damage Radius")
    t.eq(flat({ group_of(s.of("Stone_Arrow"), "projectile") }), "Projectile: Damage 35 | Damage varies by 10% | Break chance 50%")
    t.eq(flat(s.of("Stone_Arrow")), "Projectile: Damage 35 | Damage varies by 10% | Break chance 50% // Carrying: Weight 10 g | Stack size 100")
end)

t.test("food: what eating gives, the effect with its name, time and stats, and how long it keeps", function()
    local s = world()
    t.eq(flat(s.of("Cooked_Meat")), "When consumed: +100 Food when Consumed | +20 Health when Consumed"
        .. " // Effect: Cooked Meat 15 min | Boosts your health and health regeneration. | +75 Maximum Health | +20% Health Regeneration"
        .. " // Shelf life: Lasts 26 min 40 s | Turns into Spoiled Meat"
        .. " // Carrying: Weight 50 g | Stack size 20")
    local effect = group_of(s.of("Cooked_Meat"), "effect")
    t.eq(effect.lines[1].label, "Cooked Meat")
    t.eq(effect.lines[1].value, "15 min")
    t.eq(effect.lines[2].value, "")
    t.eq(flat({ group_of(s.of("Beer"), "consumed") }), "When consumed: +40 Water when Consumed | Gives back Glass Bottle")
    t.eq(group_of(s.of("Beer"), "effect"), nil, "no effect without a modifier")
end)

t.test("medicine: an effect with no time worth telling, and a note for translators is not shown", function()
    local s = world()
    t.eq(flat(s.of("Bandage")), "Effect: Bandage | Healing bleeding and wounds. // Carrying: Weight 100 g | Stack size 10")
end)

t.test("buildings, benches, containers and what is worn", function()
    local s = world()
    t.eq(flat(s.of("Wood_Floor")), "Durability: Durability 2,500"
        .. " // Building: +3 Insulation from Temperature | -50 Melee Resistance // Carrying: Weight 500 g | Stack size 20")
    t.eq(flat(s.of("Furnace")), "Durability: Durability 2,500 // Storage: Slots 30 + 1 // Carrying: Weight 25 kg")
    t.eq(flat(s.of("Canteen")), "Storage: Holds 1.5 L Water // Carrying: Weight 250 g")
    t.eq(flat(s.of("Backpack")), "When equipped: +6 Suit Inventory Slots | +5kg Weight Capacity | -10% Carry Weight of Ores"
        .. " // Carrying: Weight 500 g")
    t.eq(group_of(s.of("Backpack"), "equipped").lines[2].value, "+5kg")
end)

-- ---------------------------------------------------------------- what is left out

t.test("left out: no text, hidden by the game, a stat or a row that is not there, and a zero", function()
    local s = world()
    local groups = s.of("Odd")
    t.eq(flat(groups), "Properties: +25 Maximum Health | 1.5 seconds to Reload | Can Craft Anywhere // Carrying: Weight 12.3 kg")
    t.eq(group_of(groups, "properties").lines[2].label, "1.5 seconds to Reload", "a sentence that does not start with its figure stays whole")
    t.eq(group_of(groups, "properties").lines[2].value, "")
    t.eq(s.left.unnamed["IsScorpionItem_?"], 1)
    t.eq(s.left.unnamed["OnlyNegative_+"], 1, "a positive value with only a negative sentence")
    t.eq(s.left.hidden["IsInvulnerable_?"], 1)
    t.eq(s.left.hidden["BaseMaximumHealth_+"], nil, "hidden in the stat screen but shown on what grants it")
    t.eq(s.left.missing["Stats.Not_A_Stat_+"], 1)
    t.eq(s.left.missing["Durable.Gone"], 1)
    local counts = s.counts()
    t.eq(counts.unnamed, 2)
    t.eq(counts.hidden, 1)
    t.eq(counts.missing, 2)
    s.of("Odd")
    t.eq(s.counts().unnamed, 2, "an item is counted once")
end)

t.test("nothing: an item with no numbers, one with no Itemable, an unknown one and no item at all", function()
    local s = world()
    t.eq(#s.of("Plain"), 0)
    t.eq(#s.of("Bare"), 0)
    t.eq(#s.of("Not_An_Item"), 0)
    t.eq(#s.of(nil), 0)
    t.eq(#s.of(12), 0)
    t.eq(#s.of({}), 0)
    t.eq(s.counts().missing, 0)
end)

-- ---------------------------------------------------------------- how it is asked

t.test("items: a model item gives its own weight and stack, a row name reads them, and letter case does not matter", function()
    local s = world()
    local item = { key = "seed:oat", static = "fiber", row = "Oat_Seed", weight = 2500, stack = 50 }
    t.eq(flat(s.of(item)), "Carrying: Weight 2.5 kg | Stack size 50")
    t.eq(flat(s.of("FIBER")), "Carrying: Weight 5 g | Stack size 200")
    t.eq(flat(s.of({ static = "cloth_chest", weight = 750, stack = 1 })), flat(s.of("Cloth_Chest")))
    t.eq(flat(s.of({ row = "Cloth_Chest" })), flat(s.of("Cloth_Chest")), "without a weight it is read")
end)

t.test("on request: nothing is read before the first item, one item reads only its own rows, and the answer is kept", function()
    local s, _, provider = world()
    t.eq(provider.calls, 0)
    local first = s.of("Stone_Axe")
    t.eq(provider.asked.Load, nil, "no table is read whole")
    t.eq(provider.asked.Table, 3, "the item, its Itemable and its ToolDamage")
    local calls = provider.calls
    t.eq(s.of("Stone_Axe"), first, "the same list")
    t.eq(s.of("stone_axe"), first)
    t.eq(provider.calls, calls, "kept")
end)

t.test("on the model's source: the tables read ahead are used as they are", function()
    local provider = fixture.serve(T)
    local src = source.new(provider)
    src.load("ItemsStatic")
    src.load("Itemable")
    src.load("ItemTemplate")
    src.load("IcarusResources")
    local s = stats.new(src, nil, format)
    t.eq(flat(s.of("Cooked_Meat")), flat((world()).of("Cooked_Meat")))
    t.eq(flat(s.of("Canteen")), "Storage: Holds 1.5 L Water // Carrying: Weight 250 g")
    t.eq(#src.problems, 0)
end)

t.test("maps the provider will not give: the rest is shown, nothing raises, and the fields are named", function()
    local provider = without_maps(fixture.serve(T, { strict = false }))
    local src = source.new(provider)
    local s = stats.new(src, nil, format)
    t.eq(flat(s.of("Cloth_Chest")), "Durability: Durability 1,000 | Repaired with Fiber // Carrying: Weight 750 g")
    t.eq(flat(s.of("Stone_Pickaxe")), "Durability: Durability 20,000 | Repaired with 2 Stone, Fiber"
        .. " // Melee and harvesting: Melee damage 30 | Damage varies by 10% | Mining radius 50 | Mining efficiency 100%"
        .. " // Carrying: Weight 500 g")
    t.eq(flat(s.of("Cooked_Meat")), "Effect: Cooked Meat 15 min | Boosts your health and health regeneration."
        .. " // Shelf life: Lasts 26 min 40 s | Turns into Spoiled Meat // Carrying: Weight 50 g | Stack size 20")
    t.eq(flat(s.of("Rifle_Round")), "Projectile: Projectile damage 300 | Damage varies by 10% // Carrying: Weight 10 g | Stack size 100")
    t.eq(flat(s.of("Wood_Floor")), "Durability: Durability 2,500 // Carrying: Weight 500 g | Stack size 20")
    local unread = s.unread()
    for _, name in ipairs({ "ItemsStatic.AdditionalStats", "Armour.ArmourStats", "Consumable.Stats", "ModifierStates.GrantedStats",
        "AmmoTypes.Stats", "BuildingTypes.Stats" }) do
        t.ok(has(unread, name), name .. " is named")
    end
    t.eq(src.broken.Armour, nil, "a stage 4 field that cannot be read does not break its table")
    t.eq(src.broken.ItemsStatic, nil)
    t.eq(s.counts().unnamed, 0)
end)

t.test("maps: keys as plain names, and a list of pairs, are read like the keys of the files", function()
    local tables = clone(T)
    tables.Armour.rows[1].ArmourStats = { ["BaseHeatResistance_%"] = 20, ["BaseColdResistance_%"] = 2 }
    tables.Equippable.rows[1].GrantedStats = { { Key = { Value = "BaseBackpackSlots_+" }, Value = 6 },
        { Stat = { Value = "BaseWeightCapacity_+" }, Value = 5 }, { Key = "BaseOreCarryWeight_+%", Value = -10 } }
    local s = world(tables)
    t.eq(flat({ group_of(s.of("Cloth_Chest"), "armor") }), "Armor: +20% Heat Resistance | +2% Cold Resistance")
    t.eq(flat({ group_of(s.of("Backpack"), "equipped") }),
        "When equipped: +6 Suit Inventory Slots | +5kg Weight Capacity | -10% Carry Weight of Ores")
end)

t.test("numbers: thousands, two places at most, a display operation by name or by the game's number", function()
    local tables = clone(T)
    tables.Durable.rows[1].Max_Durability = 100000000
    tables.Armour.rows[1].ArmourStats = { [stat("BaseExplosiveDamageRadius_+")] = 123456, [stat("BaseReloadSpeedMilliseconds_+")] = -2345,
        [stat("BaseHeatResistance_%")] = 12.5 }
    tables.Stats.rows[15].DisplayOperations = { { Operation = "EStatDisplayOperation::Division", Value = 100 }, { Operation = 3, Value = 1 },
        { Operation = "Multiply", Value = 2 }, { Operation = "None", Value = 7 } }
    local s = world(tables)
    local groups = s.of("Cloth_Chest")
    t.eq(group_of(groups, "durability").lines[1].value, "100,000,000")
    t.eq(flat({ group_of(groups, "armor") }), "Armor: +12.5% Heat Resistance | 2,471.12m Explosive Damage Radius | -2.35 seconds to Reload")
end)

t.test("times: seconds, minutes and hours", function()
    local function lasts(seconds)
        local tables = clone(T)
        tables.Decayable.rows[1].SpoilTime = seconds
        return group_of((world(tables)).of("Cooked_Meat"), "shelf").lines[1].value
    end
    t.eq(lasts(45), "45 s")
    t.eq(lasts(60), "1 min")
    t.eq(lasts(800), "13 min 20 s")
    t.eq(lasts(3600), "1 h")
    t.eq(lasts(5000), "1 h 23 min")
    t.eq(lasts(10800), "3 h")
end)

t.test("words: every fixed word is in WORDS, and the mod's text table replaces them", function()
    local words = clone(stats.WORDS)
    words.durability.title, words.durability.amount, words.carrying.weight = "Wear", "Uses", "Mass"
    local s = stats.new(source.new(fixture.serve(T)), { stats = words }, format)
    t.eq(flat(s.of("Furnace")), "Wear: Uses 2,500 // Storage: Slots 30 + 1 // Carrying: Mass 25 kg")
    for _, name in ipairs({ "durability", "melee", "ranged", "projectile", "armor", "set", "equipped", "properties", "consumed", "effect",
        "shelf", "building", "storage", "carrying" }) do
        t.ok(type(stats.WORDS[name].title) == "string" and stats.WORDS[name].title ~= "", name .. " has a title")
    end
end)

t.test("weights: the mod's own format when it is given, a plain one without", function()
    local s = stats.new(source.new(fixture.serve(T)))
    t.eq(flat(s.of("Odd")):match("Weight (.+)$"), "12.35 kg")
    t.eq(flat(s.of("Fiber")), "Carrying: Weight 5 g | Stack size 200")
end)

-- ---------------------------------------------------------------- the game's own tables

local CHECK = "build/recipe-browser/check/tables.lua"

local function real_run()
    local tables = dofile(CHECK)
    if not tables.Stats or not tables.Durable or not tables.ItemsStatic then
        return nil, "tables.lua is older than the stage 4 lists (run python scripts\\recipe_check.py again)"
    end
    local tags, model = part("tags"), part("model")
    local provider = fixture.serve(tables)
    local src = source.new(provider)
    src.read_all(1)
    local m = model.build(src, nil, string.lower, tags)

    -- The collector is held while the items are timed, so a collection is not counted as an item's time.
    local function sweep(s)
        local run = { items = 0, with = 0, lines = 0, per = {}, order = {}, slowest = 0, slow_item = "", failures = {}, total = 0 }
        collectgarbage("collect")
        collectgarbage("stop")
        for _, item in ipairs(m.list) do
            if not item.hidden then
                run.items = run.items + 1
                local started = os.clock()
                local ok, groups = pcall(s.of, item)
                local took = (os.clock() - started) * 1000
                run.total = run.total + took
                if took > run.slowest then run.slowest, run.slow_item = took, item.row end
                if not ok then
                    run.failures[#run.failures + 1] = item.row .. ": " .. tostring(groups)
                else
                    if #groups > 0 then run.with = run.with + 1 end
                    local seen = {}
                    for _, group in ipairs(groups) do
                        run.lines = run.lines + #group.lines
                        if not seen[group.title] then
                            seen[group.title] = true
                            if not run.per[group.title] then
                                run.per[group.title] = 0
                                run.order[#run.order + 1] = group.title
                            end
                            run.per[group.title] = run.per[group.title] + 1
                        end
                    end
                end
            end
        end
        collectgarbage("restart")
        return run
    end

    local function told(run)
        local parts = {}
        for index, title in ipairs(run.order) do parts[index] = title .. " " .. run.per[title] end
        return table.concat(parts, ", ")
    end

    local function names(held, most)
        local list = {}
        for name in pairs(held) do list[#list + 1] = name end
        table.sort(list)
        local count = #list
        for index = most + 1, count do list[index] = nil end
        return count, table.concat(list, ", ")
    end

    local own = stats.new(source.new(provider), nil, format)
    local run = sweep(own)
    local asked = provider.calls
    local again = sweep(own)
    asked = provider.calls - asked
    local shared = sweep(stats.new(src, nil, format))
    local plain_source = source.new(without_maps(fixture.serve(tables, { strict = false })))
    local plain_stats = stats.new(plain_source, nil, format)
    local plain = sweep(plain_stats)

    t.test("game: every shown item gives its groups without raising, and every field read is in the lists", function()
        t.eq(#run.failures, 0, run.failures[1])
        t.ok(run.items > 1000, "the game has items")
        t.ok(run.with > run.items / 2, "most items have something to tell")
    end)
    t.test("game: asked again, every item is answered from what was kept", function()
        t.eq(#again.failures, 0, again.failures[1])
        t.eq(again.with, run.with)
        t.eq(asked, 0, "the second pass asks the provider nothing")
    end)
    t.test("game: the model's own source gives the same as a source of its own", function()
        t.eq(#shared.failures, 0, shared.failures[1])
        t.eq(shared.with, run.with)
        t.eq(shared.lines, run.lines)
        t.eq(told(shared), told(run))
    end)
    t.test("game: without the maps nothing raises and no stat is asked for", function()
        t.eq(#plain.failures, 0, plain.failures[1])
        t.ok(plain.with > 0)
        t.eq(plain_stats.counts().unnamed, 0)
        t.eq(plain_source.broken.Stats, nil, "D_Stats is never opened")
    end)
    t.test("game: items of every kind the plan names have their group", function()
        local wanted = { cloth_chest = "armor", stone_pickaxe = "melee", stone_axe = "melee", bone_knife = "melee", wood_bow = "ranged",
            rifle_hunting = "ranged", ammo_rifle_round = "projectile", stone_arrow = "projectile", cooked_meat = "consumed",
            bandage_basic = "effect", wood_floor = "building", crafting_bench = "storage", basic_backpack = "equipped",
            meta_module_water = "equipped" }
        for key, id in pairs(wanted) do
            local item = m.items[key]
            if item then t.ok(group_of(own.of(item), id), item.row .. " has the group " .. id) end
        end
    end)

    local counts = own.counts()
    local unnamed, unnamed_names = names(own.left.unnamed, 12)
    local hidden = names(own.left.hidden, 0)
    local missing, missing_names = names(own.left.missing, 8)
    print(("recipe-stats: the game's tables: %d shown items, %d with at least one group, %d lines"):format(run.items, run.with, run.lines))
    print("recipe-stats:   " .. told(run))
    print(("recipe-stats:   left out: %d stats with no sentence in D_Stats (%d names: %s)"):format(counts.unnamed, unnamed, unnamed_names))
    print(("recipe-stats:   left out: %d stats the game hides (%d names), %d handles to rows that are not there (%d names: %s)"):format(
        counts.hidden, hidden, counts.missing, missing, missing_names))
    print(("recipe-stats:   slowest of() %.0f ms (%s), %.3f ms an item on average, %.4f ms when asked again (this clock steps by 1 ms)"):format(
        run.slowest, run.slow_item, run.total / run.items, again.total / again.items))
    print(("recipe-stats:   as game.Data reads today (no maps): %d items with a group, %d lines: %s"):format(plain.with, plain.lines, told(plain)))
    print("recipe-stats:   fields it could not give: " .. table.concat(plain_stats.unread(), ", "))
    return true
end

if exists(CHECK) and exists(folder .. "/model.lua") then
    local ok, done, why = pcall(real_run)
    if not ok then
        t.test("game: the run on the game's tables", function() error(done, 0) end)
    elseif not done then
        print("recipe-stats: the game's tables were not used: " .. tostring(why))
    end
else
    print("recipe-stats: the game's tables were not used: run python scripts\\recipe_check.py --mod " .. folder .. " first")
end

t.finish("recipe-stats")
