-- Run from the workspace root: tools\lua\lua54\lua.exe build\nexus-work\MoreSlots\tests\moreslots_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local slots = dofile("luamods/MoreSlots/slots.lua")

t.test("the drop ship is its two loadout rows", function()
    t.eq(slots.kind("Space_Player_Loadout"), "dropship")
    t.eq(slots.kind("DropShip_Equipment"), "dropship")
    t.eq(slots.kind("Dropship_RemoveOnly"), nil)
    t.eq(slots.kind("DropShip_Meta"), nil)
end)

t.test("the backpack, not the hotbar or equipment", function()
    t.eq(slots.kind("Backpack"), "backpack")
    t.eq(slots.kind("Quickbar"), nil)
    t.eq(slots.kind("Equipment"), nil)
end)

t.test("deployable storage and bags are containers", function()
    for _, name in ipairs({ "Storage_Wood_Crate_Small", "Storage_Metal_Cupboard", "Storage_Homestead_Cabinet_Large",
        "Storage_Kitchen_Block", "Storage_Saddle_Bag", "Container", "Container_Small", "Medium_Container", "Large_Container",
        "Refrigerator", "IceBox", "Deep_Freeze", "Fishing_Crate", "Pouch_Generic", "Pouch_Generic_Large", "Seed_Pouch_T2",
        "Medicine_Bag", "Tackle_Box" }) do
        t.eq(slots.kind(name), "container", name)
    end
end)

t.test("what the game fills itself is left alone", function()
    for _, name in ipairs({ "Storage_Faction_Crate", "Storage_Faction_Crate_One", "Storage_Faction_Crate_Open",
        "Storage_Mission_Analyzer", "Storage_Stockpile_Ship", "Player_Grave", "Overflow_Bag", "Animal_Corpse", "Processor",
        "Campfire", "Reward_Pod", "IceBox_Ice", "Mount_Cargo" }) do
        t.eq(slots.kind(name), nil, name)
    end
end)

t.test("names are compared folded", function()
    t.eq(slots.kind("storage_metal_cupboard"), "container")
    t.eq(slots.kind("BACKPACK"), "backpack")
    t.eq(slots.kind(nil), nil)
end)

t.test("the drop ship takes a count, the rest a multiplier", function()
    t.eq(slots.target("dropship", 15, { dropship = 30 }), 30)
    t.eq(slots.target("dropship", 15, { dropship = 15 }), nil, "the game's own number leaves the row alone")
    t.eq(slots.target("container", 10, { containers = 2 }), 20)
    t.eq(slots.target("container", 10, { containers = 1 }), nil)
    t.eq(slots.target("backpack", 24, { backpack = 5 }), 120)
    t.eq(slots.target(nil, 10, { containers = 2 }), nil)
    t.eq(slots.target("container", 0, { containers = 2 }), nil, "a row with no slots stays so")
    t.eq(slots.target("container", 10, {}), nil)
end)

t.test("fillables of the mission and the settlement are skipped", function()
    for _, name in ipairs({ "Mission_Ship", "Mission_Speeder", "Mission_Drone", "Settlement_Water", "Settlement_Energy",
        "Milk_Cow", "Drone_Companion", "BatteryTest" }) do
        t.ok(slots.fillable_skip(name), name)
    end
    for _, name in ipairs({ "Battery", "Jerrycan", "Fillable_Water_1L", "Oil_Barrel", "Powered_Device", "Milk_Bucket" }) do
        t.ok(not slots.fillable_skip(name), name)
    end
end)

t.test("energy and liquids are told apart by the first resource type", function()
    t.eq(slots.fillable_kind({ ResourceTypes = { { Value = "Energy" } } }), "energy")
    t.eq(slots.fillable_kind({ ResourceTypes = { { Value = "Water" } } }), "fillable")
    t.eq(slots.fillable_kind({ ResourceTypes = { "Biofuel" } }), "fillable")
    t.eq(slots.fillable_kind({ ResourceTypes = {} }), nil)
    t.eq(slots.fillable_kind({}), nil)
    t.eq(slots.fillable_kind(nil), nil)
end)

t.test("volume is whole and 1x leaves the row alone", function()
    t.eq(slots.volume(10000, 10), 100000)
    t.eq(slots.volume(6500, 3), 19500)
    t.eq(slots.volume(10000, 1), nil)
    t.eq(slots.volume(0, 10), nil)
end)

t.finish("moreslots")
