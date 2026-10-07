#requires -Version 7
<#
.SYNOPSIS
  Tests build\Wax-<version>.zip against fake game folders under build\release-test.
.DESCRIPTION
  Extracts the zip and runs its installer with Windows PowerShell 5.1 (powershell.exe), which is what players have:
  install, install again over a copy that holds a player's own mods and settings, a different UE4SS already in
  place, a running game, links where folders are expected, uninstall, and update against a local stand-in for
  GitHub (serve.mjs). It also compares what was installed with the UE4SS zip and wax\runtime, and with the real game
  folder this workspace uses when there is one (read only). Nothing here touches the real game or the network.
.EXAMPLE
  .\scripts\Build-WaxRelease.ps1; .\wax\release\test\Test-WaxRelease.ps1
#>
[CmdletBinding()]
param()
. "$PSScriptRoot\..\..\..\scripts\_common.ps1"
# The installs below go into throwaway folders, so they must not take over this PC's wax:// links.
$env:WAX_SETUP_NO_LINKS = '1'

$version = (Get-Content (Join-Path $Root 'wax\VERSION') -Raw).Trim()
$zip     = Join-Path $BuildDir "Wax-$version.zip"
$work    = Join-Path $BuildDir 'release-test'
# A folder name like the ones a second download and "Extract All" produce.
$package = Join-Path $work "Bob's Downloads\Wax-$version (1)"
$setup   = Join-Path $package 'Wax-Setup.ps1'
$waxPath = 'ue4ss\Mods\Wax'
if (-not (Test-Path -LiteralPath $zip)) { throw "$zip not found. Run scripts\Build-WaxRelease.ps1 first." }

$script:passed = 0
$script:failures = @()
function Check([string]$What, $Ok, [string]$Detail = '') {
    if ($Ok) { $script:passed++; Write-Host "  ok    $What" }
    else { $script:failures += $What; Write-Host "  FAIL  $What  $Detail" -ForegroundColor Red }
}
function Section([string]$Name) { Write-Host ''; Write-Host $Name -ForegroundColor Cyan }

# Links are removed as links, so clearing the test folder can never reach outside it.
function Clear-Folder([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-ChildItem -LiteralPath $Path -Recurse -Force -Attributes ReparsePoint | ForEach-Object { [System.IO.Directory]::Delete($_.FullName) }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Invoke-Setup {
    param([string[]]$Arguments, [string]$Answers, [string]$Script = $setup)
    $all = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments
    if ($PSBoundParameters.ContainsKey('Answers')) { $lines = $Answers | & powershell.exe @all 2>&1 }
    else { $lines = $null | & powershell.exe @all 2>&1 }
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($lines) -join "`n") }
}

function New-FakeGame([string]$GameRoot) {
    $win64 = Join-Path $GameRoot 'Icarus\Binaries\Win64'
    New-Item -ItemType Directory -Force $win64 | Out-Null
    Set-Content -LiteralPath (Join-Path $win64 'Icarus-Win64-Shipping.exe') -Value 'not the real game'
    Set-Content -LiteralPath (Join-Path $win64 'tbb12.dll') -Value 'a game file'
    $win64
}

function Get-Tree([string]$Dir, [string[]]$Skip = @()) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $Dir)) { return $map }
    $base = (Get-Item -LiteralPath $Dir -Force).FullName.TrimEnd('\')
    foreach ($file in Get-ChildItem -LiteralPath "$base\" -Recurse -Force -File) {
        $relative = $file.FullName.Substring($base.Length + 1)
        if ($Skip | Where-Object { $relative -like $_ }) { continue }
        $map[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    $map
}

function Compare-Tree([hashtable]$Expected, [hashtable]$Actual) {
    $out = @()
    foreach ($name in $Expected.Keys) {
        if (-not $Actual.ContainsKey($name)) { $out += "missing: $name" }
        elseif ($Actual[$name] -ne $Expected[$name]) { $out += "differs: $name" }
    }
    foreach ($name in $Actual.Keys) { if (-not $Expected.ContainsKey($name)) { $out += "extra: $name" } }
    , @($out | Sort-Object)
}

$playerFiles = "$waxPath\mods\MyMod\init.lua", "$waxPath\mods\MyMod\mod.lua", "$waxPath\mods\RecipeBrowser\init.lua",
    "$waxPath\saved\MyMod.settings.lua", "$waxPath\saved\wax.interface.lua", 'ue4ss\Mods\OtherMod\Scripts\main.lua'

function Add-PlayerFiles([string]$Win64) {
    $wax = Join-Path $Win64 $waxPath
    New-Item -ItemType Directory -Force (Join-Path $wax 'mods\MyMod'), (Join-Path $Win64 'ue4ss\Mods\OtherMod\Scripts') | Out-Null
    Set-Content -LiteralPath (Join-Path $wax 'mods\MyMod\init.lua') -Value 'print("mine")'
    Set-Content -LiteralPath (Join-Path $wax 'mods\MyMod\mod.lua') -Value 'return { name = "MyMod" }'
    Add-Content -LiteralPath (Join-Path $wax 'mods\RecipeBrowser\init.lua') -Value '-- changed by the player'
    Set-Content -LiteralPath (Join-Path $wax 'saved\MyMod.settings.lua') -Value 'return { on = true }'
    Set-Content -LiteralPath (Join-Path $wax 'saved\wax.interface.lua') -Value 'return { scale = 1.25 }'
    Set-Content -LiteralPath (Join-Path $wax 'run\session.log') -Value 'what happened last time'
    Set-Content -LiteralPath (Join-Path $wax 'Scripts\wax\gone.lua') -Value 'return {}'
    Set-Content -LiteralPath (Join-Path $wax 'VERSION') -Value '0.0.9'
    Add-Content -LiteralPath (Join-Path $Win64 'ue4ss\UE4SS-settings.ini') -Value '; changed by the player'
    Add-Content -LiteralPath (Join-Path $Win64 'ue4ss\Mods\mods.txt') -Value 'OtherMod : 1'
    Set-Content -LiteralPath (Join-Path $Win64 'ue4ss\Mods\OtherMod\Scripts\main.lua') -Value 'print("other")'
}

function Get-PlayerState([string]$Win64) {
    ($playerFiles | ForEach-Object {
        $file = Join-Path $Win64 $_
        if (Test-Path -LiteralPath $file) { "$_=" + (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash } else { "$_=gone" }
    }) -join "`n"
}

function Test-Installed([string]$Label, [string]$Win64, [hashtable]$Expected) {
    $actual = Get-Tree $Win64 -Skip 'Icarus-Win64-Shipping.exe', 'tbb12.dll', "$waxPath\mods\*", "$waxPath\saved\*", "$waxPath\run\*",
        'ue4ss\Mods\OtherMod\*', 'ue4ss-backup-*', 'ue4ss\UE4SS-settings.ini', 'ue4ss\Mods\mods.txt'
    $wanted = @{}
    foreach ($name in $Expected.Keys) {
        if ($name -like "$waxPath\mods\*" -or $name -in 'ue4ss\UE4SS-settings.ini', 'ue4ss\Mods\mods.txt') { continue }
        $wanted[$name] = $Expected[$name]
    }
    $diff = Compare-Tree $wanted $actual
    Check "${Label}: every file of the zip's game folder is in place, and nothing else" ($diff.Count -eq 0) (($diff | Select-Object -First 5) -join '; ')
    $wax = Join-Path $Win64 $waxPath
    foreach ($folder in 'saved', 'run\in', 'run\out', 'mods') {
        Check "${Label}: Wax\$folder exists" (Test-Path -LiteralPath (Join-Path $wax $folder) -PathType Container)
    }
    Check "${Label}: the game's own files are untouched" ((Get-Content -LiteralPath (Join-Path $Win64 'Icarus-Win64-Shipping.exe') -Raw).Trim() -eq 'not the real game' -and
        (Get-Content -LiteralPath (Join-Path $Win64 'tbb12.dll') -Raw).Trim() -eq 'a game file')
}

# Install, install over a player's files, a different UE4SS, uninstall keeping things, uninstall removing all.
function Test-Cycle([string]$Label, [string[]]$Locate, [string]$Win64, [hashtable]$Expected, [switch]$AnswerByTyping) {
    Section "$Label ($($Locate -join ' '))"
    $wax = Join-Path $Win64 $waxPath

    $run = Invoke-Setup (@('-Action', 'Install') + $Locate)
    Check "${Label}: install exits 0" ($run.Code -eq 0) $run.Text
    Check "${Label}: install names the game folder it found" ($run.Text.Contains($Win64))
    Check "${Label}: install says what it did" ($run.Text -cmatch "Wax $([regex]::Escape($version)) is installed\.")
    Check "${Label}: install says what to do next" ($run.Text -match 'Press F8' -and $run.Text.Contains('https://wax-icarus.duckdns.org/'))
    Test-Installed "$Label install" $Win64 $Expected
    $diff = Compare-Tree $Expected (Get-Tree $Win64 -Skip 'Icarus-Win64-Shipping.exe', 'tbb12.dll')
    Check "${Label}: a first install is the zip's game folder exactly, UE4SS settings and Recipe Browser included" ($diff.Count -eq 0) (($diff | Select-Object -First 5) -join '; ')
    Check "${Label}: Recipe Browser is there" (Test-Path -LiteralPath (Join-Path $wax 'mods\RecipeBrowser\init.lua'))
    Check "${Label}: Recipe Browser is marked as a mod from the catalogue, and the helper that updates it is installed" ((Test-Path -LiteralPath (Join-Path $wax 'mods\RecipeBrowser\wax.origin')) -and
        (Test-Path -LiteralPath (Join-Path $wax 'bin\waxnet.dll')))
    Check "${Label}: the version file says $version" ((Get-Content -LiteralPath (Join-Path $wax 'VERSION') -Raw).Trim() -eq $version)
    Check "${Label}: nothing was backed up on a clean game" (-not (Test-Path (Join-Path $Win64 'ue4ss-backup-*')))

    Add-PlayerFiles $Win64
    $before = Get-PlayerState $Win64
    $run = Invoke-Setup (@('-Action', 'Install') + $Locate)
    Check "${Label}: install over an old copy exits 0" ($run.Code -eq 0) $run.Text
    Check "${Label}: it reports the update" ($run.Text -match "Wax was updated from 0\.0\.9 to $([regex]::Escape($version))\.")
    Check "${Label}: it says the player's files were kept" ($run.Text -match 'Your mods and settings were kept\.')
    Check "${Label}: the player's mods and settings are unchanged" ((Get-PlayerState $Win64) -eq $before)
    Check "${Label}: a mod the player made is not marked as one from the catalogue" (-not (Test-Path -LiteralPath (Join-Path $wax 'mods\MyMod\wax.origin')))
    Check "${Label}: a file of the old Wax version is gone" (-not (Test-Path -LiteralPath (Join-Path $wax 'Scripts\wax\gone.lua')))
    Check "${Label}: the session log is still there" (Test-Path -LiteralPath (Join-Path $wax 'run\session.log'))
    Check "${Label}: the player's UE4SS settings are kept on the same UE4SS" ((Get-Content -LiteralPath (Join-Path $Win64 'ue4ss\UE4SS-settings.ini') -Raw) -match 'changed by the player' -and
        (Get-Content -LiteralPath (Join-Path $Win64 'ue4ss\Mods\mods.txt') -Raw) -match 'OtherMod : 1' -and $run.Text -match 'Your own UE4SS settings were kept')
    Check "${Label}: still nothing backed up" (-not (Test-Path (Join-Path $Win64 'ue4ss-backup-*')))
    Test-Installed "$Label reinstall" $Win64 $Expected

    Set-Content -LiteralPath (Join-Path $Win64 'dwmapi.dll') -Value 'another proxy'
    Set-Content -LiteralPath (Join-Path $Win64 'ue4ss\UE4SS.dll') -Value 'another UE4SS'
    Set-Content -LiteralPath (Join-Path $Win64 'UE4SS.dll') -Value 'UE4SS in the old layout'
    $run = Invoke-Setup (@('-Action', 'Install') + $Locate)
    $backup = @(Get-ChildItem -LiteralPath $Win64 -Directory -Filter 'ue4ss-backup-*')
    Check "${Label}: install over a different UE4SS exits 0" ($run.Code -eq 0) $run.Text
    Check "${Label}: one dated backup folder was made beside the files" ($backup.Count -eq 1 -and $backup[0].Name -match '^ue4ss-backup-\d{4}-\d\d-\d\d_\d{6}$')
    if ($backup.Count -eq 1) {
        $b = $backup[0].FullName
        Check "${Label}: the backup holds the old files" ((Get-Content (Join-Path $b 'dwmapi.dll') -Raw).Trim() -eq 'another proxy' -and
            (Get-Content (Join-Path $b 'ue4ss\UE4SS.dll') -Raw).Trim() -eq 'another UE4SS' -and
            (Get-Content (Join-Path $b 'ue4ss\UE4SS-settings.ini') -Raw) -match 'changed by the player' -and
            (Get-Content (Join-Path $b 'ue4ss\Mods\mods.txt') -Raw) -match 'OtherMod : 1')
        Check "${Label}: it says so and names the folder" ($run.Text -match 'A different UE4SS was already in the game folder' -and $run.Text.Contains($b))
    }
    Check "${Label}: it mentions the old-layout UE4SS and leaves it" ($run.Text -match 'older UE4SS' -and (Test-Path -LiteralPath (Join-Path $Win64 'UE4SS.dll')))
    Check "${Label}: UE4SS is now the build from the zip, settings included" ((Get-FileHash (Join-Path $Win64 'ue4ss\UE4SS.dll')).Hash -eq $Expected['ue4ss\UE4SS.dll'] -and
        (Get-FileHash (Join-Path $Win64 'dwmapi.dll')).Hash -eq $Expected['dwmapi.dll'] -and
        (Get-FileHash (Join-Path $Win64 'ue4ss\UE4SS-settings.ini')).Hash -eq $Expected['ue4ss\UE4SS-settings.ini'])
    Check "${Label}: the player's mods and settings are still unchanged" ((Get-PlayerState $Win64) -eq $before)
    Remove-Item -LiteralPath (Join-Path $Win64 'UE4SS.dll')

    if ($AnswerByTyping) { $run = Invoke-Setup (@('-Action', 'Uninstall') + $Locate) -Answers "`n`n" }
    else { $run = Invoke-Setup (@('-Action', 'Uninstall') + $Locate) }
    Check "${Label}: uninstall with the default answers exits 0" ($run.Code -eq 0) $run.Text
    Check "${Label}: Wax's own files are gone" (-not (Test-Path -LiteralPath (Join-Path $wax 'Scripts')) -and -not (Test-Path -LiteralPath (Join-Path $wax 'enabled.txt')) -and
        -not (Test-Path -LiteralPath (Join-Path $wax 'assets')) -and -not (Test-Path -LiteralPath (Join-Path $wax 'bin')) -and -not (Test-Path -LiteralPath (Join-Path $wax 'run')))
    Check "${Label}: the player's mods and settings were kept by default" ((Get-PlayerState $Win64) -eq $before)
    Check "${Label}: UE4SS was kept by default" ((Test-Path -LiteralPath (Join-Path $Win64 'dwmapi.dll')) -and (Test-Path -LiteralPath (Join-Path $Win64 'ue4ss\UE4SS.dll')) -and $run.Text -match 'UE4SS is still installed')

    $run = Invoke-Setup (@('-Action', 'Install') + $Locate)
    Check "${Label}: installing again after that picks the player's files back up" ($run.Code -eq 0 -and (Get-PlayerState $Win64) -eq $before -and
        (Test-Path -LiteralPath (Join-Path $wax 'Scripts\main.lua')) -and $run.Text -cmatch "Wax $([regex]::Escape($version)) is installed\.")

    if ($AnswerByTyping) { $run = Invoke-Setup (@('-Action', 'Uninstall') + $Locate) -Answers "y`nyes`n" }
    else { $run = Invoke-Setup (@('-Action', 'Uninstall', '-RemoveMyFiles', 'Yes', '-RemoveUE4SS', 'Yes') + $Locate) }
    Check "${Label}: uninstall of everything exits 0" ($run.Code -eq 0) $run.Text
    Check "${Label}: Wax, the player's files and UE4SS are gone" (-not (Test-Path -LiteralPath $wax) -and -not (Test-Path -LiteralPath (Join-Path $Win64 'dwmapi.dll')) -and
        -not (Test-Path -LiteralPath (Join-Path $Win64 'ue4ss\UE4SS.dll')) -and -not (Test-Path -LiteralPath (Join-Path $Win64 'ue4ss\UE4SS-settings.ini')) -and
        -not (Test-Path -LiteralPath (Join-Path $Win64 'ue4ss\Mods\Keybinds')))
    Check "${Label}: someone else's UE4SS mod is left alone and named" ((Test-Path -LiteralPath (Join-Path $Win64 'ue4ss\Mods\OtherMod\Scripts\main.lua')) -and $run.Text -match 'OtherMod')
    Check "${Label}: the backup folder is left and named" ($backup.Count -eq 1 -and (Test-Path -LiteralPath $backup[0].FullName) -and $run.Text.Contains($backup[0].FullName))
    Check "${Label}: the game's own files are untouched" ((Get-Content -LiteralPath (Join-Path $Win64 'Icarus-Win64-Shipping.exe') -Raw).Trim() -eq 'not the real game')

    $run = Invoke-Setup (@('-Action', 'Uninstall', '-RemoveUE4SS', 'Yes') + $Locate)
    Check "${Label}: a second full uninstall leaves the other mod and exits 0" ($run.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $Win64 'ue4ss\Mods\OtherMod\Scripts\main.lua')))
}

Section 'Setting up build\release-test'
Clear-Folder $work
New-Item -ItemType Directory -Force $work, (Join-Path $work 'temp') | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $package)
$top = @(Get-ChildItem -LiteralPath $package -Force | ForEach-Object Name | Sort-Object)
Check 'the zip has the expected top level' (($top -join '|') -eq 'game|Install Wax.cmd|licenses|README.txt|Uninstall Wax.cmd|Update Wax.cmd|Wax-Setup.ps1') ($top -join ', ')
$expected = Get-Tree (Join-Path $package 'game')
Check 'no links in the zip' (@(Get-ChildItem -LiteralPath $package -Recurse -Force -Attributes ReparsePoint).Count -eq 0)

Section 'What the zip installs, against the sources'
$ue4ssSource = Join-Path $work 'ue4ss-source'
Expand-Archive -LiteralPath (Join-Path $ToolsDir 'ue4ss\UE4SS_v3.0.1-1152-ge3ba1016.zip') -DestinationPath $ue4ssSource
$diff = Compare-Tree (Get-Tree $ue4ssSource) (Get-Tree (Join-Path $package 'game') -Skip "$waxPath\*")
Check 'UE4SS in the zip is the tested build, file for file, settings included' ($diff.Count -eq 0) ($diff -join '; ')
$runtime = Join-Path $Root 'wax\runtime'
$waxSource = @{}
foreach ($item in Get-ChildItem -LiteralPath $runtime -Force | Where-Object { $_.Name -notin 'run', 'saved', 'mods' }) {
    if ($item.PSIsContainer) { (Get-Tree $item.FullName).GetEnumerator() | ForEach-Object { $waxSource["$($item.Name)\$($_.Key)"] = $_.Value } }
    else { $waxSource[$item.Name] = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }
}
$diff = Compare-Tree $waxSource (Get-Tree (Join-Path $package "game\$waxPath") -Skip 'mods\*', 'VERSION')
Check "Wax in the zip is wax\runtime, file for file ($($waxSource.Count) files)" ($diff.Count -eq 0) (($diff | Select-Object -First 5) -join '; ')
$bundledSource = Get-Tree (Join-Path $Root 'luamods\RecipeBrowser') -Skip '.*', 'wax.origin'
$diff = Compare-Tree $bundledSource (Get-Tree (Join-Path $package "game\$waxPath\mods\RecipeBrowser") -Skip 'wax.origin')
Check 'the mod in the zip is luamods\RecipeBrowser without editor files' ($diff.Count -eq 0) ($diff -join '; ')
$origin = Join-Path $package "game\$waxPath\mods\RecipeBrowser\wax.origin"
$modVersion = [regex]::Match((Get-Content -LiteralPath (Join-Path $Root 'luamods\RecipeBrowser\mod.lua') -Raw), '(?m)^\s*version\s*=\s*"([^"]+)"').Groups[1].Value
Check "the mod in the zip is marked as coming from the catalogue at version $modVersion, so Wax can update it" ($modVersion -and (Test-Path -LiteralPath $origin) -and
    [System.IO.File]::ReadAllText($origin) -ceq "id=RecipeBrowser`r`nversion=$modVersion`r`n")
Check 'the zip has both helpers and the updater' ((Test-Path -LiteralPath (Join-Path $package "game\$waxPath\bin\waxco.dll")) -and
    (Test-Path -LiteralPath (Join-Path $package "game\$waxPath\bin\waxnet.dll")) -and (Test-Path -LiteralPath (Join-Path $package "game\$waxPath\Scripts\wax\mods\update.lua")))
Check 'UE4SS loads Wax through enabled.txt' (Test-Path -LiteralPath (Join-Path $package "game\$waxPath\enabled.txt"))
Check 'the licences are there' ((Get-Content (Join-Path $package 'licenses\UE4SS-LICENSE.txt') -Raw) -match 'MIT License' -and (Get-Content (Join-Path $package 'licenses\Lucide-LICENSE.txt') -Raw) -match 'ISC License')

Section 'Against the real game folder this workspace uses (read only)'
$configFile = Join-Path $Root 'wax\wax.config.json'
$real = if (Test-Path -LiteralPath $configFile) { (Get-Content $configFile -Raw | ConvertFrom-Json).win64 }
if ($real -and (Test-Path -LiteralPath (Join-Path $real 'ue4ss\UE4SS.dll'))) {
    $realTree = @{ 'dwmapi.dll' = (Get-FileHash -LiteralPath (Join-Path $real 'dwmapi.dll')).Hash }
    # Left out: what UE4SS writes while it runs (its log, the object dump, the Lua type dump in shared\types).
    (Get-Tree (Join-Path $real 'ue4ss') -Skip 'UE4SS.log', 'UE4SS_ObjectDump.txt', 'Mods\shared\types\*', 'Mods\Wax\*').GetEnumerator() | ForEach-Object { $realTree["ue4ss\$($_.Key)"] = $_.Value }
    foreach ($item in Get-ChildItem -LiteralPath (Join-Path $real "$waxPath\") -Force | Where-Object { $_.Name -notin 'run', 'saved', 'mods' }) {
        if ($item.PSIsContainer) { (Get-Tree $item.FullName).GetEnumerator() | ForEach-Object { $realTree["$waxPath\$($item.Name)\$($_.Key)"] = $_.Value } }
        else { $realTree["$waxPath\$($item.Name)"] = (Get-FileHash -LiteralPath $item.FullName).Hash }
    }
    $diff = Compare-Tree $realTree (Get-Tree (Join-Path $package 'game') -Skip "$waxPath\mods\*", "$waxPath\VERSION")
    Check "the zip's game folder matches the working install, file for file ($($realTree.Count) files)" ($diff.Count -eq 0) (($diff | Select-Object -First 8) -join '; ')
    foreach ($folder in 'saved', 'run\in', 'run\out', 'mods') {
        Check "the working install has Wax\$folder, and so does the zip" ((Test-Path -LiteralPath (Join-Path $real "$waxPath\$folder")) -and (Test-Path -LiteralPath (Join-Path $package "game\$waxPath\$folder")))
    }
    # Only the installer's lookup functions are run here: they read Steam's registry key and library list.
    $probe = Join-Path $work 'find-game.ps1'
    Set-Content -LiteralPath $probe -Value @'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($args[0], [ref]$null, [ref]$null)
$wanted = 'Combine', 'Test-File', 'Test-Folder', 'Get-Win64', 'Get-SteamRoots', 'Get-SteamLibraries', 'Find-GameInSteam'
foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($wanted -contains $function.Name) { . ([scriptblock]::Create($function.Extent.Text)) }
}
$SteamRoot = ''; $AppId = '1149460'; $GameExe = 'Icarus-Win64-Shipping.exe'
Find-GameInSteam
'@
    $found = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $probe $setup
    Check "the installer's Steam lookup (registry, library list, app manifest) finds the real game folder" ("$found".TrimEnd('\') -ieq "$real".TrimEnd('\')) "$found"
} else {
    Write-Host '  skipped: no real game folder with UE4SS on this machine'
}

Section 'Every Lua file compiles'
$luaFiles = @(Get-ChildItem -LiteralPath $package -Recurse -Force -File -Filter *.lua)
$list = Join-Path $work 'lua-files.txt'
[System.IO.File]::WriteAllLines($list, [string[]]$luaFiles.FullName)
$luaOut = & (Join-Path $ToolsDir 'lua\lua54\lua.exe') (Join-Path $Root 'wax\release\compile_check.lua') $list
Check "all $($luaFiles.Count) Lua files in the zip compile under Lua 5.4 ($($luaOut | Select-Object -Last 1))" ($LASTEXITCODE -eq 0) ($luaOut -join '; ')

Section 'The installer parses under Windows PowerShell 5.1 and holds plain ASCII'
$bytes = [System.IO.File]::ReadAllBytes($setup)
Check 'Wax-Setup.ps1 is ASCII with Windows line endings' (-not ($bytes | Where-Object { $_ -gt 126 }) -and ([System.Text.Encoding]::ASCII.GetString($bytes) -notmatch "(?<!`r)`n"))
foreach ($name in 'Install Wax.cmd', 'Update Wax.cmd', 'Uninstall Wax.cmd', 'README.txt') {
    $text = [System.IO.File]::ReadAllText((Join-Path $package $name))
    Check "$name is ASCII with Windows line endings" ($text -notmatch '[^\x09\x0A\x0D\x20-\x7E]' -and $text -notmatch "(?<!`r)`n")
}
$psVersion = (& powershell.exe -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
Check "powershell.exe is Windows PowerShell 5.1 ($psVersion)" ($psVersion -like '5.1*')

$steam = Join-Path $work 'steam'
$library = Join-Path $work 'Steam Library 2'
New-Item -ItemType Directory -Force (Join-Path $steam 'steamapps'), (Join-Path $library 'steamapps') | Out-Null
$vdf = @"
"libraryfolders"
{
	"0"
	{
		"path"		"$($steam.Replace('\', '\\'))"
		"label"		""
		"contentid"		"1234567890123456789"
		"totalsize"		"0"
		"apps"
		{
			"228980"		"455704514"
		}
	}
	"1"
	{
		"path"		"$($library.Replace('\', '\\'))"
		"label"		"Games"
		"apps"
		{
			"1149460"		"80000000000"
		}
	}
}
"@
Set-Content -LiteralPath (Join-Path $steam 'steamapps\libraryfolders.vdf') -Value $vdf
Set-Content -LiteralPath (Join-Path $library 'steamapps\appmanifest_1149460.acf') -Value @"
"AppState"
{
	"appid"		"1149460"
	"name"		"ICARUS"
	"StateFlags"		"4"
	"installdir"		"Icarus"
}
"@
$steamWin64 = New-FakeGame (Join-Path $library 'steamapps\common\Icarus')
$directWin64 = New-FakeGame (Join-Path $work 'direct\Icarus')

Test-Cycle 'GameDir' @('-GameDir', (Join-Path $work 'direct\Icarus')) $directWin64 $expected
Test-Cycle 'SteamRoot' @('-SteamRoot', $steam) $steamWin64 $expected -AnswerByTyping

Section 'Finding the game'
$free = [char[]]'QZYXWVUT' | Where-Object { -not (Test-Path "${_}:\") } | Select-Object -First 1
$oldSteam = Join-Path $work 'steam-old'
$oldLibrary = Join-Path $work 'old library'
New-Item -ItemType Directory -Force (Join-Path $oldSteam 'steamapps'), (Join-Path $oldLibrary 'steamapps') | Out-Null
Set-Content -LiteralPath (Join-Path $oldSteam 'steamapps\libraryfolders.vdf') -Value @"
"LibraryFolders"
{
	"TimeNextStatsReport"		"1700000000"
	"ContentStatsID"		"-1234567890"
	"1"		"${free}:\\Unplugged Drive\\SteamLibrary"
	"2"		"$($oldLibrary.Replace('\', '\\'))"
}
"@
Set-Content -LiteralPath (Join-Path $oldLibrary 'steamapps\appmanifest_1149460.acf') -Value "`"AppState`"`n{`n`t`"installdir`"`t`t`"Icarus Game`"`n}"
$oldWin64 = New-FakeGame (Join-Path $oldLibrary 'steamapps\common\Icarus Game')
$run = Invoke-Setup @('-Action', 'Uninstall', '-SteamRoot', $oldSteam)
Check 'an old-style library list, an unplugged drive and another install folder name still lead to the game' ($run.Code -eq 0 -and $run.Text.Contains($oldWin64) -and $run.Text -match 'Wax is not installed in this game') $run.Text
foreach ($form in $oldWin64, (Split-Path (Split-Path $oldWin64)), (Join-Path $oldWin64 'Icarus-Win64-Shipping.exe'), "`"$(Split-Path (Split-Path (Split-Path $oldWin64)))`"") {
    $run = Invoke-Setup @('-Action', 'Uninstall', '-GameDir', $form)
    Check "-GameDir accepts $($form.Replace($work, '...'))" ($run.Code -eq 0 -and $run.Text.Contains($oldWin64)) $run.Text
}
$run = Invoke-Setup @('-Action', 'Install', '-GameDir', (Join-Path $work 'no-game-here'))
Check 'a folder without the game is refused with a plain message' ($run.Code -eq 1 -and $run.Text -match 'ICARUS is not in this folder' -and $run.Text -notmatch 'At line|Exception') $run.Text
$emptySteam = Join-Path $work 'steam-empty'
New-Item -ItemType Directory -Force $emptySteam | Out-Null
$run = Invoke-Setup @('-Action', 'Install', '-SteamRoot', $emptySteam)
Check 'when Steam does not know the game and nothing is typed, it stops without changing anything' ($run.Code -eq 1 -and $run.Text -match 'Stopped\. Nothing was changed\.' -and -not (Test-Path (Join-Path $oldWin64 'dwmapi.dll'))) $run.Text
$run = Invoke-Setup @('-Action', 'Install', '-SteamRoot', $emptySteam) -Answers "C:\not here`n$(Split-Path (Split-Path (Split-Path $oldWin64)))`n"
Check 'when Steam does not know the game, a pasted folder is asked for again until it is right, then used' ($run.Code -eq 0 -and $run.Text -match 'is not under that folder' -and (Test-Path -LiteralPath (Join-Path $oldWin64 "$waxPath\Scripts\main.lua"))) $run.Text
$accentSteam = Join-Path $work 'steam-accent'
$accentLibrary = Join-Path $work ('Jeux de Ren' + [char]0xE9)
New-Item -ItemType Directory -Force (Join-Path $accentSteam 'steamapps'), (Join-Path $accentLibrary 'steamapps') | Out-Null
Set-Content -LiteralPath (Join-Path $accentSteam 'steamapps\libraryfolders.vdf') -Value "`"libraryfolders`"`n{`n`t`"0`"`n`t{`n`t`t`"path`"`t`t`"$($accentLibrary.Replace('\', '\\'))`"`n`t}`n}"
Set-Content -LiteralPath (Join-Path $accentLibrary 'steamapps\appmanifest_1149460.acf') -Value "`"AppState`"`n{`n`t`"installdir`"`t`t`"Icarus`"`n}"
$accentWin64 = New-FakeGame (Join-Path $accentLibrary 'steamapps\common\Icarus')
$run = Invoke-Setup @('-Action', 'Install', '-SteamRoot', $accentSteam)
Check 'a Steam library with an accented letter in its name is found and installed into' ($run.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $accentWin64 "$waxPath\Scripts\main.lua"))) $run.Text

Section 'A running game'
$fakeExe = Join-Path $oldWin64 'Icarus-Win64-Shipping.exe'
$source = 'public static class Stand { public static void Main() { System.Threading.Thread.Sleep(180000); } }'
Remove-Item -LiteralPath $fakeExe -Force
& powershell.exe -NoLogo -NoProfile -Command "Add-Type -TypeDefinition '$source' -OutputAssembly '$fakeExe' -OutputType ConsoleApplication"
if (Test-Path -LiteralPath $fakeExe) {
    $stateBefore = (Get-Tree $oldWin64 -Skip 'Icarus-Win64-Shipping.exe').Count
    $standIn = Start-Process -FilePath $fakeExe -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Milliseconds 800
        $newer = Join-Path $work 'newer.json'
        Set-Content -LiteralPath $newer -Value '{"tag_name":"v9.9.9","assets":[{"name":"Wax-9.9.9.zip","browser_download_url":"http://127.0.0.1:9/Wax-9.9.9.zip"}]}'
        foreach ($action in 'Install', 'Update', 'Uninstall') {
            $run = Invoke-Setup @('-Action', $action, '-GameDir', $oldWin64, '-RemoveUE4SS', 'Yes', '-RemoveMyFiles', 'Yes', '-ReleaseApi', $newer)
            Check "$action refuses while the game in that folder is running" ($run.Code -eq 1 -and $run.Text -match 'ICARUS is running\. Close the game' -and (Get-Tree $oldWin64 -Skip 'Icarus-Win64-Shipping.exe').Count -eq $stateBefore) $run.Text
        }
        $run = Invoke-Setup @('-Action', 'Uninstall', '-GameDir', $directWin64, '-RemoveUE4SS', 'No')
        Check 'a game running from another folder does not block this one' ($run.Code -eq 0) $run.Text
    } finally {
        Stop-Process -Id $standIn.Id -Force -ErrorAction SilentlyContinue
        $standIn.WaitForExit(5000) | Out-Null
    }
} else {
    Check 'a stand-in game process could be built' $false
}
$held = [System.IO.File]::Open((Join-Path $oldWin64 'ue4ss\UE4SS.dll'), 'Open', 'Read', 'Read')
try {
    $run = Invoke-Setup @('-Action', 'Install', '-GameDir', $oldWin64)
    Check 'install refuses when UE4SS.dll is in use, whatever the process is called' ($run.Code -eq 1 -and $run.Text -match 'UE4SS\.dll is in use') $run.Text
} finally { $held.Dispose() }
$held = [System.IO.File]::Open((Join-Path $oldWin64 "$waxPath\bin\waxnet.dll"), 'Open', 'Read', 'Read')
try {
    $run = Invoke-Setup @('-Action', 'Install', '-GameDir', $oldWin64)
    Check 'install refuses when the helper that downloads updates is in use' ($run.Code -eq 1 -and $run.Text -match 'waxnet\.dll is in use') $run.Text
} finally { $held.Dispose() }

Section 'Links where folders are expected'
$linkWin64 = New-FakeGame (Join-Path $work 'linked\Icarus')
$elsewhere = Join-Path $work 'elsewhere\runtime'
New-Item -ItemType Directory -Force (Join-Path $elsewhere 'Scripts'), (Join-Path $elsewhere 'mods\Dev'), (Join-Path $linkWin64 'ue4ss\Mods') | Out-Null
Set-Content -LiteralPath (Join-Path $elsewhere 'Scripts\main.lua') -Value '-- a developer copy'
Set-Content -LiteralPath (Join-Path $elsewhere 'mods\Dev\init.lua') -Value '-- a developer mod'
New-Item -ItemType Junction -Path (Join-Path $linkWin64 $waxPath) -Target $elsewhere | Out-Null
$elsewhereBefore = (Get-Tree (Join-Path $work 'elsewhere')).GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Sort-Object | Out-String
$run = Invoke-Setup @('-Action', 'Install', '-GameDir', $linkWin64)
Check 'install refuses when Wax is a link' ($run.Code -eq 1 -and $run.Text -match 'link to another folder') $run.Text
$run = Invoke-Setup @('-Action', 'Update', '-GameDir', $linkWin64, '-ReleaseApi', (Join-Path $work 'no-such.json'))
Check 'update refuses when Wax is a link' ($run.Code -eq 1 -and $run.Text -match 'link to another folder') $run.Text
$run = Invoke-Setup @('-Action', 'Uninstall', '-GameDir', $linkWin64, '-RemoveMyFiles', 'Yes', '-RemoveUE4SS', 'Yes')
Check 'uninstall removes the link only' ($run.Code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $linkWin64 $waxPath)) -and $run.Text -match 'The link is removed') $run.Text
$run = Invoke-Setup @('-Action', 'Install', '-GameDir', $linkWin64)
Remove-Item -LiteralPath (Join-Path $linkWin64 "$waxPath\mods") -Recurse -Force
New-Item -ItemType Junction -Path (Join-Path $linkWin64 "$waxPath\mods") -Target (Join-Path $elsewhere 'mods') | Out-Null
$run2 = Invoke-Setup @('-Action', 'Install', '-GameDir', $linkWin64)
$run3 = Invoke-Setup @('-Action', 'Uninstall', '-GameDir', $linkWin64, '-RemoveMyFiles', 'Yes', '-RemoveUE4SS', 'Yes')
Check 'install and full uninstall work with Wax\mods as a link' ($run.Code -eq 0 -and $run2.Code -eq 0 -and $run3.Code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $linkWin64 'ue4ss'))) "$($run2.Text) $($run3.Text)"
$elsewhereAfter = (Get-Tree (Join-Path $work 'elsewhere')).GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Sort-Object | Out-String
Check 'nothing behind either link was changed or deleted' ($elsewhereAfter -eq $elsewhereBefore -and $elsewhereBefore -match 'Dev\\init\.lua')

Section 'The .cmd files'
$cmdWin64 = New-FakeGame (Join-Path $work 'cmd test\Icarus')
$out = $null | & (Join-Path $package 'Install Wax.cmd') -GameDir (Join-Path $work 'cmd test\Icarus') 2>&1
Check '"Install Wax.cmd" installs and returns 0' ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $cmdWin64 "$waxPath\Scripts\main.lua")) -and ($out -join "`n") -match 'is installed') ($out -join "`n")
$out = $null | & (Join-Path $package 'Update Wax.cmd') -GameDir (Join-Path $work 'cmd test\Icarus') -ReleaseApi (Join-Path $work 'no-such.json') 2>&1
Check '"Update Wax.cmd" runs the update and returns its result' ($LASTEXITCODE -eq 1 -and ($out -join "`n") -match 'could not be reached') ($out -join "`n")
$out = $null | & (Join-Path $package 'Uninstall Wax.cmd') -GameDir (Join-Path $work 'cmd test\Icarus') -RemoveUE4SS Yes -RemoveMyFiles Yes 2>&1
Check '"Uninstall Wax.cmd" uninstalls and returns 0' ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $cmdWin64 'ue4ss'))) ($out -join "`n")
$alone = Join-Path $work 'run from inside the zip'
New-Item -ItemType Directory -Force $alone | Out-Null
Copy-Item -LiteralPath (Join-Path $package 'Install Wax.cmd') -Destination $alone
$out = $null | & (Join-Path $alone 'Install Wax.cmd') 2>&1
Check 'a .cmd run without the rest of the zip says to extract it first' ($LASTEXITCODE -eq 1 -and ($out -join "`n") -match 'Extract the whole zip first') ($out -join "`n")

Section 'Update (GitHub replaced by files and a local server)'
$updWin64 = New-FakeGame (Join-Path $work 'update\Icarus')
$updArgs = @('-Action', 'Update', '-GameDir', $updWin64)
$notFound = Join-Path $work 'not-found.json'
Set-Content -LiteralPath $notFound -Value '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
$run = Invoke-Setup ($updArgs + @('-ReleaseApi', $notFound))
Check 'update on a game without Wax says to install first' ($run.Code -eq 1 -and $run.Text -match 'Wax is not installed in this game yet') $run.Text
$null = Invoke-Setup @('-Action', 'Install', '-GameDir', $updWin64)
Add-PlayerFiles $updWin64
Set-Content -LiteralPath (Join-Path $updWin64 "$waxPath\VERSION") -Value $version
$before = Get-PlayerState $updWin64
$run = Invoke-Setup ($updArgs + @('-ReleaseApi', $notFound))
Check 'no release yet (the answer GitHub gives, read from a file): plain message, nothing changed' ($run.Code -eq 1 -and $run.Text -match 'There is no Wax release to download yet' -and
    $run.Text.Contains('https://github.com/bostonstrong567/icarus-wax/releases/latest') -and $run.Text -notmatch 'At line|Exception') $run.Text

$newPackage = Join-Path $work 'package-9.9.9'
Copy-Item -LiteralPath $package -Destination $newPackage -Recurse
Set-Content -LiteralPath (Join-Path $newPackage "game\$waxPath\VERSION") -Value '9.9.9'
Set-Content -LiteralPath (Join-Path $newPackage "game\$waxPath\Scripts\wax\added_in_999.lua") -Value 'return {}'
$newZip = Join-Path $work 'Wax-9.9.9.zip'
[System.IO.Compression.ZipFile]::CreateFromDirectory($newPackage, $newZip)
$portFile = Join-Path $work 'port.txt'
$node = (Get-Command node -CommandType Application | Select-Object -First 1).Source
$server = Start-Process -FilePath $node -ArgumentList "`"$(Join-Path $PSScriptRoot 'serve.mjs')`" `"$newZip`" `"$portFile`" $version" -PassThru -WindowStyle Hidden
$oldTemp, $oldTmp = $env:TEMP, $env:TMP
$env:TEMP = $env:TMP = Join-Path $work 'temp'
try {
    for ($i = 0; $i -lt 50 -and -not (Test-Path -LiteralPath $portFile); $i++) { Start-Sleep -Milliseconds 100 }
    $base = "http://127.0.0.1:$((Get-Content -LiteralPath $portFile -Raw).Trim())"
    $run = Invoke-Setup ($updArgs + @('-ReleaseApi', "$base/none"))
    Check 'no release yet (HTTP 404): plain message' ($run.Code -eq 1 -and $run.Text -match 'There is no Wax release to download yet') $run.Text
    $run = Invoke-Setup ($updArgs + @('-ReleaseApi', "$base/limit"))
    Check 'another GitHub error: plain message' ($run.Code -eq 1 -and $run.Text -match 'GitHub answered with error 403') $run.Text
    $run = Invoke-Setup ($updArgs + @('-ReleaseApi', "$base/same"))
    Check 'same version: says so and changes nothing' ($run.Code -eq 0 -and $run.Text -match 'You have the newest version' -and (Get-Content (Join-Path $updWin64 "$waxPath\VERSION") -Raw).Trim() -eq $version) $run.Text
    $run = Invoke-Setup ($updArgs + @('-ReleaseApi', "$base/noasset"))
    Check 'a release without a zip: plain message' ($run.Code -eq 1 -and $run.Text -match 'has no Wax zip attached yet') $run.Text
    $run = Invoke-Setup ($updArgs + @('-ReleaseApi', "$base/broken"))
    Check 'a download that fails: plain message' ($run.Code -eq 1 -and $run.Text -match 'The download did not finish') $run.Text
    $run = Invoke-Setup ($updArgs + @('-ReleaseApi', "$base/notwax"))
    Check 'a download that is not a zip: plain message' ($run.Code -eq 1 -and $run.Text -match 'could not be opened') $run.Text
    Check 'none of those changed the install' ((Get-PlayerState $updWin64) -eq $before -and (Get-Content (Join-Path $updWin64 "$waxPath\VERSION") -Raw).Trim() -eq $version)
    $run = Invoke-Setup ($updArgs + @('-ReleaseApi', "$base/new"))
    Check 'a newer release is downloaded and installed' ($run.Code -eq 0 -and $run.Text -match "Wax was updated from $([regex]::Escape($version)) to 9\.9\.9\." -and
        (Get-Content (Join-Path $updWin64 "$waxPath\VERSION") -Raw).Trim() -eq '9.9.9' -and (Test-Path -LiteralPath (Join-Path $updWin64 "$waxPath\Scripts\wax\added_in_999.lua"))) $run.Text
    Check 'the update kept the player''s mods and settings' ((Get-PlayerState $updWin64) -eq $before)
    Check 'the update cleaned up its download' (@(Get-ChildItem -LiteralPath (Join-Path $work 'temp') -Force).Count -eq 0)
    $run = Invoke-Setup ($updArgs + @('-ReleaseApi', "$base/new"))
    Check 'running the update again finds nothing newer' ($run.Code -eq 0 -and $run.Text -match 'You have the newest version') $run.Text
} finally {
    $env:TEMP, $env:TMP = $oldTemp, $oldTmp
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
}
$run = Invoke-Setup ($updArgs + @('-ReleaseApi', 'http://127.0.0.1:9/latest'))
Check 'no connection: plain message' ($run.Code -eq 1 -and $run.Text -match 'GitHub could not be reached\. Check your internet connection' -and $run.Text -notmatch 'At line|Exception') $run.Text

Section 'Other ways to extract the zip keep the empty folders'
$tarDir = Join-Path $work 'extracted-tar'
New-Item -ItemType Directory -Force $tarDir | Out-Null
# Windows' own tar, by its full path: from a Git shell "tar.exe" is GNU tar, which reads D:\ as a host name
& (Join-Path $env:SystemRoot 'System32\tar.exe') -xf $zip -C $tarDir
$diff = Compare-Tree $expected (Get-Tree (Join-Path $tarDir 'game'))
Check 'tar.exe extracts the same files' ($LASTEXITCODE -eq 0 -and $diff.Count -eq 0) ($diff -join '; ')
foreach ($folder in 'saved', 'run\in', 'run\out') {
    Check "tar.exe makes Wax\$folder" (Test-Path -LiteralPath (Join-Path $tarDir "game\$waxPath\$folder") -PathType Container)
}

Write-Host ''
if ($script:failures.Count) {
    Write-Host "$($script:failures.Count) failed, $($script:passed) passed" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
Write-Host "All $($script:passed) checks passed." -ForegroundColor Green
