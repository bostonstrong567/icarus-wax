---@meta

---What game.Effects:Particles takes besides the path.
---@class WaxParticleOptions
---@field on? any What it hangs on: a character, a creature, a thing of a blueprint or a part. game.Me when omitted.
---@field socket? string A bone or socket of what it hangs on, such as "bn_Prop_R_1" for the right hand of the player's arms.
---@field at? { X: number, Y: number, Z: number }|number[] Where it sits, measured from what it hangs on.
---@field turn? { Pitch?: number, Yaw?: number, Roll?: number } How it is turned, in degrees.
---@field seconds? number|false How long it stays. 3 when omitted. False keeps it until it is stopped.
---@field set? table<string, number|string|table> Parameters of the effect, by name: a number, a colour, or three numbers.

---A particle effect that was started.
---@class WaxParticles
local Particles = {}

---Sets a parameter of the effect: a number, a colour ("Red", "#rrggbb", { R = , G = , B = }) or three numbers.
---The names belong to the effect. A name it does not have changes nothing.
---@param name string
---@param value number|string|table
---@return WaxParticles
function Particles:Set(name, value) end

function Particles:Stop() end

---@return boolean
function Particles:IsAlive() end

---What game.Effects:Light takes.
---@class WaxLightOptions
---@field on? any What it hangs on. game.Me when omitted.
---@field socket? string A bone or socket of what it hangs on.
---@field at? { X: number, Y: number, Z: number }|number[] Where it sits, measured from what it hangs on.
---@field color? string|table "Red", "#rrggbb" or { R = , G = , B = }. Red when omitted.
---@field intensity? number How bright. 5000 when omitted.
---@field radius? number How far it reaches. 400 when omitted, which is four metres.
---@field seconds? number|false How long it stays. 3 when omitted. False keeps it until it is stopped.
---@field fade? number Seconds over which it dims at the end.

---A light that was made.
---@class WaxLight
local Light = {}

function Light:Stop() end

---@return boolean
function Light:IsAlive() end

---@param color string|table
function Light:SetColor(color) end

---@param intensity number
function Light:SetIntensity(intensity) end

---What game.Effects:Trail takes besides what it follows.
---@class WaxTrailOptions
---@field from? { X: number, Y: number, Z: number }|number[] One end of the edge that leaves the trail, measured from what it follows.
---@field to? { X: number, Y: number, Z: number }|number[] The other end. { 0, 0, 50 } when omitted.
---@field color? string|table Red when omitted.
---@field seconds? number How long the ribbon is, in time. 0.25 when omitted.
---@field life? number How long it runs. Until it is stopped when omitted.
---@field width? number Makes it a streak this wide along the middle of the edge, always turned to face the view. Without it the ribbon lies between the edge's two ends, and a cut that comes straight at the view shows it from the side, as a line.
---@field with_view? boolean True keeps the trail with the view, as the arms of first person are, instead of leaving it behind in the world. For something held in first person.
---@field delay? number It starts this many seconds from now. A swing winds up first, and a trail that only runs during the cut is one clean arc. `life` counts from when it starts.
---@field embers? number|{ rate?: number, size?: number, life?: number, speed?: number, rise?: number } Small glowing bits that come off the edge while it moves: how many a second, or a table. They drift, rise and shrink to nothing. None when omitted.
---@field material? WaxInstance A material of your own in place of the plain glowing one, from game.Assets:Material. A thing held in first person is drawn bent toward the screen by its material, and a trail only lies on it when its material bends the same way.

---A trail that is running.
---@class WaxTrail
local Trail = {}

---Stops it growing. What is left of the ribbon runs out and is taken away.
function Trail:Stop() end

---@return boolean
function Trail:IsAlive() end

---game.Effects: the game's particle effects, lights, glowing trails and camera shakes, on anything.
---Everything a mod started is taken away when the mod unloads. Nothing costs anything while no effect is alive.
---@class WaxEffects
local Effects = {}

---Starts one of the game's particle effects on something.
---@param path string The path of a particle effect of the game. game.Effects:Find looks for one.
---@param options? WaxParticleOptions
---@return WaxParticles
function Effects:Particles(path, options) end

---Makes a point light on something.
---@param options? WaxLightOptions
---@return WaxLight
function Effects:Light(options) end

---Leaves a glowing ribbon behind an edge of something that moves, such as a blade.
---@param on any A thing of a blueprint, a part, a character or a creature.
---@param options? WaxTrailOptions
---@return WaxTrail
function Effects:Trail(on, options) end

---Shakes the player's view with one of the game's camera shakes.
---@param scale? number How strong. 1 when omitted.
---@param path? string The path of a camera shake of the game. A footstep of a mammoth when omitted.
---@return boolean shaken
function Effects:Shake(scale, path) end

---The paths of the game's particle effects whose path holds every word given. At most 200, then how many there were.
---@param text string
---@return string[] paths
---@return integer total
function Effects:Find(text) end

---The paths of the game's camera shakes whose path holds every word given.
---@param text? string
---@return string[] paths
---@return integer total
function Effects:FindShakes(text) end

---What game.Sounds:Play takes besides the path.
---@class WaxSoundOptions
---@field on? any What the sound comes from. When omitted it is heard everywhere at the same loudness.
---@field socket? string A bone or socket of what it comes from.
---@field at? { X: number, Y: number, Z: number }|number[] Where it comes from, measured from that.

---game.Sounds: the game's own sounds.
---@class WaxSounds
local Sounds = {}

---Plays one of the game's sounds.
---@param path string The path of a sound of the game. game.Sounds:Find looks for one.
---@param options? WaxSoundOptions
---@return boolean played
function Sounds:Play(path, options) end

---The paths of the game's sounds whose path holds every word given. At most 200, then how many there were.
---@param text string Words such as "whoosh bear".
---@return string[] paths
---@return integer total
function Sounds:Find(text) end
