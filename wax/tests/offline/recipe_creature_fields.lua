-- Prints what the Recipe Browser's Bestiary reads from the game's tables, one "Table<TAB>path" line per field.
-- A field read only while game.Data serves it (a map or a curve) prints "Table<TAB>?path".
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\recipe_creature_fields.lua <mod folder>

-- With "items" after the folder it prints instead what the item model needs to be built: the fields source.lua
-- reads in its first two stages, and those of D_Stats.

local folder = arg and arg[1]
if folder then folder = folder:gsub("\\", "/"):gsub("/+$", "") end

local chunk = folder and loadfile(folder .. "/creatures.lua")
if not chunk then
    io.stderr:write("recipe_creature_fields: no creatures.lua in " .. tostring(folder) .. "\n")
    os.exit(2)
end

local creatures = chunk()
local seen = {}
local function say(name, line)
    if seen[name .. "\t" .. line] then return end
    seen[name .. "\t" .. line] = true
    print(name .. "\t" .. line)
end

if arg[2] == "items" then
    local source = assert(loadfile(folder .. "/source.lua"))()
    for _, entry in ipairs(source.lists(true)) do
        if not entry.meta and (entry.stage <= 2 or entry.table == "Stats") then
            if #entry.fields == 0 then say(entry.table, "*names") end
            for _, field in ipairs(entry.fields) do say(entry.table, field) end
        end
    end
    os.exit(0)
end

for _, entry in ipairs(creatures.TABLES) do
    if #entry.fields == 0 and not entry.maybe then say(entry.table, "*names") end
    for _, field in ipairs(entry.fields) do say(entry.table, field) end
    for _, field in ipairs(entry.maybe or {}) do say(entry.table, "?" .. field) end
end
