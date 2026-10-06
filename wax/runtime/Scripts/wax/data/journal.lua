-- Record of data edits: the original value and who has written since. It is kept here so that reloading data.tables does not lose it.

local M = {}

local entries = {}      -- key -> { info, original, layers = { { owner, value } } }, newest layer last

local function drop(layers, owner)
    for i = #layers, 1, -1 do
        if layers[i].owner == owner then table.remove(layers, i) end
    end
end

local function restore(apply, entry, value, failures)
    local ok, err = pcall(apply, entry.info, value)
    if not ok then failures[#failures + 1] = tostring(err) end
end

-- Records `owner` writing `value`. capture() reads the current value the first time a key is written.
function M.push(key, owner, value, capture, info)
    local entry = entries[key]
    if not entry then
        entry = { info = info, original = capture(), layers = {} }
        entries[key] = entry
    end
    drop(entry.layers, owner)
    entry.layers[#entry.layers + 1] = { owner = owner, value = value }
end

-- Removes every write of `owner`. apply(info, value) runs where the visible value changes. Returns the failures.
function M.release(owner, apply)
    local failures = {}
    for key, entry in pairs(entries) do
        local layers = entry.layers
        local top = layers[#layers]
        drop(layers, owner)
        local now = layers[#layers]
        if now == nil then
            entries[key] = nil
            restore(apply, entry, entry.original, failures)
        elseif now ~= top then
            restore(apply, entry, now.value, failures)
        end
    end
    return failures
end

-- Puts back the original of every key that match(info) accepts, whoever wrote it. Returns count, failures.
function M.reset(match, apply)
    local count, failures = 0, {}
    for key, entry in pairs(entries) do
        if match(entry.info) then
            entries[key] = nil
            count = count + 1
            restore(apply, entry, entry.original, failures)
        end
    end
    return count, failures
end

-- Every key that is currently patched.
function M.list()
    local out = {}
    for _, entry in pairs(entries) do
        local top = entry.layers[#entry.layers]
        out[#out + 1] = { info = entry.info, original = entry.original, value = top.value, owner = top.owner, writers = #entry.layers }
    end
    return out
end

return M
