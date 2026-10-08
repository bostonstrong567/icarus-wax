-- Offline tests for the mod loader: environments, require, dependencies, reload, failure handling.
-- The mods are in folders of their own and reach the loader through the index, as a mod author's do in developer mode.
-- (held_test.lua has the player's side: the mods folder itself, and mods the player has not seen.)
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\mods_test.lua <empty scratch dir>

local t = dofile("wax/tests/offline/harness.lua")
local scratch = assert(arg[1], "usage: mods_test.lua <empty scratch dir>"):gsub("\\", "/")
if not scratch:match("^%a:") then scratch = io.popen("cd"):read("l"):gsub("\\", "/") .. "/" .. scratch end
local root = scratch .. "/Binaries/Win64/ue4ss/Mods/Wax"

local function mkdir(path) os.execute('mkdir "' .. path:gsub("/", "\\") .. '" >nul 2>nul') end
local function write(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
end

mkdir(root .. "/run")
mkdir(root .. "/saved")
write(root .. "/dev.txt", "")                -- developer mode: the loader reads <root>/run/mods.index.lua
-- Wax's own folder as UE4SS lists it, with an empty mods folder
function IterateGameDirectories()
    return { Game = { Binaries = { Win64 = { ue4ss = { Mods = { Wax = { mods = { __files = {} } } } } } } } }
end

local Wax = t.new_wax()
Wax.root = root
local scope = Wax.import("core.scope")
local log = Wax.import("core.log")
local guard = Wax.import("core.guard")
local sched = Wax.import("core.sched")
local loader = Wax.import("mods.loader")

local now = 0
sched.clock = function() return now end
local function frame()
    now = now + 0.016
    loader.step()
    sched.step()
end

-- Looks at the folders and switches on what is new, as the player does in the Mods page.
local look = loader.sync
local function sync()
    local summary = look()
    local any = false
    for _, entry in ipairs(loader.list()) do
        if entry.fresh then
            loader.set_enabled(entry.id, true)
            any = true
        end
    end
    if any then look() end
    return summary
end

local known = {}    -- id -> { files }

-- Writes a mod's files and rewrites the index the way the command-line tool would.
local function put_mod(id, files)
    mkdir(scratch .. "/" .. id)
    local names = {}
    for name, text in pairs(files) do
        local folder = name:match("^(.*)/[^/]+$")
        if folder then mkdir(scratch .. "/" .. id .. "/" .. folder) end
        write(scratch .. "/" .. id .. "/" .. name, text)
        names[#names + 1] = name
    end
    table.sort(names)
    known[id] = names
end

local function write_index()
    local lines = { "return { mods = {" }
    local ids = {}
    for id in pairs(known) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local quoted = {}
        for i, name in ipairs(known[id]) do quoted[i] = ("%q"):format(name) end
        lines[#lines + 1] = ("  { id = %q, dir = %q, files = { %s } },"):format(id, scratch .. "/" .. id, table.concat(quoted, ", "))
    end
    lines[#lines + 1] = "} }"
    write(root .. "/run/mods.index.lua", table.concat(lines, "\n"))
end

local function status(id)
    for _, entry in ipairs(loader.list()) do
        if entry.id == id then return entry end
    end
end

local function logged(fragment)
    for _, entry in ipairs(log.since(0)) do
        if entry.message:find(fragment, 1, true) then return true end
    end
    return false
end

shared = { hits = 0 }       -- a real global the test mods reach through their environment's fallback
local signal = sched.Signal.new("test")
shared.signal = signal

t.test("a mod loads in its own environment, with require, print and exports", function()
    put_mod("Alpha", {
        ["mod.lua"] = 'return { name = "Alpha Mod", version = "1.2.3" }',
        ["init.lua"] = [[
            local util = require("util")
            local deep = require("sub.deep")
            local pack = require("pack")
            leaked = "alpha-global"
            print("hello from", mod.id, mod.version)
            return { double = util.double, deep = deep, pack = pack, name = mod.name }
        ]],
        ["util.lua"] = "return { double = function(n) return n * 2 end }",
        ["sub/deep.lua"] = "return 'deep module'",
        ["pack/init.lua"] = "return 'folder module'",
    })
    write_index()
    sync()
    local entry = status("Alpha")
    t.eq(entry.status, "loaded")
    t.eq(entry.version, "1.2.3")
    local exports = loader.get("Alpha").exports
    t.eq(exports.double(21), 42)
    t.eq(exports.deep, "deep module")
    t.eq(exports.pack, "folder module")
    t.eq(exports.name, "Alpha Mod")
    t.eq(rawget(_G, "leaked"), nil, "a mod's globals stay in its own environment")
    t.ok(logged("hello from\tAlpha\t1.2.3"), "print goes to the log")
end)

t.test("dependencies load first and are reached with require('@Id'); undeclared use is an error", function()
    put_mod("Beta", {
        ["mod.lua"] = 'return { dependencies = { "Alpha" } }',
        ["init.lua"] = 'local alpha = require("@Alpha") return { value = alpha.double(5) }',
    })
    put_mod("Gamma", { ["init.lua"] = 'return require("@Alpha")' })
    write_index()
    sync()
    t.eq(loader.get("Beta").exports.value, 10)
    t.eq(status("Gamma").status, "failed")
    t.ok(status("Gamma").error:find("does not list", 1, true), status("Gamma").error)
    local order = {}
    for i, entry in ipairs(loader.list()) do order[entry.id] = i end
    t.ok(order.Alpha < order.Beta, "dependency sorted first")
end)

t.test("a missing dependency fails with a clear message and loads once the dependency arrives", function()
    put_mod("Delta", {
        ["mod.lua"] = 'return { dependencies = { "Epsilon" } }',
        ["init.lua"] = 'return require("@Epsilon")',
    })
    write_index()
    sync()
    t.eq(status("Delta").status, "failed")
    t.ok(status("Delta").error:find("Epsilon", 1, true))
    put_mod("Epsilon", { ["init.lua"] = "return 'here now'" })
    write_index()
    sync()
    t.eq(status("Delta").status, "loaded")
    t.eq(loader.get("Delta").exports, "here now")
end)

t.test("reload undoes what the mod set up, keeps persist() state, and reloads dependents", function()
    put_mod("Zeta", {
        ["init.lua"] = [[
            local state = persist("counter", { loads = 0 })
            state.loads = state.loads + 1
            shared.signal:Connect(function() shared.hits = shared.hits + 1 end)
            task.spawn(function() while true do task.wait() shared.ticks = (shared.ticks or 0) + 1 end end)
            return { loads = state.loads }
        ]],
    })
    put_mod("Eta", {
        ["mod.lua"] = 'return { dependencies = { "Zeta" } }',
        ["init.lua"] = 'return { sawLoads = require("@Zeta").loads }',
    })
    write_index()
    sync()
    signal:Fire()
    t.eq(shared.hits, 1)
    frame()
    t.eq(shared.ticks, 1)
    for _ = 1, 5 do t.ok(loader.reload("Zeta")) end
    signal:Fire()
    t.eq(shared.hits, 2, "exactly one connection after five reloads")
    shared.ticks = 0
    frame()
    t.eq(shared.ticks, 1, "exactly one task after five reloads")
    t.eq(loader.get("Zeta").exports.loads, 6, "persist() survived the reloads")
    t.eq(loader.get("Eta").exports.sawLoads, 6, "the dependent was reloaded after its dependency")
    t.eq(status("Zeta").generation, 6)
end)

t.test("a syntax error or a failing init leaves nothing behind, and a fixed file loads again", function()
    guard.clear_errors()
    put_mod("Theta", { ["init.lua"] = "shared.signal:Connect(function() shared.theta = true end)\nlocal x = = 1" })
    write_index()
    sync()
    t.eq(status("Theta").status, "failed")
    t.ok(status("Theta").error:find("Theta/init.lua:2", 1, true), "error names the file and line: " .. status("Theta").error)
    put_mod("Theta", { ["init.lua"] = "shared.signal:Connect(function() shared.theta = true end)\nerror('init exploded')" })
    loader.reload("Theta")
    t.eq(status("Theta").status, "failed")
    t.ok(status("Theta").error:find("init exploded", 1, true))
    signal:Fire()
    t.eq(shared.theta, nil, "the connection made before the failure was removed")
    put_mod("Theta", { ["init.lua"] = "return 'fixed'" })
    t.ok(loader.reload("Theta"))
    t.eq(loader.get("Theta").exports, "fixed")
end)

t.test("off-thread and restart functions are refused with an explanation; raw still reaches them", function()
    _G.LoopAsync = function() return "the real one" end
    put_mod("Iota", {
        ["init.lua"] = [[
            local ok, err = pcall(LoopAsync, 100, function() end)
            return { ok = ok, err = err, raw = raw.LoopAsync(), co = coroutine.create ~= raw.coroutine.create or true }
        ]],
    })
    write_index()
    sync()
    local exports = loader.get("Iota").exports
    _G.LoopAsync = nil
    t.eq(exports.ok, false)
    t.ok(exports.err:find("another thread", 1, true), exports.err)
    t.eq(exports.raw, "the real one")
end)

t.test("request_reload waits for the frame step; a removed mod unloads; a broken manifest is reported", function()
    put_mod("Kappa", { ["init.lua"] = "shared.kappa = (shared.kappa or 0) + 1 return true" })
    write_index()
    sync()
    t.eq(shared.kappa, 1)
    loader.request_reload("Kappa")
    t.eq(shared.kappa, 1, "not reloaded inline")
    frame()
    t.eq(shared.kappa, 2)
    known.Kappa = nil
    put_mod("Lambda", { ["mod.lua"] = "return { name = ", ["init.lua"] = "return true" })
    write_index()
    local summary = sync()
    t.eq(status("Kappa"), nil)
    t.eq(summary.removed[1], "Kappa")
    t.eq(status("Lambda").status, "failed")
    t.ok(status("Lambda").error:find("mod.lua", 1, true))
    t.eq(select(2, loader.reload("Nope")), "no mod named 'Nope'")
end)

t.test("saving a file reloads its mod with nothing outside the game involved", function()
    put_mod("Watched", { ["init.lua"] = "return { value = 1 }" })
    write_index()
    sync()
    t.eq(loader.get("Watched").exports.value, 1)
    local function frames_until(condition)
        for count = 1, 2000 do
            frame()
            if condition() then return count end
        end
        error("nothing happened in 2000 frames", 2)
    end

    write(scratch .. "/Watched/init.lua", "return { value = 2 }")
    frames_until(function() return status("Watched").generation == 2 end)
    t.eq(loader.get("Watched").exports.value, 2)

    -- a second save soon after is picked up faster, and a new file is found without a sync
    put_mod("Watched", { ["init.lua"] = "return { value = require('extra') }", ["extra.lua"] = "return 3" })
    write_index()
    local waited = frames_until(function() return status("Watched").generation == 3 end)
    t.eq(loader.get("Watched").exports.value, 3)
    t.ok(waited < 80, "a file being edited should reload within a second, took " .. waited .. " frames")

    -- a save that does not compile leaves the running version alone; the next good save is loaded
    write(scratch .. "/Watched/init.lua", "return {{{")
    frames_until(function() return status("Watched").waiting ~= nil end)
    t.eq(status("Watched").status, "loaded")
    t.eq(loader.get("Watched").exports.value, 3, "the version from before the broken save is still running")
    write(scratch .. "/Watched/init.lua", "return { value = 4 }")
    frames_until(function() return status("Watched").generation == 4 end)
    t.eq(loader.get("Watched").exports.value, 4)
    t.eq(status("Watched").waiting, nil)

    loader.set_watching(false)
    write(scratch .. "/Watched/init.lua", "return { value = 5 }")
    for _ = 1, 400 do frame() end
    t.eq(loader.get("Watched").exports.value, 4, "watching was switched off")
    loader.set_watching(true)
    frames_until(function() return loader.get("Watched").exports and loader.get("Watched").exports.value == 5 end)
end)

t.test("a mod whose folder is taken away while the game runs leaves the list by itself", function()
    put_mod("Leaving", { ["mod.lua"] = "return { name = 'Leaving' }", ["init.lua"] = "return true" })
    write_index()
    sync()
    t.eq(status("Leaving").status, "loaded")
    os.remove(scratch .. "/Leaving/init.lua")
    os.remove(scratch .. "/Leaving/mod.lua")
    known.Leaving = nil
    write_index()
    local gone = false
    for _ = 1, 2000 do
        frame()
        if not status("Leaving") then
            gone = true
            break
        end
    end
    t.ok(gone, "nothing asked for a look at the folders, and the mod is still listed")
end)

t.test("storage keeps a mod's settings on disk, one write for many saves", function()
    local storage = Wax.import("core.storage")
    t.eq(storage.directory, root .. "/saved")
    put_mod("Saver", { ["init.lua"] = [[
        local settings = storage.Load("settings", { volume = 5, nested = { on = true } })
        return { settings = settings, save = function() storage.Save("settings", settings) end }
    ]] })
    write_index()
    sync()
    local exports = loader.get("Saver").exports
    t.eq(exports.settings.volume, 5)
    exports.settings.volume = 9
    exports.settings.name = "a \"quoted\" name"
    exports.settings.nested.on = false
    exports.save()
    exports.save()
    t.ok(not io.open(root .. "/saved/Saver.settings.lua", "rb"), "nothing is written until the saves settle")
    for _ = 1, 60 do
        frame()
        storage.step()
    end
    local file = assert(io.open(root .. "/saved/Saver.settings.lua", "rb"), "the settings file was not written")
    file:close()
    loader.reload("Saver")
    local again = loader.get("Saver").exports.settings
    t.eq(again.volume, 9)
    t.eq(again.name, 'a "quoted" name')
    t.eq(again.nested.on, false)
    t.raises(function() storage.save("Saver", "../escape", {}) end, "may only use")
    t.raises(function() storage.save("Saver", "x", 5) end, "saves a table")
end)

t.test("a mod can be switched off and on, and what depends on it says why it stopped", function()
    put_mod("Base", { ["init.lua"] = "return { value = 1 }" })
    put_mod("Needs", { ["mod.lua"] = 'return { dependencies = { "Base" } }', ["init.lua"] = 'return { got = require("@Base").value }' })
    write_index()
    sync()
    t.eq(status("Needs").status, "loaded")
    t.ok(loader.set_enabled("Base", false))
    for _ = 1, 3 do frame() end
    t.eq(status("Base").status, "disabled")
    t.eq(loader.get("Base").exports, nil)
    t.eq(status("Needs").status, "failed")
    t.ok(status("Needs").error:find("Base", 1, true))
    loader.request_reload("Base")
    for _ = 1, 3 do frame() end
    t.eq(status("Base").status, "disabled", "reloading does not switch it back on")
    loader.set_enabled("Base", true)
    for _ = 1, 3 do frame() end
    t.eq(status("Base").status, "loaded")
    t.eq(status("Needs").status, "loaded")
    t.eq(loader.set_enabled("Nope", true), false)
end)

t.test("a mod that turns up while the game runs is listed but held until it is switched on", function()
    put_mod("Late", { ["init.lua"] = "return { value = 7 }" })
    write_index()
    local told = nil
    loader.on_held = function(id) told = id end
    loader.request_sync(true)
    for _ = 1, 3 do frame() end
    t.eq(status("Late").status, "disabled")
    t.ok(status("Late").fresh, "it is marked as new")
    t.eq(told, "Late", "and the interface is told")
    t.eq(loader.get("Late").exports, nil, "none of its code has run")
    loader.set_enabled("Late", true)
    for _ = 1, 3 do frame() end
    t.eq(status("Late").status, "loaded")
    t.ok(not status("Late").fresh)
    loader.on_held = nil
    put_mod("Asked", { ["init.lua"] = "return {}" })
    write_index()
    look()
    t.eq(status("Asked").status, "disabled", "a look that was asked for outright holds what it finds too")
    t.ok(status("Asked").fresh)
    loader.set_enabled("Asked", true)
    look()
    t.eq(status("Asked").status, "loaded")
end)

t.test("the console's environment reaches every mod, keeps what is defined in it, and blocks what mods are blocked from", function()
    put_mod("Reach", { ["init.lua"] = "counter = 3\nreturn { value = 9 }" })
    write_index()
    sync()
    local env = loader.console_env()
    t.eq(env.mods.Reach.counter, 3, "mods.<Id> is that mod's globals")
    env.mods.Reach.counter = 4
    t.eq(loader.get("Reach").env.counter, 4)
    t.eq(env.exports.Reach.value, 9, "exports.<Id> is what its init.lua returned")
    t.eq(env.mods.Nobody, nil)
    load("kept = 12", "=console", "t", env)()
    t.eq(load("return kept", "=console", "t", env)(), 12, "a name defined by one command is there for the next")
    t.eq(rawget(_G, "kept"), nil, "without leaking into the real globals")
    local listed = {}
    for id in pairs(env.mods) do listed[id] = true end
    t.ok(listed.Reach, "the loaded mods can be listed (for completing a name)")
    t.ok(not pcall(env.LoopAsync), "off-thread functions are refused here too")
    t.ok(not pcall(env.require, "x"))
end)

t.test("mod.<file> and mod.<folder>.<file> stand for the mod's files, and require takes them", function()
    put_mod("Tidy", {
        ["init.lua"] = [[
local Utils = require(mod.Utils)
local Deep = require(mod.extras.Deep)
local Pack = require(mod.pack)
return { sum = Utils.add(2, 3), deep = Deep, pack = Pack, same = require("extras.Deep") == Deep,
         shown = tostring(mod.extras.Deep), id = mod.id, missing = mod.Nothing }
]],
        ["Utils.lua"] = "local Utils = {}\nfunction Utils.add(a, b) return a + b end\nreturn Utils",
        ["extras/Deep.lua"] = "return 'deep'",
        ["pack/init.lua"] = "return 'a folder with an init.lua'",
    })
    write_index()
    sync()
    t.eq(status("Tidy").status, "loaded", tostring(status("Tidy").error))
    local exports = loader.get("Tidy").exports
    t.eq(exports.sum, 5)
    t.eq(exports.deep, "deep")
    t.eq(exports.pack, "a folder with an init.lua")
    t.eq(exports.same, true, "the name and the field are the same file, loaded once")
    t.eq(exports.shown, "Tidy/extras/Deep")
    t.eq(exports.id, "Tidy", "what the mod knows about itself is still there")
    t.eq(exports.missing, nil)

    put_mod("Tidy", { ["init.lua"] = "return require(mod.extras.Nope)", ["extras/Deep.lua"] = "return 1" })
    write_index()
    sync()
    loader.reload("Tidy")
    t.ok(status("Tidy").error:find("Tidy has no file or folder 'Nope' in extras", 1, true), tostring(status("Tidy").error))
    put_mod("Tidy", { ["init.lua"] = "return require(mod.Nothing)" })
    loader.reload("Tidy")
    t.ok(status("Tidy").error:find("require expects a file of this mod", 1, true), tostring(status("Tidy").error))
    put_mod("Tidy", { ["init.lua"] = "return 1" })
    loader.reload("Tidy")
end)

t.test("a save that does not compile leaves the running mod alone until one does", function()
    guard.clear_errors()
    put_mod("Steady", { ["init.lua"] = "shared.steady = (shared.steady or 0) + 1" })
    write_index()
    sync()
    t.eq(status("Steady").status, "loaded")
    local generation = status("Steady").generation
    put_mod("Steady", { ["init.lua"] = "local window = { width = " })
    loader.request_reload("Steady")
    frame()
    t.eq(status("Steady").status, "loaded", "the mod keeps running")
    t.eq(status("Steady").generation, generation, "and was not loaded again")
    t.ok(status("Steady").waiting:find("Steady/init.lua:1:", 1, true), status("Steady").waiting)
    for _, record in ipairs(guard.errors()) do t.ok(record.channel ~= "Steady", "it is not counted as an error: " .. record.message) end
    t.ok(logged("Steady was not reloaded"))
    put_mod("Steady", { ["init.lua"] = "shared.steady = (shared.steady or 0) + 1" })
    loader.request_reload("Steady")
    frame()
    t.eq(status("Steady").generation, generation + 1, "the next save that compiles is loaded")
    t.eq(status("Steady").waiting, nil)
end)

t.test("a mod's errors are forgotten once it loads cleanly again", function()
    guard.clear_errors()
    put_mod("Typo", { ["init.lua"] = "local x = " })
    write_index()
    sync()
    t.eq(status("Typo").status, "failed")
    local function mine()
        local n = 0
        for _, record in ipairs(guard.errors()) do
            if record.channel == "Typo" then n = n + 1 end
        end
        return n
    end
    t.eq(mine(), 1, "the half-typed file is an error")
    put_mod("Typo", { ["init.lua"] = "local x = 1" })
    write_index()
    loader.reload("Typo")
    t.eq(status("Typo").status, "loaded")
    t.eq(mine(), 0, "and no longer one after the fixed file loaded")
end)

t.test("mods can be put in another order, which is kept, and one can be removed without erasing it", function()
    put_mod("Zeta", { ["init.lua"] = "return {}" })
    put_mod("Alpha", { ["init.lua"] = "return {}" })
    sync()
    local function ids()
        local out = {}
        for _, mod in ipairs(loader.list()) do
            if mod.id == "Zeta" or mod.id == "Alpha" then out[#out + 1] = mod.id end
        end
        return table.concat(out, ",")
    end
    t.eq(ids(), "Alpha,Zeta", "the alphabet, until the user says otherwise")
    local at
    for index, mod in ipairs(loader.list()) do
        if mod.id == "Zeta" then at = index end
    end
    while at > 1 do
        t.ok(loader.move("Zeta", -1))
        at = at - 1
    end
    t.eq(loader.list()[1].id, "Zeta")
    t.eq(loader.move("Zeta", -1), false, "it is at the top already")
    sync()
    t.eq(loader.list()[1].id, "Zeta", "the order survives another look at the folder")

    local kept, problem = loader.remove("Zeta")
    t.ok(kept, tostring(problem))
    t.ok(kept:find("^%.removed%-Zeta%-"), kept)
    t.eq(loader.get("Zeta"), nil)
    local moved = io.open(scratch .. "/" .. kept .. "/init.lua", "rb")
    t.ok(moved, "the files are still there under the new name")
    moved:close()
    t.eq((loader.remove("Nobody")), nil)
    known.Zeta = nil
    write_index()
    frame()
end)

t.test("what a look at the mods folder has to say is logged once, not at every look", function()
    local function said()
        local count = 0
        for _, entry in ipairs(log.since(0)) do
            if entry.message:find("mods folder", 1, true) or entry.message:find("skipped mods/", 1, true) then count = count + 1 end
        end
        return count
    end
    sync()
    local before = said()
    sync()
    sync()
    t.eq(said(), before)
end)

-- Writes an index by hand: each entry as Lua text.
local function index_of(entries)
    write(root .. "/run/mods.index.lua", "return { mods = {\n" .. table.concat(entries, ",\n") .. "\n} }")
end

t.test("every entry of the index is checked: its id, its folder, the names of its files", function()
    mkdir(scratch .. "/Good")
    write(scratch .. "/Good/init.lua", "shared.good_ran = true return {}")
    mkdir(scratch .. "/Wrong")
    write(scratch .. "/Wrong/init.lua", "shared.wrong_ran = true return {}")
    mkdir(scratch .. "/My Mod")
    write(scratch .. "/My Mod/init.lua", "shared.wrong_ran = true return {}")
    local function entry(id, dir, files)
        return ("  { id = %q, dir = %q, files = { %s } }"):format(id, dir, files or '"init.lua"')
    end
    local bad = {
        entry("My Mod", scratch .. "/My Mod"),                              -- an id with a space
        entry("../Wrong", scratch .. "/Wrong"),                             -- an id that is a path
        entry(("W"):rep(65), scratch .. "/" .. ("W"):rep(65)),              -- an id that is too long
        entry("Wrong", "Wrong"),                                            -- a folder that is not a full path
        entry("Wrong", "//server/share/Wrong"),                             -- a folder on another machine
        entry("Wrong", scratch .. "/Good/../Wrong"),                        -- a folder reached through ..
        entry("Wrong", scratch .. "/Good"),                                 -- a folder named after another mod
        entry("Wrong", scratch .. "/Missing/Wrong"),                        -- a folder that is not there
        entry("Wrong", scratch .. "/Wrong", '"init.lua", "../Good/init.lua"'),
        entry("Wrong", scratch .. "/Wrong", '"init.lua", "C:/Windows/win.ini"'),
        entry("Wrong", scratch .. "/Wrong", '"init.lua", "sub\\\\file.lua"'),
        entry("Wrong", scratch .. "/Wrong", '"init.lua", "/file.lua"'),
        entry("Wrong", scratch .. "/Wrong", '"init.lua", 5'),
        entry("Wrong", scratch .. "/Wrong", '"other.lua"'),                 -- no init.lua
        '  { id = "Wrong", dir = 5, files = { "init.lua" } }',
        '  { id = "Wrong", dir = ' .. ("%q"):format(scratch .. "/Wrong") .. ' }',
        '  "Wrong"',
    }
    for position, text in ipairs(bad) do
        index_of({ text, entry("Good", scratch .. "/Good") })
        shared.good_ran, shared.wrong_ran = nil, nil
        loader.unload_all()
        local summary = sync()
        t.eq(#summary.mods, 1, "entry " .. position .. " was let in: " .. text)
        t.eq(status("Good").status, "loaded", "the good entry beside bad entry " .. position)
        t.eq(shared.wrong_ran, nil, "entry " .. position)
        t.ok(logged("skipped entry 1 of run/mods.index.lua"), "entry " .. position)
    end
    t.ok(logged("skipped entry 1 of run/mods.index.lua: its id may only use letters, digits, _ and -"))
    t.ok(logged("skipped entry 1 of run/mods.index.lua: its folder is not a full path on a drive"))
    t.ok(logged("skipped entry 1 of run/mods.index.lua: its folder is not a plain path"))
    t.ok(logged("skipped entry 1 of run/mods.index.lua: its folder is not named after the mod"))
    t.ok(logged("skipped entry 1 of run/mods.index.lua: its folder is not there"))
    t.ok(logged("skipped entry 1 of run/mods.index.lua: it lists a file that is not inside its folder"))
    t.ok(logged("skipped entry 1 of run/mods.index.lua: it has no init.lua"))
    -- an index that is not a list of mods is left alone as a whole
    write(root .. "/run/mods.index.lua", "return 5")
    t.eq(#sync().mods, 0)
    t.ok(logged("run/mods.index.lua could not be read and was ignored"))
    index_of({ entry("Good", scratch .. "/Good") })
    t.eq(#sync().mods, 1)
end)

t.test("without developer mode the index is not read, and the mods it listed are gone until it is back", function()
    known = { Reach = known.Reach }
    write_index()
    sync()
    t.eq(status("Reach").status, "loaded")
    os.remove(root .. "/dev.txt")
    t.eq(#look().mods, 0, "no dev.txt beside Scripts, no index")
    t.eq(loader.get("Reach"), nil)
    write(root .. "/dev.txt", "")
    look()
    t.eq(status("Reach").status, "loaded", "a mod the player had seen is back as it was")
end)

t.test("mod.OnUnload runs before the mod's things go, newest first, with why, and one that fails stops nothing", function()
    shared.bye, shared.heard = {}, 0
    put_mod("Bye", { ["init.lua"] = [[
        shared.signal:Connect(function() shared.heard = shared.heard + 1 end)
        local never = mod.OnUnload(function() shared.bye[#shared.bye + 1] = "never" end)
        mod.OnUnload(function(why)
            shared.signal:Fire()
            shared.bye[#shared.bye + 1] = "first " .. why
        end)
        mod.OnUnload(function() error("boom on the way out") end)
        mod.OnUnload(function(why) shared.bye[#shared.bye + 1] = "last " .. why end)
        never()
        shared.wrong = select(2, pcall(mod.OnUnload, 5))
    ]] })
    write_index()
    sync()
    t.eq(status("Bye").status, "loaded")
    t.ok(tostring(shared.wrong):find("mod.OnUnload expects a function, got number", 1, true), tostring(shared.wrong))
    t.eq(#shared.bye, 0, "nothing runs while the mod is loaded")

    t.ok(loader.reload("Bye"))
    t.eq(table.concat(shared.bye, ", "), "last reload, first reload")
    t.eq(shared.heard, 1, "the mod's own connection was still there when its function ran")
    t.ok(logged("boom on the way out"), "the one that failed is reported")
    shared.bye = {}
    loader.set_enabled("Bye", false)
    look()
    t.eq(table.concat(shared.bye, ", "), "last off, first off")
    shared.bye = {}
    look()
    t.eq(#shared.bye, 0, "and they run once")

    put_mod("Half", { ["init.lua"] = [[
        mod.OnUnload(function(why) shared.bye[#shared.bye + 1] = "half " .. why end)
        error("half way")
    ]] })
    write_index()
    sync()
    t.eq(status("Half").status, "failed")
    t.eq(table.concat(shared.bye, ", "), "half failed", "what a mod set up before it failed to load is taken back too")
    loader.set_enabled("Half", false)
    look()
end)

t.test("unload_all leaves no connections or tasks behind", function()
    loader.unload_all()
    t.eq(signal.count, 0)
    shared.ticks = 0
    frame()
    t.eq(shared.ticks, 0)
    t.eq(#loader.list(), 0)
    t.eq(scope.current(), nil)
end)

t.finish("mods")
