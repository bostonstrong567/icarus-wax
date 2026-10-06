#requires -Version 7
<#
.SYNOPSIS
  Builds wax\native\waxco.c into wax\runtime\bin\waxco.dll (the helper that lets Lua coroutines call the engine).
.DESCRIPTION
  Needs gcc (mingw). The game must not be running: it keeps the DLL loaded.
  The helper is tied to the UE4SS build pinned in tools.json, because it calls functions UE4SS.dll exports by
  their exact names. After a UE4SS update, rebuild and run the live tests in wax\tests\live\co_*.lua.
#>
[CmdletBinding()]
param()
. "$PSScriptRoot\_common.ps1"

$gcc = Get-Command gcc -ErrorAction SilentlyContinue
if (-not $gcc) { throw 'gcc is needed to build the helper (e.g. scoop install mingw).' }
Assert-GameNotRunning

$source = Join-Path $Root 'wax\native\waxco.c'
$outDir = Join-Path $Root 'wax\runtime\bin'
New-Item -ItemType Directory -Force $outDir | Out-Null
$dll = Join-Path $outDir 'waxco.dll'

& $gcc.Source -O2 -Wall -Wextra -Wno-cast-function-type -shared -static-libgcc -o $dll $source
if ($LASTEXITCODE -ne 0) { throw 'gcc failed to build waxco.dll.' }
Write-Host "Built $dll ($([math]::Round((Get-Item $dll).Length / 1KB)) KB)"
