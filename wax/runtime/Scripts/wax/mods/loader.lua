-- Loads mods, each in its own environment, and reloads them in place when their files change

local Wax = ...
local log = Wax.import("core.log")
local scope = Wax.import("core.scope")
local guard = Wax.import("core.guard")
local co = Wax.import("core.co")
local sched = Wax.import("core.sched")
local storage = Wax.import("core.storage")
local discover = Wax.import("mods.discover")
local watch = Wax.import("mods.watch")

local loader = {}

-- Which mods the player switched off, kept between sessions in saved/wax.mods.lua.
local preferences = nil
local function switched_off()
    if not preferences then
        preferences = storage.load("wax", "mods", { disabled = {} })
        if type(preferences.disabled) ~= "table" then preferences.disabled = {} end
    end
    return preferences.disabled
end

local core_log = log.channel("wax.mods")
local noted = {}        -- what the last look at the mods folder had to say, so the log says it once
local mods = {}             -- id -> mod record
local order = {}            -- ids in load order (dependencies first)
local pending = {}          -- reloads queued for the next frame step: id -> true
local pending_sync = false
local extras = {}           -- name -> value: additions to every mod's environment (set by other core modules)

-- UE4SS functions that must not be used from mod code, with the reason shown to the author.
local OFF_THREAD = "it runs Lua on another thread, which corrupts the game's Lua state. Use task.spawn or task.delay"
local OFF_KEYS = "it runs Lua on another thread, which corrupts the game's Lua state. Use ui.Hotkey(key, fn)"
local BLOCKED = {
    LoopAsync = OFF_THREAD, ExecuteAsync = OFF_THREAD, ExecuteWithDelay = OFF_THREAD,
    RegisterKeyBind = OFF_KEYS, RegisterKeyBindAsync = OFF_KEYS,
    RestartMod = "restarting a UE4SS mod destroys the Lua state Wax runs in. Reload the mod through Wax instead",
    RestartCurrentMod = "restarting a UE4SS mod destroys the Lua state Wax runs in. Reload the mod through Wax instead",
    UninstallMod = "it destroys the Lua state Wax runs in",
    UninstallCurrentMod = "it destroys the Lua state Wax runs in",
    ClearAllDelayedActions = "it cancels every mod's timers, and Wax's own frame loop with them",
}

local function read_file(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local text = file:read("a")
    file:close()
    watch.loaded(path, text)
    if text:sub(1, 3) =="\239\187\191" then text = text:sub(4) end     -- UTF-8 byte order mark
    return text
end

-- Loads a file that returns a plain table of data (the index, a manifest). It runs in an empty environment.
local function load_data_file(path)
    local text, err = read_file(path)
    if not text then return nil, err end
    local chunk, syntax_error = load(text, "@" .. path, "t", {})
    if not chunk then return nil, syntax_error end
    local ok, value = pcall(chunk)
    if not ok then return nil, tostring(value) end
    if type(value) ~= "table" then return nil, "expected the file to return a table, got " .. type(value) end
    return value
end

-- mod environment
local function blocked(name, reason)
    return function()
        error(("%s is not available in Wax mods: %s. (raw.%s is still the original function, with no protection.)")
            :format(name, reason, name), 2)
    end
end

-- mod.Utils and mod.extras.Utils stand for files of the mod. require takes them in place of a name.
local PATH = {}

local function has_folder(mod, path)
    local prefix = path .. "/"
    for name in pairs(mod.files) do
        if name:sub(1, #prefix) == prefix then return true end
    end
    return false
end

local function file_of(mod, path)
    if not (mod.files[path .. ".lua"] or has_folder(mod, path)) then return nil end
    return setmetatable({ [PATH] = path }, {
        __index = function(_, key)
            local inner = type(key) == "string" and file_of(mod, path .. "/" .. key)
            if not inner then
                error(("%s has no file or folder '%s' in %s"):format(mod.id, tostring(key), path), 2)
            end
            return inner
        end,
        __newindex = function() error("mod." .. path:gsub("/", ".") .. " stands for a file and cannot be assigned to", 2) end,
        __tostring = function() return mod.id .. "/" .. path end,
    })
end

local function make_env(mod)
    local env = {}
    env._G = env
    env.raw = _G                                   -- deliberate, unguarded access to everything UE4SS offers
    env.coroutine = co.library()                    -- coroutines that can call the engine
    env.print = log.printer(mod.id)
    env.task = sched.task
    env.Signal = sched.Signal
    env.log = log.channel(mod.id)
    env.mod = setmetatable({ id = mod.id, name = mod.manifest.name or mod.id, version = mod.manifest.version or "0.0.0",
        dir = mod.dir }, { __index = function(_, key) return type(key) == "string" and file_of(mod, key) or nil end })
    for name, reason in pairs(BLOCKED) do env[name] = blocked(name, reason) end
    for name, value in pairs(extras) do env[name] = value end

    -- Settings that survive restarting the game: storage.Load("settings", defaults), then storage.Save("settings", t).
    env.storage = {
        Load = function(name, defaults) return storage.load(mod.id, name, defaults) end,
        Save = function(name, value) storage.save(mod.id, name, value) end,
    }

    -- State that survives a reload of this mod: persist("key", default) returns the same table every time.
    env.persist = function(key, default)
        if type(key) ~= "string" then error("persist expects a string key", 2) end
        local kept = mod.persistent[key]
        if kept == nil then
            kept = default == nil and {} or default
            mod.persistent[key] = kept
        end
        return kept
    end

    env.require = function(name)
        local path = type(name) == "table" and rawget(name, PATH)
        if path then name = path:gsub("/", ".") end
        if type(name) ~= "string" then
            error("require expects a file of this mod, such as mod.Utils or \"Utils\", got " .. type(name), 2)
        end
        return loader._require(mod, name, 2)
    end

    -- Globals the mod does not define itself come from the real global table (standard library, UE4SS).
    return setmetatable(env, { __index = _G })
end

local LOADING = {}

local function load_module(mod, name, path, chunkname)
    local text, err = read_file(path)
    if not text then return nil, ("cannot read %s: %s"):format(chunkname, tostring(err)) end
    local chunk, syntax_error = load(text, "@" .. chunkname, "t", mod.env)
    if not chunk then return nil, syntax_error end
    mod.modules[name] = LOADING
    local previous = scope.enter(mod.scope)
    guard.arm()
    local ok, value = xpcall(chunk, guard.handler, name)
    scope.leave(previous)
    if not ok then
        mod.modules[name] = nil
        return nil, value
    end
    if value == nil then value = true end
    mod.modules[name] = value
    return value
end

-- require from inside a mod. "@Other" gives another mod's exports. Anything else is a file in this mod.
function loader._require(mod, name, level)
    if name:sub(1, 1) == "@" then
        local other_id = name:sub(2)
        local other = mods[other_id]
        if not other then error(("mod '%s' is not installed (required by %s)"):format(other_id, mod.id), level + 1) end
        if not mod.depends[other_id] then
            error(("%s uses require(\"@%s\") but does not list \"%s\" under dependencies in its mod.lua")
                :format(mod.id, other_id, other_id), level + 1)
        end
        if other.status ~= "loaded" then
            error(("mod '%s' is not loaded (%s)"):format(other_id, other.error or other.status), level + 1)
        end
        return other.exports
    end
    local cached = mod.modules[name]
    if cached == LOADING then error(("circular require of '%s' in %s"):format(name, mod.id), level + 1) end
    if cached ~= nil then return cached end
    local relative = name:gsub("%.", "/")
    local chunkname = mod.id .. "/" .. relative .. ".lua"
    local path = mod.dir .. "/" .. relative .. ".lua"
    if not mod.files[relative .. ".lua"] then
        -- a folder module: sub/init.lua
        if mod.files[relative .. "/init.lua"] then
            path, chunkname = mod.dir .. "/" .. relative .. "/init.lua", mod.id .. "/" .. relative .. "/init.lua"
        else
            error(("module '%s' not found in %s (looked for %s.lua and %s/init.lua)"):format(name, mod.id, relative, relative), level + 1)
        end
    end
    local value, err = load_module(mod, name, path, chunkname)
    if value == nil then error(err, 0) end
    return value
end

-- loading and unloading one mod
local function unload(mod, reason)
    if mod.scope then
        local failures = mod.scope:destroy()
        for _, failure in ipairs(failures) do guard.report(failure, "cleanup of " .. mod.id, mod.scope) end
    end
    mod.scope, mod.env, mod.modules, mod.exports = nil, nil, {}, nil
    if mod.status == "loaded" then
        mod.status = "unloaded"
        core_log:info("%s unloaded%s", mod.id, reason and (" (" .. reason .. ")") or "")
    end
end

local function load_mod(mod)
    unload(mod)
    mod.error = nil
    for dependency in pairs(mod.depends) do
        local other = mods[dependency]
        if not other then
            mod.status, mod.error = "failed", ("needs mod '%s', which is not installed"):format(dependency)
            core_log:error("%s: %s", mod.id, mod.error)
            return false
        elseif other.status ~= "loaded" then
            mod.status, mod.error = "failed", ("needs mod '%s', which is not loaded"):format(dependency)
            core_log:error("%s: %s", mod.id, mod.error)
            return false
        end
    end
    mod.scope = scope.new(mod.id)
    mod.env = make_env(mod)
    mod.modules = {}
    local started = os.clock()
    local main = mod.manifest.main or "init.lua"
    local value, err = load_module(mod, "init", mod.dir .. "/" .. main, mod.id .. "/" .. main)
    if value == nil then
        guard.report(err, "loading " .. mod.id, mod.scope)
        unload(mod)
        mod.status, mod.error = "failed", tostring(err):match("^[^\r\n]*")
        return false
    end
    mod.exports = value
    mod.status = "loaded"
    mod.generation = mod.generation + 1
    mod.load_seconds = os.clock() - started
    guard.forget(mod.id)
    core_log:info("%s %s loaded in %.1f ms%s", mod.id, mod.manifest.version or "", mod.load_seconds * 1000,
        mod.generation > 1 and (" (reload #" .. (mod.generation - 1) .. ")") or "")
    return true
end

-- The ids of every mod, dependencies first.
local function sort_by_dependencies()
    local sorted, state = {}, {}
    local ids = {}
    for id in pairs(mods) do ids[#ids + 1] = id end
    -- the order the user gave comes first, then the alphabet. What a mod depends on still loads before it.
    switched_off()
    local place = {}
    for index, id in ipairs(type(preferences.order) == "table" and preferences.order or {}) do place[id] = index end
    table.sort(ids, function(a, b)
        local at_a, at_b = place[a] or math.huge, place[b] or math.huge
        if at_a ~= at_b then return at_a < at_b end
        return a < b
    end)
    local function visit(id, trail)
        if state[id] == "done" then return end
        if state[id] == "visiting" then
            core_log:error("dependency cycle: %s -> %s", table.concat(trail, " -> "), id)
            return
        end
        state[id] = "visiting"
        trail[#trail + 1] = id
        local dependencies = {}
        for dependency in pairs(mods[id].depends) do dependencies[#dependencies + 1] = dependency end
        table.sort(dependencies)
        for _, dependency in ipairs(dependencies) do
            if mods[dependency] then visit(dependency, trail) end
        end
        trail[#trail] = nil
        state[id] = "done"
        sorted[#sorted + 1] = id
    end
    for _, id in ipairs(ids) do visit(id, {}) end
    return sorted
end

local function dependents_of(id, found)
    found = found or {}
    for other_id, other in pairs(mods) do
        if other.depends[id] and not found[other_id] then
            found[other_id] = true
            dependents_of(other_id, found)
        end
    end
    return found
end

-- Finds mods, loads new ones and unloads removed ones. With hold_new, a mod not seen before is listed switched off instead.
function loader.sync(hold_new)
    pending_sync = false
    local held = {}
    local found, notes = discover.all()
    local current = {}
    for _, note in ipairs(notes) do
        if not noted[note] then core_log:warn("%s", note) end
        current[note] = true
    end
    noted = current
    watch.track(found)
    local seen, added, removed = {}, {}, {}
    for _, entry in ipairs(found) do
        seen[entry.id] = true
        local files = entry.files
        -- The manifest is optional. A mod with only an init.lua gets the defaults.
        local manifest, manifest_error = {}, nil
        if files["mod.lua"] then
            local loaded, err = load_data_file(entry.dir .. "/mod.lua")
            if loaded then manifest = loaded else manifest_error = "mod.lua: " .. tostring(err) end
        end
        local depends = {}
        if type(manifest.dependencies) == "table" then
            for _, dependency in ipairs(manifest.dependencies) do depends[dependency] = true end
        end
        local mod = mods[entry.id]
        if not mod then
            mod = { id = entry.id, status = "new", generation = 0, persistent = {}, modules = {} }
            mods[entry.id] = mod
            added[#added + 1] = entry.id
            if hold_new and not switched_off()[entry.id] then
                switched_off()[entry.id] = true
                storage.save("wax", "mods", preferences)
                mod.fresh = true
                held[#held + 1] = mod
            end
        end
        mod.dir, mod.manifest, mod.files, mod.depends = entry.dir, manifest, files, depends
        mod.enabled = not switched_off()[entry.id]
        mod.manifest_error = manifest_error
        if manifest_error then
            unload(mod, "broken manifest")
            mod.status, mod.error = "failed", manifest_error
            core_log:error("%s: %s", mod.id, manifest_error)
        end
    end
    for id, mod in pairs(mods) do
        if not seen[id] then
            unload(mod, "removed")
            mods[id] = nil
            removed[#removed + 1] = id
        end
    end
    for _, mod in ipairs(held) do
        core_log:info("%s found. It stays switched off until you enable it", mod.id)
        if loader.on_held then pcall(loader.on_held, mod.id, mod.manifest.name or mod.id) end
    end
    order = sort_by_dependencies()
    -- Load what is new, and retry what failed earlier (its missing dependency may have arrived since).
    for _, id in ipairs(order) do
        local mod = mods[id]
        if not mod.enabled then
            if mod.status ~= "disabled" then
                unload(mod, "switched off")
                mod.status, mod.error = "disabled", nil
                -- what depends on it loads again, and says what it is missing
                for dependent in pairs(dependents_of(id)) do pending[dependent] = true end
            end
        elseif mod.status ~= "loaded" and not mod.manifest_error then
            load_mod(mod)
        end
    end
    return { added = added, removed = removed, mods = loader.list() }
end

-- Reloads one mod and, after it, every mod that depends on it
function loader.reload(id)
    local mod = mods[id]
    if not mod then return false, ("no mod named '%s'"):format(tostring(id)) end
    local affected = dependents_of(id)
    affected[id] = true
    -- Unload dependents first (reverse load order), then load in load order.
    for i = #order, 1, -1 do
        if affected[order[i]] then unload(mods[order[i]], "reloading") end
    end
    local ok = true
    for _, other_id in ipairs(order) do
        if affected[other_id] and mods[other_id].enabled then ok = load_mod(mods[other_id]) and ok end
    end
    return ok
end

function loader.request_reload(id) pending[id] = true end

-- The first Lua file of a mod that does not compile, as "Id/file.lua:line: what is wrong", or nil when all do.
local function broken_file(mod)
    local names = {}
    for name in pairs(mod.files) do
        if name:find("%.lua$") and name ~= "mod.lua" then names[#names + 1] = name end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local chunk, problem = loadfile(mod.dir .. "/" .. name, "t")
        if not chunk then
            local where = tostring(problem):match("(:%d+: .*)$") or (": " .. tostring(problem))
            return mod.id .. "/" .. name .. (where:match("^[^\r\n]*"))
        end
    end
    return nil
end
-- hold_new as for loader.sync. A request without it wins over one with it.
function loader.request_sync(hold_new)
    if hold_new then pending_sync = pending_sync or "hold" else pending_sync = true end
end

-- Called once per frame by the core: runs the reloads that were requested since the last frame.
function loader.step()
    watch.step()
    if pending_sync then loader.sync(pending_sync == "hold") end
    if next(pending) then
        local batch = pending
        pending = {}
        -- look at the folders again first, so a file added since the last look is found
        loader.sync(true)
        for id in pairs(batch) do
            local mod = mods[id]
            -- a file saved half-typed does not take a running mod down: the version that runs stays until one compiles
            local problem = mod and mod.status == "loaded" and broken_file(mod)
            if problem then
                if mod.held_back ~= problem then
                    mod.held_back = problem
                    core_log:warn("%s was not reloaded: %s. The version that was running stays", id, problem)
                end
            elseif mod then
                mod.held_back = nil
                loader.reload(id)
            end
        end
    end
end

function loader.list()
    local out = {}
    for _, id in ipairs(order) do
        local mod = mods[id]
        out[#out + 1] = {
            id = id, name = mod.manifest.name or id, version = mod.manifest.version, status = mod.status, enabled = mod.enabled,
            fresh = mod.fresh, waiting = mod.held_back,
            error = mod.error, generation = mod.generation, owned = mod.scope and mod.scope:size() or 0,
            loadMs = mod.load_seconds and mod.load_seconds * 1000 or nil,
        }
    end
    return out
end

function loader.get(id) return mods[id] end

-- Switches a mod off (it unloads and stays off, also after restarting the game) or back on.
function loader.set_enabled(id, enabled)
    if not mods[id] then return false, ("no mod named '%s'"):format(tostring(id)) end
    switched_off()[id] = (not enabled) or nil
    if enabled then mods[id].fresh = nil end
    storage.save("wax", "mods", preferences)
    pending_sync = true
    return true
end

-- Moves a mod one place up (-1) or down (1) in the list. The order is kept, and is the order mods load in next time.
function loader.move(id, by)
    local at = nil
    for index, other in ipairs(order) do
        if other == id then at = index end
    end
    local to = at and at + by
    if not at or to < 1 or to > #order then return false end
    local wanted = table.move(order, 1, #order, 1, {})
    wanted[at], wanted[to] = wanted[to], wanted[at]
    switched_off()
    preferences.order = wanted
    storage.save("wax", "mods", preferences)
    order = sort_by_dependencies()
    return true
end

-- Takes a mod out: it unloads and its folder is renamed with a leading dot, so nothing is erased. Returns the new folder name.
function loader.remove(id)
    local mod = mods[id]
    if not mod then return nil, ("no mod named '%s'"):format(tostring(id)) end
    local parent = mod.dir:match("^(.*)/[^/]+$")
    if not parent then return nil, "the mod's folder could not be worked out" end
    unload(mod, "removed")
    local kept = (".removed-%s-%s"):format(id, os.date("%Y%m%d-%H%M%S"))
    local ok, problem = os.rename(mod.dir, parent .. "/" .. kept)
    if not ok then
        pending[id] = true
        return nil, ("the folder could not be renamed (%s)"):format(tostring(problem))
    end
    mods[id] = nil
    order = sort_by_dependencies()
    pending_sync = pending_sync or true
    return kept
end

-- The environment for debug console commands: a mod's usual globals, plus mods.<Id> and exports.<Id> for each mod.
function loader.console_env()
    local env = make_env({ id = "console", manifest = {}, dir = "", persistent = {}, modules = {} })
    env.require = function() error("require is for a mod's own files. Reach a loaded mod with mods.<Id>", 2) end
    local function view(field)
        return setmetatable({}, {
            __index = function(_, id) return mods[id] and mods[id][field] or nil end,
            __pairs = function()
                local id = nil
                return function()
                    local mod
                    repeat id, mod = next(mods, id) until id == nil or mod[field] ~= nil
                    return id, mod and mod[field]
                end
            end,
        })
    end
    env.mods, env.exports = view("env"), view("exports")
    return env
end

-- Reloading a mod when one of its files is saved. On by default.
function loader.set_watching(on) watch.set_enabled(on) end
function loader.watching() return watch.enabled() end
watch.on_change = function(id) pending[id] = true end

-- Adds a value to every mod's environment under `name` (used by other core modules to publish their API)
function loader.provide(name, value) extras[name] = value end

function loader.unload_all()
    for i = #order, 1, -1 do unload(mods[order[i]], "shutting down") end
    mods, order, pending = {}, {}, {}
end

return loader
