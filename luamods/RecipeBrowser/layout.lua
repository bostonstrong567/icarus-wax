-- Where everything goes for one screen size: the column, the shelf, and where the game's own screens are moved to.
-- All of it is plain arithmetic, so it is tested without the game for many screen shapes.

local layout = {}

layout.FIT = 0.85               -- the share of its width the game's interface keeps beside the column
layout.ZOOM = 1.25              -- the panels are drawn this much larger than a window
layout.GAP, layout.EDGE = 2, 8
layout.PAD = 6                  -- between the box of a panel and what is in it, on every side
layout.SIDE = 7                 -- the least room left free on each side of the game's own screens
layout.COLUMNS, layout.TAB_COLUMNS, layout.TAB_ROWS = 5, 6, 5
layout.FAVOURITE_ROWS = 2
layout.SHELF_CELL = 36          -- the side of a slot on the shelf: a little under the list's, and never under 34
-- The shelf's page line, a compact form of the column's: how tall it and its arrows are, the room between an arrow and
-- the text, the room for the text (up to "Page 9 of 9", and from ten pages on), and how far it stands under the rows.
layout.PAGE_LINE = { height = 24, gap = 8, text = { 70, 86 }, above = 4 }

-- How tall things are inside the column: what each control asks for in the game (read there with GetDesiredSize on
-- 2026-10-07; the same at every screen size). A row of buttons, a row of tabs, a text box, a line of text and of
-- small text, the gap under every control, the smaller gap under the two blocks of slots that give room for the row
-- of the two sides, a rule with its gaps, and the room a page keeps free at its end. The row of the bench switch
-- was not read: it is worked out from a capture.
layout.HIGH = { row = 32.3, tabs = 35.3, input = 30, switch = 22, line = 18.3, small = 16.4, under = 8, snug = 4, rule = 13, spare = 12,
    order = 34.3 }
-- The Bestiary side: slots across, lines of category tiles, and the 3D view on a creature's page.
layout.BEAST_COLUMNS, layout.FILTER_ROWS = 4, 2
layout.VIEW = 150
-- A card on an item's page, a recipe or its creatures: what it takes besides its lines of slots (its line of text, its
-- rule and the gaps), and how many lines of slots a card can be.
layout.CARD, layout.CARD_LINES = 60, 3

-- How wide the shelf's page line is, and its room for the text: wide from ten pages on.
function layout.page_line_width(wide)
    local line = layout.PAGE_LINE
    local text = line.text[wide and 2 or 1]
    return 2 * (line.height + line.gap) + text, text
end
-- The game lays its interface out in a box 16 wide and 9 high, fitted into the screen and centred. These are shares of
-- that box: where each kind of screen starts and ends, where the hotbar starts, and where a bench has its recipe list.
-- On a screen taller than the box (4 by 3) the hotbar is not in the box: it keeps the box's distance from the screen's bottom.
layout.SCREENS = { UMG_MainMenu = { 0.085, 0.858 }, UMG_Processor_C = { 0.031, 0.865 } }
layout.HOTBAR = 0.885
layout.BENCH_LIST = { left = 0.0070, top = 0.0329, right = 0.2930, bottom = 0.3519 }

-- A row of slots that ends exactly at the edge of what it is in: the side of one slot for that many across.
function layout.even(width, columns)
    return math.floor((width - 2 * layout.PAD - (columns - 1) * layout.GAP) / columns * 100) / 100
end

-- The side of one cell of a block that is so many across and as wide as what it stands in: its first cell starts on
-- the left edge of every other band of the column and its last one ends on their right edge.
function layout.across(width, columns)
    return math.floor((width - (columns - 1) * layout.GAP) / columns * 100) / 100
end

-- What is inside the column never changes: it is the design for a screen 1920 by 1080, and the whole column is drawn
-- larger or smaller (its zoom) to fit the screen there is. So a change of the screen's size builds nothing again.
local DESIGN_WIDTH, DESIGN_HEIGHT = 1920, 1080

-- width, height: the screen in the units panels are laid out in (ui.ScreenSize).
function layout.compute(width, height)
    width, height = tonumber(width) or 1920, tonumber(height) or 1080
    -- the game reports 1919.99994 for 1920, which must not cost a whole unit when sizes are rounded down
    width, height = math.floor(width * 100 + 0.5) / 100, math.floor(height * 100 + 0.5) / 100
    local GAP, EDGE = layout.GAP, layout.EDGE
    local L = { width = width, height = height, EDGE = EDGE, even = layout.even }

    -- inside the column: the same numbers on every screen
    L.column = math.floor(((1 - layout.FIT) * DESIGN_WIDTH - 8) / layout.ZOOM)
    L.tall = math.floor((DESIGN_HEIGHT - 4) / layout.ZOOM)
    L.inner, L.down = L.column - 12, L.tall - 12
    -- every block of cells is exactly as wide as the tabs, the page line and the search box
    L.cell = layout.across(L.inner, layout.COLUMNS)
    L.tab = layout.across(L.inner, layout.TAB_COLUMNS)
    L.grid_rows = math.max(4, math.floor((L.down - (layout.TAB_ROWS * (L.tab + GAP) + 198) + GAP) / (L.cell + GAP)))
    L.budget = L.down - (3 * L.cell + 340)
    -- How tall a card with so many lines of slots is, of the budget its page has.
    function L.card(lines)
        return math.max(1, math.min(layout.CARD_LINES, lines)) * (L.cell + GAP) + layout.CARD
    end
    -- The creatures of an item, as one card. On its Recipe tab those that give it: up to two lines of them, then the
    -- arrow and the item. On its Uses tab those it is used on: the item and the arrow, then creatures to the card's end.
    -- Gives how many cells are creatures, and how many lines of slots the card is.
    function L.creature_card(count, used)
        local across = layout.COLUMNS
        if used then
            local cells = math.min(count, layout.CARD_LINES * across - 2)
            return cells, math.ceil((cells + 2) / across)
        end
        local cells = math.min(count, (layout.CARD_LINES - 1) * across)
        return cells, math.ceil(cells / across) + 1
    end

    -- What stands in the column, one thing under the other, has this much room: the box's padding is above it, and the
    -- gap under the last thing is the padding below.
    local HIGH = layout.HIGH
    local under = HIGH.under
    L.room = L.tall - layout.PAD
    L.side_row, L.snug = HIGH.tabs, HIGH.snug
    local function block(rows, size, below) return rows * size + (rows - 1) * GAP + below end
    -- The list of items from top to bottom: the two sides, the categories, their line, the bench switch when a bench is
    -- open, the page line, the items, the search box and the keys line, which is `key_lines` lines of small text.
    function L.list_height(switch, key_lines)
        return HIGH.tabs + under + block(layout.TAB_ROWS, L.tab, HIGH.snug) + HIGH.small + under + (switch and HIGH.switch + under or 0)
            + HIGH.row + under + block(L.grid_rows, L.cell, HIGH.snug) + HIGH.input + under + (key_lines or 1) * HIGH.small + under
    end

    -- The Bestiary side has the same bands at the same places: the two sides, its category tiles, the line that says
    -- what is listed (`note_lines` lines of small text), "This map only" while a map is loaded (`map`), the order of
    -- the list, the page line, the creatures, the search box, one line of keys.
    L.beast_cell, L.beast_columns, L.filter, L.filter_rows = layout.across(L.inner, layout.BEAST_COLUMNS), layout.BEAST_COLUMNS, L.tab,
        layout.FILTER_ROWS
    function L.beast_list_height(rows, note_lines, map)
        return HIGH.tabs + under + block(L.filter_rows, L.filter, HIGH.snug) + (note_lines or 1) * HIGH.small + under
            + (map and HIGH.switch + under or 0) + HIGH.order + under
            + HIGH.row + under + block(rows, L.beast_cell, HIGH.snug) + HIGH.input + under + HIGH.small + under
    end
    L.beast_rows = math.max(3, math.floor((L.room - L.beast_list_height(0, 1, true)) / (L.beast_cell + GAP)))

    -- A creature's page. Above what its tab shows: the back row, the picture and name, the word, two lines of facts,
    -- two rows of tabs and a rule. Then, each only when it shows: the 3D view with its line of keys, one or two lines
    -- of variants, the page line. beast_budget is what is left for the tab.
    L.view = { width = L.inner, height = layout.VIEW }
    L.beast_head = HIGH.row + under + L.cell + under + HIGH.line + under + 2 * HIGH.small + under + 2 * (HIGH.tabs + under) + HIGH.rule
    function L.beast_extra(view, variant_lines, pager)
        local lines = math.max(0, math.min(2, variant_lines or 0))
        return (view and L.view.height + under + HIGH.small + under or 0) + (lines > 0 and block(lines, L.cell, under) or 0)
            + (pager and HIGH.row + under or 0)
    end
    function L.beast_budget(view, variant_lines, pager)
        return L.room - L.beast_head - L.beast_extra(view, variant_lines, pager) - HIGH.spare
    end
    -- What creature_page.lua needs to know of how a section is drawn, to work its height out: see page.height there.
    -- `letters` is how many letters a line holds at the least, for cutting a long text into pages.
    L.beast_heights = { line = HIGH.line, small = HIGH.small, space = 0, row = HIGH.row, tabs = HIGH.tabs, slot = L.cell + GAP,
        under = under, tail = under - GAP, letters = 24 }

    -- the game's own box on this screen
    local box_width = math.min(width, height * 16 / 9)
    local hold = { w = box_width, h = box_width * 9 / 16 }
    hold.x, hold.y = (width - hold.w) / 2, (height - hold.h) / 2
    L.hold = hold

    -- the panels are drawn as large as the game's box is beside its own design: on a squarer screen everything is smaller
    local ZOOM = layout.ZOOM * hold.w / DESIGN_WIDTH
    L.zoom = ZOOM
    -- where the column starts at the top: the shelf starts level with it
    L.top = (height - L.tall * ZOOM) / 2
    L.column_left = width - 4 - L.column * ZOOM

    -- The game's box is made smaller until it fits beside the column, and under a full shelf above the hotbar.
    local room = L.column_left - 2 * layout.SIDE
    -- the hotbar stands at the bottom of the screen, as far up as it is in the box (seen at 1024 by 768)
    local hotbar = height - (1 - layout.HOTBAR) * hold.h
    local full_shelf = L.top + (10 + layout.FAVOURITE_ROWS * (layout.SHELF_CELL + 3 + GAP) + layout.PAGE_LINE.above + layout.PAGE_LINE.height) * ZOOM
    local tallest = 0
    for _, span in pairs(layout.SCREENS) do tallest = math.max(tallest, span[2] - span[1]) end
    -- On a screen wider than the box, the background of the game's screens reaches past the box to the screen's edges
    -- (seen in the game at 2560 by 1080 and in a small wide window). So what has to fit is the screen's whole width.
    L.scale = math.max(0.5, math.min(1, room / width, (hotbar - full_shelf - 12) / (tallest * hold.h)))
    -- it sits in the middle of the room between the screen's left edge and the column: the same gap on both sides
    L.menu_x = (L.column_left - width * L.scale) / 2
    L.hotbar = hotbar

    -- the shelf spans the room there is: from two units off the screen's left edge to two units before the column
    L.shelf_x = 2
    L.shelf = math.floor((L.column_left - 4) / ZOOM)
    L.favourite_rows = layout.FAVOURITE_ROWS
    L.favourite_columns = math.max(4, math.floor((L.shelf - 12 + GAP) / (layout.SHELF_CELL + GAP)))
    L.shelf_cell = layout.even(L.shelf, L.favourite_columns)
    -- Where the shelf ends on the screen. lines: rows of it in use (0 for its one line of text, nil for no shelf).
    -- pager: it has more than one page, so the page line stands under its rows.
    function L.shelf_bottom(lines, pager)
        if not lines then return 0 end
        local rows = lines > 0 and lines * (L.shelf_cell + GAP) or 26
        local line = layout.PAGE_LINE
        return L.top + (2 * layout.PAD - 2 + rows + (pager and line.above + line.height or 0)) * ZOOM
    end

    -- The shelf's page line: x and y on the screen, its size in the panel's own units. In the middle of the shelf's
    -- width, a little further under the rows than they are from each other. wide: from ten pages on.
    function L.pager_place(lines, wide)
        local width, text = layout.page_line_width(wide)
        local line = layout.PAGE_LINE
        local rows = math.max(1, lines or 1) * (L.shelf_cell + GAP) - GAP
        return { x = L.shelf_x + (L.shelf - width) / 2 * ZOOM, y = L.top + (layout.PAD + rows + line.above) * ZOOM,
            width = width, height = line.height, text = text, zoom = ZOOM }
    end

    -- A share of the game's box as a place on the screen, before the box is moved up or down. What is made smaller
    -- is the whole screen with the box in the middle of it, towards the screen's bottom left corner: on a screen taller
    -- than the box that is not the box's own bottom (measured at 1024 by 768, where it is 135 units further down).
    local function across(share) return L.menu_x + (hold.x + share * hold.w) * L.scale end
    local function down(share) return height - (height - hold.y - share * hold.h) * L.scale end

    -- How far up a screen of the game goes so that it sits midway between the shelf and the hotbar. One that is not
    -- listed stays where it is. Less than nothing is down.
    function L.lift(name, lines, pager)
        local span = layout.SCREENS[name]
        if not span then return 0 end
        local under_shelf = down(span[1]) - (L.shelf_bottom(lines, pager) + 6)
        local on_hotbar = down(span[2]) - hotbar
        return (under_shelf + on_hotbar) / 2
    end

    -- What ui.FitGame takes: the size, and how far the box moves as shares of itself.
    function L.fit(name, lines, pager)
        -- what is made smaller reaches from the screen's left edge, so that edge stays where it is and the move is the gap
        return L.scale, L.menu_x / hold.w, -L.lift(name, lines, pager) / hold.h
    end

    -- Where a screen of the game ends up, background and all: left, top, right, bottom on the screen.
    function L.rect(name, lines, pager)
        local span = layout.SCREENS[name]
        local up = L.lift(name, lines, pager)
        return L.menu_x, down(span[1]) - up, L.menu_x + width * L.scale, down(span[2]) - up
    end

    -- The place of a bench's own recipe list, where the favourites go while that list is hidden: x and y on the screen,
    -- width and height in the panel's own units.
    function L.bench_list()
        local list = layout.BENCH_LIST
        local up = L.lift("UMG_Processor_C", nil)
        return { x = across(list.left), y = down(list.top) - up,
            width = math.floor((list.right - list.left) * L.scale * hold.w / ZOOM),
            height = math.floor((list.bottom - list.top) * L.scale * hold.h / ZOOM) }
    end

    return L
end

return layout
