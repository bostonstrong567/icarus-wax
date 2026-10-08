-- Record of changes to the game's tables: what each field held before, and one layer a mod, in mod order

local M = {}

M.MAX_STEPS = 64        -- how many changes one mod may pile on one field before it has to Set or Reset

-- A real global: the game's tables keep what was written in them when the Wax core starts again.
local state = rawget(_G, "WaxDataJournal")
if type(state) ~= "table" or state.format ~= 1 then
    state = { format = 1, entries = {}, by_owner = {}, by_group = {}, rows = {}, counts = {}, told = {}, core = nil }
    rawset(_G, "WaxDataJournal", state)
end

local function link(index, name, key)
    local keys = index[name]
    if not keys then
        keys = {}
        index[name] = keys
    end
    keys[key] = true
end

local function unlink(index, name, key)
    local keys = index[name]
    if not keys then return end
    keys[key] = nil
    if next(keys) == nil then index[name] = nil end
end

local function layer_of(entry, owner)
    local layers = entry.layers
    for at = 1, #layers do
        if layers[at].owner == owner then return layers[at], at end
    end
    return nil
end
M.layer = layer_of

function M.find(key) return state.entries[key] end

-- The entry of a key. A new one keeps `original`, what the field held before anyone changed it. `group` is its table.
function M.open(key, group, info, original)
    local entry = state.entries[key]
    if entry then return entry, false end
    entry = { key = key, group = group, info = info, original = original, layers = {} }
    state.entries[key] = entry
    link(state.by_group, group, key)
    return entry, true
end

-- Forgets an entry and every layer on it. Nothing is written anywhere.
function M.close(entry)
    for _, layer in ipairs(entry.layers) do unlink(state.by_owner, layer.owner, entry.key) end
    entry.layers = {}
    if state.entries[entry.key] == entry then
        state.entries[entry.key] = nil
        unlink(state.by_group, entry.group, entry.key)
    end
end

-- Puts a step on owner's layer: { set = value } or a leaving layer starts it again, { change = fn } is added. Returns what restore() takes.
function M.push(entry, owner, step, rank)
    -- asked before the layers are looked at: the answer may come with a new order for them
    local place = rank and rank(owner) or math.huge
    local layer = layer_of(entry, owner)
    if layer then
        local token = { entry = entry, layer = layer, steps = layer.steps, leaving = layer.leaving }
        if layer.leaving or step.set ~= nil then
            layer.steps = { step }
        else
            local count = #layer.steps
            if count >= M.MAX_STEPS then return nil, "full" end
            local steps = table.move(layer.steps, 1, count, 1, {})
            steps[count + 1] = step
            layer.steps = steps
        end
        layer.leaving = false
        return token
    end
    layer = { owner = owner, steps = { step }, leaving = false, rank = place }
    local layers = entry.layers
    local at = #layers + 1
    for index = 1, #layers do
        if layers[index].rank > layer.rank then
            at = index
            break
        end
    end
    table.insert(layers, at, layer)
    link(state.by_owner, owner, entry.key)
    return { entry = entry, layer = layer, created = true }
end

-- Gives every layer of an entry its rank again and puts them in that order, equal ranks as they stood. True when a layer moved.
function M.rank(entry, rank)
    local layers, moved = entry.layers, false
    for at = 1, #layers do layers[at].rank = rank(layers[at].owner) end
    for at = 2, #layers do
        local layer, to = layers[at], at
        while to > 1 and layers[to - 1].rank > layer.rank do
            layers[to] = layers[to - 1]
            to = to - 1
        end
        if to ~= at then layers[to], moved = layer, true end
    end
    return moved
end

-- Takes back what one push did.
function M.restore(token)
    local entry, layer = token.entry, token.layer
    if token.created then
        local _, at = layer_of(entry, layer.owner)
        if at then table.remove(entry.layers, at) end
        unlink(state.by_owner, layer.owner, entry.key)
    else
        layer.steps, layer.leaving = token.steps, token.leaving
    end
end

-- Takes owner's layer off an entry. True when there was one, and what put_back() takes.
function M.remove(entry, owner)
    local layer, at = layer_of(entry, owner)
    if not layer then return false end
    table.remove(entry.layers, at)
    unlink(state.by_owner, owner, entry.key)
    return true, { { at = at, layer = layer } }
end

-- Puts layers that remove() or drop_leaving() took back where they stood.
function M.put_back(entry, taken)
    if state.entries[entry.key] ~= entry then return end
    local layers = entry.layers
    for index = 1, #taken do
        local layer = taken[index].layer
        if not layer_of(entry, layer.owner) then
            table.insert(layers, math.min(taken[index].at, #layers + 1), layer)
            link(state.by_owner, layer.owner, entry.key)
        end
    end
end

-- Marks every layer and every row of owner as leaving. Returns the keys of the layers, sorted, and the rows.
function M.leave(owner)
    local keys, rows = {}, {}
    for key in pairs(state.by_owner[owner] or {}) do
        local entry = state.entries[key]
        local layer = entry and layer_of(entry, owner)
        if layer then
            layer.leaving = true
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    for _, row in pairs(state.rows) do
        if row.owner == owner and not row.retired then
            row.leaving = true
            rows[#rows + 1] = row
        end
    end
    return keys, rows
end

-- Takes off the layers of an entry that are still leaving, but not those of an owner `keep` says yes to. Returns how many went, and what put_back() takes.
function M.drop_leaving(entry, keep)
    local layers, dropped, taken = entry.layers, 0, {}
    for at = #layers, 1, -1 do
        local layer = layers[at]
        if layer.leaving and not (keep and keep(layer.owner)) then
            unlink(state.by_owner, layer.owner, entry.key)
            table.remove(layers, at)
            dropped = dropped + 1
            table.insert(taken, 1, { at = at, layer = layer })
        end
    end
    return dropped, taken
end

-- What the layers make of the original, bottom to top, and { used, covered } when a Set hides another mod's different result.
function M.result(entry, copy, run, same)
    local layers = entry.layers
    local value, conflict, started = nil, nil, false
    local within = {}       -- the mods whose change is in `value`
    for index = 1, #layers do
        local layer = layers[index]
        local steps = layer.steps
        local first, from = steps[1], 1
        if first.set ~= nil then
            if not layer.quiet and #within > 0 and not same(value, first.set) then
                conflict = conflict or { covered = {} }
                conflict.used = layer.owner
                for at = 1, #within do conflict.covered[#conflict.covered + 1] = within[at] end
                within = {}
            end
            value, started, from = copy(first.set), true, 2
        elseif not started then
            value, started = copy(entry.original), true
        end
        for at = from, #steps do
            local made = run(layer, steps[at], value)
            if made ~= nil then value = made end
        end
        if not layer.leaving and not layer.quiet then within[#within + 1] = layer.owner end
    end
    if not started then value = copy(entry.original) end
    return value, conflict
end

-- Every entry, or those of one table, sorted by key.
function M.entries(group)
    local out = {}
    if group then
        for key in pairs(state.by_group[group] or {}) do out[#out + 1] = state.entries[key] end
    else
        for _, entry in pairs(state.entries) do out[#out + 1] = entry end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- The entries of one table whose key begins with `prefix`, in no order.
function M.under(group, prefix)
    local out, length = {}, #prefix
    for key in pairs(state.by_group[group] or {}) do
        if key:sub(1, length) == prefix then out[#out + 1] = state.entries[key] end
    end
    return out
end

-- The keys that have a layer on its way out or a put-back still owed, sorted.
function M.pending()
    local keys = {}
    for key, entry in pairs(state.entries) do
        local due = entry.owed == true
        for at = 1, #entry.layers do
            if entry.layers[at].leaving then due = true end
        end
        if due then keys[#keys + 1] = key end
    end
    table.sort(keys)
    return keys
end

-- Everyone who has a layer somewhere or a row that is not switched off, sorted.
function M.owners()
    local seen, out = {}, {}
    for owner in pairs(state.by_owner) do seen[owner] = true end
    for _, row in pairs(state.rows) do
        if not row.retired then seen[row.owner] = true end
    end
    for owner in pairs(seen) do out[#out + 1] = owner end
    table.sort(out)
    return out
end

-- The tables that have an entry.
function M.groups()
    local out = {}
    for group in pairs(state.by_group) do out[#out + 1] = group end
    table.sort(out)
    return out
end

-- Rows that mods added. They are kept here because the game keeps them until it closes.
function M.row(key) return state.rows[key] end

function M.add_row(key, info)
    info.key = key
    state.rows[key] = info
    return info
end

function M.remove_row(key) state.rows[key] = nil end

-- Every added row, or those of one table, sorted by key.
function M.rows(group)
    local out = {}
    for _, row in pairs(state.rows) do
        if not group or row.group == group then out[#out + 1] = row end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- How often a table was changed. It only goes up.
function M.bump(group)
    state.counts[group] = (state.counts[group] or 0) + 1
    return state.counts[group]
end

function M.count(group) return state.counts[group] or 0 end

-- True the first time an id is asked about, so a thing is said once.
function M.first(id)
    if state.told[id] then return false end
    state.told[id] = true
    return true
end

-- The names of enums, learnt from the game. They hold while the game runs, so they are kept across cores.
function M.enums()
    state.enums = state.enums or {}
    return state.enums
end

-- Called by the core that starts: the mods of the core before are gone, so their layers are leaving. A layer that switches a row off stays.
function M.adopt(core)
    if state.core == core then return {}, {} end
    local keys, rows = {}, {}
    if state.core ~= nil then
        for key, entry in pairs(state.entries) do
            local other = false
            for _, layer in ipairs(entry.layers) do
                if not layer.quiet then
                    layer.leaving = true
                    other = true
                end
            end
            if not other then entry.applied = nil end
            keys[#keys + 1] = key
        end
        table.sort(keys)
        for _, row in pairs(state.rows) do
            if not row.retired then
                row.leaving = true
                rows[#rows + 1] = row
            end
        end
    end
    state.core = core
    return keys, rows
end

function M.stats()
    local out = { entries = 0, layers = 0, rows = 0, owners = 0, tables = 0 }
    for _, entry in pairs(state.entries) do
        out.entries = out.entries + 1
        out.layers = out.layers + #entry.layers
    end
    for _ in pairs(state.rows) do out.rows = out.rows + 1 end
    for _ in pairs(state.by_owner) do out.owners = out.owners + 1 end
    for _ in pairs(state.by_group) do out.tables = out.tables + 1 end
    return out
end

-- Forgets everything without writing anything. For tests.
function M.clear()
    state.entries, state.by_owner, state.by_group, state.rows, state.counts, state.told, state.core = {}, {}, {}, {}, {}, {}, nil
end

return M
