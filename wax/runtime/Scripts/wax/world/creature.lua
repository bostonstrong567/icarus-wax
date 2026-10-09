-- What only a creature has, as plain fields on its Instance, and what the game's tables say about a variant

local Wax = ...
local easy = Wax.import("engine.easy")
local reflect = Wax.import("engine.reflect")
local instance = Wax.import("engine.instance")
local creatures = Wax.import("world.creatures")
local scope = Wax.import("core.scope")
local log = Wax.import("core.log").channel("wax.creature")

local M = {}

M.NPC = "IcarusNPCCharacter"            -- nearly every creature
M.PAWN = "IcarusPawn"                   -- the few creatures that are not characters
M.UNPROVEN = false      -- true before a creature is read also reads Epic, Behaviour and Action on an IcarusPawn: never done in the running game
M.STANCES = { [0] = "Standing", [1] = "Sitting", [2] = "Lying" }                -- EGOAPCharacterStance
M.ORDERS = { [1] = "Follow", [2] = "Wander", [3] = "Stay", [4] = "Rest" }       -- EMountMovementBehaviourState
M.COMBAT = { [1] = "Passive", [2] = "Defensive", [3] = "Aggressive" }           -- EMountCombatBehaviourState
-- the rows of D_AIRelationships that have a word of their own, by folded name
M.BEHAVIOURS = { friendlyall = "Friendly", player = "Tame", enemyplayeronly = "HostileToPlayers", enemyall = "HostileToAll" }
M.DIETS = { carnivore = "Carnivore", herbivore = "Herbivore" }

local PENDING_KILL = EInternalObjectFlags and EInternalObjectFlags.PendingKill or 0x20000000
local type, pcall, ipairs, tostring = type, pcall, ipairs, tostring
local fold = creatures.fold

local keys = {}             -- a name -> that name folded, as the game's names are compared
local function key_of(name)
    local key = keys[name]
    if not key then
        key = fold(name)
        keys[name] = key
    end
    return key
end

-- what the tables say

local TABLES = { tames = true, mounts = true, saddles = true, aisetup = true }
local RULE_LINKS = { "TamedAI.RowName", "MatureCreatureType.RowName", "JuvenileCreatureType.RowName" }
local RULE_FIELDS = { "TameDurationInSeconds", "DesiredTemperatureRange", "DesiredShelterPercentage", "DesiredNutritionPercentage",
    "RequiredTamingModifiers.RowName", "ProhibitedTamingModifiers.RowName", "TamedAI.RowName", "MatureCreatureType.RowName",
    "JuvenileCreatureType.RowName" }
local SETUP_FIELDS = { "Relationships.RowName", "Descriptors.RowName", "DeadItem.RowName", "Loot.RowName" }
local MOUNT_LINK = { "AISetup.RowName" }
local MOUNT_FIELDS = { "AISetup.RowName", "SupportedMovementStates", "SupportedCombatStates", "GrowthCurve.RowName" }
local SADDLE_FIELDS = { "SaddleTag.TagName", "SupportedMount.RowName" }

local data = nil            -- game.Data, once it was asked for
local known = {}            -- what was worked out from the tables, as plain values. Emptied when one of them changes
local warned = {}
local counts = { scans = 0, rows = 0 }

local function forget(name)
    if name == nil or TABLES[fold(name)] then known, warned = {}, {} end
end

-- game.Data, with the links that empty what is kept here. They belong to no mod, so they stay when the mod that asked first unloads.
local function game_data()
    if data then return data end
    local found = Wax.import("data.tables").api
    local previous = scope.enter(nil)
    local ok, problem = pcall(function()
        found.Changed:Connect(forget)
        Wax.import("engine.game").root.MapChanged:Connect(function() forget(nil) end)
    end)
    scope.leave(previous)
    if not ok then error(problem, 0) end
    data = found
    return found
end

local function trouble(what, problem)
    if warned[what] then return end
    warned[what] = true
    log:warn("the table %s could not be read, so creatures go without what it says: %s", what, (tostring(problem):match("^[^\r\n]*")))
end

-- A table of the game, or nil once it could not be had. It is asked for again after a map change.
local function table_of(name)
    local down = known.down
    if down and down[name] then return nil end
    local ok, found = pcall(function() return game_data():Table(name) end)
    if ok then return found end
    down = down or {}
    down[name], known.down = true, down
    trouble(name, found)
    return nil
end

-- One row as game.Data gives it, or nil. What it returns belongs to game.Data and is only read.
local function row_of(table_name, name, fields)
    local found = table_of(table_name)
    if not found then return nil end
    local ok, row = pcall(found.Row, found, name, fields)
    if ok then
        counts.rows = counts.rows + 1
        return row
    end
    trouble(table_name, row)
    return nil
end

-- Walks every row of a table once. Returns what `build` made of them, or nil when the table cannot be read.
local function scan(table_name, fields, build)
    local found = table_of(table_name)
    if not found then return nil end
    local out = {}
    local ok, problem = pcall(function()
        for _, name in ipairs(found:GetNames()) do
            local row = found:Row(name, fields)
            if row then build(out, name, row) end
        end
    end)
    counts.scans = counts.scans + 1
    if ok then return out end
    trouble(table_name, problem)
    return nil
end

-- The row a handle names, or nil for none.
local function named(link)
    local name = type(link) == "table" and link.RowName or nil
    if type(name) ~= "string" or name == "" or name == "None" then return nil end
    return name
end

local function names_of(links)
    local out = {}
    for _, link in ipairs(type(links) == "table" and links or {}) do
        local name = named(link)
        if name then out[#out + 1] = name end
    end
    return out
end

-- Kept under `key` until the tables change: false stands for "could not be worked out".
local function kept(key, make)
    local found = known[key]
    if found == nil then
        found = make() or false
        known[key] = found
    end
    return found or nil
end

-- variant -> the taming rules that name it: as the young animal, as the grown one, as the tamed one
local function rules()
    return kept("rules", function()
        return scan("Tames", RULE_LINKS, function(out, rule, row)
            local function note(link, part)
                local name = named(link)
                if not name then return end
                local entry = out[key_of(name)]
                if not entry then
                    entry = {}
                    out[key_of(name)] = entry
                end
                -- the first rule that names it counts: three rules name the chick
                if not entry[part] then entry[part] = rule end
            end
            note(row.JuvenileCreatureType, "young")
            note(row.MatureCreatureType, "grown")
            note(row.TamedAI, "tamed")
        end)
    end)
end

-- tamed variant -> the row of D_Mounts that is about it
local function mount_rows()
    return kept("mounts", function()
        return scan("Mounts", MOUNT_LINK, function(out, mount, row)
            local name = named(row.AISetup)
            if name and not out[key_of(name)] then out[key_of(name)] = mount end
        end)
    end)
end

-- row of D_Mounts -> the saddles that fit it, in the table's order
local function saddle_lists()
    return kept("saddles", function()
        return scan("Saddles", SADDLE_FIELDS, function(out, saddle, row)
            local tag = type(row.SaddleTag) == "table" and row.SaddleTag.TagName or nil
            if type(tag) ~= "string" or tag == "None" then tag = nil end
            for _, mount in ipairs(names_of(row.SupportedMount)) do
                local list = out[key_of(mount)]
                if not list then
                    list = {}
                    out[key_of(mount)] = list
                end
                list[#list + 1] = { Name = saddle, Tag = tag }
            end
        end)
    end)
end

-- What D_AISetup says about a variant: its team, what describes it, its carcass and its loot.
local function setup_of(variant)
    local setups = known.setups
    if not setups then
        setups = {}
        known.setups = setups
    end
    local key = key_of(variant)
    local found = setups[key]
    if found == nil then
        found = false
        local row = row_of("AISetup", variant, SETUP_FIELDS)
        if row then
            local team, described, diet = named(row.Relationships), names_of(row.Descriptors), nil
            for i = 1, #described do diet = diet or M.DIETS[key_of(described[i])] end
            found = { team = team, team_key = team and key_of(team) or nil, descriptors = described, diet = diet,
                      carcass = named(row.DeadItem), loot = named(row.Loot) }
        end
        setups[key] = found
    end
    return found or nil
end

local function copy(list)
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    return out
end

local function words(numbers, names)
    local out = {}
    for _, number in ipairs(type(numbers) == "table" and numbers or {}) do
        local word = names[number]
        if word then out[#out + 1] = word end
    end
    return out
end

-- The variant a rule names, when the game has it: its own tables name some that it has not.
local function existing(index, link)
    local name = named(link)
    local setup = name and index.setups[key_of(name)]
    return setup and setup.Name or nil
end

local function tame_record(index, variant)
    local found = rules()
    local rule = found and found[key_of(variant)]
    if not rule then return nil end
    local name, as = rule.young, "Young"
    if not name then name, as = rule.grown, "Grown" end
    if not name then name, as = rule.tamed, "Tamed" end
    local row = row_of("Tames", name, RULE_FIELDS)
    if not row then return nil end
    local range = row.DesiredTemperatureRange
    return {
        Rule = name, As = as, Seconds = row.TameDurationInSeconds, Nutrition = row.DesiredNutritionPercentage,
        Shelter = row.DesiredShelterPercentage, Temperature = type(range) == "table" and { Min = range.X, Max = range.Y } or nil,
        Tamed = existing(index, row.TamedAI), Young = existing(index, row.JuvenileCreatureType),
        Grown = existing(index, row.MatureCreatureType),
        Required = names_of(row.RequiredTamingModifiers), Prohibited = names_of(row.ProhibitedTamingModifiers),
    }
end

local function mount_record(variant)
    local rows = mount_rows()
    local name = rows and rows[key_of(variant)]
    if not name then return nil end
    local row = row_of("Mounts", name, MOUNT_FIELDS)
    if not row then return nil end
    local lists, saddles = saddle_lists(), nil
    if lists then
        saddles = {}
        for i, saddle in ipairs(lists[key_of(name)] or {}) do saddles[i] = { Name = saddle.Name, Tag = saddle.Tag } end
    end
    return { Name = name, Variant = variant, Orders = words(row.SupportedMovementStates, M.ORDERS),
             Combat = words(row.SupportedCombatStates, M.COMBAT), Saddles = saddles, Growth = named(row.GrowthCurve) }
end

-- What the tables say about one variant of a kind, as a new plain table. `kind` is a record of world.creatures.
function M.info(kind, variant)
    local out = { Kind = kind.Name, DisplayName = kind.DisplayName, Tag = kind.Tag, Variants = copy(kind.Variants) }
    if not variant then return out end
    out.Variant = variant
    local index = creatures.kinds()
    local setup = setup_of(variant)
    if setup then
        out.Team, out.Diet, out.Descriptors, out.Carcass, out.Loot =
            setup.team, setup.diet, copy(setup.descriptors), setup.carcass, setup.loot
    end
    local tame = tame_record(index, variant)
    out.Tame = tame
    out.Mount = mount_record(variant) or (tame and tame.Tamed and mount_record(tame.Tamed)) or nil
    return out
end

-- what a creature's own object says

local class_facts = {}      -- class name -> which of the members read here that class has

local function facts_of(self, raw)
    local name = self.ClassName
    local found = class_facts[name]
    if found then return found end
    local members = reflect.class_info(raw:GetClass()).members
    local function has(member, kind)
        local known_member = members[member]
        return known_member ~= nil and known_member.kind == "property" and known_member.type == kind
    end
    local asked = self:IsA(M.NPC) or M.UNPROVEN == true
    found = {
        epic = asked and has("EpicCreature", "StructProperty"),
        team = asked and has("AIRelationshipTableRowNew", "StructProperty"),
        controller = asked and has("Controller", "ObjectProperty"),
        target = asked and has("CurrentTarget", "ObjectProperty"),
        stance = asked and (has("CurrentStance", "EnumProperty") or has("CurrentStance", "ByteProperty")),
    }
    class_facts[name] = found
    return found
end

local function row_name(raw, member)
    local name = raw[member].RowName:ToString()
    if name == "" or name == "None" then return nil end
    return name
end

-- A row handle of the creature as the row's name. Nil for none, and for a read the game refuses.
local function handle(raw, member)
    local ok, name = pcall(row_name, raw, member)
    if ok then return name end
    return nil
end

local function kind(self, raw) return (creatures.identify(self, raw)) end

local function variant(self, raw)
    local _, found = creatures.identify(self, raw)
    return found
end

local function display_name(self, raw)
    local found = creatures.identify(self, raw)
    if not found then return nil end
    local ok, index = pcall(creatures.kinds)
    local record = ok and index.types[key_of(found)]
    return record and record.DisplayName or found
end

local function epic(self, raw)
    if not facts_of(self, raw).epic then return nil end
    return handle(raw, "EpicCreature")
end

local function behaviour(self, raw)
    if not facts_of(self, raw).team then return nil end
    local team = handle(raw, "AIRelationshipTableRowNew")
    if not team then return nil end
    local key = key_of(team)
    local word = M.BEHAVIOURS[key]
    if word then return word end
    local _, its_variant = creatures.identify(self, raw)
    local setup = its_variant and setup_of(its_variant)
    if setup and setup.team_key == key then return "Default" end
    return team
end

local action_words = {}                                 -- class name of an action -> the word for it, or false
local acting = setmetatable({}, { __mode = "k" })       -- class info of a controller -> whether it has CurrentAction

local function action_word(class_name)
    local word = action_words[class_name]
    if word == nil then
        local text = class_name:gsub("_C$", "")
        text = text:gsub("^BP_", "")
        text = text:gsub("^IcarusGOAPAction_?", "")
        word = text ~= "" and text or false
        action_words[class_name] = word
    end
    return word or nil
end

local function action(self, raw)
    if not facts_of(self, raw).controller then return nil end
    local controller = raw.Controller
    if not controller:IsValid() then return nil end
    local info = reflect.class_info(controller:GetClass())
    local able = acting[info]
    if able == nil then
        local member = info.members.CurrentAction
        able = member ~= nil and member.kind == "property" and member.type == "ObjectProperty"
        acting[info] = able
    end
    if not able then return nil end
    local doing = controller.CurrentAction
    if not doing:IsValid() then return nil end
    return action_word(doing:GetClass():GetFName():ToString())
end

local function target(self, raw)
    if not facts_of(self, raw).target then return nil end
    local found = raw.CurrentTarget
    if not found:IsValid() or found:HasAnyInternalFlags(PENDING_KILL) then return nil end
    return instance.wrap(found)
end

local function stance(self, raw)
    if not facts_of(self, raw).stance then return nil end
    local now = raw.CurrentStance
    -- UE4SS leaves a global behind for each enum it reads
    if rawget(_G, "Enum_CurrentStance") ~= nil then rawset(_G, "Enum_CurrentStance", nil) end
    return M.STANCES[now]
end

local function is_tamed(self) return self:IsA(creatures.TAMED) end

-- The taming rules that name this creature's variant, false for none, nil when that is not known.
local function rule_of(self, raw)
    local _, its_variant = creatures.identify(self, raw)
    local found = its_variant and rules()
    if not found then return nil end
    return found[key_of(its_variant)] or false
end

local function is_juvenile(self, raw)
    local rule = rule_of(self, raw)
    if rule == nil then return nil end
    return rule ~= false and rule.young ~= nil
end

local function can_be_tamed(self, raw)
    if self:IsA(creatures.TAMED) then return false end
    local rule = rule_of(self, raw)
    if rule == nil then return nil end
    return rule ~= false and (rule.young ~= nil or rule.grown ~= nil)
end

M.fields = { Kind = kind, Variant = variant, DisplayName = display_name, Epic = epic, Behaviour = behaviour, Action = action,
             Target = target, Stance = stance, IsJuvenile = is_juvenile, IsTamed = is_tamed, CanBeTamed = can_be_tamed }

-- what a mod does to a creature. Each is the game's own call, made on this machine

-- true also acts on tamed animals and IcarusPawns, spawns tamed variants and aims Attack at any actor: never tried in the game
M.ACT_UNTRIED = false
M.GOAP = "IcarusNPCGOAPCharacter"       -- the animals that plan what they do
M.SPAWNER, M.MOODS = "IcarusAIBlueprintFunctionLibrary", "BP_AIFunctionLibrary_C"
M.NAV = "/Script/NavigationSystem.Default__NavigationSystemV1"
M.TEAMS_TABLE, M.ZONES_TABLE = "AIRelationships", "AISpawnZones"
M.TEAMS = { friendly = "FriendlyAll", tame = "Player", hostiletoplayers = "EnemyPlayerOnly", hostiletoall = "EnemyAll" }
M.TEAM_WORDS = { "Default", "Friendly", "Tame", "HostileToPlayers", "HostileToAll" }
M.MOST_LEVEL = 120      -- the highest level a zone of the game gives a creature
M.REACH = { X = 500, Y = 500, Z = 100000 }      -- how far from a place the ground is looked for
M.LIFT = 150            -- a creature is put this far above the ground the game found
M.AHEAD = 600           -- with no place given, this far in front of the character
M.SETTLE = 2            -- the most seconds Spawn waits for the game to finish a creature
M.GONE = 0.1            -- the life span the game is given for what Remove takes away
M.HOLD = 0.4            -- seconds a death seen by looking waits for the game's word of who did it

local suggest = Wax.import("core.suggest")
local sched = Wax.import("core.sched")
local floor, huge, rad, sin, cos, atan = math.floor, math.huge, math.rad, math.sin, math.cos, math.atan
local rawequal, error, pairs, rawget, rawset = rawequal, error, pairs, rawget, rawset
local acts = { spawned = 0 }

TABLES.airelationships = true

local function first_line(problem) return (tostring(problem):match("^[^\r\n]*") or "") end
local function clean(problem) return (tostring(problem):gsub("^[^\n]-%.lua:%d+: ", "", 1)) end
local function characters() return Wax.import("world.character") end
local function finite(value) return type(value) == "number" and value == value and value ~= huge and value ~= -huge end
local perf_now = Wax.import("core.perf").now

local function once(names)
    local seen, out = {}, {}
    for i = 1, #names do
        local key = key_of(names[i])
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = names[i]
        end
    end
    return out
end

-- One of the game's function libraries, found again for each call and never kept.
local function library(name)
    local ok, found = pcall(function() return Wax.import("engine.game").root:Library(name).Raw end)
    if ok and found ~= nil and found:IsValid() then return found end
    error(("the game's %s is not loaded right now, so this cannot be done"):format(name), 0)
end

local abilities = setmetatable({}, { __mode = "k" })    -- class info -> which of the members used here that class has

local function able(raw)
    local info = reflect.class_info(raw:GetClass())
    local found = abilities[info]
    if found then return found end
    local members = info.members
    local function has(member, kind, type_name)
        local known_member = members[member]
        return known_member ~= nil and known_member.kind == kind and (type_name == nil or known_member.type == type_name)
    end
    found = {
        freeze = has("FreezeNPC", "function") and has("UnfreezeNPC", "function") and has("bIsNPCFrozen", "property", "BoolProperty"),
        team = has("AIRelationshipTableRowNew", "property", "StructProperty"),
        level = has("CurrentLevel", "property", "IntProperty"),
        thinks = has("Motivations", "property", "ArrayProperty"),
    }
    abilities[info] = found
    return found
end

-- Raises unless the game's calls were tried on this sort of creature: a wild animal that is an IcarusNPCCharacter.
local function tried(self, what)
    if M.ACT_UNTRIED == true then return end
    if not self:IsA(M.NPC) then
        error(("%s is not in this version of Wax for a %s: the game's call was only made on creatures that are an IcarusNPCCharacter so far")
            :format(what, self.ClassName), 0)
    end
    if self:IsA(creatures.TAMED) then
        error(("%s is not in this version of Wax for a tamed animal: the game's call was only made on wild ones so far"):format(what), 0)
    end
end

local function living(self, cannot)
    if self.Alive == false then error("this creature is dead, so " .. cannot, 0) end
end

local function is_frozen(_, raw)
    if not able(raw).freeze then return nil end
    return raw.bIsNPCFrozen == true
end

local function base_level(ai, raw, level) return ai:SetBaseLevel(raw, level) end
local function freeze_npc(raw) return raw:FreezeNPC() end
local function unfreeze_npc(raw) return raw:UnfreezeNPC() end
local function end_soon(raw) raw:SetLifeSpan(M.GONE) end
local function write_team(raw, row) raw.AIRelationshipTableRowNew = { RowName = FName(row) } end
local function make_angry(moods, raw, target) moods:MakeNPCAngry(raw, target, FName("TargetActor"), raw) end

local function set_level(self, raw, level)
    local character = characters()
    local wanted = character.whole(level, "SetLevel")
    if wanted < 1 or wanted > M.MOST_LEVEL then
        error(("SetLevel expects a level from 1 to %d, the highest the game's own zones give, got %d"):format(M.MOST_LEVEL, wanted), 0)
    end
    tried(self, "SetLevel")
    if not able(raw).level then error(("this %s keeps no level of the kind the game sets"):format(self.ClassName), 0) end
    living(self, "its level cannot be set")
    local changed = character.ask("setting a creature's level", base_level, library(M.SPAWNER), raw, wanted)
    local stats = Wax.modules["world.stats"]
    if type(stats) == "table" and type(stats.forget) == "function" then stats.forget(self) end
    return changed == true
end

local function frozen_or_not(self, raw, what, cannot)
    tried(self, what)
    if not able(raw).freeze then
        error(("this %s cannot be frozen: the game gives its class no way to"):format(self.ClassName), 0)
    end
    living(self, cannot)
    return raw.bIsNPCFrozen == true
end

local function freeze(self, raw)
    local character = characters()
    if frozen_or_not(self, raw, "Freeze", "it cannot be frozen") then return false end
    character.ask("freezing a creature", freeze_npc, raw)
    return raw.bIsNPCFrozen == true
end

local function unfreeze(self, raw)
    local character = characters()
    if not frozen_or_not(self, raw, "Unfreeze", "there is nothing to unfreeze") then return false end
    character.ask("unfreezing a creature", unfreeze_npc, raw)
    return raw.bIsNPCFrozen ~= true
end

local function remove(self, raw)
    local character = characters()
    tried(self, "Remove")
    character.ask("removing a creature", end_soon, raw)
    return true
end

local function teams()
    return kept("teams", function()
        local found = table_of(M.TEAMS_TABLE)
        if not found then return nil end
        local ok, names = pcall(found.GetNames, found)
        if not ok then
            trouble(M.TEAMS_TABLE, names)
            return nil
        end
        local out = {}
        for _, name in ipairs(names) do out[key_of(name)] = name end
        return out
    end)
end

-- The row of D_AIRelationships a word or a team's own name stands for. `start` is the team "Default" means, when there is one.
local function team_for(value, start)
    if type(value) ~= "string" or value == "" then
        error("a behaviour is a word such as \"Friendly\", or a team of the game such as \"EnemyAll\", got " .. type(value), 0)
    end
    local key = key_of(value)
    if key == "default" then
        if not start then
            error("the game's tables do not say which team this creature starts on, so \"Default\" cannot be set. "
                .. "Name the team itself: a row of D_AIRelationships", 0)
        end
        key = key_of(start)
    elseif M.TEAMS[key] then
        key = key_of(M.TEAMS[key])
    end
    local known_teams = teams()
    if not known_teams then
        error(("the game's table of teams cannot be read right now, so the behaviour '%s' cannot be checked"):format(value), 0)
    end
    local row = known_teams[key]
    if row then return row end
    local names = {}
    for i = 1, #M.TEAM_WORDS do names[i] = M.TEAM_WORDS[i] end
    for _, name in pairs(known_teams) do names[#names + 1] = name end
    error(("'%s' is not a behaviour or a team of the game.%s"):format(value, suggest.phrase(value, names)), 0)
end

local function set_behaviour(self, raw, value)
    local character = characters()
    tried(self, "Assigning Behaviour")
    if not able(raw).team then
        error(("this %s is on no team the game lets be changed"):format(self.ClassName), 0)
    end
    local start = nil
    if type(value) == "string" and key_of(value) == "default" then
        local _, its_variant = creatures.identify(self, raw)
        local setup = its_variant and setup_of(its_variant)
        start = setup and setup.team or nil
    end
    character.ask("changing a creature's behaviour", write_team, raw, team_for(value, start))
end

local function aggression_of(controller)
    local list = controller.Motivations
    for index = 1, #list do
        local motivation = list[index]
        if motivation:IsValid() and key_of(motivation.CachedRowHandle.RowName:ToString()) == "aggression" then return motivation end
    end
    return nil
end

local function attack(self, raw, target)
    local character = characters()
    tried(self, "Attack")
    local who = target
    if rawequal(target, character.me) then
        who = character.current()
        if not who then error("there is no character right now, so game.Me cannot be attacked. game.Me.Exists says when there is one", 0) end
    end
    if not instance.is_instance(who) then
        error("Attack expects whom to attack: a player's character or game.Me, got " .. type(target), 0)
    end
    if not who:IsValid() then error("Attack was given a target that no longer exists", 0) end
    if rawequal(who, self) then error("a creature cannot be made to attack itself", 0) end
    if M.ACT_UNTRIED ~= true and not who:IsA(character.PLAYER) then
        error(("Attack takes a player's character as its target in this version of Wax, and a %s is not one: "
            .. "the game's call was only made with a player's so far"):format(who.ClassName), 0)
    end
    if not who:IsA("Actor") then error(("Attack expects an actor to attack, and a %s is not one"):format(who.ClassName), 0) end
    if not self:IsA(M.GOAP) then
        error(("this %s cannot be made to attack: the game's call is for the animals that plan what they do, and it is not one")
            :format(self.ClassName), 0)
    end
    living(self, "it cannot be made to attack")
    local controller = raw.Controller
    if not controller:IsValid() or not able(controller).thinks then
        error("nothing decides what this creature does right now, so it cannot be made to attack", 0)
    end
    local anger = aggression_of(controller)
    if not anger then
        error(("a %s cannot be made to attack: the game gives its kind no aggression to raise. Attack works on a hunter such as a wolf")
            :format(creatures.identify(self, raw) or self.ClassName), 0)
    end
    character.ask("making a creature attack", make_angry, library(M.MOODS), raw, who.Raw)
    local now = anger.CurrentValue
    return type(now) == "number" and now > 0
end

M.act_fields = { IsFrozen = is_frozen }
M.act_setters = { Behaviour = set_behaviour }
M.act_methods = { SetLevel = set_level, Freeze = freeze, Unfreeze = unfreeze, Remove = remove, Attack = attack }

-- game.Creatures:Spawn

local SPAWN_OPTIONS = { "level", "variant", "facing", "behaviour", "keep" }
local IS_SPAWN_OPTION = { level = true, variant = true, facing = true, behaviour = true, keep = true }
local NOT_YET = { tamed = true, name = true, saddle = true, epic = true, count = true }
local ZONE_FIELDS = { "MedianLevel" }

local function variant_for(kind, wanted)
    local ok, index = pcall(creatures.kinds)
    if not ok then error(clean(index), 0) end
    local key = key_of(kind)
    local setup, record = index.setups[key], index.types[key] or index.shown[key]
    if wanted ~= nil then
        if type(wanted) ~= "string" then error("the option variant of Spawn is a name such as \"Snow_Wolf\", got " .. type(wanted), 0) end
        local asked = index.setups[key_of(wanted)]
        if not asked then
            error(("'%s' is not a variant of a creature.%s"):format(wanted, suggest.phrase(wanted, record and record.Variants or once(index.names))), 0)
        end
        if (record and asked.kind == record) or setup == asked then return asked.Name end
        if setup then
            error(("Spawn was asked for %s and for the variant %s. Give one of them"):format(setup.Name, asked.Name), 0)
        end
        if record then
            error(("%s is not a variant of %s. Its variants are %s"):format(asked.Name, record.Name, table.concat(record.Variants, ", ")), 0)
        end
        error(("'%s' is not a creature kind.%s"):format(kind, suggest.phrase(kind, once(index.names))), 0)
    end
    if setup then return setup.Name end
    if not record then error(("'%s' is not a creature kind.%s"):format(kind, suggest.phrase(kind, once(index.names))), 0) end
    if #record.Variants == 1 then return record.Variants[1] end
    if #record.Variants == 0 then error(("the game's tables name no variant of %s to spawn"):format(record.Name), 0) end
    error(("%s comes in several variants: %s. Name one of them, as the kind or with the option variant")
        :format(record.Name, table.concat(record.Variants, ", ")), 0)
end

local function wild_variant(variant)
    if M.ACT_UNTRIED == true then return end
    local key, found, mounts = key_of(variant), rules(), mount_rows()
    if (mounts and mounts[key]) or (found and found[key] and found[key].tamed) then
        error(("%s is a tamed animal, and spawning one is not in this version of Wax: the game's call was only made for wild animals so far")
            :format(variant), 0)
    end
end

local function wanted_place(place, me, character)
    if place == nil then
        local x, y, z = character.place(me.Raw)
        local yaw = rad(me.Rotation.Yaw)
        return { X = x + cos(yaw) * M.AHEAD, Y = y + sin(yaw) * M.AHEAD, Z = z + 100 }, true
    end
    if rawequal(place, character.me) then place = me end
    if instance.is_instance(place) then
        if not place:IsValid() then error("Spawn was given a place that no longer exists", 0) end
        if not place:IsA("Actor") then
            error(("Spawn expects an actor as its place, and a %s is not one. Give the actor it belongs to"):format(place.ClassName), 0)
        end
        local x, y, z = character.place(place.Raw)
        return { X = x, Y = y, Z = z }, false
    end
    if type(place) == "table" and finite(place.X) and finite(place.Y) and finite(place.Z) then
        return { X = place.X, Y = place.Y, Z = place.Z }, false
    end
    error("Spawn expects a place as its second value: a position such as { X = 0, Y = 0, Z = 0 }, an actor or game.Me, got " .. type(place), 0)
end

local function ground(context, wanted)
    local nav = StaticFindObject(M.NAV)
    if not nav:IsValid() then error("the game's navigation is not there", 0) end
    local found = {}
    local hit = nav:K2_ProjectPointToNavigation(context, wanted, found, nil, nil, { X = M.REACH.X, Y = M.REACH.Y, Z = M.REACH.Z })
    if hit ~= true or not (finite(found.X) and finite(found.Y) and finite(found.Z)) then return nil end
    return { X = found.X, Y = found.Y, Z = found.Z + M.LIFT }
end

-- The middle level the game's data gives creatures in the zone a place lies in. 1 when the game names no zone there.
local function zone_level(context, at)
    local ok, level = pcall(function()
        local zone = {}
        library(M.MOODS):GetZoneTextureSample(context, at, context, zone)
        local name = zone.RowName and zone.RowName:ToString()
        if not name or name == "" or name == "None" then return nil end
        local zones = table_of(M.ZONES_TABLE)
        local row = zones and zones:Has(name) and row_of(M.ZONES_TABLE, name, ZONE_FIELDS)
        return row and row.MedianLevel
    end)
    if ok and finite(level) and level >= 1 then return level <= M.MOST_LEVEL and floor(level) or M.MOST_LEVEL end
    return 1
end

local function spawn_ai(ai, context, row, transform, level)
    return ai:SpawnNewAI(context, { RowName = FName(row), DataTableName = FName("D_AISetup") },
        { RowName = FName("None"), DataTableName = FName("D_EpicCreatures") }, transform, level, 2, nil, nil, -1)
end

-- The level the game has given it by now. Nil once it left the world, false when its class keeps none.
local function level_now(made)
    local ok, now = pcall(function()
        local raw = made.Raw
        return able(raw).level and raw.CurrentLevel or false
    end)
    if not ok then return nil end
    return now
end

local function give_team(made, team)
    local ok, problem = pcall(function() write_team(made.Raw, team) end)
    if not ok then log:warn("a spawned creature could not be put on the team %s: %s", team, first_line(problem)) end
end

-- Spawn(kind, place, options). Inside a task it answers once the game has given the creature its level, else at once.
function M.spawn(kind, place, options)
    local character = characters()
    if type(kind) ~= "string" or kind == "" then
        error("Spawn expects the kind of creature as its first value, such as \"Deer\" or \"Conifer_Wolf\", got " .. type(kind), 0)
    end
    if options == nil and type(place) == "table" and not instance.is_instance(place) and not rawequal(place, character.me)
        and rawget(place, "X") == nil and rawget(place, "Y") == nil and rawget(place, "Z") == nil then
        place, options = nil, place
    end
    options = options or {}
    if type(options) ~= "table" then error("the options of Spawn are a table such as { level = 10 }, got " .. type(options), 0) end
    for key in pairs(options) do
        if NOT_YET[key] then
            error(("the option '%s' of Spawn is not in this version of Wax: what the game does with it has not been tried"):format(key), 0)
        end
        if not IS_SPAWN_OPTION[key] then
            error(("Spawn has no option '%s'.%s"):format(tostring(key), suggest.phrase(tostring(key), SPAWN_OPTIONS)), 0)
        end
    end
    local level = nil
    if options.level ~= nil then
        level = character.whole(options.level, "the option level of Spawn")
        if level < 1 or level > M.MOST_LEVEL then
            error(("the option level of Spawn is a level from 1 to %d, the highest the game's own zones give, got %d"):format(M.MOST_LEVEL, level), 0)
        end
    end
    local facing = options.facing
    if facing ~= nil and (type(facing) ~= "table" or not finite(facing.Yaw)) then
        error("the option facing of Spawn is the way the creature looks, such as { Yaw = 90 }", 0)
    end
    if options.keep ~= nil and type(options.keep) ~= "boolean" then
        error("the option keep of Spawn is true or false, got " .. type(options.keep), 0)
    end
    local variant = variant_for(kind, options.variant)
    wild_variant(variant)
    local team = options.behaviour ~= nil and team_for(options.behaviour, (setup_of(variant) or {}).team) or nil
    local me = character.current()
    if not me then
        error("there is no character right now, and the game needs one to spawn a creature beside. game.Me.Exists says when there is one", 0)
    end
    local context = me.Raw
    local wanted, ahead = wanted_place(place, me, character)
    local began = perf_now()
    local at = character.ask("finding the ground for a creature", ground, context, wanted)
    if not at then
        error("the game found no ground a creature can walk on within 5 metres of that place, so nothing was spawned", 0)
    end
    level = level or zone_level(context, at)
    local half = 0
    if facing then
        half = rad(facing.Yaw) / 2
    elseif ahead then
        local x, y = character.place(context)
        half = atan(y - at.Y, x - at.X) / 2
    end
    local transform = { Rotation = { X = 0, Y = 0, Z = sin(half), W = cos(half) }, Translation = at, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local spawned = character.ask("spawning a creature", spawn_ai, library(M.SPAWNER), context, variant, transform, level)
    if spawned == nil or not spawned:IsValid() then
        error(("the game spawned nothing for %s. Its row of D_AISetup may name a class this version of the game does not have"):format(variant), 0)
    end
    local made = instance.wrap(spawned)
    acts.spawned, acts.spawn_us = acts.spawned + 1, floor((perf_now() - began) * 1e6 + 0.5)
    if options.keep == false then
        scope.own(function()
            if made:IsValid() then pcall(function() end_soon(made.Raw) end) end
        end)
    end
    local task = sched.task
    if not Wax.import("core.co").isyieldable() then
        if team then
            task.spawn(function()
                task.wait()
                task.wait()
                if made:IsValid() then give_team(made, team) end
            end)
        end
        return made
    end
    local started = sched.clock()
    task.wait()
    while true do
        local now = level_now(made)
        if now == nil then return nil, "the creature left the world before the game had finished making it" end
        if now == false or now == level or sched.clock() - started >= M.SETTLE then break end
        task.wait()
    end
    if team then give_team(made, team) end
    return made
end

-- what the game tells of creatures: damage, and who ended one

local Signal = sched.Signal
local plain_disconnect = nil

local function no_mod(fn, ...)
    local previous = scope.enter(nil)
    local ok, made = pcall(fn, ...)
    scope.leave(previous)
    if not ok then error(made, 0) end
    return made
end

-- Makes a signal say when its first handler comes and when its last one leaves. first may raise: nothing is connected then.
local function counted(signal, first, last)
    signal.Connect = function(self, fn)
        if type(fn) ~= "function" then error("Connect expects a function, got " .. type(fn), 2) end
        if self.count == 0 then
            local ok, problem = pcall(first)
            if not ok then error(clean(problem), 2) end
        end
        local connection = Signal.Connect(self, fn)
        plain_disconnect = plain_disconnect or connection.Disconnect
        connection.Disconnect = function(this)
            if not this.Connected then return end
            plain_disconnect(this)
            if self.count == 0 then last() end
        end
        return connection
    end
    return signal
end

local function damaged_signal()
    local damaged, link = Signal.new("creatures.Damaged"), nil
    return counted(damaged, function()
        local events = characters().events
        if type(events) ~= "table" or not events.Damaged then
            error("damage cannot be told: what the game tells of characters by itself is switched off or did not start", 0)
        end
        link = no_mod(events.Damaged.Connect, events.Damaged, function(who, amount, info)
            if damaged.count > 0 and who:IsA(M.NPC) then damaged:Fire(who, amount, info) end
        end)
    end, function()
        if link then link:Disconnect() end
        link = nil
    end)
end

local function death_facts(who)
    local entry = creatures.tracked:entry_of(who)
    if entry then return { Kind = entry.kind, Variant = entry.variant, ClassName = entry.class_name, Name = entry.name }, entry end
    local info = { ClassName = who.ClassName }
    pcall(function()
        info.Name = who.Name
        info.Kind, info.Variant = creatures.identify(who, who.Raw)
    end)
    return info, nil
end

-- Adds the game's own word of who ended a creature to the deaths that looking sees, and tells each death once.
local function richer_deaths(died)
    local before = rawget(died, "told_by")
    if type(before) == "table" and before.unlink then pcall(before.unlink) end
    local state = { link = nil, held = {}, told = setmetatable({}, { __mode = "k" }), waiting = false }
    rawset(died, "told_by", state)

    local function flush()
        while next(state.held) ~= nil do
            sched.task.wait(M.HOLD / 2)
            local now, due = sched.clock(), {}
            for who, waits in pairs(state.held) do
                if now - waits.at >= M.HOLD then due[#due + 1] = who end
            end
            for i = 1, #due do
                local who = due[i]
                local waits = state.held[who]
                state.held[who] = nil
                if waits and not state.told[who] then
                    state.told[who] = true
                    Signal.Fire(died, who, waits.info)
                end
            end
        end
        state.waiting = false
    end

    died.Fire = function(self, who, info)
        if state.told[who] then return end
        if not state.link or not who:IsA(M.NPC) then
            state.told[who] = true
            return Signal.Fire(self, who, info)
        end
        state.held[who] = { info = info, at = sched.clock() }
        if not state.waiting then
            state.waiting = true
            no_mod(sched.task.spawn, flush)
        end
    end

    function state.unlink()
        if state.link then state.link:Disconnect() end
        if state.added then state.added:Disconnect() end
        state.link, state.added, state.held = nil, nil, {}
    end

    -- Looking tells of a death only after it saw the creature alive, so the listed ones are looked at when the first handler comes.
    local function seen_alive(entry)
        if entry.dead ~= nil or not entry.has_state or entry.destroyed then return end
        local ok, alive = pcall(function() return entry.instance.Alive end)
        if ok and alive ~= nil then entry.dead = not alive end
    end

    local function watch_list()
        local set = creatures.tracked
        if state.added or not set.tracking then return end
        for _, entry in pairs(set.entries) do seen_alive(entry) end
        state.added = no_mod(set.Added.Connect, set.Added, function(who)
            local entry = set:entry_of(who)
            if entry and entry.dead == nil then entry.dead = false end
        end)
    end

    local function on_death(who, death)
        if died.count == 0 then return state.unlink() end
        if state.told[who] or not who:IsA(M.NPC) then return end
        local waits = state.held[who]
        state.held[who] = nil
        state.told[who] = true
        local info, entry = nil, nil
        if waits then info = waits.info else info, entry = death_facts(who) end
        if entry then entry.dead = true end
        info.Killer, info.Instigator, info.Damage = death.Killer, death.Instigator, death.Damage
        Signal.Fire(died, who, info)
    end

    local function link()
        pcall(watch_list)
        if state.link then return end
        local ok, events = pcall(function() return characters().events end)
        if not ok or type(events) ~= "table" or not events.Died then return end
        local linked, made = pcall(no_mod, events.Died.Connect, events.Died, on_death)
        if linked then state.link = made end
    end

    -- a handler connected under an older copy of this file lets go through whichever copy listens now
    counted(died, link, function()
        local current = rawget(died, "told_by")
        if type(current) == "table" and current.unlink then current.unlink() end
    end)
    if died.count > 0 then link() end
    return state
end

local function acts_start()
    easy.class({ M.NPC, M.PAWN }, { fields = M.act_fields, setters = M.act_setters, methods = M.act_methods }, "creature.acts")
    local api = creatures.api
    rawset(api, "Spawn", function(self, kind, place, options)
        if not rawequal(self, api) then error("call Spawn with a colon: game.Creatures:Spawn(\"Deer\")", 2) end
        local ok, made, why = pcall(M.spawn, kind, place, options)
        if not ok then error(clean(made), 2) end
        return made, why
    end)
    rawset(api, "Damaged", damaged_signal())
    local meta = getmetatable(api)
    local names = meta and meta.__names and meta.__names()
    if type(names) == "table" then
        local have = {}
        for _, name in ipairs(names) do have[name] = true end
        for _, name in ipairs({ "Spawn", "Damaged" }) do
            if not have[name] then names[#names + 1] = name end
        end
    end
    if creatures.died then acts.deaths = richer_deaths(creatures.died) end
end

function M.act_stats()
    local deaths, held = acts.deaths, 0
    for _ in pairs(deaths and deaths.held or {}) do held = held + 1 end
    return { spawned = acts.spawned, spawn_us = acts.spawn_us, deaths_linked = deaths ~= nil and deaths.link ~= nil, deaths_held = held }
end

-- Forgets what was worked out, from the tables and about classes.
function M.flush()
    forget(nil)
    class_facts = {}
end

function M.start()
    easy.class({ M.NPC, M.PAWN }, { fields = M.fields }, "creature")
    local acts_ok, acts_problem = pcall(acts_start)
    if not acts_ok then log:warn("what the host does to a creature could not be set up: %s", first_line(acts_problem)) end
end

function M.stats()
    local classes, variants, down = 0, 0, {}
    for _ in pairs(class_facts) do classes = classes + 1 end
    for _ in pairs(known.setups or {}) do variants = variants + 1 end
    for name in pairs(known.down or {}) do down[#down + 1] = name end
    table.sort(down)
    -- rules, mounts, saddles: true once that table was walked, false when it could not be read, nil while nobody asked
    local function walked(key)
        if known[key] == nil then return nil end
        return known[key] ~= false
    end
    return { classes = classes, variants = variants, scans = counts.scans, rows = counts.rows, linked = data ~= nil,
             rules = walked("rules"), mounts = walked("mounts"), saddles = walked("saddles"), down = down }
end

return M
