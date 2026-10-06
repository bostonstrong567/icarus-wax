-- Icons by name: the bundled Lucide set (see assets/lucide), plus images that mods register

local Wax = ...
local suggest = Wax.import("core.suggest")
local scope = Wax.import("core.scope")

local icons = {}

-- name -> its place on the sheet of small icons (assets/lucide/sheet32.png, written by scripts/import_lucide.py)
local bundled, sorted, count = {}, nil, 0
for name in Wax.import("gui.icons_list"):gmatch("%S+") do
    count = count + 1
    bundled[name] = count
end
icons.SHEET_COLUMNS = 40
local registered = { ["wax-grip"] = Wax.root .. "/assets/icon_grip.png" }

-- The texture key (and file, for registered images) of an icon drawn at this many screen pixels.
function icons.resolve(name, pixels)
    local file = registered[name]
    if file then return "icon:" .. name .. ":" .. file, file end
    if not bundled[name] then
        error(("there is no icon named '%s'.%s"):format(tostring(name), suggest.phrase(tostring(name), icons.names())), 0)
    end
    return "lucide/" .. (pixels > 22 and "96" or "32") .. "/" .. name
end

-- Column and row on the sheet, for a bundled icon drawn small, or nil for anything else.
function icons.cell(name, pixels)
    local place = bundled[name]
    if not place or pixels > 22 or registered[name] then return nil end
    return (place - 1) % icons.SHEET_COLUMNS, (place - 1) // icons.SHEET_COLUMNS
end

function icons.has(name) return bundled[name] ~= nil or registered[name] ~= nil end

function icons.names()
    if not sorted then
        sorted = {}
        for name in pairs(bundled) do sorted[#sorted + 1] = name end
        for name in pairs(registered) do
            if name ~= "wax-grip" then sorted[#sorted + 1] = name end
        end
        table.sort(sorted)
    end
    return sorted
end

-- Names containing the text, at most `limit` of them (all when the text is empty).
function icons.find(text, limit)
    local out, needle = {}, tostring(text or ""):lower()
    for _, name in ipairs(icons.names()) do
        if needle == "" or name:find(needle, 1, true) then
            out[#out + 1] = name
            if limit and #out >= limit then break end
        end
    end
    return out
end

-- Adds an icon from a PNG file (white on transparent works best: it is tinted when drawn).
function icons.register(name, file)
    if type(name) ~= "string" or name == "" then error("an icon needs a name", 2) end
    if type(file) ~= "string" or file == "" then error("an icon needs the path of a .png file", 2) end
    registered[name] = (file:gsub("\\", "/"))
    sorted = nil
    -- the icon belongs to the mod that registered it and is removed with it
    scope.own(function()
        registered[name] = nil
        sorted = nil
    end)
end

function icons.list() return table.move(icons.names(), 1, #icons.names(), 1, {}) end

return icons
