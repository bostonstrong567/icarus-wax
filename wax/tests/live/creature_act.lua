-- Live test of what the host does with creatures: game.Creatures:Spawn, SetLevel, Freeze and Unfreeze, Heal, damage that
-- the game tells of (game.Creatures.Damaged), a death with who did it (game.Creatures.Died), Remove, assigning Behaviour,
-- and Attack on a wolf. A deer appears six metres in front of the character and goes through all of it, a wolf is made
-- angry and taken away before it bites, and a rabbit shows the level a zone gives and how long a body stays. Each step
-- is said in a notification.
-- Everything is put back: every animal the test made is out of the world again, with what it left, and the character
-- has the health it had.
-- It writes only for the host and only while the character is the one saved/wax.tests.lua names as test_character. It refuses anywhere else.
-- Send it with:  node wax/cli/wax.mjs eval --file wax/tests/live/creature_act.lua
-- It runs for about a minute and a half in a task. Send the same file again for the result: while it runs it says
-- which step it is at. Before sending, set WaxCreatureActPause to the seconds each step stays to be seen (2.5 when it
-- is not set), WaxCreatureActHits to the seconds the poison has to act and the player has to hit the deer (6),
-- WaxCreatureActKind to another harmless animal than "Deer", and WaxCreatureActWolf = false to leave the wolf out.
-- Each step is noted in run\session.log before it is made.

local kept, set = pcall(function() return dofile(Wax.root .. "/saved/wax.tests.lua") end)
local NAME, WHO = "WaxCreatureActLive", kept and type(set) == "table" and type(set.test_character) == "string" and set.test_character or nil
local run = rawget(_G, NAME)
if run and run.running then return { running = true, step = run.step, seconds = os.time() - run.started } end
if run and run.result then
    rawset(_G, NAME, nil)
    return run.result
end

local game, ui = Wax.game, Wax.ui
local sched = Wax.import("core.sched")
local task = sched.task
local note = Wax.import("core.blackbox").note
local instance = Wax.import("engine.instance")
local now = Wax.perf.now
local PAUSE = tonumber(rawget(_G, "WaxCreatureActPause")) or 2.5
local HITS = tonumber(rawget(_G, "WaxCreatureActHits")) or 6
local KIND = rawget(_G, "WaxCreatureActKind") or "Deer"
local WOLF = rawget(_G, "WaxCreatureActWolf") ~= false
local POISON = "Poison_DOT"

local checks, costs, facts = {}, {}, {}
local function check(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail } end
local function result(extra)
    local passed, failed, details = 0, {}, {}
    for _, c in ipairs(checks) do
        if c.ok then passed = passed + 1 else failed[#failed + 1] = c.name .. " :: " .. tostring(c.detail) end
        details[#details + 1] = (c.ok and "ok   " or "FAIL ") .. c.name .. (c.detail ~= nil and ("  [" .. tostring(c.detail):sub(1, 260) .. "]") or "")
    end
    local out = { passed = passed, failed = #failed, failures = failed, details = details, costs_us = costs, facts = facts }
    for key, value in pairs(extra or {}) do out[key] = value end
    return out
end
local function refuse(why)
    check("the test may run here", false, why)
    return result()
end

local me = game and rawget(game, "Me")
local Creatures = game and rawget(game, "Creatures")
if not me or not Creatures then return refuse("game.Me or game.Creatures is not there") end
if type(rawget(Creatures, "Spawn")) ~= "function" or type(rawget(Creatures, "Damaged")) ~= "table" then
    return refuse("game.Creatures has no Spawn or no Damaged: the running game has world.creature from before they were added")
end
if not game.InProspect then return refuse("this is not a prospect") end
if not game.IsHost then return refuse("this player is not the host, and every one of these is for the host only") end
if not me.Exists then return refuse("there is no character right now") end
local named, name = pcall(function() return game.LocalPlayer.PlayerState.Raw.ActiveCharacter.CharacterName:ToString() end)
if not WHO then return refuse('no test character is named, so nothing is written: saved/wax.tests.lua in Wax\'s folder has to return { test_character = "<name>" }') end
if not named or name ~= WHO then
    return refuse(("the character is %s, not %s, so nothing is written"):format(named and tostring(name) or "not readable", WHO))
end
if me.Alive ~= true then return refuse("the character is not alive") end

local creature_module, character_module = Wax.import("world.creature"), Wax.import("world.character")

local function say(text, kind, seconds)
    pcall(ui.Notify, text, { title = "Wax test: creatures", kind = kind or "info", seconds = seconds or (PAUSE + 3) })
end
-- An event as it arrives.
local function heard(text) pcall(ui.Notify, text, { title = "The game told Wax", kind = "good", seconds = 4 }) end
local function pause(times) task.wait(PAUSE * (times or 1)) end
local function timed(label, fn, ...)
    local started = now()
    local a, b = fn(...)
    costs[label] = math.floor((now() - started) * 1e6 + 0.5)
    return a, b
end
-- Waits until done() is true, at most `seconds`. Answers whether it was.
local function until_true(seconds, done)
    local started = now()
    while now() - started < seconds do
        if done() then return true end
        task.wait(0.05)
    end
    return done()
end
local function raised(fn, fragment)
    local ok, problem = pcall(fn)
    if ok then return false, "it was not refused" end
    return tostring(problem):find(fragment, 1, true) ~= nil, tostring(problem)
end
local function class_of(who)
    local ok, text = pcall(function() return who.ClassName end)
    return ok and text or "something that is gone"
end
local function body() return me.Character.Raw end
local function speed(who)
    local moving = who.Velocity
    return moving and math.sqrt(moving.X ^ 2 + moving.Y ^ 2 + moving.Z ^ 2) or -1
end
local function team(who) return who.Raw.AIRelationshipTableRowNew.RowName:ToString() end
local function enum_globals()
    local found = {}
    for key in pairs(_G) do
        if type(key) == "string" and key:find("^Enum_") then found[key] = true end
    end
    return found
end
local function valid(object) return object ~= nil and type(object) == "userdata" and object:IsValid() end

local before = { health = me.Health, errors = #Wax.guard.errors(), enums = enum_globals(),
    listening = character_module.stats().told.listening, spawned = creature_module.act_stats().spawned }
local mine, connections, deaths = {}, {}, {}
local deer, death = nil, nil
local function on(signal, fn)
    local connection = signal:Connect(fn)
    connections[#connections + 1] = connection
    return connection
end
local function drop_connections()
    for i = #connections, 1, -1 do pcall(function() connections[i]:Disconnect() end) end
    connections = {}
end
local function animal()
    if not deer then error("left out: there is no animal to do it with", 0) end
    return deer
end

local steps = {}
local function step(label, telling, fn) steps[#steps + 1] = { label = label, telling = telling, fn = fn } end

step("spawn", ("A %s appears six metres in front of you, at level 5"):format(KIND), function()
    local made, why = timed("Spawn, until the game finished it", function() return Creatures:Spawn(KIND, { level = 5 }) end)
    check("Spawn answers the creature as an Instance", instance.is_instance(made), tostring(why))
    if not instance.is_instance(made) then return end
    deer = made
    mine[#mine + 1] = made
    check("its level is the one asked for when Spawn answers", made.Level == 5 and made.Raw.CurrentLevel == 5,
        ("Level %s, the game's own %s"):format(tostring(made.Level), tostring(made.Raw.CurrentLevel)))
    check("it is what was asked for", made.Variant == KIND, ("%s / %s, a %s"):format(tostring(made.Kind), tostring(made.Variant), class_of(made)))
    local far = made:DistanceTo(game.Me)
    check("it stands a few metres from the character", far > 2 and far < 12, ("%.1f m"):format(far))
    check("it is alive with all its health", made.Alive == true and made.Health == made.MaxHealth,
        ("%s of %s"):format(tostring(made.Health), tostring(made.MaxHealth)))
    check("game.Creatures lists it", until_true(1.5, function() return Creatures:GetKind(made) ~= nil end))
    check("it is not falling", until_true(2, function() return math.abs(made.Velocity.Z) < 5 end), ("speed down %.0f"):format(made.Velocity.Z))
    facts.spawned = ("%s uid %s, %s"):format(class_of(made), tostring(made.Raw.IcarusUID), tostring(made.DisplayName))
end)

step("freeze", "The animal is frozen: it stands still", function()
    local it = animal()
    local frozen = timed("Freeze", function() return it:Freeze() end)
    check("Freeze answers true and the game marks it frozen", frozen == true and it.IsFrozen == true and it.Raw.bIsNPCFrozen == true, tostring(frozen))
    check("a second Freeze answers false", it:Freeze() == false)
    task.wait(1)
    check("it does not move", speed(it) < 1, ("speed %.0f"):format(speed(it)))
    pause()
end)

step("level", "Its level goes from 5 to 25. Look at it to see the number", function()
    local it = animal()
    local most = it.MaxHealth
    local changed = timed("SetLevel", function() return it:SetLevel(25) end)
    check("SetLevel answers true and the level reads back at once", changed == true and it.Level == 25 and it.Raw.CurrentLevel == 25,
        ("%s, Level %s"):format(tostring(changed), tostring(it.Level)))
    check("its health followed the level and is full", it.Health == it.MaxHealth, ("%s of %s, %s before"):format(tostring(it.Health), tostring(it.MaxHealth), tostring(most)))
    check("the same level again answers false", it:SetLevel(25) == false)
    pause()
end)

step("health", "Its health drops to half and Heal() gives it back", function()
    local it = animal()
    local most = it.MaxHealth
    local half = math.floor(most / 2)
    it.Health = half
    check("assigning Health sets it in the game at once", it.Raw.ActorState.Health == half, tostring(it.Raw.ActorState.Health))
    pause()
    local healed = it:Heal()
    check("Heal() gives all of it back", healed == most and it.Health == most, tostring(healed))
end)

step("damage", ("It is poisoned for %d seconds. Each loss of health is told by the game itself. Hit it if you like: your hits are told too"):format(HITS), function()
    local it = animal()
    local own, every = {}, {}
    on(it.Damaged, function(who, amount, info)
        own[#own + 1] = { who = who, amount = amount, info = info }
        local by = info.Causer and (rawequal(info.Causer, who) and "the poison on it" or class_of(info.Causer)) or "nobody"
        heard(("Damaged: the animal lost %s health to %s, %s left"):format(tostring(amount), by, tostring(info.Health)))
    end)
    timed("the first handler on game.Creatures.Damaged", function()
        on(Creatures.Damaged, function(who, amount, info)
            if rawequal(who, it) then every[#every + 1] = { amount = amount, info = info } end
        end)
    end)
    local id = it:AddModifier(POISON, { seconds = HITS + 2 })
    facts.poison = ("AddModifier answered %s"):format(tostring(id))
    until_true(HITS, function() return #own >= 3 end)
    pcall(function() it:RemoveModifier(POISON) end)
    task.wait(0.3)
    check("damage to the animal is told on its own Damaged", #own >= 1 and rawequal(own[1].who, it) and own[1].amount > 0,
        #own >= 1 and ("%d times, the first for %s"):format(#own, tostring(own[1].amount)) or "nothing was told: the poison dealt no damage the game told of, and the animal was not hit")
    check("game.Creatures.Damaged told the same hits", #every == #own and #every >= 1, ("%d against %d"):format(#every, #own))
    if own[1] then
        local info = own[1].info
        facts.damage = ("%s damage, Causer %s, Instigator %s, Applied %s, Health after %s"):format(tostring(own[1].amount),
            info.Causer and class_of(info.Causer) or "none", info.Instigator and class_of(info.Instigator) or "none",
            tostring(info.Applied), tostring(info.Health))
    end
    drop_connections()
    if it.Alive then it:Heal() end
end)

step("unfreeze", "It is let go and may walk off, then it is held again", function()
    local it = animal()
    local freed = timed("Unfreeze", function() return it:Unfreeze() end)
    check("Unfreeze answers true and the game marks it free", freed == true and it.IsFrozen == false, tostring(freed))
    check("a second Unfreeze answers false", it:Unfreeze() == false)
    local moved = until_true(3, function() return speed(it) > 20 end)
    facts.after_unfreeze = moved and "it walked on within three seconds" or "it stood where it was for three seconds"
    check("Freeze holds it again", it:Freeze() == true and it.IsFrozen == true)
end)

step("behaviour", "Its team is changed to Friendly, to HostileToPlayers and back, and a deer is asked to attack", function()
    local it = animal()
    local start = team(it)
    timed("Behaviour = word", function() it.Behaviour = "Friendly" end)
    check("assigning Friendly puts it on the game's team FriendlyAll", team(it) == "FriendlyAll" and it.Behaviour == "Friendly", team(it))
    it.Behaviour = "HostileToPlayers"
    check("assigning HostileToPlayers puts it on EnemyPlayerOnly", team(it) == "EnemyPlayerOnly" and it.Behaviour == "HostileToPlayers", team(it))
    it.Behaviour = "Default"
    check("Default puts it back on the team it started on", team(it):lower() == start:lower() and it.Behaviour == "Default",
        ("%s, started on %s, reads %s"):format(team(it), start, tostring(it.Behaviour)))
    local refused, text = raised(function() it.Behaviour = "Freindly" end, "is not a behaviour or a team of the game")
    check("a wrong word is refused with the nearest one", refused and team(it):lower() == start:lower(), text)
    refused, text = raised(function() it:Attack(game.Me) end, "cannot be made to attack")
    check("an animal with no aggression says so when it is asked to attack", refused, text)
    facts.no_aggression = text
end)

step("death", "It has 1 health left and is poisoned: the next loss ends it. A second later what is left of it is taken away", function()
    local it = animal()
    local told, own = {}, {}
    on(Creatures.Died, function(who, info)
        if not rawequal(who, it) then return end
        told[#told + 1] = info
        local by = ", with no hit that was told"
        if info.Killer then
            by = rawequal(info.Killer, who) and ", ended by the poison on it: the game names the animal itself for that" or (", ended by " .. class_of(info.Killer))
        end
        heard(("Died: the %s%s"):format(tostring(info.Variant), by))
    end)
    on(it.Died, function(_, info) own[#own + 1] = info end)
    it.Health = 1
    it:AddModifier(POISON, { seconds = HITS + 4 })
    local by_damage = until_true(HITS, function() return it.Alive == false end)
    if not by_damage then
        local killed = timed("Kill", function() return it:Kill() end)
        check("Kill() answers true", killed == true, tostring(killed))
    end
    death = { at = now(), place = it.Position }
    deaths[#deaths + 1] = death
    local came = until_true(2, function() return #told >= 1 end)
    task.wait(1)
    check("game.Creatures.Died tells of it, once", came and #told == 1, #told .. " times")
    check("the creature's own Died told it too, once", #own == 1, #own .. " times")
    if told[1] then
        local info = told[1]
        check("it says what died", info.Variant == KIND and info.Kind ~= nil and info.ClassName == class_of(it),
            ("%s / %s, %s"):format(tostring(info.Kind), tostring(info.Variant), tostring(info.ClassName)))
        facts.death = ("%s, Killer %s, Instigator %s, Damage %s"):format(by_damage and "ended by damage" or "ended by Kill()",
            info.Killer and class_of(info.Killer) or "none", info.Instigator and class_of(info.Instigator) or "none", tostring(info.Damage))
        if by_damage then check("a death by damage names what did it", info.Killer ~= nil and info.Damage ~= nil, facts.death) end
    end
    drop_connections()
    -- the game makes a corpse of a dead animal about three seconds after its death, so the body is taken away before that
    deer = nil
    local since = now() - death.at
    if not it:IsValid() then
        check("Remove takes the dead animal out of the world", false,
            ("%.1f s after its death the game had made a corpse of it already"):format(since))
        return
    end
    local asked = timed("Remove", function() return it:Remove() end)
    local gone = until_true(3, function() return not it:IsValid() end)
    check("Remove takes the dead animal out of the world", asked == true and gone, ("asked %.1f s after its death"):format(since))
    facts.removed_dead = ("%.1f s after its death"):format(since)
end)

if WOLF then
    step("a wolf", "A wolf appears twelve metres ahead and is made angry at you. It is held and taken away before it bites", function()
        local here, yaw, health = me.Position, math.rad(me.Rotation.Yaw), me.Health
        local wolf, why = Creatures:Spawn("Conifer_Wolf", { X = here.X + math.cos(yaw) * 1200, Y = here.Y + math.sin(yaw) * 1200, Z = here.Z }, { level = 1 })
        check("a wolf is spawned at a place that was given", instance.is_instance(wolf), tostring(why))
        if not instance.is_instance(wolf) then return end
        mine[#mine + 1] = wolf
        local far = wolf:DistanceTo(game.Me)
        check("it is a level 1 wolf about twelve metres away", wolf.Variant == "Conifer_Wolf" and wolf.Level == 1 and far > 6 and far < 18,
            ("%s level %s, %.1f m"):format(tostring(wolf.Variant), tostring(wolf.Level), far))
        facts.wolf = ("on the team %s, which reads %s, doing %s"):format(team(wolf), tostring(wolf.Behaviour), tostring(wolf.Action))
        task.wait(1)
        local angry = timed("Attack", function() return wolf:Attack(game.Me) end)
        check("Attack answers true", angry == true, tostring(angry))
        local started = now()
        local after = until_true(6, function() return rawequal(wolf.Target, me.Character) end)
        check("the wolf has the character as its target", after, after and ("after %.1f s, doing %s"):format(now() - started, tostring(wolf.Action)) or tostring(wolf.Action))
        check("Freeze holds the angry wolf", wolf:Freeze() == true)
        say("The wolf is after you. It is held still, and taken away in a moment", "info")
        pause()
        wolf:Remove()
        check("the wolf is out of the world again", until_true(3, function() return not wolf:IsValid() end))
        local lost = health - me.Health
        facts.wolf_bites = lost > 0 and ("the character lost %d health, which was given back"):format(lost) or "the character lost no health"
        if lost > 0 and me.Alive then me.Health = health end
    end)
end

step("a rabbit", "A rabbit appears with no level given: it gets the middle level of the zone you stand in", function()
    local rabbit, why = timed("Spawn with the zone's level", function() return Creatures:Spawn("Rabbit") end)
    check("a rabbit is spawned with neither place nor level", instance.is_instance(rabbit), tostring(why))
    if not instance.is_instance(rabbit) then return end
    mine[#mine + 1] = rabbit
    local zone, median = "?", nil
    pcall(function()
        local found = {}
        game:Library("BP_AIFunctionLibrary_C").Raw:GetZoneTextureSample(body(), rabbit.Position, body(), found)
        zone = found.RowName:ToString()
        median = game.Data:Table("AISpawnZones"):Row(zone, { "MedianLevel" }).MedianLevel
    end)
    check("its level is the middle level of the zone", median ~= nil and rabbit.Level == median,
        ("zone %s, middle level %s, the rabbit has %s"):format(zone, tostring(median), tostring(rabbit.Level)))
    facts.spawn_call_us = creature_module.act_stats().spawn_us
    pause()
    -- a death with no hit: told by looking, a moment later, and the body is left to see how long the game keeps it
    say("The rabbit is ended with Kill() and left lying, to see when the game makes a corpse of it")
    local told = {}
    on(Creatures.Died, function(who, info)
        if rawequal(who, rabbit) then told[#told + 1] = { info = info, at = now() } end
    end)
    local place, killed_at = rabbit.Position, now()
    local killed = rabbit:Kill()
    deaths[#deaths + 1] = { at = killed_at, place = place }
    local came = until_true(2, function() return #told >= 1 end)
    check("Kill() ends it, and game.Creatures.Died tells of it once with no killer",
        killed == true and came and #told == 1 and told[1].info.Killer == nil and told[1].info.Variant == "Rabbit",
        came and ("told %.2f s after Kill()"):format(told[1].at - killed_at) or "not told in two seconds")
    local swapped = until_true(14, function() return not rabbit:IsValid() end)
    facts.body_stays = swapped and ("%.1f s after Kill() the rabbit was no creature any more"):format(now() - killed_at)
        or "the rabbit was still a creature 14 s after Kill()"
    if not swapped then rabbit:Remove() end
    check("the rabbit is out of the world again", until_true(3, function() return not rabbit:IsValid() end))
    check("its death was told once in all", #told == 1, #told .. " times")
end)

step("what is refused", "Spawn is asked for a kind with several variants, a tamed animal and options that are not there yet", function()
    local made = creature_module.act_stats().spawned
    local refused, text = raised(function() Creatures:Spawn("Wolf") end, "comes in several variants")
    check("a kind with several variants lists them", refused, text)
    refused, text = raised(function() Creatures:Spawn("Mount_Horse") end, "is a tamed animal")
    check("a tamed variant is refused", refused, text)
    refused, text = raised(function() Creatures:Spawn("Deer", { count = 2 }) end, "is not in this version of Wax")
    check("an option that was never tried is refused by name", refused, text)
    refused, text = raised(function() Creatures:Spawn("Dear") end, "is not a creature kind")
    check("a wrong kind is refused with the nearest names", refused, text)
    check("none of them spawned anything", creature_module.act_stats().spawned == made)
end)

-- Takes away whatever a step that failed half way left behind.
local function put_back()
    drop_connections()
    for _, made in ipairs(mine) do
        if made:IsValid() then pcall(function() made.Raw:SetLifeSpan(0.1) end) end
    end
    if me.Alive then pcall(function() me.Health = math.max(me.Health, before.health) end) end
end

-- A killed animal becomes a corpse some seconds after its death, unless it left the world first.
local function sweep_corpses()
    if #deaths == 0 then return end
    local wait = 12 - (now() - deaths[#deaths].at)
    if wait > 0 then task.wait(wait) end
    local corpses, left = FindAllOf("IcarusCorpse"), 0
    for index = 1, corpses and #corpses or 0 do
        pcall(function()
            local corpse = corpses[index]
            if not valid(corpse) or corpse.bActorIsBeingDestroyed == true then return end
            local lies = corpse:K2_GetActorLocation()
            for _, one in ipairs(deaths) do
                local place = one.place
                if math.sqrt((lies.X - place.X) ^ 2 + (lies.Y - place.Y) ^ 2 + (lies.Z - place.Z) ^ 2) <= 600 then
                    corpse:SetLifeSpan(0.1)
                    left = left + 1
                    break
                end
            end
        end)
    end
    facts.corpses_removed = left
end

run = { running = true, step = "starting", started = os.time() }
rawset(_G, NAME, run)
task.spawn(function()
    local finished, problem = pcall(function()
        for _, one in ipairs(steps) do
            run.step = one.label
            note("creature_act live: " .. one.label)
            say("Testing " .. one.label .. ": " .. one.telling)
            task.wait(math.min(PAUSE, 1.5))
            local failed_before = 0
            for _, c in ipairs(checks) do failed_before = failed_before + (c.ok and 0 or 1) end
            local ok, raised_text = pcall(one.fn)
            if not ok then check(one.label, false, "raised: " .. tostring(raised_text)) end
            drop_connections()
            local failed_now = 0
            for _, c in ipairs(checks) do failed_now = failed_now + (c.ok and 0 or 1) end
            say(one.label .. (failed_now > failed_before and ": failed" or ": passed"), failed_now > failed_before and "bad" or "good")
            task.wait(math.min(PAUSE, 1.5))
        end
    end)
    if not finished then check("the run", false, "raised: " .. tostring(problem)) end
    run.step = "putting things back"
    pcall(put_back)
    pcall(sweep_corpses)
    task.wait(0.6)
    local left = 0
    for _, made in ipairs(mine) do
        if made:IsValid() then left = left + 1 end
    end
    check("every animal the test made is out of the world", left == 0, left .. " still there")
    local stats, told = creature_module.act_stats(), character_module.stats().told
    check("nothing is listened to or held once every handler is gone",
        told.listening == before.listening and stats.deaths_held == 0 and Creatures.Damaged.count == 0,
        ("listening %s (%s before), deaths held %s"):format(tostring(told.listening), tostring(before.listening), tostring(stats.deaths_held)))
    facts.spawned_in_all = stats.spawned - before.spawned
    local leftover = {}
    for key in pairs(enum_globals()) do
        if not before.enums[key] then leftover[#leftover + 1] = key end
    end
    facts.enum_globals_left_meanwhile = table.concat(leftover, " ")
    check("nothing was recorded as an error", #Wax.guard.errors() == before.errors, #Wax.guard.errors() - before.errors)
    check("no name Wax gives hides one of the game's", #Wax.import("engine.easy").clashes() == 0)
    check("the character is alive with the health it had", me.Alive == true and me.Health >= before.health,
        ("%s, %s before"):format(tostring(me.Health), tostring(before.health)))
    local out = result({ pause = PAUSE })
    run.result, run.running = out, false
    say(("Creatures: %d checks passed, %d failed"):format(out.passed, out.failed), out.failed == 0 and "good" or "bad", 8)
end)

return { started = true, steps = #steps, next = "send this file again for the result" }
