-- Coroutines the engine accepts

local Wax = ...

local co = {}

-- Negative, so it can never collide with the positive slots luaL_ref hands out. Keep in sync with waxco.c.
local FN_KEY = -22433
local EXPECTED_VERSION = 1

local registry = debug.getregistry()
local plain_create = coroutine.create
local newthread

local function load_helper()
    if not (package and package.loadlib and Wax and Wax.root) then return nil, "no package.loadlib or Wax.root" end
    local dll = Wax.root .. "/bin/waxco.dll"
    local version_fn, err = package.loadlib(dll, "wax_native_version")
    if not version_fn then return nil, tostring(err) end
    local version = version_fn()
    if version ~= EXPECTED_VERSION then
        return nil, "waxco.dll reports version " .. tostring(version) .. ", expected " .. EXPECTED_VERSION
    end
    local fn, err2 = package.loadlib(dll, "wax_newthread")
    if not fn then return nil, tostring(err2) end
    return fn
end

do
    local fn, err = load_helper()
    newthread = fn
    co.native = fn ~= nil
    co.native_error = err
    -- os.clock only resolves a millisecond in this Lua build. The helper reads the high-resolution counter.
    local micros = fn and package.loadlib(Wax.root .. "/bin/waxco.dll", "wax_clock_us")
    if micros and math.type(micros()) == "integer" then
        co.clock = function() return micros() * 1e-6 end
    end
end

-- Like coroutine.create, but the thread may call the engine.
function co.create(fn)
    if type(fn) ~= "function" then error("co.create expects a function, got " .. type(fn), 2) end
    if not newthread then return plain_create(fn) end
    registry[FN_KEY] = fn
    local thread = newthread()
    registry[FN_KEY] = nil
    if not thread then error("could not create an engine-registered coroutine", 2) end
    return thread
end

local function wrap_finish(thread, ok, ...)
    if ok then return ... end
    local err = ...
    -- Keep the failing coroutine's own traceback: the caller's would stop at this resume.
    if type(err) == "string" then err = debug.traceback(thread, err) end
    error(err, 0)
end

function co.wrap(fn)
    local thread = co.create(fn)
    return function(...)
        return wrap_finish(thread, coroutine.resume(thread, ...))
    end
end

co.resume = coroutine.resume
co.yield = coroutine.yield
co.status = coroutine.status
co.running = coroutine.running
co.isyieldable = coroutine.isyieldable
co.close = coroutine.close

-- The coroutine library mods get: create and wrap make threads that can call the engine
function co.library()
    local lib = {}
    for name, value in pairs(coroutine) do lib[name] = value end
    lib.create = co.create
    lib.wrap = co.wrap
    return lib
end

return co
