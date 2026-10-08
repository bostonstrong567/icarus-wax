-- The pak check: tools\lua\lua54\lua.exe wax\tests\offline\content_test.lua [scratch folder]
local t = dofile("wax/tests/offline/harness.lua")
local pakfile = assert(loadfile("wax/runtime/Scripts/wax/mods/pakfile.lua"))()

local SAMPLE = "wax/tests/offline/fixtures/Sample.pak"
local COMPRESSED = "wax/tests/offline/fixtures/Compressed.pak"
local MOUNT = "../../../Icarus/Content/Mods/WaxSample/"
local scratch = (arg and arg[1]) or os.getenv("TEMP") or "."

local function bytes_of(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("a")
    file:close()
    return data
end

local function written(name, data)
    local path = scratch .. "/" .. name
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
    return path
end

local function hex(text) return (text:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end

local good = bytes_of(SAMPLE)
local TRAILER = 221
local index_offset, index_size = ("<I8I8"):unpack(good, #good - TRAILER + 1 + 25)

t.test("sha1 gives the known answers", function()
    t.eq(hex(pakfile.sha1("")), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    t.eq(hex(pakfile.sha1("abc")), "a9993e364706816aba3e25717850c26c9cd0d89d")
    t.eq(hex(pakfile.sha1(("a"):rep(1000))), "291e9a6c66994949b57ba5e650361e98fc36b1ba")
end)

t.test("a pak packed for the mod passes and lists its files", function()
    local info, why = pakfile.check(SAMPLE, MOUNT)
    t.ok(info, why)
    t.eq(info.mount_point, MOUNT)
    t.eq(#info.files, 4)
    t.eq(info.files[1], "BP_WaxSampleActor.uasset")
    t.eq(info.size, #good)
    t.eq(#info.mark, 12)
end)

t.test("the mark follows the content", function()
    local first = pakfile.check(SAMPLE, MOUNT)
    local again = pakfile.check(written("content_same.pak", good), MOUNT)
    t.eq(again.mark, first.mark)
    local at = 200
    local other = good:sub(1, at - 1) .. string.char((good:byte(at) + 1) % 256) .. good:sub(at + 1)
    local changed = pakfile.check(written("content_data.pak", other), MOUNT)
    t.ok(changed, "a change in the data leaves the index as it was")
    t.ok(changed.mark ~= first.mark, "and gives another mark")
end)

t.test("another mod's mount point is refused", function()
    local info, why = pakfile.check(SAMPLE, "../../../Icarus/Content/Mods/Other/")
    t.eq(info, nil)
    t.ok(why:find("mount point", 1, true), why)
end)

t.test("a compressed pak is refused", function()
    local info, why = pakfile.check(COMPRESSED)
    t.eq(info, nil)
    t.ok(why:find("compress", 1, true), why)
end)

t.test("damage is refused before the game sees it", function()
    local function refused(name, data, fragment)
        local info, why = pakfile.check(written(name, data), MOUNT)
        t.eq(info, nil, name)
        t.ok(why and why:find(fragment, 1, true), name .. ": " .. tostring(why))
    end
    refused("content_short.pak", good:sub(1, 100), "too short")
    refused("content_text.pak", ("x"):rep(4000), "not a version 11 pak")
    local at = index_offset + 10
    refused("content_index.pak", good:sub(1, at) .. string.char((good:byte(at + 1) + 1) % 256) .. good:sub(at + 2), "checksum")
    local trailer = #good - TRAILER
    refused("content_key.pak", good:sub(1, trailer + 16) .. "\1" .. good:sub(trailer + 18), "encrypted")
    refused("content_version.pak", good:sub(1, trailer + 21) .. ("<i4"):pack(9) .. good:sub(trailer + 26), "version")
    refused("content_far.pak", good:sub(1, trailer + 25) .. ("<I8"):pack(#good * 2) .. good:sub(trailer + 34), "outside")
    t.ok(index_size > 0)
end)

t.test("a file that is not there is refused", function()
    local info, why = pakfile.check(scratch .. "/no_such_file.pak", MOUNT)
    t.eq(info, nil)
    t.ok(why:find("cannot be opened", 1, true), why)
end)

t.finish()
