-- game.Assets: the game's assets by path, pictures from files, materials made from the game's own, and meshes made of numbers

local Wax = ...
local instance = Wax.import("engine.instance")
local scope = Wax.import("core.scope")
local suggest = Wax.import("core.suggest")
local sched = Wax.import("core.sched")
local log = Wax.import("core.log").channel("wax.assets")

local M = {}

M.EXPLAIN = true            -- a path that gives nothing is looked up in the game's list of assets, to say what is near it
M.EXPLAINED = 24            -- how many such lookups a session: each leaves a few kilobytes behind in UE4SS
M.RETRY = 5                 -- seconds before a path that gave nothing is tried again
M.MAX_VERTICES = 65000      -- UE4SS hands vertices over one at a time: a bigger model belongs in a cooked asset
M.MAX_SECTION = 15          -- the highest section of a part a mesh can go on
M.MANY = 2000               -- held things at which the log says once that something is being made over and over
M.clock = function() return sched.clock() end

local MAX_PATH, MAX_MISSING, MAX_APPLIED = 400, 256, 256
local COLLAPSED = 1
local PNG, JPG = "\137PNG\r\n\26\n", "\255\216\255"
local NAMES = { "Load", "IsLoaded", "Texture", "Material", "Mesh", "Release" }
local MATERIAL_OPTIONS = { "colors", "numbers", "textures" }
local SHAPE_OPTIONS = { "vertices", "triangles", "normals", "uvs", "colors", "collision", "box" }
local APPLY_OPTIONS = { "section", "material", "collision" }
local COLORS = { "Red", "Orange", "Yellow", "Green", "Cyan", "Blue", "Purple", "Magenta", "Pink", "White", "Grey", "Black" }
local NAMED = {
    red = { 1, 0.05, 0.05 }, orange = { 1, 0.4, 0 }, yellow = { 1, 1, 0 }, green = { 0, 1, 0.35 }, cyan = { 0, 1, 1 },
    blue = { 0, 0.53, 1 }, purple = { 0.55, 0.2, 1 }, magenta = { 1, 0, 1 }, pink = { 1, 0.35, 0.65 },
    white = { 1, 1, 1 }, grey = { 0.5, 0.5, 0.5 }, black = { 0, 0, 0 },
}
local NOBODY = { name = "wax" }     -- stands for the caller while no mod is running: the console, the bridge
local DATA = {}                     -- where a mesh keeps its numbers, out of a mod's reach

local wrap = instance.wrap
local engine, engine_problem = nil, nil
local entries = {}          -- key -> what is held, and for whom
local by_address = {}       -- engine address -> its entry, so an Instance finds it without the engine being asked
local missing = {}          -- key -> { why, at }: a path that gave nothing
local missing_count, explained, held_count, serial = 0, 0, 0, 0
local bank, bank_canvas, free = nil, nil, {}    -- the hidden box of holders, the root it sits under, holders with nothing in them
local applied, applied_count = {}, 0            -- part and section -> who put a mesh there
local warned_unheld, warned_many = false, false
local taking = nil                              -- while a material is put together: what the call claimed, given back if it fails
local Assets, Mesh = {}, {}         -- game.Assets and a mesh hold nothing themselves, so nothing of them can be replaced
local members, mesh_members = {}, {}
local MESH_NAMES = { "VertexCount", "TriangleCount", "Size", "Apply" }

local function first_line(problem) return (tostring(problem):match("^[^\r\n]*")) end

local function usable(object) return object ~= nil and object:IsValid() end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function describe(value)
    if instance.is_instance(value) then return "a " .. tostring(value.ClassName) end
    if value == nil then return "nothing" end
    return "a " .. type(value)
end

-- Raises for a key the option table should not have, so a misspelt option is not silently skipped.
local function known_keys(options, names, what, level)
    for key in pairs(options) do
        local found = false
        for _, name in ipairs(names) do found = found or key == name end
        if not found then
            error(("%s has no option '%s'.%s"):format(what, tostring(key), suggest.phrase(tostring(key), names)), level + 1)
        end
    end
end

local function need(path)
    local found = StaticFindObject(path)
    if not found:IsValid() then error(path, 0) end
    return found
end

-- The engine objects every call goes through, looked up at first use. A miss costs tens of milliseconds, so it is remembered.
local function engine_now(level)
    if engine then return engine end
    if not engine_problem then
        local ok, found = pcall(function()
            return {
                system = need("/Script/Engine.Default__KismetSystemLibrary"),
                helpers = need("/Script/AssetRegistry.Default__AssetRegistryHelpers"),
                registry = need("/Script/AssetRegistry.Default__AssetRegistryImpl"),
                materials = need("/Script/Engine.Default__KismetMaterialLibrary"),
                rendering = need("/Script/Engine.Default__KismetRenderingLibrary"),
            }
        end)
        if ok then
            engine = found
            return engine
        end
        engine_problem = ("game.Assets does not work with this version of the game: it has no %s"):format(first_line(found))
        log:error("%s", engine_problem)
    end
    error(engine_problem, level + 1)
end

local function world_now(level)
    local game = Wax.game
    local world = game and game.World
    if not world then error("there is no world right now, so nothing can be made", level + 1) end
    return world.Raw
end

local function raw_of(value, what, level)
    local ok, raw = pcall(function() return value.Raw end)
    if not ok then error(("%s: %s"):format(what, first_line(raw)), level + 1) end
    return raw
end

-- "/Game/Folder/Name" or "/Game/Folder/Name.Name", also the way the editor copies it: Texture2D'/Game/Folder/Name.Name'.
-- Returns the whole path, its package and its name, or nil and why. No engine call is made for a path this refuses.
local function check_path(path)
    local inner = path:match("^[%w_]+'(.*)'$")
    if inner then path = inner end
    if path == "" or path == "None" then return nil, "the path is empty" end
    if #path > MAX_PATH then return nil, ("the path is longer than %d characters"):format(MAX_PATH) end
    local package, name = path:match("^([^.]+)%.([^.]+)$")
    if not package and not path:find(".", 1, true) then package, name = path, path:match("([^/]+)$") end
    if not package or not name or not package:match("^/[%w_]+/[%w_/%-]+$") or package:find("//", 1, true)
        or package:sub(-1) == "/" or not name:match("^[%w_%-]+$") then
        return nil, ("'%s' is not the path of an asset. One looks like /Game/Folder/Name or /Game/Folder/Name.Name"):format(path)
    end
    return package .. "." .. name, package, name
end
M.check = check_path

local function in_memory(e, full)
    local object = e.system:Conv_SoftObjectReferenceToObject(e.system:Conv_SoftObjPathToSoftObjRef({ AssetPathName = FName(full) }))
    if usable(object) then return object end
    return nil
end

-- By the game's list of assets first, then by the path alone, which also finds what the list does not name. Neither raises on a miss.
local function load(e, full, package, name)
    local ok, object = pcall(LoadAsset, full)
    if ok and usable(object) then return object end
    ok, object = pcall(function()
        return e.helpers:GetAsset({ ObjectPath = FName(full), PackageName = FName(package), AssetName = FName(name) })
    end)
    if ok and usable(object) then return object end
    return nil
end

local function listed(list)
    local names, paths = {}, {}
    for index = 1, #list do
        local data = list[index]:get()
        local name = data.AssetName:ToString()
        names[#names + 1] = name
        paths[name] = data.ObjectPath:ToString()
    end
    return names, paths
end

local function quoted(names, paths)
    local out = {}
    for index, name in ipairs(names) do out[index] = "'" .. (paths and paths[name] or name) .. "'" end
    local last = table.remove(out)
    return (#out > 0 and (table.concat(out, ", ") .. " or ") or "") .. last
end

-- Why a path gave nothing: its file holds another name, or its folder holds a near one. Asks the game's list of what is on disk.
local function explain(e, full, package, name)
    local plain = ("the game has no asset at %s"):format(full)
    if not M.EXPLAIN or explained >= M.EXPLAINED then return plain end
    explained = explained + 1
    local ok, text = pcall(function()
        local list = {}
        e.registry:GetAssetsByPackageName(FName(package), list, true)
        local names, paths = listed(list)
        local others, asked = {}, name:lower()
        for _, other in ipairs(names) do
            if other:lower() ~= asked then others[#others + 1] = other end
        end
        if #others > 0 then return ("%s. Did you mean %s?"):format(plain, quoted(others, paths)) end
        if #names > 0 then return ("the game lists %s, but it could not be loaded"):format(full) end
        local folder, file = package:match("^(.*)/([^/]+)$")
        list = {}
        e.registry:GetAssetsByPath(FName(folder), list, false, true)
        names, paths = listed(list)
        if #names == 0 then return ("%s. The game has no assets in the folder %s"):format(plain, folder) end
        local near = suggest.suggest(file, names, 3)
        if #near == 0 then return ("%s. Nothing in the folder %s has a name like that"):format(plain, folder) end
        return ("%s. Did you mean %s?"):format(plain, quoted(near, paths))
    end)
    return ok and text or plain
end

local function owner_now()
    local owner = scope.current()
    if owner and owner.alive then return owner end
    return NOBODY
end

-- The interface was built again: what its old root held is no longer held, and nothing under that root may be touched.
local function lose_all()
    local count = 0
    for _, entry in pairs(entries) do
        count = count + 1
        for owner, slot in pairs(entry.owners) do
            if slot ~= true then owner:remove(slot) end
        end
        instance.retire(entry.address)
    end
    entries, by_address, held_count = {}, {}, 0
    bank, bank_canvas, free = nil, nil, {}
    if count > 0 then log:warn("the interface was built again, so game.Assets let go of %d things. Ask for them again", count) end
end

-- The interface's root canvas while it is alive. Notices first when it is not the one the holders sit under.
local function canvas_now()
    local loaded, gui = pcall(Wax.import, "gui.root")
    local canvas = nil
    if loaded then
        local checked, alive = pcall(gui.check)
        if checked and alive then canvas = gui.canvas() end
    end
    if bank and (canvas == nil or not rawequal(canvas, bank_canvas)) then lose_all() end
    return canvas, gui
end

-- Gives the object to a hidden image, which is what keeps the engine from freeing it. False while there is no interface.
local function pin(entry, object)
    local canvas, gui = canvas_now()
    if not canvas then
        if not warned_unheld then
            warned_unheld = true
            log:warn("Wax's interface is not running, so game.Assets cannot keep things in memory. "
                .. "What nothing else uses is freed within minutes: ask for it again right before it is used")
        end
        return false
    end
    if not bank then
        local box = gui.new("VerticalBox")
        box:SetVisibility(COLLAPSED)
        canvas:AddChild(box)
        bank, bank_canvas, free = box, canvas, {}
    end
    local image = table.remove(free)
    if not image then
        image = gui.new("Image")
        bank:AddChild(image)
    end
    image:SetBrushResourceObject(object)
    entry.image = image
    return true
end

-- What an entry holds, handed over afresh by its holder. Only asked after canvas_now() has said the holders are still there.
local function held_object(entry)
    local object = entry.image.Brush.ResourceObject
    if object:IsValid() then return object end
    return nil
end

-- Its Instance answers with an error from now on: what is no longer held may be freed at any time.
local function let_go(entry)
    if entries[entry.key] == entry then
        entries[entry.key] = nil
        held_count = held_count - 1
    end
    if by_address[entry.address] == entry then by_address[entry.address] = nil end
    local image = entry.image
    entry.image = nil
    if not (canvas_now() and bank) then
        instance.retire(entry.address)
        return
    end
    -- held until now, so its Instance may be asked. One from before a map change says no without the engine, and is left alone.
    local current = entry.instance ~= nil and entry.instance:IsValid()
    if pcall(function() image:SetBrushResourceObject(nil) end) then free[#free + 1] = image end
    if current then instance.retire(entry.address) end
end

local function drop(entry, owner, by_scope)
    local slot = entry.owners[owner]
    if not slot then return false end
    entry.owners[owner] = nil
    entry.count = entry.count - 1
    if not by_scope and slot ~= true then owner:remove(slot) end
    if entry.count <= 0 then let_go(entry) end
    return true
end

local function claim(entry, owner)
    if entry.owners[owner] then return end
    entry.owners[owner] = true
    entry.count = entry.count + 1
    if owner ~= NOBODY then
        entry.owners[owner] = owner:add(function() drop(entry, owner, true) end) or true
    end
    if taking then taking[#taking + 1] = { entry, owner } end
end

-- Keeps `object` for `owner` under `key` and returns its Instance. What cannot be held is handed over all the same.
local function hold(key, kind, label, object, owner)
    local entry = entries[key]
    local address = object:GetAddress()
    if not entry then
        entry = { key = key, kind = kind, label = label, owners = {}, count = 0, address = address }
        local ok, pinned = pcall(pin, entry, object)
        if not ok then log:warn("%s could not be kept in memory: %s", label, first_line(pinned)) end
        if not ok or not pinned then return wrap(object) end
        entries[key] = entry
        by_address[address] = entry
        held_count = held_count + 1
        if held_count >= M.MANY and not warned_many then
            warned_many = true
            log:warn("game.Assets holds %d things for mods. A material or a picture is made once and kept, not made again every frame", held_count)
        end
    elseif entry.address ~= address then
        -- the holder was found empty and the asset loaded again
        entry.image:SetBrushResourceObject(object)
        if by_address[entry.address] == entry then by_address[entry.address] = nil end
        entry.address = address
        by_address[address] = entry
    end
    claim(entry, owner)
    entry.instance = wrap(object)
    return entry.instance
end

local function colon(self, name, arguments)
    if self ~= Assets then error(("call %s with a colon: game.Assets:%s(%s)"):format(name, name, arguments), 3) end
end

-- Loads an asset of the game by its path and keeps it in memory for the mod that asked, until that mod unloads.
function members:Load(path)
    colon(self, "Load", "path")
    if type(path) ~= "string" then
        error(("game.Assets:Load expects the path of an asset such as \"/Game/Folder/Name\", got %s"):format(describe(path)), 2)
    end
    local full, package, name = check_path(path)
    if not full then return nil, package end
    local e = engine_now(2)
    local owner = owner_now()
    canvas_now()
    local key = "a:" .. full:lower()
    local entry = entries[key]
    local object = entry and held_object(entry) or in_memory(e, full)
    if not object then
        local miss, now = missing[key], M.clock()
        if miss and now - miss.at < M.RETRY then return nil, miss.why end
        object = load(e, full, package, name)
        if not object then
            if not miss then
                if missing_count >= MAX_MISSING then missing, missing_count = {}, 0 end
                miss = { why = explain(e, full, package, name) }
                missing[key] = miss
                missing_count = missing_count + 1
            end
            miss.at = now
            return nil, miss.why
        end
    end
    if missing[key] then
        missing[key] = nil
        missing_count = missing_count - 1
    end
    -- what the engine itself is made of is never freed, so it is not held
    if package:sub(1, 8) == "/Script/" then return wrap(object) end
    return hold(key, "asset", full, object, owner)
end

-- True while the asset at this path is in memory. Loads nothing.
function members:IsLoaded(path)
    colon(self, "IsLoaded", "path")
    if type(path) ~= "string" then
        error(("game.Assets:IsLoaded expects the path of an asset such as \"/Game/Folder/Name\", got %s"):format(describe(path)), 2)
    end
    local full, why = check_path(path)
    if not full then return false, why end
    return in_memory(engine_now(2), full) ~= nil
end

-- The folder of the mod that is running: the owner is its scope, or a scope under it.
local function mod_folder(owner)
    local mods = Wax.mods
    if owner == NOBODY or not (mods and mods.get) then return nil end
    local at = owner
    while at do
        local mod = mods.get(at.name)
        local dir = mod and mod.scope == at and mod.dir
        if type(dir) == "string" and dir ~= "" then return (dir:gsub("\\", "/")) end
        at = at.parent
    end
    return nil
end

-- The whole path of a picture file: one inside the asking mod's folder, or a whole path as it is. nil and why otherwise.
local function file_of(file, owner)
    local path = file:gsub("\\", "/")
    if path == "" then return nil, "the file name is empty" end
    if #path > MAX_PATH or path:find("[%c\"<>|?*]") then return nil, ("'%s' is not a file name"):format(file) end
    local extension = (path:match("%.(%w+)$") or ""):lower()
    if extension ~= "png" and extension ~= "jpg" and extension ~= "jpeg" then
        return nil, ("'%s' is not a .png or .jpg file"):format(file)
    end
    if path:match("^%a:/") or path:sub(1, 1) == "/" then return path end
    if ("/" .. path .. "/"):find("/../", 1, true) then
        return nil, ("'%s' leaves the mod's folder. Name a file inside it, or give a whole path"):format(file)
    end
    local folder = mod_folder(owner)
    if not folder then
        return nil, ("'%s' is a file name, and no mod is running that it could belong to. Give the whole path"):format(file)
    end
    return folder .. "/" .. path
end

local function picture_problem(full)
    local handle = io.open(full, "rb")
    if not handle then return ("there is no file %s"):format(full) end
    local head = handle:read(8) or ""
    handle:close()
    if head == PNG or head:sub(1, 3) == JPG then return nil end
    return ("%s is not a PNG or JPG picture"):format(full)
end

-- A picture file as a texture: a .png or .jpg in the mod's folder. Asked for again, the same texture comes back.
function members:Texture(file)
    colon(self, "Texture", "file")
    if type(file) ~= "string" then
        error(("game.Assets:Texture expects the name of a picture file such as \"logo.png\", got %s"):format(describe(file)), 2)
    end
    local owner = owner_now()
    local full, why = file_of(file, owner)
    if not full then error("game.Assets:Texture: " .. why, 2) end
    local e = engine_now(2)
    canvas_now()
    local key = "t:" .. full:lower()
    local entry = entries[key]
    local object = entry and held_object(entry)
    if not object then
        local problem = picture_problem(full)
        if problem then error("game.Assets:Texture: " .. problem, 2) end
        object = e.rendering:ImportFileAsTexture2D(world_now(2), full)
        if not usable(object) then error(("game.Assets:Texture: the game could not read the picture %s"):format(full), 2) end
    end
    return hold(key, "texture", full, object, owner)
end

-- A screen colour value (0 to 1) as the linear value a material works with.
local function linear(c) return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end

local function clamp(value) return math.max(0, math.min(1, value)) end

-- A colour as R, G, B, A from 0 to 1, and whether the mod said its numbers are linear already.
local function parse_color(color, what, level)
    if type(color) == "string" then
        local wanted = color:lower()
        if wanted == "gray" then wanted = "grey" end
        local named = NAMED[wanted]
        if named then return named[1], named[2], named[3], 1, false end
        local r, g, b, a = color:match("^#?(%x%x)(%x%x)(%x%x)(%x?%x?)$")
        if r and #a ~= 1 then
            return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255, a == "" and 1 or tonumber(a, 16) / 255, false
        end
        error(("%s: '%s' is not a colour.%s Use a name (%s), \"#rrggbb\" or { R = 1, G = 0.5, B = 0 }"):format(what, color,
            suggest.phrase(color, COLORS), table.concat(COLORS, ", ")), level + 1)
    end
    if type(color) == "table" then
        local r, g, b, a = color.R or color[1], color.G or color[2], color.B or color[3], color.A or color[4]
        if a == nil then a = 1 end
        if finite(r) and finite(g) and finite(b) and finite(a) then
            if color.linear == true then return r, g, b, a, true end
            return clamp(r), clamp(g), clamp(b), clamp(a), false
        end
    end
    error(("%s is not a colour: give a name such as \"Red\", \"#rrggbb\" or { R = 1, G = 0.5, B = 0 } with values from 0 to 1")
        :format(what), level + 1)
end

local function parameter_name(name, what, level)
    if type(name) ~= "string" or name == "" or #name > 200 or name:find("%c") then
        error(("%s: a parameter is named by a string such as \"Color\", got %s"):format(what, type(name) == "string" and "'" .. name .. "'"
            or describe(name)), level + 1)
    end
    return name
end

-- Reads the options through before anything is made, so a mistake in them leaves nothing half done.
local function material_options(options, level)
    local colors, numbers, textures = {}, {}, {}
    if options == nil then return colors, numbers, textures end
    if type(options) ~= "table" then
        error("game.Assets:Material: the options are a table such as { colors = { Color = \"Red\" } }, got " .. describe(options), level + 1)
    end
    known_keys(options, MATERIAL_OPTIONS, "game.Assets:Material", level + 1)
    for _, group in ipairs(MATERIAL_OPTIONS) do
        if options[group] ~= nil and type(options[group]) ~= "table" then
            error(("game.Assets:Material: %s is a table of parameter names and values, got %s"):format(group, describe(options[group])), level + 1)
        end
    end
    for name, color in pairs(options.colors or {}) do
        local what = "game.Assets:Material: colors." .. tostring(name)
        local r, g, b, a, as_given = parse_color(color, what, level + 1)
        if not as_given then r, g, b = linear(r), linear(g), linear(b) end
        colors[parameter_name(name, what, level + 1)] = { R = r, G = g, B = b, A = a }
    end
    for name, value in pairs(options.numbers or {}) do
        local what = "game.Assets:Material: numbers." .. tostring(name)
        if not finite(value) then
            error(("%s is a number, got %s"):format(what, type(value) == "number" and tostring(value) or describe(value)), level + 1)
        end
        numbers[parameter_name(name, what, level + 1)] = value
    end
    for name, texture in pairs(options.textures or {}) do
        local what = "game.Assets:Material: textures." .. tostring(name)
        parameter_name(name, what, level + 1)
        if type(texture) == "string" then
            local loaded, why = Assets:Load(texture)
            if not loaded then error(("%s: %s"):format(what, why), level + 1) end
            texture = loaded
        end
        if not instance.is_instance(texture) or not texture:IsA("Texture") then
            error(("%s is a texture: one from game.Assets:Load or game.Assets:Texture, or the path of one. Got %s"):format(what,
                describe(texture)), level + 1)
        end
        textures[name] = raw_of(texture, what, level + 1)
    end
    return colors, numbers, textures
end

-- A material of its own, made from one of the game's, with colours, numbers and textures set on it.
function members:Material(parent, options)
    colon(self, "Material", "parent, options")
    local e = engine_now(2)
    local owner = owner_now()
    local outer, claimed = taking, {}
    taking = claimed
    -- an error raised in here names no line: it gets the caller's below
    local ok, result = pcall(function()
        if type(parent) == "string" then
            local loaded, why = Assets:Load(parent)
            if not loaded then error("game.Assets:Material: " .. why, 2) end
            parent = loaded
        end
        if not instance.is_instance(parent) or not parent:IsA("MaterialInterface") then
            error("game.Assets:Material expects a material of the game to start from: one from game.Assets:Load, or its path. Got "
                .. describe(parent), 2)
        end
        if not (parent:IsA("Material") or parent:IsA("MaterialInstanceConstant")) then
            error(("game.Assets:Material cannot start from %s. Start from the material that one was made from"):format(describe(parent)), 2)
        end
        local source = raw_of(parent, "game.Assets:Material", 2)
        local colors, numbers, textures = material_options(options, 2)
        local made = e.materials:CreateDynamicMaterialInstance(world_now(2), source, FName("None"), 0)
        if not usable(made) then error("game.Assets:Material: the game did not make the material", 2) end
        for name, color in pairs(colors) do made:SetVectorParameterValue(FName(name), color) end
        for name, value in pairs(numbers) do made:SetScalarParameterValue(FName(name), value) end
        for name, texture in pairs(textures) do made:SetTextureParameterValue(FName(name), texture) end
        serial = serial + 1
        return hold("m:" .. serial, "material", "a material of " .. tostring(parent.Name), made, owner)
    end)
    taking = outer
    if ok then return result end
    for index = #claimed, 1, -1 do
        local entry, claimant = claimed[index][1], claimed[index][2]
        if entries[entry.key] == entry then drop(entry, claimant, false) end
    end
    error(result, 2)
end

-- Lets go of something this mod asked for. What nobody else holds is freed by the engine soon after.
function members:Release(what)
    colon(self, "Release", "what")
    local owner = owner_now()
    local entry = nil
    if instance.is_instance(what) then
        entry = by_address[instance.address(what)]
    elseif type(what) == "string" then
        local full = check_path(what)
        entry = full and entries["a:" .. full:lower()] or nil
        if not entry then
            local file = file_of(what, owner)
            entry = file and entries["t:" .. file:lower()] or nil
        end
    else
        error("game.Assets:Release expects what Load, Texture or Material gave, or the path it was asked for with. Got " .. describe(what), 2)
    end
    if not entry then return false end
    return drop(entry, owner, false)
end

local function vector(value, what, index, level)
    if type(value) == "table" then
        local x, y, z = value.X or value[1], value.Y or value[2], value.Z or value[3]
        if finite(x) and finite(y) and finite(z) then return { X = x, Y = y, Z = z } end
    end
    error(("game.Assets:Mesh: %s %d is not three numbers. Give { X = 0, Y = 0, Z = 0 } or { 0, 0, 0 }"):format(what, index), level + 1)
end

local function list_of(shape, key, count, level)
    local list = shape[key]
    if list == nil then return nil end
    if type(list) ~= "table" or #list ~= count then
        error(("game.Assets:Mesh: %s needs one entry for each of the %d vertices, got %s"):format(key, count,
            type(list) == "table" and (#list .. " entries") or describe(list)), level + 1)
    end
    return list
end

-- A box around the origin, laid out as the engine lays out its own: four vertices a side, so every side is flat.
local function box_shape(size, level)
    local x, y, z = size, size, size
    if type(size) == "table" then x, y, z = size.X or size[1], size.Y or size[2], size.Z or size[3] end
    if not (finite(x) and finite(y) and finite(z)) or x <= 0 or y <= 0 or z <= 0 then
        error("game.Assets:Mesh: box is its size: one number, or { X = 100, Y = 50, Z = 20 }, each above 0", level + 1)
    end
    x, y, z = x / 2, y / 2, z / 2
    local corners = { { -x, y, z }, { x, y, z }, { x, -y, z }, { -x, -y, z }, { -x, y, -z }, { x, y, -z }, { x, -y, -z }, { -x, -y, -z } }
    local sides = { { 1, 2, 3, 4 }, { 5, 1, 4, 8 }, { 6, 2, 1, 5 }, { 7, 3, 2, 6 }, { 8, 4, 3, 7 }, { 8, 7, 6, 5 } }
    local corner_uvs = { { 0, 0 }, { 0, 1 }, { 1, 1 }, { 1, 0 } }
    local vertices, triangles, uvs = {}, {}, {}
    for _, side in ipairs(sides) do
        local first = #vertices
        for corner = 1, 4 do
            vertices[first + corner] = corners[side[corner]]
            uvs[first + corner] = corner_uvs[corner]
        end
        for _, step in ipairs({ 1, 2, 4, 2, 3, 4 }) do triangles[#triangles + 1] = first + step end
    end
    return vertices, triangles, uvs
end

-- One normal a vertex: the engine's own rule for a triangle, (P1 - P2) x (P0 - P2), added up over the triangles that use it.
local function normals_of(vertices, triangles)
    local sums = {}
    for index = 1, #vertices do sums[index] = { 0, 0, 0 } end
    for at = 1, #triangles, 3 do
        local a, b, c = triangles[at] + 1, triangles[at + 1] + 1, triangles[at + 2] + 1
        local p0, p1, p2 = vertices[a], vertices[b], vertices[c]
        local ux, uy, uz = p1.X - p2.X, p1.Y - p2.Y, p1.Z - p2.Z
        local vx, vy, vz = p0.X - p2.X, p0.Y - p2.Y, p0.Z - p2.Z
        local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
        local length = math.sqrt(nx * nx + ny * ny + nz * nz)
        if length > 0 then
            for _, corner in ipairs({ a, b, c }) do
                local sum = sums[corner]
                sum[1], sum[2], sum[3] = sum[1] + nx / length, sum[2] + ny / length, sum[3] + nz / length
            end
        end
    end
    local normals = {}
    for index, sum in ipairs(sums) do
        local length = math.sqrt(sum[1] * sum[1] + sum[2] * sum[2] + sum[3] * sum[3])
        if length > 0 then
            normals[index] = { X = sum[1] / length, Y = sum[2] / length, Z = sum[3] / length }
        else
            normals[index] = { X = 0, Y = 0, Z = 1 }
        end
    end
    return normals
end

-- A shape made of numbers, checked through, for a ProceduralMeshComponent part. Nothing is asked of the engine until Apply.
function members:Mesh(shape)
    colon(self, "Mesh", "shape")
    if type(shape) ~= "table" then
        error("game.Assets:Mesh expects a shape: { vertices = { ... }, triangles = { ... } } or { box = 100 }. Got " .. describe(shape), 2)
    end
    known_keys(shape, SHAPE_OPTIONS, "game.Assets:Mesh", 2)
    local points, corners, given_uvs = shape.vertices, shape.triangles, shape.uvs
    if shape.box ~= nil then
        if points ~= nil or corners ~= nil then error("game.Assets:Mesh: give box, or vertices and triangles, not both", 2) end
        points, corners, given_uvs = box_shape(shape.box, 2)
        if shape.uvs ~= nil then given_uvs = shape.uvs end
    end
    if type(points) ~= "table" or #points < 3 then
        error("game.Assets:Mesh: vertices is a list of at least 3 positions such as { X = 0, Y = 0, Z = 0 }", 2)
    end
    local count = #points
    if count > M.MAX_VERTICES then
        error(("game.Assets:Mesh: %d vertices is more than the %d a mesh made in Lua can have. A model that large belongs in a cooked asset")
            :format(count, M.MAX_VERTICES), 2)
    end
    if type(corners) ~= "table" or #corners < 3 or #corners % 3 ~= 0 then
        error("game.Assets:Mesh: triangles is a list of vertex numbers, three for each triangle, counted from 1", 2)
    end
    local vertices, low, high = {}, { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
    for index = 1, count do
        local vertex = vector(points[index], "vertex", index, 2)
        vertices[index] = vertex
        low[1], low[2], low[3] = math.min(low[1], vertex.X), math.min(low[2], vertex.Y), math.min(low[3], vertex.Z)
        high[1], high[2], high[3] = math.max(high[1], vertex.X), math.max(high[2], vertex.Y), math.max(high[3], vertex.Z)
    end
    local triangles = {}
    for index = 1, #corners do
        local number = math.tointeger(corners[index])
        if not number or number < 1 or number > count then
            error(("game.Assets:Mesh: triangles entry %d is %s. It has to be the number of a vertex, from 1 to %d"):format(index,
                tostring(corners[index]), count), 2)
        end
        triangles[index] = number - 1
    end
    local normals
    local given = list_of(shape, "normals", count, 2)
    if given then
        normals = {}
        for index = 1, count do normals[index] = vector(given[index], "normal", index, 2) end
    else
        normals = normals_of(vertices, triangles)
    end
    local uvs = {}
    if given_uvs ~= nil then
        if type(given_uvs) ~= "table" or #given_uvs ~= count then
            error(("game.Assets:Mesh: uvs needs one entry for each of the %d vertices"):format(count), 2)
        end
        for index = 1, count do
            local uv = given_uvs[index]
            local u, v = nil, nil
            if type(uv) == "table" then u, v = uv.X or uv.U or uv[1], uv.Y or uv.V or uv[2] end
            if not (finite(u) and finite(v)) then
                error(("game.Assets:Mesh: uv %d is not two numbers. Give { X = 0, Y = 0 } or { 0, 0 }"):format(index), 2)
            end
            uvs[index] = { X = u, Y = v }
        end
    end
    local colors = {}
    given = list_of(shape, "colors", count, 2)
    if given then
        for index = 1, count do
            local r, g, b, a = parse_color(given[index], "game.Assets:Mesh: colors entry " .. index, 2)
            colors[index] = { R = r, G = g, B = b, A = a }
        end
    end
    if shape.collision ~= nil and type(shape.collision) ~= "boolean" then error("game.Assets:Mesh: collision is true or false", 2) end
    return setmetatable({ [DATA] = {
        vertices = vertices, triangles = triangles, normals = normals, uvs = uvs, colors = colors, collision = shape.collision == true,
        count = count, size = { high[1] - low[1], high[2] - low[2], high[3] - low[3] },
    } }, Mesh)
end

local function forget_applied()
    for key, record in pairs(applied) do
        if not record.part:IsValid() then
            if record.owner and record.slot then record.owner:remove(record.slot) end
            applied[key] = nil
            applied_count = applied_count - 1
        end
    end
end

-- Puts the shape on a ProceduralMeshComponent as one of its sections, replacing what that section had.
function mesh_members:Apply(part, options)
    local data = type(self) == "table" and rawget(self, DATA)
    if not data then error("call Apply with a colon on a mesh from game.Assets:Mesh: mesh:Apply(part)", 2) end
    if not instance.is_instance(part) or not part:IsA("ProceduralMeshComponent") then
        error("mesh:Apply expects the part the shape goes on: an Instance of a ProceduralMeshComponent. Got " .. describe(part), 2)
    end
    local section, material, collision = 0, nil, data.collision
    if options ~= nil then
        if type(options) ~= "table" then error("mesh:Apply: the options are a table such as { material = material }, got " .. describe(options), 2) end
        known_keys(options, APPLY_OPTIONS, "mesh:Apply", 2)
        if options.section ~= nil then
            local wanted = math.tointeger(options.section)
            if not wanted or wanted < 0 or wanted > M.MAX_SECTION then
                error(("mesh:Apply: section is a whole number from 0 to %d, got %s"):format(M.MAX_SECTION, tostring(options.section)), 2)
            end
            section = wanted
        end
        if options.material ~= nil then
            if not instance.is_instance(options.material) or not options.material:IsA("MaterialInterface") then
                error("mesh:Apply: material is a material from game.Assets:Material or game.Assets:Load, got " .. describe(options.material), 2)
            end
            material = raw_of(options.material, "mesh:Apply: material", 2)
        end
        if options.collision ~= nil then
            if type(options.collision) ~= "boolean" then error("mesh:Apply: collision is true or false", 2) end
            collision = options.collision
        end
    end
    local raw = raw_of(part, "mesh:Apply", 2)
    local ok, problem = pcall(function()
        raw:CreateMeshSection_LinearColor(section, data.vertices, data.triangles, data.normals, data.uvs, {}, {}, {}, data.colors, {}, collision)
        if material then raw:SetMaterial(section, material) end
    end)
    if not ok then error("mesh:Apply: the game refused the shape: " .. first_line(problem), 2) end
    local key = instance.address(part) .. ":" .. section
    local record = applied[key]
    if record and record.part ~= part then
        if record.owner and record.slot then record.owner:remove(record.slot) end
        applied[key], record = nil, nil
        applied_count = applied_count - 1
    end
    if not record then
        if applied_count >= MAX_APPLIED then forget_applied() end
        record = { part = part }
        record.owner, record.slot = scope.own(function()
            if applied[key] == record then
                applied[key] = nil
                applied_count = applied_count - 1
            end
            if part:IsValid() then pcall(function() part.Raw:ClearMeshSection(section) end) end
        end)
        applied[key] = record
        applied_count = applied_count + 1
    end
end

Mesh.__index = function(self, key)
    local member = mesh_members[key]
    if member then return member end
    local data = rawget(self, DATA)
    if key == "VertexCount" then return data.count end
    if key == "TriangleCount" then return #data.triangles // 3 end
    if key == "Size" then return { X = data.size[1], Y = data.size[2], Z = data.size[3] } end
    error(("%s is not a member of a mesh.%s"):format(tostring(key), suggest.phrase(tostring(key), MESH_NAMES)), 2)
end
Mesh.__tostring = function(self) return ("Mesh (%d vertices, %d triangles)"):format(self.VertexCount, self.TriangleCount) end
Mesh.__newindex = function(_, key) error(("Mesh.%s cannot be assigned: make another mesh with game.Assets:Mesh"):format(tostring(key)), 2) end
Mesh.__names = function() return MESH_NAMES end
Mesh.__metatable = "Mesh"

setmetatable(Assets, {
    __index = function(_, key)
        local member = members[key]
        if member then return member end
        error(("%s is not a member of game.Assets.%s"):format(tostring(key), suggest.phrase(tostring(key), NAMES)), 2)
    end,
    __newindex = function(_, key)
        error(("game.Assets.%s cannot be assigned because game.Assets is read-only"):format(tostring(key)), 2)
    end,
    __tostring = function() return "Assets" end,
    __names = function() return NAMES end,
})

-- A material's Instance is of no use after a map change, so the material is let go. Pictures and assets stay: they are asked for again by name.
local function on_map_change()
    canvas_now()
    local old = {}
    for _, entry in pairs(entries) do
        if entry.kind == "material" and not (entry.instance and entry.instance:IsValid()) then old[#old + 1] = entry end
    end
    for _, entry in ipairs(old) do
        for owner, slot in pairs(entry.owners) do
            if slot ~= true then owner:remove(slot) end
        end
        entry.owners, entry.count = {}, 0
        let_go(entry)
    end
    -- what is still held keeps the Instance a mod has of it
    if bank then
        for _, entry in pairs(entries) do
            if entry.instance and entry.image then
                local ok, object = pcall(held_object, entry)
                if ok and object then pcall(instance.renew, entry.instance, object) end
            end
        end
    end
    forget_applied()
end

-- For whoever builds the interface again: everything is let go now, not at the next call. Touches nothing of the old interface.
function M.forget_all()
    if bank then lose_all() end
end

local MODEL_OPTIONS = { "scale", "up", "flip", "collision" }
local MAX_MODEL_BYTES = 16 * 1024 * 1024

-- A 3D model from an .obj file in the mod's folder, as a shape for a part: what game.Assets:Mesh gives.
-- options: scale (100 when omitted: a model made in metres), up ("y" as most programs save it, or "z"),
-- flip (true turns every triangle round, for a model that shows inside out), collision.
function members:Model(file, options)
    colon(self, "Model", "file")
    if type(file) ~= "string" then
        error(("game.Assets:Model expects the name of a model file such as \"rock.obj\", got %s"):format(describe(file)), 2)
    end
    options = options or {}
    if type(options) ~= "table" then error("game.Assets:Model: the options are a table, such as { scale = 100 }", 2) end
    known_keys(options, MODEL_OPTIONS, "game.Assets:Model", 2)
    local scale, up = options.scale or 100, options.up or "y"
    if not finite(scale) or scale == 0 then error("game.Assets:Model: scale is a number that is not 0", 2) end
    if up ~= "y" and up ~= "z" then error("game.Assets:Model: up is \"y\" or \"z\"", 2) end
    local path = file:gsub("\\", "/")
    if not path:lower():match("%.obj$") then error(("game.Assets:Model: '%s' is not an .obj file"):format(file), 2) end
    if not (path:match("^%a:/") or path:sub(1, 1) == "/") then
        if ("/" .. path .. "/"):find("/../", 1, true) then error(("game.Assets:Model: '%s' leaves the mod's folder"):format(file), 2) end
        local folder = mod_folder(owner_now())
        if not folder then error(("game.Assets:Model: '%s' is a file name, and no mod is running that it could belong to. Give the whole path"):format(file), 2) end
        path = folder .. "/" .. path
    end
    local handle = io.open(path, "rb")
    if not handle then error(("game.Assets:Model: there is no file %s"):format(path), 2) end
    local size = handle:seek("end")
    if size > MAX_MODEL_BYTES then
        handle:close()
        error("game.Assets:Model: the file is larger than 16 MB. A model that large belongs in a mod's game content", 2)
    end
    handle:seek("set", 0)
    local text = handle:read("a")
    handle:close()

    local places, pictures, facings = {}, {}, {}
    local vertices, uvs, normals, triangles, made = {}, {}, {}, {}, {}
    local has_uv, has_normal = true, true
    local function place(x, y, z)
        x, y, z = x * scale, y * scale, z * scale
        if up == "y" then return { X = x, Y = z, Z = y } end
        return { X = x, Y = y, Z = z }
    end
    local function facing(x, y, z)
        if up == "y" then return { X = x, Y = z, Z = y } end
        return { X = x, Y = y, Z = z }
    end
    -- A corner of a face is a place with its own spot on the picture and its own facing: each such trio is one vertex.
    local function corner(word)
        local known = made[word]
        if known then return known end
        local v, vt, vn = word:match("^(-?%d+)/?(-?%d*)/?(-?%d*)$")
        v = tonumber(v)
        if not v then error("game.Assets:Model: a face names a corner that cannot be read: " .. word, 0) end
        if v < 0 then v = #places + 1 + v end
        local at = places[v]
        if not at then error("game.Assets:Model: a face names a place the file does not have", 0) end
        local index = #vertices + 1
        if index > M.MAX_VERTICES then
            error(("game.Assets:Model: the model has more than %d vertices. One that large belongs in a mod's game content"):format(M.MAX_VERTICES), 0)
        end
        vertices[index] = at
        vt, vn = tonumber(vt), tonumber(vn)
        if vt and vt < 0 then vt = #pictures + 1 + vt end
        if vn and vn < 0 then vn = #facings + 1 + vn end
        if vt and pictures[vt] then uvs[index] = pictures[vt] else has_uv = false end
        if vn and facings[vn] then normals[index] = facings[vn] else has_normal = false end
        made[word] = index
        return index
    end
    local ok, problem = pcall(function()
        for line in text:gmatch("[^\r\n]+") do
            local kind, rest = line:match("^%s*(%a+)%s+(.*)$")
            if kind == "v" then
                local x, y, z = rest:match("^(%S+)%s+(%S+)%s+(%S+)")
                x, y, z = tonumber(x), tonumber(y), tonumber(z)
                if not (x and y and z) then error("game.Assets:Model: a place in the file cannot be read", 0) end
                places[#places + 1] = place(x, y, z)
            elseif kind == "vt" then
                local u, v = rest:match("^(%S+)%s*(%S*)")
                pictures[#pictures + 1] = { X = tonumber(u) or 0, Y = 1 - (tonumber(v) or 0) }
            elseif kind == "vn" then
                local x, y, z = rest:match("^(%S+)%s+(%S+)%s+(%S+)")
                facings[#facings + 1] = facing(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 1)
            elseif kind == "f" then
                local corners = {}
                for word in rest:gmatch("%S+") do corners[#corners + 1] = corner(word) end
                -- a face of more than three corners is cut into triangles from its first corner
                for index = 2, #corners - 1 do
                    local a, b, c = corners[1], corners[index], corners[index + 1]
                    if options.flip then b, c = c, b end
                    triangles[#triangles + 1], triangles[#triangles + 2], triangles[#triangles + 3] = a, b, c
                end
            end
        end
    end)
    if not ok then error(problem, 2) end
    if #triangles == 0 then error(("game.Assets:Model: %s holds no faces"):format(path), 2) end
    return self:Mesh({ vertices = vertices, triangles = triangles, uvs = has_uv and uvs or nil, normals = has_normal and normals or nil,
        collision = options.collision })
end

-- Something made paths loadable that were not (a pack of files was added): they are tried again at once.
function M.forget_missing() missing, missing_count = {}, 0 end

-- Pictures read from files are kept by hidden images under the interface's root, the oldest let go first.
local FILE_PICTURES = 64
local picture_slots, picture_of, picture_at, picture_bank, picture_canvas = {}, {}, 0, nil, nil

-- A .png or .jpg file as a texture and its shape (width over height). Read once: asked again, the kept one comes back.
-- Returns nil and why. Without an interface nothing keeps it, so the widget it is put on has to.
function M.import_picture(full)
    local canvas, gui = canvas_now()
    if picture_bank and (canvas == nil or not rawequal(canvas, picture_canvas)) then
        picture_slots, picture_of, picture_at, picture_bank, picture_canvas = {}, {}, 0, nil, nil
    end
    local known = picture_of[full]
    if known then
        local kept = known.image.Brush.ResourceObject
        if usable(kept) then return kept, known.shape end
        picture_of[full] = nil
    end
    local problem = picture_problem(full)
    if problem then return nil, problem end
    local ok, object = pcall(function() return engine_now(2).rendering:ImportFileAsTexture2D(world_now(2), full) end)
    if not ok or not usable(object) then return nil, "the game could not read the picture" end
    local shape = 16 / 9
    local sized, wide, tall = pcall(function() return object:Blueprint_GetSizeX(), object:Blueprint_GetSizeY() end)
    if sized and type(wide) == "number" and type(tall) == "number" and wide > 0 and tall > 0 then shape = wide / tall end
    if canvas then
        if not picture_bank then
            picture_bank = gui.new("VerticalBox")
            picture_bank:SetVisibility(COLLAPSED)
            canvas:AddChild(picture_bank)
            picture_canvas = canvas
        end
        picture_at = picture_at % FILE_PICTURES + 1
        local slot = picture_slots[picture_at]
        if not slot then
            slot = { image = gui.new("Image") }
            picture_bank:AddChild(slot.image)
            picture_slots[picture_at] = slot
        elseif slot.path then
            picture_of[slot.path] = nil
        end
        slot.image:SetBrushResourceObject(object)
        slot.path, slot.shape = full, shape
        picture_of[full] = slot
    end
    return object, shape
end

function M.stats()
    local kinds, pinned = { asset = 0, texture = 0, material = 0 }, 0
    for _, entry in pairs(entries) do
        kinds[entry.kind] = kinds[entry.kind] + 1
        if entry.image then pinned = pinned + 1 end
    end
    return { held = held_count, pinned = pinned, assets = kinds.asset, textures = kinds.texture, materials = kinds.material,
             spare = #free, missing = missing_count, explained = explained, applied = applied_count }
end

local connection = nil

function M.start()
    local root = Wax.import("engine.game").root
    connection = root.MapChanged:Connect(on_map_change)
    rawset(root, "Assets", Assets)
end

-- Lets everything go and takes game.Assets away. For loading this file again in a running game.
function M.stop()
    if connection then connection:Disconnect() end
    connection = nil
    local all = {}
    for _, entry in pairs(entries) do all[#all + 1] = entry end
    for _, entry in ipairs(all) do
        for owner, slot in pairs(entry.owners) do
            if slot ~= true then owner:remove(slot) end
        end
        entry.owners, entry.count = {}, 0
        let_go(entry)
    end
    local root = Wax.import("engine.game").root
    if rawget(root, "Assets") == Assets then rawset(root, "Assets", nil) end
end

M.api = Assets
return M
