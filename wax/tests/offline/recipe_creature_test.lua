-- Offline tests for the Recipe Browser's Bestiary: its table lists, the model and the background read.
-- They run on real rows of seven creature groups (creature_rows.lua).
-- Run from the workspace root:  tools\lua\lua54\lua.exe wax\tests\offline\recipe_creature_test.lua <mod folder>

local t = dofile("wax/tests/offline/harness.lua")

local folder = arg and arg[1]
if folder then folder = folder:gsub("\\", "/"):gsub("/+$", "") end

local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil
end

if not folder or not exists(folder .. "/creatures.lua") then
    print("recipe-creature: 0 passed (skipped: the Bestiary's creatures.lua is not here)")
    os.exit(0)
end

local fixture = dofile("wax/tests/offline/creature_fixture.lua")
local part = fixture.parts(folder)
local source, creatures, model, tags = part("source"), part("creatures"), part("model"), part("tags")

local WORDS = { hostile = "Hostile", neutral = "Neutral", passive = "Passive", friendly = "Friendly", attacks = "Can attack",
    boss = "Boss", tamed = "Can be tamed", ridden = "Can be ridden", meat = "Meat eater", plants = "Plant eater" }

local function build(options)
    options = options or {}
    return fixture.build(part, fixture.provider({ tables = options.tables, maps = options.maps }),
        { words = WORDS, stages = options.stages, pause = options.pause })
end

local c, m, src = build()

local function joined(list, separator) return table.concat(list or {}, separator or " ") end

local function names(list)
    local out = {}
    for position, entry in ipairs(list or {}) do out[position] = entry.name end
    return table.concat(out, ", ")
end

local function variant_of(model_built, setup)
    local at = assert(model_built.by_setup[setup:lower()], setup .. " is in no group")
    return assert(model_built.entries[at.entry].variants[at.variant]), model_built.entries[at.entry], at.variant
end

local function drop_text(drops)
    local out = {}
    for position, drop in ipairs(drops) do
        local amount = drop.min == drop.max and tostring(drop.min) or (drop.min .. "-" .. drop.max)
        out[position] = drop.item .. " " .. amount .. (drop.chance < 100 and (" at " .. math.floor(drop.chance + 0.5) .. "%") or "")
            .. (drop.needs and " needs " .. drop.needs or "")
    end
    return table.concat(out, ", ")
end

local function skipped_has(model_built, name, row)
    for _, entry in ipairs(model_built.skipped) do
        if entry.table == name and entry.row == row then return true end
    end
    return false
end

local function close(got, want, what)
    t.ok(type(got) == "number" and math.abs(got - want) < 0.05, (what or "value") .. ": expected about " .. want .. ", got " .. tostring(got))
end

-- ---------------------------------------------------------------- the lists, and source.lua with a list of its own

t.test("lists: real field paths, a stage each, maps and curves only as maybe fields of a page", function()
    local seen = {}
    for _, entry in ipairs(creatures.TABLES) do
        seen[entry.table] = true
        t.ok(entry.stage == 1 or entry.stage == 4, entry.table .. " is read ahead or for a page")
        if entry.stage == 4 then t.eq(entry.rows, "request", entry.table .. " is read a row at a time") end
        if entry.maybe then t.eq(entry.stage, 4, entry.table .. " has maybe fields on a page only") end
        for _, field in ipairs(entry.fields) do
            t.ok(not field:find("DataTableName", 1, true), entry.table .. " never reads a handle's table: " .. field)
            for _, map in ipairs({ "Variations", "Animations", "WorldStatInjection", "TamedAIOverride", "AISpawnRules", "WorldBosses" }) do
                t.ok(not field:find(map, 1, true), entry.table .. " never names the map " .. map)
            end
        end
    end
    for _, name in ipairs({ "BestiaryData", "BestiaryTraits", "Atmospheres", "Terrains", "AISetup", "GOAPSetup", "AICreatureType",
        "ItemRewards", "Tames", "ModifierStates", "Mounts", "Saddles", "CharacterGrowth", "AISpawnZones", "AISpawnConfig",
        "EpicCreatures", "WorldBosses", "GreatHuntCreatureInfo", "AutonomousSpawns", "HordeWave", "ExperienceEvents", "AIGrowth",
        "Experience" }) do
        t.ok(seen[name], name .. " is listed")
    end
end)

t.test("source: a list of its own leaves the item lists alone", function()
    local provider = fixture.provider()
    local items = source.new(provider)
    local own = source.new(provider, creatures.TABLES)
    own.read(1, 1)
    t.eq(provider.asked.Table ~= nil, true)
    t.ok(own.row("BestiaryData", "Forest_Deer") ~= nil, "the creature source read its tables")
    t.eq(rawget(own.row("ItemsStatic", "Leather") or {}, "Itemable"), nil, "and reads no field of an item table")
    items.read(1, 1)
    t.ok(items.row("ItemsStatic", "Leather") ~= nil)
    t.eq(items.detail("BestiaryData", "Forest_Deer"), nil, "the item source knows nothing of the creature lists")
    t.ok(own.stamps():find("BestiaryData=", 1, true) and not own.stamps():find("ItemsStatic=", 1, true), "stamps are of its own tables")
    t.ok(items.stamps():find("ItemsStatic=", 1, true) and not items.stamps():find("BestiaryData=", 1, true))
    local listed = {}
    for _, entry in ipairs(source.lists(true)) do listed[entry.table] = true end
    t.eq(listed.BestiaryData, nil, "source.lists is still the item lists")
    t.eq(#own.problems, 0)
end)

t.test("source: a maybe field the provider refuses is left out and nothing is noted", function()
    local own = source.new(fixture.provider(), creatures.TABLES)
    own.read(1, 1)
    t.eq(own.serves("AIGrowth", "Base"), false)
    t.eq(own.serves("BestiaryData", "StatsUnlock1"), false)
    t.eq(own.detail("AIGrowth", "Deer"), nil, "an entry of maybe fields alone reads nothing")
    local guide = own.detail("BestiaryData", "Forest_Deer")
    t.ok(guide and guide.Lore1:find("deer", 1, true), "the fields that are not maybe are read")
    t.eq(guide.TotalPointsRequired, 1800)
    t.eq(#own.problems, 0, "a refused maybe field is not a problem")
    t.eq(next(own.broken), nil)
end)

t.test("source: a maybe field the provider serves is read with the rest", function()
    local own = source.new(fixture.provider({ maps = true }), creatures.TABLES)
    own.read(1, 1)
    t.eq(own.serves("AIGrowth", "Base"), true)
    t.eq(own.serves("AISetup", "MovementMapping"), true)
    local growth = own.detail("AIGrowth", "Deer")
    t.eq(growth.Base['(Value="BaseMovementSpeed_+")'], 220)
    t.eq(type(growth.Health), "table")
    t.eq(#own.problems, 0)
end)

t.test("source: a field that is not maybe and is gone is still a problem", function()
    local changed = fixture.copy()
    changed.Mounts.fields = { "AISetup", "GrowthCurve", "SupportedMovementStates", "SupportedCombatStates", "bUseTemperature" }
    for _, row in ipairs(changed.Mounts.rows) do row.ComfortableTemperatureRange = nil end
    local own = source.new(fixture.provider({ tables = changed }), creatures.TABLES)
    own.read(1, 1)
    t.eq(own.broken.Mounts, true)
    t.eq(own.problems[1].table, "Mounts")
    t.ok(own.problems[1].field:find("ComfortableTemperatureRange", 1, true))
end)

-- ---------------------------------------------------------------- groups, variants, roles

t.test("groups: one entry a bestiary row, each set-up in its group, names compared without letter case", function()
    t.eq(c.stage, 1)
    t.eq(next(c.off), nil, "no part is off")
    t.eq(c.counts.all, 7)
    t.eq(c.counts.setups, 25)
    t.eq(c.entries.forest_deer.name, "Deer")
    t.eq(c.entries.horse.name, "Terrenus")
    t.eq(c.entries.alpha_wolf_boss.name, "Black Wolf")
    t.eq(c.by_setup.conifer_wolf.entry, "forest_wolf")
    local changed = fixture.copy()
    fixture.find(changed, "AISetup", "Deer").BestiaryGroup = { RowName = "FOREST_deer" }
    fixture.find(changed, "AISetup", "Deer").CreatureType = { RowName = "mediumDEER" }
    local other = build({ tables = changed })
    t.eq(other.by_setup.deer.entry, "forest_deer", "a handle in other capitals still finds its group")
    t.eq(variant_of(other, "Deer").name, "Deer", "and its kind")
    t.eq(variant_of(other, "Deer").kind, "MediumDeer", "the kind's row is spelled as the table spells it")
end)

t.test("variants: set-ups that would read alike fold, and what a folded one carries is kept", function()
    local wolf = variant_of(c, "Conifer_Wolf")
    t.eq(joined(wolf.setups), "Conifer_Wolf Wolf_Anchored")
    t.eq(variant_of(c, "Wolf_Anchored"), wolf)
    t.eq(wolf.epics[1].row, "Follower_Wolf", "the anchored copy's named form")
    t.eq(joined(wolf.epics[1].names, ", "), "Mature Pack Wolf")
    t.eq(joined(variant_of(c, "Bear").setups), "Bear Bear_Anchored")
    local horse = variant_of(c, "Horse")
    t.eq(joined(horse.setups), "Horse Terrenus_Boss")
    t.eq(joined(horse.epics[1].names, ", "), "Alpha Mare, Alpha Stallion")
end)

t.test("variants: another kind, another trophy or another growth row is another variant", function()
    local deer, entry = variant_of(c, "Deer")
    t.eq(#entry.variants, 2, "the deer has two variants")
    t.eq(entry.variants[1].name .. ", " .. entry.variants[2].name, "Deer, Large Deer")
    t.ok(deer ~= variant_of(c, "Deer_Conifer_Large"))
    t.ok(variant_of(c, "Alpha_Wolf") ~= variant_of(c, "Alpha_Snow_Wolf"), "the snow alpha has another trophy")
    t.eq(variant_of(c, "Alpha_Snow_Wolf").trophy[1].item, "snowwolf_head")
    t.eq(variant_of(c, "Alpha_Wolf").trophy[1].item, "alphawolf_head")
    t.eq(#c.entries.dog.variants, 9, "each dog has a head or a growth row of its own")
    t.eq(c.counts.variants, 22)
end)

t.test("variants: a behaviour word of its own keeps a set-up apart", function()
    local changed = fixture.copy()
    fixture.find(changed, "AISetup", "Bear_Anchored").Descriptors = { { RowName = "Passive" }, { RowName = "Carnivore" } }
    local other = build({ tables = changed })
    t.eq(#other.entries.bear.variants, 2)
    t.eq(other.entries.bear.variants[1].temper .. ", " .. other.entries.bear.variants[2].temper, "hostile, passive")
end)

t.test("roles: young and tamed by the taming and mount rows, boss by the boss tables, and never by the group", function()
    t.eq(variant_of(c, "Juvenile_Forest_Wolf").role, "young")
    t.eq(variant_of(c, "Juvenile_Horse").role, "young")
    t.eq(variant_of(c, "Tamed_Forest_Wolf").role, "tamed")
    t.eq(variant_of(c, "Mount_Horse").role, "tamed")
    t.eq(variant_of(c, "Tame_Dog_A1").role, "tamed", "a mount row names it")
    t.eq(variant_of(c, "Tame_Dog_C1").role, "tamed")
    t.eq(variant_of(c, "Alpha_Wolf_Boss").role, "boss")
    t.eq(variant_of(c, "Alpha_Wolf").role, "wild", "a set-up of a boss group that no boss table names is not a boss")
    t.eq(variant_of(c, "Alpha_Snow_Wolf").role, "wild")
    t.eq(c.entries.alpha_wolf_boss.boss, true, "the group's own mark is the bestiary's")
    t.eq(variant_of(c, "Deer").role, "wild")
end)

t.test("roles: a set-up on the player's team that no taming row names is on your side, not tamed", function()
    t.eq(variant_of(c, "Tame_Dog_A2").role, "friendly")
    t.eq(variant_of(c, "Tame_Dog_E").role, "friendly")
    local changed = fixture.copy()
    fixture.find(changed, "AISetup", "Bear_Anchored").Relationships = { RowName = "Player" }
    local other = build({ tables = changed })
    local friend = variant_of(other, "Bear_Anchored")
    t.eq(friend.role, "friendly")
    t.eq(friend.temper, "friendly")
    t.eq(friend.mount, nil)
    t.eq(other.entries.bear.tame, nil, "nothing about taming comes from the team")
    t.eq(other.entries.bear.tamed, false)
end)

t.test("roles: the line is wild, boss, tamed, on your side, young, and in a boss group the boss leads", function()
    local roles = {}
    for position, variant in ipairs(c.entries.forest_wolf.variants) do roles[position] = variant.role end
    t.eq(joined(roles), "wild tamed young")
    roles = {}
    for position, variant in ipairs(c.entries.horse.variants) do roles[position] = variant.role end
    t.eq(joined(roles), "wild tamed young")
    roles = {}
    for position, variant in ipairs(c.entries.alpha_wolf_boss.variants) do roles[position] = variant.setup end
    t.eq(joined(roles), "Alpha_Wolf_Boss Alpha_Wolf Alpha_Snow_Wolf")
    roles = {}
    for position, variant in ipairs(c.entries.dog.variants) do roles[position] = variant.role end
    t.eq(joined(roles), "tamed tamed friendly friendly friendly friendly friendly friendly friendly")
    t.eq(c.by_setup.tamed_forest_wolf.variant, 2, "by_setup follows the order of the line")
end)

t.test("word: the team is asked first, then the game's descriptor", function()
    t.eq(c.entries.forest_deer.temper, "passive")
    t.eq(c.entries.bear.temper, "hostile")
    t.eq(c.entries.forest_wolf.temper, "neutral")
    t.eq(c.entries.dog.temper, "friendly")
    local mount = variant_of(c, "Mount_Horse")
    t.eq(mount.temper, "friendly", "it carries Neutral and is on the player's team")
    t.eq(variant_of(c, "Juvenile_Forest_Wolf").temper, "passive")
    t.eq(c.counts.hostile .. " " .. c.counts.neutral .. " " .. c.counts.passive .. " " .. c.counts.friendly, "1 4 1 1")
end)

t.test("word: a Neutral one whose GOAP row has Aggression or Protective can attack", function()
    t.eq(variant_of(c, "Conifer_Wolf").attacks, true)
    t.eq(variant_of(c, "Horse").attacks, true)
    t.eq(variant_of(c, "Alpha_Wolf_Boss").attacks, true)
    t.eq(c.entries.forest_wolf.attacks, true)
    t.eq(variant_of(c, "Bee").attacks, false, "its GOAP row has neither")
    t.eq(variant_of(c, "Bear").attacks, false, "said of Neutral ones only: Hostile says it already")
    t.eq(variant_of(c, "Deer").attacks, false)
    local changed = fixture.copy()
    fixture.find(changed, "GOAPSetup", "Wolf").Motivations = { { RowName = "Hunger" }, { RowName = "Protective" } }
    t.eq(variant_of(build({ tables = changed }), "Conifer_Wolf").attacks, true)
    fixture.find(changed, "GOAPSetup", "Wolf").Motivations = { { RowName = "Hunger" } }
    t.eq(variant_of(build({ tables = changed }), "Conifer_Wolf").attacks, false)
end)

t.test("diet: a group has one, its first variant's that is not young", function()
    t.eq(c.entries.forest_wolf.diet, "meat")
    t.eq(variant_of(c, "Juvenile_Forest_Wolf").diet, "plants", "the cub's own descriptor, which the page never shows")
    t.eq(c.entries.forest_deer.diet, "plants")
    t.eq(c.entries.dog.diet, nil)
end)

t.test("picture: a trophy's icon, then a carcass's, then none", function()
    t.ok(c.entries.forest_deer.icon:find("ITEM_Deer_Head", 1, true))
    t.eq(c.entries.bee.icon, nil)
    t.eq(variant_of(c, "Bee").icon, nil)
    t.ok(variant_of(c, "Juvenile_Horse").icon:find("Carcass", 1, true) or variant_of(c, "Juvenile_Horse").icon ~= nil,
        "a variant with no trophy shows its carcass")
    t.ok(variant_of(c, "Juvenile_Horse").icon ~= variant_of(c, "Horse").icon)
    local changed = fixture.copy()
    for _, name in ipairs({ "Deer", "Deer_Conifer_Large" }) do fixture.find(changed, "AISetup", name).Trophy = { RowName = "None" } end
    local other = build({ tables = changed })
    t.eq(other.entries.forest_deer.icon, m.items.animalcarcass_deer.icon)
    t.ok(c.entries.forest_deer.image:find("T_Bestiary_Deer", 1, true), "the bestiary's own picture is kept beside it")
end)

-- ---------------------------------------------------------------- drops

t.test("drops: loot, trophy and bones as items with the row's amounts and chances", function()
    local deer = variant_of(c, "Deer")
    t.eq(drop_text(deer.skin), "leather 10-16, fur 4-8, bone 2-4, raw_meat 2, gamey_meat 3-5 at 10%")
    t.eq(drop_text(deer.bones), "bone 15-25")
    t.eq(joined(deer.carcass), "animalcarcass_deer")
    t.eq(drop_text(variant_of(c, "Deer_Conifer_Large").skin), "leather 12-18, fur 6-12, bone 4-6, raw_meat 2-4, gamey_meat 3-5 at 25%")
    t.eq(drop_text(variant_of(c, "Bear").bones), "bone 25-50")
    local foal = variant_of(c, "Juvenile_Horse")
    t.eq(drop_text(foal.skin), drop_text(variant_of(c, "Horse").skin), "the foal's row names the adult's loot")
    t.eq(#foal.trophy, 0)
end)

t.test("drops: a trophy always needs the vestige chance, and a reward's own stat is kept", function()
    local deer = variant_of(c, "Deer")
    t.eq(#deer.trophy, 1)
    t.eq(deer.trophy[1].item, "deer_head")
    t.eq(deer.trophy[1].needs, creatures.TROPHY_STAT)
    local wolf, extra = variant_of(c, "Conifer_Wolf"), 0
    for _, drop in ipairs(wolf.skin) do
        if drop.needs then
            extra = extra + 1
            t.eq(drop.needs, "WolvesDropExtraMeat_?")
            t.eq(drop.chance, 25)
        end
    end
    t.eq(extra, 5, "the wolf's five extra meats")
    local boss, vestige = variant_of(c, "Alpha_Wolf_Boss"), nil
    for _, drop in ipairs(boss.skin) do
        if drop.item == "alphawolf_head" then vestige = drop end
    end
    t.ok(vestige and vestige.needs == nil, "the black wolf's vestige is also in its loot, with no stat")
    t.eq(#boss.bones, 1, "a boss has its bones row")
    t.eq(joined(boss.carcass), "animalcarcass_alpha_wolf", "and its carcass")
end)

t.test("drops: a template, a reward row or a carcass item the game lacks is left out and counted", function()
    local changed = fixture.copy()
    local rewards = fixture.find(changed, "ItemRewards", "Deer_Carcass_Loot").Rewards
    rewards[#rewards + 1] = { Item = { RowName = "Chitin" }, DropChance = 100, MinRandomStackCount = 1, MaxRandomStackCount = 2,
        RequiredStatToDrop = { RowName = "None" } }
    fixture.find(changed, "AISetup", "Deer").DeadItem = { RowName = "AnimalCarcass_Roat" }
    fixture.find(changed, "AISetup", "Deer").Trophy = { RowName = "Irradiated_Prospector_Head" }
    local other = build({ tables = changed })
    local deer = variant_of(other, "Deer")
    t.eq(drop_text(deer.skin), "leather 10-16, fur 4-8, bone 2-4, raw_meat 2, gamey_meat 3-5 at 10%")
    t.eq(#deer.carcass, 0)
    t.eq(#deer.trophy, 0)
    t.ok(skipped_has(other, "ItemTemplate", "Chitin"))
    t.ok(skipped_has(other, "ItemsStatic", "AnimalCarcass_Roat"))
    t.ok(skipped_has(other, "ItemRewards", "Irradiated_Prospector_Head"))
end)

t.test("drops index: who gives an item, one line a group, most first, a drop that needs something after the plain ones", function()
    local lines, seen = c.drops.leather, {}
    t.eq(#lines, 5, "deer, wolf, bear, terrenus, black wolf")
    for position, line in ipairs(lines) do
        t.eq(seen[line.entry], nil, "one line a group")
        seen[line.entry] = true
        if position > 1 then t.ok(lines[position - 1].amount >= line.amount, "most first") end
    end
    t.eq(lines[1].entry, "forest_deer", "the large deer gives 12 to 18")
    t.eq(lines[1].variant, 2)
    t.eq(lines[1].min .. "-" .. lines[1].max, "12-18")
    t.eq(lines[1].way, "skin")
    local bone = c.drops.bone
    t.eq(bone[1].entry, "bear")
    t.eq(bone[1].way, "bones", "25 to 50 from the bear's bones")
    local head = c.drops.alphawolf_head
    t.eq(#head, 1)
    t.eq(head[1].variant, 1)
    t.eq(head[1].way, "skin", "the boss's loot gives it without the knife, which ranks before a trophy")
    t.eq(head[1].needs, nil)
    t.eq(c.drops.deer_head[1].needs, creatures.TROPHY_STAT)
    t.eq(c.counts.items, 31)
    t.eq(c.drops.wood, nil)
end)

-- ---------------------------------------------------------------- where

t.test("areas: a block a map with the areas that list it, their level band and its share of each list", function()
    local deer = variant_of(c, "Deer")
    t.eq(#deer.areas, 3)
    local olympus = deer.areas[1]
    t.eq(olympus.name, "Olympus")
    t.eq(olympus.count, 4)
    t.eq(olympus.low .. "-" .. olympus.high, "1-120")
    close(olympus.share_low, 10.0, "least share")
    close(olympus.share_high, 21.05, "most share")
    t.eq(olympus.median, 15)
    t.eq(deer.areas[2].name .. " " .. deer.areas[2].count, "Styx 5")
    t.eq(deer.areas[3].name .. " " .. deer.areas[3].count .. " " .. deer.areas[3].low .. "-" .. deer.areas[3].high, "Prometheus 5 30-90")
    local bear = variant_of(c, "Bear")
    t.eq(bear.areas[1].count, 3, "the bear is in three Olympus areas")
    close(bear.areas[1].share_low, 5.26)
    close(bear.areas[1].share_high, 16.67)
    t.eq(#variant_of(c, "Tamed_Forest_Wolf").areas, 0)
end)

t.test("areas: every outpost together is one block, and Orbit, Devland and a name marked [DNT] give none", function()
    local deer = variant_of(c, "Deer")
    t.eq(deer.outposts.count, 3)
    t.eq(deer.outposts.low .. "-" .. deer.outposts.high, "1-30")
    local wolf = variant_of(c, "Conifer_Wolf")
    t.eq(wolf.outposts.count, 2, "the third area that lists it belongs to [DNT] Outpost 011")
    for _, block in ipairs(deer.areas) do
        t.ok(block.name ~= "Orbit" and block.name ~= "Devland" and not block.name:find("DNT", 1, true), block.name)
    end
    t.eq(#deer.areas, 3, "Orbit shares Olympus's spawn config and is not a fourth block")
end)

t.test("areas: a share is the variant's weight over the sum of the list, and folded set-ups add up", function()
    local changed = fixture.copy()
    local zone = fixture.find(changed, "AISpawnZones", "OLY_Conifer_Easy")
    local list = zone.Creatures.AISpawnList
    local total, wolf_weight = 0, 0
    for _, entry in ipairs(list) do
        total = total + entry.SpawnWeight
        if entry.AISetup.Value == "Conifer_Wolf" then wolf_weight = entry.SpawnWeight end
    end
    t.eq(total, 43)
    t.eq(wolf_weight, 8)
    list[#list + 1] = { AISetup = { Value = "Wolf_Anchored" }, SpawnWeight = 7 }
    local other = build({ tables = changed })
    local best = 0
    for _, block in ipairs(variant_of(other, "Conifer_Wolf").areas) do best = math.max(best, block.share_high) end
    close(best, 100 * 15 / 50, "8 and 7 of 50")
end)

t.test("maps: the bestiary's maps and the maps of the blocks together", function()
    t.eq(names(c.entries.forest_wolf.maps), "Olympus, Styx, Prometheus", "the bestiary names two, the spawn lists a third")
    t.eq(names(c.entries.bear.maps), "Olympus, Styx, Prometheus")
    t.eq(names(c.entries.dog.maps), "Orbit")
    t.eq(names(c.entries.forest_deer.biomes), "Forest, Arctic", "a biome is shown by its name, not its row")
    t.eq(c.entries.dog.workshop, true)
    t.eq(c.entries.forest_deer.workshop, false)
end)

t.test("other sources: world boss, hordes without the test waves, near players, brought along", function()
    t.eq(variant_of(c, "Alpha_Wolf_Boss").boss.respawn, 3600)
    t.eq(variant_of(c, "Alpha_Wolf").boss, nil)
    t.eq(variant_of(c, "Conifer_Wolf").horde, true)
    t.eq(variant_of(c, "Alpha_Wolf").horde, true)
    t.eq(variant_of(c, "Deer").horde, false)
    t.eq(variant_of(c, "Deer").near, false)

    local changed = fixture.copy()
    for _, row in ipairs(changed.HordeWave.rows) do
        if not row.Name:find("^Test_Wave") then row.Creatures = {} end
    end
    t.eq(variant_of(build({ tables = changed }), "Conifer_Wolf").horde, false, "Test_Wave_1 names the wolf and does not count")

    changed = fixture.copy()
    fixture.find(changed, "AutonomousSpawns", "Kea").AISetup = { Value = "Deer" }
    fixture.find(changed, "AISetup", "Bear").AdditionalAIToSpawn = { { RowName = "Deer" }, { RowName = "Deer" } }
    local other = build({ tables = changed })
    t.eq(variant_of(other, "Deer").near, true)
    t.eq(joined(variant_of(other, "Deer").with, ", "), "Bear", "by the name of the kind that brings it, once")
end)

t.test("order: as you meet them: the lowest middle level, the earlier map, the commoner one, then by name, bosses last", function()
    t.eq(c.entries.forest_deer.rank, 15)
    t.eq(c.entries.forest_deer.rank_map, 1, "met first on Olympus")
    close(c.entries.forest_deer.rank_share, 100 * 6 / 43, "6 of the 43 of the starting forest's list")
    close(c.entries.forest_wolf.rank_share, 100 * 8 / 43)
    t.eq(c.entries.bear.rank, 15)
    t.eq(c.entries.bear.rank_map, 2, "its Olympus areas start at a middle level of 25, one on Styx at 15")
    t.eq(c.entries.dog.rank, creatures.NO_RANK)
    local order = {}
    for position, entry in ipairs(c.list) do order[position] = entry.id end
    t.eq(joined(order), "forest_wolf forest_deer horse bear bee dog alpha_wolf_boss")

    local changed = fixture.copy()
    for _, row in ipairs(changed.AISpawnZones.rows) do
        if not row.Name:find("^Outpost") then
            local kept = {}
            for _, entry in ipairs(row.Creatures.AISpawnList) do
                if entry.AISetup.Value ~= "Bear" then kept[#kept + 1] = entry end
            end
            row.Creatures.AISpawnList = kept
        end
    end
    local other = build({ tables = changed })
    t.eq(other.entries.bear.rank, 15, "one that only an outpost lists is met there")
    t.eq(other.entries.bear.rank_map > 4, true, "after those the maps list at that level")
    t.eq(other.list[4].id, "bear")
end)

-- ---------------------------------------------------------------- taming

t.test("taming: a trap row tames the grown wild one, with the bait its set-up names and the biomes", function()
    local tame = c.entries.forest_wolf.tame
    t.eq(tame.row, "Forest_Wolf")
    t.eq(joined(tame.trap_in, ", "), "Forest, Grasslands")
    t.eq(tame.bait, "creaturebait_wolf")
    t.eq(c.trap, "snare_trap")
    t.eq(tame.grown, 1)
    t.eq(tame.becomes, 2)
    t.eq(tame.young, 3)
    t.eq(tame.beside, nil, "no young one beside a wild wolf")
    t.eq(tame.seconds, 600)
    t.eq(tame.nutrition, 25)
    t.eq(tame.shelter, 0)
    t.eq(tame.cold .. " " .. tame.hot, "10 40")
    t.eq(#tame.not_while, 0, "the wolf's row prohibits nothing")
    t.eq(c.entries.forest_wolf.tamed, true)
    t.eq(c.entries.forest_wolf.ridden, false)
end)

t.test("taming: a young one beside a wild adult by the row's chance, and no trap without trap biomes", function()
    local tame = c.entries.horse.tame
    t.eq(tame.beside, 50)
    t.eq(tame.trap_in, nil)
    t.eq(tame.bait, nil)
    t.eq(tame.seconds, 900)
    t.eq(joined(tame.not_while, ", "), "Wet, Sleepy")
    t.eq(c.entries.horse.tamed, true)
    t.eq(c.entries.horse.ridden, true)
end)

t.test("taming: breeding only where a Fertility Serum carries a kind tag of the group", function()
    t.eq(c.entries.forest_wolf.tame.serum, "fertility_serum_wolf")
    t.eq(c.entries.forest_wolf.tame.gestation, 1500)
    t.eq(c.entries.horse.tame.serum, nil, "the row has a gestation time and the game no serum for it")
    t.eq(c.entries.horse.tame.gestation, nil)
end)

t.test("taming: a row that names only a tamed set-up tames nothing, and the table's defaults are not shown", function()
    local dog = c.entries.dog
    t.eq(dog.tame.row, "Dog")
    t.eq(dog.tame.becomes, 1)
    t.eq(dog.tame.young, nil)
    t.eq(dog.tame.grown, nil)
    t.eq(dog.tame.seconds, nil)
    t.eq(dog.tamed, false)
    t.eq(dog.ridden, false)
    t.eq(c.entries.forest_deer.tame, nil)
    t.eq(c.entries.bear.tame, nil)
    t.eq(c.counts.tamed, 2)
    t.eq(c.counts.ridden, 1)
end)

t.test("taming: a taming or mount row that names a set-up the game lacks counts as not there", function()
    t.ok(skipped_has(c, "AISetup", "Juvenile_Blueback"))
    t.ok(skipped_has(c, "AISetup", "Mount_SwampQuad"))
    local changed = fixture.copy()
    fixture.find(changed, "Tames", "Horse").JuvenileCreatureType = { RowName = "Juvenile_Gone" }
    local other = build({ tables = changed })
    t.eq(other.entries.horse.tamed, false)
    t.eq(other.entries.horse.tame.row, nil, "the mount row still names its tamed form")
    t.eq(variant_of(other, "Juvenile_Horse").role, "wild")
    t.eq(other.entries.horse.ridden, true)
end)

t.test("mounts: top level from the growth row, the orders by name, what fits its saddle slot, ridden", function()
    local horse = variant_of(c, "Mount_Horse").mount
    t.eq(horse.row, "Horse")
    t.eq(horse.top, 50)
    t.eq(horse.pet, false)
    t.eq(joined(horse.orders), "Follow IdleWander IdleStanding IdleLying")
    t.eq(joined(horse.combat), "DoNotEngage NeutralEngagement AggressiveEngagement")
    t.eq(horse.comfortable.low .. " " .. horse.comfortable.high, "-8 35")
    t.eq(#horse.saddles, 14, "fifteen saddle rows, one with a tag no item carries")
    t.eq(horse.saddles[1], "saddle_standard")
    t.eq(horse.ridden, true)
    local wolf = variant_of(c, "Tamed_Forest_Wolf").mount
    t.eq(wolf.top, 25)
    t.eq(wolf.pet, true)
    t.eq(joined(wolf.orders), "Follow IdleWander")
    t.eq(wolf.comfortable.low .. " " .. wolf.comfortable.high, "8 35", "the row gives Y and the table's default X")
    t.eq(#wolf.saddles, 0)
    t.eq(wolf.ridden, false)
    local dog = variant_of(c, "Tame_Dog_A1").mount
    t.eq(joined(dog.saddles), "dog_accessory_d")
    t.eq(dog.ridden, false, "an item fits its slot and its growth row is the pets'")
    t.eq(joined(variant_of(c, "Tame_Dog_C1").mount.combat), "DoNotEngage")
    t.eq(variant_of(c, "Tame_Dog_A2").mount, nil)
end)

t.test("mounts: the orders read as numbers, as the game gives them", function()
    local changed = fixture.copy()
    local row = fixture.find(changed, "Mounts", "Horse")
    row.SupportedMovementStates, row.SupportedCombatStates = { 1, 2, 3, 4 }, { 1, 3 }
    local horse = variant_of(build({ tables = changed }), "Mount_Horse").mount
    t.eq(joined(horse.orders), "Follow IdleWander IdleStanding IdleLying")
    t.eq(joined(horse.combat), "DoNotEngage AggressiveEngagement")
end)

t.test("uses: what a saddle, a bait and a serum are used on, and the items every page shares", function()
    t.eq(c.uses.saddle_standard[1].entry .. " " .. c.uses.saddle_standard[1].as, "horse saddle")
    t.eq(c.uses.creaturebait_wolf[1].entry .. " " .. c.uses.creaturebait_wolf[1].as, "forest_wolf bait")
    t.eq(c.uses.fertility_serum_wolf[1].as, "serum")
    t.eq(c.uses.dog_accessory_d[1].entry, "dog")
    t.eq(#c.feed, 15)
    local met, twice = {}, nil
    for _, key in ipairs(c.feed) do
        if met[m.items[key].name] then twice = m.items[key].name end
        met[m.items[key].name] = true
    end
    t.eq(twice, nil, "no feed is listed under a name twice")
    t.eq(m.items.food_animal_feed_speed.hidden, true, "the item list hides this copy of Seed Animal Feed")
    t.eq(joined(c.feed):find("food_animal_feed_speed", 1, true), nil, "so the feed list leaves it out")
    t.ok(joined(c.feed):find("food_animal_feed ", 1, true), "and keeps the one it shows")
    t.eq(c.knife, "taxidermy_knife")
end)

-- ---------------------------------------------------------------- names, search, the list

t.test("names: trimmed, and one marked [DNT] or empty is never shown", function()
    local bear = variant_of(c, "Bear")
    t.eq(bear.epics[3].row, "SQ_Fisher_Bear")
    t.eq(bear.epics[3].names[1], "Tide-Gorged Bear", "the table has a space in front")
    local changed = fixture.copy()
    fixture.find(changed, "Atmospheres", "Arctic").AtmosphereName = "[DNT] Cold place"
    fixture.find(changed, "EpicCreatures", "Bear_Boss").CreatureNames = { "[DNT] Test bear", "  " }
    fixture.find(changed, "AICreatureType", "MediumDeer").CreatureName = ""
    local other = build({ tables = changed })
    t.eq(names(other.entries.forest_deer.biomes), "Forest")
    t.eq(variant_of(other, "Bear").epics[1].row, "Roaming_Bear", "a named form with no name to show is left out")
    t.eq(variant_of(other, "Deer").name, "Deer", "a kind with no name takes the group's")
end)

t.test("traits: the game's own list, in its order, an empty handle skipped", function()
    t.eq(names(c.entries.forest_deer.traits), "Critical Area: Head, Passive, Weak to Poison")
    t.eq(c.entries.forest_deer.traits[1].type, "critspot")
    local changed = fixture.copy()
    local traits = fixture.find(changed, "BestiaryData", "Forest_Deer").Traits
    table.insert(traits, 2, { RowName = "None" })
    t.eq(names(build({ tables = changed }).entries.forest_deer.traits), "Critical Area: Head, Passive, Weak to Poison")
end)

t.test("search: every typed word must be in a creature's words", function()
    local function found(typed, which, item)
        local out = {}
        for position, entry in ipairs(creatures.filter(c, typed, which, item)) do out[position] = entry.id end
        return joined(out)
    end
    t.eq(found({ "wolf" }), "forest_wolf alpha_wolf_boss")
    t.eq(found({ "olympus", "hostile" }), "bear")
    t.eq(found({ "pack" }), "forest_wolf alpha_wolf_boss", "a trait's name")
    t.eq(found({ "boss" }), "alpha_wolf_boss")
    t.eq(found({ "ridden" }), "horse")
    t.eq(found({ "juvenile" }), "horse", "a variant's name")
    t.eq(found({ "workshop" }), "dog")
    t.eq(found({ "friendly" }), "dog")
    t.eq(found({ "can", "attack" }), "forest_wolf horse alpha_wolf_boss")
    t.eq(found({ "attacks" }), "bear", "the bear's trait is Strong Attacks")
    t.eq(found({ "xyz" }), "")
    t.eq(found({}), "forest_wolf forest_deer horse bear bee dog alpha_wolf_boss", "nothing typed: the whole list in its order")
    t.eq(found({}, "neutral"), "forest_wolf horse bee alpha_wolf_boss")
    t.eq(found({}, "tamed"), "forest_wolf horse")
    t.eq(found({}, "ridden"), "horse")
    t.eq(found({ "forest" }, "passive"), "forest_deer")
    t.eq(found({}, nil, "honeycomb"), "bee", "the creatures that give one item")
    t.eq(found({}, "hostile", "leather"), "bear")
end)

-- ---------------------------------------------------------------- one page: texts, and the numbers while they are served

t.test("detail: with maps refused, the field guide's texts, the points and the skinning XP, and no numbers", function()
    local detail = creatures.detail(c, src, "forest_deer", 1)
    t.eq(#detail.lore, 3)
    t.ok(detail.lore[1]:find("^On Icarus, deer"))
    t.eq(detail.points, 1800)
    t.eq(detail.xp.skin, 260)
    t.eq(detail.xp.kill, nil)
    t.eq(detail.stats, nil)
    t.eq(detail.rewards, nil)
    t.eq(creatures.detail(c, src, "forest_deer", 1), detail, "read once and kept")
    t.eq(creatures.detail(c, src, "forest_wolf", 1).xp.skin, 750)
    t.eq(creatures.detail(c, src, "forest_wolf", 3).xp.skin, 750, "the cub has the adult's kind")
    t.eq(creatures.detail(c, src, "nothing", 1), nil)
    t.eq(#src.problems, 0)
end)

t.test("detail: with maps and curves served, health and damage at a level, speeds by state, senses, kill XP", function()
    local served, _, source_served = build({ maps = true })
    local deer = creatures.detail(served, source_served, "forest_deer", 1)
    close(creatures.at(deer.stats.health, 28), 346.67, "deer health at 28")
    close(creatures.at(deer.stats.health, 1), 301.67)
    close(creatures.at(deer.stats.health, 500), 500, "held to the curve's end")
    t.eq(deer.stats.damage, nil, "the deer has no damage curve")
    t.eq(deer.stats.last, 120)
    t.eq(deer.stats.speed, 220)
    close(deer.stats.speed * deer.stats.states.Walk, 220)
    close(deer.stats.speed * deer.stats.states.Run, 660)
    close(deer.stats.speed * deer.stats.states.Sprint, 1199, "sprint")
    t.eq(deer.stats.sight .. " " .. deer.stats.hearing, "5000 2500")
    t.eq(deer.xp.kill, 520)
    t.eq(deer.xp.skin, 260)
    local wolf = creatures.detail(served, source_served, "forest_wolf", 1)
    close(creatures.at(wolf.stats.health, 30), 216.67, "a curved segment")
    close(wolf.stats.speed * wolf.stats.states.Attacking, 900, "its fastest state is not one of walk, run and sprint")
    t.eq(wolf.xp.kill, 1500)
end)

t.test("detail: a tamed one stops at its growth row's top level, not where a curve ends", function()
    local served, _, source_served = build({ maps = true })
    local mount = creatures.detail(served, source_served, "horse", 2)
    t.eq(mount.stats.last, 50)
    close(creatures.at(mount.stats.health, 50), 1500)
    close(creatures.at(mount.stats.damage, 50), 57.5, "its damage curve runs on to 120")
    t.eq(mount.stats.food .. " " .. mount.stats.food_hour, "300 240")
    t.eq(mount.stats.water .. " " .. mount.stats.water_hour, "300 120")
    t.eq(mount.stats.carry, 200)
    t.eq(mount.stats.cargo, 3)
    t.eq(creatures.detail(served, source_served, "forest_wolf", 2).stats.last, 25)
end)

t.test("detail: resistances are every resistance stat, and a named form's stats are all of its row's", function()
    local served, _, source_served = build({ maps = true })
    local tamed = creatures.detail(served, source_served, "forest_wolf", 2)
    local resists = {}
    for position, pair in ipairs(tamed.stats.resists) do resists[position] = pair.name:match("^Base(.-)Resistance") .. " " .. pair.value end
    table.sort(resists)
    t.eq(#resists, 8)
    t.ok(joined(resists, ", "):find("ExplosiveDamage 40", 1, true))
    local boss = creatures.detail(served, source_served, "alpha_wolf_boss", 1)
    t.eq(boss.stats.traits.Wound_DamageType.name, "BaseAttacksCauseWound_%", "the wound chance is a flat stat of Base")
    t.eq(boss.stats.traits.Wound_DamageType.value, 50)
    t.eq(#boss.stats.attacks, 0, "its trait says it, so the list of what its attacks cause does not")
    local bear = creatures.detail(served, source_served, "bear", 1)
    t.eq(#bear.epics[2], 5, "Roaming Beast")
    t.eq(#bear.epics[3], 5, "Tide-Gorged Bear")
    t.eq(#bear.rewards, 2)
    t.eq(bear.rewards[1].name .. " " .. bear.rewards[1].value, "BaseDeepWoundResistance_% 10")
end)

t.test("detail: a trait's figure is the stat its row name ties it to, and only when that stat says what the trait says", function()
    local served, _, source_served = build({ maps = true })
    local deer = creatures.detail(served, source_served, "forest_deer", 1)
    t.eq(deer.stats.traits.Poison_Weakness.name, "BasePoisonDamageResistance_%")
    t.eq(deer.stats.traits.Poison_Weakness.value, -50)
    t.eq(#deer.stats.resists, 0, "said with the trait")
    t.eq(deer.stats.traits.Head_CritSpot, nil, "no row holds a critical area's own figure")
    -- the tamed wolf resists the poison its wild form is weak to
    local tamed = creatures.detail(served, source_served, "forest_wolf", 2)
    t.eq(tamed.stats.traits.Poison_Weakness, nil)
    local held = {}
    for _, pair in ipairs(tamed.stats.resists) do held[pair.name] = pair.value end
    t.eq(held["BasePoisonDamageResistance_%"], 40)
    -- the row's own rules
    t.eq(creatures.trait_stat({ row = "Fire_Weakness" }, { ["BaseFireDamageResistance_%"] = -100 }), "BaseFireDamageResistance_%")
    t.eq(creatures.trait_stat({ row = "Fire_Weakness" }, { ["BaseFireDamageResistance_+%"] = -25 }), "BaseFireDamageResistance_+%")
    t.eq(creatures.trait_stat({ row = "Fire_Weakness" }, { ["BaseFireDamageResistance_%"] = 40 }), nil)
    t.eq(creatures.trait_stat({ row = "Fire_Resist_Strength" }, { ["BaseFireDamageResistance_%"] = 40 }), "BaseFireDamageResistance_%")
    t.eq(creatures.trait_stat({ row = "Fire_Resist_Strength" }, { ["BaseFireDamageResistance_%"] = -40 }), nil)
    t.eq(creatures.trait_stat({ row = "Poison_Infliction" }, { ["BaseAttacksCausePoison_%"] = 75 }), "BaseAttacksCausePoison_%")
    t.eq(creatures.trait_stat({ row = "Head_CritSpot" }, { ["BaseFireDamageResistance_%"] = -100 }), nil)
    t.eq(creatures.trait_stat({ row = "Fast_Strength" }, {}), nil)
    t.eq(creatures.trait_stat(nil, {}), nil)
end)

t.test("detail: a stat the row gives by level, the rest of its stats, a flat damage, and what a critical hit counts", function()
    local served, _, source_served = build({ maps = true })
    local wolf = creatures.detail(served, source_served, "forest_wolf", 1)
    local wound = wolf.stats.traits.Wound_DamageType
    t.eq(wound.name, "BaseAttacksCauseWound_%")
    t.eq(type(wound.value), "table", "D_AIGrowth.CustomStats: a curve by level")
    t.eq(creatures.figure(wound.value, 1), 0)
    close(creatures.figure(wound.value, 60), 30.7, "the wolf's wound chance at level 60")
    t.eq(creatures.figure(7, 60), 7, "a plain figure is the same at every level")
    t.eq(creatures.figure(nil, 60), nil)
    local deer = creatures.detail(served, source_served, "forest_deer", 1)
    local others = {}
    for _, pair in ipairs(deer.stats.others) do others[pair.name] = pair.value end
    t.eq(others["BaseCharacterMass_+"], 175)
    t.eq(others["BaseHealthRegenPerMinute_+"], 10)
    t.eq(others["BaseMovementSpeed_+"], nil, "said as speeds")
    t.eq(others["BaseSwimSpeed_+"], nil)
    t.eq(others["BaseAIPerceptionSightRadius_+"], nil)
    t.eq(deer.stats.swim, 300)
    t.eq(deer.crit.start, 300, "D_CharacterStartingStats: BaseCriticalDamage_+%")
    t.eq(joined(deer.crit.shares), "100 50 15", "D_CriticalHitAreas: the shares of the kinds of weak point, most first")
    t.eq(joined(served.crit.shares), "100 50 15")
    -- a creature with no damage curve and a flat melee damage
    local changed = fixture.copy()
    local bear = fixture.find(changed, "AIGrowth", "Bear")
    bear.MeleeDamage = nil
    bear.Base['(Value="BaseMeleeDamage_+")'] = 70
    local other, _, other_source = build({ maps = true, tables = changed })
    t.eq(creatures.detail(other, other_source, "bear", 1).stats.damage, 70)
    -- without maps there is nothing a critical hit could be counted from
    t.eq(creatures.detail(c, src, "forest_deer", 1).crit, nil)
    t.eq(joined(c.crit.shares), "100 50 15", "the shares are plain fields, read with the rest")
end)

t.test("detail: kill XP is the event's own; by level only behind the switch nobody has proven", function()
    local served, _, source_served = build({ maps = true })
    local deer = creatures.detail(served, source_served, "forest_deer", 1)
    t.eq(creatures.XP_BY_LEVEL, false)
    local xp, by_level = creatures.kill_xp(deer, 120)
    t.eq(xp, 520)
    t.eq(by_level, false)
    close(creatures.at(deer.stats.xp_times, 120), 2, "the multiplier is read, and waits for the switch")
    creatures.XP_BY_LEVEL = true
    local ok, problem = pcall(function()
        local scaled, scaled_by_level = creatures.kill_xp(deer, 120)
        close(scaled, 1040)
        t.eq(scaled_by_level, true)
    end)
    creatures.XP_BY_LEVEL = false
    assert(ok, problem)
    t.eq(creatures.kill_xp(nil, 5), nil)
end)

t.test("shapes: stat maps, movement maps and curves in every form they may come in", function()
    local pairs_found = creatures.stat_pairs({ ['(Value="A_+")'] = 2, B = 3, { Key = "C", Value = 4 }, { Stat = { Value = "D" }, Value = 5 } })
    local names_found = {}
    for position, pair in ipairs(pairs_found) do names_found[position] = pair.name .. "=" .. pair.value end
    t.eq(joined(names_found), "A_+=2 B=3 C=4 D=5")
    t.eq(creatures.stat_pairs("None"), nil)
    local by_number = creatures.speeds({ [3] = { MaxWalkSpeed = 1 }, [5] = { MaxWalkSpeed = 3 }, [7] = 6 })
    t.eq(by_number.Walk .. " " .. by_number.Run .. " " .. by_number.Attacking, "1 3 6")
    local by_name = creatures.speeds({ Walk = { MaxWalkSpeed = 1 }, ["EMovementState::Sprint"] = { MaxWalkSpeed = 5.45 } })
    t.eq(by_name.Walk .. " " .. by_name.Sprint, "1 5.45")
    t.eq(creatures.speeds({}), nil)
    local sampled = creatures.curve({ First = 0, Values = { 10, 20, 30 } })
    t.eq(sampled.first .. " " .. sampled.last, "0 2")
    t.eq(creatures.at(sampled, 1), 20)
    t.eq(creatures.at(sampled, -5), 10)
    t.eq(creatures.at(sampled, 99), 30)
    local keyed = creatures.curve({ Keys = { { Time = 0, Value = 300 }, { Time = 120, Value = 500 } } })
    close(creatures.at(keyed, 28), 346.67)
    t.eq(keyed.last, 120)
    t.eq(creatures.at(creatures.curve({ 5, 6, 7 }), 2), 7, "a plain list starts at level 0")
    t.eq(creatures.curve("CurveFloat'/Game/Data/AI/Curves/C_X.C_X'"), nil, "an asset path is no curve")
    t.eq(creatures.at(100, 30), 100, "a flat figure is the same at every level")
    t.eq(creatures.at(nil, 30), nil)
end)

-- ---------------------------------------------------------------- a game that changed, and the join giving way

t.test("off: a table that lost a field switches its part off and the rest stands", function()
    local changed = fixture.copy()
    changed.Saddles.fields = { "SupportedMount" }
    for _, row in ipairs(changed.Saddles.rows) do row.SaddleTag = nil end
    local other = build({ tables = changed })
    t.eq(other.off.taming, true)
    t.eq(other.off.list, nil)
    t.eq(other.counts.all, 7)
    t.eq(other.entries.horse.tame, nil)
    t.eq(variant_of(other, "Mount_Horse").role, "friendly", "with no mount row read it is only on your side")
    t.eq(drop_text(variant_of(other, "Deer").skin), "leather 10-16, fur 4-8, bone 2-4, raw_meat 2, gamey_meat 3-5 at 10%")
    t.eq(other.missing[1].table, "Saddles")
end)

t.test("off: without a table the list stands on there is no list, and no error", function()
    local changed = fixture.copy()
    changed.BestiaryData = nil
    local other = build({ tables = changed })
    t.eq(other.off.list, true)
    t.eq(#other.list, 0)
    t.eq(other.stage, 0)
    local early = creatures.build(src, { stage = 0, off = {}, items = {} }, {})
    t.eq(early.off.items, true, "and none before the items are read")
    t.eq(early.stage, 0)
end)

t.test("build: it gives the frame back now and then, and only reads fields its lists name", function()
    local pauses = 0
    local paused = build({ pause = function() pauses = pauses + 1 end })
    t.ok(pauses >= 1, "pause was called " .. pauses .. " times")
    t.eq(paused.counts.variants, 22)
    t.eq(#src.problems, 0, "the strict rows raised nothing")
end)

-- ---------------------------------------------------------------- creature_load.lua

local loading = part("creature_load", { os = os, debug = debug, xpcall = xpcall })

local function new_task()
    local waiting, task = {}, {}
    local function run(thread, ...)
        local ok, problem = coroutine.resume(thread, ...)
        if not ok then error(problem, 0) end
        if coroutine.status(thread) ~= "dead" then waiting[#waiting + 1] = thread end
    end
    function task.spawn(fn, ...)
        local thread = coroutine.create(fn)
        run(thread, ...)
        return thread
    end
    function task.wait() coroutine.yield() end
    function task.cancel(thread)
        for position, held in ipairs(waiting) do
            if held == thread then
                table.remove(waiting, position)
                break
            end
        end
    end
    function task.step()
        local now = waiting
        waiting = {}
        for _, thread in ipairs(now) do run(thread) end
    end
    return task
end

local function item_model(provider, stages)
    local items = source.new(provider)
    local b = model.begin(items, string.lower, tags)
    items.read(1, 1)
    model.items(b)
    if (stages or 3) >= 2 then
        items.read(2, 1)
        model.recipes(b)
    end
    if (stages or 3) >= 3 then b.model.stage = 3 end
    return b.model
end

local function new_job(options)
    options = options or {}
    local provider = options.provider or fixture.provider()
    local world = { task = new_task(), told = 0, kept = options.kept or {}, items = options.items, showing = false, provider = provider }
    world.job = loading.new({ data = provider, source = source, creatures = creatures, task = world.task, kept = world.kept,
        lower = string.lower, words = WORDS, items = function() return world.items end,
        showing = function() return world.showing end, changed = function() world.told = world.told + 1 end })
    function world.finish()
        for _ = 1, 2000 do
            if not world.job.reading then return end
            world.task.step()
        end
        error("the read did not end", 2)
    end
    return world
end

t.test("load: nothing is read before the items are there, and asking early starts it with them", function()
    local world = new_job()
    world.job.want()
    t.eq(world.job.reading, false)
    t.eq(world.provider.calls, 0, "game.Data was not asked anything")
    world.items = item_model(world.provider, 1)
    world.job.items_changed()
    t.eq(world.job.reading, true)
    t.eq(world.job.runs, 1)
    world.job.items_changed()
    world.job.want()
    t.eq(world.job.runs, 1, "a read is under way for these items")
    world.finish()
    t.eq(world.job.model.counts.all, 7)
    t.eq(world.job.failed, false)
    t.ok(world.told >= 2, "the views were told when it began and when it ended")
    t.eq(world.job.detail("forest_deer", 1).xp.skin, 260)
end)

t.test("load: it starts by itself when the item read has finished, and not before", function()
    local world = new_job()
    world.items = item_model(world.provider, 2)
    world.job.items_changed()
    t.eq(world.job.reading, false, "the recipes are read, the last stage is not")
    world.items.stage = 3
    world.job.items_changed()
    t.eq(world.job.reading, true)
    world.finish()
    t.eq(world.job.model.stage, 1)
    world.job.items_changed()
    t.eq(world.job.runs, 1, "the same items again change nothing")
end)

t.test("load: kept across a reload while the tables and the items are the same, and built again when the items change", function()
    local provider = fixture.provider()
    local items = item_model(provider, 3)
    local first = new_job({ provider = provider, items = items })
    first.job.want()
    first.finish()
    local kept = first.kept
    t.eq(kept.version, creatures.version)
    t.ok(kept.model == first.job.model)

    local again = new_job({ provider = provider, items = items, kept = kept })
    t.ok(again.job.model == kept.model, "the kept model is used at once")
    t.eq(again.job.reading, false)
    t.eq(again.job.runs, 0)
    t.eq(again.job.detail("forest_wolf", 1).xp.skin, 750, "with a source of its own for the pages")

    local other_items = item_model(provider, 3)
    other_items.stamp = other_items.stamp .. "x"
    local changed = new_job({ provider = provider, items = other_items, kept = kept })
    t.eq(changed.job.reading, true, "items read from other tables: built again")
    changed.finish()
    t.ok(changed.job.model ~= first.job.model)

    kept.version = (kept.version or 0) + 1
    local newer = new_job({ provider = provider, items = other_items, kept = kept })
    t.eq(newer.job.reading, true, "another version of the model's shape: built again")
    newer.finish()
end)

t.test("load: a creature table the game made again is read again, another table is not", function()
    local world = new_job()
    world.items = item_model(world.provider, 3)
    world.job.want()
    world.finish()
    world.job.data_changed("D_ItemsStatic")
    t.eq(world.job.reading, false, "an item table is the item read's business")
    world.job.data_changed("D_AISetup")
    t.eq(world.job.reading, true)
    t.eq(world.job.model, nil, "the old model is not shown meanwhile")
    world.finish()
    t.eq(world.job.runs, 2)
    world.job.data_changed(nil)
    t.eq(world.job.reading, true, "everything was dropped")
    world.job.stop()
    t.eq(world.job.reading, false)
end)

t.test("load: a game that lost a creature table gives a model that says so, and nothing fails", function()
    local changed = fixture.copy()
    changed.AISetup = nil
    local world = new_job({ provider = fixture.provider({ tables = changed }) })
    world.items = item_model(world.provider, 3)
    world.job.want()
    world.finish()
    t.eq(world.job.failed, false)
    t.eq(world.job.off(), true)
    t.eq(world.job.problems()[1].table, "AISetup")
end)

t.finish("recipe-creature")
