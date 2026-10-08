-- Live test of world.assets (game.Assets): loading, pictures from files, materials, meshes made of numbers, and letting go.
-- It needs a prospect, the host, and the test character. It loads that one module again by itself and no other.
-- Send it twice:  node wax/cli/wax.mjs eval --file wax/tests/live/assets.lua
--   1. runs the checks that fit in one call, puts three small things in front of the camera, and starts the timed half
--   2. about twelve seconds later: gives the result of both halves
-- The timed half asks the engine to collect garbage twice (a hitch each), to see that what is held stays in memory and
-- what was let go leaves it. Set WaxAssetsLook = 20 first to leave the things standing that many seconds (5 when unset).

local kept = rawget(_G, "WaxAssetsLive")
if kept then
    if not kept.done then
        return { passed = 0, failed = 0, failures = {}, details = { "the timed half is still running: send this again in a few seconds" }, pending = true }
    end
    rawset(_G, "WaxAssetsLive", nil)
    return kept.result
end

local game = Wax.game
local scope = Wax.import("core.scope")
local now = Wax.perf.now
local LOOK = tonumber(rawget(_G, "WaxAssetsLook")) or 5

local checks = {}
local function check(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail } end
local function attempt(name, fn)
    local ok, a, b = pcall(fn)
    if ok then check(name, a, b) else check(name, false, "raised: " .. tostring(a)) end
end
local function raises(fn, fragment)
    local ok, problem = pcall(fn)
    if ok then return false, "it did not raise" end
    return tostring(problem):find(fragment, 1, true) ~= nil, (tostring(problem):match("^[^\r\n]*"))
end
local function result(pending)
    local passed, failed, details = 0, {}, {}
    for _, c in ipairs(checks) do
        if c.ok then passed = passed + 1 else failed[#failed + 1] = c.name .. " :: " .. tostring(c.detail) end
        details[#details + 1] = (c.ok and "ok   " or "FAIL ") .. c.name .. (c.detail ~= nil and ("  [" .. tostring(c.detail):sub(1, 260) .. "]") or "")
    end
    return { passed = passed, failed = #failed, failures = failed, details = details, pending = pending or nil }
end

if not game.InProspect or not game.Character then
    check("a prospect with a character", false, "this test puts things in the world: enter a prospect first")
    return result()
end

-- the module, by itself
local old = Wax.modules["world.assets"]
if type(old) == "table" and old.stop then pcall(old.stop) end
Wax.modules["world.assets"] = nil
local module = Wax.import("world.assets")
module.start()
local Assets = game.Assets
local owner = scope.new("WaxAssetsLive")
local function mine(fn, ...) return scope.run(owner, fn, ...) end

local WOOD = "/Game/Assets/2DArt/UI/Items/Item_Icons/Resources/ITEM_Wood.ITEM_Wood"
local FOLDER = "/Game/Assets/2DArt/UI/Items/Item_Icons/Resources/"
local GLOW = "/Engine/EngineMaterials/EmissiveMeshMaterial"
local SHOWS = "/Engine/EngineMaterials/Widget3DPassThrough_Opaque"
local HUES = Wax.root .. "/assets/picker/hues.png"

attempt("game.Assets is there and says its name", function() return tostring(Assets) == "Assets", tostring(Assets) end)
attempt("a member it lacks is an error that names a near one", function()
    return raises(function() return Assets.Laod end, "Did you mean 'Load'?")
end)

-- Load
local wood
attempt("Load gives an Instance of the asset", function()
    local started = now()
    wood = mine(function() return Assets:Load(WOOD) end)
    return wood ~= nil and wood:IsA("Texture2D") and wood.Name == "ITEM_Wood", tostring(wood) .. (" in %.3f ms"):format((now() - started) * 1000)
end)
attempt("asked again, the same Instance comes back, also by the short path and the editor's form", function()
    local started = now()
    local again = mine(function() return Assets:Load(WOOD) end)
    local spent = (now() - started) * 1000
    local short = mine(function() return Assets:Load(FOLDER .. "ITEM_Wood") end)
    local editor = mine(function() return Assets:Load("Texture2D'" .. WOOD .. "'") end)
    return again == wood and short == wood and editor == wood, ("%.3f ms"):format(spent)
end)
attempt("IsLoaded tells, and loads nothing", function()
    local there, nothing = Assets:IsLoaded(WOOD), Assets:IsLoaded("/Game/WaxLive/Nothing")
    local bad, why = Assets:IsLoaded("wood")
    return there == true and nothing == false and bad == false and type(why) == "string", tostring(why)
end)
attempt("a misspelt name gives nil and names the asset that is near", function()
    local nothing, why = Assets:Load(FOLDER .. "ITEM_Wod")
    return nothing == nil and tostring(why):find("Did you mean '" .. WOOD .. "'?", 1, true) ~= nil, why
end)
attempt("asked again within seconds, the answer is the kept one", function()
    local started = now()
    local nothing, why = Assets:Load(FOLDER .. "ITEM_Wod")
    local spent = (now() - started) * 1000
    return nothing == nil and spent < 0.5, ("%.3f ms"):format(spent)
end)
attempt("a blueprint asked for without _C names its class", function()
    local nothing, why = Assets:Load("/Game/BP/Player/BP_IcarusPlayerCharacterSurvival")
    return nothing == nil and tostring(why):find("BP_IcarusPlayerCharacterSurvival_C'?", 1, true) ~= nil, why
end)
attempt("a blueprint's class loads", function()
    local class = mine(function() return Assets:Load("/Game/BP/Player/BP_IcarusPlayerCharacterSurvival.BP_IcarusPlayerCharacterSurvival_C") end)
    return class ~= nil and class.Name == "BP_IcarusPlayerCharacterSurvival_C", tostring(class)
end)
attempt("a folder the game lacks is said so", function()
    local nothing, why = Assets:Load("/Game/WaxLive/Nothing")
    return nothing == nil and tostring(why):find("no assets in the folder /Game/WaxLive", 1, true) ~= nil, why
end)
attempt("what is not a path gives nil and why, and a number is an error", function()
    local nothing, why = Assets:Load("wood")
    local raised = raises(function() return Assets:Load(5) end, "got a number")
    return nothing == nil and tostring(why):find("is not the path of an asset", 1, true) ~= nil and raised, why
end)
attempt("a class of the engine is found and not held", function()
    local before = module.stats().held
    local class = mine(function() return Assets:Load("/Script/Engine.StaticMeshComponent") end)
    return class ~= nil and class.Name == "StaticMeshComponent" and module.stats().held == before, tostring(class)
end)

-- Texture
local hues
attempt("Texture reads a picture file", function()
    local started = now()
    hues = mine(function() return Assets:Texture(HUES) end)
    local spent = (now() - started) * 1000
    return hues ~= nil and hues:IsA("Texture2D") and hues:Blueprint_GetSizeX() == 360 and hues:Blueprint_GetSizeY() == 4,
        ("%s in %.3f ms"):format(tostring(hues), spent)
end)
attempt("asked again, the same texture comes back and no file is read", function()
    local started = now()
    local again = mine(function() return Assets:Texture(HUES) end)
    local spent = (now() - started) * 1000
    return again == hues and spent < 0.5, ("%.3f ms"):format(spent)
end)
attempt("a file that is not there, a file that is no picture and a bare name with no mod are errors", function()
    local a, said_a = raises(function() return Assets:Texture(Wax.root .. "/assets/picker/nothing.png") end, "there is no file")
    local b, said_b = raises(function() return Assets:Texture(Wax.root .. "/Scripts/main.lua") end, "is not a .png or .jpg file")
    local c, said_c = raises(function() return Assets:Texture("logo.png") end, "Give the whole path")
    return a and b and c, said_a .. " / " .. said_b .. " / " .. said_c
end)

-- Material
local glow, rainbow, wooden
attempt("Material makes one from a material's path and sets a colour", function()
    local started = now()
    glow = mine(function() return Assets:Material(GLOW, { colors = { Color = "#ff8800" } }) end)
    local spent = (now() - started) * 1000
    local c = glow:K2_GetVectorParameterValue("Color")
    local right = math.abs(c.R - 1) < 0.001 and math.abs(c.G - 0.2462) < 0.001 and math.abs(c.B) < 0.001 and c.A == 1
    return glow:IsA("MaterialInstanceDynamic") and right, ("%.3f %.3f %.3f in %.3f ms"):format(c.R, c.G, c.B, spent)
end)
attempt("numbers given as linear go on as they are", function()
    local bright = mine(function() return Assets:Material(GLOW, { colors = { Color = { R = 0, G = 3, B = 0.6, linear = true } } }) end)
    local c = bright:K2_GetVectorParameterValue("Color")
    glow = bright
    return math.abs(c.G - 3) < 0.001 and math.abs(c.B - 0.6) < 0.001, ("%.3f %.3f %.3f"):format(c.R, c.G, c.B)
end)
attempt("a texture and a number go on, from an Instance and from a path", function()
    rainbow = mine(function() return Assets:Material(SHOWS, { textures = { SlateUI = hues }, numbers = { OpacityFromTexture = 1 } }) end)
    wooden = mine(function() return Assets:Material(SHOWS, { textures = { SlateUI = WOOD } }) end)
    return rainbow:K2_GetTextureParameterValue("SlateUI") == hues and wooden:K2_GetTextureParameterValue("SlateUI") == wood
        and rainbow:K2_GetScalarParameterValue("OpacityFromTexture") == 1, tostring(rainbow)
end)
attempt("a material made here, a texture, a misspelt option and a bad colour are refused in plain words", function()
    local a, said_a = raises(function() return Assets:Material(glow) end, "cannot start from a MaterialInstanceDynamic")
    local b, said_b = raises(function() return Assets:Material(wood) end, "Got a Texture2D")
    local c, said_c = raises(function() return Assets:Material(GLOW, { Colors = {} }) end, "Did you mean 'colors'?")
    local d, said_d = raises(function() return Assets:Material(GLOW, { colors = { Color = "Oragne" } }) end, "Did you mean 'Orange'?")
    return a and b and c and d, said_a .. " / " .. said_b .. " / " .. said_c .. " / " .. said_d:sub(1, 60)
end)

-- Mesh
local box, pyramid
attempt("Mesh makes a box and a shape from numbers", function()
    local started = now()
    box = Assets:Mesh({ box = 60, collision = true })
    pyramid = Assets:Mesh({
        vertices = { { -40, -40, 0 }, { 40, -40, 0 }, { 40, 40, 0 }, { -40, 40, 0 }, { X = 0, Y = 0, Z = 70 } },
        triangles = { 2, 1, 5, 3, 2, 5, 4, 3, 5, 1, 4, 5, 1, 2, 3, 1, 3, 4 },
        uvs = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, { 0.5, 0.5 } },
    })
    local spent = (now() - started) * 1000
    return box.VertexCount == 24 and box.TriangleCount == 12 and box.Size.X == 60 and pyramid.VertexCount == 5
        and pyramid.TriangleCount == 6 and pyramid.Size.Z == 70, ("%s, %s in %.3f ms"):format(tostring(box), tostring(pyramid), spent)
end)
attempt("a shape that cannot be is refused in plain words", function()
    local a, said_a = raises(function() return Assets:Mesh({ vertices = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } }, triangles = { 1, 2, 4 } }) end,
        "from 1 to 3")
    local b, said_b = raises(function() return Assets:Mesh({ box = 60, Collision = true }) end, "Did you mean 'collision'?")
    local c, said_c = raises(function() return box:Apply(wood) end, "Got a Texture2D")
    return a and b and c, said_a .. " / " .. said_b .. " / " .. said_c
end)

-- three things in front of the camera: a box of numbers that blocks, a pyramid of numbers with a picture on it, a cube of the engine's
local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
local system = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local world = game.World.Raw
local camera = game.LocalPlayer.Raw.PlayerCameraManager
local eye, turn = camera:GetCameraLocation(), camera:GetCameraRotation()
local yaw = math.rad(turn.Yaw)
local middle = { X = eye.X + math.cos(yaw) * 450, Y = eye.Y + math.sin(yaw) * 450, Z = eye.Z - 20 }
local side = { X = -math.sin(yaw) * 140, Y = math.cos(yaw) * 140 }
local function transform(x, y, z, scale)
    return { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = scale, Y = scale, Z = scale } }
end
local actor, parts = nil, {}
local function line_from_above(at)
    local hit = {}
    local blocked = system:LineTraceSingle(world, { X = at.X, Y = at.Y, Z = at.Z + 80 }, { X = at.X, Y = at.Y, Z = at.Z + 5 }, 0, true, {}, 0, hit,
        false, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
    return blocked == true, blocked and (hit.ImpactPoint.Z - at.Z) or nil
end
local box_at = { X = middle.X - side.X, Y = middle.Y - side.Y, Z = middle.Z }
attempt("the things are put together", function()
    local cube = mine(function() return Assets:Load("/Engine/BasicShapes/Cube") end)
    actor = statics:BeginDeferredActorSpawnFromClass(world, StaticFindObject("/Script/Engine.Actor"), transform(middle.X, middle.Y, middle.Z, 1), 1, nil)
    local function part(class, x, y, scale)
        local where = #parts == 0 and transform(middle.X, middle.Y, middle.Z, scale) or transform(x, y, 0, scale)
        local made = actor:AddComponentByClass(StaticFindObject(class), false, where, true)
        made:SetMobility(2)
        actor:FinishAddComponent(made, false, where)
        parts[#parts + 1] = made
        return made
    end
    local centre = part("/Script/Engine.StaticMeshComponent", 0, 0, 0.6)
    local left = part("/Script/ProceduralMeshComponent.ProceduralMeshComponent", -side.X / 0.6, -side.Y / 0.6, 1 / 0.6)
    local right = part("/Script/ProceduralMeshComponent.ProceduralMeshComponent", side.X / 0.6, side.Y / 0.6, 1 / 0.6)
    statics:FinishSpawningActor(actor, transform(middle.X, middle.Y, middle.Z, 1))
    centre:SetStaticMesh(cube.Raw)
    centre:SetMaterial(0, wooden.Raw)
    centre:SetCollisionEnabled(0)
    local started = now()
    mine(function()
        box:Apply(game.wrap(left), { material = glow })
        pyramid:Apply(game.wrap(right), { material = rainbow })
    end)
    right:SetCollisionEnabled(0)
    local spent = (now() - started) * 1000
    return left:GetNumSections() == 1 and right:GetNumSections() == 1, ("two shapes put on in %.3f ms"):format(spent)
end)
attempt("the box of numbers stops a line from above at its top", function()
    local blocked, height = line_from_above(box_at)
    return blocked and math.abs(height - 30) < 1, ("blocked %s, %s above its middle"):format(tostring(blocked), tostring(height))
end)

-- what is held now
attempt("everything asked for is held for the one that asked", function()
    local stats = module.stats()
    -- five assets: the wood icon, the blueprint class, the two materials named by path, the cube
    return stats.held == stats.pinned and stats.assets == 5 and stats.textures == 1 and stats.materials == 4 and owner:size() >= 10,
        ("held %d (assets %d, textures %d, materials %d), the owner has %d registrations"):format(stats.held, stats.assets, stats.textures,
            stats.materials, owner:size())
end)
local released
attempt("Release lets one thing go, and its Instance says so", function()
    released = mine(function() return Assets:Material(GLOW) end)
    local held_before = module.stats().held
    local first = mine(function() return Assets:Release(released) end)
    local second = mine(function() return Assets:Release(released) end)
    local gone, said = raises(function() return released.Name end, "no longer exists")
    return first == true and second == false and gone and module.stats().held == held_before - 1, said
end)

-- the timed half: an icon that is held, one that is not, a collection, then everything let go and another collection
local function cold_icons(wanted)
    local found, looked = {}, 0
    local items = StaticFindObject("/Engine/Transient.D_Itemable")
    if not items:IsValid() then return found end
    local names = items:GetRowNames()
    for index = #names, 1, -1 do
        local ok, path = pcall(function() return items:FindRow(names[index]).Icon:GetObjectID():GetAssetPathName():ToString() end)
        if ok and module.check(path) and not found[path] then
            looked = looked + 1
            if not Assets:IsLoaded(path) then
                found[path] = true
                found[#found + 1] = path
            end
        end
        if #found >= wanted or looked >= 200 then break end
    end
    return found
end

local state = { done = false }
rawset(_G, "WaxAssetsLive", state)
local icons = cold_icons(2)
local held_icon
attempt("an icon that was not in memory is loaded and held, another is loaded and left to itself", function()
    if #icons < 2 then return false, "fewer than two icons were outside memory" end
    local started = now()
    held_icon = mine(function() return Assets:Load(icons[1]) end)
    local spent = (now() - started) * 1000
    local loose = LoadAsset(icons[2])
    return held_icon ~= nil and loose:IsValid(), ("%s in %.3f ms; left to itself: %s"):format(icons[1], spent, icons[2])
end)

local function finish()
    state.result = result()
    state.done = true
end

Wax.task.spawn(function()
    local ok, problem = pcall(function()
        system:CollectGarbage()
        Wax.task.wait(1.5)
        attempt("after a collection the held icon is in memory and the other is not", function()
            local held, loose = Assets:IsLoaded(icons[1]), Assets:IsLoaded(icons[2])
            return held == true and loose == false and held_icon.Name ~= nil, ("held %s, left to itself %s"):format(tostring(held), tostring(loose))
        end)
        attempt("the things were drawn", function()
            local drawn = 0
            for _, made in ipairs(parts) do
                if made:WasRecentlyRendered(1.5) then drawn = drawn + 1 end
            end
            return drawn == #parts, drawn .. " of " .. #parts .. " parts drawn in the last second and a half"
        end)
        Wax.task.wait(LOOK)
        local failures = owner:destroy()
        attempt("when the owner goes, everything it held is let go and its Instances say so", function()
            local stats = module.stats()
            local gone, said = raises(function() return held_icon.Name end, "no longer exists")
            local gone_too = raises(function() return glow.Name end, "no longer exists")
            return #failures == 0 and stats.held == 0 and gone and gone_too, ("held %d, spare holders %d; %s"):format(stats.held, stats.spare, said)
        end)
        attempt("the shapes it put on are taken off again", function()
            local blocked, height = line_from_above(box_at)
            return not (blocked and math.abs(height - 30) < 1), ("blocked %s at %s"):format(tostring(blocked), tostring(height))
        end)
        if actor then
            pcall(function() actor:K2_DestroyActor() end)
            actor, parts = nil, {}
        end
        system:CollectGarbage()
        Wax.task.wait(1.5)
        attempt("after another collection the icon that was held is out of memory", function()
            return Assets:IsLoaded(icons[1]) == false, icons[1]
        end)
    end)
    if not ok then check("the timed half ran through", false, tostring(problem)) end
    if actor then pcall(function() actor:K2_DestroyActor() end) end
    if owner.alive then owner:destroy() end
    finish()
end)

return result(true)
