-- game.Animations: the game's own clips on anything with a skeleton, and animations written as keyframes in Lua

local Wax = ...
local instance = Wax.import("engine.instance")
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local suggest = Wax.import("core.suggest")
local perf = Wax.import("core.perf")
local log = Wax.import("core.log").channel("wax.animations")

local M = {}

M.RIG_IDLE = 10             -- seconds a posable copy is kept after its last animation
M.MAX_TRACKS = 64
M.MAX_KEYS = 256
M.SLOT = "DefaultSlot"      -- where a single sequence is played when no slot is named

local POSEABLE = "/Script/Engine.PoseableMeshComponent"
local COMPONENT_SPACE = 1
local KEEP_RELATIVE = 0
local SELF = "self"
local PLAY_OPTIONS = { "rate", "loop", "keep", "done", "weight" }
local CLIP_OPTIONS = { "rate", "blend", "start", "slot", "loops" }
local DEFINE_OPTIONS = { "length", "loop", "tracks", "third", "events", "ease" }
local KEYS = { "X", "Y", "Z", "Pitch", "Yaw", "Roll", "Scale" }
local EASES = { "linear", "smooth", "in", "out", "snap" }
-- Names that fit both of the player's skeletons: the arms seen in first person, then the body. Any other bone goes by its own name.
local ALIASES = {
    rightclavicle = { "bn_Arm_r_clav_1", "clavicle_r" }, rightshoulder = { "bn_Arm_r_shoulder_1", "upperarm_r" },
    rightelbow = { "bn_Arm_r_elbow_1", "lowerarm_r" }, rightwrist = { "bn_Arm_r_wrist_1", "hand_r" },
    righthand = { "bn_Prop_R_1", "R_prop_00" },
    leftclavicle = { "bn_Arm_l_clav_1", "clavicle_l" }, leftshoulder = { "bn_Arm_l_shoulder_1", "upperarm_l" },
    leftelbow = { "bn_Arm_l_elbow_1", "lowerarm_l" }, leftwrist = { "bn_Arm_l_wrist_1", "hand_l" },
    lefthand = { "bn_Prop_L_1", "L_prop_00" },
    head = { "Head" }, neck = { "neck_01" }, chest = { "spine_03" }, waist = { "spine_01" }, hips = { "Pelvis" },
    rightthigh = { "thigh_r" }, leftthigh = { "thigh_l" },
}
local IDENTITY = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }

local Animations = {}
local members = {}
local defined = {}          -- name (lower) -> animation
local plays = {}            -- everything that is playing, in the order it started
local rigs = {}             -- address of a skeleton's own mesh -> rig
local rig_count = 0
local poseable = nil
local last = nil
local connection = nil
local stats = { plays = 0, rigs = 0, bones = 0 }

local function first_line(problem) return (tostring(problem):match("^[^\r\n]*")) end

local function describe(value)
    if type(value) == "string" then return ("the string \"%s\""):format(value) end
    if type(value) == "table" then return "a table" end
    return type(value) == "nil" and "nothing" or ("a " .. type(value))
end

local function known_keys(options, names, what, level)
    for key in pairs(options) do
        local found = false
        for index = 1, #names do found = found or names[index] == key end
        if not found then
            error(("%s has no option named %s.%s"):format(what, tostring(key), type(key) == "string" and suggest.phrase(key, names) or ""), level + 1)
        end
    end
end

local function finite(value) return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge end

local EASE = {
    linear = function(t) return t end,
    smooth = function(t) return t * t * (3 - 2 * t) end,
    ["in"] = function(t) return t * t end,
    out = function(t) return 1 - (1 - t) * (1 - t) end,
    snap = function(t) return t < 1 and 0 or 1 end,
}

-- Keys as { time, values, ease } or { time = , ease = , Pitch = ... }, sorted by time. Returns the list the player reads.
local function read_keys(list, what, default_ease, level)
    if type(list) ~= "table" or #list == 0 then
        error(("%s is a list of keys such as { { 0, { Pitch = 0 } }, { 0.3, { Pitch = 40 } } }"):format(what), level + 1)
    end
    if #list > M.MAX_KEYS then error(("%s has more than %d keys"):format(what, M.MAX_KEYS), level + 1) end
    local keys = {}
    for index = 1, #list do
        local key = list[index]
        if type(key) ~= "table" then error(("%s: key %d is not a table"):format(what, index), level + 1) end
        local at, values, ease = key[1] or key.time, key[2] or key, key[3] or key.ease or default_ease
        if not finite(at) or at < 0 then error(("%s: key %d needs a time in seconds, 0 or more"):format(what, index), level + 1) end
        if type(values) ~= "table" then error(("%s: key %d needs its values, such as { Pitch = 40 }"):format(what, index), level + 1) end
        if not EASE[ease] then
            error(("%s: key %d: '%s' is not a way to ease.%s"):format(what, index, tostring(ease), suggest.phrase(tostring(ease), EASES)), level + 1)
        end
        local made = { at = at, ease = EASE[ease] }
        for name, value in pairs(values) do
            if type(name) == "string" and name ~= "time" and name ~= "ease" then
                local real
                for k = 1, #KEYS do if KEYS[k]:lower() == name:lower() then real = KEYS[k] end end
                if not real then
                    error(("%s: key %d has no value named %s.%s"):format(what, index, name, suggest.phrase(name, KEYS)), level + 1)
                end
                if not finite(value) then error(("%s: key %d: %s is a number"):format(what, index, real), level + 1) end
                made[real] = value
            end
        end
        keys[index] = made
    end
    table.sort(keys, function(a, b) return a.at < b.at end)
    return keys
end

-- The values of a track at one moment, written into `into`.
local function sample(keys, at, into)
    local count = #keys
    local a, b = keys[1], keys[1]
    if at >= keys[count].at then
        a, b = keys[count], keys[count]
    elseif at > keys[1].at then
        for index = 2, count do
            if at < keys[index].at then a, b = keys[index - 1], keys[index] break end
        end
    end
    local t = 0
    if b ~= a then t = b.ease((at - a.at) / (b.at - a.at)) end
    for k = 1, #KEYS do
        local name = KEYS[k]
        local rest = name == "Scale" and 1 or 0
        local from, to = a[name] or rest, b[name] or rest
        into[name] = from + (to - from) * t
    end
    return into
end
M.sample, M.read_keys = sample, read_keys

local function me_raw()
    local game = Wax.game
    local me = game and game.Me
    if not (me and me.Exists) then return nil end
    return me.Raw
end

local function third_person()
    local game = Wax.game
    local player = game and game.LocalPlayer
    return player ~= nil and player.Raw:GetIsThirdPerson() == true
end

-- What a target is: its Instance, whether it is the player's own character, and the mesh with the skeleton if it has one.
local function resolve(target, what, level)
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
        error(("%s expects what to animate: a character, a creature, a thing of a blueprint, or one of its parts. Got %s"):format(what,
            describe(target)), level + 1)
    end
    local raw = inst.Raw
    local mine = me_raw()
    local own = mine ~= nil and raw:GetAddress() == mine:GetAddress()
    local mesh, body = nil, nil
    if inst:IsA("SkeletalMeshComponent") then
        mesh, own = raw, false
    elseif own then
        mesh, body = raw:GetFirstPersonMesh(), raw:GetThirdPersonMesh()
    elseif inst:IsA("Character") then
        mesh = raw.Mesh
    end
    if mesh ~= nil and not mesh:IsValid() then mesh = nil end
    if body ~= nil and not body:IsValid() then body = nil end
    return inst, own, mesh, body
end

-- The part of a target that is moved as a whole.
local function scene_of(inst)
    local raw = inst.Raw
    if inst:IsA("SceneComponent") then return raw end
    local root = raw.RootComponent
    if root == nil or not root:IsValid() then return nil end
    return root
end

local function assets_now(level)
    local assets = Wax.game and Wax.game.Assets
    if not assets then error("game.Assets is not there, so no clip can be loaded", level + 1) end
    return assets
end

-- ---------------------------------------------------------------- the game's own clips

local function play_on(mesh, path, options, what, level)
    local asset = assets_now(level + 1):Load(path)
    local anim = mesh:GetAnimInstance()
    if not anim:IsValid() then error(("%s: what it is played on has no animation running"):format(what), level + 1) end
    local rate, blend, start = options.rate or 1, options.blend or 0.15, options.start or 0
    local raw = asset.Raw
    local montage
    if asset:IsA("AnimMontage") then
        anim:Montage_Play(raw, rate, 0, start, true)
        montage = raw
    elseif asset:IsA("AnimSequenceBase") then
        montage = anim:PlaySlotAnimationAsDynamicMontage(raw, FName(options.slot or M.SLOT), blend, blend, rate, options.loops or 1, -1, start)
    else
        error(("%s: %s is a %s, not an animation"):format(what, path, tostring(asset.ClassName)), level + 1)
    end
    return anim, montage
end

-- Play(target, clip, options): one of the game's montages or sequences on a character.
-- clip is a path, or { first = path, third = path } for the player's arms and body.
function members:Play(target, clip, options)
    if self ~= Animations then error("call Play with a colon: game.Animations:Play(target, clip)", 2) end
    options = options or {}
    if type(options) ~= "table" then error("game.Animations:Play: the options are a table such as { rate = 1.5 }", 2) end
    known_keys(options, CLIP_OPTIONS, "game.Animations:Play", 2)
    for _, name in ipairs({ "rate", "blend", "start" }) do
        if options[name] ~= nil and not finite(options[name]) then error(("game.Animations:Play: %s is a number"):format(name), 2) end
    end
    local inst, own = resolve(target, "game.Animations:Play", 2)
    local raw = inst.Raw
    local jobs = {}
    if type(clip) == "string" then
        local _, _, mesh = resolve(target, "game.Animations:Play", 2)
        if not mesh then error("game.Animations:Play: what was given has no skeleton to play a clip on", 2) end
        jobs[1] = { mesh, clip }
    elseif type(clip) == "table" and (clip.first or clip.third) then
        if not own then error("game.Animations:Play: { first = , third = } is for the player's own character. Give one path for anything else", 2) end
        if clip.first then jobs[#jobs + 1] = { raw:GetFirstPersonMesh(), clip.first } end
        if clip.third then jobs[#jobs + 1] = { raw:GetThirdPersonMesh(), clip.third } end
    else
        error("game.Animations:Play expects a clip: the path of a montage or a sequence, or { first = path, third = path }. Got "
            .. describe(clip), 2)
    end
    local started = {}
    for index = 1, #jobs do
        if type(jobs[index][2]) ~= "string" then error("game.Animations:Play: a clip is the path of an animation", 2) end
        local ok, anim, montage = pcall(play_on, jobs[index][1], jobs[index][2], options, "game.Animations:Play", 2)
        if not ok then error(first_line(anim), 2) end
        started[index] = { anim = instance.wrap(anim), montage = montage }
    end
    local handle = {}
    function handle:Stop(blend)
        for index = 1, #started do
            pcall(function() started[index].anim.Raw:Montage_Stop(blend or 0.15, started[index].montage) end)
        end
    end
    function handle:IsPlaying()
        for index = 1, #started do
            local ok, playing = pcall(function() return started[index].anim.Raw:Montage_IsPlaying(started[index].montage) end)
            if ok and playing then return true end
        end
        return false
    end
    return handle
end

-- ---------------------------------------------------------------- posable copies

local function engine_class()
    if poseable and poseable:IsValid() then return poseable end
    poseable = StaticFindObject(POSEABLE)
    if not poseable:IsValid() then error("this game has no posable mesh, so bones cannot be animated from Lua", 0) end
    return poseable
end

local skinned = nil
local function skinned_class()
    if skinned and skinned:IsValid() then return skinned end
    skinned = StaticFindObject("/Script/Engine.SkinnedMeshComponent")
    return skinned
end

-- A camera or a sound source stays on the real mesh: on the copy it would run a frame behind, and the view would jerk.
local function follows(child)
    local class = child:GetClass():GetFName():ToString()
    return not (class:find("Camera", 1, true) or class:find("Audio", 1, true) or class:find("SpringArm", 1, true))
end

-- Everything that hangs on `from` (a held tool, an effect) is moved over to `to`, at the same socket.
local function move_children(from, to, skip)
    local moved = {}
    for index = from:GetNumChildrenComponents() - 1, 0, -1 do
        local child = from:GetChildComponent(index)
        if child:IsValid() and child:GetAddress() ~= skip:GetAddress() and follows(child) then moved[#moved + 1] = child end
    end
    for index = 1, #moved do
        local child = moved[index]
        local socket = child:GetAttachSocketName()
        child:K2_AttachToComponent(to, socket, KEEP_RELATIVE, KEEP_RELATIVE, KEEP_RELATIVE, false)
        -- a piece of clothing has no socket: it takes its whole pose from what it hangs on
        if socket:ToString() == "None" and child:IsA(skinned_class()) then child:SetMasterPoseComponent(to, true) end
    end
    return #moved
end

local function make_rig(mesh, gate)
    local owner = mesh:GetOwner()
    local copy = owner:AddComponentByClass(engine_class(), true, IDENTITY, true)
    if not copy:IsValid() then error("the game did not make a posable copy", 0) end
    copy:SetMobility(2)
    -- it is only looked at: a copy that things bump into would stop its own character from moving
    copy:SetCollisionEnabled(0)
    copy:SetGenerateOverlapEvents(false)
    copy:SetSkeletalMesh(mesh.SkeletalMesh, true)
    owner:FinishAddComponent(copy, true, IDENTITY)
    copy:K2_AttachToComponent(mesh, FName("None"), 2, 2, 2, false)
    for index = 0, mesh:GetNumMaterials() - 1 do copy:SetMaterial(index, mesh:GetMaterial(index)) end
    copy:SetOnlyOwnerSee(mesh.bOnlyOwnerSee == true)
    copy:SetOwnerNoSee(mesh.bOwnerNoSee == true)
    copy:SetCastShadow(mesh.CastShadow == true)
    copy:SetVisibility(false, false)
    local rig = { real = instance.wrap(mesh), copy = instance.wrap(copy), gate = gate, shown = false, users = 0, idle = 0, bones = {} }
    rigs[mesh:GetAddress()] = rig
    rig.key = mesh:GetAddress()
    rig_count = rig_count + 1
    stats.rigs = stats.rigs + 1
    return rig
end

local function show_rig(rig, on)
    if rig.shown == on then return end
    local real, copy = rig.real.Raw, rig.copy.Raw
    if on then
        rig.tick = real.VisibilityBasedAnimTickOption
        real.VisibilityBasedAnimTickOption = 0
        copy:CopyPoseFromSkeletalComponent(real)
        copy:SetVisibility(true, false)
        real:SetVisibility(false, false)
        move_children(real, copy, copy)
    else
        move_children(copy, real, copy)
        real:SetVisibility(true, false)
        copy:SetVisibility(false, false)
        if rig.tick ~= nil then real.VisibilityBasedAnimTickOption = rig.tick end
    end
    rig.shown = on
end

local function drop_rig(rig, touch)
    if rigs[rig.key] == rig then
        rigs[rig.key] = nil
        rig_count = rig_count - 1
    end
    if not touch then return end
    pcall(function()
        show_rig(rig, false)
        rig.copy.Raw:K2_DestroyComponent(rig.copy.Raw)
    end)
end

local function bone_of(rig, name, what, level, soft)
    local known = rig.bones[name]
    if known then return known end
    local raw = rig.copy.Raw
    local candidates = ALIASES[name:lower()] or { name }
    for index = 1, #candidates do
        local at = raw:GetBoneIndex(FName(candidates[index]))
        if at >= 0 then
            known = { name = FName(candidates[index]), index = at }
            rig.bones[name] = known
            return known
        end
    end
    if soft then return nil end
    local names = {}
    for i = 0, raw:GetNumBones() - 1 do names[#names + 1] = raw:GetBoneName(i):ToString() end
    for alias in pairs(ALIASES) do names[#names + 1] = alias end
    error(("%s: the skeleton has no bone named %s.%s"):format(what, name, suggest.phrase(name, names)), level + 1)
end

-- ---------------------------------------------------------------- animations of keys

local Animation = {}
Animation.__index = Animation

-- Define(name, { length = , loop = , ease = , tracks = { Bone = keys, Self = keys }, events = { { time, fn } } })
function members:Define(name, spec)
    if self ~= Animations then error("call Define with a colon: game.Animations:Define(name, spec)", 2) end
    if type(name) ~= "string" or name == "" then error("game.Animations:Define expects a name such as \"Reap\", got " .. describe(name), 2) end
    if type(spec) ~= "table" then error("game.Animations:Define expects what the animation is: { length = 0.6, tracks = { ... } }", 2) end
    known_keys(spec, DEFINE_OPTIONS, "game.Animations:Define", 2)
    local ease = spec.ease or "smooth"
    if not EASE[ease] then error(("game.Animations:Define: '%s' is not a way to ease.%s"):format(tostring(ease), suggest.phrase(tostring(ease), EASES)), 2) end
    if type(spec.tracks) ~= "table" or next(spec.tracks) == nil then
        error("game.Animations:Define: tracks says what moves: { RightShoulder = { { 0, { Pitch = 0 } }, { 0.3, { Pitch = 40 } } } }", 2)
    end
    local tracks, count, longest = {}, 0, 0
    for track, keys in pairs(spec.tracks) do
        if type(track) ~= "string" then error("game.Animations:Define: a track is named by a bone, or Self for the thing as a whole", 2) end
        count = count + 1
        if count > M.MAX_TRACKS then error(("game.Animations:Define: more than %d tracks"):format(M.MAX_TRACKS), 2) end
        local read = read_keys(keys, "game.Animations:Define: track " .. track, ease, 2)
        tracks[#tracks + 1] = { name = track, self = track:lower() == SELF, keys = read }
        longest = math.max(longest, read[#read].at)
    end
    table.sort(tracks, function(a, b) return a.name < b.name end)
    local third = nil
    if spec.third ~= nil then
        if type(spec.third) ~= "table" then error("game.Animations:Define: third is the tracks for the body seen in third person", 2) end
        third = {}
        for track, keys in pairs(spec.third) do
            local read = read_keys(keys, "game.Animations:Define: third track " .. tostring(track), ease, 2)
            third[#third + 1] = { name = track, keys = read }
            longest = math.max(longest, read[#read].at)
        end
    end
    local length = spec.length or longest
    if not finite(length) or length <= 0 then error("game.Animations:Define: length is the seconds it runs, more than 0", 2) end
    local events = {}
    for index, event in ipairs(spec.events or {}) do
        if type(event) ~= "table" or not finite(event[1]) or type(event[2]) ~= "function" then
            error(("game.Animations:Define: event %d is { seconds, function }"):format(index), 2)
        end
        events[index] = { at = event[1], fn = event[2] }
    end
    table.sort(events, function(a, b) return a.at < b.at end)
    local animation = setmetatable({ Name = name, Length = length, Loop = spec.loop == true, tracks = tracks, third = third, events = events,
        owner = scope.current() }, Animation)
    defined[name:lower()] = animation
    local owner = scope.current()
    if owner then owner:add(function() if defined[name:lower()] == animation then defined[name:lower()] = nil end end) end
    return animation
end

function members:Get(name)
    if self ~= Animations then error("call Get with a colon: game.Animations:Get(name)", 2) end
    return type(name) == "string" and defined[name:lower()] or nil
end

local function finish(play, ended)
    if play.done then return end
    play.done = true
    if play.owner and play.slot then play.owner:remove(play.slot) end
    for index = 1, #play.sets do play.sets[index].rig.users = play.sets[index].rig.users - 1 end
    if play.scene and not play.keep then
        pcall(function()
            local scene, base = play.scene.Raw, play.base
            scene:K2_SetRelativeLocation(base.at, false, {}, false)
            scene:K2_SetRelativeRotation(base.turn, false, {}, false)
            scene:SetRelativeScale3D(base.size)
        end)
    end
    if ended and play.on_done then
        local ok, why = pcall(scope.run, play.owner, play.on_done, play.handle)
        if not ok then log:warn("the done function of %s failed: %s", play.animation.Name, first_line(why)) end
    end
end

-- animation:Play(target, { rate = , loop = , keep = , done = fn })
function Animation:Play(target, options)
    if getmetatable(self) ~= Animation then error("call Play with a colon on an animation: animation:Play(target)", 2) end
    options = options or {}
    if type(options) ~= "table" then error("animation:Play: the options are a table such as { rate = 1.5 }", 2) end
    known_keys(options, PLAY_OPTIONS, "animation:Play", 2)
    local rate, weight = options.rate or 1, options.weight or 1
    if not finite(rate) or rate <= 0 then error("animation:Play: rate is a number more than 0", 2) end
    if not finite(weight) then error("animation:Play: weight is a number, 1 for the whole movement", 2) end
    if options.done ~= nil and type(options.done) ~= "function" then error("animation:Play: done is a function", 2) end
    local inst, own, mesh, body = resolve(target, "animation:Play", 2)
    local play = { animation = self, rate = rate, weight = weight, at = 0, loop = options.loop == nil and self.Loop or options.loop == true,
        keep = options.keep == true, on_done = options.done, sets = {}, next_event = 1 }
    -- one set of bones for each skeleton the target shows: the arms and the body for the player, one for anything else
    local function bones_on(skeleton, gate, tracks, soft)
        if not skeleton then return end
        local ok, rig = pcall(function() return rigs[skeleton:GetAddress()] or make_rig(skeleton, gate) end)
        if not ok then error("animation:Play: " .. first_line(rig), 3) end
        local set = { rig = rig, bones = {} }
        for index = 1, #tracks do
            local track = tracks[index]
            if not track.self then
                local fine, bone = pcall(bone_of, rig, track.name, "animation:Play", 0, soft)
                if not fine then error(first_line(bone), 3) end
                if bone then set.bones[#set.bones + 1] = { bone = bone, keys = track.keys } end
            end
        end
        if #set.bones == 0 then return end
        table.sort(set.bones, function(x, y) return x.bone.index < y.bone.index end)
        rig.users, rig.idle = rig.users + 1, 0
        play.sets[#play.sets + 1] = set
    end
    local moves_bones = false
    for index = 1, #self.tracks do
        local track = self.tracks[index]
        if track.self then
            local scene = scene_of(inst)
            if not scene then error("animation:Play: what was given has no place of its own, so its Self track cannot move it", 2) end
            play.scene, play.self_keys = instance.wrap(scene), track.keys
            local at, turn, size = scene.RelativeLocation, scene.RelativeRotation, scene.RelativeScale3D
            play.base = { at = { X = at.X, Y = at.Y, Z = at.Z }, turn = { Pitch = turn.Pitch, Yaw = turn.Yaw, Roll = turn.Roll },
                size = { X = size.X, Y = size.Y, Z = size.Z } }
        else
            moves_bones = true
        end
    end
    if moves_bones or self.third then
        if not mesh then
            error("animation:Play: the animation moves bones, and what was given has no skeleton. Use a Self track to move a thing as a whole", 2)
        end
        if own then
            bones_on(mesh, "first", self.tracks, true)
            bones_on(body, "third", self.third or self.tracks, true)
        else
            bones_on(mesh, nil, self.tracks, false)
        end
    end
    local handle = { Animation = self }
    function handle:Stop() finish(play, false) end
    function handle:IsPlaying() return not play.done end
    function handle:GetTime() return play.at end
    function handle:SetRate(value)
        if not finite(value) or value <= 0 then error("SetRate expects a number more than 0", 2) end
        play.rate = value
    end
    play.handle = handle
    play.owner = scope.current()
    if play.owner then play.slot = play.owner:add(function() finish(play, false) end) end
    plays[#plays + 1] = play
    stats.plays = stats.plays + 1
    return handle
end

local values = {}

local function step_scene(play)
    local scene, base, w = play.scene.Raw, play.base, play.weight
    local v = sample(play.self_keys, play.at, values)
    scene:K2_SetRelativeLocation({ X = base.at.X + v.X * w, Y = base.at.Y + v.Y * w, Z = base.at.Z + v.Z * w }, false, {}, false)
    scene:K2_SetRelativeRotation({ Pitch = base.turn.Pitch + v.Pitch * w, Yaw = base.turn.Yaw + v.Yaw * w, Roll = base.turn.Roll + v.Roll * w },
        false, {}, false)
    local size = 1 + (v.Scale - 1) * w
    scene:SetRelativeScale3D({ X = base.size.X * size, Y = base.size.Y * size, Z = base.size.Z * size })
end

local function step_bones(play, set)
    local copy, w = set.rig.copy.Raw, play.weight
    for index = 1, #set.bones do
        local entry = set.bones[index]
        local v = sample(entry.keys, play.at, values)
        local name = entry.bone.name
        if v.Pitch ~= 0 or v.Yaw ~= 0 or v.Roll ~= 0 then
            local turn = copy:GetBoneRotationByName(name, COMPONENT_SPACE)
            copy:SetBoneRotationByName(name, { Pitch = turn.Pitch + v.Pitch * w, Yaw = turn.Yaw + v.Yaw * w, Roll = turn.Roll + v.Roll * w },
                COMPONENT_SPACE)
        end
        if v.X ~= 0 or v.Y ~= 0 or v.Z ~= 0 then
            local at = copy:GetBoneLocationByName(name, COMPONENT_SPACE)
            copy:SetBoneLocationByName(name, { X = at.X + v.X * w, Y = at.Y + v.Y * w, Z = at.Z + v.Z * w }, COMPONENT_SPACE)
        end
        if v.Scale ~= 1 then
            local size = 1 + (v.Scale - 1) * w
            copy:SetBoneScaleByName(name, { X = size, Y = size, Z = size }, COMPONENT_SPACE)
        end
        stats.bones = stats.bones + 1
    end
end

local function fire_events(play, from, to)
    local events = play.animation.events
    while play.next_event <= #events and events[play.next_event].at <= to do
        local event = events[play.next_event]
        play.next_event = play.next_event + 1
        if event.at >= from or from == 0 then
            local ok, why = pcall(scope.run, play.owner, event.fn, play.handle)
            if not ok then log:warn("an event of %s failed: %s", play.animation.Name, first_line(why)) end
        end
    end
end

function M.step()
    if #plays == 0 and rig_count == 0 then
        last = nil
        return
    end
    local now = perf.now()
    local dt = last and math.min(now - last, 0.1) or 0
    last = now
    -- a rig takes the game's own pose first, then every animation on it adds its part
    local third = nil
    for _, rig in pairs(rigs) do
        local ok, why = pcall(function()
            if rig.users > 0 then
                local on = true
                if rig.gate then
                    if third == nil then third = third_person() end
                    on = (rig.gate == "third") == third
                end
                show_rig(rig, on)
                if on then rig.copy.Raw:CopyPoseFromSkeletalComponent(rig.real.Raw) end
                rig.idle = 0
            else
                show_rig(rig, false)
                rig.idle = rig.idle + dt
                if rig.idle > M.RIG_IDLE then drop_rig(rig, true) end
            end
        end)
        if not ok then
            log:warn("a posable copy was let go: %s", first_line(why))
            drop_rig(rig, false)
        end
    end
    local kept = 0
    for index = 1, #plays do
        local play = plays[index]
        if not play.done then
            local before = play.at
            play.at = play.at + dt * play.rate
            local length = play.animation.Length
            local over = play.at >= length
            if over and not play.loop then play.at = length end
            local ok, why = pcall(function()
                if play.scene then step_scene(play) end
                for s = 1, #play.sets do
                    local set = play.sets[s]
                    if not rigs[set.rig.key] then error("what it played on is gone", 0) end
                    if set.rig.shown then step_bones(play, set) end
                end
            end)
            fire_events(play, before, play.at)
            if not ok then
                play.keep = true
                finish(play, false)
            elseif over then
                if play.loop then
                    play.at, play.next_event = play.at % length, 1
                else
                    finish(play, true)
                end
            end
        end
        if not play.done then
            kept = kept + 1
            plays[kept] = play
        end
    end
    for index = #plays, kept + 1, -1 do plays[index] = nil end
end

-- The bones of a target's skeleton, by name, for writing tracks.
function members:GetBones(target)
    if self ~= Animations then error("call GetBones with a colon: game.Animations:GetBones(target)", 2) end
    local _, _, mesh = resolve(target, "game.Animations:GetBones", 2)
    local names = {}
    if mesh then
        for index = 0, mesh:GetNumBones() - 1 do names[#names + 1] = mesh:GetBoneName(index):ToString() end
    end
    return names
end

function members:Find(text)
    if self ~= Animations then error("call Find with a colon: game.Animations:Find(text)", 2) end
    return Wax.import("world.media").find("animations", text, "game.Animations:Find")
end

function members:StopAll()
    if self ~= Animations then error("call StopAll with a colon: game.Animations:StopAll()", 2) end
    local owner = scope.current()
    for index = 1, #plays do
        if plays[index].owner == owner then finish(plays[index], false) end
    end
end

setmetatable(Animations, {
    __index = members,
    __newindex = function(_, key) error(("game.Animations.%s cannot be assigned"):format(tostring(key)), 2) end,
    __tostring = function() return "game.Animations" end,
})

local function on_map_change()
    for index = 1, #plays do
        plays[index].keep = true
        finish(plays[index], false)
    end
    plays, rigs, rig_count, poseable, last = {}, {}, 0, nil, nil
end

function M.stats() return { playing = #plays, rigs = rig_count, plays = stats.plays, rigs_made = stats.rigs, bones = stats.bones } end

function M.start()
    local root = Wax.import("engine.game").root
    rawset(root, "Animations", Animations)
    if connection then connection:Disconnect() end
    connection = root.MapChanged:Connect(on_map_change)
end

function M.stop()
    for index = 1, #plays do finish(plays[index], false) end
    for _, rig in pairs(rigs) do drop_rig(rig, true) end
    plays, rigs, rig_count = {}, {}, 0
    if connection then connection:Disconnect() end
    connection = nil
    local root = Wax.import("engine.game").root
    if rawget(root, "Animations") == Animations then rawset(root, "Animations", nil) end
end

M.api = Animations
return M
