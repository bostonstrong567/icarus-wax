-- The browser beside the game's own screens: a column at the right that lists every item, or shows one item's recipes and
-- details, and favourites along the top. Nothing is drawn over the game's screens, so they stay in use the whole time.

local view = {}

local FIT = 0.85            -- the game's screens are drawn this much smaller, which frees the column and the band
local ZOOM = 1.25           -- the panels are read beside the game's own text, which is larger than a window's
local GAP = 2
local COLUMNS, TAB_COLUMNS, TAB_ROWS = 5, 6, 5
local CARDS = 6
local PLAIN = { item = "package", tag = "tags", resource = "droplet" }
local KEYS = { make = "R", used = "U", favourite = "A" }

function view.start(app)
    local text, rows, search = app.text, app.rows, app.search
    -- on a Wax from before the panels it says what it needs and shows nothing
    if not (ui.Panel and ui.FitGame and ui.GameScreen and ui.ScreenSize) then
        ui.Notify(text.problem.needs_wax(app.needs), { kind = "bad", seconds = 10 })
        return {}
    end
    local words = text.panel
    local small = ui.Theme().small_size
    local crafting = game.Crafting
    local state = { query = "", page = 1, list = {}, mode = "make", view = "recipes", card_page = 1, tab = 1, pass = 0, on = true,
        bare = false, detail = false, amount = 1, numbers = {}, tabs = {}, pages = {}, only = app.settings.bench_only ~= false }

    -- every size and place comes from the screen's size, worked out in layout.lua
    local L = require(mod.layout).compute(ui.ScreenSize())
    local screen_width, screen_height = L.width, L.height
    local column, tall, inner, down = L.column, L.tall, L.inner, L.down
    local CELL, TAB, grid_rows, budget = L.cell, L.tab, L.grid_rows, L.budget
    local shelf, favourite_columns, favourite_rows, even = L.shelf, L.favourite_columns, L.favourite_rows, L.even

    local function model()
        local m = app.job.model
        if m and m.stage >= 1 and not m.off.list then return m end
        return nil
    end

    local function set(parts, shown)
        for _, part in ipairs(parts) do part:SetVisible(shown) end
    end

    -- Every item in the order it comes in the game: by the level asked for by the first recipe that makes it, or, for a
    -- thing that is gathered or that nothing makes, by the first recipe that uses it. At one level what is used in the
    -- most recipes comes first, so wood, fibre and stone lead. What nothing makes or uses comes last. Worked out once
    -- for each read of the data.
    local ranked = { list = {}, rank = {} }
    local function in_order(m)
        local needs = app.job.needs
        if ranked.model == m and ranked.needs == needs and ranked.stage == m.stage then return ranked.list, ranked.rank end
        local levels, rank = {}, {}
        local function lowest(numbers)
            local best = nil
            for _, number in ipairs(numbers or {}) do
                local level = levels[number]
                if level == nil then
                    local recipe = m.recipes[number]
                    level = recipe and not recipe.hidden_only and app.unlock.level(needs, m, recipe) or false
                    levels[number] = level
                end
                if level and (not best or level < best) then best = level end
            end
            return best
        end
        -- ores, wood, hides and the like also have recipes that break something down into them: those do not count
        local gathered = app.gather.choice(m)
        for key in pairs(m.items) do
            if gathered[key] == false then
                rank[key] = lowest(m.used_in[key]) or lowest(m.made_by[key]) or 9999
            else
                rank[key] = lowest(m.made_by[key]) or lowest(m.used_in[key]) or 9999
            end
        end
        local list = table.move(m.list, 1, #m.list, 1, {})
        -- the kinds of one item (each seed, each flag) do not lead a level between them
        local uses = {}
        for _, item in ipairs(list) do uses[item.key] = not item.variant and m.uses and m.uses[item.key] or 0 end
        table.sort(list, function(a, c)
            if rank[a.key] ~= rank[c.key] then return rank[a.key] < rank[c.key] end
            local first, second = uses[a.key], uses[c.key]
            if first ~= second then return first > second end
            if a.lower ~= c.lower then return a.lower < c.lower end
            return a.key < c.key
        end)
        ranked = { model = m, needs = needs, stage = m.stage, list = list, rank = rank }
        return list, rank
    end

    -- Orders: an item and how many of it, kept so what it takes can be looked up again. One for each item.
    local orders = {}
    for _, entry in ipairs(storage.Load("orders", {})) do
        if type(entry) == "table" and type(entry.key) == "string" and type(entry.amount) == "number" then
            orders[#orders + 1] = { key = entry.key, amount = math.max(1, math.floor(entry.amount)) }
        end
    end
    local function order_at(key)
        for at, order in ipairs(orders) do
            if order.key == key then return at end
        end
        return nil
    end

    -- The order of the shelf, favourites and orders together: "f:<item>" and "o:<item>". What is not in it yet goes last.
    local shelf_order = {}
    for _, id in ipairs(storage.Load("shelf", {})) do
        if type(id) == "string" then shelf_order[#shelf_order + 1] = id end
    end
    -- Every favourite and order there is, in the shelf's order. `listed` leaves favourites out that it does not answer for.
    local function shelf_ids(listed)
        local ids, rank = {}, {}
        for at, id in ipairs(shelf_order) do rank[id] = at end
        for at, order in ipairs(orders) do ids[#ids + 1] = { id = "o:" .. order.key, order = at, rank = rank["o:" .. order.key] } end
        for _, key in ipairs(app.favourites:list(listed)) do ids[#ids + 1] = { id = "f:" .. key, key = key, rank = rank["f:" .. key] } end
        for at, entry in ipairs(ids) do entry.rank = entry.rank or (1000000 + at) end
        table.sort(ids, function(a, c) return a.rank < c.rank end)
        return ids
    end

    local show_items, show_tabs, show_list, show_favourites, show_detail, open, close_detail, station_changed, step_back, time_at

    -- What the open bench says about an item: { row, valid, order }, or nothing. at_bench answers only while the list is cut down to it.
    local function here_of(key)
        return state.station and state.station.items[key] or nil
    end
    local function at_bench(key)
        return state.only and here_of(key) or nil
    end

    -- What a bench's recipe asks of the player: the level, and the line that says it ("Tier 2 - level 10"). 0 when it asks nothing.
    local function asked_of(m, here)
        local needs = app.job.needs
        local line = needs and app.unlock and here.number and app.unlock.describe(needs, m, m.recipes[here.number]) or nil
        local level = line and line.level or 0
        return level, line and text.join(line.tier, level > 0 and text.needs.level(level) or nil) or ""
    end

    local function station_names(m, item)
        local names, seen = {}, {}
        for _, number in ipairs(rows.recipes(m, item, "make", false)) do
            for _, id in ipairs(m.recipes[number].stations) do
                local set_of = m.sets[id]
                local name = set_of and (set_of.hand and text.right.by_hand or set_of.name) or ""
                if name ~= "" and not seen[name] then
                    seen[name] = true
                    names[#names + 1] = name
                end
            end
        end
        return names
    end

    -- What the tooltip of an item says, worked out when the mouse gets there.
    local function tip_of(key)
        local m = model()
        local item = m and m.items[key]
        if not item then return nil end
        local lines = {}
        if rows.ready(m) then
            local names = station_names(m, item)
            lines[#lines + 1] = #names > 0 and text.tip.made_at(names, 3) or (item.hints and item.hints[1]) or text.tip.no_recipe
            -- how long it takes: the recipe of the open bench when it has one, else the first
            local listed = here_of(key)
            local number = listed and listed.number or rows.recipes(m, item, "make", false)[1]
            local made = number and rows.recipe(m, app.job.needs, number, item, "make") or nil
            lines[#lines + 1] = made and text.tip.takes(time_at(made, nil)) or ""
            lines[#lines + 1] = text.tip.used_in(#rows.recipes(m, item, "used", false))
        end
        local level = item.level and m.levels and m.levels[item.level]
        if level and level.name then lines[#lines + 1] = { level.name, "warn" } end
        if app.favourites:has(key) then lines[#lines + 1] = { text.tip.favourite, "accent" } end
        local here = at_bench(key)
        if here then
            local _, asks = asked_of(m, here)
            lines[#lines + 1] = asks
            lines[#lines + 1] = here.valid and { words.can_make, "good" } or words.missing
            lines[#lines + 1] = words.choose
        end
        if app.settings.internal_names then lines[#lines + 1] = item.row end
        local kept = {}
        for _, line in ipairs(lines) do
            if line ~= "" then kept[#kept + 1] = line end
        end
        return { title = item.name, lines = kept }
    end

    -- starred = false is for the favourites and the picked item: no star on them, and they are never faded.
    local function look_of(item, starred)
        local key = item.key
        local here = at_bench(key)
        return { image = item.icon, icon = not item.icon and PLAIN.item or nil, value = key, tone = here and here.valid and "good" or nil,
            dim = starred ~= false and here ~= nil and not here.valid, mark = starred ~= false and app.favourites:has(key) and "star" or nil,
            tip = function() return tip_of(key) end }
    end

    -- Lines of slots, each there only while it holds something. More looks than cells: the last cell stands for the rest.
    local blocks = {}
    local function slot_lines(panel, count, columns, drag, size)
        local lines = {}
        for at = 1, count do
            lines[at] = panel:Slots({ columns = columns, rows = 1, size = size or CELL, gap = GAP, below = GAP, drag = drag })
            lines[at]:SetVisible(false)
            blocks[#blocks + 1] = lines[at]
        end
        return lines
    end
    local function fill_lines(lines, looks)
        local columns = lines[1]:Capacity()
        local room = #lines * columns
        if #looks > room then
            local rest = {}
            for at = room, #looks do
                local tip = looks[at].tip
                rest[#rest + 1] = type(tip) == "table" and tip.title or ""
            end
            looks[room] = { icon = "ellipsis", count = text.plus(#rest), tip = { title = text.and_more(#rest), lines = text.some(rest, 7) } }
        end
        for row, line in ipairs(lines) do
            local part, any = {}, false
            for at = 1, columns do
                local look = looks[(row - 1) * columns + at]
                part[at] = look
                any = any or look ~= nil
            end
            line:Set(part)
            line:SetVisible(any)
        end
    end

    -- the column at the right. First the list: categories, the bench switch, the page line, the items, the search box
    local items = ui.Panel({ anchor = "right", x = 4, y = 0, width = column, height = tall, padding = 6, zoom = ZOOM, when = "always", opacity = 1,
        visible = false })
    local tabs = items:Slots({ columns = TAB_COLUMNS, rows = TAB_ROWS, size = TAB, gap = GAP })
    local category_line = items:Label("", { size = small, dim = true, align = "center" })
    local switch_row = items:Row()
    switch_row:Toggle(words.bench_only, state.only, function(on)
        state.only = on
        app.settings.bench_only = on
        app.save()
        station_changed()
    end)
    switch_row.control:SetVisible(false)
    local head = items:Row()
    local back = head:Button(nil, function() state.page = state.page - 1 show_items() end, { icon = "chevron-left" })
    local page_label = head:Label("", { align = "center" })
    local forth = head:Button(nil, function() state.page = state.page + 1 show_items() end, { icon = "chevron-right" })
    local note_label = items:Label("", { dim = true, align = "center" })
    note_label:SetVisible(false)
    local grid = items:Slots({ columns = COLUMNS, rows = grid_rows, size = CELL, gap = GAP })
    local find = items:Input(nil, { hint = words.search })
    local keys_line = items:Label(text.right.keys(KEYS), { size = small, dim = true, align = "center" })
    local list_parts = { tabs, category_line, head.control, grid, find, keys_line }

    function show_tabs()
        local m = model()
        local looks, line = {}, ""
        if m then
            if state.category and not (m.category[state.category] and m.category[state.category].count > 0) then state.category = nil end
            -- beside a bench, with the list cut down to it, each category says how much of it the bench makes
            local made = state.only and state.station and state.station.items or nil
            local counts, ready, all, all_ready = {}, {}, 0, 0
            for key, here in pairs(made or {}) do
                local item = m.items[key]
                local home = item and not item.hidden and item.cats and item.cats[1]
                if item and not item.hidden then
                    all, all_ready = all + 1, all_ready + (here.valid and 1 or 0)
                    if home then
                        counts[home] = (counts[home] or 0) + 1
                        if here.valid then ready[home] = (ready[home] or 0) + 1 end
                    end
                end
            end
            local function lines_for(count, can)
                if not made then return { text.left.count(count) } end
                return { text.left.count(count), { words.ready(can), can > 0 and "good" or "dim" } }
            end
            looks[1] = { icon = "layout-grid", value = { category = false }, selected = state.category == nil,
                tip = { title = text.left.all_categories, lines = lines_for(made and all or m.counts.shown, all_ready) } }
            line = text.left.all_categories
            for _, category in ipairs(m.categories) do
                if category.count > 0 and category.name ~= "" and #looks < tabs:Capacity() then
                    local count = made and (counts[category.key] or 0) or category.count
                    looks[#looks + 1] = { image = category.icon, icon = not category.icon and "folder" or nil,
                        value = { category = category.key }, selected = state.category == category.key, dim = made ~= nil and count == 0,
                        tone = made and (ready[category.key] or 0) > 0 and "good" or nil,
                        tip = { title = category.name, lines = lines_for(count, ready[category.key] or 0) } }
                    if state.category == category.key then line = text.join(category.name, made and text.left.count(count) or nil) end
                end
            end
        end
        tabs:Set(looks)
        category_line:Set(line)
    end

    function show_items()
        local per = grid:Capacity()
        local pages = math.max(1, math.ceil(#state.list / per))
        state.page = math.max(1, math.min(state.page, pages))
        local looks, first = {}, (state.page - 1) * per
        for at = 1, per do
            local item = state.list[first + at]
            if item then looks[at] = look_of(item) end
        end
        grid:Set(looks)
        local line
        if model() then
            line = #state.list == 0 and state.query ~= "" and text.no_match(state.query) or ""
        else
            line = app.job.failed and app.failed or text.status.reading()
        end
        state.note = line
        note_label:Set(line)
        note_label:SetVisible(line ~= "" and not state.detail)
        page_label:Set(words.page(state.page, pages))
        back:SetEnabled(state.page > 1)
        forth:SetEnabled(state.page < pages)
    end

    function show_list()
        set(list_parts, not state.detail)
        note_label:SetVisible(not state.detail and (state.note or "") ~= "")
        switch_row.control:SetVisible(not state.detail and state.station ~= nil)
    end

    local function apply(keep_page)
        state.pass = state.pass + 1
        local pass = state.pass
        local m, finder = model(), app.job.find
        local list = {}
        if m and finder then
            local query = search.parse(state.query)
            -- a search by station looks at every recipe the first time, so it is done a part a frame
            local slowly = #query.stations > 0 and coroutine.isyieldable()
            list = finder.filter(in_order(m), query, { show = "all", category = state.category, every = 400,
                is_favourite = function(item) return app.favourites:has(item.key) end, pause = slowly and task.wait or nil })
            if state.pass ~= pass then return end
        end
        -- beside a bench the list is what that bench makes: what can be made now first, each part in the same order as
        -- the whole list, from the first tier of the tech tree to the last
        if state.only and state.station then
            local made, ready, rest = state.station.items, {}, {}
            for _, item in ipairs(list) do
                local here = made[item.key]
                if here and here.valid then ready[#ready + 1] = item elseif here then rest[#rest + 1] = item end
            end
            table.move(rest, 1, #rest, #ready + 1, ready)
            list = ready
        end
        state.list = list
        if not keep_page then state.page = 1 end
        show_items()
    end

    find.Typed:Connect(function(typed)
        state.query = typed
        if state.queued then return end
        state.queued = true
        task.defer(function()
            state.queued = false
            apply(false)
        end)
    end)

    -- Then, in the same column, one item: its picture and name, four tabs, and what the chosen tab shows.
    local top = items:Row()
    top:Button(words.back, function() close_detail() end, { icon = "arrow-left", stretch = false })
    top:Label("")
    local previous = top:Button(nil, function() step_back() end, { icon = "undo-2" })
    local star = top:Button(nil, function() view.favourite(state.pick) end, { icon = "star" })
    local name_row = items:Row()
    local picked_slot = name_row:Slots({ columns = 1, rows = 1, size = CELL, gap = 0 })
    local title = name_row:Heading("")
    local view_tabs = {}
    local tab_rows = { items:Row(), items:Row() }
    local function tab(row, name, on_click) view_tabs[name] = tab_rows[row]:Button(words.views[name], on_click, { tab = true }) end
    tab(1, "make", function() open(state.pick, "make") end)
    tab(1, "used", function() open(state.pick, "used") end)
    tab(2, "tree", function()
        state.view = "tree"
        show_detail()
    end)
    tab(2, "details", function()
        state.view = "details"
        show_detail()
    end)
    local rule = items:Separator()
    local mode_line = items:Label("", { dim = true })
    local head_parts = { top.control, name_row.control, tab_rows[1].control, tab_rows[2].control, rule, mode_line }

    -- recipes: the stations as tabs, a button to choose the recipe at the open bench, then a recipe to a block
    local station_lines = slot_lines(items, 2, COLUMNS)
    local station_line = items:Label("", { align = "center" })
    -- Chooses a recipe the open screen lists, as a click on the game's own tile would. From another tab of the game's
    -- menu the game goes to its crafting tab first.
    local function select_here(here)
        if not (here and crafting) then return false end
        if state.station and state.station.kind == "menu" then
            if not (crafting.OpenTab and crafting:OpenTab()) then return false end
            local row = here.row
            task.spawn(function()
                task.wait()
                crafting:Select(row)
            end)
            return true
        end
        return crafting:Select(here.row) == true
    end
    local here_button = items:Button(words.make_here, function() select_here(state.pick and here_of(state.pick)) end, { primary = true })
    local pager = items:Row()
    local card_back = pager:Button(nil, function() state.card_page = state.card_page - 1 show_detail() end, { icon = "chevron-left" })
    local card_label = pager:Label("", { align = "center", dim = true })
    local card_forth = pager:Button(nil, function() state.card_page = state.card_page + 1 show_detail() end, { icon = "chevron-right" })
    -- a recipe is what goes in, then an arrow and what comes out on a line of its own
    local cards = {}
    for at = 1, CARDS do
        local card = { inputs = slot_lines(items, 2, COLUMNS) }
        card.output = slot_lines(items, 1, COLUMNS)
        card.needs = items:Label("", { size = small, dim = true })
        card.rule = items:Separator()
        cards[at] = card
    end
    local recipe_parts = { station_lines[1], station_lines[2], station_line, here_button, pager.control }
    for _, card in ipairs(cards) do
        for _, part in ipairs({ card.inputs[1], card.inputs[2], card.output[1], card.needs, card.rule }) do
            recipe_parts[#recipe_parts + 1] = part
        end
    end

    -- materials: everything the item takes, for a number of them: what to gather, then what to make
    local amount_row = items:Row()
    local function more(by)
        state.amount = math.max(1, math.min(9999, state.amount + by))
        show_detail()
    end
    amount_row:Button(nil, function() more(-1) end, { icon = "minus" })
    local amount_label = amount_row:Label("", { align = "center" })
    amount_row:Button(nil, function() more(1) end, { icon = "plus" })
    local quick_row = items:Row()
    for _, count in ipairs({ 1, 10, 100 }) do
        quick_row:Button(tostring(count), function()
            state.amount = count
            show_detail()
        end)
    end
    local order_button = items:Button(words.order_keep, function()
        local key = state.pick
        if not key then return end
        local at = order_at(key)
        if at and orders[at].amount == state.amount then
            table.remove(orders, at)
        elseif at then
            orders[at].amount = state.amount
        else
            orders[#orders + 1] = { key = key, amount = state.amount }
        end
        storage.Save("orders", orders)
        show_favourites()
        show_detail()
    end, { icon = ui.Icons.Has("clipboard-list") and "clipboard-list" or "list" })
    local gather_label = items:Label(text.tree.gather, { size = small, dim = true })
    local gather_lines = slot_lines(items, 5, COLUMNS)
    local craft_label = items:Label(text.tree.craft, { size = small, dim = true })
    local craft_lines = slot_lines(items, 4, COLUMNS)
    local total_label = items:Label("")
    local times_label = items:Label("", { size = small, dim = true })
    local tree_parts = { amount_row.control, quick_row.control, order_button, gather_label, craft_label, times_label, total_label }
    for _, line in ipairs(gather_lines) do tree_parts[#tree_parts + 1] = line end
    for _, line in ipairs(craft_lines) do tree_parts[#tree_parts + 1] = line end

    -- details: the game's own words about the item, where it comes from, then its numbers a group at a time
    local describe_label = items:Label("")
    local flavour_label = items:Label("", { size = small, dim = true })
    local where_label = items:Label(words.where, { size = small, dim = true })
    local where_lines = {}
    for at = 1, 4 do where_lines[at] = items:Label("") end
    local detail_parts = { describe_label, flavour_label, where_label, table.unpack(where_lines) }
    local stat_groups = {}
    for at = 1, 6 do
        local group = { title = items:Label("", { size = small, dim = true }) }
        local pair = items:Row()
        group.pair = pair.control
        group.names = pair:Label("", { weight = 3 })
        group.values = pair:Label("", { align = "right", weight = 2 })
        group.notes = items:Label("", { size = small, dim = true })
        stat_groups[at] = group
        for _, part in ipairs({ group.title, group.pair, group.notes }) do detail_parts[#detail_parts + 1] = part end
    end
    local message = items:Label("", { dim = true })

    local one_parts = { message }
    for _, parts in ipairs({ head_parts, recipe_parts, tree_parts, detail_parts }) do
        for _, part in ipairs(parts) do one_parts[#one_parts + 1] = part end
    end
    set(one_parts, false)

    local function entry_look(entry)
        local name = entry.kind == "tag" and text.right.any(entry.name) or entry.name
        local lines = {}
        if entry.kind == "resource" then lines[1] = entry.amount end
        if entry.item then lines[#lines + 1] = words.click end
        return { image = entry.icon, icon = not entry.icon and PLAIN[entry.kind] or nil, count = entry.amount ~= "1" and entry.amount or nil,
            value = entry.item, tip = { title = name, lines = lines } }
    end

    local function tab_key(set_of) return set_of.hand and "" or set_of.lower end

    -- How long a recipe takes at the chosen station: one figure when its benches agree, else each bench with its own.
    function time_at(made, chosen)
        local benches = {}
        for _, station in ipairs(made.stations) do
            if not chosen or chosen.all or station.name == chosen.name then
                for _, bench in ipairs(station.benches) do
                    if bench.time ~= "" then benches[#benches + 1] = bench end
                end
            end
        end
        if #benches == 0 then return "" end
        local same, list = true, {}
        for at, bench in ipairs(benches) do
            if bench.time ~= benches[1].time then same = false end
            list[at] = text.tip.bench(bench.name, bench.time)
        end
        if same then return benches[1].time end
        return table.concat(text.some(list, 3), ", ")
    end

    -- The recipes of one station as pages: as many to a page as the column has room for.
    local function paginate(m, numbers)
        local pages, page, used = {}, {}, 0
        for _, number in ipairs(numbers) do
            local made = m.recipes[number]
            local inputs = #made.inputs + #made.tags_in + #made.res_in
            local height = (1 + math.max(1, math.min(2, math.ceil(inputs / COLUMNS)))) * (CELL + GAP) + 60
            if #page > 0 and (#page >= CARDS or used + height > budget) then
                pages[#pages + 1] = page
                page, used = {}, 0
            end
            page[#page + 1] = number
            used = used + height
        end
        if #page > 0 then pages[#pages + 1] = page end
        return pages
    end

    local function show_recipes(m, picked, ready)
        mode_line:Set(ready and text.right.mode(state.mode, #state.numbers) or text.status.reading())
        local stations = state.tabs
        state.tab = math.max(1, math.min(state.tab, math.max(1, #stations)))
        local station_looks = {}
        for at, station in ipairs(stations) do
            station_looks[at] = { image = station.icon, icon = not station.icon and station.plain or nil, value = { tab = at },
                selected = at == state.tab, tip = { title = station.name, lines = station.item and { words.station } or nil } }
        end
        fill_lines(station_lines, station_looks)
        local chosen, here = stations[state.tab], {}
        for _, number in ipairs(state.numbers) do
            local fits = chosen == nil or chosen.all == true
            if not fits then
                for _, id in ipairs(m.recipes[number].stations) do
                    local set_of = m.sets[id]
                    if set_of and tab_key(set_of) == chosen.key then fits = true break end
                end
            end
            if fits then here[#here + 1] = number end
        end
        station_line:Set(chosen and chosen.name or "")
        station_line:SetVisible(chosen ~= nil)
        -- the open bench makes this: one press chooses it there
        local listed = state.mode == "make" and here_of(picked.key) or nil
        here_button:SetVisible(listed ~= nil)
        local pages = paginate(m, here)
        state.pages = pages
        state.card_page = math.max(1, math.min(state.card_page, math.max(1, #pages)))
        card_label:Set(words.page(state.card_page, math.max(1, #pages)))
        card_back:SetEnabled(state.card_page > 1)
        card_forth:SetEnabled(state.card_page < #pages)
        pager.control:SetVisible(#pages > 1)
        local page = pages[state.card_page] or {}
        for at, card in ipairs(cards) do
            local made = page[at] and rows.recipe(m, app.job.needs, page[at], picked, state.mode) or nil
            if made then
                local inputs, outputs = {}, { { icon = "arrow-right", plain = true } }
                for _, entry in ipairs(made.inputs) do inputs[#inputs + 1] = entry_look(entry) end
                for _, entry in ipairs(made.outputs) do outputs[#outputs + 1] = entry_look(entry) end
                fill_lines(card.inputs, inputs)
                fill_lines(card.output, outputs)
                local needs = made.needs
                local line = text.join(state.mode ~= "make" and made.name or nil, made.random and text.right.one_of or nil,
                    time_at(made, chosen),
                    needs and needs.short or nil, needs and needs.extra or nil, not needs and made.level or nil)
                card.needs:Set(line)
                card.needs:SetVisible(line ~= "")
                card.rule:SetVisible(true)
            end
        end
        if ready and #here == 0 then
            return state.mode == "make" and ((picked.hints and picked.hints[1]) or text.right.no_recipe) or text.right.no_use
        end
        return ""
    end

    -- The raw materials and the order to make things in, for the number asked for.
    local function show_tree(m, picked)
        mode_line:Set(text.tree.title(state.amount))
        amount_row.control:SetVisible(true)
        quick_row.control:SetVisible(true)
        amount_label:Set(text.right.times(state.amount))
        local root = app.tree.build(m, picked.key, state.amount, { choice = app.gather.choice(m) })
        if not root or root.raw then return text.tree.nothing end
        local kept = order_at(picked.key)
        order_button:SetCaption(kept and orders[kept].amount == state.amount and words.order_drop or words.order_keep)
        order_button:SetVisible(true)
        local raw, steps = {}, {}
        for _, node in ipairs(app.tree.totals(root)) do
            local amount = text.number(node.need)
            if node.kind == "resource" then
                local resource = m.resources[node.key]
                amount = text.right.amount(app.format.litres(node.need), resource and resource.units or "")
            end
            raw[#raw + 1] = { image = node.icon, icon = not node.icon and PLAIN[node.kind] or nil, count = amount,
                value = node.kind == "item" and node.key or nil,
                tip = { title = node.kind == "tag" and text.right.any(node.name) or node.name, lines = { amount } } }
        end
        -- how long each thing takes at the first bench of its station, and all of it together
        local times, total = {}, 0
        for _, step in ipairs(app.tree.steps(root)) do
            local set_of = step.set and m.sets[step.set]
            local bench = set_of and set_of.benches and set_of.benches[1]
            local seconds = bench and (bench.mw or 0) > 0 and (step.mj or 0) > step.crafts and step.mj / bench.mw or nil
            local at = bench and m.items[bench.item]
            local lines = { text.tree.crafts(step.crafts, step.hand and text.right.by_hand or step.station),
                text.tree.makes(step.crafts * step.makes, step.left) }
            if seconds then
                total = total + seconds
                lines[#lines + 1] = text.tree.each(text.duration(seconds / step.crafts), text.duration(seconds))
            end
            if at and not step.hand then lines[#lines + 1] = at.name end
            times[#times + 1] = text.tree.step(step.name, step.crafts, seconds and text.duration(seconds) or "", "")
            steps[#steps + 1] = { image = step.icon, icon = not step.icon and PLAIN.item or nil, count = text.right.times(step.crafts),
                value = step.key, tip = { title = step.name, lines = lines } }
        end
        -- the list of times gets the lines that are left in the column, and says how many more there are
        local shown = math.min(#gather_lines, math.ceil(#raw / COLUMNS)) + math.min(#craft_lines, math.ceil(#steps / COLUMNS))
        local room = math.floor((down - (CELL + 425 + shown * (CELL + GAP))) / 16) - 1
        times_label:Set(table.concat(text.some(times, math.max(1, room - 1)), "\n"))
        times_label:SetVisible(#times > 0 and room >= 2)
        total_label:Set(total > 0 and text.tree.total(text.duration(total)) or "")
        total_label:SetVisible(total > 0)
        gather_label:SetVisible(true)
        craft_label:SetVisible(true)
        fill_lines(gather_lines, raw)
        fill_lines(craft_lines, steps)
        return ""
    end

    local function show_details(m, picked)
        mode_line:Set(rows.about(m, picked, { internal = app.settings.internal_names }, inner, 11))
        local static = m.items[picked.static] or picked
        local told, flavour = nil, nil
        if app.describe then told, flavour = app.describe(static.row) end
        describe_label:Set(told or "")
        describe_label:SetVisible(told ~= nil)
        flavour_label:Set(flavour or "")
        flavour_label:SetVisible(flavour ~= nil)
        local lines = {}
        for _, hint in ipairs(picked.hints or {}) do lines[#lines + 1] = hint end
        if picked.workshop then lines[#lines + 1] = text.right.workshop end
        where_label:SetVisible(#lines > 0)
        for at, label in ipairs(where_lines) do
            label:Set(lines[at] or "")
            label:SetVisible(lines[at] ~= nil)
        end
        -- the numbers: a name and its figure to a line, and whole sentences under them. Weight and stack are in the line above.
        local groups, left = {}, down > 900 and 24 or 14
        for _, group in ipairs(app.stats and app.stats.of(static.row) or {}) do
            if group.id ~= "carrying" and left > 0 and #groups < #stat_groups then
                local names, values, notes = {}, {}, {}
                for _, line in ipairs(group.lines) do
                    if left > 0 then
                        left = left - 1
                        if line.value and line.value ~= "" then
                            names[#names + 1], values[#values + 1] = line.label, line.value
                        else
                            notes[#notes + 1] = line.text or line.label
                        end
                    end
                end
                groups[#groups + 1] = { title = group.title, names = names, values = values, notes = notes }
            end
        end
        for at, parts in ipairs(stat_groups) do
            local group = groups[at]
            parts.title:SetVisible(group ~= nil)
            parts.pair:SetVisible(group ~= nil and #group.names > 0)
            parts.notes:SetVisible(group ~= nil and #group.notes > 0)
            if group then
                parts.title:Set(group.title)
                parts.names:Set(table.concat(group.names, "\n"))
                parts.values:Set(table.concat(group.values, "\n"))
                parts.notes:Set(table.concat(group.notes, "\n"))
            end
        end
        return ""
    end

    -- The column shows the picked item, or goes back to the list when there is none.
    function show_detail()
        local m = model()
        local picked = m and state.detail and state.pick and m.items[state.pick]
        set(one_parts, false)
        if not picked then
            state.detail = false
            return show_list()
        end
        show_list()
        set(head_parts, true)
        picked_slot:Set({ look_of(picked, false) })
        title:Set(rows.shorten(picked.name, inner - CELL - 20, 13))
        previous:SetEnabled(app.history:can_back())
        star:SetIcon(app.favourites:has(picked.key) and ui.Icons.Has("star-off") and "star-off" or "star")
        local ready = rows.ready(m)
        local showing = state.view == "recipes" and state.mode or state.view
        for name, button in pairs(view_tabs) do button:SetActive(name == showing) end
        local nothing
        if state.view == "tree" and ready then
            nothing = show_tree(m, picked)
        elseif state.view == "details" then
            nothing = show_details(m, picked)
        else
            nothing = show_recipes(m, picked, ready)
        end
        message:Set(nothing)
        message:SetVisible(nothing ~= "")
    end

    -- The recipes of the picked item in the mode asked for, and the stations they are made at.
    local function prepare(m, picked)
        state.numbers = rows.ready(m) and rows.recipes(m, picked, state.mode, false) or {}
        local stations, seen = {}, {}
        for _, number in ipairs(state.numbers) do
            for _, id in ipairs(m.recipes[number].stations) do
                local set_of = m.sets[id]
                local at = set_of and tab_key(set_of)
                if set_of and not seen[at] and (set_of.hand or set_of.name ~= "") then
                    seen[at] = true
                    stations[#stations + 1] = { key = at, name = set_of.hand and text.right.by_hand or set_of.name, icon = set_of.icon,
                        plain = set_of.hand and "hand" or "hammer",
                        item = not set_of.hand and set_of.link and m.items[set_of.link] and set_of.link or nil }
                end
            end
        end
        if #stations > 1 then table.insert(stations, 1, { all = true, name = text.right.all_stations, plain = "layout-grid" }) end
        state.tabs = stations
    end

    -- Shows how an item is made ("make") or what it is used in ("used").
    function open(key, mode, stay)
        local m = model()
        local picked = m and key and m.items[key]
        if not picked then return end
        mode = mode or "make"
        if not stay then app.history:push(key, mode) end
        state.detail, state.pick, state.mode, state.card_page, state.tab, state.view = true, key, mode, 1, 1, "recipes"
        prepare(m, picked)
        show_detail()
    end

    function close_detail()
        state.detail = false
        app.history:clear()
        show_detail()
    end

    -- The item looked at before this one, or the list when there was none.
    function step_back()
        local m, entry = model(), app.history:back()
        while entry and not (m and m.items[entry.item]) do entry = app.history:back() end
        if entry then open(entry.item, entry.mode, true) else close_detail() end
    end

    -- favourites: on a shelf along the top, or beside a bench in the place of the game's own recipe list
    local favourite_blocks = {}
    local function favourite_place(panel, width, columns, count, titled)
        if titled then panel:Label(words.favourites, { size = small, dim = true }) end
        local size = even(width, columns)
        local place = { panel = panel, columns = columns, at = 1, pitch = size + GAP }
        place.hint = panel:Label(text.strip.empty(KEYS.favourite), { dim = true })
        place.lines = slot_lines(panel, count, columns, true, size)
        for _, line in ipairs(place.lines) do favourite_blocks[line] = place end
        -- the page line with an arrow at each end, there only while there is more than one page
        local pager_row = panel:Row()
        place.back = pager_row:Button(nil, function()
            place.at = place.at - 1
            show_favourites()
        end, { icon = "chevron-left" })
        place.page = pager_row:Label("", { size = small, dim = true, align = "center" })
        place.forth = pager_row:Button(nil, function()
            place.at = place.at + 1
            show_favourites()
        end, { icon = "chevron-right" })
        place.pager = pager_row.control
        place.pager:SetVisible(false)
        panel:Spacer(4)
        return place
    end
    local favourites = ui.Panel({ anchor = "top-left", x = L.shelf_x, y = 6, width = shelf, padding = 6, zoom = ZOOM, when = "always", opacity = 1,
        visible = false })
    local on_shelf = favourite_place(favourites, shelf, favourite_columns, favourite_rows, false)
    -- where the game's list sits on a bench screen, as shares of the screen before it is made smaller
    local list_place = L.bench_list()
    local box_width, box_height = list_place.width, list_place.height
    local box = ui.Panel({ anchor = "top-left", x = list_place.x, y = list_place.y,
        width = box_width, height = box_height, padding = 6, zoom = ZOOM, when = "always", opacity = 1, visible = false })
    local in_box = favourite_place(box, box_width, math.max(3, math.floor((box_width - 12 + GAP) / (CELL + GAP))),
        math.max(1, math.floor((box_height - 12 - 21 - 21 - 4 + GAP) / (CELL + GAP))), true)
    local favourite_places = { on_shelf, in_box }

    -- One page of the entries in a place. `held` is the entry being dragged: it is drawn faint where it would land.
    local function show_place(place, entries, held)
        local per = place.columns * (place.rows or #place.lines)
        local looks = {}
        for at = 1, per do
            local entry = entries[place.first + at]
            if entry and entry == held then
                local faint = {}
                for name, value in pairs(entry) do faint[name] = value end
                faint.dim = true
                entry = faint
            end
            looks[at] = entry
        end
        fill_lines(place.lines, looks)
    end

    function show_favourites()
        if state.drag then return end
        local m = model()
        -- beside a bench, with the list cut down to it, the favourites are cut down the same way. Orders always show.
        local made = state.only and state.station and state.station.items or nil
        local entries = {}
        for _, entry in ipairs(m and shelf_ids(function(key) return m.items[key] ~= nil and (not made or made[key] ~= nil) end) or {}) do
            local look = nil
            if entry.order then
                local order = orders[entry.order]
                local item = m.items[order.key]
                if item then
                    look = { image = item.icon, icon = not item.icon and PLAIN.item or nil, value = { order = entry.order },
                        count = text.right.times(order.amount), mark = ui.Icons.Has("clipboard-list") and "clipboard-list" or "list",
                        tip = { title = item.name, lines = { text.tree.title(order.amount), words.order_open, words.order_remove } } }
                end
            else
                look = look_of(m.items[entry.key], false)
            end
            if look then
                look.id = entry.id
                entries[#entries + 1] = look
            end
        end
        state.entries = entries
        for _, place in ipairs(favourite_places) do
            local per = place.columns * (place.rows or #place.lines)
            local pages = math.max(1, math.ceil(#entries / per))
            place.at = math.max(1, math.min(place.at, pages))
            place.first = (place.at - 1) * per
            show_place(place, entries, nil)
            place.hint:SetVisible(#entries == 0)
            place.page:Set(words.page(place.at, pages))
            place.pager:SetVisible(pages > 1)
            if place == on_shelf then
                state.shelf_pager = pages > 1
                state.shelf_lines = math.min(#place.lines, math.ceil(math.max(0, math.min(per, #entries - place.first)) / place.columns))
            end
            place.back:SetEnabled(place.at > 1)
            place.forth:SetEnabled(place.at < pages)
        end
    end

    -- Dragging a favourite or an order to another place among its own kind, on the page that shows. What it passes
    -- slides one place over, and it is put down where it is let go.
    local function drag_started(place, row, index)
        local entries = state.entries or {}
        local at = (place.first or 0) + (row - 1) * place.columns + index
        local entry = entries[at]
        if not entry then return end
        -- anywhere on the page that shows, favourites and orders alike
        state.drag = { place = place, from = at, at = at, low = place.first + 1,
            high = math.min(place.first + place.columns * (place.rows or #place.lines), #entries), entry = entry,
            list = table.move(entries, 1, #entries, 1, {}) }
        show_place(place, state.drag.list, entry)
    end
    local function drag_moved(dx, dy)
        local held = state.drag
        if not held then return end
        local place = held.place
        local pitch = place.pitch
        local shift = math.floor(dx / pitch + 0.5) + math.floor(dy / pitch + 0.5) * place.columns
        local target = math.max(held.low, math.min(held.high, held.from + shift))
        if target == held.at then return end
        table.insert(held.list, target, table.remove(held.list, held.at))
        show_place(place, held.list, held.entry)
        local step = target > held.at and 1 or -1
        for at = held.at, target - step, step do
            local on_page = at - place.first
            local line = place.lines[(on_page - 1) // place.columns + 1]
            if line then line:Slide((on_page - 1) % place.columns + 1, step * pitch, 0) end
        end
        held.at = target
    end
    local function drag_ended()
        local held = state.drag
        state.drag = nil
        if held and held.at ~= held.from then
            -- In the whole shelf, with what does not show now, it goes just before what follows it here, or just after
            -- what comes before it when it was put down last.
            local ids, moved = {}, held.entry.id
            for _, entry in ipairs(shelf_ids()) do
                if entry.id ~= moved then ids[#ids + 1] = entry.id end
            end
            local after, before = held.list[held.at + 1], held.list[held.at - 1]
            local at = #ids + 1
            for index, id in ipairs(ids) do
                if after and id == after.id then
                    at = index
                    break
                elseif not after and before and id == before.id then
                    at = index + 1
                    break
                end
            end
            table.insert(ids, at, moved)
            shelf_order = ids
            storage.Save("shelf", shelf_order)
        end
        show_favourites()
    end
    for _, place in ipairs(favourite_places) do
        for row, line in ipairs(place.lines) do
            line.DragStarted:Connect(function(_, index) drag_started(place, row, index) end)
            line.DragMoved:Connect(drag_moved)
            line.DragEnded:Connect(drag_ended)
        end
    end

    function view.favourite(key)
        -- on an order it takes the order off
        if type(key) == "table" and key.order and orders[key.order] then
            table.remove(orders, key.order)
            storage.Save("orders", orders)
            show_favourites()
            if state.detail then show_detail() end
            return
        end
        if type(key) ~= "string" then return end
        app.favourites:toggle(key)
        show_items()
        show_favourites()
        if state.detail then show_detail() end
    end

    -- a click on a slot: an item is opened, a category or a station is chosen. A station that is chosen already opens as an item.
    local function pressed(value, mode)
        if type(value) == "string" then return open(value, mode) end
        if type(value) ~= "table" then return end
        if value.category ~= nil then
            -- the chosen category clicked again goes back to all of them
            local wanted = value.category or nil
            state.category = wanted ~= state.category and wanted or nil
            show_tabs()
            return apply(false)
        end
        if value.order then
            -- an order opens as what it takes, for the number it was kept with
            local order = orders[value.order]
            if not order then return end
            open(order.key, "make")
            state.view, state.amount = "tree", order.amount
            return show_detail()
        end
        if value.tab then
            local station = state.tabs[value.tab]
            if station and station.item and (mode == "used" or value.tab == state.tab) then return open(station.item, "make") end
            state.tab, state.card_page = value.tab, 1
            show_detail()
        end
    end
    -- beside a bench a click on one of its items chooses the recipe there, as a click on the game's own tile would
    local function choose(value)
        return select_here(type(value) == "string" and at_bench(value) or nil)
    end
    for _, block in ipairs({ tabs, grid, picked_slot }) do blocks[#blocks + 1] = block end
    for _, block in ipairs(blocks) do
        local chooses = block == grid or favourite_blocks[block] ~= nil
        block.Activated:Connect(function(value)
            -- a second click on the same item straight after the first opens it, whatever the first click did
            local time = os.clock()
            if type(value) == "string" and state.clicked == value and time - (state.clicked_at or 0) < 0.4 then
                state.clicked = nil
                return open(value, "make")
            end
            state.clicked, state.clicked_at = value, time
            if chooses and choose(value) then return end
            pressed(value, "make")
        end)
        block.RightClicked:Connect(function(value) pressed(value, "used") end)
        block.MiddleClicked:Connect(function(value) view.favourite(value) end)
    end

    -- keys for what is under the mouse: an item of ours, the bench of a station, or an item in the game's own slots
    local function under_mouse()
        local value = ui.Hovered()
        if type(value) == "string" then return value end
        if type(value) == "table" and value.tab then
            local station = state.tabs[value.tab]
            return station and station.item or nil
        end
        return nil
    end
    local function in_game()
        local m = model()
        if not (m and crafting and crafting.GetHovered and state.near) then return nil end
        local kind, row = crafting:GetHovered()
        if kind == "item" then
            local key = row:lower()
            return m.items[key] and key or nil
        elseif kind == "recipe" then
            local number = m.recipe[row:lower()]
            local made = number and m.recipes[number]
            return made and (made.title or (made.outputs[1] and made.outputs[1].item)) or nil
        end
        return nil
    end
    local function keyed()
        if ui.Hovered() ~= nil then return under_mouse() end
        return in_game()
    end
    -- the favourite key over an order takes the order off
    local function keyed_or_order()
        local value = ui.Hovered()
        if type(value) == "table" and value.order then return value end
        return keyed()
    end
    local always = { in_menu = true }
    ui.Hotkey(KEYS.make, function() open(keyed(), "make") end, always)
    ui.Hotkey(KEYS.used, function() open(keyed(), "used") end, always)
    ui.Hotkey(KEYS.favourite, function() view.favourite(keyed_or_order()) end, always)
    ui.Hotkey("BackSpace", function() if state.detail then step_back() end end, always)
    -- The wheel over a panel turns its pages. The panel takes the wheel, so the game's hotbar does not turn with it.
    items.Scrolled:Connect(function(by)
        if not state.detail then
            state.page = state.page + by
            show_items()
        elseif state.view == "recipes" and #state.pages > 1 then
            state.card_page = state.card_page + by
            show_detail()
        end
    end)
    for _, place in ipairs(favourite_places) do
        place.panel.Scrolled:Connect(function(by)
            place.at = place.at + by
            show_favourites()
        end)
    end

    -- The game's own screens make room while the panels are beside them.
    local fit = ui.FitGame({ scale = L.scale, corner = "bottom-left", enabled = false })

    -- The game's screens the panels belong beside: every tab of its main menu, so nothing changes size between tabs,
    -- and a bench or a container. Not the escape menu.
    local function beside()
        local name = ui.GameScreen()
        return name ~= nil and name ~= "UMG_EscapeMenu"
    end

    -- What the open bench or crafting screen lists, by the item each recipe makes: { kind, items = { [key] = { row, valid, order } } }.
    local function read_station()
        local m = model()
        if not (crafting and state.screen and m and rows.ready(m)) then return nil end
        local listed, _, kind = crafting:GetRecipes()
        if not listed or #listed == 0 then return nil end
        local station = { kind = kind, items = {} }
        for order, entry in ipairs(listed) do
            local number = m.recipe[entry.row:lower()]
            local made = number and m.recipes[number]
            if made then
                local keys = {}
                for _, output in ipairs(made.outputs) do keys[#keys + 1] = output.item end
                if made.title then keys[#keys + 1] = made.title end
                for _, key in ipairs(keys) do
                    local known = station.items[key]
                    if not known then
                        station.items[key] = { row = entry.row, valid = entry.valid, order = order, number = number }
                    elseif entry.valid and not known.valid then
                        known.row, known.valid, known.number = entry.row, true, number
                    end
                end
            end
        end
        return station
    end

    -- Another screen is open, or the switch was turned: the list, the game's own list and the favourites follow.
    function station_changed()
        local station = read_station()
        state.station = station
        state.replace = station ~= nil and state.only and station.kind == "bench"
        if crafting then crafting:SetListHidden(state.replace) end
        show_tabs()
        apply(false)
        show_favourites()
        show_detail()
    end

    -- What can be made changes as things are picked up and used, so the bench is asked again now and then.
    local function check_station()
        local fresh = read_station()
        if not fresh or not state.station then return end
        local changed = false
        for key, entry in pairs(fresh.items) do
            local old = state.station.items[key]
            if not old or old.valid ~= entry.valid then
                changed = true
                break
            end
        end
        state.station = fresh
        if changed then
            show_tabs()
            apply(true)
            show_favourites()
        end
    end

    -- The panels show beside those screens in a prospect, with the Wax menu, and wherever the open key brought them up.
    local frames, play, was_near = 0, false, false
    local function place()
        if frames % 30 == 0 then play = game.InProspect == true end
        frames = frames + 1
        local near = state.on and play and beside()
        state.near = near
        -- each kind of screen is moved up as far as its own top allows, so it sits just under the favourites
        if near then
            local lines = not state.replace and (state.shelf_lines or 0) or nil
            fit:Set(L.fit(ui.GameScreen() or "", lines, state.shelf_pager == true))
        end
        fit:SetEnabled(near)
        -- which bench is open: looked at the frame a screen comes up, then a few times a second
        local screen = state.screen
        if not near then
            screen = nil
        elseif crafting and (not was_near or frames % 6 == 0) then
            local number, kind = crafting:GetScreen()
            screen = number and (kind .. number) or nil
        end
        was_near = near
        if screen ~= state.screen then
            state.screen = screen
            station_changed()
        elseif state.station and frames % 120 == 0 then
            check_station()
        end
        -- with the Wax menu they come up too, but not over the escape menu: the column would cover its buttons
        local escape = play and ui.GameScreen() == "UMG_EscapeMenu"
        local there = state.on and (state.bare or near or (play and not escape and (ui.IsOpen() or ui.IsPreview())))
        items:SetVisible(there)
        favourites:SetVisible(there and not state.replace)
        box:SetVisible(there and state.replace == true)
        if there then
            app.job.want()
        elseif state.detail then
            close_detail()
        end
    end

    local function refresh()
        show_tabs()
        -- the bench is read again once the recipes are known
        if state.screen and not state.station then station_changed() end
        apply(true)
        show_favourites()
        local m = model()
        local picked = m and state.detail and state.pick and m.items[state.pick]
        if picked then prepare(m, picked) end
        show_detail()
        place()
    end

    ui.Closed:Connect(function()
        state.bare = false
        place()
    end)

    -- The open key hides the panels while they show. While they do not, it frees the mouse and shows them on their own.
    local function toggle()
        if items:IsVisible() then
            if state.bare then return ui.Close() end
            state.on = false
            return place()
        end
        state.on = true
        place()
        if items:IsVisible() then return end
        state.bare = true
        place()
        ui.Open({ windows = false })
    end

    -- every frame, so the game's screen is its smaller size from the frame it opens
    task.spawn(function()
        while true do
            place()
            task.wait()
        end
    end)
    refresh()

    return { refresh = refresh, toggle = toggle, showing = function() return items:IsVisible() end }
end

return view
