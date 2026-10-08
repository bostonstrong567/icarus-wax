-- The in-game debug panel: mods, log, performance and settings, plus pages other mods add

local Wax = ...
local ui = Wax.import("gui.init")
local style = Wax.import("gui.style")
local log = Wax.import("core.log")
local perf = Wax.import("core.perf")
local scope = Wax.import("core.scope")
local task = Wax.import("core.sched").task
local explorer = Wax.import("gui.explorer")
local root = Wax.import("gui.root")
local kit = Wax.import("gui.kit")
local events = Wax.import("gui.events")
local drag = Wax.import("gui.drag")
local guard = Wax.import("core.guard")

local panel = {}

local V, H, VA = style.Visibility, style.HAlign, style.VAlign
-- the grip of a mod's card: where it sits in the card's title line, and the room it takes at the left of the title
local GRIP = { x = 5, width = 18, height = 25, room = 12, icon = 14 }
local TITLE_PAD = { x = 14, y = 10 }        -- what a card keeps free round its title line: the button's padding and its slot's
local held, sorting, ghost = nil, nil, nil      -- a grip that is down, the card that is being dragged, what is drawn for it

local REFRESH_SECONDS = 0.5
local SCAN_EVERY = 20       -- refreshes between two looks at the mods folder while the Mods page shows
local LEVEL_COLOR = { error = "bad", warn = "warn", info = "text", debug = "dim", trace = "dim" }
local window, mods_page, mods_note, console, opened, status
local mod_rows, mods_signature, mod_filter, scan_tick, log_lines = {}, nil, "", 0, 0
local mods_open = {}        -- mod id -> whether the user left its card open, for this session
local filters = { error = true, warn = true, info = true }
local search, follow = "", true
local log_stamp, last_refresh = nil, 0
local perf_fields, perf_before = {}, nil

local function in_core_scope(fn)
    local previous = scope.enter(nil)
    local ok, err = pcall(fn)
    scope.leave(previous)
    if not ok then error(err, 0) end
end

-- A value as one short line, for showing what a command returned.
local function describe(value, inside)
    local kind = type(value)
    if kind == "string" then
        local text = #value > 300 and value:sub(1, 297) .. "..." or value
        return inside and ("%q"):format(text) or text
    elseif kind ~= "table" then
        local ok, text = pcall(tostring, value)
        return ok and text or "(" .. kind .. ")"
    end
    local meta = getmetatable(value)
    if (meta and meta.__tostring) or inside then
        local ok, text = pcall(tostring, value)
        return ok and (meta and meta.__tostring and text or "{...}") or "{...}"
    end
    local parts, count = {}, 0
    for key, item in pairs(value) do
        count = count + 1
        if count <= 12 then
            parts[count] = (type(key) == "string" and key or "[" .. tostring(key) .. "]") .. " = " .. describe(item, true)
        end
    end
    if count > 12 then parts[13] = ("... %d more"):format(count - 12) end
    return count == 0 and "{}" or "{ " .. table.concat(parts, ", ") .. " }"
end

local command_env, command_scope, history, history_at = nil, nil, {}, 0
local cleared_after = 0     -- log entries up to this one are not shown (the Clear button)

local command_box, log_page, tab_key, step_count, focused_at = nil, nil, nil, 0, -10

-- An icon button that shows a tick once action(flash) has run. action returns false for no tick, or "later" to call flash itself.
local function ticking_button(row, icon, action)
    local button, back = nil, nil
    local function flash(shown)
        if button.destroyed then return end
        button:SetIcon(shown or "check")
        if back then task.cancel(back) end
        back = task.delay(1.4, function()
            back = nil
            if not button.destroyed then button:SetIcon(icon) end
        end)
    end
    button = row:Button(nil, function()
        local result = action(flash)
        if result ~= false and result ~= "later" then flash() end
    end, { icon = icon })
    return button, flash
end

local function command_environment()
    if not command_env then
        command_env = Wax.mods.console_env and Wax.mods.console_env() or setmetatable({}, { __index = _G })
        command_env.clear = function()
            if command_scope then command_scope:destroy() end
            command_scope = nil
        end
    end
    return command_env
end

-- Runs what was typed, as an expression if it is one (its value is shown), else as statements. Then calls done(ok, summary).
local function run_command(text, done)
    if not text:find("%S") then return end
    if history[#history] ~= text then history[#history + 1] = text end
    history_at = #history + 1
    local out = log.channel("console")
    out:info("> %s", text)
    local env = command_environment()
    command_scope = command_scope or scope.new("console")
    local chunk, problem = load("return " .. text, "=console", "t", env)
    if not chunk then chunk, problem = load(text, "=console", "t", env) end
    if not chunk then
        out:error("%s", tostring(problem))
        if done then done(false) end
        return
    end
    -- as a task of its own, so it may wait. What it sets up belongs to the console and is removed by clear().
    local previous = scope.enter(command_scope)
    task.spawn(function()
        local results = table.pack(xpcall(chunk, function(err) return tostring(err) end))
        if not results[1] then
            out:error("%s", tostring(results[2]))
            if done then done(false) end
            return
        end
        local first = nil
        for index = 2, results.n do
            local shown = describe(results[index])
            first = first or shown
            out:info("= %s", shown)
        end
        if done then done(true, first) end
    end)
    scope.leave(previous)
end

-- Returns the sorted names that could finish the last word typed, then the part of it typed so far, then the text before it.
local function candidates(text)
    local path, partial = text:match("([%a_][%w_%.]*)[%.:]([%w_]*)$")
    if not path then partial = text:match("([%a_][%w_]*)$") or "" end
    local head = text:sub(1, #text - #partial)
    local env, names = command_environment(), {}
    local function add(name)
        if type(name) == "string" and name:find("^[%a_][%w_]*$") then names[name] = true end
    end
    if path then
        local value = env
        for part in path:gmatch("[^%.]+") do
            local ok, inner = pcall(function() return value[part] end)
            if not ok or inner == nil then return {}, partial, head end
            value = inner
        end
        if type(value) == "table" then
            local instances = Wax.instance
            if instances and instances.is_instance(value) then
                local ok, members = pcall(value.GetMembers, value)
                for _, name in ipairs(ok and members or {}) do add(name) end
                for name in pairs(instances.Instance) do add(name) end
            else
                pcall(function() for key in pairs(value) do add(key) end end)
                local meta = getmetatable(value)
                if meta and type(meta.__index) == "table" then
                    for key in pairs(meta.__index) do add(key) end
                end
                -- a table that computes its members lists them through __names
                if meta and type(meta.__names) == "function" then
                    for _, name in ipairs(meta.__names()) do add(name) end
                end
            end
        end
    else
        for key in pairs(env) do add(key) end
        for key in pairs(_G) do add(key) end
    end
    -- names with the same capitals first, and if none match, with any capitals
    local found, lower = {}, partial:lower()
    for name in pairs(names) do
        if name:sub(1, #partial) == partial then found[#found + 1] = name end
    end
    if #found == 0 then
        for name in pairs(names) do
            if name:sub(1, #partial):lower() == lower then found[#found + 1] = name end
        end
    end
    table.sort(found)
    return found, partial, head
end

local EVERYDAY = {}
for rank, name in ipairs({ "print", "pairs", "ipairs", "game", "ui", "mods", "task", "exports", "string", "table", "math",
    "tostring", "tonumber", "type", "LocalPlayer", "World", "Character", "Notify", "Window" }) do
    EVERYDAY[name] = rank
end

-- The likeliest of the names that fit: one used in a recent command, then the everyday ones, then the shortest.
local function likeliest(found)
    local used = {}
    for index = #history, math.max(1, #history - 30), -1 do
        for name in history[index]:gmatch("[%a_][%w_]*") do used[name] = used[name] or index end
    end
    local best, best_score = nil, nil
    for _, name in ipairs(found) do
        local score = used[name] and 1e6 + used[name] or (EVERYDAY[name] and 1e5 - EVERYDAY[name] or -#name)
        if not best or score > best_score then best, best_score = name, score end
    end
    return best
end

-- The one name suggested for what is typed (nil until a letter of it has been typed), then all that fit.
local function suggestion(text)
    local found, partial, head = candidates(text)
    if #found == 0 or partial == "" then return nil, found, head, partial end
    return likeliest(found), found, head, partial
end

-- What shows greyed after the typed text: the rest of the suggested name.
local function preview(text)
    local best, _, _, partial = suggestion(text)
    if not best or best:sub(1, #partial) ~= partial then return "" end
    return best:sub(#partial + 1)
end

-- What Tab turns the text into: the suggestion, or the next name that fits when Tab is pressed again.
local cycle = nil
local function tab(text)
    if cycle and cycle.text == text and #cycle.names > 1 then
        cycle.at = cycle.at % #cycle.names + 1
        cycle.text = cycle.head .. cycle.names[cycle.at]
        return cycle.text
    end
    cycle = nil
    local best, found, head = suggestion(text)
    if not best then return text, found end
    local names = { best }
    for _, name in ipairs(found) do
        if name ~= best then names[#names + 1] = name end
    end
    cycle = { head = head, names = names, at = 1, text = head .. best }
    return cycle.text
end
panel.preview, panel.tab, panel.history = preview, tab, history

-- Tab, while the command box has the keyboard.
local function on_tab()
    if not command_box or command_box.destroyed or step_count - focused_at > 3 then return end
    local text = command_box:Get()
    local written, there = tab(text)
    if written ~= text then
        command_box:Set(written)
        command_box:SetGhost("")
    elseif there and #there > 0 and text:find("[%.:]$") then
        -- nothing typed after the dot yet: list the members in the log
        local shown = table.concat(there, "  ", 1, math.min(#there, 24))
        log.channel("console"):info("%s  %s%s", text, shown, #there > 24 and ("  ... %d more"):format(#there - 24) or "")
    end
    command_box:Focus()
end

-- What the updater knows, or nil while it is not running.
local function update_state()
    local updates = Wax.update
    return updates and updates.state() or nil
end

-- The owners that have a window, by id: a mod among them gets its "Open key" on its card.
local function window_owners()
    local found = {}
    for _, owner in ipairs(ui.Keys.Owners()) do found[owner.id] = owner end
    return found
end

-- What the updater knows of one mod that came from the catalogue ({ version, auto }), or nil for any other mod.
local function from_catalogue(updates, id)
    return updates and updates.mods and updates.mods[id] or nil
end

local function mod_list_signature(list, updates, keyed)
    local parts = {}
    for _, mod in ipairs(list) do
        local newer = updates and updates.available[mod.id]
        parts[#parts + 1] = mod.id .. ":" .. mod.status .. ":" .. mod.generation .. ":" .. (mod.waiting or "")
            .. (mod.content and (":" .. tostring(mod.content.state) .. tostring(mod.content.mark)) or "")
            .. ":" .. (newer or "") .. (newer and updates.installing[mod.id] and "+" or "")
            .. (from_catalogue(updates, mod.id) and ":catalogue" or "") .. (keyed[mod.id] and ":window" or "")
    end
    return table.concat(parts, "|")
end

-- The quiet line beside "Check now": what the updater is doing, or when it last asked the catalogue.
local function update_line(updates)
    if updates.look == false then return "Not looking for updates. Nothing is asked of the catalogue." end
    if updates.checking then return "Checking ..." end
    if next(updates.installing) then return "Updating ..." end
    local ago = os.time() - updates.last
    if updates.last <= 0 then return "Not checked yet." end
    return ago < 90 and "Last checked a moment ago."
        or (ago < 3600 and ("Last checked %d minutes ago."):format(ago // 60))
        or (ago < 7200 and "Last checked an hour ago.")
        or (ago < 172800 and ("Last checked %d hours ago."):format(ago // 3600))
        or ("Last checked %d days ago."):format(ago // 86400)
end

-- Every word typed has to be found in the mod: its name, id, version, state ("loaded", "off", "failed", "new") or error.
local function mod_matches(mod, needle)
    local state = mod.status == "loaded" and "loaded on enabled running"
        or (mod.status == "disabled" and "off disabled switched" .. (mod.fresh and " new" or "") or "failed error broken")
    local words = table.concat({ mod.name, mod.id, mod.version or "", state, mod.error or "" }, " "):lower()
    for word in needle:gmatch("%S+") do
        if not words:find(word, 1, true) then return false end
    end
    return true
end

local function filter_mods()
    local needle = mod_filter:lower()
    local total, shown, loaded, off, failed = 0, 0, 0, 0, 0
    for _, row in ipairs(mod_rows) do
        local mod = row.mod
        if mod then
            total = total + 1
            if mod.status == "loaded" then loaded = loaded + 1 elseif mod.status == "disabled" then off = off + 1 else failed = failed + 1 end
            local visible = mod_matches(mod, needle)
            if visible then shown = shown + 1 end
            if row.visible ~= visible then
                row.control:SetVisible(visible)
                row.visible = visible
            end
        end
    end
    if total == 0 then
        mods_note:Set("No mods yet. Put a folder with an init.lua in the mods folder and it shows up here.")
    elseif needle:find("%S") then
        mods_note:Set(shown == 0 and ("No mod matches \"%s\"."):format(mod_filter) or ("Showing %d of %d."):format(shown, total))
    else
        local parts = { ("%d loaded"):format(loaded) }
        if off > 0 then parts[#parts + 1] = ("%d switched off"):format(off) end
        if failed > 0 then parts[#parts + 1] = ("%d failed"):format(failed) end
        mods_note:Set(("%d mod%s: %s."):format(total, total == 1 and "" or "s", table.concat(parts, ", ")))
    end
    -- a card can only be dragged while there is another one to drag it past
    for _, row in ipairs(mod_rows) do
        if row.grip and row.gripping ~= (shown > 1) then
            row.gripping = shown > 1
            row.grip:SetVisibility(row.gripping and V.Visible or V.HitTestInvisible)
            row.grip:SetRenderOpacity(row.gripping and 1 or 0.4)
        end
    end
end

-- Ends a drag at once: every card is where the list has it.
local function stop_sort()
    held = nil
    if sorting then sorting:stop() end
    sorting = nil
end

-- What is drawn for a card while it is held: its title line, with the grip lit.
local function build_ghost(float)
    local theme = style.theme
    local card = root.new("Overlay")
    kit.slot(card:AddChild(kit.box(theme.card, "round8")), { h = H.Fill, v = VA.Fill })
    local line = root.new("HorizontalBox")
    local grip_at = GRIP.x + (GRIP.width - GRIP.icon) / 2
    kit.slot(line:AddChild(kit.icon("wax-dots", GRIP.icon, theme.text)), { v = VA.Center, pad = style.margin(grip_at, 0, 0, 0) })
    kit.slot(line:AddChild(kit.icon("chevron-right", 14, theme.dim)), { v = VA.Center,
        pad = style.margin(TITLE_PAD.x + GRIP.room - grip_at - GRIP.icon, 0, 8, 0) })
    float.title = kit.label("", { face = "Bold", free = true })
    kit.slot(line:AddChild(float.title), { v = VA.Center, fill = 1 })
    kit.slot(card:AddChild(line), { h = H.Fill, v = VA.Top, pad = style.margin(0, TITLE_PAD.y, TITLE_PAD.x, TITLE_PAD.y) })
    kit.slot(card:AddChild(kit.image(theme.outline, "frame8", 1, 1)), { h = H.Fill, v = VA.Fill })
    float.box = kit.sized(card, 200, 32)
    return float.box
end

-- The grip at the left of a card's title: held and moved, it takes the card to another place in the list.
local function add_grip(row)
    local control = row.control
    local icon, button
    style.extend(control, function()
        local theme = style.theme
        icon = kit.icon("wax-dots", GRIP.icon, theme.dim)
        button = kit.button(nil, { flat = true, color = theme.clear, hover = theme.clear, press = theme.clear,
            padding = style.margin(0), cursor = style.Cursor.Move })
        kit.slot(button:SetContent(icon), { h = H.Center, v = VA.Center })
        -- it lies over the title's own button, level with the arrow, and the arrow and the title move over to make room for it
        kit.slot(control.source:GetParent():AddChild(kit.sized(button, GRIP.width, GRIP.height)),
            { h = H.Left, v = VA.Center, pad = style.margin(GRIP.x, 0, 0, 0) })
        row.section.parts.chevron.Slot:SetPadding(style.margin(GRIP.room, 0, 8, 0))
    end)
    -- the title keeps to one line in the room that is left beside the grip
    local parts = row.section.parts
    if parts.fit then
        parts.before = GRIP.room
        parts.fit()
    end
    row.grip = button
    local function listen(delegate, handler)
        control.disconnects[#control.disconnects + 1] = events.connect(button, delegate, window.parking, handler)
    end
    listen("OnPressed", function()
        if not sorting then held = { hold = drag.hold(button), id = row.mod.id, owner = control } end
    end)
    -- the muted colour of the arrow beside it, and the colour of text under the mouse
    listen("OnHovered", function() style.tint(icon, "image", style.theme.text) end)
    listen("OnUnhovered", function() style.tint(icon, "image", style.theme.dim) end)
end

local function rebuild_mods(list, updates, keyed)
    stop_sort()
    for _, row in ipairs(mod_rows) do
        -- a card the user opened or closed by hand stays that way for the session
        if row.section:IsOpen() ~= row.built_open then mods_open[row.mod.id] = row.section:IsOpen() end
        row.control:Destroy()
    end
    mod_rows = {}
    if panel.updates then panel.updates.buttons = {} end
    in_core_scope(function()
        for _, mod in ipairs(list) do
            local healthy, off = mod.status == "loaded", mod.status == "disabled"
            local newer = updates and updates.available[mod.id]
            local updating = newer and updates.installing[mod.id]
            -- cards start closed, so the list stays short. One with a problem or an update to put in starts open, and a closed one says its state
            local open = mods_open[mod.id]
            if open == nil then open = mod.error ~= nil or mod.waiting ~= nil or mod.fresh == true or (newer ~= nil and not updating) end
            local state = off and (mod.fresh and " (new, switched off)" or " (switched off)") or (not healthy and (" (%s)"):format(mod.status) or "")
            if newer then state = state .. (" (%s available)"):format(newer) end
            local title = ("%s  %s%s"):format(mod.name, mod.version or "", state)
            local section = mods_page:Section(title, { open = open, fit = true })
            section:Field("Status", healthy and "loaded" or (off and (mod.fresh and "new, switched off" or "switched off") or mod.status))
                :SetColor(healthy and style.theme.good or (off and (mod.fresh and style.theme.warn or style.theme.dim) or style.theme.bad))
            if off and mod.fresh then
                section:Label("This mod is new here, so it is switched off. It starts when you switch on Enabled below. A mod is code that can do what a program can, so switch on only the ones you trust.",
                    { color = style.theme.warn, size = style.theme.small_size })
            end
            if updating then
                section:Label(("Updating to %s ..."):format(newer), { dim = true })
            elseif newer then
                panel.updates.buttons[mod.id] = section:Button(("Update to %s"):format(newer), function() Wax.update.install(mod.id) end,
                    { icon = "download", stretch = false })
            end
            if mod.error then section:Label(mod.error, { color = style.theme.bad, size = style.theme.small_size }) end
            if mod.waiting then
                section:Label("The last save does not compile, so the version before it is still running: " .. mod.waiting,
                    { color = style.theme.warn, size = style.theme.small_size })
            end
            if mod.loadMs and not off then section:Field("Load time", ("%.1f ms"):format(mod.loadMs)) end
            -- a mod that brings game content of its own: whether the game has it
            if mod.content and not off then
                local state = mod.content.state
                section:Field("Game content", state == "ready" and ("%d files, ready"):format(mod.content.files)
                    or state == "restart" and "changed, restart the game" or state == "off" and "off" or "not looked at yet")
                if mod.content.reason then
                    section:Label(mod.content.reason, { color = state == "off" and style.theme.bad or style.theme.warn, size = style.theme.small_size })
                end
            end
            section:Toggle("Enabled", not off, function(on) Wax.mods.set_enabled(mod.id, on) end)
            local row = { control = section.control, section = section, built_open = open, mod = mod, visible = true, title = title }
            add_grip(row)
            -- a mod that came from the catalogue: whether a newer version of it is put in by itself
            local listed = from_catalogue(updates, mod.id)
            if listed then
                row.auto = section:Toggle("Auto Update", listed.auto, function(on) Wax.update.set_auto(mod.id, on) end)
                if panel.updates and panel.updates.stopped then row.auto:SetEnabled(false) end
            end
            -- a mod with a window: the key that shows and hides its windows, and nobody else's
            if keyed[mod.id] then
                row.keybind = section:Keybind("Open key", keyed[mod.id].key, function(key)
                    if not ui.Keys.Set(mod.id, key) and not row.keybind.destroyed then row.keybind:Set(ui.Keys.Get(mod.id)) end
                end)
            end
            local tools = section:Row()
            local reload = tools:Button("Reload", function() Wax.mods.request_reload(mod.id) end, { icon = "refresh-cw", spin = true })
            if off then reload:SetEnabled(false) end
            -- removing asks first, in the mod's own card
            local ask
            tools:Button(nil, function() ask.control:SetVisible(true) end, { icon = "trash-2" })
            ask = section:Row()
            ask:Label(("Remove %s? Its folder is renamed, not erased."):format(mod.name), { color = style.theme.warn })
            ask:Button("Remove", function()
                local kept, problem = Wax.mods.remove(mod.id)
                if kept then
                    ui.Notify(("To get it back, rename mods/%s to %s."):format(kept, mod.id), { title = mod.name .. " removed", seconds = 10 })
                else
                    ui.Notify(tostring(problem), { title = "Could not remove " .. mod.name, kind = "bad" })
                end
            end, { icon = "trash-2", stretch = false })
            ask:Button("Keep", function() ask.control:SetVisible(false) end, { stretch = false })
            ask.control:SetVisible(false)
            mod_rows[#mod_rows + 1] = row
        end
    end)
    filter_mods()
end

-- The mods, what the updater knows and who has a window. The cards are built again when they no longer say that, unless told to keep them.
local function list_mods(keep)
    local list, updates, keyed = Wax.mods.list(), panel.updates and update_state() or nil, window_owners()
    local signature = mod_list_signature(list, updates, keyed)
    if signature ~= mods_signature and not keep then
        mods_signature = signature
        rebuild_mods(list, updates, keyed)
    end
    return list, updates, keyed
end

-- Puts a mod where another one stands in the list. The loader has the last word: a mod still loads after the ones it needs.
local function put_at(mod, other)
    local from, to = nil, nil
    for index, entry in ipairs(Wax.mods.list()) do
        if entry.id == mod.id then from = index end
        if entry.id == other.id then to = index end
    end
    if not from or not to or from == to then return end
    for _ = 1, math.abs(to - from) do Wax.mods.move(mod.id, to > from and 1 or -1) end
    for index, entry in ipairs(Wax.mods.list()) do
        if entry.id == mod.id and index ~= to then
            ui.Notify(("%s could not go there: a mod loads after the ones it needs."):format(mod.name), { title = "Mods", seconds = 6 })
        end
    end
end

-- Two signatures of the list that differ in nothing but the order of the mods.
local function same_mods(one, other)
    local function sorted(text)
        local parts = {}
        for part in tostring(text):gmatch("[^|]+") do parts[#parts + 1] = part end
        table.sort(parts)
        return table.concat(parts, "|")
    end
    return sorted(one) == sorted(other)
end

-- Puts the cards there are in the order the loader has the mods in. No card is made again, so a card that was put down
-- stays the widget it was. False when the cards and the mods are not the same any more: then they have to be built again.
local function reorder_cards()
    local list, by_id, wanted = Wax.mods.list(), {}, {}
    if #list ~= #mod_rows then return false end
    for _, row in ipairs(mod_rows) do by_id[row.mod.id] = row end
    for index, mod in ipairs(list) do
        local row = by_id[mod.id]
        if not row or row.control.destroyed then return false end
        wanted[index] = row
    end
    local first = nil
    for index, row in ipairs(wanted) do
        if mod_rows[index] ~= row then
            first = index
            break
        end
    end
    if first then
        -- from the first card that changes place on, they are taken off the page and put back in the new order
        local box, spacing = mods_page.box, style.theme.spacing
        for index = first, #mod_rows do
            local control = mod_rows[index].control;
            (control.cell or control.widget):RemoveFromParent()
        end
        for index = first, #wanted do
            local control = wanted[index].control
            kit.slot(box:AddChild(control.cell or control.widget), { pad = style.margin(0, 0, 0, spacing), h = H.Fill })
        end
    end
    mod_rows = wanted
    return true
end

-- A grip was held and moved: its card leaves the list and follows the mouse until the button comes up.
local function begin_sort(pending)
    local theme, scale = style.theme, style.scale
    local rows, index = {}, nil
    for _, row in ipairs(mod_rows) do
        if row.visible then
            rows[#rows + 1] = { widget = row.control.widget, owner = row.control, height = row.control.widget:GetDesiredSize().Y, row = row }
            if row.mod.id == pending.id then index = #rows end
        end
    end
    if not index or #rows < 2 then return end
    local picked, scroller = rows[index], mods_page.scroller
    local card, head = picked.row, picked.row.control.source:GetDesiredSize().Y
    if not ghost then ghost = drag.float(build_ghost, { X = 0, Y = 0 }) end
    ghost.box:SetWidthOverride(window.width - (window.nav_width or 0) - theme.padding - 2 - kit.GUTTER)
    ghost.box:SetHeightOverride(head)
    kit.set_text(ghost.title, card.section.parts.shown or card.title)
    -- the cards are the last things on the page, so the one picked up stands this far above the end of it
    local below = 0
    for at = index, #rows do below = below + rows[at].height + theme.spacing end
    local top = theme.bar_height + 1 + theme.padding + mods_page.box:GetDesiredSize().Y - below - drag.offset(scroller)
    local y = window.at_y + top * scale
    -- the grip, in the middle of the title line, was under the mouse when it went down: a place that says otherwise is not believed
    local by_mouse = pending.hold.y - head / 2 * scale
    if math.abs(y - by_mouse) > (GRIP.height / 2 + 2) * scale then y = by_mouse end
    local foot = window.status_holder and window.status_holder:GetDesiredSize().Y or 0
    local host, page = window, mods_page
    -- an open card is folded to its title while it is held, and is open again where it is put down
    local folded = card.section:IsOpen()
    if folded then card.section:SetOpen(false) end
    sorting = drag.sort({
        rows = rows, index = index, gap = theme.spacing, hold = pending.hold, scale = scale, float = ghost, height = head,
        x = host.at_x + ((host.nav_width or 0) + theme.padding) * scale, y = y, scroller = scroller,
        settle = folded and theme.animation + 0.1 or 0,
        area = function()
            return host.at_x + (host.nav_width or 0) * scale, host.at_y + (theme.bar_height + 1) * scale,
                host.at_x + host.width * scale, host.at_y + (host.height - foot) * scale
        end,
        showing = function() return not host.destroyed and host:IsShowing() and not host.minimized and host.page == page end,
        done = function(from, to)
            if to == from then return end
            put_at(card.mod, rows[to].row.mod)
            -- The cards change places as they are, so nothing flickers where the card is put down. Only when something
            -- else about the mods changed meanwhile are they built again: this one as it was before it was folded.
            local signature = mod_list_signature(Wax.mods.list(), panel.updates and update_state() or nil, window_owners())
            if same_mods(signature, mods_signature) and reorder_cards() then
                mods_signature = signature
            else
                if folded then card.built_open, mods_open[card.mod.id] = false, true end
                list_mods()
            end
        end,
        ended = function()
            if not folded or card.control.destroyed then return end
            card.built_open = true
            card.section:SetOpen(true)
        end,
    })
end

-- Every frame: a grip that is down becomes a drag once the mouse has moved, and a card that is held follows it.
local function step_grips()
    if sorting then
        if not sorting:step() then sorting = nil end
        return
    end
    local pending = held
    if not pending then return end
    -- let go without a move: nothing happens
    if pending.owner.destroyed or not window or window.destroyed or not window:IsShowing() or not drag.down(pending.hold.button) then
        held = nil
    elseif drag.far(pending.hold) then
        held = nil
        begin_sort(pending)
    end
end

local function refresh_log()
    local lines = {}
    local needle = search ~= "" and search:lower() or nil
    for _, entry in ipairs(log.since(cleared_after)) do
        if filters[entry.level] ~= false and (filters.content ~= false or entry.channel ~= "wax.content") then
            local text = ("[%s] %s%s"):format(entry.channel, entry.message:gsub("[\r\n]+", " "), entry.count > 1 and (" (x" .. entry.count .. ")") or "")
            if not needle or text:lower():find(needle, 1, true) then
                lines[#lines + 1] = { text, style.theme[LEVEL_COLOR[entry.level] or "text"] }
            end
        end
    end
    log_lines = #lines
    console:SetLines(lines)
end

local function refresh_perf()
    local now = perf.totals()
    local before = perf_before
    perf_before = now
    if not before or now.frames == before.frames then return end
    local frames, seconds = now.frames - before.frames, now.seconds - before.seconds
    -- the page's own figures are only written while it shows: its bar moves to each new value, which costs every frame it does
    local showing = window.page == perf_fields.page
    local total = 0
    for name, field in pairs(perf_fields.sections) do
        local spent = ((now.sections[name] or 0) - (before.sections[name] or 0)) / frames
        total = total + spent
        if showing then field:Set(("%.3f ms"):format(spent * 1000)) end
    end
    status:Right(("%.0f fps   Wax %.2f ms"):format(frames / seconds, total * 1000))
    if not showing then return end
    perf_fields.fps:Set(("%.0f"):format(frames / seconds))
    perf_fields.frame:Set(("%.2f ms"):format(seconds / frames * 1000))
    perf_fields.wax:Set(("%.3f ms"):format(total * 1000))
    perf_fields.share:Set(total / (seconds / frames))
end

local function refresh()
    if not window or window.destroyed or not window:IsShowing() then return end
    -- While the Mods page is showing, the folder is looked at every ten seconds. A look takes about 15 ms, which is a
    -- frame that stutters: every two seconds, as it was, could be felt.
    scan_tick = scan_tick + 1
    if window.page == mods_page and scan_tick % SCAN_EVERY == 0 then Wax.mods.request_sync(true) end
    local shown = panel.updates
    -- the cards are not built again under a card that is being dragged
    local list, updates, keyed = list_mods(sorting ~= nil)
    -- a card's switch and key show what they are now, also when they were changed elsewhere
    for _, row in ipairs(mod_rows) do
        local listed, owner = from_catalogue(updates, row.mod.id), keyed[row.mod.id]
        if row.auto and listed and row.auto:Get() ~= listed.auto then row.auto:Set(listed.auto) end
        if row.keybind and owner and row.keybind:Get() ~= owner.key then row.keybind:Set(owner.key) end
    end
    if updates and not shown.line.destroyed then
        local text = os.clock() < shown.hold and shown.text or update_line(updates)
        if text ~= shown.text then
            shown.text = text
            shown.line:Set(text)
        end
        if updates.problem ~= shown.problem then
            shown.problem = updates.problem
            shown.note:Set(updates.problem or "")
            shown.note:SetVisible(updates.problem ~= nil)
        end
        local looking = updates.look ~= false
        if shown.look and shown.look:Get() ~= looking then shown.look:Set(looking) end
        -- without the helper no control here does anything, and while nothing is looked for the button and the cards' switches do nothing
        local helpless = updates.stopped == true
        local stopped = helpless or not looking
        if stopped ~= shown.stopped then
            shown.stopped = stopped
            shown.check:SetEnabled(not stopped)
            for _, row in ipairs(mod_rows) do
                if row.auto then row.auto:SetEnabled(not stopped) end
            end
        end
        if shown.look and helpless ~= shown.helpless then
            shown.helpless = helpless
            shown.look:SetEnabled(not helpless)
        end
    end
    local newest = log.newest_id()
    local newest_entry = log.since(newest - 1)[1]
    local stamp = newest * 1000 + (newest_entry and newest_entry.count or 0)
    if stamp ~= log_stamp and follow then
        log_stamp = stamp
        refresh_log()
    end
    refresh_perf()
    local errors, loaded = #Wax.guard.errors(), 0
    for _, mod in ipairs(list) do
        if mod.status == "loaded" then loaded = loaded + 1 end
    end
    if errors > 0 then
        status:Set(("%d of %d mods loaded, %d error%s (see the Log page)"):format(loaded, #list, errors, errors == 1 and "" or "s"),
            { kind = "bad", icon = "alert-triangle" })
    else
        status:Set(("%d of %d mods loaded, no errors"):format(loaded, #list), { kind = "good", icon = "check-circle" })
    end
end

panel.refresh = refresh     -- what the panel does every half second while it shows

-- A page in the debug panel for the calling mod. Returns a container: page:Toggle(...), page:Button(...), ...
function panel.Page(name, options)
    if name == panel then error("write ui.Debug.Page(...) with a dot, not a colon", 2) end
    if not window then error("the debug panel is not running", 2) end
    local page = window:Page(tostring(name), options)
    scope.own(function() if not window.destroyed then window:RemovePage(page) end end)
    return page
end

function panel.Window() return window end
-- What a mod's card on the Mods page is made of: its section, its grip, and the switch (auto) and key (keybind) it has, if any.
function panel.card(id)
    for _, row in ipairs(mod_rows) do
        if row.mod.id == id then return row end
    end
    return nil
end
-- The panel is Wax's own, whoever asks for it: a mod that calls this gets the panel, not its own windows.
function panel.Show()
    in_core_scope(function()
        if window then window:Show() end
        ui.Open()
    end)
end

local SECTION_NAMES = { bridge = "Bridge", game = "Game tree", mods = "Mod loader", tasks = "Tasks", gui = "Interface", debug = "This panel" }
local SECTION_ORDER = { "bridge", "game", "mods", "tasks", "gui", "debug" }

function panel.start()
    in_core_scope(function()
        window = ui.Window({ title = "Wax", nav = "side", width = 620, height = 440, x = 40, y = 80 })
        opened = ui.Opened:Connect(function() Wax.mods.request_sync(true) end)
        -- and when the Mods page is turned to
        window.PageChanged:Connect(function(name)
            if name == "Mods" then Wax.mods.request_sync(true) end
        end)
        Wax.mods.on_held = function(_, name)
            ui.Notify(("%s was added. It is switched off until you enable it on the Mods page."):format(name),
                { title = "New mod", icon = "package-plus", seconds = 8 })
        end

        status = window:StatusBar("Starting")
        mods_page = window:Page("Mods", { icon = "package" })
        mods_page:Title("Mods", "Every mod in the mods folder. A new one appears on its own, switched off until you switch it on. Saving a file reloads its mod.")
        local mod_tools = mods_page:Row()
        mod_tools:Input(nil, { hint = "Search mods: a name, loaded, off, failed, new ...", clear = true }).Typed:Connect(function(text)
            stop_sort()
            mod_filter = text
            filter_mods()
        end)
        mod_tools:Button(nil, function() Wax.mods.request_sync(true) end, { icon = "refresh-cw", spin = true })
        mods_note = mods_page:Label("", { dim = true })
        -- mods that were added from the catalogue: each has its own Auto Update on its card. Here, whether to look at all, and a button to ask now
        local updates = update_state()
        if updates then
            local shown = { buttons = {}, hold = 0, text = update_line(updates), stopped = false, helpless = false }
            -- the one switch for the network: off, neither mods nor Wax itself are looked for and nothing is downloaded
            if Wax.update.set_looking then
                shown.look = mods_page:Toggle("Look for updates", updates.look ~= false, function(on) Wax.update.set_looking(on) end)
            end
            local asking = mods_page:Row()
            shown.check = asking:Button("Check now", function()
                local asked, wait = Wax.update.check_now()
                if not asked and not wait then return end
                -- said for a few seconds, then the line goes back to what the updater reports
                shown.text = asked and "Checking ..." or ("Try again in %d seconds."):format(wait)
                shown.hold = os.clock() + (asked and 1.5 or 4)
                shown.line:Set(shown.text)
            end, { icon = "refresh-cw", spin = true, stretch = false })
            shown.line = asking:Label(shown.text, { dim = true })
            shown.note = mods_page:Label("", { color = style.theme.warn, size = style.theme.small_size })
            shown.note:SetVisible(false)
            panel.updates = shown
        end

        log_page = window:Page("Log", { icon = "scroll-text", scroll = false })
        log_page:Title("Log", "What Wax and the mods printed, newest at the bottom. Drag to select, Ctrl+C to copy.")
        local levels = log_page:Flow()
        for _, level in ipairs({ { "error", "Errors" }, { "warn", "Warnings" }, { "info", "Prints" }, { "content", "Game content" } }) do
            levels:Toggle(level[2], true, function(on)
                filters[level[1]] = on
                refresh_log()
            end)
        end
        local tools = log_page:Row()
        local find = tools:Input(nil, { hint = "Search the log", clear = true })
        find.Typed:Connect(function(text)
            search = text
            refresh_log()
        end)
        tools:Toggle("Follow", true, function(on)
            follow = on
            console:SetFollow(on)
            if on then refresh_log() end
        end)
        -- Copy and Clear act on what is shown. The log itself keeps everything.
        ticking_button(tools, "copy", function()
            if log_lines == 0 then return false end
            ui.Copy(console:GetText())
            ui.Notify(("Copied %d line%s of the log."):format(log_lines, log_lines == 1 and "" or "s"),
                { title = "Copied", kind = "good", icon = "check", seconds = 2.5 })
        end)
        ticking_button(tools, "trash-2", function()
            if log_lines == 0 and #Wax.guard.errors() == 0 then return false end
            cleared_after = log.newest_id()
            Wax.guard.clear_errors()
            refresh_log()
            ui.Notify("The log was cleared.", { title = "Cleared", kind = "good", icon = "check", seconds = 2.5 })
        end)
        console = log_page:Console()
        -- a line of Lua, run in the game: game, ui, task, mods.<Id> (a mod's globals), exports.<Id>, raw (everything)
        local command_row = log_page:Row()
        local command = command_row:Input(nil, { hint = "print(\"Hello World\")", mono = true })
        command_box = command
        local run_flash = nil
        local function submit(text)
            if not text:find("%S") then return false end
            run_command(text, function(ok, first)
                run_flash(ok and "check" or "x")
                if ok then ui.Notify(first or "Done.", { title = "Ran", kind = "good", icon = "check", seconds = 2.5 }) end
            end)
            command:Set("")
            command:SetGhost("")
            task.spawn(function()
                task.wait()
                if not command.destroyed then command:Focus() end
            end)
            return "later"
        end
        command.Entered:Connect(submit)
        command.Typed:Connect(function(text) command:SetGhost(preview(text)) end)
        ticking_button(command_row, "history", function()
            if #history == 0 then
                ui.Notify("Nothing has been run yet.", { title = "History", seconds = 2.5 })
                return false
            end
            history_at = history_at - 1
            if history_at < 1 then history_at = #history end
            command:Set(history[history_at])
            command:SetGhost(preview(history[history_at]))
            command:Focus()
        end)
        local _, flash = ticking_button(command_row, "play", function() return submit(command:Get()) end)
        run_flash = flash
        tab_key = ui.Hotkey("Tab", on_tab, { in_menu = true })

        local perf_page = window:Page("Performance", { icon = "activity" })
        perf_fields.page = perf_page
        perf_page:Title("Performance", "What Wax costs on top of the game, measured every half second.")
        perf_fields.fps = perf_page:Field("Frames per second", "", { mono = true })
        perf_fields.frame = perf_page:Field("Frame time", "", { mono = true })
        perf_fields.wax = perf_page:Field("Wax per frame", "", { mono = true })
        perf_fields.share = perf_page:Progress("Share of the frame used by Wax", 0)
        local parts = perf_page:Section("Where it goes")
        perf_fields.sections = {}
        for _, name in ipairs(SECTION_ORDER) do perf_fields.sections[name] = parts:Field(SECTION_NAMES[name], "", { mono = true }) end

        -- the search stays at the top and the grid takes the rest. The grid builds only the icons in view.
        local icons_page = window:Page("Icons", { icon = "shapes", scroll = false })
        icons_page:Title("Icons")
        local found = icons_page:Label("", { dim = true })
        local icon_search = icons_page:Input(nil, { hint = "Search icons: arrow, map, user ...", clear = true })
        local every = #ui.Icons.Find("")
        local grid = icons_page:Grid({
            cell = 38,
            make = function(cell)
                local button
                button = cell:Button(nil, function() ui.Notify(button.item, { title = "Icon", icon = button.item }) end,
                    { icon = "circle", stretch = true })
                return button
            end,
            show = function(button, name)
                button.item = name
                button:SetIcon(name)
            end,
        })
        local function show_icons(text)
            local matches = ui.Icons.Find(text)
            grid:SetItems(matches)
            if #matches == every then
                found:Set(("%d icons. Click one to see its name, then use that name wherever an icon is accepted."):format(every))
            elseif #matches == 0 then
                found:Set(("No icon has \"%s\" in its name."):format(text))
            else
                found:Set(("%d of %d icons have \"%s\" in their name."):format(#matches, every, text))
            end
        end
        icon_search.Typed:Connect(show_icons)
        show_icons("")

        explorer.build(window:Page("Explorer", { icon = "scan-search", scroll = false }))

        local settings_page = window:Page("Settings", { icon = "settings", bottom = true })
        settings_page:Title("Settings", "These are remembered the next time you play.")
        ui.AddSettings(settings_page)
    end)
    mods_signature, log_stamp, perf_before = nil, nil, nil
end

function panel.step()
    -- remembers the frame in which the command box last had the keyboard, so on_tab can tell Tab was meant for it
    step_count = step_count + 1
    if command_box and not command_box.destroyed and window and window.page == log_page and ui.IsOpen() and command_box:HasFocus() then
        focused_at = step_count
    end
    if (held or sorting) and not guard.call("mods drag", step_grips) then pcall(stop_sort) end
    explorer.step()
    local now = os.clock()
    if now - last_refresh < REFRESH_SECONDS then return end
    last_refresh = now
    refresh()
end

function panel.stop()
    if command_scope then command_scope:destroy() end
    if tab_key then tab_key.Disconnect() end
    command_scope, command_env, command_box, tab_key = nil, nil, nil, nil
    if Wax.mods then Wax.mods.on_held = nil end
    if opened then opened:Disconnect() end
    pcall(stop_sort)
    if ghost then ghost:destroy() end
    ghost = nil
    if window then window:Destroy() end
    window, opened, panel.updates = nil, nil, nil
end

-- Forgets the window without touching it (the game removed the interface).
function panel.forget()
    window, opened, mod_rows, mods_signature, command_box, tab_key = nil, nil, {}, nil, nil, nil
    held, sorting = nil, nil
    if ghost then ghost:forget() end
    ghost = nil
    drag.forget()
    panel.updates = nil
    if Wax.mods then Wax.mods.on_held = nil end
end

return panel
