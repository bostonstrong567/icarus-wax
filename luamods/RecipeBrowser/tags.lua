-- Gameplay tag queries as D_TagQueries stores them, and how to ask one about an item's tags.

local tags = {}

local ANY, ALL, NONE, ANY_OF, ALL_OF, NONE_OF = 1, 2, 3, 4, 5, 6
local DEEPEST = 32

tags.KINDS = { ANY = ANY, ALL = ALL, NONE = NONE, ANY_OF = ANY_OF, ALL_OF = ALL_OF, NONE_OF = NONE_OF }

-- The stream is: version, has a root, then kind, count and that many tag numbers or inner expressions.
function tags.parse(query)
    if type(query) ~= "table" then return nil, "no query" end
    local stream, dictionary = query.QueryTokenStream, query.TagDictionary
    if type(stream) ~= "table" or #stream < 2 or stream[2] == 0 then return nil end
    local names = {}
    for position, entry in ipairs(dictionary or {}) do
        local name = type(entry) == "table" and entry.TagName or entry
        if type(name) ~= "string" then return nil, "tag " .. position .. " of the dictionary has no name" end
        names[position] = name:lower()
    end
    local at, size, problem = 3, #stream, nil

    local function whole(value)
        if type(value) ~= "number" then return nil end
        return math.tointeger(value)
    end

    local function expression(depth)
        local kind, count = whole(stream[at]), whole(stream[at + 1])
        if depth > DEEPEST or not kind or kind < ANY or kind > NONE_OF or not count or count < 0 or at + 1 > size then
            problem = "the token stream breaks at " .. at
            return nil
        end
        at = at + 2
        local list = {}
        for position = 1, count do
            if kind <= NONE then
                local name = names[(whole(stream[at]) or -1) + 1]
                if not name then
                    problem = (at > size and "the token stream ends early at " or "the token stream names a tag the dictionary lacks at ") .. at
                    return nil
                end
                list[position] = name
                at = at + 1
            else
                local inner = expression(depth + 1)
                if not inner then return nil end
                list[position] = inner
            end
        end
        return { kind = kind, list = list }
    end

    local tree = expression(1)
    if not tree then return nil, problem end
    return tree
end

local chains = {}

-- A tag and each of its parents: a.b.c, a.b, a.
local function chain(tag)
    local known = chains[tag]
    if known then return known end
    known = { tag }
    local rest = tag
    while true do
        local cut = rest:match("^(.*)%.[^.]*$")
        if not cut or cut == "" then break end
        known[#known + 1] = cut
        rest = cut
    end
    chains[tag] = known
    return known
end

-- The tags of two containers as one list of lower-case names, each once.
function tags.union(first, second)
    local list, seen = {}, {}
    local function take(container)
        local entries = type(container) == "table" and container.GameplayTags or nil
        for _, entry in ipairs(entries or {}) do
            local name = type(entry) == "table" and entry.TagName or entry
            if type(name) == "string" and name ~= "" then
                name = name:lower()
                if not seen[name] and name ~= "none" then
                    seen[name] = true
                    list[#list + 1] = name
                end
            end
        end
    end
    take(first)
    take(second)
    return list
end

-- Fills `into` with every tag of the list and every parent, so a lookup answers "has this tag or a child of it".
function tags.set(list, into)
    into = into or {}
    for key in pairs(into) do into[key] = nil end
    for _, tag in ipairs(list or {}) do
        local parents = chain(type(tag) == "string" and tag:lower() or "")
        for position = 1, #parents do into[parents[position]] = true end
    end
    return into
end

function tags.matches(tree, set)
    if not tree then return false end
    local kind, list = tree.kind, tree.list
    if kind == ANY then
        for position = 1, #list do
            if set[list[position]] then return true end
        end
        return false
    elseif kind == ALL then
        for position = 1, #list do
            if not set[list[position]] then return false end
        end
        return true
    elseif kind == NONE then
        for position = 1, #list do
            if set[list[position]] then return false end
        end
        return true
    elseif kind == ANY_OF then
        for position = 1, #list do
            if tags.matches(list[position], set) then return true end
        end
        return false
    elseif kind == ALL_OF then
        for position = 1, #list do
            if not tags.matches(list[position], set) then return false end
        end
        return true
    elseif kind == NONE_OF then
        for position = 1, #list do
            if tags.matches(list[position], set) then return false end
        end
        return true
    end
    return false
end

return tags
