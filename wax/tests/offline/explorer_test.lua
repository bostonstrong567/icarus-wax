-- Offline tests for the Explorer: its list of the world, the Lua it writes, what it reads and writes, and the page in a window.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\explorer_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local fake = dofile("wax/tests/offline/fake_engine.lua")
local world = dofile("wax/tests/offline/fake_world.lua")
fake.install()
local interface_object = StaticFindObject
world.install()
world.as_userdata()

-- The interface asks for its classes, libraries and fonts; everything else is the world's.
function StaticFindObject(path)
    local found = world.static[path]
    if found then return found end
    if path:find("^/Script/UMG%.") or path:find("Default__", 1, true) or path:find("Fonts", 1, true) then return interface_object(path) end
    return world.INVALID
end

function FindFirstOf(class_name)
    if class_name == "Engine" then return world.engine end
    for _, actor in ipairs(world.actors) do
        local class = rawget(actor, "__class")
        while class do
            if rawget(class, "__name") == class_name then return actor end
            class = rawget(class, "__super")
        end
    end
    return world.INVALID
end

-- Engine text: reading a text property through an Instance gives a string, as in the game.
local TEXT = { __index = { ToString = function(self) return rawget(self, "__text") end, type = function() return "FText" end } }
function FText(text) return setmetatable({ __props = {}, __text = text }, TEXT) end

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)

-- A value of a kind the Explorer must never read: looking at it in any way is counted.
local trapped = 0
local trap = setmetatable({}, { __index = function()
    trapped = trapped + 1
    error("a value that is never to be read was read")
end })

local object = world.class("/Script/CoreUObject.Object")
local actor_class = world.class("/Script/Engine.Actor", object,
    { Tags = { "ArrayProperty", inner = "NameProperty" }, bHidden = "BoolProperty" },
    { K2_GetActorLocation = {}, SetActorHiddenInGame = { { "bNewHidden", "BoolProperty" } } })
local world_class = world.class("/Script/Engine.World", object, { TimeSeconds = "FloatProperty" })
local level_class = world.class("/Script/Engine.Level", object)
local component_class = world.class("/Script/Engine.ActorComponent", object, { bIsActive = "BoolProperty" })
local scene_class = world.class("/Script/Engine.SceneComponent", component_class,
    { RelativeLocation = { "StructProperty", struct = "Vector" } })
local stats_class = world.class("/Script/Icarus.IcarusStatContainer", component_class, { Oxygen = "IntProperty" })
local state_class = world.class("/Script/Icarus.ActorState", component_class, { Health = "IntProperty" })
local pawn_class = world.class("/Script/Engine.Pawn", actor_class, { PlayerState = "ObjectProperty" })
local player_class = world.class("/Script/Icarus.IcarusPlayerCharacter", pawn_class, {
    Health = "FloatProperty", Stamina = "IntProperty", bIsCrouched = "BoolProperty", Mode = "EnumProperty", Flags = "ByteProperty",
    Nickname = "StrProperty", Title = "TextProperty", Tribe = "NameProperty", Name = "StrProperty",
    ["Stat Container"] = "ObjectProperty", Mesh = "ObjectProperty", Rival = "ObjectProperty",
    Spot = { "StructProperty", struct = "Vector" }, Tint = { "StructProperty", struct = "Color" },
    Aim = { "StructProperty", struct = "Rotator" }, Glow = { "StructProperty", struct = "LinearColor" },
    Reach = { "StructProperty", struct = "Vector2D" }, Session = { "StructProperty", struct = "IcarusSession" },
    Carried = { "ArrayProperty", inner = "ObjectProperty" }, Scores = { "ArrayProperty", inner = "IntProperty" },
    Slots = { "ArrayProperty", inner = "StructProperty" },
    Friends = "MapProperty", Seen = "SetProperty", Target = "WeakObjectProperty", Skin = "SoftObjectProperty",
    Outfit = "SoftClassProperty", Helper = "InterfaceProperty", Field = "FieldPathProperty", Lazy = "LazyObjectProperty",
    OnHit = "MulticastInlineDelegateProperty", OnSparse = "MulticastSparseDelegateProperty", OnDone = "DelegateProperty",
    Precise = "DoubleProperty", Broken = "IntProperty",
}, {
    Jump = {}, AddItem = { { "Item", "ObjectProperty" }, { "Item Count", "IntProperty" } }, GetParent = {},
    Tick = { { "DeltaTime", "FloatProperty" }, { "CallFunc_Add_ReturnValue", "IntProperty" }, { "K2Node_Local", "IntProperty" } },
})
local controller_class = world.class("/Script/Engine.PlayerController", actor_class,
    { Pawn = "ObjectProperty", PlayerCameraManager = "ObjectProperty", Hud = "ObjectProperty" })
local npc_class = world.class("/Script/Icarus.IcarusNPCCharacter", pawn_class, { AISetup = "StructProperty", CurrentLevel = "IntProperty" })
local wolf_class = world.class("/Game/BP/AI/BP_Wolf.BP_Wolf_C", npc_class)
local deer_class = world.class("/Game/BP/AI/BP_Deer.BP_Deer_C", npc_class)
local drone_class = world.class("/Script/Icarus.IcarusPawn", pawn_class)
local item_class = world.class("/Script/Icarus.IcarusItem", actor_class)
local building_class = world.class("/Script/Icarus.BuildingBase", item_class)
local bench_class = world.class("/Script/Icarus.Deployable", actor_class)
local tree_class = world.class("/Game/BP/BP_Tree.BP_Tree_C", actor_class)
local weather_class = world.class("/Game/BP/BP_Weather.BP_Weather_C", actor_class)
local settings_class = world.class("/Script/Engine.WorldSettings", actor_class)
local game_state_class = world.class("/Script/Engine.GameStateBase", actor_class, { ElapsedTime = "IntProperty" })
local game_mode_class = world.class("/Script/Engine.GameModeBase", actor_class)
local camera_class = world.class("/Script/Engine.PlayerCameraManager", actor_class)
local widget_class = world.class("/Script/UMG.Widget", object, { Opacity = "FloatProperty", Slot = "ObjectProperty" })
local slot_class = world.class("/Script/UMG.PanelSlot", object, { Row = "IntProperty" })
local game_instance_class = world.class("/Script/Engine.GameInstance", object, { LocalPlayers = { "ArrayProperty", inner = "ObjectProperty" } })
local local_player_class = world.class("/Script/Engine.LocalPlayer", object, { PlayerController = "ObjectProperty" })
local viewport_class = world.class("/Script/Engine.GameViewportClient", object)
local engine_class = world.class("/Script/Engine.GameEngine", object)

local function scene_part(name, props)
    props = props or {}
    props.AttachChildren = props.AttachChildren or world.array({})
    props.RelativeLocation = props.RelativeLocation or { X = 0, Y = 0, Z = 0 }
    return world.component(scene_class, name, props)
end

-- the world settings actor is the first actor of a level, which is how the level's actor list is checked
local settings_actor = world.place(settings_class, "WorldSettings", { Location = { 0, 0, 0 } })

local hat = scene_part("Hat")
local mesh = scene_part("CharacterMesh0", { AttachChildren = world.array({ hat }) })
rawget(hat, "__props").AttachParent = mesh
local stat_container = world.component(stats_class, "Stat Container", { Oxygen = 80, bIsActive = true })
local player_state = world.place(game_state_class, "PlayerState_1", { ElapsedTime = 1, Location = { 0, 0, 0 } })
local me = world.place(player_class, "BP_Player_C_7", {
    Health = 87.5, Stamina = 60, bIsCrouched = false, bHidden = false, Mode = 2, Flags = 3,
    Nickname = "Bo", Title = "Prospector", Tribe = "Olympus", Name = "a property called Name",
    ["Stat Container"] = stat_container, Mesh = mesh, Rival = world.INVALID, PlayerState = player_state,
    Spot = { X = 1.0, Y = 2.0, Z = 3.0 }, Tint = { R = 255, G = 128, B = 0, A = 255 }, Aim = { Pitch = 0.0, Yaw = 90.0, Roll = 0.0 },
    Glow = { R = 0.5, G = 0.25, B = 1.0, A = 1.0 }, Reach = { X = 4.0, Y = 5.0 }, Session = trap,
    Carried = world.array({}), Scores = world.array({ 10, 20, 30 }), Slots = world.array({ trap, trap }), Tags = world.array({ "Local", "Player" }),
    Friends = trap, Seen = trap, Target = trap, Skin = trap, Outfit = trap, Helper = trap, Field = trap, Lazy = trap,
    OnHit = trap, OnSparse = trap, OnDone = trap, Precise = trap,
    Location = { 0, 0, 0 },
}, { mesh, stat_container, hat })

local slot = world.component(slot_class, "Slot_0", { Row = 2 })
local hud = world.component(widget_class, "HUD_Main", { Opacity = 1.0, Slot = slot })
local camera = world.place(camera_class, "PlayerCameraManager_0", { Location = { 0, 0, 0 } })
local controller = world.place(controller_class, "PlayerController_0",
    { Pawn = me, PlayerCameraManager = camera, Hud = hud, Location = { 0, 0, 0 } })
local game_state = world.place(game_state_class, "GameState_0", { ElapsedTime = 12, Location = { 0, 0, 0 } })
local game_mode = world.place(game_mode_class, "GameMode_0", { Location = { 0, 0, 0 } })
local weather = world.place(weather_class, "BP_Weather_C_2147", { Location = { 0, 0, 90000 } })

local serial = 0
local function creature(class, at, spawn)
    serial = serial + 1
    local state = world.component(state_class, "ActorState", { Health = 100, bIsActive = true })
    local body = scene_part("Body")
    return (spawn and world.spawn or world.place)(class, rawget(class, "__name") .. "_" .. serial,
        { AISetup = world.handle("Row"), CurrentLevel = 3, Location = at }, { state, body }), state
end
local near_wolf = creature(wolf_class, { 500, 0, 0 })                  -- 5 m away
local far_wolf = creature(wolf_class, { 30000, 0, 0 })                 -- 300 m
local deer = creature(deer_class, { 0, 1500, 0 })                      -- 15 m
world.place(drone_class, "IcarusPawn_1", { Location = { 0, 0, 0 } })   -- a pawn that is not a creature
local axe = world.place(item_class, "Item_Axe_1", { Location = { 100, 0, 0 } })
local wall = world.place(building_class, "Wall_Wood_1", { Location = { 0, 4000, 0 } })
world.place(bench_class, "Bench_1", { Location = { 0, 4100, 0 } })
local torch_root = scene_part("TorchRoot", { AttachParent = mesh })
local torch = world.place(item_class, "Item_Torch_1", { RootComponent = torch_root, Location = { 0, 0, 0 } }, { torch_root })
world.attach(torch, me)
rawget(me, "__props").Carried = world.array({ axe, world.INVALID, torch })
for index = 1, 700 do world.place(tree_class, ("BP_Tree_C_%04d"):format(index), { Location = { 100000 + index * 100, 0, 0 } }) end

local level = world.component(level_class, "PersistentLevel", { WaxLevelActors = world.array(world.actors), WorldSettings = settings_actor })
local the_world = world.component(world_class, "Terrain_016", { PersistentLevel = level, Levels = world.array({ level }),
    GameState = game_state, AuthorityGameMode = game_mode, TimeSeconds = 5 })
local local_player = world.component(local_player_class, "LocalPlayer_0", { PlayerController = controller })
local game_instance = world.component(game_instance_class, "GameInstance_0",
    { LocalPlayers = world.array({ local_player }), ReferencedObjects = world.array({}) })
local viewport = world.component(viewport_class, "GameViewportClient_0", { World = the_world, GameInstance = game_instance })
world.engine = world.component(engine_class, "GameEngine_0", { GameViewport = viewport })

local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local sched = Wax.import("core.sched")
local log = Wax.import("core.log")
Wax.log, Wax.guard, Wax.sched = log, guard, sched
Wax.mods = { list = function() return {} end, request_reload = function() end, request_sync = function() end }
Wax.import("core.storage").directory = nil
local instance = Wax.import("engine.instance")
local game_module = Wax.import("engine.game")
game_module.start()
Wax.game = game_module.root
Wax.instance = instance
local game = game_module.root
local actors = Wax.import("engine.actors")
actors.start()
local inspect = Wax.import("engine.inspect")
local index = Wax.import("gui.explorer_index")
local paths = Wax.import("gui.explorer_path")
local members = Wax.import("gui.explorer_members")
local explorer = Wax.import("gui.explorer")
local ui = Wax.import("gui.init")
local events = Wax.import("gui.events")
ui.start()
Wax.ui = ui
ui.Theme().animation = 0

local now = 0
explorer.clock = function() return now end
members.clock = explorer.clock
index.budget.seconds = math.huge        -- slices are counted in objects here; one test below is about the time limit

local function tick(count)
    for _ = 1, count or 1 do
        now = now + 1 / 60
        sched.step()
        index.step()
    end
end
local function settle(limit)
    for _ = 1, limit or 400 do
        tick()
        if not index.seeding() and not index.searching() then return end
    end
    error("the list did not settle", 2)
end
local function names(list, limit)
    local out = {}
    for i = 1, math.min(#list, limit or #list) do out[i] = list[i].name end
    return table.concat(out, ",")
end
local function errors() return #guard.errors() end
local function wrap(raw) return instance.wrap(raw) end

t.test("the level's actor list is read in slices that never look at more than was asked", function()
    local found, place = game_module.actors_from(nil, 5)
    t.eq(#found, 5)
    t.eq(found[1].Name, "WorldSettings")
    local total = #found
    while place do
        found, place = game_module.actors_from(place, 200)
        t.ok(#found <= 200, "a slice is never larger than asked")
        total = total + #found
    end
    t.eq(total, #world.actors)
end)

t.test("nothing is listed and nobody listens until the Explorer shows", function()
    local before = world.touches
    for _ = 1, 20 do index.step() end
    t.eq(world.touches, before, "a sleeping list asks the engine nothing")
    t.eq(index.stats().awake, false)
    t.eq(actors.stats().listening, false)
    t.eq((index.counts()), 0)
end)

t.test("the world is listed a slice per frame", function()
    index.wake()
    t.eq(actors.stats().listening, true)
    tick()
    t.eq((index.counts()), index.budget.seed, "one frame lists one slice")
    local frames_taken = 1
    while index.seeding() do
        tick()
        frames_taken = frames_taken + 1
    end
    t.eq((index.counts()), #world.actors)
    t.eq(frames_taken, math.ceil(#world.actors / index.budget.seed), "716 actors, 120 a frame")
    t.ok(index.stats().mostInAFrame.seeded <= index.budget.seed)
    settle()
    t.eq(#index.results(), #world.actors, "with no search, every actor is shown")
    t.eq(errors(), 0)
end)

t.test("listing also stops for the frame when it has taken too long, however few actors that was", function()
    local real_clock, time = index.clock, 0
    index.clock = function()
        time = time + 0.0004        -- every look at the clock finds 0.4 ms gone
        return time
    end
    index.budget.seconds = 0.001
    index.reset()
    tick()
    local listed = (index.counts())
    t.ok(listed >= 1 and listed <= 3, "a slow frame lists a few and goes on next frame: " .. listed)
    tick(5)
    t.ok((index.counts()) > listed, "and it does go on")
    index.clock, index.budget.seconds = real_clock, math.huge
    settle()
    t.eq((index.counts()), #world.actors)
    t.eq(#index.results(), #world.actors)
end)

t.test("a kind comes from the class and what it inherits, worked out once per class", function()
    local function kind(raw) return index.entry_of(wrap(raw)).kind end
    t.eq(kind(me), "player")
    t.eq(kind(near_wolf), "creature")
    t.eq(kind(deer), "creature")
    t.eq(kind(axe), "item")
    t.eq(kind(wall), "building", "a building is an item too, and counts as a building")
    t.eq(kind(weather), "actor")
    t.eq(index.entry_of(wrap(world.actors[#world.actors])).kind, "actor")
    t.eq(inspect.kind(wrap(mesh)), "component")
    t.eq(inspect.kind(wrap(hud)), "widget")
    t.eq(inspect.kind(wrap(game_instance)), "object")
    local drone
    for _, entry in ipairs(index.results()) do
        if entry.name == "IcarusPawn_1" then drone = entry end
    end
    t.eq(drone.kind, "actor", "a pawn without a creature row is not a creature")
    t.ok(inspect.stats().kinds < 25, "one answer per class, not per actor: " .. inspect.stats().kinds)
end)

t.test("search: every word has to be in the name or the class, whatever the capitals", function()
    t.eq(index.query({ text = "WOLF" }), true)
    t.eq(index.query({ text = "wolf  " }), false, "the same search again starts nothing")
    settle()
    t.eq(names(index.results()), "BP_Wolf_C_1,BP_Wolf_C_2")
    index.query({ text = "bp_ c_0" })
    settle()
    t.eq(#index.results(), 700, "bp_ and c_0 are both in the name of every tree")
    index.query({ text = "wolf c_2" })
    settle()
    t.eq(names(index.results()), "BP_Wolf_C_2")
    index.query({ text = "icarusitem" })
    settle()
    t.eq(names(index.results()), "Item_Axe_1,Item_Torch_1", "a class name finds its actors")
    index.query({ text = "no such thing" })
    settle()
    t.eq(#index.results(), 0)
end)

t.test("more letters of the same search look only at what was found before", function()
    index.query({ text = "wo" })
    settle()
    local found = #index.results()
    t.ok(found >= 3 and found < 20, "wolves, the wall of wood and the world settings: " .. found)
    index.query({ text = "wol" })
    tick()
    t.eq(index.stats().thisFrame.filtered, found, "only the earlier results were tested")
    settle()
    t.eq(names(index.results()), "BP_Wolf_C_1,BP_Wolf_C_2")
    index.query({ text = "w" })
    tick()
    t.ok(index.stats().thisFrame.filtered > found, "a shorter search reads the whole list again")
    settle()
end)

t.test("kinds filter the list, and sorting is by name, class or newest first", function()
    index.query({ kind = "creature" })
    settle()
    t.eq(names(index.results()), "BP_Deer_C_3,BP_Wolf_C_1,BP_Wolf_C_2")
    index.query({ kind = "player" })
    settle()
    t.eq(names(index.results()), "BP_Player_C_7")
    index.query({ kind = "building" })
    settle()
    t.eq(names(index.results()), "Bench_1,Wall_Wood_1")
    index.query({ kind = "item", sort = "class" })
    settle()
    t.eq(names(index.results()), "Item_Axe_1,Item_Torch_1")
    index.query({ text = "c_", sort = "class" })
    settle()
    t.eq(names(index.results(), 3), "BP_Deer_C_3,BP_Tree_C_0001,BP_Tree_C_0002", "BP_Deer_C, then BP_Tree_C")
    t.eq(index.results()[#index.results()].name, "BP_Player_C_7", "IcarusPlayerCharacter comes last")
    t.raises(function() index.query({ sort = "size" }) end, "the sort is")
end)

t.test("a long list is sorted in pieces and joined a slice per frame", function()
    index.query({ text = "tree", sort = "name" })
    settle()
    local results = index.results()
    t.eq(#results, 700)
    for i = 2, #results do t.ok(results[i - 1].name_key < results[i].name_key, "in order at " .. i) end
    local most = index.stats().mostInAFrame
    t.ok(most.sorted <= index.budget.sort, "never more than one piece sorted in a frame: " .. most.sorted)
    t.ok(most.merged <= index.budget.merge)
    t.ok(most.filtered <= index.budget.filter)
end)

t.test("an actor that begins play is listed the frame after, in its place", function()
    index.query({ kind = "creature", sort = "name" })
    settle()
    local _, before = index.results()
    local fresh = creature(wolf_class, { 900, 0, 0 }, true)
    t.eq(index.entry_of(wrap(fresh)), nil, "not listed inside the engine's call")
    tick()
    local entry = index.entry_of(wrap(fresh))
    t.ok(entry ~= nil)
    t.eq(entry.began, index.frame(), "it remembers the frame it began play in")
    local results, after = index.results()
    t.ok(after ~= before, "the shown list says it changed")
    t.eq(names(results), "BP_Deer_C_3,BP_Wolf_C_1,BP_Wolf_C_2," .. entry.name)
    index.query({ kind = "creature", sort = "newest" })
    settle()
    t.eq(index.results()[1].name, entry.name, "newest first puts it on top")
    world.spawn(tree_class, "BP_Tree_C_late", { Location = { 0, 0, 0 } })
    tick()
    t.eq(#index.results(), 4, "an actor of another kind is listed but not shown")
    t.eq(index.stats().actors, #world.actors)
end)

t.test("an actor that ends play leaves at once and is never asked anything again", function()
    index.query({ kind = "creature", sort = "name" })
    settle()
    local doomed = index.results()[4]
    local raw = world.actors[#world.actors - 1]
    t.eq(rawget(raw, "__name"), doomed.name)
    world.destroy(raw)
    t.eq(doomed.gone, true, "gone inside the engine's call")
    t.eq(index.entry_of(doomed.instance), nil)
    world.free(raw)
    tick(2)
    t.eq(names(index.results()), "BP_Deer_C_3,BP_Wolf_C_1,BP_Wolf_C_2")
    -- one that began and ended between two frames is never listed at all
    local brief = creature(deer_class, { 0, 0, 0 }, true)
    world.destroy(brief)
    world.free(brief)
    tick(40)
    t.eq(#index.results(), 3)
    t.eq(world.dead_touches, 0, "nothing touched what was freed")
    t.eq(errors(), 0)
end)

t.test("near me: positions are read a few per frame and the list follows the character", function()
    index.query({ near = 20, sort = "distance" })
    tick()
    t.ok(index.stats().thisFrame.spots <= index.budget.first_spots, "a slice of positions per frame")
    tick(index.rerun * 2 + 20)
    settle()
    local shown = names(index.results())
    t.ok(shown:find("BP_Player_C_7", 1, true), "the character itself: " .. shown)
    t.ok(shown:find("Item_Axe_1", 1, true) < shown:find("BP_Wolf_C_1", 1, true), "the axe 1 m away comes before the wolf")
    t.ok(shown:find("BP_Wolf_C_1", 1, true), "the wolf 5 m away")
    t.ok(shown:find("BP_Deer_C_3", 1, true), "the deer 15 m away")
    t.ok(not shown:find("BP_Wolf_C_2", 1, true), "not the wolf 300 m away")
    t.ok(not shown:find("Wall_Wood_1", 1, true), "not the wall 40 m away")
    local wolf_at, deer_at = shown:find("BP_Wolf_C_1", 1, true), shown:find("BP_Deer_C_3", 1, true)
    t.ok(wolf_at < deer_at, "nearest first")
    t.ok(math.abs(index.entry_of(wrap(deer)).distance - 15) < 0.01)
    -- the character walks to the far wolf
    rawget(me, "__props").Location = { 29000, 0, 0 }
    tick(index.rerun * 2 + 40)
    settle()
    shown = names(index.results())
    t.ok(shown:find("BP_Wolf_C_2", 1, true) and not shown:find("BP_Wolf_C_1", 1, true), "the list follows: " .. shown)
    t.ok(index.stats().mostInAFrame.spots <= index.budget.first_spots)
    rawget(me, "__props").Location = { 0, 0, 0 }
    index.query({ near = 20, kind = "creature", sort = "distance" })
    tick(index.rerun + 5)
    settle()
    t.eq(names(index.results()), "BP_Wolf_C_1,BP_Deer_C_3")
    t.eq(errors(), 0)
end)

t.test("components are listed only when they are asked for, a few actors per frame", function()
    local _, parts = index.counts()
    t.eq(parts, 0)
    index.query({ kind = "components", text = "actorstate" })
    tick()
    t.eq(index.stats().thisFrame.parts, index.budget.parts)
    for _ = 1, 400 do tick() end
    settle()
    _, parts = index.counts()
    t.eq(parts, 3 + 3 * 2 + 1, "the character's three, two for each creature, and the torch's one")
    t.eq(#index.results(), 3, "one ActorState for each of the three creatures")
    t.eq(index.results()[1].kind, "component")
    index.query({ kind = "everything", text = "hat" })
    settle()
    t.eq(names(index.results()), "Hat", "a component attached to another component is found too")
    -- a creature that leaves takes its components with it
    local gone = creature(deer_class, { 0, 0, 0 }, true)
    tick(3)
    _, parts = index.counts()
    t.eq(parts, 12)
    world.destroy(gone)
    world.free(gone)
    tick()
    _, parts = index.counts()
    t.eq(parts, 10)
    index.query({ kind = "actors" })
    settle()
    _, parts = index.counts()
    t.eq(parts, 0, "and they are dropped again when no longer asked for")
    t.eq(world.dead_touches, 0)
end)

t.test("sleeping stops everything, and waking finds what changed meanwhile", function()
    index.query({ kind = "creature", sort = "name" })
    settle()
    index.sleep()
    t.eq(actors.stats().listening, false)
    local before = world.touches
    tick(30)
    t.eq(world.touches, before, "asleep, a frame asks the engine nothing")
    world.destroy(far_wolf)
    world.free(far_wolf)
    local arrived = creature(deer_class, { 0, 0, 0 }, true)
    index.wake()
    settle()
    tick(2)
    t.eq(names(index.results()), "BP_Deer_C_3," .. rawget(arrived, "__name") .. ",BP_Wolf_C_1")
    t.eq((index.counts()), #world.actors)
    t.eq(world.dead_touches, 0)
    t.eq(errors(), 0)
end)

-- the Lua the Explorer writes

local function evaluate(code)
    local chunk = assert(load("return " .. code, "=lua", "t", { game = game }))
    return chunk()
end

t.test("an object is reached by the shortest Lua that keeps working, and that Lua really gives the object", function()
    local function check(raw, wanted, path)
        local inst = wrap(raw)
        local code = paths.expression(inst, path, index.unique)
        t.eq(code, wanted)
        t.ok(evaluate(code) == inst, wanted .. " gives the object it was written for")
    end
    check(me, "game.Character")
    check(controller, "game.LocalPlayer")
    check(game_state, "game.GameState")
    check(game_mode, "game.GameMode")
    check(game_instance, "game.GameInstance")
    check(viewport, "game.Viewport")
    check(world.engine, "game.Engine")
    check(the_world, "game.World")
    check(mesh, "game.Character.Mesh", nil)
    check(stat_container, "game.Character:Get(\"Stat Container\")")
    check(hat, "game.Character.Mesh:FindFirstChild(\"Hat\")")
    check(camera, "game.LocalPlayer.PlayerCameraManager")
    check(player_state, "game.Character.PlayerState")
    check(torch, "game.Character:FindFirstChild(\"Item_Torch_1\")", nil)
    check(torch_root, "game.Character:FindFirstChild(\"Item_Torch_1\"):FindFirstChild(\"TorchRoot\")")
    check(deer, "game.World:FindFirstChild(\"BP_Deer_C_3\")", nil)
    for _, raw in ipairs(world.actors) do
        if rawget(raw, "__name") == "BP_Tree_C_0015" then check(raw, "game.World:FindFirstChild(\"BP_Tree_C_0015\")") end
    end
    check(near_wolf, "game:Find(\"BP_Wolf_C\")", nil)
    check(weather, "game:Find(\"BP_Weather_C\")")
    check(hud, "game.LocalPlayer.Hud", paths.step(paths.from_root("LocalPlayer"), "Hud"))
    check(slot, "game.LocalPlayer.Hud.Slot", paths.step(paths.step(paths.from_root("LocalPlayer"), "Hud"), "Slot"))
    check(local_player, "game.GameInstance.LocalPlayers[1]", paths.step(paths.from_root("GameInstance"), "LocalPlayers", 1))
    check(axe, "game.Character.Carried[1]", paths.step(paths.from_root("Character"), "Carried", 1))
    -- reached from a kept actor that is not under a root
    local deer_state = rawget(deer, "__components")[1]
    check(deer_state, "game.World:FindFirstChild(\"BP_Deer_C_3\"):FindFirstChild(\"ActorState\")")
end)

t.test("a path is walked again from its root every time, and gives nothing rather than something stale", function()
    local path = paths.step(paths.step(paths.from_root("LocalPlayer"), "Hud"), "Slot")
    t.ok(paths.resolve(path) == wrap(slot))
    local other = world.component(slot_class, "Slot_9", { Row = 9 })
    rawget(hud, "__props").Slot = other
    t.ok(paths.resolve(path) == wrap(other), "it follows what the property holds now")
    rawget(hud, "__props").Slot = world.INVALID
    t.eq(paths.resolve(path), nil)
    rawget(hud, "__props").Slot = slot
    t.eq(paths.resolve(paths.step(paths.from_root("Character"), "Carried", 2)), nil, "an empty place of an array")
    t.eq(paths.resolve(paths.step(paths.from_root("Character"), "Carried", 9)), nil, "past the end of an array")
    t.eq(rawget(me, "__props").Carried:GetArrayNum(), 3, "and reading past the end did not make it longer")
    t.eq(paths.resolve(paths.step(paths.from_root("Character"), "Health")), nil, "a property that is not an object")
    t.eq(paths.resolve(paths.from_root("Nonsense")), nil)
    t.ok(paths.same(path, paths.step(paths.step(paths.from_root("LocalPlayer"), "Hud"), "Slot")))
    t.ok(not paths.same(path, paths.step(paths.from_root("LocalPlayer"), "Hud")))
end)

t.test("members are written the way mods write them, with Get and Set for names Wax uses itself", function()
    t.eq(paths.read_of("game.Character", "Health"), "game.Character.Health")
    t.eq(paths.write_of("game.Character", "Health", "50"), "game.Character.Health = 50")
    t.eq(paths.read_of("x", "Name"), "x:Get(\"Name\")", "Name is the object's own name")
    t.eq(paths.write_of("x", "Name", "\"Bo\""), "x:Set(\"Name\", \"Bo\")")
    t.eq(paths.read_of("x", "Parent"), "x:Get(\"Parent\")")
    t.eq(paths.read_of("x", "GetChildren"), "x:Get(\"GetChildren\")")
    t.eq(paths.read_of("x", "Stat Container"), "x:Get(\"Stat Container\")", "a name with a space")
    t.eq(paths.read_of("x", "end"), "x:Get(\"end\")", "a Lua word")
    t.eq(paths.read_line("x", "Spot", "X"), "local value = x.Spot.X")
    t.eq(paths.read_line("x", "Scores", nil, 2), "local value = x.Scores[2]")
    t.eq(paths.call_of("x", "Jump", {}), "x:Jump()")
    t.eq(paths.call_of("x", "AddItem", { { name = "Item" }, { name = "Item Count" } }), "x:AddItem(Item, Item_Count)")
    t.eq(paths.call_of("x", "GetParent", {}), "x:Call(\"GetParent\")", "a function with a name Wax uses")
    -- and the game agrees: these are how an Instance is really read and written
    local character = game.Character
    t.eq(character:Get("Name"), "a property called Name")
    t.eq(character.Name, "BP_Player_C_7")
    t.eq(evaluate("game.Character.Health"), 87.5)
    t.eq(evaluate("game.Character.Spot.X"), 1)
    t.eq(evaluate("game.Character.Scores[2]"), 20)
end)

-- what is read and written

local sheet, character

t.test("every member is described: how it is shown, whether it can be typed, and what is never read", function()
    character = game.Character
    local list = inspect.members(character)
    t.ok(inspect.members(character) == list, "one list per class")
    local by = {}
    for _, record in ipairs(list) do by[record.name] = record end
    local function has(name, show, label, edit)
        local record = by[name]
        t.ok(record, name .. " is listed")
        t.eq(record.show, show, name .. " is shown as")
        t.eq(record.label, label, name .. " is labelled")
        t.eq(record.edit or false, edit, name .. " can be typed")
    end
    has("bIsCrouched", "bool", "bool", true)
    has("Health", "float", "float", true)
    has("Stamina", "int", "int", true)
    has("Mode", "int", "enum", true)
    has("Flags", "int", "byte", true)
    has("Nickname", "text", "string", true)
    has("Title", "text", "text", true)
    has("Tribe", "text", "name", true)
    has("Mesh", "object", "object", false)
    has("Spot", "struct", "Vector", true)
    has("Tint", "struct", "Color", true)
    has("Aim", "struct", "Rotator", true)
    has("Glow", "struct", "LinearColor", true)
    has("Reach", "struct", "Vector2D", true)
    has("Session", nil, "IcarusSession", false)
    has("AISetup" and "PlayerState", "object", "object", false)
    has("Carried", "array", "array of object", false)
    has("Scores", "array", "array of int", false)
    has("Slots", "array", "array of struct", false)
    has("Tags", "array", "array of name", false)
    for name, label in pairs({ Friends = "map", Seen = "set", Target = "weak object", Skin = "soft object", Outfit = "soft class",
        Helper = "interface", Field = "field path", Lazy = "lazy object", OnHit = "event", OnSparse = "event", OnDone = "delegate",
        Precise = "double" }) do
        has(name, nil, label, false)
        t.ok(not by[name].poll, name .. " is not watched")
    end
    t.eq(by.Jump.kind, "function")
    t.eq(by.Slots.inner_show, nil, "an array of structs is counted, never opened")
    t.eq(by.Carried.inner_show, "object")
    local order = {}
    for index_, record in ipairs(list) do order[index_] = record.name end
    t.ok(table.concat(order, ","):find("AddItem,Aim,bHidden,bIsCrouched", 1, true), "sorted without regard to capitals")
end)

t.test("values are read as plain Lua values and shown as short text", function()
    local by = {}
    for _, record in ipairs(inspect.members(character)) do by[record.name] = record end
    local function read(name)
        local ok, value = inspect.read(character, by[name])
        t.ok(ok, name .. " reads: " .. tostring(value))
        return value, inspect.text(by[name], value), inspect.literal(by[name], value)
    end
    local value, text, code = read("Health")
    t.eq(value, 87.5)
    t.eq(text, "87.5")
    t.eq(code, "87.5")
    t.eq(select(2, read("Stamina")), "60")
    t.eq(select(2, read("bIsCrouched")), "false")
    t.eq(select(3, read("Nickname")), "\"Bo\"")
    t.eq(select(2, read("Tribe")), "Olympus")
    value, text = read("Mesh")
    t.eq(text, "CharacterMesh0 (SceneComponent)")
    value, text = read("Rival")
    t.eq(value, false)
    t.eq(text, "none")
    value, text, code = read("Spot")
    t.eq(text, "1.0, 2.0, 3.0")
    t.eq(code, "{ X = 1.0, Y = 2.0, Z = 3.0 }")
    t.eq(select(3, read("Tint")), "{ R = 255, G = 128, B = 0, A = 255 }")
    t.eq(select(2, read("Glow")), "0.5, 0.25, 1.0, 1.0")
    t.eq(select(2, read("Scores")), "3 items")
    local ok, found = inspect.elements(character, by.Scores)
    t.ok(ok)
    t.eq(found.total, 3)
    t.eq(found.items[2], 20)
    ok, found = inspect.elements(character, by.Carried)
    t.eq(found.items[1].name, "Item_Axe_1")
    t.eq(found.items[2], false, "an empty place")
    t.eq(inspect.text(by.Carried, found.items[2], true), "none")
    ok, found = inspect.elements(character, by.Slots)
    t.eq(found.total, 2)
    t.eq(#found.items, 0, "the structs in it are not looked at")
    ok, found = inspect.elements(character, by.Tags)
    t.eq(found.items[2], "Player")
    t.ok(inspect.element(character, by.Carried, 3) == wrap(torch))
    -- a long array is cut where it is told to be
    local long = {}
    for i = 1, 500 do long[i] = i end
    rawget(me, "__props").Scores = world.array(long)
    ok, found = inspect.elements(character, by.Scores)
    t.eq(found.total, 500)
    t.eq(#found.items, inspect.ELEMENTS)
    rawget(me, "__props").Scores = world.array({ 10, 20, 30 })
    -- what is never read says so without the engine being asked
    world.watch = {}
    local failed, problem = inspect.read(character, by.Friends)
    t.eq(failed, false)
    t.ok(problem:find("not read", 1, true))
    t.eq(world.watch.Friends, nil)
    world.watch = nil
    -- numbers that are whole are shown whole, small ones keep their digits
    t.eq(inspect.text(by.Health, 600.0), "600.0")
    t.eq(inspect.text(by.Health, 0.1), "0.1")
    t.eq(inspect.text(by.Health, 0.00001), "1e-05")
    t.eq(inspect.text(by.Nickname, ("x"):rep(300)):len(), 120)
    t.eq(inspect.literal(by.Nickname, "two\nlines"), "\"two\\nlines\"")
end)

t.test("typed text becomes a value of the right type, or is refused with the reason", function()
    local by = {}
    for _, record in ipairs(inspect.members(character)) do by[record.name] = record end
    t.eq(inspect.parse(by.Stamina, " 42 "), 42)
    t.eq(math.type(inspect.parse(by.Stamina, "42")), "integer")
    t.eq(select(2, inspect.parse(by.Stamina, "4.5")), "a whole number is needed")
    t.eq(select(2, inspect.parse(by.Stamina, "lots")), "a number is needed")
    t.eq(inspect.parse(by.Health, "12.5"), 12.5)
    t.eq(inspect.parse(by.bIsCrouched, "TRUE"), true)
    t.eq(inspect.parse(by.bIsCrouched, "0"), false)
    t.eq(select(2, inspect.parse(by.bIsCrouched, "maybe")), "true or false is needed")
    t.eq(inspect.parse(by.Nickname, " spaces stay "), " spaces stay ")
    t.eq(inspect.parse(by.Tribe, ""), "None", "an empty name is the name None")
    t.eq(inspect.parse(by.Spot, "7.5", "X"), 7.5)
    t.eq(select(2, inspect.parse(by.Tint, "7.5", "R")), "a whole number is needed")
    t.eq(select(2, inspect.parse(by.Spot, "1,2,3")), "this cannot be typed")
    t.eq(select(2, inspect.parse(by.Mesh, "1")), "this cannot be typed")
end)

t.test("writes go through the checked path, and what it refuses is reported, not written", function()
    local by = {}
    for _, record in ipairs(inspect.members(character)) do by[record.name] = record end
    local props = rawget(me, "__props")
    t.ok(inspect.write(character, by.Stamina, 75))
    t.eq(props.Stamina, 75)
    t.ok(inspect.write(character, by.bIsCrouched, true))
    t.eq(props.bIsCrouched, true)
    t.ok(inspect.write(character, by.Tribe, "Styx"))
    t.eq(props.Tribe, "Styx")
    t.ok(inspect.write(character, by.Title, "Miner"))
    t.eq(character.Title, "Miner", "a text is given to the engine as text and read back as a string")
    t.ok(inspect.write(character, by.Spot, { X = 9, Y = 2, Z = 3 }))
    t.eq(props.Spot.X, 9)
    local ok, problem = inspect.write(character, by.Stamina, 1.5)
    t.eq(ok, false)
    t.ok(problem:find("expects a whole number", 1, true), problem)
    t.ok(not problem:find(".lua:", 1, true), "the message is for a player, without a file and line")
    ok, problem = inspect.write(character, by.bIsCrouched, 1)
    t.eq(ok, false)
    ok, problem = inspect.write(character, by.OnDone, {})
    t.eq(ok, false)
    t.ok(problem:find("cannot be set", 1, true), problem)
    t.eq(props.Stamina, 75)
    props.Stamina, props.bIsCrouched, props.Tribe, props.Spot = 60, false, "Olympus", { X = 1.0, Y = 2.0, Z = 3.0 }
    props.Title = "Prospector"
end)

t.test("a sheet reads what is shown and watches the simple values a few per frame", function()
    sheet = members.new(inspect.members(character), character:GetClassChain())
    t.eq(#sheet.polled, 11, "bools, numbers and texts are watched, nothing else")
    world.watch = {}
    local rounds_needed = math.ceil(#sheet.polled / members.POLL)
    for _ = 1, rounds_needed do t.eq(members.poll(sheet, character), members.POLL) end
    t.eq(sheet.failed, 1, "one of them cannot be read (the next test is about that)")
    t.eq(sheet.reads, rounds_needed * members.POLL - 1, "eight a frame, and the one that failed is skipped the second time round")
    t.eq(sheet.changed, 0, "the first look at a value is not a change")
    rawget(me, "__props").Stamina = 55
    for _ = 1, rounds_needed do members.poll(sheet, character) end
    t.eq(sheet.changed, 1)
    t.ok(sheet.state.Stamina.changed_at ~= nil)
    t.eq(sheet.state.Health.changed_at, nil)
    t.eq(members.look(sheet, { type = "member", record = sheet.polled[1], depth = 0 }).tone ~= nil, true)
    -- nothing of a kind that is never read was fetched from the engine, and no trap was sprung
    for _, name in ipairs({ "Friends", "Seen", "Target", "Skin", "Outfit", "Helper", "Field", "Lazy", "OnHit", "OnSparse", "OnDone",
        "Precise", "Session", "Slots", "Mesh", "Spot", "Carried" }) do
        t.eq(world.watch[name], nil, name .. " was not read by the watch")
    end
    t.eq(trapped, 0)
    world.watch = nil
end)

t.test("a read that fails is shown once and that member is not read again", function()
    local fresh = members.new(inspect.members(character), character:GetClassChain())
    local broken
    for _, record in ipairs(fresh.records) do
        if record.name == "Broken" then broken = record end
    end
    world.watch = {}
    local state = members.read(fresh, character, broken)
    t.eq(state.failed, true)
    t.ok(type(state.problem) == "string" and #state.problem > 0)
    local reads = world.watch.Broken
    t.eq(reads, 1)
    for _ = 1, 20 do
        members.read(fresh, character, broken)
        members.poll(fresh, character)
    end
    t.eq(world.watch.Broken, reads, "never fetched again")
    t.eq(fresh.failed, 1)
    local look = members.look(fresh, { type = "member", record = broken, depth = 0 })
    t.eq(look.tone, "bad")
    t.eq(look.value, state.problem)
    world.watch = nil
    t.eq(errors(), 0, "a failed read is shown in its row, not reported as an error")
end)

t.test("rows: all, properties, functions, changed, changed first, a search, and what opens", function()
    local function listed(rows)
        local out = {}
        for i, a_row in ipairs(rows) do out[i] = a_row.key end
        return table.concat(out, ",")
    end
    local rows = members.rows(sheet)
    t.eq(rows[1].type, "class")
    t.eq(members.look(sheet, rows[1]).value, "IcarusPlayerCharacter")
    t.eq(members.look(sheet, rows[1]).arrow, false)
    t.eq(#rows, 1 + #sheet.records)
    t.ok(members.rows(sheet)[5] == rows[5], "the same row is handed out every time")
    sheet.open["#class"] = true
    rows = members.rows(sheet)
    t.eq(rows[2].type, "ancestor")
    t.eq(members.look(sheet, rows[2]).value, "Pawn")
    t.eq(members.look(sheet, rows[4]).value, "Object")
    sheet.open["#class"] = nil

    members.show(sheet, "Functions", "")
    t.eq(listed(members.rows(sheet)), "AddItem,GetParent,Jump,K2_GetActorLocation,SetActorHiddenInGame,Tick")
    local tick_row = members.rows(sheet)[6]
    t.eq(members.look(sheet, tick_row).value, "(DeltaTime: float)", "what a blueprint function keeps for itself is left out")
    t.eq(members.look(sheet, members.rows(sheet)[1]).value, "(Item: object, Item Count: int)")
    members.show(sheet, "Properties", "")
    t.eq(#members.rows(sheet), 1 + #sheet.records - 6)
    members.show(sheet, "Changed", "")
    t.eq(listed(members.rows(sheet)), "Stamina")
    now = now + 1
    rawget(me, "__props").Health = 50
    for _ = 1, 4 do members.poll(sheet, character) end
    t.eq(listed(members.rows(sheet)), "Health,Stamina", "the most recent change first")
    members.show(sheet, "Changed first", "")
    rows = members.rows(sheet)
    t.eq(rows[1].key .. "," .. rows[2].key .. "," .. rows[3].key, "Health,Stamina,Aim")
    t.eq(members.look(sheet, rows[1]).tone, "warn", "a value that just changed is marked")
    now = now + members.RECENT + 1
    t.eq(members.look(sheet, rows[1]).tone, "text", "and the mark goes away")
    rawget(me, "__props").Health = 87.5

    members.show(sheet, "All", "FLOAT")
    t.eq(listed(members.rows(sheet)), "Health", "a search by type")
    members.show(sheet, "All", "is cr")
    t.eq(listed(members.rows(sheet)), "bIsCrouched", "every word has to be in it")
    members.show(sheet, "All", "spot")
    sheet.open.Spot = true
    members.read(sheet, character, members.rows(sheet)[1].record)
    rows = members.rows(sheet)
    t.eq(listed(rows), "Spot,Spot.X,Spot.Y,Spot.Z")
    t.eq(members.look(sheet, rows[3]).value, "2.0")
    t.eq(members.look(sheet, rows[3]).indent, 1)
    t.eq(members.editable(rows[3]), true)
    t.eq(members.editable(rows[1]), false, "a struct is typed one part at a time")
    members.show(sheet, "All", "scores")
    sheet.open.Scores = true
    rawget(me, "__props").Scores = world.array({ 1, 2, 3 })
    local long = {}
    for i = 1, 80 do long[i] = i * 2 end
    rawget(me, "__props").Scores = world.array(long)
    now = now + 1
    members.items(sheet, character, members.rows(sheet)[1].record)
    rows = members.rows(sheet)
    t.eq(#rows, 1 + inspect.ELEMENTS + 1)
    t.eq(members.look(sheet, rows[3]).text, "[2]")
    t.eq(members.look(sheet, rows[3]).value, "4")
    t.eq(members.look(sheet, rows[#rows]).text, "and 30 more")
    rawget(me, "__props").Scores = world.array({ 10, 20, 30 })
    rawget(me, "__props").Stamina = 60
    t.eq(trapped, 0)
end)

-- the page

local window, page, other_page, view
local copied, noticed = {}, {}
local real_copy, real_notify = ui.Copy, ui.Notify
ui.Copy = function(text) copied[#copied + 1] = text end
ui.Notify = function(message, options)
    noticed[#noticed + 1] = { message, options }
    return real_notify(message, options)
end
fake.scroll_end = 0             -- nothing is scrolled: a list shows as many rows as its height holds

local asked = 0                 -- how often the Explorer's own step touched the engine
local function frames(count)
    for _ = 1, count or 1 do
        now = now + 1 / 60
        sched.step()
        ui.step()
        local before = world.touches
        explorer.step()
        asked = asked + world.touches - before
    end
end
local function click(widget) events.simulate(widget, "OnClicked") end
local function tree_cell(name)
    for _, made in ipairs(view.tree_cells) do
        if made.row and made.row.name == name and made.line:Get().text == name then return made end
    end
    return nil
end
local function member_cell(key)
    for _, made in ipairs(view.cells) do
        if made.row and made.row.key == key and made.line:Get().text ~= "" then return made end
    end
    return nil
end
local function find_members(text)
    events.simulate(view.find.source, "OnTextChanged", text)
    frames(30)
end
local function search(text)
    events.simulate(view.search.source, "OnTextChanged", text)
    frames(40)
end
local function label_text(control) return fake.last(control.widget, "SetText")[2]:ToString() end

-- the notices make what they keep for good now, so the mark below is only about the page
real_notify("ready")
ui.Notifications.Clear()

local panel_scope = scope.new("panel")
local objects_before = fake.mark()

t.test("the page builds in the panel and does nothing until it is the page on screen", function()
    index.sleep()
    scope.run(panel_scope, function()
        window = ui.Window({ title = "Wax", nav = "side", width = 620, height = 440, x = 40, y = 80 })
        other_page = window:Page("Mods", { icon = "package" })
        other_page:Label("another page")
        page = window:Page("Explorer", { icon = "folder-tree", scroll = false })
        explorer.build(page)
    end)
    view = explorer.view()
    t.ok(view ~= nil, "built")
    t.eq(errors(), 0)
    t.eq(explorer.stats().built, true)
    -- the menu is closed
    asked = 0
    frames(30)
    t.eq(asked, 0, "with the menu closed the Explorer asks the engine nothing")
    t.eq(index.stats().awake, false)
    -- the menu is open on another page
    ui.SetPreview(true)
    frames(30)
    t.eq(asked, 0, "nor while another page shows")
    t.eq(explorer.stats().showing, false)
    window:SelectPage("Explorer")
    frames(1)
    t.eq(index.stats().awake, true)
    t.ok(asked > 0)
end)

t.test("the tree shows the roots of game, then the world's actors, in a list that only builds what is in view", function()
    frames(60)
    t.eq(view.flat[1].name, "Character")
    t.eq(view.flat[8].name, "World")
    t.eq(#view.flat, 8 + #world.actors)
    t.ok(#view.tree_cells > 5 and #view.tree_cells < 40, "a screenful of rows for " .. #view.flat .. " lines: " .. #view.tree_cells)
    local line = tree_cell("Character").line:Get()
    t.eq(line.note, "IcarusPlayerCharacter")
    t.eq(line.icon, "user")
    t.eq(line.arrow, false, "an actor can be opened")
    t.eq(tree_cell("GameInstance").line:Get().arrow, nil, "something that is not an actor has nothing under it")
    t.eq(tree_cell("World").line:Get().note, ("%d actors"):format(#world.actors))
    t.eq(tree_cell("World").line:Get().arrow, true)
    t.eq(tree_cell("World").line:Get().icon, "globe")
    t.ok(view.summary:find("actors in this world", 1, true), view.summary)
    for _, name in pairs({ "user", "paw-print", "hammer", "package", "box", "puzzle", "app-window", "circle-dot", "globe" }) do
        t.ok(ui.Icons.Has(name), "the icon " .. name .. " exists")
    end
    t.eq(errors(), 0)
end)

t.test("a row opens to show its children and closes again", function()
    click(tree_cell("Character").line.arrow)
    frames(20)
    t.eq(names(view.flat, 5), "Character,CharacterMesh0,Item_Torch_1,Stat Container,LocalPlayer",
        "its components and what is attached to it, by name")
    local part = tree_cell("CharacterMesh0").line:Get()
    t.eq(part.indent, 1)
    t.eq(part.icon, "puzzle")
    t.eq(part.arrow, false)
    t.eq(tree_cell("Stat Container").line:Get().arrow, nil, "a component that cannot have others attached")
    click(tree_cell("CharacterMesh0").line.arrow)
    frames(20)
    t.eq(names(view.flat, 4), "Character,CharacterMesh0,Hat,Item_Torch_1")
    t.eq(tree_cell("Hat").line:Get().indent, 2)
    -- a new component shows up by itself
    local extra = world.component(stats_class, "Another", { Oxygen = 1, bIsActive = true })
    rawset(extra, "__outer", me)
    table.insert(rawget(me, "__components"), extra)
    frames(240)
    t.eq(names(view.flat, 2), "Character,Another")
    table.remove(rawget(me, "__components"))
    frames(240)
    t.eq(names(view.flat, 2), "Character,CharacterMesh0")
    click(tree_cell("Character").line.arrow)
    frames(20)
    t.eq(names(view.flat, 2), "Character,LocalPlayer")
    click(tree_cell("World").line.arrow)
    frames(20)
    t.eq(#view.flat, 8, "the world closed")
    click(tree_cell("World").line.arrow)
    frames(20)
    t.eq(#view.flat, 8 + #world.actors)
    t.eq(errors(), 0)
end)

t.test("searching and the filters show what fits, with the count", function()
    search("wolf")
    t.eq(names(view.flat), "World,BP_Wolf_C_1", "the roots make way for what was found")
    t.eq(tree_cell("World").line:Get().note, ("1 of %d fit"):format(#world.actors))
    t.eq(tree_cell("BP_Wolf_C_1").line:Get().icon, "paw-print")
    t.eq(tree_cell("BP_Wolf_C_1").line:Get().note, "BP_Wolf_C")
    search("")
    t.eq(#view.flat, 8 + #world.actors)
    click(view.kind.items["Creatures"])
    frames(40)
    t.eq(#view.flat, 1 + 3)
    click(view.sort.items["Newest first"])
    frames(40)
    t.eq(index.current().sort, "newest")
    click(view.range.items["Within 50 m"])
    frames(index.rerun * 2 + 60)
    t.eq(index.current().near, 50)
    t.eq(names(view.flat), "World,BP_Deer_C_7,BP_Deer_C_3,BP_Wolf_C_1", "creatures within 50 m, the newest first")
    click(view.range.items["Any distance"])
    click(view.kind.items["Actors"])
    click(view.sort.items["By name"])
    frames(60)
    t.eq(#view.flat, 8 + #world.actors)
    t.eq(errors(), 0)
end)

t.test("picking a row shows the object: its name, the Lua that reaches it, its class and its members", function()
    t.eq(view.split:IsSingle(), true, "at this width one side shows at a time")
    t.eq(view.split:Shown(), "left")
    click(tree_cell("Character").line.source)
    frames(60)
    t.eq(view.split:Shown(), "right", "the details take the place of the list")
    t.eq(label_text(view.name), "BP_Player_C_7")
    t.eq(label_text(view.path), "game.Character")
    t.eq(explorer.stats().picked, "BP_Player_C_7")
    t.eq(view.shown_rows[1].type, "class")
    t.eq(member_cell("#class").line:Get().value, "IcarusPlayerCharacter")
    click(member_cell("#class").line.source)
    frames(30)
    t.eq(member_cell("#class2").line:Get().value, "Pawn")
    t.eq(member_cell("#class2").line:Get().text, "inherits")
    click(member_cell("#class").line.arrow)
    frames(30)
    t.eq(view.shown_rows[2].type, "member")
    t.ok(#view.cells > 5 and #view.cells < 40, "a screenful of rows: " .. #view.cells)
    -- the way back to the list
    click(view.back.source)
    frames(5)
    t.eq(view.split:Shown(), "left")
    t.eq(tree_cell("Character").line:Get().selected, true, "and the picked row is marked in the list")
    t.eq(tree_cell("LocalPlayer").line:Get().selected, false)
    click(tree_cell("Character").line.source)
    frames(30)
    t.eq(errors(), 0)
end)

t.test("values in view are read again every few frames, and a change is marked for a moment", function()
    find_members("health")
    local cell = member_cell("Health")
    t.eq(cell.line:Get().value, "87.5")
    t.eq(cell.line:Get().note, "float")
    t.eq(cell.line:Get().tone, "text")
    rawget(me, "__props").Health = 42.5
    frames(30)
    t.eq(cell.line:Get().value, "42.5")
    t.eq(cell.line:Get().tone, "warn", "marked as just changed")
    frames(math.ceil(members.RECENT * 60) + 60)
    t.eq(cell.line:Get().tone, "text")
    t.ok(explorer.stats().changed >= 1)
    rawget(me, "__props").Health = 87.5
    frames(30)
end)

t.test("a switch changes a true-or-false value through the checked write and adds a line of Lua", function()
    find_members("crouch")
    local cell = member_cell("bIsCrouched")
    t.ok(cell.flag ~= nil, "a true-or-false row has a switch")
    t.eq(cell.flag:Get(), false)
    t.eq(cell.line:Get().value, "false", "the value is written out beside the switch")
    click(cell.flag.source)
    frames(5)
    t.eq(rawget(me, "__props").bIsCrouched, true)
    t.eq(explorer.changes()[1], "game.Character.bIsCrouched = true")
    click(cell.flag.source)
    frames(5)
    t.eq(rawget(me, "__props").bIsCrouched, false)
    t.eq(explorer.changes()[2], "game.Character.bIsCrouched = false")
    -- the game changes it: the switch follows
    rawget(me, "__props").bIsCrouched = true
    frames(30)
    t.eq(cell.flag:Get(), true)
    rawget(me, "__props").bIsCrouched = false
    frames(30)
    -- a cell that goes on to show something else hides its switch
    find_members("stamina")
    t.eq(cell.line:Get().text, "Stamina")
    t.eq(cell.flag_shown, false)
    t.eq(errors(), 0)
end)

t.test("a picked member is typed into the box at the bottom: numbers, text, names and one part of a struct", function()
    local function edit(key, text)
        click(member_cell(key).line.source)
        frames(2)
        events.simulate(view.edit.source, "OnTextCommitted", text)
        frames(5)
    end
    local props = rawget(me, "__props")
    find_members("stamina")
    t.eq(member_cell("Stamina").line:Get().value, "60")
    click(member_cell("Stamina").line.source)
    frames(2)
    t.eq(label_text(view.edit_name), "Stamina  (int)")
    t.eq(member_cell("Stamina").line:Get().selected, true)
    events.simulate(view.edit.source, "OnTextCommitted", "75")
    frames(5)
    t.eq(props.Stamina, 75)
    t.eq(explorer.changes()[3], "game.Character.Stamina = 75")
    t.eq(member_cell("Stamina").line:Get().value, "75")
    -- text that is not a whole number changes nothing and says why
    local notices = #noticed
    events.simulate(view.edit.source, "OnTextCommitted", "7.5")
    frames(5)
    t.eq(props.Stamina, 75)
    t.eq(#noticed, notices + 1)
    t.ok(noticed[#noticed][1]:find("a whole number is needed", 1, true), noticed[#noticed][1])
    t.eq(noticed[#noticed][2].kind, "bad")
    t.eq(#explorer.changes(), 3, "nothing is added for a change that was not made")

    find_members("health")
    edit("Health", "12.5")
    t.eq(props.Health, 12.5)
    t.eq(explorer.changes()[4], "game.Character.Health = 12.5")
    find_members("nickname")
    edit("Nickname", "Boston \"B\"")
    t.eq(props.Nickname, "Boston \"B\"")
    t.eq(explorer.changes()[5], "game.Character.Nickname = \"Boston \\\"B\\\"\"")
    find_members("tribe")
    edit("Tribe", "Styx")
    t.eq(props.Tribe, "Styx")
    find_members("mode")
    edit("Mode", "3")
    t.eq(props.Mode, 3)
    t.eq(explorer.changes()[7], "game.Character.Mode = 3")
    find_members("name")
    edit("Name", "Bo")
    t.eq(props.Name, "Bo")
    t.eq(explorer.changes()[8], "game.Character:Set(\"Name\", \"Bo\")", "a property called Name is written with Set")

    find_members("spot")
    click(member_cell("Spot").line.arrow)
    frames(30)
    t.eq(member_cell("Spot.Y").line:Get().value, "2.0")
    click(member_cell("Spot").line.source)
    frames(2)
    t.eq(fake.last(view.edit.source, "SetIsEnabled") == nil or view.edit.destroyed == nil, true)
    edit("Spot.Y", "250")
    t.eq(props.Spot.Y, 250)
    t.eq(props.Spot.X, 1, "the other parts stay as they were")
    t.eq(explorer.changes()[9], "game.Character.Spot = { X = 1.0, Y = 250, Z = 3.0 }")
    t.eq(label_text(view.edit_name), "Spot.Y  (float)")
    find_members("tint")
    click(member_cell("Tint").line.arrow)
    frames(30)
    edit("Tint.G", "64")
    t.eq(props.Tint.G, 64)
    edit("Tint.G", "6.5")
    t.eq(props.Tint.G, 64, "a colour's parts are whole numbers")
    t.eq(#explorer.changes(), 10)
    t.eq(errors(), 0)
    t.eq(trapped, 0)
end)

t.test("the Lua for a member, for the object and for every change can be copied", function()
    find_members("health")
    click(member_cell("Health").line.source)
    frames(2)
    copied = {}
    click(view.code.source)
    t.eq(copied[1], "local value = game.Character.Health\ngame.Character.Health = 12.5")
    find_members("spot")
    click(member_cell("Spot.X").line.source)
    frames(2)
    click(view.code.source)
    t.eq(copied[2], "local value = game.Character.Spot.X\ngame.Character.Spot = { X = 1.0, Y = 250, Z = 3.0 }")
    events.simulate(view.show.items["Functions"], "OnClicked")
    find_members("additem")
    click(member_cell("AddItem").line.source)
    frames(2)
    t.eq(member_cell("AddItem").line:Get().value, "(Item: object, Item Count: int)")
    click(view.code.source)
    t.eq(copied[3], "game.Character:AddItem(Item, Item_Count)")
    find_members("getparent")
    click(member_cell("GetParent").line.source)
    frames(2)
    click(view.code.source)
    t.eq(copied[4], "game.Character:Call(\"GetParent\")")
    events.simulate(view.edit.source, "OnTextCommitted", "x")
    frames(3)
    t.eq(#explorer.changes(), 10, "a function is listed and copied, never called or written")
    events.simulate(view.show.items["All"], "OnClicked")
    click(view.copy_path.source)
    t.eq(copied[5], "game.Character")
    click(view.copy_changes.source)
    t.eq(copied[6], table.concat(explorer.changes(), "\n"))
    t.eq(select(2, copied[6]:gsub("\n", "\n")), 9, "ten lines")
    -- every line of it is Lua that runs against the game and does what was done
    rawget(me, "__props").Stamina = 1
    assert(load(copied[6], "=changes", "t", { game = game }))()
    t.eq(rawget(me, "__props").Stamina, 75)
    t.eq(rawget(me, "__props").Name, "Bo")
    click(view.clear_changes.source)
    t.eq(#explorer.changes(), 0)
    local props = rawget(me, "__props")
    props.Stamina, props.Health, props.Nickname, props.Tribe, props.Mode, props.Name = 60, 87.5, "Bo", "Olympus", 2, "a property called Name"
    props.Spot, props.Tint = { X = 1.0, Y = 2.0, Z = 3.0 }, { R = 255, G = 128, B = 0, A = 255 }
    find_members("")
    t.eq(errors(), 0)
end)

t.test("an array opens to its first places, and a place that holds an object is a link", function()
    find_members("carried")
    local cell = member_cell("Carried")
    t.eq(cell.line:Get().value, "3 items")
    t.eq(cell.line:Get().arrow, false)
    click(cell.line.arrow)
    frames(40)
    t.eq(member_cell("Carried[1]").line:Get().value, "Item_Axe_1 (IcarusItem)")
    t.eq(member_cell("Carried[2]").line:Get().value, "none")
    click(member_cell("Carried[2]").line.source)
    frames(2)
    copied = {}
    click(view.code.source)
    t.eq(copied[1], "local value = game.Character.Carried[2]")
    click(member_cell("Carried[3]").line.source)
    frames(30)
    t.eq(label_text(view.name), "Item_Torch_1", "pressing a place with an object in it goes to that object")
    t.eq(label_text(view.path), "game.Character.Carried[3]")
    click(view.previous.source)
    frames(30)
    t.eq(label_text(view.name), "BP_Player_C_7", "and there is a way back")
    t.eq(errors(), 0)
end)

t.test("an object-valued member is a link, and an object that is no actor is found again each frame instead of being kept", function()
    click(view.back.source)
    frames(5)
    click(tree_cell("LocalPlayer").line.source)
    frames(40)
    t.eq(label_text(view.path), "game.LocalPlayer")
    find_members("hud")
    t.eq(member_cell("Hud").line:Get().value, "HUD_Main (Widget)")
    t.eq(member_cell("Hud").line:Get().tone, "accent_hover")
    click(member_cell("Hud").line.source)
    frames(40)
    t.eq(label_text(view.name), "HUD_Main")
    t.eq(label_text(view.path), "game.LocalPlayer.Hud")
    t.eq(view.picked.instance, nil, "a widget is not kept")
    t.ok(view.picked.path ~= nil)
    find_members("opacity")
    t.eq(member_cell("Opacity").line:Get().value, "1.0")
    -- the game swaps the widget for another: the page shows the new one without having held the old one
    local replacement = world.component(widget_class, "HUD_Second", { Opacity = 0.5, Slot = world.INVALID })
    rawget(controller, "__props").Hud = replacement
    rawset(hud, "__freed", true)
    frames(40)
    t.eq(label_text(view.name), "HUD_Second")
    find_members("opacity")
    t.eq(member_cell("Opacity").line:Get().value, "0.5")
    t.eq(world.dead_touches, 0, "the freed widget was never touched")
    -- and when there is none
    rawget(controller, "__props").Hud = world.INVALID
    frames(40)
    t.eq(label_text(view.name), "HUD_Second is gone")
    t.eq(#view.shown_rows, 0)
    rawget(controller, "__props").Hud = replacement
    frames(40)
    t.eq(label_text(view.name), "HUD_Second", "it comes back when the property holds one again")
    t.eq(world.dead_touches, 0)
    t.eq(errors(), 0)
end)

t.test("an actor that is destroyed while its details show is not touched again", function()
    click(view.back.source)
    frames(5)
    search("wolf")
    click(tree_cell("BP_Wolf_C_1").line.source)
    frames(40)
    t.eq(label_text(view.name), "BP_Wolf_C_1")
    t.eq(label_text(view.path), "game:Find(\"BP_Wolf_C\")", "the only wolf left is found by its class")
    t.ok(view.picked.instance ~= nil, "an actor is kept: it is told when it ends play")
    find_members("level")
    t.eq(member_cell("CurrentLevel").line:Get().value, "3")
    world.destroy(near_wolf)
    world.free(near_wolf)
    frames(60)
    t.eq(label_text(view.name), "BP_Wolf_C_1 is gone")
    t.eq(#view.shown_rows, 0)
    events.simulate(view.edit.source, "OnTextCommitted", "9")
    frames(5)
    t.eq(world.dead_touches, 0)
    click(view.back.source)
    frames(40)
    t.eq(names(view.flat), "World", "and it left the list")
    search("")
    t.eq(errors(), 0)
end)

t.test("with room, the list and the details show side by side, and the divider can be dragged", function()
    window:SetSize(1100, 640)
    frames(5)
    t.eq(view.split:IsSingle(), false)
    local share = view.split:GetShare()
    local controls = Wax.import("gui.controls")
    local total = controls.wrap_width(page) + 12
    t.eq(math.floor(controls.wrap_width(view.split.Left) + 0.5), math.floor((total - 7) * share - 12 + 0.5))
    t.eq(math.floor(controls.wrap_width(view.split.Left) + controls.wrap_width(view.split.Right) + 0.5), total - 7 - 12 - 12 - 8)
    click(tree_cell("Character").line.source)
    frames(40)
    t.eq(label_text(view.name), "BP_Player_C_7")
    t.ok(tree_cell("Character") ~= nil, "the list is still there beside the details")
    -- dragging the divider
    ui.Open()
    fake.mouse.X, fake.mouse.Y = 500, 300
    events.simulate(view.split.source, "OnPressed")
    fake.pressed = true
    fake.mouse.X = 600
    frames(1)
    t.ok(view.split:GetShare() > share, "the left side grew")
    local grown = controls.wrap_width(view.split.Left)
    t.eq(math.floor(grown + 0.5), math.floor((total - 7) * share + 100 - 12 + 0.5))
    fake.mouse.X = -5000
    frames(1)
    t.eq(math.floor(controls.wrap_width(view.split.Left) + 0.5), 260 - 12, "neither side gets narrower than it can be used at")
    fake.pressed = false
    frames(1)
    ui.Close()
    ui.SetPreview(true)
    view.split:SetShare(0.42)
    -- narrow again: one side, and it is the one that was being used
    window:SetSize(620, 440)
    frames(5)
    t.eq(view.split:IsSingle(), true)
    t.eq(errors(), 0)
end)

t.test("a map change empties everything without touching the old world, and the new world is listed", function()
    click(view.back.source)
    frames(5)
    click(tree_cell("Character").line.source)
    frames(30)
    local old = {}
    for i, raw in ipairs(world.actors) do old[i] = raw end
    for _, raw in ipairs(old) do world.destroy(raw, 1) end
    for _, raw in ipairs(old) do world.free(raw) end
    local new_settings = world.place(settings_class, "WorldSettings", { Location = { 0, 0, 0 } })
    world.place(tree_class, "BP_Tree_C_new", { Location = { 0, 0, 0 } })
    local new_level = world.component(level_class, "PersistentLevel", { WaxLevelActors = world.array(world.actors), WorldSettings = new_settings })
    local new_world = world.component(world_class, "Terrain_017", { PersistentLevel = new_level, Levels = world.array({ new_level }),
        GameState = world.INVALID, AuthorityGameMode = world.INVALID, TimeSeconds = 0 })
    rawget(viewport, "__props").World = new_world
    -- the new map has its own controller, and no character yet
    local new_controller = world.place(controller_class, "PlayerController_1",
        { Pawn = world.INVALID, PlayerCameraManager = world.INVALID, Hud = world.INVALID, Location = { 0, 0, 0 } })
    rawget(local_player, "__props").PlayerController = new_controller
    rawset(the_world, "__freed", true)
    game_module.step()
    frames(120)
    t.eq((index.counts()), 3)
    click(view.back.source)
    frames(30)
    t.eq(names(view.flat),
        "Character,LocalPlayer,GameState,GameMode,GameInstance,Viewport,Engine,World,BP_Tree_C_new,PlayerController_1,WorldSettings")
    t.eq(tree_cell("LocalPlayer").line:Get().note, "PlayerController")
    t.eq(tree_cell("Character").line:Get().note, "none")
    t.eq(tree_cell("Character").line:Get().faint, true)
    click(tree_cell("Character").line.source)
    frames(5)
    t.eq(view.split:Shown(), "left", "something that is not there cannot be picked")
    t.eq(world.dead_touches, 0, tostring(world.dead_where))
    t.eq(errors(), 0)
end)

t.test("an idle frame is cheap, and a frame with the page closed is free", function()
    click(tree_cell("GameInstance").line.source)
    frames(60)
    local started, count = os.clock(), 3000
    frames(count)
    local open_cost = (os.clock() - started) / count * 1e6
    local reads = explorer.stats().reads
    frames(100)
    local per_frame = (explorer.stats().reads - reads) / 100
    t.ok(per_frame <= members.POLL + explorer.VISIBLE, "at most the watched and the shown values are read: " .. per_frame)
    window:SelectPage("Mods")
    frames(2)
    local before = world.touches
    started = os.clock()
    for _ = 1, 20000 do explorer.step() end
    local closed_cost = (os.clock() - started) / 20000 * 1e6
    t.eq(world.touches, before)
    t.eq(index.stats().awake, false)
    print(("  measured here (Lua only, no engine): %.1f us a frame with the page open and idle, including the scheduler and the rest of "
        .. "the interface; %.3f us a frame with it closed"):format(open_cost, closed_cost))
    t.ok(closed_cost < 2, "closed, a frame costs next to nothing: " .. closed_cost)
    window:SelectPage("Explorer")
    frames(5)
end)

t.test("everything the page made belongs to it: once the window is gone nothing of it is used again", function()
    -- the notices shown along the way were made in between too, and are not the page's
    ui.Notifications.Clear()
    frames(2)
    local objects_after = fake.mark()
    panel_scope:destroy()
    fake.free(objects_before, objects_after)
    fake.dead_touches = 0
    frames(30)
    ui.SetTheme("Dune")
    ui.SetTheme("Midnight")
    ui.SetScale(1.25)
    ui.SetScale(1)
    frames(30)
    t.ok(fake.dead_touches == 0, "touched something that was freed: " .. tostring(fake.dead_last) .. tostring(fake.dead_where))
    t.eq(explorer.stats().built, false, "the page noticed its window is gone")
    t.eq(index.stats().awake, false)
    t.eq(actors.stats().listening, false)
    t.eq(ui.stats().handlers, 0)
    t.eq(errors(), 0)
end)

t.test("a page built again starts clean, and a page with no game behind it only says so", function()
    local again = scope.new("again")
    scope.run(again, function()
        window = ui.Window({ title = "Wax", nav = "side", width = 620, height = 440 })
        page = window:Page("Explorer", { icon = "folder-tree", scroll = false })
        explorer.build(page)
        explorer.build(page)
    end)
    view = explorer.view()
    frames(60)
    t.eq((index.counts()), 3)
    t.eq(errors(), 0)
    again:destroy()
    frames(2)
    local held = Wax.game
    Wax.game = nil
    local bare = scope.new("bare")
    scope.run(bare, function()
        window = ui.Window({ title = "Wax", nav = "side" })
        explorer.build(window:Page("Explorer", { scroll = false }))
    end)
    t.eq(explorer.view(), nil)
    frames(5)
    bare:destroy()
    Wax.game = held
    t.eq(errors(), 0)
end)

ui.Copy, ui.Notify = real_copy, real_notify
t.finish("explorer")
