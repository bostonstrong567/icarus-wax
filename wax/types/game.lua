---@meta _

---An engine object. Every class of the game (Actor, Pawn, IcarusPlayerCharacter ...) is an Instance: it has what is
---listed here, and adds the properties and functions of its own class and of the classes that one is built on.
---A member the editor does not know is still read from the object, so nothing here stops you using it.
---@class WaxInstance : table
---@field Name string The object's name.
---@field ClassName string The name of the object's class.
---@field FullName string The engine's full name for the object: its class, then its path.
---@field Parent WaxInstance? What GetParent() returns.
---@field Raw any The UE4SS object itself, for unchecked access.
---@field [string] any
local Instance = {}

---Reads a reflected property by name, including one whose name Wax also uses (Name, Parent ...).
---@param name string
---@return any
function Instance:Get(name) end

---Writes a reflected property by name, converting and checking the value first.
---@param name string
---@param value any
function Instance:Set(name, value) end

---Calls a reflected function by name, converting and checking the arguments first.
---@param name string
---@param ... any
---@return any
function Instance:Call(name, ...) end

---False once the object has been destroyed or the map has changed.
---@return boolean
function Instance:IsValid() end

---True when the object's class is, or inherits from, the named class ("Actor", "BP_IcarusPlayerCharacterSurvival_C").
---@param class_name string
---@return boolean
function Instance:IsA(class_name) end

---The class names from this object's own class up to Object.
---@return string[]
function Instance:GetClassChain() end

---Every property and function name this object has, with the names Wax gives its class, sorted.
---@return string[]
function Instance:GetMembers() end

---The actor or component this one is attached to. For an actor attached to nothing it is the world, and for anything else the object's outer.
---@return WaxInstance?
function Instance:GetParent() end

---The children: actors for the world, components and attached actors for an actor, attached components for a component.
---@return WaxInstance[]
function Instance:GetChildren() end

---The first child with this Name, or nil. `recursive` searches every descendant.
---@param name string
---@param recursive? boolean
---@return WaxInstance?
function Instance:FindFirstChild(name, recursive) end

---The first child of exactly this class, or nil.
---@generic T : WaxInstance
---@param class_name `T`
---@return T?
function Instance:FindFirstChildOfClass(class_name) end

---The first child of this class or a class derived from it, or nil.
---@generic T : WaxInstance
---@param class_name `T`
---@return T?
function Instance:FindFirstChildWhichIsA(class_name) end

---Every Instance below this one, nearest first, stopping at `limit` (default 5000).
---@param limit? integer
---@return WaxInstance[]
function Instance:GetDescendants(limit) end

---The value SetAttribute stored on the Instance under `name`, or nil.
---@param name string
---@return any
function Instance:GetAttribute(name) end

---A copy of every attribute, as name -> value.
---@return table<string, any>
function Instance:GetAttributes() end

---Stores a value on the Instance under `name`. nil removes it.
---@param name string
---@param value any
function Instance:SetAttribute(name, value) end

---A signal for one attribute, fired with (value, previous). Without a name it covers every attribute and fires with (name, value, previous).
---@param name string
---@return WaxSignal<fun(value: any, previous: any)>
---@overload fun(self: WaxInstance): WaxSignal<fun(name: string, value: any, previous: any)>
function Instance:GetAttributeChangedSignal(name) end

---A signal for one value of the object: a property of the game's that holds a number, true or false, text or an object, or a field Wax gives the class.
---It fires with (value, previous) when the value is found changed. The value is read ten times a second, and only while a handler is connected.
---An object arrives as an Instance, or nil when the property holds none. A table a field returns is compared by what it holds.
---`seconds` sets another time between reads, up to 3600. It is rounded to the nearest 0.05, and anything under 0.05 counts as 0.05. When one value is asked for at two paces, the faster is used.
---It works on an actor in the world and on a component that a property of its actor holds. Anything else raises an error that says why.
---When the object is gone, reading stops and every handler is disconnected. A task that waits on the signal is then not woken.
---A wrong name raises an error that suggests the right one.
---@param name string
---@param seconds? number
---@return WaxSignal<fun(value: any, previous: any)>
function Instance:GetPropertyChangedSignal(name, seconds) end

---Marks the Instance with a tag. game:GetTagged(tag) finds it again.
---@param tag string
function Instance:AddTag(tag) end

---Takes a tag off the Instance.
---@param tag string
function Instance:RemoveTag(tag) end

---True when the Instance carries the tag.
---@param tag string
---@return boolean
function Instance:HasTag(tag) end

---The Instance's tags, sorted.
---@return string[]
function Instance:GetTags() end

---The players in the session and the characters they control, with signals for when they come and go.
---@class WaxPlayers
---@field LocalPlayer IcarusPlayerController The local player's controller, the same as game.LocalPlayer.
---@field CharacterAdded WaxSignal<fun(character: IcarusPlayerCharacter)> Fires when a player's character appears.
---@field CharacterRemoved WaxSignal<fun(character: IcarusPlayerCharacter)> Fires when a player's character leaves the world.
---@field Joined WaxSignal<fun(player: IcarusPlayerState)> Fires when a player is in the session who was not there at the last look. The players are looked at once a second, and only while a handler is connected to Joined or Left. It does not fire for the players who are there when you connect, nor for those who are there on another map when the map changes.
---@field Left WaxSignal<fun(player: IcarusPlayerState, name: string?)> Fires when a player who was in the session is gone at the next look, with the name that was last seen. The Instance can no longer be used, only compared. It is looked at with Joined, and does not fire for the players a map change takes away.
local Players = {}

---One Instance per player in the session (their player state). Works for the host and for clients.
---@return IcarusPlayerState[]
function Players:GetPlayers() end

---The characters those players are controlling right now.
---@return IcarusPlayerCharacter[]
function Players:GetCharacters() end

---Calls fn(character) for each player's character that is here now and each that appears later (a join, a respawn).
---If fn returns a function, that runs when the character is gone or the watch is stopped.
---@param fn fun(character: IcarusPlayerCharacter): (fun()?)
---@return WaxConnection
function Players:ObserveCharacters(fn) end

---The name of the player who controls a character, or nil while the game has not said yet.
---@param character IcarusPlayerCharacter
---@return string?
function Players:GetName(character) end

---True for the character this player controls.
---@param character IcarusPlayerCharacter
---@return boolean
function Players:IsLocal(character) end

---The options GetAll, GetNearest and GetTamed take: which creatures to give, and in what order.
---@class WaxCreatureQuery
---@field within? number Only creatures this many metres away or nearer. The result is then sorted nearest first.
---@field from? WaxInstance|{ X: number, Y: number, Z: number } Where to measure from. Your character when omitted.
---@field dead? boolean True also returns bodies that have not been cleared away yet.
---@field sort? "nearest" Sorts nearest first without a distance limit.

---One kind of creature, as GetKinds lists it. The table is a copy: it does not change when creatures come and go.
---@class WaxCreatureKind
---@field Name string The kind's name in the game's data, such as "Wolf".
---@field DisplayName string The name the game shows players.
---@field Tag string The game's own tag for the kind, such as "NPC.Wolf".
---@field Variants string[] The versions of the kind, such as "Conifer_Wolf" and "Snow_Wolf".
---@field Count integer How many are in the world now.

---What Describe gives: the common facts about one creature as plain values, as they were when it was asked.
---@class WaxCreatureFacts
---@field Kind string
---@field Variant string
---@field DisplayName string
---@field ClassName string
---@field Name string
---@field IsAlive boolean
---@field Health integer?
---@field MaxHealth integer?
---@field Level integer?
---@field Position { X: number, Y: number, Z: number } In the engine's units: 100 is one metre.

---What Removed and Died give beside the creature: what it was, as plain values that can still be read when the creature cannot.
---Reason and Position come with Removed only. Killer, Instigator and Damage come with Died only.
---@class WaxCreatureEnd
---@field Kind string
---@field Variant string
---@field ClassName string
---@field Name string
---@field Reason? "Destroyed"|"Unloaded" Only with Removed: "Destroyed" when the game took the creature out of the world, "Unloaded" when its part of the map or the whole map went.
---@field Position? { X: number, Y: number, Z: number } Only with Removed: where it was, when the game could still say.
---@field Killer? WaxInstance Only with Died: the actor the game named as what did the hit that left the creature no health. nil for a death with no hit that Wax heard, such as one by Kill(). A death that is seen by looking waits up to 0.4 seconds for the game's word of the hit, so Died comes that much later.
---@field Instigator? WaxInstance Only with Died: the controller the game named as who did that hit.
---@field Damage? integer Only with Died: the damage of that hit.

---A creature. Nearly all are an IcarusNPCCharacter. A few bosses are an IcarusPawn.
---@alias WaxCreature IcarusNPCCharacter|IcarusPawn

---The animals and enemies in the world, kept as a live list. A kind is named the way the game names it: "Wolf",
---"Conifer_Wolf", "Cave Worm". Letter case, spaces and underscores do not matter. A wrong name raises an error that suggests the right one.
---@class WaxCreatures
---@field Added WaxSignal<fun(creature: WaxCreature)> Fires for each creature that appears from now on.
---@field Removed WaxSignal<fun(creature: WaxCreature, info: WaxCreatureEnd)> Fires when a creature leaves the world. The Instance can no longer be used, only compared.
---@field Died WaxSignal<fun(creature: WaxCreature, info: WaxCreatureEnd)> Fires when a creature is killed, a few seconds before it is removed.
---@field Cleared WaxSignal<fun()> Fires once when the map changes, in place of one Removed per creature.
---@field GetModel fun(self: WaxCreatures, name: string, options?: WaxCreatureModelOptions): WaxCreatureModel?, string? What a Model control needs to show a creature, by its set-up row ("Bear", "Conifer_Wolf") or its kind ("Wolf"). The creature does not have to be in the world. With options.saddle a mount wears that saddle in the picture, such as GetModel("Mount_Horse", { saddle = "Saddle_Standard" }). Gives nil and the reason when Wax has no model for it, or no such saddle for that mount; a name that is no creature raises an error.
---@field GetSaddles fun(self: WaxCreatures, name: string): WaxSaddle[], string? What Wax can put on a creature's model through GetModel's saddle option, in the order of the game's saddle table: saddles, carts, a pack harness and the like, for the set-up row of a tamed mount such as "Mount_Horse". An empty list for a creature that wears nothing, and for one Wax has no model for, with the reason as a second value. A name that is no creature raises an error.
---@field Damaged WaxSignal<fun(creature: WaxCreature, amount: integer, info: WaxDamageInfo)> Fires when the game says a creature took damage: the creature, the damage of the hit, and what the game knows of it, as Damaged of a character hands it over. The game's own damage call is listened to from the first handler on, and nothing is looked at meanwhile. It tells of the creatures that are an IcarusNPCCharacter, which nearly all are. Seen on the host of a session.
---@field Spawn fun(self: WaxCreatures, kind: string, place?: WaxInstance|WaxMe|{ X: number, Y: number, Z: number }, options?: WaxSpawnOptions): WaxCreature?, string? Puts a new wild creature into the world with the game's own spawn, for the host only: in someone else's game it raises an error that says so. kind is a variant such as "Conifer_Wolf" or "Deer", or a kind that has one variant. A kind with several raises an error that lists them. place is a position, an actor or game.Me. When it is omitted the creature goes six metres in front of your character, and the options may stand in its place. Wax asks the game for ground a creature can walk on near the place, within 5 metres to the sides and at any height, and puts the creature a little above it. Where the game has none it raises an error and nothing is spawned. Inside a task Spawn waits until the game has given the creature its level, two seconds at most, and then answers the creature. Outside a task it answers at once, and Level and Health are right a few frames later. It answers nil and the reason when the creature left the world before it was finished. A tamed variant is refused in this version of Wax. The game's call took 3 to 4 ms when it was timed, and 18 ms once: a kind that is not in memory is loaded by the game inside the call. What is spawned stays when the mod unloads, unless the option keep is false.
local Creatures = {}

---Every creature, or those of one kind. Dead ones are left out unless asked for.
---@param kind? string
---@param options? WaxCreatureQuery
---@return WaxCreature[]
---@overload fun(self: WaxCreatures, options: WaxCreatureQuery): WaxCreature[]
function Creatures:GetAll(kind, options) end

---The closest matching creature and its distance in metres, or nil.
---@param kind? string
---@param options? WaxCreatureQuery
---@return WaxCreature?, number?
---@overload fun(self: WaxCreatures, options: WaxCreatureQuery): WaxCreature?, number?
function Creatures:GetNearest(kind, options) end

---How many creatures of a kind are in the world now.
---@param kind? string
---@return integer
function Creatures:Count(kind) end

---Every kind this version of the game has, with how many of each are here now.
---@return WaxCreatureKind[]
function Creatures:GetKinds() end

---The names of the kinds that are in the world now.
---@return string[]
function Creatures:GetLiveKinds() end

---The kind and variant of a creature, or nil when it is not a creature in the world.
---@param creature WaxCreature
---@return string?, string?
function Creatures:GetKind(creature) end

---The common facts about one creature as plain values.
---@param creature WaxCreature
---@return WaxCreatureFacts
function Creatures:Describe(creature) end

---What the game's tables say about one variant of a kind: its team, diet, carcass and loot, the taming rule that names it, and what it is like as a tamed animal.
---Give a variant such as "Conifer_Wolf", or a creature, for that variant. Give a kind such as "Wolf" for the variant that is named like the kind, or else the kind's first variant. Variants lists them all.
---The first call reads the game's tables of taming rules, tamed animals and saddles. What it read is kept until one of those tables changes or the map does.
---A wrong name raises an error that suggests the right one.
---@param kind string|WaxCreature
---@return WaxCreatureInfo
function Creatures:GetInfo(kind) end

---The tamed animals among the creatures in the world: mounts, pets and livestock, whoever they belong to. Dead ones are left out unless asked for.
---@param kind? string
---@param options? WaxCreatureQuery
---@return WaxCreature[]
---@overload fun(self: WaxCreatures, options: WaxCreatureQuery): WaxCreature[]
function Creatures:GetTamed(kind, options) end

---Calls fn(creature) for each matching creature that is here now and each that appears later.
---If fn returns a function, that runs when the creature is gone or the watch is stopped.
---@param kind? string
---@param fn fun(creature: WaxCreature): (fun()?)
---@return WaxConnection
---@overload fun(self: WaxCreatures, fn: fun(creature: WaxCreature): (fun()?)): WaxConnection
function Creatures:Observe(kind, fn) end

---Outlines every creature of a kind, now and as more appear. Disconnect the result to stop.
---@param kind? string
---@param options? WaxHighlightOptions|WaxHighlightLook
---@return WaxConnection
function Creatures:Highlight(kind, options) end

---@class WaxHighlightOptions
---@field Color? string|{ R: number, G: number, B: number } A name from game.Highlight.Colors, "#rrggbb", or values from 0 to 1. "Red" when omitted.
---@field Fill? boolean Also tints the whole model. True when omitted.
---@field FillColor? string|{ R: number, G: number, B: number }|false The tint's colour when it is not the outline's. false goes back to the outline's colour.

---A colour and fill that many outlines share. Changing it changes all of them at once.
---@class WaxHighlightLook
local Look = {}

---Changes the colour or the fill of every outline that has this look. What is left out stays as it is.
---@param options WaxHighlightOptions
function Look:Set(options) end

---One outlined actor.
---@class WaxHighlightMark
---@field Instance WaxInstance
---@field Active boolean False once it was removed or its actor is gone.
local Mark = {}

---Takes the outline off. Safe to call twice, and after the actor is gone.
function Mark:Remove() end

---Changes the colour or the fill of this one outline: `mark:Set({ Color = "#ff8800", Fill = false })`. What is left out
---stays as it is. An outline that was made with a shared look no longer follows that look afterwards.
---@param options WaxHighlightOptions
function Mark:Set(options) end

---Changes the colour of this one outline, as Set does with `{ Color = color }`.
---@param color string|{ R: number, G: number, B: number }
function Mark:SetColor(color) end

---Outlines actors so they show through walls, using the outline the game itself draws.
---The game has room for four filled colours and three outline-only colours at a time. A colour counts once, however many actors use it.
---@class WaxHighlight
---@field Colors string[] The colour names that can be used.
local Highlight = {}

---Outlines anything with a shape: an actor (a creature, a player's character, an item, something built) or one mesh part of an actor.
---@param target WaxInstance
---@param options? WaxHighlightOptions|WaxHighlightLook
---@return WaxHighlightMark
function Highlight:Add(target, options) end

---Takes the outline off an actor or a part that Add was given. It does nothing when that one has no outline.
---@param target WaxInstance
function Highlight:Remove(target) end

---Takes every outline off.
function Highlight:Clear() end

---The actors that are outlined now.
---@return WaxInstance[]
function Highlight:GetAll() end

---A look to give to many outlines, so one call changes them all.
---@param options? WaxHighlightOptions
---@return WaxHighlightLook
function Highlight:Look(options) end

---Settings every outline shares: Fill is how strongly a filled model is tinted (0 to 1), Width the line width (1 to 4).
---@param options { Fill?: number, Width?: number }
---@return { Fill: number, Width: number }
function Highlight:Configure(options) end

---@alias WaxGameMember
---| "World"
---| "GameInstance"
---| "GameState"
---| "GameMode"
---| "LocalPlayer"
---| "Character"
---| "Engine"
---| "Viewport"
---| "MapName"
---| "InProspect"
---| "Players"
---| "Creatures"
---| "Highlight"
---| "Data"
---| "MapChanged"
---| "IsHost"
---| "Me"
---| "Items"
---| "Time"
---| "Weather"
---| "Prospect"

---The root every mod starts from. It is read-only, and reading a member it does not have raises an error.
---@class WaxGame
---@field World World The current world. Its children are the actors in it.
---@field GameInstance BP_IcarusGameInstance_C Lives from the start of the game to its end.
---@field GameState IcarusGameStateBase The state of the session that every player sees.
---@field GameMode IcarusGameModeBase? The rules of the session. Nil when you are a client in someone else's game.
---@field LocalPlayer IcarusPlayerController The local player's controller. At the title screen it is the title screen's own controller.
---@field Character IcarusPlayerCharacter? The pawn the local player controls. nil at the main menu.
---@field Engine IcarusGameEngine
---@field Viewport IcarusGameViewportClient The game viewport.
---@field MapName string? The name of the current world.
---@field InProspect boolean True while you are in a prospect.
---@field IsHost boolean True when this game runs the session's rules: you play alone or you are the host. False when you are a client in someone else's game, and while there is no world.
---@field Players WaxPlayers
---@field Creatures WaxCreatures
---@field Highlight WaxHighlight
---@field Data WaxData The game's data tables as plain Lua values.
---@field Crafting WaxCrafting The bench or crafting screen that is open.
---@field Research WaxResearch The tech tree: what a recipe still needs researched, and researching it.
---@field Workshop WaxWorkshop The store on the station: its categories, nodes and prices, and where the player stands with them.
---@field MapChanged WaxSignal<fun(name: string)> Fires with the new map's name when the world changes.
---@field Frame WaxFrameSignal Fires once every frame with the seconds since the frame before. For work that has to run every frame.
---@field Me WaxMe The local player's character, whichever one that is: its fields and functions, and signals for its health, food, level and the like. It is there with no character too, and says so.
---@field Items WaxItems The kinds of item the game has, and the facts of each: its shown name, weight, stack size, durability and picture.
---@field Recipes WaxRecipes The game's crafting recipes: finding them, and changing what they take, what they give, how long they take and where they are made.
---@field Assets WaxAssets The game's assets by path, pictures from a mod's own files, materials made from the game's, and shapes made of numbers, each kept in memory for the mod that asked.
---@field Blueprints WaxBlueprints Things described in Lua and spawned by the host: an actor of a class the game has, with parts, assets and functions of your own. The game does not save them.
---@field Time WaxTime The time of day in the prospect: the hour, the clock as text, the part of the day, and a signal for a new hour.
---@field Weather WaxWeather The weather on your character, and for the host every weather event that is running on the map.
---@field Prospect WaxProspect The prospect you are in: which one it is, its mission, and how long it has run.
game = {}

---The Instance for a UE4SS object, or nil for a null or invalid one. The same object always gives the same Instance.
---@param object any
---@return WaxInstance?
function game.wrap(object) end

---The first live object of a class ("PlayerController", "BP_IcarusPlayerCharacterSurvival_C"), or nil.
---The editor then knows the members of that class.
---@generic T : WaxInstance
---@param class_name `T`
---@return T?
function game:Find(class_name) end

---Every live object of a class. It searches all objects, so never call it per frame.
---@generic T : WaxInstance
---@param class_name `T`
---@return T[]
function game:FindAll(class_name) end

---One of the game's function libraries ("KismetSystemLibrary", "GameplayStatics", "KismetMathLibrary").
---A library has no objects in the world. Its functions are called on what this returns:
---`game:Library("KismetMathLibrary"):RandomFloat()`. A wrong name raises an error that suggests the right one.
---@generic T : WaxInstance
---@param name `T`
---@return T
function game:Library(name) end

---Every live Instance carrying the tag.
---@param tag string
---@return WaxInstance[]
function game:GetTagged(tag) end

---One recipe a bench or the crafting screen lists.
---@class WaxListedRecipe
---@field row string The recipe's row name in D_ProcessorRecipes.
---@field valid boolean The game's own answer to "can this be made right now".

---The bench or crafting screen that is open: the recipes it lists, and choosing one of them.
---@class WaxCrafting
local Crafting = {}

---The recipes the open screen lists, in the game's order. Nothing when no bench and no crafting tab is open.
---@return WaxListedRecipe[]? recipes
---@return integer? screen A number that stays the same while that screen stays open.
---@return "bench"|"crafting"|"menu"? kind "menu" is another tab of the game's menu: the list is then what can be made by hand.
function Crafting:GetRecipes() end

---The number of the screen that is open, without reading its recipes. Nothing when none is.
---@return integer? screen
---@return "bench"|"crafting"|"menu"? kind
function Crafting:GetScreen() end

---What the mouse is over in the game's own screens, whichever of them is open: "item" and its row name in
---D_ItemsStatic for a slot that holds an item, "recipe" and its row name in D_ProcessorRecipes for a recipe tile,
---"talent" and its row name in D_Talents for a node of the tech tree or of the talents. Nothing over anything else,
---over an empty slot, or while the game does not show the mouse. It asks its way down the widgets under the mouse,
---which took about a millisecond when it was measured, so ask when a key is pressed and not every frame. A list the
---game builds as a list view is not looked into.
---@return "item"|"recipe"|"talent"? kind
---@return string? row
function Crafting:GetHovered() end

---True while one of the game's own text boxes has the keyboard, such as the search box of the crafting screen or of
---the tech tree. It asks its way down the widgets the keyboard is in, so ask when a key is pressed and not every frame.
---@return boolean
function Crafting:IsTyping() end

---Goes from another tab of the game's menu to its crafting tab, the way the game's own key for crafting does. True
---when the crafting tab was asked for or is showing already, false on any other screen.
---@return boolean
function Crafting:OpenTab() end

---Chooses a recipe on the open screen, as a click on its tile does. False when the screen does not list it.
---@param row string
---@return boolean
function Crafting:Select(row) end

---Hides the game's own recipe list on the open screen, or shows it again. Hidden, it keeps its place and takes no clicks.
---A screen opened later has its list again. It is shown again when the mod reloads.
---@param on boolean
---@return boolean
function Crafting:SetListHidden(on) end

---Asks the crafting tab to show what the recipe table holds now. However often it is asked in a frame, one refresh is made
---when the frame ends, and only when the crafting tab is the screen that shows. On another tab of the menu the game builds the
---list itself when the crafting tab is opened, and a bench that is open is left as it is in this version. Without options the
---tab's list is built again and the recipe that was chosen is chosen again, which took 33 to 41 ms for 25 recipes when it was measured.
---game.Recipes asks for this itself whenever a recipe was written, so a mod that changes recipes through it has nothing to do.
---@param options? WaxCraftingRefreshOptions
function Crafting:Refresh(options) end

---One node of the tech tree that still has to be researched.
---@class WaxResearchStep
---@field node string The node's row name in D_Talents, in lower case.
---@field name string The name the game shows for it.
---@field level integer The level it asks of the player.

---What researching the node of one recipe takes.
---@class WaxResearchPlan
---@field node string The node's row name in D_Talents, in lower case.
---@field name string The name the game shows for it.
---@field unlocked boolean True when it is researched already.
---@field default boolean True for a node every character has from the start.
---@field level integer The level this node asks of the player.
---@field steps WaxResearchStep[] Every node that still has to be researched, in the order to do it, the node itself last.
---@field points integer How many points that takes: one for each step.
---@field available integer The points the player has left.
---@field player_level integer The player's level.
---@field needed_level integer The highest level any of the steps asks.
---@field can boolean True when level and points are enough and the game says the first step can be researched now.
---@field blocked boolean True when level and points are enough and it still cannot be done: a step needs a mission finished or a DLC owned.

---The tech tree: what a recipe still needs researched, and researching it with the player's points.
---@class WaxResearch
---@field Changed WaxSignal<fun(level: integer?, points: integer?)> Fires when the player's level or points changed. It is looked at about twice a second.
local Research = {}

---True while the player has a tech tree to ask, which is in a prospect.
---@return boolean
function Research:IsReady() end

---The player's level as the tech tree counts it. Nothing while there is no tech tree.
---@return integer? level
function Research:GetLevel() end

---The player's tech tree points. Nothing while there is no tech tree.
---@return integer? available The points left to spend.
---@return integer? total
---@return integer? spent
function Research:GetPoints() end

---What researching the node of a recipe takes. Nothing when the recipe needs no node, when the game has no such
---recipe, and while there is no tech tree. Letter case does not matter. The game is asked about each node, so call
---it when something is shown or pressed, not every frame.
---@param recipe string A row name of D_ProcessorRecipes.
---@return WaxResearchPlan?
function Research:GetPlan(recipe) end

---Researches the node of a recipe, and first every node it still needs, with the player's own points. It does
---nothing unless the plan says `can`, and it stops at the first node the game does not research. It waits a few
---frames after each node, so call it inside a task.
---@param recipe string A row name of D_ProcessorRecipes.
---@return boolean ok True when the recipe's node is researched now.
---@return integer bought How many nodes were researched by this call.
---@return string? failed The name of the node the game did not research.
function Research:Unlock(recipe) end

---The top of the tree: World, GameInstance, GameState, GameMode, LocalPlayer, Engine and Viewport, where they exist.
---@return WaxInstance[]
function game:GetChildren() end

---The member of game with this name, the same as game[name].
---@param name WaxGameMember
---@return any
function game:GetService(name) end
