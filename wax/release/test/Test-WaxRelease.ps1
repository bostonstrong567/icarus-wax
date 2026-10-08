#requires -Version 7
<#
.SYNOPSIS
  Tests build\Wax-<version>.zip against fake game folders under build\release-test.
.DESCRIPTION
  Extracts the zip and runs its installer with Windows PowerShell 5.1 (powershell.exe), which is what players have:
  install, install again over a copy that holds a player's own mods and settings, a different UE4SS already in
  place, a running game, links where folders are expected, the "Add to game" question, who may change Wax's folder,
  UE4SS's cheat and console mods, uninstall, and update. It also compares what was installed with the UE4SS zip and
  wax\runtime, and with the real game folder this workspace uses when there is one (read only).

  The installer that ships has no way to point it somewhere else, so the runs here use a copy with five lines
  changed: where "Update" looks (serve.mjs, a local stand-in for GitHub), the key (one that serve.mjs makes), the
  kind of link (wax-test-release, so this PC's own wax:// registration is never written), and the folder under
  %LOCALAPPDATA% (Wax-test-release, so the real log of the importer is never touched).
  Nothing here touches the real game, the real registration or the network. Never run two of these at once, and
  not beside Test-WaxImport.ps1: both start a process named like the game.
.EXAMPLE
  .\scripts\Build-WaxRelease.ps1 -Unsigned; .\wax\release\test\Test-WaxRelease.ps1 *> build\release-test.log
#>
[CmdletBinding()]
param()
. "$PSScriptRoot\..\..\..\scripts\_common.ps1"
. "$PSScriptRoot\..\..\..\scripts\_release.ps1"

$version = (Get-Content (Join-Path $Root 'wax\VERSION') -Raw).Trim()
$zip     = Join-Path $BuildDir "Wax-$version.zip"
$work    = Join-Path $BuildDir 'release-test'
# A folder name like the ones a second download and "Extract All" produce.
$package = Join-Path $work "Bob's Downloads\Wax-$version (1)"
$setup   = Join-Path $package 'Wax-Setup.ps1'
$shipped = Join-Path $work 'shipped\Wax-Setup.ps1'
$stand   = Join-Path $work 'stand-in'
$waxPath = 'ue4ss\Mods\Wax'
$scheme  = 'wax-test-release'
$schemeKey = "HKCU:\Software\Classes\$scheme"
$localName = 'Wax-test-release'
$localData = [System.Environment]::GetFolderPath('LocalApplicationData')
$localTest = Join-Path $localData $localName
$localReal = Join-Path $localData 'Wax'
$cheatMods = 'CheatManagerEnablerMod', 'ConsoleCommandsMod', 'ConsoleEnablerMod'
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

# Every run names its game folder. Without one the installer would look for the real game through Steam.
function Invoke-Setup {
    param([string[]]$Arguments, [string]$Answers, [string]$Script = $setup)
    if ($Arguments -notcontains '-GameDir' -and $Arguments -notcontains '-SteamRoot') { throw 'A test run of the installer has to say which game folder it is for.' }
    $all = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments
    if ($PSBoundParameters.ContainsKey('Answers')) { $lines = $Answers | & powershell.exe @all 2>&1 }
    else { $lines = $null | & powershell.exe @all 2>&1 }
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($lines) -join "`n") }
}

# The command Windows would run for a link, under the test's own kind of link unless another is named.
function Get-Link([string]$Name = $scheme) {
    try { [string](Get-ItemProperty -Path "HKCU:\Software\Classes\$Name\shell\open\command" -ErrorAction Stop).'(default)' } catch { '' }
}
function Set-Link([string]$Command) {
    New-Item -Path "$schemeKey\shell\open\command" -Force | Out-Null
    Set-ItemProperty -Path $schemeKey -Name 'URL Protocol' -Value ''
    Set-ItemProperty -Path "$schemeKey\shell\open\command" -Name '(Default)' -Value $Command
}
function Clear-Link { if (Test-Path -LiteralPath $schemeKey) { Remove-Item -LiteralPath $schemeKey -Recurse -Force } }
# The test's own folder under %LOCALAPPDATA%, with the files named, or gone when none is.
function Set-LocalFolder([string[]]$Files) {
    if ($localTest -notlike '*\Wax-test-release') { throw 'This is not the folder of the test.' }
    if (Test-Path -LiteralPath $localTest) { Remove-Item -LiteralPath $localTest -Recurse -Force }
    foreach ($file in $Files) {
        New-Item -ItemType Directory -Force $localTest | Out-Null
        Set-Content -LiteralPath (Join-Path $localTest $file) -Value '2026-10-07 09:00:00  RecipeBrowser  added 0.9.1'
    }
}
function Get-LinkCommand([string]$Win64) {
    '"{0}" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "{1}" "%1"' -f (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), (Join-Path $Win64 "$waxPath\Wax-Import.ps1")
}

function Set-Case([string]$Name) { [System.IO.File]::WriteAllText((Join-Path $stand 'case.txt'), $Name) }
function Get-Requests([string]$Case) {
    $log = Join-Path $stand 'requests.log'
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    @(Get-Content -LiteralPath $log | Where-Object { $_.StartsWith("$Case ") })
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

# The rules on a file or folder as text, its own or the ones it takes from the folder above.
function Format-Rules($Acl, [switch]$Inherited) {
    (@($Acl.GetAccessRules(-not $Inherited, [bool]$Inherited, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object {
        "$($_.IdentityReference.Value) $($_.AccessControlType) $($_.FileSystemRights) [$($_.InheritanceFlags)]" } | Sort-Object)) -join '; '
}
function Get-Rules([string]$Path, [switch]$Inherited) { Format-Rules (Get-Acl -LiteralPath $Path) -Inherited:$Inherited }
function Get-Sddl([string]$Path) { (Get-Acl -LiteralPath $Path).Sddl }

$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function Get-WantedRules([string]$Flags) {
    (@("S-1-5-18 Allow FullControl [$Flags]", "S-1-5-32-544 Allow FullControl [$Flags]", "S-1-5-32-545 Allow ReadAndExecute, Synchronize [$Flags]",
        "$me Allow FullControl [$Flags]") | Sort-Object) -join '; '
}

# Wax's folder is the installing user's: its own four rules and nothing from above, and everything inside takes exactly those.
function Test-Closed([string]$Label, [string]$Wax) {
    $acl = Get-Acl -LiteralPath $Wax
    Check "${Label}: Wax's folder takes no rules from the folder above, and has four of its own: full control for this user, Administrators and SYSTEM, reading for Users" (
        $acl.AreAccessRulesProtected -and (Get-Rules $Wax) -ceq (Get-WantedRules 'ContainerInherit, ObjectInherit') -and (Get-Rules $Wax -Inherited) -eq '') "$(Get-Rules $Wax) | $(Get-Rules $Wax -Inherited)"
    Check "${Label}: Wax's folder belongs to this user" ($acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -eq $me)
    $wanted = @{ $true = Get-WantedRules 'ContainerInherit, ObjectInherit'; $false = Get-WantedRules 'None' }
    $items = @(Get-ChildItem -LiteralPath $Wax -Recurse -Force -Attributes !ReparsePoint)
    $odd = @(foreach ($item in $items) {
        $inside = Get-Acl -LiteralPath $item.FullName
        if ($inside.AreAccessRulesProtected -or (Format-Rules $inside) -ne '' -or (Format-Rules $inside -Inherited) -cne $wanted[[bool]$item.PSIsContainer] -or
            $inside.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne $me) { $item.FullName.Substring($Wax.Length + 1) }
    })
    Check "${Label}: each of the $($items.Count) files and folders inside takes those four rules, has none of its own and belongs to this user" ($items.Count -gt 100 -and $odd.Count -eq 0) (($odd | Select-Object -First 5) -join '; ')
    $above = Get-Acl -LiteralPath (Split-Path $Wax)
    Check "${Label}: the folder above Wax is as it was: it still takes its rules from the game folder" (-not $above.AreAccessRulesProtected -and (Get-Rules (Split-Path $Wax)) -eq '')
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
    $diff = Compare-Tree $Expected (Get-Tree $Win64 -Skip 'Icarus-Win64-Shipping.exe', 'tbb12.dll', "$waxPath\run\links.txt")
    Check "${Label}: a first install is the zip's game folder exactly, UE4SS settings and Prospector's Codex included" ($diff.Count -eq 0) (($diff | Select-Object -First 5) -join '; ')
    Check "${Label}: Prospector's Codex is there" (Test-Path -LiteralPath (Join-Path $wax 'mods\RecipeBrowser\init.lua'))
    Check "${Label}: the installed copy is free to update itself: it has a VERSION file and no dev.txt" ((Test-Path -LiteralPath (Join-Path $wax 'VERSION')) -and
        -not (Test-Path -LiteralPath (Join-Path $wax 'dev.txt')))
    Check "${Label}: Prospector's Codex is marked as a mod from the catalogue, and the helper that updates it is installed" ((Test-Path -LiteralPath (Join-Path $wax 'mods\RecipeBrowser\wax.origin')) -and
        (Test-Path -LiteralPath (Join-Path $wax 'bin\waxnet.dll')))
    Check "${Label}: the version file says $version" ((Get-Content -LiteralPath (Join-Path $wax 'VERSION') -Raw).Trim() -eq $version)
    Check "${Label}: nothing was backed up on a clean game" (-not (Test-Path (Join-Path $Win64 'ue4ss-backup-*')))
    Check "${Label}: the install asked about the `"Add to game`" button, and Enter alone left Windows as it was" ($run.Text -match 'Windows has to hand links that start with' -and
        $run.Text -match 'is not set up' -and (Get-Link) -eq '' -and (Get-Content -LiteralPath (Join-Path $wax 'run\links.txt') -Raw).Trim() -eq 'no') $run.Text
    Check "${Label}: it says who can change Wax's folder now" ($run.Text -match "Wax's folder can now only be changed by your Windows account and by administrators") $run.Text
    Test-Closed "$Label install" $wax
    $installedList = Get-Content -LiteralPath (Join-Path $Win64 'ue4ss\Mods\mods.txt') -Raw
    Check "${Label}: UE4SS's cheat and console mods are switched off in the game" (-not ($cheatMods | Where-Object { $installedList -notmatch "(?m)^$_ : 0\r?$" }) -and $run.Text -notmatch 'cheat')

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
    Check "${Label}: the question about the button is not asked a second time, and the answer stands" ($run.Text -notmatch 'Windows has to hand links' -and (Get-Link) -eq '') $run.Text
    Test-Installed "$Label reinstall" $Win64 $Expected
    Test-Closed "$Label reinstall" $wax

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
    Check "${Label}: uninstall with the default answers exits 0, with the folder closed to other accounts as it is" ($run.Code -eq 0) $run.Text
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

$server = $null
$realLink = Get-Link 'wax'
$realLog = Test-Path -LiteralPath $localReal
$oldTemp, $oldTmp = $env:TEMP, $env:TMP
try {

Section 'Setting up build\release-test'
Clear-Link
Set-LocalFolder @()
Clear-Folder $work
New-Item -ItemType Directory -Force $work, (Join-Path $work 'temp'), (Join-Path $stand 'files'), (Split-Path $shipped) | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $package)
$top = @(Get-ChildItem -LiteralPath $package -Force | ForEach-Object Name | Sort-Object)
$wantedTop = @('game', 'Install Wax.cmd', 'licenses', 'README.txt', 'Uninstall Wax.cmd', 'Update Wax.cmd', 'Wax-Setup.ps1' | Sort-Object)
Check 'the zip has the expected top level and no program in it' (($top -join '|') -eq ($wantedTop -join '|')) ($top -join ', ')
$kinds = '.exe', '.com', '.scr', '.msi', '.dll', '.sys', '.ocx', '.cpl', '.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.vbs', '.vbe', '.js', '.jse', '.wsf', '.wsh', '.hta', '.lnk', '.jar', '.reg', '.pif'
$runnable = @(Get-ChildItem -LiteralPath $package -Recurse -Force -File | Where-Object { $_.Extension -in $kinds } | ForEach-Object { $_.FullName.Substring($package.Length + 1) } | Sort-Object)
$wantedRunnable = @('game\dwmapi.dll', 'game\ue4ss\UE4SS.dll', "game\$waxPath\bin\waxco.dll", "game\$waxPath\bin\waxnet.dll", "game\$waxPath\Wax-Import.ps1",
    'Install Wax.cmd', 'Uninstall Wax.cmd', 'Update Wax.cmd', 'Wax-Setup.ps1' | Sort-Object)
Check 'there is no .exe in the zip, and what Windows can run in it is these nine files and no other: four DLLs, two scripts, three .cmd files' (
    ($runnable -join '|') -ceq ($wantedRunnable -join '|') -and -not ($runnable | Where-Object { $_ -like '*.exe' })) ($runnable -join ', ')
if ($script:failures.Count) {
    Write-Host ''
    Write-Host 'This is not the zip that players get, so nothing in it was run and the rest of the test was left out.' -ForegroundColor Red
    Write-Host "$($script:failures.Count) failed, $($script:passed) passed" -ForegroundColor Red
    exit 1
}
$expected = Get-Tree (Join-Path $package 'game')
Check 'no links in the zip' (@(Get-ChildItem -LiteralPath $package -Recurse -Force -Attributes ReparsePoint).Count -eq 0)

Set-Case 'none'
$portFile = Join-Path $stand 'port.txt'
$node = (Get-Command node -CommandType Application | Select-Object -First 1).Source
$server = Start-Process -FilePath $node -ArgumentList "`"$(Join-Path $PSScriptRoot 'serve.mjs')`" `"$stand`" `"$portFile`" $version" -PassThru -WindowStyle Hidden
for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $portFile); $i++) { Start-Sleep -Milliseconds 100 }
$base = "http://127.0.0.1:$((Get-Content -LiteralPath $portFile -Raw).Trim())"
$testKey = (Get-Content -LiteralPath (Join-Path $stand 'key.txt') -Raw).Trim()

# The copy the tests run: the shipped installer with the five fixed lines changed, and nothing else.
Copy-Item -LiteralPath $setup -Destination $shipped
$shippedText = [System.IO.File]::ReadAllText($shipped)
$changes = [ordered]@{ ReleaseApi = "$base/api/latest"; DownloadRoot = "$base/dl/"; SigningKey = $testKey; LinkScheme = $scheme; LocalFolder = $localName }
$testText = $shippedText
foreach ($name in $changes.Keys) {
    $line = "(?m)^\`$$name = '[^'\r\n]*'(?=\r?$)"
    if ([regex]::Matches($testText, $line).Count -ne 1) { throw "The installer has no single line that sets `$$name." }
    $testText = [regex]::Replace($testText, $line, [System.Text.RegularExpressions.MatchEvaluator] { "`$$name = '$($changes[$name])'" })
}
[System.IO.File]::WriteAllText($setup, $testText, [System.Text.Encoding]::ASCII)
$oldLines = $shippedText -split "`r`n"
$newLines = $testText -split "`r`n"
$differing = @(0..($oldLines.Count - 1) | Where-Object { $oldLines[$_] -cne $newLines[$_] })
Check 'the copy the tests run is the shipped installer with five lines changed: where it updates from (two), the key, the kind of link, the folder under %LOCALAPPDATA%' ($oldLines.Count -eq $newLines.Count -and
    $differing.Count -eq 5 -and -not ($differing | Where-Object { $oldLines[$_] -notmatch '^\$(ReleaseApi|DownloadRoot|SigningKey|LinkScheme|LocalFolder) = ' })) "$($differing.Count) lines differ"

Section 'What the zip installs, against the sources'
$ue4ssSource = Join-Path $work 'ue4ss-source'
Expand-Archive -LiteralPath (Join-Path $ToolsDir 'ue4ss\UE4SS_v3.0.1-1152-ge3ba1016.zip') -DestinationPath $ue4ssSource
$diff = Compare-Tree (Get-Tree $ue4ssSource -Skip 'ue4ss\Mods\mods.txt', 'ue4ss\Mods\mods.json') (Get-Tree (Join-Path $package 'game') -Skip "$waxPath\*", 'ue4ss\Mods\mods.txt', 'ue4ss\Mods\mods.json')
Check 'UE4SS in the zip is the tested build, file for file, settings included (its two mod lists are looked at below)' ($diff.Count -eq 0) ($diff -join '; ')
$stockList = [System.IO.File]::ReadAllText((Join-Path $ue4ssSource 'ue4ss\Mods\mods.txt'))
$stockJson = [System.IO.File]::ReadAllText((Join-Path $ue4ssSource 'ue4ss\Mods\mods.json'))
$zipList = [System.IO.File]::ReadAllText((Join-Path $package 'game\ue4ss\Mods\mods.txt'))
$zipJson = [System.IO.File]::ReadAllText((Join-Path $package 'game\ue4ss\Mods\mods.json'))
$wantedList = $stockList
$wantedJson = $stockJson
foreach ($mod in $cheatMods) {
    $wantedList = $wantedList.Replace("$mod : 1", "$mod : 0")
    $wantedJson = [regex]::Replace($wantedJson, "(`"mod_name`": `"$mod`",\s*`"mod_enabled`": )true", '${1}false')
}
Check "UE4SS's own zip switches its cheat and console mods on, which is what the build changes" (-not ($cheatMods | Where-Object { $stockList -notmatch "(?m)^$_ : 1\r?$" }))
Check 'mods.txt in the zip is UE4SS''s own with CheatManagerEnablerMod, ConsoleCommandsMod and ConsoleEnablerMod switched off, and no other change' ($zipList -ceq $wantedList -and $zipList -cne $stockList -and
    -not ($cheatMods | Where-Object { $zipList -notmatch "(?m)^$_ : 0\r?$" }))
Check 'mods.json in the zip says the same' ($zipJson -ceq $wantedJson -and $zipJson -cne $stockJson -and
    -not (($zipJson | ConvertFrom-Json) | Where-Object { $_.mod_name -in $cheatMods -and $_.mod_enabled }) -and @(($zipJson | ConvertFrom-Json) | Where-Object mod_enabled).Count -eq 3)
Check 'the mods UE4SS needs for its own mod loading are still on' ($zipList -match '(?m)^BPModLoaderMod : 1\r?$' -and $zipList -match '(?m)^BPML_GenericFunctions : 1\r?$' -and $zipList -match '(?m)^Keybinds : 1\r?$')
$runtime = Join-Path $Root 'wax\runtime'
$waxSource = @{}
foreach ($item in Get-ChildItem -LiteralPath $runtime -Force | Where-Object { $_.Name -notin 'run', 'saved', 'mods', 'dev.txt' }) {
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
Check 'the zip has the two files that let Wax update itself: the swap at start and the downloader' (
    (Test-Path -LiteralPath (Join-Path $package "game\$waxPath\Scripts\selfswap.lua")) -and
    (Test-Path -LiteralPath (Join-Path $package "game\$waxPath\Scripts\wax\mods\selfupdate.lua")))
# A copy that downloads a new version but never puts it in, or puts one in and never says that it started, is a
# mistake in main.lua or boot.lua. The second kind would take every update back at the start after it.
$bootText = Get-Content -LiteralPath (Join-Path $package "game\$waxPath\Scripts\wax\boot.lua") -Raw
$swaps = (Get-Content -LiteralPath (Join-Path $package "game\$waxPath\Scripts\main.lua") -Raw).Contains('selfswap.lua')
$fetches = $bootText.Contains('mods.selfupdate')
$settles = $bootText.Contains('selfupdate.settle')
Check "start-up is wired for it in full or not at all (main.lua runs selfswap.lua: $swaps, boot.lua starts mods.selfupdate: $fetches, boot.lua calls its settle each frame: $settles)" (
    $swaps -eq $fetches -and $fetches -eq $settles)
Check 'dev.txt, the mark of a copy that never updates itself, is in the workspace and not in the zip' (
    (Test-Path -LiteralPath (Join-Path $runtime 'dev.txt')) -and
    @(Get-ChildItem -LiteralPath $package -Recurse -Force -File -Filter 'dev.txt').Count -eq 0)
Check 'the licences are there' ((Get-Content (Join-Path $package 'licenses\UE4SS-LICENSE.txt') -Raw) -match 'MIT License' -and (Get-Content (Join-Path $package 'licenses\Lucide-LICENSE.txt') -Raw) -match 'ISC License')

Section 'Against the real game folder this workspace uses (read only)'
$configFile = Join-Path $Root 'wax\wax.config.json'
$real = if (Test-Path -LiteralPath $configFile) { (Get-Content $configFile -Raw | ConvertFrom-Json).win64 }
if ($real -and (Test-Path -LiteralPath (Join-Path $real 'ue4ss\UE4SS.dll'))) {
    $realTree = @{ 'dwmapi.dll' = (Get-FileHash -LiteralPath (Join-Path $real 'dwmapi.dll')).Hash }
    # Left out: what UE4SS writes while it runs (its log, the object dump, the Lua type dump in shared\types), and the
    # two mod lists, which the owner's own game keeps as UE4SS's zip has them.
    (Get-Tree (Join-Path $real 'ue4ss') -Skip 'UE4SS.log', 'UE4SS_ObjectDump.txt', 'Mods\shared\types\*', 'Mods\Wax\*', 'Mods\mods.txt', 'Mods\mods.json').GetEnumerator() | ForEach-Object { $realTree["ue4ss\$($_.Key)"] = $_.Value }
    foreach ($item in Get-ChildItem -LiteralPath (Join-Path $real "$waxPath\") -Force | Where-Object { $_.Name -notin 'run', 'saved', 'mods', 'dev.txt' }) {
        if ($item.PSIsContainer) { (Get-Tree $item.FullName).GetEnumerator() | ForEach-Object { $realTree["$waxPath\$($item.Name)\$($_.Key)"] = $_.Value } }
        else { $realTree["$waxPath\$($item.Name)"] = (Get-FileHash -LiteralPath $item.FullName).Hash }
    }
    $diff = Compare-Tree $realTree (Get-Tree (Join-Path $package 'game') -Skip "$waxPath\mods\*", "$waxPath\VERSION", 'ue4ss\Mods\mods.txt', 'ue4ss\Mods\mods.json')
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
    $found = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $probe $shipped
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

Section 'The installer that ships: plain text, fixed addresses, one key'
$bytes = [System.IO.File]::ReadAllBytes($shipped)
Check 'Wax-Setup.ps1 is ASCII with Windows line endings' (-not ($bytes | Where-Object { $_ -gt 126 }) -and ([System.Text.Encoding]::ASCII.GetString($bytes) -notmatch "(?<!`r)`n"))
foreach ($name in 'Install Wax.cmd', 'Update Wax.cmd', 'Uninstall Wax.cmd', 'README.txt') {
    $text = [System.IO.File]::ReadAllText((Join-Path $package $name))
    Check "$name is ASCII with Windows line endings" ($text -notmatch '[^\x09\x0A\x0D\x20-\x7E]' -and $text -notmatch "(?<!`r)`n")
}
$psVersion = (& powershell.exe -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
Check "powershell.exe is Windows PowerShell 5.1 ($psVersion)" ($psVersion -like '5.1*')
$parseErrors = & powershell.exe -NoLogo -NoProfile -Command "`$e = `$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$shipped', [ref]`$null, [ref]`$e); `$e.Count"
Check 'Wax-Setup.ps1 parses under Windows PowerShell 5.1' ("$parseErrors".Trim() -eq '0') "$parseErrors"
$contractKey = '8b37ac88ea0d9e8a8d239b731f1ba1d12fe163c605f6fe3c3933253e36421a953c5d04fdcb94e3934223e41aeb511593788140a7865c00ab2f6ad67746900d62'
Check 'it looks for a newer Wax at the project''s own releases on GitHub, over https, and those lines are fixed text' (
    $shippedText.Contains("`r`n`$ReleaseApi = 'https://api.github.com/repos/bostonstrong567/icarus-wax/releases/latest'`r`n") -and
    $shippedText.Contains("`r`n`$DownloadRoot = 'https://github.com/bostonstrong567/icarus-wax/releases/download/'`r`n") -and
    $shippedText.Contains("`r`n`$LinkScheme = 'wax'`r`n") -and $shippedText.Contains("`r`n`$LocalFolder = 'Wax'`r`n"))
Check 'it holds the one public key that everything in Wax checks signatures with' ($shippedText.Contains("`r`n`$SigningKey = '$contractKey'`r`n") -and (Get-ReleaseKey) -ceq $contractKey)
$ast = [System.Management.Automation.Language.Parser]::ParseFile($shipped, [ref]$null, [ref]$null)
$parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath } | Sort-Object)
Check 'its parameters are the action, the game folder, the Steam folder and three answers. None says where to download from or which key to trust' (
    ($parameters -join ',') -ceq 'Action,GameDir,ModLinks,RemoveMyFiles,RemoveUE4SS,SteamRoot') ($parameters -join ',')
$assigned = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
    Where-Object { $_.Left.Extent.Text -match '^\$(script:|global:)?(ReleaseApi|DownloadRoot|SigningKey|LinkScheme|LocalFolder)$' })
Check 'each of those five is set once, by a line of fixed text, and never from the environment or a file' ($assigned.Count -eq 5 -and
    -not ($assigned | Where-Object { $_.Right.Extent.Text -notmatch "^'[^']*'$" }) -and $shippedText -notmatch '(?i)\$env:(?!SystemRoot\b)')
$fingerprint = Get-KeyFingerprint $contractKey
Check "README.txt gives the key's fingerprint ($fingerprint), names the registry key of the button, why it is there and two ways to remove it" (
    ($readme = [System.IO.File]::ReadAllText((Join-Path $package 'README.txt'))).Contains($fingerprint) -and $readme.Contains('HKEY_CURRENT_USER\Software\Classes\wax') -and
    $readme -match 'Uninstall Wax\.cmd' -and $readme.Contains('reg delete HKCU\Software\Classes\wax /f') -and $readme -match 'two ways to remove' -and $readme -notmatch '@[A-Z]+@')
Check 'README.txt lists what Wax leaves on a PC, the importer''s log among it, and says the three UE4SS mods are off and who can change Wax''s folder' (
    $readme.Contains('%LOCALAPPDATA%\Wax\import.log') -and $readme -match 'WHAT WAX LEAVES ON YOUR PC' -and
    $readme.Contains('CheatManagerEnablerMod, ConsoleCommandsMod, ConsoleEnablerMod') -and $readme -match 'WHO CAN CHANGE WAX''S FOLDER')
Check 'the three .cmd files only start Wax-Setup.ps1 beside them with their own action' (-not ('Install', 'Update', 'Uninstall' | Where-Object {
    [System.IO.File]::ReadAllText((Join-Path $package "$_ Wax.cmd")) -notmatch "-File `"%~dp0Wax-Setup\.ps1`" -Action $_ %\*\r\n" }))

Section 'The check the build and the publish script make of a signed list'
$listFile = Join-Path $work 'check\Wax-9.9.9.manifest'
New-Item -ItemType Directory -Force (Split-Path $listFile) | Out-Null
$fileA = Join-Path $work 'check\Wax-9.9.9.zip'
$fileB = Join-Path $work 'check\wax-icarus-9.9.9.vsix'
[System.IO.File]::WriteAllText($fileA, 'a zip for the check')
[System.IO.File]::WriteAllText($fileB, 'an extension for the check')
$throwaway = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
$point = $throwaway.ExportParameters($false).Q
$checkKey = [System.Convert]::ToHexString([byte[]]($point.X + $point.Y)).ToLower()
$listBody = "release 9.9.9`n" + (($fileA, $fileB | ForEach-Object { "$((Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLower()) $((Get-Item -LiteralPath $_).Length) $(Split-Path $_ -Leaf)`n" }) -join '')
[System.IO.File]::WriteAllText($listFile, $listBody)
$listSignature = [System.Convert]::ToBase64String($throwaway.SignData([System.Text.Encoding]::UTF8.GetBytes($listBody), [System.Security.Cryptography.HashAlgorithmName]::SHA256))
[System.IO.File]::WriteAllText("$listFile.sig", "$listSignature`n")
function Test-Assert([string[]]$Files, [string]$Key = $checkKey, [string]$Version = '9.9.9') {
    try { Assert-ReleaseSigned -Version $Version -Files $Files -Manifest $listFile -Signature "$listFile.sig" -KeyHex $Key; '' } catch { $_.Exception.Message }
}
Check 'a list signed with the key that names both files as they are is accepted' ((Test-Assert $fileA, $fileB) -eq '') (Test-Assert $fileA, $fileB)
Check 'the same list is refused against another key (the real one here)' ((Test-Assert $fileA, $fileB -Key $contractKey) -match 'does not carry the signature')
Check 'it is refused for another version' ((Test-Assert $fileA, $fileB -Version '9.9.8') -match 'is not the list of files of Wax 9\.9\.8')
Check 'it is refused when it names a file that is not released, and when a released file is not in it' ((Test-Assert $fileA) -match 'not part of this release' -and
    (Test-Assert $fileA, $fileB, (Join-Path $work 'shipped\Wax-Setup.ps1')) -match 'is not in the signed list')
[System.IO.File]::AppendAllText($fileA, '!')
Check 'it is refused once a file changed after signing' ((Test-Assert $fileA, $fileB) -match 'changed after the list was signed')
Remove-Item -LiteralPath "$listFile.sig"
Check 'it is refused without its signature file' ((Test-Assert $fileA, $fileB) -match 'not found')
$throwaway.Dispose()
$ownerText = Join-Path $Root 'wax\market\lib\signing.mjs'
if (Test-Path -LiteralPath $ownerText) {
    $given = Join-Path $work 'check\files.json'
    [System.IO.File]::WriteAllText($given, (ConvertTo-Json @(@{ name = 'wax-icarus-9.9.9.vsix'; size = 5; sha256 = 'b' * 64 }, @{ name = 'Wax-9.9.9.zip'; size = 123; sha256 = 'a' * 64 })))
    $theirs = (& $node --input-type=module -e "const m = await import(process.argv[1]); process.stdout.write(m.releaseText('9.9.9', JSON.parse((await import('node:fs')).readFileSync(process.argv[2], 'utf8'))));" ([uri]$ownerText).AbsoluteUri $given) -join "`n"
    Check 'the owner''s tool writes a list in the form the installer and these checks read' ("$theirs`n" -ceq "release 9.9.9`n$('a' * 64) 123 Wax-9.9.9.zip`n$('b' * 64) 5 wax-icarus-9.9.9.vsix`n") $theirs
} else {
    Write-Host '  skipped: the owner''s signing tool is not in this copy of the source'
}

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
$null = Invoke-Setup @('-Action', 'Install', '-GameDir', $oldWin64, '-ModLinks', 'Yes')
Set-LocalFolder 'import.log'
if (Test-Path -LiteralPath $fakeExe) {
    $stateBefore = (Get-Tree $oldWin64 -Skip 'Icarus-Win64-Shipping.exe').Count
    $standIn = Start-Process -FilePath $fakeExe -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Milliseconds 800
        Set-Case 'new'
        foreach ($action in 'Install', 'Update', 'Uninstall') {
            $run = Invoke-Setup @('-Action', $action, '-GameDir', $oldWin64, '-RemoveUE4SS', 'Yes', '-RemoveMyFiles', 'Yes')
            Check "$action refuses while the game in that folder is running" ($run.Code -eq 1 -and $run.Text -match 'ICARUS is running\. Close the game' -and (Get-Tree $oldWin64 -Skip 'Icarus-Win64-Shipping.exe').Count -eq $stateBefore) $run.Text
        }
        Check 'the refused uninstall left the "Add to game" registration and the importer''s log where they were' ((Get-Link) -ceq (Get-LinkCommand $oldWin64) -and
            (Test-Path -LiteralPath (Join-Path $localTest 'import.log'))) (Get-Link)
        Check 'the refused update asked the stand-in for the newest release and downloaded nothing' ((@(Get-Requests 'new') -join '; ') -ceq 'new GET /api/latest') ((Get-Requests 'new') -join '; ')
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
Clear-Link
Set-LocalFolder @()

Section 'Links where folders are expected'
$linkWin64 = New-FakeGame (Join-Path $work 'linked\Icarus')
$elsewhere = Join-Path $work 'elsewhere\runtime'
New-Item -ItemType Directory -Force (Join-Path $elsewhere 'Scripts'), (Join-Path $elsewhere 'mods\Dev'), (Join-Path $linkWin64 'ue4ss\Mods') | Out-Null
Set-Content -LiteralPath (Join-Path $elsewhere 'Scripts\main.lua') -Value '-- a developer copy'
Set-Content -LiteralPath (Join-Path $elsewhere 'Wax-Import.ps1') -Value '# a developer copy'
Set-Content -LiteralPath (Join-Path $elsewhere 'mods\Dev\init.lua') -Value '-- a developer mod'
New-Item -ItemType Junction -Path (Join-Path $linkWin64 $waxPath) -Target $elsewhere | Out-Null
$elsewhereBefore = (Get-Tree (Join-Path $work 'elsewhere')).GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Sort-Object | Out-String
$rulesBefore = (Get-ChildItem -LiteralPath (Join-Path $work 'elsewhere') -Recurse -Force | ForEach-Object { "$($_.FullName)=$(Get-Sddl $_.FullName)" }) -join "`n"
$run = Invoke-Setup @('-Action', 'Install', '-GameDir', $linkWin64)
Check 'install refuses when Wax is a link' ($run.Code -eq 1 -and $run.Text -match 'link to another folder') $run.Text
$run = Invoke-Setup @('-Action', 'Update', '-GameDir', $linkWin64)
Check 'update refuses when Wax is a link' ($run.Code -eq 1 -and $run.Text -match 'link to another folder') $run.Text
# The registration of a developer's copy names the real folder, which is still there after the link is gone.
Set-Link ('"powershell.exe" -File "{0}" "%1"' -f (Join-Path $elsewhere 'Wax-Import.ps1'))
$developerLink = Get-Link
$run = Invoke-Setup @('-Action', 'Uninstall', '-GameDir', $linkWin64, '-RemoveMyFiles', 'Yes', '-RemoveUE4SS', 'Yes')
Check 'uninstall removes the link only' ($run.Code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $linkWin64 $waxPath)) -and $run.Text -match 'The link is removed') $run.Text
Check 'a registration that names the folder behind the link, which is still there, is left alone' ((Get-Link) -ceq $developerLink -and $developerLink) (Get-Link)
New-Item -ItemType Directory -Force (Join-Path $linkWin64 'ue4ss\Mods') | Out-Null
New-Item -ItemType Junction -Path (Join-Path $linkWin64 $waxPath) -Target $elsewhere | Out-Null
Set-Link (Get-LinkCommand $linkWin64)
$run = Invoke-Setup @('-Action', 'Uninstall', '-GameDir', $linkWin64, '-RemoveMyFiles', 'Yes', '-RemoveUE4SS', 'Yes')
Check 'uninstall of a Wax that was a link takes away a registration that went through the link' ($run.Code -eq 0 -and (Get-Link) -eq '' -and $run.Text -match 'The link is removed' -and
    $run.Text -match 'The registry entry for them is removed') "$(Get-Link) $($run.Text)"
$run = Invoke-Setup @('-Action', 'Install', '-GameDir', $linkWin64)
Remove-Item -LiteralPath (Join-Path $linkWin64 "$waxPath\mods") -Recurse -Force
New-Item -ItemType Junction -Path (Join-Path $linkWin64 "$waxPath\mods") -Target (Join-Path $elsewhere 'mods') | Out-Null
$run2 = Invoke-Setup @('-Action', 'Install', '-GameDir', $linkWin64)
Check 'with Wax\mods as a link, Wax''s folder is still closed to other accounts' ($run2.Text -match "Wax's folder can now only be changed by your Windows account" -and
    (Get-Acl -LiteralPath (Join-Path $linkWin64 $waxPath)).AreAccessRulesProtected) $run2.Text
$run3 = Invoke-Setup @('-Action', 'Uninstall', '-GameDir', $linkWin64, '-RemoveMyFiles', 'Yes', '-RemoveUE4SS', 'Yes')
Check 'install and full uninstall work with Wax\mods as a link' ($run.Code -eq 0 -and $run2.Code -eq 0 -and $run3.Code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $linkWin64 'ue4ss'))) "$($run2.Text) $($run3.Text)"
$elsewhereAfter = (Get-Tree (Join-Path $work 'elsewhere')).GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Sort-Object | Out-String
Check 'nothing behind either link was changed or deleted' ($elsewhereAfter -eq $elsewhereBefore -and $elsewhereBefore -match 'Dev\\init\.lua')
$rulesAfter = (Get-ChildItem -LiteralPath (Join-Path $work 'elsewhere') -Recurse -Force | ForEach-Object { "$($_.FullName)=$(Get-Sddl $_.FullName)" }) -join "`n"
Check 'and who may change the files behind the links is as it was' ($rulesAfter -ceq $rulesBefore)
Clear-Link

Section 'The .cmd files'
$cmdWin64 = New-FakeGame (Join-Path $work 'cmd test\Icarus')
$out = $null | & (Join-Path $package 'Install Wax.cmd') -GameDir (Join-Path $work 'cmd test\Icarus') 2>&1
Check '"Install Wax.cmd" installs and returns 0' ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $cmdWin64 "$waxPath\Scripts\main.lua")) -and ($out -join "`n") -match 'is installed') ($out -join "`n")
$out = $null | & (Join-Path $package 'Install Wax.cmd') -GameDir (Join-Path $work 'cmd test\Icarus') -ModLinks Yes 2>&1
Check '"Install Wax.cmd" -ModLinks Yes switches the button on later, as README.txt says' ($LASTEXITCODE -eq 0 -and (Get-Link) -ceq (Get-LinkCommand $cmdWin64)) ($out -join "`n")
Set-Case 'limit'
$out = $null | & (Join-Path $package 'Update Wax.cmd') -GameDir (Join-Path $work 'cmd test\Icarus') 2>&1
Check '"Update Wax.cmd" runs the update and returns its result' ($LASTEXITCODE -eq 1 -and ($out -join "`n") -match 'GitHub answered with error 403') ($out -join "`n")
Set-Case 'param'
$out = $null | & (Join-Path $package 'Update Wax.cmd') -GameDir (Join-Path $work 'cmd test\Icarus') -ReleaseApi "$base/api/latest" 2>&1
Check 'an address handed to "Update Wax.cmd" is refused: there is no parameter for one, and nothing was asked of any server' ($LASTEXITCODE -ne 0 -and
    ($out -join "`n") -match 'ReleaseApi' -and @(Get-Requests 'param').Count -eq 0) ($out -join "`n")
$out = $null | & (Join-Path $package 'Uninstall Wax.cmd') -GameDir (Join-Path $work 'cmd test\Icarus') -RemoveUE4SS Yes -RemoveMyFiles Yes 2>&1
Check '"Uninstall Wax.cmd" uninstalls, takes the registration with it and returns 0' ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $cmdWin64 'ue4ss')) -and (Get-Link) -eq '') ($out -join "`n")
$alone = Join-Path $work 'run from inside the zip'
New-Item -ItemType Directory -Force $alone | Out-Null
Copy-Item -LiteralPath (Join-Path $package 'Install Wax.cmd') -Destination $alone
$out = $null | & (Join-Path $alone 'Install Wax.cmd') 2>&1
Check 'a .cmd run without the rest of the zip says to extract it first' ($LASTEXITCODE -eq 1 -and ($out -join "`n") -match 'Extract the whole zip first') ($out -join "`n")

Section 'The "Add to game" button (under a kind of link made for this test)'
$askWin64 = New-FakeGame (Join-Path $work 'button\Icarus')
$askArgs = @('-GameDir', $askWin64)
$askWax = Join-Path $askWin64 $waxPath
$note = Join-Path $askWax 'run\links.txt'
# The mark Windows puts on a file that came out of a downloaded zip. Copying the file carries it along.
Set-Content -LiteralPath (Join-Path $package "game\$waxPath\Wax-Import.ps1") -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
$run = Invoke-Setup (@('-Action', 'Install') + $askArgs) -Answers "y`n"
Check 'the question says what a yes changes: the registry key, that a link can come from any page, and that Wax asks before it downloads' ($run.Text.Contains("HKEY_CURRENT_USER\Software\Classes\$scheme") -and
    $run.Text -match 'can come from any web page' -and $run.Text -match 'asks\s+before it downloads anything' -and $run.Text -match 'stays switched off until you switch it on' -and
    $run.Text -match 'Uninstalling Wax removes it') $run.Text
Check 'typing y registers the link for this user' ($run.Code -eq 0 -and (Get-Link) -ceq (Get-LinkCommand $askWin64) -and $run.Text -match 'now opens Wax on this PC' -and
    (Get-Content -LiteralPath $note -Raw).Trim() -eq 'yes') "$(Get-Link) $($run.Text)"
$command = Get-Link
Check 'what is registered is Windows PowerShell in a window that shows, with one script and the link, and nothing that skips the rules for scripts' ($command -notmatch '(?i)hidden|bypass|unrestricted|-command|-enc' -and
    $command.StartsWith("`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" ") -and $command.EndsWith(" -File `"$askWax\Wax-Import.ps1`" `"%1`"")) $command
Check 'the registration is in this user''s own part of the registry, marked as a kind of link' ((Get-ItemProperty -LiteralPath $schemeKey).PSObject.Properties['URL Protocol'] -and
    -not (Test-Path -LiteralPath "HKLM:\Software\Classes\$scheme"))
Check 'the script the link runs is no longer marked as downloaded' (-not (Get-Item -LiteralPath (Join-Path $askWax 'Wax-Import.ps1') -Stream Zone.Identifier -ErrorAction SilentlyContinue))
$run = Invoke-Setup (@('-Action', 'Install') + $askArgs)
Check 'installing again asks nothing and leaves the registration as it is' ($run.Code -eq 0 -and $run.Text -notmatch 'Windows has to hand links' -and (Get-Link) -ceq $command) $run.Text
Clear-Link
$run = Invoke-Setup (@('-Action', 'Install') + $askArgs)
Check 'a registration the player removed by hand stays removed' ($run.Code -eq 0 -and $run.Text -notmatch 'Windows has to hand links' -and (Get-Link) -eq '') $run.Text
$run = Invoke-Setup (@('-Action', 'Install', '-ModLinks', 'Yes') + $askArgs)
Check '-ModLinks Yes registers without a question' ($run.Code -eq 0 -and $run.Text -notmatch 'Windows has to hand links' -and (Get-Link) -ceq $command) $run.Text
Set-Link $command.Replace($askWin64, (Join-Path $work 'button\where the game was before\Win64'))
$run = Invoke-Setup (@('-Action', 'Install') + $askArgs)
Check 'after a yes, a registration that still names the place the game was moved from is written for the place it is in now' ($run.Code -eq 0 -and
    $run.Text -notmatch 'Windows has to hand links' -and (Get-Link) -ceq $command) (Get-Link)
$run = Invoke-Setup (@('-Action', 'Install', '-ModLinks', 'No') + $askArgs)
Check '-ModLinks No takes the registration away and keeps Wax' ($run.Code -eq 0 -and (Get-Link) -eq '' -and (Test-Path -LiteralPath (Join-Path $askWax 'Scripts\main.lua')) -and
    (Get-Content -LiteralPath $note -Raw).Trim() -eq 'no') $run.Text
# What Wax 0.2.0 and older left behind: a registration nobody was asked about, some of them hidden and with the script rules skipped.
$hidden = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" "%1"' -f (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), (Join-Path $askWax 'Wax-Import.ps1')
Set-Link $hidden
Remove-Item -LiteralPath $note
$run = Invoke-Setup (@('-Action', 'Install') + $askArgs)
Check 'over a Wax that registered the link without asking, the question is put, and Enter alone takes the registration away' ($run.Code -eq 0 -and $run.Text -match 'Windows has to hand links' -and
    (Get-Link) -eq '' -and $run.Text -match 'The registry entry for them is removed') "$(Get-Link) $($run.Text)"
Set-Link $hidden
Remove-Item -LiteralPath $note
$run = Invoke-Setup (@('-Action', 'Install') + $askArgs) -Answers "yes`n"
Check 'and a yes writes it again in today''s form' ($run.Code -eq 0 -and (Get-Link) -ceq $command) (Get-Link)
$otherCopy = Join-Path $work 'button\another copy\Wax-Import.ps1'
New-Item -ItemType Directory -Force (Split-Path $otherCopy) | Out-Null
Set-Content -LiteralPath $otherCopy -Value '# another copy of Wax'
$elsewhereCommand = '"powershell.exe" -File "{0}" "%1"' -f $otherCopy
Set-Link $elsewhereCommand
$run = Invoke-Setup (@('-Action', 'Install', '-ModLinks', 'No') + $askArgs)
Check 'a registration that points at another copy of Wax is left alone by a no, and the installer says so' ($run.Code -eq 0 -and (Get-Link) -ceq $elsewhereCommand -and $run.Text -match 'opens another copy of Wax') $run.Text
$run = Invoke-Setup (@('-Action', 'Uninstall', '-RemoveUE4SS', 'No') + $askArgs)
Check 'and by an uninstall of this copy' ($run.Code -eq 0 -and (Get-Link) -ceq $elsewhereCommand) $run.Text

# Uninstall in each of its three states: Wax is a folder, Wax is already gone, Wax is a link (that one is with the other link tests above).
$null = Invoke-Setup (@('-Action', 'Install', '-ModLinks', 'Yes') + $askArgs)
$run = Invoke-Setup (@('-Action', 'Uninstall', '-RemoveMyFiles', 'No', '-RemoveUE4SS', 'No') + $askArgs)
Check 'uninstall takes the registration away with Wax, also when the player''s mods and UE4SS stay' ($run.Code -eq 0 -and (Get-Link) -eq '' -and $run.Text -match 'The registry entry for them is removed' -and
    (Test-Path -LiteralPath (Join-Path $askWax 'mods\RecipeBrowser\init.lua'))) "$(Get-Link) $($run.Text)"
$null = Invoke-Setup (@('-Action', 'Install', '-ModLinks', 'Yes') + $askArgs)
Remove-Item -LiteralPath $askWax -Recurse -Force
$run = Invoke-Setup (@('-Action', 'Uninstall', '-RemoveUE4SS', 'No') + $askArgs)
Check 'after Wax''s folder was deleted by hand, uninstall still takes the registration away (UE4SS still there)' ($run.Code -eq 0 -and (Get-Link) -eq '' -and $run.Text -match 'Wax is not in this game') "$(Get-Link) $($run.Text)"
Set-Link $command
$null = Invoke-Setup (@('-Action', 'Uninstall', '-RemoveUE4SS', 'Yes') + $askArgs)
Set-Link $command
$run = Invoke-Setup (@('-Action', 'Uninstall') + $askArgs)
Check 'and when nothing of Wax or UE4SS is left in the game at all' ($run.Code -eq 0 -and (Get-Link) -eq '' -and $run.Text -match 'Wax is not installed in this game') "$(Get-Link) $($run.Text)"
Set-Link $elsewhereCommand
Remove-Item -LiteralPath $otherCopy
$run = Invoke-Setup (@('-Action', 'Uninstall') + $askArgs)
Check 'a registration that points at a file that no longer exists is taken away by any uninstall' ($run.Code -eq 0 -and (Get-Link) -eq '') "$(Get-Link) $($run.Text)"
Check 'this PC''s own wax:// registration was not touched by any of that' ((Get-Link 'wax') -ceq $realLink)

Section 'The log of the importer under %LOCALAPPDATA% (in a folder made for this test)'
$logWin64 = New-FakeGame (Join-Path $work 'log\Icarus')
$logArgs = @('-GameDir', $logWin64)
$everything = @('-Action', 'Uninstall', '-RemoveMyFiles', 'Yes', '-RemoveUE4SS', 'Yes') + $logArgs
Set-LocalFolder 'import.log'
$run = Invoke-Setup (@('-Action', 'Install') + $logArgs)
Check 'an install leaves the log alone' ($run.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $localTest 'import.log')) -and $run.Text -notmatch 'The log of mods')
$run = Invoke-Setup $everything
Check 'uninstall removes the log and its folder when the log is all the folder holds, and says so in its last lines' ($run.Code -eq 0 -and -not (Test-Path -LiteralPath $localTest) -and
    $run.Text.TrimEnd() -match "The log of mods added through links is removed too:\s+$([regex]::Escape($localTest))$") $run.Text
$null = Invoke-Setup (@('-Action', 'Install') + $logArgs)
Set-LocalFolder 'import.log', 'notes of my own.txt'
$run = Invoke-Setup $everything
Check 'it leaves the folder as it is when something else is in it, and says so' ($run.Code -eq 0 -and @(Get-ChildItem -LiteralPath $localTest -Force).Count -eq 2 -and
    $run.Text -match 'was left where it is, because its folder holds other files too') $run.Text
Set-LocalFolder @()
$run = Invoke-Setup $everything
Check 'with no such folder it says nothing about a log' ($run.Code -eq 0 -and $run.Text -match 'Wax is not installed in this game' -and $run.Text -notmatch 'The log of mods') $run.Text
Set-LocalFolder 'import.log'
$run = Invoke-Setup $everything
Check 'the log goes as well when Wax was already gone from the game' ($run.Code -eq 0 -and -not (Test-Path -LiteralPath $localTest)) $run.Text

Section 'Who can change Wax''s folder'
$aclWin64 = New-FakeGame (Join-Path $work 'accounts\Icarus')
$aclWax = Join-Path $aclWin64 $waxPath
$null = Invoke-Setup @('-Action', 'Install', '-GameDir', $aclWin64)
# What another account could have left behind: a mod and a settings file with rules of their own that let everyone change them.
$everyone = [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0')
$planted = (Join-Path $aclWax 'mods\Planted\init.lua'), (Join-Path $aclWax 'saved\planted.lua')
New-Item -ItemType Directory -Force (Join-Path $aclWax 'mods\Planted') | Out-Null
foreach ($file in $planted) {
    Set-Content -LiteralPath $file -Value 'return {}'
    $open = [System.Security.AccessControl.FileSecurity]::new()
    $open.SetAccessRuleProtection($true, $false)
    $open.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($everyone, 'FullControl', 'Allow'))
    $open.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.SecurityIdentifier]::new($me), 'FullControl', 'Allow'))
    [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.FileInfo]::new($file), $open)
}
$openFolder = [System.Security.AccessControl.DirectorySecurity]::new()
$openFolder.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($everyone, 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
[System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new((Join-Path $aclWax 'mods\Planted')), $openFolder)
Check 'before: the planted files let everyone change them' ((Get-Rules $planted[0]) -match 'S-1-1-0 Allow FullControl' -and (Get-Rules (Join-Path $aclWax 'mods\Planted')) -match 'S-1-1-0 Allow Modify')
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$run = Invoke-Setup @('-Action', 'Install', '-GameDir', $aclWin64)
Check "installing again takes those rules off, so the folder's own apply (the whole install took $([math]::Round($watch.Elapsed.TotalSeconds, 1)) s)" ($run.Code -eq 0 -and
    -not ($planted | Where-Object { (Get-Rules $_) -ne '' }) -and (Get-Rules (Join-Path $aclWax 'mods\Planted')) -eq '') "$(Get-Rules $planted[0]) | $($run.Text)"
Test-Closed 'after that' $aclWax
Check 'the planted files are still there: nothing of the player''s is deleted for this' (-not ($planted | Where-Object { -not (Test-Path -LiteralPath $_) }))
$writable = Join-Path $aclWax 'run\session.log'
Set-Content -LiteralPath $writable -Value 'the game can still write here as this user'
Check 'this user can still write in Wax''s folder, as the game does' ((Get-Content -LiteralPath $writable -Raw) -match 'can still write')
$run = Invoke-Setup @('-Action', 'Uninstall', '-GameDir', $aclWin64, '-RemoveMyFiles', 'Yes', '-RemoveUE4SS', 'Yes')
Check 'uninstall works on the closed folder' ($run.Code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $aclWin64 'ue4ss'))) $run.Text

Section 'UE4SS''s cheat and console mods on a game that had an older Wax'
$modsWin64 = New-FakeGame (Join-Path $work 'older wax\Icarus')
$modsArgs = @('-Action', 'Install', '-GameDir', $modsWin64)
$null = Invoke-Setup $modsArgs
$gameList = Join-Path $modsWin64 'ue4ss\Mods\mods.txt'
$gameJson = Join-Path $modsWin64 'ue4ss\Mods\mods.json'
# Wax 0.2.0 installed UE4SS's two mod lists as they are in UE4SS's zip, with the three mods on.
[System.IO.File]::WriteAllText($gameList, $stockList)
[System.IO.File]::WriteAllText($gameJson, $stockJson)
Set-Content -LiteralPath (Join-Path $modsWin64 "$waxPath\VERSION") -Value '0.2.0'
$run = Invoke-Setup $modsArgs
Check 'over Wax 0.2.0 with the mod lists never touched: the three are switched off, and the installer says so and how to switch one back on' ($run.Code -eq 0 -and
    [System.IO.File]::ReadAllText($gameList) -ceq $zipList -and [System.IO.File]::ReadAllText($gameJson) -ceq $zipJson -and
    $run.Text -match "cheat and console mods are now switched off: CheatManagerEnablerMod, ConsoleCommandsMod, ConsoleEnablerMod\." -and
    $run.Text -match 'change its 0 to 1' -and $run.Text.Contains($gameList)) $run.Text
Check 'nothing was backed up for that, and it is not called the player''s own setting' (-not (Test-Path (Join-Path $modsWin64 'ue4ss-backup-*')) -and $run.Text -notmatch 'Your own UE4SS settings were kept')
$edited = $stockList + "MyOtherMod : 1`r`n"
[System.IO.File]::WriteAllText($gameList, $edited)
$run = Invoke-Setup $modsArgs
Check 'a mods.txt the player changed is kept as it is, and the installer names the three that are on in it and says how to switch them off' ($run.Code -eq 0 -and
    [System.IO.File]::ReadAllText($gameList) -ceq $edited -and $run.Text -match 'Your own UE4SS settings were kept: mods\.txt' -and
    $run.Text -match 'these mods of UE4SS are switched on: CheatManagerEnablerMod, ConsoleCommandsMod, ConsoleEnablerMod\.' -and
    $run.Text -match 'Your file was not changed' -and $run.Text -match 'change its 1 to 0') $run.Text
$oneOn = $zipList.Replace('ConsoleEnablerMod : 0', 'ConsoleEnablerMod : 1')
[System.IO.File]::WriteAllText($gameList, $oneOn)
$run = Invoke-Setup $modsArgs
Check 'a player who switched one of them on keeps it on, and only that one is named' ($run.Code -eq 0 -and [System.IO.File]::ReadAllText($gameList) -ceq $oneOn -and
    $run.Text -match 'these mods of UE4SS are switched on: ConsoleEnablerMod\.') $run.Text
$oldStyle = Join-Path $work 'old-updater\Wax-update-0a1b2c3d\Wax'
New-Item -ItemType Directory -Force (Split-Path $oldStyle) | Out-Null
Copy-Item -LiteralPath $package -Destination $oldStyle -Recurse
$run = Invoke-Setup $modsArgs -Script (Join-Path $oldStyle 'Wax-Setup.ps1')
Check 'started by the "Update Wax.cmd" of an older Wax, the install says that file checks nothing and to download this version once' ($run.Code -eq 0 -and
    $run.Text -match 'started by an "Update Wax\.cmd" from an older Wax' -and $run.Text -match 'without\s+checking who made it' -and $run.Text.Contains('https://wax-icarus.duckdns.org/docs/install/')) $run.Text
$run = Invoke-Setup $modsArgs
Check 'an install started any other way does not say that' ($run.Code -eq 0 -and $run.Text -notmatch 'This update was started by|without\s+checking who made it') $run.Text

Section 'Update (GitHub replaced by a local stand-in, the key by one made for this test)'
$updWin64 = New-FakeGame (Join-Path $work 'update\Icarus')
$updArgs = @('-Action', 'Update', '-GameDir', $updWin64)
$updVersion = Join-Path $updWin64 "$waxPath\VERSION"
Set-Case 'new'
$run = Invoke-Setup $updArgs
Check 'update on a game without Wax says to install first' ($run.Code -eq 1 -and $run.Text -match 'Wax is not installed in this game yet') $run.Text
$null = Invoke-Setup @('-Action', 'Install', '-GameDir', $updWin64)
Add-PlayerFiles $updWin64
Set-Content -LiteralPath $updVersion -Value $version
$before = Get-PlayerState $updWin64

$newPackage = Join-Path $work 'package-9.9.9'
Copy-Item -LiteralPath $package -Destination $newPackage -Recurse
Set-Content -LiteralPath (Join-Path $newPackage "game\$waxPath\VERSION") -Value '9.9.9'
Set-Content -LiteralPath (Join-Path $newPackage "game\$waxPath\Scripts\wax\added_in_999.lua") -Value 'return {}'
[System.IO.Compression.ZipFile]::CreateFromDirectory($newPackage, (Join-Path $stand 'files\Wax-9.9.9.zip'))
$oldInside = Join-Path $work 'package-old-inside'
New-Item -ItemType Directory -Force (Join-Path $oldInside "game\$waxPath") | Out-Null
Set-Content -LiteralPath (Join-Path $oldInside 'Wax-Setup.ps1') -Value 'exit 0'
Set-Content -LiteralPath (Join-Path $oldInside 'game\dwmapi.dll') -Value 'an older release'
Set-Content -LiteralPath (Join-Path $oldInside "game\$waxPath\VERSION") -Value '0.0.1'
[System.IO.Compression.ZipFile]::CreateFromDirectory($oldInside, (Join-Path $stand 'files\old-inside.zip'))
$zipSize = (Get-Item -LiteralPath (Join-Path $stand 'files\Wax-9.9.9.zip')).Length
$env:TEMP = $env:TMP = Join-Path $work 'temp'

$bySite = 'https://wax-icarus\.duckdns\.org/docs/install/'
$notUnder = "is not under the Wax project's releases, so nothing was downloaded[\s\S]*$bySite"
$notSigned = "does not carry the signature of Wax's author, so nothing was installed[\s\S]*$bySite"
$refused = @(
    @{ Case = 'none';           Fetch = 0; Says = 'There is no Wax release to download yet';  What = 'no release yet (HTTP 404)' }
    @{ Case = 'limit';          Fetch = 0; Says = 'GitHub answered with error 403';           What = 'another GitHub error' }
    @{ Case = 'oddtag';         Fetch = 0; Says = "is called nightly, which this updater does not understand[\s\S]*$bySite"; What = 'a release whose name is not a version' }
    @{ Case = 'noasset';        Fetch = 0; Says = 'has no Wax zip attached yet';              What = 'a release without a zip' }
    @{ Case = 'unsigned';       Fetch = 0; Says = "has no signed list of its files, so this updater does not install it\. Download Wax by hand from the site:\s+$bySite"; What = 'a release with no manifest (every release before 0.2.1 is like this)' }
    @{ Case = 'nosig';          Fetch = 0; Says = "has no signed list of its files[\s\S]*$bySite"; What = 'a release with a manifest and no signature file' }
    @{ Case = 'elsewhere-path'; Fetch = 0; Says = $notUnder; What = 'download addresses under another path of the same server' }
    @{ Case = 'elsewhere-host'; Fetch = 0; Says = $notUnder; What = 'download addresses on another host' }
    @{ Case = 'elsewhere-dots'; Fetch = 0; Says = $notUnder; What = 'download addresses that climb out with ..' }
    @{ Case = 'elsewhere-user'; Fetch = 0; Says = $notUnder; What = 'download addresses that put the right host before an @' }
    @{ Case = 'elsewhere-tag';  Fetch = 0; Says = $notUnder; What = 'download addresses of another release of the project' }
    @{ Case = 'elsewhere-query'; Fetch = 0; Says = $notUnder; What = 'download addresses with something after a ?' }
    @{ Case = 'elsewhere-list'; Fetch = 0; Says = $notUnder; What = 'a right address for the zip and a wrong one for the manifest' }
    @{ Case = 'badsig';         Fetch = 2; Says = $notSigned; What = 'a signature of the right key over another text' }
    @{ Case = 'otherkey';       Fetch = 2; Says = $notSigned; What = 'a signature made with another key' }
    @{ Case = 'notsig';         Fetch = 2; Says = $notSigned; What = 'a signature file that holds no signature' }
    @{ Case = 'biglist';        Fetch = 2; Says = $notSigned; What = 'a manifest larger than 64 KB' }
    @{ Case = 'otherversion';   Fetch = 2; Says = "The signed list of files is for Wax 9\.9\.8, not for Wax 9\.9\.9, so nothing was installed[\s\S]*$bySite"; What = 'a rightly signed manifest of another version' }
    @{ Case = 'changedzip';     Fetch = 3; Says = 'is not the file the signed list describes, so nothing was installed'; What = 'a zip that differs from the manifest in one byte' }
    @{ Case = 'smaller';        Fetch = 3; Says = 'is not the file the signed list describes, so nothing was installed'; What = 'a zip that is cut short' }
    @{ Case = 'bigheader';      Fetch = 3; Says = 'larger than the signed list says the zip is, so it was stopped'; What = 'a zip that says up front it is larger than the manifest says' }
    @{ Case = 'bigger';         Fetch = 3; Says = 'larger than the signed list says the zip is, so it was stopped'; What = 'a zip that gives no size and keeps coming' }
    @{ Case = 'broken';         Fetch = 3; Says = "The download did not finish[\s\S]*$bySite"; What = 'a download that fails' }
    @{ Case = 'redirect-kind';  Fetch = 1; Says = 'The download did not finish';              What = 'a download that is sent on to another kind of address (not https, in the installer that ships)' }
    @{ Case = 'redirect-loop';  Fetch = 6; Says = 'The download did not finish';              What = 'a download that is sent on for ever' }
    @{ Case = 'notwax';         Fetch = 3; Says = 'could not be opened';                      What = 'a signed file that is not a zip' }
    @{ Case = 'oldinside';      Fetch = 3; Says = "The downloaded zip holds Wax 0\.0\.1, not Wax 9\.9\.9, so nothing was installed"; What = 'a signed zip named 9.9.9 that holds an older Wax' }
)
foreach ($case in $refused) {
    Set-Case $case.Case
    $run = Invoke-Setup $updArgs
    $asked = @(Get-Requests $case.Case | Where-Object { $_ -match ' GET /(dl|cdn|elsewhere)/' })
    Check "$($case.What): refused in plain words, with $($case.Fetch) of the release's files asked for" ($run.Code -eq 1 -and $run.Text -match $case.Says -and
        $run.Text -notmatch 'At line|Exception' -and $asked.Count -eq $case.Fetch) "asked for $($asked.Count): $($run.Text)"
    $unchanged = (Get-PlayerState $updWin64) -eq $before -and (Get-Content -LiteralPath $updVersion -Raw).Trim() -eq $version -and
        @(Get-ChildItem -LiteralPath (Join-Path $work 'temp') -Force).Count -eq 0
    if (-not $unchanged) { Check "$($case.What): the install is as it was and the download is cleaned up" $false }
}
Check 'none of those changed the install or left a download behind' ((Get-PlayerState $updWin64) -eq $before -and (Get-Content -LiteralPath $updVersion -Raw).Trim() -eq $version -and
    @(Get-ChildItem -LiteralPath (Join-Path $work 'temp') -Force).Count -eq 0)
$extra = [long]0
foreach ($line in Get-Requests 'bigger') { if ($line -match ' extra (\d+)$') { $extra = [long]$Matches[1] } }
Check "the zip that kept coming was hung up on while reading, not after: the stand-in got $([math]::Round($extra / 1MB, 1)) MB of 64 MB out past the size the manifest gives ($([math]::Round($zipSize / 1MB, 1)) MB)" ($extra -gt 0 -and $extra -lt 32MB)
Set-Case 'same'
$run = Invoke-Setup $updArgs
Check 'same version: says so and changes nothing' ($run.Code -eq 0 -and $run.Text -match 'You have the newest version' -and (Get-Content -LiteralPath $updVersion -Raw).Trim() -eq $version) $run.Text
Set-Case 'older'
$run = Invoke-Setup $updArgs
Check 'a newest release that is older than the installed Wax: nothing is downloaded and nothing changes' ($run.Code -eq 0 -and $run.Text -match 'You have the newest version\. Nothing was changed' -and
    (Get-Content -LiteralPath $updVersion -Raw).Trim() -eq $version -and @(Get-Requests 'older' | Where-Object { $_ -match '/dl/' }).Count -eq 0) $run.Text

Set-Case 'new'
$run = Invoke-Setup $updArgs
Check 'a newer release with a good signature is downloaded and installed' ($run.Code -eq 0 -and $run.Text -match "Wax was updated from $([regex]::Escape($version)) to 9\.9\.9\." -and
    (Get-Content -LiteralPath $updVersion -Raw).Trim() -eq '9.9.9' -and (Test-Path -LiteralPath (Join-Path $updWin64 "$waxPath\Scripts\wax\added_in_999.lua"))) $run.Text
Check 'it checked the signature before it downloaded the zip: the manifest, its signature, then the zip' (((Get-Requests 'new' | Where-Object { $_ -match '/dl/' } | Select-Object -Last 3) -replace '^.*/', '') -join ' ' -ceq
    'Wax-9.9.9.manifest Wax-9.9.9.manifest.sig Wax-9.9.9.zip') ((Get-Requests 'new') -join '; ')
Check 'the update kept the player''s mods and settings' ((Get-PlayerState $updWin64) -eq $before)
Check 'the update cleaned up its download' (@(Get-ChildItem -LiteralPath (Join-Path $work 'temp') -Force).Count -eq 0)
Check 'the update asked nothing, left the button as it was (off), and closed the folder again' ($run.Text -notmatch 'Windows has to hand links' -and (Get-Link) -eq '' -and
    $run.Text -match "Wax's folder can now only be changed by your Windows account") $run.Text
Test-Closed 'after the update' (Join-Path $updWin64 $waxPath)
$run = Invoke-Setup $updArgs
Check 'running the update again finds nothing newer' ($run.Code -eq 0 -and $run.Text -match 'You have the newest version') $run.Text
Set-Case 'older'
$run = Invoke-Setup $updArgs
Check 'and it cannot be taken back to an older release' ($run.Code -eq 0 -and $run.Text -match 'You have the newest version' -and (Get-Content -LiteralPath $updVersion -Raw).Trim() -eq '9.9.9') $run.Text

$upd2Win64 = New-FakeGame (Join-Path $work 'update two\Icarus')
$null = Invoke-Setup @('-Action', 'Install', '-GameDir', $upd2Win64, '-ModLinks', 'Yes')
$linkBefore = Get-Link
Set-Case 'redirect'
$run = Invoke-Setup @('-Action', 'Update', '-GameDir', $upd2Win64)
Check 'a download that is sent on once, as GitHub does, still works' ($run.Code -eq 0 -and (Get-Content -LiteralPath (Join-Path $upd2Win64 "$waxPath\VERSION") -Raw).Trim() -eq '9.9.9' -and
    @(Get-Requests 'redirect' | Where-Object { $_ -match ' GET /cdn/' }).Count -eq 3) $run.Text
Check 'a button that was switched on is still on after the update, with no question' ($linkBefore -and (Get-Link) -ceq $linkBefore -and $run.Text -notmatch 'Windows has to hand links') (Get-Link)
$null = Invoke-Setup @('-Action', 'Uninstall', '-GameDir', $upd2Win64, '-RemoveMyFiles', 'Yes', '-RemoveUE4SS', 'Yes')

$mistakes = @(Get-Requests 'error')
Check 'the stand-in for GitHub answered every request it got' ($mistakes.Count -eq 0 -and -not $server.HasExited) ($mistakes -join '; ')
Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
$server = $null
Set-Content -LiteralPath $updVersion -Value $version
$run = Invoke-Setup $updArgs
Check 'no connection: plain message' ($run.Code -eq 1 -and $run.Text -match 'GitHub could not be reached\. Check your internet connection' -and $run.Text -notmatch 'At line|Exception') $run.Text
$env:TEMP, $env:TMP = $oldTemp, $oldTmp

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

Section 'What the test left on this PC'
Clear-Link
Set-LocalFolder @()
Check 'this PC''s own wax:// registration is as it was before the test' ((Get-Link 'wax') -ceq $realLink)
Check 'the real folder of the importer''s log was not removed' (-not $realLog -or (Test-Path -LiteralPath $localReal))
Check 'the test''s own kind of link and its folder under %LOCALAPPDATA% are gone' (-not (Test-Path -LiteralPath $schemeKey) -and -not (Test-Path -LiteralPath $localTest))

} finally {
    $env:TEMP, $env:TMP = $oldTemp, $oldTmp
    if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    Clear-Link
    Set-LocalFolder @()
}

Write-Host ''
if ($script:failures.Count) {
    Write-Host "$($script:failures.Count) failed, $($script:passed) passed" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
Write-Host "All $($script:passed) checks passed." -ForegroundColor Green
