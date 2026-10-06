-- Step 1: load the helper and call its version probe (exercises the exported constructor, an integer push, the destructor).
local dll = "C:/Program Files (x86)/Steam/steamapps/common/Icarus/Icarus/Binaries/Win64/ue4ss/Mods/Wax/bin/waxco.dll"
local version_fn, err, where = package.loadlib(dll, "wax_native_version")
if not version_fn then return { loaded = false, error = tostring(err), where = tostring(where) } end
local newthread_fn, err2 = package.loadlib(dll, "wax_newthread")
local top_before = select("#", version_fn())
return {
    loaded = true,
    version = version_fn(),
    resultCount = top_before,
    newthreadFound = newthread_fn ~= nil,
    newthreadError = err2,
}
