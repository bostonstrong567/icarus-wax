-- Room beside the game's own screens: its menus are drawn smaller, from one corner, so panels get a column of their own

local Wax = ...
local input = Wax.import("gui.input")
local scope = Wax.import("core.scope")

local M = {}

M.EVERY = 30        -- frames between looks, so a new map's screens are fitted too

local CORNERS = {
    ["top-left"] = { 0, 0 }, ["top"] = { 0.5, 0 }, ["top-right"] = { 1, 0 },
    ["left"] = { 0, 0.5 }, ["center"] = { 0.5, 0.5 }, ["right"] = { 1, 0.5 },
    ["bottom-left"] = { 0, 1 }, ["bottom"] = { 0.5, 1 }, ["bottom-right"] = { 1, 1 },
}

local requests = {}     -- every live request, the newest last
local shown = nil       -- the request on the screens now
local frames = 0

-- The holder of the game's menu screens (inventory, crafting, benches). Read from the game each time, never kept.
local function menus()
    local player = input.controller()
    if not player then return nil end
    local interface = player.UserInterface
    if not interface or not interface:IsValid() then return nil end
    local holder = interface.Menus
    if not holder or not holder:IsValid() then return nil end
    return holder, interface
end

-- x, y move the screens after they are made smaller, as shares of the screen: right and down are positive.
local function put(scale, corner, x, y)
    local holder, interface = menus()
    if not holder then return false end
    holder:SetRenderTransformPivot({ X = corner[1], Y = corner[2] })
    holder:SetRenderScale({ X = scale, Y = scale })
    -- the holder is laid out at the size the game designs its interface for, which is what a move is measured in
    local width, height = 3840, 2160
    local size = interface.MainSize
    if size and size:IsValid() then
        local wide, tall = size.WidthOverride, size.HeightOverride
        if type(wide) == "number" and wide > 0 and type(tall) == "number" and tall > 0 then width, height = wide, tall end
    end
    holder:SetRenderTranslation({ X = (x or 0) * width, Y = (y or 0) * height })
    return true
end

local function current()
    for at = #requests, 1, -1 do
        if requests[at].enabled then return requests[at] end
    end
    return nil
end

local function apply()
    local request = current()
    if request then
        if put(request.scale, request.corner, request.x, request.y) then shown = request end
    elseif shown then
        if put(1, CORNERS.center, 0, 0) then shown = nil end
    end
end

-- options: { scale = 0.85, corner = "bottom-left", x = 0, y = 0, enabled = true }. x and y move the screens after they
-- are made smaller, as shares of the screen (right and down are positive). The game's screens keep working.
-- Returns the request: :Set(scale, x, y), :SetEnabled(on), :Remove().
function M.create(options)
    if type(options) == "table" and type(options.FitGame) == "function" then error("write ui.FitGame({ ... }) with a dot, not a colon", 2) end
    options = options or {}
    local corner = CORNERS[options.corner or "bottom-left"]
    if not corner then error("unknown corner '" .. tostring(options.corner) .. "'", 2) end
    local function checked(scale)
        scale = tonumber(scale) or 0.85
        return math.max(0.5, math.min(1, scale))
    end
    local function share(value) return math.max(-0.5, math.min(0.5, tonumber(value) or 0)) end
    local request = { scale = checked(options.scale), corner = corner, x = share(options.x), y = share(options.y),
        enabled = options.enabled ~= false }
    requests[#requests + 1] = request
    local handle = {}
    function handle:Set(scale, x, y)
        local fresh_x, fresh_y = x ~= nil and share(x) or request.x, y ~= nil and share(y) or request.y
        scale = checked(scale)
        if scale == request.scale and fresh_x == request.x and fresh_y == request.y then return end
        request.scale, request.x, request.y = scale, fresh_x, fresh_y
        apply()
    end
    function handle:SetEnabled(on)
        on = on and true or false
        if request.enabled == on then return end
        request.enabled = on
        apply()
    end
    function handle:Remove()
        for at = #requests, 1, -1 do
            if requests[at] == request then table.remove(requests, at) end
        end
        apply()
    end
    scope.own(function() handle:Remove() end)
    apply()
    return handle
end

M.LOOK = 6          -- calls between full looks at the game's screens while the mouse stays free

local named_address, named = nil, nil      -- the last screen asked for its name, so the name is read once
local seen = { cursor = false, name = nil, tab = nil, age = 0 }

local function look()
    local holder = menus()
    if not holder then return nil end
    for index = 0, holder:GetChildrenCount() - 1 do
        local child = holder:GetChildAt(index)
        if child:IsValid() then
            local visibility = child:GetVisibility()
            if visibility ~= 1 and visibility ~= 2 then
                local address = child:GetAddress()
                if address ~= named_address then
                    named_address = address
                    named = (child:GetFullName():match("([^%.:]+)$") or ""):gsub("_%d+$", "")
                end
                local tab = nil
                if named == "UMG_MainMenu" then
                    local switcher = child.MenuSwitcher
                    if switcher:IsValid() then tab = switcher:GetActiveWidgetIndex() end
                end
                return named, tab
            end
        end
    end
    return nil
end

-- The game's own menu screen that is showing now: its name ("UMG_MainMenu", "UMG_EscapeMenu", "UMG_Processor_C" for a bench)
-- and, for the main menu, the number of its tab (0 inventory, 1 crafting, 2 tech tree, 3 talents, 4 map). Nothing when none shows.
-- Looked at the moment the game frees the mouse, then a few times a second.
function M.screen()
    local player = input.controller()
    if not player or player.bShowMouseCursor ~= true then
        seen.cursor, seen.name, seen.tab = false, nil, nil
        return nil
    end
    seen.age = seen.age + 1
    if seen.cursor and seen.age < M.LOOK then return seen.name, seen.tab end
    seen.cursor, seen.age = true, 0
    seen.name, seen.tab = look()
    return seen.name, seen.tab
end

function M.step()
    frames = frames + 1
    if frames % M.EVERY ~= 0 then return end
    if current() or shown then apply() end
end

-- The interface is going away: the game's screens get their own size back.
function M.restore()
    requests = {}
    if shown then
        pcall(put, 1, CORNERS.center, 0, 0)
        shown = nil
    end
end

function M.stats()
    local request = current()
    return { requests = #requests, scale = request and request.scale or 1, shown = shown ~= nil }
end

return M
