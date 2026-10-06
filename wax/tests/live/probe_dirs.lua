-- Probe: can the game list folders itself (UE4SS's own directory table), and what does it cost?
local now = Wax.perf.now
local out = {}
local started = now()
local dirs = IterateGameDirectories()
out.build_ms = (now() - started) * 1000
out.type = type(dirs)

local function step(node, name)
    if node == nil then return nil end
    local ok, child = pcall(function() return node[name] end)
    return ok and child or nil
end

started = now()
local node = dirs
local reached = {}
for _, name in ipairs({ "Game", "Binaries", "Win64", "ue4ss", "Mods", "Wax" }) do
    node = step(node, name)
    reached[#reached + 1] = name .. "=" .. type(node)
    if node == nil then break end
end
out.walk_ms = (now() - started) * 1000
out.reached = reached
if type(node) == "table" then
    out.name = node.__name
    out.path = node.__absolute_path
    local children = {}
    for key, value in pairs(node) do children[#children + 1] = tostring(key) .. ":" .. type(value) end
    out.children = children
    local scripts = step(node, "Scripts")
    if type(scripts) == "table" then
        started = now()
        local files = {}
        local list = scripts.__files
        for i = 1, #list do files[#files + 1] = list[i].__name end
        out.files_ms = (now() - started) * 1000
        out.script_files = files
    end
end
return out
