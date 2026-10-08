-- The browser beside the game's own screens: a column at the right that lists every item, or shows one item's recipes and
-- details, and favourites along the top. Nothing is drawn over the game's screens, so they stay in use the whole time.

local view = {}

local FIT = 0.85            -- the game's screens are drawn this much smaller, which frees the column and the band
local GAP = 2
local COLUMNS, TAB_COLUMNS, TAB_ROWS = 5, 6, 5
local CARDS = 6
local PLAIN = { item = "package", tag = "tags", resource = "droplet" }
local KEYS = { make = "R", used = "U", favourite = "A" }
local MIDDLE = "MiddleMouseButton"
local POP = 2               -- a swept slot moves this far and settles: never more than the gap, so the mouse stays off the next slot
local KEEP_CREATURES = true -- creatures can be kept on the shelf among the favourites and orders: false takes their star and key away
local CREATURES = "creatures"   -- stands among an item's recipes for the card of its creatures

function view.start(app)
    local text, rows, search = app.text, app.rows, app.search
    -- on a Wax from before the panels it says what it needs and shows nothing
    if not (ui.Panel and ui.FitGame and ui.GameScreen and ui.ScreenSize) then
        ui.Notify(text.problem.needs_wax(app.needs), { kind = "bad", seconds = 10 })
        return {}
    end
    local words = text.panel
    local theme = ui.Theme()
    local small = theme.small_size
    local crafting = game.Crafting
    -- game.Research is newer than the Wax this mod asks for: without it no block has a research line
    local has_research, research = pcall(function() return game.Research end)
    if not has_research then research = nil end
    local state = { query = "", page = 1, list = {}, mode = "make", view = "recipes", card_page = 1, tab = 1, pass = 0, on = true,
        bare = false, detail = false, amount = 1, numbers = {}, tabs = {}, pages = {}, only = app.settings.bench_only ~= false,
        shown = {}, first = 0 }
    -- a Wax that can say whether a key is held: the favourite key can then be held and moved over items
    local can_hold = type(ui.IsKeyDown) == "function"

    -- every size and place comes from the screen's size, worked out in layout.lua
    local wide, high = ui.ScreenSize()
    -- while the game starts it has no screen yet
    while not (wide and high and wide >= 200 and high >= 200) do
        task.wait(0.25)
        wide, high = ui.ScreenSize()
    end
    local layout = require(mod.layout)
    local L = layout.compute(wide, high)
    -- The numbers for a screen of this size. Each panel's place function asks, so they are worked out once for a change of
    -- the screen, and the game's own screens are put beside the panels again in the same frame. Nothing is built again.
    local refit = nil
    local function laid_out(width, height)
        if math.abs(width - L.width) > 0.005 or math.abs(height - L.height) > 0.005 then
            L = layout.compute(width, height)
            if refit then refit() end
        end
        return L
    end
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

    -- The order of the shelf, favourites, orders and kept creatures together: "f:<item>", "o:<item>" and "c:<creature>".
    -- What is not in it yet goes last.
    local shelf_order = {}
    for _, id in ipairs(storage.Load("shelf", {})) do
        if type(id) == "string" then shelf_order[#shelf_order + 1] = id end
    end
    -- Every favourite, order and kept creature there is, in the shelf's order. `listed` leaves favourites out that it
    -- does not answer for, `met` creatures.
    local function shelf_ids(listed, met)
        local ids, rank = {}, {}
        for at, id in ipairs(shelf_order) do rank[id] = at end
        for at, order in ipairs(orders) do ids[#ids + 1] = { id = "o:" .. order.key, order = at, rank = rank["o:" .. order.key] } end
        for _, key in ipairs(app.favourites:list(listed)) do ids[#ids + 1] = { id = "f:" .. key, key = key, rank = rank["f:" .. key] } end
        for _, key in ipairs(KEEP_CREATURES and app.kept:list(met) or {}) do
            ids[#ids + 1] = { id = "c:" .. key, creature = key, rank = rank["c:" .. key] }
        end
        for at, entry in ipairs(ids) do entry.rank = entry.rank or (1000000 + at) end
        table.sort(ids, function(a, c) return a.rank < c.rank end)
        return ids
    end

    local show_items, show_tabs, show_list, show_favourites, show_detail, open, close_detail, station_changed, step_back, time_at
    -- The Bestiary side (creature_view.lua), started further down, and what the two sides share: which one the column
    -- shows, the row of the two tabs, and the counts on them.
    local beasts, swap, set_side, show_sides
    state.side, state.box = "items", ""

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

    -- The hold of the favourite key while it lasts. One that takes things off only marks them (leaving) until the key comes up.
    local sweep = nil
    local function is_favourite(key)
        return app.favourites:has(key) and not (sweep and sweep.leaving["f:" .. key])
    end
    local function is_kept(id)
        return app.kept:has(id) and not (sweep and sweep.leaving["c:" .. id])
    end

    -- What the tooltip of an item says, worked out when the mouse gets there.
    local function tip_of(key)
        local m = model()
        local item = m and m.items[key]
        if not item then return nil end
        local lines = {}
        if rows.ready(m) then
            local names = station_names(m, item)
            -- what no recipe makes may come from creatures
            local _, givers = beasts.droppers(key, 0)
            lines[#lines + 1] = #names > 0 and text.tip.made_at(names, 3) or (item.hints and item.hints[1])
                or (givers > 0 and text.beasts.dropped_by(givers)) or text.tip.no_recipe
            -- how long it takes: the recipe of the open bench when it has one, else the first
            local listed = here_of(key)
            local number = listed and listed.number or rows.recipes(m, item, "make", false)[1]
            local made = number and rows.recipe(m, app.job.needs, number, item, "make") or nil
            lines[#lines + 1] = made and text.tip.takes(time_at(made, nil)) or ""
            lines[#lines + 1] = made and text.tip.gives(made.gives) or ""
            lines[#lines + 1] = text.tip.used_in(#rows.recipes(m, item, "used", false))
        end
        local level = item.level and m.levels and m.levels[item.level]
        if level and level.name then lines[#lines + 1] = { level.name, "warn" } end
        if is_favourite(key) then lines[#lines + 1] = { text.tip.favourite, "accent" } end
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
            dim = starred ~= false and here ~= nil and not here.valid, mark = starred ~= false and is_favourite(key) and "star" or nil,
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
    local items = ui.Panel({ anchor = "right", x = 4, y = 0, width = column, height = tall, padding = 6, zoom = L.zoom, when = "always", opacity = 1,
        visible = false, place = function(width, height) return { zoom = laid_out(width, height).zoom } end })
    -- a Wax from before panels could be placed again: another screen size or interface size means laying everything out anew
    local placed = items.Resized ~= nil
    if not placed and ui.ScreenChanged and mod.Reload then ui.ScreenChanged:Connect(function() mod.Reload() end) end
    -- The row of the two sides, the same in both panels: Items and Bestiary, each half the column whatever it says.
    -- show(side, counts, off): the side that shows, how many each found while text is typed, and whether the Bestiary is off.
    local function side_tabs(panel)
        local row = panel:Row({ height = L.side_row })
        local pair = { row = row.control }
        for _, name in ipairs({ "items", "beasts" }) do
            pair[name] = row:Button(text.beasts.side(name), function() set_side(name) end, { tab = true })
        end
        function pair.show(side, counts, off)
            for _, name in ipairs({ "items", "beasts" }) do
                local caption = text.beasts.side(name, counts and counts[name] or nil)
                if caption ~= pair[name .. "_caption"] then
                    pair[name .. "_caption"] = caption
                    pair[name]:SetCaption(caption)
                end
                pair[name]:SetActive(name == side)
            end
            if off ~= pair.off then
                pair.off = off
                pair.beasts:SetEnabled(not off)
                -- a Wax from before buttons had tips shows it switched off and no more
                if pair.beasts.SetTip then pair.beasts:SetTip(off and text.beasts.changed or nil) end
            end
        end
        return pair
    end
    local sides = side_tabs(items)
    local tabs = items:Slots({ columns = TAB_COLUMNS, rows = TAB_ROWS, size = TAB, gap = GAP, below = L.snug })
    local category_line = items:Label("", { size = small, dim = true, align = "center" })
    local switch_row = items:Row()
    switch_row:Toggle(words.bench_only, state.only, function(on)
        state.only = on
        app.settings.bench_only = on
        app.save()
        station_changed()
    end)
    switch_row.control:SetVisible(false)
    -- A page line: an arrow, the page, an arrow. The item list and the favourites all have this one. turn(by) is told -1 or 1.
    local function page_line(panel, turn)
        local row = panel:Row()
        local line = { row = row.control }
        line.back = row:Button(nil, function() turn(-1) end, { icon = "chevron-left" })
        line.label = row:Label("", { align = "center" })
        line.forth = row:Button(nil, function() turn(1) end, { icon = "chevron-right" })
        -- page of pages, and the arrow that leads nowhere switched off
        function line.set(page, pages)
            line.label:Set(words.page(page, pages))
            line.back:SetEnabled(page > 1)
            line.forth:SetEnabled(page < pages)
        end
        return line
    end
    local head = page_line(items, function(by)
        state.page = state.page + by
        show_items()
    end)
    local note_label = items:Label("", { dim = true, align = "center" })
    note_label:SetVisible(false)
    local grid = items:Slots({ columns = COLUMNS, rows = grid_rows, size = CELL, gap = GAP, below = L.snug })
    local find = items:Input(nil, { hint = words.search, clear = true })
    -- a Wax whose game.Crafting finds what the mouse is over on every screen of the game says so with IsTyping
    local keys_line = items:Label(text.right.keys(KEYS), { size = small, dim = true, align = "center" })
    local list_parts = { sides.row, tabs, category_line, head.row, grid, find, keys_line }

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
            -- the same filled picture as the Bestiary side's tile for everything
            looks[1] = { image = require(mod.creature_view).ALL, symbol = true, value = { category = false }, selected = state.category == nil,
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
        local looks, first, shown = {}, (state.page - 1) * per, {}
        for at = 1, per do
            local item = state.list[first + at]
            if item then
                looks[at] = look_of(item)
                shown[item.key] = at
            end
        end
        state.shown, state.first = shown, first
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
        head.set(state.page, pages)
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
        show_sides()
    end

    -- What is typed in the item side's box: the list of items follows a frame later. The Bestiary side has a box of its own.
    local function typed_in(typed)
        if typed == state.query then return end
        state.query = typed
        if state.queued then return end
        state.queued = true
        task.defer(function()
            state.queued = false
            apply(false)
        end)
    end
    find.Typed:Connect(function(typed)
        state.box = typed
        typed_in(typed)
    end)

    -- Then, in the same column, one item: its picture and name, four tabs, and what the chosen tab shows.
    local top = items:Row()
    -- it reads the list it goes to: the side that was showing
    local back_button = top:Button(words.back, function() close_detail() end, { icon = "arrow-left", stretch = false })
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
    -- what the player has to spend on research, above the recipes that ask for it
    local points_line = items:Label("", { size = small, dim = true, align = "center" })
    local pager = items:Row()
    local card_back = pager:Button(nil, function() state.card_page = state.card_page - 1 show_detail() end, { icon = "chevron-left" })
    local card_label = pager:Label("", { align = "center", dim = true })
    local card_forth = pager:Button(nil, function() state.card_page = state.card_page + 1 show_detail() end, { icon = "chevron-right" })
    sides.turn = { back = card_back, forth = card_forth, row = pager.control }
    -- Researches a recipe's node with the player's points, in the task of the button that asked, then says how it went.
    local function research_run(row)
        if state.researching then return end
        local found, plan = pcall(research.GetPlan, research, row)
        if not (found and plan and plan.can) then return show_detail() end
        state.researching, state.asking = row, nil
        show_detail()
        local ran, done, _, failed = pcall(research.Unlock, research, row)
        state.researching = nil
        if ran and done then
            ui.Notify(text.research.researched(plan.name), { kind = "good" })
        else
            if not ran then log:warn("%s", tostring(done)) end
            ui.Notify(text.research.refused(ran and failed or plan.name), { kind = "warn" })
        end
        show_detail()
    end
    -- The research line of a block: a mark when its recipe is researched, a button when it can be, else what is missing.
    local function research_line(panel)
        local line = {}
        local done = panel:Row()
        done:Icon("check", { size = 12, color = theme.good })
        done:Label(text.research.done, { size = small, dim = true })
        line.note = panel:Label("", { size = small, dim = true })
        line.button = panel:Button(text.research.button(1), function()
            if not line.row or not line.ask or state.researching then return end
            state.asking = line.row
            show_detail()
        end)
        local pair = panel:Row()
        line.confirm = pair:Button(text.research.all, function() if line.row then research_run(line.row) end end, { primary = true })
        pair:Button(text.research.cancel, function()
            state.asking = nil
            show_detail()
        end, { stretch = false })
        line.done, line.pair = done.control, pair.control
        return line
    end
    -- told: what unlock.research made of the game's answer for the recipe `row`, or nothing
    local function show_research(line, row, told)
        local kind = told and told.kind
        line.row, line.ask = row, told and told.ask or nil
        local asking = line.ask ~= nil and state.asking == row
        line.done:SetVisible(kind == "done")
        line.button:SetVisible((kind == "buy" or kind == "points") and not asking)
        line.pair:SetVisible(asking)
        line.note:SetVisible(asking or kind == "level" or kind == "points")
        if kind == "buy" or kind == "points" then
            line.button:SetCaption(told.caption)
            line.button:SetEnabled(kind == "buy" and state.researching == nil)
        end
        if asking then
            line.confirm:SetCaption(told.confirm)
            line.note:Set(told.ask)
            line.note:SetColor(theme.text)
        elseif kind == "level" or kind == "points" then
            line.note:Set(told.line)
            line.note:SetColor(kind == "level" and theme.warn or theme.dim)
        end
    end
    -- How much of the column a research line takes. The room for the question is kept from the start, so a press moves nothing.
    local function research_room(told)
        if not told then return 0 end
        if told.kind == "points" then return 60 end
        if told.kind ~= "buy" then return 24 end
        return #rows.wrap(told.ask, inner * 0.94, small) * 16 + 44
    end

    -- a recipe is what goes in, then an arrow and what comes out on a line of its own
    local cards = {}
    for at = 1, CARDS do
        local card = { inputs = slot_lines(items, 2, COLUMNS) }
        card.output = slot_lines(items, 1, COLUMNS)
        card.needs = items:Label("", { size = small, dim = true })
        card.research = research and research_line(items) or nil
        card.rule = items:Separator()
        cards[at] = card
    end
    local recipe_parts = { station_lines[1], station_lines[2], station_line, here_button, points_line, pager.control }
    for _, card in ipairs(cards) do
        for _, part in ipairs({ card.inputs[1], card.inputs[2], card.output[1], card.needs, card.rule }) do
            recipe_parts[#recipe_parts + 1] = part
        end
        local line = card.research
        for _, part in ipairs(line and { line.done, line.note, line.button, line.pair } or {}) do
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
    -- how a name and its figure can share a line, and the room each side then has for its text
    local PAIR_SPLITS = rows.PAIR_SPLITS
    -- Which split shows every line of a group whole. Lines no split has room for are named, to go under as sentences.
    local function pair_fit(names, values)
        return rows.pair_fit(names, values, inner)
    end
    for at = 1, 6 do
        local group = { title = items:Label("", { size = small, dim = true }) }
        -- the same pair three times, each sharing the line another way: the one whose texts all fit is shown
        group.pairs = {}
        for index, split in ipairs(PAIR_SPLITS) do
            local pair = items:Row()
            group.pairs[index] = { control = pair.control, names = pair:Label("", { weight = split[1] }),
                values = pair:Label("", { align = "right", weight = split[2] }) }
            detail_parts[#detail_parts + 1] = pair.control
        end
        group.notes = items:Label("", { size = small, dim = true })
        stat_groups[at] = group
        for _, part in ipairs({ group.title, group.notes }) do detail_parts[#detail_parts + 1] = part end
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

    -- What one craft gives at the chosen station, or over all of them: "52 XP".
    local function gives_at(made, chosen)
        return rows.gives(rows.xp(made, chosen and not chosen.all and chosen.name or nil))
    end

    -- The recipes of one station as pages: as many to a page as the column has room for.
    local function paginate(m, numbers, more)
        local pages, page, used = {}, {}, 0
        for _, number in ipairs(numbers) do
            local height
            if number == CREATURES then
                local _, lines = L.creature_card(state.creatures or 0, state.mode ~= "make")
                height = L.card(lines)
            else
                local made = m.recipes[number]
                local inputs = #made.inputs + #made.tags_in + #made.res_in
                height = L.card(1 + math.max(1, math.ceil(inputs / COLUMNS))) + more(number)
            end
            if #page > 0 and (#page >= CARDS or used + height > budget - (state.points_shown and 20 or 0)) then
                pages[#pages + 1] = page
                page, used = {}, 0
            end
            page[#page + 1] = number
            used = used + height
        end
        if #page > 0 then pages[#pages + 1] = page end
        return pages
    end

    -- The card of an item's creatures, drawn as a recipe. On Recipe: those that give it, an arrow, the item. On Uses:
    -- the item, an arrow, those it is used on. More than fit: the last cell stands for the rest and lists them all.
    local function show_creatures(card, picked)
        local used = state.mode ~= "make"
        local list = used and beasts.users or beasts.droppers
        local _, total = list(picked.key, 0)
        local shown = L.creature_card(total, used)
        local looks = list(picked.key, shown)
        if total > shown then
            local rest = total - shown + 1
            looks[shown] = { image = require(mod.creature_view).PAWS, symbol = true, count = text.plus(rest),
                value = { [used and "users" or "droppers"] = picked.key },
                tip = { title = text.and_more(rest), lines = { text.beasts.list_them } } }
        end
        local arrow = { icon = "arrow-right", plain = true }
        -- the item itself: it is what is open, so it takes no click
        local own = { image = picked.icon, icon = not picked.icon and PLAIN.item or nil, tip = { title = picked.name } }
        if used then
            local first, rest = { own, arrow }, {}
            local room = #card.inputs * COLUMNS
            for _, look in ipairs(looks) do
                if #first < room then first[#first + 1] = look else rest[#rest + 1] = look end
            end
            fill_lines(card.inputs, first)
            fill_lines(card.output, rest)
        else
            fill_lines(card.inputs, looks)
            fill_lines(card.output, { arrow, own })
        end
        card.needs:Set(used and text.beasts.used_on(total) or text.beasts.dropped_by(total))
        card.needs:SetVisible(true)
        card.rule:SetVisible(true)
    end

    local function show_recipes(m, picked, ready)
        mode_line:Set(ready and text.right.mode(state.mode, #state.numbers) or text.status.reading())
        local stations = state.tabs
        state.tab = math.max(1, math.min(state.tab, math.max(1, #stations)))
        local station_looks = {}
        for at, station in ipairs(stations) do
            station_looks[at] = { image = station.icon, icon = not station.icon and station.plain or nil, symbol = station.symbol,
                value = { tab = at },
                selected = at == state.tab, tip = { title = station.name, lines = station.item and { words.station } or nil } }
        end
        fill_lines(station_lines, station_looks)
        local chosen, here = stations[state.tab], {}
        for _, number in ipairs(state.numbers) do
            local fits = chosen == nil or chosen.all == true
            if not fits and not chosen.creatures then
                for _, id in ipairs(m.recipes[number].stations) do
                    local set_of = m.sets[id]
                    if set_of and tab_key(set_of) == chosen.key then fits = true break end
                end
            end
            if fits then here[#here + 1] = number end
        end
        -- its creatures come last, as one card more
        if state.creatures and (chosen == nil or chosen.all or chosen.creatures) then here[#here + 1] = CREATURES end
        station_line:Set(chosen and chosen.name or "")
        station_line:SetVisible(chosen ~= nil)
        -- the open bench makes this: one press chooses it there
        local listed = state.mode == "make" and here_of(picked.key) or nil
        here_button:SetVisible(listed ~= nil)
        local have = nil
        if research and state.mode == "make" then
            local found, available = pcall(research.GetPoints, research)
            have = found and tonumber(available) or nil
        end
        state.points_shown = have ~= nil
        points_line:Set(have and text.research.have(have) or "")
        points_line:SetVisible(have ~= nil)
        -- what the game says about researching each recipe here, asked once for this showing
        local told = {}
        local function told_of(number)
            if not (research and state.mode == "make") then return nil end
            if told[number] == nil then
                local found, plan = pcall(research.GetPlan, research, m.recipes[number].row)
                told[number] = found and app.unlock.research(plan, text.research) or false
            end
            return told[number] or nil
        end
        local pages = paginate(m, here, function(number) return research_room(told_of(number)) end)
        state.pages = pages
        state.card_page = math.max(1, math.min(state.card_page, math.max(1, #pages)))
        card_label:Set(words.page(state.card_page, math.max(1, #pages)))
        card_back:SetEnabled(state.card_page > 1)
        card_forth:SetEnabled(state.card_page < #pages)
        pager.control:SetVisible(#pages > 1)
        local page = pages[state.card_page] or {}
        for at, card in ipairs(cards) do
            local made = page[at] and page[at] ~= CREATURES and rows.recipe(m, app.job.needs, page[at], picked, state.mode) or nil
            if page[at] == CREATURES then
                show_creatures(card, picked)
            elseif made then
                local inputs, outputs = {}, { { icon = "arrow-right", plain = true } }
                for _, entry in ipairs(made.inputs) do inputs[#inputs + 1] = entry_look(entry) end
                for _, entry in ipairs(made.outputs) do outputs[#outputs + 1] = entry_look(entry) end
                fill_lines(card.inputs, inputs)
                fill_lines(card.output, outputs)
                local needs = made.needs
                local line = text.join(state.mode ~= "make" and made.name or nil, made.random and text.right.one_of or nil,
                    time_at(made, chosen), gives_at(made, chosen),
                    needs and needs.short or nil, needs and needs.extra or nil, not needs and made.level or nil)
                card.needs:Set(line)
                card.needs:SetVisible(line ~= "")
                if card.research then show_research(card.research, made.row, told_of(page[at])) end
                card.rule:SetVisible(true)
            end
        end
        if ready and #here == 0 then
            -- while the game's creatures can be listed, drops are: the sentence no longer says they are not
            local none = (app.beasts.off() or app.beasts.failed) and text.right.no_recipe or text.beasts.no_recipe
            return state.mode == "make" and ((picked.hints and picked.hints[1]) or none) or text.right.no_use
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
            raw[#raw + 1] = { image = node.icon, icon = not node.icon and PLAIN[node.kind] or nil,
                count = node.kind == "resource" and tostring(app.format.litres(node.need)) or text.short(node.need),
                value = node.kind == "item" and node.key or nil,
                tip = { title = node.kind == "tag" and text.right.any(node.name) or node.name, lines = { amount } } }
        end
        -- how long each thing takes at the first bench of its station and the XP it gives there, and all of it together
        local times, total, gained = {}, 0, 0
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
            -- a step whose XP is not known leaves the sum out
            local xp = step.xp and rows.gives(step.xp) or ""
            if not step.xp then gained = nil end
            if xp ~= "" then
                if gained then gained = gained + step.xp end
                lines[#lines + 1] = text.tree.gives(rows.gives(step.xp // step.crafts), xp)
            end
            if at and not step.hand then lines[#lines + 1] = at.name end
            times[#times + 1] = text.tree.step(step.name, step.crafts, seconds and text.duration(seconds) or "", "", xp)
            steps[#steps + 1] = { image = step.icon, icon = not step.icon and PLAIN.item or nil, count = text.short(step.crafts),
                value = step.key, tip = { title = step.name, lines = lines } }
        end
        -- the list of times gets the lines that are left in the column, and says how many more there are
        local shown = math.min(#gather_lines, math.ceil(#raw / COLUMNS)) + math.min(#craft_lines, math.ceil(#steps / COLUMNS))
        local all = gained and rows.gives(gained) or ""
        local summed = total > 0 or all ~= ""
        -- with its XP the sentence above the list is a line longer
        local sentence = (total > 0 and all ~= "") and 16 or 0
        local room = math.floor((down - (CELL + 425 + sentence + shown * (CELL + GAP))) / 16) - 1
        times_label:Set(table.concat(text.some(times, math.max(1, room - 1)), "\n"))
        times_label:SetVisible(#times > 0 and room >= 2)
        total_label:Set(summed and text.tree.total(total > 0 and text.duration(total) or "", all) or "")
        total_label:SetVisible(summed)
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
            local chosen = nil
            if group and #group.names > 0 then
                local best, left = pair_fit(group.names, group.values)
                -- a line too long for any split is written out under the others, where it has the whole width
                for index = #left, 1, -1 do
                    local line = left[index]
                    table.insert(group.notes, 1, text.pair(group.names[line], group.values[line]))
                    table.remove(group.names, line)
                    table.remove(group.values, line)
                end
                chosen = #group.names > 0 and best or nil
            end
            for index, pair in ipairs(parts.pairs) do
                pair.control:SetVisible(index == chosen)
                if index == chosen then
                    pair.names:Set(table.concat(group.names, "\n"))
                    pair.values:Set(table.concat(group.values, "\n"))
                end
            end
            parts.notes:SetVisible(group ~= nil and #group.notes > 0)
            if group then
                parts.title:Set(group.title)
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
            show_list()
            return swap()
        end
        show_list()
        set(head_parts, true)
        local back_to = state.side == "beasts" and text.beasts.back or words.back
        if back_to ~= sides.back_to then
            sides.back_to = back_to
            back_button:SetCaption(back_to)
        end
        picked_slot:Set({ look_of(picked, false) })
        -- a long name takes a second line beside the picture. Only one too long for two lines is cut short
        local name_lines = rows.wrap(picked.name, (inner - CELL - 20) * 0.94, 13)
        if #name_lines > 2 then
            name_lines = { name_lines[1], rows.shorten(table.concat(name_lines, " ", 2), inner - CELL - 20, 13) }
        end
        title:Set(table.concat(name_lines, "\n"))
        previous:SetEnabled(app.history:can_back())
        star:SetIcon(is_favourite(picked.key) and ui.Icons.Has("star-off") and "star-off" or "star")
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
        swap()
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
        -- The creatures that give the item, or that it is used on, are one card after the recipes, with a tab of its
        -- own among the stations: last, or where it still shows when there are more stations than the tabs hold.
        local _, creatures = beasts[state.mode == "make" and "droppers" or "users"](picked.key, 0)
        state.creatures = creatures > 0 and creatures or nil
        if state.creatures then
            local room = #station_lines * COLUMNS
            table.insert(stations, #stations + 2 <= room and #stations + 1 or room - 2,
                { creatures = true, name = text.beasts.dropped, icon = require(mod.creature_view).PAWS, symbol = true })
        end
        -- the game's own filled pictures, as the stations beside them and the tiles of the two lists have
        if #stations > 1 then
            table.insert(stations, 1, { all = true, name = text.right.all_stations, icon = require(mod.creature_view).ALL, symbol = true })
        end
        state.tabs = stations
    end

    -- Shows how an item is made ("make") or what it is used in ("used").
    function open(key, mode, stay)
        local m = model()
        local picked = m and key and m.items[key]
        if not picked then return end
        -- a creature's page gives way: the item is in the item panel
        beasts.leave()
        -- an item's page says which creatures give it and which it is used on, so they are wanted now
        app.beasts.want()
        mode = mode or "make"
        if not stay then app.history:push(key, mode) end
        state.detail, state.pick, state.mode, state.card_page, state.tab, state.view = true, key, mode, 1, 1, "recipes"
        state.asking = nil
        prepare(m, picked)
        show_detail()
    end

    -- Back to the list of the side that shows, from an item or from a creature: always one press.
    function close_detail()
        state.detail = false
        app.history:clear()
        beasts.close()
        show_detail()
    end

    -- The item or the creature looked at before this one, or the list when there was none.
    function step_back()
        local m, entry = model(), app.history:back()
        local function known(seen)
            if seen.creature then return beasts.thing.known(seen.creature) end
            return m ~= nil and m.items[seen.item] ~= nil
        end
        while entry and not known(entry) do entry = app.history:back() end
        if not entry then return close_detail() end
        if entry.creature then return beasts.open(entry.creature, entry.mode, true, entry.variant) end
        open(entry.item, entry.mode, true)
    end

    -- favourites: on a shelf along the top, or beside a bench in the place of the game's own recipe list
    local favourite_blocks = {}
    local function favourite_place(panel, width, columns, count, titled)
        if titled then panel:Label(words.favourites, { size = small, dim = true }) end
        local size = even(width, columns)
        local place = { panel = panel, columns = columns, at = 1, pitch = size + GAP }
        place.hint = panel:Label(text.strip.empty(KEYS.favourite, can_hold), { dim = true })
        place.lines = slot_lines(panel, count, columns, true, size)
        for _, line in ipairs(place.lines) do favourite_blocks[line] = place end
        local function turn(by)
            place.at = place.at + by
            show_favourites()
        end
        place.turn = turn
        if titled then
            -- the page line, there only while there is more than one page
            place.pager = page_line(panel, turn)
            place.pager.row:SetVisible(false)
        else
            -- the shelf keeps room for its page line, which is made further down from small panels of its own
            place.room = panel:Spacer(layout.PAGE_LINE.above - GAP + layout.PAGE_LINE.height + GAP)
            place.room:SetVisible(false)
        end
        panel:Spacer(4)
        return place
    end
    local favourites = ui.Panel({ anchor = "top-left", x = L.shelf_x, y = L.top, width = L.shelf, padding = 6, zoom = L.zoom, when = "always", opacity = 1,
        visible = false, place = function(width, height)
            local now = laid_out(width, height)
            return { x = now.shelf_x, y = now.top, width = now.shelf, zoom = now.zoom }
        end })
    local on_shelf = favourite_place(favourites, L.shelf, L.favourite_columns, favourite_rows, false)
    -- The shelf's page line is the column's in a compact form: an arrow, the page, an arrow, as wide as what is in it
    -- and in the middle under the shelf's rows. Its three parts are small panels of their own, so that each stands exactly
    -- where it should, which a row of a panel cannot do.
    local LINE = layout.PAGE_LINE
    local turner = { pieces = {}, wide = false }
    local function pager_at() return L.pager_place(#on_shelf.lines, turner.wide) end
    -- dx(at): how far right of the line's left end the part starts, in the line's own units
    local function piece(make, width, dx, dy)
        local entry = {}
        function entry.where(at) return at.x + dx(at) * at.zoom, at.y + dy * at.zoom end
        local at = pager_at()
        local x, y = entry.where(at)
        entry.panel = make({ anchor = "top-left", x = x, y = y, width = width, padding = 0, zoom = at.zoom, when = "always",
            background = false, movable = false, visible = false,
            place = function(screen_width, screen_height)
                laid_out(screen_width, screen_height)
                local now = pager_at()
                local now_x, now_y = entry.where(now)
                return { x = now_x, y = now_y, zoom = now.zoom }
            end })
        turner.pieces[#turner.pieces + 1] = entry
        return entry.panel
    end
    local function arrow(icon, by, dx)
        local panel = piece(ui.Panel, LINE.height, dx, 0)
        local control = panel:Slots({ columns = 1, rows = 1, size = LINE.height, gap = 0, below = 0 })
        control:Set({ { icon = icon } })
        control.Activated:Connect(function() on_shelf.turn(by) end)
        panel.Scrolled:Connect(on_shelf.turn)
        return control
    end
    local pager = { back = arrow("chevron-left", -1, function() return 0 end),
        forth = arrow("chevron-right", 1, function(at) return at.width - LINE.height end) }
    -- in a row, where a label is one line whatever its width. Its panel is as wide as the longest page it can show
    pager.label = piece(ui.Overlay, LINE.text[2], function(at) return (at.width - LINE.text[2]) / 2 end, 2.5):Row()
        :Label("", { size = small, align = "center" })
    -- page of pages, the arrow that leads nowhere switched off, and the parts where a line of this width has them
    function pager.set(page, pages)
        pager.label:Set(words.page(page, pages))
        pager.back:SetEnabled(page > 1)
        pager.forth:SetEnabled(page < pages)
        turner.wide = pages >= 10
        local at = pager_at()
        local key = at.x .. " " .. at.y .. " " .. at.width
        if key == turner.key then return end
        turner.key = key
        for _, entry in ipairs(turner.pieces) do entry.panel:SetOffset(entry.where(at)) end
    end
    on_shelf.pager = pager
    -- the shelf spans the room beside the column: when that changes, its slots are set out again for the new width
    if placed then
        local function set_out(exact)
            local columns = L.favourite_columns
            -- while the size is still changing only a change in how many fit across costs anything: the cells keep their size
            if columns == on_shelf.columns and not exact then return end
            local again = columns ~= on_shelf.columns
            on_shelf.columns, on_shelf.pitch = columns, L.shelf_cell + GAP
            for _, line in ipairs(on_shelf.lines) do line:SetLayout(columns, L.shelf_cell) end
            if again then show_favourites() end
        end
        favourites.Resized:Connect(function() set_out(false) end)
        -- once the size has settled, a full row ends at the shelf's edge again
        ui.ScreenChanged:Connect(function() set_out(true) end)
    end
    -- where the game's list sits on a bench screen, as shares of the screen before it is made smaller
    local list_place = L.bench_list()
    local box_width, box_height = list_place.width, list_place.height
    local box = ui.Panel({ anchor = "top-left", x = list_place.x, y = list_place.y,
        width = box_width, height = box_height, padding = 6, zoom = L.zoom, when = "always", opacity = 1, visible = false,
        place = function(width, height)
            local now = laid_out(width, height)
            local list = now.bench_list()
            return { x = list.x, y = list.y, width = list.width, height = list.height, zoom = now.zoom }
        end })
    local in_box = favourite_place(box, box_width, math.max(3, math.floor((box_width - 12 + GAP) / (CELL + GAP))),
        math.max(1, math.floor((box_height - 12 - 21 - 21 - 4 + GAP) / (CELL + GAP))), true)
    local favourite_places = { on_shelf, in_box }

    -- One page of the entries in a place. `held` is the entry being dragged: it is drawn faint where it would land.
    local function show_place(place, entries, held)
        local per = place.columns * #place.lines
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
        -- a shelf with pages keeps all its rows on every page, so the page line under them never moves
        if place.paged then
            for _, line in ipairs(place.lines) do line:SetVisible(true) end
        end
    end

    -- The tooltip of something a hold has marked: it says first that it is going.
    local function leaving_tip(tip)
        return function()
            local told = tip
            if type(told) == "function" then told = told() end
            if type(told) ~= "table" then return told end
            local lines = { { words.leaving, "warn" } }
            for _, line in ipairs(told.lines or {}) do lines[#lines + 1] = line end
            return { title = told.title, lines = lines }
        end
    end

    -- reveal: the id of a favourite just added. Each place turns to the page it is on.
    function show_favourites(reveal)
        if state.drag then return end
        local m = model()
        -- beside a bench, with the list cut down to it, the favourites are cut down the same way. Orders always show, and
        -- creatures wherever the shelf does: not in the box that stands in the place of a bench's own list.
        local made = state.only and state.station and state.station.items or nil
        local entries, found = {}, nil
        for _, entry in ipairs(m and shelf_ids(function(key) return m.items[key] ~= nil and (not made or made[key] ~= nil) end,
            function(key) return not state.replace and beasts.thing.known(key) end) or {}) do
            local look = nil
            if entry.creature then
                look = beasts.thing.look(entry.creature)
            elseif entry.order then
                local order = orders[entry.order]
                local item = m.items[order.key]
                if item then
                    look = { image = item.icon, icon = not item.icon and PLAIN.item or nil, value = { order = entry.order },
                        count = "x" .. text.short(order.amount), mark = ui.Icons.Has("clipboard-list") and "clipboard-list" or "list",
                        tip = { title = item.name, lines = { text.tree.title(order.amount), words.order_open, words.order_remove } } }
                end
            else
                look = look_of(m.items[entry.key], false)
            end
            if look then
                look.id = entry.id
                -- what a hold has marked keeps its place, faint, until the key comes up
                if sweep and sweep.leaving[entry.id] then
                    look.dim, look.mark, look.tip = true, "x", leaving_tip(look.tip)
                end
                entries[#entries + 1] = look
                if entry.id == reveal then found = #entries end
            end
        end
        state.entries = entries
        for _, place in ipairs(favourite_places) do
            local per = place.columns * #place.lines
            local pages = math.max(1, math.ceil(#entries / per))
            if found then place.at = (found - 1) // per + 1 end
            place.found = found
            place.at = math.max(1, math.min(place.at, pages))
            place.first, place.per = (place.at - 1) * per, per
            -- with pages the shelf is the same on every page: all its rows, and the page line where it was
            place.paged = place == on_shelf and pages > 1
            show_place(place, entries, nil)
            place.hint:SetVisible(#entries == 0)
            place.pager.set(place.at, pages)
            if place == on_shelf then
                state.shelf_pager = pages > 1
                state.shelf_lines = pages > 1 and #place.lines
                    or math.min(#place.lines, math.ceil(math.max(0, math.min(per, #entries - place.first)) / place.columns))
                place.room:SetVisible(pages > 1)
            else
                place.pager.row:SetVisible(pages > 1)
            end
        end
    end

    -- Dragging a favourite or an order to another place among its own kind, on the page that shows. What it passes
    -- slides one place over, and it is put down where it is let go.
    local function drag_started(place, row, index)
        local entries = state.entries or {}
        local at = (place.first or 0) + (row - 1) * place.columns + index
        local entry = entries[at]
        if not entry or sweep then return end
        -- anywhere on the page that shows, favourites and orders alike
        state.drag = { place = place, from = at, at = at, low = place.first + 1,
            high = math.min(place.first + place.per, #entries), entry = entry,
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
        -- a creature is kept or let go, and its cell and its page follow
        if type(key) == "table" and key.creature then
            if not (KEEP_CREATURES and beasts.thing.known(key.creature)) then return end
            local kept = app.kept:toggle(key.creature)
            beasts.kept_changed(key.creature)
            -- the shelf turns to the page it landed on: it goes last, which may be a page that does not show
            show_favourites(kept and "c:" .. key.creature or nil)
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
        -- a creature opens its page: on its drops for a right click, as an item opens on what it is used in
        if value.creature then return beasts.open(value.creature, mode == "used" and "drops" or "about") end
        -- the creatures that give an item, or that it is used on, listed in the Bestiary
        if value.droppers then return beasts.list_drops(value.droppers) end
        if value.users then return beasts.list_users(value.users) end
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
    -- The clicks every block of slots has. chooses: a click on an item the open bench makes chooses it there.
    local function wire(block, chooses)
        block.Activated:Connect(function(value)
            -- a second click on the same item straight after the first opens it, whatever the first click did
            local time = os.clock()
            if type(value) == "string" and state.clicked == value and time - (state.clicked_at or 0) < 0.4 then
                state.clicked = nil
                return open(value, "make")
            end
            state.clicked, state.clicked_at = value, time
            -- a block may take a click itself (a saddle of the Bestiary is put on its mount's model)
            if type(chooses) == "function" then
                if chooses(value) then return end
            elseif chooses and choose(value) then
                return
            end
            pressed(value, "make")
        end)
        block.RightClicked:Connect(function(value) pressed(value, "used") end)
        block.MiddleClicked:Connect(function(value)
            -- a hold of the middle button dealt with this press when the button went down
            if (sweep and sweep.key == MIDDLE) or os.clock() - (state.middle_done or -1) < 0.3 then return end
            view.favourite(value)
        end)
    end
    for _, block in ipairs(blocks) do wire(block, block == grid or favourite_blocks[block] ~= nil) end

    -- The column shows one of its two panels: the items, or the Bestiary side while that is what is looked at.
    function swap()
        local theirs = state.there == true and beasts.active()
        items:SetVisible(state.there == true and not theirs)
        beasts.set_visible(theirs)
    end

    -- The two tabs of both panels: each says how many it found while text is typed in its own box.
    function show_sides()
        local counts = { items = state.query ~= "" and model() and #state.list or nil,
            beasts = beasts.query() ~= "" and beasts.count() or nil }
        local off = app.beasts.off()
        sides.show("items", counts, off)
        beasts.sides(counts, off)
    end

    -- A tab of the two was pressed. The Bestiary side builds itself the first time, and the items stay until it has.
    function set_side(name)
        if name == state.side or (name == "beasts" and app.beasts.off()) then return end
        state.side = name
        beasts.side_changed()
        swap()
        show_sides()
    end

    -- The game's own name for the map that is loaded ("Terrain_016"), while one is: a prospect or an outpost.
    local function map_now()
        local ok, name = pcall(function() return game.InProspect == true and game.MapName or nil end)
        return ok and type(name) == "string" and name ~= "" and name or nil
    end

    -- What the Bestiary side is given of this one, so an item slot there behaves as an item slot does everywhere.
    local host = {
        map = map_now,
        column = { anchor = "right", x = 4, y = 0, width = column, height = tall, padding = 6 },
        place = function(width, height) return { zoom = laid_out(width, height).zoom } end,
        L = function() return L end,
        keys = KEYS,
        keeps = KEEP_CREATURES,
        kept = is_kept,
        favourite = function(value) view.favourite(value) end,
        model = model,
        -- an item's slot as it looks everywhere. One the item list hides is drawn and takes no click
        item_look = function(key)
            local m = model()
            local item = m and m.items[key]
            if not item then return nil end
            local look = look_of(item, false)
            look.tone = nil
            if item.hidden or item.title_only then look.value, look.tip = nil, { title = item.name } end
            return look
        end,
        wire = wire, slot_lines = slot_lines, fill_lines = fill_lines, page_line = page_line, side_tabs = side_tabs,
        pair_fit = pair_fit, pair_splits = PAIR_SPLITS,
        side = function() return state.side end,
        set_side = function(name) set_side(name) end,
        item_open = function() return state.detail == true end,
        -- a creature's page takes the column: the item that showed is put away
        close_item = function()
            if not state.detail then return end
            state.detail = false
            show_detail()
        end,
        close = function() close_detail() end,
        back = function() step_back() end,
        repaint = function()
            swap()
            show_sides()
        end,
    }
    beasts = require(mod.creature_view).start(app, host)
    -- a Wax that says when the game loads another map: "This map only" follows it while the column is up
    local told_map, map_changed = pcall(function() return game.MapChanged end)
    if told_map and type(map_changed) == "table" and map_changed.Connect then
        map_changed:Connect(function() task.defer(beasts.map_changed) end)
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
    -- What a node of the tech tree unlocks: the item of the first recipe that asks for it. Worked out once for each read of the data.
    local nodes = {}
    local function node_item(m, talent)
        if nodes.model ~= m or nodes.stage ~= m.stage then
            nodes = { model = m, stage = m.stage, items = {} }
            local first = {}
            for number, made in pairs(m.recipes) do
                local item = made.talent and not made.hidden_only and (made.title or (made.outputs[1] and made.outputs[1].item))
                if item and m.items[item] and number < (first[made.talent] or math.huge) then
                    first[made.talent], nodes.items[made.talent] = number, item
                end
            end
        end
        return nodes.items[talent]
    end
    -- The item under the mouse in the game's own screens: in a slot, as what a recipe tile makes, or as what a node of the tech tree unlocks.
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
        elseif kind == "talent" then
            return node_item(m, row:lower())
        end
        return nil
    end
    -- True while the keys may act: the panels show, and the player is not typing in one of the game's own text boxes.
    -- The column shows: its list of items or one item, or the Bestiary side in the same place.
    local function column_shows()
        return items:IsVisible() or beasts.visible()
    end
    local function keys_on()
        if not column_shows() then return false end
        return not (crafting and crafting.IsTyping and crafting:IsTyping())
    end
    local function keyed()
        if ui.Hovered() ~= nil then return under_mouse() end
        return in_game()
    end
    -- the favourite key over an order takes the order off, and over a creature keeps it or lets it go
    local function keyed_or_order()
        local value = ui.Hovered()
        if type(value) == "table" and (value.order or value.creature) then return value end
        return keyed()
    end

    -- Hold and sweep. What a slot stands for on the shelf: "f:<item>", "o:<item>" for an order, "c:<creature>" for a
    -- creature. Nothing for any other slot.
    local function id_of(value)
        if type(value) == "table" and value.order then
            local order = orders[value.order]
            return order and "o:" .. order.key or nil
        end
        if type(value) == "table" and value.creature then
            return KEEP_CREATURES and beasts.thing.known(value.creature) and "c:" .. value.creature or nil
        end
        local key = type(value) == "string" and value or nil
        if type(value) == "table" and value.tab then
            local station = state.tabs[value.tab]
            key = station and station.item or nil
        end
        return key and "f:" .. key or nil
    end

    -- The slots on the straight way from one slot of a block to another, the last one included: a fast mouse skips none.
    local function way(from, to, columns)
        local x, y = (from - 1) % columns, (from - 1) // columns
        local dx, dy = (to - 1) % columns - x, (to - 1) // columns - y
        local steps, out = math.max(math.abs(dx), math.abs(dy)), {}
        for step = 1, steps do
            out[step] = (y + math.floor(dy * step / steps + 0.5)) * columns + x + math.floor(dx * step / steps + 0.5) + 1
        end
        return out
    end

    -- One thing the held key passed, once for each hold. The first decides what the hold does: add, or take off.
    local function sweep_take(held, id, control, index)
        if held.seen[id] then return end
        held.seen[id] = true
        local key, kind = id:sub(3), id:sub(1, 1)
        local order = kind == "o"
        -- a creature is kept in a list of its own
        local kept = kind == "c" and app.kept or app.favourites
        local has
        if order then has = order_at(key) ~= nil else has = kept:has(key) end
        if held.adds == nil then held.adds = not has end
        if held.adds == has then return end
        if held.adds then
            kept:toggle(key)
        else
            held.leaving[id] = true
            held.marked = held.marked + 1
        end
        if kind == "c" then
            beasts.kept_changed(key)
        elseif not order then
            -- its slot in the list shows it at once, and so does the star of the picked item
            local at = state.shown[key]
            if at then grid:SetLook(at, look_of(state.list[state.first + at])) end
            if state.detail and state.pick == key then
                star:SetIcon(is_favourite(key) and ui.Icons.Has("star-off") and "star-off" or "star")
            end
        end
        -- the slot the mouse is on gives a little. One on the shelf keeps still
        if control and not favourite_blocks[control] then control:Slide(index, 0, held.adds and -POP or POP, 0.2) end
        show_favourites(held.adds and id or nil)
        if not held.adds then return end
        -- what was added comes onto the shelf from the side
        for _, place in ipairs(favourite_places) do
            local on_page = place.found and place.found - place.first or 0
            local line = on_page > 0 and place.lines[(on_page - 1) // place.columns + 1]
            if line then line:Slide((on_page - 1) % place.columns + 1, 12, 0, 0.2) end
        end
    end

    -- Once a frame while the key is held: the slot the mouse came to, and the slots it crossed on the way there.
    local function sweep_look(held)
        held.frame = held.frame + 1
        local _, look, control = ui.Hovered()
        if not look then
            held.look, held.at = nil, nil
            -- off the panels: what the mouse comes to in the game's own screens counts as it does for a press
            local item = held.game and in_game() or nil
            if item ~= held.item then
                held.item = item
                if item then sweep_take(held, "f:" .. item) end
            end
            return
        end
        held.item = nil
        if look == held.look then return end
        held.look = look
        local index = nil
        for at = 1, control:Capacity() do
            if control:GetLook(at) == look then
                index = at
                break
            end
        end
        if not index then return end
        -- the same slot showing something else (a page turned under the mouse) is not a slot the mouse came to
        local was = held.at
        held.at = { control = control, index = index }
        if was and was.control == control and was.index == index then return end
        local cells, last = { index }, held.last
        if last and last.control == control and held.frame - last.frame <= 3 then
            local still = control:GetLook(last.index)
            if still and id_of(still.value) == last.id then
                cells = way(last.index, index, control == grid and COLUMNS or beasts.across(control) or control:Capacity())
            end
        end
        held.last = { control = control, index = index, frame = held.frame, id = id_of(look.value) }
        for _, cell in ipairs(cells) do
            local passed = control:GetLook(cell)
            local id = passed and id_of(passed.value)
            if id then sweep_take(held, id, control, cell) end
        end
        held.look = control:GetLook(index)
    end

    -- The key came up: what the hold marked goes, all at once. cancel: nothing goes and the marks come off.
    local function sweep_done(cancel)
        local held = sweep
        sweep = nil
        if not held then return end
        if held.key == MIDDLE then state.middle_done = os.clock() end
        if held.marked == 0 then return end
        local before = {}
        for at, entry in ipairs(state.entries or {}) do before[entry.id] = at end
        if not cancel then
            local fewer = false
            for at = #orders, 1, -1 do
                if held.leaving["o:" .. orders[at].key] then
                    table.remove(orders, at)
                    fewer = true
                end
            end
            if fewer then storage.Save("orders", orders) end
            for id in pairs(held.leaving) do
                local key, kind = id:sub(3), id:sub(1, 1)
                if kind == "f" and app.favourites:has(key) then app.favourites:toggle(key) end
                if kind == "c" and app.kept:has(key) then app.kept:toggle(key) end
            end
        end
        show_items()
        beasts.kept_changed()
        show_favourites()
        if state.detail then show_detail() end
        if cancel then return end
        -- what stood behind them slides into the places they left
        for _, place in ipairs(favourite_places) do
            for on_page = 1, place.per do
                local entry = state.entries[place.first + on_page]
                local moved = entry and before[entry.id] and before[entry.id] - (place.first + on_page) or 0
                if moved > 0 then
                    place.lines[(on_page - 1) // place.columns + 1]:Slide((on_page - 1) % place.columns + 1,
                        math.min(moved, 3) * place.pitch, 0)
                end
            end
        end
    end

    -- The favourite key: a press is one item, and held it does the same to every item the mouse passes. Escape ends the hold with nothing taken off.
    local function favourite_key(key)
        if key == KEYS.favourite and not keys_on() then return end
        if not can_hold then return view.favourite(keyed_or_order()) end
        -- a hold whose task ended without saying so is forgotten
        if sweep and os.clock() - sweep.beat > 1 then sweep = nil end
        if sweep or state.drag or not column_shows() then return end
        -- game: this Wax finds what the mouse is over in the game's screens fast enough to ask every frame of a hold
        local held = { key = key, seen = {}, leaving = {}, marked = 0, frame = 0, beat = os.clock(),
            game = crafting ~= nil and crafting.IsTyping ~= nil }
        sweep = held
        -- on an older Wax an item in the game's own slots counts at the press only
        if not held.game and ui.Hovered() == nil then
            local item = in_game()
            if item then sweep_take(held, "f:" .. item) end
        end
        while true do
            local ok, problem = pcall(sweep_look, held)
            if not ok then
                sweep_done(true)
                error(problem, 0)
            end
            task.wait()
            if sweep ~= held then return end
            held.beat = os.clock()
            if not column_shows() or ui.IsKeyDown("Escape") then return sweep_done(true) end
            if not ui.IsKeyDown(key) then return sweep_done(false) end
        end
    end

    local always = { in_menu = true }
    -- the two keys do the nearest thing for a creature under the mouse: its page, or its drops
    local function key_open(mode)
        if not keys_on() then return end
        local value = ui.Hovered()
        if type(value) == "table" and value.creature then return pressed(value, mode) end
        open(keyed(), mode)
    end
    ui.Hotkey(KEYS.make, function() key_open("make") end, always)
    ui.Hotkey(KEYS.used, function() key_open("used") end, always)
    ui.Hotkey(KEYS.favourite, function() favourite_key(KEYS.favourite) end, always)
    -- the middle button the same way. Without this its click still marks one item when it comes up
    if can_hold then ui.Hotkey(MIDDLE, function() favourite_key(MIDDLE) end, { in_menu = true, hover = true }) end
    ui.Hotkey("BackSpace", function() if (state.detail or beasts.page()) and keys_on() then step_back() end end, always)
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
        place.panel.Scrolled:Connect(place.turn)
    end

    -- The game's own screens make room while the panels are beside them.
    local fit = ui.FitGame({ scale = L.scale, corner = "bottom-left", enabled = false })

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
    local play, was_near = false, false
    local play_at, screen_at, station_at = -1, -1, 0    -- when each was last looked at: none of them needs a look every frame
    refit = function()
        if not state.near then return end
        local lines = not state.replace and (state.shelf_lines or 0) or nil
        fit:Set(L.fit(ui.GameScreen() or "", lines, state.shelf_pager == true))
    end
    -- changed: the game has just shown another screen, so which bench is open is looked at now.
    local function place(changed)
        local now = os.clock()
        if now - play_at >= 0.35 then play, play_at = game.InProspect == true, now end
        -- The game's screens the panels belong beside: every tab of its main menu, so nothing changes size between tabs,
        -- and a bench or a container. Not the escape menu.
        local name = ui.GameScreen()
        local near = state.on and play and name ~= nil and name ~= "UMG_EscapeMenu"
        state.near = near
        -- each kind of screen is moved up as far as its own top allows, so it sits just under the favourites
        if near then
            local lines = not state.replace and (state.shelf_lines or 0) or nil
            fit:Set(L.fit(name, lines, state.shelf_pager == true))
        end
        fit:SetEnabled(near)
        -- which bench is open: looked at the frame a screen comes up, then a few times a second
        local screen = state.screen
        if not near then
            screen = nil
        elseif crafting and (changed or not was_near or now - screen_at >= 0.07) then
            screen_at = now
            local number, kind = crafting:GetScreen()
            screen = number and (kind .. number) or nil
        end
        was_near = near
        if screen ~= state.screen then
            state.screen, station_at = screen, now
            station_changed()
        elseif state.station and now - station_at >= 1.4 then
            station_at = now
            check_station()
        end
        -- with the Wax menu they come up too, but not over the escape menu: the column would cover its buttons
        local escape = play and name == "UMG_EscapeMenu"
        local there = state.on and (state.bare or near or (play and not escape and (ui.IsOpen() or ui.IsPreview())))
        state.there = there == true
        swap()
        favourites:SetVisible(there and not state.replace)
        local paged = there and not state.replace and state.shelf_pager == true
        for _, entry in ipairs(turner.pieces) do entry.panel:SetVisible(paged) end
        box:SetVisible(there and state.replace == true)
        if there then
            app.job.want()
        elseif state.detail or beasts.page() then
            close_detail()
        end
    end

    local function refresh()
        beasts.refresh()
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

    -- a level gained or a point spent, here or in the game's own tech tree: the research lines that show are asked again
    if research then
        research.Changed:Connect(function()
            if items:IsVisible() and state.detail and state.view == "recipes" and state.mode == "make" then show_detail() end
        end)
    end

    -- The open key hides the panels while they show. While they do not, it frees the mouse and shows them on their own.
    local function toggle()
        if column_shows() then
            if state.bare then return ui.Close() end
            state.on = false
            return place()
        end
        state.on = true
        place()
        if column_shows() then return end
        state.bare = true
        place()
        ui.Open({ windows = false })
    end

    -- The game's screen is its smaller size from the frame it opens. A Wax that says when the game shows another screen is
    -- listened to, and a look a few times a second sees to the rest. An older Wax is asked every frame.
    local told = ui.GameScreenChanged
    if told then
        told:Connect(function() place(true) end)
        ui.Opened:Connect(function() place() end)
    end
    task.spawn(function()
        while true do
            place()
            task.wait(told and 0.25 or nil)
        end
    end)
    refresh()
    -- creatures kept on the shelf need the game's creatures to be drawn, so they are read without being asked for
    if KEEP_CREATURES and app.kept:count() > 0 then app.beasts.want() end

    -- creatures: the read of the creature tables has started or ended. The Bestiary side and the tabs show it, the
    -- shelf has the creatures that are kept, and an item that is open has its card of creatures.
    -- beasts, sides: the Bestiary side and the controls of this one, for a test or a script that presses them
    sides.back, sides.previous, sides.find, sides.grid, sides.categories = back_button, previous, find, grid, tabs
    sides.shelf, sides.cards, sides.stations, sides.views, sides.message = on_shelf.lines, cards, station_lines, view_tabs, message
    sides.tree = { total = total_label, times = times_label, steps = craft_lines }
    return { refresh = refresh, toggle = toggle, showing = column_shows, beasts = beasts, sides = sides, creatures = function()
        beasts.refresh()
        show_sides()
        show_favourites()
        local m = model()
        local picked = m and state.detail and state.pick and m.items[state.pick]
        if picked then
            prepare(m, picked)
            show_detail()
        end
    end }
end

return view
