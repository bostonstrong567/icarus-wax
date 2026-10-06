-- Step 2: a coroutine created through the helper must accept engine calls; one from coroutine.create must not.
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

local function body(a)
    local world = FindFirstOf("World")                -- UE4SS global function
    local name = world:GetFullName()                  -- userdata method
    local pc = FindFirstOf("PlayerController")
    local pawn = pc.Pawn                              -- property read
    local pawnName = pawn:IsValid() and pawn:GetFullName() or "no pawn"
    local b = coroutine.yield(name, pawnName)         -- yield out, resumed by the caller
    local again = FindFirstOf("World"):GetFullName()  -- engine call after a resume
    return a + b, again == name
end

local out = {}

-- Control: an ordinary coroutine fails on the first engine call.
local plain = coroutine.create(body)
local okPlain, errPlain = coroutine.resume(plain, 1)
out.plainCoroutine = { ok = okPlain, error = (not okPlain) and tostring(errPlain):sub(1, 120) or nil }

-- The helper's coroutine.
local co = cocreate(body)
out.type = type(co)
out.statusBefore = type(co) == "thread" and coroutine.status(co) or "n/a"
if type(co) == "thread" then
    local ok1, world, pawn = coroutine.resume(co, 40)
    out.firstResume = { ok = ok1, world = world, pawn = pawn }
    out.statusMid = coroutine.status(co)
    if ok1 then
        local ok2, sum, same = coroutine.resume(co, 2)
        out.secondResume = { ok = ok2, sum = sum, sameWorld = same }
    end
    out.statusAfter = coroutine.status(co)
end
out.registrySlotCleared = registry[KEY] == nil
return out
