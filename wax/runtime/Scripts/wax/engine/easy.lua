-- Members a module gives to a family of classes: fields to read, fields to set, and methods

local Wax = ...
local scope = Wax.import("core.scope")
local suggest = Wax.import("core.suggest")
local log = Wax.import("core.log").channel("wax.easy")

local M = {}

local PARTS = { "fields", "setters", "methods" }
local IS_PART = { fields = true, setters = true, methods = true }

local by_class = {}         -- class name -> what was registered for it, oldest first
local taken = {}            -- member name -> how many registrations give it
local registered = 0
local clashes, noted = {}, {}

-- class info -> what its objects are given, or false. engine.instance reads this table itself: it is emptied, never replaced.
local merged = setmetatable({}, { __mode = "k" })
M.merged = merged
local lists = setmetatable({}, { __mode = "k" })       -- class info -> every name such an object answers to
local roots = {}            -- class name -> what that class is given, shared by the classes built on it that add nothing

-- Given by engine.instance when it loads.
local function unbound(...) error("engine.instance is not loaded, so there is no Instance to give members to", 0) end
local is_instance, live = unbound, unbound
local own, is_own = {}, {}

local function forget()
    for info in pairs(merged) do merged[info] = nil end
    for info in pairs(lists) do lists[info] = nil end
    roots = {}
end

-- What a member raises is raised again at the line of the mod that used it.
-- engine.instance reaches a reader and a writer by a tail call, so level 2 is that line.
local function reader(get)
    return function(self)
        local ok, value = pcall(get, self, live(self, 2))
        if ok then return value end
        error(value, 2)
    end
end

local function writer(set)
    return function(self, value)
        local ok, problem = pcall(set, self, live(self, 2), value)
        if not ok then error(problem, 2) end
    end
end

-- Reached by a tail call as well.
local function finish(ok, ...)
    if ok then return ... end
    error((...), 2)
end

local function caller(name, fn)
    return function(self, ...)
        if not is_instance(self) then error(("call %s with a colon: instance:%s(...)"):format(name, name), 2) end
        return finish(pcall(fn, self, live(self, 2), ...))
    end
end

local function build(spec, level)
    for part, members in pairs(spec) do
        if not IS_PART[part] then
            error(("easy.class: a class is given fields, setters and methods, not '%s'.%s"):format(tostring(part),
                suggest.phrase(tostring(part), PARTS)), level + 1)
        end
        if type(members) ~= "table" then
            error(("easy.class: %s is a table of names and functions, got %s"):format(part, type(members)), level + 1)
        end
        for name, fn in pairs(members) do
            if type(name) ~= "string" or not name:find("^%u[%w_]*$") then
                error(("easy.class: '%s' in %s is not a name for a member. A name starts with a capital letter and has no spaces")
                    :format(tostring(name), part), level + 1)
            end
            if type(fn) ~= "function" then
                error(("easy.class: %s.%s must be a function, got %s"):format(part, name, type(fn)), level + 1)
            end
            if is_own[name] then
                error(("easy.class: every Instance has '%s' already, so a class cannot be given that name"):format(name), level + 1)
            end
        end
    end
    local built = { fields = {}, setters = {}, methods = {} }
    for name, fn in pairs(spec.methods or {}) do
        if (spec.fields and spec.fields[name]) or (spec.setters and spec.setters[name]) then
            error(("easy.class: '%s' is given as a method and as a field. It can only be one of them"):format(name), level + 1)
        end
        built.methods[name] = caller(name, fn)
    end
    for name, fn in pairs(spec.fields or {}) do built.fields[name] = reader(fn) end
    for name, fn in pairs(spec.setters or {}) do built.setters[name] = writer(fn) end
    return built
end

local function count_names(entry, by)
    for _, part in ipairs(PARTS) do
        for name in pairs(entry[part]) do
            local left = (taken[name] or 0) + by
            taken[name] = left > 0 and left or nil
        end
    end
end

local function drop(entry)
    local list = by_class[entry.class]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == entry then
            table.remove(list, i)
            registered = registered - 1
            count_names(entry, -1)
        end
    end
    if #list == 0 then by_class[entry.class] = nil end
end

-- easy.class("IcarusCharacter", { fields = { Health = get }, setters = { Health = set }, methods = { Heal = fn } }, "character")
-- get(self, raw), set(self, raw, value), fn(self, raw, ...): the Instance and its live engine object. Returns the undo.
function M.class(class_name, spec, source)
    local names = type(class_name) == "table" and class_name or { class_name }
    if #names == 0 then error("easy.class expects a class name such as \"IcarusCharacter\", or a list of them", 2) end
    for _, name in ipairs(names) do
        if type(name) ~= "string" or name == "" then
            error("easy.class expects a class name such as \"IcarusCharacter\", or a list of them, got " .. type(name), 2)
        end
    end
    if type(spec) ~= "table" then
        error("easy.class expects a table with fields, setters and methods, got " .. type(spec), 2)
    end
    if source ~= nil and type(source) ~= "string" then
        error("easy.class: the source is a name such as \"character\", got " .. type(source), 2)
    end
    local built = build(spec, 2)
    local made = {}
    for _, name in ipairs(names) do
        local list = by_class[name]
        if not list then
            list = {}
            by_class[name] = list
        end
        if source then
            for i = #list, 1, -1 do
                if list[i].source == source then drop(list[i]) end
            end
            list = by_class[name] or {}
            by_class[name] = list
        end
        local entry = { class = name, source = source, fields = built.fields, setters = built.setters, methods = built.methods }
        list[#list + 1] = entry
        made[#made + 1] = entry
        registered = registered + 1
        count_names(entry, 1)
    end
    forget()
    local owner, slot, gone = nil, nil, false
    local function remove()
        if gone then return end
        gone = true
        for _, entry in ipairs(made) do drop(entry) end
        forget()
        if owner then owner:remove(slot) end
    end
    owner, slot = scope.own(remove)
    return remove
end

local function clash(class_name, name, info, kind)
    local key = class_name .. "." .. name
    if noted[key] then return end
    noted[key] = true
    clashes[#clashes + 1] = { Class = class_name, Name = name, On = info.name, Kind = kind }
    log:warn("%s is given the name %s, and the game's own %s has a %s of that name. A mod reads Wax's. "
        .. "The game's is reached with :Get, :Set or :Call", class_name, name, info.name, kind)
end

-- What the class at chain[at] is given, with what the classes it is built on are given. Further down the family wins.
local function gather(chain, at)
    local found, from = { fields = {}, setters = {}, methods = {}, names = {} }, {}
    for index = #chain, at, -1 do
        local list = by_class[chain[index]]
        for i = 1, list and #list or 0 do
            local entry = list[i]
            entry.seen = true
            for name, fn in pairs(entry.fields) do
                found.fields[name], found.methods[name], from[name] = fn, nil, entry.class
            end
            for name, fn in pairs(entry.setters) do
                found.setters[name], found.methods[name], from[name] = fn, nil, entry.class
            end
            for name, fn in pairs(entry.methods) do
                found.methods[name], found.fields[name], found.setters[name], from[name] = fn, nil, nil, entry.class
            end
        end
    end
    for name in pairs(from) do
        if is_own[name] then
            found.fields[name], found.setters[name], found.methods[name] = nil, nil, nil
        else
            found.names[#found.names + 1] = name
        end
    end
    table.sort(found.names)
    found.from = from
    return found
end

-- What an object of this class is given: false for nothing. Classes that add nothing of their own share one answer.
function M.merge(info)
    local chain, at = info.chain, 1
    while chain[at] and not by_class[chain[at]] do at = at + 1 end
    local root, found = chain[at], false
    if root then
        found = roots[root]
        if not found then
            found = gather(chain, at)
            roots[root] = found
        end
        local members, names = info.members, found.names
        for i = 1, #names do
            local member = members[names[i]]
            if member then clash(found.from[names[i]], names[i], info, member.kind) end
        end
    end
    merged[info] = found
    return found
end

-- Every name an object of this class answers to: the game's, Wax's own and what the class is given. For suggestions.
function M.every(info)
    local list = lists[info]
    if list then return list end
    local seen = {}
    list = {}
    local function add(names)
        for i = 1, #names do
            local name = names[i]
            if not seen[name] then
                seen[name] = true
                list[#list + 1] = name
            end
        end
    end
    add(info.list)
    add(own)
    local added = merged[info]
    if added == nil then added = M.merge(info) end
    if added then add(added.names) end
    lists[info] = list
    return list
end

-- True when some class is given a member of this name.
function M.taken(name) return taken[name] ~= nil end

-- Called by engine.instance: how to tell an Instance, how to get its engine object, and the names every Instance has.
function M.bind(tools)
    is_instance, live = tools.is_instance, tools.live
    own, is_own = {}, {}
    for _, name in ipairs(tools.own) do
        own[#own + 1] = name
        is_own[name] = true
    end
    forget()
end

-- The names Wax gives that the game's own classes also have. It should stay empty.
function M.clashes()
    local out = {}
    for i, found in ipairs(clashes) do out[i] = { Class = found.Class, Name = found.Name, On = found.On, Kind = found.Kind } end
    return out
end

function M.stats()
    local classes, cached, unseen = 0, 0, {}
    for name, list in pairs(by_class) do
        classes = classes + 1
        local seen = false
        for i = 1, #list do seen = seen or list[i].seen == true end
        if not seen then unseen[#unseen + 1] = name end
    end
    for _ in pairs(merged) do cached = cached + 1 end
    table.sort(unseen)
    -- unseen: classes that were given members and that no object has had yet (a misspelt class name stays here)
    return { registrations = registered, classes = classes, cached = cached, clashes = #clashes, unseen = unseen }
end

return M
