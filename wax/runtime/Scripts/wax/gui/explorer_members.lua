-- The Explorer's details: the rows for one object's members, what was last read of each, and which changed

local Wax = ...
local inspect = Wax.import("engine.inspect")

local M = {}

M.clock = os.clock
M.POLL = 8              -- properties read per frame to notice changes
M.RECENT = 2            -- seconds a changed value stays marked
M.ITEMS_EVERY = 0.5     -- seconds between two reads of an open array

M.MODES = { "All", "Properties", "Functions", "Changed", "Changed first" }

local function state_of(sheet, record)
    local state = sheet.state[record.name]
    if not state then
        state = {}
        sheet.state[record.name] = state
    end
    return state
end
M.state_of = state_of

local function differs(record, old, new)
    if type(old) ~= type(new) then return true end
    if type(new) ~= "table" then return old ~= new and (old == old or new == new) end
    if record.fields then
        for _, field in ipairs(record.fields) do
            if old[field] ~= new[field] then return true end
        end
        return false
    end
    return old.name ~= new.name or old.class ~= new.class
end

local function row(sheet, key, fields)
    local found = sheet.made[key]
    if not found then
        found = fields
        found.key = key
        sheet.made[key] = found
    end
    return found
end

-- A sheet for an object whose class has these members (from inspect.members) and this class chain.
function M.new(records, chain)
    local sheet = { records = records, chain = chain or {}, state = {}, made = {}, open = {}, mode = "All", words = {},
        polled = {}, poll_at = 1, rounds = 0, reads = 0, failed = 0, changed = 0, dirty = false,
        written = {} }      -- written[name] = true for a member that was changed from the page
    for _, record in ipairs(records) do
        if record.poll then sheet.polled[#sheet.polled + 1] = record end
    end
    return sheet
end

-- Reads a property now, unless it is of a kind that is never read or failed before. Returns what is known of it.
function M.read(sheet, inst, record)
    local state = state_of(sheet, record)
    if state.failed or not record.show then return state end
    local ok, value = inspect.read(inst, record)
    sheet.reads = sheet.reads + 1
    if not ok then
        state.failed, state.problem = true, value
        sheet.failed = sheet.failed + 1
        return state
    end
    if state.seen and differs(record, state.value, value) then
        if not state.changed_at then sheet.changed = sheet.changed + 1 end
        state.changed_at = M.clock()
        sheet.dirty = true
    end
    state.value, state.seen = value, true
    return state
end

-- The places of an open array, read again when what is known is old.
function M.items(sheet, inst, record)
    local state = state_of(sheet, record)
    local now = M.clock()
    if state.failed or (state.items and now - state.items_at < M.ITEMS_EVERY) then return state.items end
    local ok, found = inspect.elements(inst, record)
    sheet.reads = sheet.reads + 1
    if not ok then
        state.failed, state.problem = true, found
        sheet.failed = sheet.failed + 1
        return state.items
    end
    if state.items and #found.items ~= #state.items then sheet.dirty = true end
    state.items, state.items_at = found, now
    return found
end

-- Reads the next few of the simple properties, round and round, so a value that changes is noticed even while it is not in view.
function M.poll(sheet, inst, count)
    local polled = sheet.polled
    local total = #polled
    if total == 0 then return 0 end
    count = math.min(count or M.POLL, total)
    for _ = 1, count do
        if sheet.poll_at > total then sheet.poll_at, sheet.rounds = 1, sheet.rounds + 1 end
        M.read(sheet, inst, polled[sheet.poll_at])
        sheet.poll_at = sheet.poll_at + 1
    end
    return count
end

local function matches(record, words)
    for i = 1, #words do
        if not record.search:find(words[i], 1, true) then return false end
    end
    return true
end

-- Sets what is shown: one of M.MODES and the words every shown member has in its name or type.
-- With `lift`, what changed lately comes first whatever the mode.
function M.show(sheet, mode, text, lift)
    sheet.mode, sheet.words, sheet.lift = mode or sheet.mode, {}, lift and true or false
    for word in tostring(text or ""):lower():gmatch("%S+") do sheet.words[#sheet.words + 1] = word end
    sheet.dirty = true
end

-- The rows to show, in order. A row is { type, record, field, index, depth }, and the same row is handed out every time.
function M.rows(sheet)
    local rows, mode, words, state = {}, sheet.mode, sheet.words, sheet.state
    sheet.dirty = false
    if #words == 0 and (mode == "All" or mode == "Properties") and sheet.chain[1] then
        rows[1] = row(sheet, "#class", { type = "class", depth = 0 })
        if sheet.open["#class"] then
            for index = 2, #sheet.chain do
                rows[#rows + 1] = row(sheet, "#class" .. index, { type = "ancestor", name = sheet.chain[index], depth = 1 })
            end
        end
    end
    local first, rest = {}, {}
    local lift = sheet.lift or mode == "Changed" or mode == "Changed first"
    for _, record in ipairs(sheet.records) do
        local known = state[record.name]
        local wanted
        if mode == "Properties" or mode == "Changed first" then
            wanted = record.kind == "property"
        elseif mode == "Functions" then
            wanted = record.kind == "function"
        elseif mode == "Changed" then
            wanted = known ~= nil and known.changed_at ~= nil
        else
            wanted = true
        end
        if wanted and matches(record, words) then
            if lift and known and known.changed_at then
                first[#first + 1] = record
            else
                rest[#rest + 1] = record
            end
        end
    end
    -- the most recent change on top
    table.sort(first, function(a, b)
        local at_a, at_b = state[a.name].changed_at, state[b.name].changed_at
        if at_a ~= at_b then return at_a > at_b end
        return a.order < b.order
    end)
    for _, group in ipairs({ first, rest }) do
        for _, record in ipairs(group) do
            rows[#rows + 1] = row(sheet, record.name, { type = "member", record = record, depth = 0 })
            if sheet.open[record.name] then
                if record.show == "struct" then
                    for _, field in ipairs(record.fields) do
                        rows[#rows + 1] = row(sheet, record.name .. "." .. field, { type = "field", record = record, field = field, depth = 1 })
                    end
                elseif record.show == "array" then
                    local items = state[record.name] and state[record.name].items
                    local shown = items and #items.items or 0
                    for index = 1, shown do
                        rows[#rows + 1] = row(sheet, record.name .. "[" .. index .. "]", { type = "element", record = record, index = index, depth = 1 })
                    end
                    if items and items.total > shown then
                        local more = row(sheet, record.name .. "[+]", { type = "more", record = record, depth = 1 })
                        more.count = items.total - shown
                        rows[#rows + 1] = more
                    end
                end
            end
        end
    end
    return rows
end

local function signature(record)
    if record.signature == nil then
        local ok, params = pcall(inspect.parameters, record)
        local parts = {}
        for index, param in ipairs(ok and params or {}) do parts[index] = ("%s: %s"):format(param.name, param.label) end
        record.params = ok and params or {}
        record.signature = ok and ("(" .. table.concat(parts, ", ") .. ")") or "()"
    end
    return record.signature
end
M.signature = signature

-- True when the row has something under it: a struct's parts, or the places of an array that has some and whose places are read.
function M.opens(sheet, a_row)
    local record = a_row.record
    if a_row.type ~= "member" or not record then return false end
    if record.show == "struct" then return true end
    if record.show ~= "array" or not record.inner_show then return false end
    local state = sheet.state[record.name]
    return state ~= nil and state.seen == true and not state.failed and state.value ~= 0
end

-- How a row looks: { text, note, value, tone, faint, arrow, indent, flag } where flag is true or false for a row with a switch.
function M.look(sheet, a_row)
    local kind, record = a_row.type, a_row.record
    local out = { indent = a_row.depth }
    if kind == "class" then
        out.text, out.value, out.tone = "Class", sheet.chain[1], "dim"
        if #sheet.chain > 1 then out.arrow = sheet.open["#class"] and true or false end
        return out
    elseif kind == "ancestor" then
        out.text, out.value, out.tone, out.faint = "inherits", a_row.name, "dim", true
        return out
    elseif kind == "more" then
        out.text, out.faint = ("and %d more"):format(a_row.count or 0), true
        return out
    end
    local state = sheet.state[record.name] or {}
    local recent = state.changed_at and M.clock() - state.changed_at < M.RECENT
    -- a value changed from the page keeps a quiet mark of its own
    local settled = sheet.written[record.name] and "good" or "text"
    if kind == "member" then
        out.text, out.note = record.name, record.label
        if record.kind == "function" then
            out.note, out.value, out.tone = "", signature(record), "dim"
        elseif state.failed then
            out.value, out.tone = state.problem or "could not be read", "bad"
        elseif not record.show then
            out.value, out.tone, out.faint = "not shown", "dim", true
        elseif state.seen then
            out.value = inspect.text(record, state.value)
            if record.show == "bool" then out.flag = state.value end
            out.tone = recent and "warn" or (record.show == "object" and state.value and "accent_hover" or settled)
        end
        if M.opens(sheet, a_row) then out.arrow = sheet.open[record.name] and true or false end
    elseif kind == "field" then
        out.text, out.note = a_row.field, record.fields.whole and "byte" or "float"
        if state.failed then
            out.value, out.tone = state.problem or "could not be read", "bad"
        elseif state.seen then
            out.value, out.tone = inspect.text(record, state.value[a_row.field], true), recent and "warn" or settled
        end
    elseif kind == "element" then
        local item = state.items and state.items.items[a_row.index]
        out.text = ("[%d]"):format(a_row.index)
        if item ~= nil then
            out.value = inspect.text(record, item, true)
            out.tone = record.inner_show == "object" and item and "accent_hover" or "text"
        end
    end
    return out
end

-- True when pressing the row goes to another object.
function M.links(sheet, a_row)
    local record, state = a_row.record, a_row.record and sheet.state[a_row.record.name]
    if not record or not state then return false end
    if a_row.type == "member" then return record.show == "object" and state.seen and state.value ~= false end
    if a_row.type == "element" then
        local item = state.items and state.items.items[a_row.index]
        return record.inner_show == "object" and item ~= nil and item ~= false
    end
    return false
end

-- True when the row's value can be typed.
function M.editable(a_row)
    local record = a_row.record
    if not record or record.kind ~= "property" then return false end
    if a_row.type == "field" then return true end
    return a_row.type == "member" and record.edit == true and record.show ~= "struct"
end

return M
