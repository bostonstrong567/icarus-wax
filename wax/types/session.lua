---@meta _

---The time of day in the prospect, game.Time. Each field asks the game when it is read. Every field is nil while you
---are not in a prospect. No field can be assigned: the host moves the clock with Set.
---@class WaxTime
---@field Hour integer? The hour of the game's clock, from 0 to 23.
---@field Minute integer? The minute within the hour, from 0 to 59.
---@field Clock string? The time as text, hours and minutes on a 24 hour clock: "7:05", "19:30".
---@field Phase string? The part of the day, by the hours of the game's table D_TimeOfDay: "Morning" from 6, "Day" from 10, "Afternoon" from 14, "Night" from 18 to 6. nil when the table gives none for the time.
---@field IsNight boolean? True while Phase is "Night".
---@field Scale number? The speed the game's clock is set to: 1 as the game sets it. The clock does not run evenly through the day at one Scale, and runs faster at night, so read Hour and do not work it out from seconds. The first read on a map looks the game's clock up, which costs more than the reads after it.
---@field HourChanged WaxSignal<fun(hour: integer, previous: integer)> Fires when the hour is not what it was at the last look. Looked at twice a second, and only while a handler is connected. It does not fire for the hour that is found when you connect, nor for the first hour found on another map.
local Time = {}

---Moves the game's clock forward to a time later today, for the host only: in someone else's game it raises an error
---that says so. The game's clock only goes forward within a day. It would count an earlier time as the next day, and
---Wax does not do that yet, so an earlier time raises an error that says what the clock shows. The minute the clock is
---already in changes nothing.
---@param hour integer From 0 to 23.
---@param minute? integer From 0 to 59. 0 when omitted.
---@return boolean set True when the clock says that time afterwards.
function Time:Set(hour, minute) end

---One weather event that is running somewhere on the map, as game.Weather.Active lists it.
---@class WaxWeatherEvent
---@field Event string The event's row in the game's table D_WeatherEvents, such as "T2_Arctic_Snow".
---@field Biome string? The biome it is running in, as a row of D_Biomes such as "Arctic".
---@field Since integer? When it began, in seconds on the clock that game.Prospect.Elapsed counts.
---@field Tier integer? The event's tier in D_WeatherEvents, from 0 to 6.

---The weather, game.Weather. Current, Tier and IsStorm are about the weather on your own character, which the game
---tells every player. Active is the whole map, which only the host has.
---@class WaxWeather
---@field Current string? The weather event your character is in, as a row of D_WeatherEvents such as "T3_Conifer_Rain". nil in clear weather and while you have no character.
---@field Tier integer? The tier of that event in D_WeatherEvents: 0 for the lightest, such as showers, up to 6 for the heaviest. nil in clear weather.
---@field IsStorm boolean True while your character is in weather of tier 1 or more.
---@field Active WaxWeatherEvent[]? Every weather event that is running on the map, one entry for each biome it runs in. It reads each of them, so do not read it every frame. nil when you are a client in someone else's game, and outside a prospect.
---@field Changed WaxSignal<fun(current: string?, previous: string?)> Fires when the weather on your character is another event than at the last look, with nil for clear weather. Looked at once a second, and only while a handler is connected. It does not fire for the weather that is found when you connect, nor for the first found on another map.
local Weather = {}

---The prospect you are in, game.Prospect. Each field asks the game when it is read. Every field is nil while you are
---not in a prospect.
---@class WaxProspect
---@field Id string? The game's own id for this prospect, a long text of letters and digits.
---@field Name string? The prospect's name in the game's data: its row in D_ProspectList, such as "Tier1_Forest_Recon_0".
---@field Mission string? The mission's row in D_FactionMissions, such as "OLY_Forest_Recon". nil when the prospect has none.
---@field Difficulty "Easy"|"Medium"|"Hard"|"Extreme"? The prospect's difficulty.
---@field Elapsed integer? How long the prospect has run, in seconds.
---@field Duration integer? How long the prospect lasts in all, in seconds.
---@field Remaining integer? Duration less Elapsed, and never below 0. nil when the game gives no Duration above 0.
---@field IsOpenWorld boolean? The game's own mark for an open world prospect.
---@field IsOutpost boolean? The game's own mark for an outpost.
---@field Seed integer? The game's seed for this prospect.
local Prospect = {}

---What Wax adds to a player of the session: every Instance whose class is PlayerState or is built on it, which is what
---game.Players:GetPlayers() returns and what Joined hands over.
---@class WaxPlayer
---@field PlayerName string? The player's name. nil while the game has not said.
---@field IsHost boolean? True for the player who hosts the session. nil where the game does not say, as at the title screen.
---@field Character IcarusPlayerCharacter? The character the player controls right now, or nil.
