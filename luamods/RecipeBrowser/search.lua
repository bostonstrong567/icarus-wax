-- The query language of the two search boxes, and the lower-casing every name goes through.

local search = {}

local find, gsub, gmatch, char = string.find, string.gsub, string.gmatch, string.char

local ASCII, PAIRS = {}, {}
for byte = 65, 90 do ASCII[char(byte)] = char(byte + 32) end

local function two(code)
    return char(0xC0 | (code >> 6), 0x80 | (code & 0x3F))
end

local function fold(first, last, step, offset)
    for code = first, last, step do PAIRS[two(code)] = two(code + offset) end
end

fold(0xC0, 0xDE, 1, 0x20)       -- Latin-1
PAIRS[two(0xD7)] = nil
fold(0x100, 0x136, 2, 1)        -- Latin Extended-A
PAIRS[two(0x130)] = "i"
fold(0x139, 0x147, 2, 1)
fold(0x14A, 0x176, 2, 1)
PAIRS[two(0x178)] = two(0xFF)
fold(0x179, 0x17D, 2, 1)
fold(0x400, 0x40F, 1, 0x50)     -- Cyrillic
fold(0x410, 0x42F, 1, 0x20)
fold(0x460, 0x480, 2, 1)
fold(0x48A, 0x4BE, 2, 1)
PAIRS[two(0x4C0)] = two(0x4CF)
fold(0x4C1, 0x4CD, 2, 1)
fold(0x4D0, 0x4FE, 2, 1)

-- Byte classes are spelled out because %u, %s and string.lower follow the C locale.
local LEADS = char(0xC3) .. "-" .. char(0xC5) .. char(0xD0) .. "-" .. char(0xD3)
local UPPER = "[A-Z" .. LEADS .. "]"
local LETTER = "[" .. LEADS .. "][" .. char(0x80) .. "-" .. char(0xBF) .. "]"
local WORD = "[^ \t\r\n]+"
local WIDE_SPACES = { char(0xC2, 0xA0), char(0xE3, 0x80, 0x80) }

function search.lower(text)
    if type(text) ~= "string" then return "" end
    if not find(text, UPPER) then return text end
    text = gsub(text, "[A-Z]", ASCII)
    return (gsub(text, LETTER, PAIRS))
end

local MARKS = { ["@"] = "stations", ["#"] = "categories", ["-"] = "excluded" }

-- A mark with nothing after it is ignored, so a half-typed term does not empty the list.
function search.parse(text)
    local query = { words = {}, stations = {}, categories = {}, excluded = {}, text = "", empty = true }
    if type(text) ~= "string" then return query end
    for index = 1, #WIDE_SPACES do text = gsub(text, WIDE_SPACES[index], " ") end
    query.text = text:match("^[ \t\r\n]*(.-)[ \t\r\n]*$")
    for token in gmatch(search.lower(text), WORD) do
        local kind = MARKS[token:sub(1, 1)]
        local list = query[kind or "words"]
        if kind then token = token:sub(2) end
        if token ~= "" then
            list[#list + 1] = token
            query.empty = false
        end
    end
    return query
end

search.SHOWS = { "all", "recipe", "favourites", "hidden" }

local function in_category(item, key)
    local cats = item.cats
    if not cats then return false end
    for index = 1, #cats do
        if cats[index] == key then return true end
    end
    return false
end

local function never(_, _) return false end

-- A lookup that is left out of the options matches nothing.
function search.filter(items, query, options)
    if type(query) ~= "table" then query = search.parse(query) end
    options = options or {}
    local show, category = options.show or "all", options.category
    local has_recipe = options.has_recipe or never
    local is_favourite = options.is_favourite or never
    local station_match = options.station_match or never
    local category_match = options.category_match or never
    local belongs = options.in_category or in_category
    local pause, every = options.pause, options.every or 500
    local words, excluded, stations, categories = query.words, query.excluded, query.stations, query.categories
    local word_count, excluded_count, station_count, category_count = #words, #excluded, #stations, #categories

    local out, count = {}, 0
    for index = 1, #items do
        local item = items[index]
        local keep
        if show == "hidden" then
            keep = item.hidden
        elseif show == "favourites" then
            keep = is_favourite(item)
        else
            keep = not item.hidden and (show ~= "recipe" or has_recipe(item))
        end
        if keep and category then keep = belongs(item, category) end
        if keep then
            local name = item.lower or ""
            for w = 1, word_count do
                if not find(name, words[w], 1, true) then keep = false break end
            end
            if keep then
                for w = 1, excluded_count do
                    if find(name, excluded[w], 1, true) then keep = false break end
                end
            end
            if keep then
                for w = 1, station_count do
                    if not station_match(item, stations[w]) then keep = false break end
                end
            end
            if keep then
                for w = 1, category_count do
                    if not category_match(item, categories[w]) then keep = false break end
                end
            end
            if keep then
                count = count + 1
                out[count] = item
            end
        end
        if pause and index % every == 0 then pause() end
    end
    return out
end

local CACHED_WORDS = 64

local function entry_key(entry)
    return entry.item or entry.tag or entry.res or entry[1]
end

-- The lookups search.filter asks for, made from a model. Make a new one after each load stage.
function search.index(model, parts)
    parts = parts or {}
    local lower = parts.lower or search.lower
    local member = parts.member
    local index = {}

    local function item_of(key)
        local items = model.items
        return items and items[key]
    end

    local function recipe_of(entry)
        if type(entry) == "table" then return entry end
        local recipes = model.recipes
        return recipes and recipes[entry]
    end

    local set_names = {}
    local function names_of_set(id, set)
        local names = set_names[id]
        if names then return names end
        names = {}
        if set.lower or set.name then names[#names + 1] = set.lower or lower(set.name) end
        local extra = parts.stations and parts.stations[id]
        if extra then names[#names + 1] = lower(extra) end
        for _, bench in ipairs(set.benches or {}) do
            local item = item_of(entry_key(bench))
            if item and not item.hidden and item.lower then names[#names + 1] = item.lower end
        end
        set_names[id] = names
        return names
    end

    local set_hits, set_words = {}, 0
    local function sets_for(word)
        local hits = set_hits[word]
        if hits then return hits end
        if set_words >= CACHED_WORDS then set_hits, set_words = {}, 0 end
        hits = {}
        for id, set in pairs(model.sets or {}) do
            local names = names_of_set(id, set)
            for n = 1, #names do
                if find(names[n], word, 1, true) then hits[id] = true break end
            end
        end
        set_hits[word], set_words = hits, set_words + 1
        return hits
    end

    -- The sets an item is made at: false, one id, or a list of ids. Kept per item.
    local item_sets = {}
    local function sets_of(item)
        local list = model.made_by and model.made_by[item.key]
        local first, many
        for n = 1, list and #list or 0 do
            local recipe = recipe_of(list[n])
            local ids = recipe and recipe.sets or {}
            for s = 1, #ids do
                local id = ids[s]
                if first == nil then
                    first = id
                elseif id ~= first then
                    many = many or { first }
                    local held = false
                    for m = 2, #many do
                        if many[m] == id then held = true break end
                    end
                    if not held then many[#many + 1] = id end
                end
            end
        end
        if many then return many end
        if first == nil then return false end
        return first
    end

    -- Without names the keys the items carry are what # is matched against.
    local category_names, category_items
    local function names_of_categories()
        if category_names then return category_names end
        category_names, category_items = {}, {}
        local given = parts.categories or model.categories
        for key, value in pairs(given or {}) do
            local name = value
            if type(value) == "table" then key, name = value.key or key, value.lower or value.name end
            if type(key) == "string" then
                category_names[key] = type(name) == "string" and lower(name) or ""
                if type(value) == "table" then category_items[key] = value.items end
            end
        end
        if given then return category_names end
        for _, item in pairs(model.items or {}) do
            for _, key in ipairs(item.cats or {}) do category_names[key] = "" end
        end
        return category_names
    end

    local category_hits, category_words = {}, 0
    local function categories_for(word)
        local hits = category_hits[word]
        if hits then return hits end
        if category_words >= CACHED_WORDS then category_hits, category_words = {}, 0 end
        hits = { held = {}, list = {}, items = {} }
        for key, name in pairs(names_of_categories()) do
            if find(name, word, 1, true) or find(key, word, 1, true) then
                hits.held[key] = true
                hits.list[#hits.list + 1] = key
                hits.items[#hits.items + 1] = category_items[key]
            end
        end
        category_hits[word], category_words = hits, category_words + 1
        return hits
    end

    function index.has_recipe(item)
        local list = model.made_by and model.made_by[item.key]
        return list ~= nil and list[1] ~= nil
    end

    local station_word, station_hits
    function index.station_match(item, word)
        if word ~= station_word then station_word, station_hits = word, sets_for(word) end
        local ids = item_sets[item]
        if ids == nil then
            ids = sets_of(item)
            item_sets[item] = ids
        end
        if not ids then return false end
        if type(ids) ~= "table" then return station_hits[ids] == true end
        for s = 1, #ids do
            if station_hits[ids[s]] then return true end
        end
        return false
    end

    local category_word, category_found
    function index.category_match(item, word)
        if word ~= category_word then category_word, category_found = word, categories_for(word) end
        local cats, held = item.cats, category_found.held
        for n = 1, cats and #cats or 0 do
            if held[cats[n]] then return true end
        end
        local lists = category_found.items
        for n = 1, #lists do
            if lists[n][item.key] then return true end
        end
        if member then
            local list = category_found.list
            for n = 1, #list do
                if member(item, list[n]) then return true end
            end
        end
        return false
    end

    local function named(group, key)
        local entry = group and group[key]
        if type(entry) ~= "table" then return nil end
        return entry.lower or (type(entry.name) == "string" and lower(entry.name)) or nil
    end

    -- Every name a recipe shows, joined once per recipe and kept.
    local texts = {}
    local function text_of(recipe)
        local text = texts[recipe]
        if text then return text end
        local names, count = {}, 0
        local function add(name)
            if name then
                count = count + 1
                names[count] = name
            end
        end
        local function add_items(list)
            for _, entry in ipairs(list or {}) do
                local item = item_of(entry_key(entry))
                add(item and item.lower)
            end
        end
        local title = recipe.title and item_of(recipe.title)
        add(title and title.lower)
        add_items(recipe.outputs)
        add_items(recipe.inputs)
        for _, entry in ipairs(recipe.tags_in or {}) do add(named(model.tags, entry_key(entry))) end
        for _, entry in ipairs(recipe.res_in or {}) do add(named(model.resources, entry_key(entry))) end
        for _, entry in ipairs(recipe.res_out or {}) do add(named(model.resources, entry_key(entry))) end
        text = table.concat(names, "\n")
        texts[recipe] = text
        return text
    end

    local function at_group(recipe, group)
        local ids, sets = recipe.sets, model.sets
        if not ids then return false end
        for s = 1, #ids do
            local id = ids[s]
            local set = sets and sets[id]
            if id == group or (set and set.group == group) then return true end
        end
        return false
    end

    local function output_in(recipe, word)
        local title = recipe.title and item_of(recipe.title)
        if title and index.category_match(title, word) then return true end
        for _, entry in ipairs(recipe.outputs or {}) do
            local item = item_of(entry_key(entry))
            if item and index.category_match(item, word) then return true end
        end
        return false
    end

    local function recipe_fits(recipe, query, group)
        if group ~= nil and not at_group(recipe, group) then return false end
        if query.empty then return true end
        local text = text_of(recipe)
        for w = 1, #query.words do
            if not find(text, query.words[w], 1, true) then return false end
        end
        for w = 1, #query.excluded do
            if find(text, query.excluded[w], 1, true) then return false end
        end
        for w = 1, #query.stations do
            local hits, ids, found = sets_for(query.stations[w]), recipe.sets or {}, false
            for s = 1, #ids do
                if hits[ids[s]] then found = true break end
            end
            if not found then return false end
        end
        for w = 1, #query.categories do
            if not output_in(recipe, query.categories[w]) then return false end
        end
        return true
    end

    -- The list holds recipes or their numbers. The group is a set's group or id, nil for every station.
    function index.filter_recipes(recipes, text, group)
        local query = type(text) == "table" and text or search.parse(text)
        local out, count = {}, 0
        for n = 1, #recipes do
            local recipe = recipe_of(recipes[n])
            if recipe and recipe_fits(recipe, query, group) then
                count = count + 1
                out[count] = recipes[n]
            end
        end
        return out
    end

    function index.filter(items, query, options)
        local filled = {
            has_recipe = index.has_recipe,
            station_match = index.station_match,
            category_match = index.category_match,
        }
        for key, value in pairs(options or {}) do filled[key] = value end
        return search.filter(items, query, filled)
    end

    return index
end

function search.filter_recipes(recipes, text, group, index)
    if not index then error("search.filter_recipes needs the index made by search.index(model)", 2) end
    return index.filter_recipes(recipes, text, group)
end

return search
