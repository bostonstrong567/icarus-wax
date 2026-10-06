---@meta _

---An engine object. Any member not listed here is one of the object's own reflected properties or functions.
---@class WaxInstance
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

---Every property and function name this object has, sorted.
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
---@param class_name string
---@return WaxInstance?
function Instance:FindFirstChildOfClass(class_name) end

---The first child of this class or a class derived from it, or nil.
---@param class_name string
---@return WaxInstance?
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

---@class WaxPlayers
---@field LocalPlayer WaxInstance The local player's controller, the same as game.LocalPlayer.
---@field CharacterAdded WaxSignal<fun(character: WaxInstance)> Fires when a player's character appears.
---@field CharacterRemoved WaxSignal<fun(character: WaxInstance)> Fires when a player's character leaves the world.
local Players = {}

---One Instance per player in the session (their player state). Works for the host and for clients.
---@return WaxInstance[]
function Players:GetPlayers() end

---The characters those players are controlling right now.
---@return WaxInstance[]
function Players:GetCharacters() end

---Calls fn(character) for each player's character that is here now and each that appears later (a join, a respawn).
---If fn returns a function, that runs when the character is gone or the watch is stopped.
---@param fn fun(character: WaxInstance): (fun()?)
---@return WaxConnection
function Players:ObserveCharacters(fn) end

---The name of the player who controls a character, or nil while the game has not said yet.
---@param character WaxInstance
---@return string?
function Players:GetName(character) end

---True for the character this player controls.
---@param character WaxInstance
---@return boolean
function Players:IsLocal(character) end

---@class WaxCreatureQuery
---@field within? number Only creatures this many metres away or nearer. The result is then sorted nearest first.
---@field from? WaxInstance|{ X: number, Y: number, Z: number } Where to measure from. Your character when omitted.
---@field dead? boolean True also returns bodies that have not been cleared away yet.
---@field sort? "nearest" Sorts nearest first without a distance limit.

---@class WaxCreatureKind
---@field Name string The kind's name in the game's data, such as "Wolf".
---@field DisplayName string The name the game shows players.
---@field Tag string The game's own tag for the kind, such as "NPC.Wolf".
---@field Variants string[] The versions of the kind, such as "Conifer_Wolf" and "Snow_Wolf".
---@field Count integer How many are in the world now.

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

---@class WaxCreatureEnd
---@field Kind string
---@field Variant string
---@field ClassName string
---@field Name string
---@field Reason "Destroyed"|"Unloaded"
---@field Position? { X: number, Y: number, Z: number }

---The animals and enemies in the world, kept as a live list. A kind is named the way the game names it: "Wolf",
---"Conifer_Wolf", "Cave Worm". Letter case, spaces and underscores do not matter. A wrong name raises an error that suggests the right one.
---@class WaxCreatures
---@field Added WaxSignal<fun(creature: WaxInstance)> Fires for each creature that appears from now on.
---@field Removed WaxSignal<fun(creature: WaxInstance, info: WaxCreatureEnd)> Fires when a creature leaves the world. The Instance can no longer be used, only compared.
---@field Died WaxSignal<fun(creature: WaxInstance, info: WaxCreatureEnd)> Fires when a creature is killed, a few seconds before it is removed.
---@field Cleared WaxSignal<fun()> Fires once when the map changes, in place of one Removed per creature.
local Creatures = {}

---Every creature, or those of one kind. Dead ones are left out unless asked for.
---@param kind? string
---@param options? WaxCreatureQuery
---@return WaxInstance[]
---@overload fun(self: WaxCreatures, options: WaxCreatureQuery): WaxInstance[]
function Creatures:GetAll(kind, options) end

---The closest matching creature and its distance in metres, or nil.
---@param kind? string
---@param options? WaxCreatureQuery
---@return WaxInstance?, number?
---@overload fun(self: WaxCreatures, options: WaxCreatureQuery): WaxInstance?, number?
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
---@param creature WaxInstance
---@return string?, string?
function Creatures:GetKind(creature) end

---The common facts about one creature as plain values.
---@param creature WaxInstance
---@return WaxCreatureFacts
function Creatures:Describe(creature) end

---Calls fn(creature) for each matching creature that is here now and each that appears later.
---If fn returns a function, that runs when the creature is gone or the watch is stopped.
---@param kind? string
---@param fn fun(creature: WaxInstance): (fun()?)
---@return WaxConnection
---@overload fun(self: WaxCreatures, fn: fun(creature: WaxInstance): (fun()?)): WaxConnection
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

---@param options WaxHighlightOptions
function Look:Set(options) end

---One outlined actor.
---@class WaxHighlightMark
---@field Instance WaxInstance
---@field Active boolean False once it was removed or its actor is gone.
local Mark = {}

---Takes the outline off. Safe to call twice, and after the actor is gone.
function Mark:Remove() end

---@param options WaxHighlightOptions
function Mark:Set(options) end

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
---| "MapChanged"

---The root every mod starts from. It is read-only, and reading a member it does not have raises an error.
---@class WaxGame
---@field World WaxInstance The current world. Its children are the actors in it.
---@field GameInstance WaxInstance
---@field GameState WaxInstance
---@field GameMode WaxInstance? Nil when you are a client in someone else's game.
---@field LocalPlayer WaxInstance The local player's controller.
---@field Character WaxInstance? The pawn the local player controls. nil at the main menu.
---@field Engine WaxInstance
---@field Viewport WaxInstance The game viewport.
---@field MapName string? The name of the current world.
---@field InProspect boolean True while you are in a prospect.
---@field Players WaxPlayers
---@field Creatures WaxCreatures
---@field Highlight WaxHighlight
---@field MapChanged WaxSignal<fun(name: string)> Fires with the new map's name when the world changes.
game = {}

---The Instance for a UE4SS object, or nil for a null or invalid one. The same object always gives the same Instance.
---@param object any
---@return WaxInstance?
function game.wrap(object) end

---The first live object of a class ("PlayerController", "BP_IcarusPlayerCharacterSurvival_C"), or nil.
---@param class_name string
---@return WaxInstance?
function game:Find(class_name) end

---Every live object of a class. It searches all objects, so never call it per frame.
---@param class_name string
---@return WaxInstance[]
function game:FindAll(class_name) end

---Every live Instance carrying the tag.
---@param tag string
---@return WaxInstance[]
function game:GetTagged(tag) end

---The top of the tree: World, GameInstance, GameState, GameMode, LocalPlayer, Engine and Viewport, where they exist.
---@return WaxInstance[]
function game:GetChildren() end

---The member of game with this name, the same as game[name].
---@param name WaxGameMember
---@return any
function game:GetService(name) end
