-- How the Explorer reached an object, how to reach it again, and the Lua that does the same

local Wax = ...
local instance = Wax.import("engine.instance")
local inspect = Wax.import("engine.inspect")
local game = Wax.import("engine.game").root

local M = {}

M.ROOTS = { "Character", "LocalPlayer", "GameState", "GameMode", "GameInstance", "Viewport", "Engine", "World" }
local SHORT = { "Character", "LocalPlayer", "GameState", "GameMode" }      -- a property of one of these is a short way to an object
local DEPTH = 8

-- names an Instance answers itself, so a property with one of them is read with :Get
local OWN = { Name = true, ClassName = true, FullName = true, Parent = true, Raw = true }
for name in pairs(instance.Instance) do OWN[name] = true end
local WORDS = {}
for word in ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"):gmatch("%a+") do
    WORDS[word] = true
end

local function simple(name)
    return name:find("^[%a_][%w_]*$") ~= nil and not WORDS[name] and not OWN[name] and not Wax.import("engine.easy").taken(name)
end

function M.quote(text) return (("%q"):format(tostring(text)):gsub("\\\n", "\\n")) end
local quote = M.quote

-- Lua that reads the property `name` of what `expr` gives.
function M.read_of(expr, name)
    if simple(name) then return expr .. "." .. name end
    return ("%s:Get(%s)"):format(expr, quote(name))
end

-- Lua that writes it.
function M.write_of(expr, name, literal)
    if simple(name) then return ("%s.%s = %s"):format(expr, name, literal) end
    return ("%s:Set(%s, %s)"):format(expr, quote(name), literal)
end

-- Lua that calls the function `name` with the parameter names standing in for values.
function M.call_of(expr, name, params)
    local words = {}
    for index, param in ipairs(params or {}) do
        local word = param.name:gsub("[^%w_]", "_")
        words[index] = word:find("^%d") and "_" .. word or word
    end
    if simple(name) then return ("%s:%s(%s)"):format(expr, name, table.concat(words, ", ")) end
    table.insert(words, 1, quote(name))
    return ("%s:Call(%s)"):format(expr, table.concat(words, ", "))
end

-- A path starts at a member of `game` or at a kept Instance and goes on by property names.
function M.from_root(name) return { root = name, steps = {} } end
function M.from(inst) return { base = inst, steps = {} } end

-- The path one property further (and one place into an array when `index` is given).
function M.step(path, name, index)
    local steps = table.move(path.steps, 1, #path.steps, 1, {})
    steps[#steps + 1] = { name = name, index = index }
    return { root = path.root, base = path.base, steps = steps }
end

function M.same(a, b)
    if a == b then return true end
    if not a or not b or a.root ~= b.root or #a.steps ~= #b.steps then return false end
    if (a.base or false) ~= (b.base or false) then return false end
    for index, step in ipairs(a.steps) do
        local other = b.steps[index]
        if step.name ~= other.name or step.index ~= other.index then return false end
    end
    return true
end

-- The member of `game` with this name as it is now, or nil.
function M.root(name)
    local ok, found = pcall(function() return game[name] end)
    return ok and instance.is_instance(found) and found or nil
end

local function follow(path)
    local at = path.base
    if path.root then at = game[path.root] end
    if not instance.is_instance(at) or not at:IsValid() then return nil end
    for _, step in ipairs(path.steps) do
        if step.index then at = inspect.element(at, step, step.index) else at = at:Get(step.name) end
        if not instance.is_instance(at) then return nil end
    end
    return at
end

-- Reaches the object again from where the path starts. Nothing found on an earlier walk is used.
function M.resolve(path)
    local ok, found = pcall(follow, path)
    return ok and found or nil
end

-- The path as Lua. `base` is the Lua for the Instance a path without a root starts at.
function M.code(path, base)
    local expr = path.root and ("game." .. path.root) or base
    if not expr then return nil end
    for _, step in ipairs(path.steps) do
        expr = M.read_of(expr, step.name)
        if step.index then expr = ("%s[%d]"):format(expr, step.index) end
    end
    return expr
end

local function root_named(inst, roots)
    for _, name in ipairs(M.ROOTS) do
        if roots[name] and roots[name] == inst then return name end
    end
    return nil
end

local function held_by_root(inst, roots)
    for _, name in ipairs(SHORT) do
        local root = roots[name]
        if root then
            local ok, property = pcall(inspect.holder, root, inst)
            if ok and property then return M.read_of("game." .. name, property) end
        end
    end
    return nil
end

-- Lua that reaches `inst` through what it belongs to, or nil. `unique(class_name)` says that one actor has that class.
local function by_family(inst, unique)
    local roots = {}
    for _, name in ipairs(M.ROOTS) do roots[name] = M.root(name) end
    local chain, base = { inst }, nil
    for _ = 1, DEPTH do
        local top = chain[#chain]
        local name = root_named(top, roots)
        if name then
            base = "game." .. name
            break
        end
        base = held_by_root(top, roots)
        if base then break end
        local parent = top:GetParent()
        if not parent then break end
        if roots.World and parent == roots.World then
            -- by class when it is the only one (its name has a number that changes every session), else by name
            local class_name = top.ClassName
            local first = unique and unique(class_name) and game:Find(class_name) or nil
            if first and first == top then
                base = ("game:Find(%s)"):format(quote(class_name))
            else
                base = ("game.World:FindFirstChild(%s)"):format(quote(top.Name))
            end
            break
        end
        chain[#chain + 1] = parent
    end
    if not base then return nil end
    local expr = base
    for index = #chain - 1, 1, -1 do
        local parent, child = chain[index + 1], chain[index]
        local property = inspect.holder(parent, child)
        if property then
            expr = M.read_of(expr, property)
        else
            local name = child.Name
            local found = parent:FindFirstChild(name)
            if not (found and found == child) then return nil end
            expr = ("%s:FindFirstChild(%s)"):format(expr, quote(name))
        end
    end
    return expr
end

local function searches(expr) return expr:find(":Find", 1, true) ~= nil end

-- The shortest Lua that reaches the object and keeps working: a member of game, then properties, then a search by name or class.
-- `inst` is the object if it is at hand, `path` is how it was reached, if by properties.
function M.expression(inst, path, unique)
    local found = {}
    if path then
        local base = nil
        if path.base then base = M.expression(path.base, nil, unique) end
        found[#found + 1] = M.code(path, base)
    end
    if inst then
        local ok, expr = pcall(by_family, inst, unique)
        if ok and expr then found[#found + 1] = expr end
    end
    local best = nil
    for _, expr in ipairs(found) do
        if not best or (searches(best) and not searches(expr)) or (searches(best) == searches(expr) and #expr < #best) then best = expr end
    end
    if best then return best end
    if inst then return ("game:Find(%s)"):format(quote(inst.ClassName)) end
    return nil
end

-- "local value = <expr>.Health", or one part of a struct or one place of an array.
function M.read_line(expr, name, field, index)
    local target = M.read_of(expr, name)
    if field then target = target .. "." .. field end
    if index then target = ("%s[%d]"):format(target, index) end
    return "local value = " .. target
end

return M
