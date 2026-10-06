-- What an item does, in numbers: durability, damage, armor, effects, storage. Read for one item when it is asked for.

local stats = {}

-- Every fixed word shown. A stat line is the game's own sentence from D_Stats.
local WORDS = {
    durability = { title = "Durability", amount = "Durability", repair = "Repaired with" },
    melee = { title = "Melee and harvesting", damage = "Melee damage", varies = "Damage varies by", felling = "Felling damage",
        felling_rate = "Felling efficiency", radius = "Mining radius", mining_rate = "Mining efficiency",
        skinning_rate = "Skinning efficiency", reaping_rate = "Reaping efficiency", shattering = "Shattering damage",
        shattering_rate = "Shattering efficiency" },
    ranged = { title = "Ranged weapon", ammo = "Ammunition", capacity = "Ammo capacity", rate = "Rate of fire",
        per_minute = "%s per minute", reload = "Reload time", multiplier = "Damage multiplier", force = "Launch force" },
    projectile = { title = "Projectile", damage = "Projectile damage", count = "Projectiles", hit = "Damage",
        varies = "Damage varies by", breaks = "Break chance" },
    armor = { title = "Armor" },
    set = { title = "Set bonus", piece = "1 piece", pieces = "%s pieces" },
    equipped = { title = "When equipped" },
    properties = { title = "Properties" },
    consumed = { title = "When consumed", back = "Gives back" },
    effect = { title = "Effect" },
    shelf = { title = "Shelf life", lasts = "Lasts", into = "Turns into" },
    building = { title = "Building" },
    storage = { title = "Storage", slots = "Slots", holds = "Holds" },
    carrying = { title = "Carrying", weight = "Weight", stack = "Stack size" },
    units = { percent = "%", second = "s", minute = "min", hour = "h", gram = "g", kilo = "kg" },
    plus = " + ",
    list = ", ",
}

stats.WORDS = WORDS

-- { word, field, kind, the field that must be above zero for the line to mean something }
local MELEE = {
    { "damage", "Melee_Damage" }, { "varies", "DamageVariationPercentage", "percent", "Melee_Damage" },
    { "felling", "Felling_Damage" }, { "felling_rate", "Felling_Efficiency", "rate" }, { "radius", "Mining_Radius" },
    { "mining_rate", "Mining_Efficiency", "rate" }, { "skinning_rate", "Skinning_Efficiency", "rate" },
    { "reaping_rate", "Reaping_Efficiency", "rate" }, { "shattering", "Shattering_Damage" },
    { "shattering_rate", "Shattering_Efficiency", "rate" },
}

-- The game's enum EStatDisplayOperation: a name in the files, a number in the game.
local OPERATIONS = { multiply = 1, division = 2, addition = 3 }

local function fold(name)
    return (name:lower())
end

local function ref(handle)
    local name = handle
    if type(handle) == "table" then name = handle.RowName end
    if type(name) ~= "string" or name == "" or name:lower() == "none" then return nil end
    return name
end

local function words(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function list(value)
    if type(value) ~= "table" then return {} end
    return value
end

local function amount(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
end

-- 2500 is "2,500" and 0.70 is "0.7".
local function shown(value, places)
    local digits = ("%." .. (places or 2) .. "f"):format(math.abs(value))
    local whole, part = digits:match("^(%d+)%.?(%d*)$")
    part = part:gsub("0+$", "")
    whole = whole:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if whole:sub(1, 1) == "," then whole = whole:sub(2) end
    local out = part ~= "" and (whole .. "." .. part) or whole
    if value < 0 and out:find("[1-9]") then out = "-" .. out end
    return out
end

local function span(seconds, units)
    seconds = math.floor(seconds + 0.5)
    if seconds < 60 then return seconds .. " " .. units.second end
    local hours, minutes, rest = seconds // 3600, seconds % 3600 // 60, seconds % 60
    local parts = {}
    if hours > 0 then parts[#parts + 1] = hours .. " " .. units.hour end
    if minutes > 0 then parts[#parts + 1] = minutes .. " " .. units.minute end
    if rest > 0 and hours == 0 then parts[#parts + 1] = rest .. " " .. units.second end
    return table.concat(parts, " ")
end

-- A stat map as { name, value } pairs. Keys come plain or as the files write them, (Value="Name"), or as a list of pairs.
local function pairs_of(map)
    local out = {}
    if type(map) ~= "table" then return out end
    for key, value in pairs(map) do
        local name, figure = key, value
        if type(value) == "table" then
            name, figure = value.Key or value.Stat, value.Value
            if type(name) == "table" then name = name.Value end
        end
        figure = amount(figure)
        if type(name) == "string" and figure then
            out[#out + 1] = { name = name:match('^%(Value="(.*)"%)$') or name, value = figure }
        end
    end
    return out
end

local function applied(value, steps)
    for _, step in ipairs(list(steps)) do
        local kind, by = step.Operation, amount(step.Value)
        if type(kind) == "string" then kind = OPERATIONS[kind:lower():match("(%a+)$") or ""] end
        if by then
            if kind == 1 then
                value = value * by
            elseif kind == 2 and by ~= 0 then
                value = value / by
            elseif kind == 3 then
                value = value + by
            end
        end
    end
    return value
end

-- src: a source of its own. text: the mod's text table, used when it holds `stats`. format: the mod's format.lua, for weights.
function stats.new(src, text, format)
    local w = type(text) == "table" and type(text.stats) == "table" and text.stats or WORDS
    local self = { left = { unnamed = {}, hidden = {}, missing = {} } }
    local cache, known = {}, {}

    local function leave(kind, name)
        local held = self.left[kind]
        held[name] = (held[name] or 0) + 1
    end

    local function percent(value, places)
        return shown(value, places or 1) .. w.units.percent
    end

    local function heavy(grams)
        local made = type(format) == "table" and format.weight and format.weight(grams)
        if made then return made end
        if grams < 1000 then return shown(grams, 1) .. " " .. w.units.gram end
        return shown(grams / 1000) .. " " .. w.units.kilo
    end

    -- The row a handle of `row` names in a stage 4 table.
    local function trait(row, field, name)
        local wanted = row and ref(row[field])
        if not wanted then return nil end
        local found = src.detail(name or field, wanted)
        if not found then leave("missing", (name or field) .. "." .. wanted) end
        return found
    end

    local function item_name(static)
        local row = static and src.detail("ItemsStatic", static)
        local wanted = row and ref(row.Itemable)
        local itemable = wanted and src.row("Itemable", wanted)
        local name = itemable and words(itemable.DisplayName) or ""
        if name == "" then return nil end
        return name
    end

    local function template_name(handle)
        local wanted = ref(handle)
        local row = wanted and src.row("ItemTemplate", wanted)
        return item_name(row and ref(row.ItemStaticData))
    end

    local function line(lines, label, value)
        if not value or value == "" then return end
        lines[#lines + 1] = { text = label .. " " .. value, label = label, value = value }
    end

    local function note(lines, label, value)
        if label == "" then return end
        lines[#lines + 1] = { text = value ~= "" and (label .. " " .. value) or label, label = label, value = value }
    end

    local function group(out, id, title, lines)
        if lines[1] then out[#out + 1] = { id = id, title = title, lines = lines } end
    end

    local function stat_of(name)
        local key = fold(name)
        local stat = known[key]
        if stat == nil then
            local row = src.detail("Stats", name)
            stat = row and { positive = words(row.PositiveDescription), negative = words(row.NegativeDescription),
                steps = row.DisplayOperations, hidden = row.bHideStatInUserInterface == true and row.bShowStatOnModifiers ~= true,
                order = src.position("Stats", name) or 0 } or false
            known[key] = stat
        end
        return stat or nil
    end

    -- One stat as the game words it, or nil when it is left out. A sentence that starts with its figure is split as well.
    local function sentence(name, value)
        if value == 0 then return nil end
        local stat = stat_of(name)
        if not stat then
            leave("missing", "Stats." .. name)
            return nil
        end
        if stat.hidden then
            leave("hidden", name)
            return nil
        end
        local figure = applied(value, stat.steps)
        local template = figure < 0 and stat.negative or stat.positive
        if template == "" then
            leave("unnamed", name)
            return nil
        end
        local number = shown(math.abs(figure))
        local function fill() return number end
        local whole = template:gsub("{0}", fill)
        local head, rest = template:match("^([+-]?{0}%%?%a*)%s+(%u.*)$")
        if head then return { text = whole, label = rest, value = (head:gsub("{0}", fill)) } end
        return { text = whole, label = whole, value = "" }
    end

    -- The stats of a map in the order D_Stats lists them.
    local function add_stats(lines, map)
        local found = pairs_of(map)
        for _, entry in ipairs(found) do
            local stat = stat_of(entry.name)
            entry.order = stat and stat.order or 0
        end
        table.sort(found, function(a, b)
            if a.order ~= b.order then return a.order < b.order end
            return a.name < b.name
        end)
        for _, entry in ipairs(found) do
            local made = sentence(entry.name, entry.value)
            if made then lines[#lines + 1] = made end
        end
    end

    local function durability(out, row)
        local durable = trait(row, "Durable")
        if not durable then return end
        local lines, parts, most = {}, {}, amount(durable.Max_Durability)
        if most and most > 0 then line(lines, w.durability.amount, shown(most)) end
        for _, entry in ipairs(list(durable.ItemsForRepair)) do
            local name, count = item_name(ref(entry.Item)), amount(entry.Amount) or 1
            if name then parts[#parts + 1] = count > 1 and (shown(count) .. " " .. name) or name end
        end
        line(lines, w.durability.repair, table.concat(parts, w.list))
        group(out, "durability", w.durability.title, lines)
    end

    local function melee(out, row)
        local tool = trait(row, "ToolDamage")
        if not tool then return end
        local lines = {}
        for _, plan in ipairs(MELEE) do
            local value, needed = amount(tool[plan[2]]), plan[4] and (amount(tool[plan[4]]) or 0) or 1
            if value and value > 0 and needed > 0 then
                local figure = shown(value)
                if plan[3] == "rate" then
                    figure = percent(value * 100)
                elseif plan[3] == "percent" then
                    figure = percent(value)
                end
                line(lines, w.melee[plan[1]], figure)
            end
        end
        group(out, "melee", w.melee.title, lines)
    end

    local function ranged(out, row)
        local gun = trait(row, "FirearmData")
        if not gun then return end
        local lines, t = {}, w.ranged
        local kinds = trait(gun, "ValidAmmoTypes")
        line(lines, t.ammo, kinds and words(kinds.Description) or "")
        local capacity, rate = amount(gun.AmmoCapacity) or 1, amount(gun.RoundsPerMinute) or 0
        if capacity > 1 then
            line(lines, t.capacity, shown(capacity))
            if rate > 0 then line(lines, t.rate, t.per_minute:format(shown(rate))) end
        end
        local reload, times, force = amount(gun.ReloadTime) or 0, amount(gun.DamageMultiplier) or 1, amount(gun.LaunchForce) or 0
        if reload > 0 then line(lines, t.reload, shown(reload) .. " " .. w.units.second) end
        if times > 0 and times ~= 1 then line(lines, t.multiplier, percent(times * 100)) end
        if force > 0 then line(lines, t.force, shown(force)) end
        group(out, "ranged", t.title, lines)
    end

    local function projectile(out, row)
        local ammo, shot = trait(row, "AmmoType", "AmmoTypes"), trait(row, "Ballistic")
        if not ammo and not shot then return end
        local lines, t = {}, w.projectile
        local damage, count = ammo and amount(ammo.ProjectileDamage) or 0, ammo and amount(ammo.ProjectileCount) or 1
        local hit, varies = shot and amount(shot.Damage) or 0, shot and amount(shot.DamageVariationPercentage) or 0
        local breaks = shot and amount(shot.BreakChance) or 0
        if damage > 0 then line(lines, t.damage, shown(damage)) end
        if damage > 0 and count > 1 then line(lines, t.count, shown(count)) end
        if hit > 0 then line(lines, t.hit, shown(hit)) end
        if varies > 0 and (hit > 0 or damage > 0) then line(lines, t.varies, percent(varies)) end
        if breaks > 0 and breaks < 1 then line(lines, t.breaks, percent(breaks * 100)) end
        if ammo then add_stats(lines, ammo.Stats) end
        group(out, "projectile", t.title, lines)
    end

    local function armor(out, row)
        local armour = trait(row, "Armour")
        if not armour then return end
        local lines = {}
        add_stats(lines, armour.ArmourStats)
        group(out, "armor", w.armor.title, lines)
        local set = trait(armour, "ArmourSet", "ArmourSets")
        for _, handle in ipairs(list(set and set.SetBonus)) do
            local bonus = trait({ Bonus = handle }, "Bonus", "ArmourSetBonus")
            if bonus then
                local own, needed = {}, amount(bonus.RequiredGear) or 0
                add_stats(own, bonus.StatsGranted)
                if own[1] then
                    local pieces = needed == 1 and w.set.piece or w.set.pieces:format(shown(needed))
                    local name = words(bonus.Description)
                    table.insert(own, 1, { text = (name ~= "" and (name .. " ") or "") .. pieces, label = name ~= "" and name or pieces,
                        value = name ~= "" and pieces or "" })
                    group(out, "set", w.set.title, own)
                end
            end
        end
    end

    local function equipped(out, row)
        local worn = trait(row, "Equippable")
        if not worn then return end
        local lines = {}
        add_stats(lines, worn.GrantedStats)
        group(out, "equipped", w.equipped.title, lines)
    end

    local function properties(out, row)
        local lines = {}
        add_stats(lines, row.AdditionalStats)
        group(out, "properties", w.properties.title, lines)
    end

    local function consumed(out, row)
        local food = trait(row, "Consumable")
        if not food then return end
        local lines, back = {}, {}
        add_stats(lines, food.Stats)
        for _, handle in ipairs(list(food.Byproducts)) do
            local name = template_name(handle)
            if name then back[#back + 1] = name end
        end
        line(lines, w.consumed.back, table.concat(back, w.list))
        group(out, "consumed", w.consumed.title, lines)

        local modifier = food.Modifier
        local state = type(modifier) == "table" and trait(modifier, "Modifier", "ModifierStates")
        if not state then return end
        local own, name, lasts = {}, words(state.ModifierName), amount(modifier.ModifierLifetime) or 0
        local about = words(state.ModifierDescription):gsub("^%[DNT[%]}]%s*", "")
        if name ~= "Name" then note(own, name, lasts > 1 and span(lasts, w.units) or "") end
        if about ~= "Description" then note(own, about, "") end
        add_stats(own, state.GrantedStats)
        group(out, "effect", w.effect.title, own)
    end

    local function shelf(out, row)
        local decay = trait(row, "Decayable")
        if not decay then return end
        local lines, lasts = {}, amount(decay.SpoilTime) or 0
        if lasts <= 0 then return end
        line(lines, w.shelf.lasts, span(lasts, w.units))
        line(lines, w.shelf.into, template_name(decay.SpoiledItem))
        group(out, "shelf", w.shelf.title, lines)
    end

    local function building(out, row)
        local piece = trait(row, "Buildable")
        local kind = piece and trait(piece, "Type", "BuildingTypes")
        if not kind then return end
        local lines = {}
        add_stats(lines, kind.Stats)
        group(out, "building", w.building.title, lines)
    end

    local function storage(out, row)
        local lines, sizes = {}, {}
        local holder = trait(row, "Inventory")
        for _, handle in ipairs(list(holder and holder.Inventories)) do
            local info = trait({ Info = handle }, "Info", "InventoryInfo")
            local slots = info and amount(info.StartingSlots) or 0
            if slots > 0 then sizes[#sizes + 1] = shown(slots) end
        end
        line(lines, w.storage.slots, table.concat(sizes, w.plus))
        local tank = trait(row, "Fillable")
        local most, names, unit = tank and amount(tank.MaximumStoredUnits) or 0, {}, ""
        for _, kind in ipairs(list(tank and tank.ResourceTypes)) do
            local wanted = ref(kind.Value)
            local resource = wanted and src.row("IcarusResources", wanted)
            if resource and words(resource.DisplayName) ~= "" then
                names[#names + 1] = words(resource.DisplayName)
                if unit == "" then unit = words(resource.Units) end
            end
        end
        if most > 0 and names[1] then
            if unit ~= "" then unit = " " .. unit end
            line(lines, w.storage.holds, shown(most / 1000, 3) .. unit .. " " .. table.concat(names, w.list))
        end
        group(out, "storage", w.storage.title, lines)
    end

    local function carrying(out, row, weight, stack)
        if weight == nil and row then
            local wanted = ref(row.Itemable)
            local itemable = wanted and src.row("Itemable", wanted)
            weight, stack = itemable and amount(itemable.Weight), itemable and amount(itemable.MaxStack)
        end
        local lines = {}
        if weight and weight > 0 then line(lines, w.carrying.weight, heavy(weight)) end
        if stack and stack > 1 then line(lines, w.carrying.stack, shown(stack)) end
        group(out, "carrying", w.carrying.title, lines)
    end

    local PARTS = { durability, melee, ranged, projectile, armor, equipped, properties, consumed, shelf, building, storage }

    -- The groups of a model item or a D_ItemsStatic row name: { { id, title, lines = { { text, label, value } } } }. Kept: do not change.
    function self.of(item)
        local static, key, weight, stack = item, item, nil, nil
        if type(item) == "table" then
            static = item.static or item.row
            key, weight, stack = item.key or static, amount(item.weight), amount(item.stack)
        end
        if type(static) ~= "string" or type(key) ~= "string" then return {} end
        key = fold(key)
        local out = cache[key]
        if out then return out end
        out = {}
        local row = src.detail("ItemsStatic", static)
        if row then
            for _, part in ipairs(PARTS) do part(out, row) end
        end
        carrying(out, row, weight, stack)
        cache[key] = out
        return out
    end

    -- How many stats were left out so far: no text in D_Stats, hidden by the game, and rows that are not there.
    function self.counts()
        local out = {}
        for kind, held in pairs(self.left) do
            local total = 0
            for _, times in pairs(held) do total = total + times end
            out[kind] = total
        end
        return out
    end

    -- The fields the provider could not give, as "Table.Field".
    function self.unread()
        local out = {}
        for _, problem in ipairs(src.problems) do
            if problem.field then out[#out + 1] = problem.table .. "." .. problem.field end
        end
        return out
    end

    return self
end

return stats
