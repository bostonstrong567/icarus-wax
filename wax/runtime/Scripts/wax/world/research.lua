-- game.Research: the tech tree. What a recipe still needs researched, and researching it with the player's own points

local Wax = ...
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local co = Wax.import("core.co")
local suggest = Wax.import("core.suggest")
local log = Wax.import("core.log").channel("wax.research")

local M = {}

M.MIN_FRAMES = 3        -- frames the game gets after a node is bought before it is asked about it
M.GRACE_FRAMES = 30     -- frames a node may take to show as researched, or as open to research, before the step fails
M.MAX_FRAMES = 300      -- the longest wait for one node while the game is still sending it on
M.POLL_FRAMES = 30      -- how often level and points are looked at while something listens to Changed
M.MAX_VISITS = 400      -- a walk through the tree that looks at more nodes than this is cut short

local RECIPES, TALENTS = "/Engine/Transient.D_ProcessorRecipes", "/Engine/Transient.D_Talents"
local TREES, TIERS, ITEMS = "/Engine/Transient.D_TalentTrees", "/Engine/Transient.D_TalentArchetypes", "/Engine/Transient.D_Itemable"
local REROUTE = 1
local NONE = {}

local function fold(name) return (tostring(name):lower()) end

local function top_level(world, nodes)
    local top = 0
    for _, node in ipairs(nodes) do top = math.max(top, world.level_of(node) or 0) end
    return top
end

-- Fewer nodes to buy is better. Of two ways as long, the one that asks the lower level.
local function better(world, way, than)
    if not than then return true end
    if #way ~= #than then return #way < #than end
    return top_level(world, way) < top_level(world, than)
end

-- The nodes to buy so that `node` counts as researched, the node itself last. Nothing when every way leads round in a circle.
local function way_to(world, node, walk)
    if walk.trail[node] then
        walk.looped = true
        return nil
    end
    local known = walk.done[node]
    if known then return known end
    walk.visits = walk.visits + 1
    if walk.visits > M.MAX_VISITS then
        walk.looped = true
        return nil
    end
    -- a reroute is researched from the start and stands for what is behind it, so its own state says nothing
    local reroute = world.is_reroute(node)
    if not reroute and world.unlocked(node) then
        walk.done[node] = NONE
        return NONE
    end
    local outer = walk.looped
    walk.trail[node], walk.looped = true, false
    -- of several parents one is enough
    local best, parents = nil, world.parents(node)
    for _, parent in ipairs(parents) do
        local way = way_to(world, parent, walk)
        if way and better(world, way, best) then best = way end
    end
    walk.trail[node] = nil
    local clean = not walk.looped
    walk.looped = outer or walk.looped
    if #parents == 0 then best = NONE end
    if not best then return nil end
    local way = best
    if not reroute then
        way = table.move(best, 1, #best, 1, {})
        way[#way + 1] = node
    end
    if clean then walk.done[node] = way end
    return way
end

-- What researching a recipe's node takes, over a `world` of plain functions. `live` below is the game's.
function M.plan(world, recipe)
    local node = world.node_of(recipe)
    if not node then return nil end
    local level, available = world.player_level() or 0, world.points() or 0
    local plan = { node = node, name = world.name_of(node), level = world.level_of(node) or 0, unlocked = false,
        default = world.is_default ~= nil and world.is_default(node) == true, steps = {}, points = 0, available = available,
        player_level = level, needed_level = 0, can = false, blocked = false }
    local nodes = not world.unlocked(node) and (way_to(world, node, { trail = {}, done = {}, looped = false, visits = 0 }) or { node })
    if not nodes or #nodes == 0 then
        plan.unlocked = true
        return plan
    end
    -- a later step that needs a flag cannot be asked about until the steps before it are bought
    local unsure = false
    for at, step in ipairs(nodes) do
        local needs = world.level_of(step) or 0
        plan.steps[at] = { node = step, name = world.name_of(step), level = needs }
        if needs > plan.needed_level then plan.needed_level = needs end
        if at > 1 and world.flagged ~= nil and world.flagged(step) then unsure = true end
    end
    plan.points = #nodes
    if level >= plan.needed_level and available >= plan.points then
        plan.can = not unsure and world.can_unlock(nodes[1]) == true
        plan.blocked = not plan.can
    end
    return plan
end

-- The step before may take a few frames to open this one.
local function open_now(world, node)
    for _ = 1, M.GRACE_FRAMES do
        if world.can_unlock(node) then return true end
        world.wait()
    end
    return false
end

-- After a node is bought: a few frames, then until the game has sent it on, then the model says whether it took.
local function took(world, node)
    local quiet = 0
    for frame = 1, M.MAX_FRAMES do
        world.wait()
        if world.syncing() then
            quiet = 0
        elseif frame >= M.MIN_FRAMES then
            if world.unlocked(node) then return true end
            quiet = quiet + 1
            if quiet >= M.GRACE_FRAMES then return false end
        end
    end
    return false
end

-- Buys what a recipe's node still needs, a node at a time. `world` also has buy(node), syncing() and wait().
function M.unlock(world, recipe)
    local plan = M.plan(world, recipe)
    if plan and plan.unlocked then return true, 0, nil end
    if not plan or not plan.can then return false, 0, nil end
    local bought = 0
    for _, step in ipairs(plan.steps) do
        if not world.unlocked(step.node) then
            if not open_now(world, step.node) or not world.buy(step.node) then return false, bought, step.name end
            if not took(world, step.node) then return false, bought, step.name end
            bought = bought + 1
        end
    end
    return true, bought, nil
end

local recipe_names = nil    -- folded recipe name -> the name as the game lists it
local facts = {}            -- folded node name -> what its row says as plain values, false when the game has no such row
local sources = {}          -- folded node name -> the row a handle for it is read from: { recipe = name } or { child = name }
local tier_levels = {}      -- folded tree name -> the level its tier asks
local absent = {}           -- tables the game did not have when asked
local warned = {}

function M.flush()
    recipe_names, facts, sources, tier_levels, absent, warned = nil, {}, {}, {}, {}, {}
end

-- Runs fn and gives what it returns, or nothing when it raises. Each kind of failure is logged once.
local function try(what, fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    if not warned[what] then
        warned[what] = true
        log:warn("%s failed: %s", what, tostring(a))
    end
    return nil
end

local function read(fallback, fn, ...)
    local ok, value = pcall(fn, ...)
    if ok and value ~= nil then return value end
    return fallback
end

-- A table that is not there is asked for once: each miss takes the engine tens of milliseconds.
local function table_at(path)
    if absent[path] then return nil end
    local found = StaticFindObject(path)
    if found:IsValid() then return found end
    absent[path] = true
    return nil
end

local function controller()
    local game = Wax.game
    local player = game and game.LocalPlayer
    return player and player.Raw or nil
end

-- The player's tech tree: the model that answers, the component that unlocks, the controller. Read each time, never kept.
local function tree()
    local player = controller()
    if not player then return nil end
    local state = player.PlayerState
    if not state or not state:IsValid() then return nil end
    local unlocker = state.BlueprintTalentController
    if not unlocker or not unlocker:IsValid() then return nil end
    local model = unlocker.Model
    if not model or not model:IsValid() then return nil end
    return model, unlocker, player
end

local function trimmed(value) return (tostring(value):gsub("^%s+", ""):gsub("%s+$", "")) end
local function empty(name) return name == "" or fold(name) == "none" end

local function tier_level(row)
    local name = row.TalentTree.RowName:ToString()
    local key = fold(name)
    local known = tier_levels[key]
    if known then return known end
    local level = 0
    local trees, tiers = table_at(TREES), table_at(TIERS)
    local tree_row = trees and not empty(name) and trees:FindRow(name)
    if tree_row and tiers then
        local tier = tree_row.Archetype.RowName:ToString()
        local tier_row = not empty(tier) and tiers:FindRow(tier)
        if tier_row then level = tonumber(tier_row.RequiredLevel) or 0 end
    end
    tier_levels[key] = level
    return level
end

-- A node's own name, else the name of the item it stands for.
local function shown_name(row)
    local name = trimmed(row.DisplayName:ToString())
    if name ~= "" then return name end
    local item = row.ExtraData.RowName:ToString()
    local items = not empty(item) and table_at(ITEMS)
    local item_row = items and items:FindRow(item)
    return item_row and trimmed(item_row.DisplayName:ToString()) or ""
end

-- What a node's row says, read once. `spelled` is the name as a handle gave it, so the engine knows it already.
local function fact_of(node, spelled)
    local fact = facts[node]
    if fact ~= nil then return fact or nil end
    local talents = table_at(TALENTS)
    if not talents then return nil end
    local row = talents:FindRow(spelled)
    if not row then
        facts[node] = false
        return nil
    end
    fact = { row = spelled, parents = {} }
    fact.reroute = read(false, function() return row.TalentType == REROUTE end)
    fact.default = read(false, function() return row.bDefaultUnlocked == true end)
    -- when the flags cannot be read the node counts as needing one
    fact.flagged = read(true, function() return row.RequiredFlags:GetArrayNum() > 0 end)
    fact.level = math.max(read(0, function() return tonumber(row.RequiredLevel) end), read(0, tier_level, row))
    fact.name = read("", shown_name, row)
    if fact.name == "" then fact.name = (spelled:gsub("_", " ")) end
    pcall(function()
        row.RequiredTalents:ForEach(function(_, element)
            local name = element:get().RowName:ToString()
            if not empty(name) then fact.parents[#fact.parents + 1] = name end
        end)
    end)
    facts[node] = fact
    return fact
end

-- The handle the game's functions take for a node, from a live row. For this call only, never kept.
local function handle_of(node)
    local from = sources[node]
    if not from then return nil end
    if from.recipe then
        local recipes = table_at(RECIPES)
        local row = recipes and recipes:FindRow(from.recipe)
        return row and row.Requirement or nil
    end
    local talents = table_at(TALENTS)
    local row = talents and talents:FindRow(from.child)
    if not row then return nil end
    local found = nil
    row.RequiredTalents:ForEach(function(_, element)
        local handle = element:get()
        if not found and fold(handle.RowName:ToString()) == node then found = handle end
    end)
    return found
end

local function in_model(node)
    local model, unlocker, player = tree()
    if not model then return nil end
    local handle = handle_of(node)
    if not handle or model:DoesModelContainTalent(handle) ~= true then return nil end
    return model, handle, unlocker, player
end

local live = {}

function live.ready()
    return try("looking for the tech tree", function() return tree() ~= nil end) == true
end

function live.player_level()
    return try("reading the level", function()
        local model = tree()
        local level = model and model:GetLevel()
        return type(level) == "number" and level or nil
    end)
end

function live.points()
    return try("reading the points", function()
        local model = tree()
        if not model then return nil end
        local available, total, spent = model:GetAvailablePoints(), model:GetTotalPoints(), model:GetSpentPoints()
        if type(available) ~= "number" then return nil end
        return available, tonumber(total) or available, tonumber(spent) or 0
    end)
end

function live.node_of(recipe)
    return try("reading a recipe's node", function()
        local recipes = table_at(RECIPES)
        if not recipes then return nil end
        if not recipe_names then
            local names = {}
            for _, name in ipairs(recipes:GetRowNames()) do
                if type(name) == "string" then names[fold(name)] = name end
            end
            recipe_names = names
        end
        -- only names the game listed are asked for: an unknown one would stay in the engine's name table
        local listed = recipe_names[fold(recipe)]
        local row = listed and recipes:FindRow(listed)
        if not row then return nil end
        local spelled = row.Requirement.RowName:ToString()
        if empty(spelled) then return nil end
        local node = fold(spelled)
        if not fact_of(node, spelled) then return nil end
        sources[node] = { recipe = listed }
        return node
    end)
end

function live.parents(node)
    return try("reading a node's parents", function()
        local out, fact = {}, facts[node]
        for _, spelled in ipairs(fact and fact.parents or {}) do
            local parent = fold(spelled)
            if fact_of(parent, spelled) then
                if not sources[parent] then sources[parent] = { child = fact.row } end
                out[#out + 1] = parent
            end
        end
        return out
    end) or {}
end

function live.is_reroute(node)
    local fact = facts[node]
    return fact and fact.reroute or false
end

function live.is_default(node)
    local fact = facts[node]
    return fact and fact.default or false
end

function live.flagged(node)
    local fact = facts[node]
    if not fact then return true end
    return fact.flagged
end

function live.level_of(node)
    local fact = facts[node]
    return fact and fact.level or 0
end

function live.name_of(node)
    local fact = facts[node]
    return fact and fact.name or node
end

function live.unlocked(node)
    return try("asking whether a node is researched", function()
        local model, handle = in_model(node)
        return model ~= nil and model:IsTalentUnlocked(handle) == true
    end) == true
end

function live.can_unlock(node)
    return try("asking whether a node can be researched", function()
        local model, handle = in_model(node)
        if not model then return false end
        local rank = model:GetTalentRank(handle)
        return type(rank) == "number" and model:CanUnlockTalent(handle, rank + 1, false) == true
    end) == true
end

-- Spends a point. The second argument stays false: the game then applies every rule of its own.
function live.buy(node)
    return try("researching a node", function()
        local model, handle, unlocker = in_model(node)
        if not model or unlocker:IsInteractionEnabled() ~= true then return false end
        return unlocker:UnlockNextTalentRank(handle, false) ~= false
    end) == true
end

function live.syncing()
    return try("asking whether the game is still sending", function()
        local player = controller()
        return player ~= nil and player:IsSyncingUpdateCharacterTalents() == true
    end) == true
end

function live.wait() sched.task.wait() end

local Changed = sched.Signal.new("Research.Changed")
local watching, seen, frames = nil, nil, 0

local function reading()
    local level = live.player_level()
    local available, total = live.points()
    return ("%s %s %s"):format(tostring(level), tostring(available), tostring(total)), level, available
end

local function tick()
    if Changed.count == 0 then
        watching:Disconnect()
        watching = nil
        return
    end
    frames = frames + 1
    if frames % M.POLL_FRAMES ~= 0 then return end
    local now, level, available = reading()
    if now == seen then return end
    seen = now
    Changed:Fire(level, available)
end

-- The look every few frames runs for no mod in particular, and only while something listens.
local function watch()
    if watching and watching.Connected then return end
    seen, frames = reading(), 0
    local previous = scope.enter(nil)
    watching = sched.Frame:Connect(tick)
    scope.leave(previous)
end

local connect = Changed.Connect
function Changed:Connect(fn)
    if type(fn) ~= "function" then error("Connect expects a function, got " .. type(fn), 2) end
    local connection = connect(self, fn)
    watch()
    return connection
end

local Research = { Changed = Changed }
local NAMES = { "IsReady", "GetLevel", "GetPoints", "GetPlan", "Unlock", "Changed" }
local running = nil

-- True while the player has a tech tree to ask, which is in a prospect.
function Research:IsReady()
    return live.ready()
end

-- The player's level as the tech tree counts it. Nothing while there is no tech tree.
function Research:GetLevel()
    return live.player_level()
end

-- The points left to spend, then all the player has had, then those spent. Nothing while there is no tech tree.
function Research:GetPoints()
    return live.points()
end

-- What researching the node of a recipe (a row name of D_ProcessorRecipes) takes. Nothing when it needs none.
function Research:GetPlan(recipe)
    if type(recipe) ~= "string" or recipe == "" then error("game.Research:GetPlan expects a recipe's row name", 2) end
    if not live.ready() then return nil end
    return M.plan(live, recipe)
end

-- Researches a recipe's node and what it needs first, with the player's points. Returns ok, bought, failed.
function Research:Unlock(recipe)
    if type(recipe) ~= "string" or recipe == "" then error("game.Research:Unlock expects a recipe's row name", 2) end
    if not co.isyieldable() then
        error("game.Research:Unlock can only be used inside a task. Wrap the code in task.spawn(function() ... end)", 2)
    end
    -- one at a time: a second call while one runs buys nothing
    if running and co.status(running) ~= "dead" then return false, 0, nil end
    if not live.ready() then return false, 0, nil end
    running = co.running()
    local ok, bought, failed = M.unlock(live, recipe)
    running = nil
    return ok, bought, failed
end

setmetatable(Research, {
    __index = function(_, key)
        error(("%s is not a member of game.Research.%s"):format(tostring(key), suggest.phrase(tostring(key), NAMES)), 2)
    end,
    __newindex = function(_, key)
        error(("game.Research.%s cannot be assigned because game.Research is read-only"):format(tostring(key)), 2)
    end,
    __tostring = function() return "Research" end,
    __names = function() return NAMES end,
})

local connection = nil

function M.start()
    local game = Wax.import("engine.game")
    rawset(game.root, "Research", Research)
    if not connection then connection = game.root.MapChanged:Connect(M.flush) end
end

M.api = Research
M.live = live
return M
