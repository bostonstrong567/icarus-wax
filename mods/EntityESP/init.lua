-- Entity ESP: pick kinds of creature and they are outlined through walls, with a tag over each one.

local settings = storage.Load("settings", {
    on = true, all = false, kinds = {}, nearby_only = true,
    color = "#ff7a00", fill = true, fill_color = "#ffd60a", strength = 0.3, width = 1,
    names = true, level = true, health = false, distance = false, range = 120,
    players = false, player_color = "#3fa9ff", player_names = true,
})
local function save() storage.Save("settings", settings) end

local creature_look = game.Highlight:Look({ Color = settings.color, Fill = settings.fill, FillColor = settings.fill_color })
local player_look = game.Highlight:Look({ Color = settings.player_color, Fill = settings.fill })
game.Highlight:Configure({ Fill = settings.strength, Width = settings.width })

local shown = {}        -- creature -> { mark, tag }
local watching = {}     -- kind -> the watch that outlines it
local player_watch = nil
local status

local function wants_tags() return settings.names or settings.level or settings.health or settings.distance end

local function tag_text(creature, me)
    local facts = game.Creatures:Describe(creature)
    local parts = {}
    if settings.names then parts[#parts + 1] = facts.DisplayName end
    if settings.level and facts.Level then parts[#parts + 1] = "Lv " .. facts.Level end
    if settings.health and facts.Health then parts[#parts + 1] = facts.Health .. "/" .. facts.MaxHealth end
    if settings.distance and me then
        local at = facts.Position
        parts[#parts + 1] = ("%.0f m"):format(math.sqrt((at.X - me.X) ^ 2 + (at.Y - me.Y) ^ 2 + (at.Z - me.Z) ^ 2) / 100)
    end
    return table.concat(parts, "  ")
end

local function my_position()
    local me = game.Character
    return me and me:K2_GetActorLocation() or nil
end

-- Gives one outlined creature its tag, or takes it away, to match the settings.
local function fit_tag(creature, entry)
    if wants_tags() and not entry.tag then
        entry.tag = ui.Tag(creature, { text = tag_text(creature, my_position()), within = settings.range })
    elseif not wants_tags() and entry.tag then
        entry.tag:Remove()
        entry.tag = nil
    end
end

local ALL = "*"

local function watch(kind)
    if watching[kind] then return end
    watching[kind] = game.Creatures:Observe(kind ~= ALL and kind or nil, function(creature)
        local entry = { mark = game.Highlight:Add(creature, creature_look) }
        shown[creature] = entry
        fit_tag(creature, entry)
        return function()
            shown[creature] = nil
            entry.mark:Remove()
            if entry.tag then entry.tag:Remove() end
        end
    end)
end

local function unwatch(kind)
    if watching[kind] then
        watching[kind]:Disconnect()
        watching[kind] = nil
    end
end

local function watch_players()
    if player_watch or not (settings.on and settings.players) then return end
    player_watch = game.Players:ObserveCharacters(function(character)
        if game.Players:IsLocal(character) then return end
        local mark = game.Highlight:Add(character, player_look)
        local tag = settings.player_names and ui.Tag(character, {
            text = game.Players:GetName(character) or "Player", within = 400, color = settings.player_color,
        }) or nil
        return function()
            mark:Remove()
            if tag then tag:Remove() end
        end
    end)
end

local function unwatch_players()
    if player_watch then
        player_watch:Disconnect()
        player_watch = nil
    end
end

local function wanted(kind)
    if not settings.on then return false end
    if settings.all then return kind == ALL end
    return settings.kinds[kind] == true
end

local function apply()
    for kind in pairs(watching) do
        if not wanted(kind) then unwatch(kind) end
    end
    if wanted(ALL) then watch(ALL) end
    for kind in pairs(settings.kinds) do
        if wanted(kind) then watch(kind) end
    end
    unwatch_players()
    watch_players()
end

local function count(list)
    local n = 0
    for _ in pairs(list) do n = n + 1 end
    return n
end

local window = ui.Window({ title = "Entity ESP", icon = "scan-eye", nav = "top", width = 400, height = 520, x = 760, y = 110 })
status = window:StatusBar("")

local creatures_page = window:Page("Creatures", { icon = "paw-print" })
local rows = {}         -- kind name -> { toggle, title, label, visible }
local search = ""

local function show_status()
    local outlined = count(shown)
    local creatures = outlined == 1 and "creature" or "creatures"
    if not settings.on then return status:Set("Switched off", { icon = "scan-eye" }) end
    if settings.all then return status:Set(("All kinds, %d %s outlined"):format(outlined, creatures), { icon = "scan-eye" }) end
    local picked = count(watching)
    status:Set(("%d %s picked, %d %s outlined"):format(picked, picked == 1 and "kind" or "kinds", outlined, creatures),
        { icon = "scan-eye" })
end

-- Shows the rows that fit the search, with how many of each kind are here now.
local function refresh_list()
    local needle = search:lower()
    for _, kind in ipairs(game.Creatures:GetKinds()) do
        local row = rows[kind.Name]
        if row then
            local label = kind.Count > 0 and ("%s  (%d)"):format(row.title, kind.Count) or row.title
            if label ~= row.label then
                row.label = label
                row.toggle:SetCaption(label)
            end
            local matches = needle == "" or row.title:lower():find(needle, 1, true) or kind.Name:lower():find(needle, 1, true)
            local visible = matches and (needle ~= "" or not settings.nearby_only or kind.Count > 0 or settings.kinds[kind.Name] == true)
            visible = visible and true or false
            if visible ~= row.visible then
                row.visible = visible
                row.toggle:SetVisible(visible)
            end
        end
    end
    show_status()
end

local nearby_toggle
creatures_page:Toggle("Outline creatures", settings.on, function(on)
    settings.on = on
    save()
    apply()
    show_status()
end)
creatures_page:Toggle("All kinds", settings.all, function(on)
    settings.all = on
    save()
    apply()
    for _, row in pairs(rows) do row.toggle:SetEnabled(not on) end
    nearby_toggle:SetEnabled(not on)
    show_status()
end)
creatures_page:Separator()
local tools = creatures_page:Row()
tools:Input(nil, { hint = "Search: wolf, bear, deer ..." }).Typed:Connect(function(text)
    search = text
    refresh_list()
end)
local function pick_listed(on)
    for name, row in pairs(rows) do
        if row.visible or not on then
            settings.kinds[name] = on or nil
            row.toggle:Set(on, true)
        end
    end
    save()
    apply()
    refresh_list()
end
tools:Button(nil, function() pick_listed(true) end, { icon = "check-check", stretch = false })
tools:Button(nil, function() pick_listed(false) end, { icon = "x", stretch = false })
nearby_toggle = creatures_page:Toggle("Only list kinds that are here now", settings.nearby_only, function(on)
    settings.nearby_only = on
    save()
    refresh_list()
end)
nearby_toggle:SetEnabled(not settings.all)

-- One row per kind, made a few per frame so opening the game does not stall.
task.spawn(function()
    local kinds = game.Creatures:GetKinds()
    local same_title = {}
    for _, kind in ipairs(kinds) do same_title[kind.DisplayName] = (same_title[kind.DisplayName] or 0) + 1 end
    for _, kind in ipairs(kinds) do
        kind.Title = same_title[kind.DisplayName] > 1 and ("%s [%s]"):format(kind.DisplayName, kind.Name) or kind.DisplayName
    end
    table.sort(kinds, function(a, b) return a.Title:lower() < b.Title:lower() end)
    for index, kind in ipairs(kinds) do
        local name = kind.Name
        local toggle = creatures_page:Toggle(kind.Title, settings.kinds[name] == true, function(on)
            settings.kinds[name] = on or nil
            save()
            apply()
            show_status()
        end)
        toggle:SetVisible(false)
        if settings.all then toggle:SetEnabled(false) end
        rows[name] = { toggle = toggle, title = kind.Title, label = kind.Title, visible = false }
        if index % 12 == 0 then
            refresh_list()
            task.wait()
        end
    end
    refresh_list()
end)

local look_page = window:Page("Look", { icon = "palette" })
look_page:Color("Outline colour", settings.color, function(color)
    settings.color = color
    creature_look:Set({ Color = color })
end).Released:Connect(save)
look_page:Toggle("Fill the model", settings.fill, function(on)
    settings.fill = on
    save()
    creature_look:Set({ Fill = on })
    player_look:Set({ Fill = on })
end)
look_page:Color("Fill colour", settings.fill_color, function(color)
    settings.fill_color = color
    creature_look:Set({ FillColor = color })
end).Released:Connect(save)
look_page:Slider("Fill strength", { min = 0, max = 1, value = settings.strength, step = 0.05 }, function(value)
    settings.strength = value
    game.Highlight:Configure({ Fill = value })
end).Released:Connect(save)
look_page:Slider("Line width", { min = 1, max = 4, value = settings.width, step = 1 }, function(value)
    settings.width = value
    game.Highlight:Configure({ Width = value })
end).Released:Connect(save)

local tags_section = look_page:Section("Tags over creatures", { collapsible = false })
local function tag_toggle(caption, key)
    tags_section:Toggle(caption, settings[key], function(on)
        settings[key] = on
        save()
        for creature, entry in pairs(shown) do
            fit_tag(creature, entry)
            if entry.tag then entry.tag:Set(tag_text(creature, my_position())) end
        end
    end)
end
tag_toggle("Name", "names")
tag_toggle("Level", "level")
tag_toggle("Health", "health")
tag_toggle("Distance", "distance")
tags_section:Slider("Show tags within (metres)", { min = 20, max = 400, value = settings.range, step = 10 }, function(value)
    settings.range = value
    for _, entry in pairs(shown) do
        if entry.tag then entry.tag:SetRange(value) end
    end
end).Released:Connect(save)

local players_page = window:Page("Players", { icon = "users" })
players_page:Label("Other players in your session. Your own character is left alone.", { dim = true })
players_page:Toggle("Outline other players", settings.players, function(on)
    settings.players = on
    save()
    unwatch_players()
    watch_players()
end)
players_page:Toggle("Show their names", settings.player_names, function(on)
    settings.player_names = on
    save()
    unwatch_players()
    watch_players()
end)
players_page:Color("Player colour", settings.player_color, function(color)
    settings.player_color = color
    player_look:Set({ Color = color })
end).Released:Connect(function()
    save()
    unwatch_players()
    watch_players()
end)

apply()
show_status()

-- Health and distance change all the time, so the tags are rewritten a few at a time. The list follows what is nearby.
task.spawn(function()
    local tick = 0
    while true do
        task.wait(0.25)
        tick = tick + 1
        if settings.health or settings.distance then
            local me, done = my_position(), 0
            for creature, entry in pairs(shown) do
                if entry.tag and done < 25 then
                    entry.tag:Set(tag_text(creature, me))
                    done = done + 1
                end
            end
        end
        if tick % 6 == 0 and ui.IsOpen() and window:IsVisible() then refresh_list() end
    end
end)

game.MapChanged:Connect(function() task.defer(refresh_list) end)
