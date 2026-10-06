-- Pictures from the game: an item icon or any other texture of the game, shown in an image by its path

local Wax = ...
local root = Wax.import("gui.root")
local style = Wax.import("gui.style")
local log = Wax.import("core.log").channel("wax.gui")

local M = {}

M.BUDGET = 0.003        -- seconds of loading a frame
M.PINS = 400            -- textures kept in memory after they left the screen, so going back to a page costs nothing

local V = style.Visibility
local queue, head, tail = {}, 1, 0      -- { image, path, owner, ticket }, waiting from head to tail
local wanted = setmetatable({}, { __mode = "k" })      -- image -> the ticket of what it should show now
local failed = {}               -- path -> true: it could not be loaded and is not asked for again
local pinned, pins, pin_at = {}, {}, 0      -- path -> place in the ring; the ring's hidden images
local ticket = 0
local stats = { loaded = 0, failed = 0, waiting = 0, pinned = 0, worst = 0 }

local function now() return (Wax.perf and Wax.perf.now or os.clock)() end

-- A game path such as "/Game/Assets/2DArt/UI/Items/Item_Icons/Resources/ITEM_Wood.ITEM_Wood". A path with no dot gets its last part again.
function M.check(source)
    if type(source) ~= "string" or #source > 260 or source:sub(1, 1) ~= "/" then return nil end
    if not source:find("%.", 1) then
        local last = source:match("([^/]+)$")
        if not last then return nil end
        source = source .. "." .. last
    end
    if not source:match("^/[%w_]+/[%w_/%-]+%.[%w_%-]+$") or source:sub(-2) == "_C" then return nil end
    return source
end

-- Keeps a texture in memory by giving it to a hidden image under the root. The oldest one is let go.
local function pin(path, texture)
    if pinned[path] then return end
    pin_at = pin_at % M.PINS + 1
    local holder = pins[pin_at]
    if not holder then
        local image = root.new("Image")
        image:SetVisibility(V.Collapsed)
        root.canvas():AddChild(image)
        holder = { image = image }
        pins[pin_at] = holder
        stats.pinned = stats.pinned + 1
    elseif holder.path then
        pinned[holder.path] = nil
    end
    holder.image:SetBrushResourceObject(texture)
    holder.path, pinned[path] = path, pin_at
end

local function load(entry)
    local started = now()
    local ok, texture = pcall(LoadAsset, entry.path)
    local good = ok and texture ~= nil and texture:IsValid()
    local spent = now() - started
    if spent > stats.worst then stats.worst = spent end
    if not good then
        failed[entry.path] = true
        stats.failed = stats.failed + 1
        log:warn("the picture %s could not be loaded", entry.path)
        return false
    end
    stats.loaded = stats.loaded + 1
    if wanted[entry.image] == entry.ticket and not (entry.owner and entry.owner.destroyed) then
        entry.image:SetBrushResourceObject(texture)
        entry.image:SetVisibility(V.HitTestInvisible)
    end
    pin(entry.path, texture)
    return true
end

-- Shows the game texture at `path` in `image` (one made by kit.picture). Nothing shows until it has loaded.
-- `owner` is the control the image belongs to: once it is destroyed the image is not touched again.
-- Returns false when the path is not a game path or could not be loaded before.
function M.show(image, path, owner)
    local checked = M.check(path)
    ticket = ticket + 1
    wanted[image] = ticket
    if not checked or failed[checked] then
        image:SetVisibility(V.Hidden)
        return false
    end
    local entry = { image = image, path = checked, owner = owner, ticket = ticket }
    -- one that is in memory already costs next to nothing, so it is shown at once and the image never blinks
    if pinned[checked] then
        load(entry)
        return true
    end
    image:SetVisibility(V.Hidden)
    tail = tail + 1
    queue[tail] = entry
    return true
end

-- The image shows nothing, and whatever was asked for it is dropped.
function M.clear(image)
    ticket = ticket + 1
    wanted[image] = ticket
    image:SetVisibility(V.Hidden)
end

-- Once per frame: loads what is waiting, for a few milliseconds at most.
function M.step()
    if head > tail then
        if tail > 0 then queue, head, tail = {}, 1, 0 end
        return
    end
    local started = now()
    repeat
        local entry = queue[head]
        queue[head] = false
        head = head + 1
        -- skip what was asked for an image that shows something else by now
        if wanted[entry.image] == entry.ticket and not (entry.owner and entry.owner.destroyed) and not failed[entry.path] then
            load(entry)
        end
    until head > tail or now() - started > M.BUDGET
end

function M.waiting() return tail - head + 1 end

function M.stats()
    stats.waiting = math.max(0, tail - head + 1)
    return { loaded = stats.loaded, failed = stats.failed, waiting = stats.waiting, pinned = stats.pinned, worst_ms = stats.worst * 1000 }
end

-- The interface was rebuilt or the map changed: nothing kept here may be touched again.
function M.forget_all()
    queue, head, tail = {}, 1, 0
    pinned, pins, pin_at = {}, {}, 0
    stats.pinned = 0
end

return M
