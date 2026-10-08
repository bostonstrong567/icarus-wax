-- The model view: a creature or any other skeletal mesh of the game, drawn in 3D inside a control

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local kit = Wax.import("gui.kit")
local sched = Wax.import("core.sched")
local guard = Wax.import("core.guard")
local scope = Wax.import("core.scope")
local suggest = Wax.import("core.suggest")
local log = Wax.import("core.log").channel("wax.gui")

local model = {}

model.TURN, model.TILT = 0.5, 0.4       -- degrees for one unit the mouse moves, sideways and up or down
model.SPIN = 12                         -- degrees a second it turns by itself until the player touches it
model.STEP = 1.2                        -- one notch of the wheel
model.NEAR, model.FAR = 0.45, 1.6       -- how near and how far the camera goes: 1 is the distance at which the model fills the view
model.ABOVE, model.BELOW = 75, 20       -- how far over and under the model the camera goes, so the view never flips
model.YAW, model.PITCH = -40, 10        -- where it starts: three quarters from the front, a little above
model.FOV, model.MARGIN = 30, 1.15
model.RADIUS = 100                      -- how large every model is made in the world, whatever its own size
model.MIN_PIXELS, model.MAX_PIXELS = 64, 1024
model.SHARP = 2                         -- pixels drawn for each pixel of the box, each way: edges and fur are smooth
model.LEAST = 0.4                       -- the least of its box a model fills when it is shown beside a larger one
model.BUDGET = 0.003                    -- seconds of loading a frame
model.RENDERING = 2                     -- how many views draw a new picture in one frame
model.KEEP_SECONDS = 60                 -- a view that has not shown for this long gives its actor up
model.NAP = 4                           -- a view that does not show is looked at every so many frames
model.TWICE = 0.35                      -- seconds between two presses that put the view back
model.CLICK = 4                         -- how far the mouse moves with the button down before it is a turn
model.ROOM = 320                        -- how far the wheel catcher can turn either way before it is put back
model.WALK_SPEED = 150                  -- what an animation blueprint is told a walking creature moves at
model.KEY, model.FILL, model.RIM = 8, 2, 5      -- the three lights, in lux at the model
model.TAG = "WaxModel"
model.PREVIEW = "/Game/BP/UI/InventoryPlayer/M_MountPreview.M_MountPreview"
model.SOURCE = "SourceMeshComponent"    -- the member of a saddle's blueprint that names the mesh whose pose it copies

local V, H, VA = style.Visibility, style.HAlign, style.VAlign
local PENDING_KILL = EInternalObjectFlags and EInternalObjectFlags.PendingKill or 0x20000000
local DEPTH, SPREAD, PLACES = -1000000, 20000, 64
local FLAGS = { "InstancedFoliage", "InstancedGrass", "TextRender", "Bloom", "EyeAdaptation", "Fog", "Landscape", "Particles",
    "Atmosphere", "VolumetricFog", "SkyLighting", "DynamicShadows", "AmbientOcclusion", "ScreenSpaceReflections", "Decals",
    "LightShafts", "MotionBlur", "Refraction" }
local KINDS = {
    mesh = { "/Script/Engine.SkeletalMesh", "a skeletal mesh" },
    material = { "/Script/Engine.MaterialInterface", "a material" },
    animation = { "/Script/Engine.AnimationAsset", "an animation" },
    splines = { "/Script/GFur.FurSplines", "the splines of a fur" },
    blueprint = { "/Script/Engine.AnimBlueprintGeneratedClass", "an animation blueprint" },
    texture = { "/Script/Engine.Texture", "a texture" },
}
local FUR_NUMBERS = { layers = "LayerCount", length = "FurLength", min_length = "MinFurLength", bias = "ShellBias",
    noise = "NoiseStrength", hair_bias = "ReferenceHairBias", uniformity = "HairLengthForceUniformity" }
local LOOK_KEYS = { "mesh", "scale", "facing", "materials", "parts", "fur", "walk", "idle", "loop", "blueprint", "speed",
    "animation", "walks", "against" }
local OPTION_KEYS = { "width", "height", "size", "align", "backdrop", "spin", "turn", "zoom", "reset", "light", "yaw", "pitch",
    "distance" }
local ANIMATIONS = { "walk", "idle", "blueprint" }

local views = {}            -- every live view
local by_address = {}       -- actor address -> the view it belongs to, for the end of its play
local failed = {}           -- kind and path -> why it cannot be used. It is not asked for again
local places = {}           -- which places under the world are taken
local classes = {}
local started = false
local frame, last_step, load_spent, wanting, wanted_last = 0, nil, 0, 0, 0
local stats = { built = 0, destroyed = 0, ended = 0, swept = 0, loads = 0, failures = 0, steps = 0, seconds = 0, worst = 0,
    pictures = 0 }

-- Where the mouse is and whether a button is held. The live tests put a made-up pointer here.
model.mouse = function() return root.mouse() end
model.held = function(button) return button:IsPressed() == true end

local function now() return (Wax.perf and Wax.perf.now or os.clock)() end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function turn(yaw) return (yaw + 180) % 360 - 180 end

-- A class of the engine by its path. One that is not there is asked for once: a miss is slow.
local function class(path)
    local found = classes[path]
    if found == nil or (found and not found:IsValid()) then
        found = StaticFindObject(path)
        if not found:IsValid() then found = false end
        classes[path] = found
    end
    if not found then error("this version of the game has no " .. path, 0) end
    return found
end

local function place(x, y, z)
    return { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } }
end

-- The player's controller, read from the game each time. Nothing while there is none.
local function controller_now()
    local game = Wax.game
    local found = game and game.LocalPlayer
    return found and found.Raw or nil
end

-- A game path such as "/Game/ASS/CRE/Deer/SK_CRE_PAS_Deer". A path with no dot gets its last part again.
function model.check(source, blueprint)
    if type(source) ~= "string" or #source > 260 or source:sub(1, 1) ~= "/" then return nil end
    if not source:find(".", 1, true) then
        local last = source:match("([^/]+)$")
        if not last then return nil end
        source = source .. "." .. last .. (blueprint and "_C" or "")
    end
    if not source:match("^/[%w_]+/[%w_/%-]+%.[%w_%-]+$") then return nil end
    return source
end

-- Loads one thing of the game and makes sure it is what it will be used as. The object, or nil and why not.
local function load(path, kind)
    local key = kind .. " " .. path
    if failed[key] then return nil, failed[key] end
    local began = now()
    local ok, object = pcall(LoadAsset, path)
    local why = nil
    if not ok or object == nil or not object:IsValid() then
        why = path .. " could not be loaded. Is the path right?"
    else
        local fine, fits = pcall(function() return object:IsA(class(KINDS[kind][1])) end)
        if not (fine and fits) then why = path .. " is not " .. KINDS[kind][2] end
    end
    load_spent = load_spent + (now() - began)
    stats.loads = stats.loads + 1
    if why then
        failed[key] = why
        log:warn("%s", why)
        return nil, why
    end
    return object
end

local function names_of(list)
    local out = {}
    for index, name in ipairs(list) do out[index] = name end
    return out
end

-- A table of paths by slot, 1 first, as a creature's data gives them. Nil and why when it is not that.
local function slots_of(given, what)
    local out = {}
    if given == nil then return out end
    if type(given) ~= "table" then return nil, what .. " is a table of game paths by slot, such as { [1] = \"/Game/...\" }" end
    for slot, path in pairs(given) do
        if type(slot) ~= "number" or slot < 1 or slot > 64 or slot % 1 ~= 0 then return nil, what .. " are numbered from 1" end
        local checked = model.check(path)
        if not checked then return nil, ("%s[%d] is not a game path: %s"):format(what, slot, tostring(path)) end
        out[slot] = checked
    end
    return out
end

local function path_of(given, what, blueprint)
    if given == nil then return nil end
    local checked = model.check(given, blueprint)
    if not checked then return nil, ("%s is a game path such as \"/Game/ASS/CRE/Deer/SK_CRE_PAS_Deer\", not %s"):format(what, tostring(given)) end
    return checked
end

local function animation_of(given)
    if given == nil then return "walk" end
    if given == false then return false end
    if given == "walk" or given == "idle" or given == "blueprint" then return given end
    if type(given) == "string" and given:sub(1, 1) == "/" then
        local checked = model.check(given)
        if checked then return checked end
    end
    return nil, ("animation is \"walk\", \"idle\", \"blueprint\", the game path of an animation or false, not %s.%s"):format(
        tostring(given), type(given) == "string" and suggest.phrase(given, ANIMATIONS) or "")
end

-- What a view shows, read from what a mod gave: a copy with every path checked. Nil and why when something is wrong.
local function read_look(given)
    local mesh, problem = path_of(given.mesh, "mesh")
    if not mesh then return nil, problem or "mesh is missing: give the game path of a skeletal mesh" end
    local look = { mesh = mesh, parts = {}, fur = {} }
    for _, name in ipairs({ "scale", "facing", "speed" }) do
        local value = given[name]
        if value ~= nil and (type(value) ~= "number" or value ~= value) then return nil, name .. " is a number" end
    end
    look.scale = clamp(given.scale or 1, 0.01, 100)
    if given.against ~= nil then
        if type(given.against) ~= "table" then return nil, "against is a look with a mesh, such as what game.Creatures:GetModel gives for the adult" end
        local other = {}
        other.mesh, problem = path_of(given.against.mesh, "against.mesh")
        if not other.mesh then return nil, problem or "against has no mesh" end
        local size = given.against.scale
        if size ~= nil and (type(size) ~= "number" or size ~= size) then return nil, "against.scale is a number" end
        other.scale = clamp(size or 1, 0.01, 100)
        look.against = other
    end
    look.facing = given.facing or -90
    look.speed = clamp(given.speed or model.WALK_SPEED, 0, 1000)
    look.materials, problem = slots_of(given.materials, "materials")
    if not look.materials then return nil, problem end
    for _, name in ipairs({ "walk", "idle", "loop" }) do
        look[name], problem = path_of(given[name], name)
        if problem then return nil, problem end
    end
    look.blueprint, problem = path_of(given.blueprint, "blueprint", true)
    if problem then return nil, problem end
    look.animation, problem = animation_of(given.animation)
    if problem then return nil, problem end
    if given.parts ~= nil and type(given.parts) ~= "table" then return nil, "parts is a list such as { { mesh = \"/Game/...\" } }" end
    for index, part in ipairs(given.parts or {}) do
        if type(part) == "string" then part = { mesh = part } end
        if type(part) ~= "table" then return nil, ("parts[%d] is a table with a mesh"):format(index) end
        local piece = {}
        piece.mesh, problem = path_of(part.mesh, ("parts[%d].mesh"):format(index))
        if not piece.mesh then return nil, problem or ("parts[%d] has no mesh"):format(index) end
        piece.materials, problem = slots_of(part.materials, ("parts[%d].materials"):format(index))
        if not piece.materials then return nil, problem end
        piece.blueprint, problem = path_of(part.blueprint, ("parts[%d].blueprint"):format(index), true)
        if problem then return nil, problem end
        local socket = part.socket
        if socket ~= nil and (type(socket) ~= "string" or #socket > 64 or not socket:match("^[%w_]+$")) then
            return nil, ("parts[%d].socket is the name of a socket or a bone of the first mesh, such as \"RigRoot\""):format(index)
        end
        piece.socket = socket
        look.parts[index] = piece
    end
    local furs = given.fur
    if furs ~= nil and type(furs) ~= "table" then return nil, "fur is a table such as { mesh = \"/Game/...\", layers = 16 }" end
    if furs and furs.mesh ~= nil then furs = { furs } end
    for index, fur in ipairs(furs or {}) do
        if type(fur) ~= "table" then return nil, ("fur[%d] is a table with a mesh"):format(index) end
        local coat = { bare = fur.bare == true }
        coat.mesh, problem = path_of(fur.mesh, ("fur[%d].mesh"):format(index))
        if not coat.mesh then return nil, problem or ("fur[%d] has no mesh"):format(index) end
        coat.splines, problem = path_of(fur.splines, ("fur[%d].splines"):format(index))
        if problem then return nil, problem end
        for name in pairs(FUR_NUMBERS) do
            local value = fur[name]
            if value ~= nil and (type(value) ~= "number" or value ~= value) then return nil, ("fur[%d].%s is a number"):format(index, name) end
            coat[name] = value
        end
        if coat.layers then coat.layers = clamp(math.floor(coat.layers), 1, 64) end
        coat.materials, problem = slots_of(fur.materials, ("fur[%d].materials"):format(index))
        if not coat.materials then return nil, problem end
        coat.mask, problem = path_of(fur.mask, ("fur[%d].mask"):format(index))
        if problem then return nil, problem end
        look.fur[index] = coat
    end
    return look
end

-- The first key of a table that is none of the allowed ones, as an error text.
local function unknown_key(given, allowed, what)
    for key in pairs(given) do
        local known = false
        for _, name in ipairs(allowed) do
            if name == key then known = true break end
        end
        if not known then return ("%s has no option '%s'.%s"):format(what, tostring(key), suggest.phrase(tostring(key), allowed)) end
    end
    return nil
end

-- "sequence" or "blueprint" and the path to play, or "none".
local function playing_of(look)
    local wanted = look.animation
    if wanted == false then return "none" end
    if wanted == "blueprint" then
        if look.blueprint then return "blueprint", look.blueprint end
        return "none"
    end
    local path = wanted
    if wanted == "walk" then
        path = look.walk or look.idle or look.loop
    elseif wanted == "idle" then
        path = look.idle or (not look.walk and look.loop or nil)
    end
    if path then return "sequence", path end
    return "none"
end

-- Everything a look needs from the game, in the order it is loaded.
local function assets_of(look)
    local list = { { "material", model.PREVIEW, true }, { "mesh", look.mesh, true } }
    local function add(kind, path)
        if path then list[#list + 1] = { kind, path } end
    end
    for _, path in pairs(look.materials) do add("material", path) end
    for _, part in ipairs(look.parts) do
        add("mesh", part.mesh)
        for _, path in pairs(part.materials) do add("material", path) end
        add("blueprint", part.blueprint)
    end
    for _, coat in ipairs(look.fur) do
        add("mesh", coat.mesh)
        add("splines", coat.splines)
        for _, path in pairs(coat.materials) do add("material", path) end
        add("texture", coat.mask)
    end
    if look.against then add("mesh", look.against.mesh) end
    local kind, path = playing_of(look)
    if kind == "sequence" then add("animation", path) elseif kind == "blueprint" then add("blueprint", path) end
    return list
end

local function emit(view, signal, ...)
    local values = table.pack(...)
    local previous = scope.enter(view.maker)
    guard.call("model", function() signal:Fire(table.unpack(values, 1, values.n)) end)
    scope.leave(previous)
end

-- Lets go of everything a view has in the world, without a call: the engine has ended the actor, or is about to.
local function forget_rig(view)
    local rig = view.rig
    if not rig then return nil end
    view.rig = nil
    local actor = rig.actor
    if rig.address then by_address[rig.address] = nil end
    if rig.place then places[rig.place] = nil end
    for key in pairs(rig) do rig[key] = nil end
    return actor
end

local function destroy_rig(view)
    local actor = forget_rig(view)
    if not actor then return end
    stats.destroyed = stats.destroyed + 1
    pcall(function() actor:K2_DestroyActor() end)
end

local function hide_picture(view)
    if view.pictured then
        view.pictured = false
        view.image:SetVisibility(V.Hidden)
    end
end

local function fail(view, reason)
    destroy_rig(view)
    view.state, view.queue, view.loaded, view.fresh = "failed", nil, false, false
    hide_picture(view)
    stats.failures = stats.failures + 1
    log:warn("a model view shows nothing: %s", reason)
    emit(view, view.control.Failed, reason)
end

-- Destroys actors of this module that no view owns: an earlier load of it left them behind.
local function sweep()
    local controller = controller_now()
    if not controller then return 0 end
    local found, count = {}, 0
    root.library("GameplayStatics", "Engine"):GetAllActorsWithTag(controller, FName(model.TAG), found)
    for index = 1, #found do
        local actor = found[index]:get()
        if actor:IsValid() and not by_address[actor:GetAddress()] and not actor:HasAnyInternalFlags(PENDING_KILL) then
            actor:K2_DestroyActor()
            count = count + 1
        end
    end
    stats.swept = stats.swept + count
    return count
end
model.sweep = sweep

-- The map changed or the actor was destroyed by someone else: the view makes a new one when it next shows.
local function ended(view)
    forget_rig(view)
    stats.ended = stats.ended + 1
    if view.state == "ready" or view.state == "loading" then view.state, view.queue = "waiting", nil end
end

local function start()
    if started then return end
    started = true
    local previous = scope.enter(nil)
    local ok, problem = pcall(function()
        sweep()
        local hooks = Wax.model_hooks
        for _, undo in ipairs(hooks or {}) do pcall(undo) end
        hooks = {}
        Wax.model_hooks = hooks
        local told, actors = pcall(Wax.import, "engine.actors")
        if told and type(actors) == "table" and actors.on_ended then
            hooks[#hooks + 1] = actors.on_ended(function(_, address)
                local view = by_address[address]
                if view then ended(view) end
            end)
        end
        local game = Wax.game
        if game and game.MapChanged then
            local connection = game.MapChanged:Connect(function()
                for _, view in ipairs(views) do
                    if view.rig then ended(view) end
                end
                failed = {}
            end)
            hooks[#hooks + 1] = function() connection:Disconnect() end
        end
    end)
    scope.leave(previous)
    if not ok then log:warn("the model views could not set up their clean-up: %s", tostring(problem)) end
end
model.start = start

-- How many pixels a view of this many units is drawn with, the longer side never past the limit.
local function pixels_of(view)
    local host = view.host
    local _, _, screen = root.viewport_size()
    local zoom = (rawget(host, "place") and 1 or style.scale) * (rawget(host, "zoom") or 1) * (screen or 1) * model.SHARP
    local width, height = view.width * zoom, view.height * zoom
    local longer = math.max(width, height)
    if longer > model.MAX_PIXELS then width, height = width * model.MAX_PIXELS / longer, height * model.MAX_PIXELS / longer end
    return math.max(model.MIN_PIXELS, math.floor(width + 0.5)), math.max(model.MIN_PIXELS, math.floor(height + 0.5))
end

-- The picture the capture draws into and the material that shows it. Both belong to the game, not to the world.
local function picture_for(view, preview)
    local width, height = pixels_of(view)
    if view.target and view.target_width == width and view.target_height == height then return view.target end
    local game_instance = Wax.game.GameInstance.Raw
    local target = root.library("KismetRenderingLibrary", "Engine"):CreateRenderTarget2D(game_instance, width, height, 6,
        { R = 0, G = 0, B = 0, A = 1 }, false)
    if not target:IsValid() then error("the game made no picture to draw the model into", 0) end
    if not view.material then
        view.material = root.library("KismetMaterialLibrary", "Engine"):CreateDynamicMaterialInstance(game_instance, preview, FName("None"), 0)
        if not view.material:IsValid() then error("the game made no material to show the model with", 0) end
        view.image:SetBrushResourceObject(view.material)
    end
    view.material:SetTextureParameterValue(FName("SceneCapture"), target)
    view.target, view.target_width, view.target_height = target, width, height
    return target
end

local function take_place()
    for index = 1, PLACES do
        if not places[index] then return index end
    end
    return (frame % PLACES) + 1
end

local function dress(part, materials)
    for slot, path in pairs(materials) do
        local material = load(path, "material")
        if material then part:SetMaterial(slot - 1, material) end
    end
end

local function quiet(part)
    part:SetCollisionEnabled(0)
    part:SetVisibleInSceneCaptureOnly(true)
    part:SetCastShadow(false)
    part:SetLightingChannels(false, false, true)
end

local function add_light(rig, actor, lux, dx, dy, dz, red, green, blue)
    local radius = rig.radius
    local x, y, z = dx * radius, dy * radius, dz * radius
    local metres = math.sqrt(x * x + y * y + z * z) / 100
    local light = actor:AddComponentByClass(class("/Script/Engine.PointLightComponent"), false, place(x, y, z), true)
    light.IntensityUnits = 1
    light.Intensity = lux * metres * metres
    light.AttenuationRadius = radius * 8
    light.SoftSourceRadius = radius * 0.5
    light.SpecularScale = 0.2
    light.CastShadows = false
    light.LightingChannels.bChannel0 = false
    light.LightingChannels.bChannel1 = false
    light.LightingChannels.bChannel2 = true
    light.LightColor = { R = red, G = green, B = blue, A = 255 }
    actor:FinishAddComponent(light, false, place(x, y, z))
end

-- The game's own mask on a fur's first material: no fur grows where a saddle lies. Left out when that material is not known.
local function mask_fur(fur, coat)
    local base = coat.materials[1] and load(coat.materials[1], "material")
    local mask = base and load(coat.mask, "texture")
    if not mask then return end
    local copy = root.library("KismetMaterialLibrary", "Engine"):CreateDynamicMaterialInstance(Wax.game.GameInstance.Raw, base, FName("None"), 0)
    if not copy:IsValid() then return end
    copy:SetTextureParameterValue(FName("FurCullingMask"), mask)
    fur:SetMaterial(0, copy)
end

local function add_fur(rig, actor, coat)
    local grown = load(coat.mesh, "mesh")
    if not grown then return false end
    local fur = actor:AddComponentByClass(class("/Script/GFur.GFurComponent"), true, place(0, 0, 0), true)
    fur.SkeletalGrowMesh = grown
    local splines = coat.splines and load(coat.splines, "splines")
    if splines then fur.FurSplines = splines end
    for name, member in pairs(FUR_NUMBERS) do
        if coat[name] ~= nil then fur[member] = coat[name] end
    end
    if coat.bare then fur.RemoveFacesWithoutSplines = true end
    fur.PhysicsEnabled = false
    fur.LightingChannels.bChannel0 = false
    fur.LightingChannels.bChannel1 = false
    fur.LightingChannels.bChannel2 = true
    fur.bVisibleInSceneCaptureOnly = true
    fur.CastShadow = false
    actor:FinishAddComponent(fur, true, place(0, 0, 0))
    fur:K2_AttachToComponent(rig.part, FName("None"), 2, 2, 2, true)
    dress(fur, coat.materials)
    if coat.mask then
        local masked, trouble = pcall(mask_fur, fur, coat)
        if not masked then log:warn("a fur is shown without its mask (%s): %s", coat.mask, tostring(trouble)) end
    end
    -- the fur was made when it registered, before it had a body: made again on the body it takes that body's pose
    fur:RegenerateFur()
    rig.capture:ShowOnlyComponent(fur)
    rig.furs[#rig.furs + 1] = fur
    return true
end

-- Whether an animation blueprint has a member of this name.
local function has_member(instance, name)
    local ok, found = pcall(function()
        return Wax.import("engine.reflect").class_info(instance:GetClass()).members[name] ~= nil
    end)
    return ok and found == true
end

-- One more mesh that moves with the body. On the body's own skeleton it takes the body's pose as it is. With a
-- blueprint or a socket it is put on as the game puts a saddle on: attached to the body or to a socket of it, and
-- posed by its own blueprint, which copies the body bone by bone.
local function add_piece(rig, actor, piece, at, scale)
    local mesh = load(piece.mesh, "mesh")
    if not mesh then return false end
    local blueprint = piece.blueprint and load(piece.blueprint, "blueprint") or nil
    local part = actor:AddComponentByClass(class("/Script/Engine.SkeletalMeshComponent"), true, at, false)
    quiet(part)
    part:SetSkeletalMesh(mesh, true)
    part:SetForcedLOD(1)
    part:SetRelativeScale3D({ X = scale, Y = scale, Z = scale })
    local follows = false
    if blueprint or piece.socket then
        part.VisibilityBasedAnimTickOption = 0
        part.bEnableUpdateRateOptimizations = false
        part:K2_AttachToComponent(rig.part, FName(piece.socket or "None"), 2, 2, 2, true)
        if blueprint then
            part:SetAnimationMode(0)
            part:SetAnimClass(blueprint)
            local instance = part:GetAnimInstance()
            if instance:IsValid() then
                -- the game's saddle blueprints look for a mount above their actor: here they are given the body
                if has_member(instance, model.SOURCE) then instance[model.SOURCE] = rig.part end
                follows = true
            end
        end
        rig.worn[#rig.worn + 1] = part
    end
    -- nothing of its own to follow by, and not riding a socket: the body's pose, bone by bone
    if not follows and not piece.socket then part:SetMasterPoseComponent(rig.part, true) end
    dress(part, piece.materials)
    rig.capture:ShowOnlyComponent(part)
    return true
end

-- Starts what the look asks for on the rig's mesh. True when something plays.
local function animate(view)
    local rig, look = view.rig, view.look
    local kind, path = playing_of(look)
    rig.playing = false
    if kind == "sequence" then
        local sequence = load(path, "animation")
        if sequence then
            rig.part:PlayAnimation(sequence, true)
            rig.playing = true
        end
    elseif kind == "blueprint" then
        local blueprint = load(path, "blueprint")
        if blueprint then
            rig.part:SetAnimationMode(0)
            rig.part:SetAnimClass(blueprint)
            local instance = rig.part:GetAnimInstance()
            if instance:IsValid() and has_member(instance, "PawnVelocity") then instance.PawnVelocity = look.speed end
            rig.playing = true
        end
    end
    -- the next step pauses or runs the mesh for what plays now
    rig.running = nil
    view.dirty = 3
    return rig.playing
end

-- The ball round a mesh's bounds, or round those and the ball given: a model made of pieces is framed as a whole.
local function around(bounds, middle, reach)
    local at, radius = bounds.Origin, bounds.SphereRadius
    local x, y, z = at.X, at.Y, at.Z
    if not middle then return { X = x, Y = y, Z = z }, radius end
    local dx, dy, dz = x - middle.X, y - middle.Y, z - middle.Z
    local apart = math.sqrt(dx * dx + dy * dy + dz * dz)
    if apart + radius <= reach then return middle, reach end
    if apart + reach <= radius then return { X = x, Y = y, Z = z }, radius end
    local wide = (apart + radius + reach) / 2
    local along = (wide - reach) / apart
    return { X = middle.X + dx * along, Y = middle.Y + dy * along, Z = middle.Z + dz * along }, wide
end

-- The ball round a model's meshes, and how far they reach up or down and sideways from its middle.
local function measure(meshes)
    local middle, reach = nil, nil
    for _, mesh in ipairs(meshes) do middle, reach = around(mesh.ExtendedBounds, middle, reach) end
    local tall, broad = 0, 0
    for _, mesh in ipairs(meshes) do
        local bounds = mesh.ExtendedBounds
        local at, size = bounds.Origin, bounds.BoxExtent
        local dx, dy = at.X - middle.X, at.Y - middle.Y
        tall = math.max(tall, math.abs(at.Z - middle.Z) + size.Z)
        broad = math.max(broad, math.sqrt(dx * dx + dy * dy) + math.sqrt(size.X * size.X + size.Y * size.Y))
    end
    return middle, math.max(1, reach), math.min(tall, reach), math.min(broad, reach)
end

-- One actor far under the world. Its root is the camera's arm, the mesh is attached to nothing: turning the actor is an orbit.
local function build(view)
    local controller = controller_now()
    if not controller then return false end
    local look = view.look
    local mesh, why = load(look.mesh, "mesh")
    if not mesh then error(why, 0) end
    local preview, missing = load(model.PREVIEW, "material")
    if not preview then error("the game's own preview material is gone: " .. tostring(missing), 0) end
    local target = picture_for(view, preview)
    local meshes = { mesh }
    for _, piece in ipairs(look.parts) do
        -- a piece on a socket is measured from that socket, so it says nothing of where the model ends
        local more = not piece.socket and load(piece.mesh, "mesh")
        if more then meshes[#meshes + 1] = more end
    end
    local middle, reach, tall, broad = measure(meshes)
    -- every model is drawn at one size, so a chick and a boss get the same lights, distances and room under the world
    local radius = model.RADIUS
    local scale = radius / reach
    local spot = take_place()
    local x, y, z = (spot - PLACES / 2) * SPREAD, 0, DEPTH
    local rig = { place = spot, radius = radius, furs = {}, worn = {}, playing = false }
    -- a wide view sees as much height as a square one: the ball fits its width, the model as it first stands fits its height
    local half = math.rad(model.FOV / 2)
    local wide = math.atan(math.tan(half) * math.max(1, view.width / view.height))
    local slant = math.rad(math.abs(view.home_pitch))
    local high = (tall * math.cos(slant) + broad * math.sin(slant)) * scale
    rig.fov = math.deg(2 * wide)
    rig.fit = math.max(radius / math.sin(wide), math.min(high, radius) / math.sin(half)) * model.MARGIN
    -- beside another model it is as much smaller in the box as it is in the game: a young animal beside its adult
    local other = look.against and load(look.against.mesh, "mesh")
    if other then
        local _, other_reach = measure({ other })
        rig.fit = rig.fit / clamp(reach * look.scale / (other_reach * look.against.scale), model.LEAST, 1)
    end
    local actor = controller:GetWorld():SpawnActor(class("/Script/Engine.Actor"), { X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    if not actor:IsValid() then error("the game made no actor to carry the model", 0) end
    rig.actor, rig.address = actor, actor:GetAddress()
    places[spot] = view
    by_address[rig.address] = view
    view.rig = rig
    local ok, problem = pcall(function()
        actor.Tags[1] = FName(model.TAG)
        actor:AddComponentByClass(class("/Script/Engine.SceneComponent"), false, place(x, y, z), false)
        local at = place(x - middle.X * scale, y - middle.Y * scale, z - middle.Z * scale)
        local part = actor:AddComponentByClass(class("/Script/Engine.SkeletalMeshComponent"), true, at, false)
        rig.part = part
        quiet(part)
        part.VisibilityBasedAnimTickOption = 0
        part.bEnableUpdateRateOptimizations = false
        part:SetSkeletalMesh(mesh, true)
        part:SetForcedLOD(1)
        part:SetRelativeScale3D({ X = scale, Y = scale, Z = scale })
        dress(part, look.materials)

        local capture = actor:AddComponentByClass(class("/Script/Engine.SceneCaptureComponent2D"), false, place(-rig.fit, 0, 0), true)
        rig.capture = capture
        capture.TextureTarget = target
        capture.FOVAngle = rig.fov
        capture.CaptureSource = 0
        capture.PrimitiveRenderMode = 2
        capture.bCaptureEveryFrame = false
        capture.bCaptureOnMovement = false
        -- show flags are only read when the part registers, so they are written before it does
        local list = capture.ShowFlagSettings
        for index, name in ipairs(FLAGS) do
            local entry = list[index]
            entry.ShowFlagName = name
            entry.Enabled = false
        end
        actor:FinishAddComponent(capture, false, place(-rig.fit, 0, 0))
        capture:ShowOnlyComponent(part)

        local bright = view.light
        if bright > 0 then
            add_light(rig, actor, model.KEY * bright, -1.6, -1.3, 1.4, 255, 246, 228)
            add_light(rig, actor, model.FILL * bright, -1.3, 1.7, 0.2, 224, 234, 255)
            add_light(rig, actor, model.RIM * bright, 1.7, 0.7, 1.5, 255, 255, 255)
        end
        for _, piece in ipairs(look.parts) do
            local made, trouble = pcall(add_piece, rig, actor, piece, at, scale)
            if not made then log:warn("a piece of a model was left out (%s): %s", piece.mesh, tostring(trouble)) end
        end
        for _, coat in ipairs(look.fur) do
            local made, trouble = pcall(add_fur, rig, actor, coat)
            if not made then log:warn("a model is shown without its fur (%s): %s", coat.mesh, tostring(trouble)) end
        end
    end)
    if not ok then
        destroy_rig(view)
        error(problem, 0)
    end
    stats.built = stats.built + 1
    animate(view)
    return true
end

-- Puts the camera where the view says. The engine is only called for what changed.
local function aim(view)
    local rig = view.rig
    local yaw, pitch = (view.front + view.yaw) % 360, -view.pitch
    if yaw ~= rig.at_yaw or pitch ~= rig.at_pitch then
        rig.actor:K2_SetActorRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 }, false)
        rig.at_yaw, rig.at_pitch = yaw, pitch
        if view.dirty < 2 then view.dirty = 2 end
    end
    if view.zoom ~= rig.at_zoom then
        rig.capture:K2_SetRelativeLocation({ X = -rig.fit * view.zoom, Y = 0, Z = 0 }, false, {}, false)
        rig.at_zoom = view.zoom
        if view.dirty < 2 then view.dirty = 2 end
    end
end

local function touched(view, on)
    if view.touched == on then return end
    view.touched = on
    if view.reset then view.reset:SetVisibility(on and V.Visible or V.Collapsed) end
end

local function home(view)
    view.yaw, view.pitch, view.zoom = view.home_yaw, view.home_pitch, view.home_zoom
    view.auto, view.hold = view.spin ~= 0, nil
    touched(view, false)
end

local function tell_view(view)
    emit(view, view.control.Turned, turn(view.yaw), view.pitch, view.zoom)
end

local function pressed(view)
    local time = now()
    local x, y = model.mouse()
    local last = view.press
    if last and time - last.at < model.TWICE and math.abs(x - last.x) <= 6 and math.abs(y - last.y) <= 6 then
        view.press = nil
        home(view)
        tell_view(view)
        return
    end
    view.press = { at = time, x = x, y = y }
    view.hold = { x = x, y = y, yaw = view.yaw, pitch = view.pitch, moved = false }
    view.auto = false
    touched(view, true)
end

local function showing(view)
    if view.hidden then return false end
    local host = view.host
    local now_visible = rawget(host, "visible_now")
    if now_visible ~= nil then return now_visible == true end
    if host.shown ~= true or host.on_screen ~= true or host.minimized then return false end
    return not host.nav or host.page == view.page
end

local function sleep(view, time)
    local rig = view.rig
    view.hold, view.asleep = nil, true
    if not rig then return end
    if rig.capturing then
        rig.capture.bCaptureEveryFrame = false
        rig.capturing = false
    end
    if rig.running then
        rig.part.bPauseAnims = true
        rig.part:SetComponentTickEnabled(false)
        rig.running = false
    end
    if rig.awake ~= false then
        for _, fur in ipairs(rig.furs) do fur:SetComponentTickEnabled(false) end
        for _, part in ipairs(rig.worn) do part:SetComponentTickEnabled(false) end
        rig.awake = false
    end
    view.hidden_at = view.hidden_at or time
    if time - view.hidden_at > model.KEEP_SECONDS then
        destroy_rig(view)
        view.state = "waiting"
    end
end

-- Loads what the look needs, a few milliseconds a frame, then builds the actor.
local function prepare(view)
    if view.state == "waiting" then
        view.queue, view.at, view.state = assets_of(view.look), 1, "loading"
    end
    local queue = view.queue
    while view.at <= #queue do
        if load_spent >= model.BUDGET then return end
        local entry = queue[view.at]
        local object, why = load(entry[2], entry[1])
        if not object and entry[3] then return fail(view, why) end
        view.at = view.at + 1
    end
    if load_spent >= model.BUDGET then return end
    local began = now()
    local built = build(view)
    load_spent = load_spent + (now() - began)
    if not built then return end
    view.queue, view.state, view.reveal = nil, "ready", 2
    view.dirty = 3
end

local function step_view(view, time, dt)
    if not showing(view) then return sleep(view, time) end
    view.asleep, view.hidden_at = false, nil
    if view.state == "waiting" or view.state == "loading" then prepare(view) end
    local rig = view.rig
    if view.state ~= "ready" or not rig then return end

    local hold = view.hold
    if hold then
        if model.held(view.button) then
            local x, y = model.mouse()
            local dx, dy = x - hold.x, y - hold.y
            if not hold.moved and (math.abs(dx) > model.CLICK or math.abs(dy) > model.CLICK) then hold.moved = true end
            if hold.moved then
                -- the model follows the mouse: to the right its near side goes right, down it is seen more from above
                view.yaw = hold.yaw + dx * model.TURN
                view.pitch = clamp(hold.pitch + dy * model.TILT, -model.BELOW, model.ABOVE)
            end
        else
            view.hold = nil
            if hold.moved then tell_view(view) else emit(view, view.control.Clicked) end
        end
    end
    local catcher = view.catcher
    if catcher then
        local offset = catcher:GetScrollOffset()
        if offset == model.ROOM then
            view.wheel_ready = true
        else
            catcher:SetScrollOffset(model.ROOM)
            if view.wheel_ready then
                -- the box moves right when the wheel is turned towards the player: that is further away
                view.zoom = clamp(view.zoom * (offset > model.ROOM and model.STEP or 1 / model.STEP), model.NEAR, model.FAR)
                view.auto = false
                touched(view, true)
                tell_view(view)
            end
        end
    end
    if view.anim_due then
        view.anim_due = nil
        animate(view)
    end
    if view.auto then view.yaw = turn(view.yaw + view.spin * dt) end
    aim(view)

    local want = rig.playing or view.dirty > 0
    if want then
        wanting = wanting + 1
        if wanted_last > model.RENDERING and (wanting - 1 - frame) % wanted_last >= model.RENDERING then want = false end
    end
    if want ~= rig.capturing then
        rig.capture.bCaptureEveryFrame = want
        rig.capturing = want
    end
    if rig.playing ~= rig.running then
        rig.part.bPauseAnims = not rig.playing
        rig.part:SetComponentTickEnabled(rig.playing)
        rig.running = rig.playing
    end
    if rig.awake ~= true then
        for _, fur in ipairs(rig.furs) do fur:SetComponentTickEnabled(true) end
        for _, part in ipairs(rig.worn) do part:SetComponentTickEnabled(true) end
        rig.awake = true
    end
    if want then
        stats.pictures = stats.pictures + 1
        if view.dirty > 0 then view.dirty = view.dirty - 1 end
        if view.reveal then
            view.reveal = view.reveal - 1
            if view.reveal <= 0 then
                view.reveal = nil
                if not view.pictured then
                    view.pictured = true
                    view.image:SetVisibility(V.HitTestInvisible)
                end
                -- an actor made again for a look that showed before is not news
                if view.fresh then
                    view.fresh, view.loaded = false, true
                    emit(view, view.control.Loaded)
                end
            end
        end
    end
end

local function drop(view)
    destroy_rig(view)
    view.target, view.material, view.queue, view.hold = nil, nil, nil, nil
end

-- Once a frame, menu open or not. Costs nothing while no view exists.
function model.step()
    if #views == 0 then return end
    local time = now()
    local dt = math.min(0.1, time - (last_step or time))
    last_step, load_spent, wanting = time, 0, 0
    frame = frame + 1
    for index = #views, 1, -1 do
        local view = views[index]
        if view.control.destroyed or view.host.destroyed then
            drop(view)
            table.remove(views, index)
        elseif not view.asleep or (frame + index) % model.NAP == 0 then
            local ok, problem = xpcall(step_view, guard.handler, view, time, dt)
            if not ok then
                guard.report(problem, "model")
                fail(view, tostring(problem):match("^[^\r\n]*"))
            end
        end
    end
    wanted_last = wanting
    local spent = now() - time
    stats.steps, stats.seconds = stats.steps + 1, stats.seconds + spent
    if spent > stats.worst then stats.worst = spent end
end

-- Adds Container:Model. `tools` are the helpers every control in controls.lua is built with.
function model.install(Container, tools)
    local place_in, new_control, listen = tools.place, tools.new_control, tools.listen

    -- options: what to show (see read_look) and how: width, height or size, align, backdrop, spin, turn, zoom, reset, light, yaw, pitch, distance.
    function Container:Model(options)
        if options ~= nil and type(options) ~= "table" then
            error("Model expects a table of options such as { mesh = \"/Game/ASS/CRE/Deer/SK_CRE_PAS_Deer\", width = 212, height = 150 }", 0)
        end
        options = options or {}
        local keys = names_of(LOOK_KEYS)
        for _, name in ipairs(OPTION_KEYS) do keys[#keys + 1] = name end
        local wrong = unknown_key(options, keys, "Model")
        if wrong then error(wrong, 0) end
        for _, name in ipairs({ "width", "height", "size", "light", "yaw", "pitch", "distance" }) do
            if options[name] ~= nil and type(options[name]) ~= "number" then error("Model: " .. name .. " is a number", 0) end
        end
        if options.spin ~= nil and options.spin ~= false and type(options.spin) ~= "number" then
            error("Model: spin is a number of degrees a second, or false", 0)
        end
        local look = nil
        if options.mesh ~= nil then
            local problem
            look, problem = read_look(options)
            if not look then error("Model: " .. problem, 0) end
        end
        start()

        local theme, host = style.theme, self.window
        local width = clamp(options.width or options.size or 240, 48, 1024)
        local height = clamp(options.height or options.size or width, 48, 1024)
        local stack = root.new("Overlay")
        local function fill(widget) return kit.slot(stack:AddChild(widget), { h = H.Fill, v = VA.Fill }) end
        local backdrop = options.backdrop
        if backdrop == true then backdrop = theme.card end
        if backdrop then fill(kit.box(style.to_color(backdrop), "round6")) end
        local image = kit.image(style.WHITE, nil, width, height)
        image:SetVisibility(V.Hidden)
        fill(image)
        local button = nil
        if options.turn ~= false then
            button = kit.button(nil, { flat = true, color = theme.clear, hover = theme.clear, press = theme.clear, padding = style.margin(0) })
            fill(button)
        end
        local reset = nil
        if options.reset ~= false and (button or options.zoom ~= false) then
            local reset_box, reset_button = kit.icon_button("rotate-ccw", { icon_size = 12 })
            reset_box:SetVisibility(V.Collapsed)
            kit.slot(stack:AddChild(reset_box), { h = H.Right, v = VA.Top, pad = style.margin(0, 4, 4, 0) })
            reset = { box = reset_box, button = reset_button }
        end
        local outer, catcher = kit.sized(stack, width, height), nil
        if options.zoom ~= false then
            -- the view takes the wheel while the mouse is over it: a box that scrolls sideways between two empty ends
            catcher = root.new("ScrollBox")
            catcher.bAllowRightClickDragScrolling = false
            catcher:SetOrientation(0)
            catcher:SetConsumeMouseWheel(1)
            catcher:SetAnimateWheelScrolling(false)
            catcher:SetAllowOverscroll(false)
            catcher:SetScrollbarVisibility(V.Collapsed)
            for _, edge in ipairs({ "TopShadowBrush", "BottomShadowBrush", "LeftShadowBrush", "RightShadowBrush" }) do
                style.paint(catcher.WidgetStyle[edge], theme.clear)
            end
            local strip = root.new("HorizontalBox")
            strip:AddChild(kit.sized(nil, model.ROOM, 1))
            strip:AddChild(outer)
            strip:AddChild(kit.sized(nil, model.ROOM, 1))
            catcher:AddChild(strip)
            catcher:SetScrollOffset(model.ROOM)
            outer = kit.sized(catcher, width, height)
        end
        local sides = { left = H.Left, center = H.Center, right = H.Right }
        place_in(self, outer, { h = sides[options.align] or H.Center, snug = true })

        local control = new_control(self, outer)
        control.source = button
        control.Loaded = sched.Signal.new("Loaded")
        control.Failed = sched.Signal.new("Failed")
        control.Turned = sched.Signal.new("Turned")
        control.Clicked = sched.Signal.new("Clicked")
        local page = self
        while page and not rawget(page, "holder") do page = rawget(page, "parent") end
        if not page and host.nav then page = host.page end

        local view = { control = control, host = host, page = page, maker = scope.current(), width = width, height = height,
            image = image, button = button, catcher = catcher, reset = reset and reset.box, look = look, pictured = false,
            state = look and "waiting" or "empty", dirty = 0, touched = false, hidden = false, loaded = false, fresh = look ~= nil,
            light = clamp(options.light or 1, 0, 4), spin = clamp(options.spin == false and 0 or options.spin or model.SPIN, -90, 90) }
        view.home_yaw = turn(options.yaw or model.YAW)
        view.home_pitch = clamp(options.pitch or model.PITCH, -model.BELOW, model.ABOVE)
        view.home_zoom = clamp(options.distance or 1, model.NEAR, model.FAR)
        view.front = 180 - (look and look.facing or -90)
        home(view)
        if button then listen(control, button, "OnPressed", function() pressed(view) end) end
        if reset then
            listen(control, reset.button, "OnClicked", function()
                home(view)
                tell_view(view)
            end)
        end
        -- whatever takes the control away takes its actor out of the world at that moment
        control.disconnects[#control.disconnects + 1] = function() drop(view) end

        local set_visible = control.SetVisible
        function control:SetVisible(shown)
            view.hidden = not shown
            return set_visible(self, shown)
        end

        -- Shows another model in the same box. The view goes back to where it starts, unless the first mesh is the one
        -- that shows: the same body with something else on it is seen from where the player left it.
        function control:Show(given)
            if type(given) ~= "table" then
                error("Show expects a table such as { mesh = \"/Game/ASS/CRE/Deer/SK_CRE_PAS_Deer\" }, or what game.Creatures:GetModel gives", 2)
            end
            local wrong_key = unknown_key(given, LOOK_KEYS, "Show")
            if wrong_key then error(wrong_key, 2) end
            local next_look, problem = read_look(given)
            if not next_look then error("Show: " .. problem, 2) end
            local same = view.look ~= nil and view.look.mesh == next_look.mesh and view.look.facing == next_look.facing
            destroy_rig(view)
            view.look, view.state, view.queue, view.anim_due = next_look, "waiting", nil, nil
            view.loaded, view.fresh = false, true
            view.front = 180 - next_look.facing
            if same then view.hold = nil else home(view) end
        end

        -- Empties the box.
        function control:Clear()
            destroy_rig(view)
            view.look, view.state, view.queue = nil, "empty", nil
            view.loaded, view.fresh = false, false
            hide_picture(view)
        end

        -- Degrees round the model (0 looks at its front), degrees above it, and how far (1 fills the box).
        function control:GetView() return turn(view.yaw), view.pitch, view.zoom end

        -- Puts the camera somewhere. What is left out stays. The slow turn stops.
        function control:SetView(yaw, pitch, distance)
            for name, value in pairs({ yaw = yaw, pitch = pitch, distance = distance }) do
                if type(value) ~= "number" or value ~= value then error("SetView: " .. name .. " is a number", 2) end
            end
            view.yaw = yaw and turn(yaw) or view.yaw
            view.pitch = pitch and clamp(pitch, -model.BELOW, model.ABOVE) or view.pitch
            view.zoom = distance and clamp(distance, model.NEAR, model.FAR) or view.zoom
            view.auto, view.hold = false, nil
            touched(view, true)
        end

        -- The view it started with, and the slow turn again.
        function control:Reset() home(view) end

        -- "walk", "idle", "blueprint", the game path of an animation, or false to stand still. speed is for "blueprint".
        function control:SetAnimation(animation, speed)
            if animation == nil then error("SetAnimation expects \"walk\", \"idle\", \"blueprint\", the game path of an animation or false", 2) end
            local wanted, problem = animation_of(animation)
            if problem then error("SetAnimation: " .. problem, 2) end
            if speed ~= nil and (type(speed) ~= "number" or speed ~= speed) then error("SetAnimation: speed is a number", 2) end
            if not view.look then return end
            view.look.animation = wanted
            if speed then view.look.speed = clamp(speed, 0, 1000) end
            view.anim_due = true
        end

        -- Puts a shape from game.Assets:Mesh or game.Assets:Model on a socket or a bone of the model that shows.
        -- options: socket, at, turn, scale, material. It goes when another model is shown.
        function control:Attach(shape, options)
            if type(shape) ~= "table" or type(shape.Apply) ~= "function" then
                error("Attach expects a shape from game.Assets:Mesh or game.Assets:Model", 2)
            end
            options = options or {}
            if type(options) ~= "table" then error("Attach: the options are a table such as { socket = \"R_prop_00\" }", 2) end
            local rig = view.rig
            if not (view.loaded and rig and rig.part) then error("Attach: the model is not in the picture yet. Wait for Loaded", 2) end
            local at, turn_by = options.at or {}, options.turn or {}
            local actor = rig.part:GetOwner()
            local spot = place(0, 0, 0)
            local part = actor:AddComponentByClass(class("/Script/ProceduralMeshComponent.ProceduralMeshComponent"), true, spot, true)
            part:SetMobility(2)
            actor:FinishAddComponent(part, true, spot)
            -- on the posed copy when one stands in for the model, so that it goes along with an animation that plays
            local holder = Wax.import("world.animations").copy_of(rig.part) or rig.part
            part:K2_AttachToComponent(holder, FName(options.socket or "None"), 2, 2, 2, false)
            part:K2_SetRelativeLocation({ X = at.X or at[1] or 0, Y = at.Y or at[2] or 0, Z = at.Z or at[3] or 0 }, false, {}, false)
            part:K2_SetRelativeRotation({ Pitch = turn_by.Pitch or 0, Yaw = turn_by.Yaw or 0, Roll = turn_by.Roll or 0 }, false, {}, false)
            local size = options.scale or 1
            part:SetRelativeScale3D({ X = size, Y = size, Z = size })
            shape:Apply(Wax.import("engine.instance").wrap(part), options.material and { material = options.material } or nil)
            quiet(part)
            rig.capture:ShowOnlyComponent(part)
        end

        -- Plays an animation from game.Animations:Define on the model that shows, and gives the play.
        function control:Play(animation, options)
            if type(animation) ~= "table" or type(animation.Play) ~= "function" then
                error("Play expects an animation from game.Animations:Define", 2)
            end
            local rig = view.rig
            if not (view.loaded and rig and rig.part) then error("Play: the model is not in the picture yet. Wait for Loaded", 2) end
            local play = animation:Play(Wax.import("engine.instance").wrap(rig.part), options)
            -- the picture only draws what it was told of, so the posed copy is added to it
            local animations = Wax.import("world.animations")
            animations.set_facing(rig.part, view.look and view.look.facing or 0)
            local copy = animations.copy_of(rig.part)
            if copy and rig.posed ~= copy:GetAddress() then
                rig.capture:ShowOnlyComponent(copy)
                rig.posed = copy:GetAddress()
            end
            rig.playing = true
            return play
        end

        -- True once the model is in the picture.
        function control:IsLoaded() return view.loaded end

        views[#views + 1] = view
        return control
    end
end

-- The interface was rebuilt: no widget kept here may be touched again. The actors are still in the world and are taken out.
function model.forget_all()
    for index = #views, 1, -1 do
        drop(views[index])
        views[index] = nil
    end
end

model.stop = model.forget_all

function model.stats()
    local rigs, loading = 0, 0
    for _, view in ipairs(views) do
        if view.rig then rigs = rigs + 1 end
        if view.state == "loading" or view.state == "waiting" then loading = loading + 1 end
    end
    local taken = 0
    for _ in pairs(by_address) do taken = taken + 1 end
    return { views = #views, actors = rigs, tracked = taken, waiting = loading, built = stats.built, destroyed = stats.destroyed,
        ended = stats.ended, swept = stats.swept, loads = stats.loads, failures = stats.failures, pictures = stats.pictures,
        frames = stats.steps, step_us = stats.steps > 0 and stats.seconds / stats.steps * 1e6 or 0, worst_us = stats.worst * 1e6 }
end

return model
