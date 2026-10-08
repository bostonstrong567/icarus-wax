-- Reads and checks a pak before the engine sees it: the engine stops the game on a damaged one.

local pakfile = {}

local MAGIC = 0x5A6F12E1
local TRAILER = 221
local MAX_INDEX = 4 * 1024 * 1024
local MAX_FILES = 20000
local MAX_NAME = 260
local SAMPLE, SAMPLES = 32 * 1024, 16

local function rol(x, n) return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF end

function pakfile.sha1(text)
    local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
    local length = #text
    text = text .. "\128" .. ("\0"):rep((55 - length) % 64) .. (">I8"):pack(length * 8)
    local w = {}
    for block = 1, #text, 64 do
        for i = 0, 15 do w[i] = (">I4"):unpack(text, block + i * 4) end
        for i = 16, 79 do w[i] = rol(w[i - 3] ~ w[i - 8] ~ w[i - 14] ~ w[i - 16], 1) end
        local a, b, c, d, e = h0, h1, h2, h3, h4
        for i = 0, 79 do
            local f, k
            if i < 20 then f, k = (b & c) | (~b & d), 0x5A827999
            elseif i < 40 then f, k = b ~ c ~ d, 0x6ED9EBA1
            elseif i < 60 then f, k = (b & c) | (b & d) | (c & d), 0x8F1BBCDC
            else f, k = b ~ c ~ d, 0xCA62C1D6 end
            a, b, c, d, e = (rol(a, 5) + (f & 0xFFFFFFFF) + e + k + w[i]) & 0xFFFFFFFF, a, rol(b, 30), c, d
        end
        h0, h1, h2, h3, h4 = (h0 + a) & 0xFFFFFFFF, (h1 + b) & 0xFFFFFFFF, (h2 + c) & 0xFFFFFFFF,
            (h3 + d) & 0xFFFFFFFF, (h4 + e) & 0xFFFFFFFF
    end
    return (">I4I4I4I4I4"):pack(h0, h1, h2, h3, h4)
end

local function hex(bytes) return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end

-- An engine string: a length, then that many bytes with a zero at the end. Wide strings are refused.
local function fstring(data, at)
    if at + 3 > #data then return nil end
    local count = ("<i4"):unpack(data, at)
    at = at + 4
    if count == 0 then return "", at end
    if count < 0 or count > MAX_NAME or at + count - 1 > #data then return nil end
    local text = data:sub(at, at + count - 2)
    if data:byte(at + count - 1) ~= 0 or text:find("%z") then return nil end
    return text, at + count
end

local function plain(name)
    return name:match("^[%w_%-%./ ]*$") ~= nil and not name:find("..", 1, true) and not name:find("\\", 1, true)
end

-- Returns what the pak holds, or nil and the reason it is refused. mount_point is the one it must have.
function pakfile.check(path, mount_point)
    local file = io.open(path, "rb")
    if not file then return nil, "the file cannot be opened" end
    local function refuse(why)
        file:close()
        return nil, why
    end
    local size = file:seek("end")
    if not size or size < TRAILER then return refuse("it is too short to be a pak") end
    file:seek("set", size - TRAILER)
    local trailer = file:read(TRAILER)
    if not trailer or #trailer ~= TRAILER then return refuse("its end cannot be read") end
    local magic, version, index_offset, index_size = ("<I4i4I8I8"):unpack(trailer, 18)
    if magic ~= MAGIC then return refuse("it is not a version 11 pak") end
    if version ~= 11 then return refuse(("it is pak version %d, and only 11 is taken"):format(version)) end
    if trailer:byte(17) ~= 0 or trailer:sub(1, 16) ~= ("\0"):rep(16) then return refuse("it is encrypted") end
    if trailer:sub(62, 221) ~= ("\0"):rep(160) then return refuse("it is compressed. Pack it without compression") end
    local data_end = size - TRAILER
    if index_size <= 0 or index_size > MAX_INDEX or index_offset < 0 or index_offset + index_size > data_end then
        return refuse("its index lies outside the file")
    end
    file:seek("set", index_offset)
    local index = file:read(index_size)
    if not index or #index ~= index_size then return refuse("its index cannot be read") end
    local index_hash = pakfile.sha1(index)
    if index_hash ~= trailer:sub(42, 61) then return refuse("its index does not match its checksum") end

    local mount, at = fstring(index, 1)
    if not mount then return refuse("its mount point cannot be read") end
    if mount_point and mount ~= mount_point then
        return refuse(("its mount point is %s, and it has to be %s"):format(mount, mount_point))
    end
    if at + 11 > #index then return refuse("its index is cut short") end
    local count = ("<i4"):unpack(index, at)
    at = at + 12
    if count < 1 or count > MAX_FILES then return refuse("it holds no files, or too many") end

    local directory = nil
    for part = 1, 2 do
        if at + 3 > #index then return refuse("its index is cut short") end
        local has = ("<i4"):unpack(index, at)
        at = at + 4
        if has ~= 0 then
            if at + 35 > #index then return refuse("its index is cut short") end
            local offset, length = ("<i8i8"):unpack(index, at)
            local digest = index:sub(at + 16, at + 35)
            at = at + 36
            if offset < 0 or length <= 0 or length > MAX_INDEX or offset + length > data_end then
                return refuse("a part of its index lies outside the file")
            end
            file:seek("set", offset)
            local block = file:read(length)
            if not block or #block ~= length or pakfile.sha1(block) ~= digest then
                return refuse("a part of its index does not match its checksum")
            end
            if part == 2 then directory = block end
        end
    end
    if not directory then return refuse("it has no list of its files") end

    -- Every entry: not compressed, not encrypted, and inside the file.
    if at + 3 > #index then return refuse("its index is cut short") end
    local encoded = ("<i4"):unpack(index, at)
    at = at + 4
    if encoded < 0 or at + encoded - 1 > #index then return refuse("its entries lie outside the index") end
    local stop, entries = at + encoded, 0
    while at < stop do
        if at + 3 >= stop then return refuse("an entry is cut short") end
        local flags = ("<I4"):unpack(index, at)
        at = at + 4
        if (flags >> 23) & 0x3F ~= 0 then return refuse("a file in it is compressed. Pack it without compression") end
        if (flags >> 22) & 1 ~= 0 then return refuse("a file in it is encrypted") end
        if (flags >> 6) & 0xFFFF ~= 0 then return refuse("a file in it is stored in blocks") end
        local offset_format = (flags >> 31) & 1 == 1 and "<I4" or "<I8"
        local size_format = (flags >> 30) & 1 == 1 and "<I4" or "<I8"
        local need = offset_format:packsize() + size_format:packsize()
        if at + need > stop then return refuse("an entry is cut short") end
        local offset = offset_format:unpack(index, at)
        local length = size_format:unpack(index, at + offset_format:packsize())
        at = at + need
        if offset < 0 or length < 0 or offset + length > index_offset then return refuse("a file in it lies outside the pak") end
        entries = entries + 1
    end
    if entries ~= count then return refuse("its entries do not match its count of files") end
    if at + 3 > #index then return refuse("its index is cut short") end
    if ("<i4"):unpack(index, at) ~= 0 then return refuse("it has entries of a kind that is not taken") end

    local files = {}
    local folders = ("<i4"):unpack(directory, 1)
    local p = 5
    if folders < 0 or folders > MAX_FILES then return refuse("its list of files is damaged") end
    for _ = 1, folders do
        local folder, inner
        folder, p = fstring(directory, p)
        if not folder or p + 3 > #directory then return refuse("its list of files is damaged") end
        inner = ("<i4"):unpack(directory, p)
        p = p + 4
        if inner < 0 or inner > MAX_FILES or not plain(folder) then return refuse("its list of files is damaged") end
        for _ = 1, inner do
            local leaf
            leaf, p = fstring(directory, p)
            if not leaf or leaf == "" or p + 3 > #directory + 1 or not plain(leaf) or leaf:find("/", 1, true) then
                return refuse("its list of files is damaged")
            end
            p = p + 4
            files[#files + 1] = (folder:gsub("^/", "")) .. leaf
            if #files > count then return refuse("its list names more files than it holds") end
        end
    end
    if #files ~= count then return refuse("its list of files does not match its count") end
    table.sort(files)
    -- Names this content: the index, the size, and the data itself (all of a small pak, pieces of a large one).
    local pieces = { index_hash, tostring(size) }
    if index_offset <= SAMPLE * SAMPLES then
        file:seek("set", 0)
        pieces[#pieces + 1] = file:read(index_offset) or ""
    else
        for i = 0, SAMPLES - 1 do
            file:seek("set", (index_offset - SAMPLE) * i // (SAMPLES - 1))
            pieces[#pieces + 1] = file:read(SAMPLE) or ""
        end
    end
    file:close()
    return { size = size, mount_point = mount, files = files, mark = hex(pakfile.sha1(table.concat(pieces))):sub(1, 12) }
end

return pakfile
