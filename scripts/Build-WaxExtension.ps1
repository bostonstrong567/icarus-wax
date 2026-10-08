#requires -Version 7
<#
.SYNOPSIS
  Packs the VS Code extension in wax\vscode into build\wax-icarus-<version>.vsix.
.DESCRIPTION
  Copies what the extension needs on a machine without this workspace into wax\vscode\bundled (the type
  definitions, the game's classes, the require plugin and the bridge client), then packs it with vsce. Needs Node; the first run
  downloads vsce into build\.npm-cache.
.EXAMPLE
  .\scripts\Build-WaxExtension.ps1
#>
[CmdletBinding()]
param([switch]$NoSync)
. "$PSScriptRoot\_common.ps1"

# The classes of the newest build of the game, when this copy has the script and the repository answers.
$sync = Join-Path $PSScriptRoot 'Get-GameSdk.ps1'
if (-not $NoSync -and (Test-Path $sync)) {
    try { & $sync } catch { Write-Warning "The game's classes were not brought up to date: $_" }
}

$npx = Get-Command npx -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $npx) { throw 'Node.js (npx) is needed to pack the extension.' }

$extension = Join-Path $Root 'wax\vscode'
$bundled   = Join-Path $extension 'bundled'
if (Test-Path $bundled) { Remove-Item $bundled -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $bundled 'lsp') | Out-Null
Copy-Item (Join-Path $Root 'wax\types') (Join-Path $bundled 'types') -Recurse
Copy-Item (Join-Path $Root 'wax\lsp\plugin.lua') (Join-Path $bundled 'lsp')
Copy-Item (Join-Path $Root 'wax\cli\bridge.mjs') $bundled

$version = (Get-Content (Join-Path $extension 'package.json') -Raw | ConvertFrom-Json).version
New-Item -ItemType Directory -Force $BuildDir | Out-Null
$vsix = Join-Path $BuildDir "wax-icarus-$version.vsix"
if (Test-Path $vsix) { Remove-Item $vsix -Force }

# Everything npm downloads stays in this workspace.
$previousCache = $env:npm_config_cache
$env:npm_config_cache = Join-Path $BuildDir '.npm-cache'
Push-Location $extension
try {
    & $npx.Source --yes '@vscode/vsce' package --no-dependencies --allow-missing-repository --skip-license --out $vsix
    if ($LASTEXITCODE -ne 0) { throw 'vsce failed to pack the extension.' }
} finally {
    Pop-Location
    $env:npm_config_cache = $previousCache
}
if (-not (Test-Path $vsix)) { throw "vsce reported success, but $vsix was not written." }

Write-Host "Built $vsix ($([math]::Round((Get-Item $vsix).Length / 1KB)) KB)"
Write-Host 'Install it with: .\scripts\Install-WaxExtension.ps1'
