-- game.Players: the characters of everyone in the session, kept as a live list

local Wax = ...
local track = Wax.import("engine.track")
local instance = Wax.import("engine.instance")

local M = {}

local tracked = track.define("players", {
    roots = { "/Script/Icarus.IcarusPlayerCharacter" },
    seed = { "IcarusPlayerCharacter" },
    classify = function() return "Player" end,
})

local function everyone() return true end

local added = {}

-- Calls fn(character) for each player's character that is here now and each that appears later (a join, a respawn).
-- If fn returns a function, it runs when that character is gone or the watch is stopped.
function added.ObserveCharacters(_, fn)
    if type(fn) ~= "function" then error("ObserveCharacters expects a function, got " .. type(fn), 2) end
    return tracked:use():observe(everyone, fn, "Players:ObserveCharacters")
end

-- The name of the player who controls a character, or nil while the game has not said yet.
function added.GetName(_, character)
    if not instance.is_instance(character) or not character:IsA("Pawn") then
        error("game.Players:GetName expects a player's character", 2)
    end
    local state = character.PlayerState
    if not state then return nil end
    local name = state:GetPlayerName()
    return name ~= "" and name or nil
end

-- True for the character this player controls.
function added.IsLocal(_, character)
    local mine = Wax.game.Character
    return mine ~= nil and mine == character
end

function M.start()
    local game = Wax.import("engine.game")
    local players = game.root.Players
    for name, fn in pairs(added) do
        rawset(players, name, fn)
        game.player_names[#game.player_names + 1] = name
    end
    for _, name in ipairs({ "CharacterAdded", "CharacterRemoved" }) do game.player_names[#game.player_names + 1] = name end
    -- The two signals start the tracking when a mod first asks for them.
    local meta = getmetatable(players)
    local fallback = meta.__index
    meta.__index = function(self, key)
        if key == "CharacterAdded" then return tracked:use().Added end
        if key == "CharacterRemoved" then return tracked:use().Removed end
        return fallback(self, key)
    end
end

M.tracked = tracked
return M
