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
local capture_alone = nil   -- Ctrl, Shift or Alt pressed during a capture, until another key joins it or it comes up

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

-- A key can be held with Ctrl, Shift or Alt: "Ctrl+Three", "Ctrl+Shift+K". The last part is the key itself.
local MODIFIERS = { ctrl = { "LeftControl", "RightControl" }, shift = { "LeftShift", "RightShift" }, alt = { "LeftAlt", "RightAlt" } }
local MODIFIER_OF = { LeftControl = "ctrl", RightControl = "ctrl", LeftShift = "shift", RightShift = "shift", LeftAlt = "alt",
    RightAlt = "alt" }
local WORDS = { ctrl = "ctrl", control = "ctrl", shift = "shift", alt = "alt" }
local parsed = {}

-- "Ctrl+Three" as { key = "Three", ctrl = true, shift = false, alt = false, held = true }. A plain key has held = false.
function input.parse(name)
    local known = parsed[name]
    if known then return known end
    local out = { key = name, ctrl = false, shift = false, alt = false, held = false }
    local parts = {}
    for part in tostring(name):gmatch("[^+]+") do parts[#parts + 1] = part end
    if #parts > 1 then
        out.key = parts[#parts]
        for at = 1, #parts - 1 do
            local which = WORDS[parts[at]:lower()]
            if not which then error("'" .. parts[at] .. "' is not Ctrl, Shift or Alt (in the key '" .. tostring(name) .. "')", 3) end
            out[which], out.held = true, true
        end
    end
    parsed[name] = out
    return out
end

local function down(player, which)
    local keys = MODIFIERS[which]
    return player:IsInputKeyDown(key_struct(keys[1])) == true or player:IsInputKeyDown(key_struct(keys[2])) == true
end

-- Which of Ctrl, Shift and Alt are held right now.
function input.modifiers()
    local player = input.controller()
    if not player then return false, false, false end
    return down(player, "ctrl"), down(player, "shift"), down(player, "alt")
end

-- True in the frame the key goes down. A key written with Ctrl, Shift or Alt counts only with exactly those held.
function input.just_pressed(key)
    local player = input.controller()
    if not player then return false end
    local want = input.parse(key)
    if player:WasInputKeyJustPressed(key_struct(want.key)) ~= true then return false end
    if not want.held then return true end
    return down(player, "ctrl") == want.ctrl and down(player, "shift") == want.shift and down(player, "alt") == want.alt
end

function input.just_released(key)
    local player = input.controller()
    if not player then return false end
    return player:WasInputKeyJustReleased(key_struct(key)) == true
end

-- callback(key) runs with the next key pressed, or with nil if Escape cancels.
function input.capture(callback) capture, capture_alone = callback, nil end
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
        local key = CAPTURE_KEYS[i]
        if player:WasInputKeyJustPressed(key_struct(key)) == true then
            if MODIFIER_OF[key] then
                -- Ctrl, Shift or Alt may be the start of "Ctrl+3": it is taken on its own only once it comes up alone
                capture_alone = key
            else
                local name = key
                if down(player, "alt") then name = "Alt+" .. name end
                if down(player, "shift") then name = "Shift+" .. name end
                if down(player, "ctrl") then name = "Ctrl+" .. name end
                local callback = capture
                capture, swallow, capture_alone = nil, 2, nil
                callback(name)
                return
            end
        end
    end
    if capture_alone and player:WasInputKeyJustReleased(key_struct(capture_alone)) == true then
        local callback, key = capture, capture_alone
        capture, swallow, capture_alone = nil, 2, nil
        callback(key)
    end
end

return input
