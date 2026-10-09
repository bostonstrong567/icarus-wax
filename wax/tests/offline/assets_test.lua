-- Offline tests for game.Assets: loading by path, keeping things in memory, pictures from files, materials and meshes.
-- The engine, the interface's root and the garbage collector are stand-ins. A freed object raises on any use.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\assets_test.lua [scratch dir]

local t = dofile("wax/tests/offline/harness.lua")
local world = dofile("wax/tests/offline/fake_world.lua")
world.install()

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)

local INVALID = world.INVALID
local base = (arg[1] or "build/assets-test"):gsub("\\", "/")
local function win(path) return (path:gsub("/", "\\")) end
os.execute(('rmdir /s /q "%s" >nul 2>nul'):format(win(base)))
os.execute(('mkdir "%s\\MyMod\\pictures" >nul 2>nul'):format(win(base)))
local function write(name, bytes)
    local handle = assert(io.open(base .. "/MyMod/" .. name, "wb"))
    handle:write(bytes)
    handle:close()
end
write("logo.png", "\137PNG\r\n\26\n....")
write("pictures/icon.jpg", "\255\216\255\224....")
write("notes.png", "these are words, not a picture")
write("readme.txt", "words")
write("broken.png", "\137PNG\r\n\26\n....")
local MOD_DIR = base .. "/MyMod"
local cwd = nil
do
    local pipe = io.popen and io.popen("cd")
    if pipe then
        cwd = (pipe:read("l") or ""):gsub("\\", "/")
        pipe:close()
        if not cwd:match("^%a:/") then cwd = nil end
    end
end

-- classes
local object_class = world.class("/Script/CoreUObject.Object")
local class_class = world.class("/Script/CoreUObject.Class", object_class)
local blueprint_class = world.class("/Script/Engine.BlueprintGeneratedClass", class_class)
local world_class = world.class("/Script/Engine.World", object_class)
local actor_class = world.class("/Script/Engine.Actor", object_class)
local component_class = world.class("/Script/Engine.ActorComponent", object_class)
local scene_class = world.class("/Script/Engine.SceneComponent", component_class)
local primitive_class = world.class("/Script/Engine.PrimitiveComponent", scene_class)
local mesh_component_class = world.class("/Script/Engine.MeshComponent", primitive_class)
local static_part_class = world.class("/Script/Engine.StaticMeshComponent", mesh_component_class)
local procedural_class = world.class("/Script/ProceduralMeshComponent.ProceduralMeshComponent", mesh_component_class)
local texture_class = world.class("/Script/Engine.Texture", object_class)
local texture2d_class = world.class("/Script/Engine.Texture2D", texture_class)
local material_interface_class = world.class("/Script/Engine.MaterialInterface", object_class)
local material_class = world.class("/Script/Engine.Material", material_interface_class)
local material_instance_class = world.class("/Script/Engine.MaterialInstance", material_interface_class)
local constant_class = world.class("/Script/Engine.MaterialInstanceConstant", material_instance_class)
local dynamic_class = world.class("/Script/Engine.MaterialInstanceDynamic", material_instance_class)
local static_mesh_class = world.class("/Script/Engine.StaticMesh", object_class)
rawset(static_part_class, "__class", class_class)

-- the engine: what is on disk, what is in memory, and every call counted
local disk, memory, loose, always = {}, {}, {}, {}
local counts, calls = {}, 0
local engine = { load_raises = false, unreadable = {}, made = 0 }
local function count(name)
    calls = calls + 1
    counts[name] = (counts[name] or 0) + 1
end
local function reset_engine()
    counts, calls = {}, 0
    for key, object in pairs(memory) do
        rawset(object, "__freed", true)
        memory[key] = nil
    end
    for object in pairs(loose) do
        rawset(object, "__freed", true)
        loose[object] = nil
    end
    for _, entry in pairs(disk) do entry.loads = 0 end
    engine.load_raises, engine.unreadable = false, {}
end

-- An asset in the game's files. listed = false: the game's list does not name it. loadable = false: it cannot be loaded.
local function on_disk(full, class, options)
    local package, name = full:match("^(.-)%.([^.]+)$")
    local entry = { full = full, package = package, name = name, folder = package:match("^(.*)/[^/]+$"), class = class,
                    listed = true, loadable = true, used = false, loads = 0 }
    for key, value in pairs(options or {}) do entry[key] = value end
    disk[full:lower()] = entry
    return entry
end

local function bring(entry)
    local key = entry.full:lower()
    local object = memory[key]
    if object then return object end
    object = world.component(entry.class, entry.name, {})
    if entry.is_class then
        rawset(object, "__class", blueprint_class)
        rawset(object, "__super", actor_class)
        rawset(object, "__members", {})
        rawset(object, "__functions", {})
        rawset(object, "__kind", "UClass")
    end
    memory[key] = object
    entry.loads = entry.loads + 1
    return object
end

function LoadAsset(path)
    count("load")
    if engine.load_raises then error("LoadAsset: the game would not") end
    local entry = disk[tostring(path):lower()]
    if not entry or not entry.listed or not entry.loadable then return INVALID end
    return bring(entry)
end

local function listing(list, fits)
    local found = {}
    for _, entry in pairs(disk) do
        if entry.listed and fits(entry) then found[#found + 1] = entry end
    end
    table.sort(found, function(a, b) return a.full < b.full end)
    for _, entry in ipairs(found) do
        list[#list + 1] = { get = function() return { AssetName = world.name(entry.name), ObjectPath = world.name(entry.full) } end }
    end
    return #found > 0
end

local function library(path, functions)
    functions.IsValid = function() return true end
    world.static[path] = functions
end
library("/Script/Engine.Default__KismetSystemLibrary", {
    Conv_SoftObjPathToSoftObjRef = function(_, path)
        count("soft")
        return { path = path.AssetPathName }
    end,
    Conv_SoftObjectReferenceToObject = function(_, soft)
        count("in_memory")
        local key = soft.path:lower()
        return memory[key] or always[key] or INVALID
    end,
})
library("/Script/AssetRegistry.Default__AssetRegistryHelpers", {
    GetAsset = function(_, data)
        count("get")
        local entry = disk[data.ObjectPath:lower()]
        if not entry or not entry.loadable then return INVALID end
        t.eq(data.PackageName, entry.package, "GetAsset is given the package")
        t.eq(data.AssetName, entry.name, "GetAsset is given the name")
        return bring(entry)
    end,
})
library("/Script/AssetRegistry.Default__AssetRegistryImpl", {
    GetAssetsByPackageName = function(_, package, list, on_disk_only)
        count("by_package")
        t.eq(on_disk_only, true, "the list is asked for what is on disk, which is the quick way")
        return listing(list, function(entry) return entry.package:lower() == package:lower() end)
    end,
    GetAssetsByPath = function(_, folder, list, recursive, on_disk_only)
        count("by_path")
        t.eq(recursive, false)
        t.eq(on_disk_only, true)
        return listing(list, function(entry) return entry.folder:lower() == folder:lower() end)
    end,
})
library("/Script/Engine.Default__KismetRenderingLibrary", {
    ImportFileAsTexture2D = function(_, context, file)
        count("import")
        t.ok(context ~= nil and context:IsValid(), "a picture is read with the world as its context")
        if engine.unreadable[file] then return INVALID end
        engine.made = engine.made + 1
        local texture = world.component(texture2d_class, "Texture2D_" .. engine.made, { File = file })
        loose[texture] = true
        return texture
    end,
})
library("/Script/Engine.Default__KismetMaterialLibrary", {
    CreateDynamicMaterialInstance = function(_, context, parent, name, flags)
        count("material")
        t.ok(context ~= nil and context:IsValid(), "a material is made with the world as its context")
        t.eq(name, "None")
        t.eq(flags, 0)
        engine.made = engine.made + 1
        local made = world.component(dynamic_class, "MaterialInstanceDynamic_" .. engine.made, {
            Parent = parent, textures = {},
            SetTextureParameterValue = function(self, parameter, texture) self.textures[parameter] = texture end,
        })
        loose[made] = true
        return made
    end,
})
always["/script/engine.staticmeshcomponent"] = static_part_class

-- the interface's root: a canvas, and widgets that raise once their root is gone
local gui = { dead_touches = 0 }
local root_now = nil
local Widget, widget_methods = {}, {}
Widget.__index = function(self, key)
    if rawget(self, "__root").dead then
        gui.dead_touches = gui.dead_touches + 1
        error("touched a widget of an interface that is gone (" .. tostring(key) .. ")", 2)
    end
    if key == "Brush" then return { ResourceObject = rawget(self, "__resource") or INVALID } end
    return widget_methods[key]
end
function widget_methods.SetVisibility(self, value) rawset(self, "__visibility", value) end
function widget_methods.AddChild(self, child)
    local children = rawget(self, "__children")
    children[#children + 1] = child
end
function widget_methods.SetBrushResourceObject(self, object) rawset(self, "__resource", object) end
local function widget(kind)
    local made = setmetatable({ __root = root_now, __kind = kind, __children = {} }, Widget)
    root_now.widgets[#root_now.widgets + 1] = made
    return made
end
function gui.start()
    root_now = { dead = false, widgets = {} }
    root_now.canvas = widget("CanvasPanel")
end
function gui.lose()
    if root_now then root_now.dead = true end
    root_now = nil
end
function gui.count(kind)
    local found = 0
    for _, made in ipairs(root_now and root_now.widgets or {}) do
        if rawget(made, "__kind") == kind then found = found + 1 end
    end
    return found
end
Wax.modules["gui.root"] = {
    check = function() return root_now ~= nil end,
    canvas = function() return root_now and root_now.canvas end,
    new = function(kind)
        if not root_now then error("the GUI root does not exist", 2) end
        return widget(kind)
    end,
}

-- A collection: what no holder of the live interface names, and the game does not use itself, is freed.
local function collect()
    local held = {}
    for _, made in ipairs(root_now and root_now.widgets or {}) do
        local object = rawget(made, "__resource")
        if object then held[object] = true end
    end
    local freed = 0
    for key, object in pairs(memory) do
        if not held[object] and not (disk[key] and disk[key].used) then
            rawset(object, "__freed", true)
            memory[key] = nil
            freed = freed + 1
        end
    end
    for object in pairs(loose) do
        if not held[object] then
            rawset(object, "__freed", true)
            loose[object] = nil
            freed = freed + 1
        end
    end
    return freed
end

-- the world
local viewport = world.object("Viewport_0", { World = world.component(world_class, "Station_MAS", {}),
                                              GameInstance = world.object("GameInstance_0", {}) })
world.engine = world.object("Engine_0", { GameViewport = viewport })

local scope = Wax.import("core.scope")
local sched = Wax.import("core.sched")
local instance = Wax.import("engine.instance")
local game = Wax.import("engine.game")
game.start()
Wax.game = game.root

local warnings = {}
Wax.import("core.log").add_sink(function(entry, repeated)
    if entry.level == "warn" and not repeated then warnings[#warnings + 1] = entry.message end
end)

local mods = {}
Wax.mods = { get = function(id) return mods[id] end }

local now = 100
local function next_frame() sched.stats.frame = sched.stats.frame + 1 end
local function travel(name)
    rawget(viewport, "__props").World = world.component(world_class, name, {})
    game.step()
    next_frame()
end

-- A fresh module over an empty memory. interface = false: Wax's interface is not running.
local function fresh(options)
    options = options or {}
    local old = Wax.modules["world.assets"]
    if type(old) == "table" then old.stop() end
    Wax.modules["world.assets"] = nil
    gui.lose()
    reset_engine()
    if options.interface ~= false then gui.start() end
    warnings = {}
    next_frame()
    local module = Wax.import("world.assets")
    module.clock = function() return now end
    module.start()
    return module, game.root.Assets
end

-- A mod: its scope, in the mods list with the scratch folder as its own.
local function mod(id)
    local owner = scope.new(id)
    mods[id] = { id = id, dir = MOD_DIR, scope = owner }
    return owner, function(fn, ...) return scope.run(owner, fn, ...) end
end

local function first_line(text) return (tostring(text):match("^[^\r\n]*")) end
local function near(got, want, what)
    if type(got) ~= "number" or math.abs(got - want) > 0.0005 then
        error((what or "value") .. ": expected about " .. tostring(want) .. ", got " .. tostring(got), 2)
    end
end

local ICONS = "/Game/Assets/2DArt/UI/Items/Item_Icons/Resources"
local WOOD = ICONS .. "/ITEM_Wood.ITEM_Wood"
local HORN = ICONS .. "/T_ITEM_Flightless_Tank_Horn.T_ITEM_Flightless_Tank_Horn"
local CRUST = ICONS .. "/T_ITEM_Pyritic_Crust.T_ITEM_Pyritic_Crust"
local GLOW = "/Engine/EngineMaterials/EmissiveMeshMaterial.EmissiveMeshMaterial"
local SHOWS = "/Engine/EngineMaterials/Widget3DPassThrough_Opaque.Widget3DPassThrough_Opaque"
local CUBE = "/Engine/BasicShapes/Cube.Cube"
local HERO = "/Game/BP/Player/BP_Hero"
on_disk(WOOD, texture2d_class)
on_disk(HORN, texture2d_class)
on_disk(CRUST, texture2d_class)
on_disk(GLOW, material_class)
on_disk(SHOWS, constant_class)
on_disk(CUBE, static_mesh_class)
on_disk(HERO .. ".BP_Hero", object_class, { loadable = false })
on_disk(HERO .. ".BP_Hero_C", actor_class, { is_class = true })
on_disk("/Game/Mods/Mine/SM_Chair.SM_Chair", static_mesh_class, { listed = false })
on_disk("/Game/Broken/T_Torn.T_Torn", texture2d_class, { loadable = false })
on_disk("/Game/Lonely/Zebra.Zebra", texture2d_class)

t.test("game.Assets is there, says its name, and a member it lacks names a near one", function()
    local module, Assets = fresh()
    t.eq(tostring(Assets), "Assets")
    t.ok(rawequal(module.api, Assets))
    t.raises(function() return Assets.Laod end, "Laod is not a member of game.Assets. Did you mean 'Load'?")
    t.raises(function() Assets.Load = 1 end, "game.Assets.Load cannot be assigned because game.Assets is read-only")
    t.raises(function() Assets.Load(WOOD) end, "call Load with a colon: game.Assets:Load(path)")
    t.raises(function() Assets:Load(5) end, "expects the path of an asset such as \"/Game/Folder/Name\", got a number")
    t.raises(function() Assets:IsLoaded({}) end, "got a table")
end)

t.test("a path is read in its three forms", function()
    local module = fresh()
    local full, package, name = module.check("/Game/Folder/Name")
    t.eq(full, "/Game/Folder/Name.Name")
    t.eq(package, "/Game/Folder/Name")
    t.eq(name, "Name")
    t.eq(module.check("/Game/Folder/Name.Name"), "/Game/Folder/Name.Name")
    t.eq(module.check("/Game/Folder/BP_Thing.BP_Thing_C"), "/Game/Folder/BP_Thing.BP_Thing_C")
    t.eq(module.check("Texture2D'/Game/Folder/Name.Name'"), "/Game/Folder/Name.Name")
    t.eq(module.check("/Game/Name"), "/Game/Name.Name")
    t.eq(module.check("/Game/A-B/My-Name"), "/Game/A-B/My-Name.My-Name")
end)

t.test("what is not a path gives nil and why, and the engine is not asked", function()
    local _, Assets = fresh()
    local bad = { "", "None", "wood", "Game/Folder/Name", "/Game", "/Game/", "/Game/Folder/", "/Game//Name", "/Game/Folder/Name.Name.Name",
        "/Game/Folder/Na me", "/Game/Folder/Name:Part", "/Game/Folder/Name.", "/Game/Folder/Name.Na/me", "/Game/Folder/../Name",
        "/Game/Folder/Name\n", "C:/Game/Name.png", "/Game/" .. ("x"):rep(400), "'/Game/Folder/Name'" }
    for _, path in ipairs(bad) do
        local asset, why = Assets:Load(path)
        t.eq(asset, nil, path)
        t.ok(type(why) == "string" and why ~= "", "a reason for " .. path)
        local loaded, why_not = Assets:IsLoaded(path)
        t.eq(loaded, false, path)
        t.ok(type(why_not) == "string" and why_not ~= "", "a reason for " .. path)
    end
    t.eq(calls, 0, "no engine call was made for any of them")
    local _, why = Assets:Load("wood")
    t.eq(why, "'wood' is not the path of an asset. One looks like /Game/Folder/Name or /Game/Folder/Name.Name")
    t.eq(select(2, Assets:Load("")), "the path is empty")
    t.eq(select(2, Assets:Load("/Game/" .. ("x"):rep(400))), "the path is longer than 400 characters")
end)

t.test("Load gives an Instance, loads once and keeps it", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    local wood = mine(function() return Assets:Load(WOOD) end)
    t.ok(instance.is_instance(wood))
    t.eq(wood.Name, "ITEM_Wood")
    t.ok(wood:IsA("Texture2D"))
    t.eq(counts.load, 1)
    t.eq(counts.get, nil, "the second way is not needed")
    t.ok(rawequal(mine(function() return Assets:Load(WOOD) end), wood), "the same Instance")
    t.ok(rawequal(mine(function() return Assets:Load(ICONS .. "/ITEM_Wood") end), wood), "without the second half")
    t.ok(rawequal(mine(function() return Assets:Load("Texture2D'" .. WOOD .. "'") end), wood), "as the editor copies it")
    t.ok(rawequal(mine(function() return Assets:Load(WOOD:upper()) end), wood), "letter case does not matter")
    t.eq(counts.load, 1, "it was loaded once")
    t.eq(disk[WOOD:lower()].loads, 1)
    local stats = module.stats()
    t.eq(stats.held, 1)
    t.eq(stats.assets, 1)
    t.eq(stats.pinned, 1)
    t.eq(owner:size(), 1, "one registration with the mod, however often it asked")
    t.eq(gui.count("Image"), 1, "one holder")
    t.eq(gui.count("VerticalBox"), 1, "in one hidden box")
    owner:destroy()
end)

t.test("what the game's list does not name is loaded by its path alone", function()
    local _, Assets = fresh()
    local chair = Assets:Load("/Game/Mods/Mine/SM_Chair")
    t.ok(chair and chair:IsA("StaticMesh"))
    t.eq(counts.load, 1)
    t.eq(counts.get, 1)
end)

t.test("a load that raises is taken as a miss, and the other way is tried", function()
    local _, Assets = fresh()
    engine.load_raises = true
    local wood = Assets:Load(WOOD)
    t.ok(wood and wood.Name == "ITEM_Wood")
    t.eq(counts.get, 1)
end)

t.test("an asset that is in memory is not loaded again, and IsLoaded loads nothing", function()
    local module, Assets = fresh()
    t.eq(Assets:IsLoaded(WOOD), false)
    t.eq(counts.load, nil)
    bring(disk[WOOD:lower()])
    t.eq(Assets:IsLoaded(WOOD), true)
    t.eq(Assets:IsLoaded(ICONS .. "/ITEM_Wood"), true)
    local wood = Assets:Load(WOOD)
    t.ok(wood ~= nil)
    t.eq(counts.load, nil, "nothing was loaded")
    t.eq(module.stats().held, 1, "and it is held all the same")
end)

t.test("a held asset stays through a collection, and leaves once it is let go", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    local horn = mine(function() return Assets:Load(HORN) end)
    local raw_horn = horn.Raw
    LoadAsset(CRUST)
    t.eq(collect(), 1, "the one nobody holds is freed")
    next_frame()
    t.eq(Assets:IsLoaded(HORN), true)
    t.eq(Assets:IsLoaded(CRUST), false)
    t.eq(horn.Name, "T_ITEM_Flightless_Tank_Horn", "the Instance still answers")
    t.eq(owner:destroy()[1], nil, "no undo failed")
    t.eq(module.stats().held, 0)
    t.eq(module.stats().spare, 1, "the holder is kept for the next thing")
    t.raises(function() return horn.Name end, "no longer exists")
    t.eq(collect(), 1)
    t.eq(rawget(raw_horn, "__freed"), true)
    next_frame()
    t.raises(function() return horn.Name end, "no longer exists")
    t.eq(horn:IsValid(), false)
    t.eq(Assets:IsLoaded(HORN), false)
    local again = Assets:Load(HORN)
    t.ok(again ~= nil and not rawequal(again, horn), "asked again, it is loaded again")
    t.eq(disk[HORN:lower()].loads, 2)
    t.eq(gui.count("Image"), 1, "the spare holder was used")
    t.eq(world.dead_touches, 0, "nothing touched a freed object")
end)

t.test("an asset two mods asked for is kept until both are gone", function()
    local module, Assets = fresh()
    local first, as_first = mod("First")
    local second, as_second = mod("Second")
    local a = as_first(function() return Assets:Load(CUBE) end)
    local b = as_second(function() return Assets:Load(CUBE) end)
    t.ok(rawequal(a, b))
    t.eq(module.stats().held, 1)
    first:destroy()
    t.eq(module.stats().held, 1)
    collect()
    next_frame()
    t.eq(b.Name, "Cube")
    second:destroy()
    t.eq(module.stats().held, 0)
    t.raises(function() return b.Name end, "no longer exists")
end)

t.test("Release lets one thing go for the mod that asks", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    local other, as_other = mod("Other")
    local cube = mine(function() return Assets:Load(CUBE) end)
    local wood = mine(function() return Assets:Load(WOOD) end)
    t.eq(owner:size(), 2)
    t.eq(as_other(function() return Assets:Release(cube) end), false, "a mod that did not ask holds nothing")
    t.eq(module.stats().held, 2)
    t.eq(mine(function() return Assets:Release(cube) end), true)
    t.eq(mine(function() return Assets:Release(cube) end), false, "the second time there is nothing to let go")
    t.raises(function() return cube.Name end, "no longer exists")
    t.eq(owner:size(), 1, "its undo is forgotten")
    t.eq(mine(function() return Assets:Release(ICONS .. "/ITEM_Wood") end), true, "by the path it was asked for with")
    t.eq(module.stats().held, 0)
    t.eq(owner:size(), 0)
    t.eq(mine(function() return Assets:Release("/Game/Never/Held") end), false)
    t.eq(mine(function() return Assets:Release("not a path") end), false)
    t.raises(function() Assets:Release(5) end, "expects what Load, Texture or Material gave")
    t.eq(wood:IsValid(), false)
    owner:destroy()
    other:destroy()
end)

t.test("with no mod running a thing is held until it is released", function()
    local module, Assets = fresh()
    local wood = Assets:Load(WOOD)
    t.eq(module.stats().held, 1)
    collect()
    next_frame()
    t.eq(wood.Name, "ITEM_Wood")
    t.eq(Assets:Release(wood), true)
    t.eq(module.stats().held, 0)
end)

t.test("a misspelt name gives nil and the asset that is near, and is not asked again for five seconds", function()
    local module, Assets = fresh()
    local asset, why = Assets:Load(ICONS .. "/ITEM_Wod")
    t.eq(asset, nil)
    t.eq(why, "the game has no asset at " .. ICONS .. "/ITEM_Wod.ITEM_Wod. Did you mean '" .. WOOD .. "'?")
    t.eq(counts.load, 1)
    t.eq(counts.get, 1)
    t.eq(counts.by_package, 1)
    t.eq(counts.by_path, 1)
    local before = calls
    now = now + 4
    local again, same = Assets:Load(ICONS .. "/ITEM_Wod")
    t.eq(again, nil)
    t.eq(same, why)
    t.eq(calls - before, 2, "only asked whether it is in memory")
    t.eq(counts.load, 1)
    now = now + 2
    t.eq(select(2, Assets:Load(ICONS .. "/ITEM_Wod")), why)
    t.eq(counts.load, 2, "after five seconds it is tried again")
    t.eq(counts.by_path, 1, "and the reason is not worked out again")
    t.eq(module.stats().missing, 1)
    t.eq(module.stats().explained, 1)
    on_disk(ICONS .. "/ITEM_Wod.ITEM_Wod", texture2d_class)
    t.eq(Assets:Load(ICONS .. "/ITEM_Wod"), nil, "within five seconds the kept answer stands")
    module.forget_missing()
    local found = Assets:Load(ICONS .. "/ITEM_Wod")
    disk[(ICONS .. "/ITEM_Wod.ITEM_Wod"):lower()] = nil
    t.ok(found ~= nil, "once the misses are forgotten it is tried at once")
    t.eq(module.stats().missing, 0)
end)

t.test("the reason fits what the game's list says", function()
    local module, Assets = fresh()
    t.eq(select(2, Assets:Load(HERO)),
        "the game has no asset at " .. HERO .. ".BP_Hero. Did you mean '" .. HERO .. ".BP_Hero_C'?")
    local class = Assets:Load(HERO .. ".BP_Hero_C")
    t.ok(class and class.Name == "BP_Hero_C")
    t.eq(select(2, Assets:Load("/Game/WaxTest/Nothing")),
        "the game has no asset at /Game/WaxTest/Nothing.Nothing. The game has no assets in the folder /Game/WaxTest")
    t.eq(select(2, Assets:Load("/Game/Broken/T_Torn")), "the game lists /Game/Broken/T_Torn.T_Torn, but it could not be loaded")
    t.eq(select(2, Assets:Load("/Game/Lonely/Quartz")),
        "the game has no asset at /Game/Lonely/Quartz.Quartz. Nothing in the folder /Game/Lonely has a name like that")
    module.EXPLAINED = module.stats().explained
    t.eq(select(2, Assets:Load(ICONS .. "/ITEM_Wodd")), "the game has no asset at " .. ICONS .. "/ITEM_Wodd.ITEM_Wodd",
        "past the limit the plain reason is given")
    module.EXPLAINED, module.EXPLAIN = 24, false
    t.eq(select(2, Assets:Load(ICONS .. "/ITEM_Woood")), "the game has no asset at " .. ICONS .. "/ITEM_Woood.ITEM_Woood")
end)

t.test("a class of the engine is found and not held", function()
    local module, Assets = fresh()
    local class = Assets:Load("/Script/Engine.StaticMeshComponent")
    t.ok(class and class.Name == "StaticMeshComponent")
    t.eq(module.stats().held, 0)
    t.eq(Assets:Release(class), false)
    t.eq(class.Name, "StaticMeshComponent", "letting go of what was never held changes nothing")
end)

t.test("without the interface nothing can be held, and the log says so once", function()
    local module, Assets = fresh({ interface = false })
    local wood = Assets:Load(WOOD)
    t.ok(wood and wood.Name == "ITEM_Wood")
    t.ok(Assets:Load(CUBE) ~= nil)
    t.eq(module.stats().held, 0)
    t.eq(#warnings, 1)
    t.ok(warnings[1]:find("cannot keep things in memory", 1, true), warnings[1])
    gui.start()
    t.ok(rawequal(Assets:Load(WOOD), wood))
    t.eq(module.stats().held, 1, "once the interface runs, what is asked for is held")
end)

t.test("when the interface is built again everything is let go, and no old holder is touched", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    local wood = mine(function() return Assets:Load(WOOD) end)
    local logo = mine(function() return Assets:Texture("logo.png") end)
    local glow = mine(function() return Assets:Material(GLOW) end)
    t.eq(module.stats().held, 4)
    gui.lose()
    gui.start()
    local cube = mine(function() return Assets:Load(CUBE) end)
    local stats = module.stats()
    t.eq(stats.held, 1, "only what was asked for since")
    t.eq(stats.spare, 0)
    t.eq(owner:size(), 1)
    t.raises(function() return wood.Name end, "no longer exists")
    t.raises(function() return logo.Name end, "no longer exists")
    t.raises(function() return glow.Name end, "no longer exists")
    t.eq(cube.Name, "Cube")
    t.ok(warnings[#warnings]:find("let go of 4 things", 1, true), warnings[#warnings])
    t.eq(mine(function() return Assets:Release(wood) end), false)
    local again = mine(function() return Assets:Load(WOOD) end)
    t.ok(again ~= nil and not rawequal(again, wood))
    t.eq(owner:destroy()[1], nil)
    t.eq(module.stats().held, 0)
    t.eq(gui.dead_touches, 0, "no widget of the old interface was touched")
end)

t.test("forget_all lets everything go at once, for a mod and for the console, and touches no holder", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    local wood = mine(function() return Assets:Load(WOOD) end)
    local cube = Assets:Load(CUBE)
    t.eq(module.stats().held, 2)
    gui.lose()
    module.forget_all()
    t.eq(module.stats().held, 0)
    t.eq(owner:size(), 0, "the mod has nothing left to undo")
    t.raises(function() return wood.Name end, "no longer exists")
    t.raises(function() return cube.Name end, "no longer exists")
    t.ok(warnings[#warnings]:find("let go of 2 things", 1, true), warnings[#warnings])
    module.forget_all()
    gui.start()
    t.eq(mine(function() return Assets:Load(WOOD) end).Name, "ITEM_Wood")
    t.eq(module.stats().held, 1)
    t.eq(owner:destroy()[1], nil)
    t.eq(gui.dead_touches, 0, "no widget of the old interface was touched")
end)

t.test("when the interface is gone for good, letting go touches nothing", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    local wood = mine(function() return Assets:Load(WOOD) end)
    gui.lose()
    t.eq(owner:destroy()[1], nil)
    t.eq(module.stats().held, 0)
    t.raises(function() return wood.Name end, "no longer exists")
    t.eq(gui.dead_touches, 0)
end)

t.test("Texture reads a picture file of the mod and keeps it", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    local logo = mine(function() return Assets:Texture("logo.png") end)
    t.ok(logo:IsA("Texture2D"))
    t.eq(logo.Raw.File, MOD_DIR .. "/logo.png")
    t.eq(counts.import, 1)
    t.ok(rawequal(mine(function() return Assets:Texture("logo.png") end), logo), "the same texture")
    t.ok(rawequal(mine(function() return Assets:Texture("LOGO.PNG") end), logo), "Windows does not tell the letter case of a file name")
    t.eq(counts.import, 1, "the file is read once")
    local icon = mine(function() return Assets:Texture("pictures\\icon.jpg") end)
    t.eq(icon.Raw.File, MOD_DIR .. "/pictures/icon.jpg")
    t.eq(module.stats().textures, 2)
    collect()
    next_frame()
    t.eq(logo.Raw.File, MOD_DIR .. "/logo.png", "it stays through a collection")
    t.eq(mine(function() return Assets:Release("logo.png") end), true, "let go by its file name")
    t.raises(function() return logo.Name end, "no longer exists")
    owner:destroy()
    t.eq(module.stats().held, 0)
    t.eq(collect(), 2)
    t.eq(world.dead_touches, 0)
end)

t.test("a scope under the mod's own finds the mod's folder", function()
    local _, Assets = fresh()
    local owner = mod("MyMod")
    local window = scope.new("a window", owner)
    local logo = scope.run(window, function() return Assets:Texture("logo.png") end)
    t.eq(logo.Raw.File, MOD_DIR .. "/logo.png")
    window:destroy()
    t.raises(function() return logo.Name end, "no longer exists")
    local stranger = scope.new("MyMod")
    t.raises(function() scope.run(stranger, function() return Assets:Texture("logo.png") end) end, "Give the whole path")
    owner:destroy()
end)

t.test("a whole path is taken as it is", function()
    local _, Assets = fresh()
    t.raises(function() Assets:Texture("C:/WaxTest/nothing.png") end, "game.Assets:Texture: there is no file C:/WaxTest/nothing.png")
    t.raises(function() Assets:Texture("C:\\WaxTest\\nothing.png") end, "there is no file C:/WaxTest/nothing.png")
    if cwd or MOD_DIR:match("^%a:/") then
        local whole = (MOD_DIR:match("^%a:/") and MOD_DIR or cwd .. "/" .. MOD_DIR) .. "/logo.png"
        local logo = Assets:Texture(whole)
        t.eq(logo.Raw.File, whole)
        t.eq(Assets:Release(whole), true)
    end
end)

t.test("a file that cannot be a picture is refused before the game is asked", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    local function refused(file, fragment)
        t.raises(function() mine(function() return Assets:Texture(file) end) end, fragment, tostring(file))
    end
    refused("nothing.png", "game.Assets:Texture: there is no file " .. MOD_DIR .. "/nothing.png")
    refused("notes.png", MOD_DIR .. "/notes.png is not a PNG or JPG picture")
    refused("readme.txt", "'readme.txt' is not a .png or .jpg file")
    refused("logo", "'logo' is not a .png or .jpg file")
    refused("../MyMod/logo.png", "leaves the mod's folder")
    refused("pictures/../../x.png", "leaves the mod's folder")
    refused("", "the file name is empty")
    refused("lo*go.png", "'lo*go.png' is not a file name")
    refused(5, "expects the name of a picture file such as \"logo.png\", got a number")
    t.eq(counts.import, nil, "the game was not asked to read any of them")
    t.raises(function() Assets:Texture("logo.png") end, "'logo.png' is a file name, and no mod is running that it could belong to")
    engine.unreadable[MOD_DIR .. "/broken.png"] = true
    refused("broken.png", "the game could not read the picture " .. MOD_DIR .. "/broken.png")
    t.eq(module.stats().held, 0)
    t.eq(owner:size(), 0)
    owner:destroy()
end)

t.test("Material makes one from a material and sets colours, numbers and textures", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    local parent = mine(function() return Assets:Load(GLOW) end)
    local wood = mine(function() return Assets:Load(WOOD) end)
    local made = mine(function()
        return Assets:Material(parent, {
            colors = { Color = "#ff8800", Tint = "Grey", Edge = { R = 2, G = -1, B = 0.5 }, Bright = { R = 0, G = 3, B = 0.6, linear = true },
                       Faint = { 1, 1, 1, 0.25 }, Half = "#ffffff80", Plain = "gray" },
            numbers = { Glow = 4.5 },
            textures = { Picture = wood, Other = WOOD },
        })
    end)
    t.ok(made:IsA("MaterialInstanceDynamic"))
    local raw = made.Raw
    t.ok(rawequal(raw.Parent, parent.Raw), "it starts from the material given")
    near(raw.Color.R, 1)
    near(raw.Color.G, 0.2462)
    near(raw.Color.B, 0)
    t.eq(raw.Color.A, 1)
    near(raw.Tint.R, 0.2140)
    near(raw.Plain.G, 0.2140)
    near(raw.Edge.R, 1, "a value above 1 is cut")
    near(raw.Edge.G, 0, "a value below 0 is cut")
    near(raw.Edge.B, 0.2140)
    t.eq(raw.Bright.G, 3, "linear values go on as they are")
    t.eq(raw.Bright.B, 0.6)
    t.eq(raw.Faint.A, 0.25)
    near(raw.Half.A, 128 / 255)
    t.eq(raw.Glow, 4.5)
    t.ok(rawequal(raw.textures.Picture, wood.Raw))
    t.ok(rawequal(raw.textures.Other, wood.Raw))
    local stats = module.stats()
    t.eq(stats.materials, 1)
    t.eq(stats.assets, 2)
    local by_path = mine(function() return Assets:Material("/Engine/EngineMaterials/Widget3DPassThrough_Opaque") end)
    t.ok(not rawequal(by_path, made), "every call makes a new one")
    t.eq(by_path.Raw.Parent:GetFName():ToString(), "Widget3DPassThrough_Opaque")
    t.eq(module.stats().assets, 3, "a parent named by its path is loaded and held")
    t.eq(module.stats().materials, 2)
    collect()
    next_frame()
    t.eq(made.Raw.Glow, 4.5, "it stays through a collection")
    owner:destroy()
    t.eq(module.stats().held, 0)
    t.raises(function() return made.Name end, "no longer exists")
    t.eq(world.dead_touches, 0)
end)

t.test("a mistake in a material's options is refused in plain words and leaves nothing behind", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    local parent = mine(function() return Assets:Load(GLOW) end)
    local wood = mine(function() return Assets:Load(WOOD) end)
    local made = mine(function() return Assets:Material(parent) end)
    local held, materials = module.stats().held, counts.material
    local function refused(fragment, start, options)
        t.raises(function() mine(function() return Assets:Material(start, options) end) end, fragment, fragment)
    end
    refused("cannot start from a MaterialInstanceDynamic. Start from the material that one was made from", made)
    refused("expects a material of the game to start from: one from game.Assets:Load, or its path. Got a Texture2D", wood)
    refused("Got nothing", nil)
    refused("game.Assets:Material: 'glow' is not the path of an asset", "glow")
    refused("game.Assets:Material: the game has no asset at /Game/WaxTest/M_Nothing.M_Nothing", "/Game/WaxTest/M_Nothing")
    refused("the options are a table such as { colors = { Color = \"Red\" } }, got a string", parent, "Red")
    refused("game.Assets:Material has no option 'Colors'. Did you mean 'colors'?", parent, { Colors = {} })
    refused("game.Assets:Material: colors is a table of parameter names and values, got a string", parent, { colors = "Red" })
    refused("colors.Color: 'Oragne' is not a colour. Did you mean 'Orange'?", parent, { colors = { Color = "Oragne" } })
    refused("colors.Color is not a colour", parent, { colors = { Color = { R = 1, G = "x", B = 0 } } })
    refused("colors.Color is not a colour", parent, { colors = { Color = 5 } })
    refused("a parameter is named by a string such as \"Color\", got a number", parent, { colors = { "Red" } })
    refused("numbers.Glow is a number, got a string", parent, { numbers = { Glow = "4" } })
    refused("numbers.Glow is a number", parent, { numbers = { Glow = 0 / 0 } })
    refused("textures.Picture is a texture: one from game.Assets:Load or game.Assets:Texture, or the path of one. Got a Material",
        parent, { textures = { Picture = parent } })
    refused("textures.Picture: the game has no asset at /Game/WaxTest/T_Nothing.T_Nothing", parent,
        { textures = { Picture = "/Game/WaxTest/T_Nothing" } })
    refused("textures.Picture is a texture", parent, { textures = { Picture = 5 } })
    t.raises(function() Assets.Material(parent) end, "call Material with a colon")
    t.eq(counts.material, materials, "no material was made")
    t.eq(module.stats().held, held, "and nothing more is held")
    owner:destroy()
end)

t.test("a refused material gives back what the call asked for by path, and keeps what was held before", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    t.raises(function() mine(function() return Assets:Material(GLOW, { Colors = {} }) end) end, "Did you mean 'colors'?")
    t.eq(module.stats().held, 0, "the parent named by path is not kept for the mod")
    t.eq(owner:size(), 0, "and the mod has nothing to undo")
    t.raises(function() return Assets:Material(GLOW, { colors = { Color = "Oragne" } }) end, "Did you mean 'Orange'?")
    t.eq(module.stats().held, 0, "nor for the console")
    t.raises(function() mine(function() return Assets:Material(GLOW, { textures = { Picture = WOOD }, numbers = { Glow = "4" } }) end) end,
        "numbers.Glow is a number")
    t.eq(module.stats().held, 0)
    local parent = mine(function() return Assets:Load(GLOW) end)
    t.raises(function() mine(function() return Assets:Material(GLOW, { textures = { Picture = "/Game/WaxTest/T_Nothing" } }) end) end,
        "textures.Picture: the game has no asset")
    t.eq(module.stats().held, 1, "what the mod held before the call is still held")
    t.eq(parent.Name, "EmissiveMeshMaterial")
    local made = mine(function() return Assets:Material(GLOW, { textures = { Picture = WOOD } }) end)
    t.eq(module.stats().held, 3, "a call that works keeps the texture it named and the material")
    t.ok(made:IsValid())
    owner:destroy()
    t.eq(module.stats().held, 0)
end)

t.test("a map change lets materials go and keeps assets and pictures", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    local wood = mine(function() return Assets:Load(WOOD) end)
    local logo = mine(function() return Assets:Texture("logo.png") end)
    local glow = mine(function() return Assets:Material(GLOW) end)
    t.eq(module.stats().held, 4)
    travel("Terrain_016")
    local stats = module.stats()
    t.eq(stats.materials, 0)
    t.eq(stats.assets, 2)
    t.eq(stats.textures, 1)
    t.eq(owner:size(), 3, "the material's undo is forgotten")
    t.raises(function() return glow.Name end, "from before the last map change")
    t.eq(wood.Name, "ITEM_Wood", "what is still held keeps its Instance")
    t.eq(logo:IsValid(), true)
    collect()
    local loads, imports = counts.load, counts.import
    local wood_now = mine(function() return Assets:Load(WOOD) end)
    local logo_now = mine(function() return Assets:Texture("logo.png") end)
    t.eq(wood_now.Name, "ITEM_Wood")
    t.ok(rawequal(wood_now, wood), "asked again, it is the same Instance")
    t.eq(logo_now.Raw.File, MOD_DIR .. "/logo.png")
    t.eq(counts.load, loads, "nothing was loaded for it")
    t.eq(counts.import, imports, "and no file was read")
    t.eq(owner:size(), 3)
    t.eq(owner:destroy()[1], nil)
    t.eq(module.stats().held, 0)
    t.eq(wood_now:IsValid(), false)
    t.eq(world.dead_touches, 0)
    travel("Station_MAS")
end)

local function captured_part(name)
    local seen = { sections = {}, cleared = {}, materials = {} }
    local raw = world.component(procedural_class, name or "ProceduralMeshComponent_0", {
        CreateMeshSection_LinearColor = function(_, section, vertices, triangles, normals, uv0, uv1, uv2, uv3, colors, tangents, collision)
            if seen.refuse then error("the engine said no\nwith a second line") end
            seen.sections[section] = { vertices = vertices, triangles = triangles, normals = normals, uvs = uv0, colors = colors,
                collision = collision, empty = #uv1 + #uv2 + #uv3 + #tangents }
        end,
        SetMaterial = function(_, section, material) seen.materials[section] = material end,
        ClearMeshSection = function(_, section)
            seen.sections[section] = nil
            seen.cleared[#seen.cleared + 1] = section
        end,
    })
    return instance.wrap(raw), seen, raw
end

t.test("Mesh makes a box the way the engine lays one out", function()
    local _, Assets = fresh()
    local box = Assets:Mesh({ box = 60 })
    t.eq(box.VertexCount, 24)
    t.eq(box.TriangleCount, 12)
    t.eq(box.Size.X, 60)
    t.eq(tostring(box), "Mesh (24 vertices, 12 triangles)")
    t.eq(calls, 0, "nothing is asked of the engine to make one")
    local slab = Assets:Mesh({ box = { X = 100, Y = 50, Z = 20 } })
    t.eq(slab.Size.X, 100)
    t.eq(slab.Size.Y, 50)
    t.eq(slab.Size.Z, 20)
    local part, seen = captured_part()
    slab:Apply(part)
    local section = seen.sections[0]
    t.eq(#section.vertices, 24)
    t.eq(#section.triangles, 36)
    t.eq(#section.normals, 24)
    t.eq(#section.uvs, 24)
    t.eq(#section.colors, 0)
    t.eq(section.empty, 0)
    t.eq(section.collision, false)
    -- every side is flat and faces away from the middle
    for index, vertex in ipairs(section.vertices) do
        local normal = section.normals[index]
        local length = math.sqrt(normal.X ^ 2 + normal.Y ^ 2 + normal.Z ^ 2)
        near(length, 1, "normal " .. index)
        local along = normal.X * vertex.X + normal.Y * vertex.Y + normal.Z * vertex.Z
        t.ok(along > 0, "normal " .. index .. " faces outward")
        t.ok(math.abs(math.abs(normal.X) + math.abs(normal.Y) + math.abs(normal.Z) - 1) < 0.0005, "normal " .. index .. " is along one axis")
    end
    t.eq(section.vertices[1].X, -50)
    t.eq(section.vertices[1].Y, 25)
    t.eq(section.vertices[1].Z, 10)
    t.eq(section.uvs[1].X, 0)
    t.eq(section.uvs[3].Y, 1)
    for _, corner in ipairs(section.triangles) do t.ok(corner >= 0 and corner <= 23, "the engine counts vertices from 0") end
    local own_uvs = {}
    for index = 1, 24 do own_uvs[index] = { 0.5, 0.25 } end
    local painted = Assets:Mesh({ box = 10, uvs = own_uvs, collision = true })
    painted:Apply(part, { section = 1 })
    t.eq(seen.sections[1].uvs[7].X, 0.5, "uvs given with a box replace the box's own")
    t.eq(seen.sections[1].collision, true)
end)

t.test("Mesh takes vertices and triangles, and works the normals out", function()
    local _, Assets = fresh()
    local up = Assets:Mesh({ vertices = { { 0, 0, 0 }, { X = 100, Y = 0, Z = 0 }, { 0, 100, 0 } }, triangles = { 1, 3, 2 } })
    t.eq(up.VertexCount, 3)
    t.eq(up.TriangleCount, 1)
    t.eq(up.Size.X, 100)
    t.eq(up.Size.Z, 0)
    local part, seen = captured_part()
    up:Apply(part)
    local section = seen.sections[0]
    t.eq(section.triangles[1], 0)
    t.eq(section.triangles[2], 2)
    t.eq(section.triangles[3], 1)
    near(section.normals[1].Z, 1, "corners that run counter-clockwise seen from above face up")
    t.eq(#section.uvs, 0)
    Assets:Mesh({ vertices = { { 0, 0, 0 }, { 100, 0, 0 }, { 0, 100, 0 } }, triangles = { 1, 2, 3 } }):Apply(part)
    near(seen.sections[0].normals[1].Z, -1, "the other way round faces down")
    local full = Assets:Mesh({
        vertices = { { 0, 0, 0 }, { 100, 0, 0 }, { 0, 100, 0 }, { 0, 0, 0 } }, triangles = { 1, 3, 2, 4.0, 4, 4 },
        normals = { { 0, 0, 1 }, { 0, 0, 1 }, { X = 0, Y = 1, Z = 0 }, { 0, 0, 1 } },
        uvs = { { 0, 0 }, { X = 1, Y = 0 }, { U = 0, V = 1 }, { 0, 0 } },
        colors = { "Red", "#00ff00", { R = 0, G = 0, B = 1, A = 0.5 }, { 0.25, 0.5, 0.75 } },
    })
    full:Apply(part)
    section = seen.sections[0]
    t.eq(section.normals[3].Y, 1, "normals that are given go on as they are")
    t.eq(section.uvs[2].X, 1)
    t.eq(section.uvs[3].Y, 1)
    t.eq(section.colors[1].R, 1)
    t.eq(section.colors[1].G, 0.05)
    t.eq(section.colors[2].G, 1)
    t.eq(section.colors[3].A, 0.5)
    t.eq(section.colors[4].B, 0.75, "a vertex colour goes on as it is given")
    local flat = Assets:Mesh({ vertices = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }, triangles = { 1, 2, 3 } })
    flat:Apply(part)
    t.eq(seen.sections[0].normals[1].Z, 1, "a triangle with no area gets a normal all the same")
end)

t.test("a shape that cannot be is refused in plain words", function()
    local module, Assets = fresh()
    local three = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } }
    local function refused(fragment, shape) t.raises(function() Assets:Mesh(shape) end, fragment, fragment) end
    refused("expects a shape: { vertices = { ... }, triangles = { ... } } or { box = 100 }. Got a string", "box")
    refused("game.Assets:Mesh has no option 'Collision'. Did you mean 'collision'?", { box = 60, Collision = true })
    refused("game.Assets:Mesh has no option 'Vertices'. Did you mean 'vertices'?", { Vertices = three, triangles = { 1, 2, 3 } })
    refused("give box, or vertices and triangles, not both", { box = 60, vertices = three })
    refused("box is its size: one number, or { X = 100, Y = 50, Z = 20 }, each above 0", { box = 0 })
    refused("box is its size", { box = { X = 1, Y = 1 } })
    refused("box is its size", { box = "big" })
    refused("vertices is a list of at least 3 positions", { triangles = { 1, 2, 3 } })
    refused("vertices is a list of at least 3 positions", { vertices = { { 0, 0, 0 }, { 1, 0, 0 } }, triangles = { 1, 2, 1 } })
    refused("vertex 2 is not three numbers. Give { X = 0, Y = 0, Z = 0 } or { 0, 0, 0 }",
        { vertices = { { 0, 0, 0 }, { 1, 0 }, { 0, 1, 0 } }, triangles = { 1, 2, 3 } })
    refused("vertex 3 is not three numbers", { vertices = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 1 / 0 } }, triangles = { 1, 2, 3 } })
    refused("triangles is a list of vertex numbers, three for each triangle, counted from 1", { vertices = three })
    refused("triangles is a list of vertex numbers", { vertices = three, triangles = { 1, 2, 3, 1 } })
    refused("triangles entry 3 is 4. It has to be the number of a vertex, from 1 to 3", { vertices = three, triangles = { 1, 2, 4 } })
    refused("triangles entry 1 is 0. It has to be the number of a vertex, from 1 to 3", { vertices = three, triangles = { 0, 1, 2 } })
    refused("triangles entry 2 is 1.5", { vertices = three, triangles = { 1, 1.5, 2 } })
    refused("normals needs one entry for each of the 3 vertices, got 2 entries",
        { vertices = three, triangles = { 1, 2, 3 }, normals = { { 0, 0, 1 }, { 0, 0, 1 } } })
    refused("normal 1 is not three numbers", { vertices = three, triangles = { 1, 2, 3 }, normals = { "up", "up", "up" } })
    refused("uvs needs one entry for each of the 3 vertices", { vertices = three, triangles = { 1, 2, 3 }, uvs = { { 0, 0 } } })
    refused("uv 2 is not two numbers. Give { X = 0, Y = 0 } or { 0, 0 }",
        { vertices = three, triangles = { 1, 2, 3 }, uvs = { { 0, 0 }, { 0 }, { 1, 1 } } })
    refused("colors needs one entry for each of the 3 vertices, got a string", { vertices = three, triangles = { 1, 2, 3 }, colors = "Red" })
    refused("colors entry 2: 'Yelow' is not a colour. Did you mean 'Yellow'?",
        { vertices = three, triangles = { 1, 2, 3 }, colors = { "Red", "Yelow", "Blue" } })
    refused("collision is true or false", { box = 10, collision = "yes" })
    module.MAX_VERTICES = 23
    refused("24 vertices is more than the 23 a mesh made in Lua can have. A model that large belongs in a cooked asset", { box = 10 })
    module.MAX_VERTICES = 65000
    t.raises(function() Assets.Mesh({ box = 10 }) end, "call Mesh with a colon")
    local box = Assets:Mesh({ box = 10 })
    t.raises(function() box.VertexCount = 3 end, "Mesh.VertexCount cannot be assigned: make another mesh with game.Assets:Mesh")
    t.raises(function() box.Apply = print end, "Mesh.Apply cannot be assigned")
    t.raises(function() return box.Vertexes end, "Vertexes is not a member of a mesh.")
    box.Size.X = 500
    t.eq(box.Size.X, 10, "the size that is handed out is a copy")
    t.eq(box.VertexCount, 24)
    t.eq(calls, 0)
end)

t.test("Apply puts the shape on a part with its options, and refuses what is not one", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    local part, seen = captured_part()
    local glow = mine(function() return Assets:Material(GLOW) end)
    local wood = mine(function() return Assets:Load(WOOD) end)
    local box = Assets:Mesh({ box = 60, collision = true })
    mine(function() box:Apply(part, { section = 2, material = glow, collision = false }) end)
    t.eq(#seen.sections[2].vertices, 24)
    t.eq(seen.sections[2].collision, false, "the option goes before the shape's own answer")
    t.ok(rawequal(seen.materials[2], glow.Raw))
    mine(function() box:Apply(part) end)
    t.eq(seen.sections[0].collision, true, "the shape's own answer")
    t.eq(seen.materials[0], nil)
    t.eq(module.stats().applied, 2)
    local function refused(fragment, target, options)
        t.raises(function() mine(function() box:Apply(target, options) end) end, fragment, fragment)
    end
    refused("mesh:Apply expects the part the shape goes on: an Instance of a ProceduralMeshComponent. Got a Texture2D", wood)
    refused("Got a table", {})
    refused("Got nothing", nil)
    refused("mesh:Apply: the options are a table such as { material = material }, got a number", part, 1)
    refused("mesh:Apply has no option 'Material'. Did you mean 'material'?", part, { Material = glow })
    refused("mesh:Apply: section is a whole number from 0 to 15, got 16", part, { section = 16 })
    refused("section is a whole number from 0 to 15, got -1", part, { section = -1 })
    refused("section is a whole number from 0 to 15, got 1.5", part, { section = 1.5 })
    refused("mesh:Apply: material is a material from game.Assets:Material or game.Assets:Load, got a Texture2D", part, { material = wood })
    refused("mesh:Apply: collision is true or false", part, { collision = 1 })
    t.raises(function() box.Apply(part) end, "call Apply with a colon on a mesh from game.Assets:Mesh: mesh:Apply(part)")
    seen.refuse = true
    t.eq(first_line(t.raises(function() mine(function() box:Apply(part, { section = 5 }) end) end, "mesh:Apply: the game refused the shape")):match("the engine said no$"),
        "the engine said no", "one line of what the engine said")
    t.eq(module.stats().applied, 2)
    owner:destroy()
end)

t.test("when the mod goes, the shapes it put on are taken off again", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    local part, seen = captured_part("ProceduralMeshComponent_1")
    local gone, gone_seen, gone_raw = captured_part("ProceduralMeshComponent_2")
    local box = Assets:Mesh({ box = 60 })
    mine(function()
        box:Apply(part)
        box:Apply(part)
        box:Apply(part, { section = 3 })
        box:Apply(gone)
    end)
    t.eq(owner:size(), 3, "one registration for each part and section")
    t.eq(module.stats().applied, 3)
    instance.retire(instance.address(gone))
    rawset(gone_raw, "__freed", true)
    t.eq(owner:destroy()[1], nil)
    table.sort(seen.cleared)
    t.eq(#seen.cleared, 2)
    t.eq(seen.cleared[1], 0)
    t.eq(seen.cleared[2], 3)
    t.eq(seen.sections[0], nil)
    t.eq(#gone_seen.cleared, 0, "a part that is gone is not touched")
    t.eq(module.stats().applied, 0)
    t.eq(world.dead_touches, 0)
end)

t.test("a shape put on with no mod running stays", function()
    local module, Assets = fresh()
    local part, seen = captured_part("ProceduralMeshComponent_3")
    Assets:Mesh({ box = 60 }):Apply(part)
    t.eq(#seen.sections[0].vertices, 24)
    t.eq(module.stats().applied, 1)
    module.stop()
    t.eq(#seen.cleared, 0)
end)

t.test("a great many held things are said once", function()
    local module, Assets = fresh()
    module.MANY = 3
    local owner, mine = mod("MyMod")
    mine(function()
        for _ = 1, 5 do Assets:Material(GLOW) end
    end)
    local said = 0
    for _, line in ipairs(warnings) do
        if line:find("made once and kept", 1, true) then said = said + 1 end
    end
    t.eq(said, 1)
    t.eq(module.stats().held, 6)
    owner:destroy()
end)

t.test("stop lets everything go and takes game.Assets away", function()
    local module, Assets = fresh()
    local owner, mine = mod("MyMod")
    local wood = mine(function() return Assets:Load(WOOD) end)
    local loose_one = Assets:Load(CUBE)
    local listening = game.root.MapChanged.count
    module.stop()
    t.eq(module.stats().held, 0)
    t.eq(owner:size(), 0)
    t.eq(rawget(game.root, "Assets"), nil)
    t.eq(game.root.MapChanged.count, listening - 1, "it no longer listens for a map change")
    t.raises(function() return wood.Name end, "no longer exists")
    t.raises(function() return loose_one.Name end, "no longer exists")
    t.eq(collect(), 2)
    owner:destroy()
    t.eq(world.dead_touches, 0)
    t.eq(gui.dead_touches, 0)
end)

t.test("this version of the game lacking a library is said in plain words, once", function()
    local module, Assets = fresh()
    local kept = world.static["/Script/AssetRegistry.Default__AssetRegistryHelpers"]
    world.static["/Script/AssetRegistry.Default__AssetRegistryHelpers"] = nil
    local why = "game.Assets does not work with this version of the game: it has no /Script/AssetRegistry.Default__AssetRegistryHelpers"
    t.raises(function() Assets:Load(WOOD) end, why)
    world.static["/Script/AssetRegistry.Default__AssetRegistryHelpers"] = kept
    t.raises(function() Assets:IsLoaded(WOOD) end, why)
    t.eq(calls, 0)
    t.eq(module.stats().held, 0)
end)

os.execute(('rmdir /s /q "%s" >nul 2>nul'):format(win(base)))
t.finish("assets")
