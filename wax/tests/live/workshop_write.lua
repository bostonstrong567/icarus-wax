-- Live test of the writing side of game.Workshop. It moves one node of the store by a few units and changes one price by one,
-- looks whether the tables, game.Workshop and the node's widget follow, and puts both back. It buys nothing and spends nothing.
-- For a second or two the game's tables hold the changed place and price. If the player researched that very node in that time
-- they would pay one more: send it while nobody has the store open.
-- It takes three sends, a second apart, because the store's screen is brought up to date when a frame ends:
--   node wax/cli/wax.mjs eval --file wax/tests/live/workshop_write.lua
-- The first writes, the second reads the widget and puts everything back, the third sees the widget back as it was.
-- If it is never sent again, what the first send wrote is put back by itself after 30 seconds.
-- Needs a prospect or the station (a store has to exist), and world.workshop_rows started.
-- Each step is noted in run\session.log before it is made.

local game = Wax.game
local scope = Wax.import("core.scope")
local note = Wax.import("core.blackbox").note
local now = Wax.perf.now
local Workshop = rawget(game, "Workshop")
local NODE, MOVE, COST, OWNER = "Workshop_Envirosuit_1", 5, 1, "WaxWorkshopWriteTest"

local checks = {}
local function check(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail } end
local function attempt(name, fn)
    note("workshop_write: " .. name)
    local ok, a, b = pcall(fn)
    if ok then check(name, a, b) else check(name, false, "raised: " .. tostring(a)) end
end
local function result(pending, say)
    local passed, failed, details = 0, {}, {}
    for _, c in ipairs(checks) do
        if c.ok then passed = passed + 1 else failed[#failed + 1] = c.name .. " :: " .. tostring(c.detail) end
        details[#details + 1] = (c.ok and "ok   " or "FAIL ") .. c.name .. (c.detail and ("  [" .. tostring(c.detail):sub(1, 220) .. "]") or "")
    end
    return { passed = passed, failed = #failed, failures = failed, details = details, pending = pending or nil, say = say }
end
local function stop(why) return { passed = 0, failed = 1, details = {}, failures = { why } } end

local started, rows = pcall(Wax.import, "world.workshop_rows")
if not Workshop or not started or type(rows) ~= "table" or not pcall(function() return Workshop.Node end) then
    return stop("the writing side of game.Workshop has not started: add its line to boot.lua, then send dev_start_core.lua")
end

local function valid(object) return object ~= nil and type(object) == "userdata" and object:IsValid() end

-- The node's widget on the store's screen, found by a walk of its own tree, as the probes of 2026-10-07 did it.
local function find_widget()
    local player = game.LocalPlayer and game.LocalPlayer.Raw
    local state = valid(player) and player.PlayerState or nil
    local component = valid(state) and state.WorkshopTalentController or nil
    local view = valid(component) and component.View or nil
    if not valid(view) then return nil end
    local switcher = view.GraphWidgetSwitcher
    for at = 0, switcher:GetChildrenCount() - 1 do
        local graph = switcher:GetChildAt(at)
        if valid(graph) then
            local list = graph.TalentTreeWidgets
            for position = 1, #list do
                local tree = list[position]
                if valid(tree) then
                    local canvas = tree.Canvas
                    for index = 0, canvas:GetChildrenCount() - 1 do
                        local widget = canvas:GetChildAt(index)
                        if valid(widget) and widget.Talent.RowName:ToString():lower() == NODE:lower() then return widget, at end
                    end
                end
            end
        end
    end
    return nil
end

-- What the widget holds: where its slot is, and the place and the research price it copied from its rows.
local function widget_state()
    local widget, graph = find_widget()
    if not widget then return nil end
    local offsets = widget.Slot.LayoutData.Offsets
    local cached = widget.Talents
    local item = widget["Workshop Item"]
    return { left = offsets.Left, top = offsets.Top, x = cached.position.X, y = cached.position.Y,
        research = #item.ResearchCost > 0 and item.ResearchCost[1].Amount or nil, graph = graph }
end

local function said(state)
    if not state then return "no widget" end
    return ("slot %.0f,%.0f | copied place %.0f,%.0f | copied research %s | graph %s"):format(state.left, state.top, state.x, state.y,
        tostring(state.research), tostring(state.graph))
end

local function mine()
    local count = 0
    for _, change in ipairs(game.Data:Changes()) do
        if change.By == OWNER then count = count + 1 end
    end
    return count
end

local kept = rawget(_G, "WaxWorkshopWriteLive")

-- ---------------------------------------------------------------- the third send: is the widget back

if kept and kept.step == 3 then
    rawset(_G, "WaxWorkshopWriteLive", nil)
    attempt("the widget is back where it was, with the price it had", function()
        local state = widget_state()
        return state ~= nil and state.top == kept.widget.top and state.left == kept.widget.left and state.research == kept.widget.research
            and state.y == kept.widget.y, said(state) .. " | before the test: " .. said(kept.widget)
    end)
    attempt("the tables hold what they held before the test", function()
        local node = Workshop:GetNode(NODE)
        return node.At.X == kept.at.X and node.At.Y == kept.at.Y and node.Research[kept.currency] == kept.amount,
            ("%s,%s and %s %s"):format(tostring(node.At.X), tostring(node.At.Y), kept.currency, tostring(node.Research[kept.currency]))
    end)
    check("nothing of the test is left in game.Data's list of changes", mine() == 0, mine() .. " left")
    local stats = rows.stats()
    check("the screen was brought up to date without a failure", stats.failed == kept.stats.failed and stats.waiting == 0,
        ("failed %d, waiting %d, refreshed %d, missing %d"):format(stats.failed, stats.waiting, stats.refreshed, stats.missing))
    return result()
end

-- ---------------------------------------------------------------- the second send: did the widget follow, then put back

if kept and kept.step == 2 then
    local owner = kept.owner
    attempt("the widget's slot moved by what the place moved", function()
        local state = widget_state()
        return state ~= nil and state.top == kept.widget.top + MOVE and state.left == kept.widget.left, said(state)
    end)
    attempt("the widget copied the new place and the new price from its rows", function()
        local state = widget_state()
        return state ~= nil and state.y == kept.widget.y + MOVE and state.research == kept.widget.research + COST, said(state)
    end)
    attempt("the node was found where its category should be, and counted once", function()
        local stats = rows.stats()
        return stats.refreshed >= kept.stats.refreshed + 1 and stats.missing == kept.stats.missing and stats.failed == kept.stats.failed
            and stats.forced >= kept.stats.forced + 1,
            ("refreshed %d (was %d), forced %d (was %d), missing %d (was %d), failed %d"):format(stats.refreshed, kept.stats.refreshed,
                stats.forced, kept.stats.forced, stats.missing, kept.stats.missing, stats.failed)
    end)
    attempt("Reset takes both changes back, and the tables hold the old values before it returns", function()
        local count = scope.run(owner, function() return Workshop:Reset() end)
        local node = Workshop:GetNode(NODE)
        return count == 2 and node.At.Y == kept.at.Y and node.Research[kept.currency] == kept.amount,
            ("%s taken back | place %s,%s | %s %s"):format(tostring(count), tostring(node.At.X), tostring(node.At.Y), kept.currency,
                tostring(node.Research[kept.currency]))
    end)
    owner:destroy()
    kept.step, kept.owner = 3, nil
    return result(true, "send this file once more in a second: the widget should be back as it was")
end

-- ---------------------------------------------------------------- the first send: write

if not Workshop:IsReady() then return stop("there is no store to ask here: send this in a prospect or on the station") end
if not (rows.WRITES.places and rows.WRITES.prices) then return stop("places or prices are switched off in world.workshop_rows") end
if mine() > 0 then return stop("an earlier run of this test left changes behind: wait 30 seconds and look at game.Data:Changes()") end

local before = Workshop:GetNode(NODE)
if not before or not before.StoreItem then return stop("the store has no node " .. NODE .. " that sells something") end
for _, change in ipairs(game.Data:Changes()) do
    if change.Row:lower() == NODE:lower() or change.Row:lower() == before.StoreItem:lower() then
        return stop(("%s already changes %s.%s, so this test would not see the game's own values"):format(change.By, change.Row, tostring(change.Field)))
    end
end
local currency = before.Research.Credits and "Credits" or nil
if not currency then
    local names = {}
    for name in pairs(before.Research) do names[#names + 1] = name end
    table.sort(names)
    currency = names[1]
end
if not currency then return stop(NODE .. " has no research price to change") end

local widget_before = nil
attempt("the node has a widget on the store's screen", function()
    local took = now()
    widget_before = widget_state()
    return widget_before ~= nil, said(widget_before) .. (" | found in %.2f ms"):format((now() - took) * 1000)
end)
if not widget_before then return result() end

local owner = scope.new(OWNER)
local stats = rows.stats()
local price = {}
for name, amount in pairs(before.Research) do price[name] = amount end
price[currency] = price[currency] + COST

attempt("Set writes the place and the price, and returns nothing to warn about", function()
    local took = now()
    local found = scope.run(owner, function()
        return Workshop:Node(NODE):Set({ at = { before.At.X, before.At.Y + MOVE }, research = price })
    end)
    return type(found) == "table", ("%d warnings | %.2f ms"):format(#found, (now() - took) * 1000)
end)
attempt("game.Workshop reads the new place and price in the same frame", function()
    local node = Workshop:GetNode(NODE)
    return node.At.Y == before.At.Y + MOVE and node.At.X == before.At.X and node.Research[currency] == before.Research[currency] + COST,
        ("%s,%s and %s %s"):format(tostring(node.At.X), tostring(node.At.Y), currency, tostring(node.Research[currency]))
end)
check("both are changes of the test in game.Data's list", mine() == 2, mine() .. " listed")
attempt("the widget has not been touched yet: that happens when the frame ends", function()
    local state = widget_state()
    return state ~= nil and state.top == widget_before.top and state.research == widget_before.research, said(state)
end)

rawset(_G, "WaxWorkshopWriteLive", { step = 2, owner = owner, widget = widget_before, stats = stats, at = { X = before.At.X, Y = before.At.Y },
    currency = currency, amount = before.Research[currency] })

-- should nobody send the file again, the changes go back by themselves
local previous = scope.enter(nil)
Wax.task.delay(30, function()
    local left = rawget(_G, "WaxWorkshopWriteLive")
    if left and left.owner == owner then
        note("workshop_write: nobody came back, putting the node back")
        rawset(_G, "WaxWorkshopWriteLive", nil)
        owner:destroy()
    end
end)
scope.leave(previous)

return result(true, "send this file again in a second: the widget should have followed")
