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
}

t.test("at 16 by 9 it is the layout that was looked at in the game", function()
    for _, size in ipairs({ { 1920, 1080 }, { 2560, 1440 }, { 3840, 2160 } }) do
        local L = layout.compute(units(size[1], size[2]))
        t.eq(L.column, 224)
        t.eq(L.cell, 40)
        t.eq(L.tab, 33)
        t.eq(L.grid_rows, 11)
        t.eq(L.favourite_columns, 30)
        t.ok(math.abs(L.scale - 0.8448) < 0.0005, "the game's screens are at " .. L.scale)
        t.eq(L.menu_x, 8, "the game's screens start at the left gap")
        t.eq(L.hold.x, 0)
        t.eq(L.hold.y, 0)
        local scale, x, y = L.fit("UMG_MainMenu", 2, false)
        t.eq(scale, L.scale)
        t.ok(math.abs(x - 8 / 1920) < 1e-9)
        t.ok(y < 0, "the main menu moves up")
    end
end)

for _, size in ipairs(SCREENS) do
    t.test(size[1] .. ": everything is on the screen and nothing overlaps", function()
        local width, height = units(size[2], size[3])
        local L = layout.compute(width, height)
        t.ok(L.cell >= 26, "a slot is " .. L.cell .. " wide")
        t.ok(L.grid_rows >= 4)
        t.ok(L.scale >= 0.5 and L.scale <= 1, "scale " .. L.scale)
        t.ok(L.column_left > width * 0.6, "the column is not most of the screen")
        t.ok(L.column * layout.ZOOM <= 300, "the column is as wide as on a 16 by 9 screen, " .. L.column * layout.ZOOM)
        -- the shelf: on the screen, left of the column
        t.ok(L.shelf_x >= layout.EDGE - 0.01)
        t.ok(L.shelf_x + L.shelf * layout.ZOOM <= L.column_left - 4, "the shelf ends before the column")
        t.ok(L.favourite_columns * (L.shelf_cell + layout.GAP) - layout.GAP <= L.shelf - 12 + 0.01, "a full row fits the shelf")
        for name in pairs(layout.SCREENS) do
            for lines = 0, layout.FAVOURITE_ROWS do
                for _, pager in ipairs({ false, true }) do
                    local where = ("%s with %d lines%s"):format(name, lines, pager and " and pages" or "")
                    local left, top, right, bottom = L.rect(name, lines, pager)
                    t.ok(left >= layout.EDGE - 0.01, where .. ": starts at " .. left)
                    t.ok(right <= L.column_left - 4, where .. ": ends at " .. right .. ", the column starts at " .. L.column_left)
                    t.ok(top >= L.shelf_bottom(lines, pager) + 2, where .. ": top " .. top .. " under the shelf at " .. L.shelf_bottom(lines, pager))
                    t.ok(bottom <= L.hotbar + 1, where .. ": bottom " .. bottom .. " above the hotbar at " .. L.hotbar)
                    local scale, x, y = L.fit(name, lines, pager)
                    t.ok(math.abs(x) <= 0.5 and math.abs(y) <= 0.5, where .. ": the move is within what ui.FitGame takes")
                    t.eq(scale, L.scale)
                end
            end
        end
        -- a bench with its list replaced: no shelf, and the favourites where the list was
        local left, top, right, bottom = L.rect("UMG_Processor_C", nil, false)
        t.ok(top >= 4 and bottom <= L.hotbar + 1, "a bench without the shelf is on the screen")
        local list = L.bench_list()
        t.ok(list.x >= left - 0.01 and list.x + list.width * layout.ZOOM <= right + 0.01, "the favourites are inside the bench's screen")
        t.ok(list.y >= top - 0.01 and list.y + list.height * layout.ZOOM <= bottom + 0.01)
        t.ok(list.width >= 3 * (L.cell + layout.GAP) + 12, "the favourites have room for three across")
    end)
end

t.test("the size the game reports for 1920 by 1080 gives the same layout as the round numbers", function()
    local near, exact = layout.compute(1919.9999427795, 1079.9999678135), layout.compute(1920, 1080)
    for _, name in ipairs({ "column", "tall", "cell", "tab", "grid_rows", "shelf", "favourite_columns", "scale", "menu_x" }) do
        t.eq(near[name], exact[name], name)
    end
end)

t.test("a screen that is not listed stays where it is", function()
    local L = layout.compute(1920, 1080)
    t.eq(L.lift("UMG_FieldGuide_C", 2, false), 0)
    local _, _, y = L.fit("UMG_FieldGuide_C", 2, false)
    t.eq(y, 0)
end)

t.finish("recipe-layout")
