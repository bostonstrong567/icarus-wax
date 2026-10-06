-- Ownership scopes: everything a mod sets up is recorded against the scope that was current at the time

local Scope = {}
Scope.__index = Scope

local current = nil

-- name is for error reports. An optional parent destroys this scope when it is destroyed.
function Scope.new(name, parent)
    -- undo is keyed by a slot number that only goes up. Removed slots are set to nil.
    local self = setmetatable({ name = name or "scope", undo = {}, last_slot = 0, alive = true, parent = parent }, Scope)
    if parent then self.parent_slot = parent:add(function() self:destroy() end) end
    return self
end

-- Registers an undo function and returns its slot. On a destroyed scope the undo runs at once.
function Scope:add(undo)
    if type(undo) ~= "function" then error("Scope:add expects a function", 2) end
    if not self.alive then
        pcall(undo)
        return nil
    end
    local slot = self.last_slot + 1
    self.last_slot = slot
    self.undo[slot] = undo
    return slot
end

-- Forgets an undo without running it (the thing was cleaned up by other means).
function Scope:remove(slot)
    if slot then self.undo[slot] = nil end
end

-- Runs every undo, newest first. One failing undo never stops the rest. Returns the list of failures.
function Scope:destroy()
    if not self.alive then return {} end
    self.alive = false
    local slots = {}
    for slot in pairs(self.undo) do slots[#slots + 1] = slot end
    table.sort(slots, function(a, b) return a > b end)
    local failures = {}
    for i = 1, #slots do
        local undo = self.undo[slots[i]]
        self.undo[slots[i]] = nil
        if undo then
            local ok, err = xpcall(undo, debug.traceback)
            if not ok then failures[#failures + 1] = err end
        end
    end
    if self.parent and self.parent_slot then self.parent:remove(self.parent_slot) end
    return failures
end

-- Number of live registrations (for leak checks and the debugger).
function Scope:size()
    local n = 0
    for _ in pairs(self.undo) do n = n + 1 end
    return n
end

local scope = { Scope = Scope, new = Scope.new }

function scope.current() return current end

-- Runs fn(...) with `owner` as the current scope. Errors are raised again, and the previous scope is restored either way.
function scope.run(owner, fn, ...)
    local previous = current
    current = owner
    local results = table.pack(pcall(fn, ...))
    current = previous
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

-- For code that already catches its own errors: switches the current scope and returns the previous one.
function scope.enter(owner)
    local previous = current
    current = owner
    return previous
end

function scope.leave(previous) current = previous end

-- Registers an undo with the current scope, if there is one. Returns owner, slot.
function scope.own(undo)
    local owner = current
    if not owner then return nil, nil end
    return owner, owner:add(undo)
end

return scope
