-- Recipes as the lines the right list shows, and how much room a text takes so that none is cut off.

local rows = {}

rows.SHOW_TIMES = true      -- base times: the recipe's work divided by the bench's power, before talents and upgrades
rows.NAME_SHARE = 0.6       -- of a line: where the names end and the counts start
rows.NAME_MOST = 300
rows.SAFETY = 1.05
rows.LINE = 0.94            -- a line of text under a heading wraps this far across its side
rows.MODES = { "make", "used", "here" }

local PAD, INDENT, VALUE_GAP, NOTE_GAP = 26, 12, 10, 8
local GAPS = VALUE_GAP + NOTE_GAP
local FONT, SMALL, MONO = 11, 10, 8
local DOTS = "..."

-- Widths of the interface font at size 11, measured on pictures of the game at 1440p.
local WIDTHS = {}
for byte = 0, 255 do WIDTHS[byte] = 9.5 end
for byte = 97, 122 do WIDTHS[byte] = 8.1 end
for byte = 65, 90 do WIDTHS[byte] = 9.9 end
for byte = 48, 57 do WIDTHS[byte] = 8.6 end
for char in ("iljI'.,:;!| "):gmatch(".") do WIDTHS[char:byte()] = 3.9 end
for char in ('tfr-()/"'):gmatch(".") do WIDTHS[char:byte()] = 5.6 end
for char in ("mw"):gmatch(".") do WIDTHS[char:byte()] = 12.2 end
for char in ("MW"):gmatch(".") do WIDTHS[char:byte()] = 12.8 end
for byte = 128, 191 do WIDTHS[byte] = 0 end
for byte = 192, 223 do WIDTHS[byte] = 8.8 end
for byte = 224, 255 do WIDTHS[byte] = 14.7 end

local measured, measured_count = {}, 0

-- How wide a text draws, in the interface's own units. size 11 when left out.
function rows.measure(text, size)
    local total = measured[text]
    if not total then
        total = 0
        for position = 1, #text do total = total + WIDTHS[text:byte(position)] end
        if measured_count > 20000 then measured, measured_count = {}, 0 end
        measured[text], measured_count = total, measured_count + 1
    end
    return total * (size or FONT) / FONT
end

local measure = rows.measure

local function fits(text, room, size)
    return measure(text, size) * rows.SAFETY + 2 <= room
end

-- Where each letter of a text starts. A letter of another alphabet is several bytes.
local function letters(text)
    local starts = {}
    for position = 1, #text do
        local byte = text:byte(position)
        if byte < 128 or byte > 191 then starts[#starts + 1] = position end
    end
    return starts
end

-- The text, or its start with three dots when it does not fit.
function rows.shorten(text, room, size)
    if fits(text, room, size) then return text end
    local starts = letters(text)
    for count = #starts - 1, 1, -1 do
        local cut = text:sub(1, starts[count + 1] - 1):gsub("[ %-,]+$", "") .. DOTS
        if fits(cut, room, size) then return cut end
    end
    return DOTS
end

local function split_long(word, room, size, out)
    local starts, from = letters(word), 1
    for count = 1, #starts do
        local upto = (starts[count + 1] or (#word + 1)) - 1
        if count > from and not fits(word:sub(starts[from], upto), room, size) then
            out[#out + 1] = word:sub(starts[from], starts[count] - 1)
            from = count
        end
    end
    return word:sub(starts[from] or 1)
end

-- The text as lines that each fit, broken between words.
function rows.wrap(text, room, size)
    if fits(text, room, size) then return { text } end
    local out, line = {}, ""
    for word in text:gmatch("[^ ]+") do
        local longer = line == "" and word or (line .. " " .. word)
        if fits(longer, room, size) then
            line = longer
        else
            if line ~= "" then out[#out + 1] = line end
            line = fits(word, room, size) and word or split_long(word, room, size, out)
        end
    end
    if line ~= "" or #out == 0 then out[#out + 1] = line end
    return out
end

local function split(text, separator)
    local parts, from = {}, 1
    while true do
        local at, upto = text:find(separator, from, true)
        if not at then break end
        parts[#parts + 1] = text:sub(from, at - 1)
        from = upto + 1
    end
    parts[#parts + 1] = text:sub(from)
    return parts
end

-- Parts joined again, as many to a line as fit. A part too long for a line of its own goes on between words.
local function pack(parts, separator, room, size)
    local out, line = {}, ""
    for _, part in ipairs(parts) do
        local longer = line == "" and part or (line .. separator .. part)
        if fits(longer, room, size) then
            line = longer
        elseif fits(part, room, size) then
            if line ~= "" then out[#out + 1] = line end
            line = part
        else
            local pieces = rows.wrap(longer, room, size)
            for position = 1, #pieces - 1 do out[#out + 1] = pieces[position] end
            line = pieces[#pieces]
        end
    end
    if line ~= "" or #out == 0 then out[#out + 1] = line end
    return out
end

local function column(width)
    return math.min(math.floor((width - PAD) * rows.NAME_SHARE), rows.NAME_MOST)
end

-- parts: text (the mod's texts), format, unlock
function rows.new(parts)
    local text, format, unlock = parts.text, parts.format, parts.unlock
    local separator = text.join("a", "b"):sub(2, -2)
    local self = { MODES = rows.MODES, LINE = rows.LINE, measure = rows.measure, shorten = rows.shorten, wrap = rows.wrap }

    local function ready(m)
        return m ~= nil and m.stage >= 2 and not m.off.recipes
    end
    self.ready = ready

    -- The recipes one mode lists for an item, as recipe numbers in the game's order.
    function self.recipes(m, item, mode, with_hidden)
        if not item or not ready(m) then return {} end
        if mode == "make" then return m.made_by[item.key] or {} end
        local out = {}
        if mode == "used" then
            local all = m.used_in[item.key] or {}
            if with_hidden then return all end
            for _, number in ipairs(all) do
                if not m.recipes[number].hidden_only then out[#out + 1] = number end
            end
            return out
        end
        local seen = {}
        for _, id in ipairs(item.bench or {}) do
            for _, number in ipairs(m.made_at[id] or {}) do
                if not seen[number] then
                    seen[number] = true
                    out[#out + 1] = number
                end
            end
        end
        table.sort(out)
        return out
    end

    function self.counts(m, item, with_hidden)
        local out = {}
        for _, mode in ipairs(rows.MODES) do out[mode] = #self.recipes(m, item, mode, with_hidden) end
        return out
    end

    local function has_sources(m, item)
        return ready(m) and ((item.hints and item.hints[1] ~= nil) or item.workshop == true)
    end

    -- The first mode that has something to show for an item, starting with how it is made.
    function self.first_mode(m, item, with_hidden)
        if not ready(m) or has_sources(m, item) then return "make" end
        local counts = self.counts(m, item, with_hidden)
        for _, mode in ipairs(rows.MODES) do
            if counts[mode] > 0 then return mode end
        end
        return "make"
    end

    -- "Where it comes from": the game's own hints and the Workshop. True when the item has any.
    function self.sources(out, m, item)
        if not has_sources(m, item) then return false end
        out[#out + 1] = { kind = "heading", text = text.right.sources, value = "", note = "" }
        for _, hint in ipairs(item.hints or {}) do out[#out + 1] = { kind = "source", text = hint, indent = 1 } end
        if item.workshop then out[#out + 1] = { kind = "source", text = text.right.workshop, indent = 1 } end
        return true
    end

    function self.message(out, message)
        out[#out + 1] = { kind = "message", text = message, faint = true }
    end

    -- What the list says when a mode has nothing.
    function self.nothing(mode)
        if mode == "used" then return text.right.no_use end
        if mode == "here" then return text.right.nothing_here end
        return text.right.no_recipe
    end

    local function amount_of(m, amount)
        local resource = m.resources[amount.res]
        return resource, text.right.amount(format.litres(amount.units), resource.units)
    end

    -- The stations of a recipe, one for each name: two sets called the same are one station. Each lists the benches
    -- that show, with the time the recipe takes at each (empty while times are off).
    local function stations_of(m, recipe)
        local list, by_name = {}, {}
        for _, id in ipairs(recipe.stations) do
            local set = m.sets[id]
            local name = set.hand and text.right.by_hand or set.name
            local key = set.hand and "" or set.lower
            local station = by_name[key]
            if not station and name ~= "" then
                station = { id = id, name = name, icon = set.icon, hand = set.hand == true, benches = {} }
                by_name[key] = station
                list[#list + 1] = station
            end
            if station then
                if not station.item and set.link and m.items[set.link] then station.item = set.link end
                local count = (set.shown or 0) > 0 and set.shown or #set.benches
                for position = 1, count do
                    local bench = set.benches[position]
                    local item = m.items[bench.item]
                    station.benches[#station.benches + 1] = { item = bench.item, name = item and item.name or bench.item,
                        mw = bench.mw, time = rows.SHOW_TIMES and format.seconds(recipe.mj, bench.mw) or "" }
                end
            end
        end
        return list
    end

    -- One figure when every bench that shows takes the same time, else nothing.
    local function one_time(stations)
        local figure = nil
        for _, station in ipairs(stations) do
            for _, bench in ipairs(station.benches) do
                if figure == nil then figure = bench.time elseif figure ~= bench.time then return "" end
            end
        end
        return figure or ""
    end

    -- One recipe as a view shows it, whatever the view draws it with:
    --   name, item, icon, made   what heads it: the recipe's own title (a drink), else what it makes. made is "x5" or "0.5 L"
    --   inputs, outputs          { kind = "item" | "tag" | "resource", name, icon, count, amount, item, tag, resource }
    --   several, random          more than one thing is made; one of them, picked at random
    --   stations                 { id, name, icon, hand, item, benches = { { item, name, mw, time } } }
    --   station, bench           "Fabricator" or "3 stations"; the item a click on the station goes to
    --   time, needs, level       one figure or ""; what unlock.describe gives, or nil; the expansion's name, or nil
    -- Under "make" a recipe that makes several things is headed by the picked one.
    function self.recipe(m, needs, number, picked, mode)
        local recipe = m.recipes[number]
        if not recipe then return nil end
        local items = m.items
        local card = { number = number, row = recipe.row, mj = recipe.mj, random = recipe.random == true, inputs = {}, outputs = {} }

        for _, input in ipairs(recipe.inputs) do
            local item = items[input.item]
            card.inputs[#card.inputs + 1] = { kind = "item", name = item and item.name or input.item, icon = item and item.icon or nil,
                count = input.count, amount = format.count(input.count), item = item and item.key or nil }
        end
        for _, input in ipairs(recipe.tags_in) do
            local tag = m.tags[input.tag]
            card.inputs[#card.inputs + 1] = { kind = "tag", name = tag and tag.name or input.tag, icon = tag and tag.icon or nil,
                count = input.count, amount = format.count(input.count), tag = input.tag }
        end
        for _, amount in ipairs(recipe.res_in) do
            local resource, shown = amount_of(m, amount)
            card.inputs[#card.inputs + 1] = { kind = "resource", name = resource.name, icon = resource.icon, count = amount.units,
                amount = shown, item = resource.link, resource = resource.key }
        end

        local own = nil
        for _, output in ipairs(recipe.outputs) do
            local item = items[output.item]
            local entry = { kind = "item", name = item and item.name or output.item, icon = item and item.icon or nil,
                count = output.count, amount = format.count(output.count), item = item and item.key or nil }
            card.outputs[#card.outputs + 1] = entry
            if not own and picked and mode == "make" and item and (item.key == picked.key or item.static == picked.key) then own = entry end
        end
        for _, amount in ipairs(recipe.res_out) do
            local resource, shown = amount_of(m, amount)
            card.outputs[#card.outputs + 1] = { kind = "resource", name = resource.name, icon = resource.icon, count = amount.units,
                amount = shown, item = resource.link, resource = resource.key }
        end
        card.several = #card.outputs > 1

        local title = recipe.title and items[recipe.title] or nil
        local first = own or card.outputs[1]
        card.name = title and title.name or (first and first.name) or recipe.row
        card.item = title and title.key or (first and first.item) or nil
        card.icon = title and title.icon or (first and first.icon) or nil
        card.made = ""
        if first and not card.several then
            if first.kind == "resource" then
                card.made = first.amount
            elseif first.count > 1 then
                card.made = text.right.times(first.count)
            end
        end

        card.stations = stations_of(m, recipe)
        card.station = #card.stations == 1 and card.stations[1].name or text.right.stations(#card.stations)
        for _, id in ipairs(recipe.stations) do
            local link = m.sets[id].link
            if link and items[link] then
                card.bench = link
                break
            end
        end
        card.time = one_time(card.stations)
        local line = needs and unlock.describe(needs, m, recipe) or nil
        if line and (line.short ~= "" or line.extra ~= "") then card.needs = line end
        local level = recipe.level and m.levels[recipe.level]
        card.level = level and level.name or nil
        return card
    end

    -- The same recipe as lines of text: a heading, what goes in, what comes out when that is more than one thing, what it needs.
    -- options: internal (the recipe's row name is listed)
    function self.block(out, m, needs, number, picked, mode, options)
        local card = self.recipe(m, needs, number, picked, mode)
        if not card then return end
        local function add(line)
            line.recipe = number
            out[#out + 1] = line
        end
        add({ kind = "heading", text = card.name, value = card.made, note = text.join(card.station, card.time), pick = card.bench })
        for _, input in ipairs(card.inputs) do
            add({ kind = "input", text = input.kind == "tag" and text.right.any(input.name) or input.name, value = input.amount,
                pick = input.item, indent = 1 })
        end
        if card.several then
            if card.random then add({ kind = "label", text = text.right.one_of, faint = true, indent = 1 }) end
            for _, output in ipairs(card.outputs) do
                add({ kind = "output", text = output.name, value = "+" .. output.amount, tone = "good", pick = output.item, indent = 1 })
            end
        end
        if options and options.internal then add({ kind = "row", text = card.row, faint = true, indent = 1 }) end
        if card.needs then add({ kind = "needs", text = card.needs.short, more = card.needs.extra, faint = true, indent = 1 }) end
    end

    -- Every line of a list at once. The window lays long lists out a part at a time with block and flow.
    function self.lines(m, needs, item, mode, options)
        options = options or {}
        local out = {}
        if not ready(m) then return out end
        local numbers = options.numbers or self.recipes(m, item, mode, options.with_hidden)
        if mode == "make" and not options.filtered then self.sources(out, m, item) end
        for _, number in ipairs(numbers) do self.block(out, m, needs, number, item, mode, options) end
        if #out == 0 then self.message(out, options.filtered and text.no_match(options.filtered) or self.nothing(mode)) end
        return out
    end

    local function row_of(line, shown, value, note, name_width, indent)
        return { kind = line.kind, text = shown, value = value, note = note, tone = line.tone, faint = line.faint, indent = indent,
            name_width = math.max(20, math.floor(name_width)), pick = line.pick, recipe = line.recipe }
    end

    -- Lines that hold a text and nothing else: one row for each piece.
    local function plain(out, line, pieces, room, indent, faint)
        for _, piece in ipairs(pieces) do
            local row = row_of(line, piece, "", "", room - GAPS, indent)
            if faint then row.faint, row.tone = true, nil end
            out[#out + 1] = row
        end
    end

    local function flow_line(out, line, width, counts_at)
        local indent = line.indent or 0
        local room = width - PAD - indent * INDENT
        local value, note = line.value or "", line.note or ""
        if line.kind == "needs" then
            local pieces = split(line.text, separator)
            for _, piece in ipairs(split(line.more or "", separator)) do pieces[#pieces + 1] = piece end
            local kept = {}
            for _, piece in ipairs(pieces) do
                if piece ~= "" then kept[#kept + 1] = piece end
            end
            return plain(out, line, pack(kept, separator, room - GAPS, FONT), room, indent)
        end
        if value == "" and note == "" then
            return plain(out, line, rows.wrap(line.text, room - GAPS, FONT), room, indent)
        end

        local value_px = value ~= "" and (#value * MONO + 6) or 0
        local note_px = note ~= "" and (measure(note, SMALL) * rows.SAFETY + 6) or 0
        local name_px = measure(line.text, FONT) * rows.SAFETY + 2
        local box = counts_at - indent * INDENT
        -- the name's box is the column when the name fits it, so counts start at one place down the list
        local function name_box(most)
            if value ~= "" and name_px <= box and box <= most then return box end
            return most
        end
        local most = room - GAPS - value_px - note_px
        if name_px <= most then
            out[#out + 1] = row_of(line, line.text, value, note, name_box(most), indent)
            return
        end
        -- the note goes under the name when both do not fit on one line
        most = room - GAPS - value_px
        local pieces = name_px <= most and { line.text } or rows.wrap(line.text, most, FONT)
        for position, piece in ipairs(pieces) do
            local last = position == #pieces
            out[#out + 1] = row_of(line, piece, last and value or "", "", #pieces == 1 and name_box(most) or most, indent)
        end
        if note ~= "" then
            local under = room - INDENT
            plain(out, line, rows.wrap(note, under - GAPS, FONT), under, indent + 1, true)
        end
    end

    -- Lays lines out for a list that is `width` wide: each row gets the width of its name, and what is too long
    -- for one row goes on to the next. Appends to `out` the rows for lines[from] onwards.
    function self.flow(out, lines, width, from)
        local counts_at = column(width)
        for position = from or 1, #lines do flow_line(out, lines[position], width, counts_at) end
        return out
    end

    -- One line of the item list: the name, and the category beside it when both fit.
    function self.entry(name, note, width)
        local room = width - PAD - GAPS
        note = note or ""
        if note ~= "" then
            local note_px = measure(note, SMALL) * rows.SAFETY + 6
            if measure(name, FONT) * rows.SAFETY + 2 <= room - note_px then return name, note, math.floor(room - note_px) end
        end
        return rows.shorten(name, room, FONT), "", math.floor(room)
    end

    -- A message for a list, as rows that fit it.
    function self.notice(out, message, width)
        local lines = {}
        self.message(lines, message)
        return self.flow(out, lines, width)
    end

    -- The leading parts that fit on one line, joined.
    function self.fit(list, room, size)
        local kept = {}
        for _, part in ipairs(list) do
            if part ~= nil and part ~= "" then kept[#kept + 1] = part end
        end
        while #kept > 1 and not fits(text.join(kept), room, size) do kept[#kept] = nil end
        return rows.shorten(text.join(kept), room, size)
    end

    -- The small line under the picked item's name. options: internal, favourite
    function self.about(m, item, options, room, size)
        options = options or {}
        local level = item.level and m.levels[item.level]
        return self.fit({ options.internal and item.row or "", text.right.stacks(item.stack), format.weight(item.weight),
            level and level.name or "", options.favourite and text.tip.favourite or "" }, room, size)
    end

    -- The small line under the list: how many recipes each mode has, as much of it as fits.
    function self.modes(counts, mode, room, size)
        local all, some = {}, {}
        for _, name in ipairs(rows.MODES) do
            local shown = text.right.mode(name, counts[name] or 0)
            all[#all + 1] = shown
            if (counts[name] or 0) > 0 or name == mode then some[#some + 1] = shown end
        end
        local now = text.right.mode(mode, counts[mode] or 0)
        for _, try in ipairs({ text.join(all), text.join(some), now }) do
            if fits(try, room, size) then return try end
        end
        return rows.shorten(now, room, size)
    end

    -- "42 of 2,668 items", or that nothing matches, with a long search text shortened.
    function self.count(shown, total, query, room, size)
        local line = text.left.count(shown, total, query)
        if fits(line, room, size) or not query or query == "" then return line end
        local around = measure(text.left.count(shown, total, "?"), size) * rows.SAFETY + 2
        return text.left.count(shown, total, rows.shorten(query, math.max(20, room - around), size))
    end

    return self
end

return rows
