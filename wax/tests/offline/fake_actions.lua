-- What the game lets the host do to a character and to the session, as a stand-in on top of fake_world.lua and
-- fake_values.lua, and of fake_items.lua and fake_session.lua when a suite has them: the setters of the everyday values,
-- Kill, the teleport, placing and consuming items, modifiers on and off, and the clock. Each takes its values as UE4SS
-- hands them over, and answers as the game did on 2026-10-07 (.research\easy-api\probe-results.md 2.5 to 2.7 and
-- .research\creatures\probe-results.md). It is as unkind as the game:
--   the table for PlacedLocation makes every value after it arrive one early (fake_values does that), so the game
--   reads it as DropItemAtOverFlow = true; an item that finds no slot then lies on the ground, counted in `dropped`;
--   CanAdd answers for the kind of item, whatever the slot holds; a weight follows a tick later (items.settle);
--   the setters stop at the most a character can have; a time earlier than the clock's is the next day (`days`).
-- A call with values that were never tried in the game is counted in `untried`, with a line in `log`.
--   local actions = dofile("wax/tests/offline/fake_actions.lua")
--   actions.install(world, values, kit, { items = items, session = session, more = more })
--   actions.host(true)                 this player hosts the world the viewport shows (false: a client)
--   actions.prospect(place)            the clock of a prospect made by fake_session can be set
--   actions.blocked = true             the next teleports find no room and answer false
--   inv.accepts = function(item) ...   an inventory that only takes some kinds of item

local actions = { blocked = false }
---@type any
local world, values, kit, items, session, more = nil, nil, nil, nil, nil, nil
local clocks = setmetatable({}, { __mode = "k" })
local uid = 17

local COUNTERS = { "untried", "dropped", "days", "player_kills" }

-- Every counter back to zero. What was installed stays.
function actions.reset()
    for _, name in ipairs(COUNTERS) do actions[name] = 0 end
    actions.calls, actions.log, actions.last_place = {}, {}, nil
end
actions.reset()

local function called(name) actions.calls[name] = (actions.calls[name] or 0) + 1 end

local function untried(what)
    actions.untried = actions.untried + 1
    actions.log[#actions.log + 1] = what
end

local INT, FLOAT, BOOL, OBJECT = "IntProperty", "FloatProperty", "BoolProperty", "ObjectProperty"

local function add(class_name, functions)
    local class = kit.classes[class_name]
    if not class then error("fake_actions: the stand-in has no class " .. class_name, 2) end
    local held = rawget(class, "__functions")
    for name, def in pairs(functions) do held[name] = def end
end

-- Makes this player the host of the world the viewport shows, or a client in it.
function actions.host(on)
    local level = rawget(world.engine.GameViewport, "__props").World
    local held = rawget(level, "__props")
    if on == false then
        held.AuthorityGameMode = nil
    elseif held.AuthorityGameMode == nil then
        held.AuthorityGameMode = world.object("GameMode_Stand_In", {})
    end
end

function actions.prospect(place)
    clocks[place.clock] = place
    return place
end

-- ---------------------------------------------------------------------------------------------------- a character

local function setter(name, property, most_property, least)
    return { { "NewValue", INT }, call = function(self, args)
        called(name)
        local store = values.of(self)
        local value, most = args.NewValue, store[most_property]
        if value < least then untried(("%s(%d): below %d was never tried"):format(name, value, least)) end
        if value > most then value = most end
        store[property] = value
    end }
end

local function install_character()
    add("ActorState", {
        SetHealth = setter("SetHealth", "Health", "MaxHealth", 1),
        AddHealth = { { "Amount", INT }, call = function(self, args)
            called("AddHealth")
            local store = values.of(self)
            local value = store.Health + args.Amount
            if value > store.MaxHealth then
                untried(("AddHealth(%d) past the most: never tried"):format(args.Amount))
                value = store.MaxHealth
            end
            if value < 1 then untried(("AddHealth(%d) to below 1: never tried"):format(args.Amount)) end
            store.Health = value
        end },
        Kill = { call = function(self)
            called("Kill")
            local store, owner = values.of(self), rawget(self, "__outer")
            if owner and owner:IsA(kit.classes.IcarusPlayerCharacter) then actions.player_kills = actions.player_kills + 1 end
            store.Health, store.CurrentAliveState = 0, 1
        end },
    })
    add("CharacterState", { SetStamina = setter("SetStamina", "Stamina", "MaxStamina", 0) })
    add("SurvivalCharacterState", {
        SetFood = setter("SetFood", "FoodLevel", "MaxFood", 0), SetWater = setter("SetWater", "WaterLevel", "MaxWater", 0),
        SetOxygen = setter("SetOxygen", "OxygenLevel", "MaxOxygen", 0),
    })
    add("Actor", {
        K2_TeleportTo = { { "DestLocation", "StructProperty", struct = "/Script/CoreUObject.Vector" },
            { "DestRotation", "StructProperty", struct = "/Script/CoreUObject.Rotator" }, returns = BOOL, call = function(self, args)
                called("K2_TeleportTo")
                if actions.blocked then return false end
                local at, turn, store = args.DestLocation, args.DestRotation, values.of(self)
                for _, key in ipairs({ "X", "Y", "Z" }) do
                    if type(at[key]) ~= "number" then untried("K2_TeleportTo with no " .. key) end
                end
                store.Location = { at.X or 0, at.Y or 0, at.Z or 0 }
                store.Rotation = { turn.Pitch or 0, turn.Yaw or 0, turn.Roll or 0 }
                local root = store.RootComponent
                local root_store = root and values.of(root)
                if root_store then
                    if root_store.AttachParent:IsValid() then
                        untried("K2_TeleportTo on a character that sits on something")
                    else
                        root_store.RelativeLocation = { X = store.Location[1], Y = store.Location[2], Z = store.Location[3] }
                        root_store.RelativeRotation = { Pitch = store.Rotation[1], Yaw = store.Rotation[2], Roll = store.Rotation[3] }
                    end
                end
                return true
            end },
    })
end

-- ------------------------------------------------------------------------------------------------------- inventories

local ITEM, ITEM_ROW = "/Script/Icarus.ItemData", "/Script/Icarus.ItemsStaticRowHandle"

-- What the stand-in's tables say of an item: its name as the game spells it, its largest stack, its durability when new.
local function item_facts(name)
    local folded = type(name) == "string" and name:lower() or ""
    for _, row in ipairs(items.STATIC) do
        if row[1]:lower() == folded then
            local facts = { name = row[1], most = 1 }
            for _, able in ipairs(items.ITEMABLE) do
                if row[2] and able[1]:lower() == row[2]:lower() then facts.most = able[4] or 1 end
            end
            for _, durable in ipairs(items.DURABLE) do
                if row[3] and durable[1]:lower() == row[3]:lower() then facts.wear = durable[2] end
            end
            return facts
        end
    end
    return nil
end

local function item_of(args)
    local row = args.Item and args.Item.ItemStaticData and args.Item.ItemStaticData.RowName
    local facts = item_facts(row and row:ToString())
    if not facts then untried("an item the game does not have was handed to an inventory: " .. tostring(row and row:ToString())) end
    return facts
end

local function stack_of(slot)
    for _, pair in ipairs(slot.pairs) do
        if pair[1] == items.STACK then return pair[2] end
    end
    return 1
end

local function holds(slot, facts) return slot.item ~= nil and slot.item:lower() == facts.name:lower() end

local function takes(inv, facts) return inv.accepts == nil or inv.accepts(facts.name) == true end

local function install_items()
    values.struct(ITEM_ROW, "/Script/IcarusUtilities.RowHandle", {})
    values.struct("/Script/Icarus.TagQueriesRowHandle", "/Script/IcarusUtilities.RowHandle", {})
    values.struct(ITEM, nil, {
        { "ItemStaticData", "StructProperty", struct = ITEM_ROW }, { "ItemDynamicData", "ArrayProperty", inner = "StructProperty" },
        { "ItemCustomStats", "ArrayProperty", inner = "StructProperty" }, { "DatabaseGUID", "StrProperty" },
    })
    add("Inventory", {
        AutomaticallyPlaceItem = { { "Item", "StructProperty", struct = ITEM }, { "PlacedLocation", INT, out = true },
            { "DropItemAtOverFlow", BOOL }, { "AllowStacking", BOOL }, returns = BOOL, call = function(self, args)
                called("AutomaticallyPlaceItem")
                local inv, facts = items.of(self), item_of(args)
                actions.last_place = { drop = args.DropItemAtOverFlow, stacking = args.AllowStacking }
                if not facts then return false, { PlacedLocation = -1 } end
                if args.AllowStacking then
                    for position, slot in ipairs(inv.slots) do
                        if holds(slot, facts) and stack_of(slot) < facts.most then
                            items.set(inv, position, items.STACK, stack_of(slot) + 1)
                            return true, { PlacedLocation = position - 1 }
                        end
                    end
                end
                for position, slot in ipairs(inv.slots) do
                    if not slot.item and takes(inv, facts) then
                        if facts.wear then items.tool(inv, position, facts.name, facts.wear) else items.put(inv, position, facts.name, 1) end
                        return true, { PlacedLocation = position - 1 }
                    end
                end
                if args.DropItemAtOverFlow then actions.dropped = actions.dropped + 1 end
                return false, { PlacedLocation = -1 }
            end },
        AttemptPartialStackPlacement = { { "Item", "StructProperty", struct = ITEM }, { "Count", INT }, returns = INT,
            call = function(self, args)
                called("AttemptPartialStackPlacement")
                local inv, facts, left = items.of(self), item_of(args), args.Count
                if left < 1 then untried("AttemptPartialStackPlacement with a count below 1") end
                if not facts then return left end
                for position, slot in ipairs(inv.slots) do
                    local stack = stack_of(slot)
                    if left > 0 and holds(slot, facts) and stack < facts.most then
                        local more_here = math.min(left, facts.most - stack)
                        items.set(inv, position, items.STACK, stack + more_here)
                        left = left - more_here
                    end
                end
                return left
            end },
        SetItemDynamicProperty = { { "Location", INT }, { "Property", "ByteProperty" }, { "Value", INT }, returns = BOOL,
            call = function(self, args)
                called("SetItemDynamicProperty")
                local inv = items.of(self)
                local slot = inv.slots[args.Location + 1]
                if not slot or not slot.item then return false end
                local facts = item_facts(slot.item)
                if args.Property == items.STACK and facts and (args.Value > facts.most or args.Value < 1) then
                    untried(("a stack of %s set to %d: past the largest stack of %d was never tried"):format(slot.item, args.Value, facts.most))
                end
                items.set(inv, args.Location + 1, args.Property, args.Value)
                return true
            end },
        AddSlots = { { "SlotsToAdd", INT }, { "QueryOverride", "StructProperty", struct = "/Script/Icarus.TagQueriesRowHandle" },
            call = function(self, args)
                called("AddSlots")
                local inv = items.of(self)
                if args.SlotsToAdd < 1 then untried("AddSlots of less than one slot was never tried") end
                items.resize(inv, #inv.slots + args.SlotsToAdd)
            end },
        RemoveSlots = { { "SlotsToRemove", INT }, call = function(self, args)
            called("RemoveSlots")
            local inv = items.of(self)
            local size = #inv.slots - args.SlotsToRemove
            for position = size + 1, #inv.slots do
                if inv.slots[position].item then untried("RemoveSlots of a slot that holds something was never tried") end
            end
            items.resize(inv, size)
        end },
        ConsumeItem = { { "Location", INT }, { "Amount", INT }, { "ClearItemSave", BOOL }, returns = BOOL, call = function(self, args)
            called("ConsumeItem")
            local inv = items.of(self)
            local slot = inv.slots[args.Location + 1]
            if not slot or not slot.item then return false end
            local stack = stack_of(slot)
            if args.Amount < 1 or args.Amount > stack then
                untried(("ConsumeItem of %d from a stack of %d was never tried"):format(args.Amount, stack))
                return false
            end
            if args.Amount == stack then
                items.take(inv, args.Location + 1)
                if args.ClearItemSave then slot.last = nil end
            else
                items.set(inv, args.Location + 1, items.STACK, stack - args.Amount)
            end
            return true
        end },
        -- true for a slot that holds something else too: it only says whether the inventory takes that kind of item
        CanAdd = { { "Item", "StructProperty", struct = ITEM }, { "Location", INT }, returns = BOOL, call = function(self, args)
            called("CanAdd")
            local inv, facts = items.of(self), item_of(args)
            if not facts or not inv.slots[args.Location + 1] then return false end
            return takes(inv, facts)
        end },
    })
end

-- --------------------------------------------------------------------------------------------------------- modifiers

local MODIFIER, MODIFIER_ROW = "/Script/Icarus.Modifier", "/Script/Icarus.ModifierStatesRowHandle"

local function modifier_name(handle)
    local row = handle and handle.RowName
    local folded = row and row:ToString():lower() or ""
    for _, entry in ipairs(session.MODIFIERS) do
        if entry[1]:lower() == folded then return entry[1] end
    end
    return nil
end

local function modifiers_on(actor)
    local out = {}
    for _, component in ipairs(rawget(actor, "__components") or {}) do
        if not rawget(component, "__freed") and component:IsA(kit.classes.ModifierStateComponent) then out[#out + 1] = component end
    end
    return out
end

local function install_modifiers()
    values.struct(MODIFIER, nil, { { "Modifier", "StructProperty", struct = MODIFIER_ROW }, { "ModifierLifetime", FLOAT },
        { "ModifierEffectiveness", INT } })
    kit.classes.IcarusFunctionLibrary = values.class("/Script/Icarus.IcarusFunctionLibrary", kit.classes.Object, {}, {
        AddModifierState = { { "Parent", OBJECT }, { "InModifier", "StructProperty", struct = MODIFIER }, { "Causer", OBJECT },
            { "Instigator", OBJECT }, { "Effectiveness", INT }, returns = INT, call = function(_, args)
                called("AddModifierState")
                local row, given = modifier_name(args.InModifier.Modifier), args.InModifier
                if not row then
                    untried("AddModifierState with a row the game does not have")
                    return -1
                end
                if type(given.ModifierLifetime) ~= "number" or given.ModifierLifetime <= 0 then
                    untried("AddModifierState with no lifetime: what the game does then was never tried")
                end
                if args.Effectiveness ~= 100 or given.ModifierEffectiveness ~= 100 then
                    untried("AddModifierState with an effectiveness other than 100 was never tried")
                end
                uid = uid + 1
                more.modifier({ actor = args.Parent }, row, { uid = uid, lifetime = given.ModifierLifetime, remaining = given.ModifierLifetime })
                return uid
            end },
        RemoveModifierState = { { "Parent", OBJECT }, { "Modifier", "StructProperty", struct = MODIFIER_ROW }, { "UID", INT },
            returns = BOOL, call = function(_, args)
                called("RemoveModifierState")
                local row = modifier_name(args.Modifier)
                for _, component in ipairs(modifiers_on(args.Parent)) do
                    local store = values.of(component)
                    if store.ModifierUID == args.UID and row and store.DataRowHandleNew.RowName:ToString():lower() == row:lower() then
                        more.end_modifier({ actor = args.Parent }, component)
                        return true
                    end
                end
                return false
            end },
    })
    actions.library = values.part(kit.classes.IcarusFunctionLibrary, "Default__IcarusFunctionLibrary", {})
    world.static["/Script/Icarus.Default__IcarusFunctionLibrary"] = actions.library
end

-- ------------------------------------------------------------------------------------------- the clock and the weather

local function install_session()
    add("TimeOfDaySubsystem", {
        SetTimeOfDay = { { "Total", FLOAT }, call = function(self, args)
            called("SetTimeOfDay")
            local place = clocks[self]
            if not place then error("fake_actions: this clock belongs to no prospect given to actions.prospect", 0) end
            local total = args.Total
            if total < 0 then total = 0 end
            total = total % 1440
            -- as the game's own code does: an earlier time is the next day
            if total < place.store.TimeOfDay then actions.days = actions.days + 1 end
            place.store.TimeOfDay = total
        end },
        SetTimeScale = { { "Scale", FLOAT }, call = function()
            called("SetTimeScale")
            untried("SetTimeScale was only ever handed the speed the clock already had")
        end },
    })
    add("WeatherController", {
        AddWeatherEvent = { { "Biome", "StructProperty", struct = "/Script/Icarus.BiomesRowHandle" },
            { "WeatherEvent", "StructProperty", struct = "/Script/Icarus.WeatherEventsRowHandle" }, { "StartTime", INT }, returns = BOOL,
            call = function()
                called("AddWeatherEvent")
                untried("AddWeatherEvent was never called in the game")
                return false
            end },
        ForceStopAllWeatherEvents = { call = function()
            called("ForceStopAllWeatherEvents")
            untried("ForceStopAllWeatherEvents was never called in the game")
        end },
    })
end

-- Call after the stand-ins it stands on are installed. `with` names the ones a suite has: items = fake_items,
-- session = fake_session and more = what its install returned.
function actions.install(the_world, the_values, the_kit, with)
    world, values, kit = the_world, the_values, the_kit
    with = with or {}
    items, session, more = with.items, with.session, with.more
    install_character()
    if items then install_items() end
    if session and more then
        install_modifiers()
        install_session()
    end
    return actions
end

return actions
