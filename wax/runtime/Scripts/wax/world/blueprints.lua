-- game.Blueprints: things described in Lua and spawned. An actor of an existing class, with parts, assets and functions

local Wax = ...
local instance = Wax.import("engine.instance")
local reflect = Wax.import("engine.reflect")
local actors = Wax.import("engine.actors")
local track = Wax.import("engine.track")
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local suggest = Wax.import("core.suggest")
local perf = Wax.import("core.perf")
local log = Wax.import("core.log").channel("wax.blueprints")

local M = {}

M.DEFERRED = true           -- false: every thing is spawned the plain way, and begins play before its parts are there
M.TOUCH = true              -- touched and collision = "touch" ask the game what overlaps, which no game has been seen to answer yet
M.TOUCH_FRAMES = 6          -- a thing with a touched function is looked at once in this many frames
M.STEP_BUDGET = 0.002       -- seconds a frame for stepped and every functions. What is left waits a frame
M.MAX_THINGS = 2000         -- things in the world at a time
M.MAX_PARTS = 64            -- parts on one thing
M.clock = function() return perf.now() end

local MAX_NAME = 64
local MOVABLE, ALWAYS_SPAWN, NO_COLLISION = 2, 1, 0
local OVERLAP_PROFILE = "OverlapAllDynamic"
local ACTOR_PATH = "/Script/Engine.Actor"
local PACKAGES = { "/Script/Engine.", "/Script/Icarus." }
local ELSEWHERE = {
    proceduralmeshcomponent = "/Script/ProceduralMeshComponent.ProceduralMeshComponent",
    widgetcomponent = "/Script/UMG.WidgetComponent",
    niagaracomponent = "/Script/Niagara.NiagaraComponent",
    cablecomponent = "/Script/CableComponent.CableComponent",
}
local COMMON_BASES = { "Actor", "StaticMeshActor", "Pawn", "Character" }
local COMMON_PARTS = {
    "StaticMeshComponent", "ProceduralMeshComponent", "PointLightComponent", "SpotLightComponent", "RectLightComponent",
    "TextRenderComponent", "SceneComponent", "SphereComponent", "BoxComponent", "CapsuleComponent", "AudioComponent",
    "DecalComponent", "SkeletalMeshComponent", "WidgetComponent", "NiagaraComponent", "CableComponent",
}
-- Component classes of the game's own code that only stand for the classes built on them. Making a part of one can end the game.
local ABSTRACT = {
    ActorComponent = true, FXSystemComponent = true, LightComponent = true, LightComponentBase = true, LocalLightComponent = true,
    MeshComponent = true, MovementComponent = true, NavMovementComponent = true, PawnMovementComponent = true,
    PrimitiveComponent = true, ReflectionCaptureComponent = true, SceneCaptureComponent = true, ShapeComponent = true,
    SkinnedMeshComponent = true, ARComponent = true, GridObjectPlacementComponent = true, QuestModifierBase = true,
    SynthComponent = true, TalentControllerComponent = true, TraitBehaviours = true, TraitComponent = true,
    VoxelResourceDistribution = true,
}
local NAMES = { "Define", "Get", "GetThings" }
local BLUEPRINT_NAMES = { "Name", "Base", "Spawn", "GetThings", "Count", "Remove" }
-- None of these is a member of any actor class of the game: scripts/test_gameindex.py compares them with every one.
local THING_NAMES = { "Blueprint", "Data", "Actor", "Alive", "Position", "Facing", "Part", "AddPart", "GetBounds", "Destroy" }
local OPTIONS = { "base", "parts", "set", "began", "stepped", "every", "touched", "ended" }
local PART_OPTIONS = { "name", "class", "mesh", "material", "at", "rotation", "scale", "collision", "set", "root" }
local MATERIAL_OPTIONS = { "from", "colors", "numbers", "textures" }
local COLLISIONS = { "none", "solid", "touch" }
local FUNCTIONS = { "began", "stepped", "touched", "ended" }
local REASONS = { [actors.DESTROYED] = "Destroyed", [actors.MAP_CHANGE] = "MapChanged", [actors.UNLOADED] = "Unloaded" }
local WHY = {
    Destroyed = "it was destroyed", MapChanged = "the map changed", Unloaded = "its part of the world was unloaded",
    Removed = "its blueprint was removed",
}
local THING, BLUEPRINT = {}, {}     -- where a thing and a blueprint keep their record, out of a mod's reach

local wrap = instance.wrap
local is_instance = instance.is_instance
local easy_loaded, easy = pcall(Wax.import, "engine.easy")
local handles_loaded, handles = pcall(Wax.import, "engine.handle")

local blueprints = {}       -- name in lower case -> blueprint
local all = {}              -- every thing, oldest first. One that is gone is taken out at the end of a step
local stepping, touching = {}, {}       -- the things with a stepped or every function, and with a touched one
local by_address = {}       -- actor address -> its thing
local finished, begun = {}, {}          -- things whose ended and began functions are still to run
local waiting, waiting_count = {}, 0    -- actor address -> a thing that has not begun play yet
local collecting = nil      -- the addresses that begin play while a spawn is under way
local stop_began, stop_ended, connection = nil, nil, nil
local live_count, dead = 0, 0
local step_cursor, touch_cursor, net_cursor, touch_debt = 1, 1, 1, 0
local set_in_use = false
local touch_broken = nil
local warned_fallback, warned_budget = false, false
local counts = { spawned = 0, over_budget = 0, fallback = 0, looks = 0 }
local actor_filter = { path = ACTOR_PATH }
local Blueprints, Blueprint, Thing = {}, {}, {}
local members, blueprint_members, thing_members, thing_fields, thing_setters = {}, {}, {}, {}, {}

local function first_line(problem) return (tostring(problem):match("^[^\r\n]*")) end

local function clean(problem) return (first_line(problem):gsub("^.-%.lua:%d+: ", "")) end

local function usable(object) return object ~= nil and object:IsValid() end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function is_shape(value) return type(value) == "table" and getmetatable(value) == "Mesh" end

local function describe(value)
    if is_instance(value) then return "a " .. tostring(value.ClassName) end
    if is_shape(value) then return "a shape from game.Assets:Mesh" end
    if value == nil then return "nothing" end
    return "a " .. type(value)
end

local function known_keys(options, names, what)
    for key in pairs(options) do
        local found = false
        for _, name in ipairs(names) do found = found or key == name end
        if not found then
            error(("%s has no option '%s'.%s"):format(what, tostring(key), suggest.phrase(tostring(key), names)), 0)
        end
    end
end

local function fields3(value, a, b, c) return value[a], value[b], value[c] end

-- Three numbers from { X = , Y = , Z = }, { 1, 2, 3 } or what the game hands out for a place. Nil when it is not that.
local function three(value, a, b, c)
    local kind = type(value)
    if kind == "table" and not is_instance(value) then
        local x, y, z = value[a], value[b], value[c]
        if x == nil and y == nil and z == nil then x, y, z = value[1], value[2], value[3] end
        if finite(x) and finite(y) and finite(z) then return x, y, z end
    elseif kind == "userdata" then
        local ok, x, y, z = pcall(fields3, value, a, b, c)
        if ok and finite(x) and finite(y) and finite(z) then return x, y, z end
    end
    return nil
end

local TURNS = { Pitch = true, Yaw = true, Roll = true, [1] = true, [2] = true, [3] = true }

-- A turn as pitch, yaw and roll in degrees. In a table the ones left out are 0. Nil when it is not a turn.
local function turn_of(value)
    if type(value) == "userdata" then return three(value, "Pitch", "Yaw", "Roll") end
    if type(value) ~= "table" or is_instance(value) then return nil end
    for key in pairs(value) do
        if not TURNS[key] then return nil end
    end
    local pitch, yaw, roll = value.Pitch or value[1] or 0, value.Yaw or value[2] or 0, value.Roll or value[3] or 0
    if finite(pitch) and finite(yaw) and finite(roll) then return pitch, yaw, roll end
    return nil
end

-- The engine's own rule for a turn in degrees as the four numbers a transform holds.
local function quaternion(pitch, yaw, roll)
    local half = math.pi / 360
    local sp, cp = math.sin(pitch * half), math.cos(pitch * half)
    local sy, cy = math.sin(yaw * half), math.cos(yaw * half)
    local sr, cr = math.sin(roll * half), math.cos(roll * half)
    return { cr * sp * sy - sr * cp * cy, -cr * sp * cy - sr * cp * sy, cr * cp * sy - sr * sp * cy, cr * cp * cy + sr * sp * sy }
end

local NO_TURN, NO_OFFSET, FULL_SIZE = { 0, 0, 0, 1 }, { 0, 0, 0 }, { 1, 1, 1 }

-- Always written in full: a transform with a part left out has no size and no turn.
local function transform(place, turn, size)
    return {
        Rotation = { X = turn[1], Y = turn[2], Z = turn[3], W = turn[4] },
        Translation = { X = place[1], Y = place[2], Z = place[3] },
        Scale3D = { X = size[1], Y = size[2], Z = size[3] },
    }
end

local function assets_now()
    local game = Wax.game
    local assets = game and rawget(game, "Assets")
    if not assets then error("game.Assets is not running, and a blueprint gets its classes and assets from it", 0) end
    return assets
end

local function load_now(path, what)
    local found, why = assets_now():Load(path)
    if not found then error(("%s: %s"):format(what, tostring(why)), 0) end
    return found
end

-- The path an asset was found under, so it can be asked for again after a map change. Nil for what was made while the game ran.
local function path_of(found)
    local ok, full = pcall(function() return found.FullName end)
    local path = ok and type(full) == "string" and full:gsub("^%S+%s+", "") or nil
    if path and path:sub(1, 1) == "/" and path:sub(1, 18) ~= "/Engine/Transient." then return path end
    return nil
end

-- What a blueprint holds for a class, a mesh or a material: its Instance while that is usable, asked for again when it is not.
local function current(slot, what)
    local held = slot.now
    if held and held:IsValid() then return held end
    if slot.make then
        local ok, made = pcall(slot.make)
        if not ok then error(("%s: %s"):format(what, clean(made)), 0) end
        slot.now = made
    elseif slot.path then
        slot.now = load_now(slot.path, what)
    else
        error(("%s was given as an Instance that no longer exists (the map changed, or it was let go). "
            .. "Give its path, which can be asked for again, or define the blueprint again"):format(what), 0)
    end
    return slot.now
end

local function given(value, what)
    if not value:IsValid() then error(("%s is an Instance that no longer exists. Ask for it again"):format(what), 0) end
    return { now = value, path = path_of(value) }
end

local function class_path(text, what, common)
    if text:sub(1, 1) == "/" or text:find("'", 1, true) then return text end
    if not text:match("^[%a_][%w_]*$") then error(("%s: '%s' is not the name of a class"):format(what, text), 0) end
    local elsewhere = ELSEWHERE[text:lower()]
    if elsewhere then return elsewhere end
    local assets = assets_now()
    for _, package in ipairs(PACKAGES) do
        if assets:IsLoaded(package .. text) then return package .. text end
    end
    error(("%s: the game has no class named '%s'.%s A class from the game's content is named by its path, "
        .. "such as /Game/Folder/BP_Thing.BP_Thing_C"):format(what, text, suggest.phrase(text, common)), 0)
end

-- A class as a blueprint names it: a short name, a path, or the Instance game.Assets:Load gave. Returns its slot and what it has.
local function class_slot(value, what, common)
    local slot
    if is_instance(value) then
        slot = given(value, what)
    elseif type(value) == "string" and value ~= "" then
        local path = class_path(value, what, common)
        slot = { path = path, now = load_now(path, what) }
    else
        error(("%s is a class: its name such as \"%s\", its path, or what game.Assets:Load gave for it. Got %s")
            :format(what, common[1], describe(value)), 0)
    end
    if not slot.now:IsA("Class") then
        error(("%s is %s, not a class. The class of a blueprint asset is named with _C at the end: /Game/Folder/BP_Thing.BP_Thing_C")
            :format(what, describe(slot.now)), 0)
    end
    return slot, reflect.class_info(slot.now.Raw)
end

local function asset_slot(value, what, class_name, expects)
    local slot
    if type(value) == "string" then
        slot = { path = value, now = load_now(value, what) }
    elseif is_instance(value) then
        slot = given(value, what)
    else
        error(("%s is %s. Got %s"):format(what, expects, describe(value)), 0)
    end
    if not slot.now:IsA(class_name) then error(("%s is %s. Got %s"):format(what, expects, describe(slot.now)), 0) end
    return slot
end

local function material_slot(value, what)
    local expects = "a material: its path, one from game.Assets:Load or game.Assets:Material, or { from = path, colors = { ... } }"
    if type(value) ~= "table" or is_instance(value) then return asset_slot(value, what, "MaterialInterface", expects) end
    known_keys(value, MATERIAL_OPTIONS, what)
    local from = value.from
    if type(from) ~= "string" and not is_instance(from) then
        error(("%s: from is the material to start from: its path, or one from game.Assets:Load. Got %s"):format(what, describe(from)), 0)
    end
    local options = { colors = value.colors, numbers = value.numbers, textures = value.textures }
    local slot = { make = function() return assets_now():Material(from, options) end }
    current(slot, what)
    return slot
end

local function has_setter(info, name)
    if not easy_loaded then return false end
    local ok, added = pcall(easy.merge, info)
    return ok and added and added.setters[name] ~= nil or false
end

-- The properties a blueprint writes, checked against the class by name. The values are checked when they are written.
local function read_set(set, info, what)
    if set == nil then return {}, {} end
    if type(set) ~= "table" then
        error(("%s is a table of property names and values, such as { bHidden = true }. Got %s"):format(what, describe(set)), 0)
    end
    local values, names = {}, {}
    for name, value in pairs(set) do
        if type(name) ~= "string" then error(("%s: a property is named by a string, got %s"):format(what, describe(name)), 0) end
        local member = info.members[name]
        if not (member and member.kind == "property") and not has_setter(info, name) then
            error(("%s: %s has no property named '%s'.%s"):format(what, info.name, name, suggest.phrase(name, info.list)), 0)
        end
        values[name] = value
        names[#names + 1] = name
    end
    table.sort(names)
    return values, names
end

local function read_part(name, part, what)
    if type(part) ~= "table" or is_instance(part) or is_shape(part) then
        error(("%s is a table such as { class = \"PointLightComponent\", at = { 0, 0, 100 } }. Got %s"):format(what, describe(part)), 0)
    end
    known_keys(part, PART_OPTIONS, what)
    local def = { name = name }
    if part.mesh ~= nil then
        if is_shape(part.mesh) then
            def.shape = part.mesh
        else
            def.mesh = asset_slot(part.mesh, what .. ": mesh", "StaticMesh",
                "a mesh: its path, one from game.Assets:Load, or a shape from game.Assets:Mesh")
        end
    end
    local class = part.class
    if class == nil then
        class = def.shape and "ProceduralMeshComponent" or def.mesh and "StaticMeshComponent" or nil
        if not class then error(("%s needs a class such as \"PointLightComponent\", or a mesh"):format(what), 0) end
    end
    local info
    def.class, info = class_slot(class, what .. ": class", COMMON_PARTS)
    local is = info.ancestors
    if not is.ActorComponent then
        error(("%s: %s is not a kind of component, so it cannot be a part of a thing"):format(what, info.name), 0)
    end
    if ABSTRACT[info.name] then
        error(("%s: %s only stands for the classes built on it and cannot be made. Name one of those, such as %s"):format(what, info.name,
            is.SceneComponent and "\"StaticMeshComponent\" or \"PointLightComponent\"" or "\"RotatingMovementComponent\""), 0)
    end
    def.class_name, def.scene, def.primitive = info.name, is.SceneComponent == true, is.PrimitiveComponent == true
    if def.mesh and not is.StaticMeshComponent then
        error(("%s: a mesh of the game goes on a StaticMeshComponent, and this part is a %s"):format(what, info.name), 0)
    end
    if def.shape and not is.ProceduralMeshComponent then
        error(("%s: a shape from game.Assets:Mesh goes on a ProceduralMeshComponent, and this part is a %s"):format(what, info.name), 0)
    end
    if part.material ~= nil then
        if not def.primitive then error(("%s: a %s is not drawn, so it takes no material"):format(what, info.name), 0) end
        def.material = material_slot(part.material, what .. ": material")
    end
    for _, key in ipairs({ "at", "rotation", "scale" }) do
        if part[key] ~= nil and not def.scene then
            error(("%s: a %s has no place in the world, so it takes no %s"):format(what, info.name, key), 0)
        end
    end
    def.at, def.turn, def.size = NO_OFFSET, NO_TURN, FULL_SIZE
    if part.at ~= nil then
        local x, y, z = three(part.at, "X", "Y", "Z")
        if not x then error(("%s: at is where the part sits, measured from the thing: { X = 0, Y = 0, Z = 100 } or { 0, 0, 100 }"):format(what), 0) end
        def.at, def.placed = { x, y, z }, true
    end
    if part.rotation ~= nil then
        local pitch, yaw, roll = turn_of(part.rotation)
        if not pitch then error(("%s: rotation is a turn in degrees: { Pitch = 0, Yaw = 90, Roll = 0 } or { 0, 90, 0 }"):format(what), 0) end
        def.turn, def.placed = quaternion(pitch, yaw, roll), true
    end
    if part.scale ~= nil then
        local x, y, z = part.scale, part.scale, part.scale
        if type(part.scale) ~= "number" then x, y, z = three(part.scale, "X", "Y", "Z") end
        if not (finite(x) and finite(y) and finite(z)) or x == 0 or y == 0 or z == 0 then
            error(("%s: scale is a number such as 0.5, or one for each direction: { X = 1, Y = 1, Z = 2 }. None of them 0"):format(what), 0)
        end
        def.size = { x, y, z }
    end
    if part.collision ~= nil then
        local wanted = type(part.collision) == "string" and part.collision:lower() or nil
        if wanted ~= "none" and wanted ~= "solid" and wanted ~= "touch" then
            error(("%s: collision is \"none\", \"solid\" or \"touch\".%s"):format(what,
                type(part.collision) == "string" and suggest.phrase(part.collision, COLLISIONS) or ""), 0)
        end
        if not def.primitive then error(("%s: a %s has no shape, so it takes no collision"):format(what, info.name), 0) end
        if wanted == "touch" and not M.TOUCH then
            error(("%s: collision = \"touch\" is switched off in this version of Wax"):format(what), 0)
        end
        def.collision = wanted
    end
    def.set, def.set_names = read_set(part.set, info, what .. ": set")
    if part.root ~= nil and type(part.root) ~= "boolean" then error(("%s: root is true or false"):format(what), 0) end
    def.root = part.root == true
    return def
end

local function part_name(name, what)
    if type(name) ~= "string" or not name:match("^[%w_][%w_ %-]*$") or #name > MAX_NAME then
        error(("%s is named by a short string of letters and digits, such as \"Body\". Got %s"):format(what,
            type(name) == "string" and "'" .. name .. "'" or describe(name)), 0)
    end
    return name
end

-- The parts in the order they are made: the root first. Given as a list (each with a name) or by name.
local function read_parts(parts)
    if parts == nil then return {} end
    if type(parts) ~= "table" or is_instance(parts) then
        error("parts is a table of parts by name, such as { Body = { mesh = \"/Game/...\" } }. Got " .. describe(parts), 0)
    end
    local listed, named = #parts, {}
    for key in pairs(parts) do
        if type(key) == "string" then
            named[#named + 1] = key
        elseif not (math.type(key) == "integer" and key >= 1 and key <= listed) then
            error("parts is a table of parts by name, or a list of parts that each have a name. It has the key " .. tostring(key), 0)
        end
    end
    table.sort(named, function(a, b) return a:lower() < b:lower() end)
    local defs, seen = {}, {}
    local function add(name, part, what)
        part_name(name, what)
        if seen[name:lower()] then error(("two parts are named %s. Each part needs a name of its own"):format(name), 0) end
        seen[name:lower()] = true
        defs[#defs + 1] = read_part(name, part, "part " .. name)
    end
    for index = 1, listed do
        local part = parts[index]
        add(type(part) == "table" and part.name or nil, part, "part " .. index .. " of the list")
    end
    for _, name in ipairs(named) do
        local part = parts[name]
        if type(part) == "table" and part.name ~= nil and part.name ~= name then
            error(("part %s also says name = '%s'. A part given by name needs no name option"):format(name, tostring(part.name)), 0)
        end
        add(name, part, "part " .. name)
    end
    if #defs > M.MAX_PARTS then error(("%d parts is more than the %d a thing can have"):format(#defs, M.MAX_PARTS), 0) end
    local root, placed = nil, 0
    for _, def in ipairs(defs) do
        if def.root then
            if not def.scene then error(("part %s: a %s has no place in the world, so it cannot be the root"):format(def.name, def.class_name), 0) end
            if root then error(("parts %s and %s both say root = true. A thing has one root"):format(root.name, def.name), 0) end
            root = def
        end
        if def.scene then placed = placed + 1 end
    end
    if not root and placed > 0 then
        for index = 1, listed do
            if defs[index].scene then
                root = defs[index]
                break
            end
        end
        if not root and placed == 1 then
            for _, def in ipairs(defs) do
                if def.scene then root = def end
            end
        end
        if not root then
            error(("%d parts have a place and none of them says root = true. Mark the one the others hang on: it stands where the thing is spawned")
                :format(placed), 0)
        end
    end
    if root then
        if root.placed then
            error(("part %s is the root: it stands where the thing is spawned, so it takes no at and no rotation"):format(root.name), 0)
        end
        root.root = true
        for index, def in ipairs(defs) do
            if def == root then table.remove(defs, index) end
        end
        table.insert(defs, 1, root)
    end
    return defs
end

local function gone(record) return ("this %s no longer exists (%s)"):format(record.blueprint.name, WHY[record.reason] or WHY.Destroyed) end

-- A thing is gone: nothing of the game is asked from here on. Its ended function runs at the next step.
local function finish(record, reason, silent)
    if record.destroyed then return end
    record.destroyed, record.reason = true, reason
    local address = record.address
    if by_address[address] == record then by_address[address] = nil end
    if waiting[address] == record then
        waiting[address] = nil
        waiting_count = waiting_count - 1
    end
    record.parts, record.touching = {}, nil
    if record.held then record.held:drop() end
    record.held = nil
    local blueprint = record.blueprint
    blueprint.count = blueprint.count - 1
    live_count = live_count - 1
    dead = dead + 1
    if not silent and record.told and blueprint.ended and not blueprint.removed then finished[#finished + 1] = record end
end

-- True only when the engine itself says the actor is gone though its end of play was not seen. The actor is not asked.
-- Without handles nothing can be known that way, and the thing's own flag stands.
local function gone_unseen(record)
    local held = record.held
    return held ~= nil and held:checked() and not held:alive()
end

local function take_away(target) target.Raw:K2_DestroyActor() end

-- Takes a thing out of the world. End of play is seen inside the call and finishes it.
local function destroy(record, reason, silent)
    if record.destroyed then return end
    record.leaving, record.silent = reason, silent
    local target = record.instance
    if not gone_unseen(record) and target:IsValid() then
        local ok, problem = pcall(take_away, target)
        if not ok then log:warn("a %s could not be taken out of the world: %s", record.blueprint.name, clean(problem)) end
        if not record.destroyed then instance.retire(record.address) end
    end
    finish(record, reason, silent)
end

-- Runs one of a blueprint's functions for a thing. A failure that came from the thing being gone is not held against the function.
local function run(wrapped, state, record, ...)
    if state.off then return end
    local before = state.failures
    wrapped(record.api, ...)
    if state.failures > before and not record.destroyed and gone_unseen(record) then
        state.failures, state.off = before, false
        finish(record, "Destroyed")
    end
end

local function tell_began(record)
    if record.told or record.destroyed then return end
    record.told = true
    local blueprint = record.blueprint
    local now = M.clock()
    record.stepped_at, record.every_at, record.due = now, now, now + (blueprint.every_seconds or 0)
    if blueprint.began then run(blueprint.began, blueprint.began_state, record) end
end

-- Inside the engine's call: nothing of a mod runs here.
local function on_began(actor)
    local address = actor:GetAddress()
    if collecting then collecting[address] = true end
    local record = waiting[address]
    if record then
        waiting[address] = nil
        waiting_count = waiting_count - 1
        begun[#begun + 1] = record
    end
end

local function on_ended(_, address, reason)
    local record = by_address[address]
    if not record then return end
    finish(record, record.leaving or REASONS[reason] or "Destroyed", record.silent or reason == actors.QUIT)
end

local function listen()
    if not stop_began then stop_began = actors.on_began(on_began) end
end

local function unlisten()
    if stop_began and not collecting and waiting_count == 0 then
        stop_began()
        stop_began = nil
    end
end

local function assign(target, name, value) target[name] = value end

local function write(target, name, value, what)
    local ok, problem = pcall(assign, target, name, value)
    if not ok then error(("%s: %s"):format(what, clean(problem)), 0) end
end

-- Makes one part on a live actor. The first part with a place becomes the root when the actor has none, and takes the thing's place.
local function add_part(record, actor, def)
    local what = "part " .. def.name
    local class = current(def.class, what .. ": class").Raw
    local mesh = def.mesh and current(def.mesh, what .. ": mesh").Raw or nil
    local material = def.material and current(def.material, what .. ": material") or nil
    local placement = transform(def.at, def.turn, def.size)
    if def.scene then
        local root = actor.RootComponent
        if root:IsValid() then
            -- the game measures a part against its root, size and all: written against the root's size, at and scale mean what they say
            local size = root:K2_GetComponentScale()
            local x, y, z = size.X ~= 0 and size.X or 1, size.Y ~= 0 and size.Y or 1, size.Z ~= 0 and size.Z or 1
            placement = transform({ def.at[1] / x, def.at[2] / y, def.at[3] / z }, def.turn, { def.size[1] / x, def.size[2] / y, def.size[3] / z })
        else
            placement = transform(record.place, record.turn, def.size)
        end
    end
    local component = actor:AddComponentByClass(class, false, placement, true)
    if not usable(component) then error(("%s: the game did not make a %s"):format(what, def.class_name), 0) end
    local part = wrap(component)
    if def.scene then component:SetMobility(MOVABLE) end
    for _, name in ipairs(def.set_names) do write(part, name, def.set[name], what .. ": set." .. name) end
    if mesh then component:SetStaticMesh(mesh) end
    actor:FinishAddComponent(component, false, placement)
    if def.shape then
        def.shape:Apply(part, material and { material = material } or nil)
    elseif material then
        component:SetMaterial(0, material.Raw)
    end
    if def.collision == "none" then
        component:SetCollisionEnabled(NO_COLLISION)
    elseif def.collision == "touch" then
        component:SetCollisionProfileName(FName(OVERLAP_PROFILE), true)
        component:SetGenerateOverlapEvents(true)
    end
    record.parts[def.name:lower()] = { name = def.name, instance = part }
    record.part_count = record.part_count + 1
    return part
end

local function furnish(record, actor, statics, placement, deferred)
    local blueprint, target = record.blueprint, record.instance
    for _, name in ipairs(blueprint.set_names) do write(target, name, blueprint.set[name], "set." .. name) end
    for _, def in ipairs(blueprint.parts) do add_part(record, actor, def) end
    if deferred then statics:FinishSpawningActor(actor, placement) end
end

local function begin_spawn(statics, world, class, placement)
    return statics:BeginDeferredActorSpawnFromClass(world, class, placement, ALWAYS_SPAWN, nil)
end

local function plain_spawn(world, class, place, pitch, yaw, roll)
    return world:SpawnActor(class, { X = place[1], Y = place[2], Z = place[3] }, { Pitch = pitch, Yaw = yaw, Roll = roll })
end

local function build(blueprint, place, pitch, yaw, roll, data)
    local game = Wax.game
    local class = current(blueprint.base, "base").Raw
    for _, def in ipairs(blueprint.parts) do
        current(def.class, "part " .. def.name .. ": class")
        if def.mesh then current(def.mesh, "part " .. def.name .. ": mesh") end
        if def.material then current(def.material, "part " .. def.name .. ": material") end
    end
    local statics, world = game:Library("GameplayStatics").Raw, game.World.Raw
    local turn = quaternion(pitch, yaw, roll)
    local placement = transform(place, turn, FULL_SIZE)
    collecting = {}
    listen()
    local actor, deferred = nil, false
    if M.DEFERRED then
        local ok, made = pcall(begin_spawn, statics, world, class, placement)
        if ok and usable(made) then
            actor, deferred = made, true
        else
            counts.fallback = counts.fallback + 1
            if not warned_fallback then
                warned_fallback = true
                log:warn("the game did not begin a spawn in two steps (%s), so the plain way is tried: such a thing begins play before its parts are there",
                    ok and "it gave nothing" or clean(made))
            end
        end
    end
    if not actor then
        local ok, made = pcall(plain_spawn, world, class, place, pitch, yaw, roll)
        if not (ok and usable(made)) then
            collecting = nil
            unlisten()
            error(("the game did not spawn a %s%s"):format(blueprint.base_name, ok and "" or ": " .. clean(made)), 0)
        end
        actor = made
    end
    local address = actor:GetAddress()
    local record = {
        blueprint = blueprint, instance = wrap(actor), address = address, parts = {}, part_count = 0, data = data or {},
        destroyed = false, told = false, place = place, turn = turn, touching = {},
    }
    if handles_loaded then
        local taken, kept = pcall(handles.hold, actor)
        if taken then record.held = kept end
    end
    record.api = setmetatable({ [THING] = record }, Thing)
    by_address[address] = record
    all[#all + 1] = record
    blueprint.count = blueprint.count + 1
    live_count = live_count + 1
    counts.spawned = counts.spawned + 1
    local ok, problem = pcall(furnish, record, actor, statics, placement, deferred)
    local seen = collecting
    collecting = nil
    if not ok or record.destroyed then
        destroy(record, "Destroyed", true)
        unlisten()
        error(ok and "it was destroyed while it was being put together" or problem, 0)
    end
    if blueprint.stepped or blueprint.every then stepping[#stepping + 1] = record end
    if blueprint.touched then touching[#touching + 1] = record end
    if seen[address] then
        tell_began(record)
    else
        waiting[address] = record
        waiting_count = waiting_count + 1
    end
    unlisten()
    return record
end

-- What the mod that defined the blueprint asks of game.Assets while a thing is made is kept for that mod.
local function owned(blueprint, fn, ...)
    local previous = scope.enter(blueprint.owner)
    local results = table.pack(pcall(fn, ...))
    scope.leave(previous)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

local function remove(blueprint)
    if blueprint.removed then return end
    blueprint.removed = true
    if blueprints[blueprint.key] == blueprint then blueprints[blueprint.key] = nil end
    if blueprint.owner and blueprint.owner_slot then blueprint.owner:remove(blueprint.owner_slot) end
    blueprint.owner_slot = nil
    for index = 1, #all do
        local record = all[index]
        if record.blueprint == blueprint then destroy(record, "Removed", true) end
    end
end

local function things_of(blueprint)
    local out = {}
    for index = 1, #all do
        local record = all[index]
        if not record.destroyed and (blueprint == nil or record.blueprint == blueprint) then out[#out + 1] = record.api end
    end
    return out
end

local function compact(list)
    local kept = 0
    for index = 1, #list do
        local record = list[index]
        if not record.destroyed then
            kept = kept + 1
            list[kept] = record
        end
    end
    for index = #list, kept + 1, -1 do list[index] = nil end
end

local function overlapping(target, found)
    target.Raw:GetOverlappingActors(found, current(actor_filter, "the Actor class").Raw)
end

-- Asks what overlaps a thing and tells its touched function of each actor that did not overlap at the last look.
local function look(record)
    local target = record.instance
    if gone_unseen(record) then
        finish(record, "Destroyed")
        return
    end
    counts.looks = counts.looks + 1
    local found = {}
    local ok, problem = pcall(overlapping, target, found)
    if not ok then
        touch_broken = clean(problem)
        log:error("the game did not say what touches a thing (%s). No touched function runs until Wax starts again", touch_broken)
        return
    end
    local was, now, fresh = record.touching, {}, nil
    for index = 1, #found do
        local other = found[index]:get()
        if other:IsValid() then
            local address = other:GetAddress()
            now[address] = true
            if not was[address] then
                fresh = fresh or {}
                fresh[#fresh + 1] = wrap(other)
            end
        end
    end
    record.touching = now
    local blueprint = record.blueprint
    for index = 1, fresh and #fresh or 0 do
        if record.destroyed then break end
        run(blueprint.touched, blueprint.touched_state, record, fresh[index])
    end
end

local function step()
    if finished[1] then
        local list = finished
        finished = {}
        for index = 1, #list do
            local record = list[index]
            local blueprint = record.blueprint
            if not blueprint.removed and not blueprint.ended_state.off then blueprint.ended(record.api, record.reason) end
        end
    end
    if begun[1] then
        local list = begun
        begun = {}
        for index = 1, #list do tell_began(list[index]) end
        unlisten()
    end
    local count = #stepping
    if count > 0 then
        local started = M.clock()
        local now, index = started, step_cursor
        if index > count then index = 1 end
        for pass = 1, count do
            local record = stepping[index]
            index = index % count + 1
            if record.told and not record.destroyed then
                local blueprint = record.blueprint
                if blueprint.stepped then
                    local dt = now - record.stepped_at
                    record.stepped_at = now
                    run(blueprint.stepped, blueprint.stepped_state, record, dt)
                end
                if blueprint.every and now >= record.due and not record.destroyed then
                    local dt = now - record.every_at
                    record.every_at, record.due = now, now + blueprint.every_seconds
                    run(blueprint.every, blueprint.every_state, record, dt)
                end
                now = M.clock()
                if now - started > M.STEP_BUDGET and pass < count then
                    counts.over_budget = counts.over_budget + 1
                    if not warned_budget then
                        warned_budget = true
                        log:warn("the stepped and every functions of things took more than %g ms in one frame, so the rest waited a frame. "
                            .. "The last to run was a %s", M.STEP_BUDGET * 1000, blueprint.name)
                    end
                    break
                end
            end
        end
        step_cursor = index
    end
    count = #touching
    if count > 0 and M.TOUCH and not touch_broken then
        touch_debt = touch_debt + count
        while touch_debt >= M.TOUCH_FRAMES do
            touch_debt = touch_debt - M.TOUCH_FRAMES
            if touch_cursor > count then touch_cursor = 1 end
            local record = touching[touch_cursor]
            touch_cursor = touch_cursor + 1
            if record.told and not record.destroyed and not touch_broken then look(record) end
        end
    end
    -- the net under end of play: the handle of one thing a frame is asked whether its actor is still there
    count = #all
    if count > 0 then
        if net_cursor > count then net_cursor = 1 end
        local record = all[net_cursor]
        net_cursor = net_cursor + 1
        if not record.destroyed and gone_unseen(record) then finish(record, "Destroyed") end
    end
    if dead > 0 then
        dead = 0
        compact(all)
        compact(stepping)
        compact(touching)
    end
end

local function on_step()
    if not all[1] and not finished[1] then return end
    local ok, problem = xpcall(step, guard.handler)
    if not ok then guard.report(problem, "blueprints.step") end
end

-- The frame loop reaches this module through a tracked list of its own, which lists no actor.
local function use_set()
    if set_in_use then return end
    local set = track.sets.blueprints
    if not set then set = track.define("blueprints", { roots = {}, seed = {}, classify = function() return false end }) end
    set.spec.step = on_step
    set:use()
    set_in_use = true
end

local function colon(self, name, arguments)
    if self ~= Blueprints then error(("call %s with a colon: game.Blueprints:%s(%s)"):format(name, name, arguments), 3) end
end

local function describe_blueprint(name, options, owner)
    local blueprint = { name = name, key = name:lower(), owner = owner, count = 0, removed = false }
    local info
    blueprint.base, info = class_slot(options.base == nil and "Actor" or options.base, "base", COMMON_BASES)
    if not info.ancestors.Actor then
        error(("base is %s, which is not a kind of Actor. Start from \"Actor\" or from a class built on it"):format(info.name), 0)
    end
    blueprint.base_name = info.name
    blueprint.set, blueprint.set_names = read_set(options.set, info, "set")
    blueprint.parts = read_parts(options.parts)
    for _, key in ipairs(FUNCTIONS) do
        local fn = options[key]
        if fn ~= nil and type(fn) ~= "function" then error(("%s is a function, got %s"):format(key, describe(fn)), 0) end
    end
    local every = options.every
    if every ~= nil then
        if type(every) ~= "table" or not finite(every[1]) or every[1] <= 0 or type(every[2]) ~= "function" then
            error("every is the seconds between two calls and a function: every = { 0.5, function(thing, dt) end }", 0)
        end
        blueprint.every_seconds = every[1]
        blueprint.every, blueprint.every_state = guard.wrap(name .. ".every", every[2])
    end
    if options.touched ~= nil and not M.TOUCH then error("touched is switched off in this version of Wax", 0) end
    for _, key in ipairs(FUNCTIONS) do
        if options[key] then blueprint[key], blueprint[key .. "_state"] = guard.wrap(name .. "." .. key, options[key]) end
    end
    return blueprint
end

-- Describes a kind of thing. Nothing is put in the world until blueprint:Spawn.
function members:Define(name, options)
    colon(self, "Define", "name, options")
    if type(name) ~= "string" or not name:match("^[%w_][%w_ %-]*$") or #name > MAX_NAME then
        error("game.Blueprints:Define expects a name of letters and digits such as \"Crate\", then a table. Got "
            .. (type(name) == "string" and "'" .. name .. "'" or describe(name)), 2)
    end
    if type(options) ~= "table" or is_instance(options) then
        error(("game.Blueprints:Define(\"%s\") expects a table such as { parts = { Body = { mesh = \"/Game/...\" } } }. Got %s")
            :format(name, describe(options)), 2)
    end
    local owner = scope.current()
    if owner and not owner.alive then owner = nil end
    local old = blueprints[name:lower()]
    if old and old.owner ~= owner then
        error(("another mod (%s) already has a blueprint named %s. Pick another name"):format(old.owner and old.owner.name or "the console",
            old.name), 2)
    end
    local ok, blueprint = pcall(function()
        known_keys(options, OPTIONS, "the blueprint")
        return describe_blueprint(name, options, owner)
    end)
    if not ok then error(("game.Blueprints:Define(\"%s\"): %s"):format(name, clean(blueprint)), 2) end
    if old then remove(old) end
    blueprint.api = setmetatable({ [BLUEPRINT] = blueprint }, Blueprint)
    blueprints[blueprint.key] = blueprint
    if owner then blueprint.owner_slot = owner:add(function() remove(blueprint) end) end
    if blueprint.touched and (blueprint.base.path or ""):lower() == ACTOR_PATH:lower() then
        local touches = false
        for _, def in ipairs(blueprint.parts) do touches = touches or def.collision == "touch" end
        if not touches then
            log:warn("%s has a touched function and no part with collision = \"touch\", so nothing can touch it", name)
        end
    end
    use_set()
    return blueprint.api
end

-- The blueprint of that name, or nil.
function members:Get(name)
    colon(self, "Get", "name")
    if type(name) ~= "string" then error("game.Blueprints:Get expects the name of a blueprint, got " .. describe(name), 2) end
    local blueprint = blueprints[name:lower()]
    return blueprint and blueprint.api or nil
end

-- Every thing in the world that was spawned from a blueprint, oldest first.
function members:GetThings()
    colon(self, "GetThings", "")
    return things_of(nil)
end

local function blueprint_of(self, name, arguments)
    local blueprint = type(self) == "table" and rawget(self, BLUEPRINT) or nil
    if not blueprint then error(("call %s with a colon: blueprint:%s(%s)"):format(name, name, arguments), 3) end
    return blueprint
end

-- Puts one in the world. Only the host of a session can.
function blueprint_members:Spawn(position, rotation, data)
    local blueprint = blueprint_of(self, "Spawn", "position, rotation, data")
    local name = blueprint.name
    if blueprint.removed then
        error(("the blueprint %s was removed, so nothing can be spawned from it. Define it again"):format(name), 2)
    end
    local x, y, z = three(position, "X", "Y", "Z")
    if not x then
        error(("%s:Spawn expects where to put it: { X = 0, Y = 0, Z = 0 } or { 0, 0, 0 }. Got %s"):format(name, describe(position)), 2)
    end
    local pitch, yaw, roll = turn_of(rotation == nil and NO_OFFSET or rotation)
    if not pitch then
        error(("%s:Spawn: the rotation is a turn in degrees: { Pitch = 0, Yaw = 90, Roll = 0 } or { 0, 90, 0 }. Got %s")
            :format(name, describe(rotation)), 2)
    end
    if data ~= nil and (type(data) ~= "table" or is_instance(data)) then
        error(("%s:Spawn: the data is a table of your own that the thing keeps. Got %s"):format(name, describe(data)), 2)
    end
    local game = Wax.game
    if not (game and game.World) then error(("%s:Spawn: there is no world right now, so nothing can be spawned"):format(name), 2) end
    if not game.IsHost then
        error(("%s:Spawn: only the host of a session can spawn things. You have joined someone else's game, and its host decides what is in the world")
            :format(name), 2)
    end
    if live_count >= M.MAX_THINGS then
        error(("%s:Spawn: %d things are in the world already, and that is as many as Wax keeps. Destroy some first"):format(name, live_count), 2)
    end
    local ok, record = pcall(owned, blueprint, build, blueprint, { x, y, z }, pitch, yaw, roll, data)
    if not ok then error(("%s:Spawn: %s"):format(name, clean(record)), 2) end
    return record.api
end

-- The things of this blueprint that are in the world, oldest first.
function blueprint_members:GetThings() return things_of(blueprint_of(self, "GetThings", "")) end

function blueprint_members:Count() return blueprint_of(self, "Count", "").count end

-- Destroys its things and forgets it. Their ended function does not run.
function blueprint_members:Remove() remove(blueprint_of(self, "Remove", "")) end

Blueprint.__index = function(self, key)
    local member = blueprint_members[key]
    if member then return member end
    local blueprint = rawget(self, BLUEPRINT)
    if key == "Name" then return blueprint.name end
    if key == "Base" then return blueprint.base_name end
    error(("%s is not a member of a blueprint.%s"):format(tostring(key), suggest.phrase(tostring(key), BLUEPRINT_NAMES)), 2)
end
Blueprint.__newindex = function(_, key)
    error(("%s cannot be assigned: a blueprint is changed by defining it again"):format(tostring(key)), 2)
end
Blueprint.__tostring = function(self) return "Blueprint " .. rawget(self, BLUEPRINT).name end
Blueprint.__names = function() return BLUEPRINT_NAMES end
Blueprint.__metatable = "Blueprint"

local function thing_of(self, name, arguments)
    local record = type(self) == "table" and rawget(self, THING) or nil
    if not record then error(("call %s with a colon: thing:%s(%s)"):format(name, name, arguments), 3) end
    return record
end

-- The Instance of one of its parts, by the name the blueprint or AddPart gave it.
function thing_members:Part(name)
    local record = thing_of(self, "Part", "name")
    if record.destroyed then error(gone(record), 2) end
    if type(name) ~= "string" then error("thing:Part expects the name of a part, got " .. describe(name), 2) end
    local part = record.parts[name:lower()]
    if part then return part.instance end
    local names = {}
    for _, known in pairs(record.parts) do names[#names + 1] = known.name end
    error(("this %s has no part named '%s'.%s"):format(record.blueprint.name, name, suggest.phrase(name, names)), 2)
end

-- Makes one more part on a thing that is in the world. It hangs on the root.
function thing_members:AddPart(name, part)
    local record = thing_of(self, "AddPart", "name, part")
    if record.destroyed then error(gone(record), 2) end
    local blueprint = record.blueprint
    local ok, made = pcall(owned, blueprint, function()
        part_name(name, "a part")
        if record.parts[name:lower()] then error(("it already has a part named %s"):format(record.parts[name:lower()].name), 0) end
        if record.part_count >= M.MAX_PARTS then error(("it has %d parts, and that is as many as a thing can have"):format(record.part_count), 0) end
        local def = read_part(name, part, "part " .. name)
        if def.root then error(("part %s: root is for the parts a blueprint is defined with"):format(name), 0) end
        return add_part(record, record.instance.Raw, def)
    end)
    if not ok then error(("%s:AddPart: %s"):format(blueprint.name, clean(made)), 2) end
    return made
end

-- The box all its parts fit in: where its middle is and how large it is.
function thing_members:GetBounds()
    local record = thing_of(self, "GetBounds", "")
    if record.destroyed then error(gone(record), 2) end
    local ok, center, size = pcall(function()
        local origin, extent = {}, {}
        record.instance.Raw:GetActorBounds(false, origin, extent, false)
        return { X = origin.X, Y = origin.Y, Z = origin.Z }, { X = extent.X * 2, Y = extent.Y * 2, Z = extent.Z * 2 }
    end)
    if not ok then error(clean(center), 2) end
    return { Center = center, Size = size }
end

-- Takes it out of the world with all its parts. False when it was gone already.
function thing_members:Destroy()
    local record = thing_of(self, "Destroy", "")
    if record.destroyed then return false end
    destroy(record, "Destroyed")
    return true
end

-- True until the thing is gone. Never an error, and the actor itself is not asked.
function thing_fields.Alive(record)
    if record.destroyed then return false end
    if not gone_unseen(record) then return true end
    finish(record, "Destroyed")
    return false
end

-- Every Instance has IsValid, so a thing answers it too.
function thing_members:IsValid() return thing_fields.Alive(thing_of(self, "IsValid", "")) end

function thing_fields.Data(record) return record.data end

function thing_fields.Blueprint(record) return record.blueprint.api end

function thing_fields.Actor(record)
    if record.destroyed then error(gone(record), 0) end
    return record.instance
end

function thing_fields.Position(record)
    local at = thing_fields.Actor(record).Raw:K2_GetActorLocation()
    return { X = at.X, Y = at.Y, Z = at.Z }
end

function thing_fields.Facing(record)
    local turn = thing_fields.Actor(record).Raw:K2_GetActorRotation()
    return { Pitch = turn.Pitch, Yaw = turn.Yaw, Roll = turn.Roll }
end

-- A thing is moved by its root, whose place is the thing's while it hangs on nothing.
function thing_setters.Position(record, value)
    local x, y, z = three(value, "X", "Y", "Z")
    if not x then error("Position is three numbers: { X = 0, Y = 0, Z = 0 } or { 0, 0, 0 }. Got " .. describe(value), 0) end
    local root = thing_fields.Actor(record).Raw.RootComponent
    if not root:IsValid() then
        error(("this %s has no part with a place, so it cannot be moved"):format(record.blueprint.name), 0)
    end
    root:K2_SetRelativeLocation({ X = x, Y = y, Z = z }, false, {}, false)
end

function thing_setters.Facing(record, value)
    local pitch, yaw, roll = turn_of(value)
    if not pitch then error("Facing is a turn in degrees: { Pitch = 0, Yaw = 90, Roll = 0 } or { 0, 90, 0 }. Got " .. describe(value), 0) end
    thing_fields.Actor(record).Raw:K2_SetActorRotation({ Pitch = pitch, Yaw = yaw, Roll = roll }, false)
end

local function read_member(target, key) return target[key] end

-- Reached by a tail call, so level 2 is the mod's line.
local function forwarded(ok, ...)
    if ok then return ... end
    error(clean((...)), 2)
end

-- A function of the actor's Instance, callable on the thing: thing:K2_GetActorLocation().
local forwarders = setmetatable({}, { __mode = "k" })
local function forwarder(fn)
    local forward = forwarders[fn]
    if not forward then
        forward = function(receiver, ...)
            local record = type(receiver) == "table" and rawget(receiver, THING) or nil
            if not record then return fn(receiver, ...) end
            if record.destroyed then error(gone(record), 2) end
            return forwarded(pcall(fn, record.instance, ...))
        end
        forwarders[fn] = forward
    end
    return forward
end

-- The thing's own names first, then everything its actor's Instance has.
Thing.__index = function(self, key)
    local member = thing_members[key]
    if member then return member end
    local record = rawget(self, THING)
    local field = thing_fields[key]
    if field then
        local ok, value = pcall(field, record)
        if ok then return value end
        error(clean(value), 2)
    end
    if record.destroyed then error(gone(record), 2) end
    local ok, value = pcall(read_member, record.instance, key)
    if not ok then error(clean(value), 2) end
    if type(value) == "function" then return forwarder(value) end
    return value
end

Thing.__newindex = function(self, key, value)
    local record = rawget(self, THING)
    local setter = thing_setters[key]
    if setter then
        local ok, problem = pcall(setter, record, value)
        if not ok then error(clean(problem), 2) end
        return
    end
    if thing_members[key] or thing_fields[key] then
        error(("%s cannot be assigned: every thing has it%s"):format(tostring(key),
            key == "Data" and ". Change what is in the table" or ""), 2)
    end
    if record.destroyed then error(gone(record), 2) end
    local ok, problem = pcall(assign, record.instance, key, value)
    if not ok then error(clean(problem), 2) end
end

Thing.__tostring = function(self)
    local record = rawget(self, THING)
    local name = record.blueprint.name
    if record.destroyed then return name .. " (destroyed)" end
    local ok, actor = pcall(read_member, record.instance, "Name")
    return ok and (name .. " " .. tostring(actor)) or (name .. " (destroyed)")
end
Thing.__names = function() return THING_NAMES end
Thing.__metatable = "Thing"

setmetatable(Blueprints, {
    __index = function(_, key)
        local member = members[key]
        if member then return member end
        error(("%s is not a member of game.Blueprints.%s"):format(tostring(key), suggest.phrase(tostring(key), NAMES)), 2)
    end,
    __newindex = function(_, key)
        error(("game.Blueprints.%s cannot be assigned because game.Blueprints is read-only"):format(tostring(key)), 2)
    end,
    __tostring = function() return "Blueprints" end,
    __names = function() return NAMES end,
})

-- The old world's actors are gone and nothing of them may be asked. Blueprints stay, and get their classes and assets again.
local function on_map_change()
    for index = 1, #all do finish(all[index], "MapChanged") end
    waiting, waiting_count, collecting = {}, 0, nil
    unlisten()
end

function M.stats()
    local defined = 0
    for _ in pairs(blueprints) do defined = defined + 1 end
    return { blueprints = defined, things = live_count, stepping = #stepping, touching = #touching, waiting = waiting_count,
             spawned = counts.spawned, over_budget = counts.over_budget, fallback = counts.fallback, looks = counts.looks,
             touch = M.TOUCH and not touch_broken, touch_problem = touch_broken, listening = stop_began ~= nil }
end

function M.start()
    local root = Wax.import("engine.game").root
    connection = root.MapChanged:Connect(on_map_change)
    stop_ended = actors.on_ended(on_ended)
    rawset(root, "Blueprints", Blueprints)
end

-- Destroys every thing, forgets every blueprint and takes game.Blueprints away. For loading this file again in a running game.
function M.stop()
    local defined = {}
    for _, blueprint in pairs(blueprints) do defined[#defined + 1] = blueprint end
    for _, blueprint in ipairs(defined) do remove(blueprint) end
    if connection then connection:Disconnect() end
    if stop_ended then stop_ended() end
    connection, stop_ended = nil, nil
    waiting, waiting_count, collecting = {}, 0, nil
    unlisten()
    local set = track.sets.blueprints
    if set and set.spec.step == on_step then set.spec.step = nil end
    set_in_use = false
    all, stepping, touching, by_address, finished, begun = {}, {}, {}, {}, {}, {}
    live_count, dead = 0, 0
    local root = Wax.import("engine.game").root
    if rawget(root, "Blueprints") == Blueprints then rawset(root, "Blueprints", nil) end
end

M.api = Blueprints
return M
