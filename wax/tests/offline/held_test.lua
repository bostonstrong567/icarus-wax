-- Offline tests for mods the player has not seen: held at a start and while the game runs, known once switched on,
-- what a saved file from before that list does, and what the bridge's mod-added command does in the loader.
-- The mods folders are real folders under a scratch directory, listed the way UE4SS lists the game's folders.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\held_test.lua [scratch dir]

local t = dofile("wax/tests/offline/harness.lua")

local function win(path) return (path:gsub("/", "\\")) end
local here = io.popen("cd"):read("l"):gsub("\\", "/")
local base = (arg[1] or "build/held-test"):gsub("\\", "/")
if not base:match("^%a:") then base = here .. "/" .. base end
os.execute(('rmdir /s /q "%s" >nul 2>nul'):format(win(base)))

local function mkdir(path) os.execute(('mkdir "%s" >nul 2>nul'):format(win(path))) end

local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("a")
    file:close()
    return text
end

local function write(path, text)
    local file = io.open(path, "wb")
    if not file then
        mkdir(path:match("^(.*)/[^/]+$"))
        file = assert(io.open(path, "wb"))
    end
    file:write(text)
    file:close()
end

local function files_under(dir)
    local found, prefix = {}, #dir + 2
    local pipe = io.popen(('dir /b /s /a:-d "%s" 2>nul'):format(win(dir)))
    for line in pipe:lines() do found[(line:sub(prefix):gsub("\\", "/"))] = true end
    pipe:close()
    return found
end

-- A folder the way UE4SS's IterateGameDirectories lists one.
local function tree_of(dir)
    local top = { __absolute_path = win(dir), __files = {} }
    for relative in pairs(files_under(dir)) do
        local at, path = top, dir
        for folder in relative:gmatch("([^/]+)/") do
            path = path .. "/" .. folder
            at[folder] = at[folder] or { __absolute_path = win(path), __files = {} }
            at = at[folder]
        end
        at.__files[#at.__files + 1] = { __name = relative:match("[^/]+$") }
    end
    return top
end

local current = nil     -- the game that is running
IterateGameDirectories = function()
    if current.unlisted then error("the folders cannot be listed right now") end
    return { Game = { Binaries = { Win64 = { ue4ss = { Mods = { Wax = { mods = tree_of(current.root .. "/mods") } } } } } } }
end

HELD_RAN = {}           -- how often each test mod's code ran, written by the mods themselves

local function body(made)
    return ('raw.HELD_RAN[mod.id] = (raw.HELD_RAN[mod.id] or 0) + 1\nreturn { made = "%s" }'):format(made or "first")
end

local count = 0

-- A copy of Wax in a game: its folder with mods, saved and run in it. mods: { Id = { ["file"] = text } or true for a plain mod }.
local function install(mods, saved)
    count = count + 1
    local root = ("%s/%d/Binaries/Win64/ue4ss/Mods/Wax"):format(base, count)
    os.execute(('mkdir "%s\\mods" "%s\\saved" "%s\\run" >nul 2>nul'):format(win(root), win(root), win(root)))
    local it = { root = root, mods = root .. "/mods", prefix = "M" .. count }
    function it.put(id, files)
        if files == nil or files == true then files = { ["init.lua"] = body() } end
        for name, text in pairs(files) do write(it.mods .. "/" .. id .. "/" .. name, text) end
    end
    function it.saved()
        local text = read(root .. "/saved/wax.mods.lua")
        return text and load(text, "=saved", "t", {})() or nil
    end
    for id, files in pairs(mods or {}) do it.put(id, files) end
    if saved then write(root .. "/saved/wax.mods.lua", saved) end
    return it
end

-- One run of the game over an install, from the look at the mods folder that ends the start of the core.
local function start(it, options)
    local Wax = t.new_wax()
    Wax.root = it.root
    local g = { root = it.root, now = 1000, held = {}, notes = {}, unlisted = options and options.unlisted }
    current = g
    g.log, g.sched = Wax.import("core.log"), Wax.import("core.sched")
    g.sched.clock = function() return g.now end
    g.storage, g.loader = Wax.import("core.storage"), Wax.import("mods.loader")
    Wax.mods, Wax.log, Wax.sched, Wax.storage = g.loader, g.log, g.sched, g.storage
    Wax.ui = { Notify = function(text, shown) g.notes[#g.notes + 1] = { text = text, options = shown } end }
    g.loader.on_held = function(id, name) g.held[#g.held + 1] = id .. ": " .. name end
    g.loader.set_watching(options and options.watching or false)
    g.summary = g.loader.sync()

    function g.frame()
        g.now = g.now + 0.05
        g.loader.step()
        g.storage.step()
        g.sched.step()
    end
    function g.run(seconds)
        for _ = 1, math.floor(seconds / 0.05 + 0.5) do g.frame() end
    end
    function g.status(id)
        for _, entry in ipairs(g.loader.list()) do
            if entry.id == id then return entry end
        end
    end
    -- "loaded", "disabled" ..., with " new" after it for a mod the player has not seen. nil when the mod is not listed.
    function g.state(id)
        local entry = g.status(id)
        return entry and (entry.status .. (entry.fresh and " new" or "")) or nil
    end
    function g.made(id)
        local mod = g.loader.get(id)
        return mod and mod.exports and mod.exports.made
    end
    function g.logged(fragment, level)
        local found = 0
        for _, entry in ipairs(g.log.since(0)) do
            if entry.message:find(fragment, 1, true) and (not level or entry.level == level) then found = found + entry.count end
        end
        return found
    end
    -- The game closes: what was waiting to be saved is on disk, as it is a moment after any change.
    function g.close()
        g.run(1)
        g.loader.unload_all()
    end
    return g
end

local function ran(id) return HELD_RAN[id] or 0 end

t.test("a fresh install: the mod that comes with Wax is seen and runs, and the list of seen mods is written", function()
    local it = install({ FreshOne = true })
    t.eq(it.saved(), nil, "no saved file yet")
    local g = start(it)
    t.eq(g.state("FreshOne"), "loaded")
    t.eq(ran("FreshOne"), 1)
    t.eq(#g.held, 0)
    g.run(1)
    local saved = it.saved()
    t.eq(saved.known.FreshOne, true)
    t.eq(next(saved.disabled), nil)
    g.close()
end)

t.test("a mod dropped in while the game is closed is held at the next start, and stays held", function()
    local it = install({ Mine = true })
    local g = start(it)
    t.eq(g.state("Mine"), "loaded")
    g.close()

    it.put("Dropped", { ["mod.lua"] = 'return { name = "Dropped In", version = "3.0.0" }', ["init.lua"] = body() })
    g = start(it)
    t.eq(g.state("Dropped"), "disabled new", "listed, switched off, marked as new")
    t.eq(g.status("Dropped").enabled, false)
    t.eq(ran("Dropped"), 0, "none of its code has run")
    t.eq(g.loader.get("Dropped").exports, nil)
    t.eq(g.state("Mine"), "loaded", "the mod the player had still runs")
    t.eq(table.concat(g.held, " | "), "Dropped: Dropped In", "the interface is told once, with the mod's own name")
    t.eq(g.logged("Dropped is new here. It stays switched off until you switch it on in the Mods page", "info"), 1)
    t.eq(g.summary.held[1], "Dropped")
    g.run(1)
    local saved = it.saved()
    t.eq(saved.known.Dropped, nil, "it is not on the list of seen mods")
    t.eq(saved.known.Mine, true)
    t.eq(saved.disabled.Dropped, true, "and it is written down as switched off, which is what an older Wax reads")
    -- looking again, however often, does not start it
    for _ = 1, 5 do g.loader.sync() end
    g.loader.request_reload("Dropped")
    g.run(1)
    t.eq(g.state("Dropped"), "disabled new")
    t.eq(ran("Dropped"), 0)
    t.eq(#g.held, 1, "and it is not announced again")
    g.close()

    -- the start after that: still held, still marked, and not announced a second time
    g = start(it)
    t.eq(g.state("Dropped"), "disabled new")
    t.eq(ran("Dropped"), 0)
    t.eq(#g.held, 0)
    g.close()
end)

t.test("switching a new mod on is what makes it known, and that holds across a restart", function()
    local it = install({ Mine = true })
    start(it).close()
    it.put("Wanted")
    local g = start(it)
    t.eq(g.state("Wanted"), "disabled new")
    t.eq(g.loader.set_enabled("Wanted", true), true)
    g.run(1)
    t.eq(g.state("Wanted"), "loaded")
    t.eq(ran("Wanted"), 1)
    local saved = it.saved()
    t.eq(saved.known.Wanted, true)
    t.eq(saved.disabled.Wanted, nil)
    g.close()

    g = start(it)
    t.eq(g.state("Wanted"), "loaded", "it starts with the game from now on")
    t.eq(ran("Wanted"), 2)
    t.eq(#g.held, 0)
    -- switched off by the player it is off, and no longer new
    g.loader.set_enabled("Wanted", false)
    g.close()
    g = start(it)
    t.eq(g.state("Wanted"), "disabled")
    t.eq(#g.held, 0)
    g.close()
end)

t.test("a saved file from before the list: the mods that are there count as seen, once", function()
    local it = install({ OldA = true, OldB = true, OldC = true },
        'return { disabled = { OldB = true, Gone = true }, order = { "OldC", "OldA" } }')
    local g = start(it)
    t.eq(g.state("OldA"), "loaded", "nobody's mods are switched off by the update")
    t.eq(g.state("OldC"), "loaded")
    t.eq(g.state("OldB"), "disabled", "what the player had switched off stays off, and is not new")
    t.eq(ran("OldB"), 0)
    t.eq(#g.held, 0)
    t.eq(g.logged("is new here"), 0)
    t.eq(g.loader.list()[1].id, "OldC", "the order the player gave is kept")
    g.run(1)
    local saved = it.saved()
    t.eq(saved.known.OldA and saved.known.OldB and saved.known.OldC, true)
    t.eq(saved.known.Gone, nil, "a mod that is not there is not made known")
    t.eq(saved.disabled.OldB, true)
    t.eq(saved.disabled.Gone, true)
    t.eq(saved.order[1], "OldC")
    g.close()

    -- the rule was for that one start: what turns up from now on is held
    it.put("Later")
    g = start(it)
    t.eq(g.state("Later"), "disabled new")
    t.eq(ran("Later"), 0)
    t.eq(g.state("OldA"), "loaded")
    g.close()
end)

t.test("a saved file whose list is empty is not taken for one from before the list", function()
    local it = install({ Stranger = true }, 'return { disabled = {}, known = {} }')
    local g = start(it)
    t.eq(g.state("Stranger"), "disabled new")
    t.eq(ran("Stranger"), 0)
    g.close()
end)

t.test("a mod that turns up while the game runs is held, whatever brought the look about", function()
    local it = install({ Base = true, Other = true })
    local g = start(it)
    local function held_after(id, act)
        it.put(id)
        act()
        g.run(0.5)
        t.eq(g.state(id), "disabled new", id)
        t.eq(ran(id), 0, id)
    end
    held_after("ByRequest", function() g.loader.request_sync() end)
    held_after("ByOldRequest", function() g.loader.request_sync(true) end)
    held_after("ByLook", function() g.loader.sync() end)
    held_after("BySwitch", function() g.loader.set_enabled("Other", false) end)
    held_after("ByReload", function() g.loader.request_reload("Base") end)
    held_after("ByRemove", function() t.ok(g.loader.remove("Other")) end)
    t.eq(#g.held, 6, "each was announced once")
    t.eq(g.state("Base"), "loaded")
    g.close()
end)

t.test("a mod the player removes is forgotten: put back under its name, it is new", function()
    local it = install({ Keep = true, Leaves = true })
    local g = start(it)
    local kept = g.loader.remove("Leaves")
    t.ok(kept and kept:find("^%.removed%-Leaves%-"), tostring(kept))
    g.run(1)
    t.eq(g.state("Leaves"), nil)
    t.eq(it.saved().known.Leaves, nil)
    t.eq(it.saved().known.Keep, true)
    t.ok(os.rename(it.mods .. "/" .. kept, it.mods .. "/Leaves"))
    g.loader.request_sync()
    g.run(1)
    t.eq(g.state("Leaves"), "disabled new")
    t.eq(ran("Leaves"), 1, "it ran once, before it was removed, and not again")
    t.eq(table.concat(g.held, " | "), "Leaves: Leaves")
    g.close()
end)

t.test("a mod whose folder is gone when the game starts is forgotten, and one that comes back later is new", function()
    local it = install({ Stays = true, Visits = true })
    start(it).close()
    t.ok(os.rename(it.mods .. "/Visits", it.mods .. "/.away"))
    local g = start(it)
    t.eq(g.state("Visits"), nil)
    g.run(1)
    t.eq(it.saved().known.Visits, nil)
    t.eq(it.saved().known.Stays, true)
    g.close()
    t.ok(os.rename(it.mods .. "/.away", it.mods .. "/Visits"))
    g = start(it)
    t.eq(g.state("Visits"), "disabled new")
    t.eq(ran("Visits"), 1, "it ran in the first game only")
    t.eq(g.state("Stays"), "loaded")
    g.close()
end)

t.test("a folder that goes and comes back while the game runs keeps the state it had", function()
    local it = install({ On = true, Off = true }, 'return { disabled = { Off = true }, known = { On = true, Off = true } }')
    local g = start(it)
    t.eq(g.state("On"), "loaded")
    t.eq(g.state("Off"), "disabled")
    for _, id in ipairs({ "On", "Off" }) do t.ok(os.rename(it.mods .. "/" .. id, it.mods .. "/.moving-" .. id)) end
    g.loader.request_sync()
    g.run(1)
    t.eq(g.state("On"), nil)
    t.eq(g.state("Off"), nil)
    for _, id in ipairs({ "On", "Off" }) do t.ok(os.rename(it.mods .. "/.moving-" .. id, it.mods .. "/" .. id)) end
    g.loader.request_sync()
    g.run(1)
    t.eq(g.state("On"), "loaded", "which is what replacing a mod's folder with a newer copy looks like")
    t.eq(g.state("Off"), "disabled")
    t.eq(#g.held, 0)
    g.close()
end)

t.test("while the folders cannot be listed nothing is forgotten, nothing is taken for seen, and nothing new is started", function()
    -- a saved file from before the list, and a first look that fails
    local it = install({ One = true, Two = true }, 'return { disabled = { Two = true } }')
    local g = start(it, { unlisted = true })
    t.eq(#g.loader.list(), 0)
    t.eq(g.logged("could not list the mods folder", "warn"), 1)
    g.run(1)
    t.eq(it.saved().known, nil, "the saved file is as it was")
    g.unlisted = false
    g.loader.request_sync()
    g.run(1)
    t.eq(g.state("One"), "loaded", "the rule for an older saved file waits for a look that works")
    t.eq(g.state("Two"), "disabled")
    t.eq(it.saved().known.One, true)
    g.close()

    -- a list that is there, and a first look that fails
    it.put("Three")
    g = start(it, { unlisted = true })
    g.run(1)
    t.eq(it.saved().known.One, true, "a failed look forgets nobody")
    g.unlisted = false
    g.loader.request_sync()
    g.run(1)
    t.eq(g.state("One"), "loaded")
    t.eq(g.state("Three"), "disabled new")
    t.eq(ran("Three"), 0)
    -- and one that fails later takes the mods off the list for as long as it lasts, no longer
    g.unlisted = true
    g.loader.request_sync()
    g.run(1)
    t.eq(g.state("One"), nil)
    g.unlisted = false
    g.loader.request_sync()
    g.run(1)
    t.eq(g.state("One"), "loaded")
    t.eq(g.state("Two"), "disabled")
    t.eq(g.state("Three"), "disabled new")
    t.eq(ran("Three"), 0)
    t.eq(table.concat(g.held, " | "), "Three: Three", "and the new mod was announced once in all")
    g.close()
end)

t.test("a saved file edited so a new mod is not switched off does not start it", function()
    local it = install({ Had = true })
    start(it).close()
    it.put("Sneaks")
    write(it.root .. "/saved/wax.mods.lua", 'return { disabled = {}, known = { Had = true } }')
    local g = start(it)
    t.eq(g.state("Sneaks"), "disabled new", "only the list of seen mods lets a mod start")
    t.eq(ran("Sneaks"), 0)
    g.close()
end)

t.test("in a player's install the index of mods in other folders is not read", function()
    local it = install({ Mine = true })
    local outside = base .. "/outside/Elsewhere"
    write(outside .. "/init.lua", body())
    write(it.root .. "/run/mods.index.lua", ('return { mods = { { id = "Elsewhere", dir = %q, files = { "init.lua" } } } }'):format(outside))
    local g = start(it)
    t.eq(g.state("Elsewhere"), nil)
    t.eq(ran("Elsewhere"), 0)
    t.eq(#g.loader.list(), 1)
    g.close()

    -- with developer mode on it is listed, and held like any mod the player has not seen
    write(it.root .. "/dev.txt", "")
    g = start(it)
    t.eq(g.state("Elsewhere"), "disabled new")
    t.eq(ran("Elsewhere"), 0)
    t.eq(g.state("Mine"), "loaded")
    g.close()
end)

-- mod-added, the command the bridge passes on when something outside put a mod's folder in
local function named(id, name, version, made)
    return { ["mod.lua"] = ('return { id = %q, name = %q, version = %q }'):format(id, name, version), ["init.lua"] = body(made) }
end

t.test("mod-added for a mod the player did not have: listed switched off, and one notification in the mod's own words", function()
    local it = install({ Mine = true })
    local g = start(it)
    it.put("Arrives", named("Arrives", "Arrives Mod", "1.2.0"))
    local result = g.loader.added("Arrives")
    t.eq(result.id, "Arrives")
    t.eq(result.name, "Arrives Mod")
    t.eq(result.version, "1.2.0")
    t.eq(result.status, "disabled")
    t.eq(result.enabled, false)
    t.eq(result.fresh, true)
    t.eq(ran("Arrives"), 0)
    t.eq(#g.notes, 1)
    t.eq(g.notes[1].text, "Arrives Mod 1.2.0 was added. It stays switched off until you switch it on in the Mods page.")
    t.eq(g.notes[1].options.title, "New mod")
    t.eq(#g.held, 0, "the loader says it itself, so it is said once")
    -- said again for the same mod, it is still off
    t.eq(g.loader.added("Arrives").fresh, true)
    t.eq(g.state("Arrives"), "disabled new")
    t.eq(ran("Arrives"), 0)
    t.eq(#g.notes, 2)
    g.close()
end)

t.test("mod-added for a mod that was running loads the new files, and one that was switched off stays off", function()
    local it = install({ Runs = named("Runs", "Runs Mod", "1.0.0", "old"), Sleeps = named("Sleeps", "Sleeps Mod", "1.0.0", "old") },
        'return { disabled = { Sleeps = true }, known = { Runs = true, Sleeps = true } }')
    local g = start(it)
    t.eq(g.made("Runs"), "old")
    it.put("Runs", named("Runs", "Runs Mod", "1.1.0", "new"))
    it.put("Sleeps", named("Sleeps", "Sleeps Mod", "1.1.0", "new"))
    local result = g.loader.added("Runs")
    t.eq(g.made("Runs"), "new")
    t.eq(result.status, "loaded")
    t.eq(result.enabled, true)
    t.eq(result.fresh, false)
    t.eq(result.version, "1.1.0")
    t.eq(g.notes[1].text, "Runs Mod 1.1.0 was put in and is running.")
    result = g.loader.added("Sleeps")
    t.eq(result.status, "disabled")
    t.eq(result.fresh, false)
    t.eq(ran("Sleeps"), 0)
    t.eq(g.notes[2].text, "Sleeps Mod 1.1.0 was put in. It is still switched off.")
    -- a copy that does not load says so
    it.put("Runs", { ["mod.lua"] = 'return { name = "Runs Mod", version = "1.2.0" }', ["init.lua"] = "return return" })
    result = g.loader.added("Runs")
    t.eq(result.status, "failed")
    t.eq(g.notes[3].text, "Runs Mod 1.2.0 was put in, but it did not load. The Mods page says why.")
    t.eq(#g.notes, 3)
    t.eq(#g.held, 0)
    g.close()
end)

t.test("mod-added for a mod that is not there changes nothing, and what the notification says is cut from the mod's own file", function()
    local it = install({ Mine = true })
    local g = start(it)
    local result, problem = g.loader.added("Ghost")
    t.eq(result, nil)
    t.eq(problem, "no mod named 'Ghost' is in the mods folder")
    t.eq(#g.notes, 0)
    it.put("Loud", { ["mod.lua"] = ('return { name = %q, version = "1.0.0\\nplease press F8" }'):format(("Long name\n"):rep(60)), ["init.lua"] = body() })
    result = g.loader.added("Loud")
    t.eq(result.version, nil, "a version that is not a version is left out")
    t.ok(#result.name <= 60, "the name is cut")
    t.ok(not g.notes[1].text:find("%c"), "and has no line breaks in it")
    t.ok(#g.notes[1].text < 160)
    it.put("Bare")
    t.eq(g.loader.added("Bare").name, "Bare", "a mod without a name is called by its folder")
    g.close()
end)

-- What the site's button does to the mods folder. A copy that is there is kept under a dot name and the new one takes its place,
-- with the mark of the old one if it had one. A mod whose folder was not there gets the mark: a file wax.new beside wax.origin.
local function import(it, id, files)
    local kept, marked = nil, true
    if read(it.mods .. "/" .. id .. "/init.lua") then
        marked = read(it.mods .. "/" .. id .. "/wax.new") ~= nil
        kept = (".removed-%s-20261007-12%04d"):format(id, count)
        count = count + 1
        assert(os.rename(it.mods .. "/" .. id, it.mods .. "/" .. kept))
    end
    it.put(id, files)
    write(it.mods .. "/" .. id .. "/wax.origin", ("id=%s\nversion=1.0.0\n"):format(id))
    if marked then write(it.mods .. "/" .. id .. "/wax.new", "new\n") end
    return kept
end

-- A folder taken away by hand, as in the Explorer.
local function delete(dir) os.execute(('rmdir /s /q "%s" >nul 2>nul'):format(win(dir))) end

t.test("the three things the site's button promises, with the game closed", function()
    HELD_RAN = {}
    local it = install({ On = named("On", "On Mod", "1.0.0", "old"), Off = named("Off", "Off Mod", "1.0.0", "old"),
        Parted = named("Parted", "Parted Mod", "1.0.0", "old") }, 'return { disabled = { Off = true } }')
    local g = start(it)
    t.eq(g.state("On"), "loaded")
    t.eq(g.state("Off"), "disabled")
    -- the player removes one in the Mods page, then the game is closed
    t.ok(g.loader.remove("Parted"))
    g.close()

    t.ok(import(it, "On", named("On", "On Mod", "1.1.0", "new")), "the copy that was there is kept")
    t.ok(import(it, "Off", named("Off", "Off Mod", "1.1.0", "new")))
    t.eq(import(it, "Fresh", named("Fresh", "Fresh Mod", "1.0.0", "new")), nil)
    t.eq(import(it, "Parted", named("Parted", "Parted Mod", "1.1.0", "new")), nil)
    g = start(it)
    t.eq(g.state("Fresh"), "disabled new", "a mod the player did not have is listed switched off")
    t.eq(ran("Fresh"), 0)
    t.eq(g.state("On"), "loaded", "a mod they had stays switched on")
    t.eq(g.made("On"), "new", "and it is the new copy that runs")
    t.eq(g.state("Off"), "disabled", "or stays switched off, without being new")
    t.eq(g.state("Parted"), "disabled new", "a mod that was removed and added again comes up switched off")
    t.eq(ran("Parted"), 1, "it ran before it was removed, and not since")
    t.eq(#g.loader.list(), 4, "the copies kept under a dot name are not mods")
    g.close()

    -- the same for a mod whose folder was gone when the game last started
    t.ok(os.rename(it.mods .. "/On", it.mods .. "/.set-aside"))
    start(it).close()
    import(it, "On", named("On", "On Mod", "1.2.0", "newer"))
    g = start(it)
    t.eq(g.state("On"), "disabled new")
    t.eq(g.made("On"), nil)
    g.close()
end)

t.test("the three things the site's button promises, while the game runs", function()
    HELD_RAN = {}
    local it = install({ On = named("On", "On Mod", "1.0.0", "old"), Off = named("Off", "Off Mod", "1.0.0", "old"),
        Parted = named("Parted", "Parted Mod", "1.0.0", "old") }, 'return { disabled = { Off = true } }')
    local g = start(it, { watching = true })
    t.ok(g.loader.remove("Parted"))
    g.run(1)

    import(it, "Fresh", named("Fresh", "Fresh Mod", "1.0.0", "new"))
    t.eq(g.loader.added("Fresh").fresh, true)
    t.eq(g.state("Fresh"), "disabled new")

    import(it, "On", named("On", "On Mod", "1.1.0", "new"))
    local result = g.loader.added("On")
    t.eq(result.status, "loaded")
    t.eq(result.fresh, false)
    t.eq(g.made("On"), "new", "the new copy was loaded")

    import(it, "Off", named("Off", "Off Mod", "1.1.0", "new"))
    result = g.loader.added("Off")
    t.eq(result.status, "disabled")
    t.eq(result.fresh, false)

    import(it, "Parted", named("Parted", "Parted Mod", "1.1.0", "new"))
    result = g.loader.added("Parted")
    t.eq(result.status, "disabled")
    t.eq(result.fresh, true, "removed in the Mods page and added again, it is new")
    t.eq(ran("Parted"), 1)

    -- the game noticing the folder gone between the two halves of the swap changes nothing about that
    t.ok(os.rename(it.mods .. "/On", it.mods .. "/.removed-On-20261007-130000"))
    g.run(30)
    t.eq(g.state("On"), nil, "the file watcher saw the folder go")
    it.put("On", named("On", "On Mod", "1.2.0", "newer"))
    result = g.loader.added("On")
    t.eq(result.status, "loaded", "it is still a mod the player had, and switched on")
    t.eq(result.fresh, false)
    t.eq(g.made("On"), "newer")
    t.eq(table.concat(g.held, " | "), "", "each was said once, by the loader itself")
    local texts = {}
    for index, shown in ipairs(g.notes) do texts[index] = shown.text end
    t.eq(table.concat(texts, "\n"), table.concat({
        "Fresh Mod 1.0.0 was added. It stays switched off until you switch it on in the Mods page.",
        "On Mod 1.1.0 was put in and is running.",
        "Off Mod 1.1.0 was put in. It is still switched off.",
        "Parted Mod 1.1.0 was added. It stays switched off until you switch it on in the Mods page.",
        "On Mod 1.2.0 was put in and is running.",
    }, "\n"))
    g.close()
end)

-- The mark: wax.new in the folder of a copy the site's button put in for a player who did not have the mod
t.test("a mod deleted by hand and put back by the button while the game was closed is held, though it was known and switched on", function()
    HELD_RAN = {}
    local it = install({ Mine = named("Mine", "Mine Mod", "1.0.0", "old"), Other = true })
    local g = start(it)
    t.eq(g.state("Mine"), "loaded")
    g.close()
    delete(it.mods .. "/Mine")
    t.eq(import(it, "Mine", named("Mine", "Mine Mod", "1.1.0", "new")), nil, "there was no copy to keep")
    t.eq(read(it.mods .. "/Mine/wax.new"), "new\n")
    t.eq(it.saved().known.Mine, true, "going by what was written down alone, it would start")
    t.eq(it.saved().disabled.Mine, nil)

    g = start(it)
    t.eq(g.state("Mine"), "disabled new", "the mark says the player has not seen this copy")
    t.eq(g.status("Mine").enabled, false)
    t.eq(ran("Mine"), 1, "it ran in the first game, and not since")
    t.eq(g.state("Other"), "loaded")
    t.eq(table.concat(g.held, " | "), "Mine: Mine Mod", "the interface is told, as for any new mod")
    g.run(1)
    t.eq(it.saved().known.Mine, nil, "what is written down now says the same")
    t.eq(it.saved().disabled.Mine, true)
    for _ = 1, 3 do g.loader.sync() end
    g.loader.request_reload("Mine")
    g.run(1)
    t.eq(g.state("Mine"), "disabled new", "looking again does not start it")
    t.eq(ran("Mine"), 1)
    g.close()

    -- the start after that: still held, and not announced a second time
    g = start(it)
    t.eq(g.state("Mine"), "disabled new")
    t.eq(#g.held, 0)
    -- switched on by the player: the file goes, the mod is known and runs
    t.eq(g.loader.set_enabled("Mine", true), true)
    g.run(1)
    t.eq(read(it.mods .. "/Mine/wax.new"), nil, "the mark is deleted")
    t.ok(read(it.mods .. "/Mine/wax.origin"), "and nothing else in the folder is")
    t.eq(g.state("Mine"), "loaded")
    t.eq(g.made("Mine"), "new")
    t.eq(ran("Mine"), 2)
    t.eq(it.saved().known.Mine, true)
    t.eq(it.saved().disabled.Mine, nil)
    t.eq(g.logged("", "warn") + g.logged("", "error"), 0)
    g.close()

    -- and it stays on across a restart
    g = start(it)
    t.eq(g.state("Mine"), "loaded")
    t.eq(ran("Mine"), 3)
    t.eq(#g.held, 0)
    g.close()
end)

t.test("the same while the game runs: seen to go or not, with or without the button's message, the marked copy is held", function()
    HELD_RAN = {}
    local it = install({ Seen = named("Seen", "Seen Mod", "1.0.0", "old"), Unseen = named("Unseen", "Unseen Mod", "1.0.0", "old"),
        Quiet = named("Quiet", "Quiet Mod", "1.0.0", "old") })
    local g = start(it)
    t.eq(g.state("Seen") .. " " .. g.state("Unseen") .. " " .. g.state("Quiet"), "loaded loaded loaded")

    -- the game saw the folder go before the button put the mod back
    delete(it.mods .. "/Seen")
    g.loader.request_sync()
    g.run(1)
    t.eq(g.state("Seen"), nil)
    import(it, "Seen", named("Seen", "Seen Mod", "1.1.0", "new"))
    local result = g.loader.added("Seen")
    t.eq(result.status, "disabled")
    t.eq(result.enabled, false)
    t.eq(result.fresh, true, "the answer is the one for a new mod, though its name was known")
    t.eq(g.state("Seen"), "disabled new")
    t.eq(g.notes[#g.notes].text, "Seen Mod 1.1.0 was added. It stays switched off until you switch it on in the Mods page.")
    t.eq(g.notes[#g.notes].options.title, "New mod")
    t.eq(ran("Seen"), 1)

    -- the game never looked in between: the copy that was running is taken out, and the new one does not start
    delete(it.mods .. "/Unseen")
    import(it, "Unseen", named("Unseen", "Unseen Mod", "1.1.0", "new"))
    t.eq(g.made("Unseen"), "old", "the old copy is still running at this moment")
    result = g.loader.added("Unseen")
    t.eq(result.fresh, true)
    t.eq(result.status, "disabled")
    t.eq(g.state("Unseen"), "disabled new")
    t.eq(g.made("Unseen"), nil)
    t.eq(ran("Unseen"), 1)
    t.eq(g.notes[#g.notes].text, "Unseen Mod 1.1.0 was added. It stays switched off until you switch it on in the Mods page.")
    t.eq(#g.notes, 2)
    t.eq(#g.held, 0, "said by the loader itself, once each")

    -- no message from the button at all: the next look at the folder finds the mark
    delete(it.mods .. "/Quiet")
    import(it, "Quiet", named("Quiet", "Quiet Mod", "1.1.0", "new"))
    g.loader.request_sync()
    g.run(1)
    t.eq(g.state("Quiet"), "disabled new")
    t.eq(g.made("Quiet"), nil)
    t.eq(ran("Quiet"), 1)
    t.eq(table.concat(g.held, " | "), "Quiet: Quiet Mod")
    local saved = it.saved()
    t.eq(saved.known.Seen or saved.known.Unseen or saved.known.Quiet, nil)
    t.eq(saved.disabled.Seen and saved.disabled.Unseen and saved.disabled.Quiet, true, "each is written down as switched off too")

    -- mod-added again for a copy that still has its mark changes nothing
    t.eq(g.loader.added("Seen").fresh, true)
    t.eq(ran("Seen"), 1)
    -- switched on, each loses its mark and runs
    for _, id in ipairs({ "Seen", "Unseen", "Quiet" }) do
        g.loader.set_enabled(id, true)
        g.run(1)
        t.eq(g.state(id), "loaded", id)
        t.eq(g.made(id), "new", id)
        t.eq(read(it.mods .. "/" .. id .. "/wax.new"), nil, id)
    end
    g.close()
    g = start(it)
    t.eq(g.state("Seen") .. " " .. g.state("Unseen") .. " " .. g.state("Quiet"), "loaded loaded loaded", "and they stay on")
    g.close()
end)

t.test("a mark that cannot be deleted: the mod runs for this game, the log says so, and it is held again at the next start", function()
    HELD_RAN = {}
    local it = install({ Stuck = named("Stuck", "Stuck Mod", "1.0.0", "old") })
    start(it).close()
    delete(it.mods .. "/Stuck")
    import(it, "Stuck", named("Stuck", "Stuck Mod", "1.1.0", "new"))
    local real_remove = os.remove
    local ok, problem = pcall(function()
        os.remove = function(path)
            if path:lower():find("wax%.new$") then return nil, path .. ": Permission denied", 13 end
            return real_remove(path)
        end
        local g = start(it)
        t.eq(g.state("Stuck"), "disabled new")
        t.eq(g.loader.set_enabled("Stuck", true), true)
        g.run(1)
        t.eq(g.state("Stuck"), "loaded", "the player switched it on, so it runs")
        t.eq(g.made("Stuck"), "new")
        t.eq(read(it.mods .. "/Stuck/wax.new"), "new\n", "the file is still there")
        t.eq(g.logged("Stuck was switched on, but wax.new in its folder could not be removed", "warn"), 1)
        t.eq(g.logged("It is switched off again the next time the game starts", "warn"), 1)
        for _ = 1, 3 do g.loader.sync() end
        g.loader.request_reload("Stuck")
        g.run(1)
        t.eq(g.state("Stuck"), "loaded", "and it keeps running through later looks and reloads")
        t.eq(g.logged("", "warn"), 1, "one line in the log")
        -- the button puts a marked copy in again in this same game: that one is held like any other, until it is switched on
        it.put("Stuck", named("Stuck", "Stuck Mod", "1.2.0", "newest"))
        t.eq(g.loader.added("Stuck").fresh, true)
        t.eq(g.state("Stuck"), "disabled new")
        t.eq(g.made("Stuck"), nil)
        t.eq(ran("Stuck"), 3, "old once, new twice (switched on, reloaded), and the newest not at all")
        g.loader.set_enabled("Stuck", true)
        g.run(1)
        t.eq(g.made("Stuck"), "newest")
        g.close()

        g = start(it)
        t.eq(g.state("Stuck"), "disabled new", "at the next start the mark holds it again")
        t.eq(ran("Stuck"), 4, "and none of it ran at this start")
        t.eq(table.concat(g.held, " | "), "Stuck: Stuck Mod")
        g.close()
    end)
    os.remove = real_remove
    if not ok then error(problem, 0) end

    -- once the file can be deleted, switching on is for good
    local g = start(it)
    t.eq(g.state("Stuck"), "disabled new")
    g.loader.set_enabled("Stuck", true)
    g.run(1)
    t.eq(read(it.mods .. "/Stuck/wax.new"), nil)
    g.close()
    g = start(it)
    t.eq(g.state("Stuck"), "loaded")
    g.close()
end)

t.test("a mark that is gone by the time the mod is switched on is no trouble", function()
    local it = install({ Had = true })
    start(it).close()
    import(it, "Gone", named("Gone", "Gone Mod", "1.0.0", "new"))
    local g = start(it)
    t.eq(g.state("Gone"), "disabled new")
    t.ok(os.remove(it.mods .. "/Gone/wax.new"))
    t.eq(g.loader.set_enabled("Gone", true), true)
    g.run(1)
    t.eq(g.state("Gone"), "loaded")
    t.eq(g.logged("", "warn"), 0)
    g.close()
end)

t.test("a replace keeps the state: no mark on a copy the player had, and the mark carried over on one still new", function()
    HELD_RAN = {}
    local it = install({ On = named("On", "On Mod", "1.0.0", "old"), Off = named("Off", "Off Mod", "1.0.0", "old") },
        'return { disabled = { Off = true }, known = { On = true, Off = true } }')
    import(it, "New", named("New", "New Mod", "1.0.0", "old"))
    local g = start(it)
    t.eq(g.state("On") .. " | " .. g.state("Off") .. " | " .. g.state("New"), "loaded | disabled | disabled new")
    for _, id in ipairs({ "On", "Off", "New" }) do t.ok(import(it, id, named(id, id .. " Mod", "1.1.0", "new")), id) end
    t.eq(read(it.mods .. "/On/wax.new"), nil, "a copy the player had gets no mark")
    t.eq(read(it.mods .. "/Off/wax.new"), nil)
    t.eq(read(it.mods .. "/New/wax.new"), "new\n", "a copy that was still new keeps its mark")
    t.eq(g.loader.added("On").status, "loaded")
    t.eq(g.made("On"), "new")
    t.eq(g.loader.added("Off").fresh, false)
    t.eq(g.state("Off"), "disabled")
    t.eq(g.loader.added("New").fresh, true)
    t.eq(g.state("New"), "disabled new")
    t.eq(ran("New") + ran("Off"), 0)
    g.close()
    -- and the same replaces with the game closed
    for _, id in ipairs({ "On", "Off", "New" }) do t.ok(import(it, id, named(id, id .. " Mod", "1.2.0", "newer")), id) end
    g = start(it)
    t.eq(g.state("On") .. " | " .. g.state("Off") .. " | " .. g.state("New"), "loaded | disabled | disabled new")
    t.eq(g.made("On"), "newer")
    t.eq(ran("New") + ran("Off"), 0)
    g.close()
end)

t.test("the mark counts in any letter case, only beside the mod's own files, and before anything that was written down", function()
    HELD_RAN = {}
    local function marked(name) return { ["init.lua"] = body(), [name] = "new\n" } end
    local it = install({ Upper = marked("WAX.NEW"), Mixed = marked("Wax.New"), WasOff = marked("wax.new"), Deep = marked("sub/wax.new"),
        Longer = marked("wax.new.txt"), Shorter = marked("ax.new") },
        'return { disabled = { WasOff = true }, known = { Upper = true, Mixed = true, WasOff = true, Deep = true, Longer = true, Shorter = true } }')
    local g = start(it)
    t.eq(g.state("Upper"), "disabled new")
    t.eq(g.state("Mixed"), "disabled new")
    t.eq(g.state("WasOff"), "disabled new", "a mod the player had switched off is new again as well")
    t.eq(g.state("Deep"), "loaded", "a file of that name in a folder of the mod is the mod's own business")
    t.eq(g.state("Longer"), "loaded")
    t.eq(g.state("Shorter"), "loaded")
    t.eq(ran("Upper") + ran("Mixed") + ran("WasOff"), 0)
    t.eq(#g.held, 3, "each is announced, also the one that was written down as switched off")
    g.loader.set_enabled("Upper", true)
    g.loader.set_enabled("Mixed", true)
    g.run(1)
    t.eq(read(it.mods .. "/Upper/WAX.NEW"), nil, "the file is deleted under the name it has")
    t.eq(read(it.mods .. "/Mixed/Wax.New"), nil)
    t.eq(g.state("Upper") .. " " .. g.state("Mixed"), "loaded loaded")
    t.ok(read(it.mods .. "/Deep/sub/wax.new"), "and a file that was not the mark is left alone")
    g.close()

    -- a first start, with no list yet or one from before it: what is there counts as seen, a marked copy does not
    for _, saved in ipairs({ false, "return { disabled = {} }" }) do
        it = install({ Came = true, Marked = marked("wax.new") }, saved or nil)
        g = start(it)
        t.eq(g.state("Came"), "loaded")
        t.eq(g.state("Marked"), "disabled new")
        t.eq(table.concat(g.held, " | "), "Marked: Marked")
        g.run(1)
        t.eq(it.saved().known.Came, true)
        t.eq(it.saved().known.Marked, nil)
        g.close()
    end
    t.eq(ran("Marked"), 0)
end)

t.finish("held")
