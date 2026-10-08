---@meta _

---One item a recipe takes. The table is yours: changing it changes nothing in the game.
---@class WaxRecipeInput
---@field Item string The item's name: its row in D_ItemsStatic, spelled as the game spells it.
---@field Count integer How many of it the recipe takes each time it is made.

---One tag a recipe takes, such as "any raw meat": every item with that tag will do.
---@class WaxRecipeTag
---@field Tag string The tag's name: its row in D_CraftingTags.
---@field Count integer How many items with that tag the recipe takes each time it is made.

---One resource a recipe takes, such as water or biofuel.
---@class WaxRecipeResource
---@field Resource string The resource's name: its row in D_IcarusResources.
---@field Units integer How many units of it the recipe takes each time it is made.

---One thing that comes out of a recipe.
---@class WaxRecipeOutput
---@field Item string? The item's name. nil when the game has no item for what the recipe names.
---@field Count integer How many come out each time the recipe is made.
---@field Template string The row of D_ItemTemplate the recipe names. Most items have one template, of their own name. A few have more, such as an empty and a full waterskin.

---What `game.Recipes:Add` takes beside the name.
---@class WaxRecipeAddOptions
---@field like string The recipe the new one is a copy of. Whatever is not given below stays as that recipe has it.
---@field inputs? table The items it takes, as SetInputs takes them.
---@field outputs? table What comes out, as SetOutputs takes it.
---@field benches? string|string[] Where it is made, as SetBenches takes it.
---@field seconds? number How long making it once takes, as SetSeconds takes it without a bench. Give `seconds` or `work`, not both.
---@field work? integer The work making it once takes, as SetWork takes it.
---@field requirement? string|false The node of the tech tree it needs, or false for no research.
---@field hidden? boolean True to start hidden.

---One crafting recipe: a row of D_ProcessorRecipes. `game.Recipes:Get("Stone_Axe")` gives one.
---
---Reading a field reads the game's table, so it is always what the table holds now. The lists it gives are yours to change:
---that changes nothing in the game. One exception keeps a mod steady while it is being reloaded: what the mod itself wrote
---before the reload is left out, so `if recipe.Work > 2000 then recipe:SetWork(2000) end` does the same thing each time.
---
---Every function that changes the recipe returns the recipe, so changes can follow one another:
---`game.Recipes:Get("Stone_Axe"):SetInputs({ Stone = 1 }):SetSeconds(1)`. A change is written before the function returns.
---It belongs to the mod that makes it and is put back when the mod unloads, as every change of game.Data is.
---What two mods do to one recipe is worked out in the order the mods load. SetInput, RemoveInput, the Scale functions,
---AddBench, RemoveBench and the output functions build on what an earlier mod did. SetInputs, SetBenches, MoveTo, SetWork,
---SetSeconds, SetRequirement, Hide and Show replace it, and `game.Data:Conflicts()` lists a field where that hides another mod's different value.
---
---What a change does to something that is being made or waiting in a queue, as it was seen on the host: a new time
---counts from the next moment, so what is half done by the old time may be nearly done, or done, by the new one. What is
---taken and what comes out is read from the recipe when the making ends, as the recipe is then. Nothing is taken before
---that. As soon as the player cannot pay what the recipe takes, the making is dropped without a message, and nothing is
---lost. So change recipes when the mod loads if a player should never see one change while it is being made.
---
---In a game someone else hosts, a change is made on this PC only. The host works from its own tables and decides what is
---taken, what is made and how long it takes.
---
---Names of items, benches, recipes and nodes are matched without regard to letter case. A name the game does not have
---raises an error that suggests the nearest ones.
---
---This version of Wax cannot make every list of a recipe longer or shorter. The outputs keep their number: each can become
---another item and another count. The resources keep their number too. The items, the tags and the benches of a recipe can
---be added to and taken from while the list has 4 entries or fewer, before and after. A change that is refused raises an
---error that says so, and changes nothing.
---@class WaxRecipe
---@field Name string The recipe's name: its row in D_ProcessorRecipes, spelled as the game spells it.
---@field Inputs WaxRecipeInput[] The items the recipe takes each time it is made.
---@field Tags WaxRecipeTag[] What the recipe takes by tag.
---@field Resources WaxRecipeResource[] The resources the recipe takes.
---@field Outputs WaxRecipeOutput[] What comes out each time the recipe is made.
---@field Benches string[] The recipe sets the recipe is in. A bench lists the recipes of its set. "Character" is what is made by hand.
---@field Work integer The work making the recipe once takes, in millijoules. A bench works at so many milliwatts, and the time is the one divided by the other.
---@field Requirement string? The node of the tech tree that has to be researched first: its row in D_Talents. nil when the recipe needs no research.
---@field Hidden boolean True when the recipe is taken off every list.
local Recipe = {}

---How long making the recipe once takes at a bench, in seconds, before talents and upgrades. Without a bench it is the time at the
---recipe's own benches. When those work at different speeds, or Wax does not know how fast one works, it raises an error
---that says so.
---@param bench? string
---@return number
function Recipe:GetSeconds(bench) end

---Sets the items the recipe takes: `recipe:SetInputs({ Wood = 2, Fiber = 4 })`. Written like that they are put in the
---order of their names. A list keeps the order it is given in: `{ { "Wood", 2 }, { "Fiber", 4 } }`, or
---`{ { Item = "Wood", Count = 2 } }`. What the recipe takes by tag and its resources stay as they are.
---A count is a whole number of 1 or more. An empty table is refused when the recipe would then take nothing at all.
---@param inputs table<string, integer>|table[]
---@return WaxRecipe
function Recipe:SetInputs(inputs) end

---Sets how many of one thing the recipe takes, and adds it when the recipe does not take it yet: `recipe:SetInput("Wood", 2)`.
---The name is an item, a tag or a resource. A resource can only be changed where the recipe already takes it.
---@param name string
---@param count integer A whole number of 1 or more.
---@return WaxRecipe
function Recipe:SetInput(name, count) end

---Takes one item or tag out of what the recipe takes. It raises an error when the recipe does not take it, when the recipe
---would then take nothing at all, and for a resource, which cannot be taken away in this version.
---On a list of recipes, the ones that do not take it are left as they are.
---@param name string
---@return WaxRecipe
function Recipe:RemoveInput(name) end

---Multiplies every count the recipe takes: items, tags and resources. `recipe:ScaleInputs(0.5)` halves the cost.
---A count is rounded up and never goes under 1.
---@param factor number A number above 0.
---@return WaxRecipe
function Recipe:ScaleInputs(factor) end

---Multiplies the count of one item, tag or resource the recipe takes. The count is rounded up and never goes under 1.
---It raises an error when the recipe does not take it. On a list of recipes, the ones that do not take it are left as they are.
---@param name string
---@param factor number A number above 0.
---@return WaxRecipe
function Recipe:ScaleInput(name, factor) end

---Sets what comes out: `recipe:SetOutputs({ Stone_Axe = 2 })`, or a list as SetInputs takes it. An item is written as its
---template: the one of its own name, else its only one. For an item with several templates and none of its own name, name
---the template: `{ { Template = "Waterskin_Full", Count = 1 } }`. An output that stays keeps its place and whatever else
---the game keeps with it. In this version the number of outputs has to stay the same.
---@param outputs table<string, integer>|table[]
---@return WaxRecipe
function Recipe:SetOutputs(outputs) end

---Sets how many of one item come out: `recipe:SetOutput("Stone_Axe", 2)`. The name is an item or a template.
---In this version it raises an error when the recipe does not give that item, because an output cannot be added.
---@param name string
---@param count integer A whole number of 1 or more.
---@return WaxRecipe
function Recipe:SetOutput(name, count) end

---Multiplies the count of everything that comes out. A count is rounded up and never goes under 1.
---@param factor number A number above 0.
---@return WaxRecipe
function Recipe:ScaleOutputs(factor) end

---Sets the work making the recipe once takes, in millijoules. By hand, which works at 1000 milliwatts, 2500 is two and a half seconds.
---@param millijoules integer A whole number of 1 or more.
---@return WaxRecipe
function Recipe:SetWork(millijoules) end

---Sets how long making the recipe once takes at a bench, before talents and upgrades: `recipe:SetSeconds(5, "Fabricator")`. The work
---is worked out from how fast that bench is, so at a faster bench of the recipe it takes less than that.
---Without a bench the recipe's own benches are used. When they work at different speeds it raises an error that names the
---speeds: say which bench is meant, or use ScaleTime.
---@param seconds number A number above 0.
---@param bench? string
---@return WaxRecipe
function Recipe:SetSeconds(seconds, bench) end

---Multiplies the work making the recipe once takes: `recipe:ScaleTime(0.5)` makes it twice as fast at every bench.
---@param factor number A number above 0.
---@return WaxRecipe
function Recipe:ScaleTime(factor) end

---Sets where the recipe is made: `recipe:SetBenches({ "Hand", "Crafting_Bench" })`. A bench is named by the item that is
---the bench, by its recipe set, or "Hand" for what a player makes without one. One name may stand without the list.
---The crafting tab builds its list again when the frame ends, if it is the tab that shows. A bench screen that is open is
---not built again in this version.
---@param benches string|string[]
---@return WaxRecipe
function Recipe:SetBenches(benches) end

---Adds a bench to where the recipe is made. It does nothing when the recipe is made there already.
---@param bench string
---@return WaxRecipe
function Recipe:AddBench(bench) end

---Takes a bench away from where the recipe is made. It raises an error when the recipe is not made there, and when it
---would then be made nowhere: use Hide for that. On a list of recipes, the ones that are not made there are left as they are.
---@param bench string
---@return WaxRecipe
function Recipe:RemoveBench(bench) end

---Makes one bench the only place the recipe is made: `recipe:MoveTo("Hand")`.
---@param bench string
---@return WaxRecipe
function Recipe:MoveTo(bench) end

---Sets the node of the tech tree that has to be researched before the recipe can be made, by the node's row name in
---D_Talents. `recipe:SetRequirement(nil)` means no research is needed: on the host the recipe was then listed and made
---by a character who had not researched it.
---@param node string?
---@return WaxRecipe
function Recipe:SetRequirement(node) end

---Takes the recipe off the lists players choose from. The crafting tab and the game's own list of a bench's recipes were
---seen to drop it. A bench that chooses its recipe by itself was not tried.
---It does not stop the recipe from being made. One that is being made is finished, and the host still makes it when it
---is asked for by name, which is all a player's game sends. The one thing the host was seen to check is research.
---@return WaxRecipe
function Recipe:Hide() end

---Puts the recipe back on the lists it was taken off with Hide.
---@return WaxRecipe
function Recipe:Show() end

---Takes back everything this mod changed in the recipe. What other mods changed stays.
---@return integer count How many fields were taken back.
function Recipe:Reset() end

---Recipes found together, in the order the game has them. `#list` is how many, `list[1]` the first, and it holds the
---recipes it was made with, whatever changes later.
---
---It has every function of a recipe that changes one, and does it to each recipe of the list:
---`game.Recipes:At("Fabricator"):ScaleTime(0.5)`. Each returns the list. A recipe the change does not apply to is left as
---it is where the function says so. When a change is refused for some recipes, the others are still changed, and then an
---error says how many were not and why the first was not.
---
---Inside a task, work on many recipes pauses when it has used a millisecond of a frame and goes on in the next. Anywhere
---else it is all done before the function returns, which for hundreds of recipes is a frame the player can notice.
---@class WaxRecipeList
---@field [integer] WaxRecipe
local RecipeList = {}

---Calls `fn` with each recipe of the list, in order.
---@param fn fun(recipe: WaxRecipe)
---@return WaxRecipeList
function RecipeList:Each(fn) end

---The names of the recipes in the list.
---@return string[]
function RecipeList:GetNames() end

---Sets the items each recipe of the list takes, as Recipe:SetInputs does for one.
---@param inputs table<string, integer>|table[]
---@return WaxRecipeList
function RecipeList:SetInputs(inputs) end

---Sets how many of one thing each recipe of the list takes, as Recipe:SetInput does for one. A recipe that does not take it yet gets it added, and counts as refused where it cannot be added.
---@param name string
---@param count integer
---@return WaxRecipeList
function RecipeList:SetInput(name, count) end

---Takes one item or tag out of each recipe of the list that takes it, as Recipe:RemoveInput does for one. The recipes that do not take it are left as they are.
---@param name string
---@return WaxRecipeList
function RecipeList:RemoveInput(name) end

---Multiplies every count each recipe of the list takes, as Recipe:ScaleInputs does for one.
---@param factor number
---@return WaxRecipeList
function RecipeList:ScaleInputs(factor) end

---Multiplies the count of one item, tag or resource in each recipe of the list that takes it, as Recipe:ScaleInput does for one. The recipes that do not take it are left as they are.
---@param name string
---@param factor number
---@return WaxRecipeList
function RecipeList:ScaleInput(name, factor) end

---Sets what comes out of each recipe of the list, as Recipe:SetOutputs does for one.
---@param outputs table<string, integer>|table[]
---@return WaxRecipeList
function RecipeList:SetOutputs(outputs) end

---Sets how many of one item come out of each recipe of the list, as Recipe:SetOutput does for one. In this version a recipe that does not give the item counts as refused.
---@param name string
---@param count integer
---@return WaxRecipeList
function RecipeList:SetOutput(name, count) end

---Multiplies the count of everything that comes out of each recipe of the list, as Recipe:ScaleOutputs does for one.
---@param factor number
---@return WaxRecipeList
function RecipeList:ScaleOutputs(factor) end

---Sets the work making each recipe of the list once takes, as Recipe:SetWork does for one.
---@param millijoules integer
---@return WaxRecipeList
function RecipeList:SetWork(millijoules) end

---Sets how long making each recipe of the list once takes at a bench, as Recipe:SetSeconds does for one. Without a bench each recipe goes by its own benches, and one whose benches work at different speeds is refused.
---@param seconds number
---@param bench? string
---@return WaxRecipeList
function RecipeList:SetSeconds(seconds, bench) end

---Multiplies the work making each recipe of the list once takes, as Recipe:ScaleTime does for one.
---@param factor number
---@return WaxRecipeList
function RecipeList:ScaleTime(factor) end

---Sets where each recipe of the list is made, as Recipe:SetBenches does for one.
---@param benches string|string[]
---@return WaxRecipeList
function RecipeList:SetBenches(benches) end

---Adds a bench to where each recipe of the list is made, as Recipe:AddBench does for one. The recipes that are made there already are left as they are.
---@param bench string
---@return WaxRecipeList
function RecipeList:AddBench(bench) end

---Takes a bench away from each recipe of the list that is made there, as Recipe:RemoveBench does for one. The recipes that are not made there are left as they are.
---@param bench string
---@return WaxRecipeList
function RecipeList:RemoveBench(bench) end

---Makes one bench the only place each recipe of the list is made, as Recipe:MoveTo does for one.
---@param bench string
---@return WaxRecipeList
function RecipeList:MoveTo(bench) end

---Sets the node of the tech tree that has to be researched before each recipe of the list can be made, as Recipe:SetRequirement does for one.
---@param node string?
---@return WaxRecipeList
function RecipeList:SetRequirement(node) end

---Takes each recipe of the list off the lists players choose from, as Recipe:Hide does for one.
---@return WaxRecipeList
function RecipeList:Hide() end

---Puts each recipe of the list back on the lists it was taken off with Hide, as Recipe:Show does for one.
---@return WaxRecipeList
function RecipeList:Show() end

---Takes back everything this mod changed in the recipes of the list.
---@return integer count How many fields were taken back.
function RecipeList:Reset() end

---The game's crafting recipes: finding them and changing them.
---`game.Recipes:Get("Stone_Axe"):SetInputs({ Stone = 1 })` makes a stone axe cost one stone, and
---`game.Recipes:At("Fabricator"):ScaleTime(0.5)` makes everything the Fabricator makes twice as fast.
---Every change goes through game.Data, so it is checked first, put back when the mod unloads, and listed by `game.Data:Changes()`.
---@class WaxRecipes
local Recipes = {}

---One recipe by its name, at once: nothing of the recipe is read until a field is asked for.
---A name the game does not have raises an error that suggests the nearest ones, so ask Has first when the name may be wrong.
---The recipe for an item often has the item's name, but not always, and some items have several recipes: Making finds them all.
---@param name string
---@return WaxRecipe
function Recipes:Get(name) end

---True when the game has a recipe of this name.
---@param name string
---@return boolean
function Recipes:Has(name) end

---Every recipe the game has. Nothing is read for it.
---@return WaxRecipeList
function Recipes:All() end

---The recipes a bench lists: `game.Recipes:At("Fabricator")`, `game.Recipes:At("Hand")`. A bench is named by the item
---that is the bench, by its recipe set, or "Hand". A hidden recipe is on no bench's list, and what a player has researched
---makes no difference to the list. In a prospect the game itself is asked, which took 1 to 3 milliseconds when it was
---measured. Its answer for a bench is kept until a recipe is written, so asking again costs under a millisecond.
---Anywhere else, and when the game does not answer, the recipe table is read instead, as Using does it.
---@param bench string
---@return WaxRecipeList
function Recipes:At(bench) end

---The recipes that give an item: `game.Recipes:Making("Rope")`. The name is an item, or a template.
---It reads what every recipe gives and every template's item. Inside a task that pauses when it has used a millisecond of
---a frame. Anywhere else it is read at once, which the first time is a frame the player can notice. What was read is kept,
---and looking through it still took 8 milliseconds when it was measured, so search when the mod loads, not in every frame.
---@param item string
---@return WaxRecipeList
function Recipes:Making(item) end

---The recipes that take an item, a tag or a resource: `game.Recipes:Using("Fiber")`.
---It reads what every recipe takes. Inside a task that pauses when it has used a millisecond of a frame. Anywhere else it
---is read at once, which the first time is a frame the player can notice. What was read is kept, and looking through it
---still took 10 milliseconds when it was measured, so search when the mod loads, not in every frame.
---@param name string
---@return WaxRecipeList
function Recipes:Using(name) end

---The recipes `fn` returns true for: `game.Recipes:Find(function(recipe) return recipe.Work > 10000 end)`.
---It asks about every recipe, and each field `fn` reads is read from the game the first time. Inside a task it pauses
---when it has used a millisecond of a frame.
---@param fn fun(recipe: WaxRecipe): boolean?
---@return WaxRecipeList
function Recipes:Find(fn) end

---Adds a recipe: a copy of the recipe `options.like` names, changed by the other options.
---`game.Recipes:Add("MyMod_Quick_Axe", { like = "Stone_Axe", inputs = { Stone = 1 }, seconds = 1 })`.
---The name begins with the mod's id and an underscore.
---It is switched off in this version of Wax and raises an error that says so: adding a row to the game's tables while the
---game runs has not been seen working yet.
---@param name string
---@param options WaxRecipeAddOptions
---@return WaxRecipe
function Recipes:Add(name, options) end

---What `game.Crafting:Refresh` takes.
---@class WaxCraftingRefreshOptions
---@field lists? boolean False when only what recipes take, give and how long they take changed. The tab then asks its recipes again, which costs next to nothing. Without it the tab's list is built again, as it has to be when a recipe was hidden, moved to another bench or given another requirement.
---@field recipes? string[] The recipes that changed. With `lists = false`, the recipe the player has chosen is chosen again only when it is one of them. Without it, it is chosen again whichever it is.
