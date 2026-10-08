-- The check of texts against the owner's list of unwanted words, for any suite. This file holds no word of that list:
-- the list is kept in one file, which is not part of the public copy, and is read from there when it is here.
--   local wording = dofile("wax/tests/offline/wording.lua")
--   local list = wording.unwanted()        -- nil where the list is not there
--   wording.wrong_with(line, list)         -- what is wrong with a line, or nil

local M = {}

M.SOURCE = "wax/vscode/test/wording.test.mjs"

-- The list as { words, phrases, initials }, or nil when its file is not here.
function M.unwanted()
    local file = io.open(M.SOURCE, "rb")
    if not file then return nil end
    local source = file:read("a")
    file:close()
    local listed = source:match("BANNED = /(.-)/i;")
    local words, phrases = (listed or ""):match("^\\b%((.-)%)\\b|(.*)$")
    local out = { words = {}, phrases = {}, initials = source:match("INITIALS = /\\b(%u+)\\b/") }
    for term in (words or ""):gmatch("[^|]+") do
        local base, ending = term:match("^(.-)%((%a+)%)%?$")
        if not base then base, ending = term:match("^(.-)(%a)%?$") end
        if base then
            out.words[#out.words + 1] = base
            out.words[#out.words + 1] = base .. ending
        else
            out.words[#out.words + 1] = term
        end
    end
    for phrase in (phrases or ""):gmatch("[^|]+") do out.phrases[#out.phrases + 1] = phrase end
    return out
end

-- True when the list was read whole. A list that reads as nearly empty means its file changed shape, and a check with it would pass anything.
function M.complete(list)
    return #list.words > 20 and #list.phrases > 3 and list.initials ~= nil
end

-- What of the list a line has, or nil.
function M.listed(line, list)
    local lowered = line:lower()
    local spaced = " " .. lowered:gsub("%A", " ") .. " "
    for _, word in ipairs(list.words) do
        if spaced:find(" " .. word .. " ", 1, true) then return "the word '" .. word .. "'" end
    end
    for _, phrase in ipairs(list.phrases) do
        if lowered:find(phrase, 1, true) then return "'" .. phrase .. "'" end
    end
    if list.initials and (" " .. line:gsub("%A", " ") .. " "):find(" " .. list.initials .. " ", 1, true) then
        return "the initials " .. list.initials
    end
    return nil
end

-- The marks a plain text does not have, or nil.
function M.marks(line)
    if line:find("[\128-\255]") then return "a character that is not plain ASCII (a dash, an ellipsis, a picture)" end
    if line:find("!", 1, true) then return "an exclamation mark" end
    if line:find(";", 1, true) then return "a semicolon" end
    if line:find("%-%-") or line:find("%.%.%.%.") then return "a dash or dots that are not plain" end
    return nil
end

-- What is wrong with a line: a mark, or with a list something of the list. nil when nothing is.
function M.wrong_with(line, list)
    return M.marks(line) or (list and M.listed(line, list)) or nil
end

return M
