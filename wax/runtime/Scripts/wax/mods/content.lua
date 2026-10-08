-- A mod's cooked game content: content/<Id>.pak is checked, copied to the game's download folder and mounted there.

local Wax = ...

local content = {}

local log = Wax.import("core.log").channel("wax.content")
local storage = Wax.import("core.storage")
local pakfile = Wax.import("mods.pakfile")
local sched = Wax.import("core.sched")

local PREFIX = "../../../Icarus/Content/Mods/"
local LOGIC_MODS = "../../../Icarus/Content/Paks/LogicMods/"
local FOLDER, MANIFEST = "Wax", "wax.manifest"
local MAX_BYTES = 512 * 1024 * 1024
local SLICE = 4 * 1024 * 1024
local SETTLE_FRAMES = 4
local CLEAN_AFTER = 30

content.STATES = { ready = "ready", restart = "restart", off = "off" }

-- What is mounted stays mounted until the game closes, so this outlives a reload of Wax.
local process = rawget(_G, "WaxContent")
local fresh = process == nil
if fresh then
    process = { mounted = {}, order = 10 }
    rawset(_G, "WaxContent", process)
end

local record = nil
local views = {}
local stale = {}
local folder_cache = nil

local function saved()
    record = record or storage.load("wax", "content", { staged = {}, bad = {} })
    record.staged, record.bad = record.staged or {}, record.bad or {}
    return record
end

local function libraries()
    local game = Wax.game
    if not game then return nil end
    local ok, paths = pcall(game.Library, game, "BlueprintPathsLibrary")
    local ok2, patching = pcall(game.Library, game, "MobilePatchingLibrary")
    if not (ok and ok2 and paths and patching) then return nil end
    return paths, patching
end

local function exists(paths, file)
    local ok, answer = pcall(paths.Call, paths, "FileExists", file)
    return ok and answer == true
end

local function mark_file() return Wax.root .. "/run/content.mounting" end

local function manifest_text(name)
    return ([[{
  "ManifestFileVersion": "013000000000",
  "bIsFileData": false,
  "AppID": "000000000000",
  "AppNameString": "Wax",
  "BuildVersionString": "1",
  "LaunchExeString": "",
  "LaunchCommand": "",
  "FileManifestList": [
    {
      "Filename": "%s",
      "FileHash": "000000000000000000000000000000000000000000000000000000000000",
      "FileChunkParts": [
        { "Guid": "00000000000000000000000000000001", "Offset": "000000000000", "Size": "000000000000" }
      ]
    }
  ],
  "ChunkHashList": { "00000000000000000000000000000001": "000000000000000000000000" },
  "ChunkShaList": {},
  "DataGroupList": { "00000000000000000000000000000001": "000" },
  "ChunkFilesizeList": {},
  "CustomFields": {}
}
]]):format(name)
end

-- The folder the engine's patching library reads. Lua cannot make a folder: the game's own file writer does.
local function staging_folder(paths)
    if folder_cache then return folder_cache end
    local ok, download = pcall(paths.Call, paths, "ProjectPersistentDownloadDir")
    if not ok or type(download) ~= "string" or download == "" then return nil, "the game did not say where its download folder is" end
    local folder = download .. "/" .. FOLDER
    local probe = folder .. "/" .. MANIFEST
    local file = io.open(probe, "ab")
    if not file then
        local game = Wax.game
        local found, sentry = pcall(game.Library, game, "SentryLibrary")
        if found and sentry then pcall(sentry.Call, sentry, "SaveStringToFile", "{}", FOLDER .. "/" .. MANIFEST) end
        file = io.open(probe, "ab")
    end
    if not file then return nil, "the folder for game content could not be made (" .. folder .. ")" end
    file:close()
    folder_cache = folder
    return folder
end

local function copy(from, to, size)
    local source = io.open(from, "rb")
    if not source then return false, "the pak cannot be opened" end
    local target = io.open(to, "wb")
    if not target then
        source:close()
        return false, "the copy cannot be written"
    end
    local written = 0
    while true do
        local piece = source:read(SLICE)
        if not piece then break end
        if not target:write(piece) then break end
        written = written + #piece
    end
    source:close()
    target:close()
    if written ~= size then
        os.remove(to)
        return false, "the copy came out short"
    end
    return true
end

local function size_of(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:close()
    return size
end

local function object_paths(id, files)
    local list = {}
    for _, name in ipairs(files) do
        local inner = name:match("^(.*)%.uasset$")
        if inner then
            local leaf = inner:match("([^/]+)$")
            list[#list + 1] = { package = "/Game/Mods/" .. id .. "/" .. inner, leaf = leaf }
        end
    end
    return list
end

-- The assets of an older copy that the game still has in memory. Those keep their old look until a restart.
local function still_loaded(id, files)
    local assets = Wax.game and Wax.game.Assets
    local held = {}
    if not assets then return held end
    for _, entry in ipairs(object_paths(id, files)) do
        for _, name in ipairs({ entry.leaf, entry.leaf .. "_C" }) do
            local ok, loaded = pcall(assets.IsLoaded, assets, entry.package .. "." .. name)
            if ok and loaded then
                held[#held + 1] = entry.leaf
                break
            end
        end
    end
    return held
end

local function forget_misses()
    local ok, assets = pcall(Wax.import, "world.assets")
    if ok and assets.forget_missing then assets.forget_missing() end
end

local function set(view, state, reason)
    local changed = view.state ~= state or view.reason ~= reason
    view.state, view.reason = state, reason
    if changed then
        if state == "ready" then
            log:info("%s: %s (%d files)", view.id, view.updated and "game content updated, no restart needed" or "game content mounted",
                #(view.files or {}))
        else log:warn("%s: content %s: %s", view.id, state, tostring(reason)) end
    end
end

local function mount(view, info, paths, patching)
    local id = view.id
    local folder, why = staging_folder(paths)
    if not folder then return false, why end
    local name = ("wax-%s-%s.pak"):format(id, info.mark)
    local staged = folder .. "/" .. name
    if size_of(staged) ~= info.size then
        local copied, problem = copy(view.source, staged, info.size)
        if not copied then return false, problem end
    end
    local kept = saved()
    kept.staged[name] = true
    stale[name] = nil
    storage.save("wax", "content", kept)

    local manifest = io.open(folder .. "/" .. MANIFEST, "wb")
    if not manifest then return false, "the list for the game cannot be written" end
    manifest:write(manifest_text(name))
    manifest:close()

    local note = io.open(mark_file(), "wb")
    if note then
        note:write(id, " ", info.mark)
        note:close()
    end
    local ok, installed = pcall(patching.Call, patching, "GetInstalledContent", FOLDER)
    local mounted = false
    if ok and installed then
        process.order = process.order + 1
        local called, answer = pcall(installed.Call, installed, "Mount", process.order, PREFIX .. id .. "/")
        mounted = called and answer == true
    end
    os.remove(mark_file())
    if not mounted then return false, "the game did not take the pak" end
    if not exists(paths, PREFIX .. id .. "/" .. info.files[1]) then return false, "the pak was taken, and its files do not show" end
    return true
end

-- Called before a mod's code runs. Returns "wait" while the game lets go of an older copy: ask again next frame.
function content.prepare(mod)
    local id = mod.id
    local key = id:lower()
    local view = views[key]
    if not view then
        view = { id = id }
        views[key] = view
    end
    view.source = mod.dir .. "/content/" .. id .. ".pak"

    if view.settle then
        if sched.stats.frame < view.settle then return "wait" end
        view.settle = nil
        view.updated = true
        local held = still_loaded(id, view.old_files or {})
        view.old_files = nil
        forget_misses()
        if #held > 0 then
            table.sort(held)
            set(view, "restart", "the game still uses the older " .. table.concat(held, ", ") .. ". Restart the game to see the change there")
        else
            set(view, "ready")
        end
        return view.state
    end

    local paths, patching = libraries()
    if not paths then
        set(view, "off", "the game's file functions are not there")
        return view.state
    end
    if not id:match("^[%w_%-]+$") then
        set(view, "off", "a mod with game content needs an id of letters, digits, - and _")
        return view.state
    end
    if exists(paths, LOGIC_MODS .. id .. ".pak") then
        set(view, "off", "another mod loader already has content named " .. id)
        return view.state
    end
    local info, why = pakfile.check(view.source, PREFIX .. id .. "/")
    if not info then
        set(view, "off", "content/" .. id .. ".pak is refused: " .. why)
        return view.state
    end
    if info.size > MAX_BYTES then
        set(view, "off", "the pak is larger than 512 MB")
        return view.state
    end
    if saved().bad[key] == info.mark then
        set(view, "off", "the game stopped the last time this content was mounted. Build the content again to try once more")
        return view.state
    end

    local now = process.mounted[key]
    view.files, view.mark = info.files, info.mark
    if now and now.mark == info.mark then
        if view.state ~= "restart" then set(view, "ready") end
        return view.state
    end
    local ok, problem = mount(view, info, paths, patching)
    if not ok then
        set(view, "off", problem)
        return view.state
    end
    process.mounted[key] = { mark = info.mark, files = info.files }
    forget_misses()
    if now then
        -- A newer copy over an older one: what the game has let go of comes from the newer one.
        view.old_files = now.files
        local system = Wax.game:Library("KismetSystemLibrary")
        pcall(system.Call, system, "CollectGarbage")
        view.settle = sched.stats.frame + SETTLE_FRAMES
        log:info("%s: newer content mounted, waiting for the game to let go of the older", id)
        return "wait"
    end
    set(view, "ready")
    return view.state
end

local Content = {}
Content.__index = function(self, key)
    local view = rawget(self, "view")
    if key == "State" then return view.state or "off" end
    if key == "Reason" then return view.reason end
    if key == "Files" then return table.move(view.files or {}, 1, #(view.files or {}), 1, {}) end
    return Content[key]
end
Content.__newindex = function() error("mod.Content cannot be assigned to", 2) end

local function inner_name(name, what)
    if type(name) ~= "string" or name == "" or not name:match("^[%w_%-/]+$") or name:find("//", 1, true) then
        error(("mod.Content:%s expects the name of an asset in the mod's content, such as \"BP_Thing\" or \"Meshes/Rock\""):format(what), 3)
    end
    return name, name:match("([^/]+)$")
end

-- "/Game/Mods/<Id>/Folder/Name.Name": what game.Assets:Load takes.
function Content:Path(name)
    local inner, leaf = inner_name(name, "Path")
    return ("/Game/Mods/%s/%s.%s"):format(rawget(self, "view").id, inner, leaf)
end

-- The path of a blueprint's class, for game.Blueprints:Define{ base = ... }.
function Content:ClassPath(name)
    local inner, leaf = inner_name(name, "ClassPath")
    return ("/Game/Mods/%s/%s.%s_C"):format(rawget(self, "view").id, inner, leaf)
end

local function load(self, path)
    local view = rawget(self, "view")
    if view.state == "off" or not view.state then return nil, view.reason or "this mod's content is not mounted" end
    local assets = Wax.game and Wax.game.Assets
    if not assets then return nil, "game.Assets is not there" end
    return assets:Load(path)
end

function Content:Load(name) return load(self, self:Path(name)) end
function Content:LoadClass(name) return load(self, self:ClassPath(name)) end

function Content:Has(name)
    local inner = inner_name(name, "Has"):lower()
    for _, file in ipairs(rawget(self, "view").files or {}) do
        if file:lower() == inner .. ".uasset" then return true end
    end
    return false
end

-- What a mod sees as mod.Content: nil when the mod has no content/<Id>.pak.
function content.of(mod)
    if not mod.files["content/" .. mod.id .. ".pak"] then return nil end
    local key = mod.id:lower()
    local view = views[key]
    if not view then
        view = { id = mod.id }
        views[key] = view
    end
    view.facade = view.facade or setmetatable({ view = view }, Content)
    return view.facade
end

function content.has(mod) return mod.files["content/" .. mod.id .. ".pak"] == true end

function content.state(id)
    local view = views[tostring(id):lower()]
    if not view then return nil end
    return { id = view.id, state = view.state, reason = view.reason, files = #(view.files or {}), mark = view.mark,
        waiting = view.settle ~= nil }
end

function content.list()
    local list = {}
    for _, view in pairs(views) do list[#list + 1] = content.state(view.id) end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

function content.start()
    local kept = saved()
    local file = io.open(mark_file(), "rb")
    if file then
        local id, mark = (file:read("a") or ""):match("^(%S+) (%S+)$")
        file:close()
        os.remove(mark_file())
        if id then
            kept.bad[id:lower()] = mark
            storage.save("wax", "content", kept)
            log:error("the game stopped while the content of %s was being mounted. It stays off until it is built again", id)
        end
    end
    if not fresh then return end
    -- Nothing is mounted yet in a game that has only started, so copies no mod asks for can go.
    for name in pairs(kept.staged) do stale[name] = true end
    sched.task.delay(CLEAN_AFTER, function()
        local paths = libraries()
        local folder = paths and staging_folder(paths)
        if not folder then return end
        local changed = false
        for name in pairs(stale) do
            os.remove(folder .. "/" .. name)
            kept.staged[name] = nil
            changed = true
        end
        stale = {}
        if changed then storage.save("wax", "content", kept) end
    end)
end

return content
