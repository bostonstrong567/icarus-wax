-- Mounts and models: tools\lua\lua54\lua.exe wax\tests\offline\mounts_test.lua
-- The module runs against stand-ins for the engine: what it calls, in what order, and what it puts back.
local t = dofile("wax/tests/offline/harness.lua")

local next_address = 100
local function object(fields)
    next_address = next_address + 1
    local self = fields or {}
    self.address = next_address
    self.valid = self.valid ~= false
    function self:IsValid() return self.valid end
    function self:GetAddress() return self.valid and self.address or 0 end
    function self:GetFullName() return self.full or "Object /Game/Thing.Thing" end
    function self:GetFName() return { ToString = function() return self.name or "Thing" end } end
    function self:GetClass() return { GetFName = function() return { ToString = function() return self.class or "Object" end } end } end
    return self
end
local NOTHING = object({ valid = false })

local function visible(fields)
    local self = object(fields)
    self.shown = self.shown ~= false
    function self:IsVisible() return self.shown end
    function self:SetVisibility(on) self.shown = on end
    return self
end

local skeleton_a, skeleton_b = object({ name = "SK_Moa_Skeleton" }), object({ name = "SK_Horse_Skeleton" })
local function mesh_asset(name, skeleton)
    return object({ full = "SkeletalMesh /Game/" .. name .. "." .. name, class = "SkeletalMesh", Skeleton = skeleton })
end
local function material_asset(name) return object({ full = "MaterialInstanceConstant /Game/" .. name .. "." .. name, class = "MaterialInstanceConstant" }) end

local loaded = {}
local function instance(raw, class)
    return { Raw = raw, ClassName = class or raw.class, IsA = function(_, what)
        return what == raw.class or (what == "MaterialInterface" and raw.class == "MaterialInstanceConstant")
    end, IsValid = function() return raw.valid end }
end

local function mount()
    local body = visible({ SkeletalMesh = mesh_asset("SK_Moa", skeleton_a), materials = { [0] = material_asset("M_Moa") }, sets = 0 })
    local coat = visible({ class = "GFurComponent" })
    function body:GetNumChildrenComponents() return 1 end
    function body:GetChildComponent() return coat end
    function body:SetSkeletalMesh(mesh) self.SkeletalMesh, self.sets = mesh, self.sets + 1 end
    function body:GetMaterial(index) return self.materials[index] or NOTHING end
    function body:SetMaterial(index, material) self.materials[index] = material end
    local playing = NOTHING
    function body:GetAnimInstance() return { GetCurrentActiveMontage = function() return playing end } end
    local saddle = visible({ VisibilityBasedAnimTickOption = 2 })
    local seat = object({ SaddleSkeletalMesh = saddle })
    local raw = object({ Mesh = body, ChildActor_Seat = object({ ChildActor = seat }), Inventory = object({}),
        MountData = { RowName = { ToString = function() return "Moa" end } } })
    function raw.Inventory:GetInventory() return object({ slots = true }) end
    local self = instance(raw, "BP_Mount_Moa_C")
    self.calls = {}
    function self:SetMountName(name) self.calls[#self.calls + 1] = "name " .. name end
    function self:SetMountOwner() self.calls[#self.calls + 1] = "owner" end
    function self:Server_PlayActionMontage(montage, cost, rate, section)
        self.calls[#self.calls + 1] = ("montage %s %s %s"):format(montage.Raw.full, cost.RowName, section)
    end
    return self, { body = body, coat = coat, saddle = saddle, raw = raw, play = function(on) playing = on and object({}) or NOTHING end }
end

-- the module with its surroundings
local spec, undone, undos, timers, warned = nil, 0, {}, {}, {}
local world = { ground = { X = 0, Y = 0, Z = 0 }, spawned = nil, given = {}, host = true }
local player = object({})
function player:K2_GetActorLocation() return { X = 0, Y = 0, Z = 100 } end
function player:GetActorForwardVector() return { X = 1, Y = 0, Z = 0 } end

local Wax = { game = {
    IsHost = true, Me = { Exists = true, Raw = player }, LocalPlayer = { PlayerState = {} },
    Assets = { Load = function(_, path)
        local found = loaded[path]
        if not found then return nil, "the game has no asset at " .. path end
        return found
    end },
    Creatures = { GetInfo = function(_, kind) return kind == "Moa" and { Mount = { Variant = "Mount_Moa" } } or nil end },
    Data = { Table = function() return { Row = function(_, kind)
        return { Animations = kind == "Moa" and { ["BT.Mount.Animation.Attack"] = "/Game/Moa_Attack.Moa_Attack" } or {} }
    end } end },
    Library = function() return { Raw = { SpawnNewAI = function(_, _, row) world.row = row.RowName return world.spawned and world.spawned.Raw or NOTHING end } } end,
    wrap = function(raw)
        if raw.slots then return { Give = function(_, item, count) world.given[#world.given + 1] = item return world.refuse and 0 or count, world.refuse end } end
        return world.spawned
    end,
} }
local modules = {
    ["engine.easy"] = { class = function(_, given) spec = given return function() undone = undone + 1 end end },
    ["core.scope"] = { own = function(undo) undos[#undos + 1] = undo return { remove = function(_, slot) undos[slot] = false end }, #undos end,
        enter = function() return nil end, leave = function() end, current = function() return nil end,
        run = function(_, fn, ...) return fn(...) end },
    ["core.sched"] = { task = { every = function(_, fn) timers[#timers + 1] = fn return #timers end, cancel = function(id) timers[id] = false end,
        spawn = function(fn) fn() end, wait = function() end } },
    ["core.co"] = { isyieldable = function() return false end },
    ["core.suggest"] = { phrase = function() return "" end },
    ["core.log"] = { channel = function() return { warn = function(_, text, ...) warned[#warned + 1] = text:format(...) end } end },
    ["world.creatures"] = { api = {} },
}
function Wax.import(name) return assert(modules[name], name) end
function FName(text) return text end
function LoadAsset(path)
    for _, held in pairs(loaded) do
        if held.Raw.full:match(" (.+)$") == path then return held.Raw end
    end
    return NOTHING
end
function StaticFindObject()
    return object({ K2_ProjectPointToNavigation = function(_, _, _, out)
        if not world.ground then return false end
        out.X, out.Y, out.Z = world.ground.X, world.ground.Y, world.ground.Z
        return true
    end })
end

local M = assert(loadfile("wax/runtime/Scripts/wax/world/mounts.lua"))(Wax)
M.start()
local api = modules["world.creatures"].api
local function step()
    for _, fn in ipairs(timers) do
        if fn then fn() end
    end
end

local bird = instance(mesh_asset("SK_Bird", skeleton_a))
local skin = instance(material_asset("M_Bird"))
loaded["/Game/SK_Moa.SK_Moa"] = instance(mesh_asset("SK_Moa", skeleton_a))
loaded["/Game/M_Moa.M_Moa"] = instance(material_asset("M_Moa"))
loaded["/Game/Moa_Attack.Moa_Attack"] = instance(object({ full = "AnimMontage /Game/Moa_Attack.Moa_Attack", class = "AnimMontage" }))

t.test("SetModel puts the mesh and the material on and hides the fur and the saddle", function()
    local self, parts = mount()
    t.eq(spec.fields.HasModel(self, parts.raw), false)
    spec.methods.SetModel(self, parts.raw, { mesh = bird, materials = { [1] = skin }, fur = false, saddle = false })
    t.eq(parts.body.SkeletalMesh, bird.Raw)
    t.eq(parts.body.materials[0], skin.Raw)
    t.eq(parts.coat.shown, false)
    t.eq(parts.saddle.shown, false)
    t.eq(parts.saddle.VisibilityBasedAnimTickOption, 0, "the unseen saddle keeps following the body")
    t.eq(spec.fields.HasModel(self, parts.raw), true)
    spec.methods.ResetModel(self, parts.raw)
end)

t.test("fur and saddle are left alone unless asked", function()
    local self, parts = mount()
    spec.methods.SetModel(self, parts.raw, { mesh = bird })
    t.eq(parts.coat.shown, true)
    t.eq(parts.saddle.shown, true)
    spec.methods.ResetModel(self, parts.raw)
end)

t.test("a mesh on another skeleton is refused, with both names", function()
    local self, parts = mount()
    local horse = instance(mesh_asset("SK_Horse", skeleton_b))
    t.raises(function() spec.methods.SetModel(self, parts.raw, { mesh = horse }) end, "SK_Horse_Skeleton")
    t.eq(parts.body.sets, 0)
    t.eq(spec.fields.HasModel(self, parts.raw), false)
end)

t.test("a wrong option and a wrong kind of asset are said plainly", function()
    local self, parts = mount()
    t.raises(function() spec.methods.SetModel(self, parts.raw, { mesh = bird, colour = 1 }) end, "no option 'colour'")
    t.raises(function() spec.methods.SetModel(self, parts.raw, { mesh = skin }) end, "not a skeletal mesh")
    t.raises(function() spec.methods.SetModel(self, parts.raw, { mesh = bird, materials = { [1] = bird } }) end, "not a material")
    t.raises(function() spec.methods.SetModel(self, parts.raw, {}) end, "needs mesh")
end)

t.test("the model is put back on after the game wrote its own skin again", function()
    local self, parts = mount()
    spec.methods.SetModel(self, parts.raw, { mesh = bird, materials = { [1] = skin }, fur = false })
    parts.body.materials[0] = loaded["/Game/M_Moa.M_Moa"].Raw
    parts.coat.shown = true
    step()
    t.eq(parts.body.materials[0], skin.Raw)
    t.eq(parts.coat.shown, false)
    t.eq(parts.body.sets, 1, "the mesh was not set a second time")
    spec.methods.ResetModel(self, parts.raw)
end)

t.test("ResetModel gives the creature its own mesh, material, fur and saddle back", function()
    local self, parts = mount()
    spec.methods.SetModel(self, parts.raw, { mesh = bird, materials = { [1] = skin }, fur = false, saddle = false })
    t.eq(spec.methods.ResetModel(self, parts.raw), true)
    t.eq(parts.body.SkeletalMesh.full, "SkeletalMesh /Game/SK_Moa.SK_Moa")
    t.eq(parts.body.materials[0].full, "MaterialInstanceConstant /Game/M_Moa.M_Moa")
    t.eq(parts.coat.shown, true)
    t.eq(parts.saddle.shown, true)
    t.eq(spec.methods.ResetModel(self, parts.raw), false, "nothing left to put back")
end)

t.test("the mod's unload puts the creature back", function()
    local self, parts = mount()
    spec.methods.SetModel(self, parts.raw, { mesh = bird })
    undos[#undos]()
    t.eq(parts.body.SkeletalMesh.full, "SkeletalMesh /Game/SK_Moa.SK_Moa")
    t.eq(spec.fields.HasModel(self, parts.raw), false)
end)

t.test("a second SetModel replaces the first and still remembers the creature's own", function()
    local self, parts = mount()
    local other = instance(mesh_asset("SK_Other", skeleton_a))
    spec.methods.SetModel(self, parts.raw, { mesh = bird })
    spec.methods.SetModel(self, parts.raw, { mesh = other })
    t.eq(parts.body.SkeletalMesh, other.Raw)
    spec.methods.ResetModel(self, parts.raw)
    t.eq(parts.body.SkeletalMesh.full, "SkeletalMesh /Game/SK_Moa.SK_Moa")
end)

t.test("a creature that left the world is forgotten without being touched", function()
    local self, parts = mount()
    spec.methods.SetModel(self, parts.raw, { mesh = bird })
    self.Raw = nil
    step()
    t.eq(M.stats().wearing, 0)
end)

t.test("SpawnMount makes the tamed row, names it, gives it to the player and saddles it", function()
    local self = mount()
    world.spawned, world.given, world.refuse = self, {}, nil
    local made = api:SpawnMount("Moa", { name = "Dusty" })
    t.eq(made, self)
    t.eq(world.row, "Mount_Moa", "a kind is taken as its tamed row")
    t.eq(table.concat(self.calls, ", "), "name Dusty, owner")
    t.eq(world.given[1], "Saddle_Standard")
end)

t.test("SpawnMount with saddle = false and owner = false leaves both", function()
    local self = mount()
    world.spawned, world.given = self, {}
    api:SpawnMount("Mount_Moa", { saddle = false, owner = false })
    t.eq(#self.calls, 0)
    t.eq(#world.given, 0)
end)

t.test("SpawnMount says why nothing was made", function()
    world.ground = nil
    t.raises(function() api:SpawnMount("Mount_Moa") end, "no ground")
    world.ground = { X = 0, Y = 0, Z = 0 }
    world.spawned = nil
    t.raises(function() api:SpawnMount("Mount_Nothing") end, "made nothing")
    t.raises(function() api.SpawnMount({}, "Mount_Moa") end, "with a colon")
    t.raises(function() api:SpawnMount("Mount_Moa", { nmae = "x" }) end, "no option 'nmae'")
end)

t.test("Strike plays the mount's own attack and waits for a move that is playing", function()
    local self, parts = mount()
    t.eq(spec.methods.Strike(self, parts.raw), true)
    t.eq(self.calls[1], "montage AnimMontage /Game/Moa_Attack.Moa_Attack Mount_Attack None")
    parts.play(true)
    local started, why = spec.methods.Strike(self, parts.raw)
    t.eq(started, false)
    t.ok(why:find("another move", 1, true), why)
    t.eq(#self.calls, 1)
end)

t.test("stop puts every creature back and takes the members away", function()
    local self, parts = mount()
    spec.methods.SetModel(self, parts.raw, { mesh = bird })
    M.stop()
    t.eq(parts.body.SkeletalMesh.full, "SkeletalMesh /Game/SK_Moa.SK_Moa")
    t.eq(api.SpawnMount, nil)
    t.ok(undone >= 1)
end)

t.finish("mounts")
