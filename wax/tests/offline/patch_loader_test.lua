-- Offline tests for data.patch with the real mod loader: the order of layers, reloads, a mod that is put in later, a moved mod.
-- The mods are in folders of their own and reach the loader through the index, as in mods_test.lua.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\patch_loader_test.lua <empty scratch dir>

local t = dofile("wax/tests/offline/harness.lua")
local scratch = assert(arg[1], "usage: patch_loader_test.lua <empty scratch dir>"):gsub("\\", "/")
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
write(root .. "/dev.txt", "")
function IterateGameDirectories()
    return { Game = { Binaries = { Win64 = { ue4ss = { Mods = { Wax = { mods = { __files = {} } } } } } } } }
end

local fake = dofile("wax/tests/offline/fake_tables.lua")
fake.sample()
local S, U = "/Script/Icarus.", "/Script/IcarusUtilities."
fake.struct(S .. "CraftRow", U .. "IcarusTableRowBase", { { "Count", "IntProperty" }, { "Note", "StrProperty" } })
fake.table("Crafts", S .. "CraftRow", {
    Chair = { Count = 2, Note = "four legs" }, Table = { Count = 4, Note = "flat" }, Stool = { Count = 1, Note = "small" },
}, { "Chair", "Table", "Stool" })
fake.install()
fake.allow_writes(true)

local Wax = t.new_wax()
Wax.root = root
rawset(_G, "Wax", Wax)
local sched = Wax.import("core.sched")
local guard = Wax.import("core.guard")
local game = Wax.import("engine.game")
local data = Wax.import("data.tables")
local journal = Wax.import("data.journal")
journal.clear()
local loader = Wax.import("mods.loader")
rawset(Wax, "mods", loader)
loader.provide("game", game.root)

local now = 100
sched.clock = function() return now end
data.clock = function() return now end
data.start()
local patch = Wax.import("data.patch")
patch.clock = function() return now end
patch.start()
local Data = game.root.Data

local function frame()
    now = now + 0.016
    fake.next_frame()
    loader.step()
    sched.step()
end
local function frames(count) for _ = 1, count do frame() end end
local function row(name) return fake.row("Crafts", name) end

local known = {}

local function put_mod(id, files)
    mkdir(scratch .. "/" .. id)
    local names = {}
    for name, text in pairs(files) do
        write(scratch .. "/" .. id .. "/" .. name, text)
        names[#names + 1] = name
    end
    table.sort(names)
    known[id] = names
    local lines, ids = { "return { mods = {" }, {}
    for other in pairs(known) do ids[#ids + 1] = other end
    table.sort(ids)
    for _, other in ipairs(ids) do
        local quoted = {}
        for index, name in ipairs(known[other]) do quoted[index] = ("%q"):format(name) end
        lines[#lines + 1] = ("  { id = %q, dir = %q, files = { %s } },"):format(other, scratch .. "/" .. other, table.concat(quoted, ", "))
    end
    lines[#lines + 1] = "} }"
    write(root .. "/run/mods.index.lua", table.concat(lines, "\n"))
end

-- Looks at the folders and switches on what is new, as the player does in the Mods page.
local function sync()
    loader.sync()
    local any = false
    for _, entry in ipairs(loader.list()) do
        if entry.fresh then
            loader.set_enabled(entry.id, true)
            any = true
        end
    end
    if any then loader.sync() end
end

local function ids()
    local out = {}
    for index, entry in ipairs(loader.list()) do out[index] = entry.id end
    return table.concat(out, ",")
end

local function change(row_name, field)
    for _, entry in ipairs(Data:Changes()) do
        if entry.Row == row_name and entry.Field == field then return entry end
    end
end

-- names that sort the other way than the ids, so an order taken by name would show
local ALPHA = [[
    local crafts = game.Data:Table("Crafts")
    crafts:Set("Table", "Count", 41)
    crafts:Set("Chair", "Note", "alpha")
]]
local BETA = [[
    local crafts = game.Data:Table("Crafts")
    crafts:Set("Table", "Count", 60)
]]

t.test("layers stand in the order the loader loads the mods in, also for a mod that is put in later", function()
    put_mod("Beta", { ["mod.lua"] = 'return { name = "Able", version = "1.0.0" }', ["init.lua"] = BETA })
    sync()
    frame()
    t.eq(row("Table").Count, 60)
    -- Alpha is put in while Beta runs. It loads before Beta from now on, so its change goes below Beta's
    put_mod("Alpha", { ["mod.lua"] = 'return { name = "Zulu", version = "1.0.0" }', ["init.lua"] = ALPHA })
    sync()
    frame()
    t.eq(ids(), "Alpha,Beta", "the loader's order, by id")
    t.eq(table.concat(patch.order(), ","), ids(), "and the order data.patch works out is the same")
    t.eq(row("Table").Count, 60, "Beta loads later, so its value stands")
    t.eq(row("Chair").Note, "alpha")
    local found = change("Table", "Count")
    t.eq(found.By, "Beta")
    t.eq(table.concat(found.Others, ","), "Alpha")
end)

t.test("the mod that loads earlier stands below, also when it is the one that was switched on last", function()
    loader.set_enabled("Alpha", false)
    loader.set_enabled("Beta", false)
    frames(2)
    t.eq(row("Table").Count, 4, "both off")
    loader.set_enabled("Beta", true)
    frames(2)
    loader.set_enabled("Alpha", true)
    frames(2)
    t.eq(row("Table").Count, 60)
    t.eq(change("Table", "Count").By, "Beta")
    t.eq(table.concat(change("Table", "Count").Others, ","), "Alpha")
end)

t.test("a reload through the loader writes nothing and reads nothing", function()
    local writes, reads = fake.writes, patch.stats().reads
    loader.request_reload("Alpha")
    frames(3)
    t.eq(fake.writes, writes)
    t.eq(patch.stats().reads, reads)
    t.eq(row("Table").Count, 60)
    t.eq(row("Chair").Note, "alpha")
end)

t.test("a mod that makes its changes from a task, after a wait, keeps them through a reload", function()
    put_mod("Gamma", { ["init.lua"] = [[
        local crafts = game.Data:Table("Crafts")
        task.spawn(function()
            task.wait(0.03)
            crafts:Set("Stool", "Count", 9)
        end)
    ]] })
    sync()
    frames(5)
    t.eq(row("Stool").Count, 9)
    local writes, heard = fake.writes, 0
    local connection = Data.Changed:Connect(function() heard = heard + 1 end)
    loader.request_reload("Gamma")
    for _ = 1, 8 do
        frame()
        t.eq(row("Stool").Count, 9, "the game's own value never shows in between")
    end
    t.eq(fake.writes, writes, "not one write")
    t.eq(heard, 0, "and nobody is told of a change")
    now = now + 3
    frames(3)
    t.eq(row("Stool").Count, 9, "after the moment it had to say so again")
    t.eq(patch.stats().pending, 0)
    connection:Disconnect()
end)

t.test("when the player moves a mod in the list, the fields two mods changed follow the new order", function()
    t.eq(loader.move("Beta", -1), true)
    t.eq(ids():sub(1, 10), "Beta,Alpha")
    -- a file save of each mod: both say their changes again, now in the other order
    loader.request_reload("Alpha")
    loader.request_reload("Beta")
    frames(3)
    t.eq(row("Table").Count, 41, "Alpha loads later now")
    t.eq(change("Table", "Count").By, "Alpha")
    t.eq(table.concat(change("Table", "Count").Others, ","), "Beta")
    -- the loader can tell data.patch of a move, and then it shows in that frame with no reload
    t.eq(loader.move("Beta", 1), true)
    patch.reordered()
    frame()
    t.eq(row("Table").Count, 60)
    t.eq(change("Table", "Count").By, "Beta")
end)

t.test("a mod that is switched off is put back in the next frame, and nothing is left when all are off", function()
    loader.set_enabled("Beta", false)
    frames(2)
    t.eq(row("Table").Count, 41)
    loader.set_enabled("Alpha", false)
    loader.set_enabled("Gamma", false)
    frames(2)
    t.eq(row("Table").Count, 4)
    t.eq(row("Chair").Note, "four legs")
    t.eq(row("Stool").Count, 1)
    t.eq(#Data:Changes(), 0)
    t.eq(journal.stats().entries, 0)
    t.eq(#guard.errors(), 0)
    for _, name in ipairs({ "crashes", "misuse", "sloppy", "silent", "grown", "stale", "leaks" }) do t.eq(fake[name], 0, name) end
end)

t.finish("patch-loader")
