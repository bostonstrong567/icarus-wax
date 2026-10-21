---@meta _

---A value the game handed a hook, as a listener may have it: read inside the listener, never written. An array answers
---`#view`, `view[i]` (nil past the end), `view:get()` (a Lua table of its entries) and `view:ForEach`; a struct answers its
---fields. An object comes as an Instance and text as a string, not as a view. A write raises an error: the value is the
---game's own memory, and growing or emptying an array there crashes the game. Once the listener has returned, every
---view it was handed answers with an error, so copy what you keep with `get`.
---@class WaxHanded
local Handed = {}

---A copy a listener may keep. An array becomes a Lua table of its entries, with objects as Instances, text as strings and
---structs as views. A struct view gives itself.
---@return any
function Handed:get() end

---How many entries an array has. An error on a struct.
---@return integer
function Handed:GetArrayNum() end

---The same as GetArrayNum.
---@return integer
function Handed:Num() end

---True for an array with no entries.
---@return boolean
function Handed:IsEmpty() end

---Runs fn for every entry of an array, with its index from 1 and the entry converted as `view[i]` gives it. Return true from fn to stop.
---@param fn fun(index: integer, entry: any): boolean?
function Handed:ForEach(fn) end

---The return value of the function a post listener runs after. Good only inside the listener.
---@class WaxHookReturn
---@field changed boolean True once set was called.
local Return = {}

---What the function answered, converted like a parameter. An error on a function that returns nothing.
---@return any
function Return:get() end

---Replaces what the caller will see. An Instance is passed as its object. Returning a value from the listener does the same.
---An error from a "pre" listener (the function has not run yet) and on a function that returns nothing.
---@param value any
function Return:set(value) end

---@class WaxHookOptions
---@field when? "pre"|"post" "pre" (the default) runs the listener before the function, as fn(object, params...). "post" runs it after, as fn(object, ret, params...), where ret is the return value to read and set.
---@field reach? "net"|"delegate"|"called" How the game reaches the function. With "called" (blueprint code calls it) the values are the caller's own variables, not the call's, so only the object is handed over. Left out: what listens to the function already, else "delegate".
---@field label? string A name for the listener in error reports. The function's name when left out.

---Listening to the game's own functions. `hooks.listen` is the way; UE4SS's RegisterHook is not available to a mod.
---@class WaxHooks
---@field NET "net" The game's own code raises the function as a network call: its values are right.
---@field DELEGATE "delegate" The game bound the function to one of its events: its values are right.
---@field CALLED "called" Blueprint code calls the function: only the object is right.
hooks = {}

---Runs fn each time the game calls the function at `path`, such as "/Script/Icarus.ProcessingComponent:CanSatisfyRecipeInput".
---Only a function of the game's own code can be listened to, never a blueprint's. fn gets the object the function was
---called on as an Instance and its parameters as values it can read and not write: numbers, strings and booleans as they
---are, objects as Instances, arrays and structs as views (WaxHanded). With `when = "post"` the second argument is the
---return value (WaxHookReturn): `ret:get()` reads what the game answered, `ret:set(value)` or a value returned from fn
---replaces it. fn runs inside the game's own call: keep it short and never wait in it. An error in fn is logged, and
---after five in a row the listener is switched off. Returns the function that takes the listener off; a reload of the
---mod takes it off by itself.
---@param path string
---@param fn fun(object: WaxInstance, ...: any): any
---@param options? WaxHookOptions
---@return fun() undo
function hooks.listen(path, fn, options) end
