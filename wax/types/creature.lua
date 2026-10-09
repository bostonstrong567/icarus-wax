---@meta _

---What Wax adds to a creature: every Instance whose class is IcarusNPCCharacter or IcarusPawn, or is built on one of them.
---Each field asks the game when it is read. A field is nil when the creature has no such value.
---Epic, Behaviour, Action, Target, Stance and IsFrozen are read from an IcarusNPCCharacter only. On the few creatures that are an
---IcarusPawn they are nil.
---
---Behaviour can be assigned, and SetLevel, Freeze, Unfreeze, Attack and Remove called. They are the game's own calls.
---In this version of Wax they are for wild animals that are an IcarusNPCCharacter. On a tamed animal and on an IcarusPawn
---each raises an error that says so, because the game's calls were only made on wild ones. No other field can be assigned.
---
---A creature that is an IcarusNPCCharacter is a character as well, so it also has what every character has: Health, Level,
---Alive, Heal, Kill, Teleport, Damaged, Died and the rest.
---@class WaxCreatureMembers
---@field Kind string? Its kind as the game's data names it, such as "Wolf". "Unknown" when the game's data does not say what it is.
---@field Variant string? The version of its kind, such as "Conifer_Wolf": a row of the table D_AISetup. nil when the game names none.
---@field DisplayName string? The name the game shows players for its kind, such as "Cave Worm".
---@field Epic string? The row of D_EpicCreatures that makes it a named boss or alpha, such as "AlphaWolf_Boss". nil for an ordinary creature.
---@field Behaviour string? The team the game has it on now, which decides whom it treats as an enemy: "Friendly" for the team FriendlyAll, "Tame" for Player (the players' own team), "HostileToPlayers" for EnemyPlayerOnly, "HostileToAll" for EnemyAll. On any other team it is "Default" while that is the team its variant starts on, and else the team's own name, a row of D_AIRelationships such as "DefaultLargeCarnivore". nil when the game names no team. It can be assigned: one of the five words, where "Default" puts it back on the team its variant starts on, or a team's own name. A name that is neither raises an error that suggests the nearest. The game goes by the new team from the next time the animal notices somebody, not at once: a wolf that had a player in view attacked two seconds after "HostileToPlayers", a wolf that was walking away did nothing in five, and an animal that is attacking goes on attacking after "Friendly".
---@field Action string? What it is doing now, as the game's class for that action is called: "Wander", "FindFood", "EmergeFromRetreat". nil while the game names none for it.
---@field Target WaxInstance? The actor it is after right now, such as a player's character or another creature. nil while it is after nothing.
---@field Stance "Standing"|"Sitting"|"Lying"|nil How it holds itself.
---@field IsJuvenile boolean? True for a young animal: one that a taming rule of the game, a row of D_Tames, names as the young of its kind. nil when the game's tables cannot be read.
---@field IsTamed boolean True for an animal that has been tamed: a mount, a pet or livestock. The game makes these from classes built on IcarusMountCharacter, and that is what is looked at. A speeder bike counts as one, because the game builds it the same way.
---@field CanBeTamed boolean? True when a taming rule of the game names its variant, as the young animal or as the grown one, and it is not tamed already. It says what the game's data has, not whether a taming would work right now. nil when the game's tables cannot be read.
---@field IsFrozen boolean? True while the creature is held frozen, by Freeze or by the game itself. nil on a creature whose class has no such flag.
---@field HasModel boolean True while the creature wears a model that SetModel gave it.
local Creature = {}

---What creature:SetModel takes: the body the creature is to wear in place of its own.
---@class WaxCreatureModelSwap
---@field mesh SkeletalMesh|string The skeletal mesh to wear: one from game.Assets:Load or mod.Content:Load, or its path. It has to be built on the same skeleton as the creature's own mesh, or the creature's animations would stop.
---@field materials? table<integer, MaterialInterface|string> Materials by slot, 1 first: from game.Assets, mod.Content or game.Assets:Material, or their paths. A slot that is left out shows what the mesh itself names.
---@field fur? boolean False hides the creature's coat of fur or feathers, which the game grows on a body of its own and would draw over the new one. Left as it is when omitted.
---@field saddle? boolean False hides the saddle the game shows on a mount, for a model that has one of its own. The rider still sits on it. Left as it is when omitted.

---Gives the creature another body: a skeletal mesh of the game or of your mod's own content, with its materials. It
---goes on moving as before, because the new body is on the same skeleton: a mesh on another skeleton raises an error
---that names both. The game writes a mount's own skin again now and then, so Wax looks once a second and puts the
---model back. When your mod unloads, or on ResetModel, the creature has its own body again. It works for the host and
---for a client alike, and each player only sees it in their own game.
---@param model WaxCreatureModelSwap
---@return boolean worn Always true.
function Creature:SetModel(model) end

---Gives the creature the body it had before SetModel.
---@return boolean changed False when it wore no model.
function Creature:ResetModel() end

---Makes a mount attack, as the game does when its rider attacks: it plays the mount's own attack,
---takes the stamina that costs, and hits what stands in front of it at the strike. The game keeps this for mounts with
---the talent for it. Strike asks for no talent.
---@return boolean started False when the mount is in the middle of another move, or the game gives its kind no attack.
---@return string? why The reason, when it did not start.
function Creature:Strike() end

---Sets the creature's level through the game. Its experience, the most health it can have and its
---level stats follow in the same call, and its health is full afterwards. So set the level first and Health after it.
---@param level number From 1 to 120, the highest level the game's own zones give. It is rounded to a whole number.
---@return boolean changed True when the level changed. False when the creature had that level already.
function Creature:SetLevel(level) end

---Holds the creature where it stands. It stops in the same frame and decides nothing until Unfreeze.
---@return boolean frozen True when it moved freely and is frozen now. False when it was frozen already.
function Creature:Freeze() end

---Lets a frozen creature go again. A deer walked on within half a second.
---@return boolean freed True when it was frozen and is free now. False when it was not frozen.
function Creature:Unfreeze() end

---Makes the creature angry at a player's character: the game raises its aggression to the most and
---tells it where the target is. A wolf had the character as its Target within a second or two and ran at it.
---It is for the animals the game gives aggression, the hunters. For one that has none, such as a deer or a rabbit, it
---raises an error that says so, and so it does for a target that is not a player's character.
---Nothing in Wax calls an attack off again. Remove takes the animal away.
---@param target IcarusPlayerCharacter|WaxMe The player's character to go for, or game.Me.
---@return boolean angry True when its aggression is raised afterwards.
function Creature:Attack(target) end

---Takes the creature out of the world, alive or dead, with nothing left behind. The game does it a
---moment later, not in the same frame: IsValid() says when it is gone.
---The game replaces a dead creature by a corpse a few seconds after its death, one to three seconds when it was timed. The
---corpse is no creature: it is not in game.Creatures, and Remove raises an error on the creature it was, which is gone
---by then. A dead creature that was removed before that left no corpse.
---@return boolean asked Always true.
function Creature:Remove() end

---What game.Creatures:SpawnMount takes besides the kind and the place.
---@class WaxMountOptions
---@field name? string The mount's name, as the player sees it.
---@field saddle? string|false The saddle item it wears, such as "Saddle_Standard". The game only lets a mount with a saddle be ridden. "Saddle_Standard" when omitted, false for none.
---@field owner? boolean False leaves it with no owner, to be claimed in the game. Yours when omitted.
---@field facing? { Yaw: number } Which way it looks. Toward you when omitted.

---What game.Creatures:Spawn takes besides the kind and the place.
---@class WaxSpawnOptions
---@field level? number The creature's level, from 1 to 120. When omitted, the middle level the game's data gives creatures in the zone the place lies in, and 1 where the game names no zone.
---@field variant? string Which variant of the kind, such as "Snow_Wolf", when the first value names a kind that has several.
---@field facing? { Yaw: number } Which way it looks, in degrees. When omitted, a creature put in front of your character looks at it, and one put at a place you gave faces as the game makes it.
---@field behaviour? string The team to put it on once the game has finished making it: what a creature's Behaviour can be assigned.
---@field keep? boolean False takes the creature out of the world again when the mod that spawned it unloads. True when omitted: what a mod spawned stays.

---What game.Creatures:GetInfo gives: what the game's tables say about one variant of a kind. It holds plain values and is a new table each time.
---@class WaxCreatureInfo
---@field Kind string The kind's name, such as "Wolf".
---@field DisplayName string The name the game shows players for the kind.
---@field Tag string The game's own tag for the kind, such as "NPC.Wolf".
---@field Variants string[] Every variant of the kind.
---@field Variant string? The variant the fields below are about. nil for a kind without one, and then the fields below are nil too.
---@field Team string? The team it starts on: a row of D_AIRelationships such as "NeutralMediumCarnivore".
---@field Diet "Carnivore"|"Herbivore"|nil What the game's data calls it. nil when it says neither.
---@field Descriptors string[]? Every word the game's data describes it with, such as "Passive" and "Herbivore": rows of D_AIDescriptors.
---@field Carcass string? The item its dead body is: a row of D_ItemsStatic such as "AnimalCarcass_Deer".
---@field Loot string? What its body gives: a row of D_ItemRewards such as "Deer_Carcass_Loot".
---@field Tame WaxCreatureTameRule? The taming rule that names this variant. nil when none does.
---@field Mount WaxCreatureMountInfo? What the game's data says about the tamed animal: about this variant when it is a tamed one, else about the variant it becomes when tamed. nil when there is neither.

---A taming rule of the game: a row of the table D_Tames.
---@class WaxCreatureTameRule
---@field Rule string The row's name, such as "Moa".
---@field As "Young"|"Grown"|"Tamed" What the variant asked about is in this rule: the young animal, the grown one, or what they become. When several rules name a variant, the first in the table is given.
---@field Seconds integer How long a taming takes by the rule, in seconds.
---@field Nutrition integer How well fed the rule wants the animal, in percent.
---@field Shelter integer How much shelter the rule wants, in percent.
---@field Temperature { Min: number, Max: number }? The range of temperature the rule wants, as the game's table has it.
---@field Tamed string? The variant the animal becomes. nil when the rule names none, or one the game does not have.
---@field Young string? The variant of the young animal. nil when the rule names none, or one the game does not have.
---@field Grown string? The variant of the grown animal. nil when the rule names none, or one the game does not have.
---@field Required string[] The modifiers the rule lists as required: rows of D_ModifierStates.
---@field Prohibited string[] The modifiers the rule lists as prohibited, such as "Wet" and "Sleepy": rows of D_ModifierStates.

---What the game's data says about a tamed animal: a row of the table D_Mounts.
---@class WaxCreatureMountInfo
---@field Name string The row's name, such as "Buffalo".
---@field Variant string The tamed variant the row is about, such as "Mount_Buffalo".
---@field Orders ("Follow"|"Wander"|"Stay"|"Rest")[] The orders about moving that the game's data lists for it. "Wander" is the game's IdleWander, "Stay" its IdleStanding and "Rest" its IdleLying.
---@field Combat ("Passive"|"Defensive"|"Aggressive")[] The orders about fighting that the game's data lists for it. "Passive" is the game's DoNotEngage, "Defensive" its NeutralEngagement and "Aggressive" its AggressiveEngagement.
---@field Saddles WaxCreatureSaddle[]? The saddles the game's data fits to it, in the table's order. Empty when none fits. nil when the table of saddles cannot be read.
---@field Growth string? The row of D_CharacterGrowth that says how it gains levels.

---A saddle as it fits one tamed animal: a row of the table D_Saddles.
---@class WaxCreatureSaddle
---@field Name string The row's name, such as "Saddle_Buffalo_Cargo".
---@field Tag string? The tag an item carries to be this saddle, such as "Item.Mount.Saddle.Cargo".
