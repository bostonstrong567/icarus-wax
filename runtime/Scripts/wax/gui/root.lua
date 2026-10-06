-- The one root widget that everything Wax draws sits under, and the low-level constructors

local Wax = ...
local log = Wax.import("core.log").channel("wax.gui")

local root = {}

local RF_TRANSIENT = 0x40
local ROOT_PREFIX = "WaxRoot"
local Z_ORDER = 1000

local classes = {}          -- short class name -> UClass
local textures = {}         -- asset name -> UTexture2D
local sequence = 0
local user_widget, widget_tree, canvas = nil, nil, nil
local root_place, root_address, alive = nil, nil, false
local bank = nil            -- hidden images that hold every loaded texture, so the engine keeps them
local libraries = {}
local layers = {}
local HIT_TEST_INVISIBLE, SELF_HIT_TEST_INVISIBLE = 3, 4

local function class_of(kind)
    local class = classes[kind]
    if class and class:IsValid() then return class end
    class = StaticFindObject("/Script/UMG." .. kind)
    if not class:IsValid() then error("no UMG widget class named " .. kind, 3) end
    classes[kind] = class
    return class
end

local function library(name, module)
    local found = libraries[name]
    if found and found:IsValid() then return found end
    found = StaticFindObject("/Script/" .. (module or "UMG") .. ".Default__" .. name)
    libraries[name] = found
    return found
end
root.library = library

local engine_object = nil
local function game_instance()
    if not engine_object then engine_object = FindFirstOf("Engine") end
    return engine_object.GameViewport.GameInstance
end

-- The game instance lists objects it keeps alive. Only the root goes in. Returns the place it was given.
local function keep_alive(object)
    local list = game_instance().ReferencedObjects
    local count = list:GetArrayNum()
    for i = 1, count do                 -- never read past the end: that grows an engine array
        if not list[i]:IsValid() then
            list[i] = object
            return i
        end
    end
    list[count + 1] = object
    return count + 1
end

local function release(object)
    local list = game_instance().ReferencedObjects
    local address = object:GetAddress()
    for i = 1, list:GetArrayNum() do
        local entry = list[i]
        if entry:IsValid() and entry:GetAddress() == address then list[i] = nil end
    end
end

-- A root left behind by an earlier core (after a development reload) has no handlers any more: remove it.
local function remove_orphans()
    local found = FindAllOf("UserWidget")
    if not found then return end
    for i = 1, #found do
        local widget = found[i]
        if widget:IsValid() and widget:GetFName():ToString():sub(1, #ROOT_PREFIX) == ROOT_PREFIX then
            pcall(function()
                widget:RemoveFromParent()
                release(widget)
            end)
        end
    end
end

-- A new widget of a UMG class ("TextBlock", "Button", ...).
function root.new(kind)
    if not widget_tree or not widget_tree:IsValid() then error("the GUI root does not exist", 2) end
    sequence = sequence + 1
    return StaticConstructObject(class_of(kind), widget_tree, FName(("Wax_%s_%d"):format(kind, sequence)), RF_TRANSIENT)
end

-- A texture from wax/runtime/assets/<name>.png (or from `file`), loaded once.
function root.texture(name, file)
    local texture = textures[name]
    if texture then return texture end
    local path = file or (Wax.root .. "/assets/" .. name .. ".png")
    texture = library("KismetRenderingLibrary", "Engine"):ImportFileAsTexture2D(user_widget, path)
    if not texture:IsValid() then error("could not load " .. path, 2) end
    -- a texture no widget uses any more would be freed while this table still points at it
    local holder = root.new("Image")
    holder.Brush.ResourceObject = texture
    bank:AddChild(holder)
    textures[name] = texture
    return texture
end

function root.canvas() return canvas end
-- "hud" (overlays, where only the move handles take clicks), "windows" (the menu) or "toasts", drawn in that order.
function root.layer(name) return layers[name] end
function root.widget() return user_widget end
-- Whether the root still exists, found without touching it: it exists while the game instance lists it. exists() repeats the last answer.
function root.check()
    alive = false
    if not user_widget then return false end
    local list = game_instance().ReferencedObjects
    if list:GetArrayNum() < root_place then return false end
    local entry = list[root_place]
    alive = entry:IsValid() and entry:GetAddress() == root_address
    return alive
end
function root.exists() return alive end
-- True when there was a root and the game removed it. Nothing under it may be used again.
function root.lost() return user_widget ~= nil and not alive end
function root.abandon()
    user_widget, widget_tree, canvas, bank, alive = nil, nil, nil, nil, false
    textures, layers = {}, {}
end

-- Mouse position and viewport size in the same units canvas slots use.
function root.mouse()
    local position = library("WidgetLayoutLibrary"):GetMousePositionOnViewport(user_widget)
    return position.X, position.Y
end

function root.viewport_size()
    local layout = library("WidgetLayoutLibrary")
    local size = layout:GetViewportSize(user_widget)
    local scale = layout:GetViewportScale(user_widget)
    if scale <= 0 then scale = 1 end
    return size.X / scale, size.Y / scale, scale
end

function root.start()
    remove_orphans()
    sequence = sequence + 1
    user_widget = StaticConstructObject(class_of("UserWidget"), game_instance(), FName(ROOT_PREFIX .. "_" .. os.time() .. "_" .. sequence), RF_TRANSIENT)
    widget_tree = StaticConstructObject(class_of("WidgetTree"), user_widget, FName("WidgetTree"), RF_TRANSIENT)
    user_widget.WidgetTree = widget_tree
    canvas = StaticConstructObject(class_of("CanvasPanel"), widget_tree, FName("RootCanvas"), RF_TRANSIENT)
    widget_tree.RootWidget = canvas
    for _, layer in ipairs({ { "hud", SELF_HIT_TEST_INVISIBLE }, { "windows", SELF_HIT_TEST_INVISIBLE }, { "toasts", HIT_TEST_INVISIBLE } }) do
        local panel = StaticConstructObject(class_of("CanvasPanel"), widget_tree, FName("Layer_" .. layer[1]), RF_TRANSIENT)
        local slot = canvas:AddChild(panel)
        slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
        slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        panel:SetVisibility(layer[2])
        layers[layer[1]] = panel
    end
    canvas:SetVisibility(SELF_HIT_TEST_INVISIBLE)
    bank = StaticConstructObject(class_of("VerticalBox"), widget_tree, FName("TextureBank"), RF_TRANSIENT)
    canvas:AddChild(bank)
    bank:SetVisibility(1)
    root_place, root_address = keep_alive(user_widget), user_widget:GetAddress()
    alive = true
    user_widget:AddToViewport(Z_ORDER)
    log:debug("GUI root created")
end

-- Called every frame: after a map change the engine has taken the root off the viewport.
local frames = 0
function root.step()
    frames = frames + 1
    if frames % 15 ~= 0 or not alive then return end
    if not user_widget:IsInViewport() then user_widget:AddToViewport(Z_ORDER) end
end

function root.stop()
    if root.check() then
        pcall(function()
            user_widget:RemoveFromParent()
            release(user_widget)
        end)
    end
    user_widget, widget_tree, canvas, bank, alive = nil, nil, nil, nil, false
    textures, layers = {}, {}
end

return root
