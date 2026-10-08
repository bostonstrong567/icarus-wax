-- What an item takes from raw materials to the finished thing: the tree, the raw totals and the crafting order.

local tree = { LIMIT = 400, DEPTH = 12 }

local NONE = {}
local KINDS = { item = 1, tag = 2, resource = 3 }

local function takes(recipe)
    return #(recipe.inputs or NONE) + #(recipe.tags_in or NONE) + #(recipe.res_in or NONE)
end

-- A recipe the tree picks by itself shows in the browser, has a station and takes something.
local function usable(recipe)
    return not recipe.hidden_only and not recipe.disabled and #(recipe.stations or NONE) > 0 and takes(recipe) > 0
end

-- The recipe an item is made with unless another is chosen, and how many it could be made with.
local function default(m, key)
    local first, count = nil, 0
    for _, number in ipairs(m.made_by and m.made_by[key] or NONE) do
        local recipe = m.recipes[number]
        if recipe and usable(recipe) then
            first = first or number
            count = count + 1
        end
    end
    return first, count
end

local function makes_it(m, key, number)
    if type(number) ~= "number" or not m.recipes[number] then return false end
    for _, known in ipairs(m.made_by and m.made_by[key] or NONE) do
        if known == number then return true end
    end
    return false
end

-- How many one craft gives: the item or a kind of it, else the resource it stands for, else what the recipe is titled as.
local function makes_of(m, recipe, key)
    local item, total = m.items[key], 0
    for _, output in ipairs(recipe.outputs or NONE) do
        local made = m.items[output.item]
        if output.item == key or (made and made.static == key) then total = total + output.count end
    end
    if total == 0 and item and item.resource then
        for _, amount in ipairs(recipe.res_out or NONE) do
            if amount.res == item.resource then total = total + amount.units end
        end
    end
    if total == 0 and recipe.outputs and recipe.outputs[1] then total = recipe.outputs[1].count end
    if total <= 0 then total = 1 end
    return total
end

-- The first station with a name to show, as the recipe list picks it.
local function station_of(m, recipe)
    for _, id in ipairs(recipe.stations or NONE) do
        local set = m.sets and m.sets[id]
        if set and (set.hand or (set.name or "") ~= "") then return set, id end
    end
    return nil
end

-- Every node starts as one that is not broken down.
local function new_node(kind, entry, key, need, depth)
    return { kind = kind, key = key, name = entry and entry.name or key, icon = entry and entry.icon or nil,
        lower = entry and entry.lower or nil, need = need, depth = depth, raw = true }
end

local function on_path(above, node)
    local parent = above[node]
    while parent do
        if parent.key == node.key then return true end
        parent = above[parent]
    end
    return false
end

-- options: choice (item key -> recipe number, or false to stop at that item), limit (nodes), depth
function tree.build(m, key, count, options)
    local item = type(m) == "table" and type(key) == "string" and m.items and m.items[key] or nil
    if not item then return nil end
    options = options or NONE
    local choice = options.choice or NONE
    local limit, deepest = tonumber(options.limit) or tree.LIMIT, tonumber(options.depth) or tree.DEPTH
    count = tonumber(count)
    if not count or count ~= count or count < 1 then count = 1 end
    count = math.floor(count)

    local root = new_node("item", item, key, count, 0)
    local above, queue, head, nodes, full = {}, { root }, 1, 1, false
    -- A level at a time, so the node limit cuts the deepest parts and not the last branches.
    while queue[head] do
        local node = queue[head]
        head = head + 1
        local number, usable_count = default(m, node.key)
        local chosen = choice[node.key]
        if chosen == false then
            number = nil
        elseif makes_it(m, node.key, chosen) then
            number = chosen
        end
        local recipe = number and m.recipes[number]
        node.options = usable_count
        if not recipe or takes(recipe) == 0 then
            node.why = "raw"
        else
            local wanted = takes(recipe)
            node.recipe = number
            if on_path(above, node) then
                node.why = "loop"
            elseif recipe.random and #(recipe.outputs or NONE) > 1 then
                node.why = "random"
            elseif full or node.depth >= deepest or nodes + wanted > limit then
                node.why = "limit"
                if nodes + wanted > limit then full = true end
            else
                local makes = makes_of(m, recipe, node.key)
                local crafts = math.ceil(node.need / makes)
                local set, id = station_of(m, recipe)
                local below, children = node.depth + 1, {}
                node.raw, node.makes, node.crafts, node.left = false, makes, crafts, crafts * makes - node.need
                node.mj = (recipe.mj or 0) * crafts
                node.station, node.hand, node.set = set and set.name or nil, set ~= nil and set.hand == true, id
                local each = id and recipe.xp and recipe.xp[id]
                node.xp = each and each * crafts or nil
                for _, input in ipairs(recipe.inputs or NONE) do
                    local child = new_node("item", m.items[input.item], input.item, input.count * crafts, below)
                    children[#children + 1] = child
                    above[child] = node
                    queue[#queue + 1] = child
                end
                for _, input in ipairs(recipe.tags_in or NONE) do
                    children[#children + 1] = new_node("tag", m.tags and m.tags[input.tag], input.tag, input.count * crafts, below)
                end
                for _, amount in ipairs(recipe.res_in or NONE) do
                    children[#children + 1] = new_node("resource", m.resources and m.resources[amount.res], amount.res,
                        amount.units * crafts, below)
                end
                node.children = children
                nodes = nodes + #children
            end
        end
    end
    return root
end

local function sort_name(node)
    return node.lower or node.name:lower()
end

-- Everything the tree does not break down, added up: items, then tags, then resources, each by name.
function tree.totals(root)
    local list, found, names = {}, {}, {}
    local function visit(node)
        if not node.raw then
            for _, child in ipairs(node.children) do visit(child) end
            return
        end
        local id = node.kind .. " " .. node.key
        local entry = found[id]
        if not entry then
            entry = { kind = node.kind, key = node.key, name = node.name, icon = node.icon, need = 0 }
            found[id], names[entry] = entry, sort_name(node)
            list[#list + 1] = entry
        end
        entry.need = entry.need + node.need
    end
    if root then visit(root) end
    table.sort(list, function(a, c)
        if a.kind ~= c.kind then return KINDS[a.kind] < KINDS[c.kind] end
        if names[a] ~= names[c] then return names[a] < names[c] end
        return a.key < c.key
    end)
    return list
end

-- What to craft and in which order: deepest first, the finished item last, one entry for each crafted item.
function tree.steps(root)
    local list, found, deep, first = {}, {}, {}, {}
    local function visit(node)
        if node.raw then return end
        local step = found[node.key]
        if not step then
            step = { key = node.key, name = node.name, icon = node.icon, recipe = node.recipe, crafts = 0, makes = node.makes,
                need = 0, left = 0, station = node.station, hand = node.hand, set = node.set, mj = 0, xp = 0 }
            list[#list + 1] = step
            found[node.key], deep[step], first[step] = step, node.depth, #list
        end
        -- Added up as each branch was built: what one branch leaves over is not used by another.
        step.crafts, step.need, step.left = step.crafts + node.crafts, step.need + node.need, step.left + node.left
        step.mj = step.mj + node.mj
        -- the XP of all its crafts at its station, nothing once one of them is unknown
        step.xp = step.xp and node.xp and (step.xp + node.xp) or nil
        if node.depth > deep[step] then deep[step] = node.depth end
        for _, child in ipairs(node.children) do visit(child) end
    end
    if root then visit(root) end
    table.sort(list, function(a, c)
        if deep[a] ~= deep[c] then return deep[a] > deep[c] end
        return first[a] < first[c]
    end)
    return list
end

-- The nodes themselves in the order an indented list shows them; each carries its depth.
function tree.flatten(root)
    local out = {}
    local function visit(node)
        out[#out + 1] = node
        for _, child in ipairs(node.children or NONE) do visit(child) end
    end
    if root then visit(root) end
    return out
end

return tree
