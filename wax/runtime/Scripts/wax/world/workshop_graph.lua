-- The store's requirements as a graph: what can ever be bought, what goes round in a circle, what crosses categories

local M = {}

local KINDS = { "any", "all" }

-- The groups of keys that can each reach every other of the group through `edges`.
local function groups(keys, edges)
    local index, low, on_stack, stack, out, counter = {}, {}, {}, {}, {}, 0
    local function visit(key)
        counter = counter + 1
        index[key], low[key] = counter, counter
        stack[#stack + 1] = key
        on_stack[key] = true
        for _, other in ipairs(edges[key]) do
            if not index[other] then
                visit(other)
                if low[other] < low[key] then low[key] = low[other] end
            elseif on_stack[other] and index[other] < low[key] then
                low[key] = index[other]
            end
        end
        if low[key] == index[key] then
            local group = {}
            repeat
                local member = table.remove(stack)
                on_stack[member] = nil
                group[#group + 1] = member
            until member == key
            out[#out + 1] = group
        end
    end
    for _, key in ipairs(keys) do
        if not index[key] then visit(key) end
    end
    return out
end

-- One way round inside a group, from its first member back to it: { a, b, c } reads "a needs b, b needs c, c needs a".
local function way_round(start, inside, edges)
    local before, queue, head = {}, {}, 1
    for _, other in ipairs(edges[start]) do
        if other == start then return { start } end
        if inside[other] and not before[other] then
            before[other] = start
            queue[#queue + 1] = other
        end
    end
    while head <= #queue do
        local key = queue[head]
        head = head + 1
        for _, other in ipairs(edges[key]) do
            if other == start then
                local back = { key }
                while before[back[#back]] ~= start do back[#back + 1] = before[back[#back]] end
                local way = { start }
                for at = #back, 1, -1 do way[#way + 1] = back[at] end
                return way
            end
            if inside[other] and not before[other] then
                before[other] = key
                queue[#queue + 1] = other
            end
        end
    end
    return { start }
end

-- `nodes[key]` is { any, all, free, category }: of `any` one bought is enough, of `all` every one is needed. `order` lists the keys.
function M.analyse(nodes, order)
    local reachable, dependents = {}, {}
    local result = { reachable = reachable, unreachable = {}, missing = {}, circles = {}, cause = {}, cross = {} }
    for _, key in ipairs(order) do
        local node = nodes[key]
        for _, kind in ipairs(KINDS) do
            for _, parent in ipairs(node[kind] or {}) do
                local found = nodes[parent]
                if found then
                    dependents[parent] = dependents[parent] or {}
                    dependents[parent][#dependents[parent] + 1] = key
                    if found.category and node.category and found.category ~= node.category then
                        result.cross[#result.cross + 1] = { node = key, parent = parent }
                    end
                else
                    result.missing[#result.missing + 1] = { node = key, parent = parent, kind = kind }
                end
            end
        end
    end

    local function met(key)
        local node = nodes[key]
        if node.free then return true end
        for _, parent in ipairs(node.all or {}) do
            if not reachable[parent] then return false end
        end
        local any = node.any or {}
        if #any == 0 then return true end
        for _, parent in ipairs(any) do
            if reachable[parent] then return true end
        end
        return false
    end

    local queue, head = {}, 1
    for _, key in ipairs(order) do
        if not reachable[key] and met(key) then
            reachable[key] = true
            queue[#queue + 1] = key
        end
    end
    while head <= #queue do
        local key = queue[head]
        head = head + 1
        for _, dependent in ipairs(dependents[key] or {}) do
            if not reachable[dependent] and met(dependent) then
                reachable[dependent] = true
                queue[#queue + 1] = dependent
            end
        end
    end

    -- among what cannot be reached: who waits for whom
    local edges = {}
    for _, key in ipairs(order) do
        if not reachable[key] then
            result.unreachable[#result.unreachable + 1] = key
            local list, seen = {}, {}
            for _, kind in ipairs(KINDS) do
                for _, parent in ipairs(nodes[key][kind] or {}) do
                    if nodes[parent] and not reachable[parent] and not seen[parent] then
                        seen[parent] = true
                        list[#list + 1] = parent
                    end
                end
            end
            edges[key] = list
        end
    end
    local in_circle = {}
    for _, group in ipairs(groups(result.unreachable, edges)) do
        local alone = #group == 1
        local turns = not alone
        if alone then
            for _, other in ipairs(edges[group[1]]) do turns = turns or other == group[1] end
        end
        if turns then
            local inside, first = {}, nil
            for _, key in ipairs(group) do inside[key] = true end
            for _, key in ipairs(order) do
                if inside[key] then
                    first = key
                    break
                end
            end
            local way = way_round(first, inside, edges)
            result.circles[#result.circles + 1] = way
            for _, key in ipairs(group) do in_circle[key] = #result.circles end
        end
    end
    for _, key in ipairs(result.unreachable) do
        if in_circle[key] then
            result.cause[key] = { kind = "circle", circle = in_circle[key] }
        else
            -- what holds it back: a parent of `all` that cannot be reached, else the first of `any`
            local node, blocker, gone = nodes[key], nil, nil
            for _, parent in ipairs(node.all or {}) do
                if not reachable[parent] then
                    if nodes[parent] then blocker = blocker or parent else gone = gone or parent end
                end
            end
            if not blocker and not gone then
                for _, parent in ipairs(node.any or {}) do
                    if nodes[parent] then blocker = blocker or parent else gone = gone or parent end
                end
            end
            result.cause[key] = blocker and { kind = "behind", parent = blocker } or { kind = "missing", parent = gone }
        end
    end
    return result
end

return M
