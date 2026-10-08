#requires -Version 7
<#
.SYNOPSIS
  Brings the editor's definitions of the game's classes (wax\types\icarus) up to date with the newest build of
  the game, from the index the server writes to the Icarus SDK repository.
.DESCRIPTION
  Does nothing when the index here is already the one of that build. Build-WaxExtension.ps1 runs it first, so a
  built extension carries the newest classes. The definitions are written here, with this workspace's own
  wax\types, not copied: they depend on what Wax itself declares.
#>
[CmdletBinding()]
param([string]$Repository = 'bostonstrong567/icarus-sdk', [switch]$Force)
. "$PSScriptRoot\_common.ps1"

$raw   = "https://raw.githubusercontent.com/$Repository/main"
$dir   = Join-Path $BuildDir 'game-index'
$mark  = Join-Path $dir 'sdk.json'
$index = Join-Path $dir 'index.json'
New-Item -ItemType Directory -Force $dir | Out-Null

$build = Invoke-RestMethod "$raw/build.json" -TimeoutSec 30
$have  = if (Test-Path $mark) { Get-Content $mark -Raw | ConvertFrom-Json } else { $null }
if (-not $Force -and $have -and $have.manifest -eq $build.manifest -and (Test-Path $index)) {
    Write-Host "The game's classes are already those of $($build.game_version)."
    return
}

$packed = Join-Path $dir 'index.json.gz'
Invoke-WebRequest "$raw/model/index.json.gz" -OutFile $packed -TimeoutSec 300
$new = Join-Path $dir 'index.new.json'
$in  = [IO.Compression.GZipStream]::new([IO.File]::OpenRead($packed), [IO.Compression.CompressionMode]::Decompress)
$out = [IO.File]::Create($new)
try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
Remove-Item $packed
if (Test-Path $index) { Move-Item $index (Join-Path $dir 'index.before.json') -Force }
Move-Item $new $index

python (Join-Path $PSScriptRoot 'gameindex.py') types | Select-Object -Last 4
if ($LASTEXITCODE -notin 0, 2) { throw "Writing the definitions failed (exit $LASTEXITCODE)." }
$build | ConvertTo-Json -Depth 4 | Set-Content $mark
Write-Host "wax\types\icarus is now of $($build.game_version)."
