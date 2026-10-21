-- Where a mod's features run: on the host (the game that owns the world), on every player's own game, or both.
-- What mod.lua says is read here, and whether this player's game is the one a feature needs.

local Wax = ...

local M = {}

M.SIDES = { host = true, client = true, both = true }
M.WORDS = { host = "Host", client = "Client", both = "Host + client" }
M.NEEDS_HOST = "This works on the host or the server, not on a client. Ask the host to run it."
M.NEEDS_CLIENT = "This works on each player's own game, so the host sees nothing of it here."

local function word(value)
    if type(value) ~= "string" then return nil end
    value = value:lower():gsub("^%s+", ""):gsub("%s+$", "")
    return M.SIDES[value] and value or nil
end

-- The side a manifest gives: "host", "client" or "both" (the default, also for a value that is none of the three).
function M.side_of(manifest)
    return word(type(manifest) == "table" and manifest.side) or "both"
end

-- The features a manifest lists, each as { name, side }. A line reads "host: Take from nearby chests"; a table { name = , side = } is taken too.
function M.features_of(manifest)
    local out = {}
    local list = type(manifest) == "table" and manifest.features
    if type(list) ~= "table" then return out end
    for _, entry in ipairs(list) do
        local name, side = nil, nil
        if type(entry) == "string" then
            local head, rest = entry:match("^%s*(%a+)%s*:%s*(.-)%s*$")
            name, side = rest, word(head)
        elseif type(entry) == "table" then
            name, side = type(entry.name) == "string" and entry.name or nil, word(entry.side)
        end
        if name and name ~= "" and side and #out < 20 then out[#out + 1] = { name = name:sub(1, 80), side = side } end
    end
    return out
end

-- Whether this game is the one that owns the world: Wax.mode when it is there, else the game's own answer.
function M.authority()
    local mode = rawget(Wax, "mode")
    if type(mode) == "table" and mode.IsAuthority ~= nil then
        local value = mode.IsAuthority
        if type(value) == "function" then value = value(mode) end
        return value == true
    end
    local game = rawget(Wax, "game") or (Wax.modules and Wax.modules["engine.game"] and Wax.modules["engine.game"].root)
    if game == nil then
        local ok, found = pcall(Wax.import, "engine.game")
        game = ok and found.root or nil
    end
    local ok, host = pcall(function() return game and game.IsHost end)
    return ok and host == true
end

-- True when a game with a screen runs here: a dedicated server has none.
function M.has_screen()
    local mode = rawget(Wax, "mode")
    if type(mode) == "table" and mode.HasScreen ~= nil then
        local value = mode.HasScreen
        if type(value) == "function" then value = value(mode) end
        return value == true
    end
    return true
end

-- What this game is: "host", "client", "server" or "single", from Wax.mode, else worked out from the authority.
function M.kind()
    local mode = rawget(Wax, "mode")
    if type(mode) == "table" and type(mode.kind) == "string" then return mode.kind end
    if not M.has_screen() then return "server" end
    return M.authority() and "host" or "client"
end

-- Whether a feature of that side can work on this game. "both" always can.
function M.can_run(side, authority)
    side = word(side) or "both"
    if side == "both" then return true end
    if authority == nil then authority = M.authority() end
    if side == "host" then return authority == true end
    return M.has_screen()
end

-- The tip for a feature that cannot work here, or nil when it can.
function M.tip(side, authority)
    if M.can_run(side, authority) then return nil end
    return word(side) == "host" and M.NEEDS_HOST or M.NEEDS_CLIENT
end

return M
