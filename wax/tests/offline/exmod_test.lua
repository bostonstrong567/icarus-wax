-- Offline tests for EXMOD mods: discovery of folders and loose files, the applier on the stand-in tables, and the listing of other mods.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\exmod_test.lua <scratch folder>

local t = dofile("wax/tests/offline/harness.lua")
local fake = dofile("wax/tests/offline/fake_tables.lua")
fake.sample()
local S, U = "/Script/Icarus.", "/Script/IcarusUtilities."
fake.struct(S .. "StackRow", U .. "IcarusTableRowBase", {
    { "MaxStack", "IntProperty" }, { "Weight", "FloatProperty" }, { "Kind", "StrProperty" },
})
fake.table("Stacks", S .. "StackRow", {
    Wood = { MaxStack = 100, Weight = 5, Kind = "resource" },
    Stone = { MaxStack = 50, Weight = 10, Kind = "resource" },
}, { "Wood", "Stone" })
fake.install()
fake.allow_writes(true)

local root = (arg and arg[1] or "build/_exmod-test"):gsub("\\", "/")
local function mkdir(path) os.execute('mkdir "' .. path:gsub("/", "\\") .. '" >nul 2>nul') end
local function write(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
end
local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("a")
    file:close()
    return text
end
local function absolute(path)
    if path:match("^%a:/") then return path end
    local here = io.popen("cd"):read("l"):gsub("\\", "/")
    return here .. "/" .. path
end

-- a pretend game folder: <root>/Icarus/Binaries/Win64/ue4ss/Mods/{Wax/mods, Other, BPModLoaderMod}, <root>/Icarus/Content/Paks/{mods,LogicMods}
root = absolute(root)
local game = root .. "/Icarus"
local mods_dir = game .. "/Binaries/Win64/ue4ss/Mods"
local wax_root = mods_dir .. "/Wax"
for _, dir in ipairs({ game, game .. "/Binaries", game .. "/Binaries/Win64", game .. "/Binaries/Win64/ue4ss", mods_dir, wax_root, wax_root .. "/mods",
                       wax_root .. "/mods/Folded", wax_root .. "/mods/Plain", mods_dir .. "/Other", mods_dir .. "/Other/Scripts", mods_dir .. "/BPModLoaderMod",
                       game .. "/Content", game .. "/Content/Paks", game .. "/Content/Paks/mods", game .. "/Content/Paks/LogicMods" }) do
    mkdir(dir)
end
local FIX = "wax/tests/offline/fixtures/"
write(wax_root .. "/mods/Folded/Folded.EXMODZ", read(FIX .. "Sample.EXMODZ"))
write(wax_root .. "/mods/Plain/init.lua", "return {}")
write(wax_root .. "/mods/Loose Stacks.EXMOD", read(FIX .. "Stored.EXMODZ"))   -- wrong on purpose: a zip under the .EXMOD name
write(wax_root .. "/mods/Good.EXMOD", '{ "name": "Good", "Rows": [ { "CurrentFile": "Traits-D_Stacks.json", "File_Items": [ { "Name": "wood", "MaxStack": 900 } ] } ] }')
write(wax_root .. "/mods/.removed-Old.EXMOD", "{}")
write(mods_dir .. "/Other/Scripts/main.lua", "print('hi')")
write(mods_dir .. "/mods.txt", "Other : 1\nBPModLoaderMod : 0\n")
write(game .. "/Content/Paks/mods/Bigger_P.pak", "x")
write(game .. "/Content/Paks/LogicMods/Thing.pak", "x")

-- UE4SS's directory listing, built from the pretend folder
local function node_of(path)
    local node = { __absolute_path = path:gsub("/", "\\"), __files = {} }
    local pipe = io.popen('cmd /c dir /b /a-d "' .. path:gsub("/", "\\") .. '" 2>nul')
    for line in pipe:lines() do
        line = line:gsub("\r", "")
        if line ~= "" then node.__files[#node.__files + 1] = { __name = line } end
    end
    pipe:close()
    pipe = io.popen('cmd /c dir /b /ad "' .. path:gsub("/", "\\") .. '" 2>nul')
    for line in pipe:lines() do
        line = line:gsub("\r", "")
        if line ~= "" then node[line] = node_of(path .. "/" .. line) end
    end
    pipe:close()
    return node
end
rawset(_G, "IterateGameDirectories", function() return { Game = node_of(game) } end)

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)
Wax.root = wax_root
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local game_root = Wax.import("engine.game")
local data = Wax.import("data.tables")
local journal = Wax.import("data.journal")
journal.clear()
local now = 100
sched.clock = function() return now end
data.clock = function() return now end
data.start()
local patch = Wax.import("data.patch")
patch.clock = function() return now end
rawset(Wax, "mods", { list = function() return { { id = "Folded", name = "Folded" } } end })
patch.start()

local discover = Wax.import("mods.discover")
local exmod = Wax.import("mods.exmod")
local foreign = Wax.import("mods.foreign")

local function frame()
    now = now + 0.016
    fake.next_frame()
    sched.step()
end

t.test("discovery lists a folder with an EXMODZ, a loose EXMOD file, and skips the rest", function()
    local found, notes = discover.all()
    local by_id = {}
    for _, entry in ipairs(found) do by_id[entry.id] = entry end
    t.eq(by_id.Folded and by_id.Folded.exmod, "Folded.EXMODZ")
    t.eq(by_id.Folded and by_id.Folded.bare, nil)
    t.ok(by_id.Plain and not by_id.Plain.exmod, "a Lua mod is still a Lua mod")
    t.eq(by_id.Good and by_id.Good.exmod, "Good.EXMOD")
    t.eq(by_id.Good and by_id.Good.bare, true)
    t.eq(by_id.Good and by_id.Good.dir, wax_root .. "/mods")
    t.eq(by_id.Loose_Stacks and by_id.Loose_Stacks.exmod, "Loose Stacks.EXMOD", "a space in the file name becomes _ in the id")
    t.eq(by_id[".removed-Old"], nil)
    t.eq(#notes, 0, table.concat(notes, "; "))
end)

t.test("an EXMODZ loads through the zip reader, with a note about game files it holds", function()
    local loaded, notes = exmod.load(wax_root .. "/mods/Folded/Folded.EXMODZ")
    t.eq(loaded.name, "Sample Stacks")
    t.eq(#loaded.Rows, 3)
    t.eq(#notes, 1)
    t.ok(notes[1]:find("1 game files", 1, true), notes[1])
    t.raises(function() exmod.load(wax_root .. "/mods/Loose Stacks.EXMOD") end, "not an EXMOD")
    t.raises(function() exmod.load(wax_root .. "/mods/missing.EXMOD") end, "cannot read")
end)

t.test("apply writes what it can and counts the rest", function()
    local loaded = exmod.load(wax_root .. "/mods/Folded/Folded.EXMODZ")
    local owner = scope.new("Folded")
    local counts, problems = scope.run(owner, function() return exmod.apply(loaded) end)
    t.eq(counts.done, 4, "Bone_Knife time, Wood stack and weight, Stone stack")
    t.eq(counts.nulls, 1)
    t.eq(counts.missing, 1)
    t.eq(counts.tables, 1)
    t.eq(counts.failed, 0)
    t.eq(fake.row("Stacks", "Wood").MaxStack, 400)
    t.eq(fake.row("Stacks", "Stone").MaxStack, 250)
    t.eq(fake.row("ProcessorRecipes", "Bone_Knife").RequiredMillijoules, 1234)
    t.ok(problems[1]:find("Item_NotThere", 1, true) or problems[2]:find("Item_NotThere", 1, true), "the missing row is named")
    local line = exmod.summary(counts, { "extra" })
    t.ok(line:find("4 values applied, 1 new row skipped, 1 cleared field skipped, 1 unknown table. extra", 1, true), line)
    owner:destroy()
    frame()
    t.eq(fake.row("Stacks", "Wood").MaxStack, 100, "destroying the scope puts the rows back")
end)

t.test("start fills the manifest and applies in a task; a row name is matched without case", function()
    local mod = { id = "Good", dir = wax_root .. "/mods", exmod = "Good.EXMOD", bare = true, manifest = { name = "Good" } }
    local owner = scope.new("Good")
    rawset(Wax, "mods", { list = function() return { { id = "Good", name = "Good" } } end })
    scope.run(owner, function() exmod.start(mod) end)
    t.eq(mod.note, "Applying the table changes...")
    for _ = 1, 3 do frame() end
    t.eq(mod.note, "1 value applied")
    t.eq(fake.row("Stacks", "Wood").MaxStack, 900)
    owner:destroy()
    frame()
end)

t.test("other mods: UE4SS mods beside Wax with their switch, pak mods and blueprint mods", function()
    local found = foreign.list(true)
    t.eq(found.listed, true)
    t.eq(#found.ue4ss, 1)
    t.eq(found.ue4ss[1].name, "Other")
    t.eq(found.ue4ss[1].enabled, true, "listed in mods.txt")
    t.eq(found.loader, "off")
    t.eq(table.concat(found.paks, ","), "Bigger_P.pak")
    t.eq(table.concat(found.logic, ","), "Thing.pak")
    t.ok(foreign.set_enabled("Other", true))
    local written = io.open(mods_dir .. "/Other/enabled.txt", "rb")
    t.ok(written, "enabled.txt was written")
    if written then written:close() end
    t.ok(foreign.set_enabled("Other", false))
    t.eq(io.open(mods_dir .. "/Other/enabled.txt", "rb"), nil)
    t.ok(foreign.set_enabled("Other", false), "removing twice is fine")
    local ok, why = foreign.set_enabled("Nope", true)
    t.eq(ok, false)
    t.ok(why:find("no UE4SS mod named Nope", 1, true), why)
    t.ok(foreign.signature():find("Other-", 1, true), foreign.signature())
end)

t.finish()
