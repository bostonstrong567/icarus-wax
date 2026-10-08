-- Live test of what the host does to a character and to the session: assigning Health, Stamina, Food, Water and Oxygen,
-- Heal, AddModifier and RemoveModifier, Give and Take, Teleport, and game.Time:Set. Each step is said in a notification,
-- made, read back from the game's own objects, left to be seen for a moment and put back: the values as they were, the
-- modifier off, the items out again, the character where it stood. The clock is the one thing that stays: the game's
-- clock only goes forward within a day, so the hour it is moved on is not taken back.
-- It writes only for the host and only on the character that saved/wax.tests.lua names as test_character. It refuses anywhere else.
-- Send it with:  node wax/cli/wax.mjs eval --file wax/tests/live/actions.lua
-- It runs for about a minute in a task. Send the same file again for the result: while it runs it says which step it is at.
-- Before sending, set WaxActionsPause to the seconds each step stays to be seen (2.5 when it is not set),
-- WaxActionsClock = false to leave the clock where it is (a second run in one sitting), and
-- WaxActionsKill = true to end with Kill() on the test character. That one cannot be put back: the character is dead
-- afterwards and has to respawn, so only with the owner's word.
-- Each step is noted in run\session.log before it is made.

local kept, set = pcall(function() return dofile(Wax.root .. "/saved/wax.tests.lua") end)
local NAME, WHO = "WaxActionsLive", kept and type(set) == "table" and type(set.test_character) == "string" and set.test_character or nil
local run = rawget(_G, NAME)
if run and run.running then return { running = true, step = run.step, seconds = os.time() - run.started } end
if run and run.result then
    rawset(_G, NAME, nil)
    return run.result
end

local game, ui = Wax.game, Wax.ui
local task = Wax.import("core.sched").task
local note = Wax.import("core.blackbox").note
local now = Wax.perf.now
local PAUSE = tonumber(rawget(_G, "WaxActionsPause")) or 2.5
local KILL = rawget(_G, "WaxActionsKill") == true
local CLOCK = rawget(_G, "WaxActionsClock") ~= false

local checks, costs = {}, {}
local function check(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail } end
local function result(extra)
    local passed, failed, details = 0, {}, {}
    for _, c in ipairs(checks) do
        if c.ok then passed = passed + 1 else failed[#failed + 1] = c.name .. " :: " .. tostring(c.detail) end
        details[#details + 1] = (c.ok and "ok   " or "FAIL ") .. c.name .. (c.detail ~= nil and ("  [" .. tostring(c.detail):sub(1, 240) .. "]") or "")
    end
    local out = { passed = passed, failed = #failed, failures = failed, details = details, costs_us = costs }
    for key, value in pairs(extra or {}) do out[key] = value end
    return out
end
local function refuse(why)
    check("the test may run here", false, why)
    return result()
end

local me = game and rawget(game, "Me")
if not me or not rawget(game, "Time") or not rawget(game, "Items") then
    return refuse("game.Me, game.Time or game.Items is not there: world.character, world.stats, world.session and world.items have to be started")
end
if not game.InProspect then return refuse("this is not a prospect") end
if not game.IsHost then return refuse("this player is not the host, and every one of these is for the host only") end
if not me.Exists then return refuse("there is no character right now") end
local named, name = pcall(function() return game.LocalPlayer.PlayerState.Raw.ActiveCharacter.CharacterName:ToString() end)
if not WHO then return refuse('no test character is named, so nothing is written: saved/wax.tests.lua in Wax\'s folder has to return { test_character = "<name>" }') end
if not named or name ~= WHO then
    return refuse(("the character is %s, not %s, so nothing is written"):format(named and tostring(name) or "not readable", WHO))
end
for _, member in ipairs({ "Heal", "Kill", "Teleport", "AddModifier", "RemoveModifier", "Give", "Take" }) do
    local found, value = pcall(function() return me[member] end)
    if not found or type(value) ~= "function" then
        return refuse(member .. " is not a function of game.Me: the running game has the modules from before these were added")
    end
end
if me.Alive ~= true then return refuse("the character is not alive") end

local function say(text, kind, seconds)
    pcall(ui.Notify, text, { title = "Wax test: actions", kind = kind or "info", seconds = seconds or (PAUSE + 3) })
end
local function pause(times) task.wait(PAUSE * (times or 1)) end
local function timed(label, fn, ...)
    local started = now()
    local a, b = fn(...)
    costs[label] = math.floor((now() - started) * 1e6 + 0.5)
    return a, b
end
local function raised(fn, fragment)
    local ok, problem = pcall(fn)
    if ok then return false, "it was not refused" end
    return tostring(problem):find(fragment, 1, true) ~= nil, tostring(problem)
end

-- The game's own objects, found again for each look and never kept.
local function body() return me.Character.Raw end
local function vitals() return body().ActorState end
local function listing(inventory)
    inventory:Refresh()
    local parts = {}
    for i, stack in ipairs(inventory:List()) do parts[i] = ("%d:%s x%d"):format(stack.Slot, stack.Item:lower(), stack.Count) end
    return table.concat(parts, " ")
end
local function game_count(item)
    return body().BackpackInventory:FindItemCountByType({ RowName = FName(item), DataTableName = FName("D_ItemsStatic") }, true)
end
local function enum_globals()
    local found = {}
    for key in pairs(_G) do
        if type(key) == "string" and key:find("^Enum_") then found[key] = true end
    end
    return found
end
local function far(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end

local before = {
    health = me.Health, stamina = me.Stamina, food = me.Food, water = me.Water, oxygen = me.Oxygen, weight = me.Weight,
    place = me.Position, facing = me.Rotation, pack = listing(me.Backpack), bar = listing(me.Hotbar), clock = game.Time.Clock,
    errors = #Wax.guard.errors(), enums = enum_globals(),
}
local added, moved = {}, false      -- what a failed run still has to take back

local steps = {}
local function step(label, telling, fn) steps[#steps + 1] = { label = label, telling = telling, fn = fn } end

step("health", "Health goes down by 100, 40 come back with Heal(40), then all of it with Heal()", function()
    local most = me.MaxHealth
    local low = math.max(1, before.health - 100)
    timed("Health = n", function() me.Health = low end)
    check("assigning Health sets it in the game at once", vitals().Health == low, ("%s, wanted %d"):format(tostring(vitals().Health), low))
    pause()
    local was = vitals().Health
    local healed = timed("Heal(40)", function() return me:Heal(40) end)
    check("Heal(40) gives 40 back and answers the health", healed == math.min(was + 40, most) and vitals().Health == healed,
        ("%s after %s"):format(tostring(healed), tostring(was)))
    pause()
    healed = timed("Heal()", function() return me:Heal() end)
    check("Heal() gives all of it back", healed == most and vitals().Health == most, tostring(healed))
    local refused, text = raised(function() me.Health = 0 end, "Health cannot be set below 1")
    check("Health below 1 is refused", refused and vitals().Health == most, text)
    me.Health = before.health
    check("Health is as it was", vitals().Health == before.health, tostring(vitals().Health))
end)

step("stamina", "Stamina drops to half and is put back", function()
    local half = math.floor(me.MaxStamina / 2)
    timed("Stamina = n", function() me.Stamina = half end)
    check("assigning Stamina sets it in the game at once", vitals().Stamina == half, tostring(vitals().Stamina))
    pause()
    me.Stamina = before.stamina
    check("Stamina is as it was", vitals().Stamina >= before.stamina - 1, tostring(vitals().Stamina))
end)

step("food, water and oxygen", "Food, Water and Oxygen drop to 60 and are put back", function()
    timed("Food = n", function() me.Food = 60 end)
    me.Water, me.Oxygen = 60, 60
    local state = vitals()
    check("assigning Food, Water and Oxygen sets them in the game at once",
        state.FoodLevel == 60 and state.WaterLevel == 60 and state.OxygenLevel == 60,
        ("%s %s %s"):format(tostring(state.FoodLevel), tostring(state.WaterLevel), tostring(state.OxygenLevel)))
    me.Food = 100000
    check("more than the most stops at the most", vitals().FoodLevel == me.MaxFood, tostring(vitals().FoodLevel))
    me.Food = 60
    pause()
    me.Food, me.Water, me.Oxygen = before.food, before.water, before.oxygen
    state = vitals()
    check("Food, Water and Oxygen are as they were",
        state.FoodLevel == before.food and state.WaterLevel == before.water and state.OxygenLevel == before.oxygen,
        ("%s %s %s"):format(tostring(state.FoodLevel), tostring(state.WaterLevel), tostring(state.OxygenLevel)))
end)

step("modifiers", "The modifier Health Regen is put on for 30 seconds, taken off, put on again and taken off by its number", function()
    local had = me:HasModifier("Health_Regen")
    local id = timed("AddModifier", function() return me:AddModifier("Health_Regen", { seconds = 30 }) end)
    added.modifier = id
    check("AddModifier answers the number the game gave it", math.type(id) == "integer", tostring(id))
    check("HasModifier says it is on in the same frame", me:HasModifier("Health_Regen") == true)
    local found = nil
    for _, modifier in ipairs(me:GetModifiers()) do
        if modifier.Id == id then found = modifier end
    end
    check("GetModifiers lists it with its name and its time", found ~= nil and found.Name:lower() == "health_regen" and found.Duration == 30,
        found and ("%s '%s' %s s, %s left"):format(found.Name, tostring(found.DisplayName), tostring(found.Duration), tostring(found.Remaining)) or "not listed")
    pause(1.5)
    if had then
        check("RemoveModifier by name", true, "skipped: the character carried a Health Regen of its own")
    else
        local gone = timed("RemoveModifier", function() return me:RemoveModifier("Health_Regen") end)
        added.modifier = nil
        check("RemoveModifier by name takes it off at once", gone == 1 and me:HasModifier("Health_Regen") == false, tostring(gone))
        pause(0.5)
        id = me:AddModifier("health_regen", 30)
        added.modifier = id
        check("a second one gets a higher number", math.type(id) == "integer" and found ~= nil and id > found.Id, tostring(id))
        pause()
    end
    local gone = me:RemoveModifier({ Name = "Health_Regen", Id = id })
    added.modifier = nil
    check("RemoveModifier with a record takes that one off", gone == 1 and (had or me:HasModifier("Health_Regen") == false), tostring(gone))
    local refused, text = raised(function() me:AddModifier("Helth_Regen", 30) end, "is not a modifier of the game")
    check("a wrong name is refused with the nearest one", refused, text)
end)

step("items", "5 Stone, 3 more and a Stone Pickaxe go into the backpack (open it to look), then they are taken out again", function()
    local stones = me:Count("Stone")
    local given, why = timed("Give 5", function() return me:Give("Stone", 5) end)
    added.stone = (added.stone or 0) + (given or 0)
    check("Give(\"Stone\", 5) answers 5", given == 5 and why == nil, ("%s %s"):format(tostring(given), tostring(why)))
    check("Count follows in the same frame", me:Count("Stone") == stones + 5, tostring(me:Count("Stone")))
    check("the game's own count agrees", game_count("Stone") == me.Backpack:Count("Stone"), tostring(game_count("Stone")))
    given = timed("Give 3 more", function() return me:Give("stone", 3) end)
    added.stone = added.stone + (given or 0)
    local where = me.Backpack:Where("Stone")
    check("3 more go onto the stack that is there", given == 3 and me.Backpack:Count("Stone") == stones + 8 and (stones > 0 or #where == 1),
        ("%s stacks, %s in all"):format(#where, tostring(me.Backpack:Count("Stone"))))
    local picks = me:Count("Stone_Pickaxe")
    given = timed("Give a tool", function() return me:Give("Stone_Pickaxe") end)
    added.pick = (added.pick or 0) + (given or 0)
    local wanted = game.Items:Get("Stone_Pickaxe").MaxDurability
    local newest = nil
    for _, stack in ipairs(me.Backpack:Where("Stone_Pickaxe")) do newest = stack end
    check("a tool comes with the durability the game gives it", given == 1 and newest ~= nil and newest.Durability == wanted,
        newest and ("%s of %s"):format(tostring(newest.Durability), tostring(wanted)) or "not in the backpack")
    pause(2)
    check("the weight followed a moment later", me.Weight > before.weight, ("%s kg, %s before"):format(tostring(me.Weight), tostring(before.weight)))
    local taken = timed("Take 8", function() return me:Take("Stone", 8) end)
    added.stone = added.stone - (taken or 0)
    check("Take(\"Stone\", 8) answers 8", taken == 8 and me:Count("Stone") == stones, ("%s, %s left"):format(tostring(taken), tostring(me:Count("Stone"))))
    taken = me:Take("Stone_Pickaxe")
    added.pick = added.pick - (taken or 0)
    check("Take takes the tool", taken == 1 and me:Count("Stone_Pickaxe") == picks, tostring(taken))
    if stones == 0 then
        local short, said = me:Take("Stone", 3)
        check("Take answers how many there were when there are fewer", short == 0 and type(said) == "string",
            ("%s %s"):format(tostring(short), tostring(said)))
    end
    local full = game.Items:Get("Fiber").MaxStack
    if math.type(full) == "integer" and full > 1 and full <= 500 then
        local held = me.Backpack:Count("Fiber")
        given = timed("Give more than a stack", function() return me:Give("Fiber", full + 3) end)
        added.fiber = given or 0
        local stacks = me.Backpack:Where("Fiber")
        check("more than a stack fills one slot and starts the next",
            given == full + 3 and me.Backpack:Count("Fiber") == held + full + 3
                and (held > 0 or (#stacks == 2 and stacks[1].Count == full and stacks[2].Count == 3)),
            ("%s given, %d stacks, %s in the backpack"):format(tostring(given), #stacks, tostring(me.Backpack:Count("Fiber"))))
        check("the game's own count agrees for them", game_count("Fiber") == me.Backpack:Count("Fiber"), tostring(game_count("Fiber")))
        pause()
        taken = timed("Take more than a stack", function() return me.Backpack:Take("Fiber", full + 3) end)
        added.fiber = added.fiber - (taken or 0)
        check("the backpack's own Take takes them, and leaves the hotbar alone",
            taken == full + 3 and me.Backpack:Count("Fiber") == held, ("%s taken, %s left"):format(tostring(taken), tostring(me.Backpack:Count("Fiber"))))
    end
    check("the backpack and the hotbar are as they were", listing(me.Backpack) == before.pack and listing(me.Hotbar) == before.bar,
        listing(me.Backpack) .. " | " .. listing(me.Hotbar))
    local refused, text = raised(function() me:Give("Stoen") end, "is not an item of the game")
    check("a wrong item is refused with the nearest name", refused, text)
end)

step("teleport", "The character is moved 4 metres ahead and a little up, drops, and is put back where it stood", function()
    local here, facing, health = me.Position, me.Rotation, vitals().Health
    local yaw = math.rad(facing.Yaw)
    local there = { X = here.X + math.cos(yaw) * 400, Y = here.Y + math.sin(yaw) * 400, Z = here.Z + 60 }
    local went = timed("Teleport", function() return me:Teleport(there) end)
    if went ~= true then
        there = { X = here.X, Y = here.Y, Z = here.Z + 150 }
        went = me:Teleport(there)
    end
    moved = went == true
    local at = body():K2_GetActorLocation()
    check("Teleport answers true and the character is there at once", went == true and far(at, there) < 100,
        ("answer %s, %.0f cm from the place asked for"):format(tostring(went), far(at, there)))
    pause()
    local back = me:Teleport(here, facing)
    at = body():K2_GetActorLocation()
    moved = not (back == true)
    check("it is back where it stood", back == true and far(at, here) < 100, ("answer %s, %.0f cm off"):format(tostring(back), far(at, here)))
    check("DistanceTo agrees", me:DistanceTo(here) < 1, tostring(me:DistanceTo(here)))
    -- where the ground ahead lies lower the drop costs health, which is given back
    local hurt = health - vitals().Health
    if hurt > 0 then me.Health = health end
    check("the health a drop cost is given back", vitals().Health >= health, hurt > 0 and ("the drop cost %d"):format(hurt) or "the drop cost none")
end)

step("the time of day", "The clock goes one hour on. It stays there: the game's clock cannot go back within a day", function()
    local hour, minute = game.Time.Hour, game.Time.Minute
    if not CLOCK then
        local refused, text = raised(function() game.Time:Set(0, 0) end, "is earlier than the game's clock")
        check("game.Time:Set", hour == 0 and minute == 0 or refused, "the clock was left alone (WaxActionsClock = false): " .. tostring(text))
        return
    end
    if hour >= 23 then
        check("game.Time:Set", true, "skipped: it is after 23:00, so there is no hour left in this day")
        return
    end
    local done = timed("Time:Set", function() return game.Time:Set(hour + 1, minute) end)
    local total = game.GameState.Raw.TimeOfDay
    check("game.Time:Set moves the clock forward and it reads back at once",
        done == true and game.Time.Hour == hour + 1 and math.floor(total) == (hour + 1) * 60 + minute,
        ("%s, the game's own clock says %s"):format(tostring(game.Time.Clock), tostring(total)))
    local refused, text = raised(function() game.Time:Set(hour, minute) end, "is earlier than the game's clock")
    check("an earlier time is refused in plain words", refused, text)
end)

step("what is switched off", "Kill, the clock's speed and the weather are asked for, and Wax says they are not there yet", function()
    local character = Wax.import("world.character")
    if character.KILL_PLAYERS == false then
        local refused, text = raised(function() me:Kill() end, "Kill is switched off for a player's character")
        check("Kill on a player's character is refused while its switch is off", refused and me.Alive == true, text)
    end
    local refused, text = raised(function() game.Time:SetScale(2) end, "is not in this version of Wax")
    check("game.Time:SetScale says it is not there", refused, text)
    refused, text = raised(function() game.Weather:Start("Conifer", "T3_Conifer_Rain") end, "is not in this version of Wax")
    check("game.Weather:Start says it is not there", refused, text)
end)

if KILL then
    step("kill", "Kill() on the test character. It is dead afterwards and has to respawn", function()
        local character = Wax.import("world.character")
        local switch = character.KILL_PLAYERS
        character.KILL_PLAYERS = true
        local ok, killed = pcall(function() return me:Kill() end)
        character.KILL_PLAYERS = switch
        check("Kill() answers true and the character is dead at once", ok and killed == true and me.Alive == false, tostring(killed))
    end)
end

-- Takes back whatever a step that failed half way left behind.
local function put_back()
    if added.modifier then pcall(function() me:RemoveModifier({ Name = "Health_Regen", Id = added.modifier }) end) end
    if (added.stone or 0) > 0 then pcall(function() me:Take("Stone", added.stone) end) end
    if (added.pick or 0) > 0 then pcall(function() me:Take("Stone_Pickaxe", added.pick) end) end
    if (added.fiber or 0) > 0 then pcall(function() me.Backpack:Take("Fiber", added.fiber) end) end
    if moved then pcall(function() me:Teleport(before.place, before.facing) end) end
    if me.Alive then
        pcall(function() me.Health = before.health end)
        pcall(function() me.Food, me.Water, me.Oxygen = math.max(me.Food, before.food), math.max(me.Water, before.water), math.max(me.Oxygen, before.oxygen) end)
    end
end

run = { running = true, step = "starting", started = os.time() }
rawset(_G, NAME, run)
task.spawn(function()
    local finished, problem = pcall(function()
        for _, one in ipairs(steps) do
            run.step = one.label
            note("actions live: " .. one.label)
            say("Testing " .. one.label .. ": " .. one.telling)
            task.wait(math.min(PAUSE, 1.5))
            local failed_before = 0
            for _, c in ipairs(checks) do failed_before = failed_before + (c.ok and 0 or 1) end
            local ok, raised_text = pcall(one.fn)
            if not ok then check(one.label, false, "raised: " .. tostring(raised_text)) end
            local failed_now = 0
            for _, c in ipairs(checks) do failed_now = failed_now + (c.ok and 0 or 1) end
            if failed_now > failed_before then
                say(one.label .. ": failed", "bad")
            else
                say(one.label .. ": passed", "good")
            end
            task.wait(math.min(PAUSE, 1.5))
        end
    end)
    if not finished then check("the run", false, "raised: " .. tostring(problem)) end
    pcall(put_back)
    local leftover = {}
    for key in pairs(enum_globals()) do
        if not before.enums[key] then leftover[#leftover + 1] = key end
    end
    check("no global of UE4SS's enum reads was left behind", #leftover == 0, table.concat(leftover, " "))
    check("nothing was recorded as an error", #Wax.guard.errors() == before.errors, #Wax.guard.errors() - before.errors)
    check("no name Wax gives hides one of the game's", #Wax.import("engine.easy").clashes() == 0)
    local out = result({ clock_before = before.clock, clock_after = game.Time.Clock, pause = PAUSE })
    run.result, run.running = out, false
    say(("Actions: %d checks passed, %d failed"):format(out.passed, out.failed), out.failed == 0 and "good" or "bad", 8)
end)

return { started = true, steps = #steps, about_seconds = math.floor(#steps * (math.min(PAUSE, 1.5) * 2 + PAUSE * 1.5)),
    next = "send this file again for the result" }
