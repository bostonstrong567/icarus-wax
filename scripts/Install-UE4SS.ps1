#requires -Version 7
<#
.SYNOPSIS
  Installs or removes UE4SS (Lua/Blueprint mod loader, live object viewer) in the game's Binaries\Win64.
.DESCRIPTION
  UE4SS injects into the game through a dwmapi.dll proxy. Only needed for Lua mods, Blueprint mod
  loading, or dumping objects/SDKs. Data-table mods do not need it.
  UE4SS's zip switches on three mods of its own that open the game's console and cheat commands
  (CheatManagerEnablerMod, ConsoleCommandsMod, ConsoleEnablerMod). They stay on here unless -PlayerDefaults is
  given, which switches them off in mods.txt and mods.json the way the player download of Wax has them.
.EXAMPLE
  .\scripts\Install-UE4SS.ps1                   # current experimental build, as its zip has it
  .\scripts\Install-UE4SS.ps1 -Dev              # adds the GUI console and dumpers
  .\scripts\Install-UE4SS.ps1 -PlayerDefaults   # with the cheat and console mods switched off
  .\scripts\Install-UE4SS.ps1 -Remove
#>
[CmdletBinding()]
param(
    [switch]$Dev,
    [switch]$PlayerDefaults,
    [switch]$Remove
)
. "$PSScriptRoot\_common.ps1"

$win64 = (Get-IcarusPaths).Win64
Assert-GameNotRunning

if ($Remove) {
    # Mods may be directory junctions into this workspace (Install-Wax.ps1 makes one). Unlink those first so the
    # recursive delete below can never reach through a link and delete workspace files.
    foreach ($mods in 'ue4ss\Mods', 'Mods') {
        $modsDir = Join-Path $win64 $mods
        if (-not (Test-Path $modsDir)) { continue }
        Get-ChildItem -LiteralPath $modsDir -Force | Where-Object LinkType | ForEach-Object {
            [System.IO.Directory]::Delete($_.FullName)   # non-recursive: removes the link, not its target
            Write-Host "Unlinked $mods\$($_.Name)"
        }
    }
    foreach ($item in 'dwmapi.dll', 'ue4ss', 'UE4SS.dll', 'UE4SS-settings.ini', 'Mods') {
        $path = Join-Path $win64 $item
        if (Test-Path $path) { Remove-Item -LiteralPath $path -Recurse -Force; Write-Host "Removed $item" }
    }
    return
}

$pattern = if ($Dev) { 'zDEV-UE4SS_v*.zip' } else { 'UE4SS_v*.zip' }
$zip = Get-ChildItem (Join-Path $ToolsDir 'ue4ss') -Filter $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $zip) { throw "No UE4SS archive in tools\ue4ss. Run Get-Tools.ps1." }

Expand-Archive -LiteralPath $zip.FullName -DestinationPath $win64 -Force
Write-Host "Installed $($zip.Name) into $win64"

$cheatMods = 'CheatManagerEnablerMod', 'ConsoleCommandsMod', 'ConsoleEnablerMod'
if ($PlayerDefaults) {
    $modsTxt = Join-Path $win64 'ue4ss\Mods\mods.txt'
    $modsJson = Join-Path $win64 'ue4ss\Mods\mods.json'
    $list = [System.IO.File]::ReadAllText($modsTxt)
    foreach ($mod in $cheatMods) { $list = [regex]::Replace($list, "(?m)^($mod\s*:\s*)1", '${1}0') }
    [System.IO.File]::WriteAllText($modsTxt, $list)
    if (Test-Path -LiteralPath $modsJson) {
        $json = [System.IO.File]::ReadAllText($modsJson)
        foreach ($mod in $cheatMods) { $json = [regex]::Replace($json, "(`"mod_name`"\s*:\s*`"$mod`"\s*,\s*`"mod_enabled`"\s*:\s*)true", '${1}false') }
        [System.IO.File]::WriteAllText($modsJson, $json)
    }
    Write-Host "Switched off in mods.txt: $($cheatMods -join ', ')"
} else {
    Write-Host "UE4SS's cheat and console mods are on, as its zip has them ($($cheatMods -join ', ')). -PlayerDefaults switches them off."
}
Write-Host "Lua mods go in $win64\ue4ss\Mods (older layout: $win64\Mods). Enable them in mods.txt."
