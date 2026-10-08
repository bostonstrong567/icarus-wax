-- Live test of engine.handle: the proof that a handle is right where UE4SS's IsValid() is wrong, in a few seconds.
-- Send it, wait two seconds and send it again (once more if it says the engine has not collected yet):
--   node wax\cli\wax.mjs eval --file wax\tests\live\handle.lua
-- The first call checks the self-check, the kinds of object and what is refused, makes throwaway objects and 8 widgets
-- that nothing holds (a third of the objects bare, two thirds behind Instances), destroys one bare actor, and asks the
-- engine to collect. The second call asks every handle, then makes new objects until some are given the old addresses
-- and compares the handle with IsValid(), and an Instance with handles with one that goes by the older checks.
-- If handles are not plugged into Instances yet they are for the length of the test, and taken out again at its end.
-- In a game whose Instances were loaded before the place for handles existed that part says NOT TRIED.
-- It leaves nothing behind but objects the engine collects by itself. Returns { passed, failed, failures, details }.
local handle = Wax.import("engine.handle")
local instance = Wax.import("engine.instance")
local now = Wax.perf.now
local checks = {}
local function check(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail } end
local function attempt(name, fn)
    local ok, a, b = pcall(fn)
    if ok then check(name, a, b) else check(name, false, "raised: " .. tostring(a)) end
end
local function finish(extra)
    local out = { passed = 0, failed = 0, failures = {}, details = checks }
    for _, entry in ipairs(checks) do
        if entry.ok then
            out.passed = out.passed + 1
        else
            out.failed = out.failed + 1
            out.failures[#out.failures + 1] = entry.name .. (entry.detail and (": " .. tostring(entry.detail)) or "")
        end
    end
    for key, value in pairs(extra or {}) do out[key] = value end
    return out
end
local function valid(object) return type(object) == "userdata" and object:IsValid() end
local function microseconds(count, fn)
    local started = now()
    for _ = 1, count do fn() end
    return (now() - started) / count * 1e6
end

local ATTRIBUTE = "WaxHandleLive"
local library = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local class = StaticFindObject("/Script/Engine.ObjectLibrary")
local outer = StaticFindObject("/Engine/Transient")
local kept = rawget(_G, "WaxHandleLive")

-- True when a new Instance gets a handle: that is what being plugged in means.
local function plugged()
    local before = handle.stats().taken
    instance.wrap(StaticConstructObject(class, outer))
    return handle.stats().taken - before == 1
end

-- ------------------------------------------------------------------------------------------------ second call
if kept then
    kept.sends = kept.sends + 1
    handle.expire()
    local alive, gone, by_kind = 0, 0, {}
    local old = {}
    for index, entry in ipairs(kept.things) do
        local count = by_kind[entry.kind] or { alive = 0, gone = 0 }
        by_kind[entry.kind] = count
        if handle.alive(entry.handle) then
            alive, count.alive = alive + 1, count.alive + 1
        else
            gone, count.gone = gone + 1, count.gone + 1
            if entry.kind ~= "widget" then old[entry.address] = index end
        end
    end
    if alive > 0 and kept.sends < 6 then
        return { pending = true, alive = alive, gone = gone,
            say = "the engine has not collected every throwaway yet: send this file again in two seconds" }
    end
    rawset(_G, "WaxHandleLive", nil)

    local parts = {}
    for kind, count in pairs(by_kind) do parts[#parts + 1] = ("%s: %d gone, %d alive"):format(kind, count.gone, count.alive) end
    table.sort(parts)
    check("every throwaway reads as gone after the collection", alive == 0 and gone == #kept.things,
        table.concat(parts, " | ") .. (" | %d s after they were made"):format(os.time() - kept.time))

    attempt("a held throwaway is no longer given out", function()
        local given = 0
        for _, entry in ipairs(kept.things) do
            if entry.held:get() ~= nil or entry.held:alive() then given = given + 1 end
        end
        return given == 0, given .. " of " .. #kept.things .. " still given"
    end)

    attempt("the handle of something that lives still answers, with the same object", function()
        local game_instance = FindFirstOf("GameInstance")
        local back = handle.get(kept.control)
        return back ~= nil and back:GetAddress() == kept.control_address and valid(game_instance)
            and game_instance:GetAddress() == kept.control_address, ("alive %s"):format(tostring(handle.alive(kept.control)))
    end)

    if kept.actor then
        check("the destroyed actor stays gone", not handle.alive(kept.actor) and handle.get(kept.actor) == nil)
    end

    -- New objects of the same class and size: the engine gives some of them the addresses of the old ones.
    -- Only then is an old wrapper asked anything: a live object of its class sits at its address, so the read is safe.
    local tally = { made = 0, bare = 0, bare_right = 0, lies = 0, names = 0, with = 0, with_right = 0, without = 0, without_wrong = 0 }
    attempt("an old address taken by a new object: the old handle says gone and the new one answers", function()
        for _ = 1, 1024 do
            local fresh = StaticConstructObject(class, outer)
            tally.made = tally.made + 1
            local address = fresh:GetAddress()
            local entry = old[address] and kept.things[old[address]]
            if entry then
                old[address] = nil
                local fresh_name = fresh:GetFName():ToString()
                if entry.kind == "object" then
                    tally.bare = tally.bare + 1
                    local back = handle.get(handle.take(fresh))
                    if not handle.alive(entry.handle) and handle.get(entry.handle) == nil and entry.held:get() == nil
                        and back ~= nil and back:GetAddress() == address then
                        tally.bare_right = tally.bare_right + 1
                    end
                    if entry.wrapper:IsValid() then
                        tally.lies = tally.lies + 1
                        if entry.wrapper:GetFName():ToString() == fresh_name and fresh_name ~= entry.name then tally.names = tally.names + 1 end
                    end
                elseif entry.kind == "instance" then
                    -- with handles: the old Instance is gone and the new object gets an Instance of its own
                    tally.with = tally.with + 1
                    local made = instance.wrap(fresh)
                    if not rawequal(made, entry.instance) and made.Name == fresh_name and made:GetAttribute(ATTRIBUTE) == nil
                        and not entry.instance:IsValid() then
                        tally.with_right = tally.with_right + 1
                    end
                else
                    -- by the older checks alone: the old Instance answers for the new object
                    tally.without = tally.without + 1
                    instance.use_handles(nil)
                    local _, says_alive, reads = pcall(function()
                        local there = entry.instance:IsValid()
                        return there, there and entry.instance.Name or nil
                    end)
                    instance.use_handles(handle)
                    if says_alive == true and reads == fresh_name and reads ~= entry.name then tally.without_wrong = tally.without_wrong + 1 end
                end
                if tally.bare > 0 and tally.with > 0 and tally.without > 0 and tally.bare + tally.with + tally.without >= 9 then break end
            end
        end
        return tally.bare_right == tally.bare,
            ("%d new objects made | %d bare addresses taken | handle right %d of %d | UE4SS IsValid() of the old wrapper said true %d of %d, reading the new object's name %d times")
            :format(tally.made, tally.bare, tally.bare_right, tally.bare, tally.lies, tally.bare, tally.names)
    end)
    check("at least one address was used again, so the comparison with IsValid() was made", tally.bare > 0,
        tally.bare == 0 and "none this time: send the test again" or (tally.lies .. " of " .. tally.bare .. " wrong answers from IsValid()"))
    if kept.with_instances then
        check("with handles a new object at an old Instance's address gets an Instance of its own", tally.with_right == tally.with,
            tally.with == 0 and "no such address was used again this time" or (tally.with_right .. " of " .. tally.with))
        check("by the older checks alone the old Instance answers for the new object (what the handle ends)", true,
            tally.without == 0 and "no such address was used again this time"
            or (tally.without_wrong .. " of " .. tally.without .. " old Instances said they exist and read the new object's name"))

        attempt("with handles every Instance of a throwaway says it is gone, and the object is not asked", function()
            local wrong, tried = 0, 0
            for _, entry in ipairs(kept.things) do
                if entry.kind == "instance" or (entry.kind == "instance, older checks" and old[entry.address]) then
                    tried = tried + 1
                    local ok, problem = pcall(function() return entry.instance.Name end)
                    if entry.instance:IsValid() or ok or not tostring(problem):find("no longer exists", 1, true) then wrong = wrong + 1 end
                end
            end
            return wrong == 0 and tried > 0, (tried - wrong) .. " of " .. tried
        end)
        if not kept.plugged_before then instance.use_handles(nil) end
    else
        check("NOT TRIED: handles plugged into Instances", true, "see the first half")
    end
    local state = handle.stats()
    check("the self-check saw its own throwaway go", state.confirmed == true,
        ("on %s | confirmed %s | taken %d | asked %d | gone %d | refused %d"):format(tostring(state.on), tostring(state.confirmed),
            state.taken, state.asked, state.gone, state.refused))
    return finish({ costs = kept.costs, plugged_before = kept.plugged_before })
end

-- ------------------------------------------------------------------------------------------------- first call
if not (valid(library) and valid(class) and valid(outer)) then
    check("the game has what a throwaway object is made from", false)
    return finish()
end

local was_on = handle.on()
attempt("the self-check passes in this game", function()
    local started = now()
    local on = was_on or handle.start()
    local state = handle.stats()
    return on and state.on and state.why == nil, was_on and "it was on already" or ("started here in %.0f us"):format((now() - started) * 1e6)
end)
if not handle.on() then return finish({ why = handle.stats().why }) end

local controller = FindFirstOf("IcarusPlayerController")
local pawn = valid(controller) and controller.Pawn or nil
if not valid(pawn) then pawn = nil end

attempt("every kind of object the engine hands over comes back as itself", function()
    local kinds = {
        { "a library's default object", library }, { "a native class", StaticFindObject("/Script/Engine.Actor") },
        { "a package", outer }, { "a data table", StaticFindObject("/Engine/Transient.D_Itemable") },
        { "the game instance", FindFirstOf("GameInstance") }, { "the player controller", controller },
    }
    if pawn then
        kinds[#kinds + 1] = { "a blueprint class", pawn:GetClass() }
        kinds[#kinds + 1] = { "the world", pawn:GetWorld() }
        kinds[#kinds + 1] = { "the character", pawn }
        kinds[#kinds + 1] = { "a component of the character", pawn.RootComponent }
        kinds[#kinds + 1] = { "the player state", controller.PlayerState }
        kinds[#kinds + 1] = { "the game's interface widget", controller.UserInterface }
    end
    local good, tried, wrong = 0, 0, {}
    for _, entry in ipairs(kinds) do
        local label, object = entry[1], entry[2]
        if valid(object) then
            tried = tried + 1
            local taken, why = handle.take(object)
            local back = handle.get(taken)
            local held = handle.hold(object)
            if taken and handle.alive(taken) and back and back:GetAddress() == object:GetAddress() and back:type() == object:type()
                and rawequal(held:get(), object) and held:checked() then
                good = good + 1
            else
                wrong[#wrong + 1] = label .. " (" .. tostring(why or object:type()) .. ")"
            end
        end
    end
    return good == tried and tried >= 5, ("%d of %d%s"):format(good, tried, #wrong > 0 and (": " .. table.concat(wrong, ", ")) or "")
end)

attempt("what is not an object is refused before the engine sees it", function()
    local things = { { "a Lua table", {} }, { "a number", 5 }, { "a name", library:GetFName() },
        { "a soft reference", library:Conv_ObjectToSoftObjectReference(library) },
        { "a weak pointer", library:Conv_ObjectToSoftObjectReference(library):GetWeakPtr() },
        { "an enum", StaticFindObject("/Script/Engine.EEndPlayReason") },
        { "a member that does not exist", library.WaxNoSuchMember },
        { "the object behind a handle of nothing", library:Conv_ObjectToSoftObjectReference(nil):GetWeakPtr():Get(), "nothing" } }
    if pawn then
        things[#things + 1] = { "a struct", pawn.RootComponent.RelativeLocation }
        things[#things + 1] = { "a function", pawn.K2_GetActorLocation }
    end
    local before, wrong = handle.stats(), {}
    for _, entry in ipairs(things) do
        local taken, why = handle.take(entry[2])
        if taken ~= nil or why ~= (entry[3] or "not an object") then wrong[#wrong + 1] = entry[1] .. " (" .. tostring(why) .. ")" end
    end
    local taken, why = handle.take(nil)
    if taken ~= nil or why ~= "not an object" then wrong[#wrong + 1] = "nil" end
    local held_wrong = pcall(handle.hold, library.WaxNoSuchMember) or pcall(handle.hold, {})
    local after = handle.stats()
    return #wrong == 0 and not held_wrong and after.taken == before.taken and after.refused - before.refused == #things + 1,
        #wrong == 0 and (#things + 1) .. " refused" or table.concat(wrong, ", ")
end)

local costs = {}
attempt("the cost of taking and asking", function()
    local target = pawn or FindFirstOf("GameInstance")
    local taken = handle.take(target)
    local nothing = library:Conv_ObjectToSoftObjectReference(nil):GetWeakPtr()
    local held = handle.hold(target)
    costs.take = microseconds(300, function() handle.take(target) end)
    costs.alive = microseconds(2000, function() handle.alive(taken) end)
    costs.gone = microseconds(2000, function() handle.alive(nothing) end)
    costs.get = microseconds(2000, function() handle.get(taken) end)
    -- this file runs from the bridge, outside the frame loop, where every use asks. Inside it an answer is kept for the frame
    costs.held = microseconds(2000, function() held:get() end)
    handle.framed(function() costs.held_same_frame = microseconds(2000, function() held:get() end) end)()
    costs.is_valid = microseconds(2000, function() target:IsValid() end)
    for key, value in pairs(costs) do costs[key] = math.floor(value * 100 + 0.5) / 100 end
    return costs.take < 40 and costs.alive < 10 and costs.held_same_frame < costs.held,
        ("us: take %.2f | alive %.2f | gone %.2f | get %.2f | held %.2f | held, asked this frame %.2f | IsValid for comparison %.2f")
        :format(costs.take, costs.alive, costs.gone, costs.get, costs.held, costs.held_same_frame, costs.is_valid)
end)

-- An Instance module loaded before the place for handles was added cannot be tried: that needs a restart of the game.
local plugged_before, with_instances = false, false
if type(instance.use_handles) == "function" then
    attempt("handles are plugged into Instances", function()
        plugged_before = plugged()
        if not plugged_before then instance.use_handles(handle) end
        with_instances = plugged()
        if not with_instances and not plugged_before then instance.use_handles(nil) end
        return with_instances, plugged_before and "they were already" or "plugged in for this test"
    end)
else
    check("NOT TRIED: handles plugged into Instances", true,
        "the Instances of this game were loaded before the place for handles was added. Restart the game and send this again")
end

local things = {}
attempt("throwaway objects answer while they exist", function()
    for index = 1, 96 do
        local made = StaticConstructObject(class, outer)
        if valid(made) then
            local entry = { handle = handle.take(made), held = handle.hold(made), wrapper = made, address = made:GetAddress(),
                name = made:GetFName():ToString(), kind = "object" }
            -- two thirds of them are also behind an Instance, and half of those have something kept for them
            if with_instances and index % 3 ~= 0 then
                entry.kind = index % 3 == 1 and "instance" or "instance, older checks"
                entry.instance = instance.wrap(made)
                if entry.kind == "instance" then entry.instance:SetAttribute(ATTRIBUTE, index) end
            end
            things[#things + 1] = entry
        end
    end
    -- widgets made the way the interface makes them and never given a parent: what a removed widget is
    local widgets = "no interface, so no widgets"
    local ok, root = pcall(Wax.import, "gui.root")
    if ok and root.exists() then
        for _ = 1, 8 do
            local widget = root.new("Image")
            things[#things + 1] = { handle = handle.take(widget), held = handle.hold(widget), wrapper = widget,
                address = widget:GetAddress(), name = widget:GetFName():ToString(), kind = "widget" }
        end
        widgets = "8 widgets"
    end
    local answering = 0
    for _, entry in ipairs(things) do
        local back = handle.get(entry.handle)
        if back and back:GetAddress() == entry.address and rawequal(entry.held:get(), entry.wrapper)
            and (not entry.instance or (entry.instance.Name == entry.name and entry.instance:IsValid())) then
            answering = answering + 1
        end
    end
    return #things >= 96 and answering == #things, ("%d of %d answer | 96 objects, %d of them behind Instances, %s")
        :format(answering, #things, with_instances and 64 or 0, widgets)
end)

local actor_handle = nil
if pawn then
    attempt("a destroyed actor is gone in the same frame, while UE4SS's IsValid() still says true", function()
        local at = pawn:K2_GetActorLocation()
        local actor = pawn:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.Actor"), { X = at.X, Y = at.Y, Z = at.Z + 300 },
            { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(actor) then return false, "SpawnActor gave nothing" end
        actor_handle = handle.take(actor)
        local held = handle.hold(actor)
        local before = handle.alive(actor_handle)
        actor:K2_DestroyActor()
        handle.expire()
        local after, lie = handle.alive(actor_handle), actor:IsValid()
        return before and not after and handle.get(actor_handle) == nil and held:get() == nil,
            ("alive before %s | after the destroy %s | IsValid() after %s"):format(tostring(before), tostring(after), tostring(lie))
    end)
end

local control = FindFirstOf("GameInstance")
rawset(_G, "WaxHandleLive", { things = things, control = handle.take(control), control_address = control:GetAddress(),
    actor = actor_handle, time = os.time(), sends = 0, costs = costs, plugged_before = plugged_before, with_instances = with_instances })
-- what the engine does by itself about once a minute, as the theme stress test asks for it
library:CollectGarbage()
handle.expire()
return finish({ again = "send this file again in two seconds for the second half", costs = costs, started_here = not was_on })
