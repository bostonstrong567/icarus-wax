-- The Browse page of the Wax panel: the mod catalogue, searched and sorted here, a page for each mod, and a button to add it.

local Wax = ...
local scope = Wax.import("core.scope")
local style = Wax.import("gui.style")
local browse = Wax.import("mods.browse")
local tween = Wax.import("gui.tween")

local M = {}

local SORTS = { { "updated", "Recently updated" }, { "new", "Newest" }, { "downloads", "Most downloads" },
    { "votes", "Most liked" }, { "name", "Name" } }
local HAVE = { { "all", "All mods" }, { "new", "Not in my mods" }, { "here", "In my mods" } }
local ANY_CATEGORY, ANY_TAG = "All categories", "Any tag"
local PAGE_SIZE = 30
local TYPING_SECONDS = 0.3
local LOOK_SECONDS = 60
local MAX_TAGS = 40
local PICTURE_HEIGHT, THUMB_HEIGHT = 420, 54

local v = nil

local function labels(list)
    local out = {}
    for index, entry in ipairs(list) do out[index] = entry[2] end
    return out
end

local function key_of(list, label)
    for _, entry in ipairs(list) do
        if entry[2] == label then return entry[1] end
    end
    return list[1][1]
end

local function label_of(list, key)
    for _, entry in ipairs(list) do
        if entry[1] == key then return entry[2] end
    end
    return list[1][2]
end

local function in_core_scope(fn)
    local previous = scope.enter(nil)
    local ok, err = pcall(fn)
    scope.leave(previous)
    if not ok then error(err, 0) end
end

local function showing()
    local window = v and v.window
    return window and not window.destroyed and window:IsShowing() and window.page == v.page
end

local function ago(seconds)
    if seconds < 90 then return "a moment ago" end
    if seconds < 5400 then return ("%d minutes ago"):format(math.floor(seconds / 60 + 0.5)) end
    return ("%d hours ago"):format(math.floor(seconds / 3600 + 0.5))
end

local function size_text(bytes)
    if bytes >= 1024 * 1024 then return ("%.1f MB"):format(bytes / 1048576) end
    return ("%d KB"):format(math.max(1, math.floor(bytes / 1024 + 0.5)))
end

local function note_text(state, shown, fitting)
    if state.loading and state.count == 0 then return "Reading the catalogue ..." end
    local parts = {}
    if fitting == state.count then parts[1] = ("%d mods."):format(state.count)
    else parts[1] = ("%d of %d mods fit."):format(fitting, state.count) end
    if shown < fitting then parts[#parts + 1] = ("Showing the first %d."):format(shown) end
    if state.loading then parts[#parts + 1] = "Reading the catalogue ..."
    elseif state.age then parts[#parts + 1] = "Read " .. ago(state.age) .. "."
    elseif state.kept_from and state.kept_from > 0 then parts[#parts + 1] = "This is the list from the last time." end
    if state.problem then parts[#parts + 1] = state.problem end
    return table.concat(parts, " ")
end

-- how a mod stands here, as the word in the pill on its card and the colour of it
local STANDING = { here = { "In your mods", "good" }, update = { "Update ready", "accent" }, adding = { "Downloading", "accent" },
    older = { "Needs newer Wax", "bad" } }

local function standing_word(standing)
    local found = STANDING[standing]
    if not found then return nil, nil end
    return found[1], style.theme[found[2]]
end

local function byline(entry)
    local parts = { entry.version }
    if entry.author ~= "" then parts[#parts + 1] = "by " .. entry.author end
    if entry.category ~= "" then parts[#parts + 1] = entry.category end
    return table.concat(parts, "  ")
end

-- The numbers and needs of a mod, as lines of a card or of its page.
local function facts(box, entry, standing)
    if #entry.tags > 0 then box:Field("Tags", table.concat(entry.tags, ", ")) end
    if entry.updated ~= "" then box:Field("Updated", entry.updated:sub(1, 10)) end
    if entry.size > 0 then box:Field("Size", ("%s in %d files"):format(size_text(entry.size), entry.files)) end
    if #entry.needs > 0 then
        local missing = {}
        for _, other in ipairs(entry.needs) do
            if not Wax.mods.get(other) then missing[#missing + 1] = other end
        end
        box:Field("Needs the mods", table.concat(entry.needs, ", "))
        if #missing > 0 then
            box:Label("Not in your mods yet: " .. table.concat(missing, ", ") .. ". Add those as well.",
                { color = style.theme.warn, size = style.theme.small_size })
        end
    end
    if entry.needs_wax ~= "" then
        local field = box:Field("Needs Wax", entry.needs_wax .. " or newer")
        if standing == "older" then field:SetColor(style.theme.bad) end
    end
end

-- What can be done with a mod: add it (asked about first), update it, or a line that says how it stands.
local function actions(box, entry, standing, detail, view)
    local tools = box:Row()
    if view then
        tools:Button("View", function()
            v.detail, v.picture, v.dirty = entry.id, 1, true
        end, { icon = "image", stretch = false })
    end
    if standing == "new" then
        local ask
        tools:Button("Add to game", function() ask.control:SetVisible(true) end, { icon = "download", stretch = false })
        ask = box:Row()
        ask:Label(("Add %s %s%s from the Wax catalogue? A mod is code that runs in the game. It stays switched off until you switch it on."):format(
            entry.name, entry.version, entry.author ~= "" and (" by " .. entry.author) or ""), { color = style.theme.warn })
        ask:Button("Add", function()
            local started, why = browse.add(entry.id)
            if not started then Wax.ui.Notify(tostring(why), { title = "Could not add " .. entry.name, kind = "bad" }) end
        end, { icon = "download", stretch = false })
        ask:Button("Cancel", function() ask.control:SetVisible(false) end, { stretch = false })
        ask.control:SetVisible(false)
    elseif standing == "adding" then
        tools:Label("Downloading and checking its files ...", { dim = true })
    elseif standing == "update" then
        tools:Button(("Update to %s"):format(detail), function() Wax.update.install(entry.id) end, { icon = "download", stretch = false })
    elseif standing == "older" then
        tools:Label(("It needs Wax %s or newer. Update Wax first."):format(detail), { color = style.theme.warn, size = style.theme.small_size })
    else
        tools:Label("It is in your mods. Switch it on or off on the Mods page.", { dim = true })
    end
    return tools
end

-- A mod in the list: a card to press, with its first picture faded behind it. Pressing it opens the mod's own page.
-- Pressing the vote you already cast takes it back.
local function cast(entry, vote)
    local started, why = browse.vote(entry.id, browse.my_vote(entry.id) == vote and 0 or vote)
    if not started then Wax.ui.Notify(tostring(why), { title = "Could not vote", kind = "bad" }) end
end

local function card(entry)
    local standing = browse.standing(entry.id)
    local mine = browse.my_vote(entry.id)
    local word, tone = standing_word(standing)
    local note = entry.version .. (entry.author ~= "" and ("  by " .. entry.author) or "")
    local tile = v.page:Tile({ title = entry.name, note = note, text = entry.summary, badge = word, badge_color = tone,
        marks = { { icon = "download", text = entry.downloads },
            { icon = "thumbs-up", text = entry.up, active = mine == 1, color = style.theme.good, on_click = function() cast(entry, 1) end },
            { icon = "thumbs-down", text = entry.down, active = mine == -1, color = style.theme.bad, on_click = function() cast(entry, -1) end } },
        on_click = function() v.detail, v.picture, v.dirty = entry.id, 1, true end })
    if entry.pictures > 0 then v.tiles[#v.tiles + 1] = { id = entry.id, tile = tile } end
    return { control = tile, id = entry.id, tile = tile, downloads = entry.downloads, up = entry.up, down = entry.down, mine = mine }
end

-- Counts and the player's own vote are written onto what is already there, so a vote moves nothing.
local function sync_counts()
    for _, row in ipairs(v.rows) do
        local entry = row.tile and browse.get(row.id)
        if entry and not row.tile.destroyed then
            local mine = browse.my_vote(entry.id)
            if row.downloads ~= entry.downloads then row.tile:SetMark(1, entry.downloads, false) end
            if row.up ~= entry.up or row.mine ~= mine then row.tile:SetMark(2, entry.up, mine == 1) end
            if row.down ~= entry.down or row.mine ~= mine then row.tile:SetMark(3, entry.down, mine == -1) end
            row.downloads, row.up, row.down, row.mine = entry.downloads, entry.up, entry.down, mine
        end
    end
    local parts = v.parts
    local entry = parts and parts.like and browse.get(parts.id)
    if entry and not parts.like.destroyed then
        local mine = browse.my_vote(entry.id)
        if parts.up ~= entry.up or parts.down ~= entry.down or parts.mine ~= mine or parts.downloads ~= entry.downloads then
            parts.loads:Set(entry.downloads)
            parts.like:SetCaption(tostring(entry.up))
            parts.like:SetActive(mine == 1)
            parts.like:SetTip(mine == 1 and "Take your like back" or "Like this mod")
            parts.dislike:SetCaption(tostring(entry.down))
            parts.dislike:SetActive(mine == -1)
            parts.dislike:SetTip(mine == -1 and "Take your dislike back" or "Dislike this mod")
            parts.up, parts.down, parts.mine, parts.downloads = entry.up, entry.down, mine, entry.downloads
        end
    end
end

-- The first picture of each mod in the list is put behind its card when it has arrived, a few a frame.
local function fill_tiles()
    local left = {}
    for index, waiting in ipairs(v.tiles) do
        local path, why = nil, "later"
        if index <= 3 then path, why = browse.picture(waiting.id, 1) end
        if path then
            if not waiting.tile.destroyed then waiting.tile:SetPicture(path) end
        elseif why ~= "none" then
            left[#left + 1] = waiting
        end
    end
    v.tiles = left
end

local function keep(control) v.rows[#v.rows + 1] = { control = control.control or control } end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- "2026-10-08T05:31:14.000Z" as "Oct 8, 2026".
local function day(stamp)
    local year, month, date = stamp:match("^(%d+)-(%d+)-(%d+)")
    if not year then return "" end
    return ("%s %d, %s"):format(MONTHS[tonumber(month)] or month, tonumber(date), year)
end

-- Shows picture n large and marks its small copy.
local function choose_picture(number)
    local parts = v.parts
    if not parts then return end
    v.picture = number
    local path = browse.picture(parts.id, number)
    if path and parts.shown ~= path and not parts.large.destroyed then
        parts.large:Set(path)
        parts.shown = path
    end
    for index, small in ipairs(parts.small) do
        if not small.destroyed then small:SetSelected(index == number) end
    end
end

-- Pictures arrive one by one: each is put on its small copy when it is there, one a frame, without building the page again.
local function fill_pictures()
    local parts = v.parts
    if not parts or parts.waiting == 0 then return end
    for index, small in ipairs(parts.small) do
        if not parts.filled[index] then
            local path, why = browse.picture(parts.id, index)
            if path then
                if not small.destroyed then small:Set(path) end
                parts.filled[index] = true
                parts.waiting = parts.waiting - 1
                if index == v.picture then choose_picture(index) end
                break
            elseif why == "none" then
                parts.filled[index] = true
                parts.waiting = parts.waiting - 1
            end
        end
    end
    if parts.waiting == 0 and parts.note and not parts.note.destroyed then parts.note:SetVisible(false) end
end

-- What the mod says about itself arrives after the page is up, and is written into the card that waits for it.
local function fill_about()
    local parts = v.parts
    if not parts or parts.told or not parts.about then return end
    local more = browse.detail(parts.id)
    if not more then return end
    parts.told = true
    if parts.about.control.destroyed or more.description == "" or more.description == parts.summary then return end
    in_core_scope(function()
        for paragraph in more.description:gmatch("[^\r\n]+") do
            local text = paragraph:gsub("^#+%s*", ""):gsub("%*%*", ""):gsub("`", "")
            if text:match("%S") then parts.about:Label(text) end
        end
    end)
    parts.about.control:SetVisible(true)
end

local detail_rest

-- One mod on a page of its own, laid out as on the site: title, facts, the large picture, its small copies, the text.
local function detail_view(entry)
    local page = v.page
    local standing, detail = browse.standing(entry.id)
    local top = page:Row()
    top:Button("All mods", function() v.detail, v.dirty = nil, true end, { icon = "arrow-left", stretch = false })
    keep(top)

    local head = page:Flow()
    head:Title(entry.name)
    head:Label(entry.version, { dim = true })
    if entry.needs_wax ~= "" then
        head:Badge("Needs Wax " .. entry.needs_wax, { color = standing == "older" and style.theme.bad or style.theme.dim })
    end
    local word, tone = standing_word(standing)
    if word then head:Badge(word, { color = tone }) end
    keep(head)

    local line = page:Flow()
    if entry.author ~= "" then line:Stat("Author", entry.author) end
    if entry.category ~= "" then line:Stat("Category", entry.category) end
    if entry.updated ~= "" then line:Stat("Updated", day(entry.updated)) end
    if entry.created ~= "" then line:Stat("First published", day(entry.created)) end
    line:Stat("Id", entry.id)
    keep(line)
    local counts = page:Flow()
    local mine = browse.my_vote(entry.id)
    local loads = counts:Count("download", entry.downloads)
    local like = counts:Button(tostring(entry.up), function() cast(entry, 1) end, { icon = "thumbs-up", stretch = false, bare = true, active_color = style.theme.good,
        tip = mine == 1 and "Take your like back" or "Like this mod" })
    like:SetActive(mine == 1)
    local dislike = counts:Button(tostring(entry.down), function() cast(entry, -1) end, { icon = "thumbs-down", stretch = false, bare = true, active_color = style.theme.bad,
        tip = mine == -1 and "Take your dislike back" or "Dislike this mod" })
    dislike:SetActive(mine == -1)
    keep(counts)

    local parts = { id = entry.id, summary = entry.summary, small = {}, filled = {}, waiting = 0, loads = loads, like = like,
        dislike = dislike, up = entry.up, down = entry.down, mine = mine, downloads = entry.downloads }
    v.parts = parts
    if entry.pictures > 0 then
        v.picture = math.max(1, math.min(v.picture or 1, entry.pictures))
        parts.waiting = entry.pictures
        parts.large = page:Picture(nil, { height = PICTURE_HEIGHT })
        keep(parts.large)
        parts.note = page:Label("Getting the pictures ...", { dim = true })
        keep(parts.note)
    end
    -- the top of the page is up in this frame. What is under it is made in the next, so no frame does it all
    v.later = function() detail_rest(entry, parts, standing, detail) end
end

-- The part of a mod's page under its large picture.
function detail_rest(entry, parts, standing, detail)
    local page = v.page
    if entry.pictures > 1 then
        local strip = page:Flow()
        for index = 1, entry.pictures do
            parts.small[index] = strip:Picture(nil, { height = THUMB_HEIGHT, selected = index == v.picture,
                on_click = function() choose_picture(index) end })
        end
        keep(strip)
    elseif entry.pictures == 1 then
        parts.small[1] = parts.large
    end
    if entry.summary ~= "" then keep(page:Label(entry.summary)) end
    parts.about = page:Section("About", { open = true })
    parts.about.control:SetVisible(false)
    keep(parts.about)
    if #entry.tags > 0 then
        local tags = page:Flow()
        for _, tag in ipairs(entry.tags) do tags:Badge(tag) end
        keep(tags)
    end
    local extra = {}
    if entry.size > 0 then extra[#extra + 1] = { "Size", ("%s in %d files"):format(size_text(entry.size), entry.files) } end
    if #entry.needs > 0 then extra[#extra + 1] = { "Needs the mods", table.concat(entry.needs, ", ") } end
    if #extra > 0 then
        local numbers = page:Flow()
        for _, pair in ipairs(extra) do numbers:Stat(pair[1], pair[2]) end
        keep(numbers)
    end
    local last = page:Section("Get it", { collapsible = false })
    actions(last, entry, standing, detail, false)
    keep(last)
end

local function list_view(list, categories, tags)
    local page = v.page
    local filters = page:Row()
    local category_choices, tag_choices = { ANY_CATEGORY }, { ANY_TAG }
    for _, name in ipairs(categories) do category_choices[#category_choices + 1] = name end
    for index, name in ipairs(tags) do
        if index <= MAX_TAGS then tag_choices[#tag_choices + 1] = name end
    end
    filters:Dropdown(nil, category_choices, v.query.category or ANY_CATEGORY, function(choice)
        v.query.category = choice ~= ANY_CATEGORY and choice or nil
        v.shown, v.dirty = PAGE_SIZE, true
    end)
    filters:Dropdown(nil, tag_choices, v.query.tag or ANY_TAG, function(choice)
        v.query.tag = choice ~= ANY_TAG and choice or nil
        v.shown, v.dirty = PAGE_SIZE, true
    end)
    keep(filters)
    local second = page:Row()
    second:Dropdown(nil, labels(SORTS), label_of(SORTS, v.query.sort), function(choice)
        v.query.sort = key_of(SORTS, choice)
        v.dirty = true
    end)
    second:Dropdown(nil, labels(HAVE), label_of(HAVE, v.query.have), function(choice)
        v.query.have = key_of(HAVE, choice)
        v.shown, v.dirty = PAGE_SIZE, true
    end)
    keep(second)
    for index, entry in ipairs(list) do
        if index > v.shown then break end
        v.rows[#v.rows + 1] = card(entry)
    end
    if #list > v.shown then
        local more = page:Row()
        more:Button(("Show %d more"):format(math.min(PAGE_SIZE, #list - v.shown)), function()
            v.shown, v.dirty = v.shown + PAGE_SIZE, true
        end, { stretch = false })
        keep(more)
    end
    if #list == 0 and browse.state().count > 0 then
        keep(page:Label("No mod fits. Try fewer words, or another category or tag.", { dim = true }))
    end
end

local function rebuild(list, categories, tags)
    for _, row in ipairs(v.rows) do
        if row.section and row.section:IsOpen() ~= row.built_open then v.open[row.id] = row.section:IsOpen() end
        row.control:Destroy()
    end
    v.rows, v.tiles, v.parts, v.later = {}, {}, nil, nil
    local entry = v.detail and browse.get(v.detail)
    for _, control in ipairs(v.header or {}) do
        if not control.destroyed then control:SetVisible(entry == nil) end
    end
    in_core_scope(function()
        if entry then detail_view(entry) else list_view(list, categories, tags) end
    end)
    local kind = entry and entry.id or ""
    local holder = v.page.holder
    if kind ~= v.kind and holder then
        v.kind = kind
        if v.turn then v.turn.cancel() end
        v.turn = tween.run(style.theme.animation, function(progress)
            holder:SetRenderOpacity(progress)
            holder:SetRenderTranslation({ X = 0, Y = (1 - progress) * 6 })
        end, nil, nil, v.page)
    end
end

-- What the page would say: it is built again only when this changes.
local function signature(list, categories, tags)
    local entry = v.detail and browse.get(v.detail)
    if entry then
        local standing, detail = browse.standing(entry.id)
        return table.concat({ "mod", entry.id, entry.version, standing, tostring(detail), entry.pictures }, "|")
    end
    local parts = { table.concat(categories, ","), table.concat(tags, ","), v.query.sort, v.query.have, tostring(v.query.category),
        tostring(v.query.tag), tostring(v.shown) }
    for index, mod in ipairs(list) do
        if index > v.shown + 1 then break end
        local standing, detail = browse.standing(mod.id)
        parts[#parts + 1] = mod.id .. ":" .. mod.version .. ":" .. standing .. ":" .. tostring(detail)
    end
    return table.concat(parts, "|")
end

local function refresh_view()
    local state = browse.state()
    local categories, tags = browse.facets()
    -- a category or tag that no listed mod has any more is let go of
    local function known(name, names)
        for _, other in ipairs(names) do
            if other == name then return true end
        end
        return false
    end
    if v.query.category and not known(v.query.category, categories) then v.query.category = nil end
    if v.query.tag and not known(v.query.tag, tags) then v.query.tag = nil end
    if v.detail and not browse.get(v.detail) then v.detail = nil end
    local list = browse.find(v.query)
    local now = signature(list, categories, tags)
    if now ~= v.signature then
        v.signature = now
        local started = Wax.perf.now()
        rebuild(list, categories, tags)
        v.built_ms = (Wax.perf.now() - started) * 1000
    end
    sync_counts()
    local text = note_text(state, math.min(#list, v.shown), #list)
    if text ~= v.note_text then
        v.note_text = text
        v.note:Set(text)
    end
end

function M.build(page, window)
    v = { page = page, window = window, rows = {}, tiles = {}, open = {}, shown = PAGE_SIZE, dirty = true, typed_at = nil, looked_at = -LOOK_SECONDS,
        query = { text = "", category = nil, tag = nil, sort = "updated", have = "all" } }
    local title = page:Title("Browse", "Mods from the Wax catalogue. The catalogue is asked when you open this page. A mod you add stays switched off until you switch it on.")
    local tools = page:Row()
    tools:Input(nil, { hint = "Search: a name, an author, a tag ...", clear = true }).Typed:Connect(function(text)
        v.pending_text, v.typed_at = text, os.clock()
    end)
    tools:Button(nil, function() browse.refresh(true) end, { icon = "refresh-cw", spin = true })
    v.note = page:Label("", { dim = true })
    -- what belongs to the list and is put away while one mod's own page shows
    v.header = { title, tools.control, v.note }
    browse.Changed:Connect(function()
        if v then v.dirty = true end
    end)
    -- "Browse" pressed while a mod's own page shows: back to the list
    if page.PressedAgain then
        page.PressedAgain:Connect(function()
            if v and v.detail then v.detail, v.dirty = nil, true end
        end)
    end
    local update = Wax.update
    if update and update.Changed then
        update.Changed:Connect(function()
            if v then v.dirty = true end
        end)
    end
end

function M.step()
    if not v or not showing() then return end
    local now = os.clock()
    -- the catalogue is asked when the page is looked at, and again while it stays open
    if now - v.looked_at > LOOK_SECONDS then
        v.looked_at = now
        browse.refresh(false)
        v.dirty = true
    end
    if v.typed_at and now - v.typed_at >= TYPING_SECONDS then
        v.query.text, v.typed_at = v.pending_text or "", nil
        v.detail = nil
        v.shown, v.dirty = PAGE_SIZE, true
    end
    if v.dirty then
        v.dirty = false
        refresh_view()
    end
    if v.later then
        local rest = v.later
        v.later = nil
        in_core_scope(rest)
    elseif v.detail then
        fill_pictures()
        fill_about()
    elseif #v.tiles > 0 then
        fill_tiles()
    end
end

-- Shows one mod's own page, as its View button does.
function M.open(id)
    if not v or not browse.get(id) then return false end
    v.detail, v.picture, v.dirty = id, 1, true
    return true
end

-- How long the page last took to build, in milliseconds.
function M.stats() return { built_ms = v and v.built_ms or nil } end

function M.stop() v = nil end

return M
