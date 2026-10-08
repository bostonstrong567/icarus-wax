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

local function visibility_of(widget)
    local visibility = widget:GetVisibility()
    -- UE4SS leaves a global behind for an enum it hands over
    rawset(_G, "Enum_ReturnValue", nil)
    return visibility
end

local function showing(widget)
    local visibility = visibility_of(widget)
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

local TILES = { "UMG_RecipeElement", "UMG_ListElement" }     -- how the classes of recipe tiles start
local TEXT_BOXES = { "EditableText", "EditableTextBox", "MultiLineEditableText", "MultiLineEditableTextBox" }
local known = nil       -- the engine's classes the walk tells widgets apart by, found once

local function classes()
    if known then return known end
    local function class(path)
        local found = StaticFindObject(path)
        return found:IsValid() and found or nil
    end
    local found = { panel = class("/Script/UMG.PanelWidget"), user = class("/Script/UMG.UserWidget"), scroll = class("/Script/UMG.ScrollBox"),
        slot = class("/Script/Icarus.InventoryItemWidgetBase"), talent = class("/Script/Icarus.TalentWidget"), text = {} }
    for _, name in ipairs(TEXT_BOXES) do found.text[#found.text + 1] = class("/Script/UMG." .. name) end
    if not (found.panel and found.user and found.scroll) then return nil end
    known = found
    return found
end

local function row_of(handle)
    local row = handle.RowName:ToString()
    if row == "" or row == "None" then return nil end
    return row
end

-- The child of a panel that fits. A scroll box never says the mouse is over it or that the keyboard is in it (the
-- engine's own does not keep track), so its children are asked in its place.
local function child_that(panel, fits, with, depth)
    for index = panel:GetChildrenCount() - 1, 0, -1 do
        local child = panel:GetChildAt(index)
        if child:IsValid() then
            if fits(child) then return child end
            if depth < 3 and child:IsA(with.scroll) then
                local inner = child_that(child, fits, with, depth + 1)
                if inner then return inner end
            end
        end
    end
    return nil
end

-- From the game's own interface down the one line of widgets that fit, calling at(widget, with) on each until it answers.
local function walk(fits, at, with_mouse)
    local player = controller()
    if not player or (with_mouse and player.bShowMouseCursor ~= true) then return nil end
    local interface = player.UserInterface
    local with = classes()
    if not with or not interface or not interface:IsValid() or not fits(interface) then return nil end
    local widget = interface
    for _ = 1, 96 do
        local kind, row = at(widget, with)
        if kind ~= nil then return kind or nil, row end
        local below = nil
        if widget:IsA(with.user) then
            local tree = widget.WidgetTree
            below = tree:IsValid() and tree.RootWidget or nil
            if below and not below:IsValid() then below = nil end
        elseif widget:IsA(with.panel) then
            below = child_that(widget, fits, with, 1)
        end
        if not below then return nil end
        widget = below
    end
    return nil
end

local function mouse_over(widget) return widget:IsHovered() == true end
local function keyboard_in(widget) return widget:HasKeyboardFocus() == true or widget:HasFocusedDescendants() == true end

-- What one widget under the mouse stands for. false: it is a slot or a tile with nothing in it, so the walk ends there.
local function meaning(widget, with)
    if with.slot and widget:IsA(with.slot) then
        local row = row_of(widget.Item.ItemStaticData)
        return row and "item" or false, row
    end
    if with.talent and widget:IsA(with.talent) then
        local row = row_of(widget.Talent)
        return row and "talent" or false, row
    end
    if widget:IsA(with.user) then
        -- a recipe tile, whatever kind of list it is in: its class is named for it
        local name = widget:GetClass():GetFName():ToString()
        if name:find(TILES[1], 1, true) == 1 or name:find(TILES[2], 1, true) == 1 then
            local row = row_of(widget.ProcessorRecipe)
            return row and "recipe" or false, row
        end
    end
    return nil
end

local function is_text_box(widget, with)
    for _, class in ipairs(with.text) do
        if widget:IsA(class) then return true end
    end
    return nil
end

-- What the mouse is over in the game's own screens, whichever is open: "item" and its row name in D_ItemsStatic for a
-- slot of any inventory, "recipe" and its row name in D_ProcessorRecipes for a recipe tile, "talent" and its row name
-- in D_Talents for a node of the tech tree or the talents. Nothing over anything else, or over an empty slot.
-- It asks its way down the widgets under the mouse, so ask when a key is pressed, not every frame.
function Crafting:GetHovered()
    local ok, kind, row = pcall(walk, mouse_over, meaning, true)
    if ok then return kind, row end
    return nil
end

-- True while one of the game's own text boxes has the keyboard, such as the search box of the crafting screen.
-- It asks its way down the widgets the keyboard is in, so ask when a key is pressed, not every frame.
function Crafting:IsTyping()
    local ok, typing = pcall(walk, keyboard_in, is_text_box)
    return ok and typing == true
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
    hidden = { [address] = visibility_of(list) }
    list:SetRenderOpacity(0)
    list:SetVisibility(HIT_TEST_INVISIBLE)
    scope.own(show_again)
    return true
end

M.REFRESH_BENCH = false     -- building the list of an open bench again was never tried at a bench, so a bench is left as it is

local REFRESH_OPTIONS = { "lists", "recipes" }
local due = nil             -- what the refresh at the end of this frame is to do: { lists, all, rows, frame }

-- Chooses a recipe on a list again, as a click on its tile does. False when the list no longer has it.
local function choose(list, row)
    local wanted = row:lower()
    return each_tile(list, function(tile, name)
        if name:lower() ~= wanted then return false end
        list["On Recipe Selected"](list, tile.ProcessorRecipe)
        return true
    end)
end

-- Chooses the recipe the tab holds once more. The tab builds its "needs" row only for another recipe than it holds,
-- so another tile is chosen first.
local function choose_again(screen, list, row)
    local wanted = row:lower()
    local held = row_of(screen.Recipe)
    if held and held:lower() == wanted then
        each_tile(list, function(tile, name)
            if name:lower() == wanted then return false end
            list["On Recipe Selected"](list, tile.ProcessorRecipe)
            return true
        end)
    end
    return choose(list, row)
end

local function refresh_now()
    local asked = due
    due = nil
    if not asked then return end
    local screen, list, kind = open_screen()
    if kind == "crafting" then
        local was = row_of(screen.Recipe)
        if asked.lists then
            -- the game's own way to build the tab's list from the table. It ends with nothing chosen
            screen:RefreshRecipes()
            list = screen.UMG_RecipeList
        end
        screen.FullUpdateRequested = true
        if was and (asked.lists or asked.all or asked.rows[was:lower()]) then choose_again(screen, list, was) end
    elseif kind == "bench" and M.REFRESH_BENCH and asked.lists then
        local was = row_of(screen.LastSelected)
        list:Initialise(list.CachedRecipeSet, screen.AutoSelect == true, screen.UseInput == true)
        screen:UpdateAllRecipeStates()
        if was then choose(screen.UMG_RecipeList, was) end
    end
end

-- Asks the crafting tab to show what the recipe table holds now: one refresh when the frame ends, and only if that tab shows.
function Crafting:Refresh(options)
    if options ~= nil and type(options) ~= "table" then
        error("game.Crafting:Refresh takes a table of options such as { lists = false }, or nothing", 2)
    end
    local lists, rows = true, nil
    for key, value in pairs(options or {}) do
        if key == "lists" then
            if type(value) ~= "boolean" then error("lists is true or false", 2) end
            lists = value
        elseif key == "recipes" then
            if type(value) ~= "table" then error("recipes is a list of recipe names such as { \"Stone_Axe\" }", 2) end
            rows = value
        else
            local near = type(key) == "string" and Wax.import("core.suggest").phrase(key, REFRESH_OPTIONS) or ""
            error(("game.Crafting:Refresh has no option named %s.%s"):format(tostring(key), near), 2)
        end
    end
    local sched = Wax.import("core.sched")
    local frame = sched.stats.frame
    local waiting = due
    -- a refresh that was asked for two frames ago and never ran was dropped, and is asked for again
    local fresh = not waiting or frame - waiting.frame > 1
    waiting = waiting or { lists = false, all = false, rows = {} }
    waiting.frame = frame
    if lists then waiting.lists = true end
    if rows then
        for _, name in ipairs(rows) do
            if type(name) == "string" then waiting.rows[name:lower()] = true end
        end
    else
        waiting.all = true
    end
    due = waiting
    if fresh then
        -- the refresh belongs to no mod: it must run even when the mod that asked is gone by the end of the frame
        local previous = scope.enter(nil)
        local ok, thread = pcall(sched.task.defer, refresh_now)
        scope.leave(previous)
        if not ok then
            due = nil
            error(thread, 2)
        end
        sched.task.label(thread, "crafting refresh")
    end
end

function M.start()
    rawset(Wax.import("engine.game").root, "Crafting", Crafting)
end

M.api = Crafting
return M
