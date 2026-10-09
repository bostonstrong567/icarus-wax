---@meta _

---One effect that is on a character, as GetModifiers gives it. The game calls these modifiers: what food, drink, weather,
---wounds and gear put on a character.
---@class WaxModifier
---@field Name string The modifier's row in the game's table D_ModifierStates, such as "Dirty_Water".
---@field DisplayName string The name the game shows for it, such as "Tainted Water". The row name when the table gives none.
---@field Kind "Buff"|"Debuff"|"Biome"|"Aura_Positive"|"Aura_Negative"|"Radiation"|"Item"? The type the game's table gives it. nil when the table gives none Wax knows.
---@field Id integer? The number the game gave this one when it was put on. One put on later has a higher number.
---@field Duration number? How long it lasts in all, in seconds, as the game has it set. nil for one that lasts as long as its cause does, such as exposure to a storm.
---@field Remaining number? How long it still lasts, in seconds. nil when Duration is.

---What Wax adds to every character about its stats and its modifiers: every Instance whose class is IcarusCharacter or
---is built on it, a player's and a creature's. game.Me has the same for your own character.
---
---GetStat and the two regen fields ask the game for the one stat each time, so they answer for every stat the game
---has and are never out of date. Stats is the list the game keeps on the character for every player to see: the game
---puts some of its stats in that list and keeps the others out of it, and a character's list holds only those it has
---a value for. That list is read at most five times a second.
---@class WaxCharacterStats
---@field Stats table<string, integer>? Every stat in the character's list, as name -> value: `character.Stats["MovementSpeed_+"]`. A new table each time. Putting names to the list costs more than one stat does, so do not read it every frame. The first read on a map also reads the names of all the game's stats, once. A stat the game keeps out of the list is not in it: ask GetStat for that one. nil when the character has no stats.
---@field HealthRegen integer? The value of the game's stat HealthRegenPerMinute_+, read as GetStat reads it.
---@field StaminaRegen integer? The value of the game's stat StaminaRegenPerMinute_+, read as GetStat reads it.
local Stats = {}

---The value of one stat, by its name in the game's table D_Stats: "MovementSpeed_+", "MaximumHealth_+", "WeightCapacity_+".
---Letter case does not matter. A name the game does not have raises an error that suggests the nearest ones.
---The game itself is asked, so this answers for every stat, also one the game keeps out of the character's list such
---as BaseMaximumHealth_+. The answer is 0 for a stat the character has no value for, and nil for a character with no stats.
---@param name string
---@return integer?
function Stats:GetStat(name) end

---The modifiers that are on the character now, the one put on first at the front. An empty list when there are none.
---The tables are new each time. The character is asked once a frame, however often this is called in it.
---@return WaxModifier[]
function Stats:GetModifiers() end

---True when a modifier with this row name of D_ModifierStates is on the character now, such as "Berry".
---Letter case does not matter. A name the game does not have raises an error that suggests the nearest ones.
---@param name string
---@return boolean
function Stats:HasModifier(name) end

---Puts a modifier on the character. The
---modifier is named by its row of D_ModifierStates, such as "Health_Regen", in any letter case, and a name the game does
---not have raises an error that suggests the nearest ones. How long it stays has to be given: the game's table keeps no
---time of its own for a modifier. It is on at once, and GetModifiers and HasModifier say so in the same frame.
---It has been tried on a player's character. The game's table marks some modifiers as not for creatures.
---@param name string
---@param seconds number|{ seconds: number } How long it stays, above 0: a number, or a table such as { seconds = 60 }.
---@return integer? id The number the game gave it, which GetModifiers lists as Id. nil when the game did not put it on.
function Stats:AddModifier(name, seconds) end

---Takes modifiers off the character at once. With a name, every modifier of that row. With a record
---that GetModifiers gave, the one with that Id.
---@param modifier string|WaxModifier
---@return integer count How many were taken off. 0 when none of that name was on.
function Stats:RemoveModifier(modifier) end
