#requires -Version 7
<#
.SYNOPSIS
  Links the Wax framework into the game so it loads with UE4SS, or unlinks it.
.DESCRIPTION
  Installs UE4SS if it is missing, then makes <game>\Binaries\Win64\ue4ss\Mods\Wax a directory junction to
  wax\runtime in this workspace. The game therefore runs the workspace's files directly: edits are live, and
  nothing has to be copied after a change.
.EXAMPLE
  .\scripts\Install-Wax.ps1
  .\scripts\Install-Wax.ps1 -Remove      # unlink Wax, leave UE4SS in place
#>
[CmdletBinding()]
param([switch]$Remove)
. "$PSScriptRoot\_common.ps1"

$paths   = Get-IcarusPaths
$runtime = Join-Path $Root 'wax\runtime'
$link    = Join-Path $paths.Win64 'ue4ss\Mods\Wax'
Assert-GameNotRunning

if ($Remove) {
    if (Test-Path -LiteralPath $link) {
        if (-not (Get-Item -LiteralPath $link -Force).LinkType) { throw "$link is a real folder, not a link. Remove it by hand." }
        [System.IO.Directory]::Delete($link)   # non-recursive: removes the link, not wax\runtime
        Write-Host "Unlinked Wax from the game."
    } else { Write-Host 'Wax is not linked.' }
    return
}

if (-not (Test-Path (Join-Path $runtime 'Scripts\main.lua'))) { throw "wax\runtime\Scripts\main.lua not found." }
if (-not (Test-Path (Join-Path $paths.Win64 'dwmapi.dll'))) { & (Join-Path $PSScriptRoot 'Install-UE4SS.ps1') }

New-Item -ItemType Directory -Force (Join-Path $runtime 'run\in'), (Join-Path $runtime 'run\out'), (Join-Path $runtime 'saved') | Out-Null
if (-not (Test-Path (Join-Path $runtime 'enabled.txt'))) { Set-Content (Join-Path $runtime 'enabled.txt') '' }
# The game looks for mods in <Wax>\mods; in this workspace that is luamods\, linked in.
$mods = Join-Path $runtime 'mods'
if (-not (Test-Path -LiteralPath $mods)) { New-Item -ItemType Junction -Path $mods -Target (Join-Path $Root 'luamods') | Out-Null }

if (Test-Path -LiteralPath $link) {
    $item = Get-Item -LiteralPath $link -Force
    if (-not $item.LinkType) { throw "$link exists and is a real folder, not a link. Move it out of the way first." }
    if ($item.Target -ne $runtime) { [System.IO.Directory]::Delete($link) }
}
if (-not (Test-Path -LiteralPath $link)) { New-Item -ItemType Junction -Path $link -Target $runtime | Out-Null }

$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamExe -replace '/', '\'
[ordered]@{ gameDir = $paths.GameDir; win64 = $paths.Win64; steamExe = $steam } |
    ConvertTo-Json | Set-Content (Join-Path $Root 'wax\wax.config.json')

Write-Host "Wax is linked: $link -> $runtime"
Write-Host 'Start the game with:  node wax\cli\wax.mjs start'
