-- Every text the mod shows. Names from the game are passed in and come in the player's language.

local text = {}

local SEPARATOR = " - "

function text.number(value)
    local whole = math.tointeger(math.floor(tonumber(value) or 0)) or 0
    local digits = string.format("%d", math.abs(whole)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if digits:sub(1, 1) == "," then digits = digits:sub(2) end
    return (whole < 0 and "-" or "") .. digits
end

local number = text.number

local function counted(count, one, many)
    return number(count) .. " " .. (count == 1 and one or many)
end

local function filled(value)
    return value ~= nil and value ~= false and value ~= ""
end

-- Joins the parts that hold something. A list among the parts is joined in.
function text.join(...)
    local parts = {}
    for index = 1, select("#", ...) do
        local part = select(index, ...)
        if type(part) == "table" then
            for _, inner in ipairs(part) do
                if filled(inner) then parts[#parts + 1] = tostring(inner) end
            end
        elseif filled(part) then
            parts[#parts + 1] = tostring(part)
        end
    end
    return table.concat(parts, SEPARATOR)
end

function text.no_match(query)
    return 'Nothing matches "' .. tostring(query or "") .. '".'
end

function text.and_more(count)
    if count < 1 then return "" end
    return "and " .. number(count) .. " more"
end

function text.plus(count)
    if count < 1 then return "" end
    return "+" .. number(count)
end

-- The first names of a list, then "and 2 more" for the rest.
function text.some(names, limit)
    limit = limit or 6
    local lines = {}
    for index = 1, math.min(#names, limit) do lines[index] = names[index] end
    if #names > limit then lines[#lines + 1] = text.and_more(#names - limit) end
    return lines
end

-- A length of time: "2.5 s", "40 s", "3 min 20 s", "2 h 5 min".
function text.duration(seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 9.95 then return (("%.1f"):format(seconds):gsub("%.0$", "")) .. " s" end
    local whole = math.floor(seconds + 0.5)
    if whole < 60 then return whole .. " s" end
    local minutes, rest = whole // 60, whole % 60
    if minutes < 60 then return rest > 0 and (minutes .. " min " .. rest .. " s") or (minutes .. " min") end
    local hours, left = minutes // 60, minutes % 60
    return left > 0 and (number(hours) .. " h " .. left .. " min") or (number(hours) .. " h")
end

text.title = "Recipe Browser"
text.tabs = { browse = "Browse", settings = "Settings" }

text.left = {
    heading = "Items",
    hint = "Search items",
    all_categories = "All categories",
    show = { all = "All items", recipe = "Has a recipe", favourites = "Favourites", hidden = "Hidden by the game" },
}

function text.left.count(shown, total, query)
    total = total or shown
    if shown == 0 and filled(query) then return text.no_match(query) end
    if shown == total then return counted(total, "item", "items") end
    return number(shown) .. " of " .. counted(total, "item", "items")
end

text.right = {
    none = "Nothing picked",
    none_hint = "Click an item to see how it is made.",
    hint = "Search this list",
    modes = { make = "How to make it", used = "Used in", here = "Made here" },
    all_stations = "All stations",
    no_recipe = "No recipe makes this. Drops, mining, farming and fishing are not listed yet.",
    no_use = "Nothing uses this.",
    nothing_here = "Nothing is made here.",
    by_hand = "By hand",
    one_of = "one of",
    sources = "Where it comes from",
    workshop = "Bought in the Workshop",
}

function text.right.mode(mode, count)
    local name = text.right.modes[mode] or tostring(mode)
    if not count then return name end
    return name .. " (" .. number(count) .. ")"
end

function text.right.stacks(stack)
    if not stack or stack <= 1 then return "" end
    return "stacks to " .. number(stack)
end

-- The small line under the picked item's name: "stacks to 100 - 10 g - Dangerous Horizons".
function text.right.about(stack, weight, level)
    return text.join(text.right.stacks(stack), weight, level)
end

function text.right.stations(count)
    if count < 1 then return "" end
    return counted(count, "station", "stations")
end

-- A name and its figure as one sentence, for a pair too long to stand side by side: "Turns into: Spoiled Plants".
function text.pair(name, value)
    return tostring(name) .. ": " .. tostring(value)
end

-- A count short enough for a slot: 301, 1.8k, 12k, 1.2M. The whole number goes in the tip.
function text.short(value)
    local whole = math.floor(tonumber(value) or 0)
    if whole < 1000 then return tostring(math.tointeger(whole) or whole) end
    local unit, scaled = "k", whole / 1000
    if scaled >= 999.5 then unit, scaled = "M", whole / 1000000 end
    if scaled < 9.95 then return (("%.1f"):format(scaled):gsub("%.0$", "")) .. unit end
    return ("%d"):format(math.floor(scaled + 0.5)) .. unit
end

function text.right.times(count)
    return "x" .. number(count)
end

function text.right.any(name)
    return "any " .. name
end

function text.right.amount(amount, unit)
    if not filled(unit) then return tostring(amount) end
    return tostring(amount) .. " " .. unit
end

local KEY_WORDS = { { "make", "how to make" }, { "used", "used in" }, { "favourite", "favourite" } }

-- The keys line under the right list, from the binds in use: "R how to make - U used in - A favourite".
function text.right.keys(binds)
    local parts = {}
    for _, pair in ipairs(KEY_WORDS) do
        local key = binds and binds[pair[1]]
        if filled(key) then parts[#parts + 1] = key .. " " .. pair[2] end
    end
    return table.concat(parts, SEPARATOR)
end

text.strip = {}

function text.strip.caption(count)
    return "Favourites (" .. number(count) .. ")"
end

function text.strip.empty(key)
    if not filled(key) then return "Use the star to keep an item here." end
    return "Press " .. key .. " over an item to keep it here."
end

text.status = { amounts = "Amounts are before talents." }

function text.status.reading(count)
    if not count or count < 1 then return "Reading the game's items..." end
    return "Reading the game's items... " .. number(count)
end

function text.status.counts(items, recipes)
    return counted(items, "item", "items") .. ", " .. counted(recipes, "recipe", "recipes")
end

function text.status.opens(key)
    if not filled(key) then return "" end
    return key .. " opens this"
end

function text.first_load(key)
    if not filled(key) then return "" end
    return "Press " .. key .. " to open the Recipe Browser."
end

text.needs = {
    known = "known from the start",
    mission_only = "only during a mission",
    no_talent = "cannot be made in this version of the game",
    no_station = "cannot be made",
}

function text.needs.tier(tier)
    return "Tier " .. tostring(tier)
end

function text.needs.level(level)
    return "level " .. number(level)
end

function text.needs.pack(name)
    return "needs " .. name
end

function text.needs.mission(name)
    return "needs " .. name .. " finished"
end

function text.needs.talent(name)
    return "needs talent " .. name
end

text.tip = {
    no_recipe = "No recipe",
    favourite = "In favourites",
    list_them = "Click to list them",
    what_uses = "Click for what uses it",
}

function text.tip.made_at(names, limit)
    limit = limit or 2
    if #names == 0 then return "" end
    local shown = {}
    for index = 1, math.min(#names, limit) do shown[index] = names[index] end
    if #names > limit then shown[#shown + 1] = text.plus(#names - limit) end
    return "Made at " .. table.concat(shown, ", ")
end

-- "Takes 2.5 s", or the benches with a time each when they differ: "Campfire 30 s, Fireplace 23 s".
function text.tip.takes(time)
    if not filled(time) then return "" end
    if time:find(",", 1, true) then return time end
    return "Takes " .. time
end

function text.tip.used_in(count)
    if count < 1 then return "" end
    return "Used in " .. counted(count, "recipe", "recipes")
end

function text.tip.amount(count, name)
    return tostring(count) .. " x " .. name
end

function text.tip.made(name, count)
    return name .. " " .. text.right.times(count)
end

function text.tip.resource(name, amount, unit)
    return name .. " " .. text.right.amount(amount, unit)
end

function text.tip.one_of(count)
    if not count or count < 1 then return text.right.one_of end
    return text.right.one_of .. " " .. number(count)
end

function text.tip.bench(name, time)
    if not filled(time) then return name end
    return name .. " " .. time
end

text.panel = {
    search = "Search",
    favourites = "Favourites",
    click = "Click for the recipe",
    station = "Click again for its recipe",
    views = { make = "Recipe", used = "Uses", tree = "Materials", details = "Details" },
    where = "Where it comes from",
    bench_only = "This bench only",
    can_make = "You can make this now",
    missing = "Something is missing to make this",
    choose = "Click to choose it at the bench",
    make_here = "Make it here",
    back = "Items",
    order_keep = "Keep this order",
    order_drop = "Remove this order",
    order_open = "Click for what it takes",
    order_remove = "Middle click to remove it",
}

function text.panel.ready(count)
    if count < 1 then return "None can be made now" end
    return number(count) .. " can be made now"
end

function text.panel.page(page, pages)
    return "Page " .. number(page) .. " of " .. number(pages)
end

text.tree = {
    button = "Raw materials",
    gather = "Gather",
    craft = "Make, in this order",
    nothing = "This is gathered, hunted or bought. Nothing makes it.",
}

function text.tree.title(count)
    return "Everything for " .. number(count)
end

function text.tree.crafts(crafts, station)
    local times = crafts == 1 and "once" or (number(crafts) .. " times")
    if not filled(station) then return "Make " .. times end
    return "Make " .. times .. " at " .. station
end

-- One line of the order's times: "Stick x10 - 25 s at Character".
function text.tree.step(name, crafts, time, bench)
    local line = name .. " " .. text.right.times(crafts)
    if not filled(time) then return line end
    if not filled(bench) then return line .. SEPARATOR .. time end
    return line .. SEPARATOR .. time .. " at " .. bench
end

function text.tree.each(each, all)
    if each == all then return "Takes " .. all end
    return each .. " each, " .. all .. " in all"
end

function text.tree.total(time)
    return "Making it all takes " .. time .. ", before talents and upgrades."
end

function text.tree.makes(made, left)
    if not left or left < 1 then return "Makes " .. number(made) end
    return "Makes " .. number(made) .. ", " .. number(left) .. " left over"
end

text.research = {
    done = "Researched",
    one = "Research",
    all = "Research all",
    cancel = "Cancel",
}

local function in_points(count)
    return counted(count, "point", "points")
end

-- "A", "A and B", "A, B and C", then "A, B, C and 2 more".
local function named(names, limit)
    local shown = {}
    for index = 1, math.min(#names, limit) do shown[index] = names[index] end
    if #names > limit then shown[#shown + 1] = number(#names - limit) .. " more" end
    if #shown < 2 then return shown[1] or "" end
    return table.concat(shown, ", ", 1, #shown - 1) .. " and " .. shown[#shown]
end

function text.research.button(count)
    return "Research (" .. in_points(count) .. ")"
end

-- Asked before a press researches more than the one thing: "Researches Anvil Bench first. 2 points in all."
function text.research.ask(first, count, have)
    return "Researches " .. named(first, 3) .. " first. " .. in_points(count) .. " in all."
end

-- Asked before a press spends points on the one thing: "This spends 1 point."
function text.research.ask_one(count, have)
    return "This spends " .. in_points(count) .. "."
end

-- What the player has to spend, shown once above the recipes.
function text.research.have(count)
    return "Research points: " .. number(count)
end

function text.research.level(level)
    return "Unlocks at level " .. number(level)
end

function text.research.points(count, have)
    return "Needs " .. in_points(count)
end

function text.research.researched(name)
    return name .. " researched."
end

function text.research.refused(name)
    return "The game did not research " .. name .. "."
end

text.settings = {
    keys = { open = "Open the browser", make = "How to make it", used = "Used in", favourite = "Favourite", back = "Back" },
    key_is_menu = "This key opens the Wax menu.",
    key_taken = "Another action uses this key.",
    cell_size = "Cell size",
    sizes = { small = "Small", normal = "Normal", large = "Large" },
    as_list = "Show as a list",
    as_lines = "Show recipes as lines",
    internal_names = "Show internal names",
    read_at_start = "Read the game's data when the game starts",
    read_again = "Read the game's data again",
    clear = "Clear favourites",
    remove = "Remove",
    keep = "Keep",
}

function text.settings.with_menu(key)
    if not filled(key) then return "Show with the Wax menu" end
    return "Show with the Wax menu (" .. key .. ")"
end

function text.settings.clear_question(count)
    if count < 1 then return "There are no favourites." end
    if count == 1 then return "Remove 1 favourite?" end
    return "Remove all " .. number(count) .. " favourites?"
end

function text.settings.read(items, recipes, seconds)
    local line = text.status.counts(items, recipes)
    if not seconds or seconds <= 0 then return line end
    return line .. string.format(", read in %.1f s", seconds)
end

function text.settings.skipped(count)
    if count < 1 then return "" end
    return counted(count, "recipe", "recipes") .. " could not be read"
end

text.problem = {}

function text.problem.needs_wax(version)
    if not filled(version) then return "Recipe Browser needs a newer Wax." end
    return "Recipe Browser needs Wax " .. version .. " or newer."
end

function text.problem.changed(table_name, name)
    local what = filled(name) and (table_name .. "." .. name) or table_name
    return "This version of the game changed " .. what .. ". Recipes cannot be shown until Recipe Browser is updated."
end

return text
