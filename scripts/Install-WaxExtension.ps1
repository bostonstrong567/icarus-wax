#requires -Version 7
<#
.SYNOPSIS
  Installs the Wax extension into VS Code from build\wax-icarus-<version>.vsix, or removes it.
.DESCRIPTION
  Build the .vsix first with Build-WaxExtension.ps1. VS Code installs the Lua language server extension
  (sumneko.lua) alongside, because the Wax extension depends on it.
.EXAMPLE
  .\scripts\Install-WaxExtension.ps1
  .\scripts\Install-WaxExtension.ps1 -Remove
#>
[CmdletBinding()]
param([switch]$Remove)
. "$PSScriptRoot\_common.ps1"

$id   = 'RobertCincotta.wax-icarus'
$code = Get-Command code -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $code) { throw 'The "code" command was not found. Add VS Code''s bin folder to PATH (its installer has a checkbox for it).' }

if ($Remove) {
    if ((& $code.Source --list-extensions) -contains $id) {
        & $code.Source --uninstall-extension $id
        if ($LASTEXITCODE -ne 0) { throw 'VS Code could not remove the extension.' }
        Write-Host "Removed $id. Reload any open VS Code window."
    } else { Write-Host "$id is not installed." }
    return
}

$version = (Get-Content (Join-Path $Root 'wax\vscode\package.json') -Raw | ConvertFrom-Json).version
$vsix = Join-Path $BuildDir "wax-icarus-$version.vsix"
if (-not (Test-Path $vsix)) { throw "$vsix not found. Run scripts\Build-WaxExtension.ps1 first." }

& $code.Source --install-extension $vsix --force
if ($LASTEXITCODE -ne 0) { throw 'VS Code could not install the extension.' }
Write-Host "Installed $id $version. Reload any open VS Code window to start using it (Developer: Reload Window)."
