---@meta _

---A price: how many of each currency. A key is a currency's row name in D_MetaCurrency, as in `{ Credits = 100, Exotic1 = 25 }`.
---An amount is a whole number from 0 to 2147483647, the largest the game's field keeps.
---@alias WaxStoreCost table<string, integer>

---One category of the store: a row of D_TalentArchetypes whose model is the store's.
---@class WaxStoreCategory
---@field Id string The category's row name, such as "Workshop_Axes".
---@field Name string The name the game shows for it.
---@field Icon string? The path of its picture.
---@field Level integer The level its row asks for (RequiredLevel). 0 for every category of the game's own.
---@field Tree string? Its row of D_TalentTrees, which its nodes name. The first one, should it have several.
---@field Background string? The path of the picture behind its nodes.

---A flag a node asks for.
---@class WaxStoreFlag
---@field Id string The flag's row name.
---@field Kind "character"|"session"|"account"|"dlc"? Which table the flag is a row of: D_CharacterFlags, D_SessionFlags, D_AccountFlags or D_DLCPackageData. Nil when the game does not say.

---One node of the store: a row of D_Talents in a tree of the store.
---@class WaxStoreNode
---@field Id string The node's row name, such as "Workshop_Axe_Printed". What a player has researched is saved under this name.
---@field Category string The Id of its category.
---@field Joint boolean True for a joint: a node of no size that shows nothing, sells nothing and stands for its parents.
---@field Name string? The name of what it sells, as the game shows it. The store takes it from the item, not from the node's own row.
---@field Icon string? The path of the item's picture.
---@field StoreItem string? Its row of D_WorkshopItems, which says what it gives and what it costs.
---@field Gives string? The row of D_ItemTemplate that is handed over.
---@field Item string? The row of D_ItemsStatic behind that template. Nil when the game has no such template.
---@field Research WaxStoreCost What researching it costs, paid once. Empty for a joint.
---@field Replicate WaxStoreCost What each one made costs. Empty for a joint.
---@field Needs string[] The row names of the nodes it comes after. With several, one of them bought is enough.
---@field Flags WaxStoreFlag[] The flags its row asks for. A DLC that has to be owned is one of these.
---@field Level integer The level its row asks for (RequiredLevel). 0 for every node of the game's own.
---@field Free boolean True when its row says it is researched from the start. The rows of joints say so, and the game still counts a joint as bought only once one of its parents is.
---@field At { X: number, Y: number } The middle of the node on its category's canvas, which begins at 0, 0 at the top left.
---@field Size number How wide and high it is: 250 for a node, 0 for a joint.
---@field Line "elbow"|"elbow-down"|"straight"|"none"? The line style its row sets: the game's XThenY, YThenX, ShortestDistance or NoLine. Nil when the row sets none and the store's own style applies, which is XThenY.

---One of the game's currencies: a row of D_MetaCurrency.
---@class WaxStoreCurrency
---@field Id string The currency's row name, such as "Credits".
---@field Name string The name its row gives, without the "[DNT]" mark some carry. "Credits" is named "Ren".
---@field Icon string? The path of its picture.
---@field Shown boolean True when its row says it is shown on the game's main screen.

---One thing that is wrong with a store.
---@class WaxStoreProblem
---@field Level "error"|"warning" An error means the store cannot be made as described.
---@field Code string A short name for the kind of problem, such as "id-twice" or "off-screen".
---@field Node string? The id of the node it is about.
---@field Category string? The id of the category it is about.
---@field Text string The problem as a sentence.

---What a node hands over when it is not a ready row of D_ItemTemplate: an item and how many.
---@class WaxStoreGives
---@field item string A row name of D_ItemsStatic.
---@field count? integer How many are handed over. 1 when omitted.

---What a node asks for, in the long form.
---@class WaxStoreNeeds
---@field any? string|string[] Nodes of which one bought is enough. This is the game's own rule for a node with several parents.
---@field all? string|string[] Nodes that all have to be bought. The game has no such rule, so Check warns about it, and in this version of Wax nothing keeps the rule: Define, Add and Set refuse a node that uses it.
---@field level? integer The level the node's row asks for (RequiredLevel).
---@field flags? string|string[] Account flags the player must have: row names of D_AccountFlags.

---One node of a described store.
---@class WaxStoreNodeSpec
---@field id string Letters, digits and _, used once in the mod. The node's row is named "<ModId>_<id>", and what a player has researched is saved under that name, so an id is never changed. The row name can be 100 characters long at most.
---@field gives string|WaxStoreGives What it sells: a row name of D_ItemTemplate, or an item and a count.
---@field research? WaxStoreCost What researching it costs, paid once. Nothing when omitted.
---@field replicate? WaxStoreCost What each one made costs. Nothing when omitted.
---@field needs? string|string[]|WaxStoreNeeds A node, a list of nodes of which one is enough, or the long form. A node is named by its id in this store, or by the row name of one of the game's nodes.
---@field at? { [1]: number, [2]: number } The middle of the node, such as `{ 500, 850 }`, each number no further than 1000000 from 0. A node without one is placed by its category's `arrange`.
---@field line? "elbow"|"elbow-down"|"straight"|"none" The line style for its row: the game's XThenY, YThenX, ShortestDistance or NoLine.
---@field free? boolean True marks the node as researched from the start.

---The options of a shape. Each shape reads the ones named for it. A place is two numbers, such as `{ 500, 850 }`, and angles are in degrees: 0 points right, 90 points down.
---No distance, angle or place given here, and no place that comes out, can be further than 1000000 from 0: such a shape is an error.
---@class WaxStoreShapeOptions
---@field from? { [1]: number, [2]: number } Where the first node goes. For "line" and a "tree" that grows right `{ 500, 850 }` when omitted, for "grid" and a "tree" that grows down `{ 500, 250 }`.
---@field step? number|{ [1]: number, [2]: number } From one node to the next. For "line" a distance (350) or a pair, for a "tree" a pair (`{ 500, 350 }`, or `{ 350, 300 }` when it grows down), for a "radial" tree the distance between rings (360).
---@field angle? number For "line" with a `step` that is one number: the direction. 0 when omitted.
---@field cell? number|{ [1]: number, [2]: number } For "grid": how wide and high one cell is. `{ 350, 300 }` when omitted.
---@field columns? integer For "grid": how many nodes go in a row.
---@field rows? integer For "grid": the most rows there can be. A row holds as many nodes as that takes, and each row is filled from the left, so fewer rows can come out: 5 nodes with `rows = 4` make rows of 2, 2 and 1. When neither this nor `columns` is given, the most rows that fit the screen's height.
---@field center? { [1]: number, [2]: number } For "ring", "arc", "spiral" and a "radial" tree: the middle. When omitted the shape is put at height 850, with no node left of 500.
---@field radius? number|{ [1]: number, [2]: number } For "ring" and "arc": how far the nodes are from the middle, or a pair for an oval. When omitted it is the smallest that keeps neighbours 360 apart, and an oval no taller than the screen when a circle would not fit.
---@field start? number For "ring" and "arc": the angle of the first node. For "spiral", whose first node sits in the middle: the direction of the second node from there. -90 for "ring" and "spiral", 180 for "arc".
---@field sweep? number For "ring" and "arc": how far round the nodes go. 360 for "ring", 180 for "arc".
---@field gap? number For "spiral": how far a node is from the next, and one turn from the next turn. 1 or more, and 360 when omitted.
---@field turn? "right"|"left" For "spiral": which way it turns. "right" when omitted.
---@field direction? "right"|"down"|"radial" For "tree": which way it grows. "right" when omitted, which is the way the store pans.
---@field points? { [1]: number, [2]: number }[] For "path": the places the path goes through.

---How a category places the nodes that have no `at`: a shape and its options.
---@class WaxStoreArrange : WaxStoreShapeOptions
---@field shape? "line"|"grid"|"ring"|"arc"|"spiral"|"tree"|"path"|fun(index: integer, id: string, count: integer): number, number The shape. "tree" when omitted.

---One category of a described store. With `id` and `name` it is a new category. With `into` its nodes go into one of the game's categories.
---@class WaxStoreCategorySpec
---@field id? string Letters, digits and _. The category's rows are named "<ModId>_<id>", which can be 100 characters long at most.
---@field into? string The row name of one of the game's categories, such as "Workshop_Axes". With the shapes "tree", "line" and "grid", nodes without an `at` start to the right of what it has, unless `from` says where. Two entries with the same `into` are each arranged by themselves, with those shapes the later one to the right of the earlier one's nodes as well, and Check looks at the nodes of both together.
---@field name? string The name to show for a new category.
---@field icon? string The path of a texture of the game's for a new category.
---@field background? string The path of a texture to show behind the nodes of a new category.
---@field level? integer The level a new category's row asks for. 0 when omitted.
---@field arrange? "line"|"grid"|"ring"|"arc"|"spiral"|"tree"|"path"|WaxStoreArrange|fun(index: integer, id: string, count: integer): number, number How nodes without an `at` are placed: a shape's name, a shape with options, or a function that returns a place for each. "tree" when omitted.
---@field nodes WaxStoreNodeSpec[] Its nodes. At least one.

---A store as a mod describes it. game.Workshop:Check says what is wrong with it, and game.Workshop:Define puts it into the game.
---A node added to one of the game's categories (`into`) shows there with its picture, price and line. When that happens while the
---player stands in the store, Wax has the game build its store again, so the node can be bought at once, and it goes again when the mod is switched off.
---What the account has researched is kept by the game under the node's row name, so it is still there after the mod was off for a while.
---A new category of a mod's own is not switched on in this version.
---@class WaxStoreSpec
---@field mod? string The id of the mod it belongs to. Not needed when the mod itself calls Check.
---@field categories WaxStoreCategorySpec[] Its categories. At least one.

---The measures the store's screen sets, in the store's own units.
---@class WaxStoreLimits
---@field Size integer How wide and high a node is: 250.
---@field Gap integer The least distance between the middles of two nodes in the game's own store: 300.
---@field Top integer The smallest height of a middle that is known to fit a 1080p screen: 250.
---@field Bottom integer The largest such height: 1450.
---@field Edge integer A middle nearer than this to the canvas's left or top has part of its node outside: 125.
---@field Far integer No number of a place can be further than this from 0: 1000000.

---A place for a node: its middle. Neither number can be further than 1000000 from 0.
---@class WaxStorePlace
---@field X number
---@field Y number
---@field Id string? A name for it in what Check says. "Place 3" when omitted.
---@field Size number? 0 for a joint, which Check leaves out. 250 when omitted.

---Shapes that place a category's nodes, and what does not fit the store's screen.
---A place is the middle of a node in the store's own units, on a canvas that begins at 0, 0 at the top left.
---The store pans sideways only, so a category can be as wide as it likes and its height has to fit the screen.
---@class WaxStoreLayout
local Layout = {}

---Places for nodes in a shape, in the order the nodes were given, rounded to whole numbers.
---"line" puts them one after the other, "grid" in rows, "ring" and "arc" round a middle, "spiral" outwards from a middle,
---"path" evenly along a line through points, and "tree" by what each node needs: a node goes one step further than the furthest node it needs.
---A function is called with (index, id, count) for each node and returns its place as two numbers.
---The defaults keep to the screen's height where the count allows. Options you give are used as they are. A wrong shape or option raises an error that suggests the right name.
---A shape that would put a node further than 1000000 from 0 raises an error too. One call places up to 10000 nodes.
---@param shape "line"|"grid"|"ring"|"arc"|"spiral"|"tree"|"path"|fun(index: integer, id: any, count: integer): number, number
---@param items integer|any[]|{ id: any, needs?: any }[] How many nodes, or a list of ids. For "tree" a list of `{ id = , needs = }`, where `needs` is one id, a list of ids, or a table with `any` and `all` as a described store has it. A node goes after every node it needs, whichever of these names it.
---@param options? WaxStoreShapeOptions
---@return WaxStorePlace[]
function Layout:Place(shape, items, options) end

---What does not fit among places that share a category, as warnings: two nodes that lie on each other, two whose middles are closer than 300,
---a node whose middle is outside the heights 250 to 1450, and a node that reaches past the canvas's left or top.
---A place that is not two numbers, one further than 1000000 from 0, and a Size that is not a number raise an error that says which place it is.
---@param places WaxStorePlace[]
---@return WaxStoreProblem[]
function Layout:Check(places) end

---The names of the shapes.
---@return string[]
function Layout:GetShapes() end

---The measures Check and the shapes go by.
---@return WaxStoreLimits
function Layout:GetLimits() end

---The store on the station, which the game calls the Workshop: its categories, its nodes and their prices, and where the player stands with them.
---The categories, nodes and prices are read from the game's tables and can be asked anywhere. What the player has researched and holds can be asked while IsReady is true.
---Nothing here buys, researches or replicates anything.
---Node, Category and Reset change the store for the mod that calls them: prices, places, what a node needs, line styles and levels.
---Every change is a change of the game's tables made through game.Data. It is checked first, belongs to the mod, and is put back when the mod unloads.
---After a change Wax asks the game's store to refresh, and asks each changed node on the store's screen to read its row and its store item again.
---In the game that was seen to bring a node's place and price up to date while the store was not showing. With the store open it has not been looked at yet.
---The store is paid from each player's own account.
---What cannot be undone is what a player did while a change stood: what they researched is saved in their account under the node's row name,
---whatever it cost then, and Wax pays nothing back and takes nothing away when a price or a requirement changes or goes back.
---Row names are matched without regard to letter case. What is returned is a new table each time, yours to change.
---@class WaxWorkshop
---@field Changed WaxSignal<fun(what: "player"|"store")> Fires with "player" when the player's side changed: the store came or went, its points changed, the account's list of researched rows grew or shrank, or the amount held of a currency changed. Fires with "store" when game.Data dropped rows of the store's tables, so they may read differently now. The player's side is looked at about twice a second, and only while something is connected.
---@field Layout WaxStoreLayout Shapes that place nodes, and what does not fit the store's screen.
local Workshop = {}

---True while the player has a store to ask. That is so in a prospect, and not at the title screen.
---@return boolean
function Workshop:IsReady() end

---Reads the whole store ahead of time, a slice a frame, and returns how many nodes it has. It only works inside a task.
---Without it, the first GetNodes, also of one category, and the first Check of a store that gives something read every row of D_Talents
---and every node of the store in that one call, which holds the game up.
---@return integer nodes
function Workshop:Load() end

---The store's categories, in the order the game lists them.
---@return WaxStoreCategory[]
function Workshop:GetCategories() end

---The nodes of one category, in the order of the game's table. With no category named, the nodes of every category:
---one category after the other as GetCategories lists them, each in the order of the game's table. Joints are among them.
---Each call builds the list anew (329 nodes for the whole store), so keep what it returns and ask again when Changed fires with "store".
---Do not call it every frame. What the player has bought is GetState, not this list.
---A category the store does not have raises an error that suggests the right name.
---@param category? string A category's row name, such as "Workshop_Axes".
---@return WaxStoreNode[]
function Workshop:GetNodes(category) end

---One node by its row name, or nil when the store has no such node.
---@param id string A node's row name, such as "Workshop_Axe_Printed".
---@return WaxStoreNode?
function Workshop:GetNode(id) end

---The game's currencies, in the order of its table.
---@return WaxStoreCurrency[]
function Workshop:GetCurrencies() end

---Where a node stands for the player, as the game's own model of the store answers: "bought" when it is researched,
---"available" when the model says it can be researched next, "locked" otherwise. What it costs is not part of the answer,
---and neither is the lock the store's screen keeps for a node that waits for a mission.
---A joint answers as the game counts it. Nil when the store has no such node, when the player's store does not hold it, and while IsReady is false.
---Each call asks the game, so call it when something is shown or pressed, not every frame.
---@param id string A node's row name.
---@return "bought"|"available"|"locked"?
function Workshop:GetState(id) end

---How many of a currency the account holds, read from the profile the game keeps in memory. 0 when the profile does not list the currency.
---Without a name it returns the amount of every currency by row name. Nil while IsReady is false.
---A currency the game does not have raises an error that suggests the right name.
---@param currency? string A currency's row name, such as "Credits".
---@return integer? amount
---@overload fun(self: WaxWorkshop): table<string, integer>?
function Workshop:GetBalance(currency) end

---Checks a store a mod describes and returns what is wrong with it, errors first. Nothing is put into the game.
---Rows are named after the mod that calls it. Give `options.mod` when no mod is calling, as from the command bar.
---A mod's id here is the name of its folder. It has to start with a letter and use only letters, digits and _, because research is saved
---under the row names for good. A mod in a folder named otherwise is told to rename the folder, and nothing else is checked.
---The first check of a store that gives something reads every row of D_Talents, as the first GetNodes does. Call Load first, inside a task.
---An option other than `mod` is an error.
---@param store WaxStoreSpec
---@param options? { mod?: string }
---@return WaxStoreProblem[]
function Workshop:Check(store, options) end

---What a node needs, in the long form Set takes.
---@class WaxStoreNodeNeeds
---@field any? string|string[] Row names of nodes of which one bought is enough. An empty list takes every parent away.
---@field all? string|string[] Refused in this version of Wax: the game has no such rule and nothing keeps it.
---@field level? integer The same as `level` beside it. With no `any`, the node's parents stay as they are.

---What Set changes on a node. What is left out stays as it is.
---@class WaxStoreNodeChange
---@field research? WaxStoreCost What researching the node costs. `{}` is a price of nothing, written as the game writes it: 0 of its first currency. The price is kept in the node's store item (its row of D_WorkshopItems), and every node of the game's own store has a store item to itself. A joint has no price, and asking for one is an error.
---@field replicate? WaxStoreCost What each one made costs, kept in the same store item.
---@field needs? string|string[]|WaxStoreNodeNeeds The row name of a node of the store, a list of names of which one bought is enough, or the long form. Written as the node's list of parents (RequiredTalents). The lock comes from the game's own model of the store, which follows when the frame ends: GetState gives the old answer in the frame of the write and the new one from the next frame on. How the lines to new parents draw on the store's screen has not been seen yet.
---@field at? { [1]: number, [2]: number } The middle of the node, such as `{ 1000, 1150 }`, rounded to whole numbers, each no further than 1000000 from 0.
---@field line? "elbow"|"elbow-down"|"straight"|"none" The line style of the lines into the node: the game's XThenY, YThenX, ShortestDistance or NoLine. No node of the game's own store uses the last two, and how they draw there has not been seen yet.
---@field level? integer The level the node's row asks for (RequiredLevel), 0 or more. No node of the game's own store sets one. The game's model keeps a node locked while the level is above the player's, and follows a change when the frame ends, as with `needs`.

---One node of the store, to change it. It holds the node's row name and nothing of the game, so it can be kept for as long as you like.
---@class WaxStoreNodeHandle
---@field Id string The node's row name, as the game spells it.
local StoreNode = {}

---Changes the node: its prices, what it needs, its place, its line style, its level. It is written before Set returns.
---Everything is checked first, and when something is wrong an error says what, with the nearest right name, and nothing is written:
---an option Set does not have, a currency or a node the game does not have, a price that is not a whole number from 0 to 2147483647,
---a place that is not two numbers, and needs that could never be met, such as the node itself or nodes that wait for each other in a circle.
---When the game's tables refuse one of the fields, what this call had already written is taken back and the error says why.
---Returns what Check would warn about now that the change is in, as warnings: a parent in another category, a node it lies on or too close to,
---a place outside the heights that fit the screen, a straight line that runs over a node, a price in more than two currencies. An empty list when there is nothing.
---The change belongs to the mod and goes back when the mod unloads or calls Reset. When two mods change one field, game.Data's rules decide which shows.
---@param change WaxStoreNodeChange
---@return WaxStoreProblem[] warnings
function StoreNode:Set(change) end

---Takes the node off its tree, so a store the game builds afterwards does not have it. Its row stays in the game's table.
---Switched off in this version of Wax: Hide raises an error that says so. A node in no tree is in no store, and it is not known
---what the game does with a player's research of such a node when it saves their account.
function StoreNode:Hide() end

---Puts a node this mod hid back on its tree. Returns true when it was hidden. Switched off in this version of Wax, like Hide.
---@return boolean shown
function StoreNode:Show() end

---Takes back what this mod changed of the node through its handle: its fields and the prices in its store item. What other mods changed stays.
---@return integer count How many fields were taken back.
function StoreNode:Reset() end

---What AddCategory takes: a new category for the calling mod's store.
---@class WaxStoreCategoryOptions
---@field id string Letters, digits and _. The category's rows are named "<ModId>_<id>".
---@field name string The name to show.
---@field icon? string The path of a texture of the game's.
---@field background? string The path of a texture to show behind the nodes.
---@field level? integer The level the category's row asks for. 0 when omitted.
---@field arrange? "line"|"grid"|"ring"|"arc"|"spiral"|"tree"|"path"|WaxStoreArrange|fun(index: integer, id: string, count: integer): number, number How nodes without an `at` are placed. "tree" when omitted.

---One category of the store, to lay it out or to add nodes to it. It holds a name and nothing of the game.
---@class WaxStoreCategoryHandle
---@field Id string The category's row name, as the game spells it. For a category from AddCategory, the row name it will have.
local StoreCategory = {}

---Gives every node of the category a place in a shape, as Layout:Place does, and writes the places that differ from where the nodes are.
---Joints are placed like any other node, and a "tree" goes by what each node needs inside the category.
---A function is called with (index, row name, count). A wrong shape or option raises an error that suggests the right name, and nothing is written.
---Returns what Check would warn about for the new places: nodes that lie on each other or too close, nodes outside the heights that fit
---the screen, straight lines that run over a node. The places are written all the same.
---Each place is a change of the calling mod, put back when it unloads. On the store's screen the nodes follow a few a frame.
---Every node that moves is written in the one call, so call it when the mod loads or when something is pressed, not every frame.
---For a category from AddCategory it sets the shape for the nodes that have no `at`, as `arrange` does in a described store.
---@param shape "line"|"grid"|"ring"|"arc"|"spiral"|"tree"|"path"|fun(index: integer, id: string, count: integer): number, number
---@param options? WaxStoreShapeOptions
---@return WaxStoreProblem[] warnings
function StoreCategory:Arrange(shape, options) end

---Adds a node to the category, as a node of a described store. In this version of Wax it checks that it was given a table and then
---raises "adding rows to the game's tables is not switched on in this version of Wax".
---@param node WaxStoreNodeSpec
---@return WaxStoreProblem[] warnings
function StoreCategory:Add(node) end

---A node of the store by its row name, to change it. Any node the store has can be named, whichever mod added it.
---A name the store does not have raises an error that suggests the nearest one.
---@param id string A node's row name, such as "Workshop_Axe_Printed".
---@return WaxStoreNodeHandle
function Workshop:Node(id) end

---A category of the store by its row name, to lay it out or to add nodes to it. A name the store does not have raises an error that suggests the nearest one.
---@param id string A category's row name, such as "Workshop_Axes".
---@return WaxStoreCategoryHandle
function Workshop:Category(id) end

---A new category for the calling mod's store, to add nodes to. In this version of Wax it checks the names of its options and then raises
---"a new category is not switched on in this version of Wax": a category's name is text and its picture a reference to an asset,
---and game.Data does not write those yet.
---@param options WaxStoreCategoryOptions
---@return WaxStoreCategoryHandle
function Workshop:AddCategory(options) end

---Puts a described store into the game: rows for its new categories, its nodes, what they sell and what they hand over, each named
---"<ModId>_<id>" and added by the mod they are named after. The description is checked as Check does it, and an error of Check is raised
---as an error here, with how many more there are.
---In this version of Wax a store that passes then ends in one of three errors and nothing is added: a node that needs `all` of several
---is refused, a store with a new category raises "a new category is not switched on in this version of Wax", and any other store raises
---"adding rows to the game's tables is not switched on in this version of Wax".
---Research is saved in the player's account under a node's row name for good. So an id, and with it the mod's folder name, never changes
---once players have the mod: a node under a new name is a new node, and what was researched under the old name no longer counts.
---@param store WaxStoreSpec
---@return WaxStoreProblem[] warnings
function Workshop:Define(store) end

---Takes back everything the calling mod changed through Node and Category: every field goes back to what it would hold without this mod.
---What the mod changed through game.Data itself, and what other mods changed, stays. If the game does not take a field back, an error says so
---and that change stands, so Reset can be called again.
---@return integer count How many changes were taken back.
function Workshop:Reset() end
