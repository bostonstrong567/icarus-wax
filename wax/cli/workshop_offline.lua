-- The part of workshop.mjs that needs no running game: lua workshop_offline.lua <workspace> <rows.lua> list [category] | check [store.lua] [mod id] [name] [folder]

local cli = {}

local function count(number, one, many)
    return ("%d %s"):format(number, number == 1 and one or many)
end

-- A price as text, in the order the game lists its currencies: "150 Credits, 50 Exotic1".
local function price(cost, currencies)
    local parts = {}
    for _, currency in ipairs(currencies) do
        if cost[currency.Id] then parts[#parts + 1] = ("%s %s"):format(tostring(cost[currency.Id]), currency.Id) end
    end
    if #parts == 0 then return "nothing" end
    return table.concat(parts, ", ")
end

-- The store as the rows have it: every category, or the nodes of one.
function cli.list(store, category)
    local lines = {}
    local categories = store.categories()
    if category == nil then
        lines[1] = ("The store: %s, %s"):format(count(#categories, "category", "categories"), count(#store.nodes(), "node", "nodes"))
        lines[2] = ""
        for _, found in ipairs(categories) do
            lines[#lines + 1] = ("  %-30s %-22s %s"):format(found.Id, found.Name, count(#store.nodes(found.Id), "node", "nodes"))
        end
        return lines
    end
    local found = store.category(category)
    if not found then
        local suggest = cli.suggest
        return nil, ("The store has no category named '%s'.%s"):format(category, suggest and suggest.phrase(category, store.names("category")) or "")
    end
    local nodes, currencies = store.nodes(found.Id), store.currencies()
    lines[1] = ("%s (%s): %s"):format(found.Id, found.Name, count(#nodes, "node", "nodes"))
    for _, node in ipairs(nodes) do
        lines[#lines + 1] = ""
        local facts = { ("at %s, %s"):format(tostring(node.At.X), tostring(node.At.Y)) }
        if node.Joint then
            lines[#lines + 1] = ("  %-34s a joint: it shows nothing and passes its parents on"):format(node.Id)
        else
            lines[#lines + 1] = ("  %-34s %s"):format(node.Id, node.Name or node.Gives or "nothing")
            table.insert(facts, 1, "replicate " .. price(node.Replicate, currencies))
            table.insert(facts, 1, "research " .. price(node.Research, currencies))
        end
        if node.Line then facts[#facts + 1] = "line " .. node.Line end
        if node.Free and not node.Joint then facts[#facts + 1] = "free" end
        lines[#lines + 1] = "      " .. table.concat(facts, "   ")
        if #node.Needs > 0 then
            lines[#lines + 1] = "      needs " .. (#node.Needs > 1 and "one of " or "") .. table.concat(node.Needs, ", ")
        end
        if #node.Flags > 0 then
            local flags = {}
            for at, flag in ipairs(node.Flags) do flags[at] = flag.Kind and ("%s (%s)"):format(flag.Id, flag.Kind) or flag.Id end
            lines[#lines + 1] = "      asks for " .. table.concat(flags, ", ")
        end
    end
    return lines
end

-- A list of problems as lines. `what` names what was checked.
function cli.report(what, problems)
    local errors, warnings = 0, 0
    for _, problem in ipairs(problems) do
        if problem.Level == "error" then errors = errors + 1 else warnings = warnings + 1 end
    end
    if #problems == 0 then return { what .. ": nothing wrong." }, 0 end
    local lines = { ("%s: %s, %s"):format(what, count(errors, "error", "errors"), count(warnings, "warning", "warnings")), "" }
    for _, problem in ipairs(problems) do
        lines[#lines + 1] = ("  %-8s %s"):format(problem.Level, problem.Text)
    end
    return lines, errors
end

-- The table a store file returns. The file sees Lua's own libraries and nothing of the game.
function cli.read(path)
    local env = { math = math, string = string, table = table, pairs = pairs, ipairs = ipairs, next = next, select = select,
        tostring = tostring, tonumber = tonumber, type = type }
    local chunk, problem = loadfile(path, "t", env)
    if not chunk then return nil, ("%s does not load: %s"):format(path, tostring(problem)) end
    local ok, described = pcall(chunk)
    if not ok then return nil, ("%s stopped with an error: %s"):format(path, tostring(described)) end
    if type(described) ~= "table" then
        return nil, ("%s has to return the store as a table, such as return { categories = { ... } }"):format(path)
    end
    return described
end

-- What the plan is told of the mod: its id, and with "folder" that the id is the name of the folder the store file is in.
function cli.options(mod, from)
    if mod == "" then mod = nil end
    return { mod = mod, folder = mod ~= nil and from == "folder" }
end

-- The store's logic over rows in a file. Returns the modules it took and the store.
function cli.open(root, rows_path)
    local Wax = dofile(root .. "/wax/runtime/Scripts/wax/loader.lua")(root .. "/wax/runtime")
    local workshop = Wax.import("world.workshop")
    cli.suggest = Wax.import("core.suggest")
    return { Wax = Wax, workshop = workshop, spec = Wax.import("world.workshop_spec"), check = Wax.import("world.workshop_check"),
        store = workshop.reader(workshop.plain(dofile(rows_path))) }
end

local function main(root, rows_path, command, first, second, shown, from)
    local opened = cli.open(root, rows_path)
    local lines, failed
    if command == "list" then
        lines, failed = cli.list(opened.store, first)
        if not lines then
            io.stderr:write(failed, "\n")
            return 1
        end
        failed = 0
    elseif command == "check" and first == nil then
        lines, failed = cli.report("The game's own store", opened.check.store(opened.store))
        failed = 0
    elseif command == "check" then
        local described, problem = cli.read(first)
        if not described then
            io.stderr:write(problem, "\n")
            return 1
        end
        lines, failed = cli.report(shown or first, opened.spec.compile(described, opened.store, cli.options(second, from)).problems)
    else
        io.stderr:write("unknown command: ", tostring(command), "\n")
        return 2
    end
    print(table.concat(lines, "\n"))
    return failed > 0 and 1 or 0
end

if arg and arg[0] and arg[0]:gsub("\\", "/"):find("workshop_offline%.lua$") then os.exit(main(table.unpack(arg, 1, 7))) end

return cli
