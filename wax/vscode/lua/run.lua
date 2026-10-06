-- Runs Lua sent from the editor: as its mod when the file belongs to a loaded one, otherwise like the in-game console
local source, chunkname, mod_id, fresh, as_expression = ...
if not (rawget(_G, "Wax") and Wax.mods and Wax.task) then error("Wax is not running in the game", 0) end

local scope = Wax.import("core.scope")
local editor = Wax.editor
if not editor then
    editor = { scopes = {} }
    Wax.editor = editor
end

local target = mod_id and Wax.mods.get(mod_id) or nil
local env = target and target.env or nil
if not env then
    target = nil
    editor.env = editor.env or Wax.mods.console_env()
    env = editor.env
end
local ran_as = target and mod_id or "console"

local chunk, problem
if as_expression then chunk = load("return " .. source, "@" .. chunkname, "t", env) end
if not chunk then chunk, problem = load(source, "@" .. chunkname, "t", env) end
if not chunk then return { ok = false, error = tostring(problem), as = ran_as } end

-- what an earlier run of the same file set up goes first, as when a mod reloads
local owner = editor.scopes[chunkname]
if owner and (fresh or not owner.alive) then
    owner:destroy()
    owner = nil
end
if not owner then
    owner = scope.new(ran_as, target and target.scope or nil)
    editor.scopes[chunkname] = owner
end

local function describe(value, inside)
    local kind = type(value)
    if kind == "string" then
        local text = #value > 2000 and value:sub(1, 1997) .. "..." or value
        return inside and ("%q"):format(text) or text
    elseif kind ~= "table" then
        local ok, text = pcall(tostring, value)
        return ok and text or "(" .. kind .. ")"
    end
    local meta = getmetatable(value)
    if (meta and meta.__tostring) or inside then
        local ok, text = pcall(tostring, value)
        return ok and (meta and meta.__tostring and text or "{...}") or "{...}"
    end
    local parts, count = {}, 0
    for key, item in pairs(value) do
        count = count + 1
        if count <= 24 then
            parts[count] = (type(key) == "string" and key or "[" .. tostring(key) .. "]") .. " = " .. describe(item, true)
        end
    end
    if count > 24 then parts[25] = ("... %d more"):format(count - 24) end
    return count == 0 and "{}" or "{ " .. table.concat(parts, ", ") .. " }"
end

-- as a task, so the code may wait; once it has waited, an error can only go to the log
local finished, waited = nil, false
local previous = scope.enter(owner)
Wax.task.spawn(function()
    local results = table.pack(xpcall(chunk, function(err) return debug.traceback(tostring(err), 2) end))
    if not waited then
        finished = results
    elseif not results[1] then
        Wax.guard.report(results[2], "run " .. chunkname, owner)
    end
end)
scope.leave(previous)
waited = true

if not finished then return { ok = true, waiting = true, as = ran_as, kept = owner:size() } end
if not finished[1] then return { ok = false, error = tostring(finished[2]), as = ran_as, kept = owner:size() } end
local values = {}
for index = 2, finished.n do values[#values + 1] = describe(finished[index]) end
return { ok = true, values = values, as = ran_as, kept = owner:size() }
