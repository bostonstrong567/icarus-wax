-- The in-game debug panel: mods, log, performance and settings, plus pages other mods add

local Wax = ...
local ui = Wax.import("gui.init")
local style = Wax.import("gui.style")
local log = Wax.import("core.log")
local perf = Wax.import("core.perf")
local scope = Wax.import("core.scope")
local task = Wax.import("core.sched").task
local explorer = Wax.import("gui.explorer")

local panel = {}

local REFRESH_SECONDS = 0.5
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

local function mod_list_signature(list, updates)
    local parts = {}
    for _, mod in ipairs(list) do
        local newer = updates and updates.available[mod.id]
        parts[#parts + 1] = mod.id .. ":" .. mod.status .. ":" .. mod.generation .. ":" .. (mod.waiting or "")
            .. ":" .. (newer or "") .. (newer and updates.installing[mod.id] and "+" or "")
    end
    return table.concat(parts, "|")
end

-- The quiet line beside "Check now": what the updater is doing, or when it last asked the catalogue.
local function update_line(updates)
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
end

local function rebuild_mods(list, updates)
    for _, row in ipairs(mod_rows) do
        -- a card the user opened or closed by hand stays that way for the session
        if row.section:IsOpen() ~= row.built_open then mods_open[row.mod.id] = row.section:IsOpen() end
        row.control:Destroy()
    end
    mod_rows = {}
    if panel.updates then panel.updates.buttons = {} end
    in_core_scope(function()
        for index, mod in ipairs(list) do
            local healthy, off = mod.status == "loaded", mod.status == "disabled"
            local newer = updates and updates.available[mod.id]
            local updating = newer and updates.installing[mod.id]
            -- cards start closed, so the list stays short. One with a problem or an update to put in starts open, and a closed one says its state
            local open = mods_open[mod.id]
            if open == nil then open = mod.error ~= nil or mod.waiting ~= nil or (newer ~= nil and not updating) end
            local state = off and " (switched off)" or (not healthy and (" (%s)"):format(mod.status) or "")
            if newer then state = state .. (" (%s available)"):format(newer) end
            local section = mods_page:Section(("%s  %s%s"):format(mod.name, mod.version or "", state), { open = open })
            section:Field("Status", healthy and "loaded" or (off and (mod.fresh and "new: switched off until you enable it" or "switched off") or mod.status))
                :SetColor(healthy and style.theme.good or (off and (mod.fresh and style.theme.warn or style.theme.dim) or style.theme.bad))
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
            section:Toggle("Enabled", not off, function(on) Wax.mods.set_enabled(mod.id, on) end)
            local tools = section:Row()
            local reload = tools:Button("Reload", function() Wax.mods.request_reload(mod.id) end, { icon = "refresh-cw", spin = true })
            if off then reload:SetEnabled(false) end
            local up = tools:Button(nil, function() Wax.mods.move(mod.id, -1) end, { icon = "arrow-up" })
            local down = tools:Button(nil, function() Wax.mods.move(mod.id, 1) end, { icon = "arrow-down" })
            up:SetEnabled(index > 1)
            down:SetEnabled(index < #list)
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
            mod_rows[#mod_rows + 1] = { control = section.control, section = section, built_open = open, mod = mod, visible = true }
        end
    end)
    filter_mods()
end

local function refresh_log()
    local lines = {}
    local needle = search ~= "" and search:lower() or nil
    for _, entry in ipairs(log.since(cleared_after)) do
        if filters[entry.level] ~= false then
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
    perf_fields.fps:Set(("%.0f"):format(frames / seconds))
    perf_fields.frame:Set(("%.2f ms"):format(seconds / frames * 1000))
    local total = 0
    for name, field in pairs(perf_fields.sections) do
        local spent = ((now.sections[name] or 0) - (before.sections[name] or 0)) / frames
        total = total + spent
        field:Set(("%.3f ms"):format(spent * 1000))
    end
    perf_fields.wax:Set(("%.3f ms"):format(total * 1000))
    status:Right(("%.0f fps   Wax %.2f ms"):format(frames / seconds, total * 1000))
    perf_fields.share:Set(total / (seconds / frames))
end

local function refresh()
    if not window or window.destroyed or not window:IsVisible() or not (ui.IsOpen() or ui.IsPreview()) then return end
    -- while the Mods page is showing, the folder is looked at every two seconds
    scan_tick = scan_tick + 1
    if window.page == mods_page and scan_tick % 4 == 0 then Wax.mods.request_sync(true) end
    local list = Wax.mods.list()
    local shown = panel.updates
    local updates = shown and update_state()
    local signature = mod_list_signature(list, updates)
    if signature ~= mods_signature then
        mods_signature = signature
        rebuild_mods(list, updates)
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
        if shown.switch:Get() ~= updates.auto then shown.switch:Set(updates.auto) end
        -- without the helper neither control does anything
        local stopped = updates.stopped == true
        if stopped ~= shown.stopped then
            shown.stopped = stopped
            shown.switch:SetEnabled(not stopped)
            shown.check:SetEnabled(not stopped)
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

-- A page in the debug panel for the calling mod. Returns a container: page:Toggle(...), page:Button(...), ...
function panel.Page(name, options)
    if name == panel then error("write ui.Debug.Page(...) with a dot, not a colon", 2) end
    if not window then error("the debug panel is not running", 2) end
    local page = window:Page(tostring(name), options)
    scope.own(function() if not window.destroyed then window:RemovePage(page) end end)
    return page
end

function panel.Window() return window end
function panel.Show()
    if window then window:Show() end
    ui.Open()
end

local SECTION_NAMES = { bridge = "Bridge", game = "Game tree", mods = "Mod loader", tasks = "Tasks", gui = "Interface", debug = "This panel" }
local SECTION_ORDER = { "bridge", "game", "mods", "tasks", "gui", "debug" }

function panel.start()
    in_core_scope(function()
        window = ui.Window({ title = "Wax", nav = "side", width = 620, height = 440, x = 40, y = 80 })
        opened = ui.Opened:Connect(function() Wax.mods.request_sync(true) end)
        Wax.mods.on_held = function(_, name)
            ui.Notify(("%s was added. It is switched off until you enable it on the Mods page."):format(name),
                { title = "New mod", icon = "package-plus", seconds = 8 })
        end

        status = window:StatusBar("Starting")
        mods_page = window:Page("Mods", { icon = "package" })
        mods_page:Title("Mods", "Every mod in the mods folder. New ones appear on their own, and saving a file reloads its mod.")
        local mod_tools = mods_page:Row()
        mod_tools:Input(nil, { hint = "Search mods: a name, loaded, off, failed, new ..." }).Typed:Connect(function(text)
            mod_filter = text
            filter_mods()
        end)
        mod_tools:Button(nil, function() Wax.mods.request_sync(true) end, { icon = "refresh-cw", spin = true })
        mods_note = mods_page:Label("", { dim = true })
        -- mods that were added from the catalogue: a switch, and a button to ask now
        local updates = update_state()
        if updates then
            local shown = { buttons = {}, hold = 0, text = update_line(updates), stopped = false }
            shown.switch = mods_page:Toggle("Auto Update", updates.auto, function(on) Wax.update.set_auto(on) end)
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
        local levels = log_page:Row()
        for _, level in ipairs({ { "error", "Errors" }, { "warn", "Warnings" }, { "info", "Prints" } }) do
            levels:Toggle(level[2], true, function(on)
                filters[level[1]] = on
                refresh_log()
            end)
        end
        local tools = log_page:Row()
        local find = tools:Input(nil, { hint = "Search the log" })
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
        local icon_search = icons_page:Input(nil, { hint = "Search icons: arrow, map, user ..." })
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

        explorer.build(window:Page("Explorer", { icon = "folder-tree", scroll = false }))

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
    if window then window:Destroy() end
    window, opened, panel.updates = nil, nil, nil
end

-- Forgets the window without touching it (the game removed the interface).
function panel.forget()
    window, opened, mod_rows, mods_signature, command_box, tab_key = nil, nil, {}, nil, nil, nil
    panel.updates = nil
    if Wax.mods then Wax.mods.on_held = nil end
end

return panel
