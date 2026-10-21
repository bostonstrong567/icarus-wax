-- Mods a host asks of the players who join: the host (or a dedicated server) tells each joining player the list through a chat
-- line that Wax takes before the chat box shows it, and the player's game puts the mods in from the catalogue, asks, or does nothing,
-- as the setting "Mods a server requires" says. The game itself knows nothing of it: a player without the mod still joins.

local Wax = ...
local log = Wax.import("core.log").channel("wax.required")
local scope = Wax.import("core.scope")
local sched = Wax.import("core.sched")
local storage = Wax.import("core.storage")
local sides = Wax.import("mods.sides")

local task = sched.task
local M = {}

M.MARK = "\1wax required "                  -- the head of the chat line. The first byte is what tells it from a player's own words
M.HOOK = "/Script/Icarus.IcarusPlayerController:ClientReceiveChatMessage"
M.MODES = { "install", "ask", "ignore" }    -- the setting: put the mods in and switch them on, ask first, or do nothing
M.MODE_WORDS = { install = "Install and enable", ask = "Ask", ignore = "Ignore" }
M.SEND_DELAY = 6                            -- seconds after a player joins before the host tells them, so their game is listening
M.FILE_SECONDS = 10                         -- how often a host or server reads saved/wax.server.lua again
M.MAX = 50                                  -- mods one line may name
M.Changed = sched.Signal.new("required")

local ID = "^[%a][%w_]*$"
local VERSION = "^[%w][%w%.%-%+_]*$"

local settings = { mode = "install" }       -- saved as wax.required, the player's own choice
local server = { required = {} }            -- saved as wax.server: the ids a host asks of players, in the order they were added
local asked = {}                            -- what the host of this session asked: id -> { version }
local pending = {}                          -- id -> { version, why, action }: waiting for the player, or cannot be put in
local busy = {}                             -- id -> true while it is being put in
local listening, heard, file_task, joined_link = nil, nil, nil, nil
local server_text, skip_read = nil, false
local started = false

local function changed() M.Changed:Fire() end

local function no_mod(fn, ...)
    local previous = scope.enter(nil)
    local ok, made = pcall(fn, ...)
    scope.leave(previous)
    if not ok then error(made, 0) end
    return made
end

local function notify(text, options)
    local ui = Wax.ui
    if ui and ui.Notify then pcall(ui.Notify, text, options) end
end

-- the pure parts: the line, its reading, and the decision

-- The chat line for a list of { id, version }. A mod without a version is named alone.
function M.line(list)
    local parts = {}
    for _, entry in ipairs(list) do
        if #parts >= M.MAX then break end
        local version = type(entry.version) == "string" and entry.version:match(VERSION) and entry.version or nil
        if type(entry.id) == "string" and entry.id:match(ID) then parts[#parts + 1] = version and (entry.id .. "@" .. version) or entry.id end
    end
    return M.MARK .. table.concat(parts, ",")
end

-- The list a chat line carries, as { { id, version } }, or nil for a line that is not one of ours. An empty list is a host that requires nothing.
function M.parse(text)
    if type(text) ~= "string" or text:sub(1, #M.MARK) ~= M.MARK then return nil end
    local out, seen = {}, {}
    for item in text:sub(#M.MARK + 1):gmatch("[^,]+") do
        local id, version = item:match("^%s*([%a][%w_]*)@([%w%.%-%+_]+)%s*$")
        if not id then id = item:match("^%s*([%a][%w_]*)%s*$") end
        if id and #id <= 64 and not seen[id] then
            seen[id] = true
            out[#out + 1] = { id = id, version = version }
            if #out >= M.MAX then break end
        end
    end
    return out
end

local function parse_version(text)
    local a, b, c = tostring(text or ""):match("^(%d+)%.(%d+)%.(%d+)")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }
end

-- True when a is a higher version than b. Versions that are not three numbers never count as newer.
function M.newer(a, b)
    local x, y = parse_version(a), parse_version(b)
    if not x or not y then return false end
    for i = 1, 3 do
        if x[i] ~= y[i] then return x[i] > y[i] end
    end
    return false
end

-- What each required mod needs here. installed: id -> { version, enabled }. Returns { { id, version, action } } with action
-- "fine" (there and on), "enable" (there, switched off), "update" (there, older than asked) or "install" (not there).
function M.decide(required, installed)
    local out = {}
    for _, entry in ipairs(required or {}) do
        local have = installed[entry.id]
        local action
        if not have then action = "install"
        elseif entry.version and have.version and M.newer(entry.version, have.version) then action = "update"
        elseif not have.enabled then action = "enable"
        else action = "fine" end
        out[#out + 1] = { id = entry.id, version = entry.version, action = action }
    end
    return out
end

-- The ids of the mods the Mods page should offer, by mode: "ignore" offers none, "ask" everything that is not fine, "install" too
-- (what it could not do by itself stays listed). Returns the decisions that are not "fine".
function M.open(decisions, mode)
    if mode == "ignore" then return {} end
    local out = {}
    for _, decision in ipairs(decisions) do
        if decision.action ~= "fine" then out[#out + 1] = decision end
    end
    return out
end

-- the setting

function M.mode() return settings.mode end

function M.set_mode(mode)
    if type(mode) ~= "string" or not M.MODE_WORDS[mode] then error("the setting is \"install\", \"ask\" or \"ignore\", got " .. tostring(mode), 2) end
    settings.mode = mode
    storage.save("wax", "required", settings)
    changed()
end

-- the host's side: which mods are required, and telling a player

local function installed_here()
    local out = {}
    local mods = Wax.mods
    for _, mod in ipairs(mods and mods.list and mods.list() or {}) do out[mod.id] = { version = mod.version, enabled = mod.status == "loaded" } end
    return out
end

-- The list a host sends: every id in saved/wax.server.lua, with the version the host has of it.
function M.required_list()
    local here, out = installed_here(), {}
    for _, id in ipairs(server.required) do
        local have = here[id]
        out[#out + 1] = { id = id, version = have and have.version or nil }
    end
    return out
end

function M.is_required(id)
    for _, other in ipairs(server.required) do
        if other == id then return true end
    end
    return false
end

local function save_server()
    storage.save("wax", "server", server)
    skip_read = true
    changed()
end

-- Marks a mod as required to join, or takes the mark off. Players already in the session are told at once.
function M.set_required(id, on)
    if type(id) ~= "string" or not id:match(ID) then error("set_required expects a mod id, got " .. tostring(id), 2) end
    local list, kept = server.required, {}
    for _, other in ipairs(list) do
        if other ~= id then kept[#kept + 1] = other end
    end
    if on then kept[#kept + 1] = id end
    if #kept == #list and (not on or M.is_required(id)) then return false end
    server.required = kept
    save_server()
    M.tell_all()
    return true
end

-- The player controller that owns a player state, on the authority. nil when none is found.
local function controller_of(state)
    local ok, controller = pcall(function() return state:GetPlayerController() end)
    if ok and controller and controller:IsValid() then return controller end
    local list = FindAllOf("IcarusPlayerController")
    local wanted = state:GetAddress()
    for i = 1, #(list or {}) do
        local candidate = list[i]
        local found, same = pcall(function() return candidate:IsValid() and candidate.PlayerState:GetAddress() == wanted end)
        if found and same then return candidate end
    end
    return nil
end

-- The player state the line is said to come from: the host's own, or the joining player's on a server that has no player.
local function sender(state)
    local ok, mine = pcall(function()
        local game = Wax.import("engine.game").root
        local me = game.LocalPlayer
        return me and me.Raw.PlayerState or nil
    end)
    if ok and mine and mine:IsValid() then return mine end
    return state
end

-- Tells one player, given the raw player state. The line goes to that player alone: a client RPC called on the authority.
function M.tell(state)
    if not sides.authority() then return false, "not the host" end
    local controller = controller_of(state)
    if not controller then return false, "no controller for that player" end
    local line = M.line(M.required_list())
    local ok, problem = pcall(function() controller:ClientReceiveChatMessage(sender(state), line) end)
    if not ok then return false, tostring(problem) end
    return true
end

-- Tells every player in the session but the host.
function M.tell_all()
    if not sides.authority() then return 0 end
    local count = 0
    local ok, problem = pcall(function()
        local game = Wax.import("engine.game").root
        local me = game.LocalPlayer
        local mine = me and me.Raw.PlayerState
        local players = game.GameState and game.GameState.Raw.PlayerArray
        if not players then return end
        for i = 1, players:GetArrayNum() do
            local state = players[i]
            if state:IsValid() and not (mine and mine:GetAddress() == state:GetAddress()) then
                if M.tell(state) then count = count + 1 end
            end
        end
    end)
    if not ok then log:warn("the players could not be told which mods are required: %s", tostring(problem)) end
    return count
end

local function on_joined(player)
    if not sides.authority() or #server.required == 0 then return end
    local raw_ok, state = pcall(function() return player.Raw end)
    if not raw_ok or not state then return end
    local previous = scope.enter(nil)
    task.label(task.spawn(function()
        task.wait(M.SEND_DELAY)
        local ok, why = pcall(M.tell, state)
        if ok and why == nil then log:info("told a joining player which mods are required")
        elseif ok then log:warn("a joining player could not be told which mods are required: %s", tostring(why)) end
    end), "required mods: tell")
    scope.leave(previous)
end

-- A host or a server reads its file again now and then, so a server owner can edit it while the server runs.
local function read_server_file()
    if not storage.directory then return end
    local file = io.open(storage.directory .. "/wax.server.lua", "rb")
    local text = file and file:read("a") or nil
    if file then file:close() end
    if skip_read then
        skip_read, server_text = false, text
        return
    end
    if text == server_text then return end
    server_text = text
    local loaded = storage.load("wax", "server", { required = {} })
    local list = {}
    for _, id in ipairs(type(loaded.required) == "table" and loaded.required or {}) do
        if type(id) == "string" and id:match(ID) and #list < M.MAX then list[#list + 1] = id end
    end
    server.required = list
    changed()
    if #list > 0 then log:info("required mods, from saved/wax.server.lua: %s", table.concat(list, ", ")) end
    M.tell_all()
end

-- the player's side: hearing the line and acting on it

function M.pending()
    local out = {}
    for id, entry in pairs(pending) do out[#out + 1] = { id = id, version = entry.version, why = entry.why, action = entry.action, busy = busy[id] == true } end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function M.asked() return asked end

local function name_of(id)
    local mods = Wax.mods
    local mod = mods and mods.get and mods.get(id)
    local name = mod and mod.manifest and mod.manifest.name
    return type(name) == "string" and name:find("%S") and name or id
end

local function enable(id)
    local ok = Wax.mods.set_enabled(id, true)
    if ok then
        pending[id] = nil
        log:info("%s was switched on: the host requires it", id)
        notify(("Switched on %s: the host requires it."):format(name_of(id)), { title = "Mods a server requires", icon = "package-check", seconds = 8 })
    end
    changed()
    return ok
end

local function wait_for(id, seconds)
    local until_ = sched.clock() + seconds
    while sched.clock() < until_ do
        if Wax.mods.get(id) then return true end
        task.wait(0.2)
    end
    return false
end

local function could_not(id, version, why, action)
    pending[id] = { version = version, why = why, action = action }
    busy[id] = nil
    log:warn("%s%s is required by the host and could not be put in: %s", id, version and (" " .. version) or "", why)
    notify(("The host requires %s%s. %s"):format(id, version and (" " .. version) or "", why), { title = "Mods a server requires", kind = "warn", seconds = 12 })
    changed()
end

-- Puts one required mod in from the catalogue, signed as every mod from there, and switches it on. Runs as a task.
local function install(id, version)
    local browse_ok, browse = pcall(Wax.import, "mods.browse")
    if not browse_ok then return could_not(id, version, "The catalogue cannot be read here.", "install") end
    busy[id] = true
    changed()
    browse.refresh(true)
    local until_ = sched.clock() + 30
    while browse.state().loading and sched.clock() < until_ do task.wait(0.25) end
    local entry = browse.get(id)
    if not entry then
        local state = browse.state()
        return could_not(id, version, state.problem and ("The catalogue could not be reached (" .. tostring(state.problem) .. ")." )
            or "It is not in the catalogue, so ask the host for it.", "install")
    end
    if version and M.newer(version, entry.version) then
        return could_not(id, version, ("The catalogue only has %s, so ask the host which version they mean."):format(entry.version), "install")
    end
    local standing, detail = browse.standing(id)
    if standing == "older" then return could_not(id, version, ("It needs Wax %s or newer. Update Wax to get it."):format(detail), "install") end
    local finished, result, reason = false, nil, nil
    local begun, why = browse.add(id, { required = true, done = function(ok, problem)
        finished, result, reason = true, ok, problem
    end })
    if not begun then return could_not(id, version, tostring(why) .. ".", "install") end
    until_ = sched.clock() + 120
    while not finished and sched.clock() < until_ do task.wait(0.25) end
    if not result then return could_not(id, version, (reason and (tostring(reason) .. ".") or "The download did not finish."), "install") end
    if not wait_for(id, 10) then return could_not(id, version, "It was downloaded but did not appear in the mods folder.", "install") end
    local on = Wax.mods.set_enabled(id, true)
    busy[id] = nil
    pending[id] = nil
    if on then
        log:info("%s %s was put in from the catalogue and switched on: the host requires it", id, entry.version)
        notify(("Installed %s %s: the host requires it."):format(entry.name, entry.version),
            { title = "Mods a server requires", kind = "good", icon = "package-check", seconds = 10 })
    end
    changed()
end

-- A newer version than the one here: the updater puts it in when it offers one, else it is asked to look.
local function update(id, version)
    local updater = Wax.update
    local state = updater and updater.state and updater.state()
    if state and state.available[id] and not M.newer(version, state.available[id]) then
        if updater.install(id) then
            pending[id] = nil
            log:info("%s is updated to %s: the host requires it", id, state.available[id])
            notify(("Updating %s to %s: the host requires it."):format(name_of(id), state.available[id]), { title = "Mods a server requires", seconds = 8 })
            changed()
            return
        end
    end
    if state and state.mods[id] and updater.check_now then updater.check_now() end
    could_not(id, version, state and state.mods[id] and "A newer version is needed and the catalogue is being asked for it."
        or "A newer version is needed. This copy did not come from the catalogue, so put the new one in yourself.", "update")
end

local function act(decision)
    if busy[decision.id] then return end
    if decision.action == "enable" then
        enable(decision.id)
    elseif decision.action == "install" then
        local previous = scope.enter(nil)
        task.label(task.spawn(install, decision.id, decision.version), "required mods: " .. decision.id)
        scope.leave(previous)
    elseif decision.action == "update" then
        update(decision.id, decision.version)
    end
end

-- The player said yes to one on the Mods page (mode "ask"), or asked again for one that failed.
function M.install_pending(id)
    local entry = pending[id]
    if not entry then return false end
    act({ id = id, version = entry.version, action = entry.action })
    return true
end

-- What the host asked, in the frame loop. mode: the setting, taken from the saved one when not given.
function M.heard(text, mode)
    local list = M.parse(text)
    if not list then return false end
    mode = mode or settings.mode
    asked = {}
    for _, entry in ipairs(list) do asked[entry.id] = { version = entry.version } end
    local decisions = M.decide(list, installed_here())
    local open = M.open(decisions, mode)
    if #open == 0 then
        if #list > 0 then log:info("the host requires %d mods and every one is here", #list) end
        changed()
        return true
    end
    local names = {}
    for _, decision in ipairs(open) do
        names[#names + 1] = decision.id .. (decision.version and (" " .. decision.version) or "")
        if mode == "ask" then pending[decision.id] = { version = decision.version, action = decision.action, why = "The host requires it." } end
    end
    log:info("the host requires: %s (setting: %s)", table.concat(names, ", "), mode)
    if mode == "ask" then
        notify(("The host requires %s. Open the Wax menu, Mods page, to put %s in."):format(table.concat(names, ", "), #names == 1 and "it" or "them"),
            { title = "Mods a server requires", seconds = 12 })
    elseif mode == "install" then
        for _, decision in ipairs(open) do act(decision) end
    end
    changed()
    return true
end

-- Inside the engine's call: the line is copied and blanked, so the chat box has nothing to show. Nothing of a mod runs here.
local function caught(_, _, message)
    local raw = message:get()
    local text = raw
    if type(raw) == "userdata" then
        local ok, said = pcall(function() return raw:ToString() end)
        text = ok and said or nil
    end
    if type(text) ~= "string" or text:sub(1, 1) ~= "\1" then return nil end
    -- the FString is emptied in place, so the chat box gets nothing. set() is tried for a build whose parameter is a plain string
    local blanked = type(raw) == "userdata" and pcall(function() raw:Clear() end)
    if not blanked then pcall(message.set, message, "") end
    return text
end

-- The chat box keeps its lines as BP_ChatboxItem_C objects in ListView_35 (names from the game model). Ones that carry
-- our line are taken off, since the game added the line before the hook could blank it.
M.CHATBOX, M.LIST, M.ITEM_TEXT = "UMG_Chatbox_C", "ListView_35", "Message"
local function hide_in_chat()
    local ok, problem = pcall(function()
        local box = FindFirstOf(M.CHATBOX)
        if not box or not box:IsValid() then return end
        local list = box[M.LIST]
        if not list:IsValid() then return end
        local items = list.ListItems
        local gone = {}
        for i = 1, items:GetArrayNum() do
            local item = items[i]
            if item:IsValid() then
                local text = item[M.ITEM_TEXT]:ToString()
                if type(text) == "string" and text:sub(1, 1) == "\1" then gone[#gone + 1] = item end
            end
        end
        for _, item in ipairs(gone) do list:RemoveItem(item) end
    end)
    if not ok then log:warn("the line could not be taken off the chat box: %s", tostring(problem)) end
end

local function listen()
    if listening then return true end
    local ok, hooks = pcall(Wax.import, "engine.hooks")
    if not ok then return false, tostring(hooks) end
    local made, undo = pcall(no_mod, hooks.listen, M.HOOK, { reach = hooks.NET, catch = caught, deliver = function(text)
        hide_in_chat()
        M.heard(text)
    end, label = "required mods" })
    if not made then return false, tostring(undo) end
    listening = undo
    return true
end

function M.start()
    if started then return end
    started = true
    settings = storage.load("wax", "required", settings)
    if not M.MODE_WORDS[settings.mode] then settings.mode = "install" end
    local loaded = storage.load("wax", "server", { required = {} })
    server.required = {}
    for _, id in ipairs(type(loaded.required) == "table" and loaded.required or {}) do
        if type(id) == "string" and id:match(ID) then server.required[#server.required + 1] = id end
    end
    local ok, why = listen()
    if not ok then log:warn("the chat line a host sends cannot be heard here: %s", tostring(why)) end
    local session_ok, session = pcall(Wax.import, "world.session")
    if session_ok and session.api and session.api.Joined then
        local previous = scope.enter(nil)
        local link_ok, link = pcall(session.api.Joined.Connect, session.api.Joined, on_joined)
        scope.leave(previous)
        if link_ok then joined_link = link else log:warn("players who join cannot be told which mods are required: %s", tostring(link)) end
    end
    local previous = scope.enter(nil)
    file_task = task.label(task.spawn(function()
        skip_read = true
        while true do
            if sides.kind() == "host" or sides.kind() == "server" then pcall(read_server_file) end
            task.wait(M.FILE_SECONDS)
        end
    end), "required mods: file")
    scope.leave(previous)
end

function M.stop()
    if listening then pcall(listening) end
    if joined_link then pcall(joined_link.Disconnect, joined_link) end
    if file_task then task.cancel(file_task) end
    listening, joined_link, file_task, started = nil, nil, nil, false
end

function M.stats()
    return { listening = listening ~= nil, mode = settings.mode, required = #server.required, pending = #M.pending() }
end

return M
