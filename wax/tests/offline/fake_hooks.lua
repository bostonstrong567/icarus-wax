-- UE4SS's RegisterHook and the game's own calls of the functions Wax listens to, as a stand-in on top of fake_world.lua,
-- fake_values.lua and, for inventories, fake_items.lua. A callback is handed the object as a value with :get() and so is
-- every value of the call, as UE4SS does it. It is as unkind as the game and UE4SS:
--   a hook is never taken off again, so every registration stays and is counted (`registrations`);
--   a function the game does not have raises; a callback that returns a value is counted in `returned`, because
--   UE4SS would hand that value to the game as the function's answer;
--   damage is told after the health is lower and the last damage packet is written, as it was seen on 2026-10-07
--   (.research\easy-api\probe-results.md 2.4).
--   local hooks = dofile("wax/tests/offline/fake_hooks.lua")
--   hooks.install(world, values, kit, items)
--   hooks.raise(path, object, ...)                 the game calls a hooked function
--   hooks.damage(who, amount, { by = other, late = true })       hooks.vital(who, "Food", 250)
--   hooks.slot(inv, position, "added", "changed")  hooks.weight(who, inv)

local hooks = { registrations = 0, raised = 0, returned = 0, unregistered = 0 }
---@type any
local world, values, kit, items = nil, nil, nil, nil
local callbacks = {}        -- path -> every callback registered for it, oldest first
local carriers = setmetatable({}, { __mode = "k" })     -- character actor -> its inventory component

hooks.DAMAGED = "/Script/Icarus.ActorState:Multicast_OnDamaged"
hooks.VITALS = {
    Food = { "/Script/Icarus.IcarusPlayerCharacterSurvival:OnFoodLevelUpdated", "FoodLevel" },
    Water = { "/Script/Icarus.IcarusPlayerCharacterSurvival:OnWaterLevelUpdated", "WaterLevel" },
    Oxygen = { "/Script/Icarus.IcarusPlayerCharacterSurvival:OnOxygenLevelUpdated", "OxygenLevel" },
}
hooks.WEIGHT = "/Script/Icarus.InventoryComponent:WeightUpdatedDelagate"
hooks.SLOT = {
    added = "/Script/Icarus.InventoryComponent:ItemAddedDelagate",
    removed = "/Script/Icarus.InventoryComponent:ItemRemovedDelagate",
    changed = "/Script/Icarus.InventoryComponent:ItemChangedDelegate",
}
-- what the game has to listen to. Take a path out to stand for a game update that renamed the function.
hooks.FUNCTIONS = {
    [hooks.DAMAGED] = true, [hooks.WEIGHT] = true, [hooks.SLOT.added] = true, [hooks.SLOT.removed] = true,
    [hooks.SLOT.changed] = true, [hooks.VITALS.Food[1]] = true, [hooks.VITALS.Water[1]] = true, [hooks.VITALS.Oxygen[1]] = true,
    ["/Script/Icarus.IcarusCharacter:OnCharacterDamaged"] = true, ["/Script/Engine.Actor:ReceiveTick"] = true,
}

local function handed(value)
    if value == nil then value = world.INVALID end
    return { get = function() return value end, type = function() return "RemoteUnrealParam" end }
end

-- The game calls a hooked function on `object` with these values. Returns how many callbacks ran.
function hooks.raise(path, object, ...)
    local list = callbacks[path]
    if not list then return 0 end
    hooks.raised = hooks.raised + 1
    local given, n = { ... }, select("#", ...)
    local params = {}
    for i = 1, n do params[i] = handed(given[i]) end
    for i = 1, #list do
        if list[i](handed(object), table.unpack(params, 1, n)) ~= nil then hooks.returned = hooks.returned + 1 end
    end
    return #list
end

-- How many times UE4SS was asked to hook this function.
function hooks.count(path) return callbacks[path] and #callbacks[path] or 0 end

-- Damage as the game deals it: the health is lower and the packet written before the call that tells of it.
-- options.by is the character that did it (the damaged one itself when left out, as for hunger and a fall),
-- options.instigator a controller, options.late = true leaves a character at no health alive for now.
function hooks.damage(who, amount, options)
    options = options or {}
    local store = who.state_store
    local applied = math.min(amount, store.Health)
    store.Health = store.Health - applied
    local causer = options.by and options.by.actor or who.actor
    store.LastDamagePacket = { TotalDamage = amount, AppliedDamage = applied, bWasRadialDamage = options.radial == true,
        bIsStealthHit = options.stealth == true, DamageCauser = causer, EventInstigator = options.instigator or world.INVALID }
    if store.Health <= 0 and not options.late then store.CurrentAliveState = 1 end
    return hooks.raise(hooks.DAMAGED, who.state, amount, {}, options.instigator, causer)
end

-- The game changed food, water or oxygen of a player's character and tells the character.
function hooks.vital(who, name, value)
    local spec = hooks.VITALS[name]
    who.state_store[spec[2]] = value
    return hooks.raise(spec[1], who.actor, value)
end

-- The component of a character that the game tells of its inventories.
function hooks.carrier(who)
    local component = carriers[who.actor]
    if not component then
        component = world.component(nil, "InventoryComponent", {})
        rawset(component, "__outer", who.actor)
        carriers[who.actor] = component
    end
    return component
end

-- The game says a slot (counted from 1 here) of an inventory changed, in each of the ways named: "added", "removed", "changed".
function hooks.slot(inv, position, ...)
    local owner = rawget(inv.object, "__outer")
    local component = owner and hooks.carrier({ actor = owner }) or world.INVALID
    local ran = 0
    for _, way in ipairs({ ... }) do
        ran = ran + hooks.raise(hooks.SLOT[way] or error("fake_hooks: a slot is added, removed or changed, not " .. tostring(way), 2),
            component, inv.object, position - 1)
    end
    return ran
end

-- The game's next tick after what a character carries changed: the weights follow, and the inventory's new one is told.
function hooks.weight(who, inv)
    items.settle(who)
    return hooks.raise(hooks.WEIGHT, hooks.carrier(who), inv.store.CurrentWeight)
end

-- Call after the stand-ins it stands on are installed. `the_items` is fake_items when a suite has it.
function hooks.install(the_world, the_values, the_kit, the_items)
    world, values, kit, items = the_world, the_values, the_kit, the_items
    rawset(_G, "RegisterHook", function(path, callback, after)
        if type(path) ~= "string" or type(callback) ~= "function" then error("RegisterHook expects a path and a function", 2) end
        if not hooks.FUNCTIONS[path] then
            error(("[RegisterHook] Couldn't find the function '%s'"):format(path), 0)
        end
        if after ~= nil then error("fake_hooks: a second callback was never tried in the game", 2) end
        hooks.registrations = hooks.registrations + 1
        local list = callbacks[path] or {}
        callbacks[path] = list
        list[#list + 1] = callback
        return hooks.registrations * 2 - 1, hooks.registrations * 2
    end)
    rawset(_G, "UnregisterHook", function() hooks.unregistered = hooks.unregistered + 1 end)
    return hooks
end

return hooks
