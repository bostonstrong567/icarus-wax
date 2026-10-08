-- What is wrong with a store, as sentences a mod author can act on. Every such sentence is in TEXT

local Wax = ...
local graph = Wax.import("world.workshop_graph")
local layout = Wax.import("world.workshop_layout")

local M = {}

M.LARGE = 150       -- a store that adds this many nodes is told what that costs

M.TEXT = {
    ["spec"] = "A store is a table with a list named categories.",
    ["key"] = "%s has no option named '%s'.%s",
    ["mod"] = "The store does not say which mod it belongs to. Add mod = \"MyMod\": every row it adds is named after its mod.",
    ["mod-bad"] = "The mod id '%s' has to start with a letter and use only letters, digits and _.",
    ["mod-folder"] = "This mod's folder is named '%s'. A mod that adds to the store needs a folder name that starts with a letter and uses only letters, digits and _, because its rows are named after the folder and research is saved under those names. Rename the folder.",
    ["categories"] = "The store has no categories. Add at least one to categories.",
    ["category-shape"] = "Category %s is not a table.",
    ["category-kind"] = "Category %s needs either id and name, to add a category, or into, to add nodes to one of the game's. It cannot have both.",
    ["category-name"] = "Category %s needs a name to show, such as name = \"Field Kit\".",
    ["category-fixed"] = "Category %s is one of the game's, so it keeps its own %s. Take %s out.",
    ["category-missing"] = "The game's store has no category named '%s'.%s",
    ["category-empty"] = "Category %s has no nodes, so it would show nothing.",
    ["category-twice"] = "Two categories have the id %s. Every id is used once in a mod, whatever the letter case.",
    ["level"] = "%s: level is a whole number of 0 or more.",
    ["texture"] = "%s: %s is the path of a texture, such as \"/Game/Assets/2DArt/UI/Icons/Icon_Hammer.Icon_Hammer\".",
    ["node-shape"] = "Node %s of category %s is not a table.",
    ["id"] = "Node %s of category %s needs an id, such as id = \"Rope\".",
    ["id-bad"] = "The id '%s' can only use letters, digits and _.",
    ["id-twice"] = "Two nodes have the id %s. Every id is used once in a mod, whatever the letter case.",
    ["id-taken"] = "%s would be the row %s, and %s already has a row of that name. Choose another id.",
    ["row-long"] = "%s would be the row %s, which is %s characters long. A row name has at most %s. Choose a shorter id.",
    ["gives"] = "%s sells nothing. Say what it gives: gives = \"a row of %s\", or gives = { item = \"a row of %s\", count = 10 }.",
    ["gives-template"] = "%s gives \"%s\", but %s has no row of that name.%s",
    ["gives-is-item"] = "%s gives \"%s\", which is a row of %s, not of %s. Write gives = { item = \"%s\" }.",
    ["gives-item"] = "%s gives the item \"%s\", but %s has no row of that name.%s",
    ["gives-is-template"] = "%s gives the item \"%s\", which is a row of %s, not of %s. Write gives = \"%s\".",
    ["count"] = "%s: count is how many are handed over, a whole number of 1 or more.",
    ["price-shape"] = "%s: %s is a price such as { Credits = 50 }: a currency and how many.",
    ["price-amount"] = "%s: the %s price in %s is %s. A price is a whole number, such as 50.",
    ["price-large"] = "%s: the %s price in %s is %s. The largest price the game can keep is %s.",
    ["price-negative"] = "%s: the %s price in %s is %s. A price cannot be below 0.",
    ["price-currency"] = "%s: the %s price names the currency \"%s\", and %s has no row of that name.%s",
    ["price-many"] = "%s: the %s price uses %s currencies. Every price of the game's own store uses one or two.",
    ["needs-shape"] = "%s: needs is the id of a node, a list of ids of which one is enough, or a table with any, all, level and flags.",
    ["needs-missing"] = "%s needs \"%s\", which is neither a node of this store nor one of the game's store.%s",
    ["needs-foreign"] = "%s needs \"%s\", which is a row of %s but not a node of the store. The store could never count it as bought.",
    ["needs-itself"] = "%s needs itself, so it can never be bought.",
    ["flag"] = "%s asks for the flag \"%s\", and %s has no row of that name.%s",
    ["at"] = "%s: at is the middle of the node, such as at = { 500, 850 }.",
    ["at-far"] = "%s: at is %s, %s. No place in the store is further than %s from 0, 0.",
    ["line"] = "%s: line is \"elbow\", \"elbow-down\", \"straight\" or \"none\".%s",
    ["free"] = "%s: free is true or false.",
    ["arrange"] = "Category %s: %s",
    ["circle"] = "These nodes wait for each other, so none of them can ever be bought: %s.",
    ["unreachable"] = "%s can never be bought, because it needs %s, which can never be bought.",
    ["cross-category"] = "%s needs %s, which is in another category (%s). The game draws no line between categories, and nothing in its own store does this.",
    ["all-of"] = "%s needs all of %s. The game itself only knows \"one of\", so this rule holds only while Wax keeps it, and a pak made from this store does not have it.",
    ["overlap"] = "%s and %s lie on top of each other, at %s and at %s. A node is %s wide and high.",
    ["close"] = "%s and %s are %s apart. In the game's own store the middles of two nodes are never closer than %s.",
    ["off-screen"] = "%s is at height %s. Heights from %s to %s are known to fit a 1080p screen, and the store pans sideways only.",
    ["off-canvas"] = "%s is at %s, so part of it lies outside the store's canvas, which begins at 0, 0.",
    ["far"] = "%s is at %s. No place in the store is further than %s from 0, 0, so it was compared with nothing.",
    ["line-through"] = "The straight line from %s to %s runs through %s.",
    ["dlc"] = "%s sells what the game only sells to owners of %s. The same rule is put on %s, and it cannot be taken off.",
    ["stack"] = "%s gives %s of %s, and one stack of it holds %s.",
    ["large"] = "This store adds %s nodes. The game makes a widget for every node at each change of map, so a very large store slows loading.",
    ["game-item"] = "%s names the store item \"%s\", and %s has no row of that name.",
    ["game-template"] = "%s sells the store item %s, which gives \"%s\", and %s has no row of that name.",
    ["game-unsold"] = "The store item %s gives \"%s\", and %s has no row of that name. No node sells it.",
    ["game-parent"] = "%s needs \"%s\", and the game has no node of that name.",
}

local function fold(name) return (tostring(name):lower()) end

-- A number as a mod author would write it: 850, not 850.0.
local function plain(value)
    if type(value) == "number" then return layout.written(value) end
    return tostring(value)
end

local function spot(node) return plain(node.x) .. ", " .. plain(node.y) end

-- A list problems are added to. `where` is { node = id, category = id } or nothing.
function M.list()
    local errors, warnings = {}, {}
    local function add(into, level, code, where, ...)
        local text = M.TEXT[code]
        if not text then error("there is no text for the problem " .. tostring(code), 3) end
        local values = table.pack(...)
        for at = 1, values.n do values[at] = plain(values[at]) end
        into[#into + 1] = { Level = level, Code = code, Node = where and where.node or nil, Category = where and where.category or nil,
            Text = values.n > 0 and text:format(table.unpack(values, 1, values.n)) or text }
    end
    local list = {}
    function list.error(code, where, ...) add(errors, "error", code, where, ...) end
    function list.warn(code, where, ...) add(warnings, "warning", code, where, ...) end
    function list.count() return #errors, #warnings end
    -- errors first, each kind in the order it was found
    function list.sorted()
        local out = table.move(errors, 1, #errors, 1, {})
        return table.move(warnings, 1, #warnings, #out + 1, out)
    end
    return list
end

local function joined(names)
    if #names <= 1 then return names[1] or "" end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

-- What the layout of one category's nodes says, for those of `mine` (or all of them when `mine` is nothing).
function M.placed(problems, list, category, mine)
    for _, found in ipairs(layout.report(list)) do
        local a, b = found.a, found.b
        if not mine or mine[a] or (b and mine[b]) then
            local where = { node = (not mine or mine[a]) and a.id or b.id, category = category }
            if found.kind == "overlap" then
                problems.warn("overlap", where, a.id, b.id, spot(a), spot(b), layout.SIZE)
            elseif found.kind == "close" then
                problems.warn("close", where, a.id, b.id, found.distance, layout.GAP)
            elseif found.kind == "off-screen" then
                problems.warn("off-screen", where, a.id, a.y, layout.TOP, layout.BOTTOM)
            elseif found.kind == "far" then
                problems.warn("far", where, a.id, spot(a), layout.FAR)
            else
                problems.warn("off-canvas", where, a.id, spot(a))
            end
        end
    end
end

-- The graph's findings as problems. `nodes[key].shown` is the name to print, `nodes[key].own` marks what is asked about.
local function wired(problems, nodes, order, everything)
    local found = graph.analyse(nodes, order)
    local function shown(key) return nodes[key] and nodes[key].shown or key end
    local function where(key) return { node = shown(key), category = nodes[key].category_shown } end
    for _, circle in ipairs(found.circles) do
        local asked = nil
        for _, key in ipairs(circle) do
            if everything or nodes[key].own then asked = asked or key end
        end
        if asked then
            if #circle == 1 then
                problems.error("needs-itself", where(asked), shown(asked))
            else
                local parts = {}
                for at, key in ipairs(circle) do parts[at] = shown(key) .. " needs " .. shown(circle[at % #circle + 1]) end
                problems.error("circle", where(asked), table.concat(parts, ", "))
            end
        end
    end
    for _, key in ipairs(found.unreachable) do
        local cause = found.cause[key]
        if (everything or nodes[key].own) and cause.kind == "behind" then
            problems.error("unreachable", where(key), shown(key), shown(cause.parent))
        end
    end
    for _, crossing in ipairs(found.cross) do
        if everything or nodes[crossing.node].own then
            problems.warn("cross-category", where(crossing.node), shown(crossing.node), shown(crossing.parent),
                nodes[crossing.parent].category_shown or nodes[crossing.parent].category)
        end
    end
    return found
end

-- A node of the game's store as the graph wants it. A joint counts as bought when one of its parents is.
local function game_node(record)
    local any, written = {}, {}
    for at, parent in ipairs(record.Needs) do
        any[at] = fold(parent)
        written[any[at]] = parent
    end
    return { any = any, all = {}, free = record.Free and (not record.Joint or #any == 0), category = fold(record.Category),
        category_shown = record.Category, shown = record.Id, written = written }
end

-- The checks that need the whole plan: what can be bought, where things lie, and what is unusual about it.
function M.run(plan, world, problems)
    local nodes, order = {}, {}
    for _, node in ipairs(plan.nodes) do
        local any, all = {}, {}
        for at, row in ipairs(node.any or {}) do any[at] = fold(row) end
        for at, row in ipairs(node.all or {}) do all[at] = fold(row) end
        nodes[node.key] = { any = any, all = all, free = node.free == true, category = node.category.key,
            category_shown = node.category.label, shown = node.id, own = node }
        order[#order + 1] = node.key
    end
    -- the game's nodes that are needed, and through them the ones they need
    local function pull(row)
        local key = fold(row)
        if nodes[key] then return end
        local record = world.node(row)
        if not record then return end
        nodes[key] = game_node(record)
        order[#order + 1] = key
        for _, parent in ipairs(record.Needs) do pull(parent) end
    end
    for _, node in ipairs(plan.nodes) do
        for _, row in ipairs(node.any or {}) do pull(row) end
        for _, row in ipairs(node.all or {}) do pull(row) end
    end
    wired(problems, nodes, order, false)

    for _, node in ipairs(plan.nodes) do
        local where = { node = node.id, category = node.category.label }
        if #(node.all or {}) > 0 then
            local names = {}
            for at, row in ipairs(node.all) do names[at] = nodes[fold(row)] and nodes[fold(row)].shown or row end
            problems.warn("all-of", where, node.id, joined(names))
        end
        for _, name in ipairs({ "research", "replicate" }) do
            if #(node[name] or {}) > 2 then problems.warn("price-many", where, node.id, name, #node[name]) end
        end
        local gives = node.gives
        if gives and gives.new and gives.count > 1 then
            local holds = world.stack(gives.item)
            if holds and gives.count > holds then problems.warn("stack", where, node.id, gives.count, gives.item, holds) end
        end
    end

    -- entries that add to the same category of the game's lie on one canvas, so they are looked at together
    local groups, joined_by = {}, {}
    for _, category in ipairs(plan.categories) do
        local shared = not category.new and category.key or nil
        local group = shared and joined_by[shared]
        if not group then
            group = { label = category.label, new = category.new, row = category.row, nodes = {} }
            groups[#groups + 1] = group
            if shared then joined_by[shared] = group end
        end
        table.move(category.nodes, 1, #category.nodes, #group.nodes + 1, group.nodes)
    end
    for _, category in ipairs(groups) do
        local list, by, mine = {}, {}, {}
        if not category.new and category.row then
            for _, record in ipairs(world.nodes(category.row)) do
                local entry = { id = record.Id, x = record.At.X, y = record.At.Y, size = record.Size }
                list[#list + 1] = entry
                by[fold(record.Id)] = entry
            end
        end
        for _, node in ipairs(category.nodes) do
            if node.at then
                local entry = { id = node.id, x = node.at.x, y = node.at.y, size = node.size }
                list[#list + 1] = entry
                by[node.key], mine[entry] = entry, true
            end
        end
        local shown = category.label
        M.placed(problems, list, shown, mine)
        local lines = {}
        for _, node in ipairs(category.nodes) do
            if node.line == "straight" and by[node.key] then
                for _, kind in ipairs({ "any", "all" }) do
                    for _, row in ipairs(node[kind] or {}) do
                        local from = by[fold(row)]
                        if from then lines[#lines + 1] = { from = from, to = by[node.key] } end
                    end
                end
            end
        end
        for _, crossing in ipairs(layout.crossings(list, lines)) do
            problems.warn("line-through", { node = crossing.to.id, category = shown }, crossing.from.id, crossing.to.id, crossing.over.id)
        end
    end
    if #plan.nodes >= M.LARGE then problems.warn("large", nil, #plan.nodes) end
end

-- The loose ends of the game's own store: rows that name what is not there, and nodes that lie outside the screen.
function M.store(world)
    local problems = M.list()
    local nodes, order, on_sale = {}, {}, {}
    for _, category in ipairs(world.categories()) do
        local list = {}
        for _, record in ipairs(world.nodes(category.Id)) do
            local key = fold(record.Id)
            nodes[key] = game_node(record)
            order[#order + 1] = key
            list[#list + 1] = { id = record.Id, x = record.At.X, y = record.At.Y, size = record.Size }
            local where = { node = record.Id, category = category.Id }
            if record.StoreItem then on_sale[fold(record.StoreItem)] = true end
            if record.StoreItem and not world.has("store_item", record.StoreItem) then
                problems.warn("game-item", where, record.Id, record.StoreItem, world.where("store_item"))
            elseif record.Gives and not world.has("template", record.Gives) then
                problems.warn("game-template", where, record.Id, record.StoreItem, record.Gives, world.where("template"))
            end
        end
        M.placed(problems, list, category.Id, nil)
    end
    for _, name in ipairs(world.names("store_item")) do
        local item = world.store_item(name)
        if item and item.gives and not on_sale[fold(name)] and not world.has("template", item.gives) then
            problems.warn("game-unsold", nil, item.row, item.gives, world.where("template"))
        end
    end
    local found = wired(problems, nodes, order, true)
    for _, gone in ipairs(found.missing) do
        local node = nodes[gone.node]
        problems.warn("game-parent", { node = node.shown, category = node.category_shown }, node.shown, node.written[gone.parent] or gone.parent)
    end
    return problems.sorted()
end

return M
