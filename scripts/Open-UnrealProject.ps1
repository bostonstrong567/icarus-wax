#requires -Version 7
<#
.SYNOPSIS
  Opens the Icarus asset-authoring project (unreal\Icarus) in Unreal Editor 4.27.2.
.DESCRIPTION
  The engine was installed without the Epic launcher, so it is identified by a per-user registration
  rather than the name "4.27". This script makes sure that registration exists and that the project
  points at it, which is what stops the editor's "made with a different version" prompt.
  The first launch compiles shaders and takes several minutes.
.EXAMPLE
  .\scripts\Open-UnrealProject.ps1
  .\scripts\Open-UnrealProject.ps1 -NoLaunch    # only fix the engine association
#>
[CmdletBinding()]
param([switch]$NoLaunch)
. "$PSScriptRoot\_common.ps1"

$engineDir = Join-Path $Root 'engine\UE_4.27'
$editor    = Join-Path $engineDir 'Engine\Binaries\Win64\UE4Editor.exe'
$project   = Join-Path $Root 'unreal\Icarus\Icarus.uproject'
if (-not (Test-Path $editor)) { throw "Unreal Editor not found. Run scripts\Install-UnrealEditor.ps1." }

# Unreal lists non-launcher engines here: value name = engine id, data = engine folder.
$key = 'HKCU:\SOFTWARE\Epic Games\Unreal Engine\Builds'
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
$normalize = { param($p) ($p -replace '\\', '/').TrimEnd('/').ToLowerInvariant() }
$wanted = & $normalize $engineDir
$id = (Get-Item $key).Property | Where-Object { (& $normalize (Get-ItemPropertyValue $key $_)) -eq $wanted } | Select-Object -First 1
if (-not $id) {
    $id = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
    New-ItemProperty -Path $key -Name $id -Value ($engineDir -replace '\\', '/') -PropertyType String | Out-Null
}

$json = Get-Content $project -Raw
$fixed = $json -replace '("EngineAssociation":\s*)"[^"]*"', "`$1`"$id`""
if ($fixed -ne $json) { Set-Content $project $fixed -NoNewline; Write-Host "Project now points at engine $id" }

if (-not $NoLaunch) {
    Start-Process $editor -ArgumentList "`"$project`""
    Write-Host "Opening $project"
}
