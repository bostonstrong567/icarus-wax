---@meta _

---A material for a part that the blueprint makes for itself from one of the game's. It is made once, shared by every
---thing of the blueprint, kept for your mod, and made again after a map change.
---@class WaxPartMaterial
---@field from MaterialInterface|string The material to start from: its path, or one from game.Assets:Load. Give the path when the blueprint should still spawn after a map change.
---@field colors? table<string, WaxAssetColor> Colour parameters, as game.Assets:Material takes them.
---@field numbers? table<string, number> Number parameters.
---@field textures? table<string, Texture|string> Texture parameters: a texture, or the path of one.

---One part of a thing: a component of the game, with what it shows and where it sits. Give a class, a mesh, or both.
---@class WaxPartOptions
---@field name? string The part's name, for a part given in a list. A part given by name, as in parts = { Body = { ... } }, needs none.
---@field class? string|WaxInstance The component class: a name such as "StaticMeshComponent", "PointLightComponent" or "ProceduralMeshComponent", a path such as "/Script/Engine.SpotLightComponent", or what game.Assets:Load gave for a class. When omitted it follows from the mesh. A class that only stands for the ones built on it, such as PrimitiveComponent or MeshComponent, is refused. A StaticMeshComponent, a ProceduralMeshComponent and a PointLightComponent have been seen working in the game.
---@field mesh? string|StaticMesh|WaxMesh What the part shows: the path of a mesh of the game or one from game.Assets:Load, which goes on a StaticMeshComponent, or a shape from game.Assets:Mesh, which goes on a ProceduralMeshComponent.
---@field material? string|MaterialInterface|WaxPartMaterial The material of the part's first slot: a path, a material from game.Assets:Load or game.Assets:Material, or a table that says what to make. The other slots keep what the mesh has. A material from game.Assets:Material does not outlive the map, so a blueprint that should spawn after a map change gives the table.
---@field at? { X: number, Y: number, Z: number }|number[] Where the part sits, measured from the thing: { X = 0, Y = 0, Z = 100 } or { 0, 0, 100 }. 100 is one metre, whatever the scale of the root. Not for the root.
---@field rotation? { Pitch?: number, Yaw?: number, Roll?: number }|number[] How the part is turned against the thing, in degrees. Not for the root.
---@field scale? number|{ X: number, Y: number, Z: number } The part's size against the size its mesh has by itself: one number, or one for each direction. 1 when omitted, never 0. The scale of the root does not change the size of the other parts. With a root scaled differently in each direction, a part that is also turned comes out skewed.
---@field collision? "none"|"solid"|"touch" "none": things pass through the part. "solid": things stop at it, which is what a mesh part does when nothing is said. "touch": things pass through and the blueprint's touched function hears of them. A shape from game.Assets:Mesh only stops things when it was made with collision = true.
---@field set? table<string, any> Properties of the component, written before it is registered with the game. Each name is checked when the blueprint is defined, each value when it is written.
---@field root? boolean True for the part the others hang on. It stands where the thing is spawned. Needed when parts are given by name and more than one has a place. In a list the first part with a place is the root.

---What game.Blueprints:Define takes.
---@class WaxBlueprintOptions
---@field base? string|WaxInstance The class of actor a thing is: "Actor" when omitted, another class by name ("StaticMeshActor", "Pawn"), or a class from the game's content by its path, "/Game/Folder/BP_Thing.BP_Thing_C", which is loaded and kept for your mod. With such a class the thing is that actor: it has the class's own components and runs the class's own script, set reaches its properties before it begins play, its functions and properties are used on the thing, and the blueprint's parts hang on its root. Only "Actor" has been seen working in the game.
---@field parts? table<string, WaxPartOptions>|WaxPartOptions[] The parts, by name or as a list in which each has a name. At most 64.
---@field set? table<string, any> Properties of the actor, written before it begins play. Each name is checked when the blueprint is defined, each value when it is written.
---@field began? fun(thing: WaxThing) Runs once for each thing, when its actor has begun play and its parts are there. That is inside Spawn, or a frame later when the world itself had not begun.
---@field stepped? fun(thing: WaxThing, dt: number) Runs every frame for each thing, with the seconds since it last ran for that thing. All stepped and every functions together get 2 ms a frame: what is left waits a frame and is then told the longer time. The time is real time, so it also runs while the game is paused.
---@field every? { [1]: number, [2]: fun(thing: WaxThing, dt: number) } A function that runs at its own pace: the seconds between two runs, then the function, as in every = { 0.5, function(thing, dt) end }.
---@field touched? fun(thing: WaxThing, other: Actor) Runs when an actor starts to overlap the thing. Wax asks the game what overlaps each such thing once in 6 frames, and tells of every actor that did not overlap at the look before. Only a part with collision = "touch" overlaps anything.
---@field ended? fun(thing: WaxThing, reason: "Destroyed"|"MapChanged"|"Unloaded") Runs once, a frame after a thing has gone: "Destroyed" by Destroy or by the game, "MapChanged", or "Unloaded" with its part of the world. The actor is gone by then, so only Data, Blueprint and Alive can be read. It does not run when the blueprint is removed or your mod unloads.

---A kind of thing, as game.Blueprints:Define gives it. It is a description in Lua, not an asset of the game.
---@class WaxBlueprint
---@field Name string The name it was defined with.
---@field Base string The name of the class its things are actors of, such as "Actor".
local Blueprint = {}

---Puts one in the world and gives the thing. `position` is { X = 0, Y = 0, Z = 0 } or { 0, 0, 0 }, also what a call
---such as K2_GetActorLocation gives. `rotation` is a turn in degrees, { Pitch = 0, Yaw = 90, Roll = 0 } or { 0, 90, 0 },
---with what is left out being 0. `data` is a table of your own that the thing keeps as its Data.
---
---Only the host of a session can spawn: on a client it raises an error that says so, as it does while there is no
---world. A mistake while the thing is put together raises an error and leaves nothing standing. Whether the other
---players of a session see a thing has not been tried.
---
---The game's own part of making a thing with two mesh parts took about half a millisecond.
---@param position { X: number, Y: number, Z: number }|number[]
---@param rotation? { Pitch?: number, Yaw?: number, Roll?: number }|number[]
---@param data? table
---@return WaxThing
function Blueprint:Spawn(position, rotation, data) end

---The things of this blueprint that are in the world, oldest first.
---@return WaxThing[]
function Blueprint:GetThings() end

---How many things of this blueprint are in the world.
---@return integer
function Blueprint:Count() end

---Destroys every thing of the blueprint and forgets it. Their ended function does not run. Nothing can be spawned from
---it afterwards.
function Blueprint:Remove() end

---A thing in the world: an actor that a blueprint spawned. It has the names below, and beyond them everything its
---actor's Instance has: thing.Name, thing:IsA("Actor"), thing:K2_GetActorLocation(), the class's own properties and
---functions. None of the names below is a member of any actor class of the game, so a thing hides nothing of its actor.
---
---A thing is not an Instance itself: where a function wants one, give thing.Actor. Once the thing is gone, everything
---but Data, Blueprint, Alive, IsValid and Destroy raises an error that says why.
---@class WaxThing : Actor
---@field Blueprint WaxBlueprint The blueprint it was spawned from.
---@field Data table The table given to Spawn, or a new one: the thing's own memory, plain Lua. It can still be read when the thing is gone. Change what is in it. The table itself cannot be replaced.
---@field Actor Actor The Instance of its actor, for everything that takes an Instance.
---@field Alive boolean True until the thing is gone: destroyed by Destroy or by the game, or lost with its map. Reading it never raises an error, so it is the question to ask of a thing you kept. thing:IsValid() gives the same answer. When the base is a character, whether that is dead is thing.Actor.Alive.
---@field Position { X: number, Y: number, Z: number } Where it is. Assign { X = 0, Y = 0, Z = 0 } or { 0, 0, 0 } to move it there at once, through anything in the way. A thing with no part that has a place cannot be moved.
---@field Facing { Pitch: number, Yaw: number, Roll: number } How it is turned, in degrees. Assign a turn to set it. What is left out is 0.
local Thing = {}

---The Instance of one of its parts, by the name the blueprint or AddPart gave it. Letter case does not matter. A name
---it does not have raises an error that names the nearest one.
---@param name string
---@return ActorComponent
function Thing:Part(name) end

---Makes one more part on the thing and gives its Instance. The part hangs on the root and is described like a part of
---a blueprint, without root. On a thing that has no part with a place yet, the first one becomes the root and stands
---where the thing was spawned.
---@param name string
---@param part WaxPartOptions
---@return ActorComponent
function Thing:AddPart(name, part) end

---The box all its parts fit in: Center is its middle in the world, Size how far it reaches in each direction.
---@return { Center: { X: number, Y: number, Z: number }, Size: { X: number, Y: number, Z: number } }
function Thing:GetBounds() end

---Takes the thing out of the world with all its parts. True when it was there, false when it was gone already. Its
---ended function runs a frame later. In the game this took about 0.07 ms.
---@return boolean destroyed
function Thing:Destroy() end

---Things described in Lua and spawned: a blueprint says which class of actor a thing is, which parts it has, which
---assets they show and which functions run for it. No class or asset is made in the game: a blueprint is Lua, and a
---thing is an actor of a class the game already has, put together when it is spawned.
---
---Things are not saved by the game. They are gone after a map change, after leaving the prospect and after a restart,
---and nothing brings them back: spawn them again, for example on game.MapChanged. A blueprint stays through a map
---change. When your mod unloads or reloads, its things are destroyed and its blueprints forgotten.
---
---While no blueprint is defined this costs nothing. With things in the world and no functions given, a frame costs one
---question to the game at most. Beyond that only what you give costs: a stepped or every function for each of its
---things, and one question to the game in 6 frames for each thing with a touched function.
---@class WaxBlueprints
local Blueprints = {}

---Describes a kind of thing and gives its blueprint. Nothing is put in the world until blueprint:Spawn. The name is
---letters and digits, and is compared without letter case. Classes, meshes and materials are asked for from game.Assets
---here, so a wrong path or a misspelt option raises an error now, with the nearest right name, and not at the first
---spawn.
---
---Defining a name again replaces the blueprint: the things of the old one are destroyed. A name another mod holds
---raises an error.
---@param name string
---@param options WaxBlueprintOptions
---@return WaxBlueprint
function Blueprints:Define(name, options) end

---The blueprint of that name, whichever mod defined it, or nil.
---@param name string
---@return WaxBlueprint?
function Blueprints:Get(name) end

---Every thing in the world that was spawned from a blueprint, of every mod, oldest first.
---@return WaxThing[]
function Blueprints:GetThings() end
