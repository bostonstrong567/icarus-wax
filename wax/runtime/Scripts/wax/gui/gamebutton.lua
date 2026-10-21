-- A button inside one of the game's own screens, built as the game builds its buttons: ui.GameButton

local Wax = ...
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local log = Wax.import("core.log").channel("wax.gamebutton")

local M = {}

M.PREFIX = "WaxGameButton_"
M.HAND = 9
local RF_TRANSIENT = 0x40

local live = {}             -- every button that exists, in the order made
local sequence = 0
local loop = nil
local classes = {}          -- widget classes by kind, looked up once

local function address(object)
    local ok, value = pcall(function() return object:GetAddress() end)
    if ok and type(value) == "number" and value ~= 0 then return value end
    return nil
end

-- An Instance stands for its UE4SS object; anything else is taken as it is (rawget: a stand-in object answers every key).
local function raw_of(value)
    if type(value) == "table" then
        local inner = rawget(value, "Raw")
        if inner ~= nil then return inner end
    end
    return value
end

local function valid(widget)
    local ok, yes = pcall(function() return widget:IsValid() end)
    return ok and yes == true
end

-- The engine's own answer to "is the screen still there", asked without touching it (IsValid reads freed memory).
local library = nil
local function weak_of(object)
    if library == nil then
        local ok, found = pcall(function() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end)
        library = (ok and valid(found)) and found or false
    end
    if not library then return nil end
    local ok, made = pcall(function() return library:Conv_ObjectToSoftObjectReference(object):GetWeakPtr() end)
    if ok then return made end
    return nil
end

local function screen_there(handle)
    if handle == nil then return false end
    if handle.watch == nil then return true end
    local ok, there = pcall(function() return handle.watch:Get():GetAddress() ~= 0 end)
    return ok and there == true
end

local function new_widget(kind, outer)
    sequence = sequence + 1
    local class = classes[kind]
    if not valid(class) then
        class = StaticFindObject("/Script/UMG." .. kind)
        classes[kind] = class
    end
    if not valid(class) then error("the engine has no widget class " .. kind, 0) end
    return StaticConstructObject(class, outer, FName(("%s%s_%d_%d"):format(M.PREFIX, kind, os.time(), sequence)), RF_TRANSIENT)
end

local function plain(color) return { R = color.R, G = color.G, B = color.B, A = color.A } end
local function slate(color) return { SpecifiedColor = color, ColorUseRule = 0 } end
local function margin(left, top, right, bottom) return { Left = left, Top = top, Right = right, Bottom = bottom } end

local function copy_slot(from, to)
    local ok, slot = pcall(function() return from.Slot end)
    if not ok or not slot or not valid(slot) then return end
    pcall(function() local p = slot.Padding to:SetPadding(margin(p.Left, p.Top, p.Right, p.Bottom)) end)
    pcall(function() to:SetHorizontalAlignment(slot.HorizontalAlignment) end)
    pcall(function() to:SetVerticalAlignment(slot.VerticalAlignment) end)
end

local function size_of(widget)
    local ok, size = pcall(function() return widget:GetDesiredSize() end)
    if ok and size then return size.X, size.Y end
    return nil
end

-- Takes out what an earlier life of a mod left in a panel: widgets of ours, by their names.
function M.sweep(panel)
    panel = raw_of(panel)
    if not valid(panel) then return 0 end
    local removed = 0
    for at = panel:GetChildrenCount() - 1, 0, -1 do
        local child = panel:GetChildAt(at)
        local ok, name = pcall(function() return child:GetFName():ToString() end)
        if ok and name:sub(1, #M.PREFIX) == M.PREFIX then
            pcall(function() child:RemoveFromParent() end)
            removed = removed + 1
        end
    end
    return removed
end

local function restore(handle)
    for _, entry in ipairs(handle.room) do
        if valid(entry.box) then pcall(function() entry.box:SetWidthOverride(entry.was) end) end
    end
end

-- spec: like (one of the game's UMG_BasicButton_2_C buttons, whose brushes, font and colours are copied), row (the
-- HorizontalBox it goes into), caption, width (the game's units), room (a list of { box = a SizeBox of the row, width = }
-- that give up width so the row keeps its size), grow (true for a row of your own that may grow). It goes at the end of the row.
-- The row's desired size is read before and after; when it changed, everything is undone and an error says so.
function M.create(spec, on_click)
    if type(spec) ~= "table" then error("ui.GameButton expects a table such as { like = sort.SortButton, row = box, caption = \"STASH\" }", 2) end
    if on_click ~= nil and type(on_click) ~= "function" then error("ui.GameButton expects a function to run on a click as its second value", 2) end
    local model, row = raw_of(spec.like), raw_of(spec.row)
    if not valid(model) or not valid(model.ImageButton) or not valid(model.ButtonText) then error("spec.like must be one of the game's text buttons (UMG_BasicButton_2_C)", 2) end
    local adder = valid(row) and row.AddChildToHorizontalBox or nil
    if type(adder) ~= "userdata" and type(adder) ~= "function" then error("spec.row must be a HorizontalBox of the game's screen", 2) end
    local caption = tostring(spec.caption or "")
    local width = tonumber(spec.width) or 130
    local handle = { Clicked = sched.Signal.new("Clicked"), row = row, row_addr = address(row), room = {}, down = false, over = false, alive = true }
    local before_w, before_h = size_of(row)
    for _, entry in ipairs(spec.room or {}) do
        local box = raw_of(entry.box)
        if valid(box) then handle.room[#handle.room + 1] = { box = box, was = box.WidthOverride, width = entry.width } end
    end

    local look = model.ImageButton.WidgetStyle
    local font = model.ButtonText.Font
    handle.normal, handle.hovered = plain(model.Text_Normal.SpecifiedColor), plain(model.Text_Hovered.SpecifiedColor)
    local inner_model = model.SizeBox
    local height = valid(inner_model) and inner_model.HeightOverride or 75
    local outer_model = model:GetParent()
    local tree = row:GetOuter()
    handle.watch = weak_of(tree)

    local outer = new_widget("SizeBox", tree)
    local outer_height = valid(outer_model) and outer_model.HeightOverride or nil
    if type(outer_height) == "number" and outer_height > 0 then outer:SetHeightOverride(outer_height) end
    local stack = new_widget("Overlay", tree)
    outer:SetContent(stack)
    local inner = new_widget("SizeBox", tree)
    inner:SetWidthOverride(width)
    inner:SetHeightOverride(height)
    copy_slot(inner_model, stack:AddChildToOverlay(inner))
    local blur = new_widget("BackgroundBlur", tree)
    pcall(function() blur:SetBlurStrength(model.BackgroundBlur_0.BlurStrength) end)
    copy_slot(model.BackgroundBlur_0, inner:SetContent(blur))
    local press = new_widget("Button", tree)
    local mine = press.WidgetStyle
    for _, state in ipairs({ "Normal", "Hovered", "Pressed", "Disabled" }) do
        local from, to = look[state], mine[state]
        to.ResourceObject = from.ResourceObject
        to.DrawAs = from.DrawAs
        to.Margin = margin(0, 0, 0, 0)
        to.ImageSize = { X = 0, Y = 0 }
        to.TintColor = slate({ R = 1, G = 1, B = 1, A = 1 })
    end
    mine.NormalPadding = margin(0, 0, 0, 0)
    mine.PressedPadding = margin(0, 0, 0, 0)
    press.IsFocusable = false
    press:SetCursor(M.HAND)
    copy_slot(model.ImageButton, blur:SetContent(press))
    local middle = new_widget("Overlay", tree)
    copy_slot(model.ImageButton:GetChildAt(0), press:SetContent(middle))
    local fit = new_widget("ScaleBox", tree)
    local container = model.ScaleBox_TextContainer
    pcall(function() fit:SetStretch(container.Stretch) end)
    pcall(function() fit:SetStretchDirection(container.StretchDirection) end)
    copy_slot(container, middle:AddChildToOverlay(fit))
    local text = new_widget("TextBlock", tree)
    text:SetFont({ FontObject = font.FontObject, Size = font.Size, TypefaceFontName = font.TypefaceFontName, LetterSpacing = font.LetterSpacing })
    text:SetText(FText(caption))
    text:SetColorAndOpacity(slate(handle.normal))
    pcall(function() text:SetJustification(model.ButtonText.Justification) end)
    copy_slot(model.ButtonText, fit:SetContent(text))

    for _, entry in ipairs(handle.room) do entry.box:SetWidthOverride(entry.width) end
    copy_slot(outer_model, row:AddChildToHorizontalBox(outer))
    handle.box, handle.button, handle.text = outer, press, text

    local after_w, after_h = size_of(row)
    if not spec.grow and before_w and after_w and (before_w ~= after_w or before_h ~= after_h) then
        pcall(function() outer:RemoveFromParent() end)
        restore(handle)
        error(("the row would change size, %.0fx%.0f to %.0fx%.0f: give up more width in spec.room"):format(before_w, before_h, after_w, after_h), 2)
    end

    function handle:Exists() return self.alive end
    function handle:SetCaption(words)
        if not self.alive then return end
        pcall(function() self.text:SetText(FText(tostring(words))) end)
    end
    function handle:Remove()
        if not self.alive then return end
        self.alive = false
        for index = #live, 1, -1 do
            if live[index] == self then table.remove(live, index) end
        end
        -- only a row that still exists is touched; one the game threw away took the button with it
        if screen_there(self) and valid(self.row) and address(self.row) == self.row_addr then
            pcall(function() self.box:RemoveFromParent() end)
            restore(self)
        end
    end
    if on_click then handle.Clicked:Connect(on_click) end
    live[#live + 1] = handle
    scope.own(function() handle:Remove() end)
    M.start()
    return handle
end

-- A click is the button going down and coming up again under the mouse; the words turn dark under it as the game's do.
local function step()
    for index = #live, 1, -1 do
        local handle = live[index]
        -- a closed screen is freed at the next collection: never touch its button again
        local ok, down, over = false, false, false
        if screen_there(handle) then
            ok, down, over = pcall(function() return handle.button:IsPressed(), handle.button:IsHovered() end)
        end
        if not ok then
            if handle then handle.alive = false end
            table.remove(live, index)
        else
            if over ~= handle.over then
                handle.over = over
                pcall(function() handle.text:SetColorAndOpacity(slate(over and handle.hovered or handle.normal)) end)
            end
            if down then
                handle.down = true
            elseif handle.down then
                handle.down = false
                if over then handle.Clicked:Fire() end
            end
        end
    end
end

function M.step()
    if #live > 0 then guard.call("game buttons", step) end
end

-- Until ui.step calls M.step, the buttons are looked at by a task of Wax's own.
function M.start()
    if loop or M.wired then return end
    local previous = scope.enter(nil)
    loop = sched.task.spawn(function()
        while true do
            M.step()
            sched.task.wait()
        end
    end)
    scope.leave(previous)
end

function M.stop()
    for index = #live, 1, -1 do live[index]:Remove() end
    if loop then
        pcall(sched.task.cancel, loop)
        loop = nil
    end
end

function M.count() return #live end

return M
