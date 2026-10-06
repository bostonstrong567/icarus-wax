-- Live test of the game tree: runs wherever the game currently is (title screen or prospect) and reports
-- a list of named checks, each true/false with detail.
local game = Wax.game
local instance = Wax.instance
local checks = {}
local function check(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail } end
local function attempt(name, fn)
    local ok, a, b = pcall(fn)
    if ok then check(name, a, b) else check(name, false, "raised: " .. tostring(a)) end
end

attempt("game.World is an Instance of World", function()
    local world = game.World
    return world ~= nil and world:IsA("World") and world.ClassName == "World", tostring(world)
end)

attempt("the root objects exist", function()
    return game.GameInstance ~= nil and game.Engine ~= nil and game.LocalPlayer ~= nil and type(game.MapName) == "string",
        ("%s | %s | %s | map %s | inProspect %s"):format(tostring(game.GameInstance), tostring(game.Engine), tostring(game.LocalPlayer), game.MapName, tostring(game.InProspect))
end)

local world_children
attempt("World:GetChildren lists actors and every child's Parent is the world", function()
    local started = os.clock()
    world_children = game.World:GetChildren()
    local elapsed = (os.clock() - started) * 1000
    local wrong = 0
    for i = 1, math.min(#world_children, 200) do
        if world_children[i].Parent ~= game.World then wrong = wrong + 1 end
    end
    return #world_children > 0 and wrong == 0, ("%d top-level actors in %.0f ms, %d with a wrong Parent"):format(#world_children, elapsed, wrong)
end)

attempt("the level actor list passed its self-check (fast path in use)", function()
    local actors = game.World.Raw.PersistentLevel.WaxLevelActors
    return actors:type() == "TArray" and actors[1]:GetAddress() == game.World.Raw.PersistentLevel.WorldSettings:GetAddress(),
        actors:GetArrayNum() .. " actors in the persistent level"
end)

attempt("one Instance per object: wrapping twice gives the same Instance, and == works", function()
    local a, b = game.World, game.World
    return rawequal(a, b) and a == b and game.wrap(a.Raw) == a
end)

attempt("an actor's children are its components, each naming the actor (or a sibling) as Parent", function()
    local character = game.Character
    local actor = character or world_children[1]
    local children = actor:GetChildren()
    local bad, nested = 0, 0
    for _, child in ipairs(children) do
        if child.Parent ~= actor then bad = bad + 1 end
        nested = nested + #child:GetChildren()
    end
    return #children > 0 and bad == 0, ("%s has %d children (+%d nested), %d with a wrong Parent"):format(tostring(actor), #children, nested, bad)
end)

attempt("GetDescendants has no duplicates and respects its limit", function()
    local actor = game.Character or world_children[1]
    local all = actor:GetDescendants()
    local seen, duplicates = {}, 0
    for _, item in ipairs(all) do
        local key = item.FullName
        if seen[key] then duplicates = duplicates + 1 end
        seen[key] = true
    end
    local limited = #game.World:GetDescendants(25)
    return duplicates == 0 and limited <= 25 and limited > 0, ("%d descendants, %d duplicates, limited walk returned %d"):format(#all, duplicates, limited)
end)

attempt("FindFirstChild / OfClass / WhichIsA", function()
    local first = world_children[1]
    return game.World:FindFirstChild(first.Name) ~= nil
        and game.World:FindFirstChildOfClass(first.ClassName) ~= nil
        and game.World:FindFirstChildWhichIsA("Actor") ~= nil
        and game.World:FindFirstChild("NoSuchActor_xyz") == nil
end)

attempt("a misspelt member raises with a suggestion", function()
    local ok, err = pcall(function() return game.LocalPlayer.PlayerCameraManagr end)
    return not ok and tostring(err):find("PlayerCameraManager", 1, true) ~= nil, tostring(err)
end)

attempt("a misspelt name on game raises with a suggestion", function()
    local ok, err = pcall(function() return game.Wrold end)
    return not ok and tostring(err):find("'World'", 1, true) ~= nil, tostring(err)
end)

attempt("property reads convert: object -> Instance, name/text -> string, array -> table", function()
    local controller = game.LocalPlayer
    local camera = controller.PlayerCameraManager
    local tags = controller.Tags                -- TArray<FName> on every actor
    return instance.is_instance(camera) and type(tags) == "table" and type(controller.Name) == "string",
        ("camera=%s tags=%d"):format(tostring(camera), #tags)
end)

attempt("property writes are type-checked (bool, number) and round-trip", function()
    local controller = game.LocalPlayer
    local before = controller.bShowMouseCursor
    local ok_bad, err_bad = pcall(function() controller.bShowMouseCursor = 1 end)
    controller.bShowMouseCursor = not before
    local changed = controller.bShowMouseCursor == not before
    controller.bShowMouseCursor = before
    local ok_delegate, err_delegate = pcall(function() controller.OnDestroyed = {} end)
    return (not ok_bad) and changed and controller.bShowMouseCursor == before and not ok_delegate,
        tostring(err_bad) .. " || " .. tostring(err_delegate)
end)

attempt("a name property accepts a Lua string (converted, not crashed)", function()
    local controller = game.LocalPlayer
    -- Tags is an array of names; the single-name property every actor has is 'NetDriverName'.
    -- It is put back within this same call, so nothing in the engine sees the test value.
    local before = controller.NetDriverName
    controller.NetDriverName = "WaxTestDriver"
    local during = controller.NetDriverName
    controller.NetDriverName = before
    return during == "WaxTestDriver" and controller.NetDriverName == before, ("before=%s during=%s"):format(before, during)
end)

attempt("function calls: results convert, struct results come back, string arguments convert", function()
    local controller = game.LocalPlayer
    local location = controller:K2_GetActorLocation()
    local has_tag = controller:ActorHasTag("NoSuchTag")       -- takes an FName: a raw Lua string here would crash
    return type(location.X) == "number" and has_tag == false, ("location x=%.0f y=%.0f z=%.0f"):format(location.X, location.Y, location.Z)
end)

attempt("calling with a dot instead of a colon is explained", function()
    local controller = game.LocalPlayer
    local ok, err = pcall(function() return controller.K2_GetActorLocation() end)
    return not ok and tostring(err):find("colon", 1, true) ~= nil, tostring(err)
end)

attempt("oversized functions are refused instead of crashing", function()
    local found = game:Find("Button")
    if not found then return true, "no Button widget loaded here; skipped" end
    local ok, err = pcall(function() return found:SetStyle({}) end)
    return not ok and tostring(err):find("512", 1, true) ~= nil, tostring(err)
end)

attempt("attributes and tags", function()
    local world = game.World
    local fired = {}
    local connection = world:GetAttributeChangedSignal():Connect(function(name, value, previous) fired[#fired + 1] = name .. "=" .. tostring(value) .. "<" .. tostring(previous) end)
    world:SetAttribute("Difficulty", 3)
    world:SetAttribute("Difficulty", 4)
    world:SetAttribute("Difficulty", 4)
    world:AddTag("wax-test")
    local tagged = game:GetTagged("wax-test")
    local ok = world:GetAttribute("Difficulty") == 4 and #fired == 2 and world:HasTag("wax-test") and #tagged == 1 and tagged[1] == world
        and world:GetAttributes().Difficulty == 4
    world:RemoveTag("wax-test")
    world:SetAttribute("Difficulty", nil)
    connection:Disconnect()
    return ok and not world:HasTag("wax-test") and #game:GetTagged("wax-test") == 0, table.concat(fired, ", ")
end)

attempt("Players, Find and FindAll", function()
    local players = game.Players:GetPlayers()
    local controllers = game:FindAll("PlayerController")
    return game:Find("PlayerController") ~= nil and #controllers >= 1 and game:Find("NoSuchClass_xyz") == nil,
        ("%d players, %d characters, %d controllers"):format(#players, #game.Players:GetCharacters(), #controllers)
end)

attempt("explicit Get/Set/Call reach members whose names Wax also uses", function()
    local controller = game.LocalPlayer
    return type(controller:Get("NetDriverName")) == "string" and controller:Call("ActorHasTag", "x") == false
        and not pcall(function() return controller:Get("Nope") end)
end)

attempt("game is read-only and tostring is readable", function()
    local ok = pcall(function() game.World = 1 end)
    return not ok and tostring(game) == "game" and tostring(game.World):find("World", 1, true) ~= nil, tostring(game.World)
end)

local passed, failed = 0, {}
for _, c in ipairs(checks) do
    if c.ok then passed = passed + 1 else failed[#failed + 1] = c.name .. " :: " .. tostring(c.detail) end
end
local details = {}
for _, c in ipairs(checks) do details[#details + 1] = (c.ok and "ok   " or "FAIL ") .. c.name .. (c.detail and ("  [" .. tostring(c.detail):sub(1, 150) .. "]") or "") end
return { passed = passed, failed = #failed, failures = failed, details = details, stats = instance.stats() }
