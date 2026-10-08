-- Offline tests for the model view (gui/model.lua) and the list of creature models (world/creature_models.lua).
-- Widgets come from the permissive fake engine. Everything in the world is unkind: an actor, a part of one, an asset
-- or a picture answers only the members the game has, a destroyed actor raises on any use but IsValid (which still
-- says true, as it does in the game for up to a minute), and one the engine freed raises on every use.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\model_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local fake = dofile("wax/tests/offline/fake_engine.lua")
fake.install()

local Wax = t.new_wax()
_G.Wax = Wax
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local log = Wax.import("core.log")
local sched = Wax.import("core.sched")
Wax.log, Wax.guard, Wax.sched = log, guard, sched
Wax.mods = { list = function() return {} end, request_reload = function() end, request_sync = function() end }
Wax.import("core.storage").directory = nil

-- A clock the tests move: a frame is a sixtieth of a second, and loading takes the time each test gives it.
local clock = 100
Wax.perf = { now = function() return clock end }

-- the world -----------------------------------------------------------------------------------------------------------
local PENDING_KILL = 0x20000000
local world = { dead_touches = 0, actors = {}, spawned = 0, targets = {}, materials = {}, loads = {}, load_seconds = 0,
    assets = {}, ended = {}, generation = 1, calls = 0 }
local next_address = 0x500000

local MEMBERS = {
    actor = { methods = { "AddComponentByClass", "FinishAddComponent", "K2_DestroyActor", "K2_SetActorRotation" }, arrays = { "Tags" } },
    scene = { methods = {} },
    mesh = { methods = { "SetCollisionEnabled", "SetVisibleInSceneCaptureOnly", "SetCastShadow", "SetLightingChannels", "SetSkeletalMesh",
        "SetForcedLOD", "SetRelativeScale3D", "SetMaterial", "SetMasterPoseComponent", "PlayAnimation", "SetAnimationMode", "SetAnimClass",
        "GetAnimInstance", "SetComponentTickEnabled", "K2_AttachToComponent" },
        properties = { "VisibilityBasedAnimTickOption", "bEnableUpdateRateOptimizations", "bPauseAnims" } },
    capture = { methods = { "ShowOnlyComponent", "K2_SetRelativeLocation" }, arrays = { "ShowFlagSettings" },
        properties = { "TextureTarget", "FOVAngle", "CaptureSource", "PrimitiveRenderMode", "bCaptureEveryFrame", "bCaptureOnMovement" } },
    light = { methods = {}, structs = { "LightingChannels" },
        properties = { "IntensityUnits", "Intensity", "AttenuationRadius", "SoftSourceRadius", "SpecularScale", "CastShadows", "LightColor" } },
    fur = { methods = { "K2_AttachToComponent", "SetMaterial", "SetComponentTickEnabled", "RegenerateFur" }, structs = { "LightingChannels" },
        properties = { "SkeletalGrowMesh", "FurSplines", "LayerCount", "FurLength", "MinFurLength", "ShellBias", "NoiseStrength",
            "ReferenceHairBias", "HairLengthForceUniformity", "RemoveFacesWithoutSplines", "PhysicsEnabled", "bVisibleInSceneCaptureOnly",
            "CastShadow" } },
    target = { methods = {} },
    material = { methods = { "SetTextureParameterValue" } },
    asset = { methods = {}, properties = { "ExtendedBounds" } },
    instance = { methods = { "GetClass" }, properties = { "PawnVelocity", "SourceMeshComponent" } },
}
for _, spec in pairs(MEMBERS) do
    spec.set = {}
    for _, group in ipairs({ "methods", "arrays", "structs", "properties" }) do
        for _, name in ipairs(spec[group] or {}) do spec.set[name] = group end
    end
end
local COMPONENTS = {
    ["/Script/Engine.SceneComponent"] = "scene", ["/Script/Engine.SkeletalMeshComponent"] = "mesh",
    ["/Script/Engine.SceneCaptureComponent2D"] = "capture", ["/Script/Engine.PointLightComponent"] = "light",
    ["/Script/GFur.GFurComponent"] = "fur",
}

local Thing = {}
local function thing(kind, name, more)
    next_address = next_address + 0x100
    local object = { __thing = kind, __name = name, __address = next_address, __values = {}, __calls = {}, __log = {} }
    for key, value in pairs(more or {}) do object[key] = value end
    return setmetatable(object, Thing)
end
local function gone(self, key)
    if rawget(self, "__freed") then
        world.dead_touches = world.dead_touches + 1
        world.dead_where = world.dead_where or (rawget(self, "__name") .. "." .. tostring(key) .. debug.traceback("", 3))
        error("touched a freed " .. rawget(self, "__thing") .. " (" .. tostring(key) .. ")", 3)
    end
    local owner = rawget(self, "__owner") or self
    if rawget(owner, "__destroyed") and key ~= "IsValid" and key ~= "HasAnyInternalFlags" and key ~= "GetAddress" then
        world.dead_touches = world.dead_touches + 1
        world.dead_where = world.dead_where or (rawget(self, "__name") .. "." .. tostring(key) .. debug.traceback("", 3))
        error("used a destroyed " .. rawget(self, "__thing") .. " (" .. tostring(key) .. ")", 3)
    end
end
local function record(self, name, ...)
    world.calls = world.calls + 1
    local calls = rawget(self, "__calls")
    calls[name] = calls[name] or {}
    calls[name][#calls[name] + 1] = table.pack(...)
    local list = rawget(self, "__log")
    list[#list + 1] = name
end

local SPECIAL = {}
function SPECIAL.IsValid() return true end
function SPECIAL.GetAddress(self) return rawget(self, "__address") end
function SPECIAL.HasAnyInternalFlags(self, flag) return flag == PENDING_KILL and rawget(rawget(self, "__owner") or self, "__destroyed") == true end
function SPECIAL.GetFName(self) return { ToString = function() return rawget(self, "__name") end } end
function SPECIAL.IsA(self, class)
    local wanted = rawget(class, "__name")
    for _, path in ipairs(rawget(self, "__classes") or {}) do
        if path == wanted then return true end
    end
    return false
end
function SPECIAL.GetClass(self) return rawget(self, "__class") end
function SPECIAL.AddComponentByClass(self, class, manual, transform, deferred)
    record(self, "AddComponentByClass", class, manual, transform, deferred)
    local kind = COMPONENTS[rawget(class, "__name")]
    if not kind then error("the fake world has no component of the class " .. tostring(rawget(class, "__name")), 2) end
    local part = thing(kind, kind .. "_" .. (#rawget(self, "__parts") + 1), { __owner = self, __manual = manual, __at = transform,
        __registered = not deferred })
    local parts = rawget(self, "__parts")
    parts[#parts + 1] = part
    return part
end
function SPECIAL.FinishAddComponent(self, part, manual, transform)
    record(self, "FinishAddComponent", part, manual, transform)
    -- what a part holds when it registers is what the engine reads: show flags written later would be lost
    rawset(part, "__registered", true)
    rawset(part, "__at_register", #rawget(part, "__log"))
end
function SPECIAL.K2_DestroyActor(self)
    record(self, "K2_DestroyActor")
    for _, listener in ipairs(world.ended) do listener(self, rawget(self, "__address"), 0) end
    rawset(self, "__destroyed", true)
    for index, actor in ipairs(world.actors) do
        if actor == self then table.remove(world.actors, index) break end
    end
end
function SPECIAL.GetAnimInstance(self)
    record(self, "GetAnimInstance")
    return rawget(self, "__instance") or fake.new_object("no instance")
end
function SPECIAL.SetAnimClass(self, class)
    record(self, "SetAnimClass", class)
    rawset(self, "__instance", thing("instance", "instance", { __owner = rawget(self, "__owner"), __class = class }))
end

local EVERY = { IsValid = true, GetAddress = true, HasAnyInternalFlags = true, GetFName = true, IsA = true }
Thing.__index = function(self, key)
    gone(self, key)
    if EVERY[key] then return SPECIAL[key] end
    local spec = MEMBERS[rawget(self, "__thing")]
    local group = spec.set[key]
    if group == "methods" then return SPECIAL[key] or function(object, ...) record(object, key, ...) end end
    local values = rawget(self, "__values")
    if group == "arrays" or group == "structs" then
        if values[key] == nil then
            values[key] = group == "arrays" and setmetatable({}, { __index = function(list, index)
                -- reading one past the end of an engine array makes it one longer
                if type(index) == "number" and index == #list + 1 then
                    rawset(list, index, {})
                    return rawget(list, index)
                end
            end }) or {}
        end
        return values[key]
    end
    if group == "properties" then return values[key] end
    error("the game's " .. rawget(self, "__thing") .. " has no member " .. tostring(key), 2)
end
Thing.__newindex = function(self, key, value)
    gone(self, key)
    local spec = MEMBERS[rawget(self, "__thing")]
    if spec.set[key] ~= "properties" then error("the game's " .. rawget(self, "__thing") .. " has no property " .. tostring(key), 2) end
    world.calls = world.calls + 1
    local list = rawget(self, "__log")
    list[#list + 1] = key .. "="
    rawget(self, "__values")[key] = value
end

local function calls(object, name) return rawget(object, "__calls")[name] or {} end
local function value_of(object, name) return rawget(object, "__values")[name] end
local function parts_of(actor, kind)
    local out = {}
    for _, part in ipairs(rawget(actor, "__parts")) do
        if rawget(part, "__thing") == kind then out[#out + 1] = part end
    end
    return out
end

-- Everything the engine frees with a world: any use from then on raises.
local function free(object)
    rawset(object, "__freed", true)
    for _, part in ipairs(rawget(object, "__parts") or {}) do
        rawset(part, "__freed", true)
        local instance = rawget(part, "__instance")
        if instance then rawset(instance, "__freed", true) end
    end
end

-- A map change: every actor is told to end its play, then the old world's things are freed and there is a new world.
function world.change_map()
    local old = world.actors
    world.actors = {}
    for _, actor in ipairs(old) do
        for _, listener in ipairs(world.ended) do listener(actor, rawget(actor, "__address"), 1) end
    end
    for _, actor in ipairs(old) do free(actor) end
    world.generation = world.generation + 1
    world.object = fake.new_object("World_" .. world.generation)
    Wax.game.MapChanged:Fire("Map_" .. world.generation)
end

local CLASSES = {
    mesh = { "/Script/Engine.SkeletalMesh" }, material = { "/Script/Engine.MaterialInterface" },
    animation = { "/Script/Engine.AnimationAsset" }, splines = { "/Script/GFur.FurSplines" },
    blueprint = { "/Script/Engine.AnimBlueprintGeneratedClass" }, texture = { "/Script/Engine.Texture2D", "/Script/Engine.Texture" },
}
-- path -> what LoadAsset gives: { kind, radius } or "missing" (an error, as UE4SS raises one)
local function asset(path, kind, bounds)
    world.assets[path] = { kind = kind, bounds = bounds }
end
function LoadAsset(path)
    world.loads[#world.loads + 1] = path
    clock = clock + world.load_seconds
    local known = world.assets[path]
    if not known then error("LoadAsset: " .. tostring(path) .. " was not found", 0) end
    local object = thing("asset", path, { __classes = CLASSES[known.kind] })
    rawget(object, "__values").ExtendedBounds = known.bounds
    return object
end
local find_object = StaticFindObject
local registry = { IsValid = function() return true end, GetAsset = function() return { IsValid = function() return false end } end }
function StaticFindObject(path)
    if path == "/Script/AssetRegistry.Default__AssetRegistryHelpers" then return registry end
    return find_object(path)
end
local function loads_of(path)
    local count = 0
    for _, loaded in ipairs(world.loads) do
        if loaded == path then count = count + 1 end
    end
    return count
end

local controller = fake.new_object("controller")
local game_instance = fake.new_object("game instance")
world.object = fake.new_object("World_1")
Wax.game = { LocalPlayer = { Raw = controller }, GameInstance = { Raw = game_instance }, MapChanged = sched.Signal.new("MapChanged") }
fake.react.GetWorld = function() return world.object end
fake.react.SpawnActor = function(_, class, location, rotation)
    world.spawned = world.spawned + 1
    local actor = thing("actor", "Actor_" .. world.spawned, { __parts = {}, __location = location, __rotation = rotation, __spawn_class = class,
        __world = world.generation })
    world.actors[#world.actors + 1] = actor
    return actor
end
fake.react.CreateRenderTarget2D = function(_, context, width, height, format, colour, mips)
    local target = thing("target", "target_" .. (#world.targets + 1), { __outer = context, __width = width, __height = height,
        __format = format, __colour = colour, __mips = mips })
    world.targets[#world.targets + 1] = target
    return target
end
fake.react.CreateDynamicMaterialInstance = function(_, context, parent, name, flags)
    local material = thing("material", "material_" .. (#world.materials + 1), { __outer = context, __parent = parent, __flags = flags })
    world.materials[#world.materials + 1] = material
    return material
end
fake.react.GetAllActorsWithTag = function(_, _, tag, out)
    -- the engine walks the world's actors: one that was destroyed is not among them any more
    for _, actor in ipairs(world.actors) do
        local tags = rawget(actor, "__values").Tags
        if tags and rawget(tags, 1) == tag then out[#out + 1] = { get = function() return actor end } end
    end
end
-- end of play reaches the module the way engine/actors.lua delivers it
Wax.modules["engine.actors"] = { on_ended = function(fn)
    world.ended[#world.ended + 1] = fn
    return function()
        for index = #world.ended, 1, -1 do
            if world.ended[index] == fn then table.remove(world.ended, index) end
        end
    end
end }
local members_asked = 0
Wax.modules["engine.reflect"] = { class_info = function(class)
    members_asked = members_asked + 1
    local name = rawget(class, "__name")
    if name == "/Game/Saddle/Saddle_AnimBP.Saddle_AnimBP_C" then return { members = { SourceMeshComponent = { kind = "property" } } } end
    return { members = name == "/Game/Deer/Deer_AnimBP.Deer_AnimBP_C" and { PawnVelocity = { kind = "property" } } or {} }
end }

-- the interface -------------------------------------------------------------------------------------------------------
local ui = Wax.import("gui.init")
Wax.import("gui.kit").MEASURE = false      -- the stand-in engine gives every widget one size: text is fitted by its letters here
local wired = Wax.modules["gui.model"] ~= nil       -- true once gui/init.lua steps the model views itself
local events = Wax.import("gui.events")
local style = Wax.import("gui.style")
local controls = Wax.import("gui.controls")
local model = Wax.import("gui.model")
ui.start()
Wax.ui = ui
ui.Theme().animation = 0
local NAP = model.NAP
model.NAP = 1       -- a view that does not show is looked at every frame, so each test knows what a frame did

local function upvalue(fn, name)
    for index = 1, 80 do
        local found, value = debug.getupvalue(fn, index)
        if not found then return nil end
        if found == name then return value end
    end
end
-- Until gui/controls.lua registers the control itself, the suite does what its line will do.
local Container = controls.Container
if not rawget(Container, "Model") then
    local wrapper = Container.Slots
    local blank_control, slots_make = upvalue(wrapper, "blank_control"), upvalue(wrapper, "make")
    local tools = { place = upvalue(slots_make, "place"), new_control = upvalue(slots_make, "new_control"),
        listen = upvalue(upvalue(Container.Split, "make"), "listen") }
    assert(blank_control and tools.place and tools.new_control and tools.listen, "the helpers of controls.lua were not found")
    model.install(Container, tools)
    local make = Container.Model
    Container.Model = function(self, ...)
        local control = blank_control()
        local made = style.build(control, make, self, ...)
        if not control.widget then control.destroyed = true end
        return made
    end
end

local function frames(count)
    for _ = 1, count or 1 do
        clock = clock + 1 / 60
        sched.step()
        ui.step()
        if not wired then model.step() end
    end
end

local DEER = "/Game/Deer/SK_Deer.SK_Deer"
local BOUNDS = { Origin = { X = 0, Y = 30, Z = 100 }, BoxExtent = { X = 30, Y = 90, Z = 90 }, SphereRadius = 130 }
asset(model.PREVIEW, "material")
asset(DEER, "mesh", BOUNDS)
asset("/Game/Deer/SK_Deer_Fur.SK_Deer_Fur", "mesh", BOUNDS)
asset("/Game/Deer/Deer_Splines.Deer_Splines", "splines")
asset("/Game/Deer/M_Deer.M_Deer", "material")
asset("/Game/Deer/M_Deer_Fur.M_Deer_Fur", "material")
asset("/Game/Deer/Walk.Walk", "animation")
asset("/Game/Deer/Idle.Idle", "animation")
asset("/Game/Deer/Deer_AnimBP.Deer_AnimBP_C", "blueprint")
asset("/Game/Plain/Plain_AnimBP.Plain_AnimBP_C", "blueprint")
asset("/Game/Golem/SK_Rig.SK_Rig", "mesh", { Origin = { X = 0, Y = 0, Z = 50 }, BoxExtent = { X = 10, Y = 10, Z = 10 }, SphereRadius = 20 })
asset("/Game/Golem/SK_Leg.SK_Leg", "mesh", { Origin = { X = 0, Y = 100, Z = 50 }, BoxExtent = { X = 40, Y = 40, Z = 60 }, SphereRadius = 80 })
asset("/Game/UI/T_Icon.T_Icon", "texture")

local function deer(more)
    local look = { mesh = "/Game/Deer/SK_Deer", facing = -90, scale = 1.2, materials = { [1] = "/Game/Deer/M_Deer" },
        fur = { { mesh = "/Game/Deer/SK_Deer_Fur", splines = "/Game/Deer/Deer_Splines", layers = 16, length = 1.5, bias = 0,
            materials = { [1] = "/Game/Deer/M_Deer_Fur" } } },
        walk = "/Game/Deer/Walk", idle = "/Game/Deer/Idle", walks = true }
    for key, value in pairs(more or {}) do look[key] = value end
    return look
end

local owner = scope.new("model-test")
local window, view
local seen = { loaded = 0, failed = {}, turned = {}, clicked = 0 }
local function watch(control)
    control.Loaded:Connect(function() seen.loaded = seen.loaded + 1 end)
    control.Failed:Connect(function(reason) seen.failed[#seen.failed + 1] = reason end)
    control.Turned:Connect(function(yaw, pitch, distance) seen.turned[#seen.turned + 1] = { yaw, pitch, distance } end)
    control.Clicked:Connect(function() seen.clicked = seen.clicked + 1 end)
end
local function actor_now() return world.actors[#world.actors] end
local function near(got, want, what)
    if math.abs(got - want) > 1e-6 then error((what or "value") .. ": expected " .. tostring(want) .. ", got " .. tostring(got), 2) end
end
local function last_turn(actor)
    local list = calls(actor, "K2_SetActorRotation")
    return list[#list][1]
end

t.test("a game path gets its last part again, and anything else is refused", function()
    t.eq(model.check("/Game/ASS/CRE/Deer/SK_CRE_PAS_Deer"), "/Game/ASS/CRE/Deer/SK_CRE_PAS_Deer.SK_CRE_PAS_Deer")
    t.eq(model.check("/Game/A/SK-Deer_AnimBP", true), "/Game/A/SK-Deer_AnimBP.SK-Deer_AnimBP_C")
    t.eq(model.check("/Game/A/B.B"), "/Game/A/B.B")
    t.eq(model.check("Deer"), nil)
    t.eq(model.check("/Game/A/B C.B"), nil)
    t.eq(model.check("/Game/../secret.x"), nil)
    t.eq(model.check(12), nil)
    t.eq(model.check("/" .. ("a"):rep(300)), nil)
end)

t.test("wrong options are refused in plain words, with the nearest right name", function()
    scope.run(owner, function()
        window = ui.Window({ title = "Model test", width = 420, height = 400, x = 100, y = 90 })
    end)
    t.raises(function() window:Model({ meshh = "/Game/Deer/SK_Deer" }) end, "Model has no option 'meshh'. Did you mean 'mesh'?")
    t.raises(function() window:Model({ mesh = "Deer" }) end, "mesh is a game path such as")
    t.raises(function() window:Model({ mesh = "/Game/Deer/SK_Deer", width = "wide" }) end, "width is a number")
    t.raises(function() window:Model({ mesh = "/Game/Deer/SK_Deer", animation = "wlak" }) end, "Did you mean 'walk'?")
    t.raises(function() window:Model({ mesh = "/Game/Deer/SK_Deer", materials = { a = "/Game/Deer/M_Deer" } }) end, "numbered from 1")
    t.raises(function() window:Model({ mesh = "/Game/Deer/SK_Deer", fur = { mesh = "/Game/Deer/SK_Deer_Fur", layers = "many" } }) end,
        "fur[1].layers is a number")
    t.raises(function() window:Model("/Game/Deer/SK_Deer") end, "Model expects a table of options")
    t.eq(#world.actors, 0, "nothing was made for a call that was refused")
    t.eq(#world.loads, 0)
end)

t.test("while its window does not show, a view loads nothing and makes nothing", function()
    scope.run(owner, function()
        view = window:Model(deer({ width = 212, height = 150, backdrop = true }))
        watch(view)
    end)
    frames(5)
    t.eq(#world.loads, 0)
    t.eq(#world.actors, 0)
    t.eq(view:IsLoaded(), false)
end)

t.test("once it shows, what it needs is loaded a few milliseconds a frame and the mesh is checked for what it is", function()
    world.load_seconds = 0.002
    ui.SetPreview(true)
    frames(1)
    t.eq(#world.loads, 2, "two loads of 2 ms fill a frame's 3 ms")
    t.eq(world.loads[1], model.PREVIEW)
    t.eq(world.loads[2], DEER)
    t.eq(#world.actors, 0, "nothing is built before everything is in memory")
    frames(1)
    t.eq(#world.loads, 4)
    world.load_seconds = 0
    frames(2)
    t.eq(#world.actors, 1)
end)

t.test("one actor far under the world carries the arm, the mesh, the capture, three lights and the fur", function()
    local actor = actor_now()
    t.eq(rawget(rawget(actor, "__spawn_class"), "__name"), "/Script/Engine.Actor")
    t.eq(rawget(actor, "__location").Z, -1000000)
    t.eq(rawget(value_of(actor, "Tags"), 1), model.TAG)
    local parts = rawget(actor, "__parts")
    t.eq(rawget(parts[1], "__thing"), "scene", "the arm is the root: the first part, and the one the others hang on")
    t.eq(rawget(parts[1], "__manual"), false)
    local mesh = parts_of(actor, "mesh")[1]
    t.eq(rawget(mesh, "__manual"), true, "the mesh is attached to nothing, so the arm turns round it")
    t.eq(calls(mesh, "SetVisibleInSceneCaptureOnly")[1][1], true)
    t.eq(calls(mesh, "SetCollisionEnabled")[1][1], 0)
    local channels = calls(mesh, "SetLightingChannels")[1]
    t.ok(channels[1] == false and channels[2] == false and channels[3] == true, "the mesh is lit on channel 2 only")
    t.eq(rawget(calls(mesh, "SetSkeletalMesh")[1][1], "__name"), DEER)
    t.eq(rawget(calls(mesh, "SetMaterial")[1][2], "__name"), "/Game/Deer/M_Deer.M_Deer")
    t.eq(calls(mesh, "SetMaterial")[1][1], 0, "slot 1 of the data is the engine's slot 0")
    -- every model is made one size: the ball round its bounds is model.RADIUS
    near(calls(mesh, "SetRelativeScale3D")[1][1].X, model.RADIUS / 130)
    local at = rawget(mesh, "__at").Translation
    near(at.Y - rawget(actor, "__location").Y, -30 * model.RADIUS / 130, "the middle of the bounds sits on the arm")
    t.eq(#parts_of(actor, "light"), 3)
    for _, light in ipairs(parts_of(actor, "light")) do
        local lit = value_of(light, "LightingChannels")
        t.ok(lit.bChannel0 == false and lit.bChannel2 == true, "a light reaches channel 2 only, so nothing of the world is lit")
        t.eq(value_of(light, "CastShadows"), false)
        t.eq(rawget(light, "__registered"), true)
    end
    local fur = parts_of(actor, "fur")[1]
    t.eq(rawget(value_of(fur, "SkeletalGrowMesh"), "__name"), "/Game/Deer/SK_Deer_Fur.SK_Deer_Fur")
    t.eq(rawget(value_of(fur, "FurSplines"), "__name"), "/Game/Deer/Deer_Splines.Deer_Splines")
    t.eq(value_of(fur, "LayerCount"), 16)
    t.eq(value_of(fur, "FurLength"), 1.5)
    t.eq(value_of(fur, "PhysicsEnabled"), false)
    t.eq(value_of(fur, "bVisibleInSceneCaptureOnly"), true)
    t.eq(calls(fur, "K2_AttachToComponent")[1][1], mesh)
    t.eq(rawget(calls(fur, "SetMaterial")[1][2], "__name"), "/Game/Deer/M_Deer_Fur.M_Deer_Fur")
    -- fur made before it had a body stands still while the body walks (seen in the game as two deer in one place)
    t.eq(#calls(fur, "RegenerateFur"), 1, "the fur is made again once it is on the body")
    local order = {}
    for position, name in ipairs(rawget(fur, "__log")) do order[name] = order[name] or position end
    t.ok(order.K2_AttachToComponent < order.RegenerateFur, "after it is attached")
    t.ok(order.SetMaterial < order.RegenerateFur, "and dressed")
    local capture = parts_of(actor, "capture")[1]
    t.eq(#calls(capture, "ShowOnlyComponent"), 2, "the capture draws the mesh and its fur and nothing else")
end)

t.test("the capture's show flags are written before it registers, and it draws into a picture that belongs to the game", function()
    local actor = actor_now()
    local capture = parts_of(actor, "capture")[1]
    local flags = value_of(capture, "ShowFlagSettings")
    t.ok(#flags >= 10)
    local names = {}
    for index = 1, rawlen(flags) do
        local flag = rawget(flags, index)
        names[flag.ShowFlagName] = true
        t.eq(flag.Enabled, false)
    end
    t.ok(names.Fog and names.SkyLighting and names.Landscape)
    local log_at = rawget(capture, "__at_register")
    local written = 0
    for index = 1, log_at do
        if rawget(capture, "__log")[index] == "TextureTarget=" then written = index end
    end
    t.ok(written > 0, "the target was set before the part registered")
    t.eq(value_of(capture, "CaptureSource"), 0)
    t.eq(value_of(capture, "PrimitiveRenderMode"), 2)
    t.eq(value_of(capture, "bCaptureOnMovement"), false)
    local target = value_of(capture, "TextureTarget")
    t.eq(#world.targets, 1)
    t.eq(target, world.targets[1])
    t.ok(rawequal(rawget(target, "__outer"), game_instance), "a picture inside the world would stop the game at the next map change")
    t.ok(rawequal(rawget(world.materials[1], "__outer"), game_instance), "the material is not made with an actor either")
    t.eq(rawget(rawget(world.materials[1], "__parent"), "__name"), model.PREVIEW)
    t.eq(calls(world.materials[1], "SetTextureParameterValue")[1][1], "SceneCapture")
    t.eq(calls(world.materials[1], "SetTextureParameterValue")[1][2], target)
    -- 212 by 150 units at one pixel a unit, drawn with twice the pixels each way so edges and fur are smooth
    t.eq(model.SHARP, 2)
    t.eq(rawget(target, "__width"), 424)
    t.eq(rawget(target, "__height"), 300)
    t.eq(rawget(target, "__format"), 6)
    near(value_of(capture, "FOVAngle"), math.deg(2 * math.atan(math.tan(math.rad(15)) * 212 / 150)))
end)

t.test("Loaded fires once, when the model is in the picture, and the walk plays", function()
    frames(3)
    t.eq(seen.loaded, 1)
    t.eq(view:IsLoaded(), true)
    local mesh = parts_of(actor_now(), "mesh")[1]
    t.eq(rawget(calls(mesh, "PlayAnimation")[1][1], "__name"), "/Game/Deer/Walk.Walk")
    t.eq(calls(mesh, "PlayAnimation")[1][2], true, "it loops")
    t.eq(value_of(mesh, "bPauseAnims"), false)
    t.eq(value_of(parts_of(actor_now(), "capture")[1], "bCaptureEveryFrame"), true, "a walking model gets a new picture every frame")
end)

t.test("it starts three quarters from the front, a little above, and turns slowly by itself", function()
    local yaw, pitch, distance = view:GetView()
    t.ok(yaw > model.YAW and yaw < model.YAW + 10, "it has turned a little since it showed")
    t.eq(pitch, model.PITCH)
    t.eq(distance, 1)
    local before = view:GetView()
    frames(60)
    near(view:GetView() - before, model.SPIN, "a second of turning")
    -- a mesh that faces -90 looks at the camera when the arm's yaw is 270: yaw 0 is in front
    local turned = last_turn(actor_now())
    near(turned.Yaw, (270 + view:GetView()) % 360)
    near(turned.Pitch, -model.PITCH, "the engine's pitch is negative above")
end)

t.test("the model follows the mouse: right turns its near side right, down shows it more from above, and it never flips", function()
    local button = view.source
    fake.mouse = { X = 500, Y = 300 }
    events.simulate(button, "OnPressed")
    fake.pressed = true
    frames(1)
    local start = view:GetView()
    fake.mouse = { X = 560, Y = 300 }
    frames(1)
    local yaw, pitch = view:GetView()
    near(yaw - start, 60 * model.TURN, "sixty units to the right")
    t.eq(pitch, model.PITCH)
    near(last_turn(actor_now()).Yaw, (270 + yaw) % 360, "the arm's yaw goes up, so the camera goes left and the near side right")
    fake.mouse = { X = 560, Y = 350 }
    frames(1)
    yaw, pitch = view:GetView()
    near(pitch, model.PITCH + 50 * model.TILT, "fifty units down: seen from higher up")
    near(last_turn(actor_now()).Pitch, -pitch)
    fake.mouse = { X = 560, Y = 3000 }
    frames(1)
    t.eq(select(2, view:GetView()), model.ABOVE, "never past straight above")
    fake.mouse = { X = 560, Y = -3000 }
    frames(1)
    t.eq(select(2, view:GetView()), -model.BELOW, "nor far under it")
    local turns = #calls(actor_now(), "K2_SetActorRotation")
    frames(5)
    t.eq(#calls(actor_now(), "K2_SetActorRotation"), turns, "held still at the limit, the engine is not called again")
    t.eq(#seen.turned, 0, "nothing is told while it is held")
    fake.pressed = false
    frames(1)
    t.eq(#seen.turned, 1, "Turned fires once, when the player lets go")
    near(seen.turned[1][1], yaw)
    t.eq(seen.turned[1][2], -model.BELOW)
    t.eq(seen.clicked, 0, "a drag is not a click")
    local still = view:GetView()
    frames(30)
    t.eq(view:GetView(), still, "once touched it no longer turns by itself")
end)

t.test("a press that does not move is a click, and two in a row put the view back", function()
    clock = clock + 1
    fake.mouse = { X = 500, Y = 300 }
    events.simulate(view.source, "OnPressed")
    fake.pressed = true
    frames(2)
    fake.pressed = false
    frames(1)
    t.eq(seen.clicked, 1)
    t.eq(#seen.turned, 1)
    events.simulate(view.source, "OnPressed")
    local yaw, pitch, distance = view:GetView()
    t.eq(yaw, model.YAW)
    t.eq(pitch, model.PITCH)
    t.eq(distance, 1)
    t.eq(#seen.turned, 2, "going back is told too")
    frames(30)
    t.ok(view:GetView() > model.YAW, "and the slow turn starts again")
    t.eq(seen.clicked, 1)
end)

t.test("the wheel moves the camera while the view has it, between two limits, and the box is put back", function()
    local actor = actor_now()
    local capture = parts_of(actor, "capture")[1]
    fake.scroll_offset = model.ROOM
    frames(2)
    local moves = #calls(capture, "K2_SetRelativeLocation")
    fake.scroll_offset = model.ROOM + 40
    frames(1)
    local _, _, distance = view:GetView()
    near(distance, model.STEP, "towards the player is further away")
    t.eq(#calls(capture, "K2_SetRelativeLocation"), moves + 1)
    local moved = calls(capture, "K2_SetRelativeLocation")[moves + 1]
    t.ok(moved[1].X < 0 and moved[1].Y == 0, "the camera slides along its arm")
    t.eq(type(moved[3]), "table", "the hit result is an empty table")
    fake.scroll_offset = model.ROOM
    frames(1)
    for _ = 1, 12 do
        fake.scroll_offset = model.ROOM + 40
        frames(1)
        fake.scroll_offset = model.ROOM
        frames(1)
    end
    t.eq(select(3, view:GetView()), model.FAR)
    for _ = 1, 30 do
        fake.scroll_offset = model.ROOM - 40
        frames(1)
        fake.scroll_offset = model.ROOM
        frames(1)
    end
    t.eq(select(3, view:GetView()), model.NEAR, "it never goes inside the model")
    local still = view:GetView()
    frames(20)
    t.eq(view:GetView(), still, "the wheel stops the slow turn too")
end)

t.test("SetView is kept inside the limits, Reset goes back, and wrong values are refused", function()
    view:SetView(400, 500, 99)
    local yaw, pitch, distance = view:GetView()
    t.eq(yaw, 40)
    t.eq(pitch, model.ABOVE)
    t.eq(distance, model.FAR)
    view:SetView(nil, -500)
    t.eq(select(2, view:GetView()), -model.BELOW)
    t.eq((view:GetView()), 40, "what is left out stays")
    t.raises(function() view:SetView("left") end, "yaw is a number")
    view:Reset()
    yaw, pitch, distance = view:GetView()
    t.ok(yaw == model.YAW and pitch == model.PITCH and distance == 1)
end)

t.test("idle, standing still, a sequence by its path and the mesh's own blueprint", function()
    local mesh = parts_of(actor_now(), "mesh")[1]
    view:SetAnimation("idle")
    frames(2)
    local played = calls(mesh, "PlayAnimation")
    t.eq(rawget(played[#played][1], "__name"), "/Game/Deer/Idle.Idle")
    view:SetAnimation(false)
    frames(2)
    t.eq(value_of(mesh, "bPauseAnims"), true)
    local ticks = calls(mesh, "SetComponentTickEnabled")
    t.eq(ticks[#ticks][1], false)
    local capture = parts_of(actor_now(), "capture")[1]
    view:SetView(10, 10, 1)
    frames(6)
    t.eq(value_of(capture, "bCaptureEveryFrame"), false, "a model that stands still under a still camera gets no new picture")
    view:SetView(20)
    frames(1)
    t.eq(value_of(capture, "bCaptureEveryFrame"), true, "a new picture when the view changes")
    frames(6)
    t.eq(value_of(capture, "bCaptureEveryFrame"), false)
    view:SetAnimation("/Game/Deer/Walk")
    frames(2)
    played = calls(mesh, "PlayAnimation")
    t.eq(rawget(played[#played][1], "__name"), "/Game/Deer/Walk.Walk")
    t.eq(value_of(mesh, "bPauseAnims"), false)
    t.raises(function() view:SetAnimation("wlak") end, "Did you mean 'walk'?")
    t.raises(function() view:SetAnimation() end, "SetAnimation expects")
end)

t.test("the blueprint is only told a speed when it has the member for it", function()
    view:Show(deer({ blueprint = "/Game/Deer/Deer_AnimBP", animation = "blueprint", speed = 150 }))
    frames(8)
    local mesh = parts_of(actor_now(), "mesh")[1]
    t.eq(calls(mesh, "SetAnimationMode")[1][1], 0)
    t.eq(rawget(calls(mesh, "SetAnimClass")[1][1], "__name"), "/Game/Deer/Deer_AnimBP.Deer_AnimBP_C")
    t.eq(value_of(rawget(mesh, "__instance"), "PawnVelocity"), 150)
    t.eq(#calls(mesh, "PlayAnimation"), 0)
    view:Show(deer({ blueprint = "/Game/Plain/Plain_AnimBP", animation = "blueprint" }))
    frames(8)
    mesh = parts_of(actor_now(), "mesh")[1]
    t.eq(#calls(mesh, "SetAnimClass"), 1)
    t.eq(value_of(rawget(mesh, "__instance"), "PawnVelocity"), nil, "a blueprint without the member is left alone")
    t.eq(seen.loaded, 3, "Loaded fires for each model that is shown")
end)

t.test("Show takes the old actor out of the world and puts the view back to its start", function()
    local old = actor_now()
    view:SetView(100, 30, 1.3)
    -- the same body with something else on it is seen from where the player left it
    view:Show(deer({ materials = {} }))
    t.eq(rawget(old, "__destroyed"), true, "at that moment")
    t.eq(view:IsLoaded(), false)
    local yaw, pitch, distance = view:GetView()
    t.eq(yaw, 100)
    t.eq(pitch, 30)
    near(distance, 1.3)
    frames(8)
    t.eq(seen.loaded, 4, "and Loaded says when it is in the picture")
    -- another body starts where every model starts
    view:Show({ mesh = "/Game/Golem/SK_Rig", animation = false })
    t.eq((view:GetView()), model.YAW)
    frames(8)
    old = actor_now()
    view:SetView(100, 30, 1.3)
    view:Show(deer())
    t.eq(rawget(old, "__destroyed"), true)
    t.eq((view:GetView()), model.YAW)
    frames(8)
    t.eq(#world.actors, 1)
    t.ok(actor_now() ~= old)
    t.eq(view:IsLoaded(), true)
    t.eq(#world.targets, 1, "the picture is kept from one model to the next")
    t.eq(parts_of(actor_now(), "capture")[1] and value_of(parts_of(actor_now(), "capture")[1], "TextureTarget"), world.targets[1])
    t.raises(function() view:Show("deer") end, "Show expects a table")
    t.raises(function() view:Show({ mesh = "/Game/Deer/SK_Deer", width = 5 }) end, "Show has no option 'width'")
end)

t.test("a model made of pieces is framed as a whole, and its pieces take the body's pose", function()
    view:Show({ mesh = "/Game/Golem/SK_Rig", parts = { { mesh = "/Game/Golem/SK_Leg" } }, animation = false })
    frames(8)
    local meshes = parts_of(actor_now(), "mesh")
    t.eq(#meshes, 2)
    t.eq(calls(meshes[2], "SetMasterPoseComponent")[1][1], meshes[1])
    -- the ball round a ball of 20 and one of 80 whose middles are 100 apart reaches 100 from its own middle
    near(calls(meshes[1], "SetRelativeScale3D")[1][1].X, model.RADIUS / 100)
    near(calls(meshes[2], "SetRelativeScale3D")[1][1].X, model.RADIUS / 100)
    t.eq(#calls(parts_of(actor_now(), "capture")[1], "ShowOnlyComponent"), 2)
end)

-- a saddle as the list of models gives it: a mesh on a skeleton of its own, with the blueprint that copies the mount's pose
local SADDLE = { mesh = "/Game/Saddle/SK_Saddle", blueprint = "/Game/Saddle/Saddle_AnimBP", materials = { [1] = "/Game/Saddle/M_Arctic" } }
asset("/Game/Saddle/SK_Saddle.SK_Saddle", "mesh", { Origin = { X = 0, Y = 30, Z = 120 }, BoxExtent = { X = 20, Y = 30, Z = 20 }, SphereRadius = 40 })
asset("/Game/Saddle/SK_Cart.SK_Cart", "mesh", { Origin = { X = 0, Y = -300, Z = 60 }, BoxExtent = { X = 80, Y = 150, Z = 60 }, SphereRadius = 180 })
asset("/Game/Saddle/Saddle_AnimBP.Saddle_AnimBP_C", "blueprint")
asset("/Game/Saddle/Parent_AnimBP.Parent_AnimBP_C", "blueprint")
asset("/Game/Saddle/M_Arctic.M_Arctic", "material")
asset("/Game/Saddle/T_Mask.T_Mask", "texture")

t.test("a saddle is put on as the game puts it on: attached to the body, posed by its own blueprint, which is given the body", function()
    view:Show(deer({ parts = { SADDLE } }))
    frames(8)
    t.eq(view:IsLoaded(), true)
    local meshes = parts_of(actor_now(), "mesh")
    t.eq(#meshes, 2)
    local body, saddle = meshes[1], meshes[2]
    t.eq(rawget(calls(saddle, "SetSkeletalMesh")[1][1], "__name"), "/Game/Saddle/SK_Saddle.SK_Saddle")
    local attach = calls(saddle, "K2_AttachToComponent")[1]
    t.eq(attach[1], body)
    t.eq(attach[2], FName("None"), "RigRoot in the table is the body itself")
    t.ok(attach[3] == 2 and attach[4] == 2 and attach[5] == 2 and attach[6] == true, "snapped to it, as the game's own preview does")
    t.eq(calls(saddle, "SetAnimationMode")[1][1], 0)
    t.eq(rawget(calls(saddle, "SetAnimClass")[1][1], "__name"), "/Game/Saddle/Saddle_AnimBP.Saddle_AnimBP_C")
    t.eq(value_of(rawget(saddle, "__instance"), "SourceMeshComponent"), body, "the blueprint copies the body's pose")
    t.eq(#calls(saddle, "SetMasterPoseComponent"), 0)
    t.eq(value_of(saddle, "VisibilityBasedAnimTickOption"), 0, "it is posed although nothing but the capture sees it")
    t.eq(rawget(calls(saddle, "SetMaterial")[1][2], "__name"), "/Game/Saddle/M_Arctic.M_Arctic")
    t.eq(calls(saddle, "SetVisibleInSceneCaptureOnly")[1][1], true)
    local order = {}
    for position, name in ipairs(rawget(saddle, "__log")) do order[name] = order[name] or position end
    t.ok(order.SetSkeletalMesh < order.K2_AttachToComponent and order.K2_AttachToComponent < order.SetAnimClass, "mesh, body, then the blueprint")
    t.eq(#calls(parts_of(actor_now(), "capture")[1], "ShowOnlyComponent"), 3, "the body, the saddle and the fur")
    -- a saddle inside the body's ball does not change how large the body is drawn
    near(calls(body, "SetRelativeScale3D")[1][1].X, model.RADIUS / 130)
    t.eq(#seen.failed, 0)
end)

t.test("a saddle on a socket rides that socket, and one whose blueprint finds the body itself is left to it", function()
    view:Show(deer({ parts = { { mesh = "/Game/Saddle/SK_Cart", socket = "RaptorSaddle", blueprint = "/Game/Saddle/Parent_AnimBP" } } }))
    frames(8)
    local meshes = parts_of(actor_now(), "mesh")
    local attach = calls(meshes[2], "K2_AttachToComponent")[1]
    t.eq(attach[1], meshes[1])
    t.eq(attach[2], FName("RaptorSaddle"))
    t.eq(value_of(rawget(meshes[2], "__instance"), "SourceMeshComponent"), nil, "a blueprint without the member is not written to")
    t.eq(#calls(meshes[2], "SetMasterPoseComponent"), 0)
    near(calls(meshes[1], "SetRelativeScale3D")[1][1].X, model.RADIUS / 130, "what sits on a socket is measured from there: it is not framed")
    -- a socket and no blueprint: it only rides
    view:Show(deer({ parts = { { mesh = "/Game/Saddle/SK_Saddle", socket = "ChewSaddle" } } }))
    frames(8)
    meshes = parts_of(actor_now(), "mesh")
    t.eq(calls(meshes[2], "K2_AttachToComponent")[1][2], FName("ChewSaddle"))
    t.eq(#calls(meshes[2], "SetAnimClass"), 0)
    t.eq(#calls(meshes[2], "SetMasterPoseComponent"), 0)
    -- a cart behind the body is part of the picture: the model is framed with it
    view:Show(deer({ parts = { { mesh = "/Game/Saddle/SK_Cart", blueprint = "/Game/Saddle/Saddle_AnimBP" } } }))
    frames(8)
    t.ok(calls(parts_of(actor_now(), "mesh")[1], "SetRelativeScale3D")[1][1].X < model.RADIUS / 130 - 0.05)
    t.raises(function() view:Show(deer({ parts = { { mesh = "/Game/Saddle/SK_Saddle", socket = "on its back" } } })) end, "parts[1].socket is the name of a socket")
    t.raises(function() view:Show(deer({ parts = { { mesh = "/Game/Saddle/SK_Saddle", blueprint = 5 } } })) end, "parts[1].blueprint is a game path")
end)

t.test("a saddle whose blueprint is gone takes the body's pose bone by bone, and the model still shows", function()
    view:Show(deer({ parts = { { mesh = "/Game/Saddle/SK_Saddle", blueprint = "/Game/Saddle/Gone_AnimBP" } } }))
    frames(8)
    t.eq(view:IsLoaded(), true)
    local meshes = parts_of(actor_now(), "mesh")
    t.eq(#calls(meshes[2], "K2_AttachToComponent"), 0)
    t.eq(#calls(meshes[2], "SetAnimClass"), 0)
    t.eq(calls(meshes[2], "SetMasterPoseComponent")[1][1], meshes[1])
    t.eq(#seen.failed, 0)
end)

t.test("the fur under a saddle gets the game's mask on a copy of its first material, before it is made again", function()
    local furred = deer({ parts = { SADDLE } })
    furred.fur[1].mask = "/Game/Saddle/T_Mask"
    local before = #world.materials
    view:Show(furred)
    frames(8)
    local fur = parts_of(actor_now(), "fur")[1]
    t.eq(#world.materials, before + 1)
    local copy = world.materials[#world.materials]
    t.eq(rawget(rawget(copy, "__parent"), "__name"), "/Game/Deer/M_Deer_Fur.M_Deer_Fur")
    t.eq(rawget(copy, "__outer"), game_instance)
    local set = calls(copy, "SetTextureParameterValue")[1]
    t.eq(set[1], FName("FurCullingMask"))
    t.eq(rawget(set[2], "__name"), "/Game/Saddle/T_Mask.T_Mask")
    local dressed = calls(fur, "SetMaterial")
    t.eq(dressed[#dressed][2], copy)
    t.eq(dressed[#dressed][1], 0)
    local last = {}
    for position, name in ipairs(rawget(fur, "__log")) do last[name] = position end
    t.ok(last.SetMaterial < last.RegenerateFur, "the fur is made again with the mask on")
    -- a fur whose first material the list does not name is left as it is, and so is one whose mask is gone
    local plain = deer({ parts = { SADDLE } })
    plain.fur[1].materials, plain.fur[1].mask = nil, "/Game/Saddle/T_Mask"
    view:Show(plain)
    frames(8)
    t.eq(#world.materials, before + 1)
    t.eq(#parts_of(actor_now(), "fur"), 1)
    local lost = deer({ parts = { SADDLE } })
    lost.fur[1].mask = "/Game/Saddle/T_Gone"
    view:Show(lost)
    frames(8)
    t.eq(#world.materials, before + 1)
    t.eq(#parts_of(actor_now(), "fur"), 1)
    t.eq(view:IsLoaded(), true)
    t.raises(function() view:Show(deer({ fur = { mesh = "/Game/Deer/SK_Deer_Fur", mask = true } })) end, "fur[1].mask is a game path")
end)

t.test("a saddle stops being posed while the view does not show, and is posed again when it does", function()
    view:Show(deer({ parts = { SADDLE } }))
    frames(8)
    local saddle = parts_of(actor_now(), "mesh")[2]
    window:Hide()
    frames(3)
    local ticks = calls(saddle, "SetComponentTickEnabled")
    t.eq(ticks[#ticks][1], false)
    window:Show()
    frames(3)
    ticks = calls(saddle, "SetComponentTickEnabled")
    t.eq(ticks[#ticks][1], true)
end)

t.test("a path that names nothing ends as Failed, and is not asked for a second time", function()
    view:Show({ mesh = "/Game/Deer/SK_Nothing" })
    frames(4)
    t.eq(#seen.failed, 1)
    t.ok(seen.failed[1]:find("/Game/Deer/SK_Nothing.SK_Nothing could not be loaded", 1, true), seen.failed[1])
    t.eq(view:IsLoaded(), false)
    t.eq(#world.actors, 0)
    t.eq(loads_of("/Game/Deer/SK_Nothing.SK_Nothing"), 1)
    view:Show({ mesh = "/Game/Deer/SK_Nothing" })
    frames(4)
    t.eq(#seen.failed, 2)
    t.eq(loads_of("/Game/Deer/SK_Nothing.SK_Nothing"), 1, "a miss is slow in the game")
end)

t.test("a texture given as a mesh ends as Failed and never reaches the engine as a mesh", function()
    view:Show({ mesh = "/Game/UI/T_Icon" })
    frames(4)
    t.eq(#seen.failed, 3)
    t.ok(seen.failed[3]:find("is not a skeletal mesh", 1, true), seen.failed[3])
    t.eq(#world.actors, 0)
end)

t.test("a fur or a material that is gone leaves the model showing without it", function()
    view:Show(deer({ materials = { [1] = "/Game/Deer/M_Gone" }, fur = { mesh = "/Game/Deer/SK_Fur_Gone", layers = 8 } }))
    frames(8)
    t.eq(view:IsLoaded(), true)
    t.eq(#parts_of(actor_now(), "fur"), 0)
    t.eq(#calls(parts_of(actor_now(), "mesh")[1], "SetMaterial"), 0)
    t.eq(#seen.failed, 3)
end)

t.test("Clear empties the box and takes the actor out", function()
    local actor = actor_now()
    view:Clear()
    t.eq(rawget(actor, "__destroyed"), true)
    t.eq(view:IsLoaded(), false)
    frames(5)
    t.eq(#world.actors, 0)
    view:Show(deer())
    frames(8)
    t.eq(view:IsLoaded(), true)
end)

t.test("while it does not show nothing is drawn and the engine is not called, and after a while the actor is given up", function()
    local actor = actor_now()
    local capture, mesh, fur = parts_of(actor, "capture")[1], parts_of(actor, "mesh")[1], parts_of(actor, "fur")[1]
    window:Hide()
    frames(model.NAP + 1)
    t.eq(value_of(capture, "bCaptureEveryFrame"), false)
    t.eq(value_of(mesh, "bPauseAnims"), true)
    local ticks = calls(mesh, "SetComponentTickEnabled")
    t.eq(ticks[#ticks][1], false)
    ticks = calls(fur, "SetComponentTickEnabled")
    t.eq(ticks[#ticks][1], false)
    local before, loaded = world.calls, #world.loads
    frames(120)
    t.eq(world.calls, before, "two seconds hidden: not one call into the world")
    t.eq(#world.loads, loaded)
    t.eq(rawget(actor, "__destroyed"), nil)
    clock = clock + model.KEEP_SECONDS
    frames(model.NAP + 1)
    t.eq(rawget(actor, "__destroyed"), true)
    t.eq(#world.actors, 0)
    local told = seen.loaded
    window:Show()
    frames(model.NAP + 8)
    t.eq(#world.actors, 1, "it is made again when the window shows")
    t.eq(seen.loaded, told, "which is not news: the model was loaded before")
    t.eq(view:IsLoaded(), true)
    t.eq(#world.targets, 1)
end)

t.test("a view that does not show is only looked at every few frames, and wakes within that many", function()
    model.NAP = NAP
    window:Hide()
    frames(NAP * 2)
    local capture = parts_of(actor_now(), "capture")[1]
    t.eq(value_of(capture, "bCaptureEveryFrame"), false)
    window:Show()
    local waited = 0
    repeat
        frames(1)
        waited = waited + 1
    until value_of(capture, "bCaptureEveryFrame") == true or waited > NAP * 3
    t.ok(waited <= NAP, "it took " .. waited .. " frames")
    model.NAP = 1
end)

t.test("an actor somebody else destroys is forgotten at that moment and made again", function()
    local actor = actor_now()
    actor:K2_DestroyActor()
    t.eq(model.stats().actors, 0, "the end of its play told the module")
    world.dead_touches = 0
    frames(8)
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(#world.actors, 1)
    t.ok(actor_now() ~= actor)
end)

t.test("a map change frees the world's things: none is touched, the picture stays, and a new actor is made in the new world", function()
    local old = actor_now()
    local told, materials = seen.loaded, #world.materials
    world.dead_touches, world.dead_where = 0, nil
    world.change_map()
    t.eq(model.stats().actors, 0)
    frames(10)
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(#calls(old, "K2_DestroyActor"), 0, "the engine ended it: it is not destroyed a second time")
    t.eq(#world.actors, 1)
    t.eq(rawget(actor_now(), "__world"), world.generation)
    t.eq(#world.targets, 1, "the picture belongs to the game, so it is the same one")
    t.eq(#world.materials, materials)
    t.eq(value_of(parts_of(actor_now(), "capture")[1], "TextureTarget"), world.targets[1])
    t.eq(seen.loaded, told)
    t.eq(view:IsLoaded(), true)
end)

t.test("a map change while the view is hidden touches nothing either", function()
    window:Hide()
    frames(model.NAP + 1)
    world.dead_touches, world.dead_where = 0, nil
    world.change_map()
    frames(30)
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(#world.actors, 0, "nothing is made while it does not show")
    window:Show()
    frames(model.NAP + 8)
    t.eq(#world.actors, 1)
    t.eq(world.dead_touches, 0, world.dead_where)
end)

t.test("at most so many views draw a new picture in one frame", function()
    local limit = model.RENDERING
    model.RENDERING = 2
    local others = {}
    scope.run(owner, function()
        for index = 1, 3 do others[index] = window:Model(deer({ size = 100, spin = false })) end
    end)
    frames(30)
    t.eq(#world.actors, 4)
    for _ = 1, 6 do
        frames(1)
        local drawing = 0
        for _, actor in ipairs(world.actors) do
            if value_of(parts_of(actor, "capture")[1], "bCaptureEveryFrame") then drawing = drawing + 1 end
        end
        t.eq(drawing, model.RENDERING)
    end
    local places = {}
    for _, actor in ipairs(world.actors) do
        local x = rawget(actor, "__location").X
        t.ok(not places[x], "each actor has a place of its own")
        places[x] = true
    end
    for _, other in ipairs(others) do other:Destroy() end
    frames(2)
    t.eq(#world.actors, 1)
    model.RENDERING = limit
end)

t.test("a view in a panel follows the panel, and is drawn with the pixels the panel's size gives it", function()
    local panel, inside
    scope.run(owner, function()
        panel = ui.Panel({ title = "Model test", when = "always", zoom = 1.25, width = 236 })
        inside = panel:Model(deer({ width = 212, height = 150 }))
    end)
    frames(10)
    t.eq(#world.actors, 2)
    t.eq(inside:IsLoaded(), true)
    local target = world.targets[#world.targets]
    t.eq(rawget(target, "__width"), 530)
    t.eq(rawget(target, "__height"), 375)
    panel:SetVisible(false)
    frames(model.NAP + 1)
    t.eq(value_of(parts_of(actor_now(), "capture")[1], "bCaptureEveryFrame"), false)
    panel:Destroy()
    t.eq(#world.actors, 1, "a panel that goes takes the actor with it")
    frames(2)
end)

t.test("destroying the control takes the actor out at that moment, and nothing of it is used again", function()
    local actor = actor_now()
    local before = fake.mark()
    local second
    scope.run(owner, function() second = window:Model(deer()) end)
    frames(10)
    local made = fake.mark()
    local other = actor_now()
    t.ok(other ~= actor)
    second:Destroy()
    t.eq(rawget(other, "__destroyed"), true)
    t.eq(#calls(other, "K2_DestroyActor"), 1)
    fake.free(before, made)
    free(other)
    local touches = fake.dead_touches
    world.dead_touches, world.dead_where = 0, nil
    frames(20)
    t.eq(fake.dead_touches, touches, fake.dead_where)
    t.eq(world.dead_touches, 0, world.dead_where)
    t.raises(function() second:Show(deer()) end, "no longer exists")
    t.raises(function() second:GetView() end, "no longer exists")
    t.eq(model.stats().views, 1)
end)

t.test("a mod that goes takes its windows, and with them every actor and every step", function()
    local actor = actor_now()
    owner:destroy()
    t.eq(rawget(actor, "__destroyed"), true, "the window's end is the actor's end")
    t.eq(#world.actors, 0)
    free(actor)
    world.dead_touches, world.dead_where = 0, nil
    local before_calls = world.calls
    frames(10)
    t.eq(world.dead_touches, 0, world.dead_where)
    t.eq(world.calls, before_calls)
    t.eq(model.stats().views, 0)
    t.eq(model.stats().tracked, 0)
    t.raises(function() view:Reset() end, "no longer exists")
end)

t.test("when the interface is rebuilt the actors are taken out without a widget being touched", function()
    local other = scope.new("model-test-2")
    local before = fake.mark()
    scope.run(other, function()
        window = ui.Window({ title = "Model test", width = 420, height = 400 })
        view = window:Model(deer())
    end)
    frames(10)
    local actor = actor_now()
    t.eq(#world.actors, 1)
    fake.free(before, fake.mark())
    local touches = fake.dead_touches
    model.forget_all()
    t.eq(rawget(actor, "__destroyed"), true)
    t.eq(fake.dead_touches, touches, fake.dead_where)
    t.eq(model.stats().views, 0)
    world.dead_touches = 0
    model.step()
    t.eq(world.dead_touches, 0, world.dead_where)
end)

t.test("actors an earlier load of the module left behind are destroyed, and a destroyed one is left alone", function()
    local function stray()
        local actor = fake.react.SpawnActor(nil, fake.new_object("/Script/Engine.Actor"), { X = 0, Y = 0, Z = 0 }, {})
        actor.Tags[1] = model.TAG
        return actor
    end
    local left, dying = stray(), stray()
    rawset(dying, "__destroyed", true)
    local untagged = fake.react.SpawnActor(nil, fake.new_object("/Script/Engine.Actor"), { X = 0, Y = 0, Z = 0 }, {})
    world.dead_touches = 0
    t.eq(model.sweep(), 1)
    t.eq(rawget(left, "__destroyed"), true)
    t.eq(#calls(dying, "K2_DestroyActor"), 0)
    t.eq(rawget(untagged, "__destroyed"), nil)
    t.eq(world.dead_touches, 0, world.dead_where)
    world.actors = {}
end)

-- the list of creature models ------------------------------------------------------------------------------------------
local NAMES = { "GetAll", "GetKind" }
local creatures = setmetatable({}, { __names = function() return NAMES end })
-- the game's own table of set-ups: it has one row the list was made before
fake.react.FindRow = function(_, name) return name == "Brand_New_Beast" and {} or nil end
Wax.modules["world.creatures"] = { api = creatures }
local models = Wax.import("world.creature_models")
models.start()

t.test("GetModel hangs on game.Creatures and gives what a view takes as it is", function()
    t.eq(NAMES[#NAMES - 1], "GetModel")
    t.eq(NAMES[#NAMES], "GetSaddles")
    models.start()
    t.eq(#NAMES, 4, "a second start adds no name twice")
    local look = creatures:GetModel("Bear")
    t.ok(look.mesh:find("^/Game/"), look.mesh)
    t.eq(type(look.walks), "boolean")
    t.eq(type(look.facing), "number")
    local other = scope.new("model-test-3")
    scope.run(other, function()
        window = ui.Window({ title = "Model test", width = 420, height = 400 })
        t.ok(window:Model(look))
    end)
    other:destroy()
end)

t.test("a creature is found by its set-up row or its kind, however the name is spelt", function()
    local bear = creatures:GetModel("bear")
    t.eq(bear.mesh, creatures:GetModel("BEAR").mesh)
    local wolf = creatures:GetModel("Conifer_Wolf")
    t.eq(creatures:GetModel("conifer wolf").mesh, wolf.mesh)
    t.eq(creatures:GetModel("Wolf").mesh, wolf.mesh, "a kind gives its first set-up")
    bear.mesh, bear.fur = "changed", nil
    t.ok(creatures:GetModel("Bear").mesh ~= "changed", "each answer is a copy")
    t.ok(creatures:GetModel("Bear").fur ~= nil)
end)

t.test("a name that is no creature raises with the nearest right one", function()
    local problem = t.raises(function() creatures:GetModel("Beer") end, "'Beer' is not a creature set-up.")
    t.ok(tostring(problem):find("Did you mean", 1, true) and tostring(problem):find("'Bear'", 1, true), tostring(problem))
    t.ok(tostring(problem):find("model_test.lua", 1, true), "the error names the line that asked: " .. tostring(problem))
    t.raises(function() creatures:GetModel(12) end, "a creature is named by its set-up row")
    t.raises(function() creatures:GetModel("") end, "an empty text")
end)

t.test("a creature the game has and the list does not gives nothing, and says why", function()
    local look, why = creatures:GetModel("Brand_New_Beast")
    t.eq(look, nil)
    t.ok(why:find("newer than Wax's list", 1, true), why)
end)

t.test("every look of the list is one the view accepts, and every path in it is a game path", function()
    local chunk = assert(loadfile("wax/runtime/data/creature_models.lua"))
    local data = chunk()
    t.ok(#data.looks > 100)
    local other = scope.new("model-test-4")
    local shown = 0
    scope.run(other, function()
        window = ui.Window({ title = "Model test", width = 420, height = 400 })
        local every = window:Model()
        for _, look in ipairs(data.looks) do
            every:Show(look)
            shown = shown + 1
        end
    end)
    t.eq(shown, #data.looks)
    for key, at in pairs(data.rows) do
        t.ok(data.looks[at], key .. " names a look that is not there")
        t.ok(data.names[key], key .. " has no name")
    end
    for kind, key in pairs(data.kinds) do t.ok(data.rows[key], kind .. " names a set-up without a model") end
    t.eq(#models.names() > 200, true)
    other:destroy()
    frames(2)
    t.eq(#world.actors, 0)
end)

t.test("GetSaddles lists what a mount can wear, and a creature that wears nothing gives an empty list", function()
    local found = creatures:GetSaddles("Mount_Horse")
    t.ok(#found >= 10, "the Terrenus has " .. #found)
    t.eq(found[1].Row, "Saddle_Horse_Standard")
    t.eq(found[1].Tag, "Item.Mount.Saddle.Standard")
    t.eq(found[1].Items[1], "Saddle_Standard")
    found[1].Items[1] = "changed"
    t.eq(creatures:GetSaddles("mount horse")[1].Items[1], "Saddle_Standard", "each answer is a copy")
    t.eq(#creatures:GetSaddles("Bear"), 0)
    local none, why = creatures:GetSaddles("Brand_New_Beast")
    t.eq(#none, 0)
    t.ok(why:find("newer than Wax's list", 1, true), why)
    t.raises(function() creatures:GetSaddles("Beer") end, "'Beer' is not a creature set-up.")
    t.raises(function() creatures:GetSaddles() end, "a creature is named by its set-up row")
end)

t.test("GetModel puts a saddle on a mount by its item, its tag or its row, and says why when it cannot", function()
    local bare = creatures:GetModel("Mount_Horse")
    t.eq(bare.parts, nil)
    local by_item = creatures:GetModel("Mount_Horse", { saddle = "Saddle_Standard" })
    t.eq(#by_item.parts, 1)
    local part = by_item.parts[1]
    t.ok(part.mesh:find("SK_ITM_Saddle_NormieHorsie", 1, true), part.mesh)
    t.ok(part.blueprint:find("_AnimBP_C$"), part.blueprint)
    t.eq(part.socket, nil, "RigRoot is the body itself")
    t.eq(by_item.mesh, bare.mesh)
    t.eq(creatures:GetModel("Mount_Horse", { saddle = "Item.Mount.Saddle.Standard" }).parts[1].mesh, part.mesh)
    t.eq(creatures:GetModel("mount horse", { saddle = "saddle horse standard" }).parts[1].mesh, part.mesh)
    local other = creatures:GetModel("Mount_Horse", { saddle = "Saddle_Racing" })
    t.ok(other.parts[1].mesh ~= part.mesh, "another saddle is another mesh")
    -- a saddle that is the plain one in other colours
    local arctic = creatures:GetModel("Mount_Horse", { saddle = "Saddle_Basic_Arctic" })
    t.eq(arctic.parts[1].mesh, part.mesh)
    t.ok(arctic.parts[1].materials[1]:find("M_ITM_Saddle_Arctic", 1, true))
    -- one that sits on a socket of its mount, and one the game masks the fur under
    t.eq(creatures:GetModel("Mount_Raptor", { saddle = "Saddle_Standard" }).parts[1].socket, "RaptorSaddle")
    local tusker = creatures:GetModel("Mount_Tusker", { saddle = "Saddle_Standard" })
    t.ok(tusker.fur[1].mask:find("Fur_Cull_Mask", 1, true), tostring(tusker.fur[1].mask))
    t.eq(creatures:GetModel("Mount_Tusker").fur[1].mask, nil)
    t.eq(creatures:GetModel("Mount_Tusker", { saddle = "Saddle_Racing" }).fur[1].mask, nil, "only the saddles the table gives one")
    -- what cannot be put on
    local look, why = creatures:GetModel("Mount_Horse", { saddle = "Saddle_Standrad" })
    t.eq(look, nil)
    t.ok(why:find("no saddle 'Saddle_Standrad' for Mount_Horse", 1, true) and why:find("'Saddle_Standard'", 1, true), why)
    look, why = creatures:GetModel("Bear", { saddle = "Saddle_Standard" })
    t.eq(look, nil)
    t.ok(why:find("Bear wears no saddle", 1, true), why)
    look, why = creatures:GetModel("Mount_Horse", { saddle = "Saddle_Cart" })
    t.eq(look, nil, "a cart is for the buffalo and the tusker")
    t.raises(function() creatures:GetModel("Mount_Horse", { saddle = 3 }) end, "saddle is the name of a saddle's item")
    t.raises(function() creatures:GetModel("Mount_Horse", "Saddle_Standard") end, "GetModel's second argument is a table")
end)

t.test("every saddle of the list is a part the view accepts, on the mount it is for", function()
    local chunk = assert(loadfile("wax/runtime/data/creature_models.lua"))
    local data = chunk()
    t.ok(#data.worn > 50)
    local other = scope.new("model-test-6")
    local shown = 0
    scope.run(other, function()
        window = ui.Window({ title = "Model test", width = 420, height = 400 })
        local every = window:Model()
        for key, found in pairs(data.saddles) do
            t.ok(data.rows[key], key .. " wears a saddle and has no model")
            for _, entry in ipairs(found) do
                t.ok(data.worn[entry.part], entry.row .. " names a part that is not there")
                t.ok(not entry.mask or data.looks[data.rows[key]].fur[entry.fur], entry.row .. " masks a fur its mount does not have")
                every:Show(creatures:GetModel(data.names[key], { saddle = entry.row }))
                shown = shown + 1
            end
        end
    end)
    t.ok(shown > 200, tostring(shown))
    other:destroy()
    frames(2)
    t.eq(#world.actors, 0)
end)

t.test("a model shown against another is as much smaller in its box as it is in the game, and never larger or tiny", function()
    asset("/Game/Deer/SK_Fawn.SK_Fawn", "mesh", { Origin = { X = 0, Y = 15, Z = 50 }, BoxExtent = { X = 15, Y = 45, Z = 45 }, SphereRadius = 65 })
    asset("/Game/Deer/SK_Mouse.SK_Mouse", "mesh", { Origin = { X = 0, Y = 0, Z = 5 }, BoxExtent = { X = 3, Y = 6, Z = 5 }, SphereRadius = 8 })
    local run = scope.new("model-test-5")
    local shown
    scope.run(run, function()
        window = ui.Window({ title = "Model test", width = 420, height = 400 })
        shown = window:Model({ mesh = "/Game/Deer/SK_Fawn", width = 212, height = 150 })
    end)
    ui.Open()
    local function distance()
        frames(10)
        return -rawget(parts_of(actor_now(), "capture")[1], "__at").Translation.X
    end
    local alone = distance()
    -- half the adult's size and the game's scale of both: 65 x 1 against 130 x 1.2
    shown:Show({ mesh = "/Game/Deer/SK_Fawn", against = deer() })
    near(distance(), alone / (65 / (130 * 1.2)), "the camera stands as much further away")
    -- the same mesh drawn smaller by the game: only the scale tells them apart
    shown:Show({ mesh = "/Game/Deer/SK_Deer", scale = 0.6, against = { mesh = "/Game/Deer/SK_Deer", scale = 1.2 } })
    local adult = (function()
        local probe = distance()
        return probe
    end)()
    shown:Show({ mesh = "/Game/Deer/SK_Deer", scale = 1.2 })
    near(adult, distance() / 0.5, "half the scale is half the size")
    -- one that is larger than the other fills its box as it would alone
    shown:Show({ mesh = "/Game/Deer/SK_Deer", against = { mesh = "/Game/Deer/SK_Fawn" } })
    local larger = distance()
    shown:Show({ mesh = "/Game/Deer/SK_Deer" })
    near(larger, distance())
    -- and a very small one keeps four tenths of the box
    shown:Show({ mesh = "/Game/Deer/SK_Mouse" })
    local mouse = distance()
    shown:Show({ mesh = "/Game/Deer/SK_Mouse", against = deer() })
    near(distance(), mouse / model.LEAST)
    -- a mesh of the other that cannot be loaded changes nothing, and a wrong one is said
    shown:Show({ mesh = "/Game/Deer/SK_Fawn", against = { mesh = "/Game/Deer/SK_Nothing" } })
    near(distance(), alone)
    t.eq(shown:IsLoaded(), true)
    local ok, problem = pcall(function() shown:Show({ mesh = "/Game/Deer/SK_Fawn", against = "the deer" }) end)
    t.eq(ok, false)
    t.ok(tostring(problem):find("against is a look with a mesh", 1, true), tostring(problem))
    run:destroy()
    frames(2)
    t.eq(#world.actors, 0)
    t.eq(world.dead_touches, 0, tostring(world.dead_where))
end)

t.finish("model")
