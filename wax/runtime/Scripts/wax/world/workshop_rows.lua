-- The writing side of game.Workshop: a store's changes as whole fields on game.Data's write path, and the store's screen brought up to date

local Wax = ...
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local co = Wax.import("core.co")
local suggest = Wax.import("core.suggest")
local perf = Wax.import("core.perf")
local log = Wax.import("core.log").channel("wax.workshop")
local workshop = Wax.import("world.workshop")
local spec = Wax.import("world.workshop_spec")
local check = Wax.import("world.workshop_check")
local layout = Wax.import("world.workshop_layout")

local M = {}
local task = sched.task
local store = workshop.store
local T = workshop.TABLES

-- What this version writes for the store. A kind is on once the game has shown that it takes the write.
M.WRITES = {
    places = true,          -- seen in the game, with the node's widget following
    prices = true,          -- seen in the game, with the node's widget following
    parents = true,         -- a list of row handles. Seen in the game: the store's model follows when the frame ends
    lines = true,           -- an enum by its number, which the node's widget copies. Not seen drawn on the store's screen
    levels = true,          -- a whole number. Seen in the game: locked while it is above the player's level
    hide = false,           -- a node off its tree: what a save does with the research of such a node is not known
    categories = false,     -- a new category: its name is text and its picture a reference to an asset, which data.patch does not write yet
}
M.BUDGET = 0.002            -- seconds of a frame for bringing node widgets up to date
M.STACK = 7                 -- EDynamicItemProperties::ItemableStack, how many a template hands over
M.NODE = 0                  -- ETalentNodeType::Talent

-- The fields this file writes, as the game spells them.
local F = { place = "position", size = "Size", parents = "RequiredTalents", flags = "RequiredFlags", line = "DrawMethodOverride",
    level = "RequiredLevel", tree = "TalentTree", sells = "ExtraData", kind = "TalentType", free = "bDefaultUnlocked",
    research = "ResearchCost", replicate = "ReplicationCost", gives = "Item", model = "Model", name = "DisplayName", icon = "Icon",
    background = "BackgroundTexture", category = "Archetype", item = "ItemStaticData", extras = "ItemDynamicData" }

-- How a row a mod added to the store is switched off when the mod unloads, by table: handed to data.patch.
M.OFF = {
    [T.nodes] = { [F.tree] = { RowName = "None" } },
    [T.categories] = { [F.model] = { RowName = "None" } },
    [T.trees] = { [F.category] = { RowName = "None" } },
}

M.TEXT = {
    ["rows"] = "adding rows to the game's tables is not switched on in this version of Wax",
    ["categories"] = "a new category is not switched on in this version of Wax: its name is text and its picture a reference to an asset, "
        .. "and Wax does not write those yet. Nodes can go into one of the game's categories with into = \"Workshop_Axes\"",
    ["places"] = "moving a node of the store is not switched on in this version of Wax",
    ["prices"] = "changing a price of the store is not switched on in this version of Wax",
    ["parents"] = "changing what a node of the store needs is not switched on in this version of Wax",
    ["lines"] = "changing the line style of a node is not switched on in this version of Wax",
    ["levels"] = "changing the level a node asks for is not switched on in this version of Wax",
    ["hide"] = "hiding a node of the store is not switched on in this version of Wax",
    ["all"] = "%s needs all of %s. The game only knows \"one of\", and this version of Wax does not keep the other rule. "
        .. "For one of them, write needs = { %s }",
    ["owner"] = "a change of the store belongs to a mod, which puts it back when it unloads. This code runs outside any mod",
    ["other-mod"] = "the rows of this store are named after %s, and this code runs as %s. A store is added by its own mod's code",
    ["set-shape"] = "Set expects a table of what to change, such as { research = { Credits = 10 } }, got %s",
    ["set-key"] = "Set has no option named '%s'.%s",
    ["set-empty"] = "Set was given nothing to change. It takes research, replicate, needs, at, line and level",
    ["needs-shape"] = "%s: needs is the row name of a node, a list of names of which one is enough, or a table with any, all and level",
    ["needs-key"] = "%s: needs has no option named '%s'.%s",
    ["needs-flags"] = "%s: the flags a node of the game asks for cannot be changed in this version of Wax",
    ["needs-missing"] = "%s needs \"%s\", and the store has no node of that name.%s",
    ["level-twice"] = "%s: level is given twice, as %s and inside needs as %s",
    ["unsold"] = "%s sells nothing, so it has no price to change",
    ["gone"] = "the store has no node named '%s'.%s",
    ["hidden"] = "%s is hidden. Show it before changing it",
    ["no-category"] = "the store has no category named '%s'.%s",
    ["no-tree"] = "the category %s has no row in %s, so no node can go into it",
    ["no-like"] = "the game's store has no node to start a new one from",
    ["flags"] = "%s asks for %s flags. A new node takes its flags from a node of the game, and none of the game's has that many",
    ["refused"] = "%s was not changed: %s",
    ["not-added"] = "the store was not added: %s",
    ["bad-store"] = "this store cannot be put into the game: %s",
    ["more"] = " (and %s more, which game.Workshop:Check lists)",
    ["category-shape"] = "AddCategory expects a table such as { id = \"FieldKit\", name = \"Field Kit\" }, got %s",
    ["category-key"] = "AddCategory has no option named '%s'.%s",
    ["category-twice"] = "this mod already added a category with the id %s",
    ["node-shape"] = "Add expects a node such as { id = \"Rope\", gives = \"Meta_Cot_Printed\" }, got %s",
    ["stale"] = "this category is no longer part of the mod's store. Add it again with AddCategory",
}

local stats = { sets = 0, added = 0, refreshed = 0, missing = 0, forced = 0, passes = 0, failed = 0 }

local function fold(name) return (tostring(name):lower()) end

local function whole(value)
    return type(value) == "number" and math.tointeger(value) or nil
end

local function clean(problem)
    local text = tostring(problem):match("^[^\r\n]*") or ""
    local stripped = 1
    while stripped > 0 do text, stripped = text:gsub("^.-%.lua:%d+: ", "") end
    return text
end

local function sorted_keys(of)
    local keys = {}
    for key in pairs(of) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function joined(names, word)
    if #names <= 1 then return names[1] or "" end
    return table.concat(names, ", ", 1, #names - 1) .. " " .. word .. " " .. names[#names]
end

local function quoted(names)
    local out = {}
    for at, name in ipairs(names) do out[at] = "\"" .. name .. "\"" end
    return table.concat(out, ", ")
end

-- A value as text that is the same for the same value, whatever order its keys were made in.
local function text_of(value)
    if type(value) ~= "table" then return type(value):sub(1, 1) .. tostring(value) end
    local parts = {}
    for at, key in ipairs(sorted_keys(value)) do parts[at] = tostring(key) .. "=" .. text_of(value[key]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function tables_module()
    local ok, tables = pcall(Wax.import, "data.tables")
    if not ok or type(tables) ~= "table" or not tables.api then
        error("the game's tables cannot be reached, so the store cannot be changed", 0)
    end
    return tables
end

local function home(name) return tables_module().api:Table(name) end

-- True when data.patch adds rows in this version.
local function rows_on()
    local writer = tables_module().writer
    return type(writer) == "table" and type(writer.WRITES) == "table" and writer.WRITES.rows == true
end

local function gate(name)
    if not M.WRITES[name] then error(M.TEXT[name], 0) end
end

-- One sentence of the checks, raised as an error.
local function raise(code, where, ...)
    local problems = check.list()
    problems.error(code, where, ...)
    error(problems.sorted()[1].Text, 0)
end

-- Raises the first error of a list of problems. Warnings pass.
local function refuse(found, lead, more)
    local errors = {}
    for _, problem in ipairs(found) do
        if problem.Level == "error" then errors[#errors + 1] = problem end
    end
    if #errors == 0 then return end
    local text = errors[1].Text
    if lead then text = lead:format(text) end
    if #errors > 1 then text = text .. (more or " (and %s more)"):format(#errors - 1) end
    error(text, 0)
end

local function owner_now()
    local owner = scope.current()
    if not owner or not owner.alive then error(M.TEXT.owner, 0) end
    return owner
end

-- What each scope changed through the store, so Reset takes back exactly that. It goes with the scope.
local books = setmetatable({}, { __mode = "k" })

local function book(owner)
    local found = books[owner]
    if not found then
        found = { fields = {}, rows = {}, sent = {}, built = nil }
        books[owner] = found
    end
    return found
end

local function key_of(table_name, row, field) return table_name .. "\0" .. fold(row) .. "\0" .. (field or "") end

-- Writes whole fields, row by row, and takes them back when one is refused. `settled`: no field of these moves a node to another category.
local function write(owner, ops, what, settled)
    local mine, done = book(owner), {}
    local mark = settled and store.mark() or nil
    for _, op in ipairs(ops) do
        done[#done + 1] = op
        local found = home(op.home)
        local ok, problem = pcall(found.Set, found, op.row, op.fields)
        if not ok then
            for at = #done, 1, -1 do
                local undone = done[at]
                local from = home(undone.home)
                for field in pairs(undone.fields) do
                    local before = mine.fields[key_of(undone.home, undone.row, field)]
                    local fine, why
                    if before then
                        fine, why = pcall(from.Set, from, undone.row, field, before.value)
                    else
                        fine, why = pcall(from.Reset, from, undone.row, field)
                    end
                    if not fine then log:warn("%s.%s could not be taken back: %s", undone.row, field, clean(why)) end
                end
            end
            error(M.TEXT.refused:format(what, clean(problem)), 0)
        end
    end
    local nodes, items = {}, {}
    for _, op in ipairs(ops) do
        for field, value in pairs(op.fields) do
            mine.fields[key_of(op.home, op.row, field)] = { home = op.home, row = op.row, field = field, value = value, node = op.node }
        end
        local list = op.home == T.items and items or nodes
        list[#list + 1] = op.row
        stats.sets = stats.sets + 1
    end
    if mark ~= nil then store.wrote(mark, nodes, items) end
end

local function handles(rows)
    local out = {}
    for at, row in ipairs(rows) do out[at] = { RowName = row, DataTableName = "D_" .. T.nodes } end
    return out
end

-- A price as the list its field holds, in the order the game lists its currencies. No price is one entry of nothing, as the game writes it.
local function costs(amounts)
    local out, first = {}, nil
    for _, currency in ipairs(store.names("currency")) do
        first = first or currency
        local amount = amounts[fold(currency)]
        if amount then out[#out + 1] = { Meta = { RowName = currency, DataTableName = "D_" .. T.currencies }, Amount = amount } end
    end
    if #out == 0 and first then out[1] = { Meta = { RowName = first, DataTableName = "D_" .. T.currencies }, Amount = 0 } end
    return out
end

-- A price as a mod writes it, checked: folded currency -> amount.
local function amounts_of(where, id, name, given)
    if type(given) ~= "table" then raise("price-shape", where, id, name) end
    local amounts = {}
    for _, currency in ipairs(sorted_keys(given)) do
        local amount = given[currency]
        local found = type(currency) == "string" and store.has("currency", currency)
        if type(currency) ~= "string" then
            raise("price-shape", where, id, name)
        elseif not found then
            raise("price-currency", where, id, name, currency, store.where("currency"), suggest.phrase(currency, store.names("currency")))
        elseif type(amount) == "number" and amount > spec.MAX_AMOUNT then
            raise("price-large", where, id, name, found, amount, spec.MAX_AMOUNT)
        elseif not whole(amount) then
            raise("price-amount", where, id, name, found, type(amount) == "string" and ("\"" .. amount .. "\"")
                or type(amount) == "number" and amount or ("a " .. type(amount)))
        elseif amount < 0 then
            raise("price-negative", where, id, name, found, amount)
        end
        local sum = (amounts[fold(found)] or 0) + whole(amount)
        if sum > spec.MAX_AMOUNT then raise("price-large", where, id, name, found, sum, spec.MAX_AMOUNT) end
        amounts[fold(found)] = sum
    end
    return amounts
end

local function names_of(value)
    if value == nil then return {} end
    if type(value) == "string" then return { value } end
    if type(value) ~= "table" then return nil end
    for key, name in pairs(value) do
        if math.type(key) ~= "integer" or type(name) ~= "string" then return nil end
    end
    return value
end

local function parents_of(id, names)
    local out, seen = {}, {}
    for _, name in ipairs(names) do
        local found = name ~= "" and store.is_node(name) or nil
        if not found then error(M.TEXT["needs-missing"]:format(id, name, suggest.phrase(name, store.names("node"))), 0) end
        if not seen[fold(found)] then
            seen[fold(found)] = true
            out[#out + 1] = found
        end
    end
    return out
end

local SET_KEYS = { "research", "replicate", "needs", "at", "line", "level" }
local NEEDS_KEYS = { "any", "all", "level" }
local PRICES = { "research", "replicate" }

-- What a Set asks for, checked value by value: { research, replicate, any, at, line, level }.
local function wanted_of(record, options)
    local id = record.Id
    local where = { node = id, category = record.Category }
    if type(options) ~= "table" then error(M.TEXT["set-shape"]:format(type(options)), 0) end
    local keys = sorted_keys(options)
    for _, key in ipairs(keys) do
        local known = false
        for _, name in ipairs(SET_KEYS) do known = known or name == key end
        if not known then
            error(M.TEXT["set-key"]:format(tostring(key), type(key) == "string" and suggest.phrase(key, SET_KEYS) or ""), 0)
        end
    end
    if #keys == 0 then error(M.TEXT["set-empty"], 0) end
    local want = {}
    for _, name in ipairs(PRICES) do
        if options[name] ~= nil then
            gate("prices")
            if record.Joint or not record.StoreItem or not store.has("store_item", record.StoreItem) then
                error(M.TEXT.unsold:format(id), 0)
            end
            want[name] = amounts_of(where, id, name, options[name])
        end
    end
    local level = options.level
    local needs = options.needs
    if needs ~= nil then
        local any, all = nil, {}
        if type(needs) == "string" then
            any = { needs }
        elseif type(needs) == "table" then
            local named = false
            for key in pairs(needs) do named = named or type(key) ~= "number" end
            if not named then
                any = names_of(needs)
            elseif #needs == 0 then
                for _, key in ipairs(sorted_keys(needs)) do
                    local known = false
                    for _, name in ipairs(NEEDS_KEYS) do known = known or name == key end
                    if key == "flags" then error(M.TEXT["needs-flags"]:format(id), 0) end
                    if not known then
                        error(M.TEXT["needs-key"]:format(id, tostring(key), type(key) == "string" and suggest.phrase(key, NEEDS_KEYS) or ""), 0)
                    end
                end
                any, all = names_of(needs.any), names_of(needs.all)
                if needs.level ~= nil then
                    if level ~= nil and level ~= needs.level then
                        error(M.TEXT["level-twice"]:format(id, tostring(level), tostring(needs.level)), 0)
                    end
                    level = needs.level
                end
            end
        end
        if not any or not all then error(M.TEXT["needs-shape"]:format(id), 0) end
        any, all = parents_of(id, any), parents_of(id, all)
        if #all > 0 then error(M.TEXT.all:format(id, joined(all, "and"), quoted(all)), 0) end
        -- a table that only gives a level leaves the parents as they are
        if type(needs) ~= "table" or needs.any ~= nil or #needs > 0 or next(needs) == nil then
            gate("parents")
            want.any = any
        end
    end
    if level ~= nil then
        gate("levels")
        local asked = whole(level)
        if not asked or asked < 0 or asked > spec.MAX_AMOUNT then raise("level", where, id) end
        want.level = asked
    end
    local at = options.at
    if at ~= nil then
        gate("places")
        local x, y = nil, nil
        if type(at) == "table" then x, y = at[1] or at.x or at.X, at[2] or at.y or at.Y end
        if layout.usable(x) and layout.usable(y) then
            want.at = { x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
        elseif type(x) == "number" and type(y) == "number" and x == x and y == y then
            raise("at-far", where, id, x, y, layout.FAR)
        else
            raise("at", where, id)
        end
    end
    if options.line ~= nil then
        gate("lines")
        local known = false
        for _, word in ipairs(spec.LINES) do known = known or options.line == word end
        if not known then raise("line", where, id, type(options.line) == "string" and suggest.phrase(options.line, spec.LINES) or "") end
        want.line = options.line
    end
    return want, where
end

local member_names = {}     -- folded category -> the row names of its nodes, kept until a node changes tree

-- The nodes of a category. Which rows they are is kept: a node another mod moves here through game.Data is seen from the next frame on.
local function members_of(category)
    local key = fold(category)
    local names = member_names[key]
    if not names then
        names = {}
        for at, record in ipairs(store.nodes(category)) do names[at] = record.Id end
        member_names[key] = names
    end
    local out = {}
    for _, name in ipairs(names) do
        local record = store.node(name)
        if record and fold(record.Category) == key then out[#out + 1] = record end
    end
    return out
end

-- The straight lines of a category that run over a node, as warnings. `mine`, when given, names the entries that are asked about.
local function crossings(problems, category, list, lines, mine)
    for _, crossing in ipairs(layout.crossings(list, lines)) do
        if not mine or mine[crossing.from] or mine[crossing.to] or mine[crossing.over] then
            problems.warn("line-through", { node = crossing.to.id, category = category }, crossing.from.id, crossing.to.id, crossing.over.id)
        end
    end
end

-- What would be wrong with the store once a node is as `want` says: errors for what could never be bought, warnings for the rest.
local function look(record, want, where, problems)
    local id, own_key = record.Id, fold(record.Id)
    if want.any then
        local node = { id = id, key = own_key, any = want.any, all = {}, free = record.Free and (not record.Joint or #want.any == 0),
            category = { key = fold(record.Category), label = record.Category }, research = {}, replicate = {} }
        check.run({ nodes = { node }, categories = {} }, store, problems)
    end
    for _, name in ipairs(PRICES) do
        local count = 0
        for _ in pairs(want[name] or {}) do count = count + 1 end
        if count > 2 then problems.warn("price-many", where, id, name, count) end
    end
    if not (want.at or want.any or want.line) then return end
    local list, by, mine, lines = {}, {}, {}, {}
    local members = members_of(record.Category)
    for _, other in ipairs(members) do
        local entry = { id = other.Id, x = other.At.X, y = other.At.Y, size = other.Size }
        if fold(other.Id) == own_key then
            if want.at then entry.x, entry.y = want.at.x, want.at.y end
            mine[entry] = true
        end
        list[#list + 1] = entry
        by[fold(other.Id)] = entry
    end
    if want.at then check.placed(problems, list, record.Category, mine) end
    for _, other in ipairs(members) do
        local own = fold(other.Id) == own_key
        local line = own and want.line or other.Line
        if line == "straight" then
            for _, parent in ipairs(own and want.any or other.Needs) do
                local from = by[fold(parent)]
                if from then lines[#lines + 1] = { from = from, to = by[fold(other.Id)] } end
            end
        end
    end
    crossings(problems, record.Category, list, lines, mine)
end

-- The row of a node as the game spells it. A node this mod hid is still found.
function M.node(id)
    local row = store.is_node(id)
    if row then return row end
    local owner = scope.current()
    local mine = owner and books[owner]
    local hidden = mine and mine.fields[key_of(T.nodes, id, F.tree)]
    if hidden then return hidden.row end
    error(M.TEXT.gone:format(id, suggest.phrase(id, store.names("node"))), 0)
end

local function record_of(owner, row)
    local record = store.node(row)
    if record then return record end
    local mine = books[owner]
    if mine and mine.fields[key_of(T.nodes, row, F.tree)] then error(M.TEXT.hidden:format(row), 0) end
    error(M.TEXT.gone:format(row, suggest.phrase(row, store.names("node"))), 0)
end

-- Changes one node of the store. Everything is checked before anything is written. Returns what Check would warn about.
function M.set(row, options)
    local owner = owner_now()
    local record = record_of(owner, row)
    local want, where = wanted_of(record, options)
    local problems = check.list()
    look(record, want, where, problems)
    local found = problems.sorted()
    refuse(found)
    local ops, fields = {}, {}
    if want.at then fields[F.place] = { X = want.at.x, Y = want.at.y } end
    if want.any then fields[F.parents] = handles(want.any) end
    if want.line then fields[F.line] = workshop.line_number(want.line) end
    if want.level then fields[F.level] = want.level end
    if next(fields) ~= nil then ops[#ops + 1] = { home = T.nodes, row = record.Id, fields = fields, node = record.Id } end
    local price = {}
    if want.research then price[F.research] = costs(want.research) end
    if want.replicate then price[F.replicate] = costs(want.replicate) end
    if next(price) ~= nil then
        ops[#ops + 1] = { home = T.items, row = store.has("store_item", record.StoreItem), fields = price, node = record.Id }
    end
    write(owner, ops, record.Id, true)
    return found
end

-- Takes a node off its tree, so a store built after this does not show it.
function M.hide(row)
    local owner = owner_now()
    gate("hide")
    local mine = book(owner)
    if mine.fields[key_of(T.nodes, row, F.tree)] then return end
    local record = record_of(owner, row)
    write(owner, { { home = T.nodes, row = record.Id, fields = { [F.tree] = { RowName = "None" } }, node = record.Id } }, record.Id)
    member_names = {}
end

-- Puts a node this mod hid back on its tree. True when it was hidden.
function M.show(row)
    local owner = owner_now()
    gate("hide")
    local mine = books[owner]
    local id = key_of(T.nodes, row, F.tree)
    local hidden = mine and mine.fields[id]
    if not hidden then return false end
    local found = home(T.nodes)
    local ok, problem = pcall(found.Reset, found, hidden.row, F.tree)
    if not ok then error(M.TEXT.refused:format(hidden.row, clean(problem)), 0) end
    mine.fields[id] = nil
    member_names = {}
    return true
end

-- Takes back what a scope changed through the store, of one node or of everything. Returns how many changes went.
local function take_back(owner, node)
    local mine = books[owner]
    if not mine then return 0 end
    local count, problem = 0, nil
    -- which node is in which category stays as read, unless a hidden node or a row of the mod goes back
    local settled = node ~= nil or next(mine.rows) == nil
    for _, entry in pairs(mine.fields) do
        if entry.field == F.tree and (not node or (entry.node and fold(entry.node) == node)) then settled = false end
    end
    local mark = settled and store.mark() or nil
    local nodes, items = {}, {}
    for id, entry in pairs(mine.fields) do
        if not node or (entry.node and fold(entry.node) == node) then
            local found = home(entry.home)
            local ok, result = pcall(found.Reset, found, entry.row, entry.field)
            if ok then
                count = count + (tonumber(result) or 0)
                mine.fields[id] = nil
                local list = entry.home == T.items and items or nodes
                list[#list + 1] = entry.row
            else
                problem = problem or result
            end
        end
    end
    if not node then
        for id, entry in pairs(mine.rows) do
            local found = home(entry.home)
            local ok, result = pcall(found.Reset, found, entry.row)
            if ok then
                count = count + (tonumber(result) or 0)
                mine.rows[id] = nil
            else
                problem = problem or result
            end
        end
        mine.sent, mine.built = {}, nil
    end
    member_names = {}
    if mark ~= nil then store.wrote(mark, nodes, items) end
    if problem then error(clean(problem), 0) end
    return count
end

function M.reset_node(row) return take_back(owner_now(), fold(row)) end

function M.reset() return take_back(owner_now(), nil) end

-- The row of a category as the game spells it.
function M.category(id)
    local found = store.category(id)
    if not found then error(M.TEXT["no-category"]:format(id, suggest.phrase(id, store.names("category"))), 0) end
    return found.Id
end

-- Gives every node of a category a place in a shape and writes the places that differ. Returns what Check would warn about.
local function arrange(owner, category, shape, options)
    gate("places")
    local records = members_of(category)
    local inside, items = {}, {}
    for _, record in ipairs(records) do inside[fold(record.Id)] = true end
    for at, record in ipairs(records) do
        local needs = {}
        for _, parent in ipairs(record.Needs) do
            if inside[fold(parent)] then needs[#needs + 1] = fold(parent) end
        end
        items[at] = { id = type(shape) == "function" and record.Id or fold(record.Id), needs = needs }
    end
    local placed, places = pcall(layout.place, shape, items, options)
    if not placed then error(clean(places), 0) end
    local problems, list, by, lines, ops = check.list(), {}, {}, {}, {}
    for at, record in ipairs(records) do
        local entry = { id = record.Id, x = places[at].x, y = places[at].y, size = record.Size }
        list[at], by[fold(record.Id)] = entry, entry
        if entry.x ~= record.At.X or entry.y ~= record.At.Y then
            ops[#ops + 1] = { home = T.nodes, row = record.Id, fields = { [F.place] = { X = entry.x, Y = entry.y } }, node = record.Id }
        end
    end
    check.placed(problems, list, category, nil)
    for _, record in ipairs(records) do
        if record.Line == "straight" then
            for _, parent in ipairs(record.Needs) do
                local from = by[fold(parent)]
                if from then lines[#lines + 1] = { from = from, to = by[fold(record.Id)] } end
            end
        end
    end
    crossings(problems, category, list, lines, nil)
    write(owner, ops, category, true)
    return problems.sorted()
end

-- A reader that does not count the rows this scope added itself, so a store can be described again while its rows are there.
local function without(owner)
    local added, any = {}, false
    for _, name in ipairs({ T.categories, T.trees, T.nodes, T.items, T.templates }) do
        for _, change in ipairs(home(name):Changes()) do
            if change.Added and change.By == owner.name then
                added[name] = added[name] or {}
                added[name][fold(change.Row)] = true
                any = true
            end
        end
    end
    if not any then return store end
    local homes = { category = T.categories, tree = T.trees, talent = T.nodes, node = T.nodes, store_item = T.items, template = T.templates }
    local own_nodes = added[T.nodes] or {}
    return setmetatable({
        has = function(kind, name)
            local mine = added[homes[kind] or ""]
            if mine and type(name) == "string" and mine[fold(name)] then return nil end
            return store.has(kind, name)
        end,
        nodes = function(category)
            local out = {}
            for _, record in ipairs(store.nodes(category)) do
                if not own_nodes[fold(record.Id)] then out[#out + 1] = record end
            end
            return out
        end,
    }, { __index = store })
end

local function flag_number(kind)
    for number_of, word in pairs(workshop.FLAG_KINDS) do
        if word == kind then return number_of end
    end
    return 0
end

local function price_fields(list)
    local amounts = {}
    for _, cost in ipairs(list or {}) do amounts[fold(cost.currency)] = cost.amount end
    return costs(amounts)
end

-- A checked plan as rows in the order they are added: { home, row, like (the row it starts as a copy of), fields, later (fields that name rows added after it) }.
function M.rows_of(plan, world)
    world = world or store
    local out = {}
    local function add(table_name, row, like, fields, later)
        out[#out + 1] = { home = table_name, row = row, like = like, fields = fields, later = later, key = key_of(table_name, row) }
    end
    local first = world.categories()[1]
    for _, category in ipairs(plan.categories) do
        if category.new then
            if not first or not first.Tree then error(M.TEXT["no-like"], 0) end
            local fields = { [F.model] = { RowName = workshop.MODEL }, [F.name] = category.name, [F.level] = category.level or 0 }
            if category.icon then fields[F.icon] = category.icon end
            if category.background then fields[F.background] = category.background end
            add(T.categories, category.row, first.Id, fields)
            local tree = { [F.category] = { RowName = category.row } }
            if category.background then tree[F.background] = category.background end
            add(T.trees, category.tree, first.Tree, tree)
        end
    end
    -- a list of flags keeps its length, so a new node starts from a node of the game with as many flags as it asks for
    local likes = nil
    local function like_for(count)
        if not likes then
            likes = {}
            for _, record in ipairs(world.nodes()) do
                if not record.Joint and not likes[#record.Flags] and record.StoreItem and record.Gives
                    and world.has("store_item", record.StoreItem) and world.has("template", record.Gives) then
                    likes[#record.Flags] = record
                end
            end
        end
        return likes[count]
    end
    for _, node in ipairs(plan.nodes) do
        local like = like_for(#node.flags)
        if not like then
            if not like_for(0) then error(M.TEXT["no-like"], 0) end
            error(M.TEXT.flags:format(node.id, #node.flags), 0)
        end
        if not node.category.tree then error(M.TEXT["no-tree"]:format(node.category.label, "D_" .. T.trees), 0) end
        local gives = node.gives
        if gives.new then
            add(T.templates, gives.template, like.Gives, { [F.item] = { RowName = gives.item },
                [F.extras] = gives.count > 1 and { { PropertyType = M.STACK, Value = gives.count } } or {} })
        end
        add(T.items, node.store_item, world.has("store_item", like.StoreItem), { [F.gives] = { RowName = gives.template },
            [F.research] = price_fields(node.research), [F.replicate] = price_fields(node.replicate) })
        local fields = { [F.kind] = M.NODE, [F.sells] = { RowName = node.store_item, DataTableName = "D_" .. T.items },
            [F.tree] = { RowName = node.category.tree }, [F.place] = { X = node.at.x, Y = node.at.y },
            [F.size] = { X = node.size, Y = node.size }, [F.parents] = {}, [F.level] = node.level, [F.free] = node.free == true,
            [F.line] = workshop.line_number(node.line) }
        if #node.flags > 0 then
            local flags = {}
            for at, flag in ipairs(node.flags) do flags[at] = { RowName = flag.row, DataTableName = flag_number(flag.kind) } end
            fields[F.flags] = flags
        end
        add(T.nodes, node.row, like.Id, fields, #node.any > 0 and { [F.parents] = handles(node.any) } or nil)
    end
    return out
end

local function register_off()
    local writer = tables_module().writer
    if type(writer) ~= "table" or type(writer.OFF) ~= "table" then return false end
    for name, fields in pairs(M.OFF) do
        if writer.OFF[fold(name)] == nil then writer.OFF[fold(name)] = fields end
    end
    return true
end

-- Adds a plan's rows and writes their fields. A row whose fields are as this scope last sent them is left alone.
local function apply(owner, plan, world)
    register_off()
    local mine = book(owner)
    local ops, fresh, changed = M.rows_of(plan, world), {}, {}
    member_names = {}
    local ok, problem = pcall(function()
        for _, op in ipairs(ops) do
            op.sent = text_of({ op.like, op.fields, op.later or false })
            if mine.sent[op.key] ~= op.sent then
                local found = home(op.home)
                local had = found:Has(op.row)
                found:Add(op.row, op.fields, { like = op.like })
                if not had then fresh[#fresh + 1] = op end
                mine.rows[op.key] = { home = op.home, row = op.row }
                changed[#changed + 1] = op
                stats.added = stats.added + 1
            end
        end
        for _, op in ipairs(changed) do
            if op.later then home(op.home):Set(op.row, op.later) end
        end
    end)
    if not ok then
        for at = #fresh, 1, -1 do
            local op = fresh[at]
            local found = home(op.home)
            local fine, why = pcall(found.Reset, found, op.row)
            if not fine then log:warn("%s could not be switched off again: %s", op.row, clean(why)) end
            mine.rows[op.key], mine.sent[op.key] = nil, nil
        end
        error(M.TEXT["not-added"]:format(clean(problem)), 0)
    end
    for _, op in ipairs(changed) do mine.sent[op.key] = op.sent end
end

-- Checks a described store and puts it into the game. Returns what Check would warn about.
local function put(owner, described)
    local world = without(owner)
    local plan = workshop.plan(described, nil, world)
    -- rows are named after a mod, and game.Data only lets the code of that mod add them
    if plan.mod and fold((owner.name:gsub("[^%w_]", "_"))) ~= fold(plan.mod) then
        error(M.TEXT["other-mod"]:format(plan.mod, tostring(owner.name)), 0)
    end
    refuse(plan.problems, M.TEXT["bad-store"], M.TEXT.more)
    local fresh = false
    for _, category in ipairs(plan.categories) do fresh = fresh or category.new == true end
    for _, node in ipairs(plan.nodes) do
        if #node.all > 0 then error(M.TEXT.all:format(node.id, joined(node.all, "and"), quoted(node.all)), 0) end
    end
    if fresh and not M.WRITES.categories then error(M.TEXT.categories, 0) end
    if not rows_on() then error(M.TEXT.rows, 0) end
    apply(owner, plan, world)
    return plan.problems
end

function M.define(described)
    return put(owner_now(), described)
end

local CATEGORY_KEYS = { "id", "name", "icon", "background", "level", "arrange" }

-- A new category for the calling mod's store. It goes into the game with its first node. Returns what it is kept as, and its row.
function M.add_category(options)
    local owner = owner_now()
    if type(options) ~= "table" then error(M.TEXT["category-shape"]:format(type(options)), 0) end
    local entry = { nodes = {} }
    for _, key in ipairs(sorted_keys(options)) do
        local known = false
        for _, name in ipairs(CATEGORY_KEYS) do known = known or name == key end
        if not known then
            error(M.TEXT["category-key"]:format(tostring(key), type(key) == "string" and suggest.phrase(key, CATEGORY_KEYS) or ""), 0)
        end
        entry[key] = options[key]
    end
    if not M.WRITES.categories then error(M.TEXT.categories, 0) end
    if not rows_on() then error(M.TEXT.rows, 0) end
    local mine = book(owner)
    local built = mine.built or { categories = {} }
    for _, other in ipairs(built.categories) do
        if other.id ~= nil and fold(other.id) == fold(entry.id) then error(M.TEXT["category-twice"]:format(tostring(entry.id)), 0) end
    end
    -- checked by itself: a category that has no node yet is no mistake here
    local plan = workshop.plan({ categories = { entry } }, nil, without(owner))
    local errors = {}
    for _, problem in ipairs(plan.problems) do
        if problem.Level == "error" and problem.Code ~= "category-empty" then errors[#errors + 1] = problem end
    end
    refuse(errors)
    mine.built = built
    built.categories[#built.categories + 1] = entry
    return entry, plan.categories[1].row
end

local function entry_of(mine, token)
    local built = mine.built
    if type(token) == "string" then
        for _, entry in ipairs(built and built.categories or {}) do
            if entry.into ~= nil and fold(entry.into) == fold(token) then return entry, false end
        end
        return { into = token, nodes = {} }, true
    end
    for _, entry in ipairs(built and built.categories or {}) do
        if entry == token then return entry, false end
    end
    error(M.TEXT.stale, 0)
end

-- Adds a node to a category: one of the game's by its row, or one this mod added. Returns what Check would warn about.
function M.add_node(token, node)
    local owner = owner_now()
    if type(node) ~= "table" then error(M.TEXT["node-shape"]:format(type(node)), 0) end
    if not rows_on() then error(M.TEXT.rows, 0) end
    local mine = book(owner)
    local entry, made = entry_of(mine, token)
    mine.built = mine.built or { categories = {} }
    local list = mine.built.categories
    if made then list[#list + 1] = entry end
    entry.nodes[#entry.nodes + 1] = node
    local ok, result = pcall(put, owner, mine.built)
    if not ok then
        entry.nodes[#entry.nodes] = nil
        if made then list[#list] = nil end
        error(result, 0)
    end
    return result
end

-- Lays a category out in a shape: every node of one the game has, or the nodes without a place of one this mod is adding.
function M.arrange(token, shape, options)
    local owner = owner_now()
    if type(token) == "string" then return arrange(owner, token, shape, options) end
    if options ~= nil and type(options) ~= "table" then error("the options of a shape are a table, got " .. type(options), 0) end
    local mine = book(owner)
    local entry = entry_of(mine, token)
    local before = entry.arrange
    local chosen = { shape = shape }
    for key, value in pairs(options or {}) do
        if key ~= "shape" then chosen[key] = value end
    end
    entry.arrange = chosen
    if #entry.nodes == 0 then return {} end
    local ok, result = pcall(put, owner, mine.built)
    if not ok then
        entry.arrange = before
        error(result, 0)
    end
    return result
end

-- The store's screen. Each player state has its own, made anew at every change of map, so nothing of it is kept.

local wanted = { nodes = {}, items = {}, force = false }
local runner, reader, generation = nil, nil, 0
local graph_of = {}         -- folded category -> where its graph sits on the store's screen, as last found
local sells, sells_all = {}, false      -- folded store item -> { folded node row -> row }, once the whole store was read for it
local read_at, clock = {}, 0            -- folded node row -> when its widget last read its rows, on a count of writes and reads
local warned = false

local function tick()
    clock = clock + 1
    return clock
end

local function valid(object) return object ~= nil and object:IsValid() end

-- The player's store controller and its screen, read from the player each time.
local function screen()
    local game = Wax.game
    local player = game and game.LocalPlayer
    local raw = player and player.Raw
    if not raw then return nil end
    local state = raw.PlayerState
    if not valid(state) then return nil end
    local component = state.WorkshopTalentController
    if not valid(component) then return nil end
    local view = component.View
    return component, valid(view) and view or nil
end

-- Makes the waiting nodes of one graph read their rows again. False when the frame's share ran out before its end.
local function visit(pass, graph, at, started)
    if not valid(graph) then return true end
    local trees = graph.TalentTreeWidgets
    local count = trees:GetArrayNum()
    for index = 1, type(count) == "number" and count or 0 do
        local tree = trees[index]
        local canvas = valid(tree) and tree.Canvas or nil
        if valid(canvas) then
            for child = 0, canvas:GetChildrenCount() - 1 do
                local widget = canvas:GetChildAt(child)
                if valid(widget) then
                    local name = fold(widget.Talent.RowName:ToString())
                    local node = pass.nodes[name]
                    if node then
                        -- the row and the store item are copied into the node again, then its place and state follow
                        widget:OnTalentSet()
                        widget:RefreshState()
                        pass.nodes[name] = nil
                        pass.left = pass.left - 1
                        read_at[name] = tick()
                        stats.refreshed = stats.refreshed + 1
                        graph_of[node.category] = at
                        if pass.left == 0 then return true end
                        if perf.now() - started >= M.BUDGET then return false end
                    end
                end
            end
        end
    end
    return true
end

-- The next graph to look through: where a waiting node's category was last found or should be, then every other one.
local function next_graph(pass, graphs)
    for _, node in pairs(pass.nodes) do
        local guess = node.graph
        if guess and guess < graphs and not pass.seen[guess] then return guess end
    end
    for at = 0, graphs - 1 do
        if not pass.seen[at] then return at end
    end
    return nil
end

-- One frame's share of a pass. True when the pass is over.
local function step(pass)
    local component, view = screen()
    -- with no store there is nothing to bring up to date: the next one is built from the rows as they are
    if not component then return true end
    if pass.force then
        pass.force = false
        component:BP_ForceRefresh()
        stats.forced = stats.forced + 1
    end
    if pass.left == 0 then return true end
    if not view then return true end
    local switcher = view.GraphWidgetSwitcher
    local graphs = switcher:GetChildrenCount()
    local started = perf.now()
    while pass.left > 0 do
        local at = next_graph(pass, graphs)
        if at == nil then break end
        if not visit(pass, switcher:GetChildAt(at), at, started) then return false end
        pass.seen[at] = true
        if pass.left > 0 and perf.now() - started >= M.BUDGET then return false end
    end
    -- a node without a widget was added after this screen was built
    stats.missing = stats.missing + pass.left
    return true
end

-- Which nodes sell the store items that changed. The whole store is read for it once, a slice a frame.
local function resolve()
    if not sells_all then
        store.load()
        local found = {}
        for _, record in ipairs(store.nodes()) do
            if record.StoreItem then
                local key = fold(record.StoreItem)
                found[key] = found[key] or {}
                found[key][fold(record.Id)] = record.Id
            end
        end
        sells, sells_all = found, true
    end
    local items = wanted.items
    wanted.items = {}
    for item, changed in pairs(items) do
        for key, row in pairs(sells[item] or {}) do
            -- a node that read its rows after this change has the new price already
            if not (read_at[key] and read_at[key] > changed) then wanted.nodes[key] = row end
        end
    end
end

-- The nodes that wait, as one pass over the store's screen.
local function take()
    local waiting = wanted
    wanted = { nodes = {}, items = waiting.items, force = false }
    local pass = { nodes = {}, left = 0, seen = {}, force = waiting.force }
    local places = nil
    for key, row in pairs(waiting.nodes) do
        local record = store.node(row)
        if record then
            if not places then
                places = {}
                for at, category in ipairs(store.categories()) do places[fold(category.Id)] = at - 1 end
            end
            local category = fold(record.Category)
            pass.nodes[key] = { category = category, graph = graph_of[category] or places[category] }
            pass.left = pass.left + 1
            pass.force = true
        end
    end
    return pass
end

-- The next pass, or nothing when no node waits.
local function next_pass()
    if next(wanted.nodes) == nil and not wanted.force then return nil end
    -- with no store there is nothing to bring up to date: the next one is built from the rows as they are
    if not screen() then
        wanted.nodes, wanted.force = {}, false
        return nil
    end
    return take()
end

local function failed(problem)
    stats.failed = stats.failed + 1
    if not warned then
        warned = true
        log:warn("bringing the store's screen up to date failed: %s", clean(problem))
    end
end

-- Brings the waiting nodes up to date, a frame's share at a time, until none waits.
local function run()
    local mine, pass = generation, nil
    while mine == generation do
        if not pass then
            local ok, made = pcall(next_pass)
            if not ok then
                failed(made)
                wanted.nodes, wanted.force = {}, false
                break
            end
            if not made then break end
            pass = made
            stats.passes = stats.passes + 1
        end
        local ok, done = pcall(step, pass)
        if not ok then failed(done) end
        if done or not ok then pass = nil else task.wait() end
    end
    if mine == generation then runner = nil end
end

local function alive(thread) return thread ~= nil and co.status(thread) ~= "dead" end

local kick

-- Finds the nodes of the store items that changed and lets them wait with the rest. It never holds a node's own change up.
local function read()
    local mine = generation
    while mine == generation and next(wanted.items) ~= nil do
        if not screen() then
            wanted.items = {}
            break
        end
        local ok, problem = pcall(resolve)
        if mine ~= generation then break end
        if not ok then
            failed(problem)
            wanted.items = {}
            break
        end
        kick()
    end
    if mine == generation then reader = nil end
end

function kick()
    local previous = scope.enter(nil)
    if not alive(runner) and (next(wanted.nodes) ~= nil or wanted.force) then runner = task.defer(run) end
    if not alive(reader) and next(wanted.items) ~= nil then reader = task.defer(read) end
    scope.leave(previous)
end

local folded = { nodes = fold(T.nodes), items = fold(T.items), categories = fold(T.categories), trees = fold(T.trees) }
local told = {}             -- folded table -> true once a change of it was told field by field, until Changed names the table

-- A field of a row was written, by anyone: the node it belongs to reads its rows again when the frame ends.
local function on_patched(name, row, field)
    local key = fold(name)
    if key == folded.nodes then
        told[key] = true
        if field == nil or field == F.sells then sells, sells_all = {}, false end
        if field == nil or field == F.tree then member_names = {} end
        wanted.nodes[fold(row)] = row
    elseif key == folded.items then
        wanted.items[fold(row)] = tick()
    elseif key == folded.categories or key == folded.trees then
        told[key] = true
        member_names = {}
        wanted.force = true
    else
        return
    end
    kick()
end

-- A table was read again and no field was named: the game made it again, or everything read was dropped.
local function on_changed(name)
    if name ~= nil then
        local key = fold(name):gsub("^d_", "")
        if key ~= folded.nodes and key ~= folded.trees and key ~= folded.categories then return end
        if told[key] then
            told[key] = nil
            return
        end
    end
    member_names, sells, sells_all = {}, {}, false
end

local function on_map()
    generation = generation + 1
    wanted = { nodes = {}, items = {}, force = false }
    graph_of, read_at = {}, {}
    runner, reader = nil, nil
end

function M.start()
    local tables = tables_module()
    local game = Wax.import("engine.game").root
    local old = rawget(Wax, "workshop_rows_live")
    if old then
        for _, connection in pairs(old) do connection:Disconnect() end
    end
    local live = {}
    rawset(Wax, "workshop_rows_live", live)
    local previous = scope.enter(nil)
    live.patched = tables.api.Patched:Connect(on_patched)
    live.changed = tables.api.Changed:Connect(on_changed)
    live.map = game.MapChanged:Connect(on_map)
    scope.leave(previous)
    if not register_off() then log:warn("game.Data cannot change tables, so the store cannot be changed") end
    workshop.writing(M)
end

function M.stats()
    local out = {}
    for name, value in pairs(stats) do out[name] = value end
    out.waiting = 0
    for _ in pairs(wanted.nodes) do out.waiting = out.waiting + 1 end
    for _ in pairs(wanted.items) do out.waiting = out.waiting + 1 end
    out.categories_kept = 0
    for _ in pairs(member_names) do out.categories_kept = out.categories_kept + 1 end
    return out
end

return M
