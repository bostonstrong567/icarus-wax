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
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ("wax-tests-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force "$scratch\bridge\run\in", "$scratch\bridge\run\out", "$scratch\bridge\Scripts", "$scratch\mods" | Out-Null
    $suites = [ordered]@{
        'core'   = @('wax\tests\offline\core_test.lua')
        'gui'    = @('wax\tests\offline\gui_test.lua')
        'world'  = @('wax\tests\offline\world_test.lua')
        'explorer' = @('wax\tests\offline\explorer_test.lua')
        'mods'   = @('wax\tests\offline\mods_test.lua', ("$scratch\mods" -replace '\\', '/'))
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
