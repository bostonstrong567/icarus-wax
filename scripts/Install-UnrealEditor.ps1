#requires -Version 7
<#
.SYNOPSIS
  Downloads Unreal Engine 4.27.2 (the version Icarus mods are cooked with) into engine\UE_4.27.
.DESCRIPTION
  Uses the legendary command-line Epic client with the Epic account already signed in under
  tools\unreal\legendary\config. Run "legendary auth" there first if it is not signed in.
  Re-running resumes an interrupted download or verifies an existing install.

  Only the parts Icarus modding needs are installed by default (about 19 GB on disk):
    (core)          the editor itself
    engine_source   C++ headers, for code plugins
    templates       project templates for the New Project wizard
  Other tags: starter_content, editor_symbols (34 GB), platform_Android/IOS/Linux/HoloLens/Lumin/TVOS.
.EXAMPLE
  .\scripts\Install-UnrealEditor.ps1
  .\scripts\Install-UnrealEditor.ps1 -Components '', 'engine_source', 'templates', 'starter_content'
#>
[CmdletBinding()]
param(
    [string[]]$Components = @('', 'engine_source', 'templates')
)
. "$PSScriptRoot\_common.ps1"

$legendary = Get-ToolExe legendary
$env:LEGENDARY_CONFIG_PATH = Join-Path (Split-Path $legendary) 'config'
$engineDir = Join-Path $Root 'engine'
New-Item -ItemType Directory -Force $engineDir | Out-Null

if ((& $legendary status 2>&1 | Out-String) -match 'not logged in') {
    throw "legendary is not signed in to Epic. Run: `$env:LEGENDARY_CONFIG_PATH='$env:LEGENDARY_CONFIG_PATH'; & '$legendary' auth"
}

# The core editor files carry no tag, which legendary selects with an empty --install-tag.
$tagArgs = $Components | ForEach-Object { '--install-tag'; $_ }
& $legendary -y install UE_4.27 --platform Windows --base-path $engineDir --skip-sdl @tagArgs
if ($LASTEXITCODE -ne 0) { throw "legendary install failed (exit $LASTEXITCODE)." }

$editor = Join-Path $engineDir 'UE_4.27\Engine\Binaries\Win64\UE4Editor.exe'
if (-not (Test-Path $editor)) { throw "Install finished but $editor is missing." }
Write-Host "Unreal Editor: $editor"
Write-Host "If the editor reports missing runtimes, run engine\UE_4.27\Engine\Extras\Redist\en-us\UE4PrereqSetup_x64.exe once."
