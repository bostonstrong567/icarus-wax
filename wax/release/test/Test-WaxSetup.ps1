#requires -Version 7
<#
.SYNOPSIS
  Tests "Wax Setup.exe" against fake game folders under build\setup-test.
.DESCRIPTION
  The same ground as Test-WaxRelease.ps1 covers for the scripts, driven through the program's switches: install,
  install again over a copy that holds a player's own mods and settings, a different UE4SS already in place, a
  running game, links where folders are expected, uninstall, verify and repair. On top of that: a copy that fails
  half way and one that is killed half way, the wax:// registration (under a scheme name of its own, never the
  real one), mod links against a local stand-in for the catalogue (catalogue.mjs), and the window pressing its own
  buttons where nobody sees it. Nothing here touches the real game, the real wax:// registration or the network.
  Never run it at the same time as itself. It can run beside Test-WaxRelease.ps1: it has its own folder.
.EXAMPLE
  .\scripts\Build-WaxRelease.ps1; .\wax\release\test\Test-WaxSetup.ps1 *> build\setup-test.log
#>
[CmdletBinding()]
param()
. "$PSScriptRoot\..\..\..\scripts\_common.ps1"

$version = (Get-Content (Join-Path $Root 'wax\VERSION') -Raw).Trim()
$zip     = Join-Path $BuildDir "Wax-$version.zip"
$work    = Join-Path $BuildDir 'setup-test'
$data    = Join-Path $work 'data'
$shots   = Join-Path $work 'shots'
# A folder name like the ones a second download and "Extract All" produce.
$package = Join-Path $work "Bob's Downloads\Wax-$version (1)"
$setup   = Join-Path $package 'Wax Setup.exe'
$waxPath = 'ue4ss\Mods\Wax'
$scheme  = 'wax-test-setup'
$schemeKey = "HKCU:\Software\Classes\$scheme"
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
    & icacls.exe $Path /remove:d '*S-1-1-0' /T /C /Q 2>&1 | Out-Null
    Get-ChildItem -LiteralPath $Path -Recurse -Force -Attributes ReparsePoint | ForEach-Object { [System.IO.Directory]::Delete($_.FullName) }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Get-Link([string]$Name) {
    try { [string](Get-ItemProperty -Path "HKCU:\Software\Classes\$Name\shell\open\command" -ErrorAction Stop).'(default)' } catch { '' }
}

# Runs the program without its window and waits. Every run keeps its notes in the test's own folder, and leaves
# the wax:// registration alone unless -Links is given, which registers under the test's scheme name.
function Invoke-Setup {
    param([string[]]$Arguments, [string]$Exe = $setup, [switch]$Links, [string]$Trial = '')
    $result = Join-Path $work 'result.txt'
    Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue
    $all = @('--data', $data, '--result', $result)
    $all += if ($Links) { @('--scheme', $scheme) } else { @('--no-links') }
    $all += $Arguments
    $env:WAX_SETUP_TEST = $Trial
    try { $out = & $Exe @all 2>&1 | Out-String }
    finally { $env:WAX_SETUP_TEST = '' }
    $code = $LASTEXITCODE
    $text = if (Test-Path -LiteralPath $result) { Get-Content -LiteralPath $result -Raw } else { '' }
    [pscustomobject]@{ Code = $code; Text = "$text"; Out = "$out" }
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

# Every file and every folder under a game folder, as one text: two of these are equal only when nothing changed.
function Get-Print([string]$Dir) {
    $lines = @((Get-Tree $Dir).GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    $lines += @(Get-ChildItem -LiteralPath $Dir -Recurse -Force -Directory | ForEach-Object { "dir:" + $_.FullName.Substring($Dir.Length) })
    ($lines | Sort-Object) -join "`n"
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
    New-Item -ItemType Directory -Force (Join-Path $wax 'Scripts.before-0.0.8') | Out-Null
    Set-Content -LiteralPath (Join-Path $wax 'Scripts.before-0.0.8\main.lua') -Value '-- kept by an update Wax made to itself'
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

# What the program adds to the zip's game folder: a copy of itself for links, and its note of what it installed.
$own = "$waxPath\Wax Setup.exe", "$waxPath\installed.txt"

function Test-Installed([string]$Label, [string]$Win64, [hashtable]$Expected) {
    $actual = Get-Tree $Win64 -Skip (@('Icarus-Win64-Shipping.exe', 'tbb12.dll', "$waxPath\mods\*", "$waxPath\saved\*", "$waxPath\run\*",
        'ue4ss\Mods\OtherMod\*', 'ue4ss-backup-*', 'ue4ss\UE4SS-settings.ini', 'ue4ss\Mods\mods.txt') + $own)
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
    Check "${Label}: a copy of the program is in the Wax folder, with its note of what it installed" (
        (Test-Path -LiteralPath (Join-Path $wax 'Wax Setup.exe')) -and (Get-FileHash -LiteralPath (Join-Path $wax 'Wax Setup.exe')).Hash -eq $setupHash -and
        (Get-Content -LiteralPath (Join-Path $wax 'installed.txt') -Raw) -match "(?m)^version=$([regex]::Escape($version))\r?$" -and
        (Get-Content -LiteralPath (Join-Path $wax 'installed.txt') -Raw) -match '(?m)^file=dwmapi\.dll\r?$')
    Check "${Label}: nothing of the work is left behind" (-not (Test-Path -LiteralPath (Join-Path $Win64 'wax-setup-work')))
    Check "${Label}: the game's own files are untouched" ((Get-Content -LiteralPath (Join-Path $Win64 'Icarus-Win64-Shipping.exe') -Raw).Trim() -eq 'not the real game' -and
        (Get-Content -LiteralPath (Join-Path $Win64 'tbb12.dll') -Raw).Trim() -eq 'a game file')
}

# Install, install over a player's files, a different UE4SS, uninstall keeping things, uninstall removing all.
function Test-Cycle([string]$Label, [string[]]$Locate, [string]$Win64, [hashtable]$Expected) {
    Section "$Label ($($Locate -join ' '))"
    $wax = Join-Path $Win64 $waxPath

    $run = Invoke-Setup (@('--status') + $Locate)
    Check "${Label}: before anything, the state is 'not installed'" ($run.Code -eq 0 -and $run.Text -match '(?m)^state=not-installed\r?$' -and $run.Text.Contains("game=$Win64")) $run.Text
    $run = Invoke-Setup (@('--install') + $Locate)
    Check "${Label}: install exits 0" ($run.Code -eq 0) $run.Text
    Check "${Label}: what it writes to the result file is what it writes to standard output" ($run.Text -and $run.Text -eq $run.Out)
    Check "${Label}: install names the game folder it found" ($run.Text.Contains($Win64))
    Check "${Label}: install says what it did" ($run.Text -cmatch "Wax $([regex]::Escape($version)) is installed\.")
    Check "${Label}: install says what to do next" ($run.Text -match 'Press F8' -and $run.Text.Contains('https://wax-icarus.duckdns.org/'))
    Test-Installed "$Label install" $Win64 $Expected
    $diff = Compare-Tree $Expected (Get-Tree $Win64 -Skip (@('Icarus-Win64-Shipping.exe', 'tbb12.dll') + $own))
    Check "${Label}: a first install is the zip's game folder exactly, UE4SS settings and Recipe Browser included" ($diff.Count -eq 0) (($diff | Select-Object -First 5) -join '; ')
    Check "${Label}: Recipe Browser is there" (Test-Path -LiteralPath (Join-Path $wax 'mods\RecipeBrowser\init.lua'))
    Check "${Label}: the installed copy is free to update itself: it has a VERSION file and no dev.txt" ((Test-Path -LiteralPath (Join-Path $wax 'VERSION')) -and
        -not (Test-Path -LiteralPath (Join-Path $wax 'dev.txt')))
    Check "${Label}: Recipe Browser is marked as a mod from the catalogue, and the helper that updates it is installed" ((Test-Path -LiteralPath (Join-Path $wax 'mods\RecipeBrowser\wax.origin')) -and
        (Test-Path -LiteralPath (Join-Path $wax 'bin\waxnet.dll')))
    Check "${Label}: the version file says $version" ((Get-Content -LiteralPath (Join-Path $wax 'VERSION') -Raw).Trim() -eq $version)
    Check "${Label}: nothing was backed up on a clean game" (-not (Test-Path (Join-Path $Win64 'ue4ss-backup-*')))
    Check "${Label}: it notes that it brought UE4SS itself" ((Get-Content -LiteralPath (Join-Path $wax 'installed.txt') -Raw) -match '(?m)^loader=ours\r?$')
    $run = Invoke-Setup (@('--status') + $Locate)
    Check "${Label}: the state is now 'same'" ($run.Text -match '(?m)^state=same\r?$' -and $run.Text -match "(?m)^installed=$([regex]::Escape($version))\r?$") $run.Text
    $run = Invoke-Setup (@('--verify') + $Locate)
    Check "${Label}: verify finds every file in place" ($run.Code -eq 0 -and $run.Text -match "Wax $([regex]::Escape($version)) is complete\. All \d{4} files are in place\.") $run.Text

    Add-PlayerFiles $Win64
    $before = Get-PlayerState $Win64
    $run = Invoke-Setup (@('--status') + $Locate)
    Check "${Label}: with an older version file the state is 'older'" ($run.Text -match '(?m)^state=older\r?$' -and $run.Text -match '(?m)^installed=0\.0\.9\r?$') $run.Text
    $run = Invoke-Setup (@('--install') + $Locate)
    Check "${Label}: install over an old copy exits 0" ($run.Code -eq 0) $run.Text
    Check "${Label}: it reports the update" ($run.Text -match "Wax was updated from 0\.0\.9 to $([regex]::Escape($version))\.")
    Check "${Label}: it says the player's files were kept" ($run.Text -match 'Your mods and settings were kept\.')
    Check "${Label}: the player's mods and settings are unchanged" ((Get-PlayerState $Win64) -eq $before)
    Check "${Label}: a mod the player made is not marked as one from the catalogue" (-not (Test-Path -LiteralPath (Join-Path $wax 'mods\MyMod\wax.origin')))
    Check "${Label}: a file of the old Wax version is gone, and so is what an update Wax made to itself had kept" (
        -not (Test-Path -LiteralPath (Join-Path $wax 'Scripts\wax\gone.lua')) -and -not (Test-Path -LiteralPath (Join-Path $wax 'Scripts.before-0.0.8')))
    Check "${Label}: the session log is still there" (Test-Path -LiteralPath (Join-Path $wax 'run\session.log'))
    Check "${Label}: the player's UE4SS settings are kept on the same UE4SS" ((Get-Content -LiteralPath (Join-Path $Win64 'ue4ss\UE4SS-settings.ini') -Raw) -match 'changed by the player' -and
        (Get-Content -LiteralPath (Join-Path $Win64 'ue4ss\Mods\mods.txt') -Raw) -match 'OtherMod : 1' -and $run.Text -match 'Your own UE4SS settings were kept')
    Check "${Label}: still nothing backed up" (-not (Test-Path (Join-Path $Win64 'ue4ss-backup-*')))
    Check "${Label}: it still knows that it brought UE4SS itself" ((Get-Content -LiteralPath (Join-Path $wax 'installed.txt') -Raw) -match '(?m)^loader=ours\r?$')
    Test-Installed "$Label reinstall" $Win64 $Expected
    $run = Invoke-Setup (@('--verify') + $Locate)
    Check "${Label}: verify passes with the player's own mods and UE4SS settings in place" ($run.Code -eq 0 -and $run.Text -match 'is complete') $run.Text

    Set-Content -LiteralPath (Join-Path $Win64 'dwmapi.dll') -Value 'another proxy'
    Set-Content -LiteralPath (Join-Path $Win64 'ue4ss\UE4SS.dll') -Value 'another UE4SS'
    Set-Content -LiteralPath (Join-Path $Win64 'UE4SS.dll') -Value 'UE4SS in the old layout'
    $run = Invoke-Setup (@('--verify') + $Locate)
    Check "${Label}: verify names the two files that were changed and exits 1" ($run.Code -eq 1 -and $run.Text -match '2 files are missing or changed\.' -and
        $run.Text -match '(?m)^  dwmapi\.dll\r?$' -and $run.Text -match '(?m)^  ue4ss\\UE4SS\.dll\r?$' -and $run.Text -match 'Repair') $run.Text
    $run = Invoke-Setup (@('--install') + $Locate)
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
    Check "${Label}: nothing of the work is left behind after the replacement" (-not (Test-Path -LiteralPath (Join-Path $Win64 'wax-setup-work')))
    Remove-Item -LiteralPath (Join-Path $Win64 'UE4SS.dll')

    $run = Invoke-Setup (@('--uninstall') + $Locate)
    Check "${Label}: uninstall with nothing else said exits 0" ($run.Code -eq 0) $run.Text
    Check "${Label}: Wax's own files are gone, the copy of the program too" (-not (Test-Path -LiteralPath (Join-Path $wax 'Scripts')) -and -not (Test-Path -LiteralPath (Join-Path $wax 'enabled.txt')) -and
        -not (Test-Path -LiteralPath (Join-Path $wax 'assets')) -and -not (Test-Path -LiteralPath (Join-Path $wax 'bin')) -and -not (Test-Path -LiteralPath (Join-Path $wax 'run')) -and
        -not (Test-Path -LiteralPath (Join-Path $wax 'Wax Setup.exe')) -and -not (Test-Path -LiteralPath (Join-Path $wax 'installed.txt')))
    Check "${Label}: the player's mods and settings were kept, and it says where" ((Get-PlayerState $Win64) -eq $before -and $run.Text -match 'Your mods and settings are still here' -and $run.Text.Contains($wax))
    Check "${Label}: UE4SS was kept" ((Test-Path -LiteralPath (Join-Path $Win64 'dwmapi.dll')) -and (Test-Path -LiteralPath (Join-Path $Win64 'ue4ss\UE4SS.dll')) -and $run.Text -match 'UE4SS is still installed')

    $run = Invoke-Setup (@('--install') + $Locate)
    Check "${Label}: installing again after that picks the player's files back up" ($run.Code -eq 0 -and (Get-PlayerState $Win64) -eq $before -and
        (Test-Path -LiteralPath (Join-Path $wax 'Scripts\main.lua')) -and $run.Text -cmatch "Wax $([regex]::Escape($version)) is installed\.")
    Check "${Label}: this time it notes that UE4SS was there before it" ((Get-Content -LiteralPath (Join-Path $wax 'installed.txt') -Raw) -match '(?m)^loader=found\r?$')
    $run = Invoke-Setup (@('--install') + $Locate)
    Check "${Label}: installing the same version over itself says 'installed again'" ($run.Code -eq 0 -and $run.Text -match "Wax $([regex]::Escape($version)) was installed again\.") $run.Text

    $run = Invoke-Setup (@('--uninstall', '--remove-mine', '--remove-ue4ss') + $Locate)
    Check "${Label}: uninstall of everything exits 0" ($run.Code -eq 0) $run.Text
    Check "${Label}: Wax, the player's files and UE4SS are gone" (-not (Test-Path -LiteralPath $wax) -and -not (Test-Path -LiteralPath (Join-Path $Win64 'dwmapi.dll')) -and
        -not (Test-Path -LiteralPath (Join-Path $Win64 'ue4ss\UE4SS.dll')) -and -not (Test-Path -LiteralPath (Join-Path $Win64 'ue4ss\UE4SS-settings.ini')) -and
        -not (Test-Path -LiteralPath (Join-Path $Win64 'ue4ss\Mods\Keybinds')) -and -not (Test-Path -LiteralPath (Join-Path $Win64 'ue4ss\Mods\shared')) -and $run.Text -match 'UE4SS is removed\.')
    Check "${Label}: someone else's UE4SS mod is left alone and named" ((Test-Path -LiteralPath (Join-Path $Win64 'ue4ss\Mods\OtherMod\Scripts\main.lua')) -and $run.Text -match 'OtherMod')
    $left = @(Get-ChildItem -LiteralPath (Join-Path $Win64 'ue4ss') -Recurse -Force -File | ForEach-Object { $_.FullName.Substring($Win64.Length + 1) })
    Check "${Label}: that mod is all that is left under ue4ss" (($left -join '|') -eq 'ue4ss\Mods\OtherMod\Scripts\main.lua') ($left -join ', ')
    Check "${Label}: the backup folder is left and named" ($backup.Count -eq 1 -and (Test-Path -LiteralPath $backup[0].FullName) -and $run.Text.Contains($backup[0].FullName))
    Check "${Label}: the game's own files are untouched" ((Get-Content -LiteralPath (Join-Path $Win64 'Icarus-Win64-Shipping.exe') -Raw).Trim() -eq 'not the real game')

    $run = Invoke-Setup (@('--uninstall', '--remove-ue4ss') + $Locate)
    Check "${Label}: a second full uninstall leaves the other mod and exits 0" ($run.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $Win64 'ue4ss\Mods\OtherMod\Scripts\main.lua')))
}

$realLinkBefore = Get-Link 'wax'
$realData = Join-Path $env:LOCALAPPDATA 'Wax'
$realDataBefore = if (Test-Path -LiteralPath $realData) { (Get-ChildItem -LiteralPath $realData -Force | ForEach-Object { "$($_.Name) $($_.LastWriteTimeUtc.Ticks)" }) -join '|' } else { 'none' }

Section 'Setting up build\setup-test'
if (Test-Path $schemeKey) { Remove-Item -Path $schemeKey -Recurse -Force }
Clear-Folder $work
New-Item -ItemType Directory -Force $work, $data, $shots | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $package)
Check 'the zip holds "Wax Setup.exe" beside the scripts' (Test-Path -LiteralPath $setup)
if (-not (Test-Path -LiteralPath $setup)) { throw 'There is no program to test.' }
$setupHash = (Get-FileHash -LiteralPath $setup).Hash
$expected = Get-Tree (Join-Path $package 'game')
Check 'it is the program Build-WaxSetup.ps1 made last' ($setupHash -eq (Get-FileHash -LiteralPath (Join-Path $BuildDir 'setup\Wax Setup.exe')).Hash)

Section 'The program itself'
$bytes = [System.IO.File]::ReadAllBytes($setup)
$latin = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
$wide = [System.Text.Encoding]::Unicode.GetString($bytes)
$beside = @(Get-ChildItem -LiteralPath (Join-Path $BuildDir 'setup\bin\Release') -File | Where-Object Name -ne 'Wax Setup.exe')
Check "it is one file with nothing it needs beside it ($([math]::Round($bytes.Length / 1MB, 2)) MB)" ($beside.Count -eq 0 -and $bytes.Length -lt 16MB) (($beside | ForEach-Object Name) -join ', ')
Check 'it is built for .NET Framework 4.8, which every Windows 10 and 11 has' ($latin.Contains('.NETFramework,Version=v4.8'))
Check 'it asks for no administrator rights' ($latin.Contains('requestedExecutionLevel level="asInvoker"'))
Check 'it starts no script and no shell: the words are nowhere in it' (-not ($wide -match 'powershell|ExecutionPolicy|cmd\.exe|\.ps1') -and -not ($latin -match 'powershell|ExecutionPolicy'))
$run = Invoke-Setup @('--help', '--quiet')
Check '--help lists the switches and exits 0' ($run.Code -eq 0 -and $run.Text -match '--install' -and $run.Text -match '--uninstall' -and $run.Text -match '--verify' -and $run.Text -match '--game <folder>' -and $run.Text -match '--result <file>')
$run = Invoke-Setup @('--frobnicate')
Check 'a switch it does not know is refused with exit code 2' ($run.Code -eq 2 -and $run.Text -match 'does not know the switch --frobnicate') $run.Text
$run = Invoke-Setup @('--scheme', 'http', '--status')
Check 'the scheme switch only takes names made for tests' ($run.Code -eq 2 -and $run.Text -match 'wax-test') $run.Text

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

Test-Cycle 'GameDir' @('--game', (Join-Path $work 'direct\Icarus')) $directWin64 $expected
Test-Cycle 'SteamRoot' @('--steam', $steam) $steamWin64 $expected

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
$run = Invoke-Setup @('--uninstall', '--steam', $oldSteam)
Check 'an old-style library list, an unplugged drive and another install folder name still lead to the game' ($run.Code -eq 0 -and $run.Text.Contains($oldWin64) -and $run.Text -match 'Wax is not installed in this game') $run.Text
foreach ($form in $oldWin64, (Split-Path (Split-Path $oldWin64)), (Join-Path $oldWin64 'Icarus-Win64-Shipping.exe'), "`"$(Split-Path (Split-Path (Split-Path $oldWin64)))`"") {
    $run = Invoke-Setup @('--where', '--game', $form)
    Check "--game accepts $($form.Replace($work, '...'))" ($run.Code -eq 0 -and $run.Text.Trim() -eq $oldWin64) $run.Text
}
$run = Invoke-Setup @('--where', '--game', $oldWin64.ToLower())
Check 'a folder given in lower case, as Steam writes its own, comes back with the capital letters it has on disk' ($run.Code -eq 0 -and $run.Text.Trim() -ceq $oldWin64) $run.Text
$run = Invoke-Setup @('--install', '--game', (Join-Path $work 'no-game-here'))
Check 'a folder without the game is refused with a plain message' ($run.Code -eq 1 -and $run.Text -match 'ICARUS is not in this folder' -and $run.Text -notmatch 'Exception|   at ') $run.Text
$notGame = Join-Path $work 'not a game\Icarus\Binaries\Win64'
New-Item -ItemType Directory -Force $notGame | Out-Null
Set-Content -LiteralPath (Join-Path $notGame 'SomeOtherGame.exe') -Value 'another game'
$run = Invoke-Setup @('--install', '--game', (Join-Path $work 'not a game'))
Check 'a folder laid out like the game but without its exe is refused, and nothing is written there' ($run.Code -eq 1 -and $run.Text -match 'ICARUS is not in this folder' -and
    @(Get-ChildItem -LiteralPath $notGame -Force).Count -eq 1) $run.Text
$emptySteam = Join-Path $work 'steam-empty'
New-Item -ItemType Directory -Force $emptySteam | Out-Null
$run = Invoke-Setup @('--install', '--steam', $emptySteam)
Check 'when Steam does not know the game, it stops without changing anything and says how to give the folder' ($run.Code -eq 1 -and $run.Text -match 'Steam did not say where ICARUS is installed' -and
    $run.Text -match '--game' -and $run.Text -match 'Nothing was changed\.' -and -not (Test-Path (Join-Path $oldWin64 'dwmapi.dll'))) $run.Text
$run = Invoke-Setup @('--status', '--steam', $emptySteam)
Check 'the state is then "no game"' ($run.Code -eq 0 -and $run.Text -match '(?m)^state=no-game\r?$') $run.Text
$accentSteam = Join-Path $work 'steam-accent'
$accentLibrary = Join-Path $work ('Jeux de Ren' + [char]0xE9)
New-Item -ItemType Directory -Force (Join-Path $accentSteam 'steamapps'), (Join-Path $accentLibrary 'steamapps') | Out-Null
Set-Content -LiteralPath (Join-Path $accentSteam 'steamapps\libraryfolders.vdf') -Value "`"libraryfolders`"`n{`n`t`"0`"`n`t{`n`t`t`"path`"`t`t`"$($accentLibrary.Replace('\', '\\'))`"`n`t}`n}"
Set-Content -LiteralPath (Join-Path $accentLibrary 'steamapps\appmanifest_1149460.acf') -Value "`"AppState`"`n{`n`t`"installdir`"`t`t`"Icarus`"`n}"
$accentWin64 = New-FakeGame (Join-Path $accentLibrary 'steamapps\common\Icarus')
$run = Invoke-Setup @('--install', '--steam', $accentSteam)
Check 'a Steam library with an accented letter in its name is found and installed into' ($run.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $accentWin64 "$waxPath\Scripts\main.lua")) -and $run.Text.Contains($accentWin64)) $run.Text
$null = Invoke-Setup @('--install', '--game', $oldWin64)
# Only the lookup is run for real: it reads Steam's registry key, its library list and the app manifest, and opens nothing.
$configFile = Join-Path $Root 'wax\wax.config.json'
$real = if (Test-Path -LiteralPath $configFile) { (Get-Content $configFile -Raw | ConvertFrom-Json).win64 }
if ($real -and (Test-Path -LiteralPath (Join-Path $real 'Icarus-Win64-Shipping.exe'))) {
    $run = Invoke-Setup @('--where')
    Check "the program's Steam lookup (registry, library list, app manifest) finds the real game folder" ($run.Code -eq 0 -and $run.Text.Trim().TrimEnd('\') -ieq "$real".TrimEnd('\')) $run.Text
} else {
    Write-Host '  skipped: no real game folder on this machine'
}

Section 'A running game'
$fakeExe = Join-Path $oldWin64 'Icarus-Win64-Shipping.exe'
$standSource = Join-Path $work 'stand-in.cs'
# Stands in for the game: it runs for a few minutes, and when given a Wax folder it takes requests the way Wax does.
Set-Content -LiteralPath $standSource -Value @'
using System;
using System.IO;
using System.Threading;
public static class Stand {
    public static void Main(string[] args) {
        var until = DateTime.UtcNow.AddSeconds(180);
        while (DateTime.UtcNow < until) {
            Thread.Sleep(15);
            if (args.Length == 0) continue;
            string inbox = Path.Combine(args[0], @"run\in");
            if (!Directory.Exists(inbox)) continue;
            foreach (string request in Directory.GetFiles(inbox, "*.lua")) {
                string text = File.ReadAllText(request);
                File.Delete(request);
                File.AppendAllText(Path.Combine(args[0], @"run\taken.txt"), text + "\n");
                string id = text.Substring(5, text.IndexOf('\n') - 5);
                File.WriteAllText(Path.Combine(args[0], @"run\out\" + id + ".json"), "{\"ok\":true}");
            }
        }
    }
}
'@
Remove-Item -LiteralPath $fakeExe -Force
& (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:winexe "/out:$fakeExe" $standSource | Out-Null
if (Test-Path -LiteralPath $fakeExe) {
    $stateBefore = Get-Print $oldWin64
    $standIn = Start-Process -FilePath $fakeExe -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Milliseconds 800
        foreach ($action in @('--install'), @('--uninstall', '--remove-mine', '--remove-ue4ss')) {
            $run = Invoke-Setup ($action + @('--game', $oldWin64))
            Check "$($action[0]) refuses while the game in that folder is running" ($run.Code -eq 1 -and $run.Text -match 'ICARUS is running\. Close the game' -and (Get-Print $oldWin64) -eq $stateBefore) $run.Text
        }
        $run = Invoke-Setup @('--status', '--game', $oldWin64)
        Check 'the state says that the game is running' ($run.Text -match '(?m)^running=yes\r?$') $run.Text
        $run = Invoke-Setup @('--uninstall', '--game', $directWin64)
        Check 'a game running from another folder does not block this one' ($run.Code -eq 0) $run.Text
        $run = Invoke-Setup @('--status', '--game', $directWin64)
        Check 'and its state says that no game is running there' ($run.Text -match '(?m)^running=no\r?$') $run.Text
    } finally {
        Stop-Process -Id $standIn.Id -Force -ErrorAction SilentlyContinue
        $standIn.WaitForExit(5000) | Out-Null
    }
} else {
    Check 'a stand-in game process could be built' $false
}
$held = [System.IO.File]::Open((Join-Path $oldWin64 'ue4ss\UE4SS.dll'), 'Open', 'Read', 'Read')
try {
    $run = Invoke-Setup @('--install', '--game', $oldWin64)
    Check 'install refuses when UE4SS.dll is in use, whatever the process is called' ($run.Code -eq 1 -and $run.Text -match 'UE4SS\.dll is in use') $run.Text
} finally { $held.Dispose() }
$held = [System.IO.File]::Open((Join-Path $oldWin64 "$waxPath\bin\waxnet.dll"), 'Open', 'Read', 'Read')
try {
    $run = Invoke-Setup @('--install', '--game', $oldWin64)
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
$run = Invoke-Setup @('--install', '--game', $linkWin64)
Check 'install refuses when Wax is a link, shows both folders and says nothing was changed' ($run.Code -eq 1 -and $run.Text -match 'link to another folder' -and
    $run.Text.Contains((Join-Path $linkWin64 $waxPath)) -and $run.Text.Contains($elsewhere) -and $run.Text -match 'Nothing was changed\.') $run.Text
$run = Invoke-Setup @('--status', '--game', $linkWin64)
Check 'the state for it is "link", and it says where the link leads' ($run.Text -match '(?m)^state=link\r?$' -and $run.Text.Contains("leads-to=$elsewhere")) $run.Text
$run = Invoke-Setup @('--verify', '--game', $linkWin64)
Check 'verify says there is nothing to check behind a link' ($run.Code -eq 1 -and $run.Text -match 'link to another folder') $run.Text
$run = Invoke-Setup @('--uninstall', '--remove-mine', '--remove-ue4ss', '--game', $linkWin64)
Check 'uninstall removes the link only' ($run.Code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $linkWin64 $waxPath)) -and $run.Text -match 'The link is removed') $run.Text
$run = Invoke-Setup @('--install', '--game', $linkWin64)
Remove-Item -LiteralPath (Join-Path $linkWin64 "$waxPath\mods") -Recurse -Force
New-Item -ItemType Junction -Path (Join-Path $linkWin64 "$waxPath\mods") -Target (Join-Path $elsewhere 'mods') | Out-Null
$run2 = Invoke-Setup @('--install', '--game', $linkWin64)
$run3 = Invoke-Setup @('--uninstall', '--remove-mine', '--remove-ue4ss', '--game', $linkWin64)
Check 'install and full uninstall work with Wax\mods as a link' ($run.Code -eq 0 -and $run2.Code -eq 0 -and $run3.Code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $linkWin64 'ue4ss'))) "$($run2.Text) $($run3.Text)"
$elsewhereAfter = (Get-Tree (Join-Path $work 'elsewhere')).GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Sort-Object | Out-String
Check 'nothing behind either link was changed or deleted' ($elsewhereAfter -eq $elsewhereBefore -and $elsewhereBefore -match 'Dev\\init\.lua')
$null = Invoke-Setup @('--install', '--game', $linkWin64)
Remove-Item -LiteralPath (Join-Path $linkWin64 'ue4ss\Mods\shared') -Recurse -Force
New-Item -ItemType Directory -Force (Join-Path $elsewhere 'shared\UEHelpers') | Out-Null
Set-Content -LiteralPath (Join-Path $elsewhere 'shared\UEHelpers\UEHelpers.lua') -Value '-- somebody else''s copy'
New-Item -ItemType Junction -Path (Join-Path $linkWin64 'ue4ss\Mods\shared') -Target (Join-Path $elsewhere 'shared') | Out-Null
$elsewhereBefore = (Get-Tree (Join-Path $work 'elsewhere')).GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Sort-Object | Out-String
$run = Invoke-Setup @('--uninstall', '--remove-mine', '--remove-ue4ss', '--game', $linkWin64)
Check 'a full uninstall does not follow a link inside ue4ss to remove files behind it' ($run.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $elsewhere 'shared\UEHelpers\UEHelpers.lua'))) $run.Text
$elsewhereAfter = (Get-Tree (Join-Path $work 'elsewhere')).GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Sort-Object | Out-String
Check 'and nothing behind that link was changed or deleted either' ($elsewhereAfter -eq $elsewhereBefore -and $elsewhereBefore -match 'UEHelpers\.lua')

Section 'A newer Wax in the game, and repair'
$newWin64 = New-FakeGame (Join-Path $work 'newer\Icarus')
$null = Invoke-Setup @('--install', '--game', $newWin64)
Add-PlayerFiles $newWin64
Set-Content -LiteralPath (Join-Path $newWin64 "$waxPath\VERSION") -Value '9.9.9'
Set-Content -LiteralPath (Join-Path $newWin64 "$waxPath\Scripts\wax\added_in_999.lua") -Value 'return {}'
$newBefore = Get-Print $newWin64
$run = Invoke-Setup @('--status', '--game', $newWin64)
Check 'the state is "newer" when the game holds a newer Wax than the program' ($run.Text -match '(?m)^state=newer\r?$' -and $run.Text -match '(?m)^installed=9\.9\.9\r?$') $run.Text
$run = Invoke-Setup @('--install', '--game', $newWin64)
Check 'install then changes nothing, and says where the newest program is' ($run.Code -eq 1 -and $run.Text -match 'Wax 9\.9\.9 is in this game' -and $run.Text -match 'Nothing was changed\.' -and
    $run.Text.Contains('https://wax-icarus.duckdns.org/docs/install/') -and (Get-Print $newWin64) -eq $newBefore) $run.Text
$run = Invoke-Setup @('--verify', '--game', $newWin64)
Check 'verify says the versions differ and compares nothing' ($run.Code -eq 1 -and $run.Text -match 'cannot be compared') $run.Text
$run = Invoke-Setup @('--install', '--force', '--game', $newWin64)
Check 'with --force the older version is put in all the same' ($run.Code -eq 0 -and $run.Text -match "Wax was updated from 9\.9\.9 to $([regex]::Escape($version))\." -and
    -not (Test-Path -LiteralPath (Join-Path $newWin64 "$waxPath\Scripts\wax\added_in_999.lua"))) $run.Text
Remove-Item -LiteralPath (Join-Path $newWin64 "$waxPath\Scripts\wax\boot.lua")
Add-Content -LiteralPath (Join-Path $newWin64 "$waxPath\Scripts\main.lua") -Value '-- damaged'
Remove-Item -LiteralPath (Join-Path $newWin64 "$waxPath\run\out") -Recurse -Force
$run = Invoke-Setup @('--verify', '--game', $newWin64)
Check 'verify finds a deleted file, a changed file and a missing folder' ($run.Code -eq 1 -and $run.Text -match '3 files are missing or changed' -and $run.Text -match 'boot\.lua' -and
    $run.Text -match 'Scripts\\main\.lua' -and $run.Text -match 'run\\out') $run.Text
$run = Invoke-Setup @('--install', '--game', $newWin64)
$check = Invoke-Setup @('--verify', '--game', $newWin64)
Check 'installing again repairs it' ($run.Code -eq 0 -and $run.Text -match 'was installed again' -and $check.Code -eq 0) "$($run.Text) $($check.Text)"
Set-Content -LiteralPath (Join-Path $newWin64 "$waxPath\VERSION") -Value ''
$run = Invoke-Setup @('--install', '--game', $newWin64)
Check 'a copy with an empty version file is replaced, and it says so' ($run.Code -eq 0 -and $run.Text -match "Wax $([regex]::Escape($version)) replaced the copy that was there\.") $run.Text

Section 'A copy that fails half way'
$undoWin64 = New-FakeGame (Join-Path $work 'undo\Icarus')
$null = Invoke-Setup @('--install', '--game', $undoWin64)
Add-PlayerFiles $undoWin64
Set-Content -LiteralPath (Join-Path $undoWin64 'dwmapi.dll') -Value 'another proxy'
Set-Content -LiteralPath (Join-Path $undoWin64 'ue4ss\UE4SS.dll') -Value 'another UE4SS'
Remove-Item -LiteralPath (Join-Path $undoWin64 'ue4ss\Mods\Keybinds') -Recurse -Force
$undoBefore = Get-Print $undoWin64
foreach ($at in 1, 2, 5, 9, 14, 19) {
    $run = Invoke-Setup @('--install', '--game', $undoWin64) -Trial "fail:$at"
    $same = (Get-Print $undoWin64) -eq $undoBefore
    Check "a failure at change $at of the game folder: exit 1, a plain message, and every file and folder as it was" ($run.Code -eq 1 -and $same -and
        $run.Text -match 'everything was put back as it was' -and $run.Text -notmatch 'Exception|   at ') $run.Text
}
$held = [System.IO.File]::Open((Join-Path $undoWin64 "$waxPath\Scripts\wax\boot.lua"), 'Open', 'Read', 'None')
try { $run = Invoke-Setup @('--install', '--game', $undoWin64) }
finally { $held.Dispose() }
Check 'a file of the old Wax held open by another program: exit 1, and everything as it was' ($run.Code -eq 1 -and (Get-Print $undoWin64) -eq $undoBefore -and
    $run.Text -match 'everything was put back as it was' -and $run.Text -match 'Close the game if it is open') $run.Text
$run = Invoke-Setup @('--install', '--game', $undoWin64) -Trial 'stop:9'
$half = Get-Print $undoWin64
Check 'the program killed half way leaves the folder half changed, with its notes of what it did' ($run.Code -eq 9 -and $half -ne $undoBefore -and
    (Test-Path -LiteralPath (Join-Path $undoWin64 'wax-setup-work\journal.txt')))
$run = Invoke-Setup @('--install', '--game', $undoWin64) -Trial 'fail:1'
Check 'the next run first takes that back: after it fails at once itself, every file and folder is as it was before both' ($run.Code -eq 1 -and (Get-Print $undoWin64) -eq $undoBefore) $run.Text
$run = Invoke-Setup @('--install', '--game', $undoWin64) -Trial 'stop:14'
$run = Invoke-Setup @('--install', '--game', $undoWin64)
$check = Invoke-Setup @('--verify', '--game', $undoWin64)
Check 'killed half way again, then run normally: it installs, and verify passes' ($run.Code -eq 0 -and $check.Code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $undoWin64 'wax-setup-work'))) "$($run.Text) $($check.Text)"
Check 'the log of all this is in the test''s own folder' ((Get-Content -LiteralPath (Join-Path $data 'setup.log') -Raw) -match 'taken back')

Section 'A game folder that cannot be written to'
$lockedWin64 = New-FakeGame (Join-Path $work 'locked\Icarus')
& icacls.exe $lockedWin64 /deny '*S-1-1-0:(OI)(CI)(WD,AD,DC)' /Q | Out-Null
try {
    $run = Invoke-Setup @('--install', '--game', $lockedWin64)
    Check 'it says so plainly, names the folder, and asks for no administrator rights' ($run.Code -eq 1 -and $run.Text -match 'Windows does not let this program write to the game folder' -and
        $run.Text.Contains($lockedWin64) -and $run.Text -notmatch 'administrator|Exception' -and @(Get-ChildItem -LiteralPath $lockedWin64 -Force).Count -eq 2) $run.Text
} finally {
    & icacls.exe $lockedWin64 /remove:d '*S-1-1-0' /Q | Out-Null
}
$run = Invoke-Setup @('--install', '--game', $lockedWin64)
Check 'once the folder can be written to, the same install works' ($run.Code -eq 0) $run.Text

Section "The wax:// registration (under the name $scheme, never the real one)"
$regWin64 = New-FakeGame (Join-Path $work 'reg one\Icarus')
$regOther = New-FakeGame (Join-Path $work 'reg two\Icarus')
New-Item -Path "$schemeKey\shell\open\command" -Force | Out-Null
$oldCommand = '"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Somewhere\Wax-Import.ps1" "%1"'
Set-ItemProperty -Path "$schemeKey\shell\open\command" -Name '(Default)' -Value $oldCommand
$run = Invoke-Setup @('--install', '--game', $regWin64) -Links
$regExe = Join-Path $regWin64 "$waxPath\Wax Setup.exe"
Check 'install registers the link to the copy of the program in the game, replacing a registration that ran a script' ($run.Code -eq 0 -and
    (Get-Link $scheme) -ceq "`"$regExe`" --link `"%1`"") (Get-Link $scheme)
Check 'the registration starts no script, hides no window and skips no rule' ((Get-Link $scheme) -notmatch 'powershell|Hidden|Bypass|ExecutionPolicy|\.ps1|cmd')
$key = Get-ItemProperty -Path $schemeKey
Check 'it is a link scheme as Windows wants one' ($key.'(default)' -eq 'URL:Wax mod link' -and $key.PSObject.Properties['URL Protocol'] -and $key.'URL Protocol' -eq '')
Check 'it says that the "Add to game" button now works' ($run.Text -match 'The "Add to game" button on the Wax site now works on this PC\.') $run.Text
$run = Invoke-Setup @('--status', '--game', $regWin64, '--scheme', $scheme)
Check 'the state names what links are registered to' ($run.Text.Contains("links=`"$regExe`" --link `"%1`"")) $run.Text
$run = Invoke-Setup @('--install', '--game', $regOther)
Check 'an install told to leave links alone leaves them alone' ($run.Code -eq 0 -and (Get-Link $scheme) -ceq "`"$regExe`" --link `"%1`"" -and $run.Text -notmatch 'Add to game')
$run = Invoke-Setup @('--uninstall', '--remove-mine', '--remove-ue4ss', '--game', $regOther) -Links
Check 'removing Wax from another game leaves a registration that points at this one' ($run.Code -eq 0 -and (Get-Link $scheme) -ceq "`"$regExe`" --link `"%1`"")
$run = Invoke-Setup @('--uninstall', '--game', $regWin64) -Links
Check 'removing Wax from this game takes the registration away' ($run.Code -eq 0 -and -not (Test-Path $schemeKey))

Section 'The copy of the program inside the game'
$copyWin64 = New-FakeGame (Join-Path $work 'copy\Icarus')
$null = Invoke-Setup @('--install', '--game', $copyWin64)
Add-PlayerFiles $copyWin64
Set-Content -LiteralPath (Join-Path $copyWin64 "$waxPath\VERSION") -Value $version
$copyExe = Join-Path $copyWin64 "$waxPath\Wax Setup.exe"
$copyState = Get-PlayerState $copyWin64
$run = Invoke-Setup @('--status') -Exe $copyExe
Check 'run with no folder given, it works on the game it sits in' ($run.Code -eq 0 -and $run.Text.Contains("game=$copyWin64") -and $run.Text -match '(?m)^state=same\r?$') $run.Text
$run = Invoke-Setup @('--install') -Exe $copyExe
Check 'it can repair the Wax it sits in, itself included' ($run.Code -eq 0 -and $run.Text -match 'was installed again' -and (Get-FileHash -LiteralPath $copyExe).Hash -eq $setupHash -and
    (Get-PlayerState $copyWin64) -eq $copyState -and -not (Test-Path -LiteralPath (Join-Path $copyWin64 'wax-setup-work'))) $run.Text
$run = Invoke-Setup @('--uninstall', '--remove-ue4ss') -Exe $copyExe
for ($i = 0; $i -lt 150 -and -not (Test-Path -LiteralPath (Join-Path $work 'result.txt')); $i++) { Start-Sleep -Milliseconds 100 }
$handed = if (Test-Path -LiteralPath (Join-Path $work 'result.txt')) { Get-Content -LiteralPath (Join-Path $work 'result.txt') -Raw } else { '' }
Check 'a running program cannot remove its own file, so it hands the removal to a copy in its data folder, which says how it went' (
    (Test-Path -LiteralPath (Join-Path $data 'run\Wax Setup.exe')) -and $handed -match 'Wax is removed\.' -and $handed -match 'UE4SS is removed\.') $handed
Check 'that way it can remove the Wax it sits in, itself included, and keeps the player''s files' ($run.Code -eq 0 -and -not (Test-Path -LiteralPath $copyExe) -and
    -not (Test-Path -LiteralPath (Join-Path $copyWin64 "$waxPath\Scripts")) -and -not (Test-Path -LiteralPath (Join-Path $copyWin64 'dwmapi.dll')) -and
    (Get-PlayerState $copyWin64) -eq $copyState) $run.Text

Section 'Mod links (the catalogue replaced by a local server)'
$modWin64 = New-FakeGame (Join-Path $work 'mods game\Icarus')
$null = Invoke-Setup @('--install', '--game', $modWin64)
$modWax = Join-Path $modWin64 $waxPath
$modsDir = Join-Path $modWax 'mods'
$zips = Join-Path $work 'mod zips'
New-Item -ItemType Directory -Force $zips | Out-Null
function New-ModZip([string]$Name, [hashtable]$Entries) {
    $file = Join-Path $zips "$Name.zip"
    $stream = [System.IO.File]::Open($file, 'Create')
    $archive = [System.IO.Compression.ZipArchive]::new($stream, 'Create')
    foreach ($entry in $Entries.GetEnumerator()) {
        $made = $archive.CreateEntry($entry.Key)
        if ($entry.Key.EndsWith('/')) { continue }
        $writer = [System.IO.StreamWriter]::new($made.Open())
        $writer.Write([string]$entry.Value)
        $writer.Dispose()
    }
    $archive.Dispose(); $stream.Dispose()
    $file
}
$good = New-ModZip 'good' @{ 'TestMod/init.lua' = 'print("one")'; 'TestMod/mod.lua' = 'return { name = "Test Mod", version = "1.0.0" }'; 'TestMod/art/note.txt' = 'a note'; 'TestMod/empty/' = '' }
$good2 = New-ModZip 'good2' @{ 'TestMod/init.lua' = 'print("two")'; 'TestMod/mod.lua' = 'return { name = "Test Mod", version = "1.1.0" }' }
$cases = [ordered]@{
    testmod  = @{ id = 'TestMod'; name = 'Test Mod'; version = '1.0.0'; zip = $good; checksum = 'good' }
    badsum   = @{ id = 'BadSum'; name = 'Bad Sum'; version = '1.0.0'; zip = (New-ModZip 'badsum' @{ 'BadSum/init.lua' = 'x = 1' }); checksum = 'bad' }
    nosum    = @{ id = 'NoSum'; name = 'No Sum'; version = '1.0.0'; zip = (New-ModZip 'nosum' @{ 'NoSum/init.lua' = 'x = 1' }); checksum = 'none' }
    outside  = @{ id = 'Outside'; name = 'Outside'; version = '1.0.0'; zip = (New-ModZip 'outside' @{ 'Outside/init.lua' = 'x = 1'; 'Other/init.lua' = 'x = 2' }); checksum = 'good' }
    climber  = @{ id = 'Climber'; name = 'Climber'; version = '1.0.0'; zip = (New-ModZip 'climber' @{ 'Climber/init.lua' = 'x = 1'; 'Climber/../../escaped.lua' = 'x = 2' }); checksum = 'good' }
    program  = @{ id = 'Program'; name = 'Program'; version = '1.0.0'; zip = (New-ModZip 'program' @{ 'Program/init.lua' = 'x = 1'; 'Program/run.exe' = 'MZ' }); checksum = 'good' }
    noinit   = @{ id = 'NoInit'; name = 'No Init'; version = '1.0.0'; zip = (New-ModZip 'noinit' @{ 'NoInit/mod.lua' = 'return {}' }); checksum = 'good' }
    notzip   = @{ id = 'NotZip'; name = 'Not Zip'; version = '1.0.0'; zip = $standSource; checksum = 'good' }
    renamed  = @{ id = 'SomethingElse'; name = 'Renamed'; version = '1.0.0'; zip = $good; checksum = 'good' }
    oddname  = @{ id = 'Odd Name!'; name = 'Odd'; version = '1.0.0'; zip = $good; checksum = 'good' }
    unborn   = @{ id = 'Unborn'; name = 'Unborn'; zip = $good; checksum = 'good' }
    broken   = @{ id = 'Broken'; name = 'Broken'; version = '1.0.0'; status = 500 }
    quoted   = @{ id = 'Quoted'; name = "Qu'ote`") os.exit() --"; version = "1.0'0"; zip = (New-ModZip 'quoted' @{ 'Quoted/init.lua' = 'x = 1' }); checksum = 'good' }
}
$casesFile = Join-Path $work 'cases.json'
$cases | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $casesFile
$portFile = Join-Path $work 'port.txt'
$node = (Get-Command node -CommandType Application | Select-Object -First 1).Source
$server = Start-Process -FilePath $node -ArgumentList "`"$(Join-Path $PSScriptRoot 'catalogue.mjs')`" `"$casesFile`" `"$portFile`"" -PassThru -WindowStyle Hidden
function Get-ModFolders { (Get-ChildItem -LiteralPath $modsDir -Force | ForEach-Object Name | Sort-Object) -join '|' }
function Invoke-Link([string]$Link, [string]$Exe = $setup, [string[]]$Before = @('--game', $modWin64, '--quiet')) {
    Invoke-Setup ($Before + @('--server', $script:base, '--link', $Link)) -Exe $Exe
}
try {
    for ($i = 0; $i -lt 50 -and -not (Test-Path -LiteralPath $portFile); $i++) { Start-Sleep -Milliseconds 100 }
    $script:base = "http://127.0.0.1:$((Get-Content -LiteralPath $portFile -Raw).Trim())"
    $foldersBefore = Get-ModFolders
    foreach ($bad in 'wax://install/', 'wax://install/9lives', 'wax://install/Test Mod', 'wax://install/Test-Mod', 'wax://remove/TestMod', 'wax://install/TestMod/extra',
            'wax://install/TestMod?server=http://example.com', 'wax://install/..', 'https://wax-icarus.duckdns.org/api/mods/TestMod', 'wax://install/TestMod" --server "http://example.com',
            "wax://install/$('a' * 65)", '') {
        $run = Invoke-Link $bad
        Check "a link of another shape is refused: '$($bad.Substring(0, [math]::Min(60, $bad.Length)))'" ($run.Code -eq 1 -and $run.Text.Trim() -eq 'This is not a link to a Wax mod.' -and (Get-ModFolders) -eq $foldersBefore) $run.Text
    }
    # As a browser starts it: the link comes first. The test's folders go in through the environment, where no link can reach.
    $resultFile = Join-Path $work 'result.txt'
    Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
    $env:WAX_SETUP_RESULT = $resultFile
    $env:WAX_SETUP_DATA = $data
    try {
        & $setup --link 'wax://install/TestMod' --server $script:base --game $modWin64 2>&1 | Out-Null
        $code = $LASTEXITCODE
    } finally { $env:WAX_SETUP_RESULT = ''; $env:WAX_SETUP_DATA = '' }
    Check 'with the link first, as a browser starts it, nothing after the link is read: more words there make it no link at all' ($code -eq 1 -and
        (Get-Content -LiteralPath $resultFile -Raw).Trim() -eq 'This is not a link to a Wax mod.' -and (Get-ModFolders) -eq $foldersBefore)

    $run = Invoke-Link 'wax://install/TestMod'
    Check 'a good link adds the mod and says so' ($run.Code -eq 0 -and $run.Text.Trim() -eq 'Test Mod 1.0.0 was added. It will be in the Wax menu the next time you start ICARUS.') $run.Text
    Check 'its files are in the mods folder, the empty folder too' ((Get-Content -LiteralPath (Join-Path $modsDir 'TestMod\init.lua') -Raw) -eq 'print("one")' -and
        (Get-Content -LiteralPath (Join-Path $modsDir 'TestMod\art\note.txt') -Raw) -eq 'a note' -and (Test-Path -LiteralPath (Join-Path $modsDir 'TestMod\empty') -PathType Container))
    Check 'it is marked as a mod from the catalogue at that version' ([System.IO.File]::ReadAllText((Join-Path $modsDir 'TestMod\wax.origin')) -ceq "id=TestMod`r`nversion=1.0.0`r`n")
    Check 'nothing else was added to the mods folder' ((Get-ModFolders) -eq 'RecipeBrowser|TestMod') (Get-ModFolders)

    $cases.testmod = @{ id = 'TestMod'; name = 'Test Mod'; version = '1.1.0'; zip = $good2; checksum = 'good'; fileVersion = '1.1.0+build.7' }
    $cases | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $casesFile
    Set-Content -LiteralPath (Join-Path $modsDir 'TestMod\mine.txt') -Value 'something the player put there'
    $run = Invoke-Link 'WAX://Install/testmod/'
    $kept = @(Get-ChildItem -LiteralPath $modsDir -Directory -Force -Filter '.removed-TestMod-*')
    Check 'the same link later, written in other letter case, updates the mod and says so' ($run.Code -eq 0 -and $run.Text.Trim() -eq 'Test Mod was updated to 1.1.0. It will be in the Wax menu the next time you start ICARUS.' -and
        (Get-Content -LiteralPath (Join-Path $modsDir 'TestMod\init.lua') -Raw) -eq 'print("two")') $run.Text
    Check 'the copy before is kept under another name, with what the player had put in it' ($kept.Count -eq 1 -and $kept[0].Name -match '^\.removed-TestMod-\d{8}-\d{6}$' -and
        (Get-Content -LiteralPath (Join-Path $kept[0].FullName 'init.lua') -Raw) -eq 'print("one")' -and (Test-Path -LiteralPath (Join-Path $kept[0].FullName 'mine.txt')))
    Check 'the version it is marked with is the one in the name of the downloaded file' ([System.IO.File]::ReadAllText((Join-Path $modsDir 'TestMod\wax.origin')) -ceq "id=TestMod`r`nversion=1.1.0+build.7`r`n")

    $foldersBefore = Get-ModFolders
    $refusals = [ordered]@{
        BadSum = 'does not match its checksum'; NoSum = 'does not match its checksum'; Outside = 'a file outside its own folder: Other/init\.lua'
        Climber = 'a path that is not allowed'; Program = 'a kind of file that is not allowed: Program/run\.exe'; NoInit = 'has no init\.lua'
        NotZip = 'could not be opened'; Renamed = 'a name that cannot be used'; OddName = 'a name that cannot be used'; Unborn = 'no version of this mod yet'
        Broken = 'answered with error 500'; Nobody = 'has no mod with that name'
    }
    foreach ($id in $refusals.Keys) {
        $run = Invoke-Link "wax://install/$id"
        Check "$id is refused with a plain sentence ($($refusals[$id] -replace '\\', '')), and the mods folder is as it was" ($run.Code -eq 1 -and $run.Text -match $refusals[$id] -and
            $run.Text -notmatch 'Exception|   at ' -and (Get-ModFolders) -eq $foldersBefore) $run.Text
    }
    Check 'nothing escaped the mods folder' (-not (Test-Path -LiteralPath (Join-Path $modWax 'escaped.lua')) -and -not (Test-Path -LiteralPath (Join-Path (Split-Path $modWax) 'escaped.lua')))
    Check 'every download was cleaned up' (-not (Test-Path -LiteralPath (Join-Path $data 'temp')) -or @(Get-ChildItem -LiteralPath (Join-Path $data 'temp') -Force).Count -eq 0)
    $run = Invoke-Setup @('--game', $modWin64, '--quiet', '--server', 'http://127.0.0.1:9', '--link', 'wax://install/TestMod')
    Check 'no connection: a plain sentence' ($run.Code -eq 1 -and $run.Text -match 'The mod catalogue could not be reached\. Check your internet connection') $run.Text
    $run = Invoke-Link 'wax://install/TestMod' -Before @('--game', (Join-Path $work 'reg two\Icarus'), '--quiet')
    Check 'a game without Wax: it says the mods folder is missing' ($run.Code -eq 1 -and $run.Text -match 'The mods folder is missing') $run.Text

    # The game stand-in runs from this folder and takes requests as Wax does.
    $modGameExe = Join-Path $modWin64 'Icarus-Win64-Shipping.exe'
    Copy-Item -LiteralPath $fakeExe -Destination $modGameExe -Force
    $standIn = Start-Process -FilePath $modGameExe -ArgumentList "`"$modWax`"" -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Milliseconds 800
        $run = Invoke-Link 'wax://install/Quoted'
        $taken = if (Test-Path -LiteralPath (Join-Path $modWax 'run\taken.txt')) { Get-Content -LiteralPath (Join-Path $modWax 'run\taken.txt') -Raw } else { '' }
        Check 'with the game running, the mod is handed to it and the result says it is in the game now' ($run.Code -eq 0 -and $run.Text.Trim() -eq 'Quote os.exit -- 1.00 was added. It is in your game now.') $run.Text
        Check 'the game was told to load the mod, switch it on and say so' ($taken -match "(?m)^--id:[0-9a-f]{12}$" -and
            $taken.Contains("Wax.mods.sync() Wax.mods.set_enabled('Quoted', true) Wax.mods.request_reload('Quoted')") -and
            $taken.Contains("Wax.ui.Notify('Quote os.exit -- 1.00 was added.', { title = 'Mods', kind = 'good', seconds = 8 })")) $taken
        $quotes = @($taken.ToCharArray() | Where-Object { $_ -eq "'" }).Count
        Check 'quotes in a name from the catalogue never reach the Lua that is sent' ($quotes -eq 10 -and $taken -notmatch '"') "$quotes quotes"
        Check 'the request folder is left clean' (@(Get-ChildItem -LiteralPath (Join-Path $modWax 'run\in') -Force | Where-Object Name -ne 'wake').Count -eq 0 -and
            @(Get-ChildItem -LiteralPath (Join-Path $modWax 'run\out') -Force).Count -eq 0)
        # The copy in the game is what a browser starts. It needs no folder given: it adds to the game it sits in.
        $run = Invoke-Link 'wax://install/TestMod' -Exe (Join-Path $modWax 'Wax Setup.exe') -Before @('--quiet')
        Check 'the copy inside the game adds to its own game and hands the mod to it' ($run.Code -eq 0 -and $run.Text -match 'Test Mod was updated to 1\.1\.0\. It is in your game now\.') $run.Text
        $picture = Join-Path $shots 'live-link-window.png'
        $run = Invoke-Link 'wax://install/TestMod' -Before @('--game', $modWin64, '--drive', $picture)
        Check 'the small window does the same, shown where nobody sees it, and its picture is saved' ($run.Code -eq 0 -and $run.Text -match 'Test Mod was updated to 1\.1\.0\. It is in your game now\.' -and
            (Test-Path -LiteralPath $picture) -and (Get-Item -LiteralPath $picture).Length -gt 20KB) $run.Text
    } finally {
        Stop-Process -Id $standIn.Id -Force -ErrorAction SilentlyContinue
        $standIn.WaitForExit(5000) | Out-Null
    }
    $run = Invoke-Setup @('--verify', '--game', $modWin64)
    Check 'after all that, Wax itself still verifies' ($run.Code -eq 0) $run.Text
} finally {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
}

Section 'The window (shown where nobody sees it, pressing its own buttons)'
$winWin64 = New-FakeGame (Join-Path $work 'window\Icarus')
$picture = Join-Path $shots 'live-installed.png'
$run = Invoke-Setup @('--game', $winWin64, '--drive', $picture)
$check = Invoke-Setup @('--verify', '--game', $winWin64)
Check 'pressing Install in the window installs Wax and ends on the "done" page' ($run.Code -eq 0 -and $check.Code -eq 0 -and (Test-Path -LiteralPath $picture) -and (Get-Item -LiteralPath $picture).Length -gt 40KB) "$($run.Code) $($check.Text)"
Add-PlayerFiles $winWin64
$winState = Get-PlayerState $winWin64
$picture = Join-Path $shots 'live-updated.png'
$run = Invoke-Setup @('--game', $winWin64, '--drive', $picture)
$check = Invoke-Setup @('--verify', '--game', $winWin64)
Check 'pressing Update in the window updates an older Wax and keeps the player''s files' ($run.Code -eq 0 -and $check.Code -eq 0 -and (Get-PlayerState $winWin64) -eq $winState -and (Test-Path -LiteralPath $picture)) "$($run.Code) $($check.Text)"
$picture = Join-Path $shots 'live-removed.png'
$run = Invoke-Setup @('--game', $winWin64, '--drive', $picture, '--drive-quiet')
Check 'pressing Uninstall, then Remove with the answers as they stand, removes Wax and keeps the player''s files' ($run.Code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $winWin64 "$waxPath\Scripts")) -and
    (Get-PlayerState $winWin64) -eq $winState -and (Test-Path -LiteralPath $picture)) "$($run.Code)"
Check 'as another mod is in ue4ss\Mods, the answer for UE4SS stood at "keep", and it is still there' (Test-Path -LiteralPath (Join-Path $winWin64 'ue4ss\UE4SS.dll'))
$picture = Join-Path $shots 'live-game-not-found.png'
$run = Invoke-Setup @('--steam', $emptySteam, '--drive', $picture)
Check 'with no game to be found, the window ends on the page that asks for the folder' ($run.Code -eq 1 -and (Test-Path -LiteralPath $picture)) "$($run.Code)"
$run = Invoke-Setup @('--shots', $shots)
$pictures = @(Get-ChildItem -LiteralPath $shots -Filter '*.png' | Where-Object { $_.Name -match '^\d\d-' })
Check "a picture of every state is drawn to build\setup-test\shots ($($pictures.Count) pictures)" ($run.Code -eq 0 -and $pictures.Count -ge 17 -and -not ($pictures | Where-Object Length -lt 20KB))

Section 'What the tests left alone'
Check 'the real wax:// registration is as it was' ((Get-Link 'wax') -ceq $realLinkBefore) (Get-Link 'wax')
Check "nothing is left of the test's own registration" (-not (Test-Path $schemeKey))
$realDataAfter = if (Test-Path -LiteralPath $realData) { (Get-ChildItem -LiteralPath $realData -Force | ForEach-Object { "$($_.Name) $($_.LastWriteTimeUtc.Ticks)" }) -join '|' } else { 'none' }
Check "the program's real data folder ($realData) is as it was: every run wrote to the test's own" ($realDataAfter -eq $realDataBefore)
Check 'no stand-in for the game is still running' (@(Get-Process -Name 'Icarus-Win64-Shipping' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($work, [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0)

Write-Host ''
if ($script:failures.Count) {
    Write-Host "$($script:failures.Count) failed, $($script:passed) passed" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
Write-Host "All $($script:passed) checks passed." -ForegroundColor Green
