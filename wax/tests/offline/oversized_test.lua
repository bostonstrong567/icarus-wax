-- Offline tests for the guard on calls whose parameters do not fit UE4SS's 512-byte call buffer (engine.reflect,
-- engine.instance), and for the list it goes by (wax\runtime\data\oversized_functions.lua).
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\oversized_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local world = dofile("wax/tests/offline/fake_world.lua")
world.install()
local values = dofile("wax/tests/offline/fake_values.lua")
values.install(world)

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)
local reflect = Wax.import("engine.reflect")
local instance = Wax.import("engine.instance")

local STYLE, PIN = "/Script/SlateCore.TextBlockStyle", "/Script/Icarus.WaxTestPin"
values.struct(STYLE, nil, { { "Size", "IntProperty" } })
values.struct(PIN, nil, { { "Id", "IntProperty" } })

local reached = {}
local function counted(name)
    return function() reached[name] = (reached[name] or 0) + 1 end
end

-- Paths as the list has them; UPGRADE is on the list Wax has shipped since its first release.
local UPGRADE = "/Game/BP/Behaviours/Actionable/BP_ActionableBehaviour_BuildingUpgrade.BP_ActionableBehaviour_BuildingUpgrade_C"
local object_class = world.class("/Script/CoreUObject.Object")
local actor_class = values.class("/Script/Engine.Actor", object_class)
local text_class = values.class("/Script/UMG.RichTextBlock", actor_class, {}, {
    SetDefaultTextStyle = { { "InDefaultTextStyle", "StructProperty", struct = STYLE }, call = counted("style") },
    SetAutoWrapText = { { "InAutoTextWrap", "BoolProperty" }, call = counted("wrap") },
})
local library_class = values.class("/Game/BP/UI/BP_UMGFunctionLibrary.BP_UMGFunctionLibrary_C", actor_class, {}, {
    ["Get Prospect Pin State Data"] = { { "Pin", "StructProperty", struct = PIN }, call = counted("pin") },
})
local upgrade_class = values.class(UPGRADE, actor_class, {}, {
    GetContextMenuItems = { { "Count", "IntProperty" }, call = counted("menu") },
})
-- The same class as a running game can spell it: the class in another letter case, the function with a space at its end.
local respelled_class = values.class((UPGRADE:gsub("BuildingUpgrade_C$", "buildingupgrade_c")), actor_class, {}, {
    getcontextmenuitems = { { "Count", "IntProperty" }, call = counted("lower") },
    ["GetContextMenuItems "] = { { "Count", "IntProperty" }, call = counted("spaced") },
})

local serial = 0
local function made(class)
    serial = serial + 1
    return instance.wrap((values.actor(class, "Thing_" .. serial, { Location = { 0, 0, 0 } })))
end

local function folded(path) return (path:lower():gsub("%s+$", "")) end

t.test("a call whose parameters take more than 512 bytes is refused before the engine is reached", function()
    local text = made(text_class)
    local err = t.raises(function() text:SetDefaultTextStyle({}) end, "SetDefaultTextStyle cannot be called from Lua")
    t.ok(tostring(err):find("624 bytes", 1, true), "the message gives the size: " .. tostring(err))
    t.ok(tostring(err):find("512", 1, true), "and the room there is: " .. tostring(err))
    t.raises(function() text:Call("SetDefaultTextStyle", { Size = 3 }) end, "cannot be called from Lua")
    t.eq(reached.style, nil, "the engine was never called")
    t.eq(values.crashes, 0)
end)

t.test("a function whose name holds spaces is refused the same way", function()
    local library = made(library_class)
    local err = t.raises(function() library:Call("Get Prospect Pin State Data", {}) end, "cannot be called from Lua")
    t.ok(tostring(err):find("760 bytes", 1, true), tostring(err))
    t.eq(reached.pin, nil)
end)

t.test("a function that is not on the list is called", function()
    local text = made(text_class)
    text:SetAutoWrapText(true)
    t.eq(reached.wrap, 1)
    t.eq(reflect.oversized(reflect.class_info(text_class).members.SetAutoWrapText), nil)
end)

t.test("a listed function is refused as the list spells it", function()
    local upgrade = made(upgrade_class)
    local err = t.raises(function() upgrade:GetContextMenuItems(1) end, "GetContextMenuItems cannot be called from Lua")
    t.ok(tostring(err):find("14880 bytes", 1, true), tostring(err))
    t.eq(reached.menu, nil)
end)

t.test("a listed function is refused when the running game spells it in another letter case", function()
    local upgrade = made(respelled_class)
    t.raises(function() upgrade:getcontextmenuitems(1) end, "cannot be called from Lua")
    t.eq(reached.lower, nil, "the list is spelled as the game's files spell names, the running game as it first met them")
end)

t.test("a listed function is refused when the running game's name for it ends in a space", function()
    local upgrade = made(respelled_class)
    t.raises(function() upgrade:Call("GetContextMenuItems ", 1) end, "cannot be called from Lua")
    t.eq(reached.spaced, nil)
end)

t.test("the answer is kept on the member and asked of the list once", function()
    local member = reflect.class_info(upgrade_class).members.GetContextMenuItems
    t.eq(reflect.oversized(member), 14880)
    t.eq(member.oversized, 14880)
    local plain = reflect.class_info(text_class).members.SetAutoWrapText
    t.eq(reflect.oversized(plain), nil)
    t.eq(plain.oversized, false)
end)

t.test("the list holds sizes over the limit, and no path twice in another spelling", function()
    local list = assert(loadfile(Wax.root .. "/data/oversized_functions.lua"))()
    local count, seen = 0, {}
    for path, size in pairs(list) do
        count = count + 1
        -- a function of a class, or a delegate's signature that belongs to a package
        t.ok(type(path) == "string" and path:find("^/[^%.]+%..+"), "a key is a function's path: " .. tostring(path))
        t.ok(math.type(size) == "integer" and size > 512, path .. " is listed with " .. tostring(size))
        local key = folded(path)
        t.ok(not seen[key], path .. " is listed twice: " .. tostring(seen[key]))
        seen[key] = path
    end
    t.ok(count > 1600, "the list holds " .. count .. " functions")
    -- three of the functions over 512 bytes that the list of the first releases let through
    for _, path in ipairs({ "/Script/UMG.RichTextBlock:SetDefaultTextStyle", "/Script/UMG.MultiLineEditableText:SetWidgetStyle",
        "/Game/BP/MiscConstructs/IcarusFunctionLibrary.IcarusFunctionLibrary_C:Get Custom Item Icon" }) do
        t.ok(seen[folded(path)], path .. " takes more than 512 bytes and is not on the list")
    end
end)

t.finish("oversized")
