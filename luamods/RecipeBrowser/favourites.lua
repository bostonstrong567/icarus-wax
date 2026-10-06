-- The player's favourite items: item keys in the order they were added.

local favourites = {}

local Favourites = {}
Favourites.__index = Favourites

local function store(self)
    if not self.save then return end
    local copy = {}
    for index = 1, #self.keys do copy[index] = self.keys[index] end
    self.save(copy)
end

-- load() returns the saved list or nil, save(list) keeps it.
function favourites.new(load, save)
    local self = setmetatable({ keys = {}, held = {}, save = save }, Favourites)
    local saved = load and load()
    if type(saved) ~= "table" then return self end
    local order = {}
    for index, key in pairs(saved) do
        if type(index) == "number" and type(key) == "string" and key ~= "" then order[#order + 1] = index end
    end
    table.sort(order)
    for _, index in ipairs(order) do
        local key = saved[index]
        if not self.held[key] then
            self.held[key] = true
            self.keys[#self.keys + 1] = key
        end
    end
    return self
end

function Favourites:has(key)
    return self.held[key] == true
end

function Favourites:toggle(key)
    if type(key) ~= "string" or key == "" then return false end
    if self.held[key] then
        self.held[key] = nil
        for index = 1, #self.keys do
            if self.keys[index] == key then
                table.remove(self.keys, index)
                break
            end
        end
    else
        self.held[key] = true
        self.keys[#self.keys + 1] = key
    end
    store(self)
    return self.held[key] == true
end

-- Puts a favourite just before another one, or last when no other is named. False when the key is not a favourite.
function Favourites:move(key, before)
    if not self.held[key] or key == before then return false end
    for index = 1, #self.keys do
        if self.keys[index] == key then
            table.remove(self.keys, index)
            break
        end
    end
    local at = #self.keys + 1
    for index = 1, #self.keys do
        if self.keys[index] == before then
            at = index
            break
        end
    end
    table.insert(self.keys, at, key)
    store(self)
    return true
end

-- Keys the model does not have now stay saved and are only left out of this list.
function Favourites:list(known)
    local out = {}
    for index = 1, #self.keys do
        local key = self.keys[index]
        if not known or known(key) then out[#out + 1] = key end
    end
    return out
end

function Favourites:count(known)
    if not known then return #self.keys end
    local count = 0
    for index = 1, #self.keys do
        if known(self.keys[index]) then count = count + 1 end
    end
    return count
end

function Favourites:clear()
    self.keys, self.held = {}, {}
    store(self)
end

return favourites
