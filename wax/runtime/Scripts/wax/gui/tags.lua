-- Tags: a line of text that stays over something in the world

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local kit = Wax.import("gui.kit")
local input = Wax.import("gui.input")
local scope = Wax.import("core.scope")
local actors = Wax.import("engine.actors")
local instance = Wax.import("engine.instance")

local M = {}

local V = style.Visibility
local METRE, SLOW_EVERY = 100, 10
local CLOSE = 40            -- metres. Nearer than this a tag follows every frame, farther every other frame
local LINE, LETTER, STACK = 15, 6.6, 6      -- a tag's height, the width of one letter, and how many may pile up
local SMALLEST, FADE_FROM = 0.6, 0.8        -- a tag at the edge of its range is this big, and fades over the last fifth
local OUTLINE_RANGE = 14    -- metres the game's outline reaches, until game.Highlight says otherwise
local tags = {}             -- every tag that is showing or could show
local by_address = {}       -- actor address -> { tags on it }
local frames, screen_scale = 0, 1
local stop_ended, map_changed = nil, nil

local Tag = {}
Tag.__index = Tag

local function hide(tag)
    if tag.shown then
        tag.shown = false
        tag.box:SetVisibility(V.Collapsed)
    end
end

local function forget(tag)
    local list = tag.address and by_address[tag.address]
    if list then
        for i = #list, 1, -1 do
            if list[i] == tag then table.remove(list, i) end
        end
        if #list == 0 then by_address[tag.address] = nil end
    end
    for i = #tags, 1, -1 do
        if tags[i] == tag then table.remove(tags, i) end
    end
end

-- Takes the tag off. Safe to call twice, and after the thing it was on is gone.
function Tag:Remove()
    if self.destroyed then return end
    self.destroyed, self.actor = true, nil
    forget(self)
    pcall(function() self.box:RemoveFromParent() end)
    if self.owner and self.owner_slot then self.owner:remove(self.owner_slot) end
end

function Tag:Set(text)
    if self.destroyed then return end
    text = text == nil and "" or tostring(text)
    if text == self.text then return end
    self.text = text
    kit.set_text(self.label, text)
end

-- How near, in metres, the thing has to be for the tag to show. "outline" makes it show as far as outlines do.
function Tag:SetRange(metres)
    if metres == "outline" then
        self.outline, self.near = true, true
        return
    end
    if type(metres) ~= "number" then error("SetRange expects a number of metres, or \"outline\"", 2) end
    self.within, self.outline, self.near = metres, false, true
end

-- Metres this tag shows within.
function Tag:GetRange() return self.outline and M.outline_range() or self.within end

-- How far outlines reach now, asked of game.Highlight when it is running.
function M.outline_range()
    local highlight = Wax.modules["world.highlight"]
    if type(highlight) == "table" and highlight.range then return highlight.range() end
    return OUTLINE_RANGE
end

-- A tag's size and opacity at a distance: full size up close, SMALLEST at the edge, and fading out over the last fifth.
function M.look(away, within)
    local share = within > 0 and math.min(1, away / within) or 0
    local factor = 1 - (1 - SMALLEST) * share
    local alpha = share <= FADE_FROM and 1 or math.max(0, (1 - share) / (1 - FADE_FROM))
    return factor, alpha
end

function Tag:SetColor(color)
    if self.destroyed then return end
    self.label:SetColorAndOpacity(style.slate(style.to_color(color)))
end

-- Where the tag goes this frame. Returns true while it is close enough to be worth doing every frame.
local function place(tag, player, eye_x, eye_y, eye_z)
    local x, y, z
    if tag.spot then
        x, y, z = tag.spot.X, tag.spot.Y, tag.spot.Z + tag.lift
    else
        local at = tag.actor:K2_GetActorLocation()
        x, y, z = at.X + tag.aside.X, at.Y + tag.aside.Y, at.Z + tag.aside.Z + tag.lift
    end
    local away = math.sqrt((x - eye_x) ^ 2 + (y - eye_y) ^ 2 + (z - eye_z) ^ 2) / METRE
    local within = tag.outline and M.outline_range() or tag.within
    if away > within then
        hide(tag)
        return false
    end
    local screen = {}
    if not player:ProjectWorldLocationToScreen({ X = x, Y = y, Z = z }, screen, false) then
        hide(tag)
        return false
    end
    tag.x, tag.y, tag.away = screen.X / screen_scale, screen.Y / screen_scale, away
    if tag.fade then
        local factor, alpha = M.look(away, within)
        if math.abs(factor - tag.factor) > 0.02 then
            tag.factor = factor
            tag.box:SetUserSpecifiedScale(style.scale * factor)
        end
        if math.abs(alpha - tag.alpha) > 0.02 then
            tag.alpha = alpha
            tag.box:SetRenderOpacity(alpha)
        end
    end
    return true
end

local function nearer(a, b) return a.away < b.away end

-- True while one of the game's own screens or the Wax menu is open: tags stay off them.
function M.menus_open()
    local ui = Wax.ui
    if not ui then return false end
    local ok, screen = pcall(ui.GameScreen)
    if ok and screen then return true end
    local open, is_open = pcall(ui.IsOpen)
    return open and is_open == true
end

-- Tags that would cover each other are piled up, the nearest thing's tag lowest. One with no room left is not shown.
local function arrange(covered)
    local seen = {}
    for _, tag in ipairs(tags) do
        if covered and not tag.over_menus then
            hide(tag)
        elseif tag.near and tag.x then
            seen[#seen + 1] = tag
        end
    end
    table.sort(seen, nearer)
    local scale = style.scale
    for index, tag in ipairs(seen) do
        local line = LINE * scale * tag.factor
        local width, y, fits = #tag.text * LETTER * scale * tag.factor, tag.y, true
        tag.line = line
        for _ = 1, STACK do
            fits = true
            for other = 1, index - 1 do
                local below = seen[other]
                local gap = math.max(line, below.line or line)
                if below.put and math.abs(tag.x - below.x) < (width + below.width) / 2 and math.abs(y - below.put) < gap - 0.01 then
                    y, fits = below.put - gap, false
                end
            end
            if fits then break end
        end
        tag.width, tag.put = width, fits and y or nil
        if not fits then
            hide(tag)
        else
            if math.abs((tag.drawn_x or -9) - tag.x) > 0.3 or math.abs((tag.drawn_y or -9) - y) > 0.3 then
                tag.drawn_x, tag.drawn_y = tag.x, y
                tag.slot:SetPosition({ X = tag.x, Y = y })
            end
            if not tag.shown then
                tag.shown = true
                tag.box:SetVisibility(V.HitTestInvisible)
            end
        end
    end
end

local function build(tag, options)
    local theme = style.theme
    local label = kit.label(tag.text, { size = options.size or theme.font_size, color = options.color or style.WHITE, face = "Bold", free = true })
    label:SetShadowOffset({ X = 1, Y = 1 })
    label:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 })
    label:SetJustification(style.Justify.Center)
    local box = kit.scaled(label)
    box:SetVisibility(V.Collapsed)
    local slot = root.layer("hud"):AddChild(box)
    slot:SetAutoSize(true)
    slot:SetAlignment({ X = 0.5, Y = 1 })
    tag.label, tag.box, tag.slot = label, box, slot
end

-- options: text, color, size, within (metres, default 100), outline (show as far as outlines do, in place of within),
-- fade (smaller and fainter with distance, default true), over_menus (keep showing while a game screen or the Wax menu
-- is open, default false), lift (how far above the thing's middle, in centimetres)
function M.create(target, options)
    options = options or {}
    if type(options) ~= "table" then error("the tag options are a table such as { text = \"Wolf\" }", 2) end
    if not root.exists() then error("the GUI is not running", 2) end
    -- a tag goes on an actor, on one part of an actor, or on a spot in the world
    local actor, spot, address, lift = nil, nil, false, options.lift
    local aside = { X = 0, Y = 0, Z = 0 }
    if instance.is_instance(target) and target:IsA("Actor") then
        actor, address = target.Raw, instance.address(target)
        if not lift then
            lift = 60
            if target:IsA("Character") then
                local capsule = actor.CapsuleComponent
                if capsule:IsValid() then lift = capsule.CapsuleHalfHeight + 25 end
            end
        end
    elseif instance.is_instance(target) and target:IsA("SceneComponent") then
        local part = target.Raw
        actor = part:GetOwner()
        if not actor:IsValid() then error("this part does not belong to an actor, so a tag cannot follow it", 2) end
        address = actor:GetAddress()
        local here, base = part:K2_GetComponentLocation(), actor:K2_GetActorLocation()
        aside = { X = here.X - base.X, Y = here.Y - base.Y, Z = here.Z - base.Z }
    elseif type(target) == "table" and type(target.X) == "number" and type(target.Y) == "number" and type(target.Z) == "number" then
        spot = { X = target.X, Y = target.Y, Z = target.Z }
    else
        error("ui.Tag expects an actor, a part of an actor, or a position such as { X = 0, Y = 0, Z = 0 }", 2)
    end
    local tag = setmetatable({
        Instance = not spot and target or nil, actor = actor, spot = spot, aside = aside, address = address,
        text = tostring(options.text or ""), within = options.within or 100, lift = lift or 20,
        outline = options.outline == true and options.within == nil, fade = options.fade ~= false, factor = 1, alpha = 1,
        over_menus = options.over_menus == true,
        shown = false, near = true, destroyed = false,
    }, Tag)
    if options.within ~= nil and type(options.within) ~= "number" then error("within is a number of metres", 2) end
    style.build(tag, build, tag, options)
    tags[#tags + 1] = tag
    if tag.address then
        by_address[tag.address] = by_address[tag.address] or {}
        table.insert(by_address[tag.address], tag)
    end
    tag.owner, tag.owner_slot = scope.own(function() tag:Remove() end)
    return tag
end

-- Once per frame. Tags near enough to read follow every frame. The rest are looked at a few at a time.
function M.step()
    local count = #tags
    if count == 0 then return end
    frames = frames + 1
    for index = count, 1, -1 do
        if not tags[index].actor and not tags[index].spot then tags[index]:Remove() end
    end
    count = #tags
    local player = input.controller()
    if not player or count == 0 then return end
    local _, _, pixels = root.viewport_size()
    screen_scale = pixels
    local camera = player.PlayerCameraManager
    if not camera:IsValid() then return end
    local eye = camera:GetCameraLocation()
    local eye_x, eye_y, eye_z = eye.X, eye.Y, eye.Z
    for index = count, 1, -1 do
        local tag = tags[index]
        local due = tag.near and ((tag.away or 0) < CLOSE or (index + frames) % 2 == 0)
        if due or (index + frames) % SLOW_EVERY == 0 then
            local ok, near = pcall(place, tag, player, eye_x, eye_y, eye_z)
            if ok then
                tag.near = near
            else
                tag:Remove()
            end
        end
    end
    arrange(M.menus_open())
end

function M.rescale()
    for _, tag in ipairs(tags) do
        if not tag.destroyed then tag.box:SetUserSpecifiedScale(style.scale * tag.factor) end
    end
end

-- After the root or the map is gone: nothing old is touched.
function M.forget_all()
    for _, tag in ipairs(tags) do
        tag.destroyed, tag.actor = true, nil
        if tag.owner and tag.owner_slot then tag.owner:remove(tag.owner_slot) end
    end
    tags, by_address = {}, {}
end

function M.destroy_all()
    for index = #tags, 1, -1 do tags[index]:Remove() end
end

function M.start()
    if stop_ended then stop_ended() end
    stop_ended = actors.on_ended(function(_, address)
        local list = by_address[address]
        if not list then return end
        for index = #list, 1, -1 do list[index].actor = nil end
    end)
    if map_changed then map_changed:Disconnect() end
    map_changed = Wax.import("engine.game").root.MapChanged:Connect(function()
        for _, tag in ipairs(tags) do tag.actor, tag.spot = nil, nil end
        M.destroy_all()
    end)
end

function M.count() return #tags end

return M
