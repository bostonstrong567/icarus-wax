-- Where everything goes for one screen size: the column, the shelf, and where the game's own screens are moved to.
-- All of it is plain arithmetic, so it is tested without the game for many screen shapes.

local layout = {}

layout.FIT = 0.85               -- the share of its width the game's interface keeps beside the column
layout.ZOOM = 1.25              -- the panels are drawn this much larger than a window
layout.GAP, layout.EDGE = 2, 8
layout.COLUMNS, layout.TAB_COLUMNS, layout.TAB_ROWS = 5, 6, 5
layout.FAVOURITE_ROWS = 2
-- The game lays its interface out in a box 16 wide and 9 high, fitted into the screen and centred. These are shares of
-- that box: where each kind of screen starts and ends, where the hotbar starts, and where a bench has its recipe list.
layout.SCREENS = { UMG_MainMenu = { 0.085, 0.858 }, UMG_Processor_C = { 0.031, 0.865 } }
layout.HOTBAR = 0.885
layout.BENCH_LIST = { left = 0.0070, top = 0.0329, right = 0.2930, bottom = 0.3519 }

-- A row of slots that ends exactly at the edge of what it is in: the side of one slot for that many across.
function layout.even(width, columns)
    return math.floor((width - 12 - (columns - 1) * layout.GAP) / columns * 100) / 100
end

-- width, height: the screen in the units panels are laid out in (ui.ScreenSize).
function layout.compute(width, height)
    width, height = tonumber(width) or 1920, tonumber(height) or 1080
    -- the game reports 1919.99994 for 1920, which must not cost a whole unit when sizes are rounded down
    width, height = math.floor(width * 100 + 0.5) / 100, math.floor(height * 100 + 0.5) / 100
    local ZOOM, GAP, EDGE = layout.ZOOM, layout.GAP, layout.EDGE
    local L = { width = width, height = height, EDGE = EDGE, even = layout.even }

    -- the game's own box on this screen
    local box_width = math.min(width, height * 16 / 9)
    local hold = { w = box_width, h = box_width * 9 / 16 }
    hold.x, hold.y = (width - hold.w) / 2, (height - hold.h) / 2
    L.hold = hold

    -- the column is as wide as on a 16 by 9 screen of this height, however wide the screen is
    L.column = math.floor(((1 - layout.FIT) * hold.w - 8) / ZOOM)
    -- two units free above and below the column
    L.tall = math.floor((height - 4) / ZOOM)
    -- where the column starts at the top: the shelf starts level with it
    L.top = (height - L.tall * ZOOM) / 2
    L.inner, L.down = L.column - 12, L.tall - 12
    L.cell = math.floor((L.inner - (layout.COLUMNS - 1) * GAP) / layout.COLUMNS)
    L.tab = math.floor((L.inner - (layout.TAB_COLUMNS - 1) * GAP) / layout.TAB_COLUMNS)
    L.grid_rows = math.max(4, math.floor((L.down - (layout.TAB_ROWS * (L.tab + GAP) + 198) + GAP) / (L.cell + GAP)))
    L.budget = L.down - (3 * L.cell + 340)
    L.column_left = width - 4 - L.column * ZOOM

    -- The game's box is made smaller until it fits beside the column, and under a full shelf above the hotbar.
    local room = L.column_left - 6 - EDGE
    local hotbar = hold.y + layout.HOTBAR * hold.h
    local full_shelf = L.top + (10 + layout.FAVOURITE_ROWS * (L.cell + 3 + GAP) + 36) * ZOOM
    local tallest = 0
    for _, span in pairs(layout.SCREENS) do tallest = math.max(tallest, span[2] - span[1]) end
    L.scale = math.max(0.5, math.min(1, room / hold.w, (hotbar - full_shelf - 12) / (tallest * hold.h)))
    -- on a screen wider than the box needs, the box sits in the middle of the room it has
    L.menu_x = EDGE + math.max(0, (room - hold.w * L.scale) / 2)
    L.hotbar = hotbar

    -- the shelf reaches two units from the screen's edge and from the column, a little past the game's screen each side
    L.shelf_x = L.menu_x - (EDGE - 2)
    L.shelf = math.floor((L.scale * hold.w + (EDGE - 2) + 4) / ZOOM)
    L.favourite_rows = layout.FAVOURITE_ROWS
    L.favourite_columns = math.max(4, math.floor((L.shelf - 12 + GAP) / (L.cell + GAP)))
    L.shelf_cell = layout.even(L.shelf, L.favourite_columns)

    -- Where the shelf ends on the screen. lines: rows of it in use (0 for its one line of text, nil for no shelf).
    function L.shelf_bottom(lines, pager)
        if not lines then return 0 end
        return L.top + (10 + (lines > 0 and lines * (L.shelf_cell + GAP) or 26) + (pager and 36 or 0)) * ZOOM
    end

    -- A share of the game's box as a place on the screen, before the box is moved up or down.
    local function across(share) return L.menu_x + share * L.scale * hold.w end
    local function down(share) return hold.y + hold.h * (1 - (1 - share) * L.scale) end

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
        return L.scale, (L.menu_x - hold.x) / hold.w, -L.lift(name, lines, pager) / hold.h
    end

    -- Where a screen of the game ends up: left, top, right, bottom on the screen.
    function L.rect(name, lines, pager)
        local span = layout.SCREENS[name]
        local up = L.lift(name, lines, pager)
        return across(0), down(span[1]) - up, across(1), down(span[2]) - up
    end

    -- The place of a bench's own recipe list, where the favourites go while that list is hidden: x and y on the screen,
    -- width and height in the panel's own units.
    function L.bench_list()
        local list = layout.BENCH_LIST
        local up = L.lift("UMG_Processor_C", nil, false)
        return { x = across(list.left), y = down(list.top) - up,
            width = math.floor((list.right - list.left) * L.scale * hold.w / ZOOM),
            height = math.floor((list.bottom - list.top) * L.scale * hold.h / ZOOM) }
    end

    return L
end

return layout
