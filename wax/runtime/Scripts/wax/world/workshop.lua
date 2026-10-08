-- game.Workshop: the store on the station. Its categories, nodes and prices, what the player has researched, and checks for a store a mod describes

local Wax = ...
local sched = Wax.import("core.sched")
local scope = Wax.import("core.scope")
local co = Wax.import("core.co")
local suggest = Wax.import("core.suggest")
local log = Wax.import("core.log").channel("wax.workshop")
local spec = Wax.import("world.workshop_spec")
local check = Wax.import("world.workshop_check")
local layout = Wax.import("world.workshop_layout")

local M = {}

M.POLL_FRAMES = 30          -- how often the player's side is looked at while something listens to Changed
M.MAX_POLLED = 16           -- balances looked at in one such look
M.SLICE = 40                -- nodes worked out in a frame by Load
M.WALLET_CALL = false       -- true asks the wallet's own function for a balance. No probe has called it yet

-- This file alone names the game's tables, fields and numbers for the store.
M.MODEL = "Workshop"
M.TABLES = { categories = "TalentArchetypes", trees = "TalentTrees", nodes = "Talents", items = "WorkshopItems",
    templates = "ItemTemplate", statics = "ItemsStatic", itemables = "Itemable", currencies = "MetaCurrency",
    flags = "AccountFlags", dlcs = "DLCPackageData" }
M.LINES = { [1] = "none", [2] = "straight", [3] = "elbow", [4] = "elbow-down" }         -- ELineDrawMethod, 0 is the store's own way
M.FLAG_KINDS = { [0] = "character", [1] = "session", [2] = "account", [3] = "dlc" }     -- EFlagsTableType
local JOINT = 1             -- ETalentNodeType::Reroute
local NODE_HANDLE, CURRENCY_HANDLE = "D_Talents", "D_MetaCurrency"

local CATEGORY_FIELDS = { "Model.RowName", "DisplayName", "Icon", "RequiredLevel" }
local TREE_FIELDS = { "Archetype.RowName", "BackgroundTexture" }
local MEMBER_FIELDS = { "TalentTree.RowName" }
local NODE_FIELDS = { "TalentType", "ExtraData.RowName", "TalentTree.RowName", "position", "Size", "RequiredTalents.RowName",
    "RequiredFlags.RowName", "RequiredLevel", "bDefaultUnlocked", "DrawMethodOverride" }
local FLAG_FIELDS = { "RequiredFlags.DataTableName" }
local GATE_FIELDS = { "RequiredFlags.RowName" }
local PLAN_OPTIONS = { "mod" }
local ITEM_FIELDS = { "Item.RowName", "ResearchCost.Meta.RowName", "ResearchCost.Amount", "ReplicationCost.Meta.RowName",
    "ReplicationCost.Amount" }
local TEMPLATE_FIELDS = { "ItemStaticData.RowName" }
local STATIC_FIELDS = { "Itemable.RowName" }
local ITEMABLE_FIELDS = { "DisplayName", "Icon", "MaxStack" }
local CURRENCY_FIELDS = { "DisplayName", "Icon", "bDisplayOnMainScreen" }
local NAME_ONLY = {}
local HOMES = { talent = "nodes", store_item = "items", template = "templates", item = "statics", currency = "currencies",
    flag = "flags", dlc = "dlcs", category = "categories", tree = "trees" }

local function fold(name) return (tostring(name):lower()) end

local function trimmed(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function whole(value) return type(value) == "number" and math.tointeger(value) or 0 end

local function number(value)
    if type(value) ~= "number" then return 0 end
    return math.tointeger(value) or value
end

-- The row a handle points at, or nothing.
local function named(handle)
    local name = type(handle) == "table" and handle.RowName
    if type(name) ~= "string" or name == "" or fold(name) == "none" then return nil end
    return name
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = copy(item) end
    return out
end

local function copy_cost(cost)
    local out = {}
    for currency, amount in pairs(cost) do out[currency] = amount end
    return out
end

-- A node's record as a new table all the way down. Every field the reader's node() sets is named here.
local function copy_node(record)
    if not record then return nil end
    local flags = {}
    for at, flag in ipairs(record.Flags) do flags[at] = { Id = flag.Id, Kind = flag.Kind } end
    return { Id = record.Id, Category = record.Category, Joint = record.Joint, Free = record.Free, Level = record.Level,
        At = { X = record.At.X, Y = record.At.Y }, Size = record.Size, Line = record.Line,
        Needs = table.move(record.Needs, 1, #record.Needs, 1, {}), Flags = flags, Research = copy_cost(record.Research),
        Replicate = copy_cost(record.Replicate), StoreItem = record.StoreItem, Gives = record.Gives, Item = record.Item,
        Name = record.Name, Icon = record.Icon }
end

local warned = {}

-- Runs fn and gives what it returns, or nothing when it raises. Each kind of failure is logged once.
local function try(what, fn, ...)
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    if not warned[what] then
        warned[what] = true
        log:warn("%s failed: %s", what, tostring(a))
    end
    return nil
end

-- The line style's number in the game for one of Wax's words, for the step that writes rows.
function M.line_number(word)
    for number_of, known in pairs(M.LINES) do
        if known == word then return number_of end
    end
    return 0
end

-- The store read from `rows`: names(table), row(table, name, fields), and for the game also load, pause and epoch. Its records are kept and shared.
function M.reader(rows)
    local T = M.TABLES
    local R = {}
    local function empty()
        return { nodes = {}, items = {}, templates = {}, shown = {}, categories = false, members = false, currencies = false, gates = false }
    end
    local cache = empty()
    local epoch = rows.epoch
    local read_at = epoch and epoch()

    function R.flush() cache = empty() end

    -- What was worked out is dropped once the rows count a change, so a read in the frame of a write is not an old one.
    local function fresh()
        local now = epoch and epoch()
        if now ~= read_at then cache, read_at = empty(), now end
    end

    -- A row's name as the game spells it, or nothing when the table has no such row.
    local function spelled(home, name)
        if type(name) ~= "string" then return nil end
        local row = rows.row(home, name, NAME_ONLY)
        return row and row.Name or nil
    end

    local function categories()
        local known = cache.categories
        if known then return known end
        known = { list = {}, by = {}, by_tree = {} }
        for _, name in ipairs(rows.names(T.categories)) do
            local row = rows.row(T.categories, name, CATEGORY_FIELDS)
            if row and fold(named(row.Model) or "") == fold(M.MODEL) then
                local record = { Id = row.Name, Name = trimmed(row.DisplayName), Icon = row.Icon or nil, Level = whole(row.RequiredLevel) }
                known.list[#known.list + 1] = record
                known.by[fold(row.Name)] = record
            end
        end
        for _, name in ipairs(rows.names(T.trees)) do
            local row = rows.row(T.trees, name, TREE_FIELDS)
            local owner = row and known.by[fold(named(row.Archetype) or "")]
            if owner then
                known.by_tree[fold(row.Name)] = owner
                if not owner.Tree then owner.Tree, owner.Background = row.Name, row.BackgroundTexture or nil end
            end
        end
        cache.categories = known
        return known
    end

    -- The names of each category's nodes. Nothing but a look at every row of the table says which tree a node is in.
    local function members()
        local known = cache.members
        if known then return known end
        local by_tree = categories().by_tree
        known = {}
        for _, name in ipairs(rows.names(T.nodes)) do
            local row = rows.row(T.nodes, name, MEMBER_FIELDS)
            local owner = row and by_tree[fold(named(row.TalentTree) or "")]
            if owner then
                local key = fold(owner.Id)
                known[key] = known[key] or {}
                known[key][#known[key] + 1] = row.Name
            end
        end
        cache.members = known
        return known
    end

    local function template(name)
        if type(name) ~= "string" then return nil end
        local key = fold(name)
        local known = cache.templates[key]
        if known ~= nil then return known or nil end
        local row = rows.row(T.templates, name, TEMPLATE_FIELDS)
        if not row then
            cache.templates[key] = false
            return nil
        end
        local item = named(row.ItemStaticData)
        known = { row = row.Name, item = item and (spelled(T.statics, item) or item) or nil }
        cache.templates[key] = known
        return known
    end

    -- The name, picture and stack size the game has for an item of D_ItemsStatic.
    local function shown(item)
        local key = fold(item)
        local known = cache.shown[key]
        if known ~= nil then return known or nil end
        local static = rows.row(T.statics, item, STATIC_FIELDS)
        local itemable = static and named(static.Itemable)
        local row = itemable and rows.row(T.itemables, itemable, ITEMABLE_FIELDS)
        known = row and { name = trimmed(row.DisplayName), icon = row.Icon or nil, stack = whole(row.MaxStack) } or false
        cache.shown[key] = known
        return known or nil
    end

    local function price(list)
        local out = {}
        for _, cost in ipairs(list or {}) do
            local currency = named(cost.Meta)
            if currency and type(cost.Amount) == "number" then
                local id = spelled(T.currencies, currency) or currency
                out[id] = (out[id] or 0) + number(cost.Amount)
            end
        end
        return out
    end

    -- A row of the store's items: the template it gives and its two prices.
    local function sold(name)
        if type(name) ~= "string" then return nil end
        local key = fold(name)
        local known = cache.items[key]
        if known ~= nil then return known or nil end
        local row = rows.row(T.items, name, ITEM_FIELDS)
        if not row then
            cache.items[key] = false
            return nil
        end
        local given = named(row.Item)
        known = { row = row.Name, gives = given and (spelled(T.templates, given) or given) or nil,
            research = price(row.ResearchCost), replicate = price(row.ReplicationCost) }
        cache.items[key] = known
        return known
    end

    local function node(name)
        if type(name) ~= "string" then return nil end
        local key = fold(name)
        local known = cache.nodes[key]
        if known ~= nil then return known or nil end
        local row = rows.row(T.nodes, name, NODE_FIELDS)
        local owner = row and categories().by_tree[fold(named(row.TalentTree) or "")]
        if not owner then
            cache.nodes[key] = false
            return nil
        end
        local at, size = row.position or {}, row.Size or {}
        local record = { Id = row.Name, Category = owner.Id, Joint = row.TalentType == JOINT, Free = row.bDefaultUnlocked == true,
            Level = whole(row.RequiredLevel), At = { X = number(at.X), Y = number(at.Y) }, Size = number(size.X),
            Line = M.LINES[row.DrawMethodOverride], Needs = {}, Flags = {}, Research = {}, Replicate = {} }
        for _, parent in ipairs(row.RequiredTalents or {}) do
            local parent_name = named(parent)
            if parent_name then record.Needs[#record.Needs + 1] = spelled(T.nodes, parent_name) or parent_name end
        end
        local flags = row.RequiredFlags or {}
        if #flags > 0 then
            -- which table a flag is of is read by itself, and worked out from the tables when that fails
            local kinds = try("reading which table a flag is of", rows.row, T.nodes, name, FLAG_FIELDS)
            local list = kinds and kinds.RequiredFlags or {}
            for index, flag in ipairs(flags) do
                local id = named(flag)
                if id then
                    local kind = M.FLAG_KINDS[list[index] and list[index].DataTableName or false]
                    if not kind then kind = spelled(T.dlcs, id) and "dlc" or spelled(T.flags, id) and "account" or nil end
                    local home = kind == "dlc" and T.dlcs or kind == "account" and T.flags or nil
                    record.Flags[#record.Flags + 1] = { Id = home and spelled(home, id) or id, Kind = kind }
                end
            end
        end
        local selling = named(row.ExtraData)
        if selling then
            local item = sold(selling)
            record.StoreItem = item and item.row or selling
            if item then
                record.Research, record.Replicate, record.Gives = copy(item.research), copy(item.replicate), item.gives
                local what = template(item.gives)
                if what and what.item then
                    record.Item = what.item
                    local look = shown(what.item)
                    if look then record.Name, record.Icon = look.name, look.icon end
                end
            end
        end
        cache.nodes[key] = record
        return record
    end

    local function all_names()
        local of, out = members(), {}
        for _, category in ipairs(categories().list) do
            for _, name in ipairs(of[fold(category.Id)] or {}) do out[#out + 1] = name end
        end
        return out
    end

    function R.categories() return categories().list end

    function R.category(name)
        return type(name) == "string" and categories().by[fold(name)] or nil
    end

    R.node = node

    -- The node's row name as the game spells it when it is a node of the store. It does not read what the node sells.
    local function is_node(name)
        local row = type(name) == "string" and rows.row(T.nodes, name, MEMBER_FIELDS)
        if not row or not categories().by_tree[fold(named(row.TalentTree) or "")] then return nil end
        return row.Name
    end
    R.is_node = is_node

    -- The nodes of one category, or of every category in the store's order.
    function R.nodes(category)
        local names, out = category and (members()[fold(category)] or {}) or all_names(), {}
        for _, name in ipairs(names) do
            local record = node(name)
            if record then out[#out + 1] = record end
        end
        return out
    end

    local function currencies()
        local known = cache.currencies
        if known then return known end
        known = {}
        for _, name in ipairs(rows.names(T.currencies)) do
            local row = rows.row(T.currencies, name, CURRENCY_FIELDS)
            if row then
                known[#known + 1] = { Id = row.Name, Name = (trimmed(row.DisplayName):gsub("^%[DNT%]%s*", "")), Icon = row.Icon or nil,
                    Shown = row.bDisplayOnMainScreen == true }
            end
        end
        cache.currencies = known
        return known
    end
    R.currencies = currencies

    -- The game's spelling of a row of one kind, or nothing. Kinds: talent, node, store_item, template, item, currency, flag, dlc, category, tree.
    function R.has(kind, name)
        if kind == "node" then return is_node(name) end
        return spelled(T[HOMES[kind]], name)
    end

    function R.where(kind) return "D_" .. T[HOMES[kind] or "nodes"] end

    function R.names(kind)
        if kind == "node" then return all_names() end
        if kind == "category" then
            local out = {}
            for at, category in ipairs(categories().list) do out[at] = category.Id end
            return out
        end
        return rows.names(T[HOMES[kind]])
    end

    -- What an item template hands over: { row, item }. And a row of the store's items: { row, gives, research, replicate }.
    R.template = template
    R.store_item = sold

    -- How many of an item one stack holds, or nothing when the game does not say.
    function R.stack(item)
        local look = type(item) == "string" and shown(item)
        return look and look.stack > 0 and look.stack or nil
    end

    -- What the game only sells to owners of a DLC: template and item, each folded, to the DLC rows that gate it.
    function R.gates()
        local known = cache.gates
        if known then return known end
        known = { templates = {}, items = {} }
        local function add(into, name, flag)
            local key = fold(name)
            into[key] = into[key] or {}
            for _, have in ipairs(into[key]) do
                if fold(have) == fold(flag) then return end
            end
            into[key][#into[key] + 1] = flag
        end
        for _, name in ipairs(all_names()) do
            -- only the flags are asked for: the few nodes that have some are then read in full
            local row = rows.row(T.nodes, name, GATE_FIELDS)
            if row and #(row.RequiredFlags or {}) > 0 then
                local record = node(name)
                for _, flag in ipairs(record and record.Flags or {}) do
                    if flag.Kind == "dlc" then
                        if record.Gives then add(known.templates, record.Gives, flag.Id) end
                        if record.Item then add(known.items, record.Item, flag.Id) end
                    end
                end
            end
        end
        cache.gates = known
        return known
    end

    -- Reads all of the store, and gives the frame back in between when the rows can do that. For a task.
    function R.load()
        local load, pause = rows.load, rows.pause
        if load then
            load(T.categories, CATEGORY_FIELDS)
            load(T.trees, TREE_FIELDS)
            load(T.nodes, MEMBER_FIELDS)
        end
        local names = all_names()
        if load then
            load(T.nodes, NODE_FIELDS, names)
            local items, templates, statics, itemables = {}, {}, {}, {}
            for _, name in ipairs(names) do
                local row = rows.row(T.nodes, name, NODE_FIELDS)
                items[#items + 1] = row and named(row.ExtraData) or nil
            end
            load(T.items, ITEM_FIELDS, items)
            for _, name in ipairs(items) do
                local row = rows.row(T.items, name, ITEM_FIELDS)
                templates[#templates + 1] = row and named(row.Item) or nil
            end
            load(T.templates, TEMPLATE_FIELDS, templates)
            for _, name in ipairs(templates) do
                local row = rows.row(T.templates, name, TEMPLATE_FIELDS)
                statics[#statics + 1] = row and named(row.ItemStaticData) or nil
            end
            load(T.statics, STATIC_FIELDS, statics)
            for _, name in ipairs(statics) do
                local row = rows.row(T.statics, name, STATIC_FIELDS)
                itemables[#itemables + 1] = row and named(row.Itemable) or nil
            end
            load(T.itemables, ITEMABLE_FIELDS, itemables)
            load(T.currencies, CURRENCY_FIELDS)
        end
        for at, name in ipairs(names) do
            node(name)
            if pause and at % M.SLICE == 0 then pause() end
        end
        currencies()
        return #names
    end

    for name, fn in pairs(R) do
        if name ~= "flush" and name ~= "where" then
            R[name] = function(...)
                fresh()
                return fn(...)
            end
        end
    end

    -- For the writing side: how far the rows had been read, to hand to wrote after a write.
    function R.mark()
        fresh()
        return read_at
    end

    -- After a write that only changed fields of these nodes and prices of these store items: which node is in which category is kept.
    function R.wrote(mark, nodes, items)
        if not epoch or mark == nil or mark ~= read_at then return end
        if #items > 0 then
            -- any node may sell a changed store item, and a node's record holds its prices
            cache.nodes = {}
            for _, item in ipairs(items) do cache.items[fold(item)] = nil end
        else
            for _, row in ipairs(nodes) do cache.nodes[fold(row)] = nil end
        end
        read_at = epoch()
    end
    return R
end

-- Rows from plain tables, for the command line and the tests: { Talents = { defaults = { ... }, rows = { { "Name", Field = value } } } }.
function M.plain(tables)
    local opened = {}
    local function open(name)
        local found = opened[name]
        if found then return found end
        local source = tables[name]
        if type(source) ~= "table" then error(("these rows have no table named %s"):format(tostring(name)), 0) end
        found = { names = {}, by = {} }
        for at, row in ipairs(source.rows) do
            local filled = copy(source.defaults or {})
            for key, value in pairs(row) do
                if key ~= 1 then filled[key] = value end
            end
            filled.Name = row[1]
            found.names[at] = row[1]
            found.by[fold(row[1])] = filled
        end
        opened[name] = found
        return found
    end
    return {
        names = function(name)
            local names = open(name).names
            return table.move(names, 1, #names, 1, {})
        end,
        row = function(name, row) return open(name).by[fold(row)] end,
    }
end

local function clean(problem)
    local text = tostring(problem):match("^[^\r\n]*") or ""
    local stripped = 1
    while stripped > 0 do text, stripped = text:gsub("^.-%.lua:%d+: ", "") end
    return text
end

-- Wraps a function whose errors carry no position, so they point at the mod's line.
local function public(fn)
    return function(...)
        local ok, result = pcall(fn, ...)
        if not ok then error(clean(result), 2) end
        return result
    end
end

local data_api = nil

local function data()
    if data_api == nil then
        local ok, tables = pcall(Wax.import, "data.tables")
        data_api = ok and type(tables) == "table" and tables.api or false
    end
    if not data_api then error("the game's tables cannot be read, so the store cannot be read either", 0) end
    return data_api
end

local held_tables = {}      -- table name -> the object game.Data hands out for it, which stays the same one

local function table_of(name)
    local found = held_tables[name]
    if not found then
        found = data():Table(name)
        held_tables[name] = found
    end
    return found
end

local game_rows = {}
function game_rows.names(name) return table_of(name):GetNames() end
function game_rows.row(name, row, fields) return table_of(name):Row(row, fields) end
function game_rows.load(name, fields, names) table_of(name):Load({ fields = fields, names = names }) end
function game_rows.pause() sched.task.wait() end
-- The number game.Data counts up whenever it forgets rows. Nothing while it keeps no such number.
function game_rows.epoch()
    local tables = Wax.modules["data.tables"]
    return type(tables) == "table" and tables.epoch or nil
end

local store = M.reader(game_rows)

local function controller()
    local game = Wax.game
    local player = game and game.LocalPlayer
    return player and player.Raw or nil
end

-- The model that answers for the player's store, their state and their controller. Read each time, never kept.
local function store_model()
    local player = controller()
    if not player then return nil end
    local state = player.PlayerState
    if not state or not state:IsValid() then return nil end
    local component = state.WorkshopTalentController
    if not component or not component:IsValid() then return nil end
    local model = component.Model
    if not model or not model:IsValid() then return nil end
    return model, state, player
end

local function text_of(value)
    if type(value) == "string" then return value end
    return value:ToString()
end

local live = {}

function live.ready()
    return try("looking for the store", function() return store_model() ~= nil end) == true
end

-- "bought", "available" or "locked" as the game's own model says, for a node's row name as the game spells it.
function live.state(row)
    return try("asking the store about a node", function()
        local model = store_model()
        if not model then return nil end
        local handle = { RowName = FName(row), DataTableName = FName(NODE_HANDLE) }
        if model:DoesModelContainTalent(handle) ~= true then return nil end
        if model:IsTalentUnlocked(handle) == true then return "bought" end
        local rank = model:GetTalentRank(handle)
        -- the last argument is bIgnoreLockedState: false keeps the model's own lock
        if type(rank) == "number" and model:CanUnlockTalent(handle, rank + 1, false) == true then return "available" end
        return "locked"
    end)
end

-- What the account holds of each currency, by folded row name, as the profile in memory lists it.
function live.balances()
    return try("reading the account's currencies", function()
        local model, state = store_model()
        if not model then return nil end
        local list = state.ActiveUserProfile.MetaResources
        -- the length first, then only places that exist: reading one past the end makes the game's list longer
        local count = list:GetArrayNum()
        if type(count) ~= "number" then return nil end
        local out = {}
        for index = 1, count do
            local entry = list[index]
            local row, amount = text_of(entry.MetaRow), entry.Count
            if type(row) == "string" and type(amount) == "number" then out[fold(row)] = amount end
        end
        return out
    end)
end

function live.wallet(currency)
    return try("asking the wallet for a balance", function()
        local model, _, player = store_model()
        if not model then return nil end
        local wallet = player.PlayerDataComponent
        if not wallet or not wallet:IsValid() then return nil end
        local amount = wallet:GetAvailableMetaResource({ RowName = FName(currency), DataTableName = FName(CURRENCY_HANDLE) })
        return type(amount) == "number" and amount or nil
    end)
end

function live.balance(currency)
    if M.WALLET_CALL then return live.wallet(currency) end
    local held = live.balances()
    return held and (held[fold(currency)] or 0) or nil
end

-- A text that differs when the player's side of the store does: researched nodes, and what the account holds.
function live.reading()
    local model, state = try("looking for the store", store_model)
    if not model then return "none" end
    -- each half by itself, so one the game no longer answers does not hide the other
    local points = try("looking at the store's points", function()
        return ("%s %s"):format(tostring(model:GetSpentPoints()), tostring(model:GetAvailablePoints()))
    end)
    local held = try("looking at the account", function()
        local profile = state.ActiveUserProfile
        local parts = { tostring(profile.Talents:GetArrayNum()) }
        local list = profile.MetaResources
        local count = list:GetArrayNum()
        for index = 1, math.min(type(count) == "number" and count or 0, M.MAX_POLLED) do parts[#parts + 1] = tostring(list[index].Count) end
        return table.concat(parts, " ")
    end)
    return tostring(points) .. " | " .. tostring(held)
end

local Changed = sched.Signal.new("Workshop.Changed")
local watching, seen, frames = nil, nil, 0

local function tick()
    if Changed.count == 0 then
        watching:Disconnect()
        watching = nil
        return
    end
    frames = frames + 1
    if frames % M.POLL_FRAMES ~= 0 then return end
    local now = live.reading()
    if now == seen then return end
    seen = now
    Changed:Fire("player")
end

-- The look every few frames runs for no mod in particular, and only while something listens.
local function watch()
    if watching and watching.Connected then return end
    seen, frames = live.reading(), 0
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

local told = {}             -- folded table -> true while this frame's changes of it were all named field by field

-- A field was written through game.Data. The rows counted that when it was written, so the reader is not older than it.
local function on_patched(name, _, field)
    local key = fold(name):gsub("^d_", "")
    if field == nil then told[key] = false elseif told[key] == nil then told[key] = true end
end

-- game.Data dropped rows: what was worked out from the store's tables goes with them.
local function on_tables(name)
    if name ~= nil then
        local mine, key = false, fold(name):gsub("^d_", "")
        for _, home in pairs(M.TABLES) do mine = mine or fold(home) == key end
        local by_field = told[key]
        told[key] = nil
        if not mine then return end
        if by_field == true then
            if Changed.count > 0 then Changed:Fire("store") end
            return
        end
    else
        told = {}
    end
    store.flush()
    if Changed.count > 0 then Changed:Fire("store") end
end

local function name_of(value, call, example)
    if type(value) ~= "string" or value == "" then
        error(("game.Workshop:%s expects %s, got %s"):format(call, example, type(value) == "string" and "an empty text" or type(value)), 0)
    end
    return value
end

-- The id of the loaded mod whose code is running, else nothing.
local function caller()
    local at = scope.current()
    while at and at.parent do at = at.parent end
    local mods = Wax.mods
    local mod = at and mods and mods.get and mods.get(at.name)
    return mod and mod.scope == at and at.name or nil
end

-- The plan for a described store, for the step that writes rows. `options.mod` names the mod when the caller is none.
-- `world`, when given, answers for the game in place of the store as it is read.
function M.plan(described, options, world)
    if options ~= nil and type(options) ~= "table" then error("the options are a table such as { mod = \"MyMod\" }", 0) end
    for key in pairs(options or {}) do
        if key ~= "mod" then
            error(("Check has no option named '%s'.%s"):format(tostring(key), type(key) == "string" and suggest.phrase(key, PLAN_OPTIONS) or ""), 0)
        end
    end
    local from = caller()
    local mod = from or (options and options.mod) or (type(described) == "table" and described.mod) or nil
    return spec.compile(described, world or store, { mod = mod, folder = from ~= nil })
end

local Layout = {}
local LAYOUT_NAMES = { "Place", "Check", "GetShapes", "GetLimits" }

-- Places for nodes in a shape, as { X, Y } in the order given.
Layout.Place = public(function(_, shape, items, options)
    local out = {}
    for at, place in ipairs(layout.place(shape, items, options)) do out[at] = { X = place.x, Y = place.y } end
    return out
end)

-- What does not fit among places that share a category: nodes on top of each other, too close, or outside the screen.
Layout.Check = public(function(_, places)
    if type(places) ~= "table" then error("game.Workshop.Layout:Check expects a list of places such as { { X = 500, Y = 850 } }", 0) end
    local list = {}
    for at, place in ipairs(places) do
        local x, y, size = nil, nil, nil
        if type(place) == "table" then x, y, size = place.X or place.x or place[1], place.Y or place.y or place[2], place.Size end
        if type(x) ~= "number" or type(y) ~= "number" or x ~= x or y ~= y then
            error(("place %d of the list is not two numbers"):format(at), 0)
        end
        if not (layout.usable(x) and layout.usable(y)) then
            error(("place %d of the list is further than %d from 0, 0, and no place in the store is"):format(at, layout.FAR), 0)
        end
        if size ~= nil and not layout.usable(size) then
            error(("place %d of the list: Size is a number, 0 for a joint"):format(at), 0)
        end
        list[at] = { id = type(place.Id) == "string" and place.Id or ("Place " .. at), x = x, y = y, size = size }
    end
    local problems = check.list()
    check.placed(problems, list)
    return problems.sorted()
end)

function Layout:GetShapes() return table.move(layout.SHAPES, 1, #layout.SHAPES, 1, {}) end

function Layout:GetLimits()
    return { Size = layout.SIZE, Gap = layout.GAP, Top = layout.TOP, Bottom = layout.BOTTOM, Edge = layout.EDGE, Far = layout.FAR }
end

setmetatable(Layout, {
    __index = function(_, key)
        error(("%s is not a member of game.Workshop.Layout.%s"):format(tostring(key), suggest.phrase(tostring(key), LAYOUT_NAMES)), 2)
    end,
    __newindex = function(_, key)
        error(("game.Workshop.Layout.%s cannot be assigned because game.Workshop.Layout is read-only"):format(tostring(key)), 2)
    end,
    __tostring = function() return "Workshop.Layout" end,
    __names = function() return LAYOUT_NAMES end,
})

local Workshop = { Changed = Changed, Layout = Layout }
local NAMES = { "IsReady", "Load", "GetCategories", "GetNodes", "GetNode", "GetCurrencies", "GetState", "GetBalance", "Check",
    "Changed", "Layout" }

-- True while the player has a store to ask. Not at the title screen.
function Workshop:IsReady()
    return live.ready()
end

-- Reads the whole store a slice a frame, so nothing after it has to wait for the game. Only inside a task.
function Workshop:Load()
    if not co.isyieldable() then
        error("game.Workshop:Load can only be used inside a task. Wrap the code in task.spawn(function() ... end)", 2)
    end
    return store.load()
end

Workshop.GetCategories = public(function()
    return copy(store.categories())
end)

Workshop.GetNodes = public(function(_, category)
    local found = nil
    if category ~= nil then
        name_of(category, "GetNodes", "a category's row name such as \"Workshop_Axes\"")
        found = store.category(category)
        if not found then
            error(("the store has no category named '%s'.%s"):format(category, suggest.phrase(category, store.names("category"))), 0)
        end
    end
    local out = {}
    for at, record in ipairs(store.nodes(found and found.Id)) do out[at] = copy_node(record) end
    return out
end)

Workshop.GetNode = public(function(_, id)
    return copy_node(store.node(name_of(id, "GetNode", "a node's row name such as \"Workshop_Axe_Printed\"")))
end)

Workshop.GetCurrencies = public(function()
    return copy(store.currencies())
end)

Workshop.GetState = public(function(_, id)
    local row = store.is_node(name_of(id, "GetState", "a node's row name such as \"Workshop_Axe_Printed\""))
    if not row then return nil end
    return live.state(row)
end)

Workshop.GetBalance = public(function(_, currency)
    if currency == nil then
        local held = live.balances()
        if not held then return nil end
        local out = {}
        for _, known in ipairs(store.currencies()) do out[known.Id] = held[fold(known.Id)] or 0 end
        return out
    end
    name_of(currency, "GetBalance", "a currency's row name such as \"Credits\"")
    local row = store.has("currency", currency)
    if not row then
        error(("the game has no currency named '%s'.%s"):format(currency, suggest.phrase(currency, store.names("currency"))), 0)
    end
    return live.balance(row)
end)

Workshop.Check = public(function(_, described, options)
    return M.plan(described, options).problems
end)

setmetatable(Workshop, {
    __index = function(_, key)
        error(("%s is not a member of game.Workshop.%s"):format(tostring(key), suggest.phrase(tostring(key), NAMES)), 2)
    end,
    __newindex = function(_, key)
        error(("game.Workshop.%s cannot be assigned because game.Workshop is read-only"):format(tostring(key)), 2)
    end,
    __tostring = function() return "Workshop" end,
    __names = function() return NAMES end,
})

-- The writing side. world.workshop_rows hands itself over when it starts, and until then game.Workshop only reads.
local writer = nil
local WRITE_NAMES = { "Node", "Category", "AddCategory", "Define", "Reset" }
local NODE_NAMES = { "Id", "Set", "Hide", "Show", "Reset" }
local CATEGORY_NAMES = { "Id", "Add", "Arrange" }
local node_rows = setmetatable({}, { __mode = "k" })        -- a node handle -> its row name
local category_tokens = setmetatable({}, { __mode = "k" })  -- a category handle -> its row name, or what the writer keeps of a new one

-- A handle holds a name and nothing of the game. Its methods are found through `methods`, and anything else is an error.
local function handle(kind, names, methods, known, id, token)
    local made = setmetatable({}, {
        __index = function(_, key)
            if key == "Id" then return id end
            local method = methods[key]
            if method ~= nil then return method end
            error(("%s is not a member of %s.%s"):format(tostring(key), kind, suggest.phrase(tostring(key), names)), 2)
        end,
        __newindex = function(_, key)
            error(("%s cannot be assigned because %s is read-only"):format(tostring(key), kind), 2)
        end,
        __tostring = function() return id end,
        __names = function() return names end,
    })
    known[made] = token
    return made
end

local function held(known, self, call, example)
    local token = type(self) == "table" and known[self] or nil
    if token == nil then error(("%s is called with a colon, as in %s"):format(call, example), 0) end
    return token
end

local Node = {}
Node.Set = public(function(self, options)
    return writer.set(held(node_rows, self, "Set", "node:Set({ research = { Credits = 10 } })"), options)
end)
Node.Hide = public(function(self) return writer.hide(held(node_rows, self, "Hide", "node:Hide()")) end)
Node.Show = public(function(self) return writer.show(held(node_rows, self, "Show", "node:Show()")) end)
Node.Reset = public(function(self) return writer.reset_node(held(node_rows, self, "Reset", "node:Reset()")) end)

local Category = {}
Category.Add = public(function(self, node)
    return writer.add_node(held(category_tokens, self, "Add", "category:Add({ id = \"Rope\", gives = \"Meta_Cot_Printed\" })"), node)
end)
Category.Arrange = public(function(self, shape, options)
    return writer.arrange(held(category_tokens, self, "Arrange", "category:Arrange(\"ring\")"), shape, options)
end)

local Writing = {}

Writing.Node = public(function(_, id)
    local row = writer.node(name_of(id, "Node", "a node's row name such as \"Workshop_Axe_Printed\""))
    return handle("a node of the store", NODE_NAMES, Node, node_rows, row, row)
end)

Writing.Category = public(function(_, id)
    local row = writer.category(name_of(id, "Category", "a category's row name such as \"Workshop_Axes\""))
    return handle("a category of the store", CATEGORY_NAMES, Category, category_tokens, row, row)
end)

Writing.AddCategory = public(function(_, options)
    local token, row = writer.add_category(options)
    return handle("a category of the store", CATEGORY_NAMES, Category, category_tokens, row, token)
end)

Writing.Define = public(function(_, described) return writer.define(described) end)

Writing.Reset = public(function() return writer.reset() end)

-- Called by world.workshop_rows when it starts: from then on game.Workshop has the calls that change the store.
function M.writing(rows)
    writer = rows
    for _, name in ipairs(WRITE_NAMES) do
        rawset(Workshop, name, Writing[name])
        local listed = false
        for _, known in ipairs(NAMES) do listed = listed or known == name end
        if not listed then NAMES[#NAMES + 1] = name end
    end
end

function M.start()
    local game = Wax.import("engine.game")
    rawset(game.root, "Workshop", Workshop)
    local old = rawget(Wax, "workshop_live")
    if old and old.tables then old.tables:Disconnect() end
    if old and old.patched then old.patched:Disconnect() end
    local links = {}
    rawset(Wax, "workshop_live", links)
    local ok, tables = pcall(Wax.import, "data.tables")
    if ok and type(tables) == "table" and tables.api then
        local previous = scope.enter(nil)
        links.patched = tables.api.Patched:Connect(on_patched)
        links.tables = tables.api.Changed:Connect(on_tables)
        scope.leave(previous)
    else
        log:warn("game.Data is not there, so the store cannot be read: %s", tostring(tables))
    end
end

M.api = Workshop
M.live = live
M.store = store
return M
