-- Live test of the model view (gui/model.lua), for a game where Container:Model is registered and stepped.
-- It is sent several times and goes one step further each time:
--   1. in a prospect: makes a window "Model test" with a deer in it and opens the menu
--   2. a few seconds later: the deer is in the picture, one actor carries it, its picture belongs to the game
--   3. after a map change with the window left up (leave the prospect, or load another): nothing was touched that the
--      engine freed, no actor of the old world is left, and a view that still exists has a new actor in the new world
-- The last send takes the window away and returns { passed, failed, failures, details }.
-- Send it with WaxModelViewTest = "stop" set first to end it at any step.
local state = Wax._model_view_test
local checks = state and state.checks or {}
local function check(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok and true or false, detail = detail } end

local function tagged()
    local controller = Wax.game.LocalPlayer
    local found, count = {}, 0
    if controller then
        StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetAllActorsWithTag(controller.Raw, FName("WaxModel"), found)
        for index = 1, #found do
            if found[index]:get():IsValid() then count = count + 1 end
        end
    end
    return count
end

local function finish()
    if state and state.window and not state.window.destroyed then state.window:Destroy() end
    Wax._model_view_test = nil
    local passed, failures, details = 0, {}, {}
    for _, entry in ipairs(checks) do
        if entry.ok then passed = passed + 1 else failures[#failures + 1] = entry.name .. ": " .. tostring(entry.detail) end
        details[#details + 1] = (entry.ok and "ok   " or "FAIL ") .. entry.name .. (entry.detail and (" (" .. tostring(entry.detail) .. ")") or "")
    end
    return { passed = passed, failed = #failures, failures = failures, details = details }
end

if rawget(_G, "WaxModelViewTest") == "stop" then
    WaxModelViewTest = nil
    return finish()
end

local model = Wax.modules["gui.model"]
if not state then
    if not model or type(Wax.import("gui.controls").Container.Model) ~= "function" then
        check("Container:Model is registered", false, "gui/controls.lua does not call model.install yet")
        return finish()
    end
    local look, why = Wax.game.Creatures:GetModel("Deer")
    if not look then
        check("game.Creatures:GetModel gives a deer", false, why)
        return finish()
    end
    state = { checks = checks, map = Wax.game.MapName, errors = #Wax.guard.errors(), step = 1, events = {}, before = model.stats(),
        tagged = tagged() }
    state.window = Wax.ui.Window({ title = "Model test", width = 300, height = 320, remember = false })
    state.view = state.window:Model(look)
    state.view.Loaded:Connect(function() state.events[#state.events + 1] = "Loaded" end)
    state.view.Failed:Connect(function(reason) state.events[#state.events + 1] = "Failed: " .. tostring(reason) end)
    if not Wax.ui.IsOpen() then Wax.ui.Open() end
    Wax._model_view_test = state
    return { running = true, step = 1, next = "send this file again in a few seconds" }
end

local stats = model.stats()
if state.step == 1 then
    check("the deer is in the picture", state.view:IsLoaded() and state.events[1] == "Loaded", table.concat(state.events, "; "))
    check("one actor carries it", stats.actors == state.before.actors + 1 and tagged() == state.tagged + 1,
        ("%d in the module and %d in the world, %d and %d before"):format(stats.actors, tagged(), state.before.actors, state.tagged))
    local owned = 0
    for _, target in ipairs(FindAllOf("TextureRenderTarget2D") or {}) do
        if target:IsValid() and target:GetFullName():find("GameInstance", 1, true) then owned = owned + 1 end
    end
    check("its picture belongs to the game instance, not to the world", owned >= 1, owned .. " render targets under the game instance")
    check("no Lua error so far", #Wax.guard.errors() == state.errors, #Wax.guard.errors() - state.errors .. " new")
    state.step, state.ended = 2, stats.ended
    return { running = true, step = 2, next = "change the map with the window left up (leave the prospect), then send this file again" }
end

if Wax.game.MapName == state.map then
    return { running = true, step = 2, next = "the map is still " .. tostring(state.map) .. ": change it, then send this file again" }
end
check("the end of its play told the module about the old actor", stats.ended > state.ended, ("ended %d, was %d"):format(stats.ended, state.ended))
check("no Lua error across the map change", #Wax.guard.errors() == state.errors, #Wax.guard.errors() - state.errors .. " new")
if state.window.destroyed then
    check("the game took the interface away, and no actor or step is left", stats.views == 0 and stats.actors == 0 and stats.tracked == 0,
        ("views %d, actors %d, tracked %d"):format(stats.views, stats.actors, stats.tracked))
    check("no actor of this module is in the new world", tagged() == 0, tagged() .. " tagged")
elseif state.window:IsShowing() then
    check("the view has a new actor in the new world", stats.actors >= 1 and tagged() == stats.actors, ("%d in the module, %d in the world"):format(stats.actors, tagged()))
    check("the model was not announced a second time", #state.events == 1, table.concat(state.events, "; "))
else
    check("the view waits for its window to show again, with no actor", stats.actors == 0 and tagged() == 0,
        ("%d in the module, %d in the world"):format(stats.actors, tagged()))
end
return finish()
