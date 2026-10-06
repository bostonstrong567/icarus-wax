-- A strict stand-in for the game's data tables as UE4SS hands them to Lua.
-- It raises on what crashes or changes the real game and counts what a reader asks the engine.
--   local tables = dofile("wax/tests/offline/fake_tables.lua")
--   tables.struct(path, parent, fields)   tables.table(name, struct, rows, order)   tables.install()
-- Run it by itself to see each strict behaviour raise:  tools\lua\lua54\lua.exe wax\tests\offline\fake_tables.lua

local tables = { frame = 0 }

local COUNTERS = { "touches", "finds", "misses", "lists", "stale", "grown", "crashes", "misuse", "unknown_names",
                   "rows_asked", "enum_reads", "never_reads" }

-- Every counter back to zero. The tables and structs stay.
function tables.reset()
    for _, name in ipairs(COUNTERS) do tables[name] = 0 end
    tables.asked = {}       -- table name -> row name as it was asked -> how often
end
tables.reset()

local structs, by_path, by_name, listed = {}, {}, {}, {}
local short = nil
local next_address = 0x7FF600000000

local NUMBERS = { Int8Property = true, Int16Property = true, IntProperty = true, Int64Property = true, UInt16Property = true,
                  UInt32Property = true, UInt64Property = true, ByteProperty = true, FloatProperty = true }
local TEXTS = { NameProperty = "None", StrProperty = "", TextProperty = "" }
local SOFTS = { SoftObjectProperty = "TSoftObjectPtrUserdata", SoftClassProperty = "TSoftClassPtrUserdata" }

-- What would crash the game, or change the player's data.
local function crash(what)
    tables.crashes = tables.crashes + 1
    error("CRASH: " .. what, 3)
end

-- What the real objects may allow but a reader has no business doing.
local function misuse(what)
    tables.misuse = tables.misuse + 1
    error("MISUSE: " .. what, 3)
end

-- A check for one wrapper: using it in a later frame raises.
local function stamp(what)
    local born = tables.frame
    return function(key)
        if born ~= tables.frame then
            tables.stale = tables.stale + 1
            error(("STALE: %s was used after its frame (%s)"):format(what, tostring(key)), 3)
        end
        tables.touches = tables.touches + 1
    end
end

local function count_touch() tables.touches = tables.touches + 1 end

-- An object with these members and no others.
local function strict(what, members, check)
    check = check or count_touch
    return setmetatable({}, {
        __index = function(_, key)
            check(key)
            local member = members[key]
            if member == nil then misuse(("%s was asked for %s"):format(what, tostring(key))) end
            return member
        end,
        __newindex = function(_, key) crash(("%s.%s was written"):format(what, tostring(key))) end,
    })
end

local function text(value)
    return strict("a name or text", { ToString = function() return value end })
end

local function soft(path, kind)
    return strict("a soft reference", {
        type = function() return kind end,
        GetObjectID = function()
            return strict("a soft object path", { GetAssetPathName = function() return text(path) end })
        end,
    })
end

local function shape_of(path)
    local shape = structs[path]
    if not shape then error("fake_tables: no struct was declared at " .. tostring(path), 0) end
    return shape
end

-- Own fields and inherited ones, by name. The struct's own definition wins.
local function fields_of(shape)
    if shape.all then return shape.all end
    local all, at = {}, shape
    while at do
        for _, field in ipairs(at.fields) do
            if not all[field.name] then all[field.name] = field end
        end
        at = at.super and shape_of(at.super) or nil
    end
    shape.all = all
    return all
end

local struct_value, array_value

local function value_of(field, value, what, holder, key)
    local kind = field.kind
    if kind == "BoolProperty" then return value == true end
    if NUMBERS[kind] then return value or 0 end
    if kind == "EnumProperty" then
        tables.enum_reads = tables.enum_reads + 1
        return value or 0
    end
    if TEXTS[kind] then return text(value or TEXTS[kind]) end
    if SOFTS[kind] then return soft(value or "None", SOFTS[kind]) end
    if kind == "StructProperty" or kind == "ArrayProperty" then
        if value == nil then
            value = {}
            holder[key] = value
        end
        if kind == "StructProperty" then return struct_value(field.struct, value, what) end
        return array_value(field, value, what)
    end
    tables.never_reads = tables.never_reads + 1
    error(("NEVER: %s is a %s, which a reader must not read"):format(what, kind), 3)
end

function struct_value(path, data, what, poison)
    local all = fields_of(shape_of(path))
    local check = stamp(what)
    return setmetatable({}, {
        __index = function(_, key)
            check(key)
            if type(key) ~= "string" then crash(("%s was indexed with a %s"):format(what, type(key))) end
            local field = all[key]
            if not field then misuse(("%s has no field named %s"):format(path, key)) end
            if poison == key then error(("the engine could not read %s.%s"):format(what, key), 2) end
            return value_of(field, data[key], what .. "." .. key, data, key)
        end,
        __newindex = function(_, key) crash(("%s.%s was written: that changes the player's game"):format(what, tostring(key))) end,
    })
end

function array_value(field, data, what)
    local check = stamp(what)
    local element = { name = "element", kind = field.inner, struct = field.struct }
    local grown = 0
    return setmetatable({}, {
        __index = function(_, key)
            check(key)
            if key == "GetArrayNum" then
                return function()
                    check(key)
                    return #data
                end
            end
            if math.type(key) ~= "integer" then misuse(("%s was asked for %s"):format(what, tostring(key))) end
            local count = #data
            if key == count + 1 then
                -- as in the game: reading one past the end makes the array one longer
                tables.grown = tables.grown + 1
                grown = grown + 1
                if grown > 3 then error(what .. " grows each time its end is read, so a loop that waits for nil never ends", 2) end
                if element.kind == "BoolProperty" then
                    data[key] = false
                elseif NUMBERS[element.kind] or element.kind == "EnumProperty" then
                    data[key] = 0
                elseif TEXTS[element.kind] then
                    data[key] = TEXTS[element.kind]
                else
                    data[key] = {}
                end
            elseif key < 1 or key > count then
                misuse(("%s[%d] is out of range (it has %d)"):format(what, key, count))
            end
            return value_of(element, data[key], what .. "[" .. key .. "]", data, key)
        end,
        __len = function()
            check("#")
            return #data
        end,
        __newindex = function(_, key) crash(("%s[%s] was written: that changes the player's game"):format(what, tostring(key))) end,
    })
end

-- A property as ForEachProperty hands it out. What GetStruct() and GetInner() return says its name and nothing else.
local function property(field, is_open)
    local function check(key)
        if not is_open() then
            tables.stale = tables.stale + 1
            error(("STALE: the property %s was used after ForEachProperty returned (%s)"):format(field.name, tostring(key)), 3)
        end
        tables.touches = tables.touches + 1
    end
    local function class_of(kind)
        return strict("a property's class", { GetFName = function() return text(kind) end }, check)
    end
    local function struct_of(path)
        return strict("a struct from GetStruct()", { GetFullName = function() return "ScriptStruct " .. path end }, check)
    end
    return strict("the property " .. field.name, {
        GetFName = function() return text(field.name) end,
        GetClass = function() return class_of(field.kind) end,
        GetStruct = function()
            if field.kind ~= "StructProperty" then crash("GetStruct() on a " .. field.kind) end
            return struct_of(field.struct)
        end,
        GetInner = function()
            if field.kind ~= "ArrayProperty" then crash("GetInner() on a " .. field.kind) end
            return strict("a property from GetInner()", {
                GetClass = function() return class_of(field.inner) end,
                GetStruct = function()
                    if field.inner ~= "StructProperty" then crash("GetStruct() on an array of " .. field.inner) end
                    return struct_of(field.struct)
                end,
            }, check)
        end,
    }, check)
end

local NO_STRUCT = strict("a struct that does not exist", { IsValid = function() return false end })

local function struct_object(shape)
    local what = "the struct " .. shape.path
    local check = stamp(what)
    return strict(what, {
        IsValid = function() return true end,
        type = function() return "UScriptStruct" end,
        GetFullName = function() return "ScriptStruct " .. shape.path end,
        -- own fields only, as the engine does it
        ForEachProperty = function(_, fn)
            local open = true
            local function is_open() return open end
            local ok, problem = pcall(function()
                for _, field in ipairs(shape.fields) do
                    if fn(property(field, is_open)) ~= nil then
                        tables.misuse = tables.misuse + 1
                        error("MISUSE: a ForEachProperty callback returned a value, which may end the walk early", 0)
                    end
                end
            end)
            open = false
            if not ok then error(problem, 0) end
        end,
        GetSuperStruct = function()
            if not shape.super then return NO_STRUCT end
            return strict("a struct from GetSuperStruct()", {
                IsValid = function() return true end,
                GetFullName = function() return "ScriptStruct " .. shape.super end,
            }, check)
        end,
    }, check)
end

local INVALID = setmetatable({}, { __index = function(_, key)
    tables.touches = tables.touches + 1
    if key == "IsValid" then return function() return false end end
    crash(("%s was used on an object that is not valid"):format(tostring(key)))
end })
tables.INVALID = INVALID

local handle

local function find_row(state, name)
    if type(name) ~= "string" then crash("FindRow was given a " .. type(name)) end
    tables.rows_asked = tables.rows_asked + 1
    local asked = tables.asked[state.name]
    if not asked then
        asked = {}
        tables.asked[state.name] = asked
    end
    asked[name] = (asked[name] or 0) + 1
    local key = name:lower()
    local row = state.rows[key]
    if row == nil then
        -- in the game this name now sits in the engine's name table until the game closes
        tables.unknown_names = tables.unknown_names + 1
        return nil
    end
    return struct_value(state.struct, row, state.name .. "." .. name, state.poison[key])
end

function handle(state)
    local what = "the table " .. state.name
    local check = stamp(what)
    local methods = {
        IsValid = function() return true end,
        type = function() return "UDataTable" end,
        GetAddress = function() return state.address end,
        GetFName = function() return text(state.path:match("([^%.]+)$")) end,
        GetFullName = function() return state.class .. " " .. state.path end,
        GetRowNames = function()
            local out = {}
            for i, name in ipairs(state.order) do out[i] = name end
            return out
        end,
        GetRowStruct = function()
            return strict("a struct from GetRowStruct()", {
                IsValid = function() return true end,
                GetFullName = function() return "ScriptStruct " .. state.struct end,
            }, check)
        end,
        FindRow = function(_, name) return find_row(state, name) end,
    }
    return setmetatable({}, {
        __index = function(_, key)
            check(key)
            if key == "MetaTable" then return state.meta and handle(state.meta) or INVALID end
            local method = methods[key]
            if not method then misuse(("%s was asked for %s"):format(what, tostring(key))) end
            return method
        end,
        __len = function()
            check("#")
            return #state.order
        end,
        __newindex = function(_, key) crash(("%s.%s was written"):format(what, tostring(key))) end,
    })
end

-- Declares a struct. `fields` is a list of { name, property class, struct = path, inner = property class }.
function tables.struct(path, super, fields)
    local shape = { path = path, super = super, fields = {} }
    for i, field in ipairs(fields or {}) do
        shape.fields[i] = { name = field[1], kind = field[2], struct = field.struct, inner = field.inner }
    end
    structs[path] = shape
    return shape
end

local function new_table(name, struct, rows, order, class, path)
    next_address = next_address + 0x1000
    local state = { name = name, struct = struct, rows = {}, order = {}, address = next_address, hidden = false,
                    class = class, path = path, poison = {} }
    for key, row in pairs(rows) do state.rows[key:lower()] = row end
    for i, row_name in ipairs(order) do
        if not state.rows[row_name:lower()] then error(("fake_tables: %s lists %s but has no such row"):format(name, row_name), 3) end
        state.order[i] = row_name
    end
    by_path[path] = state
    return state
end

-- Declares a table the game lists. `rows` maps a row name to plain data and `order` gives each name as the engine spells it.
function tables.table(name, struct, rows, order)
    local state = new_table(name, struct, rows, order, name .. "Table", "/Engine/Transient.D_" .. name)
    by_name[name] = state
    listed[#listed + 1] = state
    return state
end

-- Declares the meta table of a table. The game does not list these: they are reached through MetaTable.
function tables.meta(name, struct, rows, order)
    local owner = by_name[name] or error("fake_tables: no table named " .. tostring(name), 2)
    owner.meta = new_table(name .. "_METATABLE", struct, rows, order, "IcarusMetaTable", "/Engine/Transient.D_" .. name .. "_METATABLE")
    return owner.meta
end

-- Adds `count` small tables, so the list is as long as the game's.
function tables.fill(count)
    tables.struct("/Script/Icarus.FillerRow", nil, { { "Value", "IntProperty" } })
    for i = 1, count do
        tables.table(("Filler%03d"):format(i), "/Script/Icarus.FillerRow", { Only = { Value = i } }, { "Only" })
    end
end

local function state_of(name)
    local owner, meta = tostring(name):match("^(.-)(_METATABLE)$")
    local state = meta and by_name[owner] and by_name[owner].meta or by_name[name]
    return state or error("fake_tables: no table named " .. tostring(name), 3)
end

-- The table is another object from now on, as after the game made it again.
function tables.move(name)
    next_address = next_address + 0x1000
    state_of(name).address = next_address
end

-- The table cannot be found (true) or can again (false).
function tables.hide(name, hidden) state_of(name).hidden = hidden ~= false end

function tables.set_rows(name, rows, order)
    local state = state_of(name)
    state.rows, state.order = {}, {}
    for key, row in pairs(rows) do state.rows[key:lower()] = row end
    for i, row_name in ipairs(order) do state.order[i] = row_name end
end

-- Reading `field` of this row raises, as when UE4SS cannot read a value.
function tables.poison(name, row, field) state_of(name).poison[row:lower()] = field end

-- FindAllOf gives only the first `count` tables, as while the game is still loading. nil gives all again.
function tables.short_list(count) short = count end

-- A new frame: everything handed out so far must not be used again.
function tables.next_frame() tables.frame = tables.frame + 1 end

function tables.listed() return #listed end

-- How many different names FindRow was asked for in a table, and the most often any one was asked.
function tables.asked_rows(name)
    local distinct, most = 0, 0
    for _, times in pairs(tables.asked[name] or {}) do
        distinct = distinct + 1
        if times > most then most = times end
    end
    return distinct, most
end

function tables.install()
    function StaticFindObject(path)
        tables.touches = tables.touches + 1
        tables.finds = tables.finds + 1
        if type(path) ~= "string" then crash("StaticFindObject was given a " .. type(path)) end
        local shape = structs[path]
        if shape then return struct_object(shape) end
        local state = by_path[path]
        if state and not state.hidden then return handle(state) end
        -- a miss costs 20 to 60 ms in the game
        tables.misses = tables.misses + 1
        return INVALID
    end
    function FindAllOf(class_name)
        tables.touches = tables.touches + 1
        tables.lists = tables.lists + 1
        if class_name ~= "IcarusDataTable" then return nil end
        local out = {}
        for index, state in ipairs(listed) do
            if short and index > short then break end
            if not state.hidden then out[#out + 1] = handle(state) end
        end
        return #out > 0 and out or nil
    end
end

-- A small copy of the game's shapes: recipes, items and their meta table, tag queries. Returns what was put in.
function tables.sample(options)
    options = options or {}
    local S, U, G = "/Script/Icarus.", "/Script/IcarusUtilities.", "/Script/GameplayTags."
    tables.struct("/Script/Engine.TableRowBase", nil, {})
    tables.struct(U .. "IcarusTableRowBase", "/Script/Engine.TableRowBase",
        { { "CachedHardReferences", "ArrayProperty", inner = "ObjectProperty" } })
    tables.struct(U .. "RowHandle", nil,
        { { "DataTablePtr", "WeakObjectProperty" }, { "RowName", "NameProperty" }, { "DataTableName", "NameProperty" } })
    for _, name in ipairs({ "ItemsStatic", "ItemTemplate", "Talents", "RecipeSets", "CharacterFlags", "Itemable", "TagQueries",
                            "FeatureLevels" }) do
        tables.struct(S .. name .. "RowHandle", U .. "RowHandle", {})
    end
    tables.struct(U .. "MultiRowHandle", nil, { { "RowName", "NameProperty" } })
    tables.struct(S .. "FlagsMultiRowHandle", U .. "MultiRowHandle", { { "DataTableName", "EnumProperty" } })
    tables.struct(U .. "RowEnum", nil, { { "Value", "NameProperty" } })
    tables.struct(S .. "IcarusResourcesEnum", U .. "RowEnum", {})
    tables.struct(S .. "CraftingInput", nil,
        { { "Element", "StructProperty", struct = S .. "ItemsStaticRowHandle" }, { "Count", "IntProperty" } })
    tables.struct(S .. "QueryInput", nil,
        { { "Query", "StructProperty", struct = S .. "TagQueriesRowHandle" }, { "Count", "IntProperty" } })
    tables.struct(S .. "ResourceItem", nil,
        { { "Type", "StructProperty", struct = S .. "IcarusResourcesEnum" }, { "RequiredUnits", "IntProperty" } })
    tables.struct(S .. "CraftingOutput", nil,
        { { "Element", "StructProperty", struct = S .. "ItemTemplateRowHandle" }, { "Count", "IntProperty" } })
    tables.struct(S .. "ProcessorRecipe", U .. "IcarusTableRowBase", {
        { "bForceDisableRecipe", "BoolProperty" },
        { "Requirement", "StructProperty", struct = S .. "TalentsRowHandle" },
        { "SessionRequirement", "StructProperty", struct = S .. "FlagsMultiRowHandle" },
        { "CharacterRequirement", "StructProperty", struct = S .. "CharacterFlagsRowHandle" },
        { "RequiredMillijoules", "IntProperty" },
        { "RecipeSets", "ArrayProperty", inner = "StructProperty", struct = S .. "RecipeSetsRowHandle" },
        { "Inputs", "ArrayProperty", inner = "StructProperty", struct = S .. "CraftingInput" },
        { "QueryInputs", "ArrayProperty", inner = "StructProperty", struct = S .. "QueryInput" },
        { "ResourceInputs", "ArrayProperty", inner = "StructProperty", struct = S .. "ResourceItem" },
        { "Outputs", "ArrayProperty", inner = "StructProperty", struct = S .. "CraftingOutput" },
        { "Refundable", "EnumProperty" },
        { "RefundSteps", "ArrayProperty", inner = "EnumProperty" },
        { "ExperienceMultiplier", "FloatProperty" },
        { "Overrides", "MapProperty" },
        { "OnCrafted", "MulticastInlineDelegateProperty" },
        { "Preview", "ObjectProperty" },
    })
    tables.struct(S .. "ItemableData", U .. "IcarusTableRowBase", {
        { "Behaviour", "SoftClassProperty" }, { "DisplayName", "TextProperty" }, { "Icon", "SoftObjectProperty" },
        { "Description", "TextProperty" }, { "FieldGuideKeywords", "ArrayProperty", inner = "TextProperty" },
        { "Weight", "IntProperty" }, { "bAllowZeroWeight", "BoolProperty" }, { "MaxStack", "IntProperty" },
    })
    tables.struct(G .. "GameplayTag", nil, { { "TagName", "NameProperty" } })
    tables.struct(G .. "GameplayTagContainer", nil, {
        { "GameplayTags", "ArrayProperty", inner = "StructProperty", struct = G .. "GameplayTag" },
        { "ParentTags", "ArrayProperty", inner = "StructProperty", struct = G .. "GameplayTag" },
    })
    tables.struct(G .. "GameplayTagQuery", nil, {
        { "TokenStreamVersion", "IntProperty" },
        { "TagDictionary", "ArrayProperty", inner = "StructProperty", struct = G .. "GameplayTag" },
        { "QueryTokenStream", "ArrayProperty", inner = "ByteProperty" },
        { "UserDescription", "StrProperty" },
    })
    tables.struct(S .. "TagQueryData", U .. "IcarusTableRowBase",
        { { "Query", "StructProperty", struct = G .. "GameplayTagQuery" } })
    tables.struct(S .. "ItemStaticData", U .. "IcarusTableRowBase", {
        { "Itemable", "StructProperty", struct = S .. "ItemableRowHandle" },
        { "Generated_Tags", "StructProperty", struct = G .. "GameplayTagContainer" },
    })
    tables.struct(U .. "RowMetadata", "/Script/Engine.TableRowBase", {
        { "RequiredFeatureLevel", "StructProperty", struct = S .. "FeatureLevelsRowHandle" },
        { "bIsDeprecated", "BoolProperty" }, { "Notes", "StrProperty" }, { "ExtraMetadata", "MapProperty" },
    })
    -- a row struct with a field called Name, as two of the game's tables have
    tables.struct(S .. "LogCategory", U .. "IcarusTableRowBase", { { "Name", "StrProperty" }, { "Verbosity", "IntProperty" } })

    local function item(name) return { RowName = name, DataTableName = "D_ItemsStatic" } end
    local function made(name) return { RowName = name, DataTableName = "D_ItemTemplate" } end
    local function set(name) return { RowName = name, DataTableName = "D_RecipeSets" } end
    local function talent(name) return { RowName = name, DataTableName = "D_Talents" } end
    local recipes = {
        Stone_Pickaxe = { Requirement = talent("Stone_Pickaxe"), RequiredMillijoules = 2500, RecipeSets = { set("Character") },
            Inputs = { { Element = item("Fiber"), Count = 10 }, { Element = item("Stick"), Count = 4 }, { Element = item("Stone"), Count = 6 } },
            Outputs = { { Element = made("Stone_Pickaxe"), Count = 1 } }, ExperienceMultiplier = 1.0, Refundable = 2 },
        -- the engine spells this input "bone": names keep the letter case they were first seen with
        Bone_Knife = { Requirement = talent("Bone_Knife"), RequiredMillijoules = 3750, RecipeSets = { set("Character") },
            Inputs = { { Element = item("Wood"), Count = 2 }, { Element = item("Leather"), Count = 2 }, { Element = item("bone"), Count = 20 } },
            Outputs = { { Element = made("Bone_Knife"), Count = 1 } }, ExperienceMultiplier = 1.0, Refundable = 1,
            RefundSteps = { 3, 1 } },
        Dough_Bread = { Requirement = talent("Dough_Bread"), RequiredMillijoules = 2500,
            RecipeSets = { set("Kitchen_Bench"), set("Advanced_Kitchen_Bench") },
            Inputs = { { Element = item("Flour"), Count = 3 }, { Element = item("Yeast"), Count = 1 } },
            ResourceInputs = { { Type = { Value = "Water" }, RequiredUnits = 100 } },
            Outputs = { { Element = made("Dough_Bread"), Count = 1 } }, ExperienceMultiplier = 0.5 },
        Gold_Bed = { Requirement = talent("Gold_Decorations"), SessionRequirement = { RowName = "Art_Deco_Pack", DataTableName = 4 },
            RequiredMillijoules = 5000, RecipeSets = { set("Rustic_Decorations_Bench") }, bForceDisableRecipe = true,
            Inputs = { { Element = item("Refined_Gold"), Count = 8 }, { Element = item("Stone"), Count = 20 } },
            QueryInputs = { { Query = { RowName = "Any_Fabric", DataTableName = "D_TagQueries" }, Count = 6 } },
            Outputs = { { Element = made("Gold_Bed"), Count = 1 } }, ExperienceMultiplier = 1.0 },
        Nothing_In = { RequiredMillijoules = 1 },
    }
    local order = { "Stone_Pickaxe", "Bone_Knife", "Dough_Bread", "Gold_Bed", "Nothing_In" }
    for i = 1, options.recipes or 55 do
        local name = ("Made_%02d"):format(i)
        local row = { Requirement = talent(name), RequiredMillijoules = 1000 + i, RecipeSets = {}, Inputs = {}, Outputs = {},
                      ExperienceMultiplier = 1.0 }
        for j = 1, i % 3 do row.RecipeSets[j] = set("Bench_" .. j) end
        for j = 1, i % 4 + 1 do row.Inputs[j] = { Element = item("Part_" .. j), Count = i + j } end
        for j = 1, i % 2 + 1 do row.Outputs[j] = { Element = made(name), Count = j } end
        recipes[name] = row
        -- the engine keeps one spelling per name, not always the file's
        order[#order + 1] = i % 7 == 0 and name:upper() or name
    end
    local total = { recipes = #order, inputs = 0, outputs = 0, sets = 0 }
    for _, row in pairs(recipes) do
        total.inputs = total.inputs + #(row.Inputs or {})
        total.outputs = total.outputs + #(row.Outputs or {})
        total.sets = total.sets + #(row.RecipeSets or {})
    end
    tables.table("ProcessorRecipes", S .. "ProcessorRecipe", recipes, order)

    tables.table("Itemable", S .. "ItemableData", {
        Item_Wood = { DisplayName = "Wood", Icon = "/Game/Assets/2DArt/UI/Items/Item_Icons/Resources/ITEM_Wood.ITEM_Wood",
                      Description = "A length of timber.", Weight = 150, MaxStack = 100, FieldGuideKeywords = { "log", "timber" } },
        Item_Fiber = { DisplayName = "Fiber", Icon = "/Game/Assets/2DArt/UI/Items/Item_Icons/Resources/ITEM_Fibre.ITEM_Fibre",
                       Weight = 10, MaxStack = 200, Behaviour = "/Game/BP/Items/BP_Fiber.BP_Fiber_C" },
        Item_Ghost = { DisplayName = "", Weight = 0, bAllowZeroWeight = true, MaxStack = 1 },
    }, { "Item_Wood", "Item_Fiber", "Item_Ghost" })

    local function tags(...)
        local out = {}
        for i, name in ipairs({ ... }) do out[i] = { TagName = name } end
        return out
    end
    tables.table("ItemsStatic", S .. "ItemStaticData", {
        Wood = { Itemable = { RowName = "Item_Wood", DataTableName = "D_Itemable" },
                 Generated_Tags = { GameplayTags = tags("Item.Resource.Wood"), ParentTags = tags("Item", "Item.Resource") } },
        Fish_03 = { Itemable = { RowName = "Item_Fish_03", DataTableName = "D_Itemable" },
                    Generated_Tags = { GameplayTags = tags("NPC.Fish.Saltwater", "Item.Food"), ParentTags = tags("NPC", "NPC.Fish", "Item") } },
        Kit_Radar = { Itemable = { RowName = "Item_Kit_Radar", DataTableName = "D_Itemable" } },
    }, { "Wood", "Fish_03", "Kit_Radar" })
    local function level(name) return { RowName = name, DataTableName = "D_FeatureLevels" } end
    tables.meta("ItemsStatic", U .. "RowMetadata", {
        Wood = { RequiredFeatureLevel = level("Core") },
        Fish_03 = { RequiredFeatureLevel = level("NewFrontiers"), Notes = "salt water" },
        Kit_Radar = { RequiredFeatureLevel = level("Core"), bIsDeprecated = true },
    }, { "Wood", "Fish_03", "Kit_Radar" })

    tables.table("TagQueries", S .. "TagQueryData", {
        FieldGuide_Hide = { Query = { TokenStreamVersion = 0, TagDictionary = tags("Item.Quest", "FieldGuide.BlackList"),
                                      QueryTokenStream = { 0, 1, 5, 2, 1, 6, 0, 1 }, UserDescription = "hidden from the guide" } },
    }, { "FieldGuide_Hide" })

    tables.table("LogCategories", S .. "LogCategory", {
        LogTemp = { Name = "Temporary", Verbosity = 3 },
    }, { "LogTemp" })

    tables.struct(S .. "RecipeSet", U .. "IcarusTableRowBase", {
        { "RecipeSetName", "TextProperty" }, { "RecipeSetIcon", "SoftObjectProperty" }, { "ExperienceMultiplier", "FloatProperty" },
        { "bAllowRefundOfRecipesOnDestroy", "BoolProperty" },
    })
    tables.table("RecipeSets", S .. "RecipeSet", {
        Character = { RecipeSetName = "Character", RecipeSetIcon = "/Game/Assets/2DArt/UI/Icons/Icon_PlayerCrafting.Icon_PlayerCrafting",
                      ExperienceMultiplier = 0.25 },
        Kitchen_Bench = { RecipeSetName = "Kitchen Bench", ExperienceMultiplier = 10.0, bAllowRefundOfRecipesOnDestroy = true },
    }, { "Character", "Kitchen_Bench" })

    tables.fill(options.fill or 255)
    return total
end

-- Forgets every struct and table, for a file that builds more than one set.
function tables.clear()
    structs, by_path, by_name, listed, short = {}, {}, {}, {}, nil
    tables.frame = 0
    tables.reset()
end

local function self_test()
    local passed, failed = 0, 0
    local function check(what, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        print(("%s  %s%s"):format(ok and "ok  " or "FAIL", what, detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
    -- fn must raise with `fragment` in the message, and `counter` must go up by one
    local function raises(what, counter, fragment, fn)
        local before = counter and tables[counter] or 0
        local ok, problem = pcall(fn)
        local counted = not counter or tables[counter] == before + 1
        check(what, not ok and tostring(problem):find(fragment, 1, true) ~= nil and counted, ok and "did not raise" or problem)
    end

    local total = tables.sample()
    tables.install()
    local path = "/Engine/Transient.D_ProcessorRecipes"

    local recipes = StaticFindObject(path)
    check("a table is a UDataTable with a length, an address and its row struct",
        recipes:IsValid() and recipes:type() == "UDataTable" and #recipes == total.recipes and math.type(recipes:GetAddress()) == "integer"
        and recipes:GetRowStruct():GetFullName() == "ScriptStruct /Script/Icarus.ProcessorRecipe")
    check("GetRowNames gives plain strings in the engine's spelling", recipes:GetRowNames()[11] == "Made_06"
        and recipes:GetRowNames()[12] == "MADE_07")
    local knife = recipes:FindRow("bone_knife")
    check("a row is found whatever the letter case", knife ~= nil and knife.RequiredMillijoules == 3750)
    check("names and text have ToString", knife.Requirement.RowName:ToString() == "Bone_Knife")
    check("a handle's inherited fields are there", knife.Inputs[3].Element.DataTableName:ToString() == "D_ItemsStatic")
    check("a field the row leaves out reads as its empty value", knife.bForceDisableRecipe == false
        and knife.SessionRequirement.RowName:ToString() == "None" and knife.QueryInputs:GetArrayNum() == 0)
    local wood = StaticFindObject("/Engine/Transient.D_Itemable"):FindRow("Item_Wood")
    check("a soft reference gives its path through GetObjectID():GetAssetPathName():ToString()",
        wood.Icon:GetObjectID():GetAssetPathName():ToString():find("ITEM_Wood", 1, true) ~= nil and wood.Icon:type() == "TSoftObjectPtrUserdata")
    check("a soft reference to nothing is None", wood.Behaviour:GetObjectID():GetAssetPathName():ToString() == "None")
    local stream = StaticFindObject("/Engine/Transient.D_TagQueries"):FindRow("FieldGuide_Hide").Query.QueryTokenStream
    check("an array of bytes reads as numbers", stream:GetArrayNum() == 8 and stream[3] == 5)
    local meta = StaticFindObject("/Engine/Transient.D_ItemsStatic").MetaTable
    check("MetaTable is another table", meta:IsValid() and meta:type() == "UDataTable" and #meta == 3
        and meta:FindRow("Kit_Radar").bIsDeprecated == true)
    check("a table without one has an invalid MetaTable", recipes.MetaTable:IsValid() == false)
    local listed_now = FindAllOf("IcarusDataTable")
    check("FindAllOf lists the tables and no meta table", #listed_now == tables.listed() and tables.listed() >= 250)
    tables.short_list(40)
    check("it can be told to give a short list", #FindAllOf("IcarusDataTable") == 40)
    tables.short_list(nil)
    check("another class finds nothing", FindAllOf("Actor") == nil)

    raises("FindRow with a number raises", "crashes", "FindRow was given a number", function() recipes:FindRow(12) end)
    local unknown = tables.unknown_names
    check("FindRow with a name the table lacks is nil and is counted", recipes:FindRow("No_Such_Row") == nil
        and tables.unknown_names == unknown + 1 and tables.asked.ProcessorRecipes.No_Such_Row == 1)
    check("every name asked is recorded", tables.asked.ProcessorRecipes.bone_knife == 1)
    raises("a struct indexed with a number raises", "crashes", "indexed with a number", function() return knife[1] end)
    raises("a field the struct does not have raises", "misuse", "has no field named Inputz", function() return knife.Inputz end)
    raises("writing to a row raises", "crashes", "was written", function() knife.RequiredMillijoules = 1 end)
    raises("a map field raises", "never_reads", "MapProperty", function() return knife.Overrides end)
    raises("a delegate field raises", "never_reads", "MulticastInlineDelegateProperty", function() return knife.OnCrafted end)
    raises("an object field raises", "never_reads", "ObjectProperty", function() return knife.Preview end)
    raises("a weak object field raises", "never_reads", "WeakObjectProperty", function() return knife.Requirement.DataTablePtr end)
    raises("an element of an array of objects raises", "never_reads", "ObjectProperty", function()
        local kept = knife.CachedHardReferences
        return kept[1]
    end)
    local enums = tables.enum_reads
    check("every enum read is counted", knife.Refundable == 1 and knife.SessionRequirement.DataTableName == 0
        and knife.RefundSteps[2] == 1 and tables.enum_reads == enums + 3)

    local inputs = knife.Inputs
    local grown = tables.grown
    check("reading one past the end of an array makes it longer and is counted", inputs:GetArrayNum() == 3 and inputs[4] ~= nil
        and inputs:GetArrayNum() == 4 and tables.grown == grown + 1)
    raises("an index further out raises", "misuse", "out of range", function() return inputs[9] end)
    raises("index 0 raises", "misuse", "out of range", function() return inputs[0] end)
    raises("a loop that waits for nil is stopped", nil, "never ends", function()
        for _ in ipairs(recipes:FindRow("Stone_Pickaxe").Inputs) do end
    end)
    raises("an array asked for a member it should not be asked for raises", "misuse", "ForEach", function() return inputs.ForEach end)

    raises("a name asked for anything but ToString raises", "misuse", "GetComparisonIndex",
        function() return knife.Requirement.RowName:GetComparisonIndex() end)
    raises("anything but IsValid on an invalid object raises", "crashes", "not valid",
        function() return StaticFindObject("/Engine/Transient.D_Nothing"):GetRowNames() end)
    check("and that find was a miss", tables.misses == 1)
    raises("StaticFindObject with a number raises", "crashes", "StaticFindObject was given a number", function() StaticFindObject(5) end)

    local struct = StaticFindObject("/Script/Icarus.ProcessorRecipe")
    local seen, kept = {}, nil
    struct:ForEachProperty(function(p)
        seen[#seen + 1] = p:GetFName():ToString() .. ":" .. p:GetClass():GetFName():ToString()
        if p:GetFName():ToString() == "Inputs" then kept = p end
    end)
    check("ForEachProperty gives the struct's own fields only", #seen == 16 and seen[1] == "bForceDisableRecipe:BoolProperty"
        and seen[7] == "Inputs:ArrayProperty", #seen)
    check("GetSuperStruct names the parent", struct:GetSuperStruct():IsValid()
        and struct:GetSuperStruct():GetFullName() == "ScriptStruct /Script/IcarusUtilities.IcarusTableRowBase")
    check("a struct without a parent has an invalid one", StaticFindObject("/Script/Icarus.CraftingInput"):GetSuperStruct():IsValid() == false)
    raises("a parent struct asked for its properties raises", "misuse", "ForEachProperty",
        function() struct:GetSuperStruct():ForEachProperty(function() end) end)
    raises("a property used after ForEachProperty returned raises", "stale", "after ForEachProperty returned",
        function() return kept:GetFName() end)
    struct:ForEachProperty(function(p)
        local name = p:GetFName():ToString()
        if name == "Requirement" then
            check("GetStruct() says its full name", p:GetStruct():GetFullName() == "ScriptStruct /Script/Icarus.TalentsRowHandle")
            raises("and nothing else", "misuse", "ForEachProperty", function() p:GetStruct():ForEachProperty(function() end) end)
            raises("GetInner() on a struct property raises", "crashes", "GetInner() on a StructProperty", function() p:GetInner() end)
        elseif name == "Inputs" then
            local inner = p:GetInner()
            check("GetInner() says its class and its struct's full name", inner:GetClass():GetFName():ToString() == "StructProperty"
                and inner:GetStruct():GetFullName() == "ScriptStruct /Script/Icarus.CraftingInput")
            raises("and nothing else", "misuse", "GetFName", function() return inner:GetFName() end)
        elseif name == "RequiredMillijoules" then
            raises("GetStruct() on a number property raises", "crashes", "GetStruct() on a IntProperty", function() p:GetStruct() end)
        elseif name == "RefundSteps" then
            raises("GetStruct() on the inner of an array of enums raises", "crashes", "array of EnumProperty",
                function() p:GetInner():GetStruct() end)
        end
    end)
    raises("a ForEachProperty callback that returns a value raises", "misuse", "returned a value",
        function() struct:ForEachProperty(function() return true end) end)

    tables.poison("Itemable", "Item_Fiber", "Weight")
    raises("a poisoned field raises as a failed engine read", nil, "could not read",
        function() return StaticFindObject("/Engine/Transient.D_Itemable"):FindRow("Item_Fiber").Weight end)

    local row = recipes:FindRow("Dough_Bread")
    local resources = row.ResourceInputs
    local first = resources[1]
    local name = first.Type.Value
    tables.next_frame()
    raises("a table used after its frame raises", "stale", "after its frame", function() return recipes:IsValid() end)
    raises("a row used after its frame raises", "stale", "after its frame", function() return row.RequiredMillijoules end)
    raises("an array used after its frame raises", "stale", "after its frame", function() return resources:GetArrayNum() end)
    raises("a struct from an array used after its frame raises", "stale", "after its frame", function() return first.RequiredUnits end)
    raises("a struct object used after its frame raises", "stale", "after its frame", function() return struct:GetFullName() end)
    check("a name read before the frame ended is still text", name:ToString() == "Water")

    local address = StaticFindObject(path):GetAddress()
    tables.move("ProcessorRecipes")
    check("a moved table has another address", StaticFindObject(path):GetAddress() ~= address)
    tables.hide("ProcessorRecipes")
    check("a hidden table is not found and not listed", StaticFindObject(path):IsValid() == false
        and #FindAllOf("IcarusDataTable") == tables.listed() - 1)
    tables.hide("ProcessorRecipes", false)
    check("and is back when shown again", StaticFindObject(path):IsValid() == true)

    print(("fake_tables: %d passed, %d failed"):format(passed, failed))
    os.exit(failed == 0 and 0 or 1)
end

if arg and arg[0] and arg[0]:gsub("\\", "/"):find("fake_tables%.lua$") then self_test() end

return tables
