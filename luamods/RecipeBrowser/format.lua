-- Numbers as the browser prints them: weights, times, litres and counts.

local format = {}

format.units = { gram = "g", kilo = "kg", second = "s", thousand = "k" }

local function number(value)
    if type(value) ~= "number" or value ~= value then return nil end
    return value
end

-- "1.50" becomes "1.5" and "2.0" becomes "2".
local function trim(text)
    if not text:find(".", 1, true) then return text end
    text = text:gsub("0+$", "")
    text = text:gsub("%.$", "")
    return text
end

function format.thousands(value)
    value = number(value)
    if not value then return "" end
    local whole = math.floor(math.abs(value) + 0.5)
    local digits = ("%.0f"):format(whole)
    local out = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if out:sub(1, 1) == "," then out = out:sub(2) end
    if value < 0 and whole > 0 then out = "-" .. out end
    return out
end

-- Grams under a kilogram, kilograms above, nothing for no weight.
function format.weight(grams)
    grams = number(grams)
    if not grams or grams <= 0 then return "" end
    if grams < 1000 then
        local shown = trim(("%.1f"):format(grams))
        if shown == "1000" then return "1 " .. format.units.kilo end
        if shown == "0" then return "" end
        return shown .. " " .. format.units.gram
    end
    local kilos = grams / 1000
    local shown
    if kilos < 10 then
        shown = trim(("%.2f"):format(kilos))
    elseif kilos < 100 then
        shown = trim(("%.1f"):format(kilos))
    else
        shown = format.thousands(kilos)
    end
    return shown .. " " .. format.units.kilo
end

-- The bare figure of a time, to two figures under ten seconds.
function format.figure(seconds)
    seconds = number(seconds)
    if not seconds or seconds < 0.01 then return "" end
    if seconds >= 9.95 then return format.thousands(seconds) end
    if seconds >= 0.995 then return trim(("%.1f"):format(seconds)) end
    return trim(("%.2f"):format(seconds))
end

-- Work divided by a bench's power. Nothing for the trades that take one millijoule.
function format.seconds(millijoules, milliwatts)
    millijoules, milliwatts = number(millijoules), number(milliwatts)
    if not millijoules or not milliwatts or millijoules <= 1 or milliwatts <= 0 then return "" end
    local shown = format.figure(millijoules / milliwatts)
    if shown == "" then return "" end
    return shown .. " " .. format.units.second
end

-- A resource amount in its display unit, which is a thousand of the table's units.
function format.litres(units)
    units = number(units)
    if not units then return "" end
    local value = units / 1000
    if math.abs(value) >= 1000 then return format.thousands(value) end
    return trim(("%.3f"):format(value))
end

function format.count(value)
    value = number(value)
    if not value then return "" end
    if math.abs(value) >= 10000 then
        local sign = value < 0 and "-" or ""
        return sign .. format.thousands(math.floor(math.abs(value) / 1000)) .. format.units.thousand
    end
    if value == math.floor(value) then return format.thousands(value) end
    return trim(("%.1f"):format(value))
end

return format
