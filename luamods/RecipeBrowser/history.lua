-- The picks of this session, newest last. The last one is what is showing now.

local history = {}

local History = {}
History.__index = History

function history.new(limit)
    limit = math.max(1, math.floor(tonumber(limit) or 20))
    return setmetatable({ limit = limit, entries = {} }, History)
end

-- Takes { item = key, mode = mode } or the two values. Pushing what is already on top does nothing.
function History:push(entry, mode)
    local kept = {}
    if type(entry) == "table" then
        for key, value in pairs(entry) do kept[key] = value end
        kept.item, kept.mode = entry.item or entry[1], entry.mode or entry[2]
        kept[1], kept[2] = nil, nil
    else
        kept.item, kept.mode = entry, mode
    end
    if kept.item == nil then return false end
    local entries = self.entries
    local top = entries[#entries]
    if top and top.item == kept.item and top.mode == kept.mode then return false end
    entries[#entries + 1] = kept
    if #entries > self.limit then table.remove(entries, 1) end
    return true
end

-- Drops the pick that is showing and returns the one before it, or nil when there is none.
function History:back()
    local entries = self.entries
    if #entries < 2 then return nil end
    entries[#entries] = nil
    return entries[#entries]
end

function History:can_back()
    return #self.entries > 1
end

function History:top()
    return self.entries[#self.entries]
end

function History:count()
    return #self.entries
end

function History:clear()
    self.entries = {}
end

return history
