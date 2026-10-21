-- Quick Stash against the fake engine, the way gui_test guards the library: the mod's own init.lua runs against stand-in
-- game screens (the main menu's inventory and crafting cards, a bench screen with player, device and fuel inventories),
-- a bench is closed and everything under it marked freed, and the test fails if the mod or gui\gamebutton touches a
-- freed widget afterwards. Run from the workspace root: tools\lua\lua54\lua.exe wax\tests\offline\quickstash_live_test.lua
local t = dofile("wax/tests/offline/harness.lua")
local fake = dofile("wax/tests/offline/fake_engine.lua")
local DIR = (arg and arg[1]) or "luamods/QuickStash/"      -- a staging copy of the mod can be tested before it goes live
fake.install()

local Wax = t.new_wax()
_G.Wax = Wax
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local log = Wax.import("core.log")
local sched = Wax.import("core.sched")
Wax.log, Wax.guard, Wax.sched = log, guard, sched
Wax.mods = { list = function() return {} end, request_reload = function() end, request_sync = function() end, get = function() return nil end }
Wax.import("core.storage").directory = nil

-- the game's screens: fake objects with children, classes, names and visibility the mod reads
local function widget(name, class)
    local self = fake.new_object(name)
    rawset(self, "__class", class or "Widget")
    rawset(self, "__children", {})
    rawset(self, "__visibility", 0)
    return self
end
-- a widget answers IsA for its own class, as the engine does for "/Script/UMG.Overlay"
fake.react.IsA = function(self, class)
    local wanted = tostring(class):match("[^.]+$") or tostring(class)
    return (rawget(self, "__class") or "") == wanted
end
local function add_child(parent, child)
    local children = rawget(parent, "__children")
    if not children then
        children = {}
        rawset(parent, "__children", children)
    end
    children[#children + 1] = child
    rawset(child, "__parent", parent)
    return fake.new_object("slot")
end
fake.react.GetChildrenCount = function(self) return #(rawget(self, "__children") or {}) end
fake.react.GetChildAt = function(self, index) return (rawget(self, "__children") or {})[index + 1] end
fake.react.GetParent = function(self) return rawget(self, "__parent") end
fake.react.GetOuter = function(self) return rawget(self, "__outer") or self end
fake.react.GetFullName = function(self) return "Widget /Engine/Transient." .. tostring(rawget(self, "__name")) end
fake.react.GetVisibility = function(self) return rawget(self, "__visibility") or 0 end
fake.react.GetFName = function(self)
    local name = tostring(rawget(self, "__name"))
    name = name:match(":(.+)$") or name
    local index = rawget(self, "__address") or 0
    return { ToString = function() return name end, GetComparisonIndex = function() return index end }
end
fake.react.GetClass = function(self)
    local class = rawget(self, "__class") or "Widget"
    -- enough of a class for Wax to wrap the object: a name, an address, a full name, no parent, no members
    return { GetFName = function() return { ToString = function() return class end, GetComparisonIndex = function() return 1 end } end,
        GetAddress = function() return 1 end, GetFullName = function() return "Class /Script/Icarus." .. class end,
        IsValid = function() return true end, GetSuperStruct = function() return { IsValid = function() return false end } end,
        ForEachFunction = function() end, ForEachProperty = function() end }
end
fake.react.HasAnyInternalFlags = function() return false end
fake.react.AddChildToHorizontalBox = function(self, child) return add_child(self, child) end
fake.react.AddChildToOverlay = function(self, child) return add_child(self, child) end
fake.react.AddChildToVerticalBox = function(self, child) return add_child(self, child) end
fake.react.SetContent = function(self, child)
    rawset(self, "__children", { child })
    rawset(child, "__parent", self)
    return fake.new_object("slot")
end
fake.react.RemoveFromParent = function(self)
    local parent = rawget(self, "__parent")
    if not parent then return end
    local children = rawget(parent, "__children") or {}
    for index = #children, 1, -1 do
        if rawequal(children[index], self) then table.remove(children, index) end
    end
    rawset(self, "__parent", nil)
end
fake.react.IsInputKeyDown = function(_, key) return fake.keys[key.KeyName] == true end
-- the engine's weak pointer: it knows when its object was freed, which is what gamebutton leans on
-- a weak pointer is a value Lua owns, never freed with the screen: a plain table that answers a null object for a freed source
local gone = fake.new_object("gone")
rawset(gone, "__address", 0)
local WEAK = {}
WEAK.__index = WEAK
function WEAK:Get()
    local source = rawget(self, "__source")
    if source == nil or rawget(source, "__dead") then return gone end
    return source
end
function WEAK:GetWeakPtr() return self end
function WEAK:IsValid() return true end
fake.react.Conv_ObjectToSoftObjectReference = function(_, object) return setmetatable({ __source = object }, WEAK) end

-- a Sort control as the game builds it: the model button, the row it sits in, the Type box beside it
local backpack_raw = fake.new_object("Backpack")
local function sort_control(name, sorts_backpack)
    local sort = widget(name, "UMG_Sort_C")
    if sorts_backpack ~= false then sort.Inventory = backpack_raw end
    local row = widget(name .. ".row", "HorizontalBox")
    local combo_box = widget(name .. ".combo_box", "SizeBox")
    local combo = widget(name .. ".combo", "CustomComboBox")
    add_child(row, combo_box)
    fake.react.SetContent(combo_box, combo)
    local outer = widget(name .. ".outer", "SizeBox")
    add_child(row, outer)
    local model = widget(name .. ".SortButton", "UMG_BasicButton_2_C")
    fake.react.SetContent(outer, model)
    sort.ComboBox = combo
    sort.SortButton = model
    sort.HorizontalBox_0 = row
    add_child(sort, row)
    return sort, row
end

local function inventory_card(name)
    local card = widget(name, "UserWidget")
    local sort, row = sort_control(name .. ".UMG_Sort")
    card.UMG_Sort = sort
    local grid = widget(name .. ".UMG_Inventory", "UMG_Inventory_C")
    grid.HighlightFlagOverlay = widget(name .. ".overlay", "Overlay")
    card.UMG_Inventory = grid
    return card, row, sort
end

local holder = widget("Menus", "Overlay")
local main = widget("UMG_MainMenu_C_1", "UMG_MainMenu_C")
add_child(holder, main)
rawset(main, "__visibility", 1)
local inventory_card_w, inventory_row, inventory_sort = inventory_card("UMG_MainInventory")
local crafting_card_w, crafting_row, crafting_sort = inventory_card("UMG_Crafting")
main.UMG_MainInventory = inventory_card_w
main.UMG_Crafting = crafting_card_w
-- the crafting card's recipe list with the game's own search box, the model the mod's list boxes copy
local recipe_list = widget("UMG_Crafting.UMG_RecipeList", "UMG_RecipeList_C")
local recipe_search = widget("UMG_Crafting.UMG_RecipeList.Search", "EditableTextBox")
local recipe_root = widget("UMG_Crafting.UMG_RecipeList.root", "VerticalBox")
add_child(recipe_root, recipe_search)
recipe_list.WidgetTree = fake.new_object("UMG_Crafting.UMG_RecipeList.tree")
recipe_list.WidgetTree.RootWidget = recipe_root
crafting_card_w.UMG_RecipeList = recipe_list
-- the main menu's tree holds its two cards' Sort controls, as the game's does
local main_root = widget("main.root", "VerticalBox")
add_child(main_root, inventory_sort)
add_child(main_root, crafting_sort)
main.WidgetTree = fake.new_object("main.tree")
main.WidgetTree.RootWidget = main_root

local controller = fake.new_object("PlayerController")
controller.UserInterface = fake.new_object("UserInterface")
controller.UserInterface.Menus = holder
controller.bShowMouseCursor = true

-- the world as the mod asks it: one bench in range, with stacks of ore in a cupboard
local linked_actor = nil
local crate_actor = fake.new_object("BP_Wood_Crate_Small_C_1")
local function stacks_of(list)
    local out = {}
    for index, pair in ipairs(list) do out[index] = { Item = pair[1], Count = pair[2], Slot = index } end
    return out
end
local function wax_inventory(name, size, stacks)
    local raw = fake.new_object(name)
    return { Raw = raw, Size = size, Used = #stacks, Kind = name, List = function() return stacks_of(stacks) end,
        Count = function(_, item) local n = 0 for _, pair in ipairs(stacks) do if pair[1]:lower() == item:lower() then n = n + pair[2] end end return n end,
        Refresh = function() end }
end
local cupboard = wax_inventory("Storage_Metal_Cupboard", 50, { { "Metal_Ore", 40 }, { "Wood", 10 } })
local inputs = wax_inventory("Processor_T3", 36, {})
local fuel = wax_inventory("Fuel_Combustible", 1, {})
local backpack = wax_inventory("Backpack", 30, { { "Stick", 20 } })
backpack.Raw = backpack_raw
local signal = function() return sched.Signal.new("test") end
local notices = {}
local Containers = { Changed = signal() }
local animals = {}      -- cargo records a scenario lists; asking one whether it is owned touches its animal
local extra_records = {}    -- structures a scenario lists beside the cupboard
function Containers:Nearby(_, options)
    local out = { { Row = "Storage_Metal_Cupboard", Name = "Iron Cupboard", Kind = "storage", Distance = 5, Actor = { Raw = crate_actor },
        Inventories = { cupboard }, Fuel = {}, Inputs = nil, Accepts = function() return true end } }
    for _, animal in ipairs(animals) do out[#out + 1] = animal end
    for _, record in ipairs(extra_records) do out[#out + 1] = record end
    if linked_actor then
        table.insert(out, 1, { Row = "Kit_Stone_Furnace", Name = "Stone Furnace", Kind = "station", Distance = 3, Actor = { Raw = linked_actor },
            Inventories = {}, Fuel = { fuel }, Inputs = inputs, Accepts = function(_, item) return item:lower() == "metal_ore" end })
    end
    if options and options.kind then
        local kept = {}
        for _, record in ipairs(out) do if record.Kind == options.kind then kept[#kept + 1] = record end end
        return kept
    end
    return out
end
function Containers:Around(_, range, options) return Containers:Nearby(range, options) end
function Containers:Totals(inventory)
    local totals = {}
    local ok, stacks = pcall(function() return inventory:List() end)
    -- a fake object answers every index with another object, so only a plain list of stacks is walked
    if not ok or type(stacks) ~= "table" or rawget(stacks, "__name") ~= nil then return totals end
    for _, stack in ipairs(stacks) do
        local key = tostring(stack.Item):lower()
        totals[key] = (totals[key] or 0) + (tonumber(stack.Count) or 0)
    end
    return totals
end
function Containers:Kinds() return {} end
function Containers:Count() return 1 + #extra_records end
function Containers:Accepted(row) return row == "Kit_Stone_Furnace" and { metal_ore = "Metal_Ore" } or nil end

local game = {
    LocalPlayer = { Raw = controller },
    Me = { Exists = true, Backpack = backpack, Position = { X = 0, Y = 0, Z = 0 }, Raw = fake.new_object("me") },
    IsHost = false,
    MapChanged = signal(),
    Containers = Containers,
    Items = { Get = function(_, item) return { Name = item, DisplayName = item, MaxStack = 100 } end },
    Crafting = { IsTyping = function() return false end },
    Data = { Table = function() return { Row = function() return nil end, Load = function() return {} end } end },
    Highlight = { Look = function() return {} end, Add = function() return { Remove = function() end } end },
    FindAll = function() return {} end,
    wrap = function(raw) return { Raw = raw, Size = 1, Used = 0, List = function() return {} end } end,
}
Wax.game = game
local ui = Wax.import("gui.init")
ui.start()
Wax.ui = ui
ui.Theme().animation = 0
local notify = ui.Notify
ui.Notify = function(text, options) notices[#notices + 1] = text return notify(text, options) end

-- the mod's environment, as the loader makes it, over the real GUI
local unloads = {}
local warned = {}
local test_log = {}
for _, level in ipairs({ "info", "warn", "error" }) do
    test_log[level] = function(_, text, ...)
        local ok, line = pcall(string.format, text, ...)
        if level ~= "info" then warned[#warned + 1] = level .. ": " .. (ok and line or text) end
    end
end
local function load_mod(handles, without_ui, extras)
    Wax.handle = handles
    local env
    env = setmetatable({
        game = game, ui = not without_ui and ui or nil, task = sched.task, Signal = sched.Signal, log = test_log, print = function() end,
        storage = { Load = function(_, defaults) return defaults or {} end, Save = function() end },
        persist = function() return {} end,
        mod = { id = "QuickStash", name = "Quick Stash", OnUnload = function(fn) unloads[#unloads + 1] = fn return function() end end },
        raw = _G,
    }, { __index = _G })
    for key, value in pairs(extras or {}) do env[key] = value end
    env._G = env
    env.require = function(name)
        local chunk = assert(loadfile(DIR .. name .. ".lua", "t", env))
        return chunk()
    end
    local chunk = assert(loadfile(DIR .. "init.lua", "t", env))
    local owner = scope.new("QuickStash")
    scope.run(owner, chunk)
    return env, owner
end

-- frames of 16 ms on a clock the test owns, so a task that waits a frame is resumed every frame
local now = 1000
sched.clock = function() return now end
local function frames(count)
    for _ = 1, count or 1 do
        now = now + 0.016
        sched.step()
        ui.step()
    end
end

local function buttons_in(row)
    local count = 0
    for _, child in ipairs(rawget(row, "__children")) do
        local name = tostring(rawget(child, "__name"))
        if name:find("WaxGameButton_", 1, true) then count = count + 1 end
    end
    return count
end

-- a bench screen as the game makes one: device inventory with its Sort, a fuel box, the player's own card in its tree
local function open_bench(number)
    local screen = widget("UMG_Processor_C_" .. number, "UMG_Processor_C")
    linked_actor = fake.new_object("BP_StoneFurnace_C_" .. number)
    screen.LinkedActor = linked_actor
    local device = widget("UMG_DeviceInventory", "UMG_DeviceInventory_C")
    local device_sort, device_row = sort_control("UMG_DeviceInventory.UMG_Sort", false)
    device_sort.Inventory = inputs.Raw
    device.UMG_Sort = device_sort
    device.InventoryOverlay = widget("InventoryOverlay", "Overlay")
    screen.UMG_DeviceInventory = device
    local fuel_box = widget("UMG_FuelInventory", "UMG_FuelInventory_C")
    fuel_box.UMG_Inventory = widget("fuel.UMG_Inventory", "UMG_Inventory_C")
    fuel_box.UMG_Inventory.Inventory = fuel.Raw
    screen.UMG_FuelInventory = fuel_box
    local player = widget("Player", "UMG_Inventory_C")
    player.HighlightFlagOverlay = widget("Player.overlay", "Overlay")
    screen.Player = player
    local root = widget("root", "VerticalBox")
    local player_sort, player_row = sort_control("Player.UMG_Sort")
    add_child(root, device_sort)
    add_child(root, player_sort)
    screen.WidgetTree = fake.new_object("tree")
    screen.WidgetTree.RootWidget = root
    add_child(holder, screen)
    return screen, device_row, player_row, device_sort
end

local function open_crate(name)
    local screen = widget(name or "UMG_Storage_C_1", "UMG_Storage_C")
    screen.LinkedActor = crate_actor
    local device = widget("UMG_DeviceInventory", "UMG_DeviceInventory_C")
    local device_sort, device_row = sort_control("UMG_DeviceInventory.UMG_Sort", false)
    device_sort.Inventory = cupboard.Raw
    device.UMG_Sort = device_sort
    device.InventoryOverlay = widget("InventoryOverlay", "Overlay")
    screen.UMG_DeviceInventory = device
    local player = widget("Player", "UMG_Inventory_C")
    player.HighlightFlagOverlay = widget("Player.overlay", "Overlay")
    screen.Player = player
    local root = widget("root", "VerticalBox")
    local player_sort, player_row = sort_control("Player.UMG_Sort")
    add_child(root, device_sort)
    add_child(root, player_sort)
    screen.WidgetTree = fake.new_object("tree")
    screen.WidgetTree.RootWidget = root
    add_child(holder, screen)
    return screen, device_row, player_row
end

local function close_bench(screen)
    fake.react.RemoveFromParent(screen)
    linked_actor = nil
end

local function run_scenario(label, handles)
    fake.dead_touches, fake.dead_last, fake.dead_where = 0, nil, nil
    local env, owner = load_mod(handles)
    env.quickstash.picker().prepare()
    frames(2)
    if os.getenv("QS_DEBUG") then
        for _, child in ipairs(rawget(inventory_row, "__children")) do print("row child", rawget(child, "__name")) end
        print("quickstash table", env.quickstash ~= nil, "warned", #warned)
    end
    t.eq(buttons_in(inventory_row), 2, label .. ": STASH and PULL on the inventory card; " .. table.concat(warned, " | "))
    t.eq(buttons_in(crafting_row), 3, label .. ": STASH, PULL and the list on the crafting card")

    -- a bench opens: its device header gets PULL and FUEL, its player card STASH and PULL, in the frame the screen is seen
    local before = fake.mark()
    local screen, device_row, player_row, device_sort = open_bench(1)
    ui.GameScreenChanged:Fire("UMG_Processor_C", nil)
    frames(3)
    t.eq(buttons_in(device_row), 2, label .. ": PULL and FUEL on the device header")
    t.eq(buttons_in(player_row), 2, label .. ": STASH and PULL on the bench's player card")

    -- a right click on PULL opens the list under the header, with the spread tick first
    local pull_button = nil
    for _, child in ipairs(rawget(device_row, "__children")) do
        if tostring(rawget(child, "__name")):find("WaxGameButton_", 1, true) and not pull_button then pull_button = child end
    end
    local press = rawget(rawget(rawget(pull_button, "__children")[1], "__children")[1], "__children")[1]
    press = rawget(press, "__children")[1]           -- outer > overlay > inner > blur > press
    fake.hover(press)
    frames(2)
    fake.keys.RightMouseButton = true
    if os.getenv("QS_DEBUG") then
        local pulling = env.quickstash.pulling()
        print("before right click: key down", ui.IsKeyDown("RightMouseButton"), "buttons", pulling.buttons ~= nil, "busy", pulling.busy_with_screen(),
            "pull over", pulling.buttons and pulling.buttons.pull and pulling.buttons.pull.over, "warned", table.concat(warned, " | "))
    end
    frames(1)
    fake.keys.RightMouseButton = false
    frames(2)
    local picker = env.quickstash and env.quickstash.picker and env.quickstash.picker() or nil
    t.ok(picker and picker.is_open(), label .. ": the list opened on the right click")
    fake.hover(nil)

    -- the bench closes. With handles the game may free it the same frame; without, nothing of ours is left on it a
    -- frame later, which is before the game's collection
    close_bench(screen)
    ui.GameScreenChanged:Fire(nil, nil)
    if handles then
        fake.free(before, fake.mark())
    else
        frames(1)
        fake.free(before, fake.mark())
    end
    frames(20)
    t.eq(fake.dead_touches, 0, label .. ": nothing of the closed bench was touched: " .. tostring(fake.dead_last) .. "\n" .. tostring(fake.dead_where))
    t.ok(not picker.is_open(), label .. ": the list is gone with the screen")

    -- the Wax menu opens, a new bench comes, the map changes, the mod unloads: still nothing freed is touched
    ui.Open()
    frames(3)
    local mark2 = fake.mark()
    local screen2, device_row2 = open_bench(2)
    ui.GameScreenChanged:Fire("UMG_Processor_C", nil)
    frames(3)
    t.eq(buttons_in(device_row2), 2, label .. ": the new bench got its buttons")
    close_bench(screen2)
    ui.GameScreenChanged:Fire(nil, nil)
    if not handles then frames(1) end
    fake.free(mark2, fake.mark())
    frames(3)
    local mark3 = fake.mark()
    local crate, crate_device_row, crate_player_row = open_crate()
    ui.GameScreenChanged:Fire("UMG_Storage_C", nil)
    frames(3)
    t.eq(buttons_in(crate_device_row), 1, label .. ": PULL alone on a storage container's device header")
    t.eq(buttons_in(crate_player_row), 2, label .. ": STASH and PULL on the container screen's player card")
    close_bench(crate)
    ui.GameScreenChanged:Fire(nil, nil)
    if not handles then frames(1) end
    fake.free(mark3, fake.mark())
    frames(5)
    -- a ranching station: an animal is listed as cargo; its list is opened, the animal is freed, the list is opened again
    local before_animal = fake.mark()
    local animal = fake.new_object("Moa_1")
    animals[1] = { Row = "cargo:Mount_Moa", Name = "Cargo: Moa", Kind = "cargo", Distance = 4, Actor = { Raw = animal },
        Inventories = { cupboard }, Fuel = {}, Inputs = nil, Accepts = function() return true end,
        OwnedBy = function(self, state) return self.Actor.Raw:IsMountOwner(state) == true end }
    local animal_made = fake.mark()
    for _ = 1, 2 do
        local ranch, ranch_row = open_crate("UMG_Ranching_C_1")
        ui.GameScreenChanged:Fire("UMG_Ranching_C", nil)
        frames(3)
        t.eq(buttons_in(ranch_row), 1, label .. ": PULL on the ranching station's device header")
        local pulls_now = env.quickstash.pulling()
        fake.hover(pulls_now.buttons and pulls_now.buttons.pull and pulls_now.buttons.pull.button or nil)
        frames(1)
        fake.keys.RightMouseButton = true
        frames(1)
        fake.keys.RightMouseButton = false
        frames(2)
        fake.hover(nil)
        close_bench(ranch)
        ui.GameScreenChanged:Fire(nil, nil)
        frames(2)
        -- the animal is gone before the second look
        fake.free(before_animal, animal_made)
    end
    animals[1] = nil
    t.eq(fake.dead_touches, 0, label .. ": a freed animal was never touched: " .. tostring(fake.dead_last))
    t.eq(fake.dead_touches, 0, label .. ": nothing of the closed container screen was touched: " .. tostring(fake.dead_last))
    game.MapChanged:Fire("Terrain_019")
    frames(5)
    t.eq(fake.dead_touches, 0, label .. ": nothing freed touched after the map change: " .. tostring(fake.dead_last))
    for _, fn in ipairs(unloads) do fn("reload") end
    unloads = {}
    owner:destroy()
    frames(2)
    t.eq(fake.dead_touches, 0, label .. ": nothing freed touched on unload: " .. tostring(fake.dead_last))
    -- the main menu's cards keep nothing of ours after the unload
    t.eq(buttons_in(inventory_row), 0, label .. ": the inventory card is clean after the unload")
    t.eq(buttons_in(crafting_row), 0, label .. ": the crafting card is clean after the unload")
end

t.test("without Wax.handle: nothing of a closed bench is touched a frame after it closed", function()
    run_scenario("no handles", nil)
end)

t.test("with Wax.handle: nothing of a closed bench is touched even when it is freed the same frame", function()
    local handles = {
        take = function(object) return { source = object } end,
        alive = function(handle) return handle ~= nil and not rawget(handle.source, "__dead") end,
    }
    run_scenario("handles", handles)
end)

t.test("on a dedicated server there is no ui: the mod loads, hooks and sums only", function()
    warned = {}
    local env, owner = load_mod(nil, true)
    frames(3)
    t.eq(#warned, 0, table.concat(warned, " | "))
    t.ok(env.quickstash and env.quickstash.hooks, "the console table is there")
    t.eq(buttons_in(inventory_row), 0, "no buttons without a screen")
    for _, fn in ipairs(unloads) do fn("reload") end
    unloads = {}
    owner:destroy()
end)

-- The crafting side without a single write into the game's lists: the checks are answered through their return
-- value with what is nearby added, and a craft first moves what the backpack lacks into it with the game's own call.
local function stand_in(name, address)
    local object = { __name = name }
    function object:GetAddress() return address end
    function object:IsValid() return true end
    function object:IsA(class) return (self.__class or "") == class end
    return object
end
t.test("the crafting checks are answered from the containers and a craft moves its inputs into the backpack first", function()
    local function actor(name, address, metres, class)
        local a = stand_in(name, address)
        a.__class = class
        a.Position = { X = metres * 100, Y = 0, Z = 0 }
        function a:K2_GetActorLocation() return self.Position end
        return a
    end
    local function inventory(name, address, owner, kind, counts, stacks, size)
        local i = stand_in(name, address)
        i.Kind = kind
        i.Used = #stacks
        i.counts = counts
        function i:GetOwner() return owner end
        function i:FindItemCountByType(handle) return self.counts[tostring(handle.RowName):lower()] or 0 end
        -- a stand-in is already a table, so the mod reads it as it would the wrapped inventory
        i.Size = size or 10
        function i:List() return stacks end
        return i
    end
    local state_a = stand_in("state A", 9001)
    local furnace = actor("furnace", 100, 0)
    -- the hooked component is an engine object (Wax wraps it for the listener); the rest are plain stand-ins
    local furnace_comp = fake.new_object("furnace.proc")
    furnace_comp.GetOwner = function() return furnace end
    furnace_comp.Inventory = inventory("furnace.input", 102, furnace, "Input", {}, { { Item = "Ore", Count = 2, Slot = 1 } })
    local crate = actor("crate", 300, 5, "BP_DeployableContainerBase_C")
    local crate_inventory = inventory("crate.inventory", 301, crate, "Storage", { wood = 100, fiber = 30 },
        { { Item = "Wood", Count = 100, Slot = 1 }, { Item = "Fiber", Count = 30, Slot = 2 } })
    local player = actor("player A", 600, 1, "IcarusPlayerCharacter")
    player.PlayerState = state_a
    local shifted = {}
    player.Controller = stand_in("controller A", 601)
    function player.Controller:OnServer_ShiftItem(from, from_slot, to, to_slot, amount)
        shifted[#shifted + 1] = { from = from.__name, from_slot = from_slot, to = to.__name, to_slot = to_slot, amount = amount }
    end
    local backpack = inventory("backpack A", 602, player, "Backpack", { wood = 5 }, { { Item = "Wood", Count = 5, Slot = 1 } }, 4)
    backpack.Raw = backpack
    player.Backpack = backpack
    crate_inventory.Raw = crate_inventory
    -- what game.Containers answers around the furnace: the crate, and the furnace itself (its own input never counts)
    extra_records[1] = { Row = "Storage_Crate", Name = "Crate", Kind = "storage", Distance = 5, Actor = { Raw = crate },
        Inventories = { crate_inventory }, Fuel = {}, Inputs = nil, Accepts = function() return true end }
    extra_records[2] = { Row = "Kit_Stone_Furnace", Name = "Furnace", Kind = "station", Distance = 0, Actor = { Raw = furnace },
        Inventories = {}, Fuel = {}, Inputs = furnace_comp.Inventory, Accepts = function() return true end }
    local find_all = game.FindAll
    game.FindAll = function(_, class)
        if class == "ProcessingComponent" then return { furnace_comp } end
        if class == "Inventory" then return { furnace_comp.Inventory, crate_inventory, backpack } end
        return {}
    end
    local data_was = game.Data
    local wood_floor = { Inputs = { { Element = { RowName = "Wood" }, Count = 20 }, { Element = { RowName = "Fiber" }, Count = 3 } } }
    game.Data = { Table = function(_, name)
        return {
            Row = function(_, row) if name == "ProcessorRecipes" and row == "Wood_Floor" then return wood_floor end return nil end,
            Load = function() if name == "ProcessorRecipes" then return { Wood_Floor = wood_floor } end return {} end,
        }
    end }
    warned = {}
    local env, owner = load_mod(nil, true, { FName = function(name) return name end })
    frames(3)
    t.eq(#warned, 0, table.concat(warned, " | "))
    local _, installed = env.quickstash.hooks()
    t.eq(installed, 4, "three checks answered after the fact, one craft caught before it")
    -- Wax's one registration per function: its entries before (fn) and after (after) the game's function
    local slots = rawget(_G, "WaxHooks").slots
    local function before(path) return slots[path] and slots[path].fn end
    local function after(path) return slots[path] and slots[path].after end
    t.ok(after("/Script/Icarus.ProcessingComponent:CanSatisfyRecipeInput"), "CanSatisfyRecipeInput is answered")
    t.ok(after("/Script/Icarus.ProcessingComponent:GetMaxCraftableStack"), "GetMaxCraftableStack is answered")
    t.ok(after("/Script/Icarus.ProcessingComponent:CanQueueItem"), "CanQueueItem is answered")
    t.ok(before("/Script/Icarus.ProcessingComponent:OnServer_AddProcessingRecipe"), "OnServer_AddProcessingRecipe is caught before it runs")
    local ctx = { get = function() return furnace_comp end }
    -- the return value as UE4SS hands it: get reads the game's answer, set is what Wax writes back
    local function ret(value)
        local r = { value = value, written = nil }
        function r:get() return self.value end
        function r:set(new) self.written = new end
        return r
    end
    local function answered(path, r, ...)
        -- as the engine does: the entry before the function first (it counts the parameters), then the one after
        before(path)(ctx, ...)
        local given = after(path)(ctx, r, ...)
        if r.written ~= nil then return r.written end
        return given
    end
    local wood = { Element = { RowName = "Wood" }, Count = 20 }
    local stone = { Element = { RowName = "Stone" }, Count = 20 }
    local satisfy = "/Script/Icarus.ProcessingComponent:CanSatisfyRecipeInput"
    t.eq(answered(satisfy, ret(false), wood, 1, nil, 5), true, "15 short, 100 nearby: the answer becomes true")
    t.eq(answered(satisfy, ret(false), stone, 1, nil, 5), nil, "nothing nearby: the game's answer stands")
    t.eq(answered(satisfy, ret(true), wood, 1, nil, 50), nil, "a yes is left alone")
    local most = "/Script/Icarus.ProcessingComponent:GetMaxCraftableStack"
    local recipe = { RowName = "Wood_Floor" }
    t.eq(answered(most, ret(0), recipe, nil, player), 5, "the recipes were read in a task when the hooks went in: wood 5 + 100 over 20, fiber 0 + 30 over 3, five crafts")
    t.eq(answered(most, ret(7), recipe, nil, player), nil, "the game's larger answer stands")
    local queue = "/Script/Icarus.ProcessingComponent:CanQueueItem"
    local function order(crafts) return { CraftingPlayer = player, Recipe = recipe, CraftCount = crafts } end
    t.eq(answered(queue, ret(false), order(1)), true, "one craft: the button comes on")
    t.eq(answered(queue, ret(false), order(6)), nil, "six crafts need 120 wood: the game's no stands")
    t.eq(answered(queue, ret(true), order(1)), nil, "a yes is left alone")
    -- the craft: before the game queues it, the 15 wood and 3 fiber the backpack lacks come in with the game's own transfer
    before("/Script/Icarus.ProcessingComponent:OnServer_AddProcessingRecipe")(ctx, recipe, 1, nil, player)
    t.eq(#shifted, 3, table.concat((function() local out = {} for _, m in ipairs(shifted) do out[#out + 1] = m.amount .. " " .. m.from .. ">" .. m.to end return out end)(), ", "))
    t.eq(shifted[1].amount, 10, "wood: the cupboard's 10 first (nearest storage, same distance, listed first)")
    t.eq(shifted[1].from, "Storage_Metal_Cupboard")
    t.eq(shifted[1].from_slot, 1, "the cupboard's wood is its second slot: slots are handed to the game from 0")
    t.eq(shifted[1].to_slot, 0, "into the backpack's own wood stack")
    t.eq(shifted[2].amount, 5, "wood: the last 5 of the 15 short out of the crate")
    t.eq(shifted[2].from, "crate.inventory")
    t.eq(shifted[3].amount, 3, "fiber: all three")
    t.eq(shifted[3].to_slot, 1, "into the first empty slot")
    local stats = env.quickstash.craft_stats()
    t.eq(stats.moved, 18)
    t.eq(stats.answered, 3)
    t.eq(stats.failed, 0)
    extra_records[1], extra_records[2] = nil, nil
    game.FindAll, game.Data = find_all, data_was
    for _, fn in ipairs(unloads) do fn("reload") end
    unloads = {}
    owner:destroy()
end)

-- One mod for every way the game is played: what starts under each kind Wax reads.
t.test("the mod chooses what runs from Wax's mode: server, host, single player, client", function()
    local cases = {
        { kind = "server", IsAuthority = true, HasScreen = false, screens = false, bring_in = true, notice = false },
        { kind = "host", IsAuthority = true, HasScreen = true, screens = true, bring_in = true, notice = false },
        { kind = "single", IsAuthority = true, HasScreen = true, screens = true, bring_in = true, notice = false },
        { kind = "client", IsAuthority = false, HasScreen = true, screens = true, bring_in = false, notice = true },
    }
    local mode_was = Wax.mode
    for _, case in ipairs(cases) do
        Wax.mode = { kind = case.kind, IsAuthority = case.IsAuthority, HasScreen = case.HasScreen, IsServer = case.kind == "server" }
        warned = {}
        local env, owner = load_mod(nil, not case.HasScreen)
        frames(3)
        t.eq(#warned, 0, case.kind .. ": " .. table.concat(warned, " | "))
        local got = env.quickstash.mode()
        t.eq(got.kind, case.kind)
        t.eq(got.screens, case.screens, case.kind .. ": screens")
        t.eq(got.bring_in, case.bring_in, case.kind .. ": the bring-in")
        t.eq(got.notice, case.notice, case.kind .. ": the notice")
        t.eq(got.answers, true, case.kind .. ": the crafting checks are answered")
        t.eq(got.hooks, 4, case.kind .. ": four hooks")
        t.eq(buttons_in(inventory_row) > 0, case.screens, case.kind .. ": card buttons only with a screen")
        for _, fn in ipairs(unloads) do fn("reload") end
        unloads = {}
        owner:destroy()
        frames(2)
    end
    Wax.mode = mode_was
end)

t.finish("quickstash-live")
