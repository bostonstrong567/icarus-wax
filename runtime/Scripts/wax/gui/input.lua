-- Keys and the mouse cursor: the menu key, key capture for rebinding, and switching the game into cursor mode

local Wax = ...
local root = Wax.import("gui.root")
local log = Wax.import("core.log").channel("wax.gui")

local input = {}

local MOUSE_DO_NOT_LOCK = 0

local key_structs = {}
local cursor = nil          -- { address, stacked, was_shown } while cursor mode is on
local capture = nil
local swallow = 0           -- frames left in which a captured key press is not treated as a shortcut

local CAPTURE_KEYS = {
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
    "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    "Insert", "Delete", "Home", "End", "PageUp", "PageDown", "Tab", "CapsLock", "SpaceBar", "BackSpace", "Enter",
    "LeftShift", "RightShift", "LeftControl", "RightControl", "LeftAlt", "RightAlt",
    "Up", "Down", "Left", "Right", "Tilde", "Hyphen", "Equals", "LeftBracket", "RightBracket", "Backslash",
    "Semicolon", "Apostrophe", "Comma", "Period", "Slash",
    "NumPadZero", "NumPadOne", "NumPadTwo", "NumPadThree", "NumPadFour", "NumPadFive", "NumPadSix", "NumPadSeven",
    "NumPadEight", "NumPadNine", "Multiply", "Add", "Subtract", "Decimal", "Divide",
    "MiddleMouseButton", "ThumbMouseButton", "ThumbMouseButton2",
}

-- The local player controller, read from the game every time: nothing engine-side is kept between frames.
function input.controller()
    local game = Wax.game
    local found = game and game.LocalPlayer
    return found and found.Raw or nil
end

local function key_struct(key)
    local struct = key_structs[key]
    if not struct then
        struct = { KeyName = FName(key) }
        key_structs[key] = struct
    end
    return struct
end

function input.just_pressed(key)
    local player = input.controller()
    if not player then return false end
    return player:WasInputKeyJustPressed(key_struct(key)) == true
end

-- callback(key) runs with the next key pressed, or with nil if Escape cancels.
function input.capture(callback) capture = callback end
function input.capturing() return capture ~= nil or swallow > 0 end

local function has_ui_stack(player)
    local class = StaticFindObject("/Script/Icarus.IcarusPlayerController")
    return class:IsValid() and player:IsA(class)
end

-- While the menu is open the game must not act on keys or clicks: the world settings actor blocks input from the top of the input stack.
local blocking = false

local function world_settings()
    local world = Wax.game and Wax.game.World
    local settings = world and world.Raw:K2_GetWorldSettings() or nil
    return settings and settings:IsValid() and settings or nil
end

local function block_game(player, on)
    local settings = world_settings()        -- read again every time, because it is destroyed with the map
    if not settings then
        blocking = false
        return
    end
    if on then
        settings.bBlockInput = true
        settings.InputPriority = 1000000
        settings:EnableInput(player)
    else
        settings:DisableInput(player)
    end
    blocking = on
end

function input.blocking() return blocking end

-- Gives the game its keys back. Safe to call at any time.
function input.unblock()
    local player = input.controller()
    if player then pcall(block_game, player, false) end
    blocking = false
end

local function cursor_on(player)
    local state = { address = player:GetAddress(), stacked = has_ui_stack(player), was_shown = player.bShowMouseCursor == true }
    if state.stacked then
        -- The game's own stack of menus: it restores whatever was underneath when this entry is popped.
        player:PushUIInput(root.widget(), true, true)
    elseif not state.was_shown then
        player.bShowMouseCursor = true
        root.library("WidgetBlueprintLibrary"):SetInputMode_GameAndUIEx(player, root.widget(), MOUSE_DO_NOT_LOCK, false)
    end
    local ok, problem = pcall(block_game, player, true)
    if not ok then log:warn("could not keep the game from acting on input: %s", tostring(problem)) end
    return state
end

-- Only the controller the cursor was switched on for can have it switched off. After a map change that controller is gone.
local function current_if_same(state)
    local player = input.controller()
    if player and player:GetAddress() == state.address then return player end
    return nil
end

local function cursor_off(state)
    local player = current_if_same(state)
    if not player then
        blocking = false        -- that controller and its world are gone, and the block with them
        return
    end
    pcall(block_game, player, false)
    if state.stacked then
        player:PopUIInput()
    elseif not state.was_shown then
        player.bShowMouseCursor = false
        root.library("WidgetBlueprintLibrary"):SetInputMode_GameOnly(player)
    end
end

-- Mouse cursor on and clicks to the windows, or back to normal play.
function input.set_cursor(on)
    if on then
        if cursor and current_if_same(cursor) then return true end
        cursor = nil
        local player = input.controller()
        if not player then return false end
        local ok, state = pcall(cursor_on, player)
        if not ok then
            log:warn("could not switch to cursor mode: %s", tostring(state))
            return false
        end
        cursor = state
        return true
    end
    if cursor then
        local state = cursor
        cursor = nil
        local ok, err = pcall(cursor_off, state)
        if not ok then log:warn("could not leave cursor mode: %s", tostring(err)) end
    end
    return true
end

function input.forget() cursor, capture, swallow, blocking = nil, nil, 0, false end

function input.cursor_active() return cursor ~= nil and current_if_same(cursor) ~= nil end

function input.step()
    if swallow > 0 then swallow = swallow - 1 end
    if not capture then return end
    local player = input.controller()
    if not player then return end
    if player:WasInputKeyJustPressed(key_struct("Escape")) == true then
        local callback = capture
        capture = nil
        callback(nil)
        return
    end
    for i = 1, #CAPTURE_KEYS do
        if player:WasInputKeyJustPressed(key_struct(CAPTURE_KEYS[i])) == true then
            local callback = capture
            capture, swallow = nil, 2
            callback(CAPTURE_KEYS[i])
            return
        end
    end
end

return input
