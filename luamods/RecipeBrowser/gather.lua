-- Which items a crafting tree stops at: what is mined, hunted, picked or grown, even where the game also has a recipe for it.

local gather = {}

gather.CATEGORIES = { ores = true, animal_part = true, vestiges = true, plants = true, fish = true, corpses = true, creatures = true }
gather.NAMES = { wood = true, charcoal = true, egg = true, wool = true, limestone = true, stone = true }

local kept = setmetatable({}, { __mode = "k" })

-- The choice table for tree.build: false for every item to stop at. Worked out once for a model that has its recipes.
function gather.choice(m)
    local choice = kept[m]
    if choice then return choice end
    choice = {}
    for key, item in pairs(m.items) do
        local home = item.cats and item.cats[1]
        if (item.hints and item.hints[1]) or (home and gather.CATEGORIES[home]) or gather.NAMES[key] then choice[key] = false end
    end
    if m.stage and m.stage >= 2 then kept[m] = choice end
    return choice
end

return gather
