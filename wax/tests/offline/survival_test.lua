-- Run from the workspace root: tools\lua\lua54\lua.exe build\nexus-work\Survival\tests\survival_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local rules = dofile("luamods/Survival/rules.lua")

local function consumable(modifier, lifetime)
    return { Modifier = { Modifier = { RowName = modifier, DataTableName = "D_ModifierStates" }, ModifierLifetime = lifetime, ModifierEffectiveness = 100 } }
end

local food = { { Value = "FoodModifierDuration_+%" } }

t.test("a buff with the food affector is food", function()
    t.eq(rules.buff_kind("Cooked_Meat", consumable("CookedMeat", 900), food), "food")
end)

t.test("a thermos drink is a drink without the affector", function()
    t.eq(rules.buff_kind("Thermos_IceWater", consumable("Thermos_IceWater", 600), {}), "drink")
    t.eq(rules.buff_kind("thermos_coffee_drink", consumable("Thermos_Coffee_Modifier", 900), nil), "drink")
end)

t.test("a lasting effect that is neither is medicine", function()
    t.eq(rules.buff_kind("Antibiotic_Pill", consumable("Antibiotic_Pill", 600), {}), "medicine")
    t.eq(rules.buff_kind("Paste_Health_Regen", consumable("Health_Regen", 60), {}), "medicine")
end)

t.test("a short effect, a bad effect and no modifier are nothing", function()
    t.eq(rules.buff_kind("Bandage_Basic", consumable("Bandage", 1), {}), nil)
    t.eq(rules.buff_kind("Food_Animal_Gruel_Rotten", consumable("Animal_Gruel_Rotten", 900), food), nil)
    t.eq(rules.buff_kind("Spoiled_Food", consumable("Spoiled_Meat", 300), food), nil)
    t.eq(rules.buff_kind("Stone", consumable("None", 10), {}), nil)
    t.eq(rules.buff_kind("Stick", {}, {}), nil)
end)

t.test("an affector given as a plain string counts too", function()
    t.eq(rules.buff_kind("Food_Berry", consumable("Berry", 600), { "FoodModifierDuration_+%" }), "food")
end)

t.test("lengthened makes a new struct and leaves the old one alone", function()
    local given = consumable("CookedMeat", 900).Modifier
    local new = rules.lengthened(given, 2.5)
    t.eq(new.ModifierLifetime, 2250)
    t.eq(new.ModifierEffectiveness, 100)
    t.eq(new.Modifier, given.Modifier)
    t.eq(given.ModifierLifetime, 900)
    t.ok(new ~= given)
end)

t.test("spoilage touches food timers only", function()
    t.ok(rules.spoils_food("Decay_Raw_Meat", { SpoilTime = 600 }))
    t.ok(rules.spoils_food("Decay_Ice", { SpoilTime = 2700 }))
    t.ok(rules.spoils_food("Decay_Coconut_Mature", { SpoilTime = 600 }))
    t.ok(not rules.spoils_food("Decay_General", { SpoilTime = 0 }))
    t.ok(not rules.spoils_food("Decay_Pyritic_Crust_Iron", { SpoilTime = 300 }))
    t.ok(not rules.spoils_food("Decay_Coconut_Young", { SpoilTime = 300 }))
    t.ok(not rules.spoils_food("Decay_Advanced_Leather", { SpoilTime = 60 }))
    t.ok(not rules.spoils_food("Decay_Volatile_Substance", { SpoilTime = 600 }))
    t.ok(not rules.spoils_food("Decay_Delivery_Object", { SpoilTime = 15 }))
    t.ok(not rules.spoils_food("Decay_Raw_Meat", {}))
end)

t.test("scaling keeps whole numbers", function()
    t.eq(rules.times(150000, 10), 1500000)
    t.eq(rules.times(2700, 2), 5400)
    t.eq(rules.slower(100, 3), 33)
    t.eq(rules.slower(1, 10), 1)
    t.eq(rules.share(25, 50), 12)
    t.eq(rules.share(25, 0), 0)
    t.eq(rules.share(600, 10), 60)
    t.eq(math.type(rules.times(100, 2.5)), "integer")
end)

t.finish("survival")
