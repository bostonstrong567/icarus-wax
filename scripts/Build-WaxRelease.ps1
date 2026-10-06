#requires -Version 7
<#
.SYNOPSIS
  Builds the player download for Wax: build\Wax-<version>.zip.
.DESCRIPTION
  The zip holds a "game" folder (the UE4SS build Wax is tested on, with Wax at ue4ss\Mods\Wax and the example mod
  at ue4ss\Mods\Wax\mods\Hello), the installer files from wax\release\payload, README.txt and the licences.
  Everything in it is a real file: no junctions are followed or copied. The version comes from wax\VERSION.
  Every Lua file that goes in is compiled with tools\lua\lua54\lua.exe first, and the build fails if one does not.
.EXAMPLE
  .\scripts\Build-WaxRelease.ps1
  .\scripts\Build-WaxRelease.ps1 -KeepStage     # leaves build\_wax-release for a look
#>
[CmdletBinding()]
param([switch]$KeepStage)
. "$PSScriptRoot\_common.ps1"

# Wax is tested on this exact UE4SS build and relies on it. Do not swap in "latest".
$ue4ssZip = Join-Path $ToolsDir 'ue4ss\UE4SS_v3.0.1-1152-ge3ba1016.zip'
$runtime  = Join-Path $Root 'wax\runtime'
$payload  = Join-Path $Root 'wax\release\payload'
$hello    = Join-Path $Root 'luamods\Hello'
$lua      = Join-Path $ToolsDir 'lua\lua54\lua.exe'

$version = (Get-Content (Join-Path $Root 'wax\VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "wax\VERSION should hold a version like 0.1.0, not '$version'." }
foreach ($needed in $ue4ssZip, (Join-Path $runtime 'Scripts\main.lua'), (Join-Path $hello 'init.lua'), $lua) {
    if (-not (Test-Path -LiteralPath $needed)) { throw "Missing: $needed" }
}

$stage = Join-Path $BuildDir '_wax-release'
$zip   = Join-Path $BuildDir "Wax-$version.zip"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
$game = Join-Path $stage 'game'
$wax  = Join-Path $game 'ue4ss\Mods\Wax'
New-Item -ItemType Directory -Force $game | Out-Null

# UE4SS goes in exactly as Install-UE4SS.ps1 installs it for normal use: the release zip, settings untouched.
Expand-Archive -LiteralPath $ue4ssZip -DestinationPath $game
foreach ($needed in 'dwmapi.dll', 'ue4ss\UE4SS.dll', 'ue4ss\UE4SS-settings.ini', 'ue4ss\Mods\mods.txt') {
    if (-not (Test-Path -LiteralPath (Join-Path $game $needed))) { throw "The UE4SS zip has no $needed." }
}

# Wax: everything in wax\runtime except what belongs to one machine (run, saved) and the mods junction.
New-Item -ItemType Directory -Force $wax | Out-Null
$copied = @()
foreach ($item in Get-ChildItem -LiteralPath $runtime -Force) {
    if ($item.Name -in 'run', 'saved', 'mods') { continue }
    if ($item.LinkType) { throw "wax\runtime\$($item.Name) is a link. Only real files go into a release." }
    Copy-Item -LiteralPath $item.FullName -Destination $wax -Recurse
    $copied += $item.Name
}
foreach ($folder in 'saved', 'run\in', 'run\out', 'mods\Hello') { New-Item -ItemType Directory -Force (Join-Path $wax $folder) | Out-Null }
if (-not (Test-Path -LiteralPath (Join-Path $wax 'enabled.txt'))) { Set-Content -LiteralPath (Join-Path $wax 'enabled.txt') -Value '' }
[System.IO.File]::WriteAllText((Join-Path $wax 'VERSION'), "$version`r`n", [System.Text.Encoding]::ASCII)

# The example mod, without editor files that point into this workspace.
foreach ($item in Get-ChildItem -LiteralPath $hello -Force | Where-Object { -not $_.Name.StartsWith('.') }) {
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $wax 'mods\Hello') -Recurse
}

$links = @(Get-ChildItem -LiteralPath $stage -Recurse -Force -Attributes ReparsePoint)
if ($links.Count) { throw "Links ended up in the release: $($links.FullName -join ', ')" }

# Text a player opens is plain ASCII with Windows line endings (Windows PowerShell 5.1 and Notepad both need that).
function Copy-Text([string]$From, [string]$To) {
    $text = [System.IO.File]::ReadAllText($From)
    $text = ($text -replace "`r`n", "`n" -replace "`r", "`n").Replace('@VERSION@', $version).Replace("`n", "`r`n")
    $odd = [regex]::Match($text, '[^\x09\x0A\x0D\x20-\x7E]')
    if ($odd.Success) { throw "$From has a character that is not plain ASCII at position $($odd.Index): U+$('{0:X4}' -f [int][char]$odd.Value)" }
    [System.IO.File]::WriteAllText($To, $text, [System.Text.Encoding]::ASCII)
}
foreach ($name in 'Install Wax.cmd', 'Update Wax.cmd', 'Uninstall Wax.cmd', 'Wax-Setup.ps1', 'README.txt') {
    Copy-Text (Join-Path $payload $name) (Join-Path $stage $name)
}
New-Item -ItemType Directory -Force (Join-Path $stage 'licenses') | Out-Null
Copy-Text (Join-Path $game 'ue4ss\LICENSE') (Join-Path $stage 'licenses\UE4SS-LICENSE.txt')
Copy-Text (Join-Path $runtime 'assets\lucide\LICENSE.txt') (Join-Path $stage 'licenses\Lucide-LICENSE.txt')

# The installer has to parse under Windows PowerShell 5.1, which is what players have.
$check = "`$e = `$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$(Join-Path $stage 'Wax-Setup.ps1')', [ref]`$null, [ref]`$e); `$e | ForEach-Object { `$_.ToString() }; exit `$e.Count"
& powershell.exe -NoLogo -NoProfile -Command $check
if ($LASTEXITCODE -ne 0) { throw 'Wax-Setup.ps1 does not parse under Windows PowerShell 5.1.' }

# Every Lua file a player gets must at least compile.
$luaFiles = @(Get-ChildItem -LiteralPath $stage -Recurse -Force -File -Filter *.lua)
$list = Join-Path $BuildDir '_wax-release-lua.txt'
[System.IO.File]::WriteAllLines($list, [string[]]$luaFiles.FullName)
& $lua (Join-Path $Root 'wax\release\compile_check.lua') $list
$luaFailed = $LASTEXITCODE -ne 0
Remove-Item -LiteralPath $list -Force
if ($luaFailed) { throw 'A Lua file in the release does not compile. See above.' }

# Folders are written as entries of their own, so the empty ones (saved, run\in, run\out) exist after extraction.
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$stream = [System.IO.File]::Open($zip, 'CreateNew')
$archive = [System.IO.Compression.ZipArchive]::new($stream, 'Create')
try {
    foreach ($item in Get-ChildItem -LiteralPath $stage -Recurse -Force | Sort-Object FullName) {
        $name = $item.FullName.Substring($stage.Length + 1).Replace('\', '/')
        if ($item.PSIsContainer) {
            $archive.CreateEntry("$name/").ExternalAttributes = 0x10
        } else {
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $item.FullName, $name, 'Optimal')
        }
    }
} finally {
    $archive.Dispose()
    $stream.Dispose()
}

$read = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    $names = @($read.Entries.FullName)
    $must = 'Install Wax.cmd', 'Update Wax.cmd', 'Uninstall Wax.cmd', 'Wax-Setup.ps1', 'README.txt',
        'licenses/UE4SS-LICENSE.txt', 'licenses/Lucide-LICENSE.txt', 'game/dwmapi.dll', 'game/ue4ss/UE4SS.dll',
        'game/ue4ss/UE4SS-settings.ini', 'game/ue4ss/Mods/mods.txt', 'game/ue4ss/Mods/Wax/enabled.txt',
        'game/ue4ss/Mods/Wax/VERSION', 'game/ue4ss/Mods/Wax/Scripts/main.lua', 'game/ue4ss/Mods/Wax/bin/waxco.dll',
        'game/ue4ss/Mods/Wax/mods/Hello/init.lua', 'game/ue4ss/Mods/Wax/saved/', 'game/ue4ss/Mods/Wax/run/in/',
        'game/ue4ss/Mods/Wax/run/out/'
    $missing = @($must | Where-Object { $_ -notin $names })
    if ($missing.Count) { throw "The zip is missing: $($missing -join ', ')" }
    $top = @($names | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
    $files = @($read.Entries | Where-Object { -not $_.FullName.EndsWith('/') }).Count
} finally {
    $read.Dispose()
}
if (-not $KeepStage) { Remove-Item -LiteralPath $stage -Recurse -Force }

Write-Host "Built $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 2)) MB, $files files, $($luaFiles.Count) Lua files compiled)"
Write-Host "Top level: $($top -join ', ')"
Write-Host "From wax\runtime: $($copied -join ', ')"
Write-Host 'Test it with: .\wax\release\test\Test-WaxRelease.ps1'
