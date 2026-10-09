-- Live test of world.blueprints (game.Blueprints): defining, spawning, parts, stepped, destroying, and the module going.
-- It needs a prospect, the host, and the character saved/wax.tests.lua names as test_character. It loads that one module again by itself and no other
-- (world.assets is started too when game.Assets is not there yet, and is then left running).
-- Send it twice:  node wax/cli/wax.mjs eval --file wax/tests/live/blueprints.lua
--   1. runs the checks that fit in one call, stands three crates in front of the camera, and starts the timed half
--   2. about sixteen seconds later: gives the result of both halves
-- The crates turn for as long as they stand: capture the game's window in that time (wax\cli\screenshot.ps1). They
-- stand for WaxBlueprintsLook seconds after the checks (8 when unset). Each step is named in a notification. Every bare
-- actor is counted four times, and each count reads every actor of the world once, which is a short hitch.
-- Set WaxBlueprintsTouch = true first to try touched as well: it asks the game with GetOverlappingActors and writes a
-- collision profile, two calls that no game had been seen to take when this was written.

local kept = rawget(_G, "WaxBlueprintsLive")
if kept then
    if not kept.done then
        return { passed = 0, failed = 0, failures = {}, details = { "the timed half is still running: send this again in a few seconds" }, pending = true }
    end
    rawset(_G, "WaxBlueprintsLive", nil)
    return kept.result
end

local game = Wax.game
local scope = Wax.import("core.scope")
local instance = Wax.import("engine.instance")
local now = Wax.perf.now
local LOOK = tonumber(rawget(_G, "WaxBlueprintsLook")) or 8
local TOUCH = rawget(_G, "WaxBlueprintsTouch") == true

-- What is tried next, shown to whoever sits in front of the game.
local function tell(text, kind)
    local ui = Wax.ui
    if ui then pcall(ui.Notify, text, { title = "Testing blueprints", kind = kind or "info", seconds = 6 }) end
end

local checks = {}
local function check(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail } end
local function attempt(name, fn)
    local ok, a, b = pcall(fn)
    if ok then check(name, a, b) else check(name, false, "raised: " .. tostring(a)) end
end
local function raises(fn, fragment)
    local ok, problem = pcall(fn)
    if ok then return false, "it did not raise" end
    return tostring(problem):find(fragment, 1, true) ~= nil, (tostring(problem):match("^[^\r\n]*"))
end
local function result(pending)
    local passed, failed, details = 0, {}, {}
    for _, c in ipairs(checks) do
        if c.ok then passed = passed + 1 else failed[#failed + 1] = c.name .. " :: " .. tostring(c.detail) end
        details[#details + 1] = (c.ok and "ok   " or "FAIL ") .. c.name .. (c.detail ~= nil and ("  [" .. tostring(c.detail):sub(1, 260) .. "]") or "")
    end
    return { passed = passed, failed = #failed, failures = failed, details = details, pending = pending or nil }
end

if not game.InProspect or not game.Character then
    check("a prospect with a character", false, "this test puts things in the world: enter a prospect first")
    return result()
end
local named, who = pcall(function() return game.LocalPlayer.PlayerState.Raw.ActiveCharacter.CharacterName:ToString() end)
local kept, set = pcall(function() return dofile(Wax.root .. "/saved/wax.tests.lua") end)
local allowed = kept and type(set) == "table" and type(set.test_character) == "string" and set.test_character or nil
if not allowed then
    check("the test character", false, 'no test character is named: saved/wax.tests.lua in Wax\'s folder has to return { test_character = "<name>" }')
    return result()
end
if not named or who ~= allowed then
    check("the test character", false, "the character is " .. tostring(who) .. ": this test only runs on " .. allowed)
    return result()
end

-- the module, by itself
if not rawget(game, "Assets") then Wax.import("world.assets").start() end
local was_loaded = type(Wax.modules["world.blueprints"]) == "table"
local function load_module()
    local old = Wax.modules["world.blueprints"]
    if type(old) == "table" and old.stop then pcall(old.stop) end
    Wax.modules["world.blueprints"] = nil
    local loaded = Wax.import("world.blueprints")
    loaded.start()
    return loaded
end
local module = load_module()
local Blueprints = game.Blueprints
local owner = scope.new("WaxBlueprintsLive")
local function mine(fn, ...) return scope.run(owner, fn, ...) end

local CUBE = "/Engine/BasicShapes/Cube.Cube"
local SHOWS = "/Engine/EngineMaterials/Widget3DPassThrough_Opaque"
local GLOW = "/Engine/EngineMaterials/EmissiveMeshMaterial"
local WOOD = "/Game/Assets/2DArt/UI/Items/Item_Icons/Resources/ITEM_Wood.ITEM_Wood"

-- Every actor that is of the class Actor itself, which is what a thing with no base is. One read of each actor of the world.
local function bare_actors()
    local wanted = StaticFindObject("/Script/Engine.Actor"):GetAddress()
    local found, count = FindAllOf("Actor"), 0
    for index = 1, found and #found or 0 do
        local actor = found[index]
        if actor:IsValid() and actor:GetClass():GetAddress() == wanted and not actor.bActorIsBeingDestroyed then count = count + 1 end
    end
    return count
end

attempt("game.Blueprints is there and says its name", function() return tostring(Blueprints) == "Blueprints", tostring(Blueprints) end)
attempt("a member it lacks is an error that names a near one", function()
    return raises(function() return Blueprints.Defin end, "Did you mean 'Define'?")
end)
attempt("a misspelt option, a class the game lacks and a path it lacks are errors when the blueprint is defined", function()
    local option, said_option = raises(function() mine(function() Blueprints:Define("WaxLiveBad", { part = {} }) end) end, "Did you mean 'parts'?")
    local class, said_class = raises(function()
        mine(function() Blueprints:Define("WaxLiveBad", { parts = { Body = { class = "PointLihgtComponent" } } }) end)
    end, "Did you mean 'PointLightComponent'?")
    local path, said_path = raises(function()
        mine(function() Blueprints:Define("WaxLiveBad", { parts = { Body = { mesh = "/Engine/BasicShapes/Cubee" } } }) end)
    end, "the game has no asset")
    return option and class and path and Blueprints:Get("WaxLiveBad") == nil, said_option .. " | " .. said_class .. " | " .. said_path
end)

local before = bare_actors()

-- a crate: the engine's cube with the wood icon on it, a smaller cube on top, and a lamp above
local began, ended = {}, {}
local crate
attempt("a crate with three parts is defined, and nothing is in the world yet", function()
    local started = now()
    crate = mine(function()
        return Blueprints:Define("WaxLiveCrate", {
            parts = {
                Body = { mesh = CUBE, root = true, scale = 0.6, material = { from = SHOWS, textures = { SlateUI = WOOD } }, collision = "none" },
                Top = { mesh = CUBE, at = { 0, 0, 75 }, scale = 0.4, rotation = { Yaw = 45 },
                        material = { from = GLOW, colors = { Color = "Orange" } }, collision = "none" },
                Lamp = { class = "PointLightComponent", at = { 0, 0, 160 },
                         set = { IntensityUnits = 1, Intensity = 200, AttenuationRadius = 600, CastShadows = false } },
            },
            began = function(thing)
                began[#began + 1] = thing
                thing.Data.parts_at_began = thing:Part("Lamp").ClassName
            end,
            stepped = function(thing, dt)
                local state = thing.Data
                state.steps, state.seconds = (state.steps or 0) + 1, (state.seconds or 0) + dt
                state.yaw = ((state.yaw or 0) + 90 * dt) % 360
                thing.Facing = { Yaw = state.yaw }
            end,
            every = { 0.5, function(thing) thing.Data.ticks = (thing.Data.ticks or 0) + 1 end },
            ended = function(thing, reason) ended[#ended + 1] = { thing = thing, reason = reason } end,
        })
    end)
    local spent = (now() - started) * 1000
    return crate.Name == "WaxLiveCrate" and crate.Base == "Actor" and crate:Count() == 0 and module.stats().things == 0,
        ("defined in %.3f ms, its assets loaded"):format(spent)
end)
tell("Three crates are spawned in front of you: a cube with the wood picture, a glowing top and a lamp")

local camera = game.LocalPlayer.Raw.PlayerCameraManager
local eye, turn = camera:GetCameraLocation(), camera:GetCameraRotation()
local yaw = math.rad(turn.Yaw)
local function spot(side, ahead)
    return { X = eye.X + math.cos(yaw) * ahead - math.sin(yaw) * side, Y = eye.Y + math.sin(yaw) * ahead + math.cos(yaw) * side, Z = eye.Z - 130 }
end

local things, wanted = {}, { spot(-170, 480), spot(0, 480), spot(170, 480) }
attempt("three crates are spawned in front of the camera", function()
    if not crate then return false, "there is no blueprint" end
    local times = {}
    for index, at in ipairs(wanted) do
        local started = now()
        things[index] = crate:Spawn(at, { Yaw = 30 * index }, { n = index })
        times[index] = ("%.3f"):format((now() - started) * 1000)
    end
    return #things == 3 and crate:Count() == 3 and module.stats().things == 3, "ms a spawn: " .. table.concat(times, ", ")
end)
attempt("began ran once for each, in Spawn, with the parts there", function()
    local right = #began == 3
    for index, thing in ipairs(things) do right = right and rawequal(began[index], thing) and thing.Data.parts_at_began == "PointLightComponent" end
    return right, #began .. " calls"
end)
attempt("each stands where it was asked to, turned as asked, and is an actor of the class Actor", function()
    local off, said = 0, {}
    for index, thing in ipairs(things) do
        local at, facing = thing.Position, thing.Facing
        off = math.max(off, math.abs(at.X - wanted[index].X), math.abs(at.Y - wanted[index].Y), math.abs(at.Z - wanted[index].Z),
            math.abs(facing.Yaw - 30 * index))
        said[index] = ("%.0f %.0f %.0f yaw %.0f"):format(at.X, at.Y, at.Z, facing.Yaw)
    end
    return off < 1 and things[1].ClassName == "Actor" and things[1]:IsA("Actor") and instance.is_instance(things[1].Actor),
        table.concat(said, " | ")
end)
attempt("the root part is the root, the others hang on it at their own places", function()
    local thing = things[2]
    local body, top, lamp = thing:Part("Body"), thing:Part("Top"), thing:Part("Lamp")
    local root = thing.Actor.Raw.RootComponent
    local top_at, body_at = top.Raw:K2_GetComponentLocation(), body.Raw:K2_GetComponentLocation()
    local size, top_size = body.Raw:K2_GetComponentScale(), top.Raw:K2_GetComponentScale()
    local lamp_at = lamp.Raw:K2_GetComponentLocation()
    return root:GetAddress() == body.Raw:GetAddress() and top.Raw:GetAttachParent():GetAddress() == root:GetAddress()
        and math.abs(top_at.Z - body_at.Z - 75) < 1 and math.abs(lamp_at.Z - body_at.Z - 160) < 1 and math.abs(size.X - 0.6) < 0.01
        and math.abs(top_size.X - 0.4) < 0.01 and lamp:IsA("PointLightComponent"),
        ("top %.1f and lamp %.1f above the body, body scale %.2f, top scale %.2f, lamp intensity %s"):format(top_at.Z - body_at.Z,
            lamp_at.Z - body_at.Z, size.X, top_size.X, tostring(lamp.Intensity))
end)
attempt("collision \"none\" is written, and the bounds hold all the parts", function()
    local thing = things[1]
    local bounds = thing:GetBounds()
    local collision = thing:Part("Body").Raw:GetCollisionEnabled()
    return collision == 0 and bounds.Size.Z > 60 and bounds.Size.X > 50,
        ("collision %s, size %.0f %.0f %.0f"):format(tostring(collision), bounds.Size.X, bounds.Size.Y, bounds.Size.Z)
end)
attempt("three more bare actors are in the world", function()
    local count = bare_actors()
    return count == before + 3, ("%d before, %d now"):format(before, count)
end)

local state = { done = false }
rawset(_G, "WaxBlueprintsLive", state)
local function finish()
    state.result = result()
    state.done = true
    local outcome = state.result
    tell(("Blueprints: %d checks passed, %d failed. The crates are gone again"):format(outcome.passed, outcome.failed),
        outcome.failed == 0 and "good" or "bad")
end
do
    local so_far = result()
    tell(("%d of %d checks passed so far. The crates turn from Lua, a quarter turn a second"):format(so_far.passed, #checks),
        so_far.failed == 0 and "good" or "bad")
end

Wax.task.spawn(function()
    local ok, problem = pcall(function()
        Wax.task.wait(2)
        attempt("stepped ran every frame for each crate and turned it, and every ran at its pace", function()
            local right, said = true, {}
            for index, thing in ipairs(things) do
                local s = thing.Data
                local apart = (thing.Facing.Yaw - (s.yaw or 0)) % 360
                if apart > 180 then apart = 360 - apart end
                right = right and (s.steps or 0) > 30 and math.abs((s.seconds or 0) - 2) < 1 and (s.ticks or 0) >= 3 and (s.ticks or 0) <= 6
                    and apart < 1
                said[index] = ("%d steps in %.2f s, %d ticks, yaw %.0f"):format(s.steps or 0, s.seconds or 0, s.ticks or 0, thing.Facing.Yaw)
            end
            return right, table.concat(said, " | ")
        end)
        attempt("the crates were drawn", function()
            local drawn = 0
            for _, thing in ipairs(things) do
                if thing:WasRecentlyRendered(1.5) then drawn = drawn + 1 end
            end
            return drawn == #things, drawn .. " of " .. #things .. " drawn in the last second and a half"
        end)
        attempt("what Wax costs a frame with three stepped things", function()
            local stats = module.stats()
            return stats.stepping == 3 and stats.over_budget == 0, ("stepping %d, frames over the 2 ms: %d"):format(stats.stepping, stats.over_budget)
        end)
        tell("A small cube is added to the side of the left crate while it stands")
        attempt("AddPart makes one more part on a crate that stands", function()
            local started = now()
            local sign = things[1]:AddPart("Sign", { mesh = CUBE, at = { 0, 60, 0 }, scale = 0.2, collision = "none" })
            local spent = (now() - started) * 1000
            return instance.is_instance(sign) and rawequal(things[1]:Part("sign"), sign) and sign.Raw:GetAttachParent():IsValid(),
                ("%.3f ms"):format(spent)
        end)

        Wax.task.wait(2)

        -- touched: a pad the size of a room, stood on the character. Only when asked for: its two calls are new to the game.
        if TOUCH then
            tell("A box you cannot see is stood on the character, to hear what touches it")
            local touched, pad_thing = {}, nil
            attempt("touched is told of the character that stands in a part with collision \"touch\"", function()
                local pad = mine(function()
                    return Blueprints:Define("WaxLivePad", {
                        parts = { Sense = { mesh = CUBE, scale = 3, collision = "touch", set = { bVisible = false } } },
                        touched = function(_, other) touched[#touched + 1] = other end,
                    })
                end)
                local at = game.Character.Raw:K2_GetActorLocation()
                pad_thing = pad:Spawn({ X = at.X, Y = at.Y, Z = at.Z })
                Wax.task.wait(0.6)
                local met = false
                for _, other in ipairs(touched) do met = met or other == game.Character end
                local names = {}
                for index, other in ipairs(touched) do names[index] = other.ClassName end
                return met, ("%d looks, touched by: %s. touch is %s"):format(module.stats().looks, table.concat(names, ", "),
                    tostring(module.stats().touch_problem or "on"))
            end)
            if pad_thing then pad_thing:Destroy() end
        end

        tell("The right crate is destroyed from Lua")
        attempt("Destroy takes one crate away, and it says so from then on", function()
            local lamp = things[3]:Part("Lamp")
            local started = now()
            local first, second = things[3]:Destroy(), things[3]:Destroy()
            local spent = (now() - started) * 1000
            local gone, said = raises(function() return things[3].Name end, "no longer exists (it was destroyed)")
            local part_gone = raises(function() return lamp.Name end, "no longer exists")
            return first == true and second == false and things[3].Alive == false and gone and part_gone and things[3].Data.n == 3
                and crate:Count() == 2, ("%.3f ms; %s"):format(spent, said)
        end)
        Wax.task.wait(0.2)
        attempt("ended ran for it a frame later, once", function()
            local reasons, crate_ended = {}, false
            for index, entry in ipairs(ended) do
                reasons[index] = entry.reason
                crate_ended = crate_ended or rawequal(entry.thing, things[3])
            end
            return crate_ended and #ended == 1 and ended[1].reason == "Destroyed", table.concat(reasons, ", ")
        end)
        attempt("two crates are left, and they still turn", function()
            local steps = things[1].Data.steps or 0
            Wax.task.wait(0.3)
            return crate:Count() == 2 and module.stats().things == 2 and (things[1].Data.steps or 0) > steps and things[2].Alive,
                ("%d things, %d more steps in 0.3 s"):format(module.stats().things, (things[1].Data.steps or 0) - steps)
        end)

        Wax.task.wait(LOOK)

        -- the module goes: the crates that are left go with it
        tell("The module is loaded again: the two crates that are left go with it")
        local steps_before = (things[1].Data.steps or 0)
        attempt("loading the module again destroys what was left and forgets the blueprint", function()
            module = load_module()
            Blueprints = game.Blueprints
            local gone, said = raises(function() return things[1].Name end, "no longer exists")
            return gone and things[1].Alive == false and things[2].Alive == false and Blueprints:Get("WaxLiveCrate") == nil
                and module.stats().things == 0, said
        end)
        Wax.task.wait(0.3)
        attempt("nothing of the old module runs any more", function()
            return (things[1].Data.steps or 0) == steps_before and #ended == 1, ("ended ran %d times in all"):format(#ended)
        end)
        attempt("the fresh module spawns and destroys", function()
            local again = mine(function() return Blueprints:Define("WaxLiveAgain", { parts = { Body = { mesh = CUBE, scale = 0.3, collision = "none" } } }) end)
            local thing = again:Spawn(wanted[2])
            local alive = thing.Alive
            thing:Destroy()
            return alive and not thing.Alive and again:Count() == 0
        end)
    end)
    if not ok then check("the timed half ran through", false, tostring(problem)) end
    local failures = owner.alive and owner:destroy() or {}
    attempt("when the owner goes, nothing is left of the test: as many bare actors as before it", function()
        local stats, count = module.stats(), bare_actors()
        return #failures == 0 and stats.things == 0 and stats.blueprints == 0 and count == before,
            ("things %d, blueprints %d, failures while undoing %d, bare actors %d before and %d now"):format(stats.things, stats.blueprints,
                #failures, before, count)
    end)
    if not was_loaded then
        pcall(module.stop)
        Wax.modules["world.blueprints"] = nil
    end
    finish()
end)

return result(true)
