-- game.Crafting: the bench or crafting screen that is open, the recipes it lists, and choosing one of them

local Wax = ...
local scope = Wax.import("core.scope")

local M = {}

local LISTS = { "RecipeElements", "RecipeElementsMulti", "RecipeElementNonInteractives" }
local HIT_TEST_INVISIBLE = 3
local hidden = {}       -- address of a list hidden now -> the visibility it had

local function controller()
    local game = Wax.game
    local player = game and game.LocalPlayer
    return player and player.Raw or nil
end

local function showing(widget)
    local visibility = widget:GetVisibility()
    return visibility ~= 1 and visibility ~= 2
end

-- The open screen that has a recipe list, and that list: a bench, or the crafting tab. On the other tabs of the game's
-- menu (kind "menu") it is the crafting tab's list too, which is what the player can make by hand. Read each time, never kept.
local function open_screen()
    local player = controller()
    if not player or player.bShowMouseCursor ~= true then return nil end
    local interface = player.UserInterface
    if not interface or not interface:IsValid() then return nil end
    local screen = interface.CurrentDynamicWidget
    if screen and screen:IsValid() then
        local parent = screen:GetParent()
        local list = screen.UMG_RecipeList
        if parent and parent:IsValid() and list and list:IsValid() and showing(screen) then return screen, list, "bench" end
    end
    local main = interface.UMG_MainMenu
    if main and main:IsValid() and showing(main) then
        local switcher = main.MenuSwitcher
        local tab = switcher and switcher:IsValid() and switcher:GetActiveWidgetIndex()
        if type(tab) == "number" then
            local crafting = main.UMG_Crafting
            local list = crafting and crafting:IsValid() and crafting.UMG_RecipeList
            if list and list:IsValid() then return crafting, list, tab == 1 and "crafting" or "menu" end
        end
    end
    return nil
end

-- Calls fn(tile, row) for each recipe tile of a list, until fn returns true.
local function each_tile(list, fn)
    for _, name in ipairs(LISTS) do
        local tiles = list[name]
        -- the length first: reading one past the end makes the game's array longer
        local count = tiles:GetArrayNum()
        for index = 1, count do
            local tile = tiles[index]
            if tile:IsValid() then
                local row = tile.ProcessorRecipe.RowName:ToString()
                if row ~= "" and row ~= "None" and fn(tile, row) then return true end
            end
        end
    end
    return false
end

local Crafting = {}

-- The recipes the open screen lists, in the game's order: { { row = "Iron_Ingot", valid = true } }, then a number that
-- stays the same while that screen stays open, then "bench", "crafting" or "menu". Nothing when none is open.
-- `valid` is the game's own answer to "can this be made right now".
function Crafting:GetRecipes()
    local screen, list, kind = open_screen()
    if not list then return nil end
    local out, seen = {}, {}
    each_tile(list, function(tile, row)
        if not seen[row] then
            seen[row] = true
            out[#out + 1] = { row = row, valid = tile.Valid == true }
        end
    end)
    return out, screen:GetAddress(), kind
end

-- The number of the screen that is open, without reading its recipes. Nothing when none is.
function Crafting:GetScreen()
    local screen, _, kind = open_screen()
    if not screen then return nil end
    return screen:GetAddress(), kind
end

-- From another tab of the game's menu to its crafting tab, the way the game's own key for crafting does it. True when
-- the crafting tab was asked for or is showing already, false on any other screen.
function Crafting:OpenTab()
    local _, _, kind = open_screen()
    if kind == "crafting" then return true end
    if kind ~= "menu" then return false end
    local player = controller()
    local interface = player and player.UserInterface
    if not interface or not interface:IsValid() then return false end
    interface:TogglePlayerCrafting()
    return true
end

-- Chooses a recipe on the open screen, as a click on its tile does. False when the screen does not list it,
-- and on the other tabs of the menu, where there is nothing to choose it on.
function Crafting:Select(row)
    if type(row) ~= "string" or row == "" then error("game.Crafting:Select expects a recipe's row name", 2) end
    local _, list, kind = open_screen()
    if not list or kind == "menu" then return false end
    local wanted = row:lower()
    return each_tile(list, function(tile, name)
        if name:lower() ~= wanted then return false end
        list["On Recipe Selected"](list, tile.ProcessorRecipe)
        return true
    end)
end

-- The item of the slot under the mouse in one of the game's own slot lists, as its row name in D_ItemsStatic.
local function hovered_slot(holder)
    if not holder or not holder:IsValid() then return nil end
    local slots = holder.Slots
    local count = slots:GetArrayNum()
    for index = 1, count do
        local slot = slots[index]
        if slot:IsValid() and slot:IsHovered() then
            local row = slot.Item.ItemStaticData.RowName:ToString()
            if row ~= "" and row ~= "None" then return row end
            return nil
        end
    end
    return nil
end

local function hovered_tile(list)
    if not list or not list:IsValid() then return nil end
    for _, name in ipairs(LISTS) do
        local tiles = list[name]
        local count = tiles:GetArrayNum()
        for index = 1, count do
            local tile = tiles[index]
            if tile:IsValid() and tile:IsHovered() then
                local row = tile.ProcessorRecipe.RowName:ToString()
                if row ~= "" and row ~= "None" then return row end
                return nil
            end
        end
    end
    return nil
end

local function child(widget, name)
    if not widget or not widget:IsValid() then return nil end
    local found = widget[name]
    return found and found:IsValid() and found or nil
end

local function look_under_mouse()
    local player = controller()
    if not player or player.bShowMouseCursor ~= true then return nil end
    local interface = player.UserInterface
    if not interface or not interface:IsValid() then return nil end
    local screen = interface.CurrentDynamicWidget
    if screen and screen:IsValid() and showing(screen) then
        local parent = screen:GetParent()
        if parent and parent:IsValid() then
            local row = hovered_slot(child(screen, "Player")) or hovered_slot(child(child(screen, "UMG_DeviceInventory"), "Inventory"))
                or hovered_slot(child(child(screen, "UMG_FuelInventory"), "UMG_Inventory"))
            if row then return "item", row end
            row = hovered_tile(child(screen, "UMG_RecipeList"))
            if row then return "recipe", row end
        end
    end
    local main = interface.UMG_MainMenu
    if main and main:IsValid() and showing(main) then
        local switcher = main.MenuSwitcher
        local tab = switcher and switcher:IsValid() and switcher:GetActiveWidgetIndex()
        if tab == 0 then
            local row = hovered_slot(child(child(main, "UMG_MainInventory"), "UMG_Inventory"))
            if row then return "item", row end
        elseif tab == 1 then
            local crafting = child(main, "UMG_Crafting")
            local row = hovered_slot(child(crafting, "UMG_Inventory"))
            if row then return "item", row end
            row = hovered_tile(child(crafting, "UMG_RecipeList"))
            if row then return "recipe", row end
        end
    end
    return nil
end

-- What the mouse is over in the game's own screens: "item" and its row name in D_ItemsStatic for a slot of the inventory
-- or of a bench, "recipe" and its row name in D_ProcessorRecipes for a recipe tile. Nothing when it is over neither.
-- It walks the open screen's slots, so ask when a key is pressed, not every frame.
function Crafting:GetHovered()
    local ok, kind, row = pcall(look_under_mouse)
    if ok then return kind, row end
    return nil
end

local function show_again()
    local _, list = open_screen()
    if not list then
        hidden = {}
        return
    end
    local address = list:GetAddress()
    local was = hidden[address]
    hidden = {}
    if was == nil then return end
    list:SetRenderOpacity(1)
    list:SetVisibility(was)
end

-- Hides the game's own recipe list on the open screen, or shows it again. Hidden, it keeps its place and takes no clicks.
-- A screen opened later has its list again. False when no such screen is open.
function Crafting:SetListHidden(on)
    if not on then
        show_again()
        return true
    end
    local _, list = open_screen()
    if not list then return false end
    local address = list:GetAddress()
    if hidden[address] ~= nil then return true end
    hidden = { [address] = list:GetVisibility() }
    list:SetRenderOpacity(0)
    list:SetVisibility(HIT_TEST_INVISIBLE)
    scope.own(show_again)
    return true
end

function M.start()
    rawset(Wax.import("engine.game").root, "Crafting", Crafting)
end

M.api = Crafting
return M
