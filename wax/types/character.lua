---@meta _

---What Wax adds to every character, a player's and a creature's: every Instance whose class is IcarusCharacter or is
---built on it. Each field asks the game when it is read. A field is nil when the character has no such value.
---
---Health and Stamina can be assigned, and Heal, Kill and Teleport called. They are the game's own calls.
---No other field can be assigned.
---@class WaxCharacter : WaxCharacterStats
---@field Health integer? Its health now. It can be assigned: the number is rounded, and no more than MaxHealth is set. Below 1 raises an error, because Kill is what kills, and so does assigning it on a character that is dead.
---@field MaxHealth integer? The most health it can have.
---@field Armor integer? Its armour now.
---@field MaxArmor integer? The most armour it can have.
---@field Alive boolean? False once it is dead.
---@field Stamina integer? Its stamina now. It can be assigned: the number is rounded and brought between 0 and MaxStamina.
---@field MaxStamina integer? The most stamina it can have.
---@field Level integer? Its level.
---@field XP integer? All the experience it has earned.
---@field Biome string? The biome it stands in, as a row name of D_Biomes such as "Conifer". nil while the game names none.
---@field Temperature number? The temperature around it, in degrees Celsius.
---@field Position { X: number, Y: number, Z: number } Where it is, in the engine's units: 100 is one metre. Assign a place to move it there at once: { X = 0, Y = 0, Z = 0 }, { 0, 0, 0 }, an actor or game.Me. When the game finds no room there it raises an error that says so.
---@field Rotation { Pitch: number, Yaw: number, Roll: number } Which way its body is turned, in degrees. Assign { Yaw = 90 } or { 0, 90, 0 } to turn it. What is left out stays as it is.
---@field Velocity { X: number, Y: number, Z: number }? How fast it moves along each axis, in the engine's units a second.
---@field MoveSpeed number? Its top walking speed as the game has it set right now, in the engine's units a second.
---@field Crouching boolean? True while it crouches.
---@field Swimming boolean? True while it swims.
---@field Damaged WaxSignal<fun(who: WaxCharacter, amount: integer, info: WaxDamageInfo)> Fires when the game says this character took damage: the character, the damage of the hit, and what the game knows of it. The game tells it itself, so nothing is looked at meanwhile, and the handler runs in the same frame or the next one. Health that goes down with no hit, as when a mod assigns Health, is not damage. Seen on the host of a session. On another player's machine it has not been tried.
---@field Died WaxSignal<fun(who: WaxCharacter, info: WaxDeathInfo)> Fires once when this character is dead. After a hit that left it no health that is the frame of the hit or a moment later, and info says what did it. A death with no hit is seen by looking four times a second while a handler is connected, and info is empty then. A character that lives again and dies again is told again. When the character leaves the world, the handlers of its Damaged and Died are disconnected.
local Character = {}

---What the game knows of one hit, as Damaged hands it over. The handlers of one signal share one table.
---@class WaxDamageInfo
---@field Health integer? The character's health after the hit.
---@field Applied integer? What the game took off its health: AppliedDamage of the game's last damage packet.
---@field Total integer? TotalDamage of that packet. It was the same number as Applied whenever it was read.
---@field Radial boolean True when the game marks the hit as damage over an area.
---@field Stealth boolean True when the game marks the hit as a stealth hit.
---@field Causer WaxInstance? The actor the game names as what did it. For hunger and for a fall that is the character itself.
---@field Instigator WaxInstance? The controller the game names as who did it. For hunger and for a fall there is none.

---What is known of a death, as Died hands it over. It is empty when the character died with no hit that Wax heard.
---@class WaxDeathInfo
---@field Killer WaxInstance? The Causer of the hit that left the character no health.
---@field Instigator WaxInstance? The Instigator of that hit.
---@field Damage integer? The damage of that hit.

---How far it is to an actor, to game.Me or to a position, in metres.
---@param target WaxInstance|WaxMe|{ X: number, Y: number, Z: number }
---@return number metres
function Character:DistanceTo(target) end

---Gives health back. With an amount, that much and never past MaxHealth. Without one, all of it.
---A character that is dead is not brought back: that raises an error.
---@param amount? number How much to give back, above 0. It is rounded to a whole number.
---@return integer? health Its health afterwards.
function Character:Heal(amount) end

---Kills the character at once. A creature killed this way became a corpse one to three seconds
---later when it was timed. A player's character is refused in this version of Wax: the game's call has only been made on creatures.
---@return boolean killed True when it was alive and is dead now. False when it was dead already.
function Character:Kill() end

---Moves the character at once with the engine's own teleport. Nothing holds it up afterwards: put
---above the ground it falls. It answers false when the game did not move it.
---@param place WaxInstance|WaxMe|{ X: number, Y: number, Z: number } A position in the engine's units, or an actor or game.Me to go to.
---@param facing? { Pitch?: number, Yaw?: number, Roll?: number } Which way its body is turned afterwards, in degrees. As it was when omitted.
---@return boolean moved
function Character:Teleport(place, facing) end

---What Wax adds to a player's character, on top of what every character has: every Instance whose class is
---IcarusPlayerCharacter or is built on it. Food, Water and Oxygen can be assigned as well.
---@class WaxPlayerCharacter : WaxCharacter, WaxPlayerItems
---@field Food integer? How much food it has left. It can be assigned: the number is rounded and brought between 0 and MaxFood.
---@field MaxFood integer? The most food it can have.
---@field Water integer? How much water it has left. It can be assigned: the number is rounded and brought between 0 and MaxWater.
---@field MaxWater integer? The most water it can have.
---@field Oxygen integer? How much oxygen it has left. It can be assigned: the number is rounded and brought between 0 and MaxOxygen.
---@field MaxOxygen integer? The most oxygen it can have.
---@field Radiation integer? Its radiation level.
---@field MaxRadiation integer? The highest its radiation level goes.
---@field BodyTemperature number? The temperature of its body, in degrees Celsius.
---@field Weight number? What it carries in all its inventories, in kilograms. The game works it out a moment after the items change, not in the same frame.
---@field MaxWeight integer? The weight it can carry, in kilograms: the game's stat WeightCapacity_+.
---@field PlayerName string? The name of the player who controls it. nil while the game has not said.
---@field CharacterName string? The name the player gave this character, such as the one on the character screen. nil while the game has not said.
---@field Local boolean True for the character this player controls.
---@field InCave boolean? True while the game counts it as inside a cave.

---The local player's character, whichever one that is. game.Me is not an Instance: it finds the character each time it is
---used, so it goes on working after a respawn and on another map. It has every field and function of the character,
---and Character, Exists and the signals listed here. While there is no character, as at the title screen, Exists is
---false, a field reads nil, and calling a function or assigning a field raises an error that says so.
---
---A signal is fed by looking at the character a few times a second, and only while a handler is connected to it. What
---changes and changes back between two looks is not seen. A signal that hands over a value and the one before does not
---fire while there is no character, and for it another character whose value is not the last one seen counts as a change.
---
---Damaged and the three item signals are not fed by looking: the game tells Wax itself, through a hook on the game's
---own function that is made when the first handler connects. A handler never runs inside the game's call: what was
---heard is told from the frame loop, in the same frame or the next. All of it was seen on the host of a session. As a
---guest in someone else's game it has not been tried.
---Equipped is looked at four times a second. Activated fires inside stack:Activate, in that call.
---@class WaxMe : BP_IcarusPlayerCharacterSurvival_C, WaxPlayerCharacter
---@field Character IcarusPlayerCharacter? The character itself, as an Instance. nil while there is none.
---@field Exists boolean True while the local player has a character.
---@field HealthChanged WaxSignal<fun(health: integer, previous: integer)> Fires when health is not what it was at the last look. Looked at ten times a second.
---@field StaminaChanged WaxSignal<fun(stamina: integer, previous: integer)> Fires when stamina is not what it was at the last look. Looked at ten times a second.
---@field FoodChanged WaxSignal<fun(food: integer, previous: integer)> Fires when food is not what it was at the last look. The game says when it changed it, and that is looked at in the same frame or the next. Besides that it is looked at every two seconds, or twice a second where the game's word cannot be listened to.
---@field WaterChanged WaxSignal<fun(water: integer, previous: integer)> Fires when water is not what it was at the last look. Told and looked at as FoodChanged is.
---@field OxygenChanged WaxSignal<fun(oxygen: integer, previous: integer)> Fires when oxygen is not what it was at the last look. Told and looked at as FoodChanged is.
---@field WeightChanged WaxSignal<fun(weight: number, previous: number)> Fires when the weight carried, in kilograms, is not what it was at the last look. The game says when it worked a new weight out, a moment after the items changed, and that is looked at in the same frame or the next. Besides that it is looked at every two seconds, or twice a second where the game's word cannot be listened to.
---@field Damaged WaxSignal<fun(who: IcarusPlayerCharacter, amount: integer, info: WaxDamageInfo)> Fires when the game says your character took damage, as Damaged of a character does. It stays connected through a respawn and a map change. With damage told, HealthChanged follows in the same frame instead of at its next look.
---@field Died WaxSignal<fun(who: IcarusPlayerCharacter, info: WaxDeathInfo)> Fires once when your character is dead: in the frame of the hit that ended it, with what did it, or at the look that tells of a respawn (four times a second) when no hit came with the death.
---@field ModifierAdded WaxSignal<fun(modifier: WaxModifier)> Fires for a modifier that is on your character and was not at the last look. Looked at twice a second. The record has no Remaining: ask GetModifiers for what counts down. The modifiers a character has when it becomes yours are where it starts from, not something added.
---@field ModifierRemoved WaxSignal<fun(modifier: WaxModifier)> Fires for a modifier that was on your character at the last look and is not any more, with the record as it was. Looked at twice a second.
---@field ItemAdded WaxSignal<fun(item: string, amount: integer, stack: WaxItemStack?)> Fires when your character carries more of an item than a frame before, over all its inventories: the item's name as the game spells it, how many more, and a stack it went onto, with its Inventory. The game tells of every slot it changes. What moves from one slot or inventory to another within a frame is not added and not removed.
---@field ItemRemoved WaxSignal<fun(item: string, amount: integer, stack: WaxItemStack?)> Fires when your character carries fewer of an item than a frame before: the item, how many fewer, and a stack it came out of as that was before.
---@field ItemChanged WaxSignal<fun(stack: WaxItemStack?, previous: WaxItemStack?)> Fires for every slot of what your character carries that holds something else than a frame before: what it holds now, nil for nothing, and what it held, each with its Inventory. A tool that wore and a stack that moved are changes too. A spoil timer that only counts down is not.
---@field Equipped WaxSignal<fun(stack: WaxItemStack?, previous: string?)> Fires when the hotbar slot in hand, or the item in it, is not what it was at the last look. Looked at four times a second. Your function gets the stack in hand now, or nil when that slot is empty, and the name of the item that was in hand. Bare hands are the item Player_Fist. What was already in hand when you connect is where it starts. A change of durability alone does not fire it.
---@field Activated WaxSignal<fun(stack: WaxItemStack, use: string?)> Fires inside stack:Activate, with the stack and the use name. The use name is nil when Activate was called with no name.
---@field BiomeChanged WaxSignal<fun(biome: string, previous: string)> Fires when the character stands in another biome than at the last look. Looked at once a second.
---@field LevelUp WaxSignal<fun(level: integer, previous: integer)> Fires when the character's level went up. Looked at twice a second. Another character with a higher level is not a level up.
---@field XPGained WaxSignal<fun(amount: integer, total: integer)> Fires when the character earned experience: how much since the last look, and all it has now. Looked at twice a second.
---@field Respawned WaxSignal<fun(character: IcarusPlayerCharacter)> Fires when the character is alive after it was dead. Looked at four times a second.
---@field Spawned WaxSignal<fun(character: IcarusPlayerCharacter)> Fires when there is a character where there was none, or another one than before. It does not fire for the character that is there when you connect.
---@field Despawned WaxSignal<fun()> Fires when the character that was there is gone. When another one takes its place at once, Despawned fires first and Spawned after it.
