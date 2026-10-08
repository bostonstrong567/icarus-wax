-- Characters: plain fields on every character, more on a player's, and game.Me for the local player's own

local Wax = ...
local easy = Wax.import("engine.easy")
local reflect = Wax.import("engine.reflect")
local instance = Wax.import("engine.instance")
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local suggest = Wax.import("core.suggest")
local perf = Wax.import("core.perf")
local log = Wax.import("core.log").channel("wax.character")

local M = {}

M.CHARACTER = "IcarusCharacter"         -- every player's character and nearly every creature
M.PLAYER = "IcarusPlayerCharacter"
M.PAWN = "IcarusPawn"                   -- the few creatures that are not an IcarusCharacter
M.SURVIVAL = "IcarusPlayerCharacterSurvival"
M.UNPROVEN = false      -- true before start() also gives what was never read in the running game: the fields on an IcarusPawn, and Sprinting
M.CENTIDEGREES = 100    -- the game's temperatures are taken to be hundredths of a degree Celsius
M.GRAMS = 1000          -- the game's weights are grams, and the fields give kilograms
M.METRE = 100
M.CAPACITY = "WeightCapacity_+"
M.ALIVE, M.SWIMMING = 0, 4              -- EAliveState::Alive, EMovementMode::MOVE_Swimming
-- seconds between two looks at what feeds the signals of game.Me
M.PACE = { Health = 0.1, Stamina = 0.1, Food = 0.5, Water = 0.5, Oxygen = 0.5, Weight = 0.5, Level = 0.5, XP = 0.5, Life = 0.25, Biome = 1 }

local type, rawequal, pcall, error, pairs, tostring, sqrt = type, rawequal, pcall, error, pairs, tostring, math.sqrt
local stats = sched.stats

local Me = {}
local current

-- A part of an actor, read from the live actor each time and never kept. Nil when it has none.
local function part(raw, name)
    local found = raw[name]
    if found ~= nil and found:IsValid() then return found end
    return nil
end

-- A member the class lacks reads as an invalid object, not as nil.
local function number(value)
    if type(value) == "number" then return value end
    return nil
end

local function state_number(property)
    return function(_, raw)
        local state = part(raw, "ActorState")
        return state and number(state[property])
    end
end

local function degrees(property)
    return function(_, raw)
        local state = part(raw, "ActorState")
        local value = state and number(state[property])
        return value and value / M.CENTIDEGREES
    end
end

local function flag(property)
    return function(_, raw)
        local value = raw[property]
        if type(value) ~= "boolean" then return nil end
        return value
    end
end

local LEFT_BEHIND = "Enum_CurrentAliveState"    -- the global UE4SS makes each time that enum is read

local function alive_mode(state)
    local mode = state.CurrentAliveState
    if rawget(_G, LEFT_BEHIND) ~= nil then rawset(_G, LEFT_BEHIND, nil) end
    return mode
end

local function alive(_, raw)
    local state = part(raw, "ActorState")
    local value = state and alive_mode(state)
    if type(value) ~= "number" then return nil end
    return value == M.ALIVE
end

local function level(_, raw)
    local state = part(raw, "ActorState")
    return state and number(state.Level) or number(raw.CurrentLevel)
end

local function biome_row(state)
    local name = state.CurrentBiome.RowName:ToString()
    if name == "" or name == "None" then return nil end
    return name
end

local function biome(_, raw)
    local state = part(raw, "ActorState")
    if not state then return nil end
    local ok, name = pcall(biome_row, state)
    return ok and name or nil
end

-- The root's own place is the world's while the root is attached to nothing, and reading it costs a third of the call.
local function place(raw)
    local root, at = raw.RootComponent, nil
    if root:IsValid() and not root.AttachParent:IsValid() then at = root.RelativeLocation else at = raw:K2_GetActorLocation() end
    return at.X, at.Y, at.Z
end

local function position(_, raw)
    local x, y, z = place(raw)
    return { X = x, Y = y, Z = z }
end

local function rotation(_, raw)
    local root, turn = raw.RootComponent, nil
    if root:IsValid() and not root.AttachParent:IsValid() then turn = root.RelativeRotation else turn = raw:K2_GetActorRotation() end
    return { Pitch = turn.Pitch, Yaw = turn.Yaw, Roll = turn.Roll }
end

local function velocity(_, raw)
    local movement = part(raw, "CharacterMovement")
    if not movement then return nil end
    local speed = movement.Velocity
    return { X = speed.X, Y = speed.Y, Z = speed.Z }
end

local function move_speed(_, raw)
    local movement = part(raw, "CharacterMovement")
    return movement and number(movement.MaxWalkSpeed)
end

local function swimming(_, raw)
    local movement = part(raw, "CharacterMovement")
    local mode = movement and number(movement.MovementMode)
    if not mode then return nil end
    return mode == M.SWIMMING
end

-- What a distance is measured to: an actor, game.Me or a position.
local function place_of(target, what)
    if rawequal(target, Me) then
        target = current()
        if not target then error(what .. ": there is no character right now, so there is nothing to measure to", 0) end
    end
    if instance.is_instance(target) then
        if not target:IsA("Actor") then
            error(("%s expects an actor, and a %s is not one. Give the actor it belongs to"):format(what, target.ClassName), 0)
        end
        if not target:IsValid() then error(("%s: that %s no longer exists"):format(what, target.ClassName), 0) end
        return place(target.Raw)
    end
    if type(target) == "table" and type(target.X) == "number" and type(target.Y) == "number" and type(target.Z) == "number" then
        return target.X, target.Y, target.Z
    end
    error(what .. " expects an actor, game.Me or a position such as { X = 0, Y = 0, Z = 0 }, got " .. type(target), 0)
end

local function distance_to(_, raw, target)
    local x, y, z = place_of(target, "DistanceTo")
    local mine_x, mine_y, mine_z = place(raw)
    return sqrt((x - mine_x) ^ 2 + (y - mine_y) ^ 2 + (z - mine_z) ^ 2) / M.METRE
end

local function weight(_, raw)
    local grams = number(raw.CurrentWeight)
    return grams and grams / M.GRAMS
end

local capacity = nil

local function max_weight(_, raw)
    local container = part(raw, "StatContainer")
    if not container then return nil end
    capacity = capacity or FName(M.CAPACITY)
    return number(container:GetStatByRowHandle({ RowName = capacity }))
end

local function player_name(_, raw)
    local state = part(raw, "PlayerState")
    if not state then return nil end
    local name = state.PlayerNamePrivate
    if type(name) ~= "string" then name = name:ToString() end
    if name == "" then return nil end
    return name
end

local function is_local(self) return rawequal(current(), self) end

local function in_cave(self, raw)
    if not self:IsA(M.SURVIVAL) then return nil end
    return raw:GetIsInCave() == true
end

local character_fields = {
    Health = state_number("Health"), MaxHealth = state_number("MaxHealth"), Armor = state_number("Armor"),
    MaxArmor = state_number("MaxArmor"), Stamina = state_number("Stamina"), MaxStamina = state_number("MaxStamina"),
    XP = state_number("TotalExperience"), Alive = alive, Level = level, Biome = biome,
    Temperature = degrees("ModifiedExternalTemperature"), Position = position, Rotation = rotation, Velocity = velocity,
    MoveSpeed = move_speed, Crouching = flag("bIsCrouched"), Swimming = swimming,
}
local character_methods = { DistanceTo = distance_to }
local player_fields = {
    Food = state_number("FoodLevel"), MaxFood = state_number("MaxFood"), Water = state_number("WaterLevel"),
    MaxWater = state_number("MaxWater"), Oxygen = state_number("OxygenLevel"), MaxOxygen = state_number("MaxOxygen"),
    Radiation = state_number("RadiationLevel"), MaxRadiation = state_number("MaxRadiation"),
    BodyTemperature = degrees("ModifiedInternalTemperature"), Weight = weight, MaxWeight = max_weight,
    PlayerName = player_name, Local = is_local, InCave = in_cave,
}

-- the local player's character

local game_root = nil
local found, found_frame = nil, -1
local last_seen, epoch = nil, 0         -- the character of the last find, and how many different ones there have been
local counts = { finds = 0, seconds = 0 }
local known = {}                        -- member name -> "method" or "value", for when there is no character to ask
local learned = {}                      -- class name -> true once its members were noted

local function note(spec)
    if type(spec) ~= "table" then return end
    for name in pairs(type(spec.fields) == "table" and spec.fields or {}) do known[name] = "value" end
    for name in pairs(type(spec.setters) == "table" and spec.setters or {}) do known[name] = known[name] or "value" end
    for name in pairs(type(spec.methods) == "table" and spec.methods or {}) do known[name] = "method" end
end

-- Which names of this character are functions, so that game.Me can say so while there is no character.
local function learn(who)
    local info = reflect.class_info(who.Raw:GetClass())
    if not learned[info.name] then
        learned[info.name] = true
        for name, member in pairs(info.members) do known[name] = member.kind == "function" and "method" or "value" end
    end
    local added = easy.merged[info]
    if added == nil then added = easy.merge(info) end
    if added then note(added) end
end

-- The local player's character as an Instance, found once a frame. Nil while there is none.
function current()
    local frame = stats.frame
    if found_frame == frame and (found == nil or found:IsValid()) then return found end
    local started = perf.now()
    game_root = game_root or Wax.import("engine.game").root
    local who = game_root.Character
    if who and not who:IsA(M.PLAYER) then who = nil end
    found, found_frame = who, frame
    if who and not rawequal(who, last_seen) then
        last_seen, epoch = who, epoch + 1
        local ok, problem = pcall(learn, who)
        if not ok then log:debug("the members of %s could not be noted: %s", who.ClassName, (tostring(problem):match("^[^\r\n]*"))) end
    end
    counts.finds = counts.finds + 1
    counts.seconds = counts.seconds + (perf.now() - started)
    return who
end

-- game.Me: stands for that character, whichever one it is

local own = {}                          -- what game.Me has of its own: its signals, and what other modules give it
local own_names = { "Character", "Exists" }
local getters = {
    Character = function() return current() end,
    Exists = function() return current() ~= nil end,
}
local bound = {}

local function read(who, key) return who[key] end
local function write(who, key, value) who[key] = value end

-- What an Instance raised, without this file's own line in front of it.
local function clean(problem)
    return (tostring(problem):gsub("^[^\n]-character%.lua:%d+: ", "", 1))
end

local EVERY_INSTANCE = { "Name", "ClassName", "FullName", "Parent", "Raw" }

-- The message for a name game.Me does not have, with the nearest of every name it may answer to.
local function unknown(key)
    known[key] = nil
    local names = {}
    for i = 1, #own_names do names[own_names[i]] = true end
    for i = 1, #EVERY_INSTANCE do names[EVERY_INSTANCE[i]] = true end
    for name in pairs(instance.Instance) do names[name] = true end
    for name in pairs(known) do names[name] = true end
    return ("%s is not a member of game.Me.%s"):format(tostring(key), suggest.phrase(tostring(key), names))
end

-- A method of the character, callable on game.Me. It finds the character when it is called.
local function method(key)
    local fn = bound[key]
    if fn then return fn end
    fn = function(self, ...)
        local who = current()
        if not who then
            error(("there is no character right now, so %s cannot be called. game.Me.Exists says when there is one"):format(key), 2)
        end
        local ok, real = pcall(read, who, key)
        if not ok then
            if tostring(real):find(" is not a member of ", 1, true) then error(unknown(key), 2) end
            error(clean(real), 2)
        end
        if type(real) ~= "function" then error(("%s is not a function of this character"):format(key), 2) end
        if rawequal(self, Me) then return real(who, ...) end
        return real(self, ...)
    end
    bound[key] = fn
    return fn
end

local meta = {}

meta.__index = function(_, key)
    local mine = own[key]
    if mine ~= nil then return mine end
    local getter = getters[key]
    if getter then return getter() end
    local kind = known[key]
    if kind == "method" then return method(key) end
    local who = current()
    if not who then
        -- before any character was seen, a name may be one of the game's own that is not known yet
        if kind == "value" or next(learned) == nil then return nil end
        error(unknown(key), 2)
    end
    local ok, value = pcall(read, who, key)
    if not ok then
        if tostring(value):find(" is not a member of ", 1, true) then error(unknown(key), 2) end
        error(clean(value), 2)
    end
    if type(value) == "function" then
        known[key] = "method"
        return method(key)
    end
    return value
end

meta.__newindex = function(_, key, value)
    if own[key] ~= nil or getters[key] then error(("game.Me.%s cannot be assigned"):format(tostring(key)), 2) end
    local who = current()
    if not who then
        error(("there is no character right now, so %s cannot be set. game.Me.Exists says when there is one"):format(tostring(key)), 2)
    end
    local ok, problem = pcall(write, who, key, value)
    if not ok then error(clean(problem), 2) end
end

meta.__tostring = function()
    local who = current()
    return who and ("game.Me (" .. tostring(who) .. ")") or "game.Me (no character)"
end

meta.__names = function()
    local names, who = {}, current()
    for i = 1, #own_names do names[i] = own_names[i] end
    if who then
        for _, name in ipairs(who:GetMembers()) do names[#names + 1] = name end
    else
        for name in pairs(known) do names[#names + 1] = name end
    end
    return names
end

setmetatable(Me, meta)

-- signals fed by looking, each looked at only while it has a handler

local sources = {}
local source_of = setmetatable({}, { __mode = "k" })    -- signal -> what feeds it
local plain_connect, plain_disconnect = sched.Signal.Connect, nil

local function handlers(source)
    local n = 0
    for i = 1, #source.outlets do n = n + source.outlets[i].signal.count end
    return n
end

-- The looking belongs to no mod: it goes on for the other handlers when one mod unloads.
local function hold(source)
    if source.link and source.link.Connected then return end
    if source.prompt then source.prompt(true) end
    local loaded, watch = pcall(Wax.import, "engine.watch")
    if not loaded then
        error("the signals of game.Me need engine.watch, which did not load: " .. (tostring(watch):gsub("%s*[\r\n]+%s*", " "):sub(1, 200)), 0)
    end
    local previous = scope.enter(nil)
    local ok, problem = pcall(function()
        source.inner = source.inner or watch.signal("game.Me." .. source.name, { every = source.every(), read = source.reader })
        source.link = source.inner:Connect(source.dispatch)
    end)
    scope.leave(previous)
    if not ok then error(problem, 0) end
end

-- Takes the place of a connection's own Disconnect: the last handler to leave ends the looking at once.
local function leave(connection)
    if not connection.Connected or not plain_disconnect then return end
    plain_disconnect(connection)
    local source = source_of[connection.signal]
    if source and source.link and handlers(source) == 0 then
        source.link:Disconnect()
        source.link = nil
        if source.prompt then source.prompt(false) end
    end
end

local function connect(self, fn)
    if type(fn) ~= "function" then error("Connect expects a function, got " .. type(fn), 2) end
    local ok, problem = pcall(hold, source_of[self])
    if not ok then error(problem, 2) end
    local connection = plain_connect(self, fn)
    if rawget(connection, "Disconnect") == nil then
        plain_disconnect = plain_disconnect or connection.Disconnect
        connection.Disconnect = leave
    end
    return connection
end

-- Gives game.Me a member of its own, such as a signal another module feeds.
function M.provide(name, value)
    if type(name) ~= "string" or not name:find("^%u[%w_]*$") then
        error("character.provide expects a name that starts with a capital letter, got " .. tostring(name), 2)
    end
    if value == nil then error("character.provide expects a value for game.Me." .. name, 2) end
    if own[name] == nil and not getters[name] then own_names[#own_names + 1] = name end
    own[name] = value
end

-- A value of the local character and the signals of game.Me it feeds. read gives nil for nothing to say.
-- { name, every, read(who, raw, previous), absent(previous), outlets = { { signal name, tell(signal, value, previous) } } }
function M.feed(spec)
    if type(spec) ~= "table" or type(spec.name) ~= "string" or type(spec.read) ~= "function" or type(spec.outlets) ~= "table" then
        error("character.feed expects { name = text, every = seconds, read = function, outlets = { { name, tell } } }", 2)
    end
    local name, read_value, absent = spec.name, spec.read, spec.absent
    local source = { name = name, outlets = {} }
    source.every = function() return M.PACE[name] or spec.every or 0.5 end
    source.reader = function(previous)
        local who = current()
        if not who then
            if absent then return absent(previous) end
            return previous
        end
        local value = read_value(who, who.Raw, previous)
        if value == nil then return previous end
        return value
    end
    source.dispatch = function(value, previous)
        local outlets = source.outlets
        for i = 1, #outlets do
            local outlet = outlets[i]
            if outlet.signal.count > 0 then outlet.tell(outlet.signal, value, previous) end
        end
    end
    local made = {}
    for i, outlet in ipairs(spec.outlets) do
        local signal = sched.Signal.new("game.Me." .. outlet[1])
        signal.Connect = connect
        source_of[signal] = source
        source.outlets[i] = { name = outlet[1], signal = signal, tell = outlet[2] }
        M.provide(outlet[1], signal)
        made[outlet[1]] = signal
    end
    sources[name] = source
    return made
end

-- The first sight of a value is where it starts from, so nothing is told then.
local function changed(signal, value, previous)
    if previous ~= nil then signal:Fire(value, previous) end
end

local function plain(name, signal_name, get)
    M.feed({ name = name, read = get, outlets = { { signal_name, changed } } })
end

plain("Health", "HealthChanged", character_fields.Health)
plain("Stamina", "StaminaChanged", character_fields.Stamina)
plain("Food", "FoodChanged", player_fields.Food)
plain("Water", "WaterChanged", player_fields.Water)
plain("Oxygen", "OxygenChanged", player_fields.Oxygen)
plain("Weight", "WeightChanged", weight)
plain("Biome", "BiomeChanged", biome)

-- A level and experience are one character's: the value carries which character it was read from.
local function of_one(get)
    return function(who, raw)
        local value = get(who, raw)
        return value and { value, epoch }
    end
end

local function same_one(value, previous) return previous ~= nil and value[2] == previous[2] and value[1] > previous[1] end

M.feed({ name = "Level", read = of_one(level), outlets = {
    { "LevelUp", function(signal, value, previous)
        if same_one(value, previous) then signal:Fire(value[1], previous[1]) end
    end },
} })

M.feed({ name = "XP", read = of_one(character_fields.XP), outlets = {
    { "XPGained", function(signal, value, previous)
        if same_one(value, previous) then signal:Fire(value[1] - previous[1], value[1]) end
    end },
} })

-- { which character (0 for none), whether it is alive }. Without a character the last answer about being alive is kept.
M.feed({
    name = "Life",
    read = function(who, raw, previous)
        local is_alive = alive(who, raw)
        if is_alive == nil and previous then is_alive = previous[2] end
        return { epoch, is_alive }
    end,
    absent = function(previous) return { 0, previous and previous[2] } end,
    outlets = {
        { "Despawned", function(signal, value, previous)
            if previous and previous[1] ~= 0 and value[1] ~= previous[1] then signal:Fire() end
        end },
        { "Spawned", function(signal, value, previous)
            local who = previous and value[1] ~= 0 and value[1] ~= previous[1] and current()
            if who then signal:Fire(who) end
        end },
        { "Respawned", function(signal, value, previous)
            local who = previous and value[1] ~= 0 and value[2] == true and previous[2] == false and current()
            if who then signal:Fire(who) end
        end },
    },
})

-- what a mod does to a character. Each acts on the machine that runs it, so only the host may

M.KILL_PLAYERS = false      -- true lets Kill() kill a player's character too: the game's call was only made on creatures so far

local floor, huge = math.floor, math.huge

local function described(value)
    if rawequal(value, Me) then return "game.Me" end
    if instance.is_instance(value) then return "an Instance" end
    if type(value) == "number" then return tostring(value) end
    return type(value)
end

-- Raises unless this player hosts the session. `doing` finishes "only the host can ...".
function M.host_only(doing)
    game_root = game_root or Wax.import("engine.game").root
    if game_root.IsHost == true then return end
    error(("only the host can %s. You are in someone else's game, where its server decides. game.IsHost says which you are")
        :format(doing), 0)
end

local function finite(value) return type(value) == "number" and value == value and value ~= huge and value ~= -huge end

-- A number a mod gave, as the whole number the game's functions take.
function M.whole(value, what)
    if not finite(value) then error(("%s expects a number, got %s"):format(what, described(value)), 0) end
    return floor(value + 0.5)
end
local whole = M.whole

-- One call of the game's own. A function this version of the game lacks is said in plain words.
function M.ask(what, fn, ...)
    local ok, answer = pcall(fn, ...)
    if ok then return answer end
    error(("%s did not work in this version of the game: %s"):format(what, (tostring(answer):match("^[^\r\n]*") or "")), 0)
end
local ask = M.ask

-- The state component the game keeps a character's health in, and whether the character is alive.
local function living_state(self, raw, what)
    local state = part(raw, "ActorState")
    local mode = state and alive_mode(state)
    if not state or type(mode) ~= "number" then
        error(("%s: this %s has no state of the kind the game keeps health in"):format(what, self.ClassName), 0)
    end
    return state, mode == M.ALIVE
end

local SETTERS = {
    Health = function(state, value) state:SetHealth(value) end,
    Stamina = function(state, value) state:SetStamina(value) end,
    Food = function(state, value) state:SetFood(value) end,
    Water = function(state, value) state:SetWater(value) end,
    Oxygen = function(state, value) state:SetOxygen(value) end,
}

-- A setter for an everyday value: the game's own function, handed a whole number from `least` to the most the character can have.
local function vital(field, property, most_property, least)
    local call = SETTERS[field]
    return function(self, raw, value)
        M.host_only("set " .. field)
        local wanted = whole(value, field)
        local state, is_alive = living_state(self, raw, field)
        local now, most = number(state[property]), number(state[most_property])
        if not now or not most then error(("this %s has no %s to set"):format(self.ClassName, field), 0) end
        if not is_alive then error(("this character is dead, so its %s cannot be set"):format(field), 0) end
        if wanted < least and least > 0 then
            error(("%s cannot be set below %d. To kill a character call Kill()"):format(field, least), 0)
        end
        if wanted < least then wanted = least elseif wanted > most then wanted = most end
        if wanted ~= now then ask("setting " .. field, call, state, wanted) end
    end
end

local function add_health(state, amount) state:AddHealth(amount) end
local function set_health(state, value) state:SetHealth(value) end
local function end_life(state) state:Kill() end

-- Heal(amount) gives that much health back, Heal() all of it. Answers the health afterwards.
local function heal(self, raw, amount)
    M.host_only("heal a character")
    local by = amount ~= nil and whole(amount, "Heal") or nil
    if by and by <= 0 then
        error("Heal expects how much health to give back, a number above 0. To lower health assign Health, and to kill call Kill()", 0)
    end
    local state, is_alive = living_state(self, raw, "Heal")
    local now, most = number(state.Health), number(state.MaxHealth)
    if not now or not most then error(("this %s has no Health to give back"):format(self.ClassName), 0) end
    if not is_alive then error("this character is dead, and Heal does not bring it back", 0) end
    if now >= most then return now end
    if by and now + by < most then
        ask("healing", add_health, state, by)
    else
        ask("healing", set_health, state, most)
    end
    return number(state.Health)
end

-- Kill() answers true when the character was alive and is dead now.
local function kill(self, raw)
    M.host_only("kill a character")
    local state, is_alive = living_state(self, raw, "Kill")
    if not is_alive then return false end
    if not M.KILL_PLAYERS and self:IsA(M.PLAYER) then
        error("Kill is switched off for a player's character in this version of Wax: the game's call was only made on creatures so far", 0)
    end
    ask("killing", end_life, state)
    return alive_mode(state) ~= M.ALIVE
end

local function facing_of(facing, raw)
    if facing == nil then return rotation(nil, raw) end
    if type(facing) ~= "table" or instance.is_instance(facing) or rawequal(facing, Me)
        or (facing.Pitch == nil and facing.Yaw == nil and facing.Roll == nil) then
        error("Teleport expects the way to face as its second value, such as { Yaw = 90 }, got " .. described(facing), 0)
    end
    local pitch, yaw, roll = facing.Pitch or 0, facing.Yaw or 0, facing.Roll or 0
    if not (finite(pitch) and finite(yaw) and finite(roll)) then
        error("Teleport expects Pitch, Yaw and Roll in degrees, each a number", 0)
    end
    return { Pitch = pitch, Yaw = yaw, Roll = roll }
end

local function teleport_to(raw, at, turn) return raw:K2_TeleportTo(at, turn) end

-- Teleport(place, facing) answers true when the game moved the character.
local function teleport(_, raw, target, facing)
    M.host_only("move a character")
    local x, y, z = place_of(target, "Teleport")
    if not (finite(x) and finite(y) and finite(z)) then error("Teleport expects a place whose X, Y and Z are numbers", 0) end
    local turn = facing_of(facing, raw)
    return ask("moving a character", teleport_to, raw, { X = x, Y = y, Z = z }, turn) == true
end

local character_setters = { Health = vital("Health", "Health", "MaxHealth", 1), Stamina = vital("Stamina", "Stamina", "MaxStamina", 0) }
local player_setters = { Food = vital("Food", "FoodLevel", "MaxFood", 0), Water = vital("Water", "WaterLevel", "MaxWater", 0),
    Oxygen = vital("Oxygen", "OxygenLevel", "MaxOxygen", 0) }
character_methods.Heal, character_methods.Kill, character_methods.Teleport = heal, kill, teleport

-- what the game tells by itself: damage, death, and a nudge for the values that are looked at

M.EVENTS = true         -- false before start(): nothing of the game's is listened to, and there is no Damaged, Died or modifier signal
M.DAMAGED = "/Script/Icarus.ActorState:Multicast_OnDamaged"
-- the game's own calls after it changed one of these on a player's character
M.TOLD = {
    Food = "/Script/Icarus.IcarusPlayerCharacterSurvival:OnFoodLevelUpdated",
    Water = "/Script/Icarus.IcarusPlayerCharacterSurvival:OnWaterLevelUpdated",
    Oxygen = "/Script/Icarus.IcarusPlayerCharacterSurvival:OnOxygenLevelUpdated",
    Weight = "/Script/Icarus.InventoryComponent:WeightUpdatedDelagate",
}
M.TOLD_PACE = 2         -- seconds between two looks at a value the game tells about
M.VIGIL = 0.25          -- seconds between two looks at the characters whose death or return is waited for
M.PENDING = 2           -- seconds a character with no health left is looked at for its death

---@type any
local hooks = nil       -- engine.hooks, once start() has it
local task = sched.task
local told = {
    voices = setmetatable({}, { __mode = "k" }),    -- character Instance -> its own Damaged and Died
    heard = setmetatable({}, { __mode = "k" }),     -- character Instance -> how many of its signals have a handler
    dead = setmetatable({}, { __mode = "k" }),      -- character Instance -> true once its death was told
    hits = setmetatable({}, { __mode = "k" }),      -- character Instance -> the last damage that left it no health
    vigil = {}, watched = 0, thread = nil,          -- character Instance -> when its wait ends (false: it has no end)
    by_address = {}, left = {}, ended = nil,        -- the characters with a handler by engine address, and those that ended play
    listening = 0, undo = nil,
    events = {},                                    -- Damaged and Died of every character, for the modules that list them
}

-- What Wax sets up for itself belongs to no mod, whichever mod asked first.
local function no_mod(fn, ...)
    local previous = scope.enter(nil)
    local ok, made = pcall(fn, ...)
    scope.leave(previous)
    if not ok then error(made, 0) end
    return made
end

local function copied(values)
    local out = {}
    for key, value in pairs(values) do out[key] = value end
    return out
end

-- What is known of the hit that ended a character, while it is fresh.
local function last_hit(who)
    local hit = told.hits[who]
    if hit and sched.clock() - hit.at <= M.PENDING + 1 then return { Killer = hit.Killer, Instigator = hit.Instigator, Damage = hit.Damage } end
    return {}
end

local vigil_loop

local function keep_vigil(who, ends)
    local vigil = told.vigil
    if vigil[who] == nil then told.watched = told.watched + 1 end
    if vigil[who] ~= false then vigil[who] = ends end
    if not told.thread then told.thread = no_mod(task.spawn, vigil_loop) end
end

local function end_vigil(who)
    if told.vigil[who] == nil then return end
    told.vigil[who] = nil
    told.watched = told.watched - 1
end

local function died(who, info)
    if told.dead[who] then return end
    told.dead[who], told.hits[who] = true, nil
    keep_vigil(who, false)
    local mine, events = told.voices[who], told.events
    if mine and mine.Died.count > 0 then mine.Died:Fire(who, copied(info)) end
    if events.Died.count > 0 then events.Died:Fire(who, copied(info)) end
    if told.me_died.count > 0 and rawequal(who, current()) then told.me_died:Fire(who, copied(info)) end
end

-- A character that is gone: its handlers are disconnected and nothing waits for it. The Instance is asked nothing.
local function let_go(who)
    local mine = told.voices[who]
    told.voices[who] = nil
    if mine then
        mine.Damaged:DisconnectAll()
        mine.Died:DisconnectAll()
    end
    end_vigil(who)
    told.dead[who], told.hits[who] = nil, nil
end

-- Looks at every character that is waited for. An Instance that is gone raises, and is let go.
local function look_after()
    local now, fallen, gone = sched.clock(), nil, told.left
    told.left = {}
    for who, ends in pairs(told.vigil) do
        local ok, is_alive = pcall(read, who, "Alive")
        if not ok then
            gone[#gone + 1] = who
        elseif is_alive == false then
            if not told.dead[who] then
                fallen = fallen or {}
                fallen[#fallen + 1] = who
            end
        elseif is_alive == true then
            told.dead[who] = nil
            local mine = told.voices[who]
            if not (mine and mine.Died.count > 0) and (ends == false or now >= ends) then end_vigil(who) end
        end
    end
    for i = 1, #gone do let_go(gone[i]) end
    for i = 1, fallen and #fallen or 0 do died(fallen[i], last_hit(fallen[i])) end
end

function vigil_loop()
    while told.watched > 0 or next(told.by_address) ~= nil do
        task.wait(M.VIGIL)
        local ok, problem = pcall(look_after)
        if not ok then log:debug("looking after the characters that are waited for raised: %s", clean(problem)) end
    end
    told.thread = nil
end

-- Inside the game's own call: `state` is the damaged actor's state, the rest are the values of the call.
local function caught_damage(state, amount, _, instigator, causer)
    local owner = state:GetOuter()
    if not owner:IsValid() then return nil end
    local events = told.events
    local everyone = events.Damaged.count > 0 or events.Died.count > 0
    local mine = false
    if told.me_damaged.count > 0 or told.me_died.count > 0 then
        local me = current()
        mine = me ~= nil and instance.address(me) == owner:GetAddress()
    end
    if not mine and not everyone and next(told.heard) == nil then return nil end
    local who = instance.wrap(owner)
    if not who or not (mine or told.heard[who] or (everyone and who:IsA(M.CHARACTER))) then return nil end
    local packet = state.LastDamagePacket
    local info = { Health = number(state.Health), Applied = number(packet.AppliedDamage), Total = number(packet.TotalDamage),
        Radial = packet.bWasRadialDamage == true, Stealth = packet.bIsStealthHit == true }
    local by, from = causer:get(), instigator:get()
    if by ~= nil and by:IsValid() then info.Causer = instance.wrap(by) end
    if from ~= nil and from:IsValid() then info.Instigator = instance.wrap(from) end
    return { who = who, amount = number(amount:get()) or info.Applied or 0, info = info }
end

-- In the frame loop, with what was copied above.
local function told_damage(event)
    local who, amount, info = event.who, event.amount, event.info
    local mine, events = told.voices[who], told.events
    if mine and mine.Damaged.count > 0 then mine.Damaged:Fire(who, amount, copied(info)) end
    if events.Damaged.count > 0 then events.Damaged:Fire(who, amount, copied(info)) end
    if rawequal(who, current()) then
        if told.me_damaged.count > 0 then told.me_damaged:Fire(who, amount, copied(info)) end
        local health, watch = sources.Health, Wax.modules["engine.watch"]
        if health.inner and type(watch) == "table" then watch.check(health.inner) end
    end
    local health = info.Health
    if not health then return end
    if health > 0 then
        told.dead[who] = nil
        return
    end
    if told.dead[who] then return end
    local hit = { Killer = info.Causer, Instigator = info.Instigator, Damage = amount, at = sched.clock() }
    told.hits[who] = hit
    local ok, is_alive = pcall(read, who, "Alive")
    if ok and is_alive == false then
        died(who, last_hit(who))
    elseif ok then
        keep_vigil(who, hit.at + M.PENDING)
    end
end

local function listen_damage()
    if told.undo then return true end
    local ok, made = pcall(no_mod, hooks.listen, M.DAMAGED,
        { reach = hooks.NET, catch = caught_damage, deliver = told_damage, label = "damage" })
    if not ok then return false, clean(made) end
    told.undo = made
    return true
end

-- A signal fed by the damage the game tells got its first handler. Death can be seen by looking, damage cannot.
local function more(needed)
    local ok, problem = listen_damage()
    if not ok and needed then error("damage cannot be told in this version of the game: " .. tostring(problem), 0) end
    told.listening = told.listening + 1
end

local function less()
    told.listening = told.listening - 1
    if told.listening > 0 then return end
    told.listening = 0
    if told.undo then
        told.undo()
        told.undo = nil
    end
    told.dead, told.hits = setmetatable({}, { __mode = "k" }), setmetatable({}, { __mode = "k" })
    told.vigil, told.watched = {}, 0
end

-- The Damaged and Died of one character, made when a mod first asks for one of them.
local function voice(self)
    local mine = told.voices[self]
    if mine then return mine end
    local heard, address = told.heard, instance.address(self)
    local function first(needed)
        more(needed)
        heard[self] = (heard[self] or 0) + 1
        told.by_address[address] = self
        -- the end of play is told inside the engine's call, so it is only noted there
        told.ended = told.ended or no_mod(Wax.import("engine.actors").on_ended, function(_, ended)
            local who = told.by_address[ended]
            if who then told.left[#told.left + 1] = who end
        end)
        if not told.thread then told.thread = no_mod(task.spawn, vigil_loop) end
    end
    local function last()
        heard[self] = (heard[self] or 0) > 1 and heard[self] - 1 or nil
        if not heard[self] and told.by_address[address] == self then told.by_address[address] = nil end
        less()
    end
    local class_name = self.ClassName
    mine = {
        Damaged = hooks.signal(class_name .. ".Damaged", function() first(true) end, last),
        Died = hooks.signal(class_name .. ".Died", function()
            first(false)
            keep_vigil(self, false)
        end, function()
            if not told.dead[self] then end_vigil(self) end
            last()
        end),
    }
    told.voices[self] = mine
    return mine
end

-- One more signal of game.Me fed by a value that is already looked at.
local function outlet(source_name, name, tell)
    local source = sources[source_name]
    local signal = sched.Signal.new("game.Me." .. name)
    signal.Connect = connect
    source_of[signal] = source
    source.outlets[#source.outlets + 1] = { name = name, signal = signal, tell = tell }
    M.provide(name, signal)
    return signal
end

-- The game's own call nudges a value that is looked at, so a change is told in the next frame and the looking can be slow.
local function prompt(source, path, owner_of)
    local undo, waiting = nil, false
    local function catch(object)
        if waiting then return nil end
        local me = current()
        if not me then return nil end
        if owner_of then object = owner_of(object) end
        if not object:IsValid() or object:GetAddress() ~= instance.address(me) then return nil end
        waiting = true
        return true
    end
    local function deliver()
        waiting = false
        local watch = Wax.modules["engine.watch"]
        if source.inner and type(watch) == "table" then watch.check(source.inner) end
    end
    return function(on)
        if not on then
            if undo then undo() end
            undo, waiting = nil, false
            return
        end
        if undo then return end
        local ok, made = pcall(no_mod, hooks.listen, path,
            { reach = hooks.DELEGATE, catch = catch, deliver = deliver, label = "game.Me." .. source.name })
        if ok then
            undo = made
            return
        end
        M.PACE[source.name], source.prompt = source.pace_before, nil
        log:warn("the game's own word of a change of %s cannot be listened to, so it is looked at as often as before: %s",
            source.name, clean(made))
    end
end

local function component_owner(component) return component:GetOuter() end

-- The modifiers of a character by their number, with what does not change while one is on.
local function modifiers_now(who)
    local ok, list = pcall(function() return who:GetModifiers() end)
    if not ok or type(list) ~= "table" then return nil end
    local by = {}
    for i = 1, #list do
        local one = list[i]
        if one.Id ~= nil then
            by[one.Id] = { Name = one.Name, DisplayName = one.DisplayName, Kind = one.Kind, Id = one.Id, Duration = one.Duration }
        end
    end
    return { epoch, by }
end

-- Fires for what `now` has and `before` lacks, lowest number first.
local function tell_new(signal, now, before)
    local ids = {}
    for id in pairs(now) do
        if before[id] == nil then ids[#ids + 1] = id end
    end
    table.sort(ids)
    for i = 1, #ids do signal:Fire(copied(now[ids[i]])) end
end

local function events_start()
    if hooks or not M.EVENTS then return end
    local loaded, module = pcall(Wax.import, "engine.hooks")
    if not loaded then
        log:warn("engine.hooks did not load, so nothing is told of damage, death and modifiers: %s", clean(module))
        return
    end
    hooks = module
    local events = told.events
    events.Damaged = hooks.signal("character.Damaged", function() more(true) end, less)
    events.Died = hooks.signal("character.Died", function() more(false) end, less)
    told.me_damaged = hooks.signal("game.Me.Damaged", function() more(true) end, less)
    M.provide("Damaged", told.me_damaged)
    -- the look that tells of a respawn sees a death too, when no damage came with it
    told.me_died = hooks.count(outlet("Life", "Died", function(_, value, previous)
        local who = previous and value[1] ~= 0 and current()
        if not who then return end
        if value[2] == true then
            told.dead[who] = nil
        elseif value[2] == false and previous[2] == true and value[1] == previous[1] then
            died(who, last_hit(who))
        end
    end), function() more(false) end, less)
    M.feed({ name = "Modifiers", every = 0.5, read = modifiers_now, outlets = {
        { "ModifierAdded", function(signal, value, previous)
            if previous and value[1] == previous[1] then tell_new(signal, value[2], previous[2]) end
        end },
        { "ModifierRemoved", function(signal, value, previous)
            if previous and value[1] == previous[1] then tell_new(signal, previous[2], value[2]) end
        end },
    } })
    character_fields.Damaged = function(self) return voice(self).Damaged end
    character_fields.Died = function(self) return voice(self).Died end
    -- after a map change every character that was listened to is gone, and none of them is asked anything
    no_mod(function()
        Wax.import("engine.game").root.MapChanged:Connect(function()
            local all = {}
            for who in pairs(told.voices) do all[#all + 1] = who end
            for i = 1, #all do let_go(all[i]) end
            told.left = {}
        end)
    end)
    if type(RegisterHook) ~= "function" then return end
    for name, path in pairs(M.TOLD) do
        local source = sources[name]
        source.pace_before, M.PACE[name] = M.PACE[name], M.TOLD_PACE
        source.prompt = prompt(source, path, name == "Weight" and component_owner or nil)
    end
end

M.events = told.events

-- for the modules that give characters more: stats, items, actions

local function classes_of(kind)
    if kind == "character" then return M.UNPROVEN and { M.CHARACTER, M.PAWN } or M.CHARACTER end
    if kind == "player" then return M.PLAYER end
    return nil
end

-- easy.class for every character ("character") or for a player's ("player"). game.Me then knows the names with no character too.
function M.extend(kind, spec, source)
    local classes = classes_of(kind)
    if not classes then error("character.extend: the kind is \"character\" or \"player\", got " .. tostring(kind), 2) end
    local undo = easy.class(classes, spec, source)
    note(spec)
    return undo
end

-- The state component of a character's engine object, or nil. For one use: it is never kept.
function M.state(raw) return part(raw, "ActorState") end

M.part = part
M.place = place
M.current = current
M.me = Me

function M.start()
    if M.UNPROVEN then character_fields.Sprinting = flag("bIsSprinting") end
    local events_ok, events_problem = pcall(events_start)
    if not events_ok then log:warn("what the game tells by itself could not be set up: %s", clean(events_problem)) end
    M.extend("character", { fields = character_fields, setters = character_setters, methods = character_methods }, "character")
    M.extend("player", { fields = player_fields, setters = player_setters }, "character")
    game_root = Wax.import("engine.game").root
    rawset(game_root, "Me", Me)
end

function M.stats()
    local feeding = {}
    for name, source in pairs(sources) do
        feeding[name] = { handlers = handlers(source), looking = source.link ~= nil and source.link.Connected == true }
    end
    return { characters = epoch, finds = counts.finds, find_us = counts.finds > 0 and counts.seconds / counts.finds * 1e6 or 0,
        known = next(learned) ~= nil, signals = feeding,
        told = { listening = told.listening, hooked = told.undo ~= nil, waited_for = told.watched } }
end

return M
