#requires -Version 7
<#
.SYNOPSIS
  Installs or removes UE4SS (Lua/Blueprint mod loader, live object viewer) in the game's Binaries\Win64.
.DESCRIPTION
  UE4SS injects into the game through a dwmapi.dll proxy. Only needed for Lua mods, Blueprint mod
  loading, or dumping objects/SDKs. Data-table mods do not need it.
.EXAMPLE
  .\scripts\Install-UE4SS.ps1            # current experimental build
  .\scripts\Install-UE4SS.ps1 -Dev       # adds the GUI console and dumpers
  .\scripts\Install-UE4SS.ps1 -Remove
#>
[CmdletBinding()]
param(
    [switch]$Dev,
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
Write-Host "Lua mods go in $win64\ue4ss\Mods (older layout: $win64\Mods). Enable them in mods.txt."
