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
M.TRAIL_SMOOTH = 3          -- pieces the ribbon is cut into between two frames, on a curve
M.EMBERS = 60               -- bits one trail has at a time, at most
M.EMBER_RATE = 240
M.TRAIL_TAPER = 2.2          -- higher keeps the ribbon thin for longer before it widens to the edge
M.TRAIL_NEAR = 70           -- a streak nearer the eye than this looks no wider than it would from here
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
local TRAIL_OPTIONS = { "from", "to", "color", "seconds", "life", "material", "width", "with_view", "embers", "delay" }
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

-- A curve through four values that passes through the middle two: where it is `t` of the way from b to c.
local function curve(a, b, c, d, t)
    local t2, t3 = t * t, t * t * t
    return 0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (3 * b - a - 3 * c + d) * t3)
end

-- Trail(on, { from = , to = , color = , seconds = , life = , width = , with_view = , material = , embers = }): a glowing
-- ribbon left behind by an edge that moves, and small glowing bits that come off it.
function members:Trail(on, options)
    if self ~= Effects then error("call Trail with a colon: game.Effects:Trail(on, options)", 2) end
    options = options_of(options, TRAIL_OPTIONS, "game.Effects:Trail", 2)
    local part = part_of(on, "game.Effects:Trail", 2)
    local ax, ay, az = three(options.from, "game.Effects:Trail: from", 2)
    local bx, by, bz = three(options.to or { 0, 0, 50 }, "game.Effects:Trail: to", 2)
    local seconds = options.seconds or 0.25
    if not finite(seconds) or seconds <= 0 then error("game.Effects:Trail: seconds is how long the ribbon is, in time", 2) end
    if options.life ~= nil and (not finite(options.life) or options.life <= 0) then error("game.Effects:Trail: life is how long it runs", 2) end
    -- material: one of your own in place of the plain glowing one, for a ribbon that has to look like what it follows
    local material = options.material
    if material ~= nil then
        if not instance.is_instance(material) or not material:IsA("MaterialInterface") then
            error("game.Effects:Trail: material is a material from game.Assets:Material or game.Assets:Load", 2)
        end
    else
        material = assets_now(2):Material(M.GLOW, { colors = { Color = options.color or "Red" } })
    end
    -- width: a streak this wide along the middle of the edge, always turned to face the view, in place of the flat
    -- ribbon between the edge's two ends (which is seen from its side, as a line, when a cut comes straight down).
    local width = options.width
    if width ~= nil and (not finite(width) or width <= 0) then error("game.Effects:Trail: width is how wide the streak is", 2) end
    -- with_view: the trail stays with the view, as the arms of first person do, instead of staying behind in the world
    local with_view = options.with_view == true
    if options.with_view ~= nil and type(options.with_view) ~= "boolean" then error("game.Effects:Trail: with_view is true or false", 2) end
    -- embers: how many small bits come off the edge a second, or { rate = , size = , life = , speed = , rise = }
    local embers = options.embers
    if type(embers) == "number" then embers = { rate = embers } end
    if embers ~= nil then
        if type(embers) ~= "table" then error("game.Effects:Trail: embers is how many a second, or a table with rate, size, life, speed and rise", 2) end
        embers = { rate = embers.rate or 60, size = embers.size or 2.5, life = embers.life or 0.45, speed = embers.speed or 40, rise = embers.rise or 25 }
        for name, value in pairs(embers) do
            if not finite(value) or value < 0 then error("game.Effects:Trail: embers." .. name .. " is a number", 2) end
        end
        if embers.rate > M.EMBER_RATE then embers.rate = M.EMBER_RATE end
    end
    -- delay: it starts this long from now: a swing winds up first, and the trail belongs to the cut
    local delay = options.delay or 0
    if not finite(delay) or delay < 0 then error("game.Effects:Trail: delay is how long from now it starts, in seconds", 2) end
    local starts = perf.now() + delay
    local needs_view = width ~= nil or with_view or embers ~= nil
    local e = engine_now()
    local owner = part:GetOwner()
    local made = owner:AddComponentByClass(e.mesh, true, IDENTITY, true)
    if not made:IsValid() then error("game.Effects:Trail: the game did not make the ribbon", 2) end
    made:SetMobility(2)
    owner:FinishAddComponent(made, true, IDENTITY)
    made:SetCollisionEnabled(0)
    made:SetCastShadow(false)
    local ribbon, edge = instance.wrap(made), instance.wrap(part)
    local points, bits, feeding, drawn, owed, last = {}, {}, true, false, 0, nil
    local from, to = { X = ax, Y = ay, Z = az }, { X = bx, Y = by, Z = bz }
    local entry = { ends = options.life and options.life + delay or nil }
    entry.step = function(age)
        local raw = ribbon.Raw
        local now = perf.now()
        if now < starts then return end
        local passed = last and math.min(now - last, 0.1) or 0
        last = now
        -- where the view is and which way it looks: forward, right and up
        local cx, cy, cz, fx, fy, fz, rx, ry, rz, ux, uy, uz
        if needs_view then
            local manager = e.statics:GetPlayerCameraManager(owner, 0)
            local at, turn = manager:GetCameraLocation(), manager:GetCameraRotation()
            local f, r, u = e.math:GetForwardVector(turn), e.math:GetRightVector(turn), e.math:GetUpVector(turn)
            cx, cy, cz = at.X, at.Y, at.Z
            fx, fy, fz, rx, ry, rz, ux, uy, uz = f.X, f.Y, f.Z, r.X, r.Y, r.Z, u.X, u.Y, u.Z
        end
        if feeding then
            local world = edge.Raw:K2_GetComponentToWorld()
            local a, b = e.math:TransformLocation(world, from), e.math:TransformLocation(world, to)
            if with_view then
                -- kept as the view sees it: forward, right and up of the eye
                local dx, dy, dz = a.X - cx, a.Y - cy, a.Z - cz
                a = { X = dx * fx + dy * fy + dz * fz, Y = dx * rx + dy * ry + dz * rz, Z = dx * ux + dy * uy + dz * uz }
                dx, dy, dz = b.X - cx, b.Y - cy, b.Z - cz
                b = { X = dx * fx + dy * fy + dz * fz, Y = dx * rx + dy * ry + dz * rz, Z = dx * ux + dy * uy + dz * uz }
            end
            -- what it follows was moved somewhere else at once: the ribbon starts over, or it would stretch across the jump
            local before = points[#points]
            local jumped = before and (a.X - before.a.X) ^ 2 + (a.Y - before.a.Y) ^ 2 + (a.Z - before.a.Z) ^ 2 > M.TRAIL_JUMP ^ 2
            if jumped then points, before = {}, nil end
            points[#points + 1] = { at = now, a = { X = a.X, Y = a.Y, Z = a.Z }, b = { X = b.X, Y = b.Y, Z = b.Z } }
            if embers and before and passed > 0 then
                -- bits come off anywhere along the edge, the more the faster it moves, and keep a little of its speed
                local mx, my, mz = (b.X - before.b.X) / passed, (b.Y - before.b.Y) / passed, (b.Z - before.b.Z) / passed
                local fast = math.sqrt(mx * mx + my * my + mz * mz)
                owed = owed + embers.rate * passed * math.min(1, fast / 300)
                while owed >= 1 and #bits < M.EMBERS do
                    owed = owed - 1
                    local along, back = math.random(), math.random()
                    local spread = embers.speed
                    bits[#bits + 1] = {
                        born = now, life = embers.life * (0.6 + 0.8 * math.random()),
                        x = a.X + (b.X - a.X) * along - mx * passed * back,
                        y = a.Y + (b.Y - a.Y) * along - my * passed * back,
                        z = a.Z + (b.Z - a.Z) * along - mz * passed * back,
                        vx = mx * 0.12 + (math.random() - 0.5) * spread, vy = my * 0.12 + (math.random() - 0.5) * spread,
                        vz = mz * 0.12 + (math.random() - 0.5) * spread,
                    }
                end
                if owed > 1 then owed = 1 end
            end
        end
        while points[1] and (now - points[1].at > seconds or #points > M.TRAIL_POINTS) do table.remove(points, 1) end
        for index = #bits, 1, -1 do
            if now - bits[index].born >= bits[index].life then table.remove(bits, index) end
        end
        if #points < 2 and #bits == 0 then
            if drawn then raw:ClearMeshSection(0) end
            drawn = false
            if not feeding then entry.stop(true) end
            return
        end
        local vertices, normals, triangles = {}, {}, {}
        local count = #points
        if count >= 2 then
            -- the ends of the edge at each moment, in the world
            local known = {}
            for index = 1, count do
                local a, b = points[index].a, points[index].b
                if with_view then
                    known[index] = { cx + a.X * fx + a.Y * rx + a.Z * ux, cy + a.X * fy + a.Y * ry + a.Z * uy, cz + a.X * fz + a.Y * rz + a.Z * uz,
                                     cx + b.X * fx + b.Y * rx + b.Z * ux, cy + b.X * fy + b.Y * ry + b.Z * uy, cz + b.X * fz + b.Y * rz + b.Z * uz }
                else
                    known[index] = { a.X, a.Y, a.Z, b.X, b.Y, b.Z }
                end
            end
            -- A frame gives one place, and straight lines between frames show as corners. So a curve is laid through
            -- the places and the ribbon follows that.
            local ends = {}
            for index = 1, count - 1 do
                local p0, p1, p2, p3 = known[index - 1] or known[index], known[index], known[index + 1], known[index + 2] or known[index + 1]
                for step = 0, M.TRAIL_SMOOTH - 1 do
                    local t = step / M.TRAIL_SMOOTH
                    local one = {}
                    for n = 1, 6 do one[n] = curve(p0[n], p1[n], p2[n], p3[n], t) end
                    ends[#ends + 1] = one
                end
            end
            ends[#ends + 1] = known[count]
            local total = #ends
            local sx, sy, sz = 0, 0, 1
            for index = 1, total do
                local here = ends[index]
                -- the ribbon narrows toward its old end, slowly at first and to a point at the last
                local along = (index - 1) / (total - 1)
                local keep = math.sin(along * math.pi / 2) ^ M.TRAIL_TAPER
                local mx, my, mz = (here[1] + here[4]) / 2, (here[2] + here[5]) / 2, (here[3] + here[6]) / 2
                if width then
                    -- across the path and across the line of sight, so its flat side is what the eye gets
                    local before, after = ends[index - 1] or here, ends[index + 1] or here
                    local tx = (after[1] + after[4] - before[1] - before[4]) / 2
                    local ty = (after[2] + after[5] - before[2] - before[5]) / 2
                    local tz = (after[3] + after[6] - before[3] - before[6]) / 2
                    local vx, vy, vz = mx - cx, my - cy, mz - cz
                    local nx, ny, nz = ty * vz - tz * vy, tz * vx - tx * vz, tx * vy - ty * vx
                    local long = math.sqrt(nx * nx + ny * ny + nz * nz)
                    if long > 1e-4 then
                        nx, ny, nz = nx / long, ny / long, nz / long
                        if index > 1 and nx * sx + ny * sy + nz * sz < 0 then nx, ny, nz = -nx, -ny, -nz end
                        sx, sy, sz = nx, ny, nz
                    end
                    local far = math.sqrt(vx * vx + vy * vy + vz * vz)
                    local half = width / 2 * keep * math.min(1, far / M.TRAIL_NEAR)
                    vertices[#vertices + 1] = { X = mx + sx * half, Y = my + sy * half, Z = mz + sz * half }
                    vertices[#vertices + 1] = { X = mx - sx * half, Y = my - sy * half, Z = mz - sz * half }
                else
                    -- the outer end of the edge keeps its place and the inner end closes in on it: a crescent
                    vertices[#vertices + 1] = { X = here[4] + (here[1] - here[4]) * keep, Y = here[5] + (here[2] - here[5]) * keep, Z = here[6] + (here[3] - here[6]) * keep }
                    vertices[#vertices + 1] = { X = here[4], Y = here[5], Z = here[6] }
                end
                normals[#normals + 1], normals[#normals + 2] = { X = 0, Y = 0, Z = 1 }, { X = 0, Y = 0, Z = 1 }
                if index > 1 then
                    local base = (index - 2) * 2
                    local list = { base, base + 1, base + 2, base + 1, base + 3, base + 2, base, base + 2, base + 1, base + 1, base + 2, base + 3 }
                    for t = 1, #list do triangles[#triangles + 1] = list[t] end
                end
            end
        end
        -- each bit is a small square turned to the view, which drifts, rises and shrinks to nothing
        for index = 1, #bits do
            local bit = bits[index]
            bit.x, bit.y, bit.z = bit.x + bit.vx * passed, bit.y + bit.vy * passed, bit.z + bit.vz * passed
            local slow = 1 - math.min(1, 3 * passed)
            bit.vx, bit.vy, bit.vz = bit.vx * slow, bit.vy * slow, bit.vz * slow
            local old = (now - bit.born) / bit.life
            local wx, wy, wz = bit.x, bit.y, bit.z
            if with_view then
                bit.z = bit.z + embers.rise * passed
                wx, wy, wz = cx + bit.x * fx + bit.y * rx + bit.z * ux, cy + bit.x * fy + bit.y * ry + bit.z * uy, cz + bit.x * fz + bit.y * rz + bit.z * uz
            else
                bit.z = bit.z + embers.rise * passed
                wx, wy, wz = bit.x, bit.y, bit.z
            end
            local half = embers.size / 2 * (1 - old) ^ 0.7
            local base = #vertices
            -- a diamond, so no edge of it lines up with the screen
            vertices[base + 1] = { X = wx + rx * half, Y = wy + ry * half, Z = wz + rz * half }
            vertices[base + 2] = { X = wx + ux * half, Y = wy + uy * half, Z = wz + uz * half }
            vertices[base + 3] = { X = wx - rx * half, Y = wy - ry * half, Z = wz - rz * half }
            vertices[base + 4] = { X = wx - ux * half, Y = wy - uy * half, Z = wz - uz * half }
            for n = 1, 4 do normals[#normals + 1] = { X = 0, Y = 0, Z = 1 } end
            local list = { base, base + 1, base + 2, base, base + 2, base + 3, base, base + 2, base + 1, base, base + 3, base + 2 }
            for t = 1, #list do triangles[#triangles + 1] = list[t] end
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
