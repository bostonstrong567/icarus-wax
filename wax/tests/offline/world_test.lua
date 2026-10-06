-- Offline tests for the tracked lists, game.Creatures and game.Highlight.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\world_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local world = dofile("wax/tests/offline/fake_world.lua")
world.install()

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)

local object = world.class("/Script/CoreUObject.Object")
local actor_class = world.class("/Script/Engine.Actor", object)
world.class("/Script/Engine.World", object)
local component_class = world.class("/Script/Engine.ActorComponent", object)
local scene_class = world.class("/Script/Engine.SceneComponent", component_class)
local primitive_class = world.class("/Script/Engine.PrimitiveComponent", scene_class)
local mesh_class = world.class("/Script/Engine.MeshComponent", primitive_class,
    { bRenderCustomDepth = "BoolProperty", CustomDepthStencilValue = "IntProperty" })
local state_class = world.class("/Script/Icarus.ActorState", component_class,
    { Health = "IntProperty", MaxHealth = "IntProperty", CurrentAliveState = "EnumProperty" })
local pawn = world.class("/Script/Engine.Pawn", actor_class)
local npc = world.class("/Script/Icarus.IcarusNPCCharacter", pawn,
    { AISetupRow = "StructProperty", ActorState = "ObjectProperty", CurrentLevel = "IntProperty" })
local goap = world.class("/Script/Icarus.IcarusNPCGOAPCharacter", npc, { AISetup = "StructProperty" })
local icarus_pawn = world.class("/Script/Icarus.IcarusPawn", pawn, { AISetup = "StructProperty", ActorState = "ObjectProperty" })
local wolf_class = world.class("/Game/BP/AI/BP_NPC_Wolf_Conifer_Character.BP_NPC_Wolf_Conifer_Character_C", goap)
local deer_class = world.class("/Game/BP/AI/BP_NPC_Deer_Character.BP_NPC_Deer_Character_C", goap)
local worm_class = world.class("/Game/BP/AI/BP_CRE_CaveWorm.BP_CRE_CaveWorm_C", icarus_pawn)
local rock_class = world.class("/Game/BP/BP_Rock.BP_Rock_C", actor_class)
local player_class = world.class("/Game/BP/BP_IcarusPlayerCharacterSurvival.BP_IcarusPlayerCharacterSurvival_C", pawn,
    { HighlightablePostProcess = "ObjectProperty" })
local pass_class = world.class("/Script/Engine.PostProcessComponent", scene_class)
world.static["/Script/Engine.Default__KismetMaterialLibrary"] = world.object("Default__KismetMaterialLibrary", {})
local outline_material = world.object("PPI_OutlineColored", {})

-- A player character carrying the game's outline pass. Returns the pawn and the slot the material sits in.
local function player()
    local slot = { Weight = 1, Object = outline_material }
    local pass = world.component(pass_class, "HighlightablePostProcess",
        { Settings = { WeightedBlendables = { Array = world.array({ slot }) } } })
    local me = world.place(player_class, "Player_" .. tostring(slot):sub(-6), { HighlightablePostProcess = pass, Location = { 0, 0, 0 } }, { pass })
    world.possess(me)
    return me, slot
end

local function soft(path)
    return { GetObjectID = function() return { GetAssetPathName = function() return world.name(path) end } end }
end
world.table("/Engine/Transient.D_AICreatureType", {
    Wolf = { CreatureName = world.name("Wolf"), Tag = { TagName = world.name("NPC.Wolf") } },
    Deer = { CreatureName = world.name("Deer"), Tag = { TagName = world.name("NPC.Deer") } },
    Caveworm = { CreatureName = world.name("Cave Worm"), Tag = { TagName = world.name("NPC.CaveWorm") } },
}, { "Wolf", "Deer", "Caveworm" })
world.table("/Engine/Transient.D_AISetup", {
    Conifer_Wolf = { CreatureType = world.handle("Wolf"), ActorClass = soft("/Game/BP/AI/BP_NPC_Wolf_Conifer_Character.BP_NPC_Wolf_Conifer_Character_C") },
    Arctic_Wolf = { CreatureType = world.handle("Wolf"), ActorClass = soft("/Game/BP/AI/BP_NPC_Wolf_Arctic.BP_NPC_Wolf_Arctic_C") },
    Deer = { CreatureType = world.handle("Deer"), ActorClass = soft("/Game/BP/AI/BP_NPC_Deer_Character.BP_NPC_Deer_Character_C") },
    CaveWorm = { CreatureType = world.handle("CaveWorm"), ActorClass = soft("/Game/BP/AI/BP_CRE_CaveWorm.BP_CRE_CaveWorm_C") },
}, { "Conifer_Wolf", "Arctic_Wolf", "Deer", "CaveWorm" })

local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local sched = Wax.import("core.sched")
local instance = Wax.import("engine.instance")
local game = Wax.import("engine.game")
instance.start()
Wax.game = game.root
Wax.import("engine.actors").start()
local track = Wax.import("engine.track")
track.start()
local creatures_module = Wax.import("world.creatures")
creatures_module.start()
local highlight_module = Wax.import("world.highlight")
highlight_module.start()
local Creatures, Highlight = game.root.Creatures, game.root.Highlight

local serial = 0
local function creature(class, row, at, options)
    options = options or {}
    serial = serial + 1
    local state = world.component(state_class, "ActorState",
        { Health = options.health or 100, MaxHealth = 100, CurrentAliveState = options.dead and 1 or 0 })
    local mesh = world.component(mesh_class, "CharacterMesh0", { bRenderCustomDepth = true, CustomDepthStencilValue = 1, bVisible = true })
    local props = { AISetup = world.handle(row), AISetupRow = world.handle(row), ActorState = state,
                    CurrentLevel = options.level or 5, Location = at or { 0, 0, 0 } }
    local make = options.placed and world.place or world.spawn
    return make(class, rawget(class, "__name") .. "_" .. serial, props, { state, mesh }), state, mesh
end

local function frame()
    sched.step()
    track.step()
    highlight_module.step()
end

local function errors() return #guard.errors() end

-- Three creatures and a rock are in the world before anything asks about creatures.
local first_wolf = creature(wolf_class, "Conifer_Wolf", { 1000, 0, 0 }, { placed = true })
local first_deer = creature(deer_class, "Deer", { 5000, 0, 0 }, { placed = true })
local first_worm = creature(worm_class, "CaveWorm", { 0, 20000, 0 }, { placed = true })
world.place(rock_class, "BP_Rock_1", { Location = { 0, 0, 0 } })

t.test("nothing is tracked until a mod asks", function()
    t.eq(track.stats().sets.creatures.tracking, false)
    t.eq(track.stats().hooks.listening, false)
end)

t.test("creatures that were already there are listed, by kind, variant, shown name and class", function()
    t.eq(Creatures:Count(), 3)
    t.eq(#Creatures:GetAll("Wolf"), 1)
    t.eq(#Creatures:GetAll("wolf"), 1, "case does not matter")
    t.eq(#Creatures:GetAll("Conifer_Wolf"), 1)
    t.eq(#Creatures:GetAll("conifer wolf"), 1, "spaces and underscores do not matter")
    t.eq(#Creatures:GetAll("Arctic_Wolf"), 0)
    t.eq(#Creatures:GetAll("Cave Worm"), 1, "the name the game shows")
    t.eq(#Creatures:GetAll("IcarusPawn"), 1, "a class name")
    t.eq(Creatures:Count("Deer"), 1)
    t.eq(table.concat(Creatures:GetLiveKinds(), ","), "Caveworm,Deer,Wolf")
    t.eq(track.stats().hooks.listening, true)
end)

t.test("an unknown kind raises with the nearest names", function()
    local err = t.raises(function() Creatures:GetAll("Wolff") end, "is not a creature kind")
    t.ok(tostring(err):find("'Wolf'", 1, true), "suggests Wolf: " .. tostring(err))
    t.ok(tostring(err):find("world_test.lua", 1, true), "points at the caller: " .. tostring(err))
    t.raises(function() Creatures:GetAll(12) end, "a creature kind is a name")
end)

t.test("GetKinds lists every kind of this game version with its variants", function()
    local kinds = Creatures:GetKinds()
    t.eq(#kinds, 3)
    t.eq(kinds[1].Name, "Caveworm")
    t.eq(kinds[1].DisplayName, "Cave Worm")
    t.eq(kinds[3].Name, "Wolf")
    t.eq(table.concat(kinds[3].Variants, ","), "Conifer_Wolf,Arctic_Wolf")
    t.eq(kinds[3].Count, 1)
end)

t.test("a creature that appears fires Added on the next frame and one that leaves fires Removed", function()
    local added, removed = {}, {}
    local on_added = Creatures.Added:Connect(function(creature_instance) added[#added + 1] = creature_instance end)
    local on_removed = Creatures.Removed:Connect(function(creature_instance, info) removed[#removed + 1] = { creature_instance, info } end)
    local wolf = creature(wolf_class, "Conifer_Wolf", { 300, 400, 0 })
    world.spawn(rock_class, "BP_Rock_2", { Location = { 0, 0, 0 } })
    t.eq(#added, 0, "not announced inside the engine's call")
    frame()
    t.eq(#added, 1)
    t.eq(added[1].ClassName, "BP_NPC_Wolf_Conifer_Character_C")
    t.eq(Creatures:Count("Wolf"), 2)
    local kind, variant = Creatures:GetKind(added[1])
    t.eq(kind, "Wolf")
    t.eq(variant, "Conifer_Wolf")

    world.destroy(wolf)
    t.eq(Creatures:Count("Wolf"), 1, "out of the list at once")
    t.eq(#removed, 0)
    world.free(wolf)
    frame()
    t.eq(#removed, 1)
    t.ok(removed[1][1] == added[1], "the same Instance")
    t.eq(removed[1][2].Kind, "Wolf")
    t.eq(removed[1][2].Reason, "Destroyed")
    t.eq(removed[1][2].Position.X, 300)
    t.eq(added[1]:IsValid(), false)
    t.raises(function() return added[1].Name end, "no longer exists")
    t.eq(tostring(added[1]), "BP_NPC_Wolf_Conifer_Character_C (destroyed)")
    t.eq(Creatures:GetKind(added[1]), nil)
    on_added:Disconnect()
    on_removed:Disconnect()
    t.eq(world.dead_touches, 0, "nothing touched the freed actor")
    t.eq(errors(), 0)
end)

t.test("a component's Instance is retired with its actor", function()
    local wolf, state = creature(wolf_class, "Conifer_Wolf", { 0, 0, 0 })
    frame()
    local held = instance.wrap(state)
    t.eq(held.Health, 100)
    world.destroy(wolf)
    world.free(wolf)
    t.raises(function() return held.Health end, "no longer exists")
    frame()
    t.eq(world.dead_touches, 0)
end)

t.test("within, from and GetNearest measure in metres and sort nearest first", function()
    local from = { X = 0, Y = 0, Z = 0 }
    local near = Creatures:GetAll({ within = 60, from = from })
    t.eq(#near, 2, "the wolf at 10 m and the deer at 50 m")
    t.eq(near[1].ClassName, "BP_NPC_Wolf_Conifer_Character_C")
    t.eq(near[2].ClassName, "BP_NPC_Deer_Character_C")
    t.eq(#Creatures:GetAll("Deer", { within = 20, from = from }), 0)
    local nearest, distance = Creatures:GetNearest("Deer", { from = from })
    t.eq(nearest.ClassName, "BP_NPC_Deer_Character_C")
    t.eq(distance, 50)
    local worm, worm_distance = Creatures:GetNearest({ from = instance.wrap(first_worm) })
    t.eq(worm.ClassName, "BP_CRE_CaveWorm_C")
    t.eq(worm_distance, 0)
    t.eq((Creatures:GetNearest("Arctic_Wolf", { from = from })), nil)
    t.raises(function() Creatures:GetAll({ within = 10 }) end, "there is no character to measure from")
    t.raises(function() Creatures:GetAll({ within = "far", from = from }) end, "number of metres")
end)

t.test("the dead are left out unless asked for, and Died fires once", function()
    local died = {}
    local connection = Creatures.Died:Connect(function(creature_instance, info) died[#died + 1] = info.Kind end)
    local deer, state = creature(deer_class, "Deer", { 0, 0, 0 })
    frame()
    frame()
    t.eq(#Creatures:GetAll("Deer"), 2)
    state.CurrentAliveState = 1
    t.eq(#Creatures:GetAll("Deer"), 1)
    t.eq(#Creatures:GetAll("Deer", { dead = true }), 2)
    for _ = 1, 4 do frame() end
    t.eq(table.concat(died, ","), "Deer")
    local described = Creatures:Describe(Creatures:GetAll("Deer", { dead = true, within = 1, from = { X = 0, Y = 0, Z = 0 } })[1])
    t.eq(described.IsAlive, false)
    t.eq(described.DisplayName, "Deer")
    t.eq(described.Level, 5)
    connection:Disconnect()
    world.destroy(deer)
    world.free(deer)
    frame()
end)

t.test("a creature whose row is filled in late is announced once it is known", function()
    local seen = {}
    local connection = Creatures.Added:Connect(function(creature_instance) seen[#seen + 1] = (Creatures:GetKind(creature_instance)) end)
    local wolf = creature(wolf_class, "None", { 0, 0, 0 })
    frame()
    frame()
    t.eq(#seen, 0)
    wolf.AISetup = world.handle("Arctic_Wolf")
    frame()
    t.eq(table.concat(seen, ","), "Wolf")
    t.eq(#Creatures:GetAll("Arctic_Wolf"), 1)
    local unnamed = creature(deer_class, "None", { 0, 0, 0 })
    for _ = 1, 31 do frame() end
    t.eq(table.concat(seen, ","), "Wolf,Deer", "after waiting, the class says what it is")
    connection:Disconnect()
    for _, gone in ipairs({ wolf, unnamed }) do
        world.destroy(gone)
        world.free(gone)
    end
    frame()
end)

t.test("Observe sees those here now and later, and its clean-up runs when one leaves or the watch stops", function()
    local log = {}
    local connection = Creatures:Observe("Wolf", function(creature_instance)
        log[#log + 1] = "in"
        return function() log[#log + 1] = "out" end
    end)
    t.eq(table.concat(log, ","), "in", "the wolf that was already there")
    local wolf = creature(wolf_class, "Conifer_Wolf", { 0, 0, 0 })
    creature(deer_class, "Deer", { 0, 0, 0 })
    frame()
    t.eq(table.concat(log, ","), "in,in")
    world.destroy(wolf)
    world.free(wolf)
    frame()
    t.eq(table.concat(log, ","), "in,in,out")
    connection:Disconnect()
    t.eq(table.concat(log, ","), "in,in,out,out")
    creature(wolf_class, "Conifer_Wolf", { 0, 0, 0 })
    frame()
    t.eq(#log, 4, "nothing after the watch stopped")
    t.eq(errors(), 0)
end)

t.test("a highlight marks every mesh, comes back when the game overwrites it, and is undone exactly", function()
    local wolf, _, mesh = creature(wolf_class, "Conifer_Wolf", { 0, 0, 0 })
    frame()
    local target = instance.wrap(wolf)
    local mark = Highlight:Add(target, { Color = "cyan" })
    t.eq(mesh.CustomDepthStencilValue, 253)
    t.eq(mark.Color, "cyan")
    mesh.CustomDepthStencilValue = 255
    for _ = 1, 8 do frame() end
    t.eq(mesh.CustomDepthStencilValue, 253, "put back after the game's own outline")
    mark:SetColor("Yellow")
    t.eq(mesh.CustomDepthStencilValue, 248)
    mark:Remove()
    t.eq(mesh.CustomDepthStencilValue, 1, "what a creature had before")
    t.eq(mesh.bRenderCustomDepth, true)
    t.eq(mark.Active, false)
    mark:Remove()
    t.raises(function() Highlight:Add(target, { Color = "Pinkk" }) end, "is not a colour")
    t.raises(function() Highlight:Add(target, { Fill = "yes" }) end, "Fill is true or false")
    t.raises(function() Highlight:Add("wolf") end, "something with a shape")
end)

t.test("one part of an actor can be outlined on its own, and goes with its actor", function()
    local wolf, state, mesh = creature(wolf_class, "Conifer_Wolf", { 0, 0, 0 })
    frame()
    t.raises(function() Highlight:Add(instance.wrap(state)) end, "something with a shape")
    local mark = Highlight:Add(instance.wrap(mesh), { Color = "Yellow" })
    t.eq(mesh.CustomDepthStencilValue, 248)
    mark:Remove()
    t.eq(mesh.CustomDepthStencilValue, 1)
    mark = Highlight:Add(instance.wrap(mesh))
    world.destroy(wolf)
    world.free(wolf)
    for _ = 1, 4 do frame() end
    t.eq(mark.Active, false)
    t.eq(world.dead_touches, 0)
end)

t.test("a highlighted actor that ends play is never touched again", function()
    local wolf, _, mesh = creature(wolf_class, "Conifer_Wolf", { 0, 0, 0 })
    frame()
    local mark = Highlight:Add(instance.wrap(wolf))
    t.eq(mesh.CustomDepthStencilValue, 252)
    world.destroy(wolf)
    world.free(wolf)
    for _ = 1, 6 do frame() end
    t.eq(mark.Active, false)
    mark:Remove()
    t.eq(world.dead_touches, 0)
    t.eq(#Highlight:GetAll(), 0)
end)

t.test("Creatures:Highlight follows a kind, and a mod's scope undoes all of it", function()
    local mod = scope.new("mod")
    local deer_mesh = select(3, creature(deer_class, "Deer", { 0, 0, 0 }))
    frame()
    scope.run(mod, function() Creatures:Highlight("Deer", { Color = "Green" }) end)
    t.eq(deer_mesh.CustomDepthStencilValue, 251)
    local later_mesh = select(3, creature(deer_class, "Deer", { 0, 0, 0 }))
    frame()
    t.eq(later_mesh.CustomDepthStencilValue, 251, "one that appeared later")
    t.raises(function() Creatures:Highlight("Deer", { Color = "Pinkk" }) end, "is not a colour")
    mod:destroy()
    t.eq(deer_mesh.CustomDepthStencilValue, 1)
    t.eq(later_mesh.CustomDepthStencilValue, 1)
    t.eq(#Highlight:GetAll(), 0)
    t.eq(errors(), 0)
end)

t.test("with the player's outline pass any colour can be used, and a colour takes one slot however many use it", function()
    local _, slot = player()
    local meshes, targets = {}, {}
    for i = 1, 6 do
        local wolf, _, mesh = creature(wolf_class, "Conifer_Wolf", { 0, 0, 0 })
        meshes[i], targets[i] = mesh, wolf
    end
    frame()
    local function wrap(i) return instance.wrap(targets[i]) end
    local orange = Highlight:Add(wrap(1), { Color = "#ff8000" })
    local copy = slot.Object
    t.ok(copy ~= outline_material, "a copy of the material is in place")
    t.eq(copy.Parent, outline_material)
    t.eq(meshes[1].CustomDepthStencilValue, 248, "the first slot that tints the model")
    t.eq(copy.Color1.R, 1.5)
    t.ok(math.abs(copy.Color1.G - 0.3238) < 0.01, "a screen colour is converted for the material")
    t.eq(copy.FillAlpha, 0.25)
    Highlight:Add(wrap(2), { Color = "#ff8000" })
    t.eq(meshes[2].CustomDepthStencilValue, 248, "the same colour shares the slot")
    Highlight:Add(wrap(3), { Color = { R = 0, G = 0, B = 1 } })
    t.eq(meshes[3].CustomDepthStencilValue, 249)
    t.eq(copy.Color2.B, 1.5)
    local line = Highlight:Add(wrap(4), { Color = "Blue", Fill = false })
    t.eq(meshes[4].CustomDepthStencilValue, 254, "outline only")
    t.eq(copy.Color8, world.INVALID, "the game's look-at colour is left alone")

    orange:Set({ Color = "Green" })
    t.eq(meshes[1].CustomDepthStencilValue, 248, "it keeps its slot and the slot changes colour")
    t.eq(copy.Color1.G, 1.5)
    t.eq(meshes[2].CustomDepthStencilValue, 250, "the other orange one moved to a slot of its own")
    line:Set({ Fill = true })
    t.eq(meshes[4].CustomDepthStencilValue, 251)

    Highlight:Add(wrap(5), { Color = "Pink" })
    t.eq(meshes[5].CustomDepthStencilValue, 250, "no slot left, so the nearest colour in use")
    local shared = Highlight:Look({ Color = "White", Fill = false })
    local sixth = Highlight:Add(wrap(6), shared)
    t.eq(meshes[6].CustomDepthStencilValue, 254)
    t.eq(copy.Color7.R, 1.5)
    shared:Set({ Color = "#0000ff" })
    frame()
    t.eq(meshes[6].CustomDepthStencilValue, 254, "a look that changes colour keeps its slot")
    t.eq(copy.Color7.R, 0)
    t.eq(copy.Color7.B, 1.5)
    sixth:Remove()
    t.eq(Highlight:Configure({ Fill = 0.6, Width = 9 }).Width, 4)
    t.eq(copy.FillAlpha, 0.6)
    t.eq(copy.OutlineThickness, 4)
    t.eq(errors(), 0)
end)

t.test("a tint with a colour of its own is drawn by a second copy of the material", function()
    local me = Wax.game.Character
    local list = me.Raw.HighlightablePostProcess.Settings.WeightedBlendables.Array
    t.eq(list:GetArrayNum(), 1, "one copy while every tint has its outline's colour")
    local wolf, _, mesh = creature(wolf_class, "Conifer_Wolf", { 0, 0, 0 })
    frame()
    Highlight:Clear()
    frame()
    local mark = Highlight:Add(instance.wrap(wolf), { Color = "#ff0000", FillColor = "#0000ff" })
    t.eq(mesh.CustomDepthStencilValue, 248)
    t.eq(list:GetArrayNum(), 2)
    local lines, tints = list[1].Object, list[2].Object
    t.eq(list[2].Weight, 1)
    t.eq(lines.Color1.R, 1.5)
    t.eq(lines.FillAlpha, 0, "the first copy draws lines only")
    t.eq(tints.Color1.B, 1.5)
    t.eq(tints.Color1.R, 0)
    t.eq(tints.OutlineThickness, 0, "the second draws tints only")
    t.ok(tints.FillAlpha > 0)
    mark:Set({ FillColor = false })
    t.eq(list[2].Weight, 0, "switched off again when no tint needs it")
    t.ok(lines.FillAlpha > 0)
    t.raises(function() mark:Set({ FillColor = "nope" }) end, "is not a colour")
    mark:Remove()
    frame()
    t.eq(errors(), 0)
end)

t.test("a new character gets the colours again, and the game's material comes back when nothing is outlined", function()
    local wolf = creature(wolf_class, "Conifer_Wolf", { 0, 0, 0 })
    frame()
    Highlight:Add(instance.wrap(wolf), { Color = "Green" })
    local _, new_slot = player()
    for _ = 1, 31 do frame() end
    local copy = new_slot.Object
    t.ok(copy ~= outline_material, "the new character has a copy")
    t.eq(copy.Color1.G, 1.5)
    t.eq(copy.FillAlpha, 0.6)
    Highlight:Clear()
    t.eq(#Highlight:GetAll(), 0)
    frame()
    t.eq(new_slot.Object, outline_material)
    Highlight:Configure({ Fill = 0.25, Width = 1 })
    world.possess(nil)
    t.eq(errors(), 0)
end)

t.test("a map change clears the lists without touching the old world, and the new world is found", function()
    local cleared, added = 0, 0
    local on_cleared = Creatures.Cleared:Connect(function() cleared = cleared + 1 end)
    local on_added = Creatures.Added:Connect(function() added = added + 1 end)
    local held = Creatures:GetAll("Wolf")[1]
    Highlight:Add(held)
    local old = {}
    for i, actor in ipairs(world.actors) do old[i] = actor end
    for _, actor in ipairs(old) do world.destroy(actor, 1) end
    for _, actor in ipairs(old) do world.free(actor) end
    creature(wolf_class, "Arctic_Wolf", { 0, 0, 0 }, { placed = true })
    instance.flush()
    game.root.MapChanged:Fire("Terrain_New")
    t.eq(cleared, 1)
    t.eq(Creatures:Count(), 0)
    frame()
    t.eq(added, 1, "the creature of the new map")
    t.eq(Creatures:Count("Arctic_Wolf"), 1)
    t.eq(held:IsValid(), false)
    t.eq(#Highlight:GetAll(), 0)
    for _ = 1, 4 do frame() end
    on_cleared:Disconnect()
    on_added:Disconnect()
    t.eq(world.dead_touches, 0)
    t.eq(errors(), 0)
end)

t.finish("world")
