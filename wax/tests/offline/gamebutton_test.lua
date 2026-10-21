-- Buttons in the game's screens (ui.GameButton): tools\lua\lua54\lua.exe wax\tests\offline\gamebutton_test.lua
-- Against stand-in widgets: the row keeps its size or the button is undone, clicks are seen, and leftovers are swept.
local t = dofile("wax/tests/offline/harness.lua")

local next_address = 100
local function widget(fields)
    next_address = next_address + 1
    local self = fields or {}
    self.address = next_address
    self.children = self.children or {}
    self.valid = true
    function self:IsValid() return self.valid end
    function self:GetAddress() return self.address end
    function self:GetFName() return { ToString = function() return self.name or "Widget" end } end
    function self:GetChildrenCount() return #self.children end
    function self:GetChildAt(index) return self.children[index + 1] end
    function self:GetParent() return self.parent end
    function self:GetOuter() return self.outer or "tree" end
    function self:RemoveFromParent()
        local parent = self.parent
        if not parent then return end
        for index, child in ipairs(parent.children) do
            if child == self then table.remove(parent.children, index) end
        end
        self.parent = nil
    end
    function self:GetDesiredSize()
        if self.width_override then return { X = self.width_override, Y = self.height or 50 } end
        local width = 0
        for _, child in ipairs(self.children) do width = width + child:GetDesiredSize().X end
        return { X = width, Y = self.height or 50 }
    end
    function self:SetWidthOverride(value) self.width_override = value end
    function self:SetHeightOverride(value) self.height = value end
    function self:SetContent(child) child.parent = self self.children = { child } return { SetPadding = function() end, SetHorizontalAlignment = function() end, SetVerticalAlignment = function() end } end
    function self:AddChildToOverlay(child) child.parent = self self.children[#self.children + 1] = child return self:SetContent_slot() end
    function self:AddChildToHorizontalBox(child) child.parent = self self.children[#self.children + 1] = child return self:SetContent_slot() end
    function self:SetContent_slot() return { SetPadding = function() end, SetHorizontalAlignment = function() end, SetVerticalAlignment = function() end } end
    function self:SetBlurStrength() end
    function self:SetCursor() end
    function self:SetStretch() end
    function self:SetStretchDirection() end
    function self:SetFont() end
    function self:SetText(text) self.text = text end
    function self:SetColorAndOpacity(color) self.color = color end
    function self:SetJustification() end
    function self:IsPressed() return self.pressed == true end
    function self:IsHovered() return self.hovered == true end
    return self
end

-- the game's Sort button, as ui.GameButton reads it
local function model()
    local brush = function() return { ResourceObject = "material", DrawAs = 3 } end
    local button = widget({ WidgetStyle = { Normal = brush(), Hovered = brush(), Pressed = brush(), Disabled = brush() } })
    local text = widget({ Font = { FontObject = "font", Size = 20, TypefaceFontName = "Default", LetterSpacing = 0 }, Justification = 1 })
    local inner = widget({ width_override = 200, height = 75 })
    inner.WidthOverride, inner.HeightOverride = 200, 75
    local outer = widget({ height = 40 })
    outer.HeightOverride = 40
    function outer:GetDesiredSize() return { X = inner.width_override, Y = 40 } end
    local sort = widget({ ImageButton = button, ButtonText = text, SizeBox = inner, BackgroundBlur_0 = widget({ BlurStrength = 3 }),
        ScaleBox_TextContainer = widget({ Stretch = 2, StretchDirection = 1 }),
        Text_Normal = { SpecifiedColor = { R = 0.6, G = 0.7, B = 0.4, A = 1 } }, Text_Hovered = { SpecifiedColor = { R = 0, G = 0, B = 0, A = 1 } } })
    button.children = { widget({}) }
    sort.parent = outer
    outer.children = { sort }
    return sort, outer, inner
end

local function row_with_sort()
    local sort, outer, inner = model()
    local combo = widget({ width_override = 250 })
    combo.WidthOverride = 250
    local row = widget({ children = { combo, outer } })
    combo.parent, outer.parent = row, row
    return row, sort, combo, inner
end

local made = {}
local function construct(class, outer, name)
    local self = widget({ name = name, class = class })
    if class.path:match("Button$") then self.WidgetStyle = { Normal = {}, Hovered = {}, Pressed = {}, Disabled = {} } end
    made[#made + 1] = self
    return self
end
function StaticFindObject(path) return { IsValid = function() return true end, path = path } end
function StaticConstructObject(class, outer, name) return construct(class, outer, name) end
function FName(text) return text end
function FText(text) return text end

local owned = {}
local stepped = nil
local modules = {
    ["core.sched"] = { Signal = { new = function()
        local handlers = {}
        return { Connect = function(_, fn) handlers[#handlers + 1] = fn end, Fire = function() for _, fn in ipairs(handlers) do fn() end end }
    end }, task = { spawn = function(fn) stepped = fn return "thread" end, wait = function() error("stop") end, cancel = function() end } },
    ["core.scope"] = { own = function(undo) owned[#owned + 1] = undo end, enter = function() return nil end, leave = function() end },
    ["core.guard"] = { call = function(_, fn, ...) return pcall(fn, ...) end },
    ["core.log"] = { channel = function() return { warn = function() end } end },
}
local Wax = { import = function(name) return assert(modules[name], name) end }
local M = assert(loadfile("wax/runtime/Scripts/wax/gui/gamebutton.lua"))(Wax)

t.test("the row keeps its size when the room gives up what the button takes", function()
    local row, sort, combo, inner = row_with_sort()
    t.eq(row:GetDesiredSize().X, 450)
    local clicks = 0
    local handle = M.create({ like = sort, row = row, caption = "STASH", width = 130, room = { { box = combo, width = 170 }, { box = inner, width = 150 } } },
        function() clicks = clicks + 1 end)
    t.eq(row:GetDesiredSize().X, 450)
    t.eq(#row.children, 3)
    t.eq(row.children[3]:GetFName():ToString():sub(1, #M.PREFIX), M.PREFIX, "named after the module")
    t.eq(handle.text.text, "STASH")
    t.ok(handle:Exists())
    -- a click is a press and a release under the mouse
    handle.button.pressed, handle.button.hovered = true, true
    M.step()
    t.eq(clicks, 0)
    handle.button.pressed = false
    M.step()
    t.eq(clicks, 1)
    t.eq(handle.text.color.SpecifiedColor.R, 0, "the words turn dark under the mouse")
    handle.button.hovered = false
    M.step()
    t.eq(handle.text.color.SpecifiedColor.R, 0.6)
    -- a release away from the button is no click
    handle.button.pressed, handle.button.hovered = true, true
    M.step()
    handle.button.pressed, handle.button.hovered = false, false
    M.step()
    t.eq(clicks, 1)
    handle:Remove()
    t.eq(#row.children, 2)
    t.eq(combo.width_override, 250, "the room is given back")
    t.eq(inner.width_override, 200)
    t.ok(not handle:Exists())
    t.eq(M.count(), 0)
end)

t.test("a button that would widen the row is undone and said", function()
    local row, sort, combo, inner = row_with_sort()
    local err = t.raises(function() M.create({ like = sort, row = row, caption = "STASH", width = 130, room = { { box = combo, width = 200 } } }) end, "would change size")
    t.ok(err:find("450x50 to 530x50", 1, true), err)
    t.eq(#row.children, 2)
    t.eq(combo.width_override, 250)
    t.eq(inner.width_override, 200)
end)

t.test("leftovers of an earlier life are swept by name", function()
    local row = row_with_sort()
    local stray = widget({ name = M.PREFIX .. "SizeBox_1_1" })
    stray.parent = row
    row.children[#row.children + 1] = stray
    local other = widget({ name = "GameThing" })
    other.parent = row
    row.children[#row.children + 1] = other
    t.eq(M.sweep(row), 1)
    t.eq(#row.children, 3)
    t.eq(row.children[3], other)
end)

t.test("a wrong spec is refused in plain words", function()
    t.raises(function() M.create("no") end, "expects a table")
    local row = row_with_sort()
    t.raises(function() M.create({ like = widget({}), row = row, caption = "X" }) end, "UMG_BasicButton_2_C")
    local _, sort = row_with_sort()
    local bare = widget({})
    bare.AddChildToHorizontalBox = nil
    t.raises(function() M.create({ like = sort, row = bare, caption = "X" }) end, "HorizontalBox")
end)

t.test("the mod's scope removes it", function()
    local row, sort, combo, inner = row_with_sort()
    owned = {}
    M.create({ like = sort, row = row, caption = "STASH", width = 130, room = { { box = combo, width = 170 }, { box = inner, width = 150 } } })
    t.eq(#owned, 1)
    owned[1]()
    t.eq(#row.children, 2)
end)

t.finish("gamebutton")
