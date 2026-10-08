-- game.Effects and game.Sounds: the game's particle effects, lights, trails, camera shakes and sounds, on anything

local Wax = ...
local instance = Wax.import("engine.instance")
local scope = Wax.import("core.scope")
local suggest = Wax.import("core.suggest")
local perf = Wax.import("core.perf")
local log = Wax.import("core.log").channel("wax.effects")

local M = {}

M.SECONDS = 3               -- how long particles and a light stay when nothing is said
M.MOST = 64                 -- effects alive at once, for all mods
M.TRAIL_POINTS = 14
M.TRAIL_JUMP = 150          -- further than this in one frame is a jump, not a movement
M.SHAKE = "/Game/BP/CameraShake/Creatures/CS_Mammoth_Footstep.CS_Mammoth_Footstep_C"
M.GLOW = "/Engine/EngineMaterials/EmissiveMeshMaterial"

local IDENTITY = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
local NAMED = {
    red = { 1, 0.05, 0.05 }, orange = { 1, 0.4, 0 }, yellow = { 1, 1, 0 }, green = { 0, 1, 0.35 }, cyan = { 0, 1, 1 },
    blue = { 0, 0.53, 1 }, purple = { 0.55, 0.2, 1 }, magenta = { 1, 0, 1 }, pink = { 1, 0.35, 0.65 },
    white = { 1, 1, 1 }, grey = { 0.5, 0.5, 0.5 }, gray = { 0.5, 0.5, 0.5 },
}
local COLORS = { "Red", "Orange", "Yellow", "Green", "Cyan", "Blue", "Purple", "Magenta", "Pink", "White", "Grey" }
local PARTICLE_OPTIONS = { "on", "socket", "at", "turn", "seconds", "set" }
local LIGHT_OPTIONS = { "on", "socket", "at", "color", "intensity", "radius", "seconds", "fade" }
local TRAIL_OPTIONS = { "from", "to", "color", "seconds", "life" }
local SOUND_OPTIONS = { "on", "socket", "at" }

local Effects, Sounds = {}, {}
local members, sound_members = {}, {}
local live = {}             -- effects that have to be stepped or taken away
local engine = nil
local last = nil
local connection = nil
local stats = { made = 0 }

local function first_line(problem) return (tostring(problem):match("^[^\r\n]*")) end

local function describe(value)
    if type(value) == "string" then return ("the string \"%s\""):format(value) end
    return type(value) == "nil" and "nothing" or ("a " .. type(value))
end

local function finite(value) return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge end

local function known_keys(options, names, what, level)
    for key in pairs(options) do
        local found = false
        for index = 1, #names do found = found or names[index] == key end
        if not found then
            error(("%s has no option named %s.%s"):format(what, tostring(key), type(key) == "string" and suggest.phrase(key, names) or ""), level + 1)
        end
    end
end

local function options_of(options, names, what, level)
    if options == nil then return {} end
    if type(options) ~= "table" then error(("%s: the options are a table"):format(what), level + 1) end
    known_keys(options, names, what, level + 1)
    return options
end

local function color_of(color, what, level)
    if color == nil then return 1, 0.05, 0.05 end
    if type(color) == "string" then
        local named = NAMED[color:lower()]
        if named then return named[1], named[2], named[3] end
        local r, g, b = color:match("^#?(%x%x)(%x%x)(%x%x)$")
        if r then return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255 end
        error(("%s: '%s' is not a colour.%s Use a name, \"#rrggbb\" or { R = 1, G = 0.5, B = 0 }"):format(what, color,
            suggest.phrase(color, COLORS)), level + 1)
    end
    if type(color) == "table" then
        local r, g, b = color.R or color[1], color.G or color[2], color.B or color[3]
        if finite(r) and finite(g) and finite(b) then return r, g, b end
    end
    error(("%s: a colour is a name, \"#rrggbb\" or { R = 1, G = 0.5, B = 0 }, got %s"):format(what, describe(color)), level + 1)
end

local function three(value, what, level)
    if value == nil then return 0, 0, 0 end
    if type(value) == "table" then
        local x, y, z = value.X or value[1], value.Y or value[2], value.Z or value[3]
        if finite(x) and finite(y) and finite(z) then return x, y, z end
    end
    error(("%s is three numbers: { X = 0, Y = 0, Z = 0 } or { 0, 0, 0 }"):format(what), level + 1)
end

local function engine_now()
    if engine and engine.math:IsValid() then return engine end
    engine = {
        math = StaticFindObject("/Script/Engine.Default__KismetMathLibrary"),
        statics = StaticFindObject("/Script/Engine.Default__GameplayStatics"),
        niagara = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary"),
        fmod = StaticFindObject("/Script/FMODStudio.Default__FMODBlueprintStatics"),
        light = StaticFindObject("/Script/Engine.PointLightComponent"),
        mesh = StaticFindObject("/Script/ProceduralMeshComponent.ProceduralMeshComponent"),
    }
    return engine
end

local function assets_now(level)
    local assets = Wax.game and Wax.game.Assets
    if not assets then error("game.Assets is not there, so nothing can be loaded", level + 1) end
    return assets
end

-- The part of a target that an effect hangs on. The player's own character gives the arms or the body, whichever shows.
local function part_of(target, what, level)
    local game = Wax.game
    if target == nil then target = game and game.Me end
    local inst = nil
    if instance.is_instance(target) then
        inst = target
    elseif type(target) == "table" or type(target) == "userdata" then
        local ok, actor = pcall(function() return target.Actor end)
        if ok and instance.is_instance(actor) then
            inst = actor
        else
            local fine, raw = pcall(function() return target.Raw end)
            if fine and raw ~= nil then inst = instance.wrap(raw) end
        end
    end
    if not inst then
        error(("%s: on is what the effect hangs on: a character, a creature, a thing of a blueprint or a part. Got %s"):format(what,
            describe(target)), level + 1)
    end
    local raw = inst.Raw
    if inst:IsA("SceneComponent") then return raw end
    local me = game and game.Me
    if me and me.Exists and me.Raw:GetAddress() == raw:GetAddress() then
        local third = game.LocalPlayer.Raw:GetIsThirdPerson() == true
        return third and raw:GetThirdPersonMesh() or raw:GetFirstPersonMesh()
    end
    if inst:IsA("Character") then
        local mesh = raw.Mesh
        if mesh:IsValid() then return mesh end
    end
    local root = raw.RootComponent
    if root == nil or not root:IsValid() then error(("%s: what was given has no place an effect could hang on"):format(what), level + 1) end
    return root
end

local function add_live(entry)
    local count = 0
    for _ in pairs(live) do count = count + 1 end
    if count >= M.MOST then
        local oldest
        for other in pairs(live) do
            if not oldest or other.born < oldest.born then oldest = other end
        end
        if oldest then oldest.stop(true) end
    end
    entry.born = perf.now()
    entry.owner = scope.current()
    if entry.owner then entry.slot = entry.owner:add(function() entry.stop(true) end) end
    live[entry] = true
    stats.made = stats.made + 1
end

local function remove_live(entry)
    if not live[entry] then return false end
    live[entry] = nil
    if entry.owner and entry.slot then entry.owner:remove(entry.slot) end
    return true
end

local function destroy(component)
    pcall(function()
        local raw = component.Raw
        raw:K2_DestroyComponent(raw)
    end)
end

-- ---------------------------------------------------------------- particles

-- Particles(path, { on = , socket = , at = , turn = , seconds = , set = { name = value } })
function members:Particles(path, options)
    if self ~= Effects then error("call Particles with a colon: game.Effects:Particles(path, options)", 2) end
    if type(path) ~= "string" then error("game.Effects:Particles expects the path of a particle effect of the game, got " .. describe(path), 2) end
    options = options_of(options, PARTICLE_OPTIONS, "game.Effects:Particles", 2)
    local seconds = options.seconds == nil and M.SECONDS or options.seconds
    if seconds ~= false and (not finite(seconds) or seconds <= 0) then
        error("game.Effects:Particles: seconds is how long it stays, or false for until it is stopped", 2)
    end
    local asset = assets_now(2):Load(path)
    local part = part_of(options.on, "game.Effects:Particles", 2)
    local x, y, z = three(options.at, "game.Effects:Particles: at", 2)
    local turn = options.turn or {}
    local e = engine_now()
    local socket = FName(options.socket or "None")
    local place, facing = { X = x, Y = y, Z = z }, { Pitch = turn.Pitch or 0, Yaw = turn.Yaw or 0, Roll = turn.Roll or 0 }
    local made, niagara
    if asset:IsA("NiagaraSystem") then
        made, niagara = e.niagara:SpawnSystemAttached(asset.Raw, part, socket, place, facing, 0, false, true, 0, true), true
    elseif asset:IsA("ParticleSystem") then
        made = e.statics:SpawnEmitterAttached(asset.Raw, part, socket, place, facing, { X = 1, Y = 1, Z = 1 }, 0, false, 0, true)
    else
        error(("game.Effects:Particles: %s is a %s, not a particle effect"):format(path, tostring(asset.ClassName)), 2)
    end
    if made == nil or not made:IsValid() then error("game.Effects:Particles: the game did not start " .. path, 2) end
    local component = instance.wrap(made)
    local entry = { ends = seconds and seconds or nil }
    local handle = {}
    function handle:Set(name, value)
        if type(name) ~= "string" then error("Set expects the name of a parameter of the effect", 2) end
        local raw = component.Raw
        if type(value) == "number" then
            if niagara then raw:SetNiagaraVariableFloat(name, value) else raw:SetFloatParameter(FName(name), value) end
        elseif type(value) == "table" and (value.X or (value[1] and not value.R)) and not value.R then
            local vx, vy, vz = three(value, "Set: " .. name, 2)
            if niagara then raw:SetNiagaraVariableVec3(name, { X = vx, Y = vy, Z = vz }) else raw:SetVectorParameter(FName(name), { X = vx, Y = vy, Z = vz }) end
        else
            local r, g, b = color_of(value, "Set: " .. name, 2)
            local color = { R = r, G = g, B = b, A = 1 }
            if niagara then raw:SetNiagaraVariableLinearColor(name, color) else raw:SetColorParameter(FName(name), color) end
        end
        return handle
    end
    function handle:Stop() entry.stop(true) end
    function handle:IsAlive() return live[entry] == true end
    entry.stop = function() if remove_live(entry) then destroy(component) end end
    add_live(entry)
    for name, value in pairs(options.set or {}) do
        local ok, why = pcall(handle.Set, handle, name, value)
        if not ok then
            entry.stop(true)
            error("game.Effects:Particles: " .. first_line(why), 2)
        end
    end
    return handle
end

-- ---------------------------------------------------------------- light

-- Light({ on = , socket = , at = , color = , intensity = , radius = , seconds = , fade = })
function members:Light(options)
    if self ~= Effects then error("call Light with a colon: game.Effects:Light(options)", 2) end
    options = options_of(options, LIGHT_OPTIONS, "game.Effects:Light", 2)
    local seconds = options.seconds == nil and M.SECONDS or options.seconds
    if seconds ~= false and (not finite(seconds) or seconds <= 0) then
        error("game.Effects:Light: seconds is how long it stays, or false for until it is stopped", 2)
    end
    local part = part_of(options.on, "game.Effects:Light", 2)
    local r, g, b = color_of(options.color, "game.Effects:Light", 2)
    local x, y, z = three(options.at, "game.Effects:Light: at", 2)
    local intensity, radius = options.intensity or 5000, options.radius or 400
    if not finite(intensity) or not finite(radius) then error("game.Effects:Light: intensity and radius are numbers", 2) end
    local e = engine_now()
    local owner = part:GetOwner()
    local made = owner:AddComponentByClass(e.light, true, IDENTITY, true)
    if not made:IsValid() then error("game.Effects:Light: the game did not make a light", 2) end
    made:SetMobility(2)
    owner:FinishAddComponent(made, true, IDENTITY)
    made:K2_AttachToComponent(part, FName(options.socket or "None"), 2, 2, 2, false)
    made:K2_SetRelativeLocation({ X = x, Y = y, Z = z }, false, {}, false)
    made:SetLightColor({ R = r, G = g, B = b, A = 1 }, true)
    made:SetAttenuationRadius(radius)
    made:SetCastShadows(false)
    made:SetIntensity(intensity)
    local component = instance.wrap(made)
    local fade = options.fade or 0
    local entry = { ends = seconds and seconds or nil }
    if fade > 0 and seconds then
        entry.step = function(age)
            local left = seconds - age
            if left < fade then component.Raw:SetIntensity(intensity * math.max(0, left / fade)) end
        end
    end
    local handle = {}
    function handle:Stop() entry.stop(true) end
    function handle:IsAlive() return live[entry] == true end
    function handle:SetColor(color)
        local nr, ng, nb = color_of(color, "SetColor", 2)
        component.Raw:SetLightColor({ R = nr, G = ng, B = nb, A = 1 }, true)
    end
    function handle:SetIntensity(value)
        if not finite(value) then error("SetIntensity expects a number", 2) end
        intensity = value
        component.Raw:SetIntensity(value)
    end
    entry.stop = function() if remove_live(entry) then destroy(component) end end
    add_live(entry)
    return handle
end

-- ---------------------------------------------------------------- trail

-- Trail(on, { from = , to = , color = , seconds = , life = }): a glowing ribbon left behind by an edge that moves.
function members:Trail(on, options)
    if self ~= Effects then error("call Trail with a colon: game.Effects:Trail(on, options)", 2) end
    options = options_of(options, TRAIL_OPTIONS, "game.Effects:Trail", 2)
    local part = part_of(on, "game.Effects:Trail", 2)
    local ax, ay, az = three(options.from, "game.Effects:Trail: from", 2)
    local bx, by, bz = three(options.to or { 0, 0, 50 }, "game.Effects:Trail: to", 2)
    local seconds = options.seconds or 0.25
    if not finite(seconds) or seconds <= 0 then error("game.Effects:Trail: seconds is how long the ribbon is, in time", 2) end
    if options.life ~= nil and (not finite(options.life) or options.life <= 0) then error("game.Effects:Trail: life is how long it runs", 2) end
    local material = assets_now(2):Material(M.GLOW, { colors = { Color = options.color or "Red" } })
    local e = engine_now()
    local owner = part:GetOwner()
    local made = owner:AddComponentByClass(e.mesh, true, IDENTITY, true)
    if not made:IsValid() then error("game.Effects:Trail: the game did not make the ribbon", 2) end
    made:SetMobility(2)
    owner:FinishAddComponent(made, true, IDENTITY)
    made:SetCollisionEnabled(0)
    made:SetCastShadow(false)
    local ribbon, edge = instance.wrap(made), instance.wrap(part)
    local points, feeding, drawn = {}, true, false
    local from, to = { X = ax, Y = ay, Z = az }, { X = bx, Y = by, Z = bz }
    local entry = { ends = options.life }
    entry.step = function(age)
        local raw = ribbon.Raw
        local now = perf.now()
        if feeding then
            local world = edge.Raw:K2_GetComponentToWorld()
            local a, b = e.math:TransformLocation(world, from), e.math:TransformLocation(world, to)
            -- what it follows was moved somewhere else at once: the ribbon starts over, or it would stretch across the jump
            local before = points[#points]
            if before and (a.X - before.a.X) ^ 2 + (a.Y - before.a.Y) ^ 2 + (a.Z - before.a.Z) ^ 2 > M.TRAIL_JUMP ^ 2 then points = {} end
            points[#points + 1] = { at = now, a = { X = a.X, Y = a.Y, Z = a.Z }, b = { X = b.X, Y = b.Y, Z = b.Z } }
        end
        while points[1] and (now - points[1].at > seconds or #points > M.TRAIL_POINTS) do table.remove(points, 1) end
        if #points < 2 then
            if drawn then raw:ClearMeshSection(0) end
            drawn = false
            if not feeding then entry.stop(true) end
            return
        end
        local vertices, normals, triangles = {}, {}, {}
        local count = #points
        for index = 1, count do
            local point = points[index]
            -- the ribbon narrows toward its old end
            local keep = index / count
            local mx, my, mz = (point.a.X + point.b.X) / 2, (point.a.Y + point.b.Y) / 2, (point.a.Z + point.b.Z) / 2
            vertices[#vertices + 1] = { X = mx + (point.a.X - mx) * keep, Y = my + (point.a.Y - my) * keep, Z = mz + (point.a.Z - mz) * keep }
            vertices[#vertices + 1] = { X = mx + (point.b.X - mx) * keep, Y = my + (point.b.Y - my) * keep, Z = mz + (point.b.Z - mz) * keep }
            normals[#normals + 1], normals[#normals + 2] = { X = 0, Y = 0, Z = 1 }, { X = 0, Y = 0, Z = 1 }
            if index > 1 then
                local base = (index - 2) * 2
                local list = { base, base + 1, base + 2, base + 1, base + 3, base + 2, base, base + 2, base + 1, base + 1, base + 2, base + 3 }
                for t = 1, #list do triangles[#triangles + 1] = list[t] end
            end
        end
        raw:CreateMeshSection_LinearColor(0, vertices, triangles, normals, {}, {}, {}, {}, {}, {}, false)
        if not drawn then raw:SetMaterial(0, material.Raw) end
        drawn = true
    end
    local handle = {}
    function handle:Stop() feeding = false end
    function handle:IsAlive() return live[entry] == true end
    entry.stop = function(now)
        if not now and feeding then
            -- its time is up: it stops growing and what is left runs out
            feeding, entry.ends = false, nil
            return
        end
        if remove_live(entry) then destroy(ribbon) end
    end
    add_live(entry)
    return handle
end

-- ---------------------------------------------------------------- shake

-- Shake(scale, path): shakes the player's view with one of the game's camera shakes.
function members:Shake(scale, path)
    if self ~= Effects then error("call Shake with a colon: game.Effects:Shake(scale)", 2) end
    scale = scale == nil and 1 or scale
    if not finite(scale) or scale < 0 then error("game.Effects:Shake: scale is how strong, 1 for the shake as the game made it", 2) end
    if path ~= nil and type(path) ~= "string" then error("game.Effects:Shake: the second value is the path of a camera shake of the game", 2) end
    local player = Wax.game and Wax.game.LocalPlayer
    if not player then return false end
    local class = assets_now(2):Load(path or M.SHAKE)
    player.Raw:ClientStartCameraShake(class.Raw, scale, 0, { Pitch = 0, Yaw = 0, Roll = 0 })
    return true
end

function members:Find(text)
    if self ~= Effects then error("call Find with a colon: game.Effects:Find(text)", 2) end
    return Wax.import("world.media").find("particles", text, "game.Effects:Find")
end

function members:FindShakes(text)
    if self ~= Effects then error("call FindShakes with a colon: game.Effects:FindShakes(text)", 2) end
    return Wax.import("world.media").find("shakes", text or "", "game.Effects:FindShakes")
end

-- ---------------------------------------------------------------- sounds

-- Play(path, { on = , socket = , at = }): one of the game's sounds. With nothing to play it on, it is heard everywhere.
function sound_members:Play(path, options)
    if self ~= Sounds then error("call Play with a colon: game.Sounds:Play(path)", 2) end
    if type(path) ~= "string" then error("game.Sounds:Play expects the path of a sound of the game, got " .. describe(path), 2) end
    options = options_of(options, SOUND_OPTIONS, "game.Sounds:Play", 2)
    local event = assets_now(2):Load(path)
    if not event:IsA("FMODEvent") then
        error(("game.Sounds:Play: %s is a %s, not a sound of the game"):format(path, tostring(event.ClassName)), 2)
    end
    local e = engine_now()
    if options.on == nil then
        local world = Wax.game and Wax.game.World
        if not world then return false end
        e.fmod:PlayEvent2D(world.Raw, event.Raw, true)
        return true
    end
    local part = part_of(options.on, "game.Sounds:Play", 2)
    local x, y, z = three(options.at, "game.Sounds:Play: at", 2)
    e.fmod:PlayEventAttached(event.Raw, part, FName(options.socket or "None"), { X = x, Y = y, Z = z }, 0, true, true, true)
    return true
end

function sound_members:Find(text)
    if self ~= Sounds then error("call Find with a colon: game.Sounds:Find(text)", 2) end
    return Wax.import("world.media").find("sounds", text, "game.Sounds:Find")
end

-- ----------------------------------------------------------------

function M.step()
    if next(live) == nil then
        last = nil
        return
    end
    local now = perf.now()
    last = now
    local over = nil
    for entry in pairs(live) do
        local age = now - entry.born
        if entry.step then
            local ok, why = pcall(entry.step, age)
            if not ok then
                log:warn("an effect was let go: %s", first_line(why))
                over = over or {}
                over[#over + 1] = { entry, true }
            end
        end
        if entry.ends and age >= entry.ends then
            over = over or {}
            over[#over + 1] = { entry, false }
        end
    end
    for index = 1, #(over or {}) do
        if live[over[index][1]] then over[index][1].stop(over[index][2]) end
    end
end

local function guarded(name, table_of_members)
    return {
        __index = table_of_members,
        __newindex = function(_, key) error(("%s.%s cannot be assigned"):format(name, tostring(key)), 2) end,
        __tostring = function() return name end,
    }
end
setmetatable(Effects, guarded("game.Effects", members))
setmetatable(Sounds, guarded("game.Sounds", sound_members))

local function on_map_change()
    for entry in pairs(live) do
        if entry.owner and entry.slot then entry.owner:remove(entry.slot) end
    end
    live, engine, last = {}, nil, nil
end

function M.stats()
    local count = 0
    for _ in pairs(live) do count = count + 1 end
    return { alive = count, made = stats.made }
end

function M.start()
    local root = Wax.import("engine.game").root
    rawset(root, "Effects", Effects)
    rawset(root, "Sounds", Sounds)
    if connection then connection:Disconnect() end
    connection = root.MapChanged:Connect(on_map_change)
end

function M.stop()
    for entry in pairs(live) do entry.stop(true) end
    live = {}
    if connection then connection:Disconnect() end
    connection = nil
    local root = Wax.import("engine.game").root
    if rawget(root, "Effects") == Effects then rawset(root, "Effects", nil) end
    if rawget(root, "Sounds") == Sounds then rawset(root, "Sounds", nil) end
end

M.api, M.sounds = Effects, Sounds
return M
