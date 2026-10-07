#requires -Version 7
<#
.SYNOPSIS
  Builds the two native helpers of Wax into wax\runtime\bin: waxco.dll and waxnet.dll.
.DESCRIPTION
  Needs gcc (mingw).
  waxco.dll (wax\native\waxco.c) lets Lua coroutines call the engine. The game keeps it loaded, so the game must
  not be running. It is tied to the UE4SS build pinned in tools.json, because it calls functions UE4SS.dll exports
  by their exact names. After a UE4SS update, rebuild and run the live tests in wax\tests\live\co_*.lua.
  waxnet.dll (wax\native\waxnet.c) downloads mod updates from the catalogue. It uses nothing of UE4SS or Lua, and
  the game only loads it at the first check for updates, so it can usually be built while the game runs.
.EXAMPLE
  .\scripts\Build-WaxNative.ps1
  .\scripts\Build-WaxNative.ps1 -Only waxnet
#>
[CmdletBinding()]
param([ValidateSet('waxco', 'waxnet')][string]$Only = '')
. "$PSScriptRoot\_common.ps1"

$gcc = Get-Command gcc -ErrorAction SilentlyContinue
if (-not $gcc) { throw 'gcc is needed to build the helpers (e.g. scoop install mingw).' }

$outDir = Join-Path $Root 'wax\runtime\bin'
New-Item -ItemType Directory -Force $outDir | Out-Null

$helpers = [ordered]@{
    waxco  = @('-Wno-cast-function-type')
    waxnet = @('-lwinhttp', '-lbcrypt')
}
foreach ($name in $helpers.Keys) {
    if ($Only -and $Only -ne $name) { continue }
    if ($name -eq 'waxco') { Assert-GameNotRunning }
    $source = Join-Path $Root "wax\native\$name.c"
    $dll = Join-Path $outDir "$name.dll"
    New-Item -ItemType Directory -Force $BuildDir | Out-Null
    $fresh = Join-Path $BuildDir "_native-$name.dll"
    & $gcc.Source -O2 -Wall -Wextra -shared -static-libgcc -o $fresh $source @($helpers[$name])
    if ($LASTEXITCODE -ne 0) { throw "gcc failed to build $name.dll." }
    try { Move-Item -LiteralPath $fresh -Destination $dll -Force }
    catch {
        Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
        throw "$name.dll is in use, so the new build could not replace it. Close the game and run this again."
    }
    Write-Host "Built $dll ($([math]::Round((Get-Item $dll).Length / 1KB)) KB)"
}
