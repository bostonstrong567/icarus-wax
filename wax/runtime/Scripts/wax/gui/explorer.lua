-- The Explorer page: what is in the game as a tree, the picked object's members beside it, and every change as Lua

local Wax = ...
local index = Wax.import("gui.explorer_index")
local paths = Wax.import("gui.explorer_path")
local members = Wax.import("gui.explorer_members")
local inspect = Wax.import("engine.inspect")
local instance = Wax.import("engine.instance")
local game = Wax.import("engine.game").root
local kit = Wax.import("gui.kit")
local style = Wax.import("gui.style")
local wrap_width = Wax.import("gui.controls").wrap_width
local storage = Wax.import("core.storage")
local sched = Wax.import("core.sched")
local guard = Wax.import("core.guard")

local M = {}

M.clock = os.clock
local function precise() return (Wax.perf and Wax.perf.now or os.clock)() end
M.VISIBLE = 4           -- rows of the details whose values are read again each frame
M.TREE_EVERY = 1        -- seconds between two rebuilds of the tree's rows when the world changed by itself
M.TREE_FIRST = 0.25     -- and while the world is first being listed or a search is still running
M.ROWS_EVERY = 0.5      -- and of the details' rows
M.ROOTS_EVERY = 1       -- seconds between looks at game.Character, game.GameState and the others
M.KIDS_EVERY = 1.5      -- an open row's children are read again this often, one row at a time
M.HISTORY, M.CHANGES = 20, 200
M.worst = { index = 0, list = 0 }       -- the longest the index step and a rebuild of the list took, in seconds

local ROW, GAP = 26, 1
local BAND = 36             -- the least height of the third row of each side, so both lists start at the same place
local FIT = 0.97            -- text may draw a little wider than its letters add up to
local LEAST = 310           -- the narrowest a side may be: two choices side by side still show whole
local BUTTON, BACK = 38, 84 -- the room an icon button and the "List" button take in a row, with the gap before them
local ICONS = { player = "user", creature = "paw-print", building = "hammer", item = "package", actor = "box",
    component = "puzzle", widget = "app-window", object = "circle-dot", world = "globe" }
local KINDS = { { "Actors", "actors" }, { "Creatures", "creature" }, { "Players", "player" }, { "Items", "item" },
    { "Buildings", "building" }, { "Components", "components" }, { "Everything", "everything" } }
local SORTS = { { "By name", "name" }, { "By class", "class" }, { "Nearest first", "distance" }, { "Newest first", "newest" } }
local RANGES = { { "Any distance from you", false }, { "Within 25 m of you", 25 }, { "Within 50 m of you", 50 },
    { "Within 100 m of you", 100 }, { "Within 250 m of you", 250 }, { "Within 500 m of you", 500 } }
local NOUNS = { actors = { "actor", "actors" }, creature = { "creature", "creatures" }, player = { "player", "players" },
    item = { "item", "items" }, building = { "building", "buildings" }, components = { "component", "components" },
    everything = { "actor or component", "actors and components" } }
local SHOWS = { "Properties", "Functions", "All", "Changed" }
local ORDERS = { "By name", "Changed first" }
local NAME_SHARE = 0.44     -- of a details line: where the names end and the values start
local HELP = {
    "Click a row in the list to see everything it holds. The small arrow beside a row opens what is inside it.",
    "Click a value to change it: type the new one in the box that appears above the list and press Enter. "
        .. "A value that is true or false has a switch.",
    "A value in colour is another object. Click it to go there. The curved arrow at the top brings you back.",
    "Whatever you change is written down as Lua at the bottom of the page, ready to copy into a mod.",
}
local GONE = "Pick something else in the list, or use the curved arrow to step back."
local HINTS = { int = "a whole number, then Enter", float = "a number, then Enter", text = "text, then Enter",
    bool = "true or false, then Enter" }

local view = nil        -- what belongs to the page that is built now
local changes = {}      -- one line of Lua for every change made here, oldest first
local settings = { text = "", kind = "actors", sort = "name", near = false, range = 50, show = SHOWS[1], order = ORDERS[1] }

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

local function one_of(list, wanted)
    for _, name in ipairs(list) do
        if name == wanted then return true end
    end
    return false
end

-- The filters are kept from one session to the next. What was typed in a search is not.
local function recall()
    local ok, saved = pcall(storage.load, "wax", "explorer", {})
    if not ok or type(saved) ~= "table" then return end
    if pick(KINDS, saved.kind, 2) then settings.kind = saved.kind end
    if pick(SORTS, saved.sort, 2) then settings.sort = saved.sort end
    if type(saved.range) == "number" and pick(RANGES, saved.range, 2) then
        settings.range, settings.near = saved.range, saved.near == true
    end
    if one_of(SHOWS, saved.show) then settings.show = saved.show end
    if one_of(ORDERS, saved.order) then settings.order = saved.order end
end
recall()

local function remember()
    pcall(storage.save, "wax", "explorer", { kind = settings.kind, sort = settings.sort, near = settings.near,
        range = settings.range, show = settings.show, order = settings.order })
end

local function searching() return settings.text:find("%S") ~= nil or settings.near end
local function filtering() return searching() or settings.kind ~= "actors" end

-- What the list holds, in words: the line under the heading and the note beside the world.
local function count_texts(shown)
    local actors, parts = index.counts()
    local kind = settings.kind
    local noun = NOUNS[kind] or NOUNS.actors
    if not searching() then
        local text = ("%d %s"):format(shown, shown == 1 and noun[1] or noun[2])
        return text .. " in this world.", text
    end
    local total = kind == "components" and parts or (kind == "everything" and actors + parts or actors)
    local of = (kind == "components" or kind == "everything") and noun or NOUNS.actors
    local note = ("%d of %d"):format(shown, total)
    return ("%s %s fit."):format(note, total == 1 and of[1] or of[2]), note .. " fit"
end

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

-- The heading and the line of Lua under it, each cut to the one line it has.
local function fit_texts(v)
    local picked, theme = v.picked, style.theme
    local width = wrap_width(v.split.Right)
    v.right_width = width
    local room = (width - 2 * BUTTON - (v.split:IsSingle() and BACK or 0)) * FIT
    local title = "Nothing picked"
    if picked and v.sheet then
        -- the heading is bold, which draws wider than the letter widths say
        title = kit.shorten(picked.name, room * 0.84, theme.title_size)
    elseif picked then
        local ending = " is gone"
        title = picked.name and (kit.shorten(picked.name, room * 0.84 - kit.text_width(ending, theme.title_size), theme.title_size) .. ending)
            or "Nothing there right now"
    end
    if title ~= v.title_text then
        v.title_text = title
        v.name:Set(title)
    end
    -- the end of the Lua is what tells one object from another, so that is the part that stays
    local code = picked and picked.code and kit.shorten(picked.code, width * FIT, theme.small_size, "mono", true) or ""
    if code ~= v.path_text then
        v.path_text = code
        v.path:Set(code)
    end
end

-- Shows what the right side has something to say with: help while nothing is picked, one line when it is gone, else the lists.
local function arrange(v)
    local picked = v.picked
    local state = not picked and "none" or (v.sheet and "object" or "gone")
    if state ~= v.state then
        v.state = state
        local there = state == "object"
        for _, line in ipairs(v.help) do line:SetVisible(state == "none") end
        v.gone:SetVisible(state == "gone")
        v.path:SetVisible(there)
        v.path_hint:SetVisible(not there)
        v.path_hint:Set(state == "gone" and "It left the world, or nothing is there now." or "Pick something in the list.")
        v.find:SetVisible(there)
        v.filters.control:SetVisible(there)
        v.rows:SetVisible(there)
        v.bar.control:SetVisible(there)
    end
    fit_texts(v)
    v.copy_path:SetEnabled(picked ~= nil and picked.code ~= nil)
end

local function adopt(v, inst)
    local picked = v.picked
    picked.address, picked.class_name = inst and instance.address(inst) or nil, inst and inst.ClassName or nil
    v.member = nil
    if inst then
        picked.name = inst.Name
        local ok, list = pcall(inspect.members, inst)
        v.sheet = members.new(ok and list or {}, inst:GetClassChain())
        local found, code = pcall(paths.expression, inst, picked.path, index.unique)
        picked.code = found and code or nil
        if picked.code then
            -- what was changed here stays marked when the object is picked again
            v.written[picked.code] = v.written[picked.code] or {}
            v.sheet.written = v.written[picked.code]
        end
        members.show(v.sheet, v.mode, v.member_text, v.order_by == ORDERS[2])
    else
        v.sheet, picked.code = nil, nil
    end
    arrange(v)
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

-- True when the target is what is picked already.
local function is_picked(v, target)
    local picked = v.picked
    if not picked then return false end
    if picked.instance or target.instance then return picked.instance ~= nil and rawequal(picked.instance, target.instance) end
    return paths.same(picked.path, target.path)
end

-- The way back says where it leads.
local function show_history(v)
    local last = v.history[#v.history]
    v.previous:SetEnabled(last ~= nil)
    v.previous:SetTip(last and last.name and ("Back to " .. last.name) or "Back to what was picked before")
end

local function select(v, target, remember_it)
    if not target then return end
    local before = v.picked
    if is_picked(v, target) then
        if v.split:IsSingle() then v.split:Show("right") end
        return
    end
    if remember_it and before then
        v.history[#v.history + 1] = { instance = before.instance, path = before.path, name = before.name }
        if #v.history > M.HISTORY then table.remove(v.history, 1) end
    end
    v.picked = { instance = target.instance, path = target.path, name = target.name, address = false }
    show_history(v)
    current(v)
    if v.split:IsSingle() then v.split:Show("right") end
    v.tree:Refresh()
end

-- True while what was picked earlier can still be shown.
local function still_there(target)
    if target.instance then return target.instance:IsValid() end
    return paths.resolve(target.path) ~= nil
end

-- Steps back to what was picked before. What has left the world since is passed over.
local function go_back(v)
    while #v.history > 0 do
        local target = table.remove(v.history)
        local ok, there = pcall(still_there, target)
        if ok and there then return select(v, target, false) end
    end
    show_history(v)
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

-- How far away a row of the world is, while the list is being asked about distance.
local function far(row)
    local distance = row.distance
    if not distance or not row.key or not index.current().distance then return nil end
    if distance >= 1000 then return ("%.1f km"):format(distance / 1000) end
    return ("%d m"):format(math.floor(distance + 0.5))
end

local function tree_look(v, row)
    local picked = v.picked
    return { text = row.name, note = row.note or row.class_name, icon = ICONS[row.kind] or ICONS.object, indent = row.depth,
        arrow = arrow_of(row), faint = row.missing or row.gone or false, value = far(row), tone = "dim",
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

-- The line under the heading, cut to the one line it has.
local function fit_count(v)
    local width = wrap_width(v.split.Left)
    v.left_width = width
    local text = kit.shorten(v.summary or "", width * FIT, style.theme.small_size)
    if text ~= v.count_text then
        v.count_text = text
        v.count:Set(text)
    end
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
    for entry in pairs(v.world_open) do
        if entry.gone or not entry.open then v.world_open[entry] = nil end
    end
    if world.open or narrowed then
        if next(v.world_open) == nil then
            -- nothing under the world is open: its rows are taken over in one move, not one by one (20,000 of them)
            table.move(results, 1, #results, #flat + 1, flat)
        else
            for i = 1, #results do
                local entry = results[i]
                if not entry.gone then
                    if entry.open then add(entry) else flat[#flat + 1] = entry end
                end
            end
        end
    end
    local text, note = count_texts(#results)
    world.note = note
    if index.seeding() then
        text = ("Listing the world: %d actors so far."):format((index.counts()))
    elseif index.current().distance and v.character.missing then
        text = "There is no character to measure from."
    end
    if text ~= v.summary then
        v.summary = text
        fit_count(v)
    end
    local folds = #opened > 0
    if folds ~= v.folds then
        v.folds = folds
        v.fold:SetEnabled(folds)
    end
    v.flat, v.opened, v.tree_dirty = flat, opened, false
    -- a new search or filter shows from its top. A list that only changed by itself stays where it is scrolled to.
    v.tree:SetItems(flat, not v.tree_top)
    v.tree_top = false
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
    if row.gone or row.missing or row.root == "World" or not row.open or not row.kids then return end
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
    local target = target_for(row.instance, nil)
    if target then target.name = row.name end
    select(v, target, true)
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
    -- the world's own rows that are open, so the list knows when it has to be put together row by row
    if row.key and not row.root then v.world_open[row] = row.open or nil end
    v.tree_dirty, v.tree_due, v.tree_now = true, 0, true
end

-- Closes every open row but the world's.
local function fold_all(v)
    for _, row in ipairs(v.opened) do
        if row.root ~= "World" then row.open = false end
    end
    v.tree_dirty, v.tree_due, v.tree_now = true, 0, true
end

-- Both sides are laid out alike, so they line up: a heading with its buttons, one small line, a search box,
-- two choices side by side, one row that is BAND tall, and the list down to the bottom.
local function build_tree(v, side)
    local theme = style.theme
    local head = side:Row()
    v.title = head:Heading("Explorer")
    v.fold = head:Button(nil, function() fold_all(v) end, { icon = "chevrons-down-up", tip = "Close every row that is open" })
    v.fold:SetEnabled(false)
    v.count = side:Label("", { size = theme.small_size, dim = true })
    v.search = side:Input(nil, { hint = "Search by name or class", text = settings.text, clear = true })
    v.search.Typed:Connect(function(text)
        settings.text = text
        apply_query()
        v.tree_dirty, v.tree_now, v.tree_top = true, true, true
    end)
    local filters = side:Row()
    v.kind = filters:Dropdown(nil, labels(KINDS), pick(KINDS, settings.kind, 2), function(choice)
        settings.kind = pick(KINDS, choice, 1)
        remember()
        apply_query()
        v.tree_dirty, v.tree_now, v.tree_top = true, true, true
    end)
    v.sort = filters:Dropdown(nil, labels(SORTS), pick(SORTS, settings.sort, 2), function(choice)
        settings.sort = pick(SORTS, choice, 1)
        remember()
        apply_query()
        v.tree_dirty, v.tree_now, v.tree_top = true, true, true
    end)
    local third = side:Row({ height = BAND })
    v.range = third:Dropdown(nil, labels(RANGES), pick(RANGES, settings.near and settings.range or false, 2), function(choice)
        local metres = pick(RANGES, choice, 1)
        settings.near = metres ~= false
        if metres then settings.range = metres end
        remember()
        apply_query()
        v.tree_dirty, v.tree_now, v.tree_top = true, true, true
    end)
    v.tree = side:Grid({ cell = 100000, cell_height = ROW, gap = GAP, batch = 3, warm = true,
        make = function(cell)
            local made = {}
            made.line = cell:Item({ fit = true }, function() press_tree(v, made) end, function() open_tree(v, made) end)
            v.tree_cells[#v.tree_cells + 1] = made
            return made
        end,
        show = function(made, row)
            made.row = row
            made.line:Set(tree_look(v, row))
        end })
    for _, name in ipairs(paths.ROOTS) do
        local row = { root = name, name = name, class_name = "none", kind = name == "World" and "world" or "object", depth = 0,
            missing = true, address = false, open = name == "World" }
        v.roots[#v.roots + 1] = row
        if name == "World" then v.world = row end
        if name == "Character" then v.character = row end
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

-- Why the picked member has no box to type in, in one line.
local function why_not(v, a_row)
    local record, sheet = a_row.record, v.sheet
    if a_row.type == "element" then return "One place of a list. Places are shown, not changed." end
    if record.kind == "function" then return "A function. Copy it as Lua to call it from a mod." end
    local state = sheet.state[record.name]
    if state and state.failed then return "It could not be read, so it is left alone." end
    if record.show == "struct" then return "Open it with its arrow and change one part." end
    if record.show == "array" then
        return members.opens(sheet, a_row) and "A list. Its arrow shows what is in it." or "A list with nothing to open."
    end
    if record.show == "object" then return "There is no object in it." end
    return "Values of this kind are not shown."
end

-- True when the picked member's value can be typed: one of a kind that is written, and that could be read.
local function types(v, a_row)
    if not (a_row and v.sheet and members.editable(a_row)) then return false end
    local state = v.sheet.state[a_row.record.name]
    return not (state and state.failed)
end

-- What to type for the picked member.
local function hint_for(a_row)
    local record = a_row.record
    if a_row.type == "field" then return record.fields.whole and HINTS.int or HINTS.float end
    return HINTS[record.show] or ""
end

-- The row above the members is the picked member's name, or a word about it, cut to the room the box and the buttons leave.
local function fit_bar(v)
    local room = wrap_width(v.split.Right)
    if v.bar_code then room = room - BUTTON end
    if v.bar_edit then room = (room - BUTTON - 8) * 0.7 / 1.7 end
    local text = kit.shorten(v.edit_label or "", room * FIT, style.theme.font_size)
    if text ~= v.edit_text then
        v.edit_text = text
        v.edit_name:Set(text)
    end
end

-- The name turns to the colour of a problem when what was typed was refused.
local function mark_bar(v, bad)
    if bad == v.edit_bad then return end
    v.edit_bad = bad
    v.edit_name:SetColor(bad and style.theme.bad or style.theme.dim)
end

function show_edit(v)
    local a_row = v.member
    local member = a_row ~= nil and v.sheet ~= nil
    local typed = types(v, a_row)
    local copies = member and v.picked ~= nil and v.picked.code ~= nil
    if typed ~= v.bar_edit then
        v.bar_edit = typed
        v.edit:SetVisible(typed)
        v.set:SetVisible(typed)
    end
    if copies ~= v.bar_code then
        v.bar_code = copies
        v.code:SetVisible(copies)
    end
    if not member then
        v.edit_label = "Click a value to change it."
    elseif typed then
        v.edit_label = member_name(a_row)
    else
        v.edit_label = why_not(v, a_row)
    end
    mark_bar(v, false)
    fit_bar(v)
    v.edit_shown = typed and edit_text(v) or ""
    v.edit_typed = v.edit_shown
    if not typed then return end
    local hint = hint_for(a_row)
    if hint ~= v.edit_hint then
        v.edit_hint = hint
        v.edit:SetHint(hint)
    end
    v.edit:Set(v.edit_shown)
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
    local width = made.cell and tonumber(made.cell.fixed_width) or 320
    local look
    if a_row.type == "note" then
        -- one line that says why the list is empty
        look = { text = a_row.text, faint = true, name_width = width }
    else
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
        look = members.look(sheet, a_row)
        look.selected = v.member == a_row
        -- names end at the same place on every line, however far a line is set in
        look.name_width = math.max(80, math.floor(width * NAME_SHARE) - (look.indent or 0) * 12)
    end
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
    -- the line ends where its switch starts
    look.width = width - (made.flag_shown and 50 or 0)
    made.line:Set(look)
end

-- The one line shown in place of a list of members that has nothing in it.
local function empty_note(v)
    local text = "It has no members."
    if v.member_text:find("%S") then
        text = ("Nothing here has \"%s\" in its name or type."):format((v.member_text:gsub("^%s+", ""):gsub("%s+$", "")))
    elseif v.mode == "Changed" then
        text = "Nothing has changed since you picked it."
    elseif v.mode == "Functions" then
        text = "It has no functions."
    elseif v.mode == "Properties" then
        text = "It has no properties."
    end
    local note = v.note_row
    note.text = text
    return note
end

function refresh_rows(v, top)
    local rows = v.sheet and members.rows(v.sheet) or {}
    if v.sheet and #rows == 0 then rows = { empty_note(v) } end
    local before = v.shown_rows
    local same = not top and #rows == #before
    for at = 1, same and #rows or 0 do
        if rows[at] ~= before[at] then same = false break end
    end
    -- the same lines in the same order: only their values are shown again
    if same then return v.rows:Refresh() end
    for _, made in ipairs(v.cells) do made.row = nil end
    v.shown_rows = rows
    v.rows:SetItems(rows, not top)
end

-- Says why a value was not changed. After typing, the box keeps what was typed and gets the keyboard back, so it can be put right.
local function refuse(v, problem, typed)
    Wax.ui.Notify(tostring(problem), { title = "Not changed", kind = "bad", seconds = 5 })
    if not typed then return end
    mark_bar(v, true)
    v.edit_keep = v.frame + 3
    sched.task.spawn(function()
        sched.task.wait()
        if view == v and not v.edit.destroyed and v.bar_edit then v.edit:Focus() end
    end)
end

local function note_change(v, line)
    if changes[#changes] ~= line then changes[#changes + 1] = line end
    if #changes > M.CHANGES then table.remove(changes, 1) end
    show_changes(v)
end

-- Every write the Explorer makes goes through here: the checked write, then the line of Lua that does the same. False and why, if not.
local function write(v, record, value)
    local inst, sheet, picked = current(v), v.sheet, v.picked
    if not (inst and sheet) then return false, "It is not there any more." end
    local ok, problem = inspect.write(inst, record, value)
    if not ok then return false, problem end
    sheet.written[record.name] = true
    if picked.code then note_change(v, paths.write_of(picked.code, record.name, inspect.literal(record, value))) end
    members.read(sheet, inst, record)
    show_edit(v)
    v.rows:Refresh()
    return true
end

-- Writes what was typed for the picked member. Only Enter and the button beside the box come here: leaving the box writes nothing.
local function commit(v, text)
    local a_row, sheet, inst = v.member, v.sheet, current(v)
    if not (inst and types(v, a_row)) then return end
    -- the value it has already is not written again (a number would come back rounded to what the box shows)
    if text == edit_text(v) then return end
    local record = a_row.record
    local value, problem = inspect.parse(record, text, a_row.field)
    if value == nil then return refuse(v, ("%s: %s."):format(member_name(a_row), problem), true) end
    if a_row.type == "field" then
        -- one part of a struct: the whole struct is written, with the other parts as they are now
        local state = members.read(sheet, inst, record)
        if state.failed or not state.seen then return refuse(v, state.problem or "It could not be read.", true) end
        local whole = {}
        for _, field in ipairs(record.fields) do whole[field] = state.value[field] end
        whole[a_row.field] = value
        value = whole
    end
    local ok, why = write(v, record, value)
    if not ok then refuse(v, why, true) end
end

local function press_member(v, made)
    local a_row, sheet = made.row, v.sheet
    if not a_row or not sheet then return end
    if a_row.type == "class" then return v.open_member(made) end
    if a_row.type == "ancestor" or a_row.type == "more" or a_row.type == "note" then return end
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
    -- a row with parts shows them when it is picked. Its arrow closes it again.
    if members.opens(sheet, a_row) and not sheet.open[a_row.record.name] then return v.open_member(made) end
    v.rows:Refresh()
end

local function build_details(v, side)
    local theme = style.theme
    local head = side:Row()
    v.back = head:Button("List", function() v.split:Show("left") end, { icon = "arrow-left", stretch = false, tip = "Back to the list" })
    v.name = head:Heading("Nothing picked")
    v.previous = head:Button(nil, function() go_back(v) end, { icon = "undo-2", tip = "Back to what was picked before" })
    v.copy_path = head:Button(nil, function() copy(v.copy_path, "copy", v.picked and v.picked.code) end,
        { icon = "copy", tip = "Copy the Lua that reaches this object" })
    v.previous:SetEnabled(false)
    v.copy_path:SetEnabled(false)
    v.path = side:Label("", { family = "mono", size = theme.small_size, dim = true })
    v.path_hint = side:Label("Pick something in the list.", { size = theme.small_size, dim = true })
    v.find = side:Input(nil, { hint = "Search by name or type", clear = true })
    local function apply_members()
        if not v.sheet then return end
        members.show(v.sheet, v.mode, v.member_text, v.order_by == ORDERS[2])
        refresh_rows(v, true)
    end
    v.find.Typed:Connect(function(text)
        v.member_text = text
        apply_members()
    end)
    v.filters = side:Row()
    v.show = v.filters:Dropdown(nil, SHOWS, v.mode, function(choice)
        v.mode, settings.show = choice, choice
        remember()
        apply_members()
    end)
    v.order = v.filters:Dropdown(nil, ORDERS, v.order_by, function(choice)
        v.order_by, settings.order = choice, choice
        remember()
        apply_members()
    end)
    v.bar = side:Row({ height = BAND })
    v.edit_name = v.bar:Label("", { dim = true, weight = 0.7 })
    v.edit = v.bar:Input(nil, { mono = true })
    v.edit.Typed:Connect(function(text)
        v.edit_typed = text
        mark_bar(v, false)
    end)
    v.edit.Entered:Connect(function(text) commit(v, text) end)
    v.set = v.bar:Button(nil, function() commit(v, v.edit_typed) end, { icon = "check", tip = "Write this value. Enter does the same." })
    v.code = v.bar:Button(nil, function() copy(v.code, "code", member_code(v)) end,
        { icon = "code", tip = "Copy as Lua: how a mod reads this, and how it changes it" })
    for at, text in ipairs(HELP) do v.help[at] = side:Label(text, { dim = true }) end
    v.gone = side:Label(GONE, { dim = true })

    v.open_member = function(made)
        local a_row, sheet = made.row, v.sheet
        if not a_row or not sheet then return end
        local key = a_row.type == "class" and "#class" or (members.opens(sheet, a_row) and a_row.record.name or nil)
        if not key then return end
        sheet.open[key] = not sheet.open[key] or nil
        local inst = current(v)
        if sheet.open[key] and inst and a_row.record and a_row.record.show == "array" then members.items(sheet, inst, a_row.record) end
        refresh_rows(v)
    end
    v.flip = function(made, on)
        local a_row = made.row
        if not (a_row and a_row.type == "member" and a_row.record.show == "bool") then return end
        local ok, why = write(v, a_row.record, on)
        if ok then return end
        if made.flag and not made.flag.destroyed then made.flag:Set(not on, true) end
        refuse(v, ("%s: %s"):format(a_row.record.name, tostring(why)), false)
    end
    v.rows = side:Grid({ cell = 100000, cell_height = ROW, gap = GAP, batch = 2, warm = true,
        make = function(cell)
            local made = {}
            made.box, made.cell = cell:Row(), cell
            made.line = made.box:Item({ weight = 1, columns = true, divider = true, fit = true }, function() press_member(v, made) end,
                function() v.open_member(made) end)
            v.cells[#v.cells + 1] = made
            return made
        end,
        show = function(made, a_row)
            made.row = a_row
            paint(v, made)
        end })
end

-- Under both sides, once something has been changed: what was changed here, as Lua that does the same.
local function build_changes(v, page)
    local log = page:Section("Changes as Lua", { open = false })
    v.changes_card = log.control
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
    v.changes_note:Set(("%d change%s, as Lua that does the same."):format(#changes, #changes == 1 and "" or "s"))
    -- with nothing changed it stays out of the way, and the lists have its room
    local any = #changes > 0
    if any ~= v.changes_shown then
        v.changes_shown = any
        v.changes_card:SetVisible(any)
    end
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
    v.opened, v.history, v.tree_dirty, v.roots_due, v.tree_due, v.tree_now = {}, {}, true, 0, 0, true
    v.world_open, v.written = {}, {}
    if v.picked then v.picked.frame = nil end
    show_history(v)
end

local function make(page)
    local v = { page = page, window = page.window, frame = 0, roots = {}, flat = {}, opened = {}, kid_at = 0, tree_cells = {},
        cells = {}, cell_at = 0, history = {}, mode = settings.show, order_by = settings.order, member_text = "", tree_dirty = true,
        world_open = {}, written = {}, help = {}, note_row = { type = "note", key = "#note", depth = 0, text = "" },
        tree_due = 0, rows_due = 0,
        roots_due = 0, kids_due = 0, results_version = -1, shown_rows = {} }
    view = v
    v.split = page:Split({ share = 0.42, least = LEAST })
    build_tree(v, v.split.Left)
    build_details(v, v.split.Right)
    build_changes(v, page)
    v.back:SetVisible(v.split:IsSingle() == true)
    v.split.Changed:Connect(function(single)
        v.back:SetVisible(single == true)
        fit_texts(v)
    end)
    v.map_changed = game.MapChanged:Connect(map_changed)
    show_changes(v)
    arrange(v)
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
    local window = v.window
    return window.shown == true and window.on_screen == true and not window.minimized and window.page == v.page
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
    -- lines that are cut to their width are cut again when a side gets another width
    if wrap_width(v.split.Right) ~= v.right_width then
        fit_texts(v)
        fit_bar(v)
    end
    if wrap_width(v.split.Left) ~= v.left_width then fit_count(v) end
    local timed = precise()
    index.step()
    local spent = precise() - timed
    if spent > M.worst.index then M.worst.index = spent end
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
        -- a first listing or a search fills the list in as it goes, and its end shows at once
        local filling = index.seeding() or index.searching()
        if v.filling and not filling then v.tree_now = true end
        v.filling = filling
        if v.tree_dirty and (v.tree_now or now >= v.tree_due) then
            -- The list is not re-sorted under the mouse. What went away meanwhile is drawn faint where it stands.
            if not v.tree_now and not filling and v.tree.widget:IsHovered() then
                v.tree_due = now + M.TREE_EVERY
                v.tree:Refresh()
            else
                v.tree_due, v.tree_now = now + (filling and M.TREE_FIRST or M.TREE_EVERY), false
                timed = precise()
                rebuild_tree(v)
                spent = precise() - timed
                if spent > M.worst.list then M.worst.list = spent end
            end
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
    -- the box for typing follows the value, and goes back to it when it is left without Enter
    if v.member and v.bar_edit then
        local text = edit_text(v)
        if (text ~= v.edit_shown or v.edit_typed ~= text) and v.frame > (v.edit_keep or 0) and not v.edit:HasFocus() then
            v.edit_shown, v.edit_typed = text, text
            v.edit:Set(text)
            mark_bar(v, false)
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
        worstMs = { index = M.worst.index * 1000, list = M.worst.list * 1000 },
    }
end

-- The lines of Lua for the changes made so far.
function M.changes() return table.move(changes, 1, #changes, 1, {}) end

M.view = function() return view end
return M
