-- Offline tests for game.Research: the plan for a recipe's node and the buying of it, over a made-up tech tree.
-- The first part gives the plan a world of plain functions. The second runs the same tree through a stand-in engine.
-- Nothing here reaches the game.
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\research_test.lua

local t = dofile("wax/tests/offline/harness.lua")
local fake = dofile("wax/tests/offline/fake_world.lua")
fake.install()

local Wax = t.new_wax()
rawset(_G, "Wax", Wax)
local sched = Wax.import("core.sched")
local guard = Wax.import("core.guard")
local scope = Wax.import("core.scope")
local instance = Wax.import("engine.instance")
local game = Wax.import("engine.game")
instance.start()
Wax.game = game.root
local research = Wax.import("world.research")
research.start()
local Research = game.root.Research

local now = 0
sched.clock = function() return now end

-- ---------------------------------------------------------------- a made-up tech tree and the game's rules for it

-- needs: one of them is enough. flag: "has" or "lacks". refuses: the game answers no when asked to research it.
-- shut: it cannot be researched and no table says why. stuck: the game answers yes and nothing happens.
-- slow: frames the game takes to send it on.
local NODES = {
    Stone_Pickaxe = { default = true, item = "Item_Stone_Pickaxe" },
    Wood_Basic = { shown = "Wood Building" },
    Crafting_Bench = { tree = "T2", item = "Item_Crafting_Bench" },
    Anvil_Bench = { tree = "T2", needs = { "Crafting_Bench" }, item = "Item_Anvil_Bench" },
    Re_route_iron = { tree = "T2", reroute = true, needs = { "Anvil_Bench" } },
    Iron_Pickaxe = { tree = "T2", needs = { "Re_route_iron" }, item = "Item_Iron_Pickaxe" },
    Carpentry_Bench = { tree = "T2", level = 15, needs = { "Crafting_Bench" }, item = "Item_Carpentry_Bench" },
    Bed_Wood = { tree = "T2", needs = { "Carpentry_Bench" }, item = "Item_Bed" },
    Machine_Bench = { tree = "T3", needs = { "CRAFTING_bench" }, item = "Item_Kit_Machining_Bench" },
    Cement_Mixer = { tree = "T3", needs = { "Machine_Bench" }, item = "Item_Cement_Mixer" },
    Shotgun_Casing = { tree = "T3", needs = { "Cement_Mixer" }, item = "Item_Shotgun_Casing" },
    Shotgun = { tree = "T3", level = 25, needs = { "shotgun_casing" }, item = "Item_Shotgun" },
    Ammo_Casing = { tree = "T3", needs = { "Machine_Bench" }, item = "Item_Ammo_Casing" },
    Ammo_ReRoute = { tree = "T3", reroute = true, needs = { "Ammo_Casing", "Shotgun_Casing" } },
    Incendiary_Ammo = { tree = "T3", needs = { "Ammo_ReRoute" }, shown = "Incendiary Rounds" },
    Fabricator = { tree = "T4", needs = { "Machine_Bench" }, item = "Item_Fabricator" },
    Deep_Drill = { tree = "T4", needs = { "Fabricator" } },
    Crude_Oil_Refiner = { tree = "T4", level = 35, needs = { "Deep_Drill" } },
    Natural_Oil_Refiner = { tree = "T4", needs = { "Fabricator" } },
    Polymerizer = { tree = "T4", needs = { "Crude_Oil_Refiner", "Natural_Oil_Refiner" } },
    Rock_Golem_Gun = { tree = "T4", needs = { "Fabricator" }, flag = "lacks", shown = "Rock Golem Gun" },
    Crop_Plot = { tree = "T3", needs = { "Machine_Bench" } },
    Silo = { tree = "T3", needs = { "Silo", "Crop_Plot" } },
    Loop_A = { needs = { "Loop_B" } },
    Loop_B = { needs = { "Loop_A" } },
}
local RECIPES = { Stone_Pickaxe = "Stone_Pickaxe", Wood_Floor = "Wood_Basic", Crafting_Bench = "Crafting_Bench",
    Iron_Pickaxe = "Iron_Pickaxe", Bed_Wood = "Bed_Wood", Shotgun = "Shotgun", Rifle_Round_Incendiary = "Incendiary_Ammo",
    Polymerizer = "Polymerizer", Rock_Golem_Gun = "Rock_Golem_Gun", Silo = "Silo", Loop = "Loop_A", Stick = "None",
    Old_Charm = "Gone_Node" }
local TREES = { T2 = "Tier_Two", T3 = "Tier_Three", T4 = "Tier_Four" }
local TIERS = { Tier_Two = 10, Tier_Three = 20, Tier_Four = 30 }
local ITEMS = { Item_Stone_Pickaxe = "Stone Pickaxe", Item_Crafting_Bench = "Crafting Bench", Item_Anvil_Bench = "Anvil Bench",
    Item_Iron_Pickaxe = "Iron Pickaxe", Item_Carpentry_Bench = "Carpentry Bench", Item_Bed = "Bed",
    Item_Kit_Machining_Bench = "Machining Bench", Item_Cement_Mixer = " Cement Mixer ", Item_Shotgun_Casing = "Shotgun Shell Casing",
    Item_Shotgun = "Shotgun", Item_Ammo_Casing = "Ammo Casing", Item_Fabricator = "Fabricator" }

-- options: level, points, have (nodes researched already), change (fields to put on nodes), nodes (more nodes), recipes
local function new_game(options)
    options = options or {}
    local g = { level = options.level or 60, points = options.points or 60, spent = 0, nodes = {}, recipes = {}, bought = {},
        frames = 0, pending = nil, forced = 0 }
    local function add(name, node)
        local copy = { row = name }
        for key, value in pairs(node) do copy[key] = value end
        g.nodes[name:lower()] = copy
    end
    for name, node in pairs(NODES) do add(name, node) end
    for name, node in pairs(options.nodes or {}) do add(name, node) end
    for name, node in pairs(RECIPES) do g.recipes[name] = node end
    for name, node in pairs(options.recipes or {}) do g.recipes[name] = node end
    for _, name in ipairs(options.have or {}) do g.nodes[name:lower()].unlocked = true end
    for name, fields in pairs(options.change or {}) do
        for key, value in pairs(fields) do g.nodes[name:lower()][key] = value end
    end

    function g.level_of(key)
        local node = g.nodes[key]
        return math.max(node.level or 0, TIERS[TREES[node.tree] or ""] or 0)
    end
    function g.researched(key)
        local node = g.nodes[key]
        return node ~= nil and (node.unlocked == true or node.default == true or node.reroute == true)
    end
    -- whether a node counts as researched for what needs it: a reroute counts as what is behind it
    function g.counts(key, seen)
        local node = g.nodes[key]
        if not node or seen[key] then return false end
        if not node.reroute then return node.unlocked == true or node.default == true end
        seen[key] = true
        if #(node.needs or {}) == 0 then return true end
        for _, parent in ipairs(node.needs) do
            if g.counts(parent:lower(), seen) then return true end
        end
        return false
    end
    function g.can(key)
        local node = g.nodes[key]
        if not node or g.researched(key) or node.flag == "lacks" or node.shut then return false end
        if g.level < g.level_of(key) or g.points < 1 then return false end
        if #(node.needs or {}) == 0 then return true end
        for _, parent in ipairs(node.needs) do
            if g.counts(parent:lower(), { [key] = true }) then return true end
        end
        return false
    end
    function g.buy(key)
        g.bought[#g.bought + 1] = key
        local node = g.nodes[key]
        if node.refuses or not g.can(key) then return false end
        if node.stuck then return true end
        g.points, g.spent = g.points - 1, g.spent + 1
        if node.slow then
            g.pending = { key = key, at = g.frames + node.slow }
        else
            node.unlocked = true
        end
        for _, also in ipairs(node.brings or {}) do g.nodes[also:lower()].unlocked = true end
        return true
    end
    function g.frame()
        g.frames = g.frames + 1
        if g.pending and g.frames >= g.pending.at then
            g.nodes[g.pending.key].unlocked = true
            g.pending = nil
        end
    end
    return g
end

-- ---------------------------------------------------------------- the plan, over a world of plain functions

local function stand_in(g)
    local world = { asked = {}, parents_asked = 0 }
    function world.node_of(recipe)
        for name, node in pairs(g.recipes) do
            if name:lower() == recipe:lower() then return g.nodes[node:lower()] and node:lower() or nil end
        end
        return nil
    end
    function world.parents(key)
        world.parents_asked = world.parents_asked + 1
        local out = {}
        for _, parent in ipairs(g.nodes[key].needs or {}) do
            if g.nodes[parent:lower()] then out[#out + 1] = parent:lower() end
        end
        return out
    end
    function world.is_reroute(key) return g.nodes[key].reroute == true end
    function world.is_default(key) return g.nodes[key].default == true end
    function world.flagged(key) return g.nodes[key].flag ~= nil end
    function world.level_of(key) return g.level_of(key) end
    function world.name_of(key)
        local node = g.nodes[key]
        local name = node.shown or ITEMS[node.item or ""] or node.row:gsub("_", " ")
        return (name:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    function world.unlocked(key)
        world.asked[key] = (world.asked[key] or 0) + 1
        return g.researched(key)
    end
    function world.can_unlock(key) return g.can(key) end
    function world.points() return g.points, g.points + g.spent, g.spent end
    function world.player_level() return g.level end
    function world.buy(key) return g.buy(key) end
    function world.syncing() return g.pending ~= nil end
    function world.wait() g.frame() end
    return world
end

local function plan_for(recipe, options)
    local g = new_game(options)
    local world = stand_in(g)
    return research.plan(world, recipe), g, world
end

local function steps_of(plan)
    local out = {}
    for at, step in ipairs(plan.steps) do out[at] = step.node end
    return table.concat(out, " ")
end

t.test("a recipe that needs no node, one the game does not have and one whose node is gone have no plan", function()
    t.eq(plan_for("Stick"), nil)
    t.eq(plan_for("No_Such_Recipe"), nil)
    t.eq(plan_for("Old_Charm"), nil)
end)

t.test("a node every character starts with is researched, and says it was never bought", function()
    local plan = plan_for("Stone_Pickaxe", { level = 3, points = 11 })
    t.eq(plan.unlocked, true)
    t.eq(plan.default, true)
    t.eq(#plan.steps, 0)
    t.eq(plan.points, 0)
    t.eq(plan.can, false)
    t.eq(plan.blocked, false)
    t.eq(plan.name, "Stone Pickaxe")
end)

t.test("a node that is researched already", function()
    local plan = plan_for("Wood_Floor", { have = { "Wood_Basic" } })
    t.eq(plan.unlocked, true)
    t.eq(plan.default, false)
    t.eq(plan.points, 0)
    t.eq(plan.needed_level, 0)
    t.eq(plan.can, false)
end)

t.test("one step: the node itself, for one point", function()
    local plan = plan_for("Wood_Floor", { level = 3, points = 11 })
    t.eq(plan.node, "wood_basic", "the recipe and its node have different names")
    t.eq(plan.name, "Wood Building")
    t.eq(plan.unlocked, false)
    t.eq(steps_of(plan), "wood_basic")
    t.eq(plan.points, 1)
    t.eq(plan.available, 11)
    t.eq(plan.player_level, 3)
    t.eq(plan.level, 0)
    t.eq(plan.needed_level, 0)
    t.eq(plan.can, true)
    t.eq(plan.blocked, false)
end)

t.test("a chain is listed from the far end, the node itself last, with the name and level of each step", function()
    local plan = plan_for("Shotgun", { level = 25, points = 11, have = { "Crafting_Bench" } })
    t.eq(steps_of(plan), "machine_bench cement_mixer shotgun_casing shotgun")
    t.eq(plan.points, 4)
    t.eq(plan.level, 25)
    t.eq(plan.needed_level, 25)
    t.eq(plan.steps[1].name, "Machining Bench")
    t.eq(plan.steps[1].level, 20, "the level of its tier")
    t.eq(plan.steps[2].name, "Cement Mixer")
    t.eq(plan.steps[4].level, 25, "the larger of the node's level and its tier's")
    t.eq(plan.can, true)
    -- with nothing researched the bench before those comes first
    t.eq(steps_of(plan_for("Shotgun", { level = 25 })), "crafting_bench machine_bench cement_mixer shotgun_casing shotgun")
end)

t.test("a reroute is walked through and never bought, though the game calls it researched", function()
    local plan, _, world = plan_for("Iron_Pickaxe", { have = { "Crafting_Bench" } })
    t.eq(steps_of(plan), "anvil_bench iron_pickaxe")
    t.eq(world.asked.re_route_iron, nil, "a reroute's own state is not asked for")
    t.eq(steps_of(plan_for("Iron_Pickaxe", { have = { "Crafting_Bench", "Anvil_Bench" } })), "iron_pickaxe")
    -- a reroute with two nodes behind it needs one of them
    t.eq(steps_of(plan_for("Rifle_Round_Incendiary", { have = { "Crafting_Bench", "Machine_Bench" } })), "ammo_casing incendiary_ammo")
    t.eq(steps_of(plan_for("Rifle_Round_Incendiary", { have = { "Shotgun_Casing" } })), "incendiary_ammo")
    t.eq(plan_for("rifle_round_incendiary").name, "Incendiary Rounds")
end)

t.test("of two parents one is enough, and the cheaper way is taken", function()
    local have = { "Crafting_Bench", "Machine_Bench", "Fabricator" }
    t.eq(steps_of(plan_for("Polymerizer", { have = have })), "natural_oil_refiner polymerizer")
    -- the other way round in the table gives the same
    local turned = { Polymerizer = { needs = { "Natural_Oil_Refiner", "Crude_Oil_Refiner" } } }
    t.eq(steps_of(plan_for("Polymerizer", { have = have, change = turned })), "natural_oil_refiner polymerizer")
    -- one parent researched: nothing else is bought
    t.eq(steps_of(plan_for("Polymerizer", { have = { "Crude_Oil_Refiner" } })), "polymerizer")
    -- two ways as long: the one that asks the lower level
    local even = { "Crafting_Bench", "Machine_Bench", "Fabricator", "Deep_Drill" }
    local plan = plan_for("Polymerizer", { have = even })
    t.eq(steps_of(plan), "natural_oil_refiner polymerizer")
    t.eq(plan.needed_level, 30)
end)

t.test("each node is asked about itself: a researched one is not doubted because its parent is not", function()
    local plan, _, world = plan_for("Shotgun", { level = 25, have = { "Shotgun_Casing" } })
    t.eq(steps_of(plan), "shotgun")
    t.eq(plan.can, true)
    t.ok(world.asked.shotgun_casing, "the parent was asked about")
    t.eq(world.asked.cement_mixer, nil, "what is behind a researched node is not looked at")
end)

t.test("level too low: the highest level any step asks, also when a parent asks more than the node", function()
    local have = { "Crafting_Bench", "Machine_Bench", "Cement_Mixer", "Shotgun_Casing" }
    local plan = plan_for("Shotgun", { level = 20, points = 11, have = have })
    t.eq(plan.needed_level, 25)
    t.eq(plan.player_level, 20)
    t.eq(plan.can, false)
    t.eq(plan.blocked, false)
    local bed = plan_for("Bed_Wood", { level = 12, have = { "Crafting_Bench" } })
    t.eq(steps_of(bed), "carpentry_bench bed_wood")
    t.eq(bed.level, 10)
    t.eq(bed.needed_level, 15)
    t.eq(bed.can, false)
    t.eq(plan_for("Bed_Wood", { level = 15, have = { "Crafting_Bench" } }).can, true)
end)

t.test("too few points", function()
    local plan = plan_for("Shotgun", { level = 30, points = 3, have = { "Crafting_Bench" } })
    t.eq(plan.points, 4)
    t.eq(plan.available, 3)
    t.eq(plan.can, false)
    t.eq(plan.blocked, false)
    t.eq(plan_for("Shotgun", { level = 30, points = 4, have = { "Crafting_Bench" } }).can, true)
end)

t.test("blocked: level and points are enough and the game still says no", function()
    local have = { "Crafting_Bench", "Machine_Bench", "Fabricator" }
    local plan = plan_for("Rock_Golem_Gun", { have = have })
    t.eq(steps_of(plan), "rock_golem_gun")
    t.eq(plan.can, false)
    t.eq(plan.blocked, true)
    local with_flag = plan_for("Rock_Golem_Gun", { have = have, change = { Rock_Golem_Gun = { flag = "has" } } })
    t.eq(with_flag.can, true)
    t.eq(with_flag.blocked, false)
    -- not blocked while the level is the reason
    t.eq(plan_for("Rock_Golem_Gun", { have = have, level = 10 }).blocked, false)
end)

t.test("a later step that needs a flag cannot be asked about ahead, so nothing is started", function()
    local options = { have = { "Crafting_Bench", "Machine_Bench" }, change = { Rock_Golem_Gun = { flag = "has" } } }
    local plan, g, world = plan_for("Rock_Golem_Gun", options)
    t.eq(steps_of(plan), "fabricator rock_golem_gun")
    t.eq(plan.can, false)
    t.eq(plan.blocked, true)
    local ok, bought = research.unlock(world, "Rock_Golem_Gun")
    t.eq(ok, false)
    t.eq(bought, 0)
    t.eq(#g.bought, 0, "no point was spent on the way to a node that may be refused")
end)

t.test("names in another letter case", function()
    local options = { level = 25, have = { "Crafting_Bench" } }
    local plan = plan_for("SHOTGUN", options)
    t.eq(steps_of(plan), "machine_bench cement_mixer shotgun_casing shotgun", "the handles are spelled another way than the rows")
    t.eq(steps_of(plan_for("shotgun", options)), steps_of(plan))
    t.eq(plan.node, "shotgun")
end)

t.test("nodes that need each other do not go round for ever", function()
    local plan = plan_for("Loop")
    t.eq(steps_of(plan), "loop_a")
    t.eq(plan.can, false, "the game is asked, and says no")
    t.eq(plan.blocked, true)
    -- a node that names itself beside a real parent: the real one is the way
    local silo = plan_for("Silo", { have = { "Crafting_Bench", "Machine_Bench" } })
    t.eq(steps_of(silo), "crop_plot silo")
    t.eq(silo.can, true)
end)

t.test("a tree where every node has two parents is still walked once a node", function()
    local nodes, recipes = {}, { Top = "L30_A" }
    for layer = 1, 30 do
        local needs = layer > 1 and { "L" .. (layer - 1) .. "_A", "L" .. (layer - 1) .. "_B" } or nil
        nodes["L" .. layer .. "_A"], nodes["L" .. layer .. "_B"] = { needs = needs }, { needs = needs }
    end
    local plan, _, world = plan_for("Top", { nodes = nodes, recipes = recipes })
    t.eq(#plan.steps, 30)
    t.eq(plan.steps[30].node, "l30_a")
    t.ok(world.parents_asked <= 60, "parents were read " .. world.parents_asked .. " times")
end)

t.test("a plan holds plain values and nothing else", function()
    local plan = plan_for("Shotgun", { level = 25, have = { "Crafting_Bench" } })
    local function walk(value, where)
        local kind = type(value)
        t.ok(kind == "table" or kind == "string" or kind == "number" or kind == "boolean", where .. " is a " .. kind)
        if kind ~= "table" then return end
        t.eq(getmetatable(value), nil, where .. " has no metatable")
        for key, inner in pairs(value) do walk(inner, where .. "." .. tostring(key)) end
    end
    walk(plan, "plan")
    for _, field in ipairs({ "node", "name", "unlocked", "default", "level", "steps", "points", "available", "player_level",
        "needed_level", "can", "blocked" }) do
        t.ok(plan[field] ~= nil, "the plan has " .. field)
    end
end)

-- ---------------------------------------------------------------- buying, over the same world

local function unlock(recipe, options)
    local g = new_game(options)
    local world = stand_in(g)
    local ok, bought, failed = research.unlock(world, recipe)
    return ok, bought, failed, g
end

t.test("unlock buys the steps in order, a few frames apart, and says how many", function()
    local ok, bought, failed, g = unlock("Shotgun", { level = 25, points = 11, have = { "Crafting_Bench" } })
    t.eq(ok, true)
    t.eq(bought, 4)
    t.eq(failed, nil)
    t.eq(table.concat(g.bought, " "), "machine_bench cement_mixer shotgun_casing shotgun")
    t.eq(g.points, 7)
    t.eq(g.frames, 4 * research.MIN_FRAMES)
    t.eq(g.researched("shotgun"), true)
end)

t.test("unlock buys nothing unless the plan says it can", function()
    for what, options in pairs({
        ["level too low"] = { level = 20, have = { "Crafting_Bench" } },
        ["too few points"] = { level = 25, points = 3, have = { "Crafting_Bench" } },
    }) do
        local ok, bought, failed, g = unlock("Shotgun", options)
        t.eq(ok, false, what)
        t.eq(bought, 0, what)
        t.eq(failed, nil, what)
        t.eq(#g.bought, 0, what)
    end
    local ok, bought, _, g = unlock("Rock_Golem_Gun", { have = { "Fabricator" } })
    t.eq(ok, false, "blocked")
    t.eq(bought + #g.bought, 0)
    ok, bought, _, g = unlock("Stick")
    t.eq(ok, false, "no node")
    t.eq(bought + #g.bought, 0)
    -- researched already: true, and nothing is bought
    ok, bought, _, g = unlock("Wood_Floor", { have = { "Wood_Basic" } })
    t.eq(ok, true)
    t.eq(bought + #g.bought, 0)
end)

t.test("a step the game refuses ends it, and the rest is not tried", function()
    local options = { level = 25, points = 11, have = { "Crafting_Bench" }, change = { Cement_Mixer = { refuses = true } } }
    local ok, bought, failed, g = unlock("Shotgun", options)
    t.eq(ok, false)
    t.eq(bought, 1)
    t.eq(failed, "Cement Mixer")
    t.eq(table.concat(g.bought, " "), "machine_bench cement_mixer", "nothing after the refused step was asked for")
    t.eq(g.points, 10)
end)

t.test("a step that does not open after the one before is waited for a while, then given up without asking for it", function()
    local options = { level = 25, points = 11, have = { "Crafting_Bench" }, change = { Cement_Mixer = { shut = true } } }
    local ok, bought, failed, g = unlock("Shotgun", options)
    t.eq(ok, false)
    t.eq(bought, 1)
    t.eq(failed, "Cement Mixer")
    t.eq(table.concat(g.bought, " "), "machine_bench")
    t.ok(g.frames >= research.GRACE_FRAMES, "it was given " .. g.frames .. " frames")
    t.ok(g.frames < research.MAX_FRAMES)
end)

t.test("a node the game says yes to but that never shows as researched counts as refused", function()
    local options = { level = 25, points = 11, have = { "Crafting_Bench" }, change = { Machine_Bench = { stuck = true } } }
    local ok, bought, failed, g = unlock("Shotgun", options)
    t.eq(ok, false)
    t.eq(bought, 0)
    t.eq(failed, "Machining Bench")
    t.eq(table.concat(g.bought, " "), "machine_bench")
    t.ok(g.frames >= research.GRACE_FRAMES and g.frames < research.MAX_FRAMES)
end)

t.test("while the game is still sending a node on, the next one waits", function()
    local options = { level = 25, points = 11, have = { "Crafting_Bench" }, change = { Machine_Bench = { slow = 80 } } }
    local ok, bought, _, g = unlock("Shotgun", options)
    t.eq(ok, true)
    t.eq(bought, 4)
    t.ok(g.frames >= 80 + 3 * research.MIN_FRAMES, "it took " .. g.frames .. " frames")
    -- a node that takes longer than anything should is given up
    local never = { level = 25, points = 11, have = { "Crafting_Bench" }, change = { Machine_Bench = { slow = 100000 } } }
    local stopped, count, failed, held = unlock("Shotgun", never)
    t.eq(stopped, false)
    t.eq(count, 0)
    t.eq(failed, "Machining Bench")
    t.eq(held.frames, research.MAX_FRAMES)
    t.eq(#held.bought, 1)
end)

t.test("a step that turned out researched by the time it is reached is not bought again", function()
    local options = { level = 25, points = 11, have = { "Crafting_Bench" }, change = { Machine_Bench = { brings = { "Cement_Mixer" } } } }
    local ok, bought, _, g = unlock("Shotgun", options)
    t.eq(ok, true)
    t.eq(bought, 3)
    t.eq(table.concat(g.bought, " "), "machine_bench shotgun_casing shotgun")
end)

-- ---------------------------------------------------------------- the same tree through a stand-in engine

local current = nil     -- the game the stand-in engine answers from
local calls = { find = {}, unlock = {} }
local controller_class = fake.class("/Script/Icarus.IcarusPlayerController", fake.class("/Script/CoreUObject.Object"))

local function key_of(handle) return handle.RowName:ToString():lower() end

local function handles(names)
    local out = {}
    for at, name in ipairs(names or {}) do out[at] = fake.handle(name) end
    return fake.array(out)
end

-- Puts a game's tables and its player where the engine half looks for them.
local function install(g, options)
    options = options or {}
    current = g
    calls.find, calls.unlock = {}, {}
    local recipes, order = {}, {}
    for name, node in pairs(g.recipes) do
        recipes[name] = { Requirement = fake.handle(node) }
        order[#order + 1] = name
    end
    local recipe_table = fake.table("/Engine/Transient.D_ProcessorRecipes", recipes, order)
    local find = recipe_table.FindRow
    function recipe_table:FindRow(name)
        calls.find[#calls.find + 1] = name
        return find(self, name)
    end
    local talents, names = {}, {}
    for _, node in pairs(g.nodes) do
        talents[node.row] = { DisplayName = fake.name(node.shown or ""), ExtraData = fake.handle(node.item or "None"),
            TalentTree = fake.handle(node.tree or "None"), RequiredLevel = node.level or 0, TalentType = node.reroute and 1 or 0,
            bDefaultUnlocked = node.default == true, RequiredTalents = handles(node.needs),
            RequiredFlags = handles(node.flag and { "Some_Flag" } or nil) }
        names[#names + 1] = node.row
    end
    fake.table("/Engine/Transient.D_Talents", talents, names)
    local trees, tiers, items = {}, {}, {}
    for name, tier in pairs(TREES) do trees[name] = { Archetype = fake.handle(tier) } end
    for name, level in pairs(TIERS) do tiers[name] = { RequiredLevel = level } end
    for name, shown in pairs(ITEMS) do items[name] = { DisplayName = fake.name(shown) } end
    fake.table("/Engine/Transient.D_TalentTrees", trees, {})
    fake.table("/Engine/Transient.D_TalentArchetypes", tiers, {})
    fake.table("/Engine/Transient.D_Itemable", items, {})

    local model = fake.object("BlueprintTalentModel", {
        GetLevel = function() return g.level end,
        GetTotalPoints = function() return g.points + g.spent end,
        GetSpentPoints = function() return g.spent end,
        GetAvailablePoints = function() return g.points end,
        DoesModelContainTalent = function(_, handle) return g.nodes[key_of(handle)] ~= nil and not g.nodes[key_of(handle)].elsewhere end,
        IsTalentUnlocked = function(_, handle) return g.researched(key_of(handle)) end,
        GetTalentRank = function(_, handle) return g.researched(key_of(handle)) and 1 or 0 end,
        CanUnlockTalent = function(_, handle, rank, ignore)
            assert(ignore == false, "the last argument stays false")
            assert(rank == 1, "the rank asked for is the one after the current")
            return g.can(key_of(handle))
        end,
    })
    local unlocker = fake.object("BlueprintTalentController", {
        Model = model,
        IsInteractionEnabled = function() return g.closed ~= true end,
        UnlockNextTalentRank = function(_, handle, force)
            calls.unlock[#calls.unlock + 1] = { node = key_of(handle), force = force }
            if force ~= false then g.forced = g.forced + 1 end
            return g.buy(key_of(handle))
        end,
    })
    fake.possess(nil)
    rawset(fake.controller, "__class", controller_class)
    fake.controller.IsSyncingUpdateCharacterTalents = function() return g.pending ~= nil end
    fake.controller.PlayerState = options.no_tree and fake.INVALID or fake.object("BP_IcarusPlayerState_C", { BlueprintTalentController = unlocker })
    research.flush()
    return g
end

local function frames(count)
    for _ = 1, count do
        now = now + 1 / 60
        if current then current.frame() end
        sched.step()
    end
end

-- Runs fn in a task and gives what it returned once it has ended.
local function in_task(fn)
    local got = nil
    sched.task.spawn(function() got = table.pack(fn()) end)
    for _ = 1, 2000 do
        if got then break end
        frames(1)
    end
    assert(got, "the task did not end")
    return table.unpack(got, 1, got.n)
end

local function errors() return #guard.errors() end

t.test("engine: with no player, and with a player who has no tech tree, nothing is ready and no plan is given", function()
    t.eq(Research:IsReady(), false)
    t.eq(Research:GetLevel(), nil)
    t.eq(Research:GetPoints(), nil)
    t.eq(Research:GetPlan("Shotgun"), nil)
    install(new_game(), { no_tree = true })
    t.eq(Research:IsReady(), false)
    t.eq(Research:GetPlan("Shotgun"), nil)
    t.eq(in_task(function() return Research:Unlock("Shotgun") end), false)
    t.eq(errors(), 0)
end)

t.test("engine: level and points are the tech tree's own", function()
    install(new_game({ level = 3, points = 11 }))
    t.eq(Research:IsReady(), true)
    t.eq(Research:GetLevel(), 3)
    local available, total, spent = Research:GetPoints()
    t.eq(available, 11)
    t.eq(total, 11)
    t.eq(spent, 0)
end)

t.test("engine: a plan has the game's names and levels, and holds nothing of the engine's", function()
    install(new_game({ level = 25, points = 11, have = { "Crafting_Bench" } }))
    local plan = Research:GetPlan("Shotgun")
    t.eq(steps_of(plan), "machine_bench cement_mixer shotgun_casing shotgun")
    t.eq(plan.name, "Shotgun")
    t.eq(plan.level, 25)
    t.eq(plan.steps[1].name, "Machining Bench", "the name of the item the node stands for")
    t.eq(plan.steps[1].level, 20, "the level of the node's tier")
    t.eq(plan.steps[2].name, "Cement Mixer", "spaces round a name are cut off")
    t.eq(plan.points, 4)
    t.eq(plan.available, 11)
    t.eq(plan.player_level, 25)
    t.eq(plan.can, true)
    local function walk(value, where)
        local kind = type(value)
        t.ok(kind == "string" or kind == "number" or kind == "boolean" or (kind == "table" and getmetatable(value) == nil),
            where .. " is not a plain value")
        if kind == "table" then
            for key, inner in pairs(value) do walk(inner, where .. "." .. tostring(key)) end
        end
    end
    walk(plan, "plan")
    t.eq(Research:GetPlan("Wood_Floor").name, "Wood Building", "a node with a name of its own")
    t.eq(Research:GetPlan("Loop").name, "Loop A", "a node with no name anywhere is called by its row")
    t.eq(Research:GetPlan("Stone_Pickaxe").default, true)
    t.eq(Research:GetPlan("Stick"), nil)
    t.eq(Research:GetPlan("Old_Charm"), nil, "a recipe that names a node the game does not have")
    t.eq(errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
end)

t.test("engine: the same answers as the plain world for every recipe, in any letter case", function()
    for _, options in ipairs({ {}, { level = 3, points = 11 }, { level = 25, points = 2, have = { "Crafting_Bench", "Machine_Bench" } },
        { have = { "Crafting_Bench", "Machine_Bench", "Fabricator", "Shotgun_Casing" } } }) do
        local g = install(new_game(options))
        local world = stand_in(g)
        for name in pairs(g.recipes) do
            local plain, live = research.plan(world, name), Research:GetPlan(name:upper())
            t.eq(live == nil, plain == nil, name)
            if plain then
                t.eq(steps_of(live), steps_of(plain), name)
                for _, field in ipairs({ "node", "name", "unlocked", "default", "level", "points", "needed_level", "can", "blocked" }) do
                    t.eq(live[field], plain[field], name .. "." .. field)
                end
            end
        end
    end
    t.eq(errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
end)

t.test("engine: a recipe name the game did not list is never given to the engine", function()
    install(new_game())
    t.eq(Research:GetPlan("No_Such_Recipe"), nil)
    t.eq(#calls.find, 0)
    t.ok(Research:GetPlan("shotgun"))
    for _, name in ipairs(calls.find) do t.eq(name, "Shotgun", "asked for by the name the game listed") end
end)

t.test("engine: a node the player's tree does not hold counts as not researched and not open", function()
    install(new_game({ change = { Wood_Basic = { elsewhere = true } } }))
    local plan = Research:GetPlan("Wood_Floor")
    t.eq(plan.unlocked, false)
    t.eq(plan.can, false)
    t.eq(plan.blocked, true)
end)

t.test("engine: Unlock is for a task, and takes a recipe's name", function()
    install(new_game())
    t.raises(function() Research:Unlock("Shotgun") end, "inside a task")
    t.raises(function() Research:Unlock(nil) end, "expects a recipe's row name")
    t.raises(function() Research:GetPlan(12) end, "expects a recipe's row name")
    t.eq(#calls.unlock, 0)
end)

t.test("engine: Unlock asks the game for each step in order and never forces one", function()
    local g = install(new_game({ level = 25, points = 11, have = { "Crafting_Bench" } }))
    local ok, bought, failed = in_task(function() return Research:Unlock("Shotgun") end)
    t.eq(ok, true)
    t.eq(bought, 4)
    t.eq(failed, nil)
    local asked = {}
    for at, call in ipairs(calls.unlock) do
        asked[at] = call.node
        t.eq(call.force, false, "the second argument of step " .. at)
    end
    t.eq(table.concat(asked, " "), "machine_bench cement_mixer shotgun_casing shotgun")
    t.eq(g.forced, 0)
    t.eq(g.points, 7)
    t.eq(Research:GetPlan("Shotgun").unlocked, true)
    t.eq(errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
end)

t.test("engine: a refused step ends it with the name of that node", function()
    local options = { level = 25, points = 11, have = { "Crafting_Bench" }, change = { Cement_Mixer = { refuses = true } } }
    local g = install(new_game(options))
    local ok, bought, failed = in_task(function() return Research:Unlock("Shotgun") end)
    t.eq(ok, false)
    t.eq(bought, 1)
    t.eq(failed, "Cement Mixer")
    t.eq(#calls.unlock, 2)
    t.eq(g.forced, 0)
end)

t.test("engine: while the tree takes no input nothing is asked of it", function()
    local g = install(new_game({ level = 25, points = 11, have = { "Crafting_Bench" } }))
    g.closed = true
    local ok, bought, failed = in_task(function() return Research:Unlock("Shotgun") end)
    t.eq(ok, false)
    t.eq(bought, 0)
    t.eq(failed, "Machining Bench")
    t.eq(#calls.unlock, 0)
end)

t.test("engine: a second Unlock while one runs buys nothing", function()
    local options = { level = 25, points = 11, have = { "Crafting_Bench" }, change = { Machine_Bench = { slow = 20 } } }
    local g = install(new_game(options))
    local first, second = nil, nil
    sched.task.spawn(function() first = table.pack(Research:Unlock("Shotgun")) end)
    frames(2)
    sched.task.spawn(function() second = table.pack(Research:Unlock("Iron_Pickaxe")) end)
    t.eq(second[1], false)
    t.eq(second[2], 0)
    for _ = 1, 500 do
        if first then break end
        frames(1)
    end
    t.eq(first[1], true)
    t.eq(first[2], 4)
    t.eq(g.researched("anvil_bench"), false)
    -- and a task that was stopped part way does not leave it shut
    local stopped = sched.task.spawn(function() Research:Unlock("Iron_Pickaxe") end)
    sched.task.cancel(stopped)
    t.eq(in_task(function() return Research:Unlock("Iron_Pickaxe") end), true)
end)

t.test("engine: Changed fires when the level or the points changed, looked at every 30 frames and only while someone listens", function()
    local g = install(new_game({ level = 3, points = 11 }))
    t.eq(sched.Frame.count, 0, "nothing runs each frame before anyone listens")
    local heard = {}
    local owner = scope.new("listener")
    scope.run(owner, function()
        Research.Changed:Connect(function(level, points) heard[#heard + 1] = tostring(level) .. "/" .. tostring(points) end)
    end)
    t.eq(sched.Frame.count, 1)
    frames(90)
    t.eq(#heard, 0, "nothing changed")
    g.points = 10
    fake.watch = {}
    frames(research.POLL_FRAMES)
    t.eq(table.concat(heard, " "), "3/10")
    t.ok((fake.watch.PlayerState or 0) <= 2, "the tree was looked at once in those frames")
    fake.watch = nil
    g.level, g.points = 4, 12
    frames(research.POLL_FRAMES)
    t.eq(table.concat(heard, " "), "3/10 4/12")
    frames(research.POLL_FRAMES * 3)
    t.eq(#heard, 2)
    -- leaving the prospect is a change too
    fake.controller.PlayerState = fake.INVALID
    frames(research.POLL_FRAMES)
    t.eq(heard[3], "nil/nil")
    -- the listener's mod is gone: the look each frame stops with it
    owner:destroy()
    frames(2)
    t.eq(sched.Frame.count, 0)
    t.eq(Research.Changed.count, 0)
    t.raises(function() Research.Changed:Connect("no") end, "expects a function")
    t.eq(errors(), 0, guard.errors()[1] and guard.errors()[1].trace or "")
end)

t.test("engine: what was read of the tables is dropped when the map changes", function()
    install(new_game({ level = 25, have = { "Crafting_Bench" } }))
    t.eq(Research:GetPlan("Shotgun").points, 4)
    local shorter = new_game({ level = 25, have = { "Crafting_Bench" }, change = { Shotgun = { needs = { "Crafting_Bench" } } } })
    install(shorter)
    t.eq(Research:GetPlan("Shotgun").points, 1)
    -- the game's table says something else now: what was read stays until the map changes
    local talents = StaticFindObject("/Engine/Transient.D_Talents")
    talents:FindRow("Shotgun").RequiredLevel = 40
    t.eq(Research:GetPlan("Shotgun").level, 25)
    game.root.MapChanged:Fire("Next")
    t.eq(Research:GetPlan("Shotgun").level, 40)
end)

t.test("engine: a call the game does not answer gives nothing, is logged once, and breaks nothing", function()
    local log = Wax.import("core.log")
    local before = log.newest_id()
    local g = install(new_game({ level = 25, have = { "Crafting_Bench" } }))
    t.eq(#log.since(before, { level = "warn", channel = "wax.research" }), 0, "nothing failed quietly in the tests above")
    fake.controller.PlayerState.BlueprintTalentController.Model.GetLevel = function() error("no such function") end
    t.eq(Research:GetLevel(), nil)
    t.eq(Research:GetLevel(), nil)
    local warnings = log.since(before, { level = "warn", channel = "wax.research" })
    t.eq(#warnings, 1)
    t.ok(warnings[1].message:find("reading the level failed", 1, true), warnings[1].message)
    t.eq(Research:GetPlan("Shotgun").player_level, 0)
    t.eq(g.forced, 0)
    t.eq(errors(), 0)
end)

t.test("engine: game.Research is read-only and names what it has", function()
    local err = t.raises(function() return Research.GetPlans end, "is not a member of game.Research")
    t.ok(tostring(err):find("GetPlan", 1, true), "suggests GetPlan: " .. tostring(err))
    t.raises(function() Research.Other = 1 end, "read-only")
    t.eq(tostring(Research), "Research")
    t.eq(rawget(game.root, "Research"), Research)
end)

t.finish("research")
