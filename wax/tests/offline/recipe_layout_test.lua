-- Offline tests for where the Recipe Browser puts things, for screens of many shapes: nothing may overlap or leave the screen.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\recipe_layout_test.lua luamods\RecipeBrowser

local t = dofile("wax/tests/offline/harness.lua")

local folder = arg and arg[1]
if folder then folder = folder:gsub("\\", "/"):gsub("/+$", "") end
local file = folder and io.open(folder .. "/layout.lua", "rb")
if not file then
    print("recipe-layout: 0 passed (skipped: Recipe Browser is not here)")
    os.exit(0)
end
file:close()

local layout = assert(loadfile(folder .. "/layout.lua"))()

-- The game scales its interface by the shorter side of the screen, 1 at 1080: a screen in pixels as the units panels use.
local function units(width, height)
    local scale = math.min(width, height) / 1080
    return width / scale, height / scale
end

local SCREENS = {
    { "1280x720", 1280, 720 }, { "1920x1080", 1920, 1080 }, { "2560x1440", 2560, 1440 }, { "3840x2160", 3840, 2160 },
    { "2560x1080", 2560, 1080 }, { "3440x1440", 3440, 1440 }, { "5120x1440", 5120, 1440 },
    { "1920x1200", 1920, 1200 }, { "1680x1050", 1680, 1050 }, { "2560x1600", 2560, 1600 },
    { "1024x768", 1024, 768 }, { "1600x1200", 1600, 1200 }, { "1280x1024", 1280, 1024 },
    -- the game in a small window, as the player had it, and odd shapes
    { "1393x776", 1393, 776 }, { "800x600", 800, 600 }, { "1100x500", 1100, 500 }, { "2560x1369", 2560, 1369 },
}

t.test("at 16 by 9 it is the layout that was looked at in the game", function()
    for _, size in ipairs({ { 1920, 1080 }, { 2560, 1440 }, { 3840, 2160 } }) do
        local L = layout.compute(units(size[1], size[2]))
        t.eq(L.column, 224)
        t.eq(L.cell, 40.79, "five across end on the column's right edge")
        t.eq(L.tab, 33.66, "and so do six tiles")
        t.eq(L.grid_rows, 11)
        t.eq(L.favourite_columns, 34, "slots of 36 on the shelf")
        t.ok(L.shelf_cell >= layout.SHELF_CELL and L.shelf_cell < layout.SHELF_CELL + 1.2)
        t.ok(math.abs(L.scale - 0.8448) < 0.0005, "the game's screens are at " .. L.scale)
        t.eq(L.menu_x, 7, "the game's screens start at the left gap")
        t.eq(L.hold.x, 0)
        t.eq(L.hold.y, 0)
        local scale, x, y = L.fit("UMG_MainMenu", 2)
        t.eq(scale, L.scale)
        t.ok(math.abs(x - 7 / 1920) < 1e-9)
        t.ok(y < 0, "the main menu moves up")
    end
end)

for _, size in ipairs(SCREENS) do
    t.test(size[1] .. ": everything is on the screen and nothing overlaps", function()
        local width, height = units(size[2], size[3])
        local L = layout.compute(width, height)
        -- inside the column nothing depends on the screen: it is the design for 1920 by 1080, drawn larger or smaller
        local design = layout.compute(1920, 1080)
        for _, name in ipairs({ "column", "tall", "inner", "down", "cell", "tab", "grid_rows", "budget" }) do
            t.eq(L[name], design[name], name .. " is the same on every screen")
        end
        t.ok(L.zoom <= layout.ZOOM + 1e-9 and L.zoom >= layout.ZOOM * 0.7, "the panels are drawn at " .. L.zoom)
        t.ok(L.top >= 2 and L.top + L.tall * L.zoom <= height - 2 + 0.01, "the column is on the screen from top to bottom")
        t.ok(L.cell * L.zoom >= 26, "a slot is drawn " .. L.cell * L.zoom .. " wide")
        t.ok(L.scale >= 0.5 and L.scale <= 1, "scale " .. L.scale)
        t.ok(L.column_left > width * 0.6, "the column is not most of the screen")
        t.ok(L.column * L.zoom <= 300, "the column is no wider than on a 16 by 9 screen, " .. L.column * L.zoom)
        t.ok(math.abs(L.column_left + L.column * L.zoom + 4 - width) < 0.01, "the column ends four units from the screen's edge")
        -- the shelf spans the room: from two units off the left edge to two units before the column, with no gap at either end
        t.eq(L.shelf_x, 2, "the shelf starts two units from the screen's edge")
        local shelf_end = L.shelf_x + L.shelf * L.zoom
        t.ok(shelf_end <= L.column_left - 2 + 0.01, "the shelf ends before the column, at " .. shelf_end)
        t.ok(shelf_end >= L.column_left - 2 - L.zoom - 0.01, "and reaches it: " .. shelf_end .. " of " .. L.column_left)
        t.ok(L.favourite_columns * (L.shelf_cell + layout.GAP) - layout.GAP <= L.shelf - 12 + 0.01, "a full row fits the shelf")
        -- The shelf's box is the same distance from what is in it on all four sides, and a full row of slots ends at
        -- that distance from its right edge. With more than one page the page line stands under the rows, in the middle.
        local PAD = layout.PAD
        t.ok(L.shelf_cell >= 34, "a slot on the shelf is " .. L.shelf_cell)
        local slots_end = PAD + L.favourite_columns * (L.shelf_cell + layout.GAP) - layout.GAP
        t.ok(slots_end <= L.shelf - PAD + 0.01, "a full row ends at " .. slots_end .. " of " .. (L.shelf - PAD))
        -- a slot's size is rounded down to a hundredth, so a row can stop that much short for each slot in it
        t.ok(slots_end >= L.shelf - PAD - L.favourite_columns * 0.01 - 0.01, "and reaches the shelf's inner edge")
        for lines = 1, layout.FAVOURITE_ROWS do
            local rows_high = lines * (L.shelf_cell + layout.GAP) - layout.GAP
            local box_high = (L.shelf_bottom(lines, false) - L.top) / L.zoom
            t.ok(math.abs(box_high - rows_high - 2 * PAD) < 0.01, "the shelf's box is " .. PAD .. " above and below its " .. lines .. " rows")
            -- with pages: the page line stands a little further under the rows than they are from each other, and the
            -- box is as far under it as it is from everything else
            local form = layout.PAGE_LINE
            t.eq(form.above, layout.GAP + 2, "the gap over the page line is the gap between rows and two more")
            t.ok(form.height < L.shelf_cell, "the page line is lower than a slot")
            local paged_high = (L.shelf_bottom(lines, true) - L.top) / L.zoom
            t.ok(math.abs(paged_high - (PAD + rows_high + form.above + form.height + PAD)) < 0.01, "with pages the shelf is one page line taller")
            for _, pages in ipairs({ 2, 9, 10, 99 }) do
                local what = pages .. " pages"
                local line = L.pager_place(lines, pages >= 10)
                local left, top = (line.x - L.shelf_x) / L.zoom, (line.y - L.top) / L.zoom
                t.eq(line.width, 2 * (form.height + form.gap) + line.text, what .. ": an arrow, a gap, the text, a gap, an arrow")
                t.eq(line.text, form.text[pages >= 10 and 2 or 1])
                t.ok(math.abs(top - (PAD + rows_high + form.above)) < 0.01, what .. ": the page line starts " .. form.above .. " under the last row")
                t.ok(math.abs(top + line.height + PAD - paged_high) < 0.01, what .. ": and ends the shelf's padding above its lower edge")
                t.ok(left >= PAD and left + line.width <= L.shelf - PAD + 0.01, what .. ": it is inside the shelf from side to side")
                t.ok(math.abs(left - (L.shelf - left - line.width)) < 0.01, what .. ": in the middle of it")
                t.eq(line.zoom, L.zoom)
            end
        end
        for name in pairs(layout.SCREENS) do
            for lines = 0, layout.FAVOURITE_ROWS do
                for _, pager in ipairs({ false, true }) do
                    local where = ("%s with %d lines%s"):format(name, lines, pager and " and pages" or "")
                    local left, top, right, bottom = L.rect(name, lines, pager)
                    t.ok(left >= layout.SIDE - 0.01, where .. ": starts at " .. left)
                    t.ok(math.abs(left - (L.column_left - right)) <= 1, where .. ": the gap at its left, " .. left .. ", is the gap at its right, " .. (L.column_left - right))
                    t.ok(right <= L.column_left - 4, where .. ": ends at " .. right .. ", the column starts at " .. L.column_left)
                    t.ok(top >= L.shelf_bottom(lines, pager) + 2, where .. ": top " .. top .. " under the shelf at " .. L.shelf_bottom(lines, pager))
                    t.ok(bottom <= L.hotbar + 1, where .. ": bottom " .. bottom .. " above the hotbar at " .. L.hotbar)
                    -- midway: as far under the shelf (and the six units kept free under it) as it is above the hotbar
                    local above, below = top - (L.shelf_bottom(lines, pager) + 6), L.hotbar - bottom
                    t.ok(math.abs(above - below) < 0.01, where .. ": " .. above .. " above it and " .. below .. " below it")
                    local scale, x, y = L.fit(name, lines, pager)
                    t.ok(math.abs(x) <= 0.5 and math.abs(y) <= 0.5, where .. ": the move is within what ui.FitGame takes")
                    t.eq(scale, L.scale)
                end
            end
        end
        -- a bench with its list replaced: no shelf, and the favourites where the list was
        local left, top, right, bottom = L.rect("UMG_Processor_C", nil)
        t.ok(top >= 4 and bottom <= L.hotbar + 1, "a bench without the shelf is on the screen")
        local list = L.bench_list()
        t.ok(list.x >= left - 0.01 and list.x + list.width * L.zoom <= right + 0.01, "the favourites are inside the bench's screen")
        t.ok(list.y >= top - 0.01 and list.y + list.height * L.zoom <= bottom + 0.01)
        t.ok(list.width >= 3 * (L.cell + layout.GAP) + 12, "the favourites have room for three across")
    end)
end

t.test("where the game's own menu was measured in captures of five window sizes is where the layout says it is", function()
    -- { window in pixels, how far up the game's screens were moved then (ui.FitGame's y), the top and the bottom of the menu's sheet in pixels }
    local MEASURED = {
        { 2560, 1369, -0.036856, 250, 1155 }, { 1393, 776, -0.039725, 144, nil }, { 1280, 720, -0.041025, 134, 604 },
        -- wider than 16 by 9: the box is in the middle from side to side, and nothing changes from top to bottom
        { 1100, 500, -0.024682, 88, nil },
        -- taller than 16 by 9: what is made smaller reaches to the screen's bottom, 96 pixels under the box's own
        { 1024, 768, -0.041820, 220, 594 },
    }
    for _, seen in ipairs(MEASURED) do
        local pixels = math.min(seen[1], seen[2]) / 1080
        local L = layout.compute(seen[1] / pixels, seen[2] / pixels)
        local _, top, _, bottom = L.rect("UMG_MainMenu", 0, false)
        -- the sheet as the layout places it, with the move the game really had in place of the one it would ask for now
        local moved = L.lift("UMG_MainMenu", 0, false) + seen[3] * L.hold.h
        local what = seen[1] .. " by " .. seen[2]
        t.ok(math.abs((top + moved) * pixels - seen[4]) <= 2, what .. ": its top is at " .. (top + moved) * pixels .. ", measured " .. seen[4])
        if seen[5] then
            t.ok(math.abs((bottom + moved) * pixels - seen[5]) <= 3, what .. ": its bottom is at " .. (bottom + moved) * pixels .. ", measured " .. seen[5])
        end
        -- from side to side it was the same gap at its left as before the column, within a pixel, at every one of these sizes
        local left, _, right = L.rect("UMG_MainMenu", 0, false)
        t.ok(math.abs(left - (L.column_left - right)) * pixels <= 1, what)
    end
end)

t.test("on a screen taller than 16 by 9 the hotbar is at the bottom of the screen, and the game's menu sits between it and the shelf", function()
    -- 1024 by 768: the hotbar's slots were seen from 708 pixels down, a little under the line the layout keeps free
    local pixels = 768 / 1080
    local L = layout.compute(1024 / pixels, 768 / pixels)
    t.ok(L.hold.y > 100, "the game's box is in the middle of the screen from top to bottom")
    t.ok(math.abs(L.hotbar * pixels - 702) < 1.5, "the hotbar line is at " .. L.hotbar * pixels)
    t.ok(L.hotbar > L.hold.y + L.hold.h, "which is under the game's box, not in it")
    for _, lines in ipairs({ 0, 1, 2 }) do
        local _, top, _, bottom = L.rect("UMG_MainMenu", lines, lines == 2)
        local shelf = L.shelf_bottom(lines, lines == 2)
        t.ok(math.abs((top - shelf - 6) - (L.hotbar - bottom)) < 0.01, "midway with " .. lines .. " rows on the shelf")
        t.ok(top > shelf + 20 and bottom < L.hotbar - 20, "with room to spare above and below")
    end
    -- at 16 by 9 and wider the hotbar is where it always was
    for _, size in ipairs({ { 1920, 1080 }, { 2376, 1080 }, { 2019.58, 1080 } }) do
        t.ok(math.abs(layout.compute(size[1], size[2]).hotbar - layout.HOTBAR * 1080) < 0.01)
    end
end)

t.test("the size the game reports for 1920 by 1080 gives the same layout as the round numbers", function()
    local near, exact = layout.compute(1919.9999427795, 1079.9999678135), layout.compute(1920, 1080)
    for _, name in ipairs({ "column", "tall", "cell", "tab", "grid_rows", "shelf", "favourite_columns", "scale", "menu_x" }) do
        t.eq(near[name], exact[name], name)
    end
end)

t.test("a screen that is not listed stays where it is", function()
    local L = layout.compute(1920, 1080)
    t.eq(L.lift("UMG_FieldGuide_C", 2), 0)
    local _, _, y = L.fit("UMG_FieldGuide_C", 2)
    t.eq(y, 0)
end)

-- The row of the two sides and the Bestiary side are not in every copy of the mod: a layout.lua without them leaves these out.
if layout.BEAST_COLUMNS then
    local HIGH, GAP = layout.HIGH, layout.GAP

    t.test("the item list with the row of the two sides fits the column, also with the bench switch showing", function()
        for _, size in ipairs(SCREENS) do
            local L = layout.compute(units(size[2], size[3]))
            local what = size[1]
            t.eq(L.room, L.tall - layout.PAD, what .. ": the room is the column less the padding above it")
            t.eq(L.grid_rows, 11, what .. ": the items keep their eleven rows")
            t.eq(L.side_row, HIGH.tabs, what .. ": the two tabs are a row of tabs")
            t.eq(HIGH.tabs, 35.3, what .. ": which is as tall as its buttons ask for")
            t.ok(L.snug < HIGH.under, what .. ": the tiles and the items give up part of the gap under them")
            -- by hand, with what each control asks for in the game: the tabs, 5 lines of tiles, their line, the page
            -- line, 11 lines of items, the search box, the keys
            local plain = (35.3 + 8) + (5 * L.tab + 4 * GAP + 4) + (16.4 + 8) + (32.3 + 8) + (11 * L.cell + 10 * GAP + 4) + (30 + 8) + (16.4 + 8)
            t.ok(math.abs(L.list_height(false, 1) - plain) < 0.01, what .. ": " .. L.list_height(false, 1) .. " for " .. plain)
            t.ok(math.abs(L.list_height(true, 1) - (plain + 22 + 8)) < 0.01, what .. ": the switch is one row more")
            t.ok(L.list_height(true, 1) <= L.room, what .. ": with the switch, " .. L.list_height(true, 1) .. " of " .. L.room)
            -- the keys are one line: with the switch showing a second line would not fit
            t.ok(L.list_height(true, 2) > L.room, what .. ": with the switch the keys have one line, not two: " .. L.list_height(true, 2))
            t.ok(L.list_height(false, 2) <= L.room, what .. ": two lines of keys fit while no bench is open")
            -- two tabs share the row, so each is half the column whatever it says
            t.ok(L.inner / 2 >= 100, what .. ": a tab is " .. L.inner / 2 .. " wide")
        end
    end)

    t.test("the Bestiary's list has the item list's bands in the same places, and fits the column", function()
        for _, size in ipairs(SCREENS) do
            local L = layout.compute(units(size[2], size[3]))
            local what = size[1]
            t.eq(L.beast_columns, 4, what)
            t.eq(L.beast_cell, 51.5, what)
            t.eq(L.filter, L.tab, what .. ": a category tile is the size of the item side's")
            t.eq(L.filter_rows, 2, what)
            t.eq(L.beast_rows, 10, what .. ": 40 creatures a page, under the map switch and the order of the list")
            t.ok(L.beast_columns * (L.beast_cell + GAP) - GAP <= L.inner, what .. ": four creatures across fit")
            t.ok(6 * (L.filter + GAP) - GAP <= L.inner, what .. ": six tiles across fit")
            -- with "This map only" showing, as it does in every prospect
            local tall = L.beast_list_height(L.beast_rows, 1, true)
            t.ok(tall <= L.room, what .. ": " .. tall .. " of " .. L.room)
            t.ok(L.beast_list_height(L.beast_rows + 1, 1, true) > L.room, what .. ": and one row more would not")
            -- the line that says what is listed is kept to one line while the switch shows: a second would not fit
            t.ok(L.beast_list_height(L.beast_rows, 2, true) > L.room, what .. ": one line of text over the list, not two")
            t.ok(L.beast_list_height(L.beast_rows, 2, false) <= L.room, what .. ": two lines fit while no map is loaded")
            -- by hand: the tabs, 2 lines of tiles, the line, the map switch, the order, the page line, 10 lines of
            -- creatures, the search box, the keys
            local by_hand = (35.3 + 8) + (2 * L.filter + GAP + 4) + (16.4 + 8) + (22 + 8) + (HIGH.order + 8) + (32.3 + 8)
                + (10 * L.beast_cell + 9 * GAP + 4) + (30 + 8) + (16.4 + 8)
            t.ok(math.abs(tall - by_hand) < 0.01, what .. ": " .. tall .. " for " .. by_hand)
            t.ok(math.abs(tall - L.beast_list_height(L.beast_rows, 1, false) - (HIGH.switch + 8)) < 0.01, what .. ": the switch is one row")
            -- the tabs, the tiles and the line under them start where the item side's do
            t.ok(math.abs(L.beast_list_height(0, 1) - L.list_height(false, 1) - (HIGH.order + 8)
                - ((L.filter_rows - layout.TAB_ROWS) * (L.filter + GAP) - (L.grid_rows * (L.cell + GAP)))) < 0.01, what .. ": the same bands")
            t.ok(L.beast_cell * L.zoom >= 30, what .. ": a creature is drawn " .. L.beast_cell * L.zoom .. " wide")
        end
    end)

    t.test("a creature's page: what stands above its tab and the least room a tab is given fit the column", function()
        for _, size in ipairs(SCREENS) do
            local L = layout.compute(units(size[2], size[3]))
            local what = size[1]
            -- by hand: back row, picture and name, word, two lines of facts, two rows of tabs, the rule
            local head = (32.3 + 8) + (L.cell + 8) + (18.3 + 8) + (2 * 16.4 + 8) + 2 * (35.3 + 8) + 13
            t.ok(math.abs(L.beast_head - head) < 0.01, what .. ": " .. L.beast_head .. " for " .. head)
            t.eq(L.beast_extra(false, 0, false), 0, what)
            t.eq(L.beast_extra(false, 1, false), L.cell + 8, what .. ": a line of variants")
            t.eq(L.beast_extra(false, 2, false), 2 * L.cell + GAP + 8, what .. ": two lines of them")
            t.ok(math.abs(L.beast_extra(false, 0, true) - 40.3) < 0.01, what .. ": the page line")
            t.ok(math.abs(L.beast_extra(true, 0, false) - (L.view.height + 8 + 16.4 + 8)) < 0.01, what .. ": the 3D view and its line of keys")
            t.eq(L.view.width, L.inner, what)
            t.ok(5 * (L.cell + GAP) - GAP <= L.inner, what .. ": five variants across fit")
            for _, view in ipairs({ false, true }) do
                for lines = 0, 2 do
                    for _, pager in ipairs({ false, true }) do
                        local budget = L.beast_budget(view, lines, pager)
                        local where = ("%s, view %s, %d lines of variants, pager %s"):format(what, tostring(view), lines, tostring(pager))
                        t.ok(math.abs(L.beast_head + L.beast_extra(view, lines, pager) + budget + HIGH.spare - L.room) < 0.01, where)
                        -- the least a tab is given holds a title, a line of text, two lines of slots and a note
                        t.ok(budget >= (16.4 + 8) + (18.3 + 8) + 2 * (L.cell + GAP) + (16.4 + 8), where .. ": " .. budget .. " for the tab")
                    end
                end
            end
            t.ok(math.abs(L.beast_budget(false, 0, false) - 586.21) < 0.01, what .. ": with nothing but the head, " .. L.beast_budget(false, 0, false))
            t.ok(math.abs(L.beast_budget(true, 2, true) - 271.93) < 0.01, what .. ": with everything, " .. L.beast_budget(true, 2, true))
            -- what was read in the game: the wolf's page on Taming asked for 255 above its tab, 48 for its line of
            -- variants and 40 for its page line, and what stood under them ran out of the column before these figures
            t.ok(math.abs(L.beast_head + L.beast_extra(false, 1, true) - 344.88) < 0.01, what)
            local high = L.beast_heights
            t.eq(high.line, 18.3, what .. ": a line of text, as the game draws it")
            t.eq(high.small, 16.4, what .. ": a line of small text")
            t.eq(high.slot, L.cell + GAP, what .. ": a line of slots and the gap under it")
            t.eq(high.under, 8, what)
            t.eq(high.tail, 6, what .. ": slots that end a section have the same gap under them as a text")
        end
    end)
end

-- The card of an item's creatures is not in every copy of the mod either.
if layout.CARD then
    local GAP = layout.GAP

    t.test("an item's page: the card of its creatures is as tall as a recipe's, holds what it says, and fits a page", function()
        for _, size in ipairs(SCREENS) do
            local L = layout.compute(units(size[2], size[3]))
            local what = size[1]
            t.eq(L.card(1), L.cell + GAP + 60, what .. ": a line of slots, its line of text, the rule")
            t.eq(L.card(3), 3 * (L.cell + GAP) + 60, what)
            t.eq(L.card(7), L.card(3), what .. ": a card is never more than three lines of slots")
            t.eq(L.card(0), L.card(1), what)
            -- those that give an item: up to two lines of five, then the line with the arrow and the item
            for _, case in ipairs({ { 1, 1, 2 }, { 5, 5, 2 }, { 6, 6, 3 }, { 10, 10, 3 }, { 11, 10, 3 }, { 90, 10, 3 } }) do
                local cells, lines = L.creature_card(case[1], false)
                t.eq(cells, case[2], what .. ": " .. case[1] .. " creatures give it")
                t.eq(lines, case[3], what .. ": " .. case[1] .. " creatures give it, lines")
            end
            -- those an item is used on: the item and the arrow first, then creatures to the card's end
            for _, case in ipairs({ { 1, 1, 1 }, { 3, 3, 1 }, { 4, 4, 2 }, { 8, 8, 2 }, { 9, 9, 3 }, { 13, 13, 3 }, { 14, 13, 3 } }) do
                local cells, lines = L.creature_card(case[1], true)
                t.eq(cells, case[2], what .. ": used on " .. case[1])
                t.eq(lines, case[3], what .. ": used on " .. case[1] .. ", lines")
            end
            for _, used in ipairs({ false, true }) do
                for count = 1, 100 do
                    local cells, lines = L.creature_card(count, used)
                    local where = ("%s: %d creatures, used %s"):format(what, count, tostring(used))
                    t.ok(cells >= 1 and cells <= count, where)
                    t.ok(cells + 2 <= lines * layout.COLUMNS, where .. ": the cells, the arrow and the item have their slots")
                    t.ok(lines <= layout.CARD_LINES, where)
                    -- with the line of research points over the recipes a page has 20 less
                    t.ok(L.card(lines) <= L.budget - 20, where .. ": " .. L.card(lines) .. " of " .. (L.budget - 20))
                end
            end
            -- the tallest card and a recipe with one line of inputs share a page
            t.ok(L.card(3) + L.card(2) <= L.budget, what .. ": " .. (L.card(3) + L.card(2)) .. " of " .. L.budget)
            t.ok(5 * (L.cell + GAP) - GAP <= L.inner, what .. ": five slots across fit")
        end
    end)
end

-- The owner, with a picture of the column: "why is this gui offcentered slightly and not perfect?" The blocks of cells
-- ended six pixels before the tabs, the page line and the search box did.
t.test("every band of the column has one left and one right edge: a full row of cells is as wide as the tabs and the search box", function()
    for _, size in ipairs(SCREENS) do
        local L = layout.compute(units(size[2], size[3]))
        local what = size[1]
        -- what a tenth of a pixel is in the column's units on this screen: no block may be further off than that
        local slack = 0.1 / math.max(1, L.zoom)
        local blocks = {
            { "the category tiles of the item side", layout.TAB_COLUMNS, L.tab },
            { "the items", layout.COLUMNS, L.cell },
            { "the category tiles of the Bestiary", layout.TAB_COLUMNS, L.filter },
            { "the creatures", L.beast_columns, L.beast_cell },
            { "a line of slots on a creature's page, and a full line of its variants", 5, L.cell },
            { "a line of slots on an item's page", layout.COLUMNS, L.cell },
        }
        for _, block in ipairs(blocks) do
            local wide = block[2] * block[3] + (block[2] - 1) * layout.GAP
            t.ok(wide <= L.inner + 1e-9, ("%s: %s are %.2f wide in %.2f"):format(what, block[1], wide, L.inner))
            t.ok(L.inner - wide <= slack, ("%s: %s end %.3f before the right edge"):format(what, block[1], L.inner - wide))
        end
        -- the bands that are one control each are the column's inner width by themselves: the 3D view says so too
        t.eq(L.view.width, L.inner, what)
        t.eq(L.inner, L.column - 2 * layout.PAD, what .. ": the same padding on both sides")
    end
end)

t.finish("recipe-layout")
