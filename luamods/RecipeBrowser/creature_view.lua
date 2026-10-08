-- The Bestiary side of the column: the list of creatures and one creature's page, in a panel made when first asked for.

local creature_view = {}

creature_view.CHUNK = 6         -- controls made in one frame while the panel is built
creature_view.ACROSS = 5        -- slots in a line of a section, and variants in a line
creature_view.COUNT_EDGE = 12   -- of a slot's side, what a count cannot use: "5-10" was cut in the game, "1.8k" is not
creature_view.FIGURE_EDGE = 6   -- the same for the figure a list is in order by: the library draws a long count smaller
-- What the list can be put in order by, as the dropdown lists it. "game" is the order creatures are met in.
creature_view.ORDERS = { "game", "speed", "health", "damage", "sight", "hearing", "xp" }
creature_view.ORDER_SET = {}
for _, order in ipairs(creature_view.ORDERS) do creature_view.ORDER_SET[order] = true end
creature_view.LIGHT = 1.3       -- how bright the 3D view lights its model: 1 is the control's own, and 1.6 burnt a white coat out
creature_view.LEVEL = 30        -- the one level every creature's health and damage are compared at
creature_view.HOLD, creature_view.REPEAT = 0.4, 0.07    -- seconds a held minus or plus waits, and between its steps after that
creature_view.RANK_A_FRAME = 2  -- creatures whose figures are read in one frame while an order is worked out

local ICONS = "/Game/Assets/2DArt/UI/Icons/"
-- The category tiles after "all", in their order, each with a filled picture of the game's own, as the item side's
-- tiles have. A tile lists the creatures it fits and is left out while it fits none.
creature_view.FILTERS = {
    { key = "hostile", image = ICONS .. "Icon_AggressiveCreature", fits = function(entry) return entry.temper == "hostile" end },
    { key = "neutral", image = ICONS .. "MountTameIcons/ICON_MoodNeutral", fits = function(entry) return entry.temper == "neutral" end },
    { key = "passive", image = ICONS .. "Icon_PassiveCreature", fits = function(entry) return entry.temper == "passive" end },
    { key = "friendly", image = ICONS .. "MountTameIcons/ICON_MoodHappy", fits = function(entry) return entry.temper == "friendly" end },
    { key = "boss", image = ICONS .. "Icon_Skull", fits = function(entry) return entry.boss == true end },
    { key = "tamed", image = ICONS .. "MountTameIcons/T_ICON_Creature_Attraction", fits = function(entry) return entry.tamed == true end },
    { key = "ridden", image = ICONS .. "MountTameIcons/T_ICON_MountFollow", fits = function(entry) return entry.ridden == true end },
    { key = "meat", image = ICONS .. "MountTameIcons/ICON_FoodFull", fits = function(entry) return entry.diet == "meat" end },
    { key = "plants", image = "/Game/Assets/2DArt/UI/FieldGuide/CategoryIcons/T_ICON_FieldGuide_Plants",
        fits = function(entry) return entry.diet == "plants" end },
}
-- The picture of the tile that lists everything, on both sides of the column, and the one that stands for creatures
-- among stations and items: the game's own filled ones.
creature_view.ALL = ICONS .. "T_ICON_Classification_ALL"
creature_view.PAWS = ICONS .. "T_ICON_Paws"

-- What creature_page.lua needs to work a section's height out: layout.lua's figures, and a text's lines as rows.lua
-- measures them. sizes: the sizes of small and of usual text.
function creature_view.heights(L, rows, sizes)
    local high = { from = L.beast_heights }
    for key, value in pairs(L.beast_heights) do high[key] = value end
    local room = L.inner * rows.LINE
    function high.lines(said, is_small) return #rows.wrap(said, room, is_small and sizes.small or sizes.usual) end
    return high
end

-- A section as the page draws it: a name and its figure share a line only while both fit, and the others are written
-- out under them. pair_text(name, value) makes such a sentence.
function creature_view.settled(section, rows, inner, pair_text)
    if not section.pairs then return section end
    local names, values = {}, {}
    for at, pair in ipairs(section.pairs) do names[at], values[at] = pair.name, pair.value end
    local _, left = rows.pair_fit(names, values, inner)
    if #left == 0 then return section end
    local copy, apart = {}, {}
    for key, value in pairs(section) do copy[key] = value end
    for _, at in ipairs(left) do apart[at] = true end
    local kept, after = {}, {}
    for at, pair in ipairs(section.pairs) do
        if apart[at] then after[#after + 1] = pair_text(pair.name, pair.value) else kept[#kept + 1] = pair end
    end
    for _, said in ipairs(section.after or {}) do after[#after + 1] = said end
    copy.pairs, copy.after = kept[1] and kept or nil, after
    return copy
end

-- A tab's sections with those that hold slots of the items in `lead` moved up to stand second, in their own order.
function creature_view.leading(list, lead)
    local out, moved = {}, {}
    for at, section in ipairs(list) do
        local first = section.slots and section.slots[1]
        if at > 1 and first and first.item and lead[first.item] then moved[#moved + 1] = section else out[#out + 1] = section end
    end
    for at, section in ipairs(moved) do table.insert(out, math.min(#out + 1, 1 + at), section) end
    return out
end

-- The pages of one tab of a creature's page. pack: creature_page.pack. about: variant_lines, facts_lines (the facts
-- have room for two: a third takes its line from the tab), view_lines (the lines of text under the 3D view when the
-- tab's first page has it, else 0), view_every (true: every page of the tab has the view, as Taming has so a saddle
-- is seen on the model from whichever page lists it). Gives the pages, the room of a page, and the room of the first one.
function creature_view.paged(pack, list, L, high, about)
    local less = math.max(0, about.facts_lines - 2) * high.small
    local view_lines = about.view_lines or 0
    local function run(pager)
        local budget = L.beast_budget(false, about.variant_lines, pager) - less
        -- the view stands on the first page only, so the pages after it have the whole room
        local first = view_lines > 0 and L.beast_budget(true, about.variant_lines, pager) - less - (view_lines - 1) * high.small or nil
        if first and about.view_every then budget = first end
        return pack(list, budget, high, first), budget, first or budget
    end
    local packed, budget, first = run(false)
    if #packed > 1 then packed, budget, first = run(true) end
    return packed, budget, first
end

-- app: what init.lua gives a view. host: what view.lua offers of the item side (see where it starts this file).
function creature_view.start(app, host)
    local text, rows = app.text, app.rows
    local beasts, words = text.beasts, text.panel
    local creatures, pages = require(mod.creatures), require(mod.creature_page)
    local theme = ui.Theme()
    local small = theme.small_size
    local GAP, ACROSS = 2, creature_view.ACROSS
    local self = {}
    -- query: what is typed in this side's own box
    local state = { page = 1, list = {}, tab = "about", variant = 1, tab_page = 1, tab_pages = 1, stale = true, shown = false, query = "" }
    state.map_only = app.settings.map_only == true
    state.order = creature_view.ORDER_SET[app.settings.beast_order] and app.settings.beast_order or "game"
    local parts = nil           -- the panel and its controls, once they are being made
    local changed               -- what shows is no longer what is asked for
    local by_key = {}
    for _, filter in ipairs(creature_view.FILTERS) do by_key[filter.key] = filter end

    -- The creatures while they can be listed: both models are there and the game still has the tables.
    local function model()
        local c = app.beasts.model
        if c and not c.off.list and host.model() then return c end
        return nil
    end

    -- A control is shown or hidden only when that changes.
    local showing = {}
    local function vis(control, shown)
        shown = shown and true or false
        if showing[control] == shown then return end
        showing[control] = shown
        control:SetVisible(shown)
    end

    local counted = {}
    local function counts_of(c)
        if counted.model == c then return counted end
        counted = { model = c }
        for _, filter in ipairs(creature_view.FILTERS) do
            local count = 0
            for _, entry in ipairs(c.list) do
                if filter.fits(entry) then count = count + 1 end
            end
            counted[filter.key] = count
        end
        return counted
    end

    -- The creatures the typed words, the chosen tile and the item they have to drop or be used with leave. Nothing while there is no model.
    local function matching()
        local c = model()
        if not c then return nil end
        local typed = {}
        for word in app.search.lower(state.query):gmatch("%S+") do typed[#typed + 1] = word end
        local found = creatures.filter(c, typed, nil, not state.uses and state.item or nil)
        local filter = state.filter and by_key[state.filter]
        local among = nil
        if state.item and state.uses then
            among = {}
            for _, line in ipairs(c.uses[state.item] or {}) do among[line.entry] = true end
        end
        -- with "This map only" on, what the map that is loaded can have
        local place = state.map_only and creatures.place(c, host.map()) or nil
        if not filter and not among and not place then return found end
        local out = {}
        for _, entry in ipairs(found) do
            if (not filter or filter.fits(entry)) and (not among or among[entry.id]) and (not place or place.has[entry.id]) then
                out[#out + 1] = entry
            end
        end
        return out
    end

    local function is_kept(id)
        return host.keeps == true and host.kept(id)
    end

    -- Something of a control is set only when it changes.
    local function set_once(control, name, value, apply)
        local known = parts.set[control]
        if not known then
            known = {}
            parts.set[control] = known
        end
        if known[name] == value then return end
        known[name] = value
        apply(control, value)
    end

    -- How many creatures of a place each tile lists, counted once for a model and a place.
    local counted_here = {}
    local function counts_at(c, place)
        if counted_here.model == c and counted_here.place == place then return counted_here end
        counted_here = { model = c, place = place }
        for _, filter in ipairs(creature_view.FILTERS) do
            local count = 0
            for _, entry in ipairs(c.list) do
                if place.has[entry.id] and filter.fits(entry) then count = count + 1 end
            end
            counted_here[filter.key] = count
        end
        return counted_here
    end

    -- True while this game serves the map and curve fields the figures are read from.
    local function has_numbers()
        local ok, served = pcall(function() return app.beasts.numbers ~= nil and app.beasts.numbers() end)
        return ok and served == true
    end

    -- The figures the list can be put in order by, of every creature: worked out a few creatures a frame, once for a
    -- read of the data, the first time an order asks for them.
    local ranking = {}
    local function figures_of(c)
        if ranking.model == c then return ranking end
        local mine = { model = c, figures = {}, done = false }
        ranking = mine
        task.spawn(function()
            local worked = 0
            for _, entry in ipairs(c.list) do
                if ranking ~= mine or app.beasts.model ~= c then return end
                mine.figures[entry.id] = app.beasts.figures(entry.id, creature_view.LEVEL) or {}
                worked = worked + 1
                if worked >= creature_view.RANK_A_FRAME then
                    worked = 0
                    task.wait()
                end
            end
            mine.done = true
            changed()
        end)
        return mine
    end

    -- The order that is in use: the one chosen while its figures can be read, else the game's.
    local function order_now()
        local order = state.order
        if order == "game" or not creature_view.ORDER_SET[order] or not has_numbers() then return "game" end
        return order
    end

    -- The list from the most of a figure to the least. Creatures the tables give no figure for come last, in the game's order.
    local function ordered(c, found, order)
        if order == "game" then return found, nil end
        local ranks = figures_of(c)
        if not ranks.done then return found, nil end
        local at, out = {}, {}
        for position, entry in ipairs(found) do at[entry], out[position] = position, entry end
        table.sort(out, function(a, b)
            local first, second = ranks.figures[a.id][order], ranks.figures[b.id][order]
            if first ~= second then
                if first == nil then return false end
                if second == nil then return true end
                return first > second
            end
            return at[a] < at[b]
        end)
        return out, ranks.figures
    end

    -- A figure as a cell shows it where a count goes, in the widest form its cell holds: 1 "12.5 m/s", 2 "12.5m/s",
    -- 3 "13m/s", and only where none of those fits, 4 "13". A figure with no unit reads "1.3k" in every form.
    local FORMS = 4
    local function figure_text(order, value, form)
        local said
        if order == "speed" then
            said = beasts.speed(form >= 3 and math.floor(value / 100 + 0.5) * 100 or value)
        elseif order == "sight" or order == "hearing" then
            said = beasts.metres(form >= 3 and math.floor(value / 100 + 0.5) * 100 or value)
        else
            return text.short(math.floor(value + 0.5))
        end
        if form >= 4 then return said:match("^%S+") or said end
        return form >= 2 and (said:gsub(" ", "")) or said
    end

    -- The first form in which a figure is no wider than a creature's cell has room for.
    local function form_of(order, value)
        local room = host.L().beast_cell - creature_view.FIGURE_EDGE
        for form = 1, FORMS - 1 do
            if rows.measure(figure_text(order, value, form), small) <= room then return form end
        end
        return FORMS
    end

    -- What is listed of an item, on one line of the column. The count always stays: a name too long for the line is cut short.
    local function one_line(count, name, uses)
        local room = host.L().inner * rows.LINE
        local make = uses and beasts.uses_filter or beasts.drops_filter
        local line = make(name, count)
        for keep = #name - 1, 1, -1 do
            if #rows.wrap(line, room, small) <= 1 then break end
            line = make(name:sub(1, keep):gsub("%s+$", "") .. "...", count)
        end
        return line
    end

    local function show_list()
        local p = parts
        local c = model()
        -- a tile that lists nothing in this version of the game is not there to be chosen
        local counts = c and counts_of(c)
        if counts and state.filter and (counts[state.filter] or 0) == 0 then state.filter = nil end
        -- the map that is loaded, and what the tables say it can have
        local map = c and host.map() or nil
        local place = map and creatures.place(c, map) or nil
        state.map = map
        local here = state.map_only and place or nil
        local order = c and order_now() or "game"
        local found, figures = matching() or {}, nil
        if c then found, figures = ordered(c, found, order) end
        state.list = found
        local per = p.grid:Capacity()
        local count = math.max(1, math.ceil(#found / per))
        state.page = math.max(1, math.min(state.page, count))
        local looks, first, where = {}, (state.page - 1) * per, {}
        -- the cells of a page all say their figure in one form: the widest that fits every one of them
        local form = 1
        for at = 1, figures and per or 0 do
            local entry = found[first + at]
            local figure = entry and figures[entry.id][order]
            if figure then form = math.max(form, form_of(order, figure)) end
        end
        for at = 1, per do
            local entry = found[first + at]
            if entry then
                local look = app.page.cell(entry, { kept = is_kept(entry.id), internal = app.settings.internal_names })
                -- the figure the list is in order by, where an item's slot has its count
                local figure = figures and figures[entry.id][order]
                if figure then
                    look.count = figure_text(order, figure, form)
                    table.insert(look.tip.lines, 2, beasts.order_tip(order, figure, figures[entry.id].level or creature_view.LEVEL))
                end
                looks[at] = look
                where[entry.id] = at
            end
        end
        state.where = where
        p.grid:Set(looks)
        p.pager.set(state.page, count)

        local tiles, line = {}, nil
        if c then
            -- with the list cut down to the map, each tile says how much of it the map has, and one it has nothing of is faint
            local within = here and counts_at(c, here)
            -- symbol: a white shape of the game's, for a Wax that gives such a picture the theme's colour
            tiles[1] = { image = creature_view.ALL, symbol = true, value = { filter = false }, selected = state.filter == nil and state.item == nil,
                tip = { title = beasts.filters.all, lines = { beasts.count(here and here.count or #c.list) } } }
            for _, filter in ipairs(creature_view.FILTERS) do
                if counts[filter.key] > 0 and #tiles < p.filters:Capacity() then
                    local listed = within and within[filter.key] or counts[filter.key]
                    tiles[#tiles + 1] = { image = filter.image, icon = filter.icon, symbol = true, value = { filter = filter.key },
                        selected = state.filter == filter.key, dim = within ~= nil and listed == 0 or nil,
                        tip = { title = beasts.filters[filter.key], lines = { beasts.count(listed) } } }
                end
            end
            local item = state.item and host.model().items[state.item]
            line = app.page.count_line(#found, state.filter, state.query, item and item.name or nil, state.uses)
            -- with the map switch showing there is room for one line of it
            if item and map then line = one_line(#found, item.name, state.uses) end
        elseif app.beasts.failed then
            line = beasts.failed
        elseif app.beasts.off() then
            line = beasts.changed
        else
            line = beasts.reading
        end
        p.filters:Set(tiles)
        p.count:Set(line)

        -- the switch is there while a map is loaded, and works while the tables can say what that map has
        local lost = c ~= nil and map ~= nil and place == nil
        vis(p.map_row, c ~= nil and map ~= nil)
        if c and map then set_once(p.map_only, "on", place ~= nil, function(control, value) control:SetEnabled(value) end) end
        vis(p.no_map, lost)
        vis(p.keys, not lost)
        vis(p.order, c ~= nil)
        if c then
            local can = has_numbers()
            set_once(p.order, "on", can, function(control, value) control:SetEnabled(value) end)
            set_once(p.order, "choice", order, function(control, value) control:Set(beasts.orders[value]) end)
        end
    end

    -- A count wider than a slot has room for (a range such as 10-16) shows where it starts: the tip has both ends.
    local function fitting(count)
        if not count or rows.measure(count, small) <= host.L().cell - creature_view.COUNT_EDGE then return count end
        local low = count:match("^([^%-]+)%-")
        return low and (low .. "+") or count
    end

    -- An item's slot on a creature's page: as it looks everywhere, with what the page says of it.
    -- first: lines that stand before the page's own in its tip.
    local function slot_look(slot, first)
        if slot.arrow then return { icon = "arrow-right", plain = true } end
        local look = host.item_look(slot.item) or { icon = "package" }
        look.count, look.dim = fitting(slot.count), slot.dim and true or nil
        look.mark = slot.mark and ui.Icons.Has(slot.mark) and slot.mark or nil
        local base, lines = look.tip, slot.lines
        if first then
            local all = {}
            for _, said in ipairs(first) do all[#all + 1] = said end
            for _, said in ipairs(lines or {}) do all[#all + 1] = said end
            lines = all
        end
        if lines and #lines > 0 then
            look.tip = function()
                local told = base
                if type(told) == "function" then told = told() end
                local out = {}
                for _, said in ipairs(lines) do out[#out + 1] = said end
                for _, said in ipairs(type(told) == "table" and told.lines or {}) do out[#out + 1] = said end
                return { title = type(told) == "table" and told.title or "", lines = out }
            end
        end
        return look
    end

    local function fill(lines, looks)
        for row, line in ipairs(lines) do
            local part, any = {}, false
            for at = 1, ACROSS do
                part[at] = looks[(row - 1) * ACROSS + at]
                any = any or part[at] ~= nil
            end
            if any or showing[line] then line:Set(part) end
            vis(line, any)
        end
    end

    -- What creature_page.lua needs to work a section's height out: layout.lua's figures, and a text's lines as rows.lua measures them.
    local measured = nil
    local function heights()
        local L = host.L()
        if measured and measured.from == L.beast_heights then return measured end
        measured = creature_view.heights(L, rows, { small = small, usual = theme.font_size })
        return measured
    end

    -- The 3D view of About: what Wax's list of models gives for a set-up, asked once. Nothing on a Wax without the view.
    local views = { looks = {} }
    local function look_of(variant)
        local setup = variant and variant.setup
        if not (setup and parts and parts.model) then return nil end
        local known = views.looks[setup]
        if known == nil then
            local ok, look = pcall(function() return (game.Creatures:GetModel(setup)) end)
            -- a mesh with nothing to play draws nothing: the game shows such a creature as particles
            known = ok and type(look) == "table" and (look.walk or look.idle or look.loop or look.blueprint) and look or false
            views.looks[setup] = known
        end
        return known or nil
    end

    -- What the view is given for a variant of a group. One that is not the group's first is shown against the first, so
    -- a young one is as much smaller in the box as it is in the game. plain: the same without that, for an older Wax.
    local function look_for(entry, position)
        local variant = entry.variants[position]
        local look = look_of(variant)
        local first = position > 1 and look_of(entry.variants[1]) or nil
        if not look or not first or (first.mesh == look.mesh and (first.scale or 1) == (look.scale or 1)) then return look, look end
        views.beside = views.beside or {}
        local beside = views.beside[variant.setup]
        if not beside then
            beside = {}
            for key, value in pairs(look) do beside[key] = value end
            beside.against = { mesh = first.mesh, scale = first.scale }
            views.beside[variant.setup] = beside
        end
        return beside, look
    end

    -- The saddles Wax can put on a set-up's model: the item's row, by that row without case or underscores. Asked once
    -- a set-up. Empty on a Wax that puts none on, so Taming then has no view, as before.
    local function fold(said) return (tostring(said):lower():gsub("[%s_%-]", "")) end
    local function wearable(setup)
        views.saddles = views.saddles or {}
        local known = views.saddles[setup]
        if known == nil then
            known = {}
            local ok, found = pcall(function() return (game.Creatures:GetSaddles(setup)) end)
            for _, saddle in ipairs(ok and type(found) == "table" and found or {}) do
                for _, row in ipairs(type(saddle.Items) == "table" and saddle.Items or {}) do known[fold(row)] = row end
            end
            views.saddles[setup] = known
        end
        return known
    end

    -- What the mount of a group wears on Taming: the tamed variant, the item it wears (false: nothing), and the
    -- items of its saddle slot that can be put on its model, each with the row Wax knows it by. Nothing for a group
    -- with no model or with nothing to wear. The first that fits is on until the player picks.
    local function worn(entry)
        local tamed = app.page.tamed_of(entry, state.variant)
        local mount = tamed and tamed.mount
        if not (mount and tamed.setup and look_of(tamed)) then return nil end
        local can, m = wearable(tamed.setup), host.model()
        local fits, first = {}, nil
        for _, key in ipairs(mount.saddles or {}) do
            local item = m and m.items[key]
            local row = item and item.row and can[fold(item.row)]
            if row then
                fits[key] = row
                first = first or key
            end
        end
        if not first then return nil end
        local picked = state.worn
        if not picked or picked.setup ~= tamed.setup or (picked.item and not fits[picked.item]) then
            picked = { setup = tamed.setup, item = first }
            state.worn = picked
        end
        return tamed, picked.item, fits
    end

    -- The look of a tamed variant with a saddle on, and what to remember it by. One Wax cannot put on leaves it bare.
    local function saddled(tamed, item, fits)
        local bare = look_of(tamed)
        if not item then return bare, tamed.setup .. "|" end
        local key = tamed.setup .. "|" .. item
        views.worn = views.worn or {}
        local known = views.worn[key]
        if known == nil then
            local ok, look = pcall(function() return (game.Creatures:GetModel(tamed.setup, { saddle = fits[item] })) end)
            known = ok and type(look) == "table" and look or false
            views.worn[key] = known
        end
        return known or bare, key
    end

    -- A click on a slot of the page. On Taming a saddle the model can wear is put on, and the one it wears is taken off.
    local function wear(value)
        if type(value) ~= "string" or state.tab ~= "taming" or not state.open then return false end
        local c = model()
        local entry = c and c.entries[state.open]
        if not entry then return false end
        local tamed, item, fits = worn(entry)
        if not (tamed and fits[value]) then return false end
        state.worn = { setup = tamed.setup, item = item ~= value and value or false }
        changed()
        return true
    end

    -- Takes the model out of the world: the page is closed, or the column is hidden.
    local function drop_view()
        if not (parts and parts.model and views.shown) then return end
        views.shown, views.setup = nil, nil
        parts.model:Clear()
    end

    -- The pages of the tab that shows, worked out once for a creature, a variant and a tab.
    -- view_lines: the lines of text under the 3D view when the tab has it, else 0. every: it is on every page of the tab.
    -- lead: items whose sections stand straight under the tab's opening, so what the model can wear is beside the model.
    local function tab_pages(c, m, entry, variant_lines, facts_lines, view_lines, every, lead)
        local key = table.concat({ entry.id, state.variant, state.tab, variant_lines, facts_lines, view_lines, every and 1 or 0,
            state.level or 0 }, ":")
        local made = state.made
        if made and made.key == key and made.c == c and made.m == m and made.stage == m.stage and made.page == app.page then return made.pages end
        local L, high = host.L(), heights()
        local list = app.page.sections(state.tab, c, m, entry, state.variant,
            function(position) return app.beasts.detail(entry.id, position) end, { level = state.level })
        for at, section in ipairs(list) do list[at] = creature_view.settled(section, rows, L.inner, text.pair) end
        if lead then list = creature_view.leading(list, lead) end
        local packed = creature_view.paged(pages.pack, list, L, high,
            { variant_lines = variant_lines, facts_lines = facts_lines, view_lines = view_lines, view_every = every })
        state.made = { key = key, c = c, m = m, stage = m.stage, page = app.page, pages = packed }
        return packed
    end

    -- Fills the page with the creature that is open. False when the creatures no longer have it.
    local function show_page()
        local p, c, m = parts, model(), host.model()
        local entry = c and state.open and c.entries[state.open]
        if not entry then return false end
        local L = host.L()
        state.variant = math.max(1, math.min(state.variant, math.max(1, #entry.variants)))
        local head = app.page.head(entry, state.variant)
        local word = head.word

        set_once(p.back, "caption", host.side() == "beasts" and beasts.back or words.back, function(control, value) control:SetCaption(value) end)
        p.previous:SetEnabled(app.history:can_back())
        vis(p.star, host.keeps == true)
        if host.keeps then p.star:SetIcon(is_kept(entry.id) and ui.Icons.Has("star-off") and "star-off" or "star") end
        -- a label has no tip, so the picture's tip says what the word stands on
        local told = { { word.text, word.tone } }
        if word.tip then told[#told + 1] = word.tip end
        if app.settings.internal_names then told[#told + 1] = entry.row end
        p.head:Set({ { image = head.image, icon = head.icon, tip = { title = head.name, lines = told } } })
        local room = L.inner - L.cell - 20
        local name_lines = rows.wrap(head.name, room * rows.LINE, 13)
        if #name_lines > 2 then name_lines = { name_lines[1], rows.shorten(table.concat(name_lines, " ", 2), room, 13) } end
        p.title:Set(table.concat(name_lines, "\n"))
        p.word:Set(word.text)
        set_once(p.word, "tone", word.tone or "text", function(control, value) control:SetColor(theme[value] or theme.text) end)
        p.facts:Set(head.facts)
        local facts_lines = head.facts ~= "" and #rows.wrap(head.facts, L.inner * rows.LINE, small) or 0
        for _, control in ipairs({ p.top, p.name_row, p.word, p.tab_rows[1], p.tab_rows[2], p.rule }) do vis(control, true) end
        vis(p.facts, facts_lines > 0)

        local variants = app.page.variants(entry, state.variant, m)
        local variant_lines = #variants == 0 and 0 or (#variants <= ACROSS and 1 or 2)
        for lines, block in ipairs(p.variants) do
            if lines == variant_lines then block:Set(variants) end
            vis(block, lines == variant_lines)
        end

        local open, why = app.page.tabs(entry)
        if not open[state.tab] then state.tab = "about" end
        for _, name in ipairs(pages.TABS) do
            local button = p.tabs[name]
            button:SetActive(name == state.tab)
            set_once(button, "open", open[name] == true, function(control, value) control:SetEnabled(value) end)
            if button.SetTip then set_once(button, "tip", why[name] or false, function(control, value) control:SetTip(value or nil) end) end
        end

        -- About shows the variant in 3D, where this Wax has the view and a model of it. Taming shows the mount with
        -- what is picked for its saddle slot on, on every page of the tab.
        local variant = entry.variants[state.variant]
        local look, plain, setup, shown_as, wears = nil, nil, variant and variant.setup, nil, nil
        if state.tab == "about" then
            look, plain = look_for(entry, state.variant)
            shown_as = setup
        elseif state.tab == "taming" and p.model then
            local tamed, item, fits = worn(entry)
            if tamed then
                setup = tamed.setup
                look, shown_as = saddled(tamed, item, fits)
                plain, wears = look_of(tamed), { item = item, fits = fits }
            end
        end
        if look and views.shown ~= shown_as then
            if pcall(p.model.Show, p.model, look) or (plain ~= look and pcall(p.model.Show, p.model, plain)) then
                views.shown, views.setup, views.walking = shown_as, setup, true
            else
                views.looks[setup], look, wears = false, nil, nil
            end
        end
        local view_keys = {}
        if wears then
            local worn_item = wears.item and m.items[wears.item]
            local name = worn_item and rows.shorten(worn_item.name or "", L.inner - rows.measure("Wearing: ", small), small) or nil
            view_keys = beasts.saddle_lines(name)
        elseif look then
            view_keys = beasts.view_lines(look.walks == true, views.walking)
        end

        local packed = tab_pages(c, m, entry, variant_lines, facts_lines, #view_keys, wears ~= nil, wears and wears.fits)
        state.tab_pages = math.max(1, #packed)
        state.tab_page = math.max(1, math.min(state.tab_page, state.tab_pages))
        p.turn.set(state.tab_page, state.tab_pages)
        vis(p.turn.row, state.tab_pages > 1)
        if p.model then
            local viewed = look ~= nil and (state.tab_page == 1 or wears ~= nil)
            if viewed then p.view_keys:Set(table.concat(view_keys, "\n")) end
            vis(p.model, viewed)
            vis(p.view_keys, viewed)
        end
        local shown = packed[state.tab_page] or {}
        for at, part in ipairs(p.sections) do
            local section = shown[at] or {}
            if section.title then part.title:Set(section.title) end
            vis(part.title, section.title ~= nil)
            -- the level the numbers are of, and the ways to another one
            local picker = part.level
            if picker then
                local row = section.level
                if row then
                    state.level_now, state.level_last, picker.levels = row.value, row.last, row.quick
                    picker.label:Set(beasts.level(row.value))
                    set_once(picker.minus, "on", row.value > 1, function(control, value) control:SetEnabled(value) end)
                    set_once(picker.plus, "on", row.value < row.last, function(control, value) control:SetEnabled(value) end)
                    for index, button in ipairs(picker.quick) do
                        local level = row.quick[index]
                        if level then
                            set_once(button, "caption", tostring(level), function(control, value) control:SetCaption(value) end)
                            set_once(button, "active", level == row.value, function(control, value) control:SetActive(value) end)
                        end
                        vis(button, level ~= nil)
                    end
                    picker.watch()
                end
                vis(picker.row, row ~= nil)
                vis(picker.quick_row, row ~= nil)
            end
            local said = section.text and section.text[1] and table.concat(section.text, "\n") or nil
            if said then part.text:Set(said) end
            vis(part.text, said ~= nil)
            local chosen = nil
            if section.pairs and section.pairs[1] then
                local names, values = {}, {}
                for index, pair in ipairs(section.pairs) do names[index], values[index] = pair.name, pair.value end
                chosen = host.pair_fit(names, values)
                part.pairs[chosen].names:Set(table.concat(names, "\n"))
                part.pairs[chosen].values:Set(table.concat(values, "\n"))
            end
            for index, pair in ipairs(part.pairs) do vis(pair.control, index == chosen) end
            local after = section.after and section.after[1] and table.concat(section.after, "\n") or nil
            if after then part.after:Set(after) end
            vis(part.after, after ~= nil)
            local looks = {}
            for index, slot in ipairs(section.slots or {}) do
                -- a saddle the model can wear says what a click does, and the one it wears is marked
                if wears and slot.item and wears.fits[slot.item] then
                    local on = wears.item == slot.item
                    looks[index] = slot_look(slot, beasts.saddle_tip(on))
                    looks[index].selected = on or nil
                else
                    looks[index] = slot_look(slot)
                end
            end
            fill(part.slots, looks)
            local note = section.note and section.note[1] and table.concat(section.note, "\n") or nil
            if note then part.note:Set(note) end
            vis(part.note, note ~= nil)
            vis(part.tail, #looks > 0 and note == nil)
        end
        return true
    end

    -- Brings what the panel shows in line with what is asked of it: the list, or the creature that is open.
    local function settle()
        local p = parts
        if not (p and p.ready.list) or not state.stale then return end
        state.stale = false
        local paged = state.open ~= nil and p.ready.page and show_page()
        if not paged then
            state.open = nil
            drop_view()
            for _, control in ipairs(p.paged or {}) do vis(control, false) end
        end
        for _, control in ipairs(p.list) do vis(control, not paged) end
        if paged then
            for _, control in ipairs(p.optional) do vis(control, false) end
            return
        end
        if p.box ~= state.query then
            p.box = state.query
            p.find:Set(p.box)
        end
        show_list()
    end

    function changed()
        state.stale = true
        if state.shown then settle() end
    end

    -- Controls are made a few a frame, so the game does not stall while the panel is built. count: how many were just made.
    local made = 0
    local function pace(count)
        made = made + count
        if made < creature_view.CHUNK or not coroutine.isyieldable() then return end
        made = 0
        task.wait()
    end

    -- chooses: a function that is given a click first and says true when it took it.
    local function wired(block, chooses)
        host.wire(block, chooses or false)
        return block
    end

    local function build_list(p)
        local L = host.L()
        local panel = ui.Panel({ anchor = host.column.anchor, x = host.column.x, y = host.column.y, width = host.column.width,
            height = host.column.height, padding = host.column.padding, zoom = L.zoom, when = "always", opacity = 1,
            visible = false, place = host.place })
        p.panel = panel
        p.sides = host.side_tabs(panel)
        pace(4)
        p.filters = wired(panel:Slots({ columns = 6, rows = L.filter_rows, size = L.filter, gap = GAP, below = L.snug }))
        p.count = panel:Label("", { size = small, dim = true, align = "center" })
        -- "This map only", where the item side has "This bench only": there while a map is loaded
        local map_row = panel:Row()
        p.map_only = map_row:Toggle(beasts.map_only, state.map_only, function(on)
            state.map_only, state.page = on, 1
            app.settings.map_only = on
            app.save()
            changed()
            host.repaint()
        end)
        p.map_row = map_row.control
        p.no_map = panel:Label(beasts.no_map, { size = small, dim = true, align = "center" })
        -- the order of the list: the game's, or from the most of a figure to the least
        local names, order_of = {}, {}
        for at, order in ipairs(creature_view.ORDERS) do
            names[at] = beasts.orders[order]
            order_of[names[at]] = order
        end
        p.order = panel:Dropdown(nil, names, beasts.orders.game, function(choice)
            local order = order_of[choice] or "game"
            p.set[p.order] = p.set[p.order] or {}
            p.set[p.order].choice = order
            if order == state.order then return end
            state.order, state.page = order, 1
            app.settings.beast_order = order
            app.save()
            changed()
        end)
        p.optional = { p.map_row, p.no_map, p.order }
        for _, control in ipairs(p.optional) do
            control:SetVisible(false)
            showing[control] = false
        end
        pace(8)
        p.pager = host.page_line(panel, function(by)
            state.page = state.page + by
            changed()
        end)
        pace(6)
        p.grid = wired(panel:Slots({ columns = L.beast_columns, rows = L.beast_rows, size = L.beast_cell, gap = GAP, below = L.snug }))
        p.find = panel:Input(nil, { hint = words.search, clear = true })
        -- one line of the column: the short form when the long one would take two
        local binds = { make = host.keys.make, used = host.keys.used, favourite = host.keeps and host.keys.favourite or nil }
        local keys = beasts.keys(binds)
        if #rows.wrap(keys, L.inner * rows.LINE, small) > 1 then keys = beasts.keys(binds, true) end
        p.keys = panel:Label(keys, { size = small, dim = true, align = "center" })
        p.list = { p.sides.row, p.filters, p.count, p.pager.row, p.grid, p.find, p.keys }
        pace(3)
        for _, control in ipairs(p.list) do showing[control] = true end

        -- a tile is chosen; the chosen one clicked again, or any tile while an item's droppers are listed, is all of them
        p.filters.Activated:Connect(function(value)
            if type(value) ~= "table" or value.filter == nil then return end
            local wanted = value.filter or nil
            if state.item == nil and wanted == state.filter then wanted = nil end
            state.filter, state.item, state.uses, state.page = wanted, nil, nil, 1
            changed()
            host.repaint()
        end)
        p.find.Typed:Connect(function(typed)
            p.box = typed
            if typed == state.query then return end
            state.query, state.page = typed, 1
            changed()
            host.repaint()
        end)
        -- the wheel turns the list's pages, and on a creature's page the pages of its tab
        panel.Scrolled:Connect(function(by)
            if not state.open then
                state.page = state.page + by
            elseif state.tab_pages > 1 then
                state.tab_page = state.tab_page + by
            else
                return
            end
            changed()
        end)
        p.box = ""
    end

    local function pick_tab(name)
        if not state.open or name == state.tab then return end
        state.tab, state.tab_page = name, 1
        -- stepping back to this creature later shows the tab it was left on
        local top = app.history:top()
        if top and top.creature == state.open then top.mode = name end
        changed()
    end

    local function build_page(p)
        local panel, L = p.panel, host.L()
        local paged = {}
        local function hidden(control)
            control:SetVisible(false)
            showing[control] = false
            paged[#paged + 1] = control
            return control
        end
        local top = panel:Row()
        p.back = top:Button(beasts.back, function() host.close() end, { icon = "arrow-left", stretch = false })
        top:Label("")
        p.previous = top:Button(nil, function() host.back() end, { icon = "undo-2" })
        p.star = top:Button(nil, function() if state.open then host.favourite({ creature = state.open }) end end, { icon = "star" })
        p.top = hidden(top.control)
        pace(5)
        local name_row = panel:Row()
        p.head = wired(name_row:Slots({ columns = 1, rows = 1, size = L.cell, gap = 0 }))
        p.title = name_row:Heading("")
        p.name_row = hidden(name_row.control)
        p.word = hidden(panel:Label(""))
        p.facts = hidden(panel:Label("", { size = small, dim = true }))
        pace(5)
        -- one line of variants, or two for a group with more than five
        p.variants = {}
        for lines = 1, 2 do
            local block = wired(panel:Slots({ columns = ACROSS, rows = lines, size = L.cell, gap = GAP }))
            block.Activated:Connect(function(value)
                if type(value) ~= "table" or not value.variant or value.variant == state.variant then return end
                state.variant, state.tab_page = value.variant, 1
                local seen = app.history:top()
                if seen and seen.creature == state.open then seen.variant = value.variant end
                changed()
            end)
            p.variants[lines] = hidden(block)
        end
        pace(2)
        p.tabs, p.tab_rows = {}, {}
        for at, name in ipairs(pages.TABS) do
            local line = (at - 1) // 2 + 1
            if not p.tab_rows[line] then
                p.tab_rows[line] = panel:Row()
                hidden(p.tab_rows[line].control)
            end
            p.tabs[name] = p.tab_rows[line]:Button(beasts.tabs[name], function() pick_tab(name) end, { tab = true })
        end
        for line, row in ipairs(p.tab_rows) do p.tab_rows[line] = row.control end
        p.rule = hidden(panel:Separator())
        pace(7)
        p.turn = host.page_line(panel, function(by)
            state.tab_page = state.tab_page + by
            changed()
        end)
        hidden(p.turn.row)
        -- the 3D view of About, on a Wax that has the control and a list of the creatures' models
        local can, make = pcall(function() return panel.Model end)
        local has, get = pcall(function() return game.Creatures.GetModel end)
        if can and has and type(make) == "function" and type(get) == "function" then
            -- on the colour of the page's buttons, a little brighter than the control lights it by itself
            local made_it, control = pcall(make, panel, { width = L.view.width, height = L.view.height, backdrop = theme.raised,
                light = creature_view.LIGHT })
            if made_it and control then
                p.model = hidden(control)
                p.view_keys = hidden(panel:Label("", { size = small, dim = true, align = "center" }))
                -- a model the game could not show: the page closes up as if there were none
                control.Failed:Connect(function()
                    if views.setup then views.looks[views.setup] = false end
                    views.shown, views.setup = nil, nil
                    changed()
                end)
                -- a press that did not turn it stops the walk, and the next one starts it
                control.Clicked:Connect(function()
                    local look = views.setup and views.looks[views.setup]
                    if not (look and look.walks) then return end
                    views.walking = not views.walking
                    control:SetAnimation(views.walking and "walk" or (look.idle and "idle" or false))
                    -- Taming's lines say what the model wears, not whether it walks
                    if state.tab ~= "taming" then p.view_keys:Set(table.concat(beasts.view_lines(true, views.walking), "\n")) end
                end)
            end
            pace(3)
        end
        -- the level the numbers of About are of: never under 1 or past the creature's last
        local function pick_level(level)
            local last = state.level_last
            if not (state.open and last and level) then return end
            level = math.max(1, math.min(last, math.floor(level)))
            if level == state.level_now then return end
            state.level = level
            changed()
        end
        local function step_level(by)
            local now = state.level_now
            if now then pick_level(now + by * pages.STEP) end
        end
        p.sections = {}
        for at = 1, pages.MOST do
            local part = { title = hidden(panel:Label("", { size = small, dim = true })), pairs = {} }
            -- the numbers are the first section of About, so the level row stands in the first of the pool
            if at == 1 then
                -- as the amount of the Materials tab: a row to step, and a row of quick ones, here tabs so the chosen one is
                -- marked. Four of them, each a tab: six plain buttons in one line had no room for a number.
                local picker = { quick = {} }
                local row = panel:Row()
                -- a press that ends a hold has stepped already
                local function pressed(by)
                    if picker.repeated then
                        picker.repeated = nil
                        return
                    end
                    step_level(by)
                end
                picker.minus = row:Button(nil, function() pressed(-1) end, { icon = "minus", tip = beasts.about.level_down })
                picker.label = row:Label("", { align = "center" })
                picker.plus = row:Button(nil, function() pressed(1) end, { icon = "plus", tip = beasts.about.level_up })
                picker.row = hidden(row.control)
                local quick = panel:Row()
                for index = 1, pages.QUICK_MOST do
                    -- made with a caption as long as any it will have, so its room is worked out for one
                    picker.quick[index] = quick:Button("000", function() pick_level(picker.levels and picker.levels[index]) end, { tab = true })
                end
                picker.quick_row = hidden(quick.control)
                -- Holding the minus or the plus goes on stepping. The library has no word for a held button, so its own
                -- widget is asked, only while the row shows and never once the button is destroyed.
                local function held(button)
                    if button.destroyed or not button.source then return false end
                    local ok, down = pcall(function() return button.source:IsPressed() end)
                    return ok and down == true
                end
                function picker.watch()
                    if picker.watching then return end
                    picker.watching = true
                    task.spawn(function()
                        local since, by = nil, 0
                        while parts == p and state.shown and state.open and state.level_now and showing[picker.row] do
                            local now = os.clock()
                            local down = held(picker.minus) and -1 or (held(picker.plus) and 1 or 0)
                            if down == 0 or down ~= by then
                                -- let go: the press that ends a hold has been told by now, so the next one counts again
                                if down == 0 then picker.repeated = nil end
                                since, by = down ~= 0 and now or nil, down
                            elseif now - since >= creature_view.HOLD then
                                since = now - creature_view.HOLD + creature_view.REPEAT
                                picker.repeated = true
                                step_level(by)
                            end
                            task.wait()
                        end
                        picker.watching = nil
                    end)
                end
                part.level = picker
                pace(8)
            end
            part.text = hidden(panel:Label(""))
            for index, split in ipairs(host.pair_splits) do
                local pair = panel:Row()
                part.pairs[index] = { control = hidden(pair.control), names = pair:Label("", { weight = split[1] }),
                    values = pair:Label("", { align = "right", weight = split[2] }) }
            end
            pace(11)
            part.after = hidden(panel:Label(""))
            part.slots = {}
            for line = 1, pages.SLOTS // ACROSS do
                part.slots[line] = hidden(wired(panel:Slots({ columns = ACROSS, rows = 1, size = L.cell, gap = GAP, below = GAP }), wear))
            end
            part.tail = hidden(panel:Spacer(L.beast_heights.tail))
            part.note = hidden(panel:Label("", { size = small, dim = true }))
            p.sections[at] = part
            pace(5)
        end
        p.paged = paged
    end

    -- Makes the panel the first time it is wanted: the list, then the page. True once `what` ("list" or "page") is there.
    local function ensure(what)
        if not parts then
            local p = { ready = {}, set = {} }
            parts = p
            local function run()
                build_list(p)
                p.ready.list = true
                p.sides.show("beasts", state.counts, state.off == true)
                build_page(p)
                p.ready.page = true
            end
            local function guarded()
                local ok, problem = xpcall(run, debug.traceback)
                if ok then return end
                p.failed = true
                error(problem, 0)
            end
            if coroutine.isyieldable() then task.spawn(guarded) else guarded() end
        end
        while not parts.ready[what] do
            if parts.failed or not coroutine.isyieldable() then return false end
            task.wait()
        end
        return true
    end

    -- True while the Bestiary panel is what the column shows: its list, or a creature's page.
    function self.active()
        if not (parts and parts.ready.list) then return false end
        return state.open ~= nil or (host.side() == "beasts" and not host.item_open())
    end

    function self.visible() return state.shown end

    function self.set_visible(shown)
        shown = shown and true or false
        if shown == state.shown then return end
        state.shown = shown
        if not parts or not parts.panel then return end
        -- hidden, the column keeps no model in the world: it is shown again with the page
        if not shown and views.shown then
            drop_view()
            state.stale = true
        end
        -- another map was loaded while the column was away
        if shown and host.map() ~= state.map then state.stale = true end
        if shown then settle() end
        parts.panel:SetVisible(shown)
    end

    -- The creature whose page is open, or nothing.
    function self.page() return state.open end

    -- The panel's controls once they are made, for a test or a script that presses them.
    function self.parts() return parts end

    -- Opens a creature's page on a tab. stay: it is not noted in the history. variant: which one of its line shows.
    function self.open(id, tab, stay, variant)
        local c = model()
        if not (c and c.entries[id]) or not ensure("page") then return false end
        c = model()
        local entry = c and c.entries[id]
        if not entry then return false end
        local open = app.page.tabs(entry)
        tab = open[tab] and tab or "about"
        variant = math.max(1, math.min(math.floor(tonumber(variant) or 1), math.max(1, #entry.variants)))
        -- the level picked on one creature stays for the next, pulled into that one's own levels: two at one level is one step
        state.open, state.tab, state.variant, state.tab_page = id, tab, variant, 1
        if not stay then app.history:push({ item = "c:" .. id, creature = id, mode = tab, variant = variant }) end
        state.stale = true
        host.close_item()
        if state.shown then settle() end
        host.repaint()
        return true
    end

    -- An item is being opened: the item panel takes the column.
    function self.leave()
        if not state.open then return end
        state.open, state.stale = nil, true
        drop_view()
    end

    -- Back to the list.
    function self.close()
        if not state.open then return end
        state.open = nil
        changed()
    end

    -- The creature model or the item model has more, or is another one.
    function self.refresh()
        counted, state.made = {}, nil
        changed()
    end

    -- What is typed in this side's box.
    function self.query() return state.query end

    -- The game loaded another map, or left one: "This map only" lists what that one has.
    function self.map_changed()
        changed()
    end

    -- A tab of the two was pressed. The panel is made the first time, and the items stay in the column until it is there.
    function self.side_changed()
        if host.side() ~= "beasts" then return end
        app.beasts.want()
        state.stale = true
        if not ensure("list") then host.set_side("items") end
    end

    -- What the two tabs say on this side too.
    function self.sides(counts, off)
        state.counts, state.off = counts, off
        if parts and parts.ready.list then parts.sides.show("beasts", counts, off == true) end
    end

    -- How many creatures the typed text and the chosen tile leave. Nothing while they cannot be listed.
    function self.count()
        local found = matching()
        return found and #found or nil
    end

    -- Lists the creatures that give an item, or with `uses` those it is used on, on the Bestiary side.
    local function list_among(key, uses)
        local c = model()
        if not (c and (uses and c.uses or c.drops)[key]) then return false end
        state.item, state.uses, state.filter, state.page = key, uses or nil, nil, 1
        host.close()
        -- exactly those: what is typed in this side's box would leave fewer
        state.query = ""
        state.stale = true
        if host.side() ~= "beasts" then
            host.set_side("beasts")
        else
            if state.shown then settle() end
            host.repaint()
        end
        return true
    end
    function self.list_drops(key) return list_among(key, false) end
    function self.list_users(key) return list_among(key, true) end

    -- The looks of the creatures that give an item, most first, no more than `limit` of them, and how many there are.
    function self.droppers(key, limit)
        local c = model()
        if not c then return {}, 0 end
        return app.page.droppers(c, key, is_kept, limit), #(c.drops[key] or {})
    end

    -- The looks of the creatures an item is used on, no more than `limit` of them, and how many there are.
    function self.users(key, limit)
        local c = model()
        if not c then return {}, 0 end
        return app.page.users(c, key, is_kept, limit), #(c.uses[key] or {})
    end

    -- What is kept changed. id: only that creature, so its cell and its star follow without the list being set again.
    function self.kept_changed(id)
        local p = parts
        if not (p and p.ready.list) then return end
        local c = model()
        local entry = id and c and c.entries[id]
        -- a Wax from before one slot could be set again sets the list anew
        if not entry or not state.shown or state.stale or not p.grid.SetLook then return changed() end
        if state.open == id and p.ready.page then
            p.star:SetIcon(is_kept(id) and ui.Icons.Has("star-off") and "star-off" or "star")
        end
        local at = not state.open and state.where and state.where[id]
        if at then p.grid:SetLook(at, app.page.cell(entry, { kept = is_kept(id), internal = app.settings.internal_names })) end
    end

    -- How many slots across the block of the list is, for a hold that sweeps over it. Nothing for any other block.
    function self.across(control)
        if parts and control == parts.grid then return host.L().beast_columns end
        return nil
    end

    -- A creature as something that can be kept, for the shelf: its key in a slot, its look there, and whether the game has it.
    self.thing = {
        prefix = "c",
        key_of = function(value) return type(value) == "table" and value.creature or nil end,
        look = function(key)
            local c = model()
            local entry = c and c.entries[key]
            return entry and app.page.cell(entry, { outside = true, kept = true }) or nil
        end,
        known = function(key)
            local c = model()
            return c ~= nil and c.entries[key] ~= nil
        end,
    }

    return self
end

return creature_view
