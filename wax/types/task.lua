---@meta _

---What Connect returns: one handler's link to a signal.
---@class WaxConnection
---@field Connected boolean False once the handler has been disconnected.
local Connection = {}

---Stops the handler from being called again.
function Connection:Disconnect() end

---An event that handlers connect to. `F` is the shape of a handler, as in `WaxSignal<fun(name: string)>`.
---@class WaxSignal<F>
---@field Connect fun(self: WaxSignal<F>, fn: F): WaxConnection Calls fn on every Fire, newest connection first.
---@field Once fun(self: WaxSignal<F>, fn: F): WaxConnection Like Connect, for the next Fire only.
---@field Wait fun(self: WaxSignal<F>): ...any Pauses the calling task until the next Fire and returns what was fired.
---@field Fire fun(self: WaxSignal<F>, ...: any) Calls every handler with these values. Each runs as a task and may pause.
---@field FireDirect fun(self: WaxSignal<F>, ...: any) Calls every handler directly, without a task. Handlers must not pause.
---@field DisconnectAll fun(self: WaxSignal<F>) Disconnects every handler.

---@class WaxSignalLibrary
Signal = {}

---Creates a signal. The name labels its handlers in error reports.
---@param name? string
---@return WaxSignal
function Signal.new(name) end

---@class WaxTask
task = {}

---Runs f(...) now, until it returns or first pauses.
---@param f function|thread
---@param ... any
---@return thread
function task.spawn(f, ...) end

---Runs f(...) at the end of the current frame's step (or of the next one, when called outside a step).
---@param f function|thread
---@param ... any
---@return thread
function task.defer(f, ...) end

---Runs f(...) after `seconds`, never earlier than the next frame.
---@param seconds number
---@param f function|thread
---@param ... any
---@return thread
function task.delay(seconds, f, ...) end

---Pauses the calling task for `seconds` (at least until the next frame) and returns the time it waited. It only works inside a task.
---@param seconds? number
---@return number waited
function task.wait(seconds) end

---Stops a task. It cannot be resumed afterwards.
---@param thread thread
function task.cancel(thread) end

---Names a task for error messages and the debugger.
---@param thread thread
---@param label string
---@return thread
function task.label(thread, label) end
