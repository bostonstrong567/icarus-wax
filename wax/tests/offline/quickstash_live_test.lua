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
    return { ToString = function() return name end }
end
fake.react.GetClass = function(self)
    local class = rawget(self, "__class") or "Widget"
    return { GetFName = function() return { ToString = function() return class end } end }
end
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
function Containers:Nearby(_, options)
    local out = { { Row = "Storage_Metal_Cupboard", Name = "Iron Cupboard", Kind = "storage", Distance = 5, Actor = { Raw = crate_actor },
        Inventories = { cupboard }, Fuel = {}, Inputs = nil, Accepts = function() return true end } }
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
function Containers:Kinds() return {} end
function Containers:Accepted(row) return row == "Kit_Stone_Furnace" and { metal_ore = "Metal_Ore" } or nil end

local game = {
    LocalPlayer = { Raw = controller },
    Me = { Exists = true, Backpack = backpack, Position = { X = 0, Y = 0, Z = 0 }, Raw = fake.new_object("me") },
    IsHost = false,
    MapChanged = signal(),
    Containers = Containers,
    Items = { Get = function(_, item) return { Name = item, DisplayName = item, MaxStack = 100 } end },
    Crafting = { IsTyping = function() return false end },
    Data = { Table = function() return { Row = function() return nil end } end },
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

local function open_crate()
    local screen = widget("UMG_Storage_C_1", "UMG_Storage_C")
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

-- The crafting hooks, worked out from the station: two players' stand-ins, each with a cargo animal of their own.
local function stand_in(name, address)
    local object = { __name = name }
    function object:GetAddress() return address end
    function object:IsValid() return true end
    function object:IsA(class) return (self.__class or "") == class end
    return object
end
t.test("the hooks hand a station the storages, benches and the crafting player's own animals around it, on any side", function()
    local hooks = {}
    local extras = {
        RegisterHook = function(path, fn) hooks[path] = fn return 1, 2 end,
        UnregisterHook = function() end,
    }
    local function actor(name, address, metres, class)
        local a = stand_in(name, address)
        a.__class = class
        a.Position = { X = metres * 100, Y = 0, Z = 0 }
        function a:K2_GetActorLocation() return self.Position end
        return a
    end
    local function inventory(name, address, owner, used, kind)
        local i = stand_in(name, address)
        i.Used, i.Kind = used, kind
        function i:GetOwner() return owner end
        return i
    end
    local state_a, state_b = stand_in("state A", 9001), stand_in("state B", 9002)
    local station = actor("furnace", 100, 0)
    local station_comp = stand_in("furnace.proc", 101)
    function station_comp:GetOwner() return station end
    station_comp.Inventory = inventory("furnace.input", 102, station, 2, "Input")
    local bench = actor("bench", 200, 8)
    local bench_comp = stand_in("bench.proc", 201)
    function bench_comp:GetOwner() return bench end
    bench_comp.Inventory = inventory("bench.input", 202, bench, 5, "Input")
    local crate = actor("crate", 300, 5, "BP_DeployableContainerBase_C")
    local crate_inventory = inventory("crate.inventory", 301, crate, 8, "Storage")
    local far_crate = actor("far crate", 350, 45, "BP_DeployableContainerBase_C")
    local far_inventory = inventory("far.inventory", 351, far_crate, 8, "Storage")
    local moa_a = actor("moa of A", 400, 4, "IcarusNPCCharacter")
    function moa_a:IsMountOwner(state) return state == state_a end
    local cargo_a = inventory("moa A cargo", 401, moa_a, 3, "Mount_Cargo")
    local moa_b = actor("moa of B", 500, 3, "IcarusNPCCharacter")
    function moa_b:IsMountOwner(state) return state == state_b end
    local cargo_b = inventory("moa B cargo", 501, moa_b, 3, "Mount_Cargo")
    local player_a = actor("player A", 600, 1, "IcarusPlayerCharacter")
    player_a.PlayerState = state_a
    local backpack_a = inventory("backpack A", 601, player_a, 6, "Backpack")
    local player_b = actor("player B", 700, 2, "IcarusPlayerCharacter")
    player_b.PlayerState = state_b
    local backpack_b = inventory("backpack B", 701, player_b, 6, "Backpack")
    local find_all = game.FindAll
    game.FindAll = function(_, class)
        if class == "ProcessingComponent" then return { station_comp, bench_comp } end
        if class == "Inventory" then
            return { station_comp.Inventory, bench_comp.Inventory, crate_inventory, far_inventory, cargo_a, cargo_b, backpack_a, backpack_b }
        end
        return {}
    end
    warned = {}
    local env, owner = load_mod(nil, true, extras)
    frames(3)
    t.eq(#warned, 0, table.concat(warned, " | "))
    local count = 0
    for _ in pairs(hooks) do count = count + 1 end
    t.eq(count, 7, "all seven crafting checks are hooked")
    local function craft(first)
        local list = { first }
        list.GetArrayNum = function(self) return #self end
        list.GetAddress = function() return 1 end
        local hook = hooks["/Script/Icarus.ProcessingComponent:CanQueueItem"]
        hook({ get = function() return station_comp end }, nil, { get = function() return list end })
        local names = {}
        for index = 2, #list do names[#names + 1] = list[index].__name end
        return table.concat(names, ", ")
    end
    t.eq(craft(backpack_a), "crate.inventory, bench.input, moa A cargo", "player A at the furnace: the crate, the bench, A's own moa; never the far crate, B's moa, anyone's backpack or the furnace's own input")
    now = now + 2
    t.eq(craft(backpack_b), "crate.inventory, bench.input, moa B cargo", "player B at the same furnace gets B's own moa instead")
    local _, _, supplied = env.quickstash.hooks()
    t.eq(supplied, 6, "six inventories handed over in all")
    game.FindAll = find_all
    for _, fn in ipairs(unloads) do fn("reload") end
    unloads = {}
    owner:destroy()
end)

t.finish("quickstash-live")
