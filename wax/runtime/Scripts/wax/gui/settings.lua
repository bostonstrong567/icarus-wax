-- A settings window from a list of fields. The values are kept on disk and Changed says when one moves.
local Wax = ...
local sched = Wax.import("core.sched")
local storage = Wax.import("core.storage")

local M = {}
M.CUSTOM = "Custom"
M.NAME = "settings"

local function kind_of(field)
    if field.slider then return "slider" end
    if field.toggle then return "toggle" end
    if field.choices then return "choices" end
    if field.text then return "text" end
    return nil
end

local function has_choice(choices, value)
    for _, choice in ipairs(choices) do
        if choice == value then return true end
    end
    return false
end

-- The value as the field can hold it, or nil when it cannot.
local function fit(field, value)
    local kind = kind_of(field)
    if kind == "slider" then
        if type(value) ~= "number" then return nil end
        local range = field.slider
        return math.max(range.min or 0, math.min(range.max or 1, value))
    elseif kind == "toggle" then
        if type(value) == "boolean" then return value end
    elseif kind == "choices" then
        if has_choice(field.choices, value) then return value end
    elseif type(value) == "string" then
        return value
    end
    return nil
end

local function check(spec)
    if type(spec) ~= "table" then
        error("ui.Settings takes a table such as { title = \"My Mod\", fields = { ... } }", 3)
    end
    if type(spec.fields) ~= "table" or #spec.fields == 0 then
        error("ui.Settings needs fields: a list such as { { \"speed\", \"Speed\", slider = { min = 1, max = 10 }, default = 2 } }", 3)
    end
    local keys = {}
    for index, field in ipairs(spec.fields) do
        if type(field) ~= "table" then error(("field %d is not a table"):format(index), 3) end
        if field.heading == nil then
            local key, caption = field[1], field[2]
            if type(key) ~= "string" or key == "" then
                error(("field %d needs a key as its first entry, such as \"speed\""):format(index), 3)
            end
            if keys[key] then error(("two fields are named %s"):format(key), 3) end
            if type(caption) ~= "string" then error(("field %s needs a caption as its second entry"):format(key), 3) end
            local kind = kind_of(field)
            if not kind then
                error(("field %s needs one of slider = { min = , max = }, toggle = true, choices = { ... } or text = true"):format(key), 3)
            end
            if kind == "slider" and type(field.slider) ~= "table" then error(("field %s: slider is a table such as { min = 1, max = 10, step = 1 }"):format(key), 3) end
            if kind == "choices" and (type(field.choices) ~= "table" or #field.choices == 0) then error(("field %s: choices is a list of values"):format(key), 3) end
            if field.default == nil then error(("field %s needs a default"):format(key), 3) end
            if fit(field, field.default) ~= field.default then error(("field %s: the default %s does not fit the field"):format(key, tostring(field.default)), 3) end
            keys[key] = field
        elseif type(field.heading) ~= "string" then
            error(("field %d: heading is a string"):format(index), 3)
        end
    end
    if spec.presets ~= nil then
        if type(spec.presets) ~= "table" then error("presets is a list such as { { \"Balanced\", { speed = 2 } } }", 3) end
        for index, preset in ipairs(spec.presets) do
            if type(preset) ~= "table" or type(preset[1]) ~= "string" or type(preset[2]) ~= "table" then
                error(("preset %d is { \"Name\", { key = value, ... } }"):format(index), 3)
            end
            if preset[1] == M.CUSTOM then error(("a preset cannot be named %s: that is the name for values no preset has"):format(M.CUSTOM), 3) end
            for key, value in pairs(preset[2]) do
                local field = keys[key]
                if not field then error(("preset %s sets %s, which is not a field"):format(preset[1], tostring(key)), 3) end
                if fit(field, value) ~= value then error(("preset %s: %s does not fit %s"):format(preset[1], tostring(value), key), 3) end
            end
        end
    end
    return keys
end

-- make_window is ui.Window, passed in so this module does not depend on gui.init.
function M.create(spec, owner, make_window)
    local keys = check(spec)
    local name = spec.name or M.NAME
    local defaults = {}
    for key, field in pairs(keys) do defaults[key] = field.default end
    local values = storage.load(owner, name, defaults)
    for key, field in pairs(keys) do
        local fitted = fit(field, values[key])
        if fitted == nil then fitted = field.default end
        values[key] = fitted
    end
    local settings = { values = values, controls = {}, Changed = sched.Signal.new("Changed") }
    local controls = settings.controls
    local preset_control = nil

    local function save() storage.save(owner, name, values) end

    local function preset_name()
        for _, preset in ipairs(spec.presets or {}) do
            local all = true
            for key, value in pairs(preset[2]) do
                if values[key] ~= value then all = false break end
            end
            if all then return preset[1] end
        end
        return M.CUSTOM
    end

    local function show_preset()
        if preset_control then preset_control:Set(preset_name()) end
    end

    -- Writes several values at once: the controls follow, then Changed fires for each one that moved.
    local function put_many(given)
        local moved = {}
        for key, value in pairs(given) do
            if values[key] ~= value then
                values[key] = value
                moved[#moved + 1] = key
            end
        end
        if #moved == 0 then return false end
        table.sort(moved)
        save()
        for _, key in ipairs(moved) do
            if controls[key] then controls[key]:Set(values[key]) end
        end
        show_preset()
        for _, key in ipairs(moved) do settings.Changed:Fire(key, values[key]) end
        return true
    end

    local function from_control(key, value)
        if values[key] == value then return end
        values[key] = value
        save()
        show_preset()
        settings.Changed:Fire(key, value)
    end

    local window = make_window({
        title = spec.title, icon = spec.icon, width = spec.width, height = spec.height, x = spec.x, y = spec.y, key = spec.key,
    })
    settings.window = window
    local section = window:Section(spec.section or "Settings", { collapsible = false })
    settings.section = section
    if spec.presets then
        local names = {}
        for index, preset in ipairs(spec.presets) do names[index] = preset[1] end
        names[#names + 1] = M.CUSTOM
        preset_control = section:Dropdown("Preset", names, preset_name(), function(choice) settings:UsePreset(choice) end)
    end
    for _, field in ipairs(spec.fields) do
        if field.heading then
            section:Heading(field.heading)
        else
            local key, caption, kind = field[1], field[2], kind_of(field)
            local control
            if kind == "slider" then
                local range = field.slider
                control = section:Slider(caption, {
                    min = range.min, max = range.max, step = range.step, format = range.format, value = values[key], live = range.live == true,
                }, function(value) from_control(key, value) end)
            elseif kind == "toggle" then
                control = section:Toggle(caption, values[key], function(on) from_control(key, on) end)
            elseif kind == "choices" then
                control = section:Dropdown(caption, field.choices, values[key], function(choice) from_control(key, choice) end)
            else
                local hint = type(field.text) == "table" and field.text.hint or nil
                control = section:Input(caption, { text = values[key], hint = hint }, function(text) from_control(key, text) end)
            end
            controls[key] = control
            if field.help then section:Label(field.help, { dim = true }) end
        end
    end
    section:Button("Defaults", function() put_many(defaults) end, { icon = "rotate-ccw", stretch = false })

    function settings:Get(key)
        if not keys[key] then error(("%s is not a setting here"):format(tostring(key)), 2) end
        return values[key]
    end

    function settings:Set(key, value)
        local field = keys[key]
        if not field then error(("%s is not a setting here"):format(tostring(key)), 2) end
        local fitted = fit(field, value)
        if fitted == nil then error(("%s cannot be %s"):format(key, tostring(value)), 2) end
        return put_many({ [key] = fitted })
    end

    function settings:UsePreset(preset)
        for _, candidate in ipairs(spec.presets or {}) do
            if candidate[1] == preset then return put_many(candidate[2]) end
        end
        if preset == M.CUSTOM then return false end
        error(("there is no preset named %s"):format(tostring(preset)), 2)
    end

    function settings:Preset() return preset_name() end
    function settings:Reset() return put_many(defaults) end
    return settings
end

return M
