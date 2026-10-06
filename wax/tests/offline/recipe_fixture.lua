-- Invented tables for the Recipe Browser suites, one row per case, and a stand-in for game.Data that serves them.
--   local fixture = dofile("wax/tests/offline/recipe_fixture.lua")
--   local provider = fixture.provider()          -- strict rows: reading a field nobody asked for raises
--   local other = fixture.serve(fixture.copy())  -- the same over a copy a test may change first

local fixture = {}

local function h(name, table_name) return { RowName = name, DataTableName = table_name } end

local function tagged(...)
    local list = {}
    for position, name in ipairs({ ... }) do list[position] = { TagName = name } end
    return { GameplayTags = list }
end

local function query(names, stream)
    local dictionary = {}
    for position, name in ipairs(names) do dictionary[position] = { TagName = name } end
    return { TagDictionary = dictionary, QueryTokenStream = stream }
end

local function level(name) return { RequiredFeatureLevel = { RowName = name } } end

local function static(name, tags, extra)
    local row = { Name = name, Itemable = h("Item_" .. name), Manual_Tags = tagged(table.unpack(tags)),
        Generated_Tags = tagged(table.unpack(tags)) }
    for key, value in pairs(extra or {}) do row[key] = value end
    return row
end

local function itemable(name, label, weight, stack)
    return { Name = "Item_" .. name, DisplayName = label, Icon = "/Game/Fixture/ITEM_" .. name .. ".ITEM_" .. name,
        Weight = weight, MaxStack = stack }
end

local function template(name, static_name, stat, value)
    local row = { Name = name, ItemStaticData = h(static_name or name) }
    if stat then row.ItemCustomStats = { { Stat = { Value = stat }, Value = value } } end
    return row
end

local function input(name, count) return { Element = h(name, "D_ItemsStatic"), Count = count } end
local function output(name, count) return { Element = h(name, "D_ItemTemplate"), Count = count } end
local function resource(name, units) return { Type = { Value = name }, RequiredUnits = units } end

local function sets(...)
    local list = {}
    for position, name in ipairs({ ... }) do list[position] = h(name, "D_RecipeSets") end
    return list
end

local T = {}

T.TagQueries = {
    defaults = { Query = { TagDictionary = {}, QueryTokenStream = {} } },
    rows = {
        -- hidden: any of Guide.Hide, Thing.Secret, and not Guide.Show
        { Name = "FieldGuide_Hide", Query = query({ "Guide.Hide", "Thing.Secret", "Guide.Show" }, { 0, 1, 5, 2, 1, 2, 0, 1, 3, 1, 2 }) },
        { Name = "Any_Tool", Query = query({ "Thing.Tool" }, { 0, 1, 1, 1, 0 }) },
        { Name = "Any_Food", Query = query({ "Thing.Food" }, { 0, 1, 1, 1, 0 }) },
        { Name = "Any_Bench", Query = query({ "Trait.Bench" }, { 0, 1, 1, 1, 0 }) },
        { Name = "Any_Fish", Query = query({ "Thing.Food.Fish" }, { 0, 1, 1, 1, 0 }) },
        { Name = "River_Fish", Query = query({ "Thing.Food.Fish.River" }, { 0, 1, 2, 1, 0 }) },
        { Name = "Sharp_Tool", Query = query({ "Thing.Tool", "Thing.Sharp" }, { 0, 1, 2, 2, 0, 1 }) },
        { Name = "No_Root", Query = query({ "Thing.Tool" }, { 0, 0 }) },
        { Name = "Never_Asked", Query = query({ "Thing.Raw" }, { 0, 1, 1, 1, 0 }) },
    },
}

T.FieldGuideCategories = {
    defaults = { DisplayName = "", DisplayOrder = 0, DisplayIcon = "None", TagQuery = h("None", "D_TagQueries"), Subcategories = {} },
    rows = {
        { Name = "Food", DisplayName = "Food", DisplayOrder = 2, DisplayIcon = "/Game/Fixture/CAT_Food.CAT_Food", TagQuery = h("Any_Food"), Subcategories = { h("Food_Fish") } },
        { Name = "Tools", DisplayName = "Tools", DisplayOrder = 1, TagQuery = h("Any_Tool"),
            Subcategories = { h("Tools_Sharp"), h("Tools_Gone") } },
        { Name = "Benches", DisplayName = "Benches", DisplayOrder = 3, TagQuery = h("Any_Bench") },
        { Name = "Other", DisplayName = "Other", DisplayOrder = 999 },
        { Name = "Hidden", DisplayName = "[DNT] Hidden", DisplayOrder = 1000, TagQuery = h("FieldGuide_Hide") },
    },
}

T.FieldGuideSubcategories = {
    defaults = { DisplayName = "", DisplayOrder = 0, TagQuery = h("None", "D_TagQueries") },
    rows = {
        { Name = "Food_Fish", DisplayName = "River Fish", DisplayOrder = 1, TagQuery = h("River_Fish") },
        { Name = "Tools_Sharp", DisplayName = "Sharp", DisplayOrder = 1, TagQuery = h("Sharp_Tool") },
    },
}

T.ItemsStatic = {
    defaults = { Itemable = h("None", "D_Itemable"), Processing = h("None", "D_Processing"),
        Manual_Tags = { GameplayTags = {} }, Generated_Tags = { GameplayTags = {} } },
    rows = {
        -- its Itemable handle is spelled in lower case
        static("Pebble", { "Thing.Raw" }, { Itemable = h("item_pebble") }),
        static("Twig", { "Thing.Raw" }),
        static("Stone_Knife", { "Thing.Tool", "Thing.Sharp" }),
        -- tagged in Manual_Tags only
        { Name = "Odd_Spoon", Itemable = h("Item_Odd_Spoon"), Manual_Tags = tagged("Thing.Tool") },
        -- in two categories; the one that comes first in the guide gives its place in the list
        static("Spork", { "Thing.Food", "Thing.Tool" }),
        -- provides the hand set too, and comes before the item the hand set links to
        static("Field_Kit", { "Guide.Entry" }, { Processing = h("Field_Kit") }),
        static("FieldGuide_Character", { "Guide.Entry" }, { Processing = h("PlayerCrafting") }),
        static("Work_Table", { "Trait.Bench" }, { Processing = h("Work_Table") }),
        static("Lathe", { "Trait.Bench" }, { Processing = h("Lathe"), Metadata = level("FarLands") }),
        static("Press", { "Trait.Bench" }, { Processing = h("Press"), Metadata = level("Harvest") }),
        -- the set Hearth: a second bench first, then a hidden one, then the bench named like the set
        static("Big_Hearth", { "Trait.Bench" }, { Processing = h("Big_Hearth"), Metadata = level("DeepMines") }),
        static("Quest_Hearth", { "Thing.Secret", "Trait.Bench" }, { Processing = h("Quest_Hearth") }),
        static("Hearth", { "Trait.Bench" }, { Processing = h("Hearth") }),
        static("Gear", { "Thing.Part" }),
        static("River_Trout", { "Thing.Food.Fish.River" }),
        static("Sea_Bass", { "Thing.Food.Fish.Sea" }),
        static("Baked_Fish", { "Thing.Food.Cooked" }),
        static("Flour", { "Thing.Food" }),
        static("Dough", { "Thing.Food" }),
        static("FieldGuide_Water", { "Guide.Entry" }),
        static("FieldGuide_Power", { "Guide.Entry" }),
        static("Bucket", { "Thing.Tool" }),
        static("Fish_Meat", { "Thing.Food" }),
        static("Fish_Bone", { "Thing.Raw" }),
        static("Geode", { "Thing.Raw" }),
        static("Ruby", { "Thing.Gem" }),
        static("Opal", { "Thing.Gem" }),
        static("Seed", { "Thing.Seed" }, { Metadata = level("DeepMines") }),
        static("Oat", { "Thing.Food" }),
        static("Mash", { "Thing.Food" }),
        static("Banner", { "Thing.Decor" }),
        static("Coin", { "Thing.Raw" }),
        static("Trader_Npc", { "Guide.Hide" }, { Processing = h("Trader") }),
        static("Cup", { "Thing.Tool" }),
        static("Drink_Mint_Tea", { "Guide.Hide" }),
        static("Drink_Plum_Juice", { "Guide.Hide" }),
        static("Mint", { "Thing.Food" }),
        static("Plum", { "Thing.Food" }),
        -- hidden, and named like the shown Ruby
        static("Ruby_Quest", { "Thing.Secret" }),
        static("Quest_Map", { "Thing.Secret", "Guide.Show" }),
        static("Brick", { "Thing.Raw" }),
        static("Loom", { "Trait.Bench" }, { Processing = h("Loom") }),
        static("Cloth", { "Thing.Raw" }),
        static("Steel_Knife", { "Thing.Tool" }),
        static("Rug", { "Thing.Decor" }),
        static("Timber_Wall", { "Thing.Decor" }),
        static("Bone_Saw", { "Thing.Tool" }),
        static("Nails", { "Thing.Part" }),
        static("Signal_Fire", { "Thing.Decor" }),
        static("Old_Charm", { "Thing.Decor" }),
        static("Ore_Crust", { "Thing.Raw" }),
        static("Crust_Red", { "Guide.Hide" }),
        static("Crust_Blue", { "Guide.Hide" }),
        -- no Itemable at all
        { Name = "Ghost_Mesh", Manual_Tags = tagged("Thing.Decor"), Generated_Tags = tagged("Thing.Decor") },
    },
}

T.Itemable = {
    defaults = { DisplayName = "", Icon = "None", Weight = 0, MaxStack = 1 },
    rows = {
        itemable("Pebble", "Pebble", 300, 100),
        itemable("Twig", "Twig", 50, 200),
        itemable("Stone_Knife", "Stone Knife", 1500, 1),
        itemable("Odd_Spoon", "Odd Spoon", 5, 1),
        itemable("Spork", "Spork", 5, 1),
        itemable("Field_Kit", "Field Kit", 400, 1),
        itemable("Quest_Hearth", "Quest Hearth", 4000, 1),
        itemable("FieldGuide_Character", "Character Crafting", 0, 1),
        itemable("Work_Table", "Work Table", 5000, 1),
        itemable("Lathe", "Lathe", 20000, 1),
        itemable("Press", "Press", 20000, 1),
        itemable("Hearth", "Hearth", 4000, 1),
        itemable("Big_Hearth", "Big Hearth", 9000, 1),
        itemable("Gear", "Gear", 100, 50),
        itemable("River_Trout", "River Trout", 500, 10),
        itemable("Sea_Bass", "Sea Bass", 700, 10),
        itemable("Baked_Fish", "Baked Fish", 200, 10),
        itemable("Flour", "Flour", 10, 100),
        itemable("Dough", "Dough", 20, 50),
        itemable("FieldGuide_Water", "Water", 0, 1),
        itemable("FieldGuide_Power", "Power", 0, 1),
        itemable("Bucket", "Bucket", 800, 1),
        itemable("Fish_Meat", "Fish Meat", 100, 20),
        itemable("Fish_Bone", "Fish Bone", 10, 100),
        itemable("Geode", "Geode", 900, 20),
        itemable("Ruby", "Ruby", 5, 100),
        itemable("Opal", "Opal", 5, 100),
        itemable("Seed", "Seed", 1, 100),
        itemable("Oat", "Oat", 10, 100),
        itemable("Mash", "Mash", 100, 20),
        itemable("Banner", "Banner", 2000, 1),
        itemable("Coin", "Coin", 1, 1000),
        itemable("Trader_Npc", "Trader Hollis", 0, 1),
        itemable("Cup", "Cup", 100, 1),
        itemable("Drink_Mint_Tea", "Mint Tea", 0, 1),
        itemable("Drink_Plum_Juice", "Plum Juice", 0, 1),
        itemable("Mint", "Mint", 5, 100),
        itemable("Plum", "Plum", 80, 50),
        itemable("Ruby_Quest", "Ruby", 5, 1),
        itemable("Quest_Map", "Old Map", 10, 1),
        itemable("Brick", "Brick", 600, 100),
        itemable("Loom", "Loom", 8000, 1),
        itemable("Cloth", "Cloth", 30, 100),
        itemable("Steel_Knife", "Steel Knife", 900, 1),
        itemable("Rug", "Rug", 1200, 1),
        itemable("Timber_Wall", "Timber Wall", 3000, 10),
        itemable("Bone_Saw", "Bone Saw", 700, 1),
        itemable("Nails", "Nails", 2, 500),
        itemable("Signal_Fire", "Signal Fire", 2500, 1),
        itemable("Old_Charm", "Old Charm", 15, 1),
        itemable("Ore_Crust", "Ore Crust", 0, 1),
        itemable("Crust_Red", "Red Crust", 400, 50),
        itemable("Crust_Blue", "Blue Crust", 400, 50),
        itemable("Oat_Seed", "Oat Seed", 1, 100),
        itemable("Plum_Seed", "Plum Seed", 1, 100),
        itemable("Test_Seed", "Test Seed", 1, 100),
        itemable("Banner_North", "North Banner", 2000, 1),
        itemable("Banner_South", "South Banner", 2000, 1),
    },
}

T.ItemTemplate = {
    defaults = { ItemStaticData = h("None", "D_ItemsStatic"), ItemCustomStats = {} },
    rows = {
        template("Pebble"), template("Stone_Knife"), template("Gear"), template("Baked_Fish"), template("Dough"),
        template("Fish_Meat"), template("Fish_Bone"), template("Ruby"), template("Opal"), template("Mash"), template("Coin"),
        template("Brick"), template("Cloth"), template("Steel_Knife"), template("Rug"), template("Timber_Wall"),
        template("Bone_Saw"), template("Nails"), template("Signal_Fire"), template("Old_Charm"), template("Hearth"),
        template("Big_Hearth"), template("Ruby_Quest"), template("Twig"), template("Press"),
        -- one container that every drink recipe makes
        template("Any_Cup", "Cup"),
        -- two templates for one seed kind; a recipe makes the second
        template("Oat_Pack", "Seed", "SeedType_Enum", 1),
        template("Oat_Seed", "Seed", "SeedType_Enum", 1),
        template("Plum_Seed", "Seed", "SeedType_Enum", 2),
        -- number 0 is the row "Invalid", which is no kind
        template("Blank_Seed", "Seed", "SeedType_Enum", 0),
        -- for flags number 0 is a real row
        template("Banner_North", "Banner", "NationalFlag_Enum", 0),
        template("Banner_South", "Banner", "NationalFlag_Enum", 1),
        template("Lost_Thing", "Not_There"),
    },
}

T.FarmingSeeds = {
    defaults = { Itemable = h("None", "D_Itemable") },
    rows = {
        { Name = "Invalid" },
        { Name = "Oat", Itemable = h("Item_Oat_Seed") },
        { Name = "Plum", Itemable = h("Item_Plum_Seed") },
        { Name = "Test_Seed", Itemable = h("Item_Test_Seed") },
    },
}

T.NationalFlags = {
    defaults = { Item = h("None", "D_Itemable") },
    rows = {
        { Name = "North", Item = h("Item_Banner_North") },
        { Name = "South", Item = h("Item_Banner_South") },
    },
}

T.RecipeSets = {
    defaults = { RecipeSetName = "", RecipeSetIcon = "None" },
    rows = {
        { Name = "Character", RecipeSetName = "Character", RecipeSetIcon = "/Game/Fixture/SET_Hand.SET_Hand" },
        { Name = "Work_Table", RecipeSetName = "Work Table", RecipeSetIcon = "/Game/Fixture/SET_Table.SET_Table" },
        { Name = "Lathe", RecipeSetName = "Lathe", RecipeSetIcon = "/Game/Fixture/SET_Lathe.SET_Lathe" },
        { Name = "Press", RecipeSetName = "Press", RecipeSetIcon = "/Game/Fixture/SET_Press.SET_Press" },
        { Name = "Hearth", RecipeSetName = "Hearth", RecipeSetIcon = "/Game/Fixture/SET_Hearth.SET_Hearth" },
        -- no item provides it
        { Name = "Kiln", RecipeSetName = "Kiln", RecipeSetIcon = "/Game/Fixture/SET_Kiln.SET_Kiln" },
        -- only a hidden item provides it
        { Name = "Trader", RecipeSetName = "Trader", RecipeSetIcon = "/Game/Fixture/SET_Trader.SET_Trader" },
        -- two sets with one name
        { Name = "Loom_A", RecipeSetName = "Loom", RecipeSetIcon = "/Game/Fixture/SET_Loom.SET_Loom" },
        { Name = "Loom_B", RecipeSetName = "Loom", RecipeSetIcon = "/Game/Fixture/SET_Loom.SET_Loom" },
    },
}

T.Processing = {
    defaults = { DefaultRecipeSet = h("None", "D_RecipeSets"), MaxMilliwattage = 1000, AutoSelectRecipe = false },
    rows = {
        { Name = "PlayerCrafting", DefaultRecipeSet = h("Character") },
        { Name = "Field_Kit", DefaultRecipeSet = h("Character") },
        { Name = "Quest_Hearth", DefaultRecipeSet = h("Hearth"), MaxMilliwattage = 250 },
        { Name = "Work_Table", DefaultRecipeSet = h("Work_Table") },
        { Name = "Lathe", DefaultRecipeSet = h("Lathe"), MaxMilliwattage = 2500 },
        { Name = "Press", DefaultRecipeSet = h("Press"), MaxMilliwattage = 2500 },
        -- two benches of one set at different speeds
        { Name = "Hearth", DefaultRecipeSet = h("Hearth"), MaxMilliwattage = 250, AutoSelectRecipe = true },
        { Name = "Big_Hearth", DefaultRecipeSet = h("Hearth"), MaxMilliwattage = 500, AutoSelectRecipe = true },
        { Name = "Trader", DefaultRecipeSet = h("Trader"), MaxMilliwattage = 100000 },
        { Name = "Loom", DefaultRecipeSet = h("Loom_A") },
    },
}

T.CraftingTags = {
    defaults = { TagName = "", TagIcon = "None", Query = h("None", "D_TagQueries") },
    rows = {
        { Name = "Any_Fish", TagName = "Fish", TagIcon = "/Game/Fixture/QUERY_Fish.QUERY_Fish", Query = h("Any_Fish") },
    },
}

T.IcarusResources = {
    defaults = { DisplayName = "", Units = "", Recipe_Icon = "None" },
    rows = {
        { Name = "Invalid", DisplayName = "Invalid" },
        -- found by row name: FieldGuide_Water
        { Name = "Water", DisplayName = "Water", Units = "L", Recipe_Icon = "/Game/Fixture/RES_Water.RES_Water" },
        -- found by display name: the item FieldGuide_Power is called "Power"
        { Name = "Energy", DisplayName = "Power", Units = "kJ", Recipe_Icon = "/Game/Fixture/RES_Power.RES_Power" },
        { Name = "Steam", DisplayName = "Steam", Units = "L", Recipe_Icon = "/Game/Fixture/RES_Steam.RES_Steam" },
    },
}

T.ProcessorRecipes = {
    defaults = { Inputs = {}, Outputs = {}, QueryInputs = {}, ResourceInputs = {}, ResourceOutputs = {}, RecipeSets = {},
        Requirement = h("None", "D_Talents"), CharacterRequirement = h("None", "D_CharacterFlags"),
        SessionRequirement = h("None", "D_CharacterFlags"), RequiredMillijoules = 2500, bSelectOutputItemRandomly = false,
        bForceDisableRecipe = false, ItemIconOverride = { ItemStaticData = h("None", "D_ItemsStatic") } },
    rows = {
        -- a plain hand recipe; every handle differs from its row in letter case
        { Name = "Stone_Knife", Inputs = { input("PEBBLE", 2), input("twig", 1) }, Outputs = { output("stone_knife", 1) },
            RecipeSets = sets("character"), Requirement = h("STONE_KNIFE") },
        -- three benches
        { Name = "Gear", Inputs = { input("Pebble", 4) }, Outputs = { output("Gear", 2) }, RecipeSets = sets("Work_Table", "Lathe", "Press"),
            Requirement = h("Gear"), RequiredMillijoules = 5000, Metadata = level("FarLands") },
        -- a tag input; no requirement, so its tier comes from the bench
        { Name = "Baked_Fish", QueryInputs = { { Query = h("Any_Fish", "D_CraftingTags"), Count = 2 } }, Outputs = { output("Baked_Fish", 1) },
            RecipeSets = sets("Hearth", "Kiln"), RequiredMillijoules = 7500 },
        -- a resource input, and one set that does not exist
        { Name = "Dough", Inputs = { input("Flour", 2) }, ResourceInputs = { resource("Water", 100) }, Outputs = { output("Dough", 1) },
            RecipeSets = sets("Work_Table", "Gone_Bench") },
        -- a resource is all it makes
        { Name = "Pump_Water", Inputs = { input("Bucket", 1) }, ResourceOutputs = { resource("Water", 500) }, RecipeSets = sets("Work_Table") },
        -- several outputs
        { Name = "Butcher_Trout", Inputs = { input("River_Trout", 1) }, Outputs = { output("Fish_Meat", 2), output("Fish_Bone", 1) },
            RecipeSets = sets("Character") },
        -- one output picked at random
        { Name = "Crack_Geode", Inputs = { input("Geode", 1) }, Outputs = { output("Pebble", 1), output("Ruby", 1), output("Opal", 1) },
            RecipeSets = sets("Work_Table"), bSelectOutputItemRandomly = true },
        { Name = "Oat_Seeds", Inputs = { input("Oat", 1) }, Outputs = { output("Oat_Seed", 2) }, RecipeSets = sets("Character") },
        { Name = "Plum_Seeds", Inputs = { input("Plum", 1) }, Outputs = { output("Plum_Seed", 2) }, RecipeSets = sets("Character") },
        -- the plain seed has a use; no requirement, and its first station is of a higher tier than its second
        { Name = "Seed_Mash", Inputs = { input("Seed", 3) }, Outputs = { output("Mash", 1) }, RecipeSets = sets("Press", "Hearth") },
        { Name = "Press", Inputs = { input("Gear", 4) }, Outputs = { output("Press", 1) }, RecipeSets = sets("Work_Table"),
            Requirement = h("Press") },
        { Name = "Banner_North", Inputs = { input("Cloth", 2) }, Outputs = { output("Banner_North", 1) }, RecipeSets = sets("Loom_A") },
        { Name = "Banner_South", Inputs = { input("Cloth", 2) }, Outputs = { output("Banner_South", 1) }, RecipeSets = sets("Loom_B") },
        -- its template is not in the table
        { Name = "Ghost", Inputs = { input("Pebble", 1) }, Outputs = { output("Ghost_Template", 1) }, RecipeSets = sets("Character") },
        -- its input is not in the table
        { Name = "Broken_In", Inputs = { input("Not_An_Item", 1) }, Outputs = { output("Coin", 1) }, RecipeSets = sets("Character") },
        -- a trade that takes one millijoule
        { Name = "Trade_Ruby", Inputs = { input("Ruby", 1) }, Outputs = { output("Coin", 5) }, RecipeSets = sets("Trader"),
            RequiredMillijoules = 1 },
        -- two drinks on one container template, each named by its override
        { Name = "Mint_Tea", Inputs = { input("Mint", 1) }, ResourceInputs = { resource("Water", 250) }, Outputs = { output("Any_Cup", 1) },
            RecipeSets = sets("Hearth"), ItemIconOverride = { ItemStaticData = h("Drink_Mint_Tea") } },
        { Name = "Plum_Juice", Inputs = { input("Plum", 2) }, Outputs = { output("Any_Cup", 1) }, RecipeSets = sets("Work_Table"),
            ItemIconOverride = { ItemStaticData = h("Drink_Plum_Juice") } },
        -- everything it makes is hidden
        { Name = "Ruby_Quest", Inputs = { input("Pebble", 9) }, Outputs = { output("Ruby_Quest", 1) }, RecipeSets = sets("Work_Table") },
        -- its only set has no bench
        { Name = "Brick", Inputs = { input("Pebble", 3) }, Outputs = { output("Brick", 1) }, RecipeSets = sets("Kiln") },
        -- the node and the recipe both ask for the same pack
        { Name = "Rug", Inputs = { input("Cloth", 4) }, Outputs = { output("Rug", 1) }, RecipeSets = sets("Loom_A"),
            Requirement = h("Decor_Set"), SessionRequirement = h("Harvest", "D_DLCPackageData") },
        { Name = "Timber_Wall", Inputs = { input("Twig", 6) }, Outputs = { output("Timber_Wall", 1) }, RecipeSets = sets("Work_Table"),
            Requirement = h("Wall_Set") },
        { Name = "Bone_Saw", Inputs = { input("Fish_Bone", 2) }, Outputs = { output("Bone_Saw", 1) }, RecipeSets = sets("Work_Table"),
            Requirement = h("Bone_Saw") },
        -- names its set twice
        { Name = "Nails", Inputs = { input("Pebble", 1) }, Outputs = { output("Nails", 10) }, RecipeSets = sets("Work_Table", "work_table"),
            Requirement = h("Nails") },
        { Name = "Bulk_Nails", Inputs = { input("Pebble", 5) }, Outputs = { output("Nails", 100) }, RecipeSets = sets("Lathe"),
            Requirement = h("Nails"), CharacterRequirement = h("Talent_Bulk_Nails") },
        { Name = "Signal_Fire", Inputs = { input("Twig", 5) }, Outputs = { output("Signal_Fire", 1) }, RecipeSets = sets("Character"),
            SessionRequirement = h("Mission_Signal", "D_SessionFlags") },
        -- its talent is not in the table
        { Name = "Old_Charm", Inputs = { input("Opal", 1) }, Outputs = { output("Old_Charm", 1) }, RecipeSets = sets("Work_Table"),
            Requirement = h("Old_Charm_Talent") },
        { Name = "Hearth", Inputs = { input("Pebble", 12) }, Outputs = { output("Hearth", 1) }, RecipeSets = sets("Character"),
            Requirement = h("Hearth") },
        { Name = "Big_Hearth", Inputs = { input("Brick", 20) }, Outputs = { output("Big_Hearth", 1) }, RecipeSets = sets("Work_Table"),
            Requirement = h("Big_Hearth") },
        { Name = "Twig_Split", Inputs = { input("Pebble", 1) }, Outputs = { output("Twig", 2) }, RecipeSets = sets("Character"),
            Requirement = h("Twig_Split") },
        { Name = "Clean_Red", Inputs = { input("Crust_Red", 1) }, Outputs = { output("Pebble", 2) }, RecipeSets = sets("Work_Table") },
        { Name = "Clean_Blue", Inputs = { input("Crust_Blue", 1) }, Outputs = { output("Opal", 1) }, RecipeSets = sets("Work_Table") },
    },
}

T.FieldGuideMetaData = {
    defaults = { Item = h("None", "D_ItemsStatic"), Description1 = "", Description2 = "", Description3 = "" },
    rows = {
        -- a hint for an item that recipes also make
        { Name = "Pebble_Procure", Item = h("Pebble"), Description1 = "Pick up", Description2 = "Break rocks" },
        { Name = "Lost_Procure", Item = h("Nowhere"), Description1 = "Look around" },
    },
}

T.WorkshopItems = {
    defaults = { Item = h("None", "D_ItemTemplate") },
    rows = {
        { Name = "Meta_Steel_Knife", Item = h("Steel_Knife") },
        { Name = "Meta_Blank_Seed", Item = h("Blank_Seed") },
        { Name = "Meta_Gone", Item = h("Gone_Template") },
    },
}

T.FieldGuideRedirect = {
    defaults = { DisplayItem = h("None", "D_ItemsStatic"), HiddenItems = {} },
    rows = {
        { Name = "Crusts", DisplayItem = h("Ore_Crust"), HiddenItems = { h("Crust_Red"), h("Crust_Blue") } },
    },
}

T.Talents = {
    defaults = { DisplayName = "", ExtraData = h("None", "None"), TalentTree = h("None", "D_TalentTrees"), RequiredLevel = 0,
        bDefaultUnlocked = false, RequiredFlags = {}, Rewards = { { GrantedFlags = {} } } },
    rows = {
        -- named through ExtraData, and known from the start
        { Name = "Stone_Knife", ExtraData = h("Item_Stone_Knife", "D_Itemable"), TalentTree = h("Tree_T1"), bDefaultUnlocked = true },
        { Name = "Hearth", ExtraData = h("Item_Hearth", "D_Itemable"), TalentTree = h("Tree_T1") },
        -- the node itself asks for a character flag
        { Name = "Twig_Split", ExtraData = h("Item_Twig", "D_Itemable"), TalentTree = h("Tree_T1"),
            RequiredFlags = { h("Talent_Twig_Split", "D_CharacterFlags") } },
        { Name = "Gear", ExtraData = h("Item_Gear", "D_Itemable"), TalentTree = h("Tree_T3") },
        { Name = "Press", ExtraData = h("Item_Press", "D_Itemable"), TalentTree = h("Tree_T3") },
        { Name = "Big_Hearth", ExtraData = h("Item_Big_Hearth", "D_Itemable"), TalentTree = h("Tree_T2") },
        -- named by its own DisplayName, which is also the pack's name
        { Name = "Decor_Set", DisplayName = "Harvest Decor Pack", TalentTree = h("Tree_T2"),
            RequiredFlags = { h("Harvest", "D_DLCPackageData") } },
        -- its own level is above its tier's
        { Name = "Wall_Set", DisplayName = "Timber Wall Set", TalentTree = h("Tree_T2"), RequiredLevel = 15 },
        { Name = "Bone_Saw", ExtraData = h("Item_Bone_Saw", "D_Itemable"), TalentTree = h("Tree_T2"),
            RequiredFlags = { h("Granted_Bone_Saw", "D_AccountFlags") } },
        { Name = "Nails", ExtraData = h("Item_Nails", "D_Itemable"), TalentTree = h("Tree_T2") },
        { Name = "Skill_Bulk_Nails", DisplayName = "Nail Saver", TalentTree = h("Tree_Skill"),
            Rewards = { { GrantedFlags = { h("Talent_Bulk_Nails", "D_CharacterFlags") } } } },
        { Name = "Skill_Wood", DisplayName = "Wood Sense", TalentTree = h("Tree_Skill"),
            Rewards = { { GrantedFlags = { h("None", "D_CharacterFlags") } }, { GrantedFlags = { h("Talent_Twig_Split", "D_CharacterFlags") } } } },
    },
}

T.TalentTrees = {
    defaults = { Archetype = h("None", "D_TalentArchetypes") },
    rows = {
        { Name = "Tree_T1", Archetype = h("Arch_T1") },
        { Name = "Tree_T2", Archetype = h("Arch_T2") },
        { Name = "Tree_T3", Archetype = h("Arch_T3") },
        { Name = "Tree_Skill", Archetype = h("Arch_Skill") },
    },
}

T.TalentArchetypes = {
    defaults = { DisplayName = "", RequiredLevel = 0 },
    rows = {
        { Name = "Arch_T1", DisplayName = "Tier 1" },
        { Name = "Arch_T2", DisplayName = "Tier 2", RequiredLevel = 10 },
        { Name = "Arch_T3", DisplayName = "Tier 3", RequiredLevel = 20 },
        { Name = "Arch_Skill", DisplayName = "Skills" },
    },
}

T.DLCPackageData = {
    defaults = { DLCName = "" },
    rows = {
        { Name = "Harvest", DLCName = "Harvest Decor Pack" },
        { Name = "Far_Lands", DLCName = " Far Lands Expansion" },
    },
}

T.AccountFlags = {
    defaults = { RewardedFromMissions = {} },
    rows = {
        { Name = "Granted_Bone_Saw", RewardedFromMissions = { h("Mission_Deep", "D_ProspectList") } },
        { Name = "Granted_Nothing" },
    },
}

T.ProspectList = {
    defaults = { DropName = "" },
    rows = { { Name = "Mission_Deep", DropName = "DEEP DIVE" } },
}

T.CharacterFlags = { defaults = {}, rows = { { Name = "Talent_Bulk_Nails" }, { Name = "Talent_Twig_Split" } } }
T.SessionFlags = { defaults = {}, rows = { { Name = "Mission_Signal" } } }

T.FeatureLevels = {
    defaults = { DisplayName = "", Icon = "None" },
    rows = {
        { Name = "Core", DisplayName = "Core" },
        -- carries an Icon and has a DLC row of the same name without the underscore
        { Name = "FarLands", DisplayName = "Far Lands", Icon = "/Game/Fixture/LEVEL_Far.LEVEL_Far" },
        -- has a DLC row but no Icon: a free update, not to be named
        { Name = "Harvest", DisplayName = "Harvest" },
        -- carries an Icon and has no DLC row
        { Name = "DeepMines", DisplayName = "Deep Mines", Icon = "/Game/Fixture/LEVEL_Deep.LEVEL_Deep" },
    },
}

fixture.tables = T

local function clone(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, inner in pairs(value) do out[key] = clone(inner) end
    return out
end

function fixture.copy() return clone(T) end

local allowed = setmetatable({}, { __mode = "k" })
local GUARD = {
    __index = function(row, key)
        if type(key) ~= "string" then return nil end
        local set = allowed[row]
        if set and set[key] then return nil end
        error("the field '" .. key .. "' was read but is not in source.lua's lists", 2)
    end,
}

-- A provider with the calls source.lua makes on game.Data. options: strict (default true), meta (false: no MetaTables).
function fixture.serve(tables, options)
    options = options or {}
    local strict = options.strict ~= false
    local provider = { calls = 0, asked = {} }
    local objects = {}

    local function count(what)
        provider.calls = provider.calls + 1
        provider.asked[what] = (provider.asked[what] or 0) + 1
    end

    -- Tables at the same place in a row share one set of fields that were asked for.
    local shapes = {}

    local function fresh(shape)
        local row = {}
        if strict then
            shapes[shape] = shapes[shape] or {}
            allowed[row] = shapes[shape]
            setmetatable(row, GUARD)
        end
        return row
    end

    local function allow(row, key)
        if strict then allowed[row][key] = true end
    end

    local function copy(target, raw, defaults, parts, depth, shape)
        local key = parts[depth]
        local value, default
        if type(raw) == "table" then value = raw[key] end
        if type(defaults) == "table" then default = defaults[key] end
        if value == nil then value = default end
        allow(target, key)
        if depth == #parts then
            if rawget(target, key) == nil then rawset(target, key, clone(value)) end
            return
        end
        if type(value) ~= "table" then return end
        shape = shape .. "." .. key
        local inner = rawget(target, key)
        if inner == nil then
            inner = fresh(shape)
            rawset(target, key, inner)
        end
        if #value > 0 then
            for position = 1, #value do
                local slot = rawget(inner, position)
                if slot == nil then
                    slot = fresh(shape .. "[]")
                    rawset(inner, position, slot)
                end
                copy(slot, value[position], nil, parts, depth + 1, shape .. "[]")
            end
        elseif next(value) ~= nil then
            copy(inner, value, default, parts, depth + 1, shape)
        end
    end

    local function make(short, data, levels)
        local object = { Name = short, RowStruct = short .. "Row" }
        local names, at, served, known = {}, {}, {}, {}
        for position, row in ipairs(data.rows) do
            names[position] = row.Name
            at[row.Name:lower()] = position
            for key in pairs(row) do known[key] = true end
        end
        for key in pairs(data.defaults or {}) do known[key] = true end
        for _, field in ipairs(data.fields or {}) do known[field:match("^[^.]+")] = true end

        local function row_of(name, fields)
            if type(name) ~= "string" then error("a row name must be a string", 3) end
            local position = at[name:lower()]
            if not position then return nil end
            local raw = data.rows[position]
            local row = served[position]
            if not row then
                row = fresh(short)
                served[position] = row
                if options.meta == false and raw.Metadata then rawset(row, "Metadata", clone(raw.Metadata)) end
            end
            if not fields then
                fields = {}
                for key in pairs(known) do
                    if key ~= "Name" and key ~= "Metadata" then fields[#fields + 1] = key end
                end
            end
            for _, field in ipairs(fields) do
                local parts = {}
                for part in field:gmatch("[^.]+") do parts[#parts + 1] = part end
                if not known[parts[1]] then error(short .. " has no field '" .. field .. "'", 3) end
                copy(row, raw, data.defaults, parts, 1, short)
            end
            return row
        end

        function object:Count() count("Count") return #names end
        function object:GetNames() count("GetNames") return clone(names) end
        function object:Has(name) count("Has") return type(name) == "string" and at[name:lower()] ~= nil end
        function object:Row(name, fields) count("Row") return row_of(name, fields) end
        function object:Loaded() count("Loaded") return #names, #names end
        function object:Stamp() count("Stamp") return #names .. ":" .. tostring(data.stamp or "0x1") end
        function object:Fields()
            count("Fields")
            local list = {}
            for key in pairs(known) do list[#list + 1] = { Name = key } end
            table.sort(list, function(a, c) return a.Name < c.Name end)
            return list
        end
        function object:Load(request)
            count("Load")
            request = request or {}
            local out = {}
            for _, name in ipairs(request.names or names) do
                local row = row_of(name, request.fields or {})
                if row then out[names[at[name:lower()]]] = row end
            end
            return out
        end
        function object:Meta()
            count("Meta")
            if levels or options.meta == false then return nil end
            if not object.meta then
                local rows = {}
                for position, row in ipairs(data.rows) do
                    rows[position] = { Name = row.Name, RequiredFeatureLevel = row.Metadata and row.Metadata.RequiredFeatureLevel or nil }
                end
                object.meta = make(short .. "_METATABLE", { defaults = { RequiredFeatureLevel = { RowName = "None" } }, rows = rows }, true)
            end
            return object.meta
        end
        return object
    end

    local function resolve(name)
        if type(name) ~= "string" then error("a table name must be a string", 3) end
        local short = name:gsub("^D_", "")
        if tables[short] then return short end
        return nil
    end

    function provider:Has(name) count("Has") return resolve(name) ~= nil end
    function provider:GetTables()
        count("GetTables")
        local list = {}
        for name in pairs(tables) do list[#list + 1] = name end
        table.sort(list)
        return list
    end
    function provider:Table(name)
        count("Table")
        local short = resolve(name)
        if not short then error("there is no table named '" .. tostring(name) .. "'", 2) end
        objects[short] = objects[short] or make(short, tables[short])
        return objects[short]
    end
    function provider:Flush() count("Flush") objects = {} end
    provider.Changed = { Connect = function() return { Disconnect = function() end } end }
    return provider
end

function fixture.provider(options) return fixture.serve(T, options) end

return fixture
