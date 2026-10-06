-- Strict JSON decoder. null decodes to json.null so that "field": null survives in a Lua table

local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end, __metatable = "json.null" })

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
local MAX_DEPTH = 200
local find, sub, byte = string.find, string.sub, string.byte

function M.decode(text)
    if type(text) ~= "string" then error("json.decode expects a string, got " .. type(text), 2) end
    local pos = 1

    local function fail(message, at)
        at = at or pos
        local line, line_start = 1, 0
        for where in text:gmatch("()\n") do
            if where >= at then break end
            line, line_start = line + 1, where
        end
        error(("JSON error at line %d, column %d: %s"):format(line, at - line_start, message), 0)
    end

    local function skip() pos = find(text, "[^ \t\r\n]", pos) or #text + 1 end

    local function parse_string()
        local start = pos + 1
        local stop = find(text, '["\\\0-\31]', start)
        if stop and byte(text, stop) == 34 then
            pos = stop + 1
            return sub(text, start, stop - 1)
        end
        local parts, n, i = {}, 0, start
        while true do
            local j = find(text, '["\\\0-\31]', i)
            if not j then fail("unterminated string", start - 1) end
            n = n + 1
            parts[n] = sub(text, i, j - 1)
            local c = byte(text, j)
            if c == 34 then pos = j + 1 break end
            if c ~= 92 then fail("control character in a string", j) end
            local escape = sub(text, j + 1, j + 1)
            n = n + 1
            if escape == "u" then
                if not find(text, "^%x%x%x%x", j + 2) then fail("\\u needs four hex digits", j) end
                local code = tonumber(sub(text, j + 2, j + 5), 16)
                i = j + 6
                if code >= 0xD800 and code <= 0xDBFF then
                    if not find(text, "^\\u[dD][c-fC-F]%x%x", i) then fail("unpaired surrogate in a string", j) end
                    code = 0x10000 + (code - 0xD800) * 0x400 + (tonumber(sub(text, i + 2, i + 5), 16) - 0xDC00)
                    i = i + 6
                elseif code >= 0xDC00 and code <= 0xDFFF then
                    fail("unpaired surrogate in a string", j)
                end
                parts[n] = utf8.char(code)
            else
                local plain = ESCAPES[escape]
                if not plain then fail("unknown escape in a string", j) end
                parts[n] = plain
                i = j + 2
            end
        end
        return table.concat(parts)
    end

    local function parse_number()
        local _, stop = find(text, "^-?%d+", pos)
        if not stop then fail("unexpected character") end
        local first = byte(text, pos) == 45 and pos + 1 or pos
        if stop > first and byte(text, first) == 48 then fail("a number cannot start with 0") end
        local _, fraction = find(text, "^%.%d+", stop + 1)
        if fraction then
            stop = fraction
        elseif byte(text, stop + 1) == 46 then
            fail("digits expected after the decimal point", stop + 1)
        end
        local _, exponent = find(text, "^[eE][+-]?%d+", stop + 1)
        if exponent then
            stop = exponent
        elseif find(text, "^[eE]", stop + 1) then
            fail("digits expected in the exponent", stop + 1)
        end
        local number = tonumber(sub(text, pos, stop))
        pos = stop + 1
        return number
    end

    local function literal(word, value)
        if sub(text, pos, pos + #word - 1) ~= word then fail("unexpected character") end
        pos = pos + #word
        return value
    end

    local parse_value
    function parse_value(depth)
        if depth > MAX_DEPTH then fail("nested too deeply") end
        skip()
        local c = byte(text, pos)
        if c == nil then fail("unexpected end of input") end
        if c == 123 then
            local out = {}
            pos = pos + 1
            skip()
            if byte(text, pos) == 125 then pos = pos + 1 return out end
            while true do
                skip()
                if byte(text, pos) ~= 34 then fail("an object key must be a string") end
                local key = parse_string()
                skip()
                if byte(text, pos) ~= 58 then fail("':' expected after an object key") end
                pos = pos + 1
                out[key] = parse_value(depth + 1)
                skip()
                local d = byte(text, pos)
                if d == 125 then pos = pos + 1 return out end
                if d ~= 44 then fail("',' or '}' expected") end
                pos = pos + 1
            end
        elseif c == 91 then
            local out, n = {}, 0
            pos = pos + 1
            skip()
            if byte(text, pos) == 93 then pos = pos + 1 return out end
            while true do
                n = n + 1
                out[n] = parse_value(depth + 1)
                skip()
                local d = byte(text, pos)
                if d == 93 then pos = pos + 1 return out end
                if d ~= 44 then fail("',' or ']' expected") end
                pos = pos + 1
            end
        elseif c == 34 then
            return parse_string()
        elseif c == 116 then
            return literal("true", true)
        elseif c == 102 then
            return literal("false", false)
        elseif c == 110 then
            return literal("null", M.null)
        end
        return parse_number()
    end

    if sub(text, 1, 3) == "\239\187\191" then pos = 4 end
    local value = parse_value(1)
    skip()
    if pos <= #text then fail("unexpected text after the JSON value") end
    return value
end

return M
