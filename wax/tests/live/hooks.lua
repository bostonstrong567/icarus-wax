-- Live test of what the game tells by itself: Damaged and Died on game.Me and on a character, the nudge the game's own
-- calls give FoodChanged, WaterChanged, OxygenChanged, WeightChanged and HealthChanged, ModifierAdded and ModifierRemoved,
-- and ItemAdded, ItemRemoved and ItemChanged on game.Me and on the backpack. Every event is made to happen for real
-- and shown in a notification as it arrives: the character goes hungry and drops from a height, is given and taken
-- items, gets a modifier, and a rabbit is put in front of it, may be hit, and dies.
-- Everything is put back: the values, the place, the backpack, the modifier off, the rabbit and what it leaves gone.
-- It writes only for the host and only on the character that saved/wax.tests.lua names as test_character. It refuses anywhere else.
-- Send it with:  node wax/cli/wax.mjs eval --file wax/tests/live/hooks.lua
-- It runs for about a minute and a half in a task. Send the same file again for the result: while it runs it says
-- which step it is at. Before sending, set WaxHooksPause to the seconds a step stays to be seen (2 when not set),
-- WaxHooksRabbit = false to leave the rabbit out, and WaxHooksHits to the seconds the player has to hit it (10).
-- Each step is noted in run\session.log before it is made.

local kept, set = pcall(function() return dofile(Wax.root .. "/saved/wax.tests.lua") end)
local NAME, WHO = "WaxHooksLive", kept and type(set) == "table" and type(set.test_character) == "string" and set.test_character or nil
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
local now = Wax.perf.now
local PAUSE = tonumber(rawget(_G, "WaxHooksPause")) or 2
local RABBIT = rawget(_G, "WaxHooksRabbit") ~= false
local HITS = tonumber(rawget(_G, "WaxHooksHits")) or 10

local checks, facts = {}, {}
local function check(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail } end
local function result(extra)
    local passed, failed, details = 0, {}, {}
    for _, c in ipairs(checks) do
        if c.ok then passed = passed + 1 else failed[#failed + 1] = c.name .. " :: " .. tostring(c.detail) end
        details[#details + 1] = (c.ok and "ok   " or "FAIL ") .. c.name .. (c.detail ~= nil and ("  [" .. tostring(c.detail):sub(1, 260) .. "]") or "")
    end
    local out = { passed = passed, failed = #failed, failures = failed, details = details, facts = facts }
    for key, value in pairs(extra or {}) do out[key] = value end
    return out
end
local function refuse(why)
    check("the test may run here", false, why)
    return result()
end

local me = game and rawget(game, "Me")
if not me or not rawget(game, "Items") then return refuse("game.Me or game.Items is not there") end
local hooks_loaded, hooks = pcall(Wax.import, "engine.hooks")
if not hooks_loaded then return refuse("engine.hooks does not load: " .. tostring(hooks)) end
if not game.InProspect then return refuse("this is not a prospect") end
if not game.IsHost then return refuse("this player is not the host, and the test makes its events with what only the host can do") end
if not me.Exists then return refuse("there is no character right now") end
local named, name = pcall(function() return game.LocalPlayer.PlayerState.Raw.ActiveCharacter.CharacterName:ToString() end)
if not WHO then return refuse('no test character is named, so nothing is written: saved/wax.tests.lua in Wax\'s folder has to return { test_character = "<name>" }') end
if not named or name ~= WHO then
    return refuse(("the character is %s, not %s, so nothing is written"):format(named and tostring(name) or "not readable", WHO))
end
for _, member in ipairs({ "Damaged", "Died", "ModifierAdded", "ModifierRemoved", "ItemAdded", "ItemRemoved", "ItemChanged" }) do
    local found, value = pcall(function() return me[member] end)
    if not found or type(value) ~= "table" or type(value.Connect) ~= "function" then
        return refuse(member .. " is not a signal of game.Me: the running game has the modules from before these were added")
    end
end
if me.Alive ~= true then return refuse("the character is not alive") end

local character_module, items_module = Wax.import("world.character"), Wax.import("world.items")
local instance = Wax.import("engine.instance")

local function say(text, kind, seconds)
    pcall(ui.Notify, text, { title = "Wax test: events", kind = kind or "info", seconds = seconds or (PAUSE + 3) })
end
-- An event as it arrives.
local function heard(text) pcall(ui.Notify, text, { title = "The game told Wax", kind = "good", seconds = 4 }) end
local function pause(times) task.wait(PAUSE * (times or 1)) end
-- Waits until done() is true, at most `seconds`. Answers whether it was.
local function until_true(seconds, done)
    local started = now()
    while now() - started < seconds do
        if done() then return true end
        task.wait(0.05)
    end
    return done()
end
local function body() return me.Character.Raw end
local function vitals() return body().ActorState end
local function listing(inventory)
    inventory:Refresh()
    local parts = {}
    for i, stack in ipairs(inventory:List()) do parts[i] = ("%d:%s x%d"):format(stack.Slot, stack.Item:lower(), stack.Count) end
    return table.concat(parts, " ")
end
local function enum_globals()
    local found = {}
    for key in pairs(_G) do
        if type(key) == "string" and key:find("^Enum_") then found[key] = true end
    end
    return found
end
local function class_of(who)
    local ok, text = pcall(function() return who.ClassName end)
    return ok and text or "something that is gone"
end
local function frame() return sched.stats.frame end

local before = {
    health = me.Health, stamina = me.Stamina, food = me.Food, water = me.Water, oxygen = me.Oxygen, place = me.Position,
    facing = me.Rotation, pack = listing(me.Backpack), bar = listing(me.Hotbar), errors = #Wax.guard.errors(), enums = enum_globals(),
    hooked = hooks.stats().registered, stones = me:Count("Stone"), picks = me:Count("Stone_Pickaxe"),
}
local connections, undo = {}, {}
local function on(signal, fn)
    local connection = signal:Connect(fn)
    connections[#connections + 1] = connection
    return connection
end
local function drop_connections()
    for i = #connections, 1, -1 do pcall(function() connections[i]:Disconnect() end) end
    connections = {}
end

-- WaxHooksOnly = "a rabbit" runs that one step.
local ONLY = rawget(_G, "WaxHooksOnly")
local steps = {}
local function step(label, telling, fn)
    if ONLY == nil or ONLY == label then steps[#steps + 1] = { label = label, telling = telling, fn = fn } end
end

step("hunger", "Food goes to 0, so the character starves a little. Each loss of health is told by the game itself", function()
    local hits, own, changes = {}, {}, {}
    on(me.Damaged, function(who, amount, info)
        hits[#hits + 1] = { who = who, amount = amount, info = info, frame = frame(), health = vitals().Health }
        heard(("Damaged: %s lost %s health, %s left"):format(WHO, tostring(amount), tostring(info.Health)))
    end)
    on(me.Character.Damaged, function(who, amount) own[#own + 1] = { who = who, amount = amount } end)
    on(me.HealthChanged, function(value, previous) changes[#changes + 1] = { value = value, previous = previous, frame = frame() } end)
    check("the first handler hooks the game's own call for damage", character_module.stats().told.hooked == true)
    undo.food = true
    me.Food = 0
    local came = until_true(9, function() return #hits >= 2 end)
    me.Food = before.food
    undo.food = nil
    check("going hungry is told as damage, twice within nine seconds", came, #hits .. " events")
    local first = hits[1]
    if first then
        check("Damaged hands over the character, a number above 0 and what the game knows",
            rawequal(first.who, me.Character) and type(first.amount) == "number" and first.amount > 0 and type(first.info) == "table",
            ("%s lost %s"):format(class_of(first.who), tostring(first.amount)))
        check("info.Health is the health the game had after the hit", first.info.Health == first.health,
            ("%s told, %s read in the handler"):format(tostring(first.info.Health), tostring(first.health)))
        check("for hunger the game names the character itself as what did it", rawequal(first.info.Causer, me.Character),
            ("Causer %s, Instigator %s, Applied %s, Total %s, Radial %s, Stealth %s"):format(class_of(first.info.Causer or {}),
                first.info.Instigator and class_of(first.info.Instigator) or "none", tostring(first.info.Applied),
                tostring(first.info.Total), tostring(first.info.Radial), tostring(first.info.Stealth)))
        check("the character's own Damaged tells the same", #own == #hits and rawequal(own[1].who, me.Character), #own .. " events")
        local same_frame = false
        for _, change in ipairs(changes) do same_frame = same_frame or change.frame == first.frame end
        check("HealthChanged tells in the frame of the hit", same_frame,
            changes[1] and ("first change %s -> %s"):format(tostring(changes[1].previous), tostring(changes[1].value)) or "no change told")
    end
    pause()
    me.Health = before.health
    drop_connections()
    check("with the last handler gone the hook is let go", character_module.stats().told.hooked == false)
end)

step("a fall", "The character is lifted six metres and drops. The damage of the landing is told", function()
    local hits = {}
    on(me.Damaged, function(_, amount, info)
        hits[#hits + 1] = { amount = amount, info = info }
        heard(("Damaged: the landing cost %s health, %s left"):format(tostring(amount), tostring(info.Health)))
    end)
    local here, facing = me.Position, me.Rotation
    undo.place = { here, facing }
    local went = me:Teleport({ X = here.X, Y = here.Y, Z = here.Z + 600 }, facing)
    local came = went == true and until_true(5, function() return #hits >= 1 end)
    check("the landing is told as damage", came, went == true and (#hits .. " events") or "the game did not move the character")
    if hits[1] then facts.fall = ("%s damage, health %s afterwards"):format(tostring(hits[1].amount), tostring(hits[1].info.Health)) end
    pause()
    me:Teleport(here, facing)
    undo.place = nil
    if vitals().Health < before.health then me.Health = before.health end
    drop_connections()
end)

step("food, water and oxygen", "Each drops by 30 and is put back. The game says so itself, so it is told at once", function()
    local got, sent = {}, {}
    local function follow(label, signal)
        on(signal, function(value, previous)
            got[label] = got[label] or { value = value, previous = previous, after = now() - (sent[label] or now()) }
            if not got[label].shown then
                got[label].shown = true
                heard(("%sChanged: %s, it was %s"):format(label, tostring(value), tostring(previous)))
            end
        end)
    end
    follow("Food", me.FoodChanged)
    follow("Water", me.WaterChanged)
    follow("Oxygen", me.OxygenChanged)
    task.wait(0.3)
    undo.vitals = true
    for _, label in ipairs({ "Food", "Water", "Oxygen" }) do
        local wanted = math.max(0, me[label] - 30)
        sent[label] = now()
        me[label] = wanted
        local came = until_true(1.5, function() return got[label] ~= nil and got[label].value == wanted end)
        local told = got[label]
        check(label .. "Changed tells the new value", came, told and ("%s, it was %s"):format(tostring(told.value), tostring(told.previous)) or "nothing told")
        if told then
            facts[label .. "_ms"] = math.floor(told.after * 1000 + 0.5)
            check(label .. "Changed came within a quarter of a second, where looking would take up to two",
                told.after < 0.25, ("%d ms"):format(facts[label .. "_ms"]))
        end
        task.wait(0.6)
    end
    pause()
    me.Food, me.Water, me.Oxygen = before.food, before.water, before.oxygen
    undo.vitals = nil
    drop_connections()
end)

step("items", "5 Stone and a Stone Pickaxe go into the backpack and come out again. Open it to look: each is told", function()
    local added, removed, changed, pack_added, weights = {}, {}, {}, {}, {}
    on(me.ItemAdded, function(item, amount, stack)
        added[#added + 1] = { item = item, amount = amount, stack = stack, count = me:Count(item) }
        heard(("ItemAdded: %s x%s into the %s"):format(tostring(item), tostring(amount), stack and tostring(stack.Inventory) or "?"))
    end)
    on(me.ItemRemoved, function(item, amount, stack)
        removed[#removed + 1] = { item = item, amount = amount, stack = stack }
        heard(("ItemRemoved: %s x%s out of the %s"):format(tostring(item), tostring(amount), stack and tostring(stack.Inventory) or "?"))
    end)
    on(me.ItemChanged, function(stack, previous) changed[#changed + 1] = { stack = stack, previous = previous } end)
    on(me.Backpack.ItemAdded, function(item, amount) pack_added[#pack_added + 1] = { item = item, amount = amount } end)
    on(me.WeightChanged, function(value, previous)
        weights[#weights + 1] = { value = value, previous = previous }
        if #weights == 1 then heard(("WeightChanged: %s kg, it was %s"):format(tostring(value), tostring(previous))) end
    end)
    check("listening to what the character carries hooks the game's item events", items_module.stats().told == true,
        ("%s inventories listened to"):format(tostring(items_module.stats().listened)))
    local stones = me:Count("Stone")
    undo.stone = 5
    local given = me:Give("Stone", 5)
    undo.stone = given or 0
    local came = until_true(1.5, function() return #added >= 1 end)
    local first = added[1]
    check("giving 5 Stone is told once, as 5 Stone", came and first.item:lower() == "stone" and first.amount == 5 and #added == 1,
        first and ("%s x%s, %d events"):format(tostring(first.item), tostring(first.amount), #added) or "nothing told")
    if first then
        check("the stack that is handed over names its inventory and its slot",
            type(first.stack) == "table" and first.stack.Inventory == "Backpack" and math.type(first.stack.Slot) == "integer"
                and first.stack.Item:lower() == "stone",
            first.stack and ("%s slot %s x%s"):format(tostring(first.stack.Inventory), tostring(first.stack.Slot), tostring(first.stack.Count)) or "no stack")
        check("Count is right inside the handler", first.count == stones + 5, tostring(first.count))
    end
    check("the backpack's own ItemAdded tells the same", pack_added[1] ~= nil and pack_added[1].amount == 5, #pack_added .. " events")
    check("ItemChanged tells of the slot, with nothing before when it was empty", changed[1] ~= nil and changed[1].stack ~= nil
        and (stones > 0 or changed[1].previous == nil), #changed .. " events")
    pause()
    undo.pick = 1
    local tool = me:Give("Stone_Pickaxe")
    undo.pick = tool or 0
    came = until_true(1.5, function() return #added >= 2 end)
    check("a tool that is given is told", came and added[2].item:lower() == "stone_pickaxe" and added[2].amount == 1
        and added[2].stack.Durability ~= nil, added[2] and ("%s, durability %s"):format(tostring(added[2].item), tostring(added[2].stack.Durability)) or "nothing told")
    check("the weight the game works out a moment later is told too", until_true(2, function() return #weights >= 1 end), #weights .. " events")
    pause()
    local taken = me:Take("Stone", 5)
    undo.stone = undo.stone - (taken or 0)
    came = until_true(1.5, function() return #removed >= 1 end)
    check("taking 5 Stone is told once, as 5 Stone", came and removed[1].item:lower() == "stone" and removed[1].amount == 5 and #removed == 1,
        removed[1] and ("%s x%s, %d events"):format(tostring(removed[1].item), tostring(removed[1].amount), #removed) or "nothing told")
    taken = me:Take("Stone_Pickaxe")
    undo.pick = undo.pick - (taken or 0)
    came = until_true(1.5, function() return #removed >= 2 end)
    check("taking the tool is told", came and removed[2].item:lower() == "stone_pickaxe", #removed .. " events")
    pause(0.5)
    -- another mod or the player may move things meanwhile, so only what this step gave is counted
    local ours = 0
    for _, one in ipairs(added) do
        if one.item:lower() == "stone" or one.item:lower() == "stone_pickaxe" then ours = ours + 1 end
    end
    check("nothing else was told as added of what this step gave", ours == 2, ("%d events, %d of them Stone or a Stone Pickaxe"):format(#added, ours))
    check("the Stone and the Stone Pickaxe are out again", me:Count("Stone") == stones and me:Count("Stone_Pickaxe") == before.picks,
        listing(me.Backpack) .. " | " .. listing(me.Hotbar))
    drop_connections()
    check("with no handler left no inventory is listened to", items_module.stats().listened == 0, tostring(items_module.stats().listened))
end)

step("modifiers", "The modifier Health Regen is put on and taken off. Both are told", function()
    if type(me.AddModifier) ~= "function" then
        check("ModifierAdded and ModifierRemoved", true, "skipped: world.stats is not started in this game")
        return
    end
    local came, went = {}, {}
    on(me.ModifierAdded, function(modifier)
        came[#came + 1] = modifier
        heard(("ModifierAdded: %s"):format(tostring(modifier.DisplayName or modifier.Name)))
    end)
    on(me.ModifierRemoved, function(modifier)
        went[#went + 1] = modifier
        heard(("ModifierRemoved: %s"):format(tostring(modifier.DisplayName or modifier.Name)))
    end)
    task.wait(0.6)
    local id = me:AddModifier("Health_Regen", 30)
    undo.modifier = id
    local told = until_true(2, function() return #came >= 1 end)
    check("ModifierAdded tells the modifier with its name and its number",
        told and came[1].Name:lower() == "health_regen" and came[1].Id == id and came[1].Duration == 30,
        came[1] and ("%s '%s' #%s, %s s"):format(tostring(came[1].Name), tostring(came[1].DisplayName), tostring(came[1].Id), tostring(came[1].Duration)) or "nothing told")
    pause()
    me:RemoveModifier({ Name = "Health_Regen", Id = id })
    undo.modifier = nil
    told = until_true(2, function() return #went >= 1 end)
    check("ModifierRemoved tells the one that went", told and went[1].Id == id, went[1] and tostring(went[1].Name) or "nothing told")
    drop_connections()
end)

local function valid(object) return object ~= nil and type(object) == "userdata" and object:IsValid() end

if RABBIT then
    step("a rabbit", "A rabbit is put five metres ahead and dropped from a height. Then it is held still for you to hit, and then it dies", function()
        local pawn = body()
        local at, facing = pawn:K2_GetActorLocation(), me.Rotation
        local yaw = math.rad(facing.Yaw)
        local wanted = { X = at.X + math.cos(yaw) * 500, Y = at.Y + math.sin(yaw) * 500, Z = at.Z + 100 }
        local nav = StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
        local found = {}
        if not valid(nav) or not nav:K2_ProjectPointToNavigation(pawn, wanted, found, nil, nil, { X = 500, Y = 500, Z = 100000 }) then
            check("a rabbit", true, "skipped: the game found no ground five metres ahead")
            return
        end
        local transform = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = found.X, Y = found.Y, Z = found.Z + 150 },
            Scale3D = { X = 1, Y = 1, Z = 1 } }
        local spawned = game:Library("IcarusAIBlueprintFunctionLibrary").Raw:SpawnNewAI(pawn,
            { RowName = FName("Rabbit"), DataTableName = FName("D_AISetup") },
            { RowName = FName("None"), DataTableName = FName("D_EpicCreatures") }, transform, 1, 2, nil, nil, -1)
        if not valid(spawned) then
            check("a rabbit", false, "the game spawned nothing")
            return
        end
        local rabbit = instance.wrap(spawned)
        undo.rabbit = rabbit
        task.wait(1)
        local hits, deaths, every = {}, {}, {}
        local hit_connection = rabbit.Damaged:Connect(function(who, amount, info)
            hits[#hits + 1] = { who = who, amount = amount, info = info }
            heard(("Damaged: the rabbit lost %s health to %s, %s left"):format(tostring(amount),
                info.Causer and class_of(info.Causer) or "nobody", tostring(info.Health)))
        end)
        local death_connection = rabbit.Died:Connect(function(who, info)
            deaths[#deaths + 1] = { who = who, info = info }
            heard(("Died: the rabbit%s"):format(info.Killer and (", killed by " .. class_of(info.Killer)) or ""))
        end)
        on(character_module.events.Died, function(who) every[#every + 1] = who end)
        check("a character put into the world has its own Damaged and Died", rabbit.Health ~= nil and rabbit.Alive == true,
            ("%s, health %s"):format(class_of(rabbit), tostring(rabbit.Health)))
        -- whether an animal is hurt by a fall is the game's business: what is told of it is noted, not judged
        say("The rabbit is lifted eight metres and drops")
        local stood = rabbit.Position
        local lifted = rabbit:Teleport({ X = stood.X, Y = stood.Y, Z = stood.Z + 800 })
        until_true(4, function() return #hits >= 1 or #deaths >= 1 end)
        task.wait(0.5)
        facts.rabbit_drop = ("lifted %s, %d hits told, %d deaths told%s"):format(tostring(lifted), #hits, #deaths,
            hits[1] and (", the first for %s by %s"):format(tostring(hits[1].amount), hits[1].info.Causer and class_of(hits[1].info.Causer) or "nobody") or "")
        if #deaths == 0 then
            pcall(function() rabbit.Raw:FreezeNPC() end)
            say(("Hit the rabbit: every hit is told here for %d seconds"):format(HITS))
            until_true(HITS, function() return #deaths >= 1 end)
        end
        facts.rabbit_hits = #hits
        if hits[1] then
            local info = hits[1].info
            facts.rabbit_hit = ("%s damage, Causer %s, Instigator %s, Applied %s, Total %s, Stealth %s"):format(tostring(hits[1].amount),
                info.Causer and class_of(info.Causer) or "none", info.Instigator and class_of(info.Instigator) or "none",
                tostring(info.Applied), tostring(info.Total), tostring(info.Stealth))
            check("a hit on the rabbit is told with the rabbit and a number above 0", rawequal(hits[1].who, rabbit) and hits[1].amount > 0, facts.rabbit_hit)
        end
        local by_player = #deaths >= 1
        if not by_player then
            local killed = rabbit:Kill()
            check("Kill() answers true", killed == true, tostring(killed))
        end
        local told = until_true(2, function() return #deaths >= 1 end)
        check("the rabbit's death is told, once", told and #deaths == 1 and rawequal(deaths[1].who, rabbit), #deaths .. " events")
        if deaths[1] then
            facts.rabbit_death = ("Killer %s, Damage %s"):format(deaths[1].info.Killer and class_of(deaths[1].info.Killer) or "none",
                tostring(deaths[1].info.Damage))
            if by_player then check("a death by a hit names who did it", deaths[1].info.Killer ~= nil, facts.rabbit_death) end
        end
        check("the death is told on character.events too", #every == 1 and rawequal(every[1], rabbit), #every .. " events")
        pause()
        local place = nil
        pcall(function() place = rabbit.Position end)
        pcall(function() rabbit.Raw:SetLifeSpan(0.1) end)
        local gone = until_true(3, function() return not rabbit:IsValid() end)
        undo.rabbit = nil
        check("the rabbit is out of the world again", gone)
        check("the handlers of a character that left are disconnected by themselves",
            until_true(1.5, function() return hit_connection.Connected == false and death_connection.Connected == false end))
        drop_connections()
        -- a killed animal leaves a corpse ten seconds later, unless it left the world first
        task.wait(10.5)
        local corpses, left = FindAllOf("IcarusCorpse"), 0
        for index = 1, corpses and #corpses or 0 do
            pcall(function()
                local corpse = corpses[index]
                if not valid(corpse) or corpse.bActorIsBeingDestroyed == true or not place then return end
                local lies = corpse:K2_GetActorLocation()
                if math.sqrt((lies.X - place.X) ^ 2 + (lies.Y - place.Y) ^ 2 + (lies.Z - place.Z) ^ 2) <= 500 then
                    corpse:SetLifeSpan(0.1)
                    left = left + 1
                end
            end)
        end
        facts.corpses_removed = left
    end)
end

-- Takes back whatever a step that failed half way left behind.
local function put_back()
    drop_connections()
    if undo.modifier then pcall(function() me:RemoveModifier({ Name = "Health_Regen", Id = undo.modifier }) end) end
    if (undo.stone or 0) > 0 then pcall(function() me:Take("Stone", undo.stone) end) end
    if (undo.pick or 0) > 0 then pcall(function() me:Take("Stone_Pickaxe", undo.pick) end) end
    if undo.place then pcall(function() me:Teleport(undo.place[1], undo.place[2]) end) end
    if undo.rabbit then pcall(function() undo.rabbit.Raw:SetLifeSpan(0.1) end) end
    if me.Alive then
        pcall(function() me.Health = math.max(me.Health, before.health) end)
        pcall(function() me.Food, me.Water, me.Oxygen = math.max(me.Food, before.food), math.max(me.Water, before.water), math.max(me.Oxygen, before.oxygen) end)
    end
end

run = { running = true, step = "starting", started = os.time() }
rawset(_G, NAME, run)
task.spawn(function()
    local finished, problem = pcall(function()
        for _, one in ipairs(steps) do
            run.step = one.label
            note("hooks live: " .. one.label)
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
    pcall(put_back)
    task.wait(0.6)
    local told = character_module.stats().told
    check("nothing is listened to or waited for once every handler is gone", told.listening == 0 and told.hooked == false and told.waited_for == 0,
        ("listening %s, hooked %s, waited for %s"):format(tostring(told.listening), tostring(told.hooked), tostring(told.waited_for)))
    local stats, costs = hooks.stats(), {}
    for path, hook in pairs(stats.hooks) do
        costs[path:match("([%w_]+)$")] = ("%d calls, %.1f us each, %s, %d listening"):format(hook.calls, hook.us, hook.reach, hook.listeners)
    end
    facts.hooks = costs
    facts.telling = ("%d told in %d frames, %.1f us a frame that told, %d dropped"):format(stats.delivered, stats.flushes, stats.tell_us, stats.dropped)
    facts.registered = ("%d functions hooked now, %d before the run"):format(stats.registered, before.hooked)
    facts.stepped_by_the_frame_loop = stats.driven
    -- Other mods and other parts of Wax read enums all the time, so the globals UE4SS leaves are looked for right
    -- where this package reads one: inside the game's own call when a slot changes, with nothing else running between.
    local clean = pcall(function()
        local connection = me.ItemChanged:Connect(function() end)
        for key in pairs(enum_globals()) do rawset(_G, key, nil) end
        local given = me:Give("Stone", 1)
        local after_give = next(enum_globals())
        local taken = given == 1 and me:Take("Stone", 1) or 0
        local after_take = next(enum_globals())
        connection:Disconnect()
        check("reading a slot inside the game's call leaves no global of UE4SS's enum reads behind",
            given == 1 and taken == 1 and after_give == nil and after_take == nil,
            ("given %s, taken %s, left %s %s"):format(tostring(given), tostring(taken), tostring(after_give), tostring(after_take)))
    end)
    if not clean then check("reading a slot inside the game's call leaves no global of UE4SS's enum reads behind", false, "the look raised") end
    local leftover = {}
    for key in pairs(enum_globals()) do
        if not before.enums[key] then leftover[#leftover + 1] = key end
    end
    facts.enum_globals_other_code_left_meanwhile = table.concat(leftover, " ")
    check("nothing was recorded as an error", #Wax.guard.errors() == before.errors, #Wax.guard.errors() - before.errors)
    check("no name Wax gives hides one of the game's", #Wax.import("engine.easy").clashes() == 0)
    check("the character is as it was", me.Alive == true and me.Health >= before.health and me.Food >= before.food - 3
        and me.Water >= before.water - 3 and me.Oxygen >= before.oxygen - 3 and me:Count("Stone") == before.stones
        and me:Count("Stone_Pickaxe") == before.picks,
        ("health %s food %s water %s oxygen %s, %s Stone and %s Stone Pickaxe as before | %s"):format(tostring(me.Health), tostring(me.Food),
            tostring(me.Water), tostring(me.Oxygen), tostring(me:Count("Stone")), tostring(me:Count("Stone_Pickaxe")), listing(me.Backpack)))
    local out = result({ pause = PAUSE })
    run.result, run.running = out, false
    say(("Events: %d checks passed, %d failed"):format(out.passed, out.failed), out.failed == 0 and "good" or "bad", 8)
end)

return { started = true, steps = #steps, next = "send this file again for the result" }
