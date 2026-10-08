-- Offline tests for world.items: game.Items, what Wax gives every inventory, and what it gives a player's character for the
-- things it carries. The engine is three stand-ins together: a freed object raises on any use, a list read past its end
-- grows, what a read hands out is good for one frame, and a table row is only asked for by a name the table has.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\items_test.lua
-- Add the word cost to print what the stand-in was asked and how long the Lua side takes.

local t = dofile("wax/tests/offline/harness.lua")
local world = dofile("wax/tests/offline/fake_world.lua")
world.install()
local values = dofile("wax/tests/offline/fake_values.lua")
values.install(world)
local kit = world.icarus(values)
local tables = dofile("wax/tests/offline/fake_tables.lua")
local fake = dofile("wax/tests/offline/fake_items.lua")
fake.install(world, values, tables, kit)
local actions = dofile("wax/tests/offline/fake_actions.lua")
actions.install(world, values, kit, { items = fake })

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)

local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local sched = Wax.import("core.sched")
local log = Wax.import("core.log")
local easy = Wax.import("engine.easy")
local instance = Wax.import("engine.instance")
local game_module = Wax.import("engine.game")
world.possess(nil)
actions.host(true)
game_module.start()
Wax.game = game_module.root
Wax.import("engine.actors").start()
local data = Wax.import("data.tables")
local game = game_module.root
local task = sched.task

-- Frames of 16 ms on a clock the tests own. Whatever the engine handed out before a frame must not be used after it.
local now, FRAME = 1000, 0.016
sched.clock = function() return now end
data.clock = function() return now end
data.min_tables = 1
data.start()
local function frames(count)
    for _ = 1, count or 1 do
        now = now + FRAME
        fake.next_frame()
        game_module.step()
        sched.step()
    end
end
local function pass(seconds) frames(math.ceil(seconds / FRAME) + 2) end

-- Runs fn in a task until it ends. Returns what it returned, or raises what it raised.
local function in_task(fn)
    local done, ok, result = false, nil, nil
    task.spawn(function()
        ok, result = pcall(fn)
        done = true
    end)
    for _ = 1, 2000 do
        if done then break end
        frames(1)
    end
    if not done then error("the task did not end", 2) end
    if not ok then error(result, 0) end
    return result
end

local function at(err, line, what)
    t.ok(tostring(err):find("items_test.lua:" .. line .. ":", 1, true),
        (what or "the error") .. " should name line " .. line .. ": " .. tostring(err))
end

local function deep(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for key, value in pairs(a) do
        if not deep(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

local function text(value)
    if type(value) ~= "table" then return tostring(value) end
    local parts = {}
    for key, item in pairs(value) do parts[#parts + 1] = tostring(key) .. "=" .. text(item) end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function alike(got, want, what)
    if not deep(got, want) then error((what and (what .. ": ") or "") .. "expected " .. text(want) .. ", got " .. text(got), 2) end
end

-- The six numbers the game keeps at 0 for many stacks, with what else a stack has.
local function with_zeros(more)
    local out = { AssociatedItemInventoryId = 0, AssociatedItemInventorySlot = 0, BuildingVariation = 0, CurrentAmmoType = 0,
        DynamicState = 0, GunCurrentMagSize = 0 }
    for key, value in pairs(more) do out[key] = value end
    return out
end

-- A player's character with what it carried when it was read, and its Instance.
local function hero(over)
    local who = fake.player(over)
    who.instance = instance.wrap(who.actor)
    return who
end

-- What the local player controls is looked for once a frame, so a change shows on the next one.
local function possess(who)
    world.possess(who and who.actor or nil)
    frames(1)
end

local function warnings() return #log.since(0, { level = "warn", channel = "wax.items" }) end

local character = Wax.import("world.character")
character.start()
local asked, table_touches, finds = fake.asked(), tables.touches, values.finds
local items = Wax.import("world.items")
items.start()

-- ------------------------------------------------------------------------------------------------------- starting

t.test("starting asks the engine nothing, reads no table and puts nothing on the frame", function()
    t.eq(fake.asked(), asked, "no engine object was touched")
    t.eq(tables.touches, table_touches, "no table was touched")
    t.eq(values.finds, finds, "nothing was looked up by path")
    t.eq(sched.Frame.count, 0)
    t.ok(rawequal(game.Items, items.api))
    t.ok(rawequal(game:GetService("Items"), game.Items))
    local listed = false
    for _, name in ipairs(game_module.names()) do listed = listed or name == "Items" end
    t.ok(listed, "game lists Items among its members")
    t.eq(tostring(game.Items), "Items")
    local stats = items.stats()
    t.eq(stats.copies, 0)
    t.eq(stats.names, false)
    t.eq(stats.facts, 0)
end)

t.test("the first mod that asks about an item owns nothing of what Wax set up for it", function()
    local mod = scope.new("first")
    scope.run(mod, function()
        t.eq(game.Items:Get("Wood").DisplayName, "Wood")
        t.eq(game.Items:Has("Stone"), true)
    end)
    t.eq(mod:size(), 0, "nothing is registered with the mod")
    mod:destroy()
    t.eq(game.Items:Get("Wood").Name, "Wood", "and it goes on working when that mod is gone")
end)

-- ----------------------------------------------------------------------------------------------------- game.Items

t.test("game.Items:Get gives the facts of an item from the game's three tables", function()
    alike(game.Items:Get("Wood"), {
        Name = "Wood", DisplayName = "Wood", Description = "Roughly cut wooden timber, ready for the crafting bench.",
        Weight = 0.15, MaxStack = 100, Icon = "/Game/Assets/2DArt/UI/Items/Item_Icons/Resources/ITEM_Wood.ITEM_Wood",
    })
    local pickaxe = game.Items:Get("Stone_Pickaxe")
    t.eq(pickaxe.DisplayName, "Stone Pickaxe")
    t.eq(pickaxe.Weight, 0.5, "grams in the game, kilograms here")
    t.eq(pickaxe.MaxStack, 1)
    t.eq(pickaxe.MaxDurability, 20000)
    t.eq(math.type(pickaxe.MaxDurability), "integer")
    t.eq(game.Items:Get("Wood").MaxDurability, nil, "wood does not wear")
    t.eq(game.Items:Get("Stick").Description, nil, "an empty description is none")
    t.eq(game.Items:Get("Stick").Icon, "/Game/Assets/2DArt/UI/Items/Item_Icons/Resources/ITEM_Stick.ITEM_Stick")
    t.eq(game.Items:Get("Stone").Icon, nil, "a picture that points at nothing is none")
    t.eq(getmetatable(game.Items:Get("Wood")), nil, "a plain table")
end)

t.test("an item is named in any letter case, with spaces or underscores, and the answer is spelled as the game spells it", function()
    t.eq(game.Items:Get("wood").Name, "Wood")
    t.eq(game.Items:Get("STONE_PICKAXE").Name, "Stone_Pickaxe")
    t.eq(game.Items:Get("stone pickaxe").Name, "Stone_Pickaxe")
    t.eq(game.Items:Get("StonePickaxe").Name, "Stone_Pickaxe")
    t.eq(game.Items:Get("Wild_Tea").Name, "WildTea")
    t.eq(game.Items:Get("wild-tea").DisplayName, "Wild Tea")
    t.eq(game.Items:Get("Bone").Name, "bone", "the game's own files write Bone, the game says bone")
    t.eq(game.Items:Get("Bone").Weight, 0.1)
    local berry = game.Items:Get("Berry")
    t.eq(berry.DisplayName, "Berry", "its handle is written in another letter case than the row it names")
    t.eq(berry.Weight, 0.02)
    alike(game.Items:Get("Dev_Marker"), { Name = "Dev_Marker", DisplayName = "Dev_Marker" }, "an item the game keeps no facts about")
    local skin = game.Items:Get("Skin_Head_Male_03")
    t.eq(skin.DisplayName, "Skin_Head_Male_03", "no shown name: its own name")
    t.eq(skin.Weight, 0)
    t.eq(skin.MaxStack, 1)
end)

t.test("facts are read once and kept, and what is handed out is the mod's own copy", function()
    game.Items:Get("Fiber")
    local rows = tables.rows_asked
    local first = game.Items:Get("Fiber")
    t.eq(game.Items:Get("FIBER").Weight, 0.01)
    t.eq(game.Items:Get("fiber").MaxStack, 200)
    t.eq(tables.rows_asked, rows, "no row was asked for again")
    first.Weight, first.Name = 5, "Changed"
    t.eq(game.Items:Get("Fiber").Weight, 0.01)
    t.eq(game.Items:Get("Fiber").Name, "Fiber")
    t.eq(game.Items:Get({ Item = "Wood", Count = 3, Slot = 1 }).Name, "Wood", "a record that List gave names its item")
    t.eq(game.Items:Get(game.Items:Get("Stone")).Name, "Stone", "and so does what Get gave")
end)

t.test("a name the game does not have raises at the mod's line with the nearest name, and Has answers without raising", function()
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        game.Items:Get("Woood")
    end, "game.Items:Get: 'Woood' is not an item of the game. Did you mean 'Wood'?")
    at(err, line)
    t.ok(not tostring(err):find("items.lua", 1, true), tostring(err))
    t.raises(function() game.Items:Get("Zzzzzz") end, "'Zzzzzz' is not an item of the game.")
    t.raises(function() game.Items:Get(5) end,
        "game.Items:Get expects an item: its name such as \"Wood\", or a record that List or game.Items:Get gave. Got number")
    t.raises(function() game.Items:Get() end, "Got nil")
    t.raises(function() game.Items:Get({}) end, "Got table")
    t.raises(function() game.Items.Get("Wood") end, "call Get with a colon: game.Items:Get(...)")
    t.eq(game.Items:Has("Wood"), true)
    t.eq(game.Items:Has("stone pickaxe"), true)
    t.eq(game.Items:Has("bone"), true)
    t.eq(game.Items:Has("Woood"), false)
    t.eq(game.Items:Has(""), false)
    t.raises(function() game.Items:Has(5) end, "game.Items:Has expects an item's name such as \"Wood\", got number")
    t.raises(function() return game.Items.Got end, "Got is not a member of game.Items. Did you mean 'Get'?")
    t.raises(function() game.Items.Get = 1 end, "game.Items.Get cannot be assigned because game.Items is read-only")
end)

t.test("GetNames gives every item as the game spells and orders them, in a list of the mod's own", function()
    local names = game.Items:GetNames()
    t.eq(#names, #fake.STATIC)
    t.eq(names[1], "Wood")
    t.eq(names[7], "bone")
    t.eq(names[#names], "Dev_Marker")
    names[1] = "Changed"
    t.eq(game.Items:GetNames()[1], "Wood")
end)

t.test("Find goes by the item's name until the shown names are read", function()
    alike(game.Items:Find("stone"), { "Stone", "Stone_Pickaxe" })
    alike(game.Items:Find("pick"), { "Metal_Pickaxe", "Stone_Pickaxe" })
    alike(game.Items:Find("PICK"), { "Metal_Pickaxe", "Stone_Pickaxe" })
    alike(game.Items:Find("metal p"), { "Metal_Pickaxe" })
    alike(game.Items:Find("wild tea"), { "WildTea" })
    alike(game.Items:Find("e_p"), { "Stone_Pickaxe" }, "spaces and underscores are not part of a name")
    alike(game.Items:Find("iron"), {}, "the game shows Metal_Ore as Iron Ore, and nothing has read that yet")
    alike(game.Items:Find("zzzz"), {})
    local found = game.Items:Find("metal")
    alike(found, { "Metal_Ore", "Metal_Pickaxe", "Refined_Metal" }, "the ones that begin with the text come first")
    t.raises(function() game.Items:Find("") end, "game.Items:Find expects the text to look for, and this text is empty")
    t.raises(function() game.Items:Find(" _ - ") end, "this text is empty")
    t.raises(function() game.Items:Find(7) end, "game.Items:Find expects the text to look for, got number")
    t.raises(function() game.Items.Find("stone") end, "call Find with a colon")
end)

t.test("Load reads every shown name in a task, a slice a frame, and Find then matches those too", function()
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        game.Items:Load()
    end, "game.Items:Load can only be used inside a task. Wrap the code in task.spawn(function() ... end)")
    at(err, line)
    t.raises(function() game.Items.Load() end, "call Load with a colon")
    t.eq(items.stats().shown, false)
    items.SLICE = 5
    local frame = sched.stats.frame
    t.eq(in_task(function() return game.Items:Load() end), 14, "two of the sixteen items have no shown name")
    t.ok(sched.stats.frame - frame >= 3, "sixteen names in slices of five take three pauses")
    items.SLICE = 250
    t.eq(items.stats().shown, true)
    alike(game.Items:Find("iron"), { "Metal_Ore", "Metal_Pickaxe", "Refined_Metal" })
    alike(game.Items:Find("Iron Ore"), { "Metal_Ore" })
    alike(game.Items:Find("fists"), { "Player_Fist" })
    alike(game.Items:Find("tea"), { "WildTea" })
    alike(game.Items:Find("stone"), { "Stone", "Stone_Pickaxe" }, "an item is listed once, whichever name matched")
    alike(game.Items:Find("berry"), { "Berry" }, "a handle in another letter case still finds its shown name")
    frame = sched.stats.frame
    t.eq(in_task(function() return game.Items:Load() end), 14)
    t.eq(sched.stats.frame, frame, "a second Load has nothing to read and does not pause")
end)

t.test("when a table changes, what was kept is dropped and read again", function()
    t.eq(game.Items:Get("Wood").Weight, 0.15)
    -- the game makes D_Itemable again with other values in one row
    local rows, order = {}, {}
    for i, row in ipairs(fake.ITEMABLE) do
        rows[row[1]] = { DisplayName = row[2], Weight = row[3], MaxStack = row[4], Icon = row[5], Description = row[6] }
        order[i] = row[1]
    end
    rows.Item_Wood.DisplayName, rows.Item_Wood.Weight = "Timber", 200
    tables.set_rows("Itemable", rows, order)
    tables.move("Itemable")
    game.Data:Table("Itemable"):Stamp()         -- game.Data notices, and says so at the end of the frame
    frames(1)
    local wood = game.Items:Get("Wood")
    t.eq(wood.DisplayName, "Timber")
    t.eq(wood.Weight, 0.2)
    t.eq(items.stats().shown, false, "the shown names belonged to the old table")
    alike(game.Items:Find("iron"), {}, "so Find goes by item names again")
    t.eq(in_task(function() return game.Items:Load() end), 14)
    alike(game.Items:Find("timber"), { "Wood" })

    -- a mod's change of a row is told by Patched, and a change of another table is nobody's business here
    t.ok(items.stats().facts > 0)
    data.api.Changed:Fire("ProcessorRecipes")
    t.ok(items.stats().facts > 0, "another table")
    data.api.Patched:Fire("ItemsStatic", "Wood", "Itemable")
    t.eq(items.stats().facts, 0)
    t.eq(game.Items:Get("Wood").DisplayName, "Timber")
    data.api.Changed:Fire()
    t.eq(items.stats().facts, 0, "everything was dropped by game.Data, so here too")
    t.eq(items.stats().names, false)
end)

-- ---------------------------------------------------------------------------------------------------- inventories

t.test("a player's character has its six inventories as Instances, each with its kind, size, used slots and weight", function()
    local who = hero()
    local me = who.instance
    local expected = {
        { "Backpack", who.backpack, "Backpack", 24, 4, 1.06 }, { "Hotbar", who.hotbar, "Quickbar", 12, 1, 0.01 },
        { "Equipment", who.equipment, "Equipment", 10, 3, 0.1 }, { "Suit", who.suit, "Suit", 1, 0, 0 },
        { "Upgrades", who.upgrades, "UpgradeSlots", 0, 0, 0 }, { "Vision", who.vision, "VisionSlot", 1, 0, 0 },
    }
    for _, want in ipairs(expected) do
        local inventory = me[want[1]]
        t.ok(instance.is_instance(inventory), want[1] .. " is an Instance")
        t.eq(inventory.ClassName, "Inventory")
        t.ok(rawequal(inventory, instance.wrap(want[2].object)), want[1] .. " is the Instance of that component")
        t.eq(inventory.Kind, want[3], want[1] .. ".Kind")
        t.eq(inventory.Size, want[4], want[1] .. ".Size")
        t.eq(inventory.Used, want[5], want[1] .. ".Used")
        t.eq(inventory.Weight, want[6], want[1] .. ".Weight")
    end
    t.ok(rawequal(me.Backpack, me.BackpackInventory), "the same Instance as through the game's own property")
    t.ok(rawequal(me.Backpack.Parent, me))
    t.eq(math.type(me.Backpack.Size), "integer")
end)

t.test("List gives every stack in slot order as plain values of the mod's own, and Slot gives one", function()
    local who = hero()
    local pack = who.instance.Backpack
    local list = pack:List()
    alike(list, {
        { Item = "Fiber", Count = 64, Slot = 1, Properties = { ItemableStack = 64, TransmutableUnits = 5000 } },
        { Item = "Stick", Count = 12, Slot = 2, Properties = with_zeros({ ItemableStack = 12, TransmutableUnits = 10000 }) },
        { Item = "WildTea", Count = 3, Slot = 3, Properties = { ItemableStack = 3 } },
        { Item = "Wood", Count = 1, Slot = 4, Properties = { ItemableStack = 1, TransmutableUnits = 150000 } },
    })
    t.eq(getmetatable(list[1]), nil)
    t.eq(math.type(list[1].Count), "integer")
    list[1].Count, list[1].Properties.ItemableStack, list[2] = 0, 0, nil
    t.eq(pack:List()[1].Count, 64, "changing a record changes nothing here")
    t.eq(pack:List()[1].Properties.ItemableStack, 64)
    t.eq(#pack:List(), 4)
    alike(pack:Slot(2), { Item = "Stick", Count = 12, Slot = 2, Properties = with_zeros({ ItemableStack = 12, TransmutableUnits = 10000 }) })
    t.eq(pack:Slot(5), nil, "an empty slot")
    t.eq(pack:Slot(24), nil)
    t.eq(pack:Slot(1).Inventory, nil, "an inventory does not know whose it is")
    alike(who.instance.Hotbar:Slot(12), { Item = "Player_Fist", Count = 1, Slot = 12, Properties = with_zeros({ ItemableStack = 1 }) })
    alike(who.instance.Vision:List(), {})
    alike(who.instance.Upgrades:List(), {}, "an inventory with no slots")
end)

t.test("Count, Has and Where name an item in any spelling, or by a record", function()
    local who = hero()
    local pack = who.instance.Backpack
    t.eq(pack:Count("Fiber"), 64)
    t.eq(pack:Count("fiber"), 64)
    t.eq(pack:Count("FIBER"), 64)
    t.eq(pack:Count("wild tea"), 3)
    t.eq(pack:Count("Wild_Tea"), 3)
    t.eq(pack:Count("Stone"), 0, "an item of the game that is not in it")
    t.eq(math.type(pack:Count("Stone")), "integer")
    t.eq(pack:Count(pack:List()[4]), 1, "a record names its item")
    t.eq(pack:Count(game.Items:Get("Stick")), 12)
    t.eq(pack:Has("Fiber"), true)
    t.eq(pack:Has("Fiber", 64), true)
    t.eq(pack:Has("Fiber", 65), false)
    t.eq(pack:Has("Stone"), false)
    t.eq(pack:Has("Stone", 0), true)
    alike(pack:Where("stick"), { { Item = "Stick", Count = 12, Slot = 2,
        Properties = with_zeros({ ItemableStack = 12, TransmutableUnits = 10000 }) } })
    alike(pack:Where("Stone"), {})
    -- a second stack of the same item
    fake.put(who.backpack, 10, "Stick", 30)
    pack:Refresh()
    t.eq(pack:Count("Stick"), 42)
    t.eq(pack.Used, 5)
    local where = pack:Where("Stick")
    t.eq(#where, 2)
    t.eq(where[1].Slot, 2)
    t.eq(where[2].Slot, 10)
    t.eq(where[2].Count, 30)
    t.eq(pack:Has("Stick", 42), true)
end)

t.test("an item with no stack number counts as one, a tool has its durability, and every number is under the game's name", function()
    local who = hero()
    local worn, hotbar = who.instance.Equipment, who.instance.Hotbar
    alike(worn:List(), {
        { Item = "EnviroSuit", Count = 1, Slot = 6, Properties = { ItemableStack = 1 } },
        { Item = "Skin_Head_Male_03", Count = 1, Slot = 7 },
        { Item = "Spacesuit_Cap_Male", Count = 1, Slot = 8 },
    })
    t.eq(worn:Count("Skin_Head_Male_03"), 1)
    t.eq(worn:Slot(7).Properties, nil)
    fake.tool(who.hotbar, 3, "Stone_Pickaxe", 20000)
    hotbar:Refresh()
    alike(hotbar:Slot(3), { Item = "Stone_Pickaxe", Count = 1, Slot = 3, Durability = 20000,
        Properties = with_zeros({ ItemableStack = 1, Durability = 20000 }) })
    t.eq(hotbar:Slot(12).Durability, nil, "fists do not wear")
    fake.set(who.hotbar, 3, 3, 5)           -- GunCurrentMagSize
    fake.set(who.hotbar, 3, 21, 9)          -- a number the game added after this version of Wax
    hotbar:Refresh()
    local stack = hotbar:Slot(3)
    t.eq(stack.Properties.GunCurrentMagSize, 5)
    t.eq(stack.Properties[21], 9)
    t.eq(stack.Count, 1)
end)

t.test("a slot is numbered by what the game calls it, not by where it sits in the game's list", function()
    local who = hero()
    who.backpack.slots[1].index, who.backpack.slots[4].index = 3, 0
    local pack = who.instance.Backpack
    local list = pack:List()
    t.eq(list[1].Item, "Wood")
    t.eq(list[1].Slot, 1)
    t.eq(list[4].Item, "Fiber")
    t.eq(list[4].Slot, 4)
    t.eq(pack:Slot(4).Item, "Fiber")
    t.eq(pack:Slot(1).Item, "Wood")
    t.eq(pack:Where("Fiber")[1].Slot, 4)
    -- an event that names a slot cannot be matched to a place in such a list, so all of it is read
    local walks = items.stats().walks
    frames(1)
    t.eq(items.touch(instance.address(pack), 0), true)
    t.eq(pack:Count("Wood"), 1)
    t.eq(items.stats().walks, walks + 1)
end)

t.test("a wrong item, a wrong slot and a wrong call say what is expected, at the mod's line", function()
    local who = hero()
    local pack = who.instance.Backpack
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        pack:Count("Fibre")
    end, "Count: 'Fibre' is not an item of the game. Did you mean 'Fiber'?")
    at(err, line)
    t.ok(not tostring(err):find("items.lua", 1, true), tostring(err))
    t.raises(function() pack:Count() end,
        "Count expects an item: its name such as \"Wood\", or a record that List or game.Items:Get gave. Got nil")
    t.raises(function() pack:Count(5) end, "Got number")
    t.raises(function() pack:Count(who.instance) end, "Got an Instance")
    t.raises(function() pack:Count({ Count = 3 }) end, "Got table")
    t.raises(function() pack.Count("Fiber") end, "call Count with a colon: instance:Count(...)")
    t.raises(function() pack:Has("Fibre") end, "Has: 'Fibre' is not an item of the game. Did you mean 'Fiber'?")
    t.raises(function() pack:Has("Fiber", "many") end, "Has expects how many as its second value, got string")
    t.raises(function() pack:Where("Nope_Item") end, "Where: 'Nope_Item' is not an item of the game.")
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        pack:Slot(25)
    end, "this inventory has 24 slots, counted from 1, so it has no slot 25")
    at(err, line)
    t.raises(function() pack:Slot(0) end, "so it has no slot 0")
    t.raises(function() pack:Slot("x") end, "Slot expects a slot number from 1 to 24, got string")
    t.raises(function() pack:Slot(1.5) end, "Slot expects a slot number from 1 to 24, got number")
    t.raises(function() pack:Slot() end, "got nil")
    t.raises(function() pack.Size = 3 end, "Size is read-only")
    t.raises(function() pack.List = nil end, "List is read-only")
    t.raises(function() who.instance.Backpack = 1 end, "Backpack is read-only")
end)

-- ------------------------------------------------------------------------------------ how often the game is asked

local paced = hero()

t.test("asked every frame, an inventory is read whole once and then looked at four times a second, a few slots each", function()
    local pack = paced.instance.Backpack
    local before = items.stats()
    t.eq(pack:Count("Wood"), 1)
    local first = items.stats()
    t.eq(first.walks - before.walks, 1)
    t.eq(first.slots - before.slots, 24)
    local reads = fake.reads
    for _ = 1, 15 do
        frames(1)
        t.eq(pack:Count("Wood"), 1)
        t.eq(pack.Used, 4)
        t.eq(#pack:List(), 4)
    end
    t.eq(fake.reads, reads, "inside a quarter of a second nothing of the inventory is read")
    t.eq(items.stats().looks, first.looks)
    frames(1)
    t.eq(pack:Count("Wood"), 1)
    local second = items.stats()
    t.eq(second.looks - first.looks, 1, "one look after a quarter of a second")
    t.eq(second.walks, first.walks, "not a whole read")
    t.eq(second.slots - first.slots, 4, "24 slots in 2 seconds is 4 in the 0.256 s since the last look")
    reads = fake.reads
    t.eq(pack:Count("Fiber"), 64)
    t.eq(pack.Size, 24)
    t.eq(fake.reads, reads, "and once a frame at most")

    local mark = items.stats()
    for _ = 1, 140 do
        frames(1)
        pack:Count("Wood")
    end
    local after = items.stats()
    t.eq(after.walks, mark.walks, "kept asking for two seconds: no whole read")
    t.ok(after.slots - mark.slots >= 24, "and every slot was read again: " .. (after.slots - mark.slots))
    t.ok(after.looks - mark.looks <= 9, "in at most nine looks: " .. (after.looks - mark.looks))
end)

t.test("a stack that is added shows once the game has worked the weight out, at the next look", function()
    local pack = paced.instance.Backpack
    pack:Refresh()
    frames(1)
    fake.put(paced.backpack, 6, "Berry", 5)
    frames(1)
    t.eq(pack:Count("Berry"), 0, "the weight has not moved yet and no look is due")
    fake.settle(paced)
    local walks = items.stats().walks
    pass(items.PACE)
    t.eq(pack:Count("Berry"), 5)
    t.eq(pack.Used, 5)
    t.eq(pack.Weight, 1.16)
    t.eq(items.stats().walks, walks + 1, "a changed weight reads every slot")
    fake.take(paced.backpack, 6)
    fake.settle(paced)
    pass(items.PACE)
    t.eq(pack:Count("Berry"), 0)
    t.eq(pack:Slot(6), nil)
end)

t.test("what changes without the weight changing shows within two seconds while the inventory is asked", function()
    local hotbar = paced.instance.Hotbar
    fake.tool(paced.hotbar, 3, "Stone_Pickaxe", 20000)
    fake.settle(paced)
    pass(items.PACE)
    t.eq(hotbar:Slot(3).Durability, 20000)
    local walks = items.stats().walks
    fake.set(paced.hotbar, 3, fake.DURABILITY, 19990)
    local waited = 0
    repeat
        frames(1)
        waited = waited + FRAME
    until hotbar:Slot(3).Durability == 19990 or waited > 5
    t.ok(waited <= items.SWEEP + items.PACE, "the wear showed after " .. waited .. " s")
    -- moved to another slot of the same inventory
    fake.take(paced.hotbar, 3)
    fake.tool(paced.hotbar, 5, "Stone_Pickaxe", 19990)
    waited = 0
    repeat
        frames(1)
        waited = waited + FRAME
    until (hotbar:Slot(5) and hotbar:Slot(3) == nil) or waited > 5
    t.ok(waited <= items.SWEEP + items.PACE, "the move showed after " .. waited .. " s")
    t.eq(hotbar:Count("Stone_Pickaxe"), 1)
    t.eq(items.stats().walks, walks, "without one whole read")
end)

t.test("an inventory nobody asked about for two seconds is read whole when it is asked again", function()
    local hotbar = paced.instance.Hotbar
    pass(3)
    fake.set(paced.hotbar, 5, fake.DURABILITY, 100)
    local walks = items.stats().walks
    t.eq(hotbar:Slot(5).Durability, 100)
    t.eq(items.stats().walks, walks + 1)
end)

t.test("Refresh reads everything now, also in a frame in which it was looked at already", function()
    local hotbar = paced.instance.Hotbar
    fake.set(paced.hotbar, 5, fake.DURABILITY, 50)
    t.eq(hotbar:Slot(5).Durability, 100, "the copy")
    hotbar:Refresh()
    t.eq(hotbar:Slot(5).Durability, 50)
    t.raises(function() hotbar.Refresh() end, "call Refresh with a colon")
end)

t.test("touch reads the one slot an event names, or all of it, at the next ask", function()
    local hotbar = paced.instance.Hotbar
    frames(1)
    fake.set(paced.hotbar, 5, fake.DURABILITY, 49)
    local mark = items.stats()
    t.eq(items.touch(instance.address(hotbar), 4), true, "the game counts slots from 0")
    t.eq(hotbar:Slot(5).Durability, 49)
    local after = items.stats()
    t.eq(after.walks, mark.walks)
    t.ok(after.slots - mark.slots <= 2, "that slot and the one whose turn it was: " .. (after.slots - mark.slots))
    frames(1)
    fake.set(paced.hotbar, 5, fake.DURABILITY, 48)
    t.eq(items.touch(instance.address(hotbar)), true)
    t.eq(hotbar:Slot(5).Durability, 48)
    t.eq(items.stats().walks, after.walks + 1, "without a slot, all of it")
    t.eq(items.touch(12345, 0), false, "an inventory nobody asked about")
end)

t.test("slots that are added or taken away show at the next look", function()
    local pack = paced.instance.Backpack
    fake.resize(paced.backpack, 30)
    pass(items.PACE)
    t.eq(pack.Size, 30)
    t.eq(pack.Used, 4)
    fake.put(paced.backpack, 30, "Stone", 2)
    pack:Refresh()
    t.eq(pack:Slot(30).Item, "Stone")
    fake.resize(paced.backpack, 2)
    pass(items.PACE)
    t.eq(pack.Size, 2)
    t.eq(pack.Used, 2)
    t.eq(#pack:List(), 2)
    t.eq(pack:Count("Stone"), 0)
    t.eq(pack:Count("Wood"), 0)
    t.raises(function() pack:Slot(3) end, "this inventory has 2 slots, counted from 1, so it has no slot 3")
end)

-- ---------------------------------------------------------------------------------------- what a character carries

local carrier = hero()

t.test("a character counts and lists over all its inventories", function()
    local me = carrier.instance
    t.eq(me:Count("Fiber"), 64)
    t.eq(me:Count("player fist"), 1)
    t.eq(me:Count("EnviroSuit"), 1)
    t.eq(me:Count("Stone"), 0)
    fake.put(carrier.hotbar, 1, "Fiber", 10)
    fake.settle(carrier)
    pass(items.PACE)
    t.eq(me:Count("Fiber"), 74, "the backpack's and the hotbar's")
    t.eq(me:Has("Fiber", 74), true)
    t.eq(me:Has("Fiber", 75), false)
    t.eq(me:Has("Stone"), false)
    t.eq(me:Has("Stone", 0), true)
    t.eq(me:Count(me.Hotbar:Slot(1)), 74, "a record names its item")
    local list = me:List()
    local seen = {}
    for i, record in ipairs(list) do seen[i] = record.Inventory .. " " .. record.Slot .. " " .. record.Item .. " x" .. record.Count end
    alike(seen, { "Backpack 1 Fiber x64", "Backpack 2 Stick x12", "Backpack 3 WildTea x3", "Backpack 4 Wood x1", "Hotbar 1 Fiber x10",
        "Hotbar 12 Player_Fist x1", "Equipment 6 EnviroSuit x1", "Equipment 7 Skin_Head_Male_03 x1", "Equipment 8 Spacesuit_Cap_Male x1" })
    for _, record in ipairs(list) do
        t.eq(me[record.Inventory]:Slot(record.Slot).Item, record.Item, "the record says where its stack is")
    end
    list[1].Count = 0
    t.eq(me:List()[1].Count, 64)
end)

t.test("asked every frame, a character's inventories are not read between two looks", function()
    local me = carrier.instance
    me:Count("Fiber")
    local reads, looks = fake.reads, items.stats().looks
    for _ = 1, 10 do
        frames(1)
        t.eq(me:Count("Fiber"), 74)
        t.eq(me:Has("Wood"), true)
    end
    t.eq(fake.reads, reads)
    t.eq(items.stats().looks, looks)
    pass(items.PACE)
    me:Count("Fiber")
    t.ok(items.stats().looks - looks <= 6, "then one look at each of the six")
end)

t.test("HotbarSlot is the slot the game says is in hand, and HeldItem what the hotbar holds there", function()
    local me = carrier.instance
    t.eq(me.HotbarSlot, 12, "the game said 11, counted from 0")
    alike(me.HeldItem, { Item = "Player_Fist", Count = 1, Slot = 12, Inventory = "Hotbar", Properties = with_zeros({ ItemableStack = 1 }) })
    fake.tool(carrier.hotbar, 3, "Stone_Pickaxe", 20000)
    fake.settle(carrier)
    pass(items.PACE)
    carrier.store.FocusedQuickbarSlot = 2
    t.eq(me.HotbarSlot, 3)
    local held = me.HeldItem
    t.eq(held.Item, "Stone_Pickaxe")
    t.eq(held.Durability, 20000)
    t.eq(held.Slot, 3)
    held.Item = "Changed"
    t.eq(me.HeldItem.Item, "Stone_Pickaxe")
    carrier.store.FocusedQuickbarSlot = 4
    t.eq(me.HotbarSlot, 5)
    t.eq(me.HeldItem, nil, "an empty slot of the hotbar")
    carrier.store.FocusedQuickbarSlot = -1
    t.eq(me.HotbarSlot, nil)
    t.eq(me.HeldItem, nil)
    carrier.store.FocusedQuickbarSlot = 40
    t.eq(me.HeldItem, nil, "a slot the hotbar does not have")
    carrier.store.FocusedQuickbarSlot = 11
    t.raises(function() me.HeldItem = 1 end, "HeldItem is read-only")
end)

t.test("a wrong item on a character raises at the mod's line", function()
    local me = carrier.instance
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me:Count("Fibre")
    end, "Count: 'Fibre' is not an item of the game. Did you mean 'Fiber'?")
    at(err, line)
    t.raises(function() me:Has("Fiber", {}) end, "Has expects how many as its second value, got table")
    t.raises(function() me.Count("Fiber") end, "call Count with a colon")
    t.raises(function() me:Has() end, "Has expects an item")
end)

t.test("the character in the station has only what it has, and a creature gets none of this", function()
    local station = kit.station()
    local worn = fake.attach(station, "EquipmentInventory", fake.inventory("Equipment", 10))
    fake.put(worn, 6, "EnviroSuit", 1)
    fake.settle(worn)
    local pawn = instance.wrap(station.actor)
    for _, name in ipairs({ "Backpack", "Hotbar", "Suit", "Upgrades", "Vision", "HotbarSlot", "HeldItem" }) do
        t.eq(pawn[name], nil, name)
    end
    t.eq(pawn.Equipment.Used, 1)
    t.eq(pawn:Count("EnviroSuit"), 1)
    t.eq(pawn:Count("Wood"), 0)
    local list = pawn:List()
    t.eq(#list, 1)
    t.eq(list[1].Inventory, "Equipment")

    local animal = kit.creature()
    local wolf = instance.wrap(animal.actor)
    t.raises(function() return wolf.Backpack end, "Backpack is not a member of BP_NPC_Wolf_Conifer_Character_C")
    t.raises(function() return wolf.HeldItem end, "HeldItem is not a member of BP_NPC_Wolf_Conifer_Character_C")
    t.raises(function() return wolf:Count("Wood") end, "Count is not a member of BP_NPC_Wolf_Conifer_Character_C")
    t.eq(wolf.Inventory, nil, "the game's own property, with nothing in it")
    -- an inventory reached through any property of the game is an inventory all the same
    local carried = fake.attach(animal, "Inventory", fake.inventory("Creature", 4))
    fake.put(carried, 1, "bone", 2)
    local own = wolf.Inventory
    t.eq(own.Kind, "Creature")
    t.eq(own.Size, 4)
    t.eq(own.Used, 1)
    t.eq(own:Count("Bone"), 2)
    t.eq(own:List()[1].Item, "bone")
end)

t.test("game.Me has it all for the local player's character, and says so when there is none", function()
    possess(nil)
    local me = game.Me
    t.eq(me.Backpack, nil)
    t.eq(me.HeldItem, nil)
    t.eq(me.HotbarSlot, nil)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me:Count("Wood")
    end, "there is no character right now, so Count cannot be called. game.Me.Exists says when there is one")
    at(err, line)
    t.raises(function() me:List() end, "there is no character right now, so List cannot be called")
    t.raises(function() me:Has("Wood") end, "there is no character right now, so Has cannot be called")
    local who = hero()
    possess(who)
    t.eq(me:Count("Fiber"), 64)
    t.eq(me:Has("Wood"), true)
    t.eq(#me:List(), 8)
    t.ok(rawequal(me.Backpack, who.instance.Backpack))
    t.eq(me.Hotbar:Slot(12).Item, "Player_Fist")
    t.eq(me.HeldItem.Item, "Player_Fist")
    t.eq(me.HotbarSlot, 12)
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me:Count("Fibre")
    end, "Count: 'Fibre' is not an item of the game. Did you mean 'Fiber'?")
    at(err, line)
    local names = {}
    for _, name in ipairs(getmetatable(me).__names()) do names[name] = true end
    t.ok(names.Backpack and names.Count and names.HeldItem, "the names are among those game.Me lists")
    possess(nil)
end)

t.test("nothing is registered with the mod that asks, and the game's own members of an inventory stay as they are", function()
    local who = hero()
    local pack = who.instance.Backpack
    local mod = scope.new("carrier")
    scope.run(mod, function()
        who.instance:Count("Wood")
        pack:List()
        pack:Refresh()
        game.Items:Find("wood")
    end)
    t.eq(mod:size(), 0)
    mod:destroy()
    t.eq(pack:Count("Wood"), 1, "and nothing was taken away with the mod")
    t.eq(pack:GetItemCount(), 80, "the game's own count of items")
    t.eq(pack:HasItems(), true)
    t.eq(pack.CurrentWeight, 1060, "the game's own property, in grams")
    t.eq(pack:Get("CurrentWeight"), 1060)
    local names = {}
    for _, name in ipairs(pack:GetMembers()) do names[name] = true end
    for _, name in ipairs({ "Kind", "Size", "Used", "Weight", "List", "Slot", "Count", "Has", "Where", "Refresh",
        "GetItemCount", "Find", "GetItems", "Empty", "CurrentWeight", "Slots" }) do
        t.ok(names[name], name .. " is among the members")
    end
    alike(easy.clashes(), {}, "no name Wax gives hides a member of the game's")
    for _, name in ipairs(easy.stats().unseen) do
        t.ok(name ~= "Inventory" and name ~= "IcarusPlayerCharacter", name .. " was given members and never met")
    end
end)

-- ----------------------------------------------------------------------------------------------------- unkind parts

t.test("an inventory whose character ended play answers with an error, and nothing freed is touched", function()
    local who = hero()
    local me = who.instance
    local pack = me.Backpack
    t.eq(pack:Count("Wood"), 1)
    t.eq(me:Count("Wood"), 1)
    world.destroy(who.actor)
    world.free(who.actor)
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        pack:Count("Wood")
    end, "this Inventory no longer exists")
    at(err, line)
    t.raises(function() return pack.Size end, "this Inventory no longer exists")
    t.raises(function() pack:Refresh() end, "this Inventory no longer exists")
    t.raises(function() return me:Count("Wood") end, "this BP_IcarusPlayerCharacterSurvival_C no longer exists")
    t.raises(function() return me.Backpack end, "no longer exists")
    t.raises(function() return me.HeldItem end, "no longer exists")
    frames(2)
    t.raises(function() return pack:List() end, "this Inventory no longer exists")
    t.eq(world.dead_touches, 0, world.dead_where)
end)

t.test("after a respawn as another actor game.Me carries what the new one carries", function()
    local first = hero()
    possess(first)
    local old = game.Me.Backpack
    t.eq(game.Me:Count("Fiber"), 64)
    world.destroy(first.actor)
    world.free(first.actor)
    local second = hero()
    fake.put(second.backpack, 1, "Fiber", 7)
    fake.settle(second)
    possess(second)
    t.eq(game.Me:Count("Fiber"), 7)
    t.eq(game.Me.Backpack:Slot(1).Count, 7)
    t.ok(not rawequal(game.Me.Backpack, old))
    t.raises(function() old:Count("Fiber") end, "this Inventory no longer exists")
    t.eq(world.dead_touches, 0, world.dead_where)
end)

t.test("a map change drops every copy without asking anything of the old map, seen or not", function()
    local who = hero()
    possess(who)
    local pack = game.Me.Backpack
    t.eq(pack:Count("Wood"), 1)
    t.eq(game.Me:Count("Wood"), 1)
    t.ok(items.stats().copies > 0)
    world.travel("Terrain_017")
    frames(1)
    t.eq(items.stats().copies, 0)
    t.raises(function() pack:Count("Wood") end, "this Inventory no longer exists")
    t.eq(game.Me.Backpack, nil)
    t.raises(function() game.Me:Count("Wood") end, "there is no character right now")
    t.eq(world.dead_touches, 0, world.dead_where)

    local arrived = hero()
    possess(arrived)
    t.eq(game.Me:Count("Fiber"), 64, "on the new map")
    local kept = game.Me.Backpack
    t.eq(kept.Size, 24)
    world.travel("Terrain_018", true)       -- the old map's actors are freed with no end of play seen
    frames(1)
    t.eq(items.stats().copies, 0)
    t.raises(function() return kept.Size end, "this object is from before the last map change")
    t.raises(function() kept:Count("Wood") end, "this object is from before the last map change")
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(game.Items:Get("Stone").Weight, 0.3, "what an item is does not depend on the map")
end)

t.test("an inventory the game no longer keeps as Wax reads it has nil fields and functions that say so, once in the log", function()
    local who = hero()
    local me = who.instance
    local pack = me.Backpack
    t.eq(pack.Size, 24)
    t.eq(warnings(), 0)
    local slots = who.backpack.store.Slots
    who.backpack.store.Slots = nil              -- as after an update that renamed the member
    pass(items.PACE)
    t.eq(pack.Size, nil)
    t.eq(pack.Used, nil)
    t.eq(pack.Weight, 1.06, "what can still be read is read")
    t.eq(pack.Kind, "Backpack")
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        pack:List()
    end, "List: this inventory cannot be read in this version of the game (used an invalid object (Slots))")
    at(err, line)
    t.raises(function() pack:Count("Fiber") end, "Count: this inventory cannot be read in this version of the game")
    t.raises(function() pack:Slot(1) end, "Slot: this inventory cannot be read")
    t.raises(function() pack:Refresh() end, "Refresh: this inventory cannot be read")
    t.eq(me:Count("Fiber"), 0, "a character counts what can be read")
    t.eq(#me:List(), 4)
    pass(1)
    for _ = 1, 40 do
        frames(1)
        t.eq(pack.Size, nil)
    end
    t.eq(warnings(), 1, "one line in the log, however often it is asked")
    who.backpack.store.Slots = slots
    pass(items.PACE)
    t.eq(pack.Size, 24, "and it reads again when the game gives it again")
    t.eq(pack:Count("Fiber"), 64)
    t.eq(me:Count("Fiber"), 64)

    local hotbar = me.Hotbar
    t.eq(hotbar.Used, 1)
    who.hotbar.store.CurrentWeight = nil
    pass(items.PACE)
    t.eq(hotbar.Weight, nil)
    t.eq(hotbar.Used, nil)
    t.eq(me.HeldItem, nil)
    t.raises(function() hotbar:List() end, "this inventory cannot be read in this version of the game (it has no CurrentWeight)")
    who.hotbar.store.CurrentWeight = 10
    who.hotbar.store.InventoryInfoRowHandle = nil
    pass(items.PACE)
    t.eq(hotbar.Used, 1)
    t.eq(hotbar.Kind, nil, "a kind that cannot be read is none")
    t.eq(me.HeldItem.Item, "Player_Fist")
    t.eq(warnings(), 1)
end)

t.test("a character that lacks an inventory has nil for it and counts the rest", function()
    local who = hero()
    local me = who.instance
    t.eq(me:Count("Player_Fist"), 1)
    who.store.QuickbarInventory = nil
    who.store.FocusedQuickbarSlot = nil
    pass(items.PACE)
    t.eq(me.Hotbar, nil)
    t.eq(me.HeldItem, nil)
    t.eq(me.HotbarSlot, nil)
    t.eq(me:Count("Player_Fist"), 0)
    t.eq(me:Count("Fiber"), 64)
    for _, record in ipairs(me:List()) do t.ok(record.Inventory ~= "Hotbar") end
    t.eq(#me:List(), 7)
end)

t.test("with the item tables out of reach inventories still count, by the name as it is written", function()
    local who = hero()
    local pack = who.instance.Backpack
    t.eq(pack:Count("Fiber"), 64)
    game.Data:Flush()
    frames(1)
    tables.hide("ItemsStatic", true)
    t.eq(pack:Count("Fiber"), 64)
    t.eq(pack:Count("fiber"), 64)
    t.eq(pack:Count("Fibre"), 0, "a wrong name cannot be told from an item that is not there")
    t.eq(pack:Has("Wood"), true)
    t.raises(function() game.Items:Get("Wood") end, "the game has no table named ItemsStatic")
    t.raises(function() game.Items:Has("Wood") end, "the game has no table named ItemsStatic")
    t.raises(function() game.Items:Find("wood") end, "the game has no table named ItemsStatic")
    tables.hide("ItemsStatic", false)
    pass(data.relist_seconds)
    t.eq(game.Items:Has("Wood"), true, "the tables are back")
    t.eq(pack:Count("Fiber"), 64)
    t.raises(function() pack:Count("Fibre") end, "'Fibre' is not an item of the game. Did you mean 'Fiber'?")
end)

t.test("copies of inventories nobody asks about any more are dropped, and read again when asked", function()
    items.KEEP, items.MANY = 1, 8
    local loose = {}
    for i = 1, 10 do
        loose[i] = instance.wrap(fake.inventory("Chest", 4).object)
        t.eq(loose[i].Size, 4)
    end
    t.ok(items.stats().copies >= 10)
    pass(2.5)
    local one = instance.wrap(fake.inventory("Chest", 6).object)
    t.eq(one.Size, 6)
    t.eq(items.stats().copies, 1)
    t.eq(items.touch(instance.address(loose[1])), false, "its copy is gone")
    t.eq(loose[1].Size, 4)
    t.eq(items.stats().copies, 2)
    items.KEEP, items.MANY = 60, 32
end)

-- ---------------------------------------------------------------------------------------------- giving and taking

local function calls(name) return actions.calls[name] or 0 end

-- How often the game's own functions were called so far, to see that a refusal called none.
local function all_calls()
    local total = 0
    for _, count in pairs(actions.calls) do total = total + count end
    return total
end

t.test("the host gives items into the backpack: onto its stacks first, then into empty slots, with the game's own calls", function()
    actions.host(true)
    local who = hero()
    possess(who)
    local me = who.instance
    local silent, tops, places = values.silent, calls("AttemptPartialStackPlacement"), calls("AutomaticallyPlaceItem")
    local given, why = me:Give("Wood", 5)
    t.eq(given, 5)
    t.eq(why, nil)
    t.eq(me:Count("Wood"), 6, "it counts in the same frame, before the game has worked the weight out")
    t.eq(me.Backpack:Slot(4).Count, 6, "they went onto the stack that was there")
    t.eq(calls("AttemptPartialStackPlacement"), tops + 1)
    t.eq(calls("AutomaticallyPlaceItem"), places, "no slot was needed")
    t.eq(who.backpack.store.CurrentWeight, 1060, "the game's own weight has not moved yet")

    t.eq(me:Give("stone", 250), 250, "a name in any letter case, and more than one stack holds")
    local stones = me.Backpack:Where("Stone")
    t.eq(#stones, 3)
    alike({ stones[1].Slot, stones[1].Count, stones[2].Slot, stones[2].Count, stones[3].Slot, stones[3].Count }, { 5, 100, 6, 100, 7, 50 })
    t.eq(me:Count("Stone"), 250)
    t.eq(calls("AutomaticallyPlaceItem"), places + 3)
    t.eq(values.silent - silent, 3, "each placing hands the game the table where it reads DropItemAtOverFlow: " .. table.concat(values.log, " | "))
    t.eq(actions.last_place.drop, true, "which the game reads as true, as it did when it was tried")
    t.eq(actions.last_place.stacking, false, "and the value after it is AllowStacking")

    t.eq(me:Give("Fiber", 300), 300)
    t.eq(me.Backpack:Slot(1).Count, 200, "the stack was filled to the most it holds")
    t.eq(me.Backpack:Slot(8).Count, 164, "and the rest went into the next empty slot")

    t.eq(me:Give("Stone_Pickaxe"), 1, "one when no number is given")
    local pick = me.Backpack:Where("Stone_Pickaxe")[1]
    t.eq(pick.Slot, 9)
    t.eq(pick.Durability, 20000, "a tool comes with the durability the game gives it")
    t.eq(me:Give({ Item = "Berry", Count = 7 }, 2), 2, "a record names the item, and the number comes from the call")
    t.eq(me.Backpack:Count("Berry"), 2)
    t.eq(me.Hotbar.Used, 1, "nothing was put anywhere but the backpack")

    fake.settle(who)
    frames(1)
    t.eq(me:Count("Stone"), 250, "the same answer once the game's weight has followed")
    t.eq(actions.dropped, 0)
    t.eq(actions.untried, 0, table.concat(actions.log, " | "))
    t.eq(rawget(_G, "Enum_PropertyType"), nil)
    possess(nil)
end)

t.test("what does not fit is not given: Give answers how many went in and why, and nothing lands on the ground", function()
    actions.host(true)
    local who = hero()
    local pack = instance.wrap(who.backpack.object)
    for position = 5, 23 do fake.put(who.backpack, position, "bone", 100) end
    fake.settle(who)
    local given, why = pack:Give("Stone", 150)
    t.eq(given, 100, "the one empty slot took a full stack")
    t.eq(why, "there was no room for 50 of the 150")
    t.eq(pack.Used, 24)
    local places = calls("AutomaticallyPlaceItem")
    given, why = pack:Give("Stone", 5)
    t.eq(given, 0)
    t.eq(why, "there was no room for 5 of the 5")
    given, why = pack:Give("Wood", 1000)
    t.eq(given, 99, "what the stack that is there still holds")
    t.eq(why, "there was no room for 901 of the 1000")
    t.eq(pack:Give("Stone_Pickaxe"), 0)
    t.eq(calls("AutomaticallyPlaceItem"), places, "with no empty slot the game is never asked to place: it would drop the item")
    t.eq(actions.dropped, 0)
    t.eq(actions.untried, 0, table.concat(actions.log, " | "))
end)

t.test("an inventory that does not take a kind of item is given none of it, and one the game fails to place is said", function()
    actions.host(true)
    local who = hero()
    who.equipment.accepts = function(item) return item == "EnviroSuit" end
    local gear = instance.wrap(who.equipment.object)
    local places = calls("AutomaticallyPlaceItem")
    local given, why = gear:Give("Wood", 2)
    t.eq(given, 0)
    t.eq(why, "there was no room for 2 of the 2")
    t.eq(calls("AutomaticallyPlaceItem"), places, "the game's own answer about each empty slot was asked first")
    t.eq(gear:Give("EnviroSuit"), 1)
    t.eq(gear:Count("EnviroSuit"), 2)

    -- an inventory that says yes when asked and then places nothing: the game drops the item, and Wax stops there
    local chest = fake.inventory("Chest", 4)
    local turn = 0
    chest.accepts = function()
        turn = turn + 1
        return turn == 1
    end
    local box = instance.wrap(chest.object)
    local before = warnings()
    given, why = box:Give("Wood", 3)
    t.eq(given, 0)
    t.eq(why, "the game did not place 3 of the 3")
    t.eq(warnings(), before + 1, "it is in the log once")
    t.eq(actions.dropped, 1, "the stand-in dropped that one, as the game would")
    actions.dropped = 0
end)

t.test("Take takes items out with the game's own call, from the last stack back, and answers how many went", function()
    actions.host(true)
    local who = hero()
    possess(who)
    local me = who.instance
    fake.put(who.backpack, 10, "Stick", 30)
    fake.put(who.hotbar, 2, "Stick", 5)
    fake.settle(who)
    t.eq(me:Count("Stick"), 47)
    t.eq(me:Take("stick", 35), 35)
    t.eq(me.Backpack:Slot(10), nil, "the last stack went first")
    t.eq(me.Backpack:Slot(2).Count, 7)
    t.eq(me.Hotbar:Count("Stick"), 5, "the hotbar comes after the backpack")
    t.eq(me:Count("Stick"), 12, "it counts in the same frame")
    t.eq(who.backpack.slots[10].last, "Stick", "the slot remembers what it held, as when a player uses a stack up")
    local taken, why = me:Take("Stick", 100)
    t.eq(taken, 12)
    t.eq(why, "there were only 12 of the 100 to take")
    t.eq(me:Count("Stick"), 0)
    taken, why = me:Take("EnviroSuit")
    t.eq(taken, 0, "what the character wears is not taken")
    t.eq(why, "there were only 0 of the 1 to take")
    t.eq(me.Equipment:Take("EnviroSuit"), 1, "an inventory gives up its own")
    t.eq(me.Equipment:Count("EnviroSuit"), 0)
    t.eq(me:Take("Fiber"), 1, "one when no number is given")
    t.eq(me:Count("Fiber"), 63)
    t.eq(me:Take({ Item = "WildTea", Count = 3, Slot = 3 }, 2), 2)
    t.eq(me.Backpack:Slot(3).Count, 1)
    t.eq(actions.untried, 0, table.concat(actions.log, " | "))
    t.eq(rawget(_G, "Enum_PropertyType"), nil)
    possess(nil)
end)

t.test("a wrong item, a wrong number and a client are refused at the mod's line, and the game is asked for nothing", function()
    actions.host(true)
    local who = hero()
    possess(who)
    local me = who.instance
    local before = all_calls()
    local line
    local err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me:Give("Wod")
    end, "Give: 'Wod' is not an item of the game. Did you mean 'Wood'?")
    at(err, line)
    t.raises(function() me:Give("Wood", 0) end, "Give expects how many as its second value, a whole number from 1 to 100000, got 0")
    t.raises(function() me:Give("Wood", 2.5) end, "a whole number from 1 to 100000, got 2.5")
    t.raises(function() me:Give("Wood", "many") end, "a whole number from 1 to 100000, got string")
    t.raises(function() me:Give("Wood", 1000000) end, "a whole number from 1 to 100000, got 1000000")
    t.raises(function() me.Backpack:Give() end, "Give expects an item: its name such as \"Wood\"")
    t.raises(function() me:Take("Wod") end, "Take: 'Wod' is not an item of the game.")
    err = t.raises(function()
        line = debug.getinfo(1, "l").currentline + 1
        me.Backpack:Take("Wood", -1)
    end, "Take expects how many as its second value")
    at(err, line)
    actions.host(false)
    t.raises(function() me:Give("Wood") end, "only the host can give items. You are in someone else's game")
    t.raises(function() me:Take("Wood") end, "only the host can take items")
    t.raises(function() me.Backpack:Give("Wood") end, "only the host can give items")
    t.raises(function() me.Backpack:Take("Wood") end, "only the host can take items")
    t.eq(all_calls(), before, "the game was asked for nothing")
    t.eq(me:Count("Wood"), 1)
    actions.host(true)
    local wolf = instance.wrap(kit.creature().actor)
    t.raises(function() wolf:Give("Wood") end, "Give is not a member of BP_NPC_Wolf_Conifer_Character_C")
    possess(nil)
    t.raises(function() game.Me:Give("Wood") end, "there is no character right now, so Give cannot be called")
    t.raises(function() game.Me:Take("Wood") end, "there is no character right now, so Take cannot be called")
end)

t.test("with the item tables out of reach nothing is given, because the item cannot be checked", function()
    actions.host(true)
    local who = hero()
    local pack = who.instance.Backpack
    game.Data:Flush()
    frames(1)
    tables.hide("ItemsStatic", true)
    local before = all_calls()
    t.raises(function() pack:Give("Refined_Metal", 2) end,
        "Give: the game's item tables cannot be read right now, so 'Refined_Metal' cannot be checked")
    t.eq(all_calls(), before)
    t.eq(pack:Take("Fiber", 4), 4, "taking goes by what the inventory holds")
    tables.hide("ItemsStatic", false)
    pass(data.relist_seconds)
    t.eq(pack:Give("Refined_Metal", 2), 2, "the tables are back")
end)

t.test("through the whole suite no list was read past its end, nothing was used after its frame, nothing freed was touched", function()
    t.eq(actions.untried, 0, table.concat(actions.log, " | "))
    t.eq(actions.dropped, 0, "nothing was left on the ground")
    t.eq(fake.grown, 0, "an engine list was read one past its end")
    t.eq(fake.stale, 0, "something a read handed out was used in a later frame")
    t.eq(fake.misuse, 0, "an inventory was asked for what it does not have")
    t.eq(rawget(_G, "Enum_PropertyType"), nil, "the global UE4SS leaves after an enum read was taken away")
    for _, name in ipairs({ "stale", "grown", "crashes", "misuse", "unknown_names", "never_reads" }) do
        t.eq(tables[name], 0, "fake_tables." .. name)
    end
    t.eq(values.crashes, 0)
    t.eq(values.misuse, 0)
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(warnings(), 2, "the warning of the unreadable inventory, and the one of the item the game did not place")
    t.eq(#guard.errors(), 0, guard.errors()[1] and guard.errors()[1].trace)
end)

-- --------------------------------------------------------------------------------------------------------- cost

if arg and arg[1] == "cost" then
    local ok, problem = pcall(function()
        guard.suspend_watchdog(true)
        local perf = Wax.import("core.perf")
        local function each(rounds, body)
            local started = perf.now()
            for _ = 1, rounds do body() end
            return (perf.now() - started) / rounds * 1e6
        end
        local function asked_by(body)
            local before = fake.asked()
            body()
            return fake.asked() - before
        end
        local who = hero()
        local me = who.instance
        local pack = me.Backpack
        local as_read = asked_by(function() pack:Refresh() end)
        for slot = 1, 24 do fake.put(who.backpack, slot, "Stick", 12, { { fake.TRANSMUTABLE, 10000 } }, true) end
        local full = asked_by(function() pack:Refresh() end)
        for slot = 5, 24 do fake.take(who.backpack, slot) end
        pack:Refresh()
        pass(items.PACE)
        local look = asked_by(function() pack:Count("Wood") end)
        frames(1)
        local between = asked_by(function() pack:Count("Wood") end)
        me:Count("Wood")
        pass(items.PACE)
        local all_six = asked_by(function() me:Count("Wood") end)
        frames(1)
        local all_between = asked_by(function() me:Count("Wood") end)
        print(("values asked of the stand-in: the backpack as it was read on 2026-10-07 read whole %d, a backpack of 24 full "
            .. "stacks with 8 numbers each %d, one look a quarter second later %d, an ask between looks %d (the Instance's own check); "
            .. "a character's six inventories at a look %d, between looks %d"):format(as_read, full, look, between, all_six, all_between))

        local sink = 0
        local empty = each(200000, function() sink = sink + 1 end)
        local count = each(50000, function() sink = sink + pack:Count("Wood") end) - empty
        local carried = each(50000, function() sink = sink + me:Count("Wood") end) - empty
        local size = each(50000, function() sink = sink + pack.Size end) - empty
        local list = each(20000, function() sink = sink + #pack:List() end) - empty
        local facts = each(50000, function() sink = sink + game.Items:Get("Wood").MaxStack end) - empty
        local find = each(2000, function() sink = sink + #game.Items:Find("pick") end) - empty
        local whole = each(2000, function() pack:Refresh() end) - empty
        print(("cost on the stand-in, us, inside one frame: inventory:Count %.2f, character:Count %.2f, inventory.Size %.2f, "
            .. "List of 4 stacks %.2f, game.Items:Get of a kept item %.2f, Find over 16 items %.2f, a whole read of 24 slots %.2f")
            :format(count, carried, size, list, facts, find, whole))
        local stats = items.stats()
        print(("by the module's own count: %d looks, %d of them whole, %d slots read, %.2f us a look"):format(stats.looks, stats.walks,
            stats.slots, stats.look_us))
        assert(sink > 0)
        guard.suspend_watchdog(false)
    end)
    if not ok then print("the cost printout failed: " .. tostring(problem)) end
end

t.test("Resize adds and takes slots at the end, never a slot that holds something, and only for the host", function()
    actions.host(true)
    local who = hero()
    possess(who)
    local pack = who.instance.Backpack
    local size, adds, takes = pack.Size, calls("AddSlots"), calls("RemoveSlots")
    t.eq(pack:Resize(size + 20), size + 20)
    t.eq(pack.Size, size + 20, "it reads the new size in the same frame")
    t.eq(calls("AddSlots"), adds + 1)
    t.eq(pack:Resize(size + 20), size + 20, "the size it has asks the game nothing")
    t.eq(calls("AddSlots") + calls("RemoveSlots"), adds + takes + 1)
    fake.put(who.backpack, size + 5, "Wood", 3)
    local now, why = pack:Resize(size)
    t.eq(now, size + 5, "it stops at the last slot that holds something")
    t.ok(tostring(why):find(("slot %d holds something"):format(size + 5), 1, true), tostring(why))
    fake.take(who.backpack, size + 5)
    t.eq(pack:Resize(size), size)
    t.eq(actions.untried, 0)
    t.raises(function() pack:Resize(0) end, "Resize expects how many slots")
    t.raises(function() pack:Resize("many") end, "Resize expects how many slots")
    actions.host(false)
    t.raises(function() pack:Resize(size + 1) end, "only the host can resize an inventory")
    actions.host(true)
end)

t.finish("items")
