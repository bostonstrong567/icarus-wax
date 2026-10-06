-- Real widget events (click, hover, toggle, slide, text) delivered to Lua

local Wax = ...
local root = Wax.import("gui.root")
local guard = Wax.import("core.guard")

local events = {}

-- What a delegate passes -> the hidden widget and native function that receive it. The game's own interface calls none of these.
local SINKS = {
    none = { class = "SizeBox", path = "/Script/UMG.SizeBox:ClearMinAspectRatio", name = "ClearMinAspectRatio" },
    bool = { class = "SizeBox", path = "/Script/UMG.Widget:ForceVolatile", name = "ForceVolatile" },
    number = { class = "SizeBox", path = "/Script/UMG.SizeBox:SetMinAspectRatio", name = "SetMinAspectRatio" },
    text = { class = "InputKeySelector", path = "/Script/UMG.InputKeySelector:SetNoKeySpecifiedText", name = "SetNoKeySpecifiedText" },
}

local DELEGATES = {
    OnClicked = "none", OnPressed = "none", OnReleased = "none", OnHovered = "none", OnUnhovered = "none",
    OnMouseCaptureBegin = "none", OnMouseCaptureEnd = "none",
    OnCheckStateChanged = "bool",
    OnValueChanged = "number", OnUserScrolled = "number",
    OnTextChanged = "text", OnTextCommitted = "text",
}

local DECODE = {
    none = function() return nil end,
    bool = function(parameter) return parameter:get() end,
    number = function(parameter) return parameter:get() end,
    text = function(parameter) return parameter:get():ToString() end,
}

local handlers = {}     -- sink address -> wrapped handler
local bindings = {}     -- "<widget address>:<delegate>" -> { sink, kind }
Wax.gui_event_handlers = handlers

-- Real globals, so they survive a reload of the core: which sink functions this game process has hooked.
local hooked = rawget(_G, "WaxGuiHooked")
if not hooked then
    hooked = {}
    rawset(_G, "WaxGuiHooked", hooked)
end

-- Calls that reached a hook: ours, and any made by something else to the same function.
local counts = rawget(_G, "WaxGuiHookCalls")
if not counts then
    counts = { handled = 0, foreign = 0 }
    rawset(_G, "WaxGuiHookCalls", counts)
end

local function ensure_hook(kind)
    local sink = SINKS[kind]
    if hooked[sink.path] then return end
    local decode = DECODE[kind]
    RegisterHook(sink.path, function(context, parameter)
        local wax = rawget(_G, "Wax")
        local table_now = wax and wax.gui_event_handlers
        local handler = table_now and table_now[context:get():GetAddress()]
        if handler then
            counts.handled = counts.handled + 1
            handler(decode(parameter))
        else
            counts.foreign = counts.foreign + 1
        end
    end)
    hooked[sink.path] = true
end

-- Connects handler(value) to widget[delegate]. Returns the disconnect. Call it while the widget exists. A second call does nothing.
function events.connect(widget, delegate, parking, handler)
    local kind = DELEGATES[delegate]
    if not kind then error("unknown widget event " .. tostring(delegate), 2) end
    ensure_hook(kind)
    local sink_info = SINKS[kind]
    local sink = root.new(sink_info.class)
    parking:AddChild(sink)
    local address = sink:GetAddress()
    -- The handler runs inside an engine event: it must never raise into the engine.
    local guarded = guard.wrap("gui " .. delegate, handler)
    handlers[address] = function(...)
        local seen = events.seen
        if seen then pcall(seen, delegate, address) end
        return guarded(...)
    end
    widget[delegate]:Add(sink, sink_info.name)
    local binding_key = widget:GetAddress() .. ":" .. delegate
    bindings[binding_key] = { sink = sink, kind = kind }
    local connected = true
    return function()
        if not connected then return end
        connected = false
        handlers[address] = nil
        bindings[binding_key] = nil
        pcall(function()
            if widget:IsValid() and sink:IsValid() then widget[delegate]:Remove(sink, sink_info.name) end
            if sink:IsValid() then sink:RemoveFromParent() end
        end)
    end, address
end

-- events.seen = fn(delegate, address): runs before every event is delivered (used to close what is open).
events.seen = nil

-- For tests: deliver an event the way the engine would after the delegate fires, without real input.
function events.simulate(widget, delegate, value)
    local binding = bindings[widget:GetAddress() .. ":" .. delegate]
    if not binding then error("nothing is connected to " .. delegate .. " on that widget", 2) end
    local sink = binding.sink
    local call = sink[SINKS[binding.kind].name]
    if binding.kind == "none" then
        call(sink)
    elseif binding.kind == "bool" then
        call(sink, value and true or false)
    elseif binding.kind == "number" then
        call(sink, value)
    else
        call(sink, FText(tostring(value)))
    end
end

-- Forget a handler without touching the widgets (used when a whole window is being destroyed).
function events.forget(address) handlers[address] = nil end

-- Drops every handler without touching a widget (used when the game has removed the whole interface).
function events.forget_all()
    for address in pairs(handlers) do handlers[address] = nil end
    bindings = {}
end

function events.count()
    local n = 0
    for _ in pairs(handlers) do n = n + 1 end
    return n
end

function events.calls() return { handled = counts.handled, foreign = counts.foreign } end

return events
