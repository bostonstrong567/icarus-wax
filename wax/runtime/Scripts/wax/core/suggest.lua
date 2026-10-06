-- Closest-name search for error messages ("did you mean ...?")
local M = {}

local byte, lower, abs, max, min = string.byte, string.lower, math.abs, math.max, math.min
local rawget, rawlen, next, type = rawget, rawlen, next, type

-- Optimal string alignment distance (insert, delete, substitute, swap neighbours) between two strings
local prev2, prev, cur = {}, {}, {}
function M.distance(a, b, limit)
    local la, lb = #a, #b
    limit = limit or max(la, lb)
    if abs(la - lb) > limit then return limit + 1 end
    if a == b then return 0 end
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        cur[0] = i
        local best = i
        local ai = byte(a, i)
        local aprev = i > 1 and byte(a, i - 1) or -1
        -- only the diagonal band |i - j| <= limit can hold a value <= limit
        local lo, hi = max(1, i - limit), min(lb, i + limit)
        if lo > 1 then cur[lo - 1] = limit + 1 end
        for j = lo, hi do
            local bj = byte(b, j)
            local v = prev[j - 1] + (ai == bj and 0 or 1)
            local up = (prev[j] or limit + 1) + 1
            if up < v then v = up end
            local left = cur[j - 1] + 1
            if left < v then v = left end
            if i > 1 and j > 1 and ai == byte(b, j - 1) and aprev == bj then
                local tr = prev2[j - 2] + 1
                if tr < v then v = tr end
            end
            cur[j] = v
            if v < best then best = v end
        end
        if hi < lb then cur[hi + 1] = limit + 1 end
        if best > limit then return limit + 1 end
        prev2, prev, cur = prev, cur, prev2
    end
    local d = prev[lb]
    return d <= limit and d or limit + 1
end

-- Unreal spellings people forget: K2_ prefixes, the b on booleans, Get/Set/Is, Receive (BP events), On.
local PREFIXES = { "k2_", "b", "get", "set", "is", "receive", "on", "bp_" }

-- Lower-cased copies of a name list are cached per list (weak keys)
local lowered = setmetatable({}, { __mode = "k" })
-- Raw access only: `names` is often a strict table whose __index raises (that is why we were called).
local function prepare(names)
    local p = lowered[names]
    local isArray = rawget(names, 1) ~= nil
    if p and (not isArray or p.n == rawlen(names)) then return p end
    local list, low, n = {}, {}, 0
    if isArray then
        for i = 1, rawlen(names) do
            local name = rawget(names, i)
            if type(name) == "string" then n = n + 1 list[n] = name low[n] = lower(name) end
        end
    else
        for name in next, names do
            if type(name) == "string" then n = n + 1 list[n] = name low[n] = lower(name) end
        end
    end
    p = { list = list, low = low, n = isArray and rawlen(names) or n }
    lowered[names] = p
    return p
end

-- names: array of strings, or a set { name = anything }.  Returns up to `count` suggestions, best first.
function M.suggest(word, names, count)
    count = count or 3
    local lw = lower(word)
    local lwlen = #lw
    local limit = lwlen <= 4 and 1 or lwlen <= 8 and 2 or 3
    -- spellings that differ only by an Unreal prefix, in either direction, score as near-exact
    local variants = {}
    for i = 1, #PREFIXES do
        local p = PREFIXES[i]
        variants[p .. lw] = true
        if lwlen > #p + 1 and lw:sub(1, #p) == p then variants[lw:sub(#p + 1)] = true end
    end
    local p = prepare(names)
    local list, low = p.list, p.low
    local found, n = {}, 0
    local distance = M.distance
    for i = 1, #list do
        local ln = low[i]
        local score
        if ln == lw then
            score = 0
        elseif variants[ln] then
            score = 0.5
        else
            local diff = #ln - lwlen
            if diff <= limit and diff >= -limit then
                local d = distance(lw, ln, limit)
                if d <= limit then score = d end
            end
            if not score and lwlen >= 4 and diff > 0 and ln:find(lw, 1, true) then
                score = limit + 0.5 + diff / 1000       -- the typed text is part of a longer name
            end
        end
        if score then n = n + 1 found[n] = { list[i], score } end
    end
    table.sort(found, function(x, y)
        if x[2] ~= y[2] then return x[2] < y[2] end
        if #x[1] ~= #y[1] then return #x[1] < #y[1] end
        return x[1] < y[1]
    end)
    local out = {}
    for i = 1, min(count, n) do out[i] = found[i][1] end
    return out
end

-- "Did you mean `A`, `B` or `C`?"  (empty string when nothing is close)
function M.phrase(word, names, count)
    local s = M.suggest(word, names, count)
    if #s == 0 then return "" end
    for i = 1, #s do s[i] = "'" .. s[i] .. "'" end
    local last = table.remove(s)
    return " Did you mean " .. (#s > 0 and (table.concat(s, ", ") .. " or ") or "") .. last .. "?"
end

return M
