#requires -Version 7
<#
.SYNOPSIS
  Builds the player download for Wax: build\Wax-<version>.zip, and the signed list of the release's files.
.DESCRIPTION
  The zip holds a "game" folder (the UE4SS build Wax is tested on, with Wax at ue4ss\Mods\Wax and Recipe Browser
  at ue4ss\Mods\Wax\mods\RecipeBrowser), the installer files from wax\release\payload, README.txt and the licences.
  UE4SS goes in as its own zip has it, except that its cheat and console mods are switched off in mods.txt and mods.json.
  Recipe Browser gets a wax.origin file with its version, which is what lets Wax update it from the catalogue.
  Everything in it is a real file: no junctions are followed or copied. The version comes from wax\VERSION.
  Every Lua file that goes in is compiled with tools\lua\lua54\lua.exe first, and the build fails if one does not.

  It ends by signing: the owner's tool (wax\market\cli.mjs sign-release) writes build\Wax-<version>.manifest and
  build\Wax-<version>.manifest.sig for the zip, and for the extension's .vsix when that is built. "Update Wax.cmd"
  only installs a zip that such a list names, and Publish-Release.ps1 does not publish without one. The private key
  is on the owner's PC only, so anyone else builds with -Unsigned.
.EXAMPLE
  .\scripts\Build-WaxRelease.ps1
  .\scripts\Build-WaxRelease.ps1 -Unsigned           # the zip alone, for trying it out; it cannot be published
  .\scripts\Build-WaxRelease.ps1 -KeepStage          # leaves build\_wax-release for a look
  .\scripts\Build-WaxRelease.ps1 -WithSetupProgram   # also packs "Wax Setup.exe", which is not finished: never signed, never published
#>
[CmdletBinding()]
param([switch]$KeepStage, [switch]$Unsigned, [switch]$WithSetupProgram)
. "$PSScriptRoot\_common.ps1"
. "$PSScriptRoot\_release.ps1"

# Wax is tested on this exact UE4SS build and relies on it. Do not swap in "latest".
$ue4ssZip = Join-Path $ToolsDir 'ue4ss\UE4SS_v3.0.1-1152-ge3ba1016.zip'
$runtime  = Join-Path $Root 'wax\runtime'
$payload  = Join-Path $Root 'wax\release\payload'
$bundled  = Join-Path $Root 'luamods\RecipeBrowser'
$lua      = Join-Path $ToolsDir 'lua\lua54\lua.exe'
# UE4SS's own mods that open the game's console and cheat commands. Wax needs none of them.
$cheatMods = 'CheatManagerEnablerMod', 'ConsoleCommandsMod', 'ConsoleEnablerMod'

$version = (Get-Content (Join-Path $Root 'wax\VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "wax\VERSION should hold a version like 0.1.0, not '$version'." }
foreach ($needed in $ue4ssZip, (Join-Path $runtime 'Scripts\main.lua'), (Join-Path $runtime 'bin\waxco.dll'), (Join-Path $runtime 'bin\waxnet.dll'),
        (Join-Path $bundled 'init.lua'), (Join-Path $bundled 'mod.lua'), $lua) {
    if (-not (Test-Path -LiteralPath $needed)) { throw "Missing: $needed" }
}
# The mod that comes with Wax is also in the catalogue. Its version is written beside it, so Wax can tell when a newer one is out.
$bundledVersion = [regex]::Match((Get-Content -LiteralPath (Join-Path $bundled 'mod.lua') -Raw), '(?m)^\s*version\s*=\s*"([0-9A-Za-z][0-9A-Za-z._+-]{0,31})"').Groups[1].Value
if (-not $bundledVersion) { throw 'luamods\RecipeBrowser\mod.lua gives no version.' }

# The installer that ships looks at the project's own releases and nowhere else. A copy changed for a test must never go out.
$key = Get-ReleaseKey
$installer = Get-Content -LiteralPath (Join-Path $payload 'Wax-Setup.ps1') -Raw
foreach ($line in "`$ReleaseApi = 'https://api.github.com/repos/bostonstrong567/icarus-wax/releases/latest'",
        "`$DownloadRoot = 'https://github.com/bostonstrong567/icarus-wax/releases/download/'", "`$LinkScheme = 'wax'", "`$LocalFolder = 'Wax'") {
    $name = [regex]::Escape($line.Substring(0, $line.IndexOf(' ')))
    if ([regex]::Matches($installer, "(?m)^\s*$name\s*=").Count -ne 1 -or $installer -notmatch "(?m)^$([regex]::Escape($line))\r?$") {
        throw "Wax-Setup.ps1 should hold this line, and no other line that sets the same name: $line"
    }
}
if ([regex]::Matches($installer, '(?m)^\s*\$SigningKey\s*=').Count -ne 1 -or $installer -match '(?i)\$env:WAX|\]\$(ReleaseApi|DownloadRoot|SigningKey|LinkScheme|LocalFolder)\b') {
    throw 'Wax-Setup.ps1 takes where it updates from, its key, its kind of link or its folder from outside the file. Those are fixed lines.'
}

$stage = Join-Path $BuildDir '_wax-release'
$zip   = Join-Path $BuildDir "Wax-$version.zip"
$manifest = Join-Path $BuildDir "Wax-$version.manifest"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
# A list signed for an earlier build of this version says nothing about the zip made now.
foreach ($stale in $manifest, "$manifest.sig") { if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force } }
$game = Join-Path $stage 'game'
$wax  = Join-Path $game 'ue4ss\Mods\Wax'
New-Item -ItemType Directory -Force $game | Out-Null

# UE4SS goes in as its release zip has it, settings untouched, except for the mod lists changed below.
Expand-Archive -LiteralPath $ue4ssZip -DestinationPath $game
foreach ($needed in 'dwmapi.dll', 'ue4ss\UE4SS.dll', 'ue4ss\UE4SS-settings.ini', 'ue4ss\Mods\mods.txt') {
    if (-not (Test-Path -LiteralPath (Join-Path $game $needed))) { throw "The UE4SS zip has no $needed." }
}

# The cheat and console mods ship switched off. A list that no longer names one as switched on stops the build, so a change in UE4SS is seen.
$modsTxt = Join-Path $game 'ue4ss\Mods\mods.txt'
$modsJson = Join-Path $game 'ue4ss\Mods\mods.json'
$list = [System.IO.File]::ReadAllText($modsTxt)
$json = if (Test-Path -LiteralPath $modsJson) { [System.IO.File]::ReadAllText($modsJson) }
foreach ($mod in $cheatMods) {
    $changed = [regex]::Replace($list, "(?m)^($mod\s*:\s*)1", '${1}0')
    if ($changed -ceq $list) { throw "mods.txt in the UE4SS zip does not switch $mod on any more. Look at what UE4SS ships before releasing." }
    $list = $changed
    if ($null -ne $json) {
        $changed = [regex]::Replace($json, "(`"mod_name`"\s*:\s*`"$mod`"\s*,\s*`"mod_enabled`"\s*:\s*)true", '${1}false')
        if ($changed -ceq $json) { throw "mods.json in the UE4SS zip does not switch $mod on any more. Look at what UE4SS ships before releasing." }
        $json = $changed
    }
}
[System.IO.File]::WriteAllText($modsTxt, $list)
if ($null -ne $json) { [System.IO.File]::WriteAllText($modsJson, $json) }

# Wax: everything in wax\runtime except what belongs to one machine (run, saved), the mods junction, and dev.txt,
# which marks a copy that must never update itself.
New-Item -ItemType Directory -Force $wax | Out-Null
$copied = @()
foreach ($item in Get-ChildItem -LiteralPath $runtime -Force) {
    if ($item.Name -in 'run', 'saved', 'mods', 'dev.txt') { continue }
    if ($item.Name -match '\.(before|failed)-') { throw "wax\runtime\$($item.Name) is left over from an update that Wax made to itself. It does not belong in a workspace." }
    if ($item.LinkType) { throw "wax\runtime\$($item.Name) is a link. Only real files go into a release." }
    Copy-Item -LiteralPath $item.FullName -Destination $wax -Recurse
    $copied += $item.Name
}
foreach ($folder in 'saved', 'run\in', 'run\out', 'mods\RecipeBrowser') { New-Item -ItemType Directory -Force (Join-Path $wax $folder) | Out-Null }
if (-not (Test-Path -LiteralPath (Join-Path $wax 'enabled.txt'))) { Set-Content -LiteralPath (Join-Path $wax 'enabled.txt') -Value '' }
[System.IO.File]::WriteAllText((Join-Path $wax 'VERSION'), "$version`r`n", [System.Text.Encoding]::ASCII)

# The mod that comes with Wax, without editor files that point into this workspace.
foreach ($item in Get-ChildItem -LiteralPath $bundled -Force | Where-Object { -not $_.Name.StartsWith('.') }) {
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $wax 'mods\RecipeBrowser') -Recurse
}
[System.IO.File]::WriteAllText((Join-Path $wax 'mods\RecipeBrowser\wax.origin'), "id=RecipeBrowser`r`nversion=$bundledVersion`r`n", [System.Text.Encoding]::ASCII)

$links = @(Get-ChildItem -LiteralPath $stage -Recurse -Force -Attributes ReparsePoint)
if ($links.Count) { throw "Links ended up in the release: $($links.FullName -join ', ')" }

# Text a player opens is plain ASCII with Windows line endings (Windows PowerShell 5.1 and Notepad both need that).
$fingerprint = Get-KeyFingerprint $key
function Copy-Text([string]$From, [string]$To) {
    $text = [System.IO.File]::ReadAllText($From)
    $text = ($text -replace "`r`n", "`n" -replace "`r", "`n").Replace('@VERSION@', $version).Replace('@FINGERPRINT@', $fingerprint).Replace("`n", "`r`n")
    $odd = [regex]::Match($text, '[^\x09\x0A\x0D\x20-\x7E]')
    if ($odd.Success) { throw "$From has a character that is not plain ASCII at position $($odd.Index): U+$('{0:X4}' -f [int][char]$odd.Value)" }
    [System.IO.File]::WriteAllText($To, $text, [System.Text.Encoding]::ASCII)
}
foreach ($name in 'Install Wax.cmd', 'Update Wax.cmd', 'Uninstall Wax.cmd', 'Wax-Setup.ps1', 'README.txt') {
    Copy-Text (Join-Path $payload $name) (Join-Path $stage $name)
}
if (-not (Get-Content -LiteralPath (Join-Path $stage 'README.txt') -Raw).Contains($fingerprint)) { throw 'README.txt does not give the fingerprint of the signing key.' }
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

# The installer program is not finished and not made to the rules the rest keeps. It only goes in when asked for, and such a zip is never signed.
if ($WithSetupProgram) {
    & (Join-Path $PSScriptRoot 'Build-WaxSetup.ps1') -Game $game
    Copy-Item -LiteralPath (Join-Path $BuildDir 'setup\Wax Setup.exe') -Destination (Join-Path $stage 'Wax Setup.exe')
}

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
        'game/ue4ss/Mods/Wax/bin/waxnet.dll', 'game/ue4ss/Mods/Wax/Scripts/wax/mods/update.lua',
        'game/ue4ss/Mods/Wax/Scripts/selfswap.lua', 'game/ue4ss/Mods/Wax/Scripts/wax/mods/selfupdate.lua',
        'game/ue4ss/Mods/Wax/mods/RecipeBrowser/init.lua', 'game/ue4ss/Mods/Wax/mods/RecipeBrowser/wax.origin',
        'game/ue4ss/Mods/Wax/saved/', 'game/ue4ss/Mods/Wax/run/in/',
        'game/ue4ss/Mods/Wax/run/out/'
    $missing = @($must | Where-Object { $_ -notin $names })
    if ($missing.Count) { throw "The zip is missing: $($missing -join ', ')" }
    $programs = @($names | Where-Object { $_ -match '\.(exe|com|scr|msi)$' })
    $allowed = $WithSetupProgram ? @('Wax Setup.exe') : @()
    if (($programs -join '|') -cne ($allowed -join '|')) { throw "The zip holds programs that do not belong in it: $($programs -join ', ')" }
    # A player's copy has to be free to update itself, so the mark of a development copy never goes out.
    if ('game/ue4ss/Mods/Wax/dev.txt' -in $names) { throw 'dev.txt ended up in the zip.' }
    $top = @($names | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
    $files = @($read.Entries | Where-Object { -not $_.FullName.EndsWith('/') }).Count
} finally {
    $read.Dispose()
}
if (-not $KeepStage) { Remove-Item -LiteralPath $stage -Recurse -Force }

Write-Host "Built $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 2)) MB, $files files, $($luaFiles.Count) Lua files compiled)"
Write-Host "Top level: $($top -join ', ')"
Write-Host "From wax\runtime: $($copied -join ', ')"
Write-Host "UE4SS mods switched off: $($cheatMods -join ', ')"

if ($WithSetupProgram) {
    Write-Host 'This zip holds "Wax Setup.exe", which is not finished. It is not signed, the release test fails on it, and Publish-Release.ps1 does not publish it.'
    return
}
if ($Unsigned) {
    Write-Host 'Not signed (-Unsigned). This zip is for trying out: no updater installs it, and Publish-Release.ps1 does not publish it.'
    Write-Host 'Test it with: .\wax\release\test\Test-WaxRelease.ps1'
    return
}

# The owner's tool signs. It reads the private key itself; this script never does.
$tool = Join-Path $Root 'wax\market\cli.mjs'
$unsignedNote = 'The zip is built, but it is not signed, so it cannot be published and no updater would install it.'
if (-not (Test-Path -LiteralPath $tool)) {
    throw "$unsignedNote The signing tool (wax\market\cli.mjs) is not in this copy of the source: only Wax's owner signs releases. To build a zip for trying out, run this with -Unsigned."
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "$unsignedNote node is not installed or not on PATH, and the signing tool needs it." }
$extension = (Get-Content (Join-Path $Root 'wax\vscode\package.json') -Raw | ConvertFrom-Json).version
$vsix = Join-Path $BuildDir "wax-icarus-$extension.vsix"
$released = @($zip) + @($vsix | Where-Object { Test-Path -LiteralPath $_ })
& node $tool sign-release @released --version $version --out $BuildDir
if ($LASTEXITCODE -ne 0) {
    throw "$unsignedNote The signing tool stopped, and its message is above. It needs the owner's key file (wax\market\.wax-signing-key.pem), which is on the owner's PC only."
}
Assert-ReleaseSigned -Version $version -Files $released -Manifest $manifest -Signature "$manifest.sig" -KeyHex $key
Write-Host "Signed: $manifest and $manifest.sig name $(($released | Split-Path -Leaf) -join ' and ')."
Write-Host "Key fingerprint: $fingerprint"
if ($released.Count -eq 1) {
    Write-Host "The extension ($(Split-Path $vsix -Leaf)) is not built, so the list does not name it. Publish-Release.ps1 needs it in the list:"
    Write-Host 'run Build-WaxExtension.ps1, then this script again.'
}
Write-Host 'Test it with: .\wax\release\test\Test-WaxRelease.ps1'
