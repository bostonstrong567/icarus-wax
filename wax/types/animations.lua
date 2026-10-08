---@meta

---One moment of a track. The first entry is the time in seconds, the second what is added at that time, the third how
---the way there is eased: "linear", "smooth", "in", "out" or "snap".
---@class WaxAnimationKey
---@field [1] number The time, in seconds from the start.
---@field [2] WaxAnimationValues What is added to the bone or the thing at that time.
---@field [3]? "linear"|"smooth"|"in"|"out"|"snap" How the way from the key before is eased. The animation's own when omitted.

---What a key adds. Everything is an offset from where the bone or the thing is without the animation, so a key of {}
---means "as the game has it".
---@class WaxAnimationValues
---@field Pitch? number Degrees about the character's right: positive tips back, negative leans forward.
---@field Yaw? number Degrees about up: positive turns to the right.
---@field Roll? number Degrees about forward.
---@field X? number
---@field Y? number
---@field Z? number
---@field Scale? number 1 leaves the size as it is.

---What game.Animations:Define makes an animation from.
---@class WaxAnimationSpec
---@field tracks table<string, WaxAnimationKey[]> What moves, by name: a bone ("RightShoulder", or the name its skeleton gives it), or Self for the thing as a whole.
---@field third? table<string, WaxAnimationKey[]> Tracks for the player's body seen in third person, when they should differ from tracks.
---@field reach? table<string, WaxAnimationKey[]|WaxReach> Where the end of a limb goes: RightHand, LeftHand, RightFoot or LeftFoot. The two bones above it are bent to get it there.
---@field reach_from? "hand"|"shoulder" "hand" (when omitted): a reach key adds to where the limb's end is. "shoulder": a key says where it is, forward, right and up of the limb's root, and the reach comes in from the game's pose and goes back to it.
---@field reach_blend? number|number[] With reach_from = "shoulder": the seconds a reach takes to come in from the game's pose, and to go back. One number for both, or { in, out }. 0.15 when omitted.
---@field length? number How long it runs, in seconds. The time of the last key when omitted.
---@field loop? boolean True starts it again when it ends.
---@field ease? "linear"|"smooth"|"in"|"out"|"snap" How keys are eased when a key does not say. "smooth" when omitted.
---@field events? { [1]: number, [2]: fun(play: WaxAnimationPlay) }[] Functions that run when the animation passes a time.

---A reach that also turns the end of the limb.
---@class WaxReach
---@field keys WaxAnimationKey[] X, Y and Z say where the end goes. Pitch, Yaw and Roll say how it is turned.
---@field pin? boolean True holds the limb's end where the game has it, in place and in turn, whatever the bones above it do: a foot stays flat on the ground while the hips sink and turn. Keys are not needed then.
---@field bend? { X: number, Y: number, Z: number }|number[] Which way the elbow or the knee points: forward, right and up.
---@field bones? string[] The limb's own three bones, from its root to its end, for a skeleton that is not a person's.
---@field straight? boolean True moves the end in straight lines between keys. When omitted it moves on a curve through them.
---@field from? "hand"|"shoulder" What this limb's keys are measured from, when it differs from the animation's reach_from.
---@field turn? boolean True uses Pitch, Yaw and Roll: with reach_from = "shoulder" they are the turn of what the hand holds, as the character stands. Otherwise they are added.

---What animation:Play takes besides the target.
---@class WaxAnimationPlayOptions
---@field rate? number How fast it runs. 1 when omitted.
---@field loop? boolean Overrides the animation's own loop.
---@field weight? number How much of the movement is added. 1 when omitted.
---@field keep? boolean True leaves a thing where its Self track put it when the animation ends.
---@field done? fun(play: WaxAnimationPlay) Runs when the animation has run to its end. Not when it is stopped.
---@field view? "first"|"third" On the player's own character: the one view it shows in. Both when omitted.

---An animation that is playing.
---@class WaxAnimationPlay
---@field Animation WaxAnimation
local Play = {}

---Stops it now. A thing moved by a Self track goes back to where it was.
function Play:Stop() end

---@return boolean
function Play:IsPlaying() end

---@return number seconds
function Play:GetTime() end

---@param rate number More than 0.
function Play:SetRate(rate) end

---An animation written as keys, as game.Animations:Define gives it. It can play on any number of targets at once.
---@class WaxAnimation
---@field Name string
---@field Length number Seconds.
---@field Loop boolean
local Animation = {}

---Plays the animation. On a character or a creature its bone tracks move the bones, added to whatever the game is
---animating at that moment. On a thing of a blueprint or a part, its Self track moves the thing as a whole. On the
---player's own character it shows on the arms in first person and on the body in third. It costs nothing while
---nothing plays, and it stops when your mod unloads.
---@param target? any A character, a creature, a thing of a blueprint or a part. game.Me when omitted.
---@param options? WaxAnimationPlayOptions
---@return WaxAnimationPlay
function Animation:Play(target, options) end

---What game.Animations:Play takes besides the clip.
---@class WaxClipOptions
---@field rate? number How fast it plays. 1 when omitted.
---@field blend? number Seconds to blend in and out. 0.15 when omitted.
---@field start? number Where in the clip it starts, in seconds.
---@field slot? string The slot a single sequence plays in. "DefaultSlot" when omitted.
---@field loops? integer How often a single sequence plays. 1 when omitted.
---@field part? string|{ first?: string, third?: string } The part of a montage to play, by its name in the game, such as "Action_0".
---@field match? boolean With first and third given: false lets each clip run at its own length. When omitted the body's clip is paced to last as long as the arms'.

---One of the game's clips that was started.
---@class WaxClipPlay
local Clip = {}

---@param blend? number Seconds to blend out.
function Clip:Stop(blend) end

---@return boolean
function Clip:IsPlaying() end

---game.Animations: the game's own clips on anything with a skeleton, and animations written as keys in Lua.
---@class WaxAnimations
local Animations = {}

---Plays one of the game's own montages or sequences on a character or a creature. For the player's own character give
---{ first = path, third = path }: the arms and the body are two skeletons with clips of their own.
---@param target? any A character or a creature. game.Me when omitted.
---@param clip string|{ first?: string, third?: string } The path of a montage or a sequence of the game.
---@param options? WaxClipOptions
---@return WaxClipPlay
function Animations:Play(target, clip, options) end

---Makes an animation from keys. Nothing is asked of the game until it plays.
---@param name string
---@param spec WaxAnimationSpec
---@return WaxAnimation
function Animations:Define(name, spec) end

---The animation of that name, or nil.
---@param name string
---@return WaxAnimation?
function Animations:Get(name) end

---The names of the bones of a target's skeleton, for writing tracks.
---@param target? any game.Me when omitted.
---@return string[]
function Animations:GetBones(target) end

---The paths of the game's montages and sequences whose path holds every word given. At most 200, then how many there were.
---@param text string Words such as "1st sledge montage".
---@return string[] paths
---@return integer total
function Animations:Find(text) end

---Stops every animation your mod is playing.
function Animations:StopAll() end
