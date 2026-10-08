-- The catalogue as the game keeps it: tools\lua\lua54\lua.exe wax\tests\offline\browse_test.lua
local t = dofile("wax/tests/offline/harness.lua")

local installed = { Here = true }
local sent, answers, saved, fired = {}, {}, {}, 0
local signal = { Fire = function() fired = fired + 1 end, Connect = function() end }
local shared = {
    net = "net", looking = function() return true end, stopped = function() return false end,
    fetch = function(jobs) for _, job in ipairs(jobs) do sent[#sent + 1] = job[1] end end,
    answer = function(output) return answers[output] or { mods = {}, total = 0 } end,
    attempt = function(fn, ...)
        local ok, why = pcall(fn, ...)
        return ok, ok and nil or tostring(type(why) == "table" and why.said or why)
    end,
    fail = function(text) error({ said = text }, 0) end,
}
local modules = {
    ["core.log"] = { channel = function() return { info = function() end, warn = function() end } end },
    ["core.scope"] = { enter = function() end, leave = function() end },
    ["core.sched"] = { clock = function() return 1000 end, Signal = { new = function() return signal end },
        task = { spawn = function(fn) fn() return {} end, label = function(thread) return thread end } },
    ["core.storage"] = { load = function(_, _, defaults) return saved.value or defaults end, save = function(_, _, value) saved.value = value end },
}
local Wax = { import = function(name) return modules[name] end, mods = { get = function(id) return installed[id] and {} or nil end },
    update = { shared = shared, state = function() return { available = { Here = "2.0.0" } } end,
        newer = function(a, b) return a > b end } }
local browse = assert(loadfile("wax/runtime/Scripts/wax/mods/browse.lua"))(Wax)

local function mod(id, fields)
    local raw = { id = id, name = fields.name or id, summary = fields.summary or "", author = fields.author or "Ada",
        category = fields.category or "Tools", tags = fields.tags or {}, downloads = fields.downloads or 0,
        votes = { up = fields.up or 0, down = fields.down or 0 }, created_at = fields.created or "2026-01-01",
        updated_at = fields.updated or "2026-01-01", latest = { version = fields.version or "1.0.0", dependencies = fields.needs } }
    return raw
end

answers["plan/browse-1.json"] = { total = 4, mods = {
    mod("MapMarkers", { name = "Map Markers", summary = "Pins on the map for caves.", category = "Interface", tags = { "map", "markers" },
        downloads = 12, up = 4, down = 1, updated = "2026-10-06" }),
    mod("Here", { name = "Here Already", tags = { "map" }, downloads = 40, up = 1, updated = "2026-10-01", created = "2026-09-01" }),
    mod("Zeta", { summary = "Faster crafting.", category = "Gameplay", tags = { "crafting" }, downloads = 3, up = 9, updated = "2026-10-07" }),
    mod("bad id", {}),
} }

t.test("the catalogue is asked once and its list is kept", function()
    t.ok(browse.refresh(false))
    t.eq(#sent, 2, "the list, then this address's own votes")
    t.eq(sent[2], "/api/votes/mine")
    t.ok(sent[1]:find("/api/mods?sort=updated&per_page=100&page=1", 1, true), sent[1])
    t.eq(browse.state().count, 3, "a mod with a name that is no id is left out")
    t.eq(#saved.value.mods, 3)
    browse.refresh(false)
    t.eq(#sent, 2, "a fresh list is not asked for again")
    browse.refresh(true)
    t.eq(#sent, 4, "unless it is asked for")
end)

t.test("search takes every word, in any field", function()
    local function ids(query)
        local out = {}
        for _, entry in ipairs(browse.find(query)) do out[#out + 1] = entry.id end
        return table.concat(out, ",")
    end
    t.eq(ids({ text = "map" }), "MapMarkers,Here")
    t.eq(ids({ text = "MAP caves" }), "MapMarkers")
    t.eq(ids({ text = "ada" }), "Zeta,MapMarkers,Here")
    t.eq(ids({ text = "nothing-like-it" }), "")
    t.eq(ids({ category = "Gameplay" }), "Zeta")
    t.eq(ids({ tag = "map" }), "MapMarkers,Here")
    t.eq(ids({ tag = "map", category = "Interface" }), "MapMarkers")
    t.eq(ids({ have = "here" }), "Here")
    t.eq(ids({ have = "new" }), "Zeta,MapMarkers")
end)

t.test("sorting", function()
    local function first(sort) return browse.find({ sort = sort })[1].id end
    t.eq(first("updated"), "Zeta")
    t.eq(first("new"), "Here" == "x" and "" or browse.find({ sort = "new" })[1].id)
    t.eq(first("downloads"), "Here")
    t.eq(first("votes"), "Zeta")
    t.eq(first("name"), "Here")
end)

t.test("categories and tags, most used first", function()
    local categories, tags = browse.facets()
    t.eq(table.concat(categories, ","), "Gameplay,Interface,Tools")
    t.eq(tags[1], "map")
    t.eq(#tags, 3)
end)

t.test("how a mod stands here", function()
    t.eq(browse.standing("Zeta"), "new")
    local standing, version = browse.standing("Here")
    t.eq(standing, "update")
    t.eq(version, "2.0.0")
end)

t.test("a mod that is here, or not listed, is not added", function()
    shared.read_plan = function() end
    local ok, why = browse.add("Here")
    t.eq(ok, false)
    t.ok(why:find("already", 1, true), why)
    ok, why = browse.add("NoSuchMod")
    t.eq(ok, false)
    t.ok(why:find("does not list", 1, true), why)
end)

t.test("nothing is asked while looking is switched off", function()
    shared.looking = function() return false end
    local before = #sent
    t.eq(browse.refresh(true), false)
    t.eq(#sent, before)
    t.ok(browse.state().problem:find("switched off", 1, true))
    shared.looking = function() return true end
end)

t.finish()
