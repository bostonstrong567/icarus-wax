-- Items, recipes, stations and the indexes between them, joined from the rows source.lua loaded.

local model = { version = 2, PAUSE_ROWS = 150 }

local ANCHOR = { hide = "FieldGuide_Hide", hidden = "Hidden", hand = "Character", seed = "SeedType_Enum" }
local HAND_ITEM = "fieldguide_character"
local GUIDE = "fieldguide_"
local LAST = 1000000

local FAMILIES = {
    seedtype_enum = { stat = "SeedType_Enum", table = "FarmingSeeds", field = "Itemable", count = "seeds" },
    nationalflag_enum = { stat = "NationalFlag_Enum", table = "NationalFlags", field = "Item", count = "flags" },
}

model.ANCHORS = { { "TagQueries", ANCHOR.hide }, { "FieldGuideCategories", ANCHOR.hidden }, { "RecipeSets", ANCHOR.hand },
    { "ItemTemplate", ANCHOR.seed } }

local function fold(name)
    return (name:lower())
end

local function ref(handle)
    local name = handle
    if type(handle) == "table" then name = handle.RowName end
    if type(name) ~= "string" or name == "" or name:lower() == "none" then return nil end
    return name
end

local function key_of(handle)
    local name = ref(handle)
    return name and fold(name) or nil
end

local function words(value)
    if type(value) ~= "string" then return "" end
    return value
end

local function path(value)
    if type(value) ~= "string" or value == "" or value:lower() == "none" then return nil end
    return value
end

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function list(value)
    if type(value) ~= "table" then return {} end
    return value
end

-- A list, or one struct taken as a list of one.
local function each(value)
    if type(value) ~= "table" then return {} end
    if #value == 0 and next(value) ~= nil then return { value } end
    return value
end

-- What one row of each loop counts towards PAUSE_ROWS, from timing the loops on the real tables.
local COST = { static = 4, recipe = 3, template = 0.5, level = 0.25, sorted = 0.2, counted = 0.1 }

local function ticker(pause)
    local count = 0
    return function(cost)
        count = count + (cost or 1)
        if count >= model.PAUSE_ROWS then
            count = 0
            if pause then pause() end
        end
    end
end

local function miss(m, name, row, field)
    for _, known in ipairs(m.missing) do
        if known.table == name and known.row == row and known.field == field then return end
    end
    m.missing[#m.missing + 1] = { table = name, row = row, field = field }
end

local function skip(m, name, row, from)
    m.skipped[#m.skipped + 1] = { table = name, row = row, from = from }
end

local function note(b)
    for _, problem in ipairs(b.source.problems) do miss(b.model, problem.table, nil, problem.field) end
end

-- A part is off when one of its tables is missing or lost a field.
local function broken(b, part, ...)
    local any = false
    for _, name in ipairs({ ... }) do
        if b.source.broken[name] then any = true end
    end
    if not any then return false end
    b.model.off[part] = true
    note(b)
    return true
end

local function static_item(b, key)
    if b.dropped[key] then return nil end
    return b.model.items[key]
end

-- The entry a static's row name leads to. A row that is not there is counted; a dropped one is not.
local function static_of(b, name, from)
    local key = fold(name)
    local item = static_item(b, key)
    if not item and not b.dropped[key] then skip(b.model, "ItemsStatic", name, from) end
    return item
end

local function fill(b, item, itemable)
    local name = itemable and words(itemable.DisplayName) or ""
    if name == "" then name = item.row end
    item.name = name
    item.lower = b.lower(name)
    item.icon = itemable and path(itemable.Icon) or nil
    item.weight = itemable and tonumber(itemable.Weight) or 0
    item.stack = itemable and tonumber(itemable.MaxStack) or 1
end

local function by_order(a, c)
    if a.order ~= c.order then return a.order < c.order end
    return a.position < c.position
end

local function by_name(a, c)
    if a.lower ~= c.lower then return a.lower < c.lower end
    return a.key < c.key
end

local NONE = {}

-- The list every view filters: category order, then name. Sorted a category at a time so it can pause, swapped in at the end.
local function finish(b, tick)
    local m = b.model
    local groups, orders, per_category = {}, {}, {}
    local items, shown, hidden, made_count, used_count = 0, 0, 0, 0, 0
    -- An item is listed under one category: of those it fits, the one with the fewest items (a bullet under Ammo, not Ranged).
    local fitting, order_of, single = {}, {}, {}
    for _, item in ipairs(b.order) do
        if not b.dropped[item.key] and not item.hidden then
            for _, key in ipairs(item.fits or NONE) do fitting[key] = (fitting[key] or 0) + 1 end
        end
    end
    for _, category in ipairs(m.categories) do order_of[category.key], single[category.key] = category.order, { category.key } end
    for _, item in ipairs(b.order) do
        if not b.dropped[item.key] then
            local home = nil
            for _, key in ipairs(item.fits or NONE) do
                if not home or (fitting[key] or 0) < (fitting[home] or 0) then home = key end
            end
            item.cats, item.order = home and single[home] or NONE, home and order_of[home] or LAST
            local group = groups[item.order]
            if not group then
                group = {}
                groups[item.order] = group
                orders[#orders + 1] = item.order
            end
            group[#group + 1] = item
            items = items + 1
            if item.hidden then
                hidden = hidden + 1
            else
                shown = shown + 1
                local made = m.made_by[item.key]
                if made and made[1] then made_count = made_count + 1 end
                if (m.uses[item.key] or 0) > 0 then used_count = used_count + 1 end
                for _, key in ipairs(item.cats) do per_category[key] = (per_category[key] or 0) + 1 end
            end
        end
        tick(COST.counted)
    end
    table.sort(orders)
    local entries = {}
    for _, order in ipairs(orders) do
        local group = groups[order]
        table.sort(group, by_name)
        for position = 1, #group do entries[#entries + 1] = group[position] end
        tick(#group * COST.sorted)
    end
    local counts = m.counts
    counts.items, counts.shown, counts.hidden, counts.made, counts.used = items, shown, hidden, made_count, used_count
    counts.recipes = #m.recipes
    for _, category in ipairs(m.categories) do category.count = per_category[category.key] or 0 end
    counts.dropped = 0
    for key in pairs(b.dropped) do
        m.items[key], m.made_by[key] = nil, nil
        counts.dropped = counts.dropped + 1
    end
    m.list = entries
    note(b)
end

function model.begin(source, lower, tags)
    if type(tags) ~= "table" or not tags.parse then error("model.begin needs the tags module as its third argument", 2) end
    local m = {
        version = model.version, stamp = source.stamps and source.stamps() or "", stage = 0,
        items = {}, list = {}, categories = {}, category = {}, recipes = {}, recipe = {}, sets = {}, set_list = {},
        tags = {}, resources = {}, levels = {}, subs = {},
        made_by = {}, used_in = {}, made_at = {}, tag_items = {}, res_used = {}, res_made = {}, uses = {},
        skipped = {}, missing = {}, off = {},
        counts = { items = 0, shown = 0, hidden = 0, bare = 0, seeds = 0, flags = 0, titles = 0, dropped = 0, recipes = 0,
            skipped_recipes = 0, made = 0, used = 0 },
    }
    return { model = m, source = source, lower = lower or string.lower, tags = tags, order = {}, statics = {}, variants = {},
        kinds = {}, processing = {}, templates = {}, dropped = {}, scratch = {} }
end

-- One kind of a static: the seed or flag a template's number stands for. Nil when the number names no kind.
local function variant_for(b, static, family, value, template)
    local m, src = b.model, b.source
    local at = type(value) == "number" and math.tointeger(value) or nil
    if not at or at < 0 then return nil end
    local side = src.names(family.table)[at + 1]
    if not side then
        skip(m, family.table, tostring(at), "ItemTemplate." .. template)
        return nil
    end
    local side_row = src.row(family.table, side)
    local itemable_name = side_row and ref(side_row[family.field])
    if not itemable_name then return nil end
    local itemable = src.row("Itemable", itemable_name)
    if not itemable then
        skip(m, "Itemable", itemable_name, family.table .. "." .. side)
        return nil
    end
    local key = static.key .. ":" .. fold(side)
    local item = m.items[key]
    if not item then
        item = { key = key, row = template, static = static.key, variant = { stat = family.stat, value = at }, browser = true,
            tags = static.tags, fits = static.fits, cats = NONE, order = LAST, hidden = static.hidden }
        fill(b, item, itemable)
        m.items[key] = item
        b.order[#b.order + 1] = item
        b.variants[#b.variants + 1] = item
        b.kinds[static.key] = (b.kinds[static.key] or 0) + 1
        m.counts[family.count] = m.counts[family.count] + 1
    end
    return item
end

local function read_categories(b)
    local m, src, tags = b.model, b.source, b.tags
    local queries = {}
    if broken(b, "categories", "FieldGuideCategories") then return queries end
    local found = false
    for position, name in ipairs(src.names("FieldGuideCategories")) do
        local row = src.row("FieldGuideCategories", name)
        local key = fold(name)
        if key == fold(ANCHOR.hidden) then
            found = true
        elseif row then
            local query_name = ref(row.TagQuery)
            local query_row = query_name and src.row("TagQueries", query_name)
            if query_name and not query_row then skip(m, "TagQueries", query_name, "FieldGuideCategories." .. name) end
            local subs = {}
            for _, handle in ipairs(list(row.Subcategories)) do
                local sub = ref(handle)
                if sub and src.has("FieldGuideSubcategories", sub) then
                    subs[#subs + 1] = sub
                elseif sub then
                    skip(m, "FieldGuideSubcategories", sub, "FieldGuideCategories." .. name)
                end
            end
            local label = words(row.DisplayName)
            local category = { key = key, row = name, name = label, lower = b.lower(label), icon = path(row.DisplayIcon),
                order = tonumber(row.DisplayOrder) or 0, position = position, subs = subs, count = 0 }
            m.categories[#m.categories + 1] = category
            m.category[key] = category
            queries[key] = query_row and tags.parse(query_row.Query) or nil
        end
    end
    if not found then
        miss(m, "FieldGuideCategories", ANCHOR.hidden)
        m.off.categories = true
        m.categories, m.category = {}, {}
        return {}
    end
    table.sort(m.categories, by_order)
    return queries
end

local function read_templates(b, tick)
    local m, src = b.model, b.source
    if broken(b, "templates", "ItemTemplate") then return end
    broken(b, "variants", "FarmingSeeds", "NationalFlags")
    local seeds = false
    for _, name in ipairs(src.names("ItemTemplate")) do
        local row = src.row("ItemTemplate", name)
        local static_name = row and ref(row.ItemStaticData)
        local static = static_name and static_of(b, static_name, "ItemTemplate." .. name)
        if static then
            local target = static
            for _, stat in ipairs(list(row.ItemCustomStats)) do
                local stat_name = type(stat.Stat) == "table" and stat.Stat.Value or nil
                local family = type(stat_name) == "string" and FAMILIES[fold(stat_name)] or nil
                if family then
                    if family.stat == ANCHOR.seed then seeds = true end
                    if not src.broken[family.table] then target = variant_for(b, static, family, stat.Value, name) or target end
                end
            end
            b.templates[fold(name)] = target.key
        end
        tick(COST.template)
    end
    if not seeds then
        miss(m, "ItemTemplate", ANCHOR.seed)
        m.off.seeds = true
    end
end

-- Stage 1: items, their categories and the hide rule, seed and flag kinds.
function model.items(b, pause)
    local m, src, tags = b.model, b.source, b.tags
    local tick = ticker(pause)
    if broken(b, "list", "ItemsStatic", "Itemable", "TagQueries") then return m end

    local hide_row = src.row("TagQueries", ANCHOR.hide)
    local hide = hide_row and tags.parse(hide_row.Query)
    if not hide then
        miss(m, "TagQueries", ANCHOR.hide)
        m.off.list = true
        return m
    end

    local queries = read_categories(b)
    for _, name in ipairs(src.names("ItemsStatic")) do
        local row = src.row("ItemsStatic", name)
        if row then
            local key = fold(name)
            local own = tags.union(row.Manual_Tags, row.Generated_Tags)
            local set = tags.set(own, b.scratch)
            local itemable_name = ref(row.Itemable)
            local itemable = itemable_name and src.row("Itemable", itemable_name)
            if itemable_name and not itemable then skip(m, "Itemable", itemable_name, "ItemsStatic." .. name) end
            local item = { key = key, row = name, static = key, browser = true, tags = own, fits = {}, cats = NONE, order = LAST }
            fill(b, item, itemable)
            item.hidden = not itemable or tags.matches(hide, set)
            if not itemable then
                item.bare = true
                m.counts.bare = m.counts.bare + 1
            end
            for _, category in ipairs(m.categories) do
                if tags.matches(queries[category.key], set) then item.fits[#item.fits + 1] = category.key end
            end
            b.processing[key] = ref(row.Processing)
            m.items[key] = item
            b.order[#b.order + 1] = item
            b.statics[#b.statics + 1] = item
        end
        tick(COST.static)
    end
    read_templates(b, tick)

    finish(b, tick)
    m.stage = 1
    return m
end

local function add(index, key, number, marks)
    if marks[key] == number then return end
    marks[key] = number
    local entries = index[key]
    if not entries then
        entries = {}
        index[key] = entries
    end
    entries[#entries + 1] = number
end

-- Both lists are in rising order; the result is too, each number once.
local function merged(first, second)
    if not first or #first == 0 then return second end
    if not second or #second == 0 then return first end
    local out, a, c = {}, 1, 1
    while first[a] or second[c] do
        local x, y = first[a], second[c]
        if y == nil or (x ~= nil and x <= y) then
            out[#out + 1] = x
            a = a + 1
            if x == y then c = c + 1 end
        else
            out[#out + 1] = y
            c = c + 1
        end
    end
    return out
end

local function read_sets(b)
    local m, src = b.model, b.source
    local groups = {}
    for _, name in ipairs(src.names("RecipeSets")) do
        local row = src.row("RecipeSets", name)
        if row then
            local key = fold(name)
            local label = words(row.RecipeSetName)
            local set = { id = key, row = name, name = label, lower = b.lower(label), icon = path(row.RecipeSetIcon),
                benches = {}, auto = false, group = key }
            if set.lower ~= "" then
                groups[set.lower] = groups[set.lower] or key
                set.group = groups[set.lower]
            end
            m.sets[key] = set
            m.set_list[#m.set_list + 1] = set
            m.made_at[key] = {}
        end
    end
    local hand = m.sets[fold(ANCHOR.hand)]
    if hand then
        hand.hand = true
    else
        miss(m, "RecipeSets", ANCHOR.hand)
        m.off.hand = true
    end

    for _, item in ipairs(b.statics) do
        local proc_name = b.processing[item.key]
        if proc_name then
            local row = src.row("Processing", proc_name)
            local set_name = row and ref(row.DefaultRecipeSet)
            local set = set_name and m.sets[fold(set_name)]
            if not row then
                skip(m, "Processing", proc_name, "ItemsStatic." .. item.row)
            elseif set_name and not set then
                skip(m, "RecipeSets", set_name, "Processing." .. proc_name)
            elseif set then
                set.benches[#set.benches + 1] = { item = item.key, mw = tonumber(row.MaxMilliwattage) or 0 }
                item.bench = item.bench or {}
                item.bench[#item.bench + 1] = set.id
                if row.AutoSelectRecipe == true then set.auto = true end
            end
        end
    end

    for _, set in ipairs(m.set_list) do
        local shown, rest, same = {}, {}, nil
        for _, bench in ipairs(set.benches) do
            local item = m.items[bench.item]
            if item.hidden then
                rest[#rest + 1] = bench
            else
                shown[#shown + 1] = bench
                if not same and item.lower == set.lower then same = bench.item end
            end
        end
        set.shown = #shown
        if set.hand and m.items[HAND_ITEM] then
            set.link = HAND_ITEM
        else
            set.link = same or (shown[1] and shown[1].item) or nil
        end
        for _, bench in ipairs(rest) do shown[#shown + 1] = bench end
        set.benches = shown
        if #set.benches == 0 then set.icon = nil end
    end
end

local function read_tags(b, tick)
    local m, src, tags = b.model, b.source, b.tags
    if broken(b, "tags", "CraftingTags") then return end
    local queries = {}
    for _, name in ipairs(src.names("CraftingTags")) do
        local row = src.row("CraftingTags", name)
        if row then
            local key = fold(name)
            local label = words(row.TagName)
            m.tags[key] = { key = key, row = name, name = label, lower = b.lower(label), icon = path(row.TagIcon) }
            m.tag_items[key] = {}
            local query_name = ref(row.Query)
            local query_row = query_name and src.row("TagQueries", query_name)
            if query_name and not query_row then skip(m, "TagQueries", query_name, "CraftingTags." .. name) end
            local tree = query_row and tags.parse(query_row.Query)
            if tree then queries[#queries + 1] = { key = key, tree = tree } end
        end
    end
    for _, item in ipairs(b.statics) do
        local set = tags.set(item.tags, b.scratch)
        for _, query in ipairs(queries) do
            if tags.matches(query.tree, set) then
                local entries = m.tag_items[query.key]
                entries[#entries + 1] = item.key
            end
        end
        tick()
    end
end

local function read_resources(b)
    local m, src = b.model, b.source
    if broken(b, "resources", "IcarusResources") then return end
    for _, name in ipairs(src.names("IcarusResources")) do
        local row = src.row("IcarusResources", name)
        if row then
            local key = fold(name)
            local label = words(row.DisplayName)
            m.resources[key] = { key = key, row = name, name = label, lower = b.lower(label), units = words(row.Units),
                icon = path(row.Recipe_Icon) }
            m.res_used[key], m.res_made[key] = {}, {}
        end
    end
end

-- One recipe row as the model keeps it, or nil when it names a row that is not there.
local function read_recipe(b, name, row)
    local m = b.model
    local from = "ProcessorRecipes." .. name
    local recipe = { id = fold(name), row = name, inputs = {}, tags_in = {}, res_in = {}, outputs = {}, res_out = {}, sets = {},
        stations = {}, mj = tonumber(row.RequiredMillijoules) or 0, random = row.bSelectOutputItemRandomly == true,
        disabled = row.bForceDisableRecipe == true }

    for _, input in ipairs(list(row.Inputs)) do
        local wanted = ref(input.Element)
        if wanted then
            local item = static_of(b, wanted, from)
            if not item then return nil end
            recipe.inputs[#recipe.inputs + 1] = { item = item.key, count = tonumber(input.Count) or 1 }
        end
    end
    for _, input in ipairs(list(row.QueryInputs)) do
        local wanted = ref(input.Query)
        if wanted then
            local tag = m.tags[fold(wanted)]
            if not tag then return nil, skip(m, "CraftingTags", wanted, from) end
            recipe.tags_in[#recipe.tags_in + 1] = { tag = tag.key, count = tonumber(input.Count) or 1 }
        end
    end
    for _, pair in ipairs({ { row.ResourceInputs, recipe.res_in }, { row.ResourceOutputs, recipe.res_out } }) do
        for _, amount in ipairs(each(pair[1])) do
            local wanted = ref(type(amount.Type) == "table" and amount.Type.Value or nil)
            if wanted then
                local resource = m.resources[fold(wanted)]
                if not resource then return nil, skip(m, "IcarusResources", wanted, from) end
                pair[2][#pair[2] + 1] = { res = resource.key, units = tonumber(amount.RequiredUnits) or 0 }
            end
        end
    end
    local all_hidden = true
    for _, output in ipairs(list(row.Outputs)) do
        local wanted = ref(output.Element)
        if wanted then
            local key = b.templates[fold(wanted)]
            if not key then return nil, skip(m, "ItemTemplate", wanted, from) end
            recipe.outputs[#recipe.outputs + 1] = { item = key, count = tonumber(output.Count) or 1, template = wanted }
            if not m.items[key].hidden then all_hidden = false end
        end
    end
    recipe.hidden_only = #recipe.outputs > 0 and all_hidden

    local seen = {}
    for _, handle in ipairs(list(row.RecipeSets)) do
        local wanted = ref(handle)
        local set = wanted and m.sets[fold(wanted)]
        if wanted and not set then
            skip(m, "RecipeSets", wanted, from)
        elseif set and not seen[set.id] then
            seen[set.id] = true
            recipe.sets[#recipe.sets + 1] = set.id
            if #set.benches > 0 then recipe.stations[#recipe.stations + 1] = set.id end
        end
    end

    local title = type(row.ItemIconOverride) == "table" and ref(row.ItemIconOverride.ItemStaticData) or nil
    local titled = title and static_of(b, title, from)
    if titled then recipe.title = titled.key end
    recipe.talent = key_of(row.Requirement)
    recipe.char_flag = key_of(row.CharacterRequirement)
    recipe.session = key_of(row.SessionRequirement)
    return recipe
end

local function read_recipes(b, tick)
    local m, src = b.model, b.source
    local made, used, res_in, res_out = {}, {}, {}, {}
    local plain, titles, preferred = {}, {}, {}
    for _, name in ipairs(src.names("ProcessorRecipes")) do
        local row = src.row("ProcessorRecipes", name)
        local recipe = row and read_recipe(b, name, row)
        if recipe then
            local number = #m.recipes + 1
            m.recipes[number] = recipe
            m.recipe[recipe.id] = number
            for _, output in ipairs(recipe.outputs) do
                local item = m.items[output.item]
                add(m.made_by, item.key, number, made)
                if item.variant then
                    add(m.made_by, item.static, number, made)
                    if not preferred[item.key] then
                        preferred[item.key] = true
                        item.row = src.names("ItemTemplate")[src.position("ItemTemplate", output.template)] or item.row
                    end
                else
                    plain[item.key] = true
                end
                output.template = nil
            end
            if recipe.title then
                add(m.made_by, recipe.title, number, made)
                if not titles[recipe.title] then
                    titles[recipe.title] = true
                    titles[#titles + 1] = recipe.title
                end
            end
            for _, input in ipairs(recipe.inputs) do add(m.used_in, input.item, number, used) end
            for _, input in ipairs(recipe.tags_in) do
                for _, key in ipairs(m.tag_items[input.tag]) do add(m.used_in, key, number, used) end
            end
            for _, key in ipairs(recipe.sets) do
                local entries = m.made_at[key]
                entries[#entries + 1] = number
            end
            for _, amount in ipairs(recipe.res_in) do add(m.res_used, amount.res, number, res_in) end
            for _, amount in ipairs(recipe.res_out) do add(m.res_made, amount.res, number, res_out) end
        elseif row then
            m.counts.skipped_recipes = m.counts.skipped_recipes + 1
        end
        tick(COST.recipe)
    end

    for _, key in ipairs(titles) do
        local item = m.items[key]
        if item.hidden then
            item.hidden = false
            item.title_only = true
            m.counts.titles = m.counts.titles + 1
        end
    end

    -- A static that only ever comes as one of its kinds, and that nothing uses, is not an entry of its own.
    for _, item in ipairs(b.statics) do
        local uses = m.used_in[item.key]
        if b.kinds[item.key] and not plain[item.key] and not titles[item.key] and not item.bench and not (uses and uses[1]) then
            b.dropped[item.key] = true
        end
        tick(COST.counted)
    end
end

local function link_resources(b, tick)
    local m = b.model
    local guides = {}
    for _, item in ipairs(b.statics) do
        if not b.dropped[item.key] and item.key:sub(1, #GUIDE) == GUIDE and not guides[item.lower] then guides[item.lower] = item end
        tick(COST.counted)
    end
    for _, name in ipairs(b.source.names("IcarusResources")) do
        local resource = m.resources[fold(name)]
        local item = resource and (static_item(b, GUIDE .. resource.key) or guides[resource.lower])
        if item and not item.resource then
            resource.link = item.key
            item.resource = resource.key
            local uses = merged(m.used_in[item.key], m.res_used[resource.key])
            local made = merged(m.made_by[item.key], m.res_made[resource.key])
            if uses[1] then m.used_in[item.key] = uses end
            if made[1] then m.made_by[item.key] = made end
        end
    end
end

local function read_redirects(b)
    local m, src = b.model, b.source
    if broken(b, "redirect", "FieldGuideRedirect") then return end
    for _, name in ipairs(src.names("FieldGuideRedirect")) do
        local row = src.row("FieldGuideRedirect", name)
        local from = "FieldGuideRedirect." .. name
        local shown_name = row and ref(row.DisplayItem)
        local shown = shown_name and static_of(b, shown_name, from)
        if shown then
            for _, handle in ipairs(list(row.HiddenItems)) do
                local hidden_name = ref(handle)
                local hidden = hidden_name and static_of(b, hidden_name, from)
                local uses = hidden and merged(m.used_in[shown.key], m.used_in[hidden.key])
                if uses and uses[1] then m.used_in[shown.key] = uses end
            end
        end
    end
end

local function read_hints(b, tick)
    local m, src = b.model, b.source
    if not broken(b, "hints", "FieldGuideMetaData") then
        for _, name in ipairs(src.names("FieldGuideMetaData")) do
            local row = src.row("FieldGuideMetaData", name)
            local wanted = row and ref(row.Item)
            local item = wanted and static_of(b, wanted, "FieldGuideMetaData." .. name)
            if item then
                item.hints = item.hints or {}
                for _, field in ipairs({ "Description1", "Description2", "Description3" }) do
                    local hint = words(row[field])
                    if hint ~= "" then item.hints[#item.hints + 1] = hint end
                end
            end
            tick(COST.template)
        end
    end
    if not broken(b, "workshop", "WorkshopItems") then
        for _, name in ipairs(src.names("WorkshopItems")) do
            local row = src.row("WorkshopItems", name)
            local wanted = row and ref(row.Item)
            local key = wanted and b.templates[fold(wanted)]
            if wanted and not key then
                skip(m, "ItemTemplate", wanted, "WorkshopItems." .. name)
            elseif key and not b.dropped[key] then
                m.items[key].workshop = true
            end
            tick(COST.template)
        end
    end
end

-- Stage 2: stations, recipes and the indexes.
function model.recipes(b, pause)
    local m = b.model
    local tick = ticker(pause)
    if m.stage < 1 or m.off.list then return m end
    if broken(b, "recipes", "ProcessorRecipes", "ItemTemplate", "RecipeSets", "Processing") then return m end

    read_sets(b)
    read_tags(b, tick)
    read_resources(b)
    read_recipes(b, tick)
    link_resources(b, tick)
    read_redirects(b)
    read_hints(b, tick)

    for _, item in ipairs(b.variants) do m.used_in[item.key] = m.used_in[item.static] end
    for key, entries in pairs(m.used_in) do
        local count = 0
        for _, number in ipairs(entries) do
            if not m.recipes[number].hidden_only then count = count + 1 end
        end
        m.uses[key] = count
        tick(#entries * COST.counted)
    end

    finish(b, tick)
    m.stage = 2
    return m
end

-- Stage 3: which paid expansion an item or a recipe belongs to.
function model.levels(b, pause)
    local m, src = b.model, b.source
    local tick = ticker(pause)
    if m.stage < 1 or m.off.list then return m end
    if broken(b, "levels", "FeatureLevels") then return m end

    local packs = {}
    if not broken(b, "packs", "DLCPackageData") then
        for _, name in ipairs(src.names("DLCPackageData")) do
            local row = src.row("DLCPackageData", name)
            if row then packs[(fold(name):gsub("_", ""))] = trim(words(row.DLCName)) end
        end
    end
    for _, name in ipairs(src.names("FeatureLevels")) do
        local row = src.row("FeatureLevels", name)
        local icon = row and path(row.Icon)
        if icon then
            local key = fold(name)
            local label = packs[(key:gsub("_", ""))]
            if not label or label == "" then label = trim(words(row.DisplayName)) end
            m.levels[key] = { key = key, row = name, name = label, icon = icon }
        end
    end

    local of_static = {}
    for _, item in ipairs(b.statics) do
        local key = key_of(src.level("ItemsStatic", item.row))
        if key and m.levels[key] then
            of_static[item.key] = key
            item.level = key
        end
        tick(COST.level)
    end
    for _, item in ipairs(b.variants) do item.level = of_static[item.static] end
    for _, recipe in ipairs(m.recipes) do
        local key = key_of(src.level("ProcessorRecipes", recipe.row))
        if key and m.levels[key] then recipe.level = key end
        tick(COST.level)
    end

    m.stage = 3
    note(b)
    return m
end

function model.build(source, pause, lower, tags)
    if type(tags) ~= "table" or not tags.parse then error("model.build needs the tags module as its fourth argument", 2) end
    local b = model.begin(source, lower, tags)
    model.items(b, pause)
    model.recipes(b, pause)
    model.levels(b, pause)
    return b.model, b
end

local function in_category(item, key)
    for _, own in ipairs(item.cats) do
        if own == key then return true end
    end
    return false
end

-- The subcategories of one category, worked out the first time it is asked for.
function model.subcategories(m, source, tags, key)
    local known = m.subs[key]
    if known then return known end
    local category = m.category[key]
    if not category then return {} end
    local subs = {}
    for position, name in ipairs(category.subs) do
        local row = source.row("FieldGuideSubcategories", name)
        if row then
            local query_name = ref(row.TagQuery)
            local query_row = query_name and source.row("TagQueries", query_name)
            local label = words(row.DisplayName)
            subs[#subs + 1] = { key = fold(name), row = name, name = label, order = tonumber(row.DisplayOrder) or 0,
                position = position, tree = query_row and tags.parse(query_row.Query) or nil, items = {}, count = 0 }
        end
    end
    table.sort(subs, by_order)
    local scratch = {}
    for _, item in ipairs(m.list) do
        if in_category(item, key) then
            local set = tags.set(item.tags, scratch)
            for _, sub in ipairs(subs) do
                if tags.matches(sub.tree, set) then
                    sub.items[item.key] = true
                    if not item.hidden then sub.count = sub.count + 1 end
                end
            end
        end
    end
    for _, sub in ipairs(subs) do sub.tree, sub.position = nil, nil end
    m.subs[key] = subs
    return subs
end

return model
