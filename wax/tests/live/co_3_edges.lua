-- Step 3: the cases the relay design could not handle, plus error and cancellation paths.
local dll = "C:/Program Files (x86)/Steam/steamapps/common/Icarus/Icarus/Binaries/Win64/ue4ss/Mods/Wax/bin/waxco.dll"
local newthread = assert(package.loadlib(dll, "wax_newthread"))
local registry = debug.getregistry()
local KEY = -22433
local function cocreate(fn)
    registry[KEY] = fn
    local co = newthread()
    registry[KEY] = nil
    return co
end

local out = {}

-- 1. An engine call inside a table.sort comparator (a C frame sits between the coroutine and the call).
do
    local co = cocreate(function()
        local world = FindFirstOf("World")
        local items = { 5, 3, 9, 1, 7 }
        local comparisons = 0
        table.sort(items, function(a, b)
            comparisons = comparisons + 1
            return world:IsValid() and a < b
        end)
        return table.concat(items, ","), comparisons
    end)
    local ok, sorted, n = coroutine.resume(co)
    out.sortWithEngineComparator = { ok = ok, sorted = sorted, comparisons = n }
end

-- 2. Engine call inside a string.gsub callback and inside tostring's __tostring metamethod.
do
    local co = cocreate(function()
        local world = FindFirstOf("World")
        local replaced = ("a-b-c"):gsub("%-", function() return world:IsValid() and "+" or "?" end)
        local obj = setmetatable({}, { __tostring = function() return "world valid: " .. tostring(world:IsValid()) end })
        return replaced, tostring(obj), string.format("%s", obj)
    end)
    local ok, a, b, c = coroutine.resume(co)
    out.gsubAndTostring = { ok = ok, gsub = a, tostring = b, format = c }
end

-- 3. An error inside the coroutine is an ordinary failed resume, with a traceback available.
do
    local co = cocreate(function()
        local world = FindFirstOf("World")
        local _ = world:GetFullName()
        error("deliberate failure")
    end)
    local ok, err = coroutine.resume(co)
    out.errorInside = { ok = ok, error = tostring(err), status = coroutine.status(co), hasTraceback = debug.traceback(co):find("deliberate") == nil }
end

-- 4. Closing a suspended coroutine runs its to-be-closed variables and leaves it dead.
do
    local closed = false
    local co = cocreate(function()
        local guard <close> = setmetatable({}, { __close = function() closed = true end })
        coroutine.yield("parked")
        return "never"
    end)
    local ok, parked = coroutine.resume(co)
    local closedOk = coroutine.close(co)
    out.closeSuspended = { firstResume = ok, parked = parked, closeOk = closedOk, closeHandlerRan = closed, status = coroutine.status(co) }
end

-- 5. Nested: a helper coroutine resumed from inside another helper coroutine, both touching the engine.
do
    local inner = cocreate(function()
        return FindFirstOf("World"):GetFullName()
    end)
    local outer = cocreate(function()
        local ok, name = coroutine.resume(inner)
        return ok and name == FindFirstOf("World"):GetFullName()
    end)
    local ok, same = coroutine.resume(outer)
    out.nested = { ok = ok, sameWorld = same }
end

-- 6. coroutine.running / isyieldable inside, and that a missing function yields no thread at all.
do
    local co = cocreate(function() return coroutine.isyieldable(), select(2, coroutine.running()) end)
    local ok, yieldable, isMain = coroutine.resume(co)
    registry[KEY] = nil
    local nothing = newthread()
    out.introspection = { ok = ok, yieldable = yieldable, isMain = isMain, noFunctionGivesNil = nothing == nil }
end

return out
