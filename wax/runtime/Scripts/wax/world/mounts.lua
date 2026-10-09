-- A mount of your own, and a creature in another body: game.Creatures:SpawnMount, creature:SetModel, creature:ResetModel

local Wax = ...
local easy = Wax.import("engine.easy")
local scope = Wax.import("core.scope")
local sched = Wax.import("core.sched")
local co = Wax.import("core.co")
local suggest = Wax.import("core.suggest")
local log = Wax.import("core.log").channel("wax.mounts")

local M = {}

M.NPC, M.PAWN = "IcarusNPCCharacter", "IcarusPawn"
M.SPAWNER = "IcarusAIBlueprintFunctionLibrary"
M.NAV = "/Script/NavigationSystem.Default__NavigationSystemV1"
M.AHEAD = 450                               -- how far in front of the player a mount is made
M.REACH = { X = 500, Y = 500, Z = 100000 }  -- how far from the place walkable ground is looked for
M.DROP = 500                                -- ground further below than this is not where the player stands: the mount is brought up
M.SADDLE = "Saddle_Standard"
M.SETTLE = 0.2                              -- seconds the game is given before the owner and the saddle
M.ATTACK = "BT.Mount.Animation.Attack"       -- the key of a mount's attack in its row of D_Mounts
M.COST = "Mount_Attack"                     -- the row of D_StaminaActionCosts the game charges for it
M.LOOK = 1                                  -- seconds between two looks at the creatures that wear a model

local LOOK_KEYS = { "mesh", "materials", "fur", "saddle" }
local MOUNT_KEYS = { "name", "saddle", "owner", "facing" }

local worn = {}            -- { creature = Instance, mesh = Instance, materials = { [slot] = Instance }, fur, saddle, original, owner, slot }
local watcher = nil
local undo_class = nil
local stats = { dressed = 0, put_back = 0, mounts = 0, strikes = 0 }

local function clean(problem) return (tostring(problem):gsub("^[^\n]-%.lua:%d+: ", "", 1)) end

local function known(options, names, what, level)
    for key in pairs(options) do
        local found = false
        for _, name in ipairs(names) do found = found or key == name end
        if not found then
            error(("%s has no option '%s'.%s"):format(what, tostring(key), suggest.phrase(tostring(key), names)), level + 1)
        end
    end
end

local function is_instance(value)
    return type(value) == "table" and pcall(function() return value.Raw end) and value.Raw ~= nil
end

-- "SkeletalMesh /Game/Folder/Name.Name" gives "/Game/Folder/Name.Name". Nil for something made at run time.
local function path_of(object)
    local ok, full = pcall(function() return object:IsValid() and object:GetFullName() or nil end)
    if not ok or type(full) ~= "string" then return nil end
    local path = full:match("^%S+ (/.+)$")
    if not path or path:find("^/Engine/Transient") then return nil end
    return path
end

-- An asset given as an Instance or as a path, as an Instance kept for the mod that asked.
local function asset(value, what, level)
    if is_instance(value) then return value end
    if type(value) ~= "string" then
        error(("%s is an asset from game.Assets or mod.Content, or its path, got %s"):format(what, type(value)), level + 1)
    end
    local loaded, why = Wax.game.Assets:Load(value)
    if not loaded then error(("%s: %s"):format(what, tostring(why)), level + 1) end
    return loaded
end

local function body_of(raw)
    local body = raw.Mesh
    if not body:IsValid() then error("this creature has no body of its own to give another model", 0) end
    return body
end

local function each_coat(body, fn)
    for index = 0, body:GetNumChildrenComponents() - 1 do
        local child = body:GetChildComponent(index)
        if child:IsValid() and child:GetClass():GetFName():ToString() == "GFurComponent" then fn(child) end
    end
end

-- The saddle the game shows on a mount is a mesh of its seat. Nil for a creature with no seat.
local function saddle_of(raw)
    local holder = raw.ChildActor_Seat
    if not holder:IsValid() then return nil end
    local seat = holder.ChildActor
    if not seat:IsValid() then return nil end
    local saddle = seat.SaddleSkeletalMesh
    return saddle:IsValid() and saddle or nil
end

-- Puts the model on, or back on: the game writes a mount's own skin again now and then.
local function apply(entry, raw)
    local body, mesh = body_of(raw), entry.mesh.Raw
    if body.SkeletalMesh:GetAddress() ~= mesh:GetAddress() then
        body:SetSkeletalMesh(mesh, true)
        stats.dressed = stats.dressed + 1
    end
    for slot, material in pairs(entry.materials) do
        local wanted = material.Raw
        if body:GetMaterial(slot - 1):GetAddress() ~= wanted:GetAddress() then body:SetMaterial(slot - 1, wanted) end
    end
    if entry.fur == false then
        each_coat(body, function(coat)
            if coat:IsVisible() then coat:SetVisibility(false, false) end
        end)
    end
    if entry.saddle == false then
        local saddle = saddle_of(raw)
        if saddle and saddle:IsVisible() then
            -- unseen, it still has to follow the body: the rider sits on it
            saddle.VisibilityBasedAnimTickOption = 0
            saddle:SetVisibility(false, false)
        end
    end
end

local function put_back(entry)
    local ok, raw = pcall(function() return entry.creature.Raw end)
    if not ok or not raw then return end
    pcall(function()
        local body = body_of(raw)
        local original = entry.original
        if original.mesh then
            local found, mesh = pcall(LoadAsset, original.mesh)
            if found and mesh and mesh:IsValid() then body:SetSkeletalMesh(mesh, true) end
        end
        for slot, path in pairs(original.materials) do
            local found, material = pcall(LoadAsset, path)
            if found and material and material:IsValid() then body:SetMaterial(slot - 1, material) end
        end
        if entry.fur == false then each_coat(body, function(coat) coat:SetVisibility(true, false) end) end
        if entry.saddle == false then
            local saddle = saddle_of(raw)
            if saddle then saddle:SetVisibility(true, false) end
        end
        stats.put_back = stats.put_back + 1
    end)
end

local function find(creature)
    for index = 1, #worn do
        if rawequal(worn[index].creature, creature) then return index end
    end
    return nil
end

local function forget(index, restore)
    local entry = table.remove(worn, index)
    if entry.owner and entry.slot then entry.owner:remove(entry.slot) end
    if restore then put_back(entry) end
end

local function look()
    for index = #worn, 1, -1 do
        local entry = worn[index]
        local ok, raw = pcall(function() return entry.creature.Raw end)
        if not ok or not raw then
            forget(index, false)
        else
            local fine, why = pcall(apply, entry, raw)
            if not fine then
                -- the model was let go of, or the map changed under it
                log:warn("%s no longer wears its model: %s", tostring(entry.creature), clean(why))
                forget(index, false)
            end
        end
    end
    if #worn == 0 and watcher then
        local thread = watcher
        watcher = nil
        sched.task.cancel(thread)
    end
end

local function watch()
    if watcher then return end
    local previous = scope.enter(nil)
    watcher = sched.task.every(M.LOOK, look)
    scope.leave(previous)
end

-- creature:SetModel({ mesh = , materials = { [1] = }, fur = false, saddle = false })
local function set_model(self, raw, model)
    if type(model) ~= "table" or is_instance(model) then
        error("SetModel takes a table such as { mesh = mod.Content:Load(\"SK_Bird\") }", 0)
    end
    known(model, LOOK_KEYS, "SetModel", 1)
    if model.mesh == nil then error("SetModel needs mesh: the skeletal mesh the creature is to wear", 0) end
    local body = body_of(raw)
    local mesh = asset(model.mesh, "the mesh of SetModel", 1)
    if not mesh:IsA("SkeletalMesh") then error(("the mesh of SetModel is a %s, not a skeletal mesh"):format(mesh.ClassName), 0) end
    -- the creature's animations only go on running on the skeleton they were made for
    local now = body.SkeletalMesh
    local index = find(self)
    local own = index and worn[index].mesh.Raw or now
    local wanted, has = mesh.Raw.Skeleton, own.Skeleton
    if wanted:GetAddress() ~= has:GetAddress() then
        error(("the mesh is built on the skeleton %s and this creature moves on %s. Bind the model to that skeleton, or its animations stop")
            :format(wanted:GetFName():ToString(), has:GetFName():ToString()), 0)
    end
    local materials = {}
    if model.materials ~= nil then
        if type(model.materials) ~= "table" then error("the materials of SetModel are a table by slot, 1 first, such as { [1] = material }", 0) end
        for slot, material in pairs(model.materials) do
            if math.type(slot) ~= "integer" or slot < 1 or slot > 32 then error("the materials of SetModel go by slot, 1 first, got the key " .. tostring(slot), 0) end
            materials[slot] = asset(material, ("material %d of SetModel"):format(slot), 1)
            if not materials[slot]:IsA("MaterialInterface") then error(("material %d of SetModel is a %s, not a material"):format(slot, materials[slot].ClassName), 0) end
        end
    end
    local original
    if index then
        original = worn[index].original
        forget(index, false)
    else
        original = { mesh = path_of(now), materials = {} }
    end
    for slot in pairs(materials) do
        if original.materials[slot] == nil then original.materials[slot] = path_of(body:GetMaterial(slot - 1)) end
    end
    local entry = { creature = self, mesh = mesh, materials = materials, fur = model.fur, saddle = model.saddle, original = original }
    apply(entry, raw)
    entry.owner, entry.slot = scope.own(function()
        local at = find(self)
        if at and worn[at] == entry then
            entry.slot = nil
            forget(at, true)
        end
    end)
    worn[#worn + 1] = entry
    watch()
    return true
end

local function reset_model(self)
    local index = find(self)
    if not index then return false end
    forget(index, true)
    return true
end

local function wears(self) return find(self) ~= nil end

-- mount:Strike(): the mount's own attack, as the game starts it when its rider attacks. The game only lets a mount
-- with the talent for it attack. This goes to what that leads to: the attack animation, its cost in stamina, and
-- the hit on what stands in front of it at the strike.
local attacks = {}
local function strike(self, raw)
    local game = Wax.game
    if not raw.ChildActor_Seat:IsValid() then error("Strike is for a mount: a tamed animal that can be ridden", 0) end
    local playing = raw.Mesh:GetAnimInstance():GetCurrentActiveMontage()
    if playing:IsValid() then return false, "it is in the middle of another move" end
    local kind = raw.MountData.RowName:ToString()
    local path = attacks[kind]
    if path == nil then
        local ok, row = pcall(function() return game.Data:Table("Mounts"):Row(kind, { "Animations" }) end)
        path = ok and type(row) == "table" and type(row.Animations) == "table" and row.Animations[M.ATTACK] or false
        attacks[kind] = path
    end
    if not path then return false, "the game gives this mount no attack" end
    local montage, why = game.Assets:Load(path)
    if not montage then return false, why end
    self:Server_PlayActionMontage(montage, { RowName = M.COST, DataTableName = "D_StaminaActionCosts" }, 1, "None")
    stats.strikes = stats.strikes + 1
    return true
end

-- game.Creatures:SpawnMount(kind, place, options)
local function finish_mount(made, options)
    local raw = made.Raw
    if options.name ~= nil then made:SetMountName(options.name) end
    if options.owner ~= false then made:SetMountOwner(Wax.game.LocalPlayer.PlayerState, false) end
    local saddle = options.saddle
    if saddle == nil then saddle = M.SADDLE end
    if saddle ~= false then
        -- a saddle in its saddle slot is what makes the game give a mount its seat
        local slots = raw.Inventory:GetInventory({ Value = FName("Saddle") })
        if not slots:IsValid() then return "it has no place for a saddle" end
        local placed, why = Wax.game.wrap(slots):Give(saddle, 1)
        if placed ~= 1 then return ("its saddle did not go on: %s"):format(tostring(why or "the game said no")) end
    end
    return nil
end

function M.spawn(kind, place, options)
    if type(kind) ~= "string" or kind == "" then
        error("SpawnMount expects the tamed animal's set-up row as its first value, such as \"Mount_Moa\", got " .. type(kind), 0)
    end
    if options == nil and type(place) == "table" and place.X == nil and not is_instance(place) then place, options = nil, place end
    options = options or {}
    if type(options) ~= "table" then error("the options of SpawnMount are a table such as { name = \"Dusty\" }, got " .. type(options), 0) end
    known(options, MOUNT_KEYS, "SpawnMount", 1)
    if options.name ~= nil and type(options.name) ~= "string" then error("the option name of SpawnMount is text", 0) end
    if options.saddle ~= nil and options.saddle ~= false and type(options.saddle) ~= "string" then
        error("the option saddle of SpawnMount is an item such as \"Saddle_Standard\", or false for none", 0)
    end
    local game = Wax.game
    if not game.Me.Exists then error("you are not in the world, so there is nowhere to make a mount", 0) end
    local row = kind
    local info = nil
    pcall(function() info = game.Creatures:GetInfo(kind) end)
    if info and info.Mount and info.Mount.Variant then row = info.Mount.Variant end

    local body = game.Me.Raw
    local here = body:K2_GetActorLocation()
    local ahead = body:GetActorForwardVector()
    local yaw = math.atan(ahead.Y, ahead.X)
    local wanted, lift
    if place == nil then
        wanted = { X = here.X + math.cos(yaw) * M.AHEAD, Y = here.Y + math.sin(yaw) * M.AHEAD, Z = here.Z + 100 }
        lift = here.Z + 80
    else
        if is_instance(place) then place = place.Raw:K2_GetActorLocation() end
        if type(place) ~= "table" or type(place.X) ~= "number" or type(place.Y) ~= "number" or type(place.Z) ~= "number" then
            error("SpawnMount expects a place as its second value: a position such as { X = 0, Y = 0, Z = 0 } or an actor", 0)
        end
        wanted = { X = place.X, Y = place.Y, Z = place.Z + 100 }
        lift = place.Z + 80
    end
    local nav = StaticFindObject(M.NAV)
    if not nav:IsValid() then error("the game's navigation is not there", 0) end
    local ground = {}
    if nav:K2_ProjectPointToNavigation(body, wanted, ground, nil, nil, { X = M.REACH.X, Y = M.REACH.Y, Z = M.REACH.Z }) ~= true then
        error("the game has no ground a mount can walk on near that place", 0)
    end
    local facing = type(options.facing) == "table" and tonumber(options.facing.Yaw) and math.rad(options.facing.Yaw) or (yaw + math.pi)
    local transform = { Rotation = { X = 0, Y = 0, Z = math.sin(facing / 2), W = math.cos(facing / 2) },
        Translation = { X = ground.X, Y = ground.Y, Z = ground.Z + 150 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local spawned = game:Library(M.SPAWNER).Raw:SpawnNewAI(body, { RowName = FName(row), DataTableName = FName("D_AISetup") },
        { RowName = FName("None"), DataTableName = FName("D_EpicCreatures") }, transform, 0, 2, nil, nil, -1)
    if spawned == nil or not spawned:IsValid() then
        error(("the game made nothing for %s. Is it a row of D_AISetup, such as \"Mount_Moa\"?"):format(row), 0)
    end
    if not spawned.Inventory:IsValid() or not spawned.ChildActor_Seat:IsValid() then
        local name = spawned:GetClass():GetFName():ToString()
        spawned:K2_DestroyActor()
        error(("%s is not a mount (the game made a %s). SpawnMount takes a tamed animal such as \"Mount_Moa\""):format(row, name), 0)
    end
    -- standing on something the game's ground map does not know, such as a platform of a mod: the mount comes up to it
    if math.abs(ground.Z - (lift - 80)) > M.DROP then
        spawned:K2_TeleportTo({ X = wanted.X, Y = wanted.Y, Z = lift }, { Pitch = 0, Yaw = math.deg(facing), Roll = 0 })
    end
    stats.mounts = stats.mounts + 1
    local made = game.wrap(spawned)
    local task = sched.task
    if not co.isyieldable() then
        local owner = scope.current()
        task.spawn(function()
            task.wait(M.SETTLE)
            if not made:IsValid() then return end
            local ok, why = pcall(scope.run, owner, finish_mount, made, options)
            if not ok or why then log:warn("the mount %s was made, but %s", row, clean(why)) end
        end)
        return made
    end
    task.wait(M.SETTLE)
    if not made:IsValid() then return nil, "the mount left the world before the game had finished making it" end
    local why = finish_mount(made, options)
    return made, why
end

function M.stats() return { wearing = #worn, dressed = stats.dressed, put_back = stats.put_back, mounts = stats.mounts, strikes = stats.strikes } end

function M.start()
    if undo_class then undo_class() end
    undo_class = easy.class({ M.NPC, M.PAWN }, { fields = { HasModel = wears }, methods = { SetModel = set_model, ResetModel = reset_model, Strike = strike } }, "mounts")
    local api = Wax.import("world.creatures").api
    rawset(api, "SpawnMount", function(self, kind, place, options)
        if not rawequal(self, api) then error("call SpawnMount with a colon: game.Creatures:SpawnMount(\"Mount_Moa\")", 2) end
        local results = table.pack(pcall(M.spawn, kind, place, options))
        if not results[1] then error(clean(results[2]), 2) end
        return results[2], results[3]
    end)
end

function M.stop()
    for index = #worn, 1, -1 do forget(index, true) end
    if watcher then
        sched.task.cancel(watcher)
        watcher = nil
    end
    if undo_class then
        undo_class()
        undo_class = nil
    end
    local api = Wax.import("world.creatures").api
    rawset(api, "SpawnMount", nil)
end

return M
