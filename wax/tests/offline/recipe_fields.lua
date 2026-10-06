-- Prints what the Recipe Browser reads from the game's tables, one "Table<TAB>path" line per field.
-- A names-only table prints "Table<TAB>*names"; a MetaTable field prints "Table<TAB>*meta.path".
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\recipe_fields.lua luamods\RecipeBrowser

local folder = arg and arg[1]
if folder then folder = folder:gsub("\\", "/"):gsub("/+$", "") end

local chunk = folder and loadfile(folder .. "/source.lua")
if not chunk then
    io.stderr:write("recipe_fields: no source.lua in " .. tostring(folder) .. "\n")
    os.exit(2)
end

local source = chunk()
local order, fields, seen = {}, {}, {}
for _, entry in ipairs(source.lists(true)) do
    if not fields[entry.table] then
        fields[entry.table] = {}
        order[#order + 1] = entry.table
    end
    for _, field in ipairs(entry.fields) do
        local line = (entry.meta and "*meta." or "") .. field
        if not seen[entry.table .. "\t" .. line] then
            seen[entry.table .. "\t" .. line] = true
            fields[entry.table][#fields[entry.table] + 1] = line
        end
    end
end

for _, name in ipairs(order) do
    if #fields[name] == 0 then
        print(name .. "\t*names")
    else
        for _, line in ipairs(fields[name]) do print(name .. "\t" .. line) end
    end
end
