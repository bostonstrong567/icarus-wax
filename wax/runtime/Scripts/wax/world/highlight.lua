-- game.Highlight: outlines actors through walls, using the outline pass the game already has

local Wax = ...
local actors = Wax.import("engine.actors")
local instance = Wax.import("engine.instance")
local reflect = Wax.import("engine.reflect")
local scope = Wax.import("core.scope")
local suggest = Wax.import("core.suggest")
local log = Wax.import("core.log").channel("wax.highlight")

local M = {}

-- The game's outline pass draws stencil values 248 to 255, one colour each. 248 to 251 also tint the model.
local FIRST_SLOT, LAST_SLOT = 248, 255
local FILL_SLOTS, LINE_SLOTS = { 248, 249, 250, 251 }, { 254, 253, 252 }
local GAME_VALUES = {
    [248] = { 10, 10, 0 }, [249] = { 0, 5.29, 10 }, [250] = { 10, 0, 10 }, [251] = { 0, 10, 3.45 },
    [252] = { 10, 0.5, 0.5 }, [253] = { 0, 10, 10 }, [254] = { 0.3, 0.3, 0.3 },
}
local GAME_LOOKS = {
    [248] = { 1, 1, 0 }, [249] = { 0, 0.53, 1 }, [250] = { 1, 0, 1 }, [251] = { 0, 1, 0.35 },
    [252] = { 1, 0.05, 0.05 }, [253] = { 0, 1, 1 }, [254] = { 0.5, 0.5, 0.5 },
}
local NAMED = {
    Red = { 1, 0.05, 0.05 }, Orange = { 1, 0.4, 0 }, Yellow = { 1, 1, 0 }, Green = { 0, 1, 0.35 }, Cyan = { 0, 1, 1 },
    Blue = { 0, 0.53, 1 }, Purple = { 0.55, 0.2, 1 }, Magenta = { 1, 0, 1 }, Pink = { 1, 0.35, 0.65 },
    White = { 1, 1, 1 }, Grey = { 0.5, 0.5, 0.5 },
}
local COLORS = { "Red", "Orange", "Yellow", "Green", "Cyan", "Blue", "Purple", "Magenta", "Pink", "White", "Grey" }
local PASS, MATERIAL = "HighlightablePostProcess", "PPI_OutlineColored"
local BRIGHTNESS = 1.5      -- above 1 the outline glows, but much higher and every colour drifts toward white
local CHECKED_PER_FRAME, PASS_EVERY = 2, 30
local NAMES = { "Add", "Remove", "Clear", "GetAll", "Configure", "Look", "Colors" }

local marks = {}            -- actor address -> mark
local order = {}            -- the same marks as a list
local cursor, frames = 1, 0
local mesh_class, part_class, library = nil, nil, nil
local by_actor = {}         -- actor address -> { [mark] = true }, for when the actor ends play
local custom = false        -- true while Wax's copy of the outline material is in place
local painted = {}          -- what was last written to the copy
local settings = { fill = 0.25, width = 1 }
local warned_full = false
local stale = false         -- set when a mark went away, so the colours are worked out again on the next frame

local function parse(color, level)
    if color == nil then color = "Red" end
    if type(color) == "string" then
        local wanted = color:lower()
        if wanted == "gray" then wanted = "grey" end
        for _, name in ipairs(COLORS) do
            if name:lower() == wanted then
                local value = NAMED[name]
                return value[1], value[2], value[3]
            end
        end
        local r, g, b = color:match("^#?(%x%x)(%x%x)(%x%x)$")
        if r then return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255 end
        error(("'%s' is not a colour.%s Use a name (%s), \"#rrggbb\" or { R = 1, G = 0.5, B = 0 }"):format(color,
            suggest.phrase(color, COLORS), table.concat(COLORS, ", ")), level + 1)
    end
    if type(color) == "table" then
        local r, g, b = color.R or color[1], color.G or color[2], color.B or color[3]
        if type(r) == "number" and type(g) == "number" and type(b) == "number" then
            return math.max(0, math.min(1, r)), math.max(0, math.min(1, g)), math.max(0, math.min(1, b))
        end
    end
    error("a colour is a name such as \"Red\", \"#rrggbb\" or { R = 1, G = 0.5, B = 0 } with values from 0 to 1", level + 1)
end

-- The meshes a mark covers: every visible one of its actor, or the one part it was made for. They are looked up
-- each time and never kept, because a part can go while its actor stays.
local function meshes(actor, only)
    local out = {}
    local found = actor:K2_GetComponentsByClass(only and part_class or mesh_class)
    for i = 1, #found do
        local component = found[i]:get()
        if component:IsValid() then
            if only then
                if component:GetFName():ToString() == only then out[#out + 1] = component end
            elseif component.bVisible then
                out[#out + 1] = component
            end
        end
    end
    return out
end

-- Puts the mark's stencil value on every visible mesh of its actor, remembering what each mesh had before.
local function apply(mark)
    for _, component in ipairs(meshes(mark.actor, mark.only)) do
        local depth, stencil = component.bRenderCustomDepth, component.CustomDepthStencilValue
        if stencil ~= mark.slot or not depth then
            local name = component:GetFName():ToString()
            if not mark.previous[name] then
                -- A value in the outline range is the game's own look-at outline, which it takes off by itself.
                local borrowed = stencil >= FIRST_SLOT and stencil <= LAST_SLOT
                mark.previous[name] = { depth = depth, stencil = borrowed and (mark.creature and 1 or 0) or stencil }
            end
            component:SetRenderCustomDepth(true)
            component:SetCustomDepthStencilValue(mark.slot)
        end
    end
end

local function restore(mark)
    for _, component in ipairs(meshes(mark.actor, mark.only)) do
        local was = mark.previous[component:GetFName():ToString()]
        if was and component.CustomDepthStencilValue == mark.slot then
            component:SetCustomDepthStencilValue(was.stencil)
            component:SetRenderCustomDepth(was.depth)
        end
    end
end

local function is_copy(material)
    if not material:IsValid() or not material:GetFName():ToString():find("^MaterialInstanceDynamic") then return false end
    local parent = material.Parent
    return parent:IsValid() and parent:GetFName():ToString() == MATERIAL
end

-- The copies of the outline material on the player's character, read fresh each time. The first draws the lines.
-- A second one draws the tint when a tint has a colour of its own. `install` puts them there.
local function pass_copies(install, tinted)
    local me = Wax.game.Character
    if not me then return nil end
    local pawn = me.Raw
    if not reflect.class_info(pawn:GetClass()).members[PASS] then return nil end
    local component = pawn[PASS]
    if not component:IsValid() then return nil end
    local list = component.Settings.WeightedBlendables.Array
    local count = list:GetArrayNum()
    if count < 1 then return nil end
    local first = list[1]
    local material = first.Object
    if not material:IsValid() then return nil end
    local original, copy = material, nil
    if material:GetFName():ToString() == MATERIAL then
        if not install then return nil end
        copy = library:CreateDynamicMaterialInstance(component, material, FName("None"), 0)
        if not copy:IsValid() then return nil end
        first.Object = copy
        painted = {}
    elseif is_copy(material) then
        original, copy = material.Parent, material
    else
        return nil
    end
    local second_slot = count >= 2 and list[2] or nil
    local second = second_slot and is_copy(second_slot.Object) and second_slot.Object or nil
    if tinted and install and not second and (count < 2 or not second_slot.Object:IsValid()) then
        -- reading one past the end of an engine array makes it one longer
        second_slot = list[2]
        if list:GetArrayNum() >= 2 then
            local made = library:CreateDynamicMaterialInstance(component, original, FName("None"), 0)
            if made:IsValid() then
                second_slot.Object = made
                second = made
                painted = {}
            end
        end
    end
    if second then
        local weight = tinted and 1 or 0
        if second_slot.Weight ~= weight then
            second_slot.Weight = weight
            painted = {}
        end
        if not tinted then second = nil end
    end
    return copy, second, first, original, second_slot
end

local function remove_passes()
    local copy, _, first, original, second_slot = pass_copies(false, false)
    if copy then first.Object = original end
    if second_slot and is_copy(second_slot.Object) then second_slot.Weight = 0 end
    painted = {}
end

local function write(copy, key, kind, name, a, b, c)
    local stamp = c and (a .. "," .. b .. "," .. c) or a
    if painted[key] == stamp then return end
    painted[key] = stamp
    if kind == "color" then
        copy:SetVectorParameterValue(FName(name), { R = a, G = b, B = c, A = 1 })
    else
        copy:SetScalarParameterValue(FName(name), a)
    end
end

-- A screen colour value (0 to 1) as the linear value the material wants.
local function linear(c) return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end

-- taken[slot] = { outline r, g, b, tint r, g, b }. With a second copy the first draws only lines and the second only tints.
local function paint(copy, second, taken)
    for slot = FIRST_SLOT, LAST_SLOT - 1 do
        local mine, game = taken[slot], GAME_VALUES[slot]
        local name = "Color" .. (slot - FIRST_SLOT + 1)
        if mine then
            write(copy, "a" .. slot, "color", name, linear(mine[1]) * BRIGHTNESS, linear(mine[2]) * BRIGHTNESS, linear(mine[3]) * BRIGHTNESS)
            if second then
                write(second, "b" .. slot, "color", name, linear(mine[4]) * BRIGHTNESS, linear(mine[5]) * BRIGHTNESS,
                    linear(mine[6]) * BRIGHTNESS)
            end
        else
            write(copy, "a" .. slot, "color", name, game[1], game[2], game[3])
            if second then write(second, "b" .. slot, "color", name, game[1], game[2], game[3]) end
        end
    end
    write(copy, "a.fill", "number", "FillAlpha", second and 0 or settings.fill)
    write(copy, "a.width", "number", "OutlineThickness", settings.width)
    if second then
        write(second, "b.fill", "number", "FillAlpha", settings.fill)
        write(second, "b.width", "number", "OutlineThickness", 0)
    end
end

local function distance(a, r, g, b) return (a[1] - r) ^ 2 + (a[2] - g) ^ 2 + (a[3] - b) ^ 2 end

-- A look's colours as one slot entry, and whether a slot entry is that look.
local function entry_of(look)
    return { look.r, look.g, look.b, look.fr or look.r, look.fg or look.g, look.fb or look.b }
end

local function fits(entry, look)
    return distance(entry, look.r, look.g, look.b) < 0.0004
        and (entry[4] - (look.fr or look.r)) ^ 2 + (entry[5] - (look.fg or look.g)) ^ 2 + (entry[6] - (look.fb or look.b)) ^ 2 < 0.0004
end

local function own_tint(look)
    return look.fill and look.fr ~= nil and distance({ look.fr, look.fg, look.fb }, look.r, look.g, look.b) >= 0.0004
end

local function choose(taken, mark)
    local look = mark.look
    local r, g, b = look.r, look.g, look.b
    if not custom then
        local best, best_distance
        for slot, look in pairs(GAME_LOOKS) do
            local d = distance(look, r, g, b)
            if not best or d < best_distance or (d == best_distance and slot < best) then best, best_distance = slot, d end
        end
        return best
    end
    local range = look.fill and FILL_SLOTS or LINE_SLOTS
    local kept = false
    for _, slot in ipairs(range) do
        if slot == mark.slot then kept = true end
    end
    if kept and (not taken[mark.slot] or fits(taken[mark.slot], look)) then
        taken[mark.slot] = taken[mark.slot] or entry_of(look)
        return mark.slot
    end
    local free, nearest, nearest_distance
    for _, slot in ipairs(range) do
        local color = taken[slot]
        if not color then
            free = free or slot
        else
            if fits(color, look) then return slot end
            local d = distance(color, r, g, b)
            if not nearest or d < nearest_distance then nearest, nearest_distance = slot, d end
        end
    end
    if free then
        taken[free] = entry_of(look)
        return free
    end
    if not warned_full then
        warned_full = true
        log:warn("the game's outline pass has %d colours of this kind at a time, so the nearest one in use is shown", #range)
    end
    return nearest
end

-- Gives every mark its stencil value, writes the colours, and re-marks the actors whose value changed.
local function sync()
    local copy, second = nil, nil
    if #order > 0 then
        local tinted = false
        for _, mark in ipairs(order) do
            if mark.actor and own_tint(mark.look) then tinted = true end
        end
        local ok, first, other = pcall(pass_copies, true, tinted)
        if ok then copy, second = first, other end
    else
        pcall(remove_passes)
    end
    custom = copy ~= nil
    local taken, kept = {}, {}
    for _, mark in ipairs(order) do
        if mark.actor and mark.slot and custom then
            local look = mark.look
            for _, slot in ipairs(look.fill and FILL_SLOTS or LINE_SLOTS) do
                if slot == mark.slot and (not taken[slot] or fits(taken[slot], look)) then
                    taken[slot] = taken[slot] or entry_of(look)
                    kept[mark] = true
                end
            end
        end
    end
    for _, mark in ipairs(order) do
        if mark.actor and not kept[mark] then
            local slot = choose(taken, mark)
            if slot ~= mark.slot then
                local old = mark.slot
                mark.slot = slot
                local ok, problem = pcall(function()
                    if old then
                        for _, component in ipairs(meshes(mark.actor, mark.only)) do
                            if component.CustomDepthStencilValue == old then component:SetCustomDepthStencilValue(slot) end
                        end
                    end
                    apply(mark)
                end)
                if not ok then log:warn("could not outline %s: %s", tostring(mark.Instance), tostring(problem)) end
            end
        end
    end
    if copy then
        local ok, problem = pcall(paint, copy, second, taken)
        if not ok then log:warn("could not set the outline colours: %s", tostring(problem)) end
    end
end

local function unlist(mark)
    if marks[mark.address] == mark then marks[mark.address] = nil end
    local same_actor = by_actor[mark.actor_address]
    if same_actor then
        same_actor[mark] = nil
        if next(same_actor) == nil then by_actor[mark.actor_address] = nil end
    end
    for i = #order, 1, -1 do
        if order[i] == mark then table.remove(order, i) end
    end
end

local Look = {}
Look.__index = Look

local function read_options(look, options, level)
    if options == nil then return end
    if type(options) ~= "table" then
        error("the highlight options are a table such as { Color = \"Red\", Fill = true }", level + 1)
    end
    if options.Color ~= nil or look.r == nil then
        look.r, look.g, look.b = parse(options.Color, level + 1)
        look.Color = options.Color or "Red"
    end
    if options.Fill ~= nil then
        if type(options.Fill) ~= "boolean" then error("Fill is true or false", level + 1) end
        look.fill, look.Fill = options.Fill, options.Fill
    end
    if options.FillColor == false then
        look.fr, look.fg, look.fb, look.FillColor = nil, nil, nil, nil
    elseif options.FillColor ~= nil then
        look.fr, look.fg, look.fb = parse(options.FillColor, level + 1)
        look.FillColor = options.FillColor
    end
end

local function new_look(options, level)
    if getmetatable(options) == Look then return options end
    local look = setmetatable({ fill = true, Fill = true }, Look)
    read_options(look, options or {}, level + 1)
    return look
end

-- Changes the colour or the fill of everything outlined with this look, in one go.
function Look:Set(options)
    read_options(self, options, 2)
    stale = true
end

local Mark = {}
Mark.__index = Mark

-- Takes the outline off. Safe to call twice, and after the actor is gone.
function Mark:Remove()
    if not self.Active then return end
    self.Active = false
    unlist(self)
    if self.owner and self.slot_in_owner then self.owner:remove(self.slot_in_owner) end
    if self.actor then
        local ok, problem = pcall(restore, self)
        self.actor = nil
        if not ok then log:warn("could not take the outline off %s: %s", tostring(self.Instance), tostring(problem)) end
    end
    stale = true
end

-- Changes the colour or the fill of this outline: mark:Set({ Color = "#ff8800", Fill = false }).
function Mark:Set(options)
    if self.shared then
        local from = self.look
        local own = setmetatable({ r = from.r, g = from.g, b = from.b, fr = from.fr, fg = from.fg, fb = from.fb, fill = from.fill }, Look)
        self.look, self.shared = own, false
    end
    read_options(self.look, options, 2)
    self.Color, self.Fill = self.look.Color, self.look.Fill
    if self.Active and self.actor then sync() end
end

function Mark:SetColor(color) self:Set({ Color = color }) end

local Highlight = { Colors = table.move(COLORS, 1, #COLORS, 1, {}) }

-- Raises for options that cannot be used, so a mistake is reported where it was written.
function Highlight:Check(options, level)
    if getmetatable(options) ~= Look then read_options({}, options, (level or 1) + 1) end
end

-- A colour and fill that many outlines share. Changing it with :Set changes all of them at once.
function Highlight:Look(options)
    return new_look(options, 2)
end

-- Outlines an actor. Options: Color (a name, "#rrggbb" or { R, G, B }), Fill (tint the model too, default true) and
-- FillColor (the tint, when it is not the outline's colour). A look made with game.Highlight:Look works too.
function Highlight:Add(target, options)
    local whole = instance.is_instance(target) and target:IsA("Actor")
    if not whole and not (instance.is_instance(target) and target:IsA("PrimitiveComponent")) then
        error("game.Highlight:Add expects something with a shape: an actor (a creature, a player, an item) or one mesh part of an actor", 2)
    end
    local mark = setmetatable({ Instance = target, Active = true, previous = {} }, Mark)
    mark.look, mark.shared = new_look(options, 2), getmetatable(options) == Look
    mark.Color, mark.Fill = mark.look.Color, mark.look.Fill
    mark.address = instance.address(target)
    if whole then
        mark.actor, mark.actor_address = target.Raw, mark.address
    else
        local owner = target.Raw:GetOwner()
        if not owner:IsValid() then error("this part does not belong to an actor, so it cannot be outlined", 2) end
        mark.actor, mark.actor_address, mark.only = owner, owner:GetAddress(), target.Name
    end
    mark.creature = whole and target:IsA("IcarusNPCCharacter")
    local existing = marks[mark.address]
    if existing then
        mark.previous, mark.slot = existing.previous, existing.slot
        existing.actor = nil
        existing:Remove()
    end
    marks[mark.address] = mark
    by_actor[mark.actor_address] = by_actor[mark.actor_address] or {}
    by_actor[mark.actor_address][mark] = true
    order[#order + 1] = mark
    mark.owner, mark.slot_in_owner = scope.own(function() mark:Remove() end)
    sync()
    return mark
end

function Highlight:Remove(target)
    if not instance.is_instance(target) then error("game.Highlight:Remove expects an Instance", 2) end
    local mark = marks[instance.address(target)]
    if mark and mark.Instance == target then mark:Remove() end
end

-- Takes every outline off.
function Highlight:Clear()
    for i = #order, 1, -1 do
        if order[i] then order[i]:Remove() end
    end
end

function Highlight:GetAll()
    local out = {}
    for i, mark in ipairs(order) do out[i] = mark.Instance end
    return out
end

-- Settings shared by every outline: Fill (how strongly a filled model is tinted, 0 to 1) and Width (line width, 1 to 4).
function Highlight:Configure(options)
    if type(options) ~= "table" then error("Configure expects a table such as { Fill = 0.3, Width = 2 }", 2) end
    for key, limits in pairs({ Fill = { "fill", 0, 1 }, Width = { "width", 1, 4 } }) do
        local value = options[key]
        if value ~= nil then
            if type(value) ~= "number" then error(key .. " is a number", 2) end
            settings[limits[1]] = math.max(limits[2], math.min(limits[3], value))
        end
    end
    sync()
    return { Fill = settings.fill, Width = settings.width }
end

setmetatable(Highlight, {
    __index = function(_, key)
        error(("%s is not a member of game.Highlight.%s"):format(tostring(key), suggest.phrase(tostring(key), NAMES)), 2)
    end,
    __newindex = function(_, key)
        error(("game.Highlight.%s cannot be assigned because game.Highlight is read-only"):format(tostring(key)), 2)
    end,
    __tostring = function() return "Highlight" end,
    __names = function() return NAMES end,
})

-- The game changes these values itself (looking at something, a new character), so they are put back a little each frame.
function M.step()
    local count = #order
    frames = frames + 1
    if stale or (count > 0 and frames % PASS_EVERY == 0) then
        stale = false
        sync()
    end
    if count == 0 then return end
    for _ = 1, math.min(CHECKED_PER_FRAME, count) do
        if cursor > #order then cursor = 1 end
        local mark = order[cursor]
        cursor = cursor + 1
        if mark and mark.Active and mark.actor and mark.slot then
            local ok, problem = pcall(apply, mark)
            if not ok then
                log:warn("dropped the outline on %s: %s", tostring(mark.Instance), tostring(problem))
                mark.actor = nil
                mark:Remove()
            end
        end
    end
end

local function forget_all()
    for _, mark in ipairs(order) do
        mark.actor, mark.Active = nil, false
        if mark.owner and mark.slot_in_owner then mark.owner:remove(mark.slot_in_owner) end
    end
    marks, order, by_actor, cursor, custom, painted, stale = {}, {}, {}, 1, false, {}, false
end

function M.start()
    mesh_class = StaticFindObject("/Script/Engine.MeshComponent")
    library = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    part_class = StaticFindObject("/Script/Engine.PrimitiveComponent")
    actors.on_ended(function(_, address)
        local gone = by_actor[address]
        if not gone then return end
        local list = {}
        for mark in pairs(gone) do list[#list + 1] = mark end
        for _, mark in ipairs(list) do
            mark.actor = nil
            mark:Remove()
        end
    end)
    local root = Wax.import("engine.game").root
    root.MapChanged:Connect(forget_all)
    rawset(root, "Highlight", Highlight)
end

function M.stats() return { marks = #order, custom = custom, written = painted } end

M.api = Highlight
return M
