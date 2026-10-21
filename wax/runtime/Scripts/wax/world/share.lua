-- Spreading what is pulled or stashed evenly over the stations of one kind, so they all work at once: game.Items:Share
local M = {}

local function stack_of(facts, item)
    local told = facts and facts(item) or nil
    local most = told and told.MaxStack
    if math.type(most) ~= "integer" or most < 1 then return 1 end
    return most
end

-- How many more of an item a station's input inventory can take: the room on its stacks of it, then its free slots.
function M.room(station, item, facts)
    local most = stack_of(facts, item)
    local key = item:lower()
    local room, held = 0, 0
    for _, stack in ipairs(station.stacks or {}) do
        if stack.Item:lower() == key then
            held = held + stack.Count
            if stack.Count < most then room = room + (most - stack.Count) end
        end
    end
    local free = math.max(0, (station.size or 0) - (station.used or 0))
    return room + free * most, held
end

-- Divides `total` of an item over the stations that accept it, as evenly as their room allows: each gets up to the
-- share that brings it level with the others, a station that already holds more than its share gets nothing until
-- the rest catch up, and what the even split leaves over goes to the nearest. stations: nearest first, each
-- { stacks, size, used, accepts(item) -> bool }. Answers { [index] = count } and what could not be placed.
function M.spread(total, item, stations, facts)
    local out = {}
    if type(total) ~= "number" or total <= 0 then return out, total or 0 end
    local takers = {}
    for index, station in ipairs(stations or {}) do
        if not station.accepts or station.accepts(item) then
            local room, held = M.room(station, item, facts)
            if room > 0 then takers[#takers + 1] = { index = index, room = room, held = held, given = 0 } end
        end
    end
    if #takers == 0 then return out, total end
    local left = total
    -- level the stations up: the lowest holding gets first, until all hold the same or the item runs out
    while left > 0 do
        local lowest, count = nil, 0
        for _, taker in ipairs(takers) do
            if taker.given < taker.room then
                local holding = taker.held + taker.given
                if not lowest or holding < lowest then lowest, count = holding, 1
                elseif holding == lowest then count = count + 1 end
            end
        end
        if not lowest then break end
        local next_level = nil
        for _, taker in ipairs(takers) do
            local holding = taker.held + taker.given
            if taker.given < taker.room and holding > lowest and (not next_level or holding < next_level) then next_level = holding end
        end
        local step = next_level and (next_level - lowest) or math.huge
        local each = math.floor(left / count)
        if each > step then each = step end
        if each == 0 then
            -- fewer than one each: the remainder goes to the nearest of the lowest
            for _, taker in ipairs(takers) do
                if left > 0 and taker.given < taker.room and taker.held + taker.given == lowest then
                    local give = math.min(left, taker.room - taker.given)
                    taker.given, left = taker.given + give, left - give
                    break
                end
            end
            if not next_level then break end
        else
            for _, taker in ipairs(takers) do
                if taker.given < taker.room and taker.held + taker.given == lowest then
                    local give = math.min(each, taker.room - taker.given, left)
                    taker.given, left = taker.given + give, left - give
                end
            end
        end
    end
    for _, taker in ipairs(takers) do
        if taker.given > 0 then out[taker.index] = taker.given end
    end
    return out, left
end

return M
