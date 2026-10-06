-- Removes everything that code run from the editor set up and is still there (windows, tasks, connections)
if not (rawget(_G, "Wax") and Wax.editor) then return 0 end
local removed = 0
for name, owner in pairs(Wax.editor.scopes) do
    if owner.alive then removed = removed + owner:size() end
    owner:destroy()
    Wax.editor.scopes[name] = nil
end
return removed
