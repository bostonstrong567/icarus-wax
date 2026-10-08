---@meta _

---The frame signal, game.Frame. Wax fires it once every frame. A mod connects handlers to it and disconnects its own.
---It has no Fire and no DisconnectAll.
---@class WaxFrameSignal
local Frame = {}

---Calls fn(seconds) once every frame. `seconds` is the time since the frame before, and 0 on the first frame Wax runs.
---Each call runs as a task and may pause. A handler that is still paused is called again on the next frame all the same.
---The handler is disconnected when the mod unloads.
---@param fn fun(seconds: number)
---@return WaxConnection
function Frame:Connect(fn) end

---Like Connect, for the next frame only.
---@param fn fun(seconds: number)
---@return WaxConnection
function Frame:Once(fn) end

---Pauses the calling task until the next frame and returns the seconds since the frame before. It only works inside a task.
---@return number seconds
function Frame:Wait() end
