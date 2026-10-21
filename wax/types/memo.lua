---@meta

---Small caches for hot paths: a frame memo forgets everything when the frame changes, a timed one forgets an entry
---after its seconds. A hook the game calls hundreds of times a frame answers the same question from one of these after
---the first time.
---@class WaxMemoModule
local memo = {}

---A cache that holds its entries for the rest of the current frame.
---@return WaxMemo
function memo.frame() end

---A cache whose entries last this many seconds from when they were set.
---@param seconds number
---@return WaxTimedMemo
function memo.timed(seconds) end

---@class WaxMemo
---@field count integer How many entries it holds.
---@field hits integer How many times get or take answered from an entry.
local Memo = {}

---The value kept under the key, or nil. Keys are any Lua value; false is kept as a value.
---@param key any
---@return any
function Memo:get(key) end

---True when an entry is there.
---@param key any
---@return boolean
function Memo:has(key) end

---Keeps a value under the key and answers it.
---@param key any
---@param value any
---@return any
function Memo:set(key, value) end

---The value kept under the key, or fn(...) kept under it now. A nil answer is not kept.
---@param key any
---@param fn fun(...): any
---@param ... any
---@return any
function Memo:take(key, fn, ...) end

---Forgets every entry.
function Memo:clear() end

---@class WaxTimedMemo: WaxMemo
local TimedMemo = {}

---Drops every entry whose seconds are over.
function TimedMemo:sweep() end
