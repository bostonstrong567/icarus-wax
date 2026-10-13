-- Building Tweaks rules, from the workspace root: tools\lua\lua54\lua.exe build\nexus-work\BuildingTweaks\tests\buildingtweaks_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local rules = dofile("luamods/BuildingTweaks/rules.lua")

t.test("building durability rows are the per-material ones", function()
    t.ok(rules.is_building_durable("Wood_Building"))
    t.ok(rules.is_building_durable("wood_building_refined"), "letter case does not matter")
    t.ok(rules.is_building_durable("Tempered_Glass_Building"))
    t.ok(rules.is_building_durable("Settlement_Wall_Wood"))
    t.ok(not rules.is_building_durable("Stone_Axe"))
    t.ok(not rules.is_building_durable("Deployable"))
end)

t.test("heat sources are the placed ones", function()
    t.ok(rules.is_heat_source("Campfire"))
    t.ok(rules.is_heat_source("Thermal_Heater_SMall"), "the game's own odd spelling")
    t.ok(rules.is_heat_source("Thermal_Cooler_Large"))
    t.ok(not rules.is_heat_source("OnFire_Modifier"))
    t.ok(not rules.is_heat_source("Prototype_Laser"))
end)

t.test("scaled values are whole numbers for the game's integer fields", function()
    t.eq(rules.scaled(4000, 2), 8000)
    t.eq(math.type(rules.scaled(4000, 2)), "integer")
    t.eq(rules.scaled(350, 1.5), 525)
    t.eq(math.type(rules.scaled(350, 1.5)), "integer")
    t.eq(rules.scaled(4 + 2, 1), 6)
end)

t.test("kept per piece never lowers a material", function()
    t.eq(rules.kept(0.5, 60), 0.6)
    t.eq(rules.kept(0.666, 60), 0.666, "concrete keeps its own higher share")
    t.eq(rules.kept(0.5, 100), 1)
end)

t.test("cost factor", function()
    t.eq(rules.cost_factor(25), 0.25)
    t.eq(rules.cost_factor(100), 1)
end)

t.test("no limits is Ferani's whole row", function()
    local count = 0
    for _ in pairs(rules.NO_LIMITS) do count = count + 1 end
    t.eq(count, 8)
    t.eq(rules.NO_LIMITS.MinimumUnstableStability, 0)
    t.eq(rules.NO_LIMITS.StabilityPassMultiplier, 1)
    t.eq(rules.NO_LIMITS.HardStabilityMaxRange, 1000000)
end)

t.test("every preset names every setting", function()
    local names = {}
    for _, entry in ipairs(rules.PRESETS) do
        t.ok(not names[entry[1]], "preset named twice: " .. entry[1])
        names[entry[1]] = true
        for key in pairs(rules.VANILLA) do
            t.ok(entry[2][key] ~= nil, entry[1] .. " lacks " .. key)
        end
        for key in pairs(entry[2]) do
            t.ok(rules.VANILLA[key] ~= nil, entry[1] .. " has an unknown key " .. key)
        end
    end
    t.ok(names.Vanilla, "a Vanilla preset")
    t.ok(names[rules.DEFAULT], "the default preset exists")
    t.ok(#rules.PRESETS <= 10, "a dropdown shows up to ten in full")
end)

t.test("the Vanilla preset changes nothing and the default is the balanced one", function()
    for key, value in pairs(rules.VANILLA) do t.eq(rules.PRESETS[1][2][key], value, key) end
    local defaults = rules.defaults()
    t.eq(defaults.durability, 2)
    t.eq(defaults.stability, 2)
    t.eq(defaults.electronics, 100)
    t.eq(defaults.no_limits, false)
end)

t.finish("buildingtweaks")
