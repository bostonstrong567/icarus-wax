local content = mod.Content
print("Game content:", content.State, content.Reason or "")

local class, why = content:LoadClass("BP_WaxSampleActor")
if class then
    print("Loaded", class.Name, "from", content:ClassPath("BP_WaxSampleActor"))
else
    print("Not loaded:", why)
end
