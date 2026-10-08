-- Colours, fonts, brushes and the theme. Everything visual goes through here, so one theme styles every window.

local Wax = ...
local root = Wax.import("gui.root")
local icons = Wax.import("gui.icons")

local style = {}

-- Engine enum values, verified against this game build.
style.Visibility = { Visible = 0, Collapsed = 1, Hidden = 2, HitTestInvisible = 3, SelfHitTestInvisible = 4 }
style.HAlign = { Fill = 0, Left = 1, Center = 2, Right = 3 }
style.VAlign = { Fill = 0, Top = 1, Center = 2, Bottom = 3 }
style.DrawAs = { None = 0, Box = 1, Border = 2, Image = 3 }
style.Clip = { Inherit = 0, ClipToBounds = 1 }
style.SizeRule = { Auto = 0, Fill = 1 }
style.Justify = { Left = 0, Center = 1, Right = 2 }
style.Wrapping = { Words = 0, AnyCharacter = 1 }

style.WHITE = { R = 1, G = 1, B = 1, A = 1 }
style.Stretch = { UserSpecified = 7 }
style.Cursor = { Default = 1, ResizeLeftRight = 3, ResizeUpDown = 4, ResizeSouthEast = 5, ResizeSouthWest = 6, Move = 7, Hand = 9 }

-- Everything Wax draws is multiplied by this (see ui.SetScale).
style.scale = 1
style.screen_scale = 1

-- 9-slice shapes in wax/runtime/assets: white 64x64 images tinted at draw time. Value = corner size / 64.
local SHAPES = { frame6 = 6 / 64, frame8 = 8 / 64, frame12 = 12 / 64, top6 = 6 / 64, bottom6 = 6 / 64, top8 = 8 / 64,
    glow12 = 20 / 64, glow12_soft = 20 / 64 }
-- the same glow for the other three corners and the four edges of a window
for _, part in ipairs({ "sw", "ne", "nw", "n", "s", "e", "w" }) do
    SHAPES["glow12_" .. part], SHAPES["glow12_" .. part .. "_soft"] = 20 / 64, 20 / 64
end
local RADII = { 2, 3, 4, 5, 6, 7, 8, 9, 10, 12 }
for _, radius in ipairs(RADII) do SHAPES["round" .. radius] = radius / 64 end

-- The shape whose ends are half circles for something this tall (a bar, a switch, a round knob).
function style.capsule(height)
    local wanted, best = height / 2, RADII[1]
    for _, radius in ipairs(RADII) do
        if math.abs(radius - wanted) < math.abs(best - wanted) then best = radius end
    end
    return "round" .. best
end

-- "#RRGGBB" or 0xRRGGBB, optional alpha 0..1 -> the linear colour the engine wants (screens use sRGB).
function style.color(hex, alpha)
    if type(hex) == "string" then hex = tonumber((hex:gsub("^#", "")), 16) end
    if type(hex) ~= "number" then error("a colour is \"#RRGGBB\" or 0xRRGGBB", 2) end
    local function linear(channel)
        channel = channel / 255
        return channel <= 0.04045 and channel / 12.92 or ((channel + 0.055) / 1.055) ^ 2.4
    end
    return { R = linear((hex >> 16) & 255), G = linear((hex >> 8) & 255), B = linear(hex & 255), A = alpha or 1 }
end

-- A colour as given by a mod: an engine colour table, "#RRGGBB" or 0xRRGGBB. nil stays nil.
function style.to_color(value)
    if type(value) == "string" or type(value) == "number" then return style.color(value) end
    return value
end

function style.slate(color) return { SpecifiedColor = color, ColorUseRule = 0 } end

-- A colour made from other colours remembers how, so it can be worked out again when the theme changes.
local recipes = setmetatable({}, { __mode = "k" })

local function blend(out, from, to, amount)
    out.R, out.G = from.R + (to.R - from.R) * amount, from.G + (to.G - from.G) * amount
    out.B, out.A = from.B + (to.B - from.B) * amount, from.A + (to.A - from.A) * amount
    return out
end

function style.with_alpha(color, alpha)
    local out = { R = color.R, G = color.G, B = color.B, A = alpha }
    recipes[out] = { from = color }
    return out
end

function style.mix(from, to, amount)
    local out = blend({}, from, to, amount)
    recipes[out] = { from = from, to = to, amount = amount }
    return out
end

local renewed = 0
local function renew(color)
    local recipe = recipes[color]
    if not recipe or recipe.renewed == renewed then return end
    recipe.renewed = renewed
    renew(recipe.from)
    if recipe.to then
        renew(recipe.to)
        blend(color, recipe.from, recipe.to, recipe.amount)
    else
        color.R, color.G, color.B = recipe.from.R, recipe.from.G, recipe.from.B
    end
end

function style.margin(left, top, right, bottom)
    top = top or left
    right = right or left
    bottom = bottom or top
    return { Left = left, Top = top, Right = right, Bottom = bottom }
end

local FONTS = {
    ui = { path = "/Game/Fonts/Font_Industry.Font_Industry", face = "Medium" },
    mono = { path = "/Engine/EngineFonts/DroidSansMono.DroidSansMono", face = "Default" },
    plain = { path = "/Engine/EngineFonts/Roboto.Roboto", face = "Regular" },
}
local font_objects = {}

-- family: "ui" (the game's own interface font), "mono" or "plain". face: "Book", "Medium", "Bold" ... for "ui".
function style.font(size, face, family)
    local entry = FONTS[family or "ui"] or FONTS.ui
    local object = font_objects[entry.path]
    if not object or not object:IsValid() then
        object = StaticFindObject(entry.path)
        font_objects[entry.path] = object
    end
    return { FontObject = object, Size = size, TypefaceFontName = FName(face or entry.face) }
end

-- Writes into an existing brush struct, in place. shape = nil for a flat rectangle, or one of the 9-slice shapes.
function style.paint(brush, color, shape, width, height)
    if shape then
        if not SHAPES[shape] then error("unknown shape '" .. tostring(shape) .. "'", 2) end
        brush.ResourceObject = root.texture(shape)
        brush.DrawAs = style.DrawAs.Box
        brush.Margin = style.margin(SHAPES[shape])
        brush.ImageSize = { X = width or 64, Y = height or 64 }
    else
        brush.DrawAs = style.DrawAs.Image
        brush.Margin = style.margin(0)
        brush.ImageSize = { X = width or 16, Y = height or 16 }
    end
    style.tint(brush, "brush", color)
end

local WHOLE = { Min = { X = 0, Y = 0 }, Max = { X = 0, Y = 0 }, bIsValid = 0 }

-- The texture of an icon and the part of it to draw. Small bundled icons share one sheet, so no file is loaded per icon.
function style.icon_source(name, size)
    local pixels = (size or 14) * style.scale * style.screen_scale
    local column, row = icons.cell(name, pixels)
    if not column then return root.texture(icons.resolve(name, pixels)), WHOLE end
    local step = 1 / icons.SHEET_COLUMNS
    return root.texture("lucide/sheet32"), { Min = { X = column * step, Y = row * step },
        Max = { X = (column + 1) * step, Y = (row + 1) * step }, bIsValid = 1 }
end

-- An icon by name (see gui.icons) drawn at size x size. Small sizes use the small image so thin lines stay clean.
function style.paint_icon(brush, name, color, size)
    brush.ResourceObject, brush.UVRegion = style.icon_source(name, size)
    brush.DrawAs = style.DrawAs.Image
    brush.Margin = style.margin(0)
    brush.ImageSize = { X = size or 14, Y = size or 14 }
    style.tint(brush, "brush", color)
end

function style.paint_nothing(brush)
    brush.DrawAs = style.DrawAs.None
    brush.ImageSize = { X = 0, Y = 0 }
end

-- the themes: each is a list of colours in the order of PALETTE_KEYS
local PALETTE_KEYS = { "window", "outline", "panel", "card", "card_line", "raised", "hover", "press", "line", "text", "dim",
    "accent", "accent_hover", "good", "warn", "bad" }
local PALETTES = {
    Midnight = { "#0D1117", "#3B434E", "#161B22", "#141A21", "#262D36", "#21262D", "#30363D", "#484F58", "#262D36", "#E6EDF3",
        "#8B949E", "#2F81F7", "#58A6FF", "#3FB950", "#D29922", "#F85149" },
    Graphite = { "#1B1C1F", "#46484F", "#25262A", "#222327", "#33353A", "#2E3035", "#3B3D43", "#505259", "#33353A", "#ECECEE",
        "#9A9CA3", "#7C8CFF", "#A0ABFF", "#4CC38A", "#E2A336", "#FF6369" },
    Abyss = { "#050608", "#2C3038", "#0D0F13", "#0A0C10", "#1B1E24", "#15181D", "#22262D", "#343A43", "#1B1E24", "#E8EAED",
        "#7D838C", "#22C3A6", "#4FE0C6", "#3FB950", "#D29922", "#F85149" },
    Dune = { "#17140F", "#5A4E36", "#221D15", "#1E1A13", "#3A3223", "#2E2719", "#403622", "#5A4C30", "#3A3223", "#F1E9D6",
        "#A89B80", "#E0A030", "#F2BC57", "#8FBF4D", "#E0A030", "#E5604A" },
    Daylight = { "#F6F7F9", "#B9C0CA", "#E9ECF0", "#EEF0F3", "#D5D9E0", "#DDE1E7", "#CDD3DB", "#B9C0CA", "#D5D9E0", "#1B2028",
        "#5D6672", "#1F6FEB", "#3B82F6", "#1A7F37", "#9A6700", "#CF222E" },
    Prospector = { "#15170F", "#5A6040", "#1E2116", "#1B1E14", "#343926", "#2A2E1F", "#3A3F2A", "#50573A", "#343926", "#EEF0DC",
        "#A3A886", "#8E9A3C", "#A6B34D", "#7FC96B", "#F0B840", "#E5604A" },
    Ember = { "#14100E", "#4A3A32", "#1D1714", "#1A1512", "#33271F", "#2A201B", "#3A2C24", "#54402F", "#33271F", "#F3E9E2",
        "#A8958A", "#E8641C", "#FF8A47", "#6FCB6A", "#F2B33D", "#F0554A" },
    Aurora = { "#0B1016", "#2E4A57", "#111A22", "#0F171E", "#1F2F3A", "#18242E", "#22323F", "#2F4656", "#1F2F3A", "#E4F1F5",
        "#7F9AA6", "#7C5CFF", "#9C84FF", "#3DDC97", "#F5C150", "#FF6B81" },
    Nebula = { "#0E0B1A", "#3B3360", "#151127", "#120F22", "#272043", "#1E1936", "#2A2349", "#3B3266", "#272043", "#ECE8FA",
        "#9189B5", "#B845F5", "#D07BFF", "#4ADE80", "#FACC15", "#FB7185" },
    Rosewood = { "#140D12", "#4D3442", "#1D131A", "#1A1117", "#33212C", "#2A1B24", "#3A2632", "#523646", "#33212C", "#F5E8EE",
        "#A98C9B", "#D93B72", "#F06B98", "#5FCB8B", "#EDB44A", "#FF5C5C" },
    Terminal = { "#060A07", "#1F3B26", "#0B120D", "#09100B", "#162419", "#101C13", "#18291C", "#234029", "#162419", "#D6F5DC",
        "#6E9A78", "#1F9D48", "#3CCB6A", "#3CCB6A", "#D9B13B", "#E5534B" },
    Glacier = { "#EEF3F8", "#A9B8C8", "#E1E9F1", "#E7EEF5", "#C9D5E1", "#D3DEE9", "#C2D0DE", "#A9BBCD", "#C9D5E1", "#15222E",
        "#54677A", "#0E7FC2", "#2B97D8", "#15803D", "#A16207", "#C8233A" },
    Sandstone = { "#F5EFE4", "#C9B99A", "#EBE2D2", "#F0E8DA", "#D9CCB4", "#E0D4BD", "#D2C4A8", "#BFAF8F", "#D9CCB4", "#2A2318",
        "#6F6250", "#B5541C", "#CF6A2E", "#3F7D2A", "#9A6700", "#B42318" },
}
local THEME_ORDER = { "Midnight", "Graphite", "Abyss", "Dune", "Prospector", "Ember", "Aurora", "Nebula", "Rosewood", "Terminal",
    "Daylight", "Glacier", "Sandstone" }
local custom_themes = {}

local function palette(name)
    local out = {}
    local colors = PALETTES[name]
    if colors then
        for index, key in ipairs(PALETTE_KEYS) do out[key] = style.color(colors[index]) end
    else
        -- an added theme starts from Midnight, so what it leaves out is still defined
        out = palette("Midnight")
        for key, value in pairs(custom_themes[name]) do out[key] = style.to_color(value) end
    end
    return out
end

local function default_theme()
    local theme = palette("Midnight")
    theme.clear = { R = 0, G = 0, B = 0, A = 0 }
    theme.on_accent = style.color("#FFFFFF")        -- text and knobs drawn on top of the accent colour
    theme.font_size, theme.title_size, theme.small_size = 11, 12, 10
    theme.spacing, theme.padding, theme.row_height, theme.bar_height, theme.nav_width = 8, 12, 28, 36, 156
    theme.window_shape, theme.control_shape = "round12", "round6"
    theme.animation = 0.16      -- seconds for open, close and expand animations (0 turns animation off)
    return theme
end

style.theme = default_theme()
style.theme_name = "Midnight"

-- What is painted, followed or claimed during a build belongs to its owner: a Lua table with a `destroyed` flag.
local building = nil

local function run_for(owner, make, ...)
    local outer = building
    building = owner
    local results = table.pack(pcall(make, ...))
    building = outer
    return results
end

-- Runs make(...) as the building of owner. If it fails the half-made owner counts as destroyed.
function style.build(owner, make, ...)
    local results = run_for(owner, make, ...)
    if results[1] then return table.unpack(results, 2, results.n) end
    owner.destroyed = true
    local problem = results[2]
    -- a message with no file and line gets the line that asked for the build
    if type(problem) == "string" and not problem:find("^[^\n]-:%d+: ") then error(problem, 3) end
    error(problem, 0)
end

-- The same for something added later to an owner that already exists. A failure leaves the owner as it was.
function style.extend(owner, make, ...)
    local results = run_for(owner, make, ...)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

function style.owner() return building end

function style.claim(entry)
    entry.owner = building
    return entry
end

function style.alive(entry) return entry.owner ~= nil and not entry.owner.destroyed end

-- Every colour put on something is remembered with its owner, so a theme change repaints what is on screen.
local painted, entry_of, sweep_at = {}, setmetatable({}, { __mode = "k" }), 4000
local PUT = {
    text = function(target, color) target:SetColorAndOpacity(style.slate(color)) end,
    image = function(target, color) target:SetColorAndOpacity(color) end,
    box = function(target, color) target:SetBrushColor(color) end,
    brush = function(target, color) target.TintColor = style.slate(color) end,
    ink = function(target, color) target.ForegroundColor = style.slate(color) end,
}

local function sweep()
    local kept = {}
    for _, entry in ipairs(painted) do
        if style.alive(entry) then kept[#kept + 1] = entry else entry_of[entry.target] = nil end
    end
    painted = kept
    sweep_at = math.max(4000, #kept * 2)
end

-- kind: "text" (a text block), "image", "box" (a border), "brush" (a brush struct), "ink" (a text box style).
function style.tint(target, kind, color)
    local entry = entry_of[target]
    if entry then
        entry.color = color
    elseif building and color ~= style.WHITE and color ~= style.theme.clear then
        entry = { target = target, kind = kind, color = color, owner = building }
        entry_of[target] = entry
        painted[#painted + 1] = entry
        if #painted > sweep_at then sweep() end
    end
    PUT[kind](target, color)
end

-- For a widget that is taken away while its owner stays (an icon that is replaced).
function style.forget(target)
    local entry = entry_of[target]
    if entry then entry.owner, entry_of[target] = nil, nil end
end

function style.painted() return #painted end

-- For what a remembered colour cannot express: apply() runs now and after every theme change while its owner exists.
local followers = {}

function style.follow(apply, owner)
    apply()
    followers[#followers + 1] = { apply = apply, owner = owner or building }
end

-- After the theme changed: every colour that is still on screen is put on again.
function style.refresh()
    renewed = renewed + 1
    for color in pairs(recipes) do renew(color) end
    local kept = {}
    for _, entry in ipairs(painted) do
        if style.alive(entry) then
            pcall(PUT[entry.kind], entry.target, entry.color)
            kept[#kept + 1] = entry
        else
            entry_of[entry.target] = nil
        end
    end
    painted = kept
    kept = {}
    for _, entry in ipairs(followers) do
        if style.alive(entry) then
            pcall(entry.apply)
            kept[#kept + 1] = entry
        end
    end
    followers = kept
end

function style.theme_names()
    local names = table.move(THEME_ORDER, 1, #THEME_ORDER, 1, {})
    for name in pairs(custom_themes) do names[#names + 1] = name end
    return names
end

-- Adds a theme: a table with any of the colour settings (window, panel, raised, text, accent ...) as "#RRGGBB".
function style.add_theme(name, colors)
    if type(name) ~= "string" or name == "" then error("a theme needs a name", 2) end
    if type(colors) ~= "table" then error("a theme is a table of colours", 2) end
    if PALETTES[name] then error("'" .. name .. "' is the name of a built-in theme", 2) end
    for key in pairs(colors) do
        if style.theme[key] == nil then error("unknown theme setting '" .. tostring(key) .. "'", 2) end
    end
    custom_themes[name] = colors
end

-- A theme colour keeps its table and changes in place, so whoever holds it has the new colour.
local function set(key, value)
    local current = style.theme[key]
    if type(current) == "table" and type(value) == "table" then
        current.R, current.G, current.B, current.A = value.R, value.G, value.B, value.A or 1
    else
        style.theme[key] = value
    end
end

local function override(overrides, level)
    for key, value in pairs(overrides) do
        if style.theme[key] == nil then error("unknown theme setting '" .. tostring(key) .. "'", level) end
        if type(style.theme[key]) == "table" and (type(value) == "string" or type(value) == "number") then
            value = style.color(value)
        end
        set(key, value)
    end
end

-- A theme's name (more: overrides on top of it) or a table of overrides. Colours apply at once, sizes to what is built next.
function style.set_theme(theme, more)
    if type(theme) == "string" then
        if not (PALETTES[theme] or custom_themes[theme]) then
            error("there is no theme named '" .. theme .. "' (" .. table.concat(style.theme_names(), ", ") .. ")", 2)
        end
        for key, value in pairs(palette(theme)) do set(key, value) end
        style.theme_name = theme
        if more then override(more, 3) end
    else
        override(theme, 3)
    end
    style.refresh()
end

function style.reset_theme()
    for key, value in pairs(default_theme()) do set(key, value) end
    style.theme_name = "Midnight"
    style.refresh()
end

return style
