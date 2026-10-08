#requires -Version 7
<#
.SYNOPSIS
  Validates the whole workspace: scripts, tools, references, game data, and every mod.
.DESCRIPTION
  Fails (exit 1) on anything broken, missing, stale, duplicated, or not accounted for in tools.json.
  Run after Get-Tools.ps1, after a game update, and before sharing a mod.
  -Wax checks only Wax: its scripts, the offline suites, the VS Code extension and the game class definitions.
  That is the check to run in a copy of the Wax source, which has no game data, pak mods or modding tools.
.EXAMPLE
  .\scripts\Test-Workspace.ps1
  .\scripts\Test-Workspace.ps1 -Wax
#>
[CmdletBinding()]
param([switch]$Wax)
. "$PSScriptRoot\_common.ps1"

$script:failures = 0
$script:warnings = 0
function Report([string]$Level, [string]$Message) {
    $color = @{ ok = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$Level]
    if ($Level -eq 'FAIL') { $script:failures++ } elseif ($Level -eq 'WARN') { $script:warnings++ }
    Write-Host ("  [{0,-4}] {1}" -f $Level, $Message) -ForegroundColor $color
}
function Section([string]$Title) { Write-Host "== $Title ==" -ForegroundColor Cyan }

Section 'Scripts and config'
foreach ($ps in Get-ChildItem $PSScriptRoot -Filter *.ps1) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($ps.FullName, [ref]$null, [ref]$errors)
    if ($errors) { Report FAIL "$($ps.Name): $($errors[0].Message)" }
}
$configs = $Wax ? @('tools.json') : @('tools.json', 'schemas\exmod.schema.json', '.vscode\settings.json')
if (-not $Wax) {
    python -m py_compile (Join-Path $PSScriptRoot 'exmod.py') 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Report FAIL 'exmod.py does not compile' }
}
foreach ($json in $configs) {
    try { Get-Content (Join-Path $Root $json) -Raw | ConvertFrom-Json | Out-Null } catch { Report FAIL "$json is not valid JSON" }
}

if (-not $failures) { Report ok "$((Get-ChildItem $PSScriptRoot -Filter *.ps1).Count) PowerShell scripts and the JSON config all parse" }

if (-not $Wax) {
Section 'Tools'
$manifest = Get-ToolManifest
$declared = @($manifest.tools) + @($manifest.manual)
$before   = $failures
$versions = Join-Path $ToolsDir '.versions.json'
$installed = if (Test-Path $versions) { Get-Content $versions -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
foreach ($tool in $declared) {
    if ($tool.PSObject.Properties['dest']) {
        # A patch layered onto another tool has no folder of its own; it only has to be recorded as applied.
        if (-not $installed[$tool.name]) { Report FAIL "$($tool.name): not applied (run Get-Tools.ps1)" }
        continue
    }
    $dir = Join-Path $ToolsDir $tool.name
    if (-not (Test-Path $dir)) { Report FAIL "$($tool.name): folder missing (run Get-Tools.ps1)"; continue }
    if ($tool.PSObject.Properties['exe']) {
        $exe = Join-Path $dir $tool.exe
        if (-not (Test-Path $exe)) { Report FAIL "$($tool.name): $($tool.exe) missing"; continue }
        if ($tool.PSObject.Properties['smoke']) {
            $smokeArgs = @($tool.smoke)
            & $exe @smokeArgs *> $null
            if ($LASTEXITCODE -ne 0) { Report FAIL "$($tool.name): exited $LASTEXITCODE when run" }
        }
    }
    if ($tool.PSObject.Properties['extract'] -and -not $tool.extract) {
        foreach ($pattern in $tool.assets) {
            $n = @(Get-ChildItem $dir -Filter $pattern -File).Count
            if ($n -ne 1) { Report FAIL "$($tool.name): expected one file matching $pattern, found $n" }
        }
    }
}
$runnable = @($declared | Where-Object { $_.PSObject.Properties['smoke'] }).Count
if ($failures -eq $before) { Report ok "$($declared.Count) tools present; $runnable command-line tools ran cleanly" }

# Anything under tools\ that the manifest does not account for.
$names = @($declared | Where-Object { -not $_.PSObject.Properties['dest'] }).name
foreach ($top in Get-ChildItem $ToolsDir -Directory) {
    if ($top.Name -in $names -or $top.Name -eq '_downloads') { continue }
    if (-not ($names | Where-Object { $_ -like "$($top.Name)\*" })) { Report FAIL "tools\$($top.Name) is not in tools.json"; continue }
    foreach ($child in Get-ChildItem $top.FullName) {
        if ("$($top.Name)\$($child.Name)" -notin $names) { Report FAIL "tools\$($top.Name)\$($child.Name) is not in tools.json" }
    }
}

# The same program declared twice.
$declared | Where-Object { $_.PSObject.Properties['exe'] } | ForEach-Object {
    $exe = Join-Path $ToolsDir $_.name $_.exe
    if (Test-Path $exe) { [pscustomobject]@{ Tool = $_.name; Hash = (Get-FileHash $exe -Algorithm SHA1).Hash } }
} | Group-Object Hash | Where-Object Count -gt 1 | ForEach-Object { Report FAIL "duplicate tools: $($_.Group.Tool -join ' = ')" }

# .NET tools need a matching runtime major version.
$runtimes = dotnet --list-runtimes | ForEach-Object { $p = $_ -split ' '; "$($p[0]) $(($p[1] -split '\.')[0])" } | Sort-Object -Unique
$missing = foreach ($cfg in Get-ChildItem $ToolsDir -Recurse -Filter *.runtimeconfig.json) {
    $opts = (Get-Content $cfg.FullName -Raw | ConvertFrom-Json).runtimeOptions
    if ($opts.PSObject.Properties['includedFrameworks']) { continue }
    $frameworks = @($opts.PSObject.Properties['framework']?.Value) + @($opts.PSObject.Properties['frameworks']?.Value) | Where-Object { $_ }
    foreach ($fw in $frameworks) {
        $need = "$($fw.name) $(($fw.version -split '\.')[0])"
        if ($need -notin $runtimes) { "$($cfg.BaseName -replace '\.runtimeconfig$') needs $need" }
    }
}
if ($missing) { $missing | Sort-Object -Unique | ForEach-Object { Report FAIL $_ } } else { Report ok '.NET runtimes satisfy every tool' }
if (Test-Path (Join-Path $ToolsDir '_downloads')) { Report WARN 'tools\_downloads left behind by an interrupted Get-Tools run' }

Section 'References'
$expected = $manifest.references.repo | ForEach-Object { $_ -replace '/', '__' }
$present  = @(Get-ChildItem $RefDir -Directory -ErrorAction SilentlyContinue).Name
$expected | Where-Object { $_ -notin $present } | ForEach-Object { Report FAIL "reference\$_ missing (run Get-References.ps1)" }
$present  | Where-Object { $_ -notin $expected } | ForEach-Object { Report FAIL "reference\$_ is not in tools.json" }
if (-not (Compare-Object $expected $present)) { Report ok "$($present.Count) reference repos present, none unaccounted for" }

Section 'Game data'
$game = Get-IcarusGameDir -AllowMissing
$stamp = Join-Path $GameDataDir 'build.json'
if (-not $game) { Report FAIL 'Icarus install not found' }
elseif (-not (Test-Path $stamp)) { Report FAIL 'no extracted data (run Export-GameData.ps1)' }
else {
    $info = Get-Content $stamp -Raw | ConvertFrom-Json
    $now  = (Get-FileHash (Join-Path $game 'Icarus\Content\Data\data.pak') -Algorithm SHA256).Hash
    if ($now -ne $info.dataPakSha256) { Report FAIL 'extracted data is stale: the game updated (run Export-GameData.ps1, then rebuild mods)' }
    else { Report ok "build $($info.buildId), $($info.tables) tables, matches the installed data.pak" }
}

Section 'Mods'
$mods = @(Get-ChildItem $ModsDir -Directory -ErrorAction SilentlyContinue)
if (-not $mods) { Report WARN 'no mods yet' }
foreach ($mod in $mods) {
    $exmod = Join-Path $mod.FullName "$($mod.Name).EXMOD"
    if (-not (Test-Path $exmod)) { Report FAIL "$($mod.Name): $($mod.Name).EXMOD missing"; continue }
    $out = python (Join-Path $PSScriptRoot 'exmod.py') check $exmod 2>&1
    $summary = "$($out | Select-Object -Last 1)"
    if ($LASTEXITCODE -ne 0) {
        Report FAIL "$($mod.Name): $summary"
        $out | Select-String '^error' | Select-Object -First 5 | ForEach-Object { Write-Host "         $_" }
        continue
    }
    $pak = Join-Path $BuildDir "$($mod.Name)_P.pak"
    $newest = (Get-ChildItem $mod.FullName -Recurse -File | Sort-Object LastWriteTime | Select-Object -Last 1).LastWriteTime
    if (-not (Test-Path $pak)) { Report WARN "$($mod.Name): valid ($summary), not built" }
    elseif ((Get-Item $pak).LastWriteTime -lt $newest) { Report WARN "$($mod.Name): valid ($summary), build is older than the source" }
    elseif ((Test-Path $stamp) -and (Get-Item $pak).LastWriteTime -lt (Get-Item $stamp).LastWriteTime) {
        Report WARN "$($mod.Name): valid ($summary), built before the last game-data extraction; rebuild"
    }
    else { Report ok "$($mod.Name): valid ($summary), build is current" }
}

}

Section 'Wax (Lua framework)'
$lua = Join-Path $ToolsDir 'lua\lua54\lua.exe'
if (-not (Test-Path (Join-Path $Root 'wax\runtime\Scripts\main.lua'))) { Report WARN 'wax\runtime not present' }
elseif (-not (Test-Path $lua)) { Report FAIL 'standalone Lua missing (run Get-Tools.ps1), cannot run the offline tests' }
else {
    if (-not (Test-Path (Join-Path $Root 'wax\runtime\bin\waxco.dll'))) {
        Report FAIL 'wax\runtime\bin\waxco.dll missing (run Build-WaxNative.ps1): tasks could not call the engine'
    }
    if (-not (Test-Path (Join-Path $Root 'wax\runtime\bin\waxnet.dll'))) {
        Report FAIL 'wax\runtime\bin\waxnet.dll missing (run Build-WaxNative.ps1 -Only waxnet): mods could not update themselves'
    }
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ("wax-tests-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force "$scratch\bridge\run\in", "$scratch\bridge\run\out", "$scratch\bridge\Scripts", "$scratch\mods" | Out-Null
    # Recipe Browser is staged in a dot folder until it is shown to the user. Its suites skip themselves when it is not here.
    $recipeMod = (Test-Path (Join-Path $Root 'luamods\RecipeBrowser')) ? 'luamods/RecipeBrowser' : 'luamods/.RecipeBrowser'
    $suites = [ordered]@{
        'core'   = @('wax\tests\offline\core_test.lua')
        'gui'    = @('wax\tests\offline\gui_test.lua')
        'model'  = @('wax\tests\offline\model_test.lua')
        'world'  = @('wax\tests\offline\world_test.lua')
        'easy'   = @('wax\tests\offline\easy_test.lua')
        'watch'  = @('wax\tests\offline\watch_test.lua')
        'hooks'  = @('wax\tests\offline\hooks_test.lua')
        'handle' = @('wax\tests\offline\handle_test.lua')
        'character' = @('wax\tests\offline\character_test.lua')
        'stats'  = @('wax\tests\offline\stats_test.lua')
        'session' = @('wax\tests\offline\session_test.lua')
        'items'  = @('wax\tests\offline\items_test.lua')
        'creature' = @('wax\tests\offline\creature_test.lua')
        'creature-act' = @('wax\tests\offline\creature_act_test.lua')
        'assets' = @('wax\tests\offline\assets_test.lua', ("$scratch\assets" -replace '\\', '/'))
        'blueprints' = @('wax\tests\offline\blueprints_test.lua')
        'content' = @('wax\tests\offline\content_test.lua', ($scratch -replace '\\', '/'))
        'research' = @('wax\tests\offline\research_test.lua')
        'needs' = @('wax\tests\offline\needs_test.lua', ("$scratch\needs" -replace '\\', '/'))
        'explorer' = @('wax\tests\offline\explorer_test.lua')
        'data'   = @('wax\tests\offline\data_test.lua')
        'data-maps' = @('wax\tests\offline\data_maps_test.lua')
        'journal' = @('wax\tests\offline\journal_test.lua')
        'patch'  = @('wax\tests\offline\patch_test.lua')
        'patch-loader' = @('wax\tests\offline\patch_loader_test.lua', ("$scratch\patch-loader" -replace '\\', '/'))
        'recipes' = @('wax\tests\offline\recipes_test.lua')
        'workshop' = @('wax\tests\offline\workshop_test.lua')
        'workshop-write' = @('wax\tests\offline\workshop_write_test.lua')
        'oversized' = @('wax\tests\offline\oversized_test.lua')
        'recipe-logic' = @('wax\tests\offline\recipe_logic_test.lua', $recipeMod)
        'recipe-model' = @('wax\tests\offline\recipe_model_test.lua', $recipeMod)
        'recipe-unlock' = @('wax\tests\offline\recipe_unlock_test.lua', $recipeMod)
        'recipe-stats' = @('wax\tests\offline\recipe_stats_test.lua', $recipeMod)
        'recipe-tree' = @('wax\tests\offline\recipe_tree_test.lua', $recipeMod)
        'recipe-app' = @('wax\tests\offline\recipe_app_test.lua', $recipeMod)
        'recipe-creature' = @('wax\tests\offline\recipe_creature_test.lua', $recipeMod)
        'recipe-creature-page' = @('wax\tests\offline\recipe_creature_page_test.lua', $recipeMod)
        'recipe-layout' = @('wax\tests\offline\recipe_layout_test.lua', $recipeMod)
        'mods'   = @('wax\tests\offline\mods_test.lua', ("$scratch\mods" -replace '\\', '/'))
        'held'   = @('wax\tests\offline\held_test.lua', ("$scratch\held" -replace '\\', '/'))
        'update' =@('wax\tests\offline\update_test.lua', ("$scratch\update" -replace '\\', '/'))
        'selfupdate' = @('wax\tests\offline\selfupdate_test.lua', ("$scratch\selfupdate" -replace '\\', '/'))
        'selfswap' = @('wax\tests\offline\selfswap_test.lua', ("$scratch\selfswap" -replace '\\', '/'))
        # The helper itself, against the live catalogue. It says so and passes when the catalogue cannot be reached.
        'waxnet' = @('wax\tests\offline\waxnet_test.lua')
        'bridge' = @('wax\tests\bridge_offline.lua', ("$scratch\bridge" -replace '\\', '/'))
    }
    Push-Location $Root
    try {
        foreach ($suite in $suites.Keys) {
            $suiteArgs = $suites[$suite]
            $out = & $lua @suiteArgs 2>&1
            $verdict = "$($out | Where-Object { $_ -match 'passed|PASS' } | Select-Object -Last 1)"
            if ($LASTEXITCODE -ne 0) {
                Report FAIL "offline suite '$suite' failed"
                $out | Where-Object { $_ -match '^FAIL|expected|error' } | Select-Object -First 6 | ForEach-Object { Write-Host "         $_" }
            } else { Report ok "offline suite '$suite': $verdict" }
        }
        # The game's tables against what Prospector's Codex reads from them: this is what says a weekly patch broke it.
        $recipeCheck = Join-Path $PSScriptRoot 'recipe_check.py'
        if (-not (Test-Path $recipeCheck) -or -not (Test-Path (Join-Path $Root 'game-data\data'))) {
            Report ok "offline suite 'recipe-data': 0 passed (skipped: scripts\recipe_check.py or game-data is not here)"
        } elseif (-not (Get-Command python -ErrorAction SilentlyContinue)) {
            Report FAIL "python missing, cannot check the game's tables against Prospector's Codex"
        } else {
            $out = python $recipeCheck --mod $recipeMod 2>&1
            $verdict = "$($out | Where-Object { $_ -match 'passed' } | Select-Object -Last 1)"
            if ($LASTEXITCODE -ne 0) {
                Report FAIL "recipe-data: the game's tables no longer fit Prospector's Codex ($verdict)"
                $out | Where-Object { $_ -match '^FAIL' } | Select-Object -First 8 | ForEach-Object { Write-Host "         $_" }
            } else {
                $out = & $lua 'wax\tests\offline\recipe_data_check.lua' $recipeMod 'build/recipe-browser/check' 2>&1
                $model = "$($out | Where-Object { $_ -match 'passed' } | Select-Object -Last 1)"
                if ($LASTEXITCODE -ne 0) {
                    Report FAIL "recipe-data: the mod's model and the check's own join differ ($model)"
                    $out | Where-Object { $_ -match '^DIFF|^\s+\.\.\. and' } | Select-Object -First 8 | ForEach-Object { Write-Host "         $_" }
                } else { Report ok "offline suite 'recipe-data': $verdict; $model" }
            }
        }
        # The same for the Bestiary. Until its files are in the mod, the staged copy is checked.
        $creatureCheck = Join-Path $PSScriptRoot 'creature_check.py'
        $creatureMod = (Test-Path (Join-Path $Root "$recipeMod\creatures.lua")) ? $recipeMod : 'build/creature-work/RecipeBrowser'
        if (-not (Test-Path $creatureCheck) -or -not (Test-Path (Join-Path $Root 'game-data\data'))) {
            Report ok "offline suite 'creature-data': 0 passed (skipped: scripts\creature_check.py or game-data is not here)"
        } elseif (-not (Get-Command python -ErrorAction SilentlyContinue)) {
            Report FAIL "python missing, cannot check the game's tables against the Bestiary"
        } else {
            $out = python $creatureCheck --mod $creatureMod 2>&1
            $verdict = "$($out | Where-Object { $_ -match 'passed' } | Select-Object -Last 1)"
            if ($LASTEXITCODE -ne 0) {
                Report FAIL "creature-data: the game's tables no longer fit the Bestiary ($verdict)"
                $out | Where-Object { $_ -match '^FAIL' } | Select-Object -First 8 | ForEach-Object { Write-Host "         $_" }
            } else {
                $out = & $lua 'wax\tests\offline\recipe_creature_data_check.lua' $creatureMod 'build/creature-browser/check' 2>&1
                $model = "$($out | Where-Object { $_ -match 'passed' } | Select-Object -Last 1)"
                if ($LASTEXITCODE -ne 0) {
                    Report FAIL "creature-data: the mod's model and the check's own join differ ($model)"
                    $out | Where-Object { $_ -match '^DIFF|^FAIL|^\s+\.\.\. and' } | Select-Object -First 8 | ForEach-Object { Write-Host "         $_" }
                } else { Report ok "offline suite 'creature-data': $verdict; $model" }
            }
        }
        # The list of creature models against the script that makes it.
        $modelsTest = Join-Path $PSScriptRoot 'test_creature_models.py'
        if ((Test-Path $modelsTest) -and (Get-Command python -ErrorAction SilentlyContinue)) {
            $out = python $modelsTest 2>&1
            if ($LASTEXITCODE -ne 0) {
                Report FAIL 'creature model tests failed'
                $out | Where-Object { "$_" -match '^(FAIL|ERROR):' } | Select-Object -First 6 | ForEach-Object { Write-Host "         $_" }
            } else {
                $ran = "$($out | Where-Object { "$_" -match '^Ran \d+ tests' } | Select-Object -Last 1)" -replace '^Ran (\d+).*', '$1'
                Report ok "creature model tests: $ran passed"
            }
        }
    } finally {
        Pop-Location
        [System.IO.Directory]::Delete($scratch, $true)
    }
}

Section 'Wax VS Code extension'
if (-not (Test-Path (Join-Path $Root 'wax\vscode\package.json'))) { Report WARN 'wax\vscode not present' }
elseif (-not (Get-Command node -ErrorAction SilentlyContinue)) { Report FAIL 'Node.js missing, cannot run the extension tests' }
else {
    Push-Location (Join-Path $Root 'wax\vscode')
    try { $out = node --test --test-reporter=tap 'test/*.test.mjs' 2>&1 } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) {
        Report FAIL 'extension tests failed'
        $out | Where-Object { $_ -match '^\s*not ok ' } | Select-Object -First 6 | ForEach-Object { Write-Host "         $_" }
    } else {
        $passed = "$($out | Where-Object { $_ -match '^# pass \d+' } | Select-Object -Last 1)" -replace '\D'
        Report ok "extension tests: $passed passed"
    }
    $out | ForEach-Object { if ($_ -match '# SKIP (.+)$') { Report WARN "extension test skipped: $($Matches[1])" } }
}

Section 'Game class definitions'
$gameIndex = Join-Path $Root 'build\game-index\index.json'
if (-not (Test-Path (Join-Path $Root 'wax\types\icarus\classes.txt'))) { Report FAIL 'wax\types\icarus is missing: python scripts\gameindex.py types' }
elseif (-not (Test-Path $gameIndex)) { Report WARN 'no game index (python scripts\gameindex.py build), so the definitions were not checked against it' }
elseif (-not (Get-Command python -ErrorAction SilentlyContinue)) { Report FAIL 'python missing, cannot run the game index tests' }
else {
    $out = python (Join-Path $PSScriptRoot 'test_gameindex.py') 2>&1
    if ($LASTEXITCODE -ne 0) {
        Report FAIL 'game index tests failed'
        $out | Where-Object { "$_" -match '^(FAIL|ERROR):' } | Select-Object -First 6 | ForEach-Object { Write-Host "         $_" }
    } else {
        $ran = "$($out | Where-Object { "$_" -match '^Ran \d+ tests' } | Select-Object -Last 1)" -replace '^Ran (\d+).*', '$1'
        Report ok "game index tests: $ran passed"
    }
}

Write-Host ''
if ($failures) { Write-Host "$failures failure(s), $warnings warning(s)" -ForegroundColor Red; exit 1 }
Write-Host "All checks passed, $warnings warning(s)" -ForegroundColor Green
