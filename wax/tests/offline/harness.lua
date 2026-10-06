-- Minimal test harness for the offline suites.
--   local t = dofile("wax/tests/offline/harness.lua")
--   t.test("name", function() t.eq(1 + 1, 2) end)
--   t.finish()        -- prints the summary and exits non-zero on any failure

local t = { passed = 0, failed = 0, failures = {} }

local function show(value)
    if type(value) == "string" then return ("%q"):format(value) end
    return tostring(value)
end

function t.eq(got, want, what)
    if got ~= want then
        error((what and (what .. ": ") or "") .. "expected " .. show(want) .. ", got " .. show(got), 2)
    end
end

function t.ok(value, what)
    if not value then error(what or "expected a true value", 2) end
end

-- Asserts that fn raises and that the message contains `fragment` (plain text).
function t.raises(fn, fragment, what)
    local ok, err = pcall(fn)
    if ok then error((what or "call") .. " should have raised", 2) end
    if fragment and not tostring(err):find(fragment, 1, true) then
        error((what or "error") .. " should mention " .. show(fragment) .. ", got " .. show(tostring(err)), 2)
    end
    return err
end

function t.test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        t.passed = t.passed + 1
    else
        t.failed = t.failed + 1
        t.failures[#t.failures + 1] = name .. "\n    " .. tostring(err):gsub("\n", "\n    ")
    end
end

function t.finish(suite)
    for _, failure in ipairs(t.failures) do io.stderr:write("FAIL ", failure, "\n") end
    print(("%s: %d passed, %d failed"):format(suite or "tests", t.passed, t.failed))
    os.exit(t.failed == 0 and 0 or 1)
end

-- A fresh Wax core for one suite, rooted at the workspace's runtime folder.
function t.new_wax()
    return dofile("wax/runtime/Scripts/wax/loader.lua")("wax/runtime")
end

return t
