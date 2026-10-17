-- Reads zip files in pure Lua: the list of entries, and an entry's bytes, stored or deflated. For the EXMODZ files the community shares.
local M = {}
M.MAX_ENTRIES = 10000

local byte, sub, char, unpack_at = string.byte, string.sub, string.char, string.unpack
local concat, tunpack = table.concat, table.unpack

local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- A canonical Huffman table from code lengths (lengths[1..n], 0 for a symbol without a code).
local function construct(lengths, n)
    local count = {}
    for len = 0, 15 do count[len] = 0 end
    for s = 1, n do count[lengths[s]] = count[lengths[s]] + 1 end
    local left = 1
    for len = 1, 15 do
        left = (left << 1) - count[len]
        if left < 0 then error("bad deflate stream: over-subscribed code lengths", 0) end
    end
    local offs = { [1] = 0 }
    for len = 1, 14 do offs[len + 1] = offs[len] + count[len] end
    local symbol = {}
    for s = 1, n do
        local len = lengths[s]
        if len ~= 0 then
            symbol[offs[len] + 1] = s - 1
            offs[len] = offs[len] + 1
        end
    end
    return { count = count, symbol = symbol }
end

local fixed_len, fixed_dist

local function fixed_tables()
    if fixed_len then return fixed_len, fixed_dist end
    local lengths = {}
    for s = 1, 144 do lengths[s] = 8 end
    for s = 145, 256 do lengths[s] = 9 end
    for s = 257, 280 do lengths[s] = 7 end
    for s = 281, 288 do lengths[s] = 8 end
    fixed_len = construct(lengths, 288)
    local dists = {}
    for s = 1, 30 do dists[s] = 5 end
    fixed_dist = construct(dists, 30)
    return fixed_len, fixed_dist
end

-- Inflates a raw deflate stream (RFC 1951). `limit` caps the output; `pause` is called now and then so a long stream can yield.
function M.inflate(input, limit, pause)
    local pos, bitbuf, bitcnt = 1, 0, 0
    local out, n, flushed = {}, 0, 0
    local pieces = {}
    limit = limit or (64 * 1024 * 1024)

    local function bits(need)
        while bitcnt < need do
            local b = byte(input, pos)
            if not b then error("bad deflate stream: it ends early", 0) end
            pos = pos + 1
            bitbuf = bitbuf | (b << bitcnt)
            bitcnt = bitcnt + 8
        end
        local value = bitbuf & ((1 << need) - 1)
        bitbuf = bitbuf >> need
        bitcnt = bitcnt - need
        return value
    end

    local function decode(h)
        local code, first, index = 0, 0, 0
        local count, symbol = h.count, h.symbol
        for len = 1, 15 do
            code = code | bits(1)
            local c = count[len]
            if code - c < first then return symbol[index + (code - first) + 1] end
            index = index + c
            first = (first + c) << 1
            code = code << 1
        end
        error("bad deflate stream: a code is not in the table", 0)
    end

    -- bytes that can no longer be referenced are turned into strings; 32 KB of back-reference stay as numbers
    local function flush(force)
        if not force and n - flushed < 65536 then return end
        local keep = force and n or n - 32768
        local chunk = {}
        local at = flushed
        while at < keep do
            local stop = math.min(keep, at + 4096)
            chunk[#chunk + 1] = char(tunpack(out, at + 1, stop))
            at = stop
        end
        pieces[#pieces + 1] = concat(chunk)
        for i = flushed + 1, keep do out[i] = nil end
        flushed = keep
        if pause then pause() end
    end

    local function codes(lencode, distcode)
        while true do
            local symbol = decode(lencode)
            if symbol < 256 then
                n = n + 1
                out[n] = symbol
            elseif symbol == 256 then
                return
            else
                symbol = symbol - 256
                if symbol > 29 then error("bad deflate stream: bad length code", 0) end
                local len = LBASE[symbol] + bits(LEXT[symbol])
                local dsym = decode(distcode) + 1
                if dsym > 30 then error("bad deflate stream: bad distance code", 0) end
                local dist = DBASE[dsym] + bits(DEXT[dsym])
                if dist > n then error("bad deflate stream: a distance reaches before the start", 0) end
                for _ = 1, len do
                    n = n + 1
                    out[n] = out[n - dist]
                end
            end
            if n > limit then error(("the file unpacks to more than %d bytes"):format(limit), 0) end
            if n - flushed >= 65536 then flush(false) end
        end
    end

    repeat
        local last = bits(1)
        local kind = bits(2)
        if kind == 0 then
            bitbuf, bitcnt = 0, 0
            if pos + 3 > #input then error("bad deflate stream: it ends early", 0) end
            local len = unpack_at("<I2", input, pos)
            local nlen = unpack_at("<I2", input, pos + 2)
            if len ~= ((~nlen) & 0xFFFF) then error("bad deflate stream: stored length check failed", 0) end
            pos = pos + 4
            if pos + len - 1 > #input then error("bad deflate stream: it ends early", 0) end
            for i = pos, pos + len - 1 do
                n = n + 1
                out[n] = byte(input, i)
            end
            pos = pos + len
            if n > limit then error(("the file unpacks to more than %d bytes"):format(limit), 0) end
            flush(false)
        elseif kind == 1 then
            codes(fixed_tables())
        elseif kind == 2 then
            local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
            if nlen > 286 or ndist > 30 then error("bad deflate stream: too many codes", 0) end
            local lengths = {}
            for i = 1, 19 do lengths[i] = 0 end
            for i = 1, ncode do lengths[ORDER[i] + 1] = bits(3) end
            local lencode = construct(lengths, 19)
            local index = 1
            local all = {}
            while index <= nlen + ndist do
                local symbol = decode(lencode)
                if symbol < 16 then
                    all[index] = symbol
                    index = index + 1
                else
                    local len, repeat_n = 0, 0
                    if symbol == 16 then
                        if index == 1 then error("bad deflate stream: a repeat with nothing before it", 0) end
                        len = all[index - 1]
                        repeat_n = 3 + bits(2)
                    elseif symbol == 17 then
                        repeat_n = 3 + bits(3)
                    else
                        repeat_n = 11 + bits(7)
                    end
                    if index + repeat_n - 1 > nlen + ndist then error("bad deflate stream: too many code lengths", 0) end
                    for _ = 1, repeat_n do
                        all[index] = len
                        index = index + 1
                    end
                end
            end
            if all[257] == 0 then error("bad deflate stream: no end-of-block code", 0) end
            local lens, dists = {}, {}
            for i = 1, nlen do lens[i] = all[i] end
            for i = 1, ndist do dists[i] = all[nlen + i] end
            codes(construct(lens, nlen), construct(dists, ndist))
        else
            error("bad deflate stream: block type 3", 0)
        end
    until last == 1
    flush(true)
    return concat(pieces)
end

-- The entries of a zip: { name, method, compressed, size, offset }. Zip64 and encrypted entries are refused.
function M.entries(data)
    local size = #data
    local at = nil
    for i = size - 21, math.max(1, size - 65557), -1 do
        if sub(data, i, i + 3) == "PK\5\6" then
            at = i
            break
        end
    end
    if not at then error("not a zip file", 0) end
    local count = unpack_at("<I2", data, at + 10)
    local dir_offset = unpack_at("<I4", data, at + 16)
    if count > M.MAX_ENTRIES then error(("the zip lists more than %d files"):format(M.MAX_ENTRIES), 0) end
    local entries = {}
    local pos = dir_offset + 1
    for _ = 1, count do
        if sub(data, pos, pos + 3) ~= "PK\1\2" then error("the zip's central directory is damaged", 0) end
        local flags = unpack_at("<I2", data, pos + 8)
        local method = unpack_at("<I2", data, pos + 10)
        local compressed = unpack_at("<I4", data, pos + 20)
        local uncompressed = unpack_at("<I4", data, pos + 24)
        local name_len = unpack_at("<I2", data, pos + 28)
        local extra_len = unpack_at("<I2", data, pos + 30)
        local comment_len = unpack_at("<I2", data, pos + 32)
        local offset = unpack_at("<I4", data, pos + 42)
        local name = sub(data, pos + 46, pos + 45 + name_len)
        if flags & 1 == 1 then error(("%s is encrypted"):format(name), 0) end
        if compressed == 0xFFFFFFFF or uncompressed == 0xFFFFFFFF or offset == 0xFFFFFFFF then error("zip64 files are not supported", 0) end
        entries[#entries + 1] = { name = name, method = method, compressed = compressed, size = uncompressed, offset = offset }
        pos = pos + 46 + name_len + extra_len + comment_len
    end
    return entries
end

-- The bytes of one entry. `limit` caps the unpacked size; `pause` is passed to inflate.
function M.read(data, entry, limit, pause)
    local pos = entry.offset + 1
    if sub(data, pos, pos + 3) ~= "PK\3\4" then error(("the zip entry %s is damaged"):format(entry.name), 0) end
    local name_len = unpack_at("<I2", data, pos + 26)
    local extra_len = unpack_at("<I2", data, pos + 28)
    local start = pos + 30 + name_len + extra_len
    local stop = start + entry.compressed - 1
    if stop > #data then error(("the zip entry %s reaches past the end of the file"):format(entry.name), 0) end
    if limit and entry.size > limit then error(("%s is larger than %d bytes"):format(entry.name, limit), 0) end
    local packed = sub(data, start, stop)
    if entry.method == 0 then return packed end
    if entry.method == 8 then return M.inflate(packed, limit, pause) end
    error(("the zip entry %s uses compression method %d, which is not supported"):format(entry.name, entry.method), 0)
end

return M
