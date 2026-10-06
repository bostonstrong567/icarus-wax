-- Compiles every Lua file named in a list (one path per line) without running it

local list = assert(io.open(arg[1], "rb"))
local checked, failed = 0, 0
for line in list:lines() do
    local path = line:gsub("\r$", "")
    if path ~= "" then
        checked = checked + 1
        local chunk, err = loadfile(path)
        if not chunk then
            failed = failed + 1
            print("FAIL " .. tostring(err))
        end
    end
end
list:close()
print(("%d Lua files compiled, %d failed"):format(checked, failed))
os.exit(failed == 0 and checked > 0)
