-- The session: the time of day, the weather on the player, the prospect, and the players who join and leave

local Wax = ...
local character = Wax.import("world.character")
local easy = Wax.import("engine.easy")
local instance = Wax.import("engine.instance")
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local suggest = Wax.import("core.suggest")
local log = Wax.import("core.log").channel("wax.session")

local M = {}

M.SURVIVAL = "IcarusGameStateSurvival"      -- the game state of a prospect: the clock and the prospect are its members
M.PLAYER = "PlayerState"
M.TIME_TABLE = "/Engine/Transient.D_TimeOfDay"
M.WEATHER_TABLE = "/Engine/Transient.D_WeatherEvents"
M.CLOCK_CLASS = "/Script/Icarus.TimeOfDaySubsystem"
M.SUBSYSTEMS = "SubsystemBlueprintLibrary"
M.NIGHT = "Night"                           -- the row of D_TimeOfDay that IsNight means
M.STORM_TIER = 1                            -- weather of this tier or more counts as a storm
M.DIFFICULTY = { "Easy", "Medium", "Hard", "Extreme" }      -- EMissionDifficulty from 1
M.ENUM_GLOBAL = "Enum_Difficulty"
M.DAY = 1440                                -- the game's clock counts minutes since midnight
M.PACE = { Hour = 0.5, Weather = 1, Players = 1 }           -- seconds between two looks at what feeds the signals

local type, pcall, error, tostring, pairs, ipairs, floor = type, pcall, error, tostring, pairs, ipairs, math.floor
local frame_stats = sched.stats

local game_root = nil
local state, prospect, state_frame = nil, nil, -1
local phases = nil          -- { name, first minute, minute it ends } for each part of the day, or false when the table cannot be read
local tiers = {}            -- folded weather row -> its tier, or false
local keeper = nil          -- the game's clock subsystem as an Instance, found again when the map changes
local missing, said = {}, {}
local known = {}            -- number -> Instance of the players seen at the last looks
local numbers = setmetatable({}, { __mode = "k" })      -- Instance -> the number it is known by. An address may come round again.
local last_number = 0

local function clean(problem)
    return ((tostring(problem):match("^[^\r\n]*") or ""):gsub("^.-%.lua:%d+: ", ""))
end

local function once(key, ...)
    if said[key] then return end
    said[key] = true
    log:warn(...)
end

local function number(value)
    if type(value) == "number" then return value end
    return nil
end

-- One lookup by path. What the game does not have is not looked for again on this map: a miss is slow.
local function find(path)
    if missing[path] then return nil end
    local found = StaticFindObject(path)
    if found:IsValid() then return found end
    missing[path] = true
    return nil
end

local function root()
    game_root = game_root or Wax.import("engine.game").root
    return game_root
end

-- The game state as an Instance, found once a frame, and the same again when it is a prospect's.
local function find_state()
    local frame = frame_stats.frame
    if state_frame == frame and (state == nil or state:IsValid()) then return state, prospect end
    local found = root().GameState
    state, prospect, state_frame = found, found and found:IsA(M.SURVIVAL) and found or nil, frame
    return state, prospect
end

local function raw_of(inst) return inst.Raw end

-- The engine object of a prospect's game state, for one use. Nil anywhere else.
local function prospect_raw()
    local _, found = find_state()
    if not found then return nil end
    local ok, raw = pcall(raw_of, found)
    return ok and raw or nil
end

-- time

local function minutes()
    local raw = prospect_raw()
    local value = raw and raw.TimeOfDay
    if type(value) ~= "number" then return nil end
    return value % M.DAY
end

local function read_phases()
    local data = find(M.TIME_TABLE)
    if not data then error("the game has no table at " .. M.TIME_TABLE, 0) end
    local rows, list = data:GetRowNames(), {}
    for i = 1, #rows do
        local name = rows[i]
        local row = type(name) == "string" and data:FindRow(name) or nil
        local from, to = row and row.StartingHour, row and row.EndingHour
        if type(from) == "number" and type(to) == "number" and from ~= to then
            list[#list + 1] = { name, from * 60, to * 60 }
        end
    end
    return list
end

-- The part of the day a minute falls in, by the hours of the game's own table.
local function phase_at(now)
    if phases == nil then
        local ok, list = pcall(read_phases)
        phases = ok and list or false
        if not ok then once("phases", "the parts of the day could not be read, so game.Time.Phase reads as nothing: %s", clean(list)) end
    end
    if not phases then return nil end
    for i = 1, #phases do
        local entry = phases[i]
        local from, to = entry[2], entry[3]
        if from < to then
            if now >= from and now < to then return entry[1] end
        elseif now >= from or now < to then
            return entry[1]
        end
    end
    return nil
end

local function ask_keeper(world, class) return root():Library(M.SUBSYSTEMS).Raw:GetWorldSubsystem(world, class) end

-- The subsystem that runs the clock. It lives as long as its world, and an Instance from another map refuses to be read.
local function clock_keeper()
    if keeper and keeper:IsValid() then return keeper end
    keeper = nil
    local class = find(M.CLOCK_CLASS)
    if not class then return nil end
    local has_world, world = pcall(instance.world_object)
    if not has_world then return nil end
    local ok, found = pcall(ask_keeper, world, class)
    if not ok then
        once("clock", "the game's clock could not be found, so game.Time.Scale reads as nothing: %s", clean(found))
        return nil
    end
    keeper = instance.wrap(found)
    return keeper
end

local function scale_of(inst) return inst.Raw.TimeScale end

local time = {}

function time.Hour()
    local now = minutes()
    return now and floor(now / 60)
end

function time.Minute()
    local now = minutes()
    return now and floor(now % 60)
end

function time.Clock()
    local now = minutes()
    return now and ("%d:%02d"):format(floor(now / 60), floor(now % 60))
end

function time.Phase()
    local now = minutes()
    return now and phase_at(now)
end

function time.IsNight()
    local now = minutes()
    local phase = now and phase_at(now)
    if not phase then return nil end
    return phase == M.NIGHT
end

function time.Scale()
    if not prospect_raw() then return nil end
    local found = clock_keeper()
    if not found then return nil end
    local ok, value = pcall(scale_of, found)
    return ok and number(value) or nil
end

-- weather

local function local_weather(who) return character.state(who.Raw).LocalWeatherEvent.RowName:ToString() end

-- The weather on the local player: a row of D_WeatherEvents, false for none, nil when there is no player to ask.
local function weather_now()
    local who = character.current()
    if not who then return nil end
    local ok, row = pcall(local_weather, who)
    if not ok then return nil end
    if row == "" or row == "None" then return false end
    return row
end

local function read_tier(row)
    local data = find(M.WEATHER_TABLE)
    local found = data and data:FindRow(row)
    if found == nil then return nil end
    return found.Tier
end

local function tier_of(row)
    local key = row:lower()
    local tier = tiers[key]
    if tier == nil then
        local ok, found = pcall(read_tier, row)
        tier = ok and number(found) or false
        tiers[key] = tier
    end
    return tier or nil
end

local function read_active(mode)
    local controller = mode.Raw.WeatherController
    if not controller:IsValid() then return nil end
    local running, out = controller.CurrentWeather, {}
    for i = 1, running:GetArrayNum() do
        local info = running[i]
        local event, biome = info.WeatherEvent.RowName:ToString(), info.Biome.RowName:ToString()
        out[i] = { Event = event, Biome = biome ~= "" and biome ~= "None" and biome or nil, Since = number(info.StartTime),
            Tier = tier_of(event) }
    end
    return out
end

local weather = {}

function weather.Current() return weather_now() or nil end

function weather.Tier()
    local row = weather_now()
    return row and tier_of(row) or nil
end

function weather.IsStorm()
    local row = weather_now()
    local tier = row and tier_of(row)
    return tier ~= nil and tier ~= false and tier >= M.STORM_TIER
end

function weather.Active()
    local mode = root().GameMode
    if not mode then return nil end
    local ok, list = pcall(read_active, mode)
    if ok then return list end
    once("active", "the weather that is running could not be read, so game.Weather.Active reads as nothing: %s", clean(list))
    return nil
end

-- the prospect

local function text(value)
    if type(value) ~= "string" then value = value:ToString() end
    if value == "" or value == "None" then return nil end
    return value
end

local function info_of(raw, field) return raw.ReplicatedActiveProspect[field] end

local function info_text(field)
    return function()
        local raw = prospect_raw()
        if not raw then return nil end
        local ok, value = pcall(info_of, raw, field)
        if not ok then return nil end
        ok, value = pcall(text, value)
        return ok and value or nil
    end
end

local function state_number(property)
    return function()
        local raw = prospect_raw()
        return raw and number(raw[property])
    end
end

local function state_flag(property)
    return function()
        local raw = prospect_raw()
        local value = raw and raw[property]
        if type(value) ~= "boolean" then return nil end
        return value
    end
end

local the_prospect = {
    Id = info_text("ProspectID"), Name = info_text("ProspectDTKey"), Mission = info_text("FactionMissionDTKey"),
    Elapsed = state_number("LevelTimeElapsedSec"), Duration = state_number("ProspectDurationSec"), Seed = state_number("Seed"),
    IsOpenWorld = state_flag("bIsOpenWorldProspect"), IsOutpost = state_flag("bIsOutpostProspect"),
}

function the_prospect.Difficulty()
    local raw = prospect_raw()
    if not raw then return nil end
    local ok, value = pcall(info_of, raw, "Difficulty")
    -- UE4SS leaves a global behind for each enum it reads
    if rawget(_G, M.ENUM_GLOBAL) ~= nil then rawset(_G, M.ENUM_GLOBAL, nil) end
    return ok and type(value) == "number" and M.DIFFICULTY[value] or nil
end

function the_prospect.Remaining()
    local raw = prospect_raw()
    if not raw then return nil end
    local elapsed, duration = number(raw.LevelTimeElapsedSec), number(raw.ProspectDurationSec)
    if not elapsed or not duration or duration <= 0 then return nil end
    return duration > elapsed and duration - elapsed or 0
end

-- players

local function player_name(raw)
    local name = raw.PlayerNamePrivate
    if type(name) ~= "string" then name = name:ToString() end
    if name == "" then return nil end
    return name
end

local player_fields = {}

function player_fields.PlayerName(_, raw)
    local ok, name = pcall(player_name, raw)
    return ok and name or nil
end

function player_fields.IsHost(_, raw)
    local value = raw.bIsHost
    if type(value) ~= "boolean" then return nil end
    return value
end

function player_fields.Character(_, raw) return instance.wrap(raw.PawnPrivate) end

local function read_players(body, previous)
    local list, out, now = body.PlayerArray, {}, {}
    for i = 1, list:GetArrayNum() do
        local raw = list[i]
        local player = instance.wrap(raw)
        if player then
            local id = numbers[player]
            if not id then
                last_number = last_number + 1
                id, numbers[player] = last_number, last_number
            end
            local ok, name = pcall(player_name, raw)
            out[id], now[id] = ok and name or "", player
        end
    end
    -- one that left is kept for the look that finds it gone, and dropped at the next
    for id in pairs(known) do
        if not now[id] and not (previous and previous[id] ~= nil) then known[id] = nil end
    end
    for id, player in pairs(now) do known[id] = player end
    return out
end

-- Who is in the session, as number -> name. Nil when there is no game state to ask.
local function players_now(previous)
    local found = find_state()
    if not found then return nil end
    local has_raw, raw = pcall(raw_of, found)
    if not has_raw then return nil end
    local ok, out = pcall(read_players, raw, previous)
    if ok then return out end
    once("players", "the players of the session could not be read, so Joined and Left do not fire: %s", clean(out))
    return nil
end

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
    local loaded, watch = pcall(Wax.import, "engine.watch")
    if not loaded then
        error("this signal needs engine.watch, which did not load: " .. (tostring(watch):gsub("%s*[\r\n]+%s*", " "):sub(1, 200)), 0)
    end
    local previous = scope.enter(nil)
    local ok, problem = pcall(function()
        source.inner = source.inner or watch.signal(source.label, { every = M.PACE[source.name] or 1, read = source.reader })
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

-- A value and the signals it feeds. read(previous) gives nil for nothing to say. Each outlet is { label, tell(signal, value, previous) }.
local function feed(name, label, read, outlets)
    local source = { name = name, label = label, outlets = {} }
    source.reader = function(previous)
        local value = read(previous)
        if value == nil then return previous end
        return value
    end
    source.dispatch = function(value, previous)
        for i = 1, #source.outlets do
            local outlet = source.outlets[i]
            if outlet.signal.count > 0 then outlet.tell(outlet.signal, value, previous) end
        end
    end
    local made = {}
    for i, outlet in ipairs(outlets) do
        local signal = sched.Signal.new(outlet[1])
        signal.Connect = connect
        source_of[signal] = source
        source.outlets[i] = { signal = signal, tell = outlet[2] }
        made[i] = signal
    end
    sources[name] = source
    return made
end

-- The first sight of a value is where it starts from, so nothing is told then.
local hour_changed = feed("Hour", "game.Time.Hour", time.Hour, {
    { "game.Time.HourChanged", function(signal, value, previous)
        if previous ~= nil then signal:Fire(value, previous) end
    end },
})[1]

-- false stands for no weather, which handlers get as nil
local weather_changed = feed("Weather", "game.Weather.Current", weather_now, {
    { "game.Weather.Changed", function(signal, value, previous)
        if previous ~= nil then signal:Fire(value or nil, previous or nil) end
    end },
})[1]

-- those who left are told before those who came
local roster = feed("Players", "game.Players", players_now, {
    { "game.Players.Left", function(signal, value, previous)
        if previous == nil then return end
        for id, name in pairs(previous) do
            local player = value[id] == nil and known[id]
            if player then signal:Fire(player, name ~= "" and name or nil) end
        end
    end },
    { "game.Players.Joined", function(signal, value, previous)
        if previous == nil then return end
        for id in pairs(value) do
            local player = previous[id] == nil and known[id]
            if player then signal:Fire(player) end
        end
    end },
})
local left_signal, joined_signal = roster[1], roster[2]

-- setting the time of day: the game's own call, made by the host only

local facades = {}      -- the tables mods see, filled below, so that a function can tell it was called with a colon

-- A function of game.Time or game.Weather. What it raises carries no position, so it points at the mod's line.
local function public(owner, name, fn)
    return function(self, ...)
        if not rawequal(self, facades[owner]) then error(("call %s with a colon: game.%s:%s(...)"):format(name, owner, name), 2) end
        local results = table.pack(pcall(fn, ...))
        if not results[1] then error(clean(results[2]), 2) end
        return table.unpack(results, 2, results.n)
    end
end

local function whole(value, least, most)
    local number_given = type(value) == "number" and math.tointeger(value) or nil
    if not number_given or number_given < least or number_given > most then return nil end
    return number_given
end

local function set_clock(inst, total) inst.Raw:SetTimeOfDay(total) end

-- Set(hour, minute): true when the clock says that time afterwards. The game's clock only goes forward within a day.
local set_time = public("Time", "Set", function(hour, minute)
    character.host_only("set the time of day")
    local hours, mins = whole(hour, 0, 23), minute == nil and 0 or whole(minute, 0, 59)
    if not hours or not mins then
        error("game.Time:Set expects an hour from 0 to 23 and, if you like, a minute from 0 to 59: game.Time:Set(20) or game.Time:Set(7, 30)", 0)
    end
    local now = minutes()
    if not now then error("game.Time:Set only works in a prospect, and you are not in one", 0) end
    local wanted = hours * 60 + mins
    if wanted == floor(now) then return true end
    if wanted < now then
        error(("game.Time:Set(%d, %d) is earlier than the game's clock, which says %d:%02d. That clock only goes forward within a day: "
            .. "the game would count an earlier time as the next day, and Wax does not do that yet"):format(hours, mins,
            floor(now / 60), floor(now % 60)), 0)
    end
    local found = clock_keeper()
    if not found then error("the game's clock was not found, so the time cannot be set", 0) end
    character.ask("setting the time of day", set_clock, found, wanted + 0.0)
    local after = minutes()
    return after ~= nil and floor(after) == wanted
end)

-- What the game has a call for that was never made from Lua. A wrong guess closes the game, so these only say so.
local function untried(owner, name, call)
    return public(owner, name, function()
        error(("game.%s:%s is not in this version of Wax. The game's own call for it, %s, has not been tried from Lua yet")
            :format(owner, name, call), 0)
    end)
end

local time_members = { HourChanged = hour_changed, Set = set_time, SetScale = untried("Time", "SetScale", "SetTimeScale") }
local weather_members = { Changed = weather_changed, Start = untried("Weather", "Start", "AddWeatherEvent"),
    StopAll = untried("Weather", "StopAll", "ForceStopAllWeatherEvents") }

-- what mods see

-- A table whose fields ask the game when read. `signals` are members that stay the same. Nothing of it can be assigned.
local function facade(label, getters, signals, names)
    return setmetatable({}, {
        __index = function(_, key)
            local getter = getters[key]
            if getter then return getter() end
            local signal = signals[key]
            if signal then return signal end
            error(("%s is not a member of %s.%s"):format(tostring(key), label, suggest.phrase(tostring(key), names)), 2)
        end,
        __newindex = function(_, key)
            error(("%s.%s cannot be assigned because %s is read-only"):format(label, tostring(key), label), 2)
        end,
        __tostring = function() return label end,
        __names = function() return names end,
    })
end

local Time = facade("game.Time", time, time_members,
    { "Hour", "Minute", "Clock", "Phase", "IsNight", "Scale", "HourChanged", "Set" })
local Weather = facade("game.Weather", weather, weather_members, { "Current", "Tier", "IsStorm", "Active", "Changed" })
facades.Time, facades.Weather = Time, Weather
local Prospect = facade("game.Prospect", the_prospect, {}, { "Id", "Name", "Mission", "Difficulty", "Elapsed", "Duration", "Remaining",
    "IsOpenWorld", "IsOutpost", "Seed" })

-- Called on a map change: the tables and the clock may be other ones, and the next value seen is where a signal starts from.
function M.flush()
    phases, tiers, keeper, missing, said, known = nil, {}, nil, {}, {}, {}
    state, prospect, state_frame = nil, nil, -1
    local watch = Wax.modules["engine.watch"]
    if type(watch) ~= "table" or type(watch.reset) ~= "function" then return end
    for _, source in pairs(sources) do
        if source.inner then watch.reset(source.inner) end
    end
end

local connection = nil

function M.start()
    local game = Wax.import("engine.game")
    game_root = game.root
    rawset(game_root, "Time", Time)
    rawset(game_root, "Weather", Weather)
    rawset(game_root, "Prospect", Prospect)
    local players = game_root.Players
    rawset(players, "Joined", joined_signal)
    rawset(players, "Left", left_signal)
    for _, name in ipairs({ "Joined", "Left" }) do
        local listed = false
        for _, has in ipairs(game.player_names) do listed = listed or has == name end
        if not listed then game.player_names[#game.player_names + 1] = name end
    end
    easy.class(M.PLAYER, { fields = player_fields }, "session")
    if connection then return end
    local previous = scope.enter(nil)
    connection = game_root.MapChanged:Connect(M.flush)
    scope.leave(previous)
end

function M.stats()
    local feeding = {}
    for name, source in pairs(sources) do
        feeding[name] = { handlers = handlers(source), looking = source.link ~= nil and source.link.Connected == true }
    end
    return { signals = feeding }
end

M.api = { Time = Time, Weather = Weather, Prospect = Prospect, Joined = joined_signal, Left = left_signal }
return M
