-- Offline tests for mods.zip: inflate against streams made by zlib, and reading entries of stored and deflated zips.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\zip_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local Wax = t.new_wax()
rawset(_G, "Wax", Wax)
local zip = Wax.import("mods.zip")

local FIX = "wax/tests/offline/fixtures/"

local function read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("a")
    file:close()
    return text
end

t.test("a deflated stream with dynamic blocks inflates to the original", function()
    local plain = read(FIX .. "inflate.txt")
    local pauses = 0
    local out = zip.inflate(read(FIX .. "inflate.bin"), nil, function() pauses = pauses + 1 end)
    t.eq(#out, #plain)
    t.ok(out == plain, "the bytes are the same")
    t.ok(pauses >= 1, "a long stream pauses on the way")
end)

t.test("a stream of stored blocks inflates", function()
    local plain = read(FIX .. "inflate.txt"):sub(1, 5000)
    t.ok(zip.inflate(read(FIX .. "inflate-stored.bin")) == plain, "stored blocks")
end)

t.test("a damaged stream and an output limit are errors, not crashes", function()
    t.raises(function() zip.inflate("\255\255\255") end, "bad deflate stream")
    t.raises(function() zip.inflate(read(FIX .. "inflate.bin"), 1000) end, "unpacks to more than 1000 bytes")
    t.raises(function() zip.entries("not a zip at all") end, "not a zip file")
end)

t.test("a deflated zip lists its entries and reads them", function()
    local data = read(FIX .. "Sample.EXMODZ")
    local entries = zip.entries(data)
    t.eq(#entries, 3)
    local by_name = {}
    for _, entry in ipairs(entries) do by_name[entry.name] = entry end
    local exmod = by_name["Extracted Mods/Sample.EXMOD"]
    t.ok(exmod, "the EXMOD is listed")
    t.eq(exmod.method, 8)
    local text = zip.read(data, exmod)
    t.eq(#text, exmod.size)
    t.ok(text:find('"name": "Sample Stacks"', 1, true), "the EXMOD reads back")
    local asset = zip.read(data, by_name["Sample/Content/BP/Thing.uasset"])
    t.eq(#asset, 300)
    t.raises(function() zip.read(data, exmod, 10) end, "larger than 10 bytes")
end)

t.test("a stored zip reads without inflating", function()
    local data = read(FIX .. "Stored.EXMODZ")
    local entries = zip.entries(data)
    t.eq(#entries, 1)
    t.eq(entries[1].method, 0)
    t.ok(zip.read(data, entries[1]):find('"fileName": "Sample"', 1, true), "stored entry")
end)

t.finish()
