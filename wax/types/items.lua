---@meta _

---What a kind of item is, from the game's own tables. The table is yours: changing it changes nothing in the game.
---@class WaxItemFacts
---@field Name string The item's name: its row in D_ItemsStatic, spelled as the game spells it.
---@field DisplayName string The name the game shows players, in the language the game was showing when it was read. The item's own name when the game shows none.
---@field Description string? The game's description of the item. nil when it has none.
---@field Weight number? What one of them weighs, in kilograms. nil for an item the game keeps no such facts about.
---@field MaxStack integer? How many fit in one stack. nil for an item the game keeps no such facts about.
---@field MaxDurability integer? Its durability when new. nil for an item the game gives no durability.
---@field Icon string? The path of its picture in the game's files. nil when it has none.

---One stack in a slot of an inventory. Its fields are plain values, and changing them changes nothing in the game.
---Equip and Activate are functions: they tell the game to put this stack in a character's hand.
---@class WaxItemStack
---@field Item string The item's name as the game spells it. The game's own files do not always use the same letter case, so compare two names without it, or ask Count, Has or Where.
---@field Count integer How many are in the stack. 1 for an item the game keeps no stack number for.
---@field Slot integer The slot it is in, counted from 1. The game's own functions count from 0: their Location is Slot - 1.
---@field Durability integer? How much durability it has left. nil for an item the game keeps none for.
---@field Properties table<string|integer, integer>? Every number the game keeps for this stack, under the game's own name for it (EDynamicItemProperties): ItemableStack, Durability, GunCurrentMagSize, CurrentAmmoType, MillijoulesRemaining, TransmutableUnits, Fillable_StoredUnits, Fillable_Type, Decayable_CurrentSpoilTime and the others. One this version of Wax has no name for is under its number. nil when the game keeps none.
---@field Inventory string? Which inventory of the character it is in: "Backpack", "Hotbar", "Equipment", "Suit", "Upgrades" or "Vision". Only what a character's List and HeldItem give has it.
local Stack = {}

---Puts this stack into the character's hand. The game focuses this slot of its inventory. The location the game uses is Slot - 1.
---game.Me.Equipped follows on its next look. A hotbar key does the same kind of change, and Equipped follows that too.
---The stack has to be one that Slot, List, Where or HeldItem gave.
function Stack:Equip() end

---Puts this stack into the character's hand, then fires game.Me.Activated with the stack and `use`.
---With a use name, the game also runs that row of D_Uses. "Consume" and "Place" are two such names. A name the game does not have raises an error.
---With no name, the stack is in the hand and Activated fires with nil. A tool's swing is the game's fire button.
---@param use? string The name of a row of D_Uses. Leave it out to put the stack in the hand.
function Stack:Activate(use) end

---The kinds of item the game has, and the facts of each. Nothing is read until you ask, and what was read is kept.
---An item is named by its row in D_ItemsStatic, such as "Wood" or "Stone_Pickaxe". Letter case, spaces, underscores and
---hyphens do not matter, so "stone pickaxe" names the same item.
---@class WaxItems
local Items = {}

---The facts of one kind of item. A name the game does not have raises an error that suggests the nearest names, so ask
---Has first when the name may be wrong. The first time an item is asked for, up to three rows of the game's tables are
---read. After that it costs nothing, until a mod changes those tables or the game makes them again.
---@param item string|WaxItemStack|WaxItemFacts The item's name, or a record that List or Get gave.
---@return WaxItemFacts
function Items:Get(item) end

---True when the game has an item of this name.
---@param name string
---@return boolean
function Items:Has(name) end

---The name of every item, spelled and ordered as the game has them.
---@return string[]
function Items:GetNames() end

---The names of the items whose name contains the text: first the ones that begin with it, then the others, each group sorted.
---Once Load has run, an item also matches when the name the game shows for it contains the text. "iron" then finds
---Metal_Ore, which the game shows as Iron Ore. Letter case, spaces, underscores and hyphens do not matter.
---It goes through every item, so call it when the player types something, not every frame.
---@param text string
---@return string[]
function Items:Find(text) end

---Reads the name the game shows for every item, so that Find matches those names too. It only works inside a task: it
---reads within a millisecond a frame and returns when all are read. Rows another mod has read already are not read again.
---When a mod changes the item tables, or the game makes them again, Find goes by item names alone until Load has run again.
---@return integer count How many items have a shown name.
function Items:Load() end

---What Wax adds to every inventory: every Instance whose class is Inventory. A player's character has six of them, and
---other things that hold items have their own.
---
---Wax keeps a copy of an inventory that is asked about, so asking often costs little. It looks at the inventory again at
---most four times a second. When the weight or the number of slots is not what it was, every slot is read again.
---Otherwise a few slots are read in turn, so that all of them are read again within two seconds while you keep asking.
---An inventory that was not asked about for two seconds is read whole the next time. The game works a weight out a
---moment after the items change, so a new stack or a used-up one shows about a quarter of a second later, and what
---changes without the weight changing, such as durability or a stack moved to another slot, within two seconds.
---Refresh reads it all at once.
---
---Where the game itself tells Wax of a slot it changed, the copy follows at that moment and none of that waiting
---applies. That was seen for the inventories of a player's character on the host of a session. For a chest or a bench,
---and as a guest in someone else's game, it has not been tried, and there the looking above is what keeps the copy right.
---
---A field is nil, and a function raises an error that says so, when the game no longer keeps its inventories the way
---Wax reads them.
---@class WaxInventory
---@field ItemAdded WaxSignal<fun(item: string, amount: integer, stack: WaxItemStack?)> Fires when the inventory holds more of an item than a frame before: the item's name as the game spells it, how many more, and a stack it went onto. It is told by the game, for every slot the game says it changed, so it only fires where the game tells of an inventory: see above. A stack that moves to another slot of the same inventory within a frame is not added. Connecting reads the inventory whole once.
---@field ItemRemoved WaxSignal<fun(item: string, amount: integer, stack: WaxItemStack?)> Fires when the inventory holds fewer of an item than a frame before: the item, how many fewer, and a stack it came out of as that was before.
---@field ItemChanged WaxSignal<fun(stack: WaxItemStack?, previous: WaxItemStack?)> Fires for every slot that holds something else than a frame before: what it holds now, nil for nothing, and what it held. A tool that wore and a stack that moved are changes too. A spoil timer that only counts down is not. After a map change the handlers of all three are disconnected.
---@field Kind string? What kind of inventory the game says it is: its row of D_InventoryInfo, such as "Backpack", "Quickbar" or "Equipment". It is asked of the game each time it is read.
---@field Size integer? How many slots it has. #inventory is this number.
---@field Used integer? How many of its slots hold something.
---@field Weight number? What everything in it weighs, in kilograms. It is asked of the game each time it is read.
local Inventory = {}

---Every stack in the inventory, in the order of its slots.
---@return WaxItemStack[]
function Inventory:List() end

---What one slot holds, or nil when it is empty. Slots are counted from 1 to Size, and another number raises an error.
---inventory[n] is this. An empty slot is nil, so a loop from 1 to #inventory reaches every slot.
---@param slot integer
---@return WaxItemStack?
function Inventory:Slot(slot) end

---How many of an item the inventory holds, over all its stacks. Only its own slots are counted, not what an item in it
---holds inside. An item is named as game.Items names it, and a name the game does not have raises an error that suggests
---the nearest names.
---@param item string|WaxItemStack|WaxItemFacts The item's name, or a record that List or game.Items:Get gave.
---@return integer
function Inventory:Count(item) end

---True when the inventory holds at least `count` of an item. One when `count` is omitted.
---@param item string|WaxItemStack|WaxItemFacts
---@param count? number
---@return boolean
function Inventory:Has(item, count) end

---The stacks of an item in the inventory, in the order of their slots. An empty list when it holds none.
---@param item string|WaxItemStack|WaxItemFacts
---@return WaxItemStack[]
function Inventory:Where(item) end

---Reads every slot again now. A whole backpack took the game between half a millisecond and a millisecond and a half
---when it was measured, so use it when something has to be exact at once, not every frame.
function Inventory:Refresh() end

---Puts items into the inventory. They go
---onto the stacks of that item first, then into empty slots that the game says take that kind of item, a full stack to
---a slot. What does not fit is not given, and nothing is dropped on the ground. A tool comes as the game makes a new
---one, with its full durability. Count, Has and List follow in the same frame, the weight a moment later.
---It has been tried on a player's backpack.
---@param item string|WaxItemStack|WaxItemFacts The item's name, or a record that List or game.Items:Get gave. A name the game does not have raises an error that suggests the nearest names.
---@param count? integer How many, from 1 to 100000. One when omitted.
---@return integer given How many went in.
---@return string? why Why not all of them, in plain words, when fewer went in: "there was no room for 3 of the 10".
function Inventory:Give(item, count) end

---Takes items out of the inventory. They are gone, not dropped, and the last stack of the item goes
---first. It has been tried on a player's backpack and hotbar.
---@param item string|WaxItemStack|WaxItemFacts
---@param count? integer How many, from 1 to 100000. One when omitted.
---@return integer taken How many were taken.
---@return string? why Says how many there were, when there were fewer than asked for.
function Inventory:Take(item, count) end

---Gives the inventory this many slots. Slots are added and taken at its end. A slot that holds
---something is never taken, nor any slot before it: the inventory then keeps as many as it needs, and the second value
---says so. Size, List and the others follow in the same frame.
---It lasts as long as the inventory does: one the game makes anew, as on a map change, has the number of its row of
---D_InventoryInfo again. It has been tried on the station's loadout, from 15 to 50 slots and back.
---@param slots integer How many slots it should have, from 1 to 500.
---@return integer size How many it has now.
---@return string? why Why not what was asked, in plain words: "slot 31 holds something, so 31 slots stay".
function Inventory:Resize(slots) end

---What Wax adds to a player's character for the things it carries: every Instance whose class is IcarusPlayerCharacter or
---is built on it, and game.Me. Each inventory is an Instance of the game's Inventory with what WaxInventory lists, and is
---nil when the character has no such inventory, as the character in the station has no backpack. An inventory Wax
---cannot read is left out of Count, Has and List.
---@class WaxPlayerItems
---@field Backpack Inventory|WaxInventory? The character's backpack: its BackpackInventory.
---@field Inventory Inventory|WaxInventory? The character's backpack, the same value as Backpack. On a creature, Inventory stays the inventory the game keeps on it.
---@field Hotbar Inventory|WaxInventory? The character's hotbar: its QuickbarInventory. hotbar[n] is hotbar:Slot(n), and #hotbar is how many slots it has. An empty slot is nil, so count from 1 to #hotbar to see every slot.
---@field ShipInventory Inventory|WaxInventory? The cargo of the dropship assigned to this character, the hold the game calls DropShip_Equipment. nil while this character has no assigned dropship, as on the station. Count, Has and List on the character count the six inventories it carries; ask the ship with its own. Wax looks the ship up at most once a second. The hold the game calls Dropship_RemoveOnly is a different inventory.
---@field Equipment Inventory|WaxInventory? What the character wears: its EquipmentInventory.
---@field Suit Inventory|WaxInventory? The character's EnvirosuitInventory.
---@field Upgrades Inventory|WaxInventory? The character's UpgradeInventory.
---@field Vision Inventory|WaxInventory? The character's VisionInventory.
---@field HotbarSlot integer? The slot of the hotbar the game says is in hand, counted from 1. The keys 1 to 9 and 0 are the slots 1 to 10, the box the game shows with G is slot 11, and with bare hands the game names slot 12. nil when the game names none, as it does for a moment after the item in hand is used up.
---@field HeldItem WaxItemStack? What sits in that slot of the hotbar, or nil when it is empty. With bare hands it is the game's own item Player_Fist. It is as fresh as the hotbar's copy: see WaxInventory.
local PlayerItems = {}

---How many of an item the character carries, over those six inventories.
---@param item string|WaxItemStack|WaxItemFacts The item's name, or a record that List or game.Items:Get gave.
---@return integer
function PlayerItems:Count(item) end

---True when the character carries at least `count` of an item. One when `count` is omitted.
---@param item string|WaxItemStack|WaxItemFacts
---@param count? number
---@return boolean
function PlayerItems:Has(item, count) end

---Every stack the character carries: the backpack's first, then the hotbar's, what it wears, and the other three, each
---in the order of its slots. Each record says in `Inventory` which one it is in.
---@return WaxItemStack[]
function PlayerItems:List() end

---Gives the character items into its backpack, as the backpack's own Give does. What does not fit
---in the backpack is not given: nothing goes to the hotbar and nothing is dropped.
---@param item string|WaxItemStack|WaxItemFacts
---@param count? integer How many, from 1 to 100000. One when omitted.
---@return integer given How many went in.
---@return string? why Why not all of them, when fewer went in.
function PlayerItems:Give(item, count) end

---Takes items away from the character: out of its backpack first, then out of its hotbar. What it
---wears and what its other inventories hold is left alone. Take from one of those with the inventory's own Take.
---@param item string|WaxItemStack|WaxItemFacts
---@param count? integer How many, from 1 to 100000. One when omitted.
---@return integer taken How many were taken.
---@return string? why Says how many there were, when there were fewer than asked for.
function PlayerItems:Take(item, count) end
