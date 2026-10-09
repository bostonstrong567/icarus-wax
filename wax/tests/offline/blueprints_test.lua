-- Offline tests for game.Blueprints: things described in Lua and spawned, their parts, their functions and who owns them.
-- The engine is a stand-in that takes values the way the game does and is unkind: a destroyed actor is freed at once and
-- raises on any use, and a map change frees every actor. game.Assets is the real module over a stand-in of its own.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\blueprints_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local world = dofile("wax/tests/offline/fake_world.lua")
world.install()
local values = dofile("wax/tests/offline/fake_values.lua")
values.install(world)
local wording = dofile("wax/tests/offline/wording.lua")

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)

local INVALID = world.INVALID
local plain = values.plain
local BOOL, INT, FLOAT, OBJECT, CLASS, STRUCT, ARRAY = "BoolProperty", "IntProperty", "FloatProperty", "ObjectProperty",
    "ClassProperty", "StructProperty", "ArrayProperty"
local VECTOR, ROTATOR, QUAT, TRANSFORM = "/Script/CoreUObject.Vector", "/Script/CoreUObject.Rotator", "/Script/CoreUObject.Quat",
    "/Script/CoreUObject.Transform"
local VECTOR2D, COLOR, TANGENT, HIT = "/Script/CoreUObject.Vector2D", "/Script/CoreUObject.LinearColor",
    "/Script/ProceduralMeshComponent.ProcMeshTangent", "/Script/Engine.HitResult"
values.struct(VECTOR, nil, { { "X", FLOAT }, { "Y", FLOAT }, { "Z", FLOAT } })
values.struct(ROTATOR, nil, { { "Pitch", FLOAT }, { "Yaw", FLOAT }, { "Roll", FLOAT } })
values.struct(QUAT, nil, { { "X", FLOAT }, { "Y", FLOAT }, { "Z", FLOAT }, { "W", FLOAT } })
values.struct(TRANSFORM, nil, { { "Rotation", STRUCT, struct = QUAT }, { "Translation", STRUCT, struct = VECTOR },
    { "Scale3D", STRUCT, struct = VECTOR } })
values.struct(VECTOR2D, nil, { { "X", FLOAT }, { "Y", FLOAT } })
values.struct(COLOR, nil, { { "R", FLOAT }, { "G", FLOAT }, { "B", FLOAT }, { "A", FLOAT } })
values.struct(TANGENT, nil, { { "TangentX", STRUCT, struct = VECTOR }, { "bFlipTangentY", BOOL } })
values.struct(HIT, nil, { { "bBlockingHit", BOOL } })

local function near(got, want, what)
    if type(got) ~= "number" or math.abs(got - want) > 0.0005 then
        error((what or "value") .. ": expected about " .. tostring(want) .. ", got " .. tostring(got), 2)
    end
end

-- Every number of a transform is there, the turn has length 1 and no size is 0.
local function full(transform, what)
    local turn, place, size = transform.Rotation, transform.Translation, transform.Scale3D
    t.ok(turn and place and size, what .. ": a transform is written with its turn, its place and its size")
    near(turn.X ^ 2 + turn.Y ^ 2 + turn.Z ^ 2 + turn.W ^ 2, 1, what .. ": the length of the turn")
    for _, key in ipairs({ "X", "Y", "Z" }) do
        t.ok(type(place[key]) == "number", what .. ": the place has " .. key)
        t.ok(type(size[key]) == "number" and size[key] ~= 0, what .. ": the size has " .. key)
    end
end

-- the engine: what was asked of it, and what it is told to do wrong
local engine = {}
local function reset_engine()
    engine.world_begun, engine.begin_gives_nothing, engine.begin_raises, engine.overlap_raises = true, false, false, false
    engine.refuse, engine.spawns, engine.begins, engine.late, engine.overlaps = {}, {}, {}, {}, {}
    engine.made, engine.destroyed, engine.filter = engine.made or 0, 0, nil
end
reset_engine()

local by_path = {}      -- lower-case path -> class: what the game has in memory whatever is loaded
local object_class = values.class("/Script/CoreUObject.Object")
local class_class = values.class("/Script/CoreUObject.Class", object_class)
local blueprint_class = values.class("/Script/Engine.BlueprintGeneratedClass", class_class)
rawset(object_class, "__class", class_class)
rawset(class_class, "__class", class_class)
rawset(blueprint_class, "__class", class_class)
local function class(path, super, members, functions)
    local made = values.class(path, super, members, functions)
    rawset(made, "__class", path:sub(1, 6) == "/Game/" and blueprint_class or class_class)
    by_path[path:lower()] = made
    return made
end

local world_class = class("/Script/Engine.World", object_class, { AuthorityGameMode = OBJECT })
local component_class = class("/Script/Engine.ActorComponent", object_class)
local scene_class, primitive_class

local function begin_play(actor)
    if not engine.world_begun then
        engine.late[#engine.late + 1] = actor
        return
    end
    engine.begins[actor] = (engine.begins[actor] or 0) + 1
    values.of(actor).parts_at_begin = #rawget(actor, "__components")
    if world.began then world.began({ get = function() return actor end }) end
end

-- The world begins play after all: every actor that waited begins now.
local function begin_world()
    engine.world_begun = true
    local late = engine.late
    engine.late = {}
    for _, actor in ipairs(late) do
        if not rawget(actor, "__freed") then begin_play(actor) end
    end
end

local function new_actor(actor_class, place, turn)
    engine.made = engine.made + 1
    local actor, store = values.actor(actor_class, rawget(actor_class, "__name") .. "_" .. engine.made,
        { Location = { place.X, place.Y, place.Z }, Turn = turn or { Pitch = 0, Yaw = 0, Roll = 0 }, RootComponent = INVALID })
    if rawget(actor_class, "__own_root") then
        local root, root_store = values.part(scene_class, "DefaultSceneRoot", { AttachParent = INVALID, Mobility = 2, registered = true })
        rawset(root, "__outer", actor)
        rawget(actor, "__components")[1] = root
        store.RootComponent, root_store.is_own_root = root, true
    end
    return actor, store
end

local actor_class = class("/Script/Engine.Actor", object_class, { RootComponent = OBJECT, bHidden = BOOL, InitialLifeSpan = FLOAT }, {
    AddComponentByClass = { { "Class", CLASS }, { "bManualAttachment", BOOL }, { "RelativeTransform", STRUCT, struct = TRANSFORM },
        { "bDeferredFinish", BOOL }, returns = OBJECT, call = function(self, args)
            local part_class = args.Class
            if engine.refuse[rawget(part_class, "__name")] then return INVALID end
            t.eq(args.bManualAttachment, false, "a part is attached by the engine")
            t.eq(args.bDeferredFinish, true, "a part is finished by FinishAddComponent")
            full(args.RelativeTransform, "AddComponentByClass")
            engine.made = engine.made + 1
            local part, store = values.part(part_class, rawget(part_class, "__name") .. "_" .. engine.made,
                { AttachParent = INVALID, registered = false, added_with = args.RelativeTransform, sections = {}, materials = {},
                  actor_began = engine.begins[self] ~= nil })
            rawset(part, "__outer", self)
            local parts = rawget(self, "__components")
            parts[#parts + 1] = part
            return part
        end },
    FinishAddComponent = { { "Component", OBJECT }, { "bManualAttachment", BOOL }, { "RelativeTransform", STRUCT, struct = TRANSFORM },
        call = function(self, args)
            local part, placement = args.Component, args.RelativeTransform
            local store, mine = values.of(part), values.of(self)
            t.eq(store.registered, false, "a part is finished once")
            full(placement, "FinishAddComponent")
            t.eq(placement.Translation.Z, store.added_with.Translation.Z, "both calls for a part are given one transform")
            store.registered = true
            if part:IsA(scene_class) then
                t.eq(store.Mobility, 2, "a part is made movable before it is registered")
                if mine.RootComponent:IsValid() then
                    store.AttachParent, store.relative = mine.RootComponent, placement
                else
                    mine.RootComponent, store.world = part, placement
                    mine.Location = { placement.Translation.X, placement.Translation.Y, placement.Translation.Z }
                end
            end
        end },
    K2_DestroyActor = { call = function(self)
        engine.destroyed = engine.destroyed + 1
        world.destroy(self, 0)
        world.free(self)
    end },
    GetActorBounds = { { "bOnlyCollidingComponents", BOOL }, { "Origin", STRUCT, struct = VECTOR, out = true },
        { "BoxExtent", STRUCT, struct = VECTOR, out = true }, { "bIncludeFromChildActors", BOOL }, call = function(self, args)
            t.eq(args.bOnlyCollidingComponents, false)
            t.eq(args.bIncludeFromChildActors, false)
            local at = values.of(self).Location
            return nil, { Origin = { X = at[1], Y = at[2], Z = at[3] + 10 }, BoxExtent = { X = 50, Y = 40, Z = 30 } }
        end },
    GetOverlappingActors = { { "OverlappingActors", ARRAY, inner = OBJECT, out = true }, { "ClassFilter", CLASS }, call = function(self, args)
        if engine.overlap_raises then error("the game would not say") end
        engine.filter = args.ClassFilter
        engine.asked = (engine.asked or 0) + 1
        return nil, { OverlappingActors = engine.overlaps[self] or {} }
    end },
    K2_GetActorLocation = { returns = { STRUCT, struct = VECTOR } },
    K2_GetActorRotation = { returns = { STRUCT, struct = ROTATOR }, call = function(self)
        local turn = values.of(self).Turn
        return { Pitch = turn.Pitch, Yaw = turn.Yaw, Roll = turn.Roll }
    end },
    K2_SetActorRotation = { { "NewRotation", STRUCT, struct = ROTATOR }, { "bTeleportPhysics", BOOL }, returns = BOOL, call = function(self, args)
        t.eq(args.bTeleportPhysics, false)
        values.of(self).Turn = args.NewRotation
        return true
    end },
    SetLifeSpan = { { "InLifespan", FLOAT }, call = function(self, args) values.of(self).life = args.InLifespan end },
})
scene_class = class("/Script/Engine.SceneComponent", component_class, { AttachParent = OBJECT, bVisible = BOOL }, {
    SetMobility = { { "NewMobility", "ByteProperty" }, call = function(self, args)
        local store = values.of(self)
        t.eq(store.registered, false, "a part is made movable before it is registered")
        store.Mobility = args.NewMobility
    end },
    K2_GetComponentScale = { returns = { STRUCT, struct = VECTOR }, call = function(self)
        local store = values.of(self)
        t.eq(store.registered, true, "a part's size in the world is asked of one that is registered")
        local size = store.world and store.world.Scale3D or { X = 1, Y = 1, Z = 1 }
        return { X = size.X, Y = size.Y, Z = size.Z }
    end },
    K2_SetRelativeLocation = { { "NewLocation", STRUCT, struct = VECTOR }, { "bSweep", BOOL }, { "SweepHitResult", STRUCT, struct = HIT, out = true },
        { "bTeleport", BOOL }, call = function(self, args)
            t.eq(args.bSweep, false)
            local at = args.NewLocation
            values.of(rawget(self, "__outer")).Location = { at.X, at.Y, at.Z }
        end },
})
primitive_class = class("/Script/Engine.PrimitiveComponent", scene_class, { CastShadow = BOOL }, {
    SetMaterial = { { "ElementIndex", INT }, { "Material", OBJECT }, call = function(self, args)
        values.of(self).materials[args.ElementIndex] = args.Material
    end },
    SetCollisionEnabled = { { "NewType", "ByteProperty" }, call = function(self, args) values.of(self).collision = args.NewType end },
    SetCollisionProfileName = { { "InCollisionProfileName", "NameProperty" }, { "bUpdateOverlaps", BOOL }, call = function(self, args)
        values.of(self).profile = plain(args.InCollisionProfileName)
        t.eq(args.bUpdateOverlaps, true)
    end },
    SetGenerateOverlapEvents = { { "bInGenerateOverlapEvents", BOOL }, call = function(self, args)
        values.of(self).overlap_events = args.bInGenerateOverlapEvents
    end },
})
local mesh_component_class = class("/Script/Engine.MeshComponent", primitive_class)
local static_part_class = class("/Script/Engine.StaticMeshComponent", mesh_component_class, {}, {
    SetStaticMesh = { { "NewMesh", OBJECT }, returns = BOOL, call = function(self, args)
        local store = values.of(self)
        store.mesh, store.mesh_set_registered = args.NewMesh, store.registered
        return true
    end },
})
class("/Script/ProceduralMeshComponent.ProceduralMeshComponent", mesh_component_class, {}, {
    CreateMeshSection_LinearColor = { { "SectionIndex", INT }, { "Vertices", ARRAY, inner = STRUCT, struct = VECTOR },
        { "Triangles", ARRAY, inner = INT }, { "Normals", ARRAY, inner = STRUCT, struct = VECTOR },
        { "UV0", ARRAY, inner = STRUCT, struct = VECTOR2D }, { "UV1", ARRAY, inner = STRUCT, struct = VECTOR2D },
        { "UV2", ARRAY, inner = STRUCT, struct = VECTOR2D }, { "UV3", ARRAY, inner = STRUCT, struct = VECTOR2D },
        { "VertexColors", ARRAY, inner = STRUCT, struct = COLOR }, { "Tangents", ARRAY, inner = STRUCT, struct = TANGENT },
        { "bCreateCollision", BOOL }, call = function(self, args)
            local store = values.of(self)
            t.eq(store.registered, true, "a shape goes on a part that is registered")
            store.sections[args.SectionIndex] = { vertices = #args.Vertices, collision = args.bCreateCollision }
        end },
    ClearMeshSection = { { "SectionIndex", INT }, call = function(self, args) values.of(self).sections[args.SectionIndex] = nil end },
})
local light_base = class("/Script/Engine.LightComponent", scene_class, { Intensity = FLOAT, LightColor = { STRUCT, struct = COLOR } })
class("/Script/Engine.PointLightComponent", light_base, { AttenuationRadius = FLOAT })
class("/Script/Engine.RotatingMovementComponent", component_class, { RotationRate = { STRUCT, struct = ROTATOR } })
class("/Script/Engine.Pawn", actor_class)
class("/Script/Engine.Texture2D", object_class)
local lantern_class = class("/Game/BP/Props/BP_Lantern.BP_Lantern_C", actor_class, { Brightness = FLOAT, bLit = BOOL }, {
    Flicker = { { "Seconds", FLOAT }, returns = BOOL, call = function(self, args)
        values.of(self).flickered = args.Seconds
        return true
    end },
})
rawset(lantern_class, "__own_root", true)
by_path["/game/bp/props/bp_lantern.bp_lantern_c"] = nil     -- from the game's content: it is loaded, not found in memory

local statics_class = class("/Script/Engine.GameplayStatics", object_class, {}, {
    BeginDeferredActorSpawnFromClass = { { "WorldContextObject", OBJECT }, { "ActorClass", CLASS }, { "SpawnTransform", STRUCT, struct = TRANSFORM },
        { "CollisionHandlingOverride", "EnumProperty" }, { "Owner", OBJECT }, returns = OBJECT, call = function(_, args)
            if engine.begin_raises then error("the game would not") end
            if engine.begin_gives_nothing then return INVALID end
            full(args.SpawnTransform, "BeginDeferredActorSpawnFromClass")
            local actor = new_actor(args.ActorClass, args.SpawnTransform.Translation)
            engine.spawns[#engine.spawns + 1] = { how = "deferred", actor = actor, context = args.WorldContextObject, owner = args.Owner,
                method = args.CollisionHandlingOverride, transform = args.SpawnTransform, finished = 0 }
            return actor
        end },
    FinishSpawningActor = { { "Actor", OBJECT }, { "SpawnTransform", STRUCT, struct = TRANSFORM }, returns = OBJECT, call = function(_, args)
        full(args.SpawnTransform, "FinishSpawningActor")
        for _, spawn in ipairs(engine.spawns) do
            if spawn.actor == args.Actor then spawn.finished = spawn.finished + 1 end
        end
        begin_play(args.Actor)
        return args.Actor
    end },
})
world.static["/Script/Engine.Default__GameplayStatics"] = (values.part(statics_class, "Default__GameplayStatics", {}))

-- game.Assets' side of the engine: what is on disk, what is in memory
local disk, memory, loose = {}, {}, {}
local function on_disk(full, asset_class, options)
    local package, name = full:match("^(.-)%.([^.]+)$")
    local entry = { full = full, package = package, name = name, folder = package:match("^(.*)/[^/]+$"), class = asset_class, loads = 0 }
    for key, value in pairs(options or {}) do entry[key] = value end
    disk[full:lower()] = entry
    return entry
end
local function bring(entry)
    local key = entry.full:lower()
    local object = memory[key]
    if object then return object end
    object = entry.object or world.component(entry.class, entry.name, {})
    rawset(object, "__freed", nil)
    rawset(object, "__path", entry.full)
    memory[key] = object
    entry.loads = entry.loads + 1
    return object
end
function LoadAsset(path)
    local entry = disk[tostring(path):lower()]
    if not entry then return INVALID end
    return bring(entry)
end
local function library(path, functions)
    functions.IsValid = function() return true end
    world.static[path] = functions
end
-- The engine's weak pointers, which engine.handle is built on: one answers its object until that is destroyed or freed,
-- and the object itself is never read for the answer.
local NOTHING = { __props = {}, type = function() return "UObject" end, GetAddress = function() return 0 end,
                  IsValid = function() return false end }
local function weak_of(object)
    return { __props = {}, type = function() return "FWeakObjectPtr" end, Get = function()
        if object == nil or rawget(object, "__freed") or rawget(object, "__flags") ~= 0 then return NOTHING end
        return object
    end }
end
class("/Script/Engine.ObjectLibrary", object_class)
world.static["/Engine/Transient"] = world.object("Transient", {})
local throwaways = {}
function StaticConstructObject(made_class)
    local made = world.component(made_class, "ObjectLibrary_" .. (#throwaways + 1), {})
    throwaways[#throwaways + 1] = made
    return made
end

local asked_memory = 0
library("/Script/Engine.Default__KismetSystemLibrary", {
    __props = {},
    type = function() return "UObject" end,
    Conv_ObjectToSoftObjectReference = function(_, object)
        return { __props = {}, type = function() return "TSoftObjectPtrUserdata" end, GetWeakPtr = function() return weak_of(object) end }
    end,
    Conv_SoftObjPathToSoftObjRef = function(_, path) return { path = plain(path.AssetPathName) } end,
    Conv_SoftObjectReferenceToObject = function(_, soft)
        asked_memory = asked_memory + 1
        local key = soft.path:lower()
        return memory[key] or by_path[key] or INVALID
    end,
})
library("/Script/AssetRegistry.Default__AssetRegistryHelpers", {
    GetAsset = function(_, data)
        local entry = disk[plain(data.ObjectPath):lower()]
        return entry and bring(entry) or INVALID
    end,
})
library("/Script/AssetRegistry.Default__AssetRegistryImpl", {
    GetAssetsByPackageName = function() return false end,
    GetAssetsByPath = function(_, folder, list)
        local wanted, found = plain(folder):lower(), {}
        for _, entry in pairs(disk) do
            if entry.folder:lower() == wanted then found[#found + 1] = entry end
        end
        table.sort(found, function(a, b) return a.full < b.full end)
        for _, entry in ipairs(found) do
            list[#list + 1] = { get = function() return { AssetName = world.name(entry.name), ObjectPath = world.name(entry.full) } end }
        end
        return #found > 0
    end,
})
library("/Script/Engine.Default__KismetRenderingLibrary", { ImportFileAsTexture2D = function() return INVALID end })
local material_interface = world.class("/Script/Engine.MaterialInterface", object_class)
local material_class = world.class("/Script/Engine.Material", material_interface)
local dynamic_class = world.class("/Script/Engine.MaterialInstanceDynamic", world.class("/Script/Engine.MaterialInstance", material_interface))
local static_mesh_class = world.class("/Script/Engine.StaticMesh", object_class)
local materials_made = 0
library("/Script/Engine.Default__KismetMaterialLibrary", {
    CreateDynamicMaterialInstance = function(_, _, parent)
        materials_made = materials_made + 1
        local made = world.component(dynamic_class, "MaterialInstanceDynamic_" .. materials_made, { Parent = parent })
        rawset(made, "__path", "/Engine/Transient.MaterialInstanceDynamic_" .. materials_made)
        loose[made] = true
        return made
    end,
})

-- the interface's root, which is what game.Assets keeps things in memory with
local root_now = { widgets = {} }
local Widget = {}
Widget.__index = function(self, key)
    if key == "Brush" then return { ResourceObject = rawget(self, "__resource") or INVALID } end
    if key == "SetBrushResourceObject" then return function(_, object) rawset(self, "__resource", object) end end
    return function() end
end
local function widget()
    local made = setmetatable({}, Widget)
    root_now.widgets[#root_now.widgets + 1] = made
    return made
end
root_now.canvas = widget()
Wax.modules["gui.root"] = {
    check = function() return true end,
    canvas = function() return root_now.canvas end,
    new = function() return widget() end,
}

-- A collection: an asset no holder names is freed. Classes of the game's own code stay.
local function collect()
    local held = {}
    for _, made in ipairs(root_now.widgets) do
        local object = rawget(made, "__resource")
        if object then held[object] = true end
    end
    for key, object in pairs(memory) do
        if not held[object] then
            rawset(object, "__freed", true)
            memory[key] = nil
        end
    end
    for object in pairs(loose) do
        if not held[object] then
            rawset(object, "__freed", true)
            loose[object] = nil
        end
    end
end

local CRATE = "/Game/Assets/Props/SM_Crate.SM_Crate"
local BARREL = "/Game/Assets/Props/SM_Barrel.SM_Barrel"
local GLOW = "/Engine/EngineMaterials/EmissiveMeshMaterial.EmissiveMeshMaterial"
local LANTERN = "/Game/BP/Props/BP_Lantern.BP_Lantern_C"
on_disk(CRATE, static_mesh_class)
on_disk(BARREL, static_mesh_class)
on_disk(GLOW, material_class)
on_disk("/Game/Assets/Props/T_Crate.T_Crate", by_path["/script/engine.texture2d"])
on_disk(LANTERN, nil, { object = lantern_class })

-- the world
local mode = world.object("GameMode_0", {})
local function new_world(name)
    local made, store = values.part(world_class, name, { AuthorityGameMode = mode })
    store.SpawnActor = function(_, actor_class_given, location, rotation)
        if engine.refuse.plain then return INVALID end
        local actor = new_actor(actor_class_given, location, rotation)
        engine.spawns[#engine.spawns + 1] = { how = "plain", actor = actor }
        begin_play(actor)
        return actor
    end
    return made, store
end
local world_now, world_store = new_world("Terrain_016")
local viewport = world.object("Viewport_0", { World = world_now, GameInstance = world.object("GameInstance_0", {}) })
world.engine = world.object("Engine_0", { GameViewport = viewport })

local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local sched = Wax.import("core.sched")
local instance = Wax.import("engine.instance")
local game_module = Wax.import("engine.game")
game_module.start()
Wax.game = game_module.root
local game = game_module.root
local actors = Wax.import("engine.actors")
actors.start()
local track = Wax.import("engine.track")
track.start()
Wax.import("world.assets").start()

local said, warnings, problems = {}, {}, {}
Wax.import("core.log").add_sink(function(entry, repeated)
    if repeated then return end
    said[#said + 1] = (tostring(entry.message):match("^[^\r\n]*"))
    if entry.level == "warn" then warnings[#warnings + 1] = entry.message end
    if entry.level == "error" then problems[#problems + 1] = entry.message end
end)

local now, FRAME = 1000, 0.016
sched.clock = function() return now end
local function frame(count)
    for _ = 1, count or 1 do
        now = now + FRAME
        game_module.step()
        track.step()
        sched.step()
    end
end

-- A map change: every actor ends play and is freed (quiet: without end of play being seen), and the game holds another world.
local function travel(name, quiet)
    world.travel(name, quiet)
    world_now, world_store = new_world(name)
    rawget(viewport, "__props").World = world_now
    frame()
end

local module, Blueprints = nil, nil
local scopes = {}

-- A fresh module in a world with nothing of the last test in it. handles = true: engine.handle is started and plugged in,
-- as it will be in the game. Without it Wax has only its own flags to go by, as in the game today.
local function fresh(options)
    for _, owner in ipairs(scopes) do
        if owner.alive then owner:destroy() end
    end
    scopes = {}
    if module then module.stop() end
    Wax.modules["world.blueprints"] = nil
    instance.use_handles(nil)
    Wax.modules["engine.handle"] = nil
    if options and options.handles then
        local handle = Wax.import("engine.handle")
        t.eq(handle.start(), true, "handles start on the stand-in")
        for _, made in ipairs(throwaways) do rawset(made, "__freed", true) end
        instance.use_handles(handle)
    end
    for _, actor in ipairs({ table.unpack(world.actors) }) do
        world.destroy(actor, 0)
        world.free(actor)
    end
    reset_engine()
    for _, entry in pairs(disk) do game.Assets:Release(entry.full) end
    world_store.AuthorityGameMode = mode
    guard.clear_errors()
    warnings, problems = {}, {}
    frame()
    module = Wax.import("world.blueprints")
    module.clock = function() return now end
    module.start()
    Blueprints = game.Blueprints
    return module, Blueprints
end

local function mod(id)
    local owner = scope.new(id)
    scopes[#scopes + 1] = owner
    return owner, function(fn, ...) return scope.run(owner, fn, ...) end
end

local function raises_here(fn, fragment)
    local err = t.raises(fn, fragment)
    t.ok(tostring(err):find("blueprints_test.lua:", 1, true), "the error names the line of the mod: " .. tostring(err))
    said[#said + 1] = (tostring(err):gsub("^.-%.lua:%d+: ", ""))
    return err
end

local function errors() return #guard.errors() end
local function store_of(target) return values.of(target.Raw) end
local function parameter(material, name)
    for key, value in pairs(rawget(material, "__props")) do
        if plain(key) == name then return value end
    end
    return nil
end
local function last_spawn() return engine.spawns[#engine.spawns] end
local function alive_actors() return #world.actors end

local AT = { X = 1000, Y = 2000, Z = 300 }
local CRATE_PARTS = {
    Body = { mesh = CRATE, root = true, scale = 2 },
    Lamp = { class = "PointLightComponent", at = { 0, 0, 150 }, set = { Intensity = 5000 } },
}

-- ---------------------------------------------------------------------------------------------------------- start-up

local touches_before = world.touches
fresh()

t.test("starting asks the engine nothing and puts nothing in the frame loop", function()
    local at_start = world.touches
    Wax.modules["world.blueprints"] = nil
    module.stop()
    module = Wax.import("world.blueprints")
    module.clock = function() return now end
    module.start()
    Blueprints = game.Blueprints
    t.eq(world.touches, at_start, "no engine object was touched")
    t.ok(touches_before <= at_start)
    t.eq(track.stats().sets.blueprints, nil, "no tracked list until a blueprint is defined")
    t.eq(actors.stats().listening, false, "begin of play is not listened for")
    local stats = module.stats()
    t.eq(stats.blueprints, 0)
    t.eq(stats.things, 0)
end)

t.test("game.Blueprints says its name, and a member it lacks names a near one", function()
    t.eq(tostring(Blueprints), "Blueprints")
    t.ok(rawequal(module.api, Blueprints))
    raises_here(function() return Blueprints.Defin end, "Defin is not a member of game.Blueprints. Did you mean 'Define'?")
    raises_here(function() Blueprints.Define = 1 end, "game.Blueprints.Define cannot be assigned because game.Blueprints is read-only")
    raises_here(function() Blueprints.Define("Crate", {}) end, "call Define with a colon: game.Blueprints:Define(name, options)")
    raises_here(function() Blueprints.Get("Crate") end, "call Get with a colon")
    raises_here(function() Blueprints:Get(5) end, "expects the name of a blueprint, got a number")
    t.eq(Blueprints:Get("Nothing"), nil)
    t.eq(#Blueprints:GetThings(), 0)
end)

-- ------------------------------------------------------------------------------------------------------------ Define

t.test("Define wants a name and a table, and names an option it does not know", function()
    fresh()
    raises_here(function() Blueprints:Define(5, {}) end, "expects a name of letters and digits such as \"Crate\", then a table. Got a number")
    raises_here(function() Blueprints:Define("", {}) end, "Got ''")
    raises_here(function() Blueprints:Define("a/b", {}) end, "Got 'a/b'")
    raises_here(function() Blueprints:Define("Crate") end, "game.Blueprints:Define(\"Crate\") expects a table")
    raises_here(function() Blueprints:Define("Crate", { part = {} }) end,
        "game.Blueprints:Define(\"Crate\"): the blueprint has no option 'part'. Did you mean 'parts'?")
    raises_here(function() Blueprints:Define("Crate", { Parts = {} }) end, "has no option 'Parts'")
    t.eq(Blueprints:Get("Crate"), nil, "a Define that failed left nothing")
    t.eq(module.stats().blueprints, 0)
end)

t.test("the base is a class of actor: by name, by path, or as game.Assets gave it", function()
    fresh()
    local _, mine = mod("MyMod")
    mine(function()
        t.eq(Blueprints:Define("Plain", {}).Base, "Actor", "Actor when nothing is said")
        t.eq(Blueprints:Define("Walker", { base = "Pawn" }).Base, "Pawn")
        t.eq(Blueprints:Define("ByPath", { base = "/Script/Engine.Pawn" }).Base, "Pawn")
        t.eq(Blueprints:Define("Cooked", { base = LANTERN }).Base, "BP_Lantern_C")
        t.eq(Blueprints:Define("Given", { base = game.Assets:Load(LANTERN) }).Base, "BP_Lantern_C")
    end)
    raises_here(function() Blueprints:Define("Bad", { base = "Pwan" }) end, "base: the game has no class named 'Pwan'. Did you mean 'Pawn'?")
    raises_here(function() Blueprints:Define("Bad", { base = "Pwan" }) end, "is named by its path, such as /Game/Folder/BP_Thing.BP_Thing_C")
    raises_here(function() Blueprints:Define("Bad", { base = "Scene Component" }) end, "'Scene Component' is not the name of a class")
    raises_here(function() Blueprints:Define("Bad", { base = "SceneComponent" }) end,
        "base is SceneComponent, which is not a kind of Actor. Start from \"Actor\" or from a class built on it")
    raises_here(function() Blueprints:Define("Bad", { base = "/Game/BP/Props/BP_Lanter.BP_Lanter_C" }) end, "base: the game has no asset at")
    raises_here(function() Blueprints:Define("Bad", { base = CRATE }) end, "base is a StaticMesh, not a class")
    raises_here(function() Blueprints:Define("Bad", { base = 7 }) end, "base is a class: its name such as \"Actor\", its path")
    t.eq(Blueprints:Get("Bad"), nil)
    t.eq(alive_actors(), 0, "defining puts nothing in the world")
end)

t.test("a part needs a class or a mesh, and each option is checked against what the part is", function()
    fresh()
    local _, mine = mod("MyMod")
    local function define(parts)
        return mine(function()
            local made = Blueprints:Define("Crate", { parts = parts })
            return made
        end)
    end
    local function bad(part, fragment) raises_here(function() define({ Body = part }) end, fragment) end
    bad({}, "part Body needs a class such as \"PointLightComponent\", or a mesh")
    bad(5, "part Body is a table such as")
    bad({ class = "PointLihgtComponent" }, "part Body: class: the game has no class named 'PointLihgtComponent'. Did you mean 'PointLightComponent'?")
    bad({ class = "Pawn" }, "part Body: Pawn is not a kind of component, so it cannot be a part of a thing")
    bad({ class = "PrimitiveComponent" },
        "part Body: PrimitiveComponent only stands for the classes built on it and cannot be made. Name one of those, such as \"StaticMeshComponent\"")
    bad({ class = "/Script/Engine.ActorComponent" }, "ActorComponent only stands for the classes built on it and cannot be made")
    bad({ class = "PointLightComponent", mesh = CRATE }, "a mesh of the game goes on a StaticMeshComponent, and this part is a PointLightComponent")
    bad({ class = "StaticMeshComponent", mesh = game.Assets:Mesh({ box = 50 }) },
        "a shape from game.Assets:Mesh goes on a ProceduralMeshComponent, and this part is a StaticMeshComponent")
    bad({ mesh = GLOW }, "part Body: mesh is a mesh: its path, one from game.Assets:Load, or a shape from game.Assets:Mesh. Got a Material")
    bad({ mesh = "/Game/Assets/Props/SM_Crat" }, "part Body: mesh: the game has no asset at /Game/Assets/Props/SM_Crat.SM_Crat")
    bad({ mesh = 12 }, "Got a number")
    bad({ class = "RotatingMovementComponent", material = GLOW }, "a RotatingMovementComponent is not drawn, so it takes no material")
    bad({ class = "RotatingMovementComponent", at = { 0, 0, 1 } }, "a RotatingMovementComponent has no place in the world, so it takes no at")
    bad({ class = "PointLightComponent", collision = "none" }, "a PointLightComponent has no shape, so it takes no collision")
    bad({ mesh = CRATE, material = CRATE }, "part Body: material is a material")
    bad({ mesh = CRATE, material = { colors = {} } }, "part Body: material: from is the material to start from")
    bad({ mesh = CRATE, material = { from = GLOW, colours = {} } }, "has no option 'colours'. Did you mean 'colors'?")
    bad({ mesh = CRATE, material = { from = GLOW, colors = { Color = "Oragne" } } }, "'Oragne' is not a colour")
    bad({ mesh = CRATE, scale = 0 }, "scale is a number such as 0.5")
    bad({ mesh = CRATE, scale = { 1, 2 } }, "scale is a number such as 0.5")
    bad({ mesh = CRATE, collision = "sollid" }, "collision is \"none\", \"solid\" or \"touch\". Did you mean 'solid'?")
    bad({ mesh = CRATE, collision = true }, "collision is \"none\", \"solid\" or \"touch\".")
    bad({ mesh = CRATE, colision = "none" }, "part Body has no option 'colision'. Did you mean 'collision'?")
    bad({ mesh = CRATE, root = "yes" }, "root is true or false")
    bad({ mesh = CRATE, set = { CastShadwo = false } }, "part Body: set: StaticMeshComponent has no property named 'CastShadwo'. Did you mean 'CastShadow'?")
    raises_here(function() define({ Body = { mesh = CRATE }, Lamp = { class = "PointLightComponent", at = "up" } }) end, "part Lamp: at is where the part sits")
    raises_here(function() define({ Body = { mesh = CRATE }, Lamp = { class = "PointLightComponent", rotation = { X = 1 } } }) end,
        "part Lamp: rotation is a turn in degrees")
    raises_here(function() define(7) end, "parts is a table of parts by name")
    raises_here(function() define({ ["a b/c"] = { mesh = CRATE } }) end, "is named by a short string of letters and digits")
    t.eq(Blueprints:Get("Crate"), nil)
    t.eq(alive_actors(), 0)
end)

t.test("one part is the root: the marked one, the first of a list, or the only one with a place", function()
    fresh()
    local _, mine = mod("MyMod")
    local function define(parts)
        return mine(function()
            local made = Blueprints:Define("Crate", { parts = parts })
            return made
        end)
    end
    local light = { class = "PointLightComponent" }
    raises_here(function() define({ Body = { mesh = CRATE }, Lamp = light }) end,
        "2 parts have a place and none of them says root = true. Mark the one the others hang on")
    raises_here(function() define({ Body = { mesh = CRATE, root = true }, Lamp = { class = "PointLightComponent", root = true } }) end,
        "parts Body and Lamp both say root = true. A thing has one root")
    raises_here(function() define({ Body = { mesh = CRATE, root = true, at = { 0, 0, 5 } } }) end,
        "part Body is the root: it stands where the thing is spawned, so it takes no at and no rotation")
    raises_here(function() define({ Spin = { class = "RotatingMovementComponent", root = true } }) end,
        "a RotatingMovementComponent has no place in the world, so it cannot be the root")
    raises_here(function() define({ { mesh = CRATE } }) end, "part 1 of the list is named by a short string")
    raises_here(function() define({ { name = "Body", mesh = CRATE }, Body = light }) end, "two parts are named Body")
    raises_here(function() define({ Body = { name = "Other", mesh = CRATE } }) end, "part Body also says name = 'Other'")
    local function root_of(parts)
        define(parts)
        local thing = Blueprints:Get("Crate"):Spawn(AT)
        local root = values.of(last_spawn().actor).RootComponent
        local name = nil
        for _, key in ipairs({ "Body", "Lamp", "Top", "Spin" }) do
            local ok, part = pcall(function() return thing:Part(key) end)
            if ok and part.Raw == root then name = key end
        end
        thing:Destroy()
        return name
    end
    t.eq(root_of({ Body = { mesh = CRATE } }), "Body", "the only part")
    t.eq(root_of({ Spin = { class = "RotatingMovementComponent" }, Lamp = light }), "Lamp", "the only part with a place")
    t.eq(root_of({ Body = { mesh = CRATE }, Lamp = { class = "PointLightComponent", root = true } }), "Lamp", "the marked one")
    t.eq(root_of({ { name = "Top", mesh = CRATE }, { name = "Body", mesh = BARREL }, Lamp = light }), "Top", "the first of a list")
    t.eq(root_of({ { name = "Top", mesh = CRATE }, { name = "Body", mesh = BARREL, root = true } }), "Body", "a mark beats the order")
end)

t.test("set and the functions are checked when the blueprint is defined", function()
    fresh()
    local _, mine = mod("MyMod")
    local function bad(options, fragment) raises_here(function() mine(function() Blueprints:Define("Crate", options) end) end, fragment) end
    bad({ set = { bHiden = true } }, "set: Actor has no property named 'bHiden'. Did you mean 'bHidden'?")
    bad({ set = { K2_DestroyActor = true } }, "set: Actor has no property named 'K2_DestroyActor'")
    bad({ set = 5 }, "set is a table of property names and values")
    bad({ began = 5 }, "began is a function, got a number")
    bad({ stepped = "fast" }, "stepped is a function, got a string")
    bad({ ended = {} }, "ended is a function, got a table")
    bad({ every = 5 }, "every is the seconds between two calls and a function: every = { 0.5, function(thing, dt) end }")
    bad({ every = { 0, function() end } }, "every is the seconds between two calls and a function")
    bad({ every = { 1 } }, "every is the seconds between two calls and a function")
    t.eq(Blueprints:Get("Crate"), nil)
end)

t.test("a blueprint says its name and its base, is found without letter case, and cannot be changed", function()
    fresh()
    local _, mine = mod("MyMod")
    local crate = mine(function() return Blueprints:Define("Crate", { parts = CRATE_PARTS }) end)
    t.eq(crate.Name, "Crate")
    t.eq(crate.Base, "Actor")
    t.eq(tostring(crate), "Blueprint Crate")
    t.eq(crate:Count(), 0)
    t.eq(#crate:GetThings(), 0)
    t.ok(rawequal(Blueprints:Get("crate"), crate))
    t.ok(rawequal(Blueprints:Get("CRATE"), crate))
    raises_here(function() return crate.Spwan end, "Spwan is not a member of a blueprint. Did you mean 'Spawn'?")
    raises_here(function() crate.Name = "Box" end, "Name cannot be assigned: a blueprint is changed by defining it again")
    raises_here(function() crate.Spawn(AT) end, "call Spawn with a colon: blueprint:Spawn(position, rotation, data)")
    t.eq(alive_actors(), 0, "nothing is in the world until Spawn")
    t.eq(module.stats().blueprints, 1)
    t.eq(track.stats().sets.blueprints.tracking, true, "the frame loop reaches the module from now on")
end)

-- ------------------------------------------------------------------------------------------------------------- Spawn

t.test("Spawn makes the actor in two steps, with its parts there when it begins play", function()
    fresh()
    local _, mine = mod("MyMod")
    local seen = {}
    local crate = mine(function()
        return Blueprints:Define("Crate", { parts = CRATE_PARTS, began = function(thing)
            seen[#seen + 1] = { thing = thing, lamp = thing:Part("Lamp").ClassName, begun = engine.begins[last_spawn().actor] }
        end })
    end)
    local thing = crate:Spawn(AT, { Yaw = 90 })
    local spawn = last_spawn()
    t.eq(#engine.spawns, 1)
    t.eq(spawn.how, "deferred")
    t.ok(spawn.context == world_now, "the world is the context, so nothing becomes the instigator")
    t.eq(spawn.method, 1, "always spawn")
    t.ok(not spawn.owner:IsValid(), "no owner")
    t.eq(spawn.finished, 1)
    near(spawn.transform.Translation.X, 1000)
    near(spawn.transform.Rotation.Z, 0.70711, "a yaw of 90 as the engine writes it")
    near(spawn.transform.Rotation.W, 0.70711)
    near(spawn.transform.Scale3D.X, 1)
    t.eq(engine.begins[spawn.actor], 1, "it began play once")
    t.eq(values.of(spawn.actor).parts_at_begin, 2, "with both parts there")
    t.eq(#seen, 1, "began ran once")
    t.ok(rawequal(seen[1].thing, thing), "with the thing Spawn gives")
    t.eq(seen[1].lamp, "PointLightComponent")
    t.eq(seen[1].begun, 1, "after the actor began play")
    local body, lamp = store_of(thing:Part("Body")), store_of(thing:Part("Lamp"))
    t.ok(values.of(spawn.actor).RootComponent == thing:Part("Body").Raw, "the root part is the root")
    near(body.world.Translation.Z, 300, "the root takes the thing's place")
    near(body.world.Rotation.Z, 0.70711, "and its turn")
    near(body.world.Scale3D.Y, 2, "with its own size")
    t.eq(body.mesh, memory[CRATE:lower()])
    t.eq(body.mesh_set_registered, false, "the mesh is set before the part is registered")
    t.eq(body.actor_began, false, "the part is made before the actor begins play")
    t.ok(lamp.AttachParent == thing:Part("Body").Raw, "the other part hangs on the root")
    near(lamp.relative.Translation.Z, 75, "150 above the thing: the game measures against the root, which is twice its size")
    near(lamp.relative.Rotation.W, 1)
    near(lamp.relative.Scale3D.X, 0.5, "and its own size stays what it was given")
    t.eq(lamp.Intensity, 5000, "what set names is written")
    t.eq(body.collision, nil, "collision is left as the engine makes it")
    t.eq(crate:Count(), 1)
    t.eq(module.stats().things, 1)
    t.eq(module.stats().listening, false, "begin of play is listened for only while a spawn is under way")
    t.eq(world.dead_touches, 0)
    t.eq(errors(), 0)
end)

t.test("Spawn reads a place and a turn in each form, and says what is wrong with them", function()
    fresh()
    local _, mine = mod("MyMod")
    local crate = mine(function() return Blueprints:Define("Crate", { parts = { Body = { mesh = CRATE } } }) end)
    crate:Spawn({ 10, 20, 30 })
    near(last_spawn().transform.Translation.Y, 20)
    near(last_spawn().transform.Rotation.W, 1, "no turn when none is given")
    crate:Spawn({ X = 1, Y = 2, Z = 3 }, { 0, 180, 0 })
    near(last_spawn().transform.Rotation.Z, 1)
    crate:Spawn(AT, { Pitch = 90 })
    near(last_spawn().transform.Rotation.Y, -0.70711, "a pitch of 90 as the engine writes it")
    near(last_spawn().transform.Rotation.W, 0.70711)
    crate:Spawn(AT, { Roll = 90 })
    near(last_spawn().transform.Rotation.X, -0.70711, "a roll of 90 as the engine writes it")
    raises_here(function() crate:Spawn() end, "Crate:Spawn expects where to put it: { X = 0, Y = 0, Z = 0 } or { 0, 0, 0 }. Got nothing")
    raises_here(function() crate:Spawn({ X = 1, Y = 2 }) end, "Crate:Spawn expects where to put it")
    raises_here(function() crate:Spawn({ 1, 2, 0 / 0 }) end, "Crate:Spawn expects where to put it")
    raises_here(function() crate:Spawn("here") end, "Got a string")
    raises_here(function() crate:Spawn(AT, 90) end, "Crate:Spawn: the rotation is a turn in degrees")
    raises_here(function() crate:Spawn(AT, { X = 0, Y = 90 }) end, "Crate:Spawn: the rotation is a turn in degrees")
    raises_here(function() crate:Spawn(AT, nil, "mine") end, "Crate:Spawn: the data is a table of your own that the thing keeps. Got a string")
    t.eq(crate:Count(), 4, "a call that was refused spawned nothing")
    t.eq(alive_actors(), 4)
end)

t.test("spawning needs a world", function()
    fresh()
    local _, mine = mod("MyMod")
    local crate = mine(function() return Blueprints:Define("Crate", { parts = { Body = { mesh = CRATE } } }) end)
    rawget(viewport, "__props").World = INVALID
    raises_here(function() crate:Spawn(AT) end, "Crate:Spawn: there is no world right now, so nothing can be spawned")
    rawget(viewport, "__props").World = world_now
    t.eq(#engine.spawns, 0, "the engine was not asked")
    t.ok(crate:Spawn(AT).Alive)
end)

t.test("collision is written when it is asked for: none, solid as the engine has it, touch", function()
    fresh()
    local _, mine = mod("MyMod")
    local thing = mine(function()
        return Blueprints:Define("Crate", { parts = {
            Body = { mesh = CRATE, root = true },
            Ghost = { mesh = CRATE, collision = "None" },
            Wall = { mesh = CRATE, collision = "solid" },
            Sense = { mesh = CRATE, collision = "touch" },
        } }):Spawn(AT)
    end)
    local body, ghost, wall, sense = store_of(thing:Part("Body")), store_of(thing:Part("Ghost")), store_of(thing:Part("Wall")),
        store_of(thing:Part("Sense"))
    t.eq(body.collision, nil)
    t.eq(body.profile, nil)
    t.eq(ghost.collision, 0, "no collision")
    t.eq(wall.collision, nil, "a mesh part blocks by itself")
    t.eq(wall.profile, nil)
    t.eq(sense.profile, "OverlapAllDynamic")
    t.eq(sense.overlap_events, true)
    t.eq(sense.collision, nil)
end)

t.test("a material is put on by path, as given, or made from one of the game's and shared", function()
    fresh()
    local owner, mine = mod("MyMod")
    local made_before = materials_made
    local crate, glow = mine(function()
        local own = game.Assets:Material(GLOW, { colors = { Color = "Green" } })
        return Blueprints:Define("Crate", { parts = {
            Body = { mesh = CRATE, root = true, material = GLOW },
            Lid = { mesh = CRATE, material = own },
            Sign = { mesh = CRATE, material = { from = GLOW, colors = { Color = "Orange" } } },
        } }), own
    end)
    t.eq(materials_made, made_before + 2, "the one the mod made and the one the blueprint asked for")
    local first, second = crate:Spawn(AT), crate:Spawn(AT)
    t.eq(materials_made, made_before + 2, "a second thing makes no second material")
    t.eq(store_of(first:Part("Body")).materials[0], memory[GLOW:lower()])
    t.eq(store_of(first:Part("Lid")).materials[0], glow.Raw)
    local sign = store_of(first:Part("Sign")).materials[0]
    t.ok(sign:IsA(dynamic_class) and sign ~= glow.Raw)
    t.ok(parameter(sign, "Color").R > 0.9 and parameter(sign, "Color").B < 0.01, "with its colour set")
    t.eq(store_of(second:Part("Sign")).materials[0], sign, "both things share it")
    collect()
    t.ok(not rawget(sign, "__freed"), "it is kept for the mod that defined the blueprint")
    owner:destroy()
    collect()
    t.ok(rawget(sign, "__freed"), "and let go with that mod")
    t.eq(world.dead_touches, 0)
end)

t.test("a shape made of numbers goes on a part of its own kind", function()
    fresh()
    local _, mine = mod("MyMod")
    local thing = mine(function()
        return Blueprints:Define("Block", { parts = {
            Body = { mesh = game.Assets:Mesh({ box = 60, collision = true }), material = GLOW, root = true },
            Top = { mesh = game.Assets:Mesh({ box = { X = 20, Y = 20, Z = 5 } }), at = { 0, 0, 40 }, class = "ProceduralMeshComponent" },
        } }):Spawn(AT)
    end)
    local body, top = thing:Part("Body"), thing:Part("Top")
    t.eq(body.ClassName, "ProceduralMeshComponent", "the class follows from the mesh")
    t.eq(store_of(body).sections[0].vertices, 24)
    t.eq(store_of(body).sections[0].collision, true)
    t.eq(store_of(body).materials[0], memory[GLOW:lower()])
    t.eq(store_of(top).sections[0].collision, false)
    near(store_of(top).relative.Translation.Z, 40)
end)

t.test("set is written before the actor begins play, and a value of the wrong kind leaves nothing standing", function()
    fresh()
    local _, mine = mod("MyMod")
    local hidden_at_begin = nil
    local thing = mine(function()
        return Blueprints:Define("Crate", {
            set = { bHidden = true, InitialLifeSpan = 30 },
            parts = { Body = { mesh = CRATE, set = { CastShadow = false } }, Spin = { class = "RotatingMovementComponent",
                set = { RotationRate = { Pitch = 0, Yaw = 90, Roll = 0 } } } },
            began = function(self) hidden_at_begin = self.bHidden end,
        }):Spawn(AT)
    end)
    t.eq(hidden_at_begin, true)
    t.eq(values.of(last_spawn().actor).InitialLifeSpan, 30)
    t.eq(store_of(thing:Part("Body")).CastShadow, false)
    t.eq(store_of(thing:Part("Spin")).RotationRate.Yaw, 90)
    t.eq(store_of(thing:Part("Spin")).Mobility, nil, "a part with no place is not made movable")
    local before = alive_actors()
    local bad = mine(function() return Blueprints:Define("Bad", { set = { bHidden = "yes" }, parts = { Body = { mesh = CRATE } } }) end)
    raises_here(function() bad:Spawn(AT) end, "Bad:Spawn: set.bHidden: Actor.bHidden expects true or false, got string")
    local worse = mine(function()
        return Blueprints:Define("Worse", { parts = { Body = { mesh = CRATE, root = true },
            Lamp = { class = "PointLightComponent", set = { Intensity = "bright" } } } })
    end)
    raises_here(function() worse:Spawn(AT) end, "Worse:Spawn: part Lamp: set.Intensity: PointLightComponent.Intensity expects a number, got string")
    t.eq(alive_actors(), before, "the half-made actors were taken away")
    t.eq(bad:Count(), 0)
    t.eq(worse:Count(), 0)
    t.eq(module.stats().things, 1)
    t.eq(world.dead_touches, 0)
    frame(3)
    t.eq(errors(), 0)
end)

t.test("a part the game does not make leaves nothing standing", function()
    fresh()
    local _, mine = mod("MyMod")
    local ended = 0
    local crate = mine(function()
        return Blueprints:Define("Crate", { parts = CRATE_PARTS, ended = function() ended = ended + 1 end })
    end)
    engine.refuse.PointLightComponent = true
    raises_here(function() crate:Spawn(AT) end, "Crate:Spawn: part Lamp: the game did not make a PointLightComponent")
    t.eq(alive_actors(), 0)
    t.eq(engine.destroyed, 1)
    t.eq(crate:Count(), 0)
    frame(2)
    t.eq(ended, 0, "ended does not run for a thing that was never handed over")
    t.eq(#Blueprints:GetThings(), 0)
    engine.refuse = {}
    t.ok(crate:Spawn(AT).Alive, "and the next one is made")
    t.eq(world.dead_touches, 0)
end)

t.test("when the game refuses the two steps, the plain way is taken and said once", function()
    fresh()
    local _, mine = mod("MyMod")
    local parts_at_began = nil
    local crate = mine(function()
        return Blueprints:Define("Crate", { parts = CRATE_PARTS, began = function(thing) parts_at_began = thing:Part("Lamp") ~= nil end })
    end)
    engine.begin_gives_nothing = true
    local thing = crate:Spawn(AT, { Yaw = 45 })
    t.eq(last_spawn().how, "plain")
    t.eq(values.of(last_spawn().actor).parts_at_begin, 0, "such an actor begins play before its parts are there")
    t.eq(parts_at_began, true, "began still runs with the parts there")
    near(store_of(thing:Part("Body")).world.Translation.X, 1000, "the root still places the thing")
    near(values.of(last_spawn().actor).Turn.Yaw, 45)
    t.eq(#warnings, 1)
    t.ok(warnings[1]:find("the game did not begin a spawn in two steps (it gave nothing), so the plain way is tried", 1, true), warnings[1])
    engine.begin_gives_nothing, engine.begin_raises = false, true
    crate:Spawn(AT)
    t.eq(last_spawn().how, "plain")
    t.eq(#warnings, 1, "said once")
    t.eq(module.stats().fallback, 2)
    engine.refuse.plain = true
    raises_here(function() crate:Spawn(AT) end, "Crate:Spawn: the game did not spawn a Actor")
    t.eq(module.stats().fallback, 3)
    engine.begin_raises, engine.refuse = false, {}
    module.DEFERRED = false
    crate:Spawn(AT)
    t.eq(last_spawn().how, "plain", "the switch takes the plain way without asking")
    t.eq(module.stats().fallback, 3, "and that is not counted as a refusal")
    t.eq(crate:Count(), 3)
end)

t.test("a class from the game's content is a base: its own root, its own members, parts on top", function()
    fresh()
    local owner, mine = mod("MyMod")
    local lantern = mine(function()
        return Blueprints:Define("Lantern", { base = LANTERN, set = { Brightness = 3.5 },
            parts = { Shade = { mesh = CRATE, root = true, scale = 0.5 }, Glow = { class = "PointLightComponent", at = { 0, 0, 20 } } } })
    end)
    local thing = lantern:Spawn(AT, { Yaw = 90 })
    local actor = last_spawn().actor
    t.ok(actor:IsA(lantern_class))
    t.eq(thing.ClassName, "BP_Lantern_C")
    t.ok(thing:IsA("Actor"))
    near(last_spawn().transform.Translation.X, 1000, "the spawn places an actor that has a root of its own")
    t.eq(thing.Brightness, 3.5, "set reaches the class's own property")
    local shade = store_of(thing:Part("Shade"))
    t.ok(values.of(values.of(actor).RootComponent).is_own_root, "the class keeps its root")
    t.ok(shade.AttachParent == values.of(actor).RootComponent, "and the blueprint's root part hangs on it")
    near(shade.relative.Translation.X, 0, "at the thing's own place")
    near(shade.relative.Scale3D.X, 0.5)
    near(store_of(thing:Part("Glow")).relative.Translation.Z, 20)
    t.eq(thing:Flicker(0.25), true, "its own functions are called on the thing")
    t.eq(values.of(actor).flickered, 0.25)
    thing.bLit = true
    t.eq(values.of(actor).bLit, true, "and its own properties are written on the thing")
    collect()
    t.ok(not rawget(lantern_class, "__freed"), "the class is kept in memory for the mod")
    owner:destroy()
    collect()
    t.ok(rawget(lantern_class, "__freed"), "and let go with it")
    t.eq(world.dead_touches, 0)
end)

-- ------------------------------------------------------------------------------------------------------------- a thing

t.test("a thing keeps its state, and answers as its actor's Instance does", function()
    fresh()
    local _, mine = mod("MyMod")
    local crate = mine(function() return Blueprints:Define("Crate", { parts = CRATE_PARTS }) end)
    local mine_state = { hits = 3 }
    local thing, other = crate:Spawn(AT, nil, mine_state), crate:Spawn(AT)
    t.ok(rawequal(thing.Data, mine_state), "the table given to Spawn")
    t.eq(type(other.Data), "table", "or a new one")
    other.Data.seen = true
    t.eq(other.Data.seen, true)
    t.ok(rawequal(thing.Blueprint, crate))
    t.ok(instance.is_instance(thing.Actor))
    t.ok(not instance.is_instance(thing))
    t.eq(thing.Actor.Raw, last_spawn().actor ~= thing.Actor.Raw and engine.spawns[1].actor or last_spawn().actor)
    t.eq(thing.Name, rawget(engine.spawns[1].actor, "__name"))
    t.eq(thing.ClassName, "Actor")
    t.ok(thing:IsA("Actor"))
    t.eq(thing:IsA("Pawn"), false)
    near(thing:K2_GetActorLocation().Z, 300)
    t.eq(tostring(thing), "Crate " .. thing.Name)
    thing.bHidden = true
    t.eq(values.of(engine.spawns[1].actor).bHidden, true)
    thing:SetLifeSpan(12)
    t.eq(values.of(engine.spawns[1].actor).life, 12)
    thing:SetAttribute("Owner", "me")
    t.eq(thing.Actor:GetAttribute("Owner"), "me", "attributes are the Instance's")
    raises_here(function() return thing.Helth end, "Helth is not a member of Actor")
    raises_here(function() thing.bHidden = 5 end, "Actor.bHidden expects true or false, got number")
    raises_here(function() thing:SetLifeSpan("long") end, "Actor:SetLifeSpan argument 1 (InLifespan) expects a number, got string")
    raises_here(function() thing.Data = {} end, "Data cannot be assigned: every thing has it. Change what is in the table")
    raises_here(function() thing.Destroy = 1 end, "Destroy cannot be assigned: every thing has it")
    raises_here(function() thing.Part("Body") end, "call Part with a colon: thing:Part(name)")
    t.eq(world.dead_touches, 0)
end)

t.test("Position and Rotation are read from the actor and written through it", function()
    fresh()
    local _, mine = mod("MyMod")
    local crate = mine(function() return Blueprints:Define("Crate", { parts = CRATE_PARTS }) end)
    local thing = crate:Spawn(AT, { Yaw = 30 })
    local at, turn = thing.Position, thing.Facing
    near(at.X, 1000)
    near(at.Z, 300)
    near(turn.Yaw, 0, "the stand-in keeps the turn in the root's transform, not here")
    thing.Position = { X = 5, Y = 6, Z = 7 }
    near(thing.Position.Y, 6)
    thing.Position = { 8, 9, 10 }
    near(thing.Position.Z, 10)
    thing.Facing = { Yaw = 120 }
    near(thing.Facing.Yaw, 120)
    near(thing.Facing.Pitch, 0)
    thing.Facing = { 10, 20, 30 }
    near(thing.Facing.Roll, 30)
    raises_here(function() thing.Position = { X = 1 } end, "Position is three numbers: { X = 0, Y = 0, Z = 0 } or { 0, 0, 0 }. Got a table")
    raises_here(function() thing.Facing = "north" end, "Facing is a turn in degrees")
    local bare = mine(function() return Blueprints:Define("Bare", {}) end):Spawn(AT)
    raises_here(function() bare.Position = AT end, "this Bare has no part with a place, so it cannot be moved")
    local bounds = thing:GetBounds()
    near(bounds.Center.Z, 20)
    near(bounds.Size.X, 100)
    near(bounds.Size.Z, 60)
end)

t.test("Part gives a part's Instance, and AddPart makes one more on a living thing", function()
    fresh()
    local _, mine = mod("MyMod")
    local crate = mine(function() return Blueprints:Define("Crate", { parts = CRATE_PARTS }) end)
    local thing = crate:Spawn(AT)
    local body = thing:Part("Body")
    t.ok(instance.is_instance(body))
    t.ok(body:IsA("StaticMeshComponent"))
    t.ok(rawequal(thing:Part("body"), body), "letter case does not matter")
    t.ok(rawequal(body.Parent, thing.Actor) or body:GetParent() ~= nil)
    raises_here(function() thing:Part("Lmap") end, "this Crate has no part named 'Lmap'. Did you mean 'Lamp'?")
    raises_here(function() thing:Part(5) end, "thing:Part expects the name of a part, got a number")
    local sign = thing:AddPart("Sign", { mesh = BARREL, at = { 0, 50, 0 }, rotation = { Yaw = 180 }, scale = 0.25, collision = "none" })
    t.ok(instance.is_instance(sign))
    t.ok(rawequal(thing:Part("Sign"), sign))
    local store = store_of(sign)
    t.ok(store.AttachParent == body.Raw, "it hangs on the root")
    near(store.relative.Translation.Y, 25, "50 beside the thing, written against a root twice its size")
    near(store.relative.Rotation.Z, 1)
    near(store.relative.Scale3D.Z, 0.125, "a quarter of the mesh's own size in the world")
    t.eq(store.collision, 0)
    t.eq(store.actor_began, true, "on an actor that began play long ago")
    raises_here(function() thing:AddPart("sign", { mesh = BARREL }) end, "Crate:AddPart: it already has a part named Sign")
    raises_here(function() thing:AddPart("More", { mesh = "nothing" }) end, "Crate:AddPart: part More: mesh: 'nothing' is not the path of an asset")
    raises_here(function() thing:AddPart("More", { mesh = BARREL, root = true }) end, "root is for the parts a blueprint is defined with")
    raises_here(function() thing:AddPart("", { mesh = BARREL }) end, "a part is named by a short string")
    local other = crate:Spawn(AT)
    raises_here(function() other:Part("Sign") end, "this Crate has no part named 'Sign'")
    local bare = mine(function() return Blueprints:Define("Bare", {}) end):Spawn({ 7, 8, 9 }, { Yaw = 180 })
    local first = bare:AddPart("Body", { mesh = CRATE, scale = 3 })
    near(store_of(first).world.Translation.X, 7, "the first part with a place becomes the root, where the thing was spawned")
    near(store_of(first).world.Rotation.Z, 1)
    near(store_of(first).world.Scale3D.X, 3)
    module.MAX_PARTS = 2
    bare:AddPart("Second", { mesh = CRATE })
    raises_here(function() bare:AddPart("Third", { mesh = CRATE }) end, "it has 2 parts, and that is as many as a thing can have")
    t.eq(world.dead_touches, 0)
end)

t.test("Destroy takes the actor and its parts away, and the thing says so from then on", function()
    fresh()
    local _, mine = mod("MyMod")
    local crate = mine(function() return Blueprints:Define("Crate", { parts = CRATE_PARTS }) end)
    local thing, stays = crate:Spawn(AT, nil, { kept = 1 }), crate:Spawn(AT)
    local lamp, actor_instance = thing:Part("Lamp"), thing.Actor
    t.eq(thing.Alive, true)
    t.eq(thing:IsValid(), true)
    t.eq(thing:Destroy(), true)
    t.eq(engine.destroyed, 1)
    t.eq(alive_actors(), 1)
    t.eq(thing.Alive, false)
    t.eq(thing:IsValid(), false)
    t.eq(thing:Destroy(), false, "a second time does nothing")
    t.eq(engine.destroyed, 1)
    t.eq(thing.Data.kept, 1, "its state can still be read")
    t.ok(rawequal(thing.Blueprint, crate))
    t.eq(tostring(thing), "Crate (destroyed)")
    raises_here(function() return thing.Name end, "this Crate no longer exists (it was destroyed)")
    raises_here(function() return thing.Actor end, "this Crate no longer exists (it was destroyed)")
    raises_here(function() return thing.Position end, "this Crate no longer exists")
    raises_here(function() thing:Part("Lamp") end, "this Crate no longer exists")
    raises_here(function() thing:AddPart("More", { mesh = CRATE }) end, "this Crate no longer exists")
    raises_here(function() thing:GetBounds() end, "this Crate no longer exists")
    raises_here(function() thing.bHidden = true end, "this Crate no longer exists")
    local method = stays.SetLifeSpan
    raises_here(function() method(thing, 5) end, "this Crate no longer exists")
    t.raises(function() return lamp.Name end, "no longer exists")
    t.raises(function() return actor_instance.Name end, "no longer exists")
    t.eq(crate:Count(), 1)
    t.ok(rawequal(crate:GetThings()[1], stays))
    t.eq(stays.Alive, true)
    frame(3)
    t.eq(world.dead_touches, 0, "nothing of the destroyed actor was touched")
    t.eq(errors(), 0)
end)

-- ---------------------------------------------------------------------------------------------------------- functions

t.test("stepped runs every frame with the time since its last run, and only for things that have it", function()
    fresh()
    local _, mine = mod("MyMod")
    local runs = {}
    local spinner, still = mine(function()
        return Blueprints:Define("Spinner", { parts = { Body = { mesh = CRATE } }, stepped = function(thing, dt)
            runs[#runs + 1] = { thing = thing, dt = dt, owner = scope.current() }
            thing.Facing = { Yaw = (thing.Facing.Yaw + 90 * dt) % 360 }
        end }), Blueprints:Define("Still", { parts = { Body = { mesh = CRATE } } })
    end)
    local a, b = spinner:Spawn(AT), spinner:Spawn(AT)
    still:Spawn(AT)
    t.eq(module.stats().stepping, 2, "a thing with no function is not looked at")
    t.eq(#runs, 0, "nothing runs inside Spawn")
    frame()
    t.eq(#runs, 2)
    t.ok(rawequal(runs[1].thing, a) and rawequal(runs[2].thing, b), "oldest first")
    near(runs[1].dt, FRAME)
    t.eq(runs[1].owner.name, "MyMod", "as the mod that defined the blueprint")
    frame(4)
    t.eq(#runs, 10)
    near(a.Facing.Yaw, 90 * FRAME * 5)
    a:Destroy()
    frame(2)
    t.eq(#runs, 12, "a destroyed thing is not stepped")
    t.eq(module.stats().stepping, 1)
    t.eq(errors(), 0)
    t.eq(world.dead_touches, 0)
end)

t.test("every runs at its own pace beside stepped", function()
    fresh()
    local _, mine = mod("MyMod")
    local ticks, steps = {}, 0
    local clock = mine(function()
        return Blueprints:Define("Clock", { every = { 0.1, function(thing, dt) ticks[#ticks + 1] = { thing, dt } end },
            stepped = function() steps = steps + 1 end })
    end)
    local thing = clock:Spawn(AT)
    frame(6)
    t.eq(#ticks, 0, "not before its time")
    frame(1)
    t.eq(#ticks, 1)
    t.ok(rawequal(ticks[1][1], thing))
    near(ticks[1][2], 7 * FRAME)
    frame(7)
    t.eq(#ticks, 2)
    near(ticks[2][2], 7 * FRAME)
    t.eq(steps, 14)
    local slow = mine(function() return Blueprints:Define("Slow", { every = { 1, function() ticks[#ticks + 1] = "slow" end } }) end)
    slow:Spawn(AT)
    t.eq(module.stats().stepping, 2, "a thing with only every is in the list too")
    frame(70)
    local slow_ticks = 0
    for _, tick in ipairs(ticks) do
        if tick == "slow" then slow_ticks = slow_ticks + 1 end
    end
    t.eq(slow_ticks, 1)
end)

t.test("when stepping takes too long the rest wait a frame, and every thing gets its turn", function()
    fresh()
    local _, mine = mod("MyMod")
    local runs, dts = {}, {}
    local heavy = mine(function()
        return Blueprints:Define("Heavy", { stepped = function(thing, dt)
            runs[thing.Data.n] = (runs[thing.Data.n] or 0) + 1
            dts[thing.Data.n] = dt
            now = now + 0.0009
        end })
    end)
    for n = 1, 6 do heavy:Spawn(AT, nil, { n = n }) end
    frame()
    t.eq((runs[1] or 0) + (runs[2] or 0) + (runs[3] or 0), 3, "three fit in the 2 ms a frame has")
    t.eq(runs[4], nil)
    t.eq(#warnings, 1)
    t.ok(warnings[1]:find("took more than 2 ms in one frame, so the rest waited a frame. The last to run was a Heavy", 1, true), warnings[1])
    frame()
    t.eq(runs[4], 1, "the next frame goes on where the last stopped")
    t.eq(runs[6], 1)
    t.eq(runs[1], 1)
    t.ok(dts[4] > FRAME * 1.5, "a thing that waited is told the longer time")
    frame(10)
    local least, most = math.huge, 0
    for n = 1, 6 do
        least, most = math.min(least, runs[n]), math.max(most, runs[n])
    end
    t.ok(most - least <= 1, "no thing is served more often than another: " .. least .. " to " .. most)
    t.eq(#warnings, 1, "said once")
    t.ok(module.stats().over_budget >= 10)
end)

t.test("an error in a function is reported and the others go on, and five in a row switch it off", function()
    fresh()
    local _, mine = mod("MyMod")
    local good = 0
    local broken, fine = mine(function()
        return Blueprints:Define("Broken", { stepped = function() error("it broke") end }),
            Blueprints:Define("Fine", { stepped = function() good = good + 1 end })
    end)
    broken:Spawn(AT)
    fine:Spawn(AT)
    frame()
    t.eq(good, 1, "the other blueprint's things are stepped")
    t.eq(guard.errors()[1].channel, "MyMod", "the error is the mod's")
    t.ok(guard.errors()[1].message:find("it broke", 1, true))
    t.eq(guard.errors()[1].label, "Broken.stepped")
    frame(10)
    t.eq(good, 11)
    t.eq(guard.errors()[1].count, 5, "it was called five times and no more")
    t.ok(guard.errors()[2].message:find("switched off after 5 consecutive errors", 1, true))
end)

t.test("a function may destroy its own thing, another thing, or spawn one more", function()
    fresh()
    local _, mine = mod("MyMod")
    local order = {}
    local chain
    chain = mine(function()
        return Blueprints:Define("Chain", { stepped = function(thing)
            order[#order + 1] = thing.Data.n
            if thing.Data.n == 1 then
                thing:Destroy()
            elseif thing.Data.n == 2 then
                thing.Data.victim:Destroy()
            elseif thing.Data.n == 4 and not thing.Data.spawned then
                thing.Data.spawned = true
                chain:Spawn(AT, nil, { n = 5 })
            end
        end })
    end)
    local third = nil
    chain:Spawn(AT, nil, { n = 1 })
    local second = chain:Spawn(AT, nil, { n = 2 })
    third = chain:Spawn(AT, nil, { n = 3 })
    second.Data.victim = third
    chain:Spawn(AT, nil, { n = 4 })
    frame()
    t.eq(table.concat(order, ","), "1,2,4", "the one destroyed before its turn is skipped, the new one waits a frame")
    frame()
    t.eq(table.concat(order, ","), "1,2,4,2,4,5")
    t.eq(chain:Count(), 3)
    t.eq(module.stats().stepping, 3)
    t.eq(errors(), 0)
    t.eq(world.dead_touches, 0)
end)

t.test("touched is told of each actor that starts to overlap, once, looked for every few frames", function()
    fresh()
    local _, mine = mod("MyMod")
    local touched = {}
    local pad = mine(function()
        return Blueprints:Define("Pad", { parts = { Body = { mesh = CRATE, collision = "touch" } },
            touched = function(thing, other) touched[#touched + 1] = { thing = thing, other = other } end })
    end)
    t.eq(#warnings, 0)
    local thing = pad:Spawn(AT)
    local actor = last_spawn().actor
    local walker = values.actor(by_path["/script/engine.pawn"], "Walker_1", { Location = { 0, 0, 0 } })
    local rock = values.actor(actor_class, "Rock_1", { Location = { 0, 0, 0 } })
    engine.asked = 0
    frame(module.TOUCH_FRAMES)
    t.eq(engine.asked, 1, "one look in that many frames")
    t.ok(engine.filter == actor_class, "the game is asked for actors")
    t.eq(#touched, 0)
    engine.overlaps[actor] = { walker }
    frame(module.TOUCH_FRAMES)
    t.eq(#touched, 1)
    t.ok(rawequal(touched[1].thing, thing))
    t.ok(instance.is_instance(touched[1].other))
    t.eq(touched[1].other.Name, "Walker_1")
    frame(module.TOUCH_FRAMES * 3)
    t.eq(#touched, 1, "not again while it stays")
    engine.overlaps[actor] = { walker, rock }
    frame(module.TOUCH_FRAMES)
    t.eq(#touched, 2)
    t.eq(touched[2].other.Name, "Rock_1")
    engine.overlaps[actor] = {}
    frame(module.TOUCH_FRAMES)
    engine.overlaps[actor] = { walker }
    frame(module.TOUCH_FRAMES)
    t.eq(#touched, 3, "again when it comes back")
    t.eq(module.stats().touching, 1)
    t.eq(module.stats().looks, engine.asked)
    t.eq(errors(), 0)
    local plain_one = mine(function() return Blueprints:Define("Plain", { parts = { Body = { mesh = CRATE } }, touched = function() end }) end)
    t.eq(#warnings, 1)
    t.eq(warnings[1], "Plain has a touched function and no part with collision = \"touch\", so nothing can touch it")
    t.ok(plain_one)
end)

t.test("touching can be switched off, and switches itself off when the game does not answer", function()
    fresh()
    local _, mine = mod("MyMod")
    local touched = 0
    local pad = mine(function()
        return Blueprints:Define("Pad", { parts = { Body = { mesh = CRATE, collision = "touch" } }, touched = function() touched = touched + 1 end })
    end)
    pad:Spawn(AT)
    engine.overlaps[last_spawn().actor] = { values.actor(actor_class, "Rock_2", { Location = { 0, 0, 0 } }) }
    engine.overlap_raises = true
    frame(module.TOUCH_FRAMES * 2)
    t.eq(touched, 0)
    t.eq(#problems, 1, "said once")
    t.ok(problems[1]:find("the game did not say what touches a thing (the game would not say). No touched function runs until Wax starts again", 1, true),
        problems[1])
    t.eq(module.stats().touch, false)
    engine.overlap_raises = false
    frame(module.TOUCH_FRAMES * 2)
    t.eq(touched, 0, "it is not asked again")
    fresh()
    module.TOUCH = false
    _, mine = mod("MyMod")
    raises_here(function() mine(function() Blueprints:Define("Pad", { touched = function() end }) end) end,
        "touched is switched off in this version of Wax")
    raises_here(function() mine(function() Blueprints:Define("Pad", { parts = { Body = { mesh = CRATE, collision = "touch" } } }) end) end,
        "part Body: collision = \"touch\" is switched off in this version of Wax")
end)

t.test("ended runs once, a frame later, whoever destroyed the thing", function()
    fresh()
    local _, mine = mod("MyMod")
    local ended = {}
    local crate = mine(function()
        return Blueprints:Define("Crate", { parts = CRATE_PARTS, ended = function(thing, reason)
            ended[#ended + 1] = { thing = thing, reason = reason, alive = thing.Alive, state = thing.Data.n, owner = scope.current() }
        end })
    end)
    local first, second = crate:Spawn(AT, nil, { n = 1 }), crate:Spawn(AT, nil, { n = 2 })
    local second_actor = last_spawn().actor
    first:Destroy()
    t.eq(#ended, 0, "not inside Destroy")
    frame()
    t.eq(#ended, 1)
    t.ok(rawequal(ended[1].thing, first))
    t.eq(ended[1].reason, "Destroyed")
    t.eq(ended[1].alive, false)
    t.eq(ended[1].state, 1, "its state is still there")
    t.eq(ended[1].owner.name, "MyMod")
    world.destroy(second_actor, 0)
    world.free(second_actor)
    t.eq(second.Alive, false, "the game destroyed it, and the thing knows at once")
    frame(3)
    t.eq(#ended, 2)
    t.eq(ended[2].reason, "Destroyed")
    t.eq(ended[2].state, 2)
    local third = crate:Spawn(AT, nil, { n = 3 })
    world.destroy(last_spawn().actor, 3)
    world.free(last_spawn().actor)
    frame()
    t.eq(ended[3].reason, "Unloaded")
    t.ok(rawequal(ended[3].thing, third))
    raises_here(function() return third.Name end, "this Crate no longer exists (its part of the world was unloaded)")
    frame(5)
    t.eq(#ended, 3, "never twice")
    t.eq(crate:Count(), 0)
    t.eq(world.dead_touches, 0)
    t.eq(errors(), 0)
end)

t.test("began waits for the actor to begin play, and nothing is stepped before it", function()
    fresh()
    local _, mine = mod("MyMod")
    local began, steps = 0, 0
    local crate = mine(function()
        return Blueprints:Define("Crate", { parts = CRATE_PARTS, began = function() began = began + 1 end,
            stepped = function() steps = steps + 1 end })
    end)
    engine.world_begun = false
    local thing = crate:Spawn(AT)
    t.eq(began, 0, "the world has not begun play, so neither has the actor")
    t.eq(module.stats().waiting, 1)
    t.eq(module.stats().listening, true, "begin of play is listened for while a thing waits")
    frame(3)
    t.eq(began, 0)
    t.eq(steps, 0)
    t.eq(thing.Alive, true)
    local lost = crate:Spawn(AT)
    lost:Destroy()
    begin_world()
    t.eq(began, 0, "nothing of the mod runs inside the engine's call")
    frame()
    t.eq(began, 1, "the destroyed one never begins")
    t.eq(steps, 1)
    t.eq(module.stats().waiting, 0)
    t.eq(module.stats().listening, false)
    frame(2)
    t.eq(began, 1)
    t.eq(steps, 3)
    t.eq(world.dead_touches, 0)
end)

-- ---------------------------------------------------------------------------------------------------------- ownership

t.test("when a mod unloads its things are destroyed and its blueprints forgotten, and no other mod's", function()
    fresh()
    local owner, mine = mod("MyMod")
    local _, theirs = mod("OtherMod")
    local ended = 0
    local crate = mine(function() return Blueprints:Define("Crate", { parts = CRATE_PARTS, ended = function() ended = ended + 1 end }) end)
    local barrel = theirs(function() return Blueprints:Define("Barrel", { parts = { Body = { mesh = BARREL } } }) end)
    local a, b = crate:Spawn(AT), crate:Spawn(AT)
    local keeps = barrel:Spawn(AT)
    local from_other = theirs(function() return crate:Spawn(AT) end)
    t.eq(alive_actors(), 4)
    local size = owner:size()
    crate:Spawn(AT):Destroy()
    t.eq(owner:size(), size, "a thing leaves nothing behind with its mod")
    frame()
    ended = 0
    local failures = owner:destroy()
    t.eq(#failures, 0)
    t.eq(alive_actors(), 1, "the things of the blueprint went, whoever called Spawn")
    t.eq(a.Alive, false)
    t.eq(b.Alive, false)
    t.eq(from_other.Alive, false)
    t.eq(keeps.Alive, true)
    t.eq(Blueprints:Get("Crate"), nil)
    t.ok(rawequal(Blueprints:Get("Barrel"), barrel))
    frame(3)
    t.eq(ended, 0, "ended does not run for a mod that is going")
    raises_here(function() crate:Spawn(AT) end, "the blueprint Crate was removed, so nothing can be spawned from it. Define it again")
    raises_here(function() return a.Name end, "this Crate no longer exists (its blueprint was removed)")
    collect()
    t.eq(memory[CRATE:lower()], nil, "its mesh is let go")
    t.ok(memory[BARREL:lower()] ~= nil, "the other mod's is kept")
    local stats = module.stats()
    t.eq(stats.blueprints, 1)
    t.eq(stats.things, 1)
    t.eq(#Blueprints:GetThings(), 1)
    t.eq(world.dead_touches, 0)
    t.eq(errors(), 0)
end)

t.test("defining a name again replaces the blueprint for its own mod, and another mod cannot take it", function()
    fresh()
    local owner, mine = mod("MyMod")
    local _, theirs = mod("OtherMod")
    local crate = mine(function() return Blueprints:Define("Crate", { parts = CRATE_PARTS }) end)
    local old_thing = crate:Spawn(AT)
    raises_here(function() theirs(function() Blueprints:Define("crate", {}) end) end,
        "another mod (MyMod) already has a blueprint named Crate. Pick another name")
    raises_here(function() Blueprints:Define("Crate", {}) end, "another mod (MyMod) already has a blueprint named Crate")
    raises_here(function() mine(function() Blueprints:Define("Crate", { base = "Nothing" }) end) end, "the game has no class named 'Nothing'")
    t.ok(rawequal(Blueprints:Get("Crate"), crate), "a Define that failed leaves the old one")
    t.eq(old_thing.Alive, true)
    local size = owner:size()
    local newer = mine(function() return Blueprints:Define("Crate", { parts = { Body = { mesh = BARREL } } }) end)
    t.ok(not rawequal(newer, crate))
    t.ok(rawequal(Blueprints:Get("Crate"), newer))
    t.eq(old_thing.Alive, false, "the old blueprint's things go with it")
    t.eq(alive_actors(), 0)
    t.ok(owner:size() <= size + 1, "the old registration is taken out")
    raises_here(function() crate:Spawn(AT) end, "the blueprint Crate was removed")
    t.ok(newer:Spawn(AT).Alive)
    newer:Remove()
    t.eq(Blueprints:Get("Crate"), nil)
    t.eq(alive_actors(), 0)
    newer:Remove()
    local console = Blueprints:Define("Console", {})
    t.ok(console:Spawn(AT).Alive, "a blueprint can be defined with no mod running")
    raises_here(function() mine(function() Blueprints:Define("Console", {}) end) end, "another mod (the console) already has a blueprint named Console")
    t.eq(world.dead_touches, 0)
end)

t.test("GetThings lists the things that are in the world, oldest first", function()
    fresh()
    local _, mine = mod("MyMod")
    local crate, barrel = mine(function()
        return Blueprints:Define("Crate", {}), Blueprints:Define("Barrel", {})
    end)
    local a, b, c, d = crate:Spawn(AT), barrel:Spawn(AT), crate:Spawn(AT), barrel:Spawn(AT)
    local every = Blueprints:GetThings()
    t.eq(#every, 4)
    t.ok(rawequal(every[1], a) and rawequal(every[2], b) and rawequal(every[3], c) and rawequal(every[4], d))
    local crates = crate:GetThings()
    t.eq(#crates, 2)
    t.ok(rawequal(crates[1], a) and rawequal(crates[2], c))
    b:Destroy()
    t.eq(#Blueprints:GetThings(), 3, "at once, before the next frame")
    t.eq(barrel:Count(), 1)
    frame()
    t.ok(rawequal(Blueprints:GetThings()[2], c))
    module.MAX_THINGS = 4
    crate:Spawn(AT)
    raises_here(function() crate:Spawn(AT) end, "Crate:Spawn: 4 things are in the world already, and that is as many as Wax keeps. Destroy some first")
end)

-- --------------------------------------------------------------------------------------------------------- map change

t.test("a map change takes every thing away untouched, and the blueprints spawn again in the new world", function()
    fresh()
    local _, mine = mod("MyMod")
    local ended, steps = {}, 0
    local crate = mine(function()
        return Blueprints:Define("Crate", {
            parts = { Body = { mesh = CRATE, root = true, material = { from = GLOW, colors = { Color = "Orange" } } },
                      Lamp = { class = "PointLightComponent", at = { 0, 0, 150 } } },
            stepped = function() steps = steps + 1 end,
            ended = function(thing, reason) ended[#ended + 1] = { reason, thing.Data.n, thing.Alive } end,
        })
    end)
    local a, b = crate:Spawn(AT, nil, { n = 1 }), crate:Spawn(AT, nil, { n = 2 })
    local lamp = a:Part("Lamp")
    local old_material = store_of(a:Part("Body")).materials[0]
    frame()
    steps = 0
    travel("Terrain_017")
    t.eq(alive_actors(), 0)
    t.eq(a.Alive, false)
    t.eq(#ended, 2, "ended ran for each, once")
    t.eq(ended[1][1], "MapChanged")
    t.eq(ended[1][2] + ended[2][2], 3)
    t.eq(ended[1][3], false)
    t.eq(steps, 0, "nothing was stepped after the map went")
    raises_here(function() return a.Name end, "this Crate no longer exists (the map changed)")
    t.raises(function() return lamp.Name end)
    t.eq(crate:Count(), 0)
    t.eq(#Blueprints:GetThings(), 0)
    t.eq(module.stats().things, 0)
    t.ok(rawequal(Blueprints:Get("Crate"), crate), "the blueprint is still there")
    local again = crate:Spawn(AT)
    t.ok(again.Alive)
    t.ok(last_spawn().context == world_now, "in the new world")
    t.eq(again:Part("Lamp").ClassName, "PointLightComponent")
    local new_material = store_of(again:Part("Body")).materials[0]
    t.ok(new_material ~= old_material and new_material:IsA(dynamic_class), "its material was made again")
    frame(2)
    t.eq(steps, 2)
    t.eq(#ended, 2)
    t.eq(world.dead_touches, 0, "nothing of the old world was touched")
    t.eq(errors(), 0)
end)

t.test("a map change whose end of play was not seen is no different", function()
    fresh()
    local _, mine = mod("MyMod")
    local ended = {}
    local crate = mine(function()
        return Blueprints:Define("Crate", { parts = CRATE_PARTS, stepped = function(thing) return thing.Name end,
            touched = function() end, ended = function(_, reason) ended[#ended + 1] = reason end })
    end)
    local a = crate:Spawn(AT)
    crate:Spawn(AT)
    frame(2)
    travel("Terrain_018", true)
    t.eq(a.Alive, false)
    t.eq(table.concat(ended, ","), "MapChanged,MapChanged")
    frame(module.TOUCH_FRAMES * 2)
    t.eq(world.dead_touches, 0)
    t.eq(errors(), 0)
    t.eq(module.stats().stepping, 0)
    t.eq(module.stats().touching, 0)
end)

t.test("what was given as an Instance is asked for again by its path, and what has no path says so", function()
    fresh()
    local _, mine = mod("MyMod")
    local by_instance, by_made = mine(function()
        local mesh, class_now = game.Assets:Load(CRATE), game.Assets:Load("/Script/Engine.PointLightComponent")
        local material = game.Assets:Material(GLOW)
        return Blueprints:Define("ByInstance", { base = game.Assets:Load("/Script/Engine.Actor"),
                parts = { Body = { mesh = mesh, root = true }, Lamp = { class = class_now } } }),
            Blueprints:Define("ByMade", { parts = { Body = { mesh = CRATE, material = material } } })
    end)
    by_instance:Spawn(AT)
    by_made:Spawn(AT)
    travel("Terrain_019")
    local again = by_instance:Spawn(AT)
    t.eq(store_of(again:Part("Body")).mesh, memory[CRATE:lower()])
    t.eq(again:Part("Lamp").ClassName, "PointLightComponent")
    local before = alive_actors()
    raises_here(function() by_made:Spawn(AT) end,
        "ByMade:Spawn: part Body: material was given as an Instance that no longer exists (the map changed, or it was let go). "
        .. "Give its path, which can be asked for again, or define the blueprint again")
    t.eq(alive_actors(), before, "nothing was spawned for it")
    local gone = mine(function() return game.Assets:Load(BARREL) end)
    mine(function() game.Assets:Release(gone) end)
    raises_here(function() mine(function() Blueprints:Define("Late", { parts = { Body = { mesh = gone } } }) end) end,
        "part Body: mesh is an Instance that no longer exists. Ask for it again")
    t.eq(world.dead_touches, 0)
end)

-- ------------------------------------------------------------------------------------------------------------ the rest

t.test("with handles, a thing whose actor went without its end of play being seen is found, and nothing gone is touched", function()
    fresh({ handles = true })
    local _, mine = mod("MyMod")
    local ended, steps, touched = {}, 0, 0
    local crate = mine(function()
        return Blueprints:Define("Crate", { parts = CRATE_PARTS, ended = function(_, reason) ended[#ended + 1] = reason end })
    end)
    local spinner, pad = mine(function()
        return Blueprints:Define("Spinner", { stepped = function(thing)
            steps = steps + 1
            return thing.Name
        end }), Blueprints:Define("Pad", { parts = { Body = { mesh = CRATE, collision = "touch" } }, touched = function() touched = touched + 1 end })
    end)
    local things = { crate:Spawn(AT), crate:Spawn(AT), crate:Spawn(AT) }
    local quiet = last_spawn().actor
    local spun = spinner:Spawn(AT)
    local spun_actor = last_spawn().actor
    local padded = pad:Spawn(AT)
    local pad_actor = last_spawn().actor
    frame(4)
    world.free(quiet)
    world.free(spun_actor)
    world.free(pad_actor)
    t.eq(things[3].Alive, false, "Alive asks the handle")
    t.eq(things[2].Alive, true)
    frame()
    t.eq(steps, 5)
    frame(module.TOUCH_FRAMES + 5)
    t.eq(steps, 5, "a stepped function that failed on a thing that is gone is not called for it again")
    t.eq(spun.Alive, false)
    t.eq(padded.Alive, false, "the look for what touches a thing asks the handle first")
    t.eq(#ended, 1)
    t.eq(ended[1], "Destroyed")
    t.eq(crate:Count(), 2)
    t.eq(module.stats().things, 2)
    t.eq(#guard.errors(), 1, "the one failure was reported, and not held against the function")
    t.eq(guard.errors()[1].count, 1)
    t.eq(things[1]:Destroy(), true)
    t.eq(alive_actors(), 1)
    t.eq(world.dead_touches, 0, "nothing that is gone was touched")
end)

t.test("without handles such a thing is not asked about: Wax itself touches nothing that may be gone", function()
    fresh()
    local _, mine = mod("MyMod")
    local ticks = 0
    local crate = mine(function() return Blueprints:Define("Crate", { parts = CRATE_PARTS, every = { 0.05, function() ticks = ticks + 1 end } }) end)
    local thing = crate:Spawn(AT)
    frame(2)
    world.free(last_spawn().actor)
    frame(30)
    t.ok(ticks > 5, "its functions still run")
    t.eq(thing.Alive, true, "its own flag stands, because nothing else can be known")
    t.eq(crate:Count(), 1)
    t.eq(world.dead_touches, 0)
    travel("Terrain_020", true)
    t.eq(thing.Alive, false, "until the map goes")
    t.eq(world.dead_touches, 0)
    t.eq(errors(), 0)
end)

t.test("stopping destroys every thing and takes game.Blueprints away, and starting again uses the same list", function()
    fresh()
    local _, mine = mod("MyMod")
    local crate = mine(function() return Blueprints:Define("Crate", { parts = CRATE_PARTS, stepped = function() end }) end)
    local thing = crate:Spawn(AT)
    crate:Spawn(AT)
    module.stop()
    t.eq(alive_actors(), 0)
    t.eq(thing.Alive, false)
    t.eq(rawget(game, "Blueprints"), nil)
    raises_here(function() return game.Blueprints end, "Blueprints is not a member of game")
    frame(3)
    Wax.modules["world.blueprints"] = nil
    module = Wax.import("world.blueprints")
    module.clock = function() return now end
    module.start()
    Blueprints = game.Blueprints
    local steps = 0
    local again = mine(function() return Blueprints:Define("Crate", { stepped = function() steps = steps + 1 end }) end)
    again:Spawn(AT)
    frame(3)
    t.eq(steps, 3, "stepped once a frame, not once for each time the module was loaded")
    local lists = 0
    for _ in pairs(track.stats().sets) do lists = lists + 1 end
    t.eq(lists, 1)
    t.eq(world.dead_touches, 0)
    t.eq(errors(), 0)
end)

t.test("what a frame costs: nothing without things, one look with them, and no asset is asked for twice", function()
    fresh()
    local _, mine = mod("MyMod")
    local crate = mine(function() return Blueprints:Define("Crate", { parts = CRATE_PARTS }) end)
    local touches = world.touches
    frame(20)
    local idle = world.touches - touches
    local things = {}
    for index = 1, 10 do things[index] = crate:Spawn(AT) end
    frame()
    touches = world.touches
    frame(20)
    local busy = world.touches - touches
    t.ok(busy - idle <= 20 * 6, ("ten things with no functions cost one look a frame: %d engine reads in 20 frames, %d without"):format(busy, idle))
    local asked = asked_memory
    crate:Spawn(AT)
    t.ok(asked_memory - asked <= 1, "a spawn in the same frame asks for no asset again")
    local started = os.clock()
    for _ = 1, 200 do crate:Spawn(AT):Destroy() end
    print(("    200 spawns and destroys of a thing with two parts on the stand-in: %.1f ms"):format((os.clock() - started) * 1000))
    t.eq(world.dead_touches, 0)
end)

t.test("nothing reached the engine in a form it would drop, bend or crash on", function()
    t.eq(values.crashes, 0, table.concat(values.log, " | "))
    t.eq(values.dropped, 0, table.concat(values.log, " | "))
    t.eq(values.silent, 0, table.concat(values.log, " | "))
    t.eq(values.misuse, 0, table.concat(values.log, " | "))
    t.eq(world.dead_touches, 0, tostring(world.dead_where))
end)

t.test("what a mod author reads is plain", function()
    local unwanted = wording.unwanted()
    if unwanted then t.ok(wording.complete(unwanted), "the owner's list was read whole from " .. wording.SOURCE) end
    local file = assert(io.open("wax/types/blueprints.lua", "rb"))
    local text = file:read("a")
    file:close()
    local lines = 0
    for line in text:gmatch("[^\r\n]+") do
        if line:sub(1, 3) == "---" then
            lines = lines + 1
            t.eq(wording.wrong_with(line:sub(4), unwanted), nil, "wax/types/blueprints.lua: " .. line:sub(1, 70))
        end
    end
    t.ok(lines > 60, "the type file was read")
    t.ok(#said > 60, "the messages of this suite were gathered")
    for _, message in ipairs(said) do t.eq(wording.wrong_with(message, unwanted), nil, message) end
    for _, name in ipairs({ "Define", "Get", "GetThings", "Spawn", "Count", "Remove", "Part", "AddPart", "GetBounds", "Destroy", "Alive",
        "Data", "Blueprint", "Actor", "Position", "Facing", "Name", "Base" }) do
        t.ok(text:find("[: ]" .. name .. "[ (]"), name .. " is described in wax/types/blueprints.lua")
    end
    for _, option in ipairs({ "base", "parts", "set", "began", "stepped", "every", "touched", "ended", "class", "mesh", "material", "at",
        "rotation", "scale", "collision", "root", "name", "from", "colors", "numbers", "textures" }) do
        t.ok(text:find("---@field " .. option .. "%?? "), "the option " .. option .. " is described in wax/types/blueprints.lua")
    end
end)

fresh()
t.finish("blueprints")
