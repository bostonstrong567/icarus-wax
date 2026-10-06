-- The Explorer page: what is in the game as a tree, the picked object's members beside it, and every change as Lua

local Wax = ...
local index = Wax.import("gui.explorer_index")
local paths = Wax.import("gui.explorer_path")
local members = Wax.import("gui.explorer_members")
local inspect = Wax.import("engine.inspect")
local instance = Wax.import("engine.instance")
local game = Wax.import("engine.game").root
local sched = Wax.import("core.sched")
local guard = Wax.import("core.guard")

local M = {}

M.clock = os.clock
M.VISIBLE = 4           -- rows of the details whose values are read again each frame
M.TREE_EVERY = 0.25     -- seconds between two rebuilds of the tree's rows
M.ROWS_EVERY = 0.5      -- and of the details' rows
M.ROOTS_EVERY = 1       -- seconds between looks at game.Character, game.GameState and the others
M.KIDS_EVERY = 1.5      -- an open row's children are read again this often, one row at a time
M.HISTORY, M.CHANGES = 20, 200

local ROW, GAP = 26, 1
local ICONS = { player = "user", creature = "paw-print", building = "hammer", item = "package", actor = "box",
    component = "puzzle", widget = "app-window", object = "circle-dot", world = "globe" }
local KINDS = { { "Actors", "actors" }, { "Creatures", "creature" }, { "Players", "player" }, { "Items", "item" },
    { "Buildings", "building" }, { "Components", "components" }, { "Everything", "everything" } }
local SORTS = { { "By name", "name" }, { "By class", "class" }, { "Nearest first", "distance" }, { "Newest first", "newest" } }
local RANGES = { { "Any distance", false }, { "Within 25 m", 25 }, { "Within 50 m", 50 }, { "Within 100 m", 100 },
    { "Within 250 m", 250 }, { "Within 500 m", 500 } }
local SHOWS = { "Properties", "Functions", "All", "Changed" }
local ORDERS = { "By name", "Changed first" }
local NAME_SHARE = 0.44     -- of a details line: where the names end and the values start

local view = nil        -- what belongs to the page that is built now
local changes = {}      -- one line of Lua for every change made here, oldest first
local settings = { text = "", kind = "actors", sort = "name", near = false, range = 50 }

-- A page from an earlier load of this file is stopped before this one takes over.
if Wax.explorer_stop then pcall(Wax.explorer_stop) end

local function labels(pairs_list)
    local out = {}
    for index_, pair in ipairs(pairs_list) do out[index_] = pair[1] end
    return out
end

local function pick(pairs_list, wanted, by)
    for _, pair in ipairs(pairs_list) do
        if pair[by] == wanted then return pair[by == 1 and 2 or 1] end
    end
    return nil
end

local function filtering() return settings.text:find("%S") ~= nil or settings.kind ~= "actors" or settings.near end

local function apply_query()
    index.query({ text = settings.text, kind = settings.kind, sort = settings.sort, near = settings.near and settings.range or nil })
end

-- Puts text on the clipboard and shows a tick on the button for a moment.
local function copy(button, icon, text)
    if not text or text == "" then return end
    Wax.ui.Copy(text)
    button:SetIcon("check")
    sched.task.delay(1.2, function()
        if not button.destroyed then button:SetIcon(icon) end
    end)
end

-- the selection

-- What is picked is kept as an Instance only if it is an actor or a component of one. Anything else is found again by its path.
local function target_for(inst, path)
    local ok, owned = pcall(inspect.owned, inst)
    if ok and owned then return { instance = inst, path = path } end
    if path then return { path = path } end
    return nil
end

local refresh_rows, show_edit, show_changes

local function adopt(v, inst)
    local picked = v.picked
    picked.address, picked.class_name = inst and instance.address(inst) or nil, inst and inst.ClassName or nil
    v.member = nil
    if not inst then
        v.sheet = nil
        v.name:Set(picked.name and (picked.name .. " is gone") or "Nothing there right now")
        refresh_rows(v, true)
        show_edit(v)
        return
    end
    picked.name = inst.Name
    local ok, list = pcall(inspect.members, inst)
    v.sheet = members.new(ok and list or {}, inst:GetClassChain())
    members.show(v.sheet, v.mode, v.member_text, v.order_by == ORDERS[2])
    local found, code = pcall(paths.expression, inst, picked.path, index.unique)
    picked.code = found and code or nil
    v.name:Set(picked.name)
    v.path:Set(picked.code or "")
    refresh_rows(v, true)
    show_edit(v)
end

-- The picked object as it is in this frame, or nil. It is found once per frame and never used in a later one.
local function current(v)
    local picked = v.picked
    if not picked then return nil end
    if picked.frame == v.frame then return picked.now end
    local inst = nil
    if picked.instance then
        if picked.instance:IsValid() then inst = picked.instance end
    else
        inst = paths.resolve(picked.path)
    end
    picked.frame, picked.now = v.frame, inst
    local address = inst and instance.address(inst) or nil
    if address ~= picked.address or (inst and inst.ClassName ~= picked.class_name) then
        local ok, problem = pcall(adopt, v, inst)
        if not ok then guard.report(tostring(problem), "explorer.adopt") end
    end
    return inst
end

local function select(v, target, remember)
    if not target then return end
    local before = v.picked
    if remember and before then
        v.history[#v.history + 1] = { instance = before.instance, path = before.path }
        if #v.history > M.HISTORY then table.remove(v.history, 1) end
    end
    v.picked = { instance = target.instance, path = target.path, address = false }
    v.previous:SetEnabled(#v.history > 0)
    v.copy_path:SetEnabled(true)
    current(v)
    if v.split:IsSingle() then v.split:Show("right") end
    v.tree:Refresh()
end

local function go_back(v)
    local target = table.remove(v.history)
    if target then select(v, target, false) end
end

-- the tree

local function instance_of(row)
    if row.root then return paths.root(row.root) end
    return row.instance
end

local function arrow_of(row)
    if row.root == "World" then return (row.open or filtering()) and true or false end
    if row.missing or row.gone then return nil end
    if row.kids and #row.kids == 0 then return nil end
    if row.branches == nil then row.branches = row.instance:IsA("Actor") or row.instance:IsA("SceneComponent") end
    if not row.branches then return nil end
    return row.open and true or false
end

local function tree_look(v, row)
    local picked = v.picked
    return { text = row.name, note = row.note or row.class_name, icon = ICONS[row.kind] or ICONS.object, indent = row.depth,
        arrow = arrow_of(row), faint = row.missing or row.gone or false,
        selected = picked ~= nil and picked.address ~= nil and picked.address ~= false and row.address == picked.address }
end

local function by_name(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.address < b.address
end

-- The rows under an open row: what GetChildren gives now. A row that was there before is kept, with what was open under it.
local function children(row, inst)
    local ok, found = pcall(inst.GetChildren, inst)
    if not ok then return {} end
    local before = {}
    for _, kid in ipairs(row.kids or {}) do before[kid.address] = kid end
    local kids = {}
    for _, child in ipairs(found) do
        local address = instance.address(child)
        local kid = before[address]
        if not (kid and rawequal(kid.instance, child)) then
            local named, name = pcall(function() return child.Name end)
            local known, kind = pcall(inspect.kind, child)
            kid = { instance = child, address = address, name = named and name or "?", class_name = child.ClassName,
                kind = known and kind or "object", depth = row.depth + 1 }
            kid.order = kid.name:lower()
        end
        kids[#kids + 1] = kid
    end
    table.sort(kids, by_name)
    return kids
end

local function rebuild_tree(v)
    local flat, opened = {}, {}
    local function add(row)
        flat[#flat + 1] = row
        if row.open and row.kids then
            opened[#opened + 1] = row
            for _, kid in ipairs(row.kids) do add(kid) end
        end
    end
    local narrowed = filtering()
    if not narrowed then
        for _, row in ipairs(v.roots) do
            if row.root ~= "World" then add(row) end
        end
    end
    local world = v.world
    flat[#flat + 1] = world
    local results = index.results()
    if world.open or narrowed then
        for i = 1, #results do
            local entry = results[i]
            if not entry.gone then
                if entry.open then add(entry) else flat[#flat + 1] = entry end
            end
        end
    end
    local actors = index.counts()
    world.note = narrowed and ("%d of %d fit"):format(#results, actors) or ("%d actors"):format(actors)
    local text = index.seeding() and ("Finding what is in the world: %d so far."):format(actors)
        or narrowed and ("%d of %d actors fit."):format(#results, actors)
        or ("%d actors in this world."):format(actors)
    if text ~= v.summary then
        v.summary = text
        v.count:Set(text)
    end
    v.flat, v.opened, v.tree_dirty = flat, opened, false
    v.tree:SetItems(flat, true)
end

-- Looks at what game.Character and the other roots are now. Nothing is kept of them but names and an address to compare.
local function look_at_roots(v)
    for _, row in ipairs(v.roots) do
        local inst = paths.root(row.root)
        local address = inst and instance.address(inst) or nil
        if address ~= row.address then
            row.address, row.missing, v.tree_dirty = address, inst == nil, true
            row.class_name = inst and inst.ClassName or "none"
            row.branches = inst ~= nil and row.root ~= "World" and (inst:IsA("Actor") or inst:IsA("SceneComponent"))
            if row.root ~= "World" then
                local ok, kind = pcall(inspect.kind, inst)
                row.kind = inst and ok and kind or "object"
                row.kids, row.open = nil, false
            end
        end
    end
end

-- One open row at a time has its children read again, so what was added or destroyed under it shows.
local function look_at_kids(v)
    local opened = v.opened
    if #opened == 0 then return end
    v.kid_at = v.kid_at % #opened + 1
    local row = opened[v.kid_at]
    if row.gone or row.missing or row.root == "World" then return end
    local inst = instance_of(row)
    if not inst or not inst:IsValid() then
        row.kids, row.open, v.tree_dirty = nil, false, true
        return
    end
    local kids = children(row, inst)
    local same = #kids == #row.kids
    for i = 1, same and #kids or 0 do
        if kids[i] ~= row.kids[i] then same = false end
    end
    row.kids = kids
    if not same then v.tree_dirty = true end
end

local function press_tree(v, made)
    local row = made.row
    if not row or row.missing or row.gone then return end
    if row.root then return select(v, { path = paths.from_root(row.root) }, true) end
    select(v, target_for(row.instance, nil), true)
end

local function open_tree(v, made)
    local row = made.row
    if not row or row.missing or row.gone then return end
    if row.open then
        row.open = false
    elseif row.root == "World" then
        row.open = true
    else
        local inst = instance_of(row)
        if not inst then return end
        row.kids, row.open = children(row, inst), true
    end
    v.tree_dirty, v.tree_due = true, 0
end

-- Closes every open row but the world's.
local function fold_all(v)
    for _, row in ipairs(v.opened) do
        if row.root ~= "World" then row.open = false end
    end
    v.tree_dirty, v.tree_due = true, 0
end

-- Both sides are laid out alike, so they line up: a heading with its buttons, one small line, a search box,
-- two choices side by side, the list, and one line under it.
local function build_tree(v, side)
    local theme = Wax.import("gui.style").theme
    local head = side:Row()
    v.title = head:Heading("Explorer")
    v.fold = head:Button(nil, function() fold_all(v) end, { icon = "chevrons-down-up" })
    v.count = side:Label("", { size = theme.small_size, dim = true })
    v.search = side:Input(nil, { hint = "Search by name or class" })
    v.search.Typed:Connect(function(text)
        settings.text = text
        apply_query()
        v.tree_dirty = true
    end)
    local filters = side:Row()
    v.kind = filters:Dropdown(nil, labels(KINDS), pick(KINDS, settings.kind, 2), function(choice)
        settings.kind = pick(KINDS, choice, 1)
        apply_query()
        v.tree_dirty = true
    end)
    v.sort = filters:Dropdown(nil, labels(SORTS), pick(SORTS, settings.sort, 2), function(choice)
        settings.sort = pick(SORTS, choice, 1)
        apply_query()
    end)
    v.tree = side:Grid({ cell = 100000, cell_height = ROW, gap = GAP, batch = 3,
        make = function(cell)
            local made = {}
            made.line = cell:Item({}, function() press_tree(v, made) end, function() open_tree(v, made) end)
            v.tree_cells[#v.tree_cells + 1] = made
            return made
        end,
        show = function(made, row)
            made.row = row
            made.line:Set(tree_look(v, row))
        end })
    local foot = side:Row()
    foot:Label("How far from you", { dim = true })
    v.range = foot:Dropdown(nil, labels(RANGES), pick(RANGES, settings.near and settings.range or false, 2), function(choice)
        local metres = pick(RANGES, choice, 1)
        settings.near = metres ~= false
        if metres then settings.range = metres end
        apply_query()
        v.tree_dirty = true
    end)
    for _, name in ipairs(paths.ROOTS) do
        local row = { root = name, name = name, class_name = "none", kind = name == "World" and "world" or "object", depth = 0,
            missing = true, address = false, open = name == "World" }
        v.roots[#v.roots + 1] = row
        if name == "World" then v.world = row end
    end
end

-- the details

local function member_name(a_row)
    local record = a_row.record
    if a_row.type == "field" then return ("%s.%s"):format(record.name, a_row.field), record.fields.whole and "byte" or "float" end
    if a_row.type == "element" then return ("%s[%d]"):format(record.name, a_row.index), "" end
    return record.name, record.label
end

-- What the box for typing shows for the picked member: the whole value, not the shortened one a row shows.
local function edit_text(v)
    local a_row, sheet = v.member, v.sheet
    if not (a_row and sheet and a_row.record) then return "" end
    local record, state = a_row.record, sheet.state[a_row.record.name]
    if not state or not state.seen or state.failed then return "" end
    if a_row.type == "field" then return inspect.text(record, state.value[a_row.field], true) end
    if a_row.type ~= "member" or record.show == "struct" or record.show == "array" or record.show == "object" then return "" end
    if type(state.value) == "string" then return state.value end
    return inspect.text(record, state.value)
end

function show_edit(v)
    local a_row = v.member
    if not (a_row and v.sheet) then
        v.edit_name:Set(v.sheet and "Pick a member" or "")
        v.edit:Set("")
        v.edit_shown = ""
        v.edit:SetEnabled(false)
        v.code:SetEnabled(false)
        return
    end
    local name, kind = member_name(a_row)
    v.edit_name:Set(kind ~= "" and ("%s  (%s)"):format(name, kind) or name)
    v.edit_shown = edit_text(v)
    v.edit:Set(v.edit_shown)
    v.edit:SetEnabled(members.editable(a_row))
    v.code:SetEnabled(v.picked ~= nil and v.picked.code ~= nil)
end

-- The Lua for the picked member: how to read it and, when it can be written, how to give it the value it has now.
local function member_code(v)
    local a_row, sheet, picked = v.member, v.sheet, v.picked
    if not (a_row and sheet and picked and picked.code and a_row.record) then return nil end
    local record, expr = a_row.record, picked.code
    if record.kind == "function" then
        members.signature(record)
        return paths.call_of(expr, record.name, record.params)
    end
    local lines = { paths.read_line(expr, record.name, a_row.field, a_row.index) }
    local state = sheet.state[record.name]
    if record.edit and a_row.type ~= "element" and state and state.seen and not state.failed then
        lines[2] = paths.write_of(expr, record.name, inspect.literal(record, state.value))
    end
    return table.concat(lines, "\n")
end

local function paint(v, made)
    local a_row, sheet = made.row, v.sheet
    if not a_row or not sheet then return end
    local record = a_row.record
    if record and record.kind == "property" then
        local inst = current(v)
        if inst then
            if a_row.type == "element" then
                members.items(sheet, inst, record)
            else
                members.read(sheet, inst, record)
                if a_row.type == "member" and record.show == "array" and sheet.open[record.name] then members.items(sheet, inst, record) end
            end
        end
    end
    local look = members.look(sheet, a_row)
    look.selected = v.member == a_row
    -- names end at the same place on every line, however far a line is set in
    local width = made.cell and tonumber(made.cell.fixed_width) or 320
    look.name_width = math.max(80, math.floor(width * NAME_SHARE) - (look.indent or 0) * 12)
    made.line:Set(look)
    local flag = look.flag
    if flag ~= nil and not made.flag then
        -- the switch is made the first time this cell shows a true-or-false member
        made.flag = made.box:Toggle("", flag, function(on) v.flip(made, on) end)
        made.flag_shown = true
    end
    if made.flag then
        local shown = flag ~= nil
        if shown ~= made.flag_shown then
            made.flag_shown = shown
            made.flag:SetVisible(shown)
        end
        if shown and made.flag:Get() ~= flag then made.flag:Set(flag, true) end
    end
end

function refresh_rows(v, top)
    local rows = v.sheet and members.rows(v.sheet) or {}
    for _, made in ipairs(v.cells) do made.row = nil end
    v.shown_rows = rows
    v.rows:SetItems(rows, not top)
end

local function refuse(v, problem)
    Wax.ui.Notify(tostring(problem), { title = "Not changed", kind = "bad", seconds = 5 })
    show_edit(v)
end

local function note_change(v, line)
    if changes[#changes] ~= line then changes[#changes + 1] = line end
    if #changes > M.CHANGES then table.remove(changes, 1) end
    show_changes(v)
end

-- Every write the Explorer makes goes through here: the checked write, then the line of Lua that does the same.
local function write(v, record, value)
    local inst, sheet, picked = current(v), v.sheet, v.picked
    if not (inst and sheet) then return false end
    local ok, problem = inspect.write(inst, record, value)
    if not ok then
        refuse(v, problem)
        return false
    end
    if picked.code then note_change(v, paths.write_of(picked.code, record.name, inspect.literal(record, value))) end
    members.read(sheet, inst, record)
    show_edit(v)
    v.rows:Refresh()
    return true
end

local function commit(v, text)
    local a_row, sheet, inst = v.member, v.sheet, current(v)
    if not (a_row and sheet and inst and members.editable(a_row)) then return end
    local record = a_row.record
    local value, problem = inspect.parse(record, text, a_row.field)
    if value == nil then return refuse(v, ("%s: %s."):format(member_name(a_row), problem)) end
    if a_row.type == "field" then
        -- one part of a struct: the whole struct is written, with the other parts as they are now
        local state = members.read(sheet, inst, record)
        if state.failed or not state.seen then return refuse(v, state.problem or "It could not be read.") end
        local whole = {}
        for _, field in ipairs(record.fields) do whole[field] = state.value[field] end
        whole[a_row.field] = value
        value = whole
    end
    write(v, record, value)
end

local function press_member(v, made)
    local a_row, sheet = made.row, v.sheet
    if not a_row or not sheet then return end
    if a_row.type == "class" then return v.open_member(made) end
    if a_row.type == "ancestor" or a_row.type == "more" then return end
    if members.links(sheet, a_row) then
        local inst, record = current(v), a_row.record
        if not inst then return end
        local place = a_row.type == "element" and a_row.index or nil
        local ok, found = pcall(function()
            if place then return inspect.element(inst, record, place) end
            return inst:Get(record.name)
        end)
        if not ok or not instance.is_instance(found) then return end
        local from = v.picked.path or paths.from(v.picked.instance)
        return select(v, target_for(found, paths.step(from, record.name, place)), true)
    end
    v.member = a_row
    show_edit(v)
    v.rows:Refresh()
end

local function build_details(v, side)
    local theme = Wax.import("gui.style").theme
    local head = side:Row()
    v.back = head:Button(nil, function() v.split:Show("left") end, { icon = "arrow-left" })
    v.name = head:Heading("Nothing picked")
    v.previous = head:Button(nil, function() go_back(v) end, { icon = "undo-2" })
    v.copy_path = head:Button(nil, function() copy(v.copy_path, "copy", v.picked and v.picked.code) end, { icon = "copy" })
    v.previous:SetEnabled(false)
    v.copy_path:SetEnabled(false)
    v.path = side:Label("Pick something in the list.", { family = "mono", size = theme.small_size, dim = true })
    v.find = side:Input(nil, { hint = "Search by name or type" })
    local function apply_members()
        if not v.sheet then return end
        members.show(v.sheet, v.mode, v.member_text, v.order_by == ORDERS[2])
        refresh_rows(v, true)
    end
    v.find.Typed:Connect(function(text)
        v.member_text = text
        apply_members()
    end)
    local filters = side:Row()
    v.show = filters:Dropdown(nil, SHOWS, v.mode, function(choice)
        v.mode = choice
        apply_members()
    end)
    v.order = filters:Dropdown(nil, ORDERS, v.order_by, function(choice)
        v.order_by = choice
        apply_members()
    end)

    v.open_member = function(made)
        local a_row, sheet = made.row, v.sheet
        if not a_row or not sheet then return end
        local key = a_row.type == "class" and "#class" or (a_row.type == "member" and a_row.record.name or nil)
        if not key then return end
        sheet.open[key] = not sheet.open[key] or nil
        local inst = current(v)
        if sheet.open[key] and inst and a_row.record and a_row.record.show == "array" then members.items(sheet, inst, a_row.record) end
        refresh_rows(v)
    end
    v.flip = function(made, on)
        local a_row = made.row
        if not (a_row and a_row.type == "member" and a_row.record.show == "bool") then return end
        if not write(v, a_row.record, on) and made.flag and not made.flag.destroyed then made.flag:Set(not on, true) end
    end
    v.rows = side:Grid({ cell = 100000, cell_height = ROW, gap = GAP, batch = 2,
        make = function(cell)
            local made = {}
            made.box, made.cell = cell:Row(), cell
            made.line = made.box:Item({ weight = 1, columns = true, divider = true }, function() press_member(v, made) end,
                function() v.open_member(made) end)
            v.cells[#v.cells + 1] = made
            return made
        end,
        show = function(made, a_row)
            made.row = a_row
            paint(v, made)
        end })

    local bar = side:Row()
    v.edit_name = bar:Label("", { dim = true })
    v.edit = bar:Input(nil, { mono = true }, function(text) commit(v, text) end)
    v.code = bar:Button(nil, function() copy(v.code, "code", member_code(v)) end, { icon = "code" })
    v.edit:SetEnabled(false)
    v.code:SetEnabled(false)
end

-- Under both sides: what was changed here, as Lua that does the same.
local function build_changes(v, page)
    local log = page:Section("Changes as Lua", { open = false })
    v.changes_note = log:Label("", { dim = true })
    v.log = log:Console({ height = 84, max = M.CHANGES })
    local tools = log:Row()
    v.copy_changes = tools:Button("Copy", function() copy(v.copy_changes, "copy", table.concat(changes, "\n")) end, { icon = "copy" })
    v.clear_changes = tools:Button("Clear", function()
        changes = {}
        show_changes(v)
    end, { icon = "trash-2" })
end

function show_changes(v)
    local lines = {}
    for index_, line in ipairs(changes) do lines[index_] = { line } end
    v.log:SetLines(lines)
    v.changes_note:Set(#changes == 0 and "What you change here is listed as Lua that does the same."
        or ("%d change%s, as Lua that does the same."):format(#changes, #changes == 1 and "" or "s"))
    v.copy_changes:SetEnabled(#changes > 0)
    v.clear_changes:SetEnabled(#changes > 0)
end

-- the page

local function stop()
    local v = view
    view = nil
    if v and v.map_changed then v.map_changed:Disconnect() end
    index.sleep()
end

local function map_changed()
    index.reset()
    inspect.flush()
    local v = view
    if not v then return end
    for _, row in ipairs(v.roots) do
        row.kids, row.address, row.missing, row.class_name = nil, false, true, "none"
        if row.root ~= "World" then row.open = false end
    end
    v.opened, v.history, v.tree_dirty, v.roots_due, v.tree_due = {}, {}, true, 0, 0
    if v.picked then v.picked.frame = nil end
    v.previous:SetEnabled(false)
end

local function make(page)
    local v = { page = page, window = page.window, frame = 0, roots = {}, flat = {}, opened = {}, kid_at = 0, tree_cells = {},
        cells = {}, cell_at = 0, history = {}, mode = SHOWS[1], order_by = ORDERS[1], member_text = "", tree_dirty = true,
        tree_due = 0, rows_due = 0,
        roots_due = 0, kids_due = 0, results_version = -1, shown_rows = {} }
    view = v
    v.split = page:Split({ share = 0.42, least = 260 })
    build_tree(v, v.split.Left)
    build_details(v, v.split.Right)
    build_changes(v, page)
    v.back:SetVisible(v.split:IsSingle() == true)
    v.split.Changed:Connect(function(single) v.back:SetVisible(single == true) end)
    v.map_changed = game.MapChanged:Connect(map_changed)
    show_changes(v)
    show_edit(v)
    apply_query()
end

-- Fills a page of the Wax panel (one made with scroll = false).
function M.build(page)
    stop()
    Wax.explorer_stop = stop
    if not Wax.game then
        page:Title("Explorer")
        page:Label("The game's objects could not be read in this session, so there is nothing to explore.", { dim = true })
        return
    end
    local ok, problem = xpcall(make, debug.traceback, page)
    if not ok then
        view = nil
        guard.report(tostring(problem), "explorer.build")
    end
end

local function showing(v)
    local window, ui = v.window, Wax.ui
    return window.shown == true and not window.minimized and window.page == v.page and ui ~= nil and (ui.IsOpen() or ui.IsPreview())
end

local function step()
    local v = view
    if not v then return end
    if v.window.destroyed or v.page.destroyed then return stop() end
    if not showing(v) then
        if index.awake() then index.sleep() end
        return
    end
    v.frame = v.frame + 1
    if v.picked then v.picked.now = nil end
    if not index.awake() then
        index.wake()
        v.roots_due, v.tree_due = 0, 0
    end
    index.step()
    local now = M.clock()
    local single = v.split:IsSingle()
    if not single or v.split:Shown() == "left" then
        if now >= v.roots_due then
            v.roots_due = now + M.ROOTS_EVERY
            look_at_roots(v)
        end
        if now >= v.kids_due then
            v.kids_due = now + M.KIDS_EVERY
            look_at_kids(v)
        end
        local _, results_version = index.results()
        if results_version ~= v.results_version then v.results_version, v.tree_dirty = results_version, true end
        if v.tree_dirty and now >= v.tree_due then
            v.tree_due = now + M.TREE_EVERY
            rebuild_tree(v)
        end
    end
    if single and v.split:Shown() == "left" then return end
    local inst = current(v)
    local sheet = v.sheet
    if not (inst and sheet) then return end
    members.poll(sheet, inst, members.POLL)
    local cells = v.cells
    for _ = 1, math.min(M.VISIBLE, #cells) do
        v.cell_at = v.cell_at % #cells + 1
        paint(v, cells[v.cell_at])
    end
    if sheet.dirty and now >= v.rows_due then
        v.rows_due = now + M.ROWS_EVERY
        refresh_rows(v)
    end
    -- the box for typing follows the value, unless something is being typed in it
    if v.member then
        local text = edit_text(v)
        if text ~= v.edit_shown and not v.edit:HasFocus() then
            v.edit_shown = text
            v.edit:Set(text)
        end
    end
end

local failures = 0

-- Once per frame. It does nothing unless the Explorer page is the one on screen, and it never raises:
-- a problem is reported, and after three frames in a row the page stops working until it is built again.
function M.step()
    if not view then return end
    local ok, problem = xpcall(step, debug.traceback)
    if ok then
        failures = 0
        return
    end
    failures = failures + 1
    guard.report(tostring(problem), "explorer.step")
    if failures >= 3 then
        failures = 0
        pcall(stop)
    end
end

function M.stats()
    local v = view
    local sheet = v and v.sheet
    return {
        built = v ~= nil, showing = v ~= nil and not v.window.destroyed and showing(v), index = index.stats(),
        picked = v and v.picked and v.picked.name or nil, code = v and v.picked and v.picked.code or nil,
        treeRows = v and #v.flat or 0, treeCells = v and #v.tree_cells or 0,
        memberRows = v and #v.shown_rows or 0, memberCells = v and #v.cells or 0,
        members = sheet and #sheet.records or 0, watched = sheet and #sheet.polled or 0, reads = sheet and sheet.reads or 0,
        failedReads = sheet and sheet.failed or 0, changed = sheet and sheet.changed or 0, rounds = sheet and sheet.rounds or 0,
        changes = #changes, perFrame = { watched = members.POLL, shown = M.VISIBLE },
    }
end

-- The lines of Lua for the changes made so far.
function M.changes() return table.move(changes, 1, #changes, 1, {}) end

M.view = function() return view end
return M
