-- A store as a mod describes it, worked out into a plan: row names for its ids, parents, prices, places, and what is wrong with it

local Wax = ...
local suggest = Wax.import("core.suggest")
local check = Wax.import("world.workshop_check")
local layout = Wax.import("world.workshop_layout")

local M = {}

M.LINES = { "elbow", "elbow-down", "straight", "none" }
M.MAX_AMOUNT = 2147483647
M.MAX_ROW = 100             -- the longest name game.Data takes for a row a mod adds

local STORE_KEYS = { "mod", "categories" }
local ARRANGE_KEYS = { "shape" }
local CATEGORY_KEYS = { "id", "into", "name", "icon", "background", "level", "arrange", "nodes" }
local FRESH_ONLY = { "name", "icon", "background", "level" }
local NODE_KEYS = { "id", "gives", "research", "replicate", "needs", "at", "line", "free" }
local NEEDS_KEYS = { "any", "all", "level", "flags" }
local GIVES_KEYS = { "item", "count" }
local PRICES = { "research", "replicate" }
local ARRANGE = "arrange is the name of a shape, a function, or a table such as { shape = \"grid\", rows = 4 }"

local function fold(name) return (tostring(name):lower()) end

local function whole(value)
    return type(value) == "number" and math.tointeger(value) or nil
end

-- A wrong value as it goes into a sentence: text in quotes, a number as it is, anything else by its kind.
local function written(value)
    if type(value) == "string" then return "\"" .. value .. "\"" end
    if type(value) == "number" or type(value) == "boolean" then return value end
    return "a " .. type(value)
end

local function clean(problem)
    local text = tostring(problem):match("^[^\r\n]*") or ""
    local stripped = 1
    while stripped > 0 do text, stripped = text:gsub("^.-%.lua:%d+: ", "") end
    return text
end

local function sentence(text)
    if text:find("[%.%?]$") then return text end
    return text .. "."
end

local function sorted_keys(of)
    local keys = {}
    for key in pairs(of) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

-- nil is an empty list, one name is a list of one. Anything else is not a list of names.
local function names_of(value)
    if value == nil then return {} end
    if type(value) == "string" then return { value } end
    if type(value) ~= "table" then return nil end
    for _, name in ipairs(value) do
        if type(name) ~= "string" then return nil end
    end
    return value
end

-- The plan for a described store: { mod, categories, nodes, problems, ok }. `world` answers for the game. Options: mod (its id), folder (true when that id is the mod's folder name).
function M.compile(described, world, options)
    local problems = check.list()
    local plan = { categories = {}, nodes = {}, ok = false }
    local function done()
        plan.problems = problems.sorted()
        plan.ok = problems.count() == 0
        for _, node in ipairs(plan.nodes) do node.source = nil end
        for _, category in ipairs(plan.categories) do category.source = nil end
        return plan
    end
    if type(described) ~= "table" or type(described.categories) ~= "table" then
        problems.error("spec")
        return done()
    end

    local function stray(of, known, who, where)
        local allowed = {}
        for _, key in ipairs(known) do allowed[key] = true end
        for _, key in ipairs(sorted_keys(of)) do
            if not allowed[key] then
                problems.error("key", where, who, tostring(key), type(key) == "string" and suggest.phrase(key, known) or "")
            end
        end
    end

    stray(described, STORE_KEYS, "The store")
    local mod = options and options.mod or described.mod
    if mod == nil then
        problems.error("mod")
        return done()
    end
    -- stricter than what loads as a mod: research is saved under these row names for good, so the id is one that can be published
    if type(mod) ~= "string" or not mod:find("^%a[%w_]*$") then
        problems.error(options and options.folder and "mod-folder" or "mod-bad", nil, tostring(mod))
        return done()
    end
    plan.mod = mod
    if #described.categories == 0 then
        problems.error("categories")
        return done()
    end

    local own, own_ids, fresh = {}, {}, {}      -- folded id -> its node, the ids as written, folded id -> a new category

    -- first every category and id, so a node may need one that is written further down
    for position, entry in ipairs(described.categories) do
        if type(entry) ~= "table" then
            problems.error("category-shape", nil, position)
        else
            local label = tostring(entry.id or entry.into or position)
            local where = { category = label }
            local category = { label = label, nodes = {}, source = entry }
            plan.categories[#plan.categories + 1] = category
            stray(entry, CATEGORY_KEYS, "Category " .. label, where)
            if (entry.id ~= nil) == (entry.into ~= nil) then
                problems.error("category-kind", where, label)
            elseif entry.id ~= nil then
                category.new = true
                if type(entry.id) ~= "string" or not entry.id:find("^[%w_]+$") then
                    problems.error("id-bad", where, tostring(entry.id))
                else
                    category.id, category.row = entry.id, mod .. "_" .. entry.id
                    category.tree, category.key = category.row, fold(category.row)
                    if #category.row > M.MAX_ROW then
                        problems.error("row-long", where, "Category " .. label, category.row, #category.row, M.MAX_ROW)
                    end
                    if fresh[fold(entry.id)] then problems.error("category-twice", where, entry.id) end
                    fresh[fold(entry.id)] = category
                    for _, kind in ipairs({ "category", "tree" }) do
                        if world.has(kind, category.row) then
                            problems.error("id-taken", where, "Category " .. label, category.row, world.where(kind))
                        end
                    end
                end
                if type(entry.name) ~= "string" or entry.name == "" then problems.error("category-name", where, label) end
                category.name = entry.name
                for _, field in ipairs({ "icon", "background" }) do
                    local path = entry[field]
                    if path ~= nil and (type(path) ~= "string" or path:sub(1, 1) ~= "/") then
                        problems.error("texture", where, "Category " .. label, field)
                    else
                        category[field] = path
                    end
                end
                category.level = 0
                if entry.level ~= nil then
                    local level = whole(entry.level)
                    if not level or level < 0 then problems.error("level", where, "Category " .. label) else category.level = level end
                end
            else
                category.new = false
                local found = type(entry.into) == "string" and world.category(entry.into)
                if not found then
                    problems.error("category-missing", where, tostring(entry.into),
                        type(entry.into) == "string" and suggest.phrase(entry.into, world.names("category")) or "")
                else
                    -- from here on it is called as the game spells it
                    label = found.Id
                    category.label, where.category = label, label
                    category.row, category.tree, category.key = found.Id, found.Tree, fold(found.Id)
                    for _, field in ipairs(FRESH_ONLY) do
                        if entry[field] ~= nil then problems.error("category-fixed", where, label, field, field) end
                    end
                end
            end

            if type(entry.nodes) ~= "table" or #entry.nodes == 0 then
                problems.error("category-empty", where, label)
            else
                for at, source in ipairs(entry.nodes) do
                    if type(source) ~= "table" then
                        problems.error("node-shape", where, at, label)
                    elseif source.id == nil then
                        problems.error("id", where, at, label)
                    elseif type(source.id) ~= "string" or not source.id:find("^[%w_]+$") then
                        problems.error("id-bad", where, tostring(source.id))
                    else
                        local id = source.id
                        local node = { id = id, row = mod .. "_" .. id, category = category, source = source, size = layout.SIZE,
                            joint = false, any = {}, all = {}, level = 0, flags = {}, research = {}, replicate = {} }
                        node.key, node.store_item = fold(node.row), node.row
                        if #node.row > M.MAX_ROW then
                            problems.error("row-long", { node = id, category = label }, id, node.row, #node.row, M.MAX_ROW)
                        end
                        if own[fold(id)] then
                            problems.error("id-twice", { node = id, category = label }, id)
                        else
                            own[fold(id)] = node
                            own_ids[#own_ids + 1] = id
                            plan.nodes[#plan.nodes + 1] = node
                            category.nodes[#category.nodes + 1] = node
                            for _, kind in ipairs({ "talent", "store_item" }) do
                                if world.has(kind, node.row) then
                                    problems.error("id-taken", { node = id, category = label }, id, node.row, world.where(kind))
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local candidates = nil
    local function parent_row(node, where, name)
        if name == "" then
            problems.error("needs-shape", where, node.id)
            return nil
        end
        local mine = own[fold(name)]
        if mine then return mine.row end
        local theirs = world.node(name)
        if theirs then return theirs.Id end
        if world.has("talent", name) then
            problems.error("needs-foreign", where, node.id, name, world.where("talent"))
            return nil
        end
        if not candidates then
            candidates = table.move(own_ids, 1, #own_ids, 1, {})
            for _, id in ipairs(world.names("node")) do candidates[#candidates + 1] = id end
        end
        problems.error("needs-missing", where, node.id, name, suggest.phrase(name, candidates))
        return nil
    end

    local function parents(node, where, names, into)
        local seen = {}
        for _, name in ipairs(names) do
            local row = parent_row(node, where, name)
            if row and not seen[fold(row)] then
                seen[fold(row)] = true
                into[#into + 1] = row
            end
        end
    end

    for _, node in ipairs(plan.nodes) do
        local source, id = node.source, node.id
        local where = { node = id, category = node.category.label }
        stray(source, NODE_KEYS, id, where)

        local gives = source.gives
        if type(gives) == "string" then
            local found = world.has("template", gives)
            if found then
                local template = world.template(found)
                node.gives = { template = found, item = template and template.item or nil }
            elseif world.has("item", gives) then
                problems.error("gives-is-item", where, id, gives, world.where("item"), world.where("template"), world.has("item", gives))
            else
                problems.error("gives-template", where, id, gives, world.where("template"), suggest.phrase(gives, world.names("template")))
            end
        elseif type(gives) == "table" then
            stray(gives, GIVES_KEYS, id .. ": gives", where)
            local found = type(gives.item) == "string" and world.has("item", gives.item)
            if not found then
                if type(gives.item) == "string" and world.has("template", gives.item) then
                    problems.error("gives-is-template", where, id, gives.item, world.where("template"), world.where("item"),
                        world.has("template", gives.item))
                else
                    problems.error("gives-item", where, id, tostring(gives.item), world.where("item"),
                        type(gives.item) == "string" and suggest.phrase(gives.item, world.names("item")) or "")
                end
            end
            local count = gives.count == nil and 1 or whole(gives.count)
            if not count or count < 1 then problems.error("count", where, id) end
            if found and count and count >= 1 then
                node.gives = { template = node.row, item = found, count = count, new = true }
                if world.has("template", node.row) then problems.error("id-taken", where, id, node.row, world.where("template")) end
            end
        else
            problems.error("gives", where, id, world.where("template"), world.where("item"))
        end

        for _, name in ipairs(PRICES) do
            local given, amounts = source[name], {}
            if given ~= nil and type(given) ~= "table" then
                problems.error("price-shape", where, id, name)
            elseif given ~= nil then
                for _, currency in ipairs(sorted_keys(given)) do
                    local amount = given[currency]
                    local found = type(currency) == "string" and world.has("currency", currency)
                    if type(currency) ~= "string" then
                        problems.error("price-shape", where, id, name)
                    elseif not found then
                        problems.error("price-currency", where, id, name, currency, world.where("currency"),
                            suggest.phrase(currency, world.names("currency")))
                    elseif type(amount) == "number" and amount > M.MAX_AMOUNT then
                        problems.error("price-large", where, id, name, found, amount, M.MAX_AMOUNT)
                    elseif not whole(amount) then
                        problems.error("price-amount", where, id, name, found, written(amount))
                    elseif amount < 0 then
                        problems.error("price-negative", where, id, name, found, amount)
                    else
                        -- one currency written in two letter cases adds up, and the sum has the same limit
                        local sum = (amounts[fold(found)] or 0) + whole(amount)
                        if sum > M.MAX_AMOUNT then
                            problems.error("price-large", where, id, name, found, sum, M.MAX_AMOUNT)
                        else
                            amounts[fold(found)] = sum
                        end
                    end
                end
                -- in the order the game lists its currencies
                for _, currency in ipairs(world.names("currency")) do
                    if amounts[fold(currency)] then node[name][#node[name] + 1] = { currency = currency, amount = amounts[fold(currency)] } end
                end
            end
        end

        local needs = source.needs
        if type(needs) == "string" then
            parents(node, where, { needs }, node.any)
        elseif type(needs) == "table" then
            local named = false
            for key in pairs(needs) do named = named or type(key) ~= "number" end
            if named and #needs > 0 then
                problems.error("needs-shape", where, id)
            elseif not named then
                local any = names_of(needs)
                if any then parents(node, where, any, node.any) else problems.error("needs-shape", where, id) end
            else
                stray(needs, NEEDS_KEYS, id .. ": needs", where)
                local any, all, flags = names_of(needs.any), names_of(needs.all), names_of(needs.flags)
                if not (any and all and flags) then
                    problems.error("needs-shape", where, id)
                else
                    parents(node, where, any, node.any)
                    parents(node, where, all, node.all)
                    for _, flag in ipairs(flags) do
                        local found = world.has("flag", flag)
                        if found then
                            node.flags[#node.flags + 1] = { row = found, kind = "account" }
                        else
                            problems.error("flag", where, id, flag, world.where("flag"), suggest.phrase(flag, world.names("flag")))
                        end
                    end
                end
                if needs.level ~= nil then
                    local level = whole(needs.level)
                    if not level or level < 0 then problems.error("level", where, id) else node.level = level end
                end
            end
        elseif needs ~= nil then
            problems.error("needs-shape", where, id)
        end

        local at = source.at
        if at ~= nil then
            local x, y = nil, nil
            if type(at) == "table" then x, y = at[1] or at.x or at.X, at[2] or at.y or at.Y end
            if layout.usable(x) and layout.usable(y) then
                node.at = { x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
            elseif type(x) == "number" and type(y) == "number" and x == x and y == y then
                problems.error("at-far", where, id, x, y, layout.FAR)
            else
                problems.error("at", where, id)
            end
        end

        if source.line ~= nil then
            local known = false
            for _, word in ipairs(M.LINES) do known = known or source.line == word end
            if known then
                node.line = source.line
            else
                problems.error("line", where, id, type(source.line) == "string" and suggest.phrase(source.line, M.LINES) or "")
            end
        end

        if source.free ~= nil and type(source.free) ~= "boolean" then problems.error("free", where, id) end
        node.free = source.free == true
    end

    -- what the game only sells to owners of a DLC stays theirs alone
    local gates = nil
    for _, node in ipairs(plan.nodes) do
        if node.gives then
            gates = gates or world.gates()
            local have = {}
            for _, flag in ipairs(node.flags) do have[fold(flag.row)] = true end
            for _, list in ipairs({ gates.templates[fold(node.gives.template)] or {}, node.gives.item and gates.items[fold(node.gives.item)] or {} }) do
                for _, row in ipairs(list) do
                    if not have[fold(row)] then
                        have[fold(row)] = true
                        node.flags[#node.flags + 1] = { row = row, kind = "dlc", inherited = true }
                        problems.warn("dlc", { node = node.id, category = node.category.label }, node.id, row, node.id)
                    end
                end
            end
        end
    end

    for _, category in ipairs(plan.categories) do
        local loose = {}
        for _, node in ipairs(category.nodes) do
            if not node.at then loose[#loose + 1] = node end
        end
        if #loose > 0 then
            local arrange, chosen, fine = category.source.arrange, {}, true
            local shape = arrange
            if type(arrange) == "table" then
                shape = arrange.shape
                for _, key in ipairs(sorted_keys(arrange)) do
                    -- a misspelt `shape` is told as that, before the default shape gets to refuse it as an option of its own
                    local near = shape == nil and fine and type(key) == "string" and suggest.phrase(key, ARRANGE_KEYS) or ""
                    if near ~= "" then
                        fine = false
                        problems.error("arrange", { category = category.label }, category.label,
                            ("arrange has no option named '%s'.%s"):format(key, near))
                    elseif key ~= "shape" then
                        chosen[key] = arrange[key]
                    end
                end
            elseif arrange ~= nil and type(arrange) ~= "string" and type(arrange) ~= "function" then
                fine = false
                problems.error("arrange", { category = category.label }, category.label, sentence(ARRANGE))
            end
            if shape == nil then shape = "tree" end
            -- nodes added to one of the game's categories start to the right of what it has
            local sideways = shape == "line" or shape == "grid" or (shape == "tree" and chosen.direction ~= "radial")
            if fine and not category.new and category.row and sideways and chosen.from == nil then
                local right = nil
                for _, record in ipairs(world.nodes(category.row)) do
                    if record.Size > 0 and (not right or record.At.X > right) then right = record.At.X end
                end
                -- and of what entries further up put into the same category
                for _, earlier in ipairs(plan.categories) do
                    if earlier == category then break end
                    if not earlier.new and earlier.key == category.key then
                        for _, node in ipairs(earlier.nodes) do
                            if node.at and (not right or node.at.x > right) then right = node.at.x end
                        end
                    end
                end
                local high = (shape == "grid" or chosen.direction == "down") and layout.TOP or layout.MIDDLE
                if right then chosen.from = { right + layout.STEP_X, high } end
            end
            if fine then
                local items = {}
                for at, node in ipairs(loose) do
                    local needs = {}
                    for _, row in ipairs(node.any) do needs[#needs + 1] = fold(row) end
                    for _, row in ipairs(node.all) do needs[#needs + 1] = fold(row) end
                    items[at] = { id = type(shape) == "function" and node.id or node.key, needs = needs }
                end
                local placed, places = pcall(layout.place, shape, items, chosen)
                if placed then
                    for at, node in ipairs(loose) do node.at = places[at] end
                else
                    problems.error("arrange", { category = category.label }, category.label, sentence(clean(places)))
                end
            end
        end
    end

    check.run(plan, world, problems)
    return done()
end

return M
