# Adds a mod from the Wax catalogue to this game.
# The "Add to game" button on the Wax site opens a wax:// link, and Windows runs this script with it.
#   Wax-Import.ps1 wax://install/<ModId>     adds or updates that mod
#   Wax-Import.ps1 -Register                 makes Windows send wax:// links to this script
#   Wax-Import.ps1 -Unregister               undoes that
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Link = '',
    [switch]$Register,
    [switch]$Unregister,
    [string]$Server = 'https://wax-icarus.duckdns.org',
    [switch]$Quiet
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$GameProcess = 'Icarus-Win64-Shipping'
$ClassKey = 'HKCU:\Software\Classes\wax'
$MaxZip = 20MB
$MaxUnpacked = 40MB
$MaxEntries = 500
$Allowed = @('.lua', '.json', '.txt', '.md', '.png', '.jpg', '.jpeg', '.webp', '.ogg', '.wav', '.csv')

function Show-Message([string]$Text, [string]$Title = 'Wax', [bool]$Problem = $false) {
    if ($Quiet) { Write-Output $Text; return }
    Add-Type -AssemblyName System.Windows.Forms
    $icon = [System.Windows.Forms.MessageBoxIcon]::Information
    if ($Problem) { $icon = [System.Windows.Forms.MessageBoxIcon]::Warning }
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
}

function Stop-Import([string]$Text) { throw (New-Object System.ApplicationException $Text) }

if ($Register) {
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" "%1"' -f $shell, $PSCommandPath
    New-Item -Path "$ClassKey\shell\open\command" -Force | Out-Null
    Set-ItemProperty -Path $ClassKey -Name '(Default)' -Value 'URL:Wax mod link'
    Set-ItemProperty -Path $ClassKey -Name 'URL Protocol' -Value ''
    Set-ItemProperty -Path "$ClassKey\shell\open\command" -Name '(Default)' -Value $command
    Write-Output 'wax:// links now open this copy of Wax.'
    exit 0
}
if ($Unregister) {
    if (Test-Path $ClassKey) { Remove-Item -Path $ClassKey -Recurse -Force }
    Write-Output 'wax:// links are no longer handled.'
    exit 0
}

# Runs Lua in the running game through Wax's request folder. Returns $true when the game took it.
function Send-ToGame([string]$Lua) {
    if (-not (Get-Process -Name $GameProcess -ErrorAction SilentlyContinue)) { return $false }
    $in = Join-Path $PSScriptRoot 'run\in'
    if (-not (Test-Path -LiteralPath $in)) { return $false }
    $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $slot = $null
    foreach ($number in 0..7) {
        $claim = Join-Path $in "$number.claim"
        try {
            $stream = [System.IO.File]::Open($claim, [System.IO.FileMode]::CreateNew)
            $stream.Close()
            $slot = $number
            break
        } catch { }
    }
    if ($null -eq $slot) { return $false }
    try {
        $request = Join-Path $in "$slot.lua"
        [System.IO.File]::WriteAllText("$request.part", "--id:$id`n$Lua", (New-Object System.Text.UTF8Encoding $false))
        Move-Item -LiteralPath "$request.part" -Destination $request -Force
        [System.IO.File]::WriteAllText((Join-Path $in 'wake'), '')
        foreach ($wait in 1..150) {
            if (-not (Test-Path -LiteralPath $request)) { break }
            Start-Sleep -Milliseconds 20
        }
        $taken = -not (Test-Path -LiteralPath $request)
        if (-not $taken) { Remove-Item -LiteralPath $request -Force -ErrorAction SilentlyContinue }
        $reply = Join-Path $PSScriptRoot "run\out\$id.json"
        foreach ($wait in 1..50) {
            if (Test-Path -LiteralPath $reply) { Remove-Item -LiteralPath $reply -Force -ErrorAction SilentlyContinue; break }
            Start-Sleep -Milliseconds 20
        }
        return $taken
    } finally {
        Remove-Item -LiteralPath (Join-Path $in "$slot.claim") -Force -ErrorAction SilentlyContinue
    }
}

$temp = $null
try {
    # Only one shape of link is accepted, and the id is all that is taken from it.
    if ($Link -notmatch '^wax://install/([A-Za-z][A-Za-z0-9_]{0,63})/?$') {
        Stop-Import 'This is not a link to a Wax mod.'
    }
    $id = $Matches[1]
    $mods = Join-Path $PSScriptRoot 'mods'
    if (-not (Test-Path -LiteralPath $mods)) { Stop-Import "The mods folder is missing: $mods" }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $about = Invoke-RestMethod -Uri "$Server/api/mods/$id" -TimeoutSec 20
    $id = [string]$about.id
    if ($id -notmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$') { Stop-Import 'The catalogue answered with a name that cannot be used.' }
    $name = ([string]$about.name) -replace '[^\w \.\-]', ''
    $version = ([string]$about.latest.version) -replace '[^\w\.\-]', ''

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("wax-import-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $zip = Join-Path $temp 'mod.zip'
    $answer = Invoke-WebRequest -Uri "$Server/api/mods/$id/download" -OutFile $zip -PassThru -UseBasicParsing -TimeoutSec 120
    if ((Get-Item -LiteralPath $zip).Length -gt $MaxZip) { Stop-Import 'The download is larger than a mod may be.' }
    $expected = [string]$answer.Headers['X-Checksum-Sha256']
    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    if (-not $expected -or $expected.Trim().ToLower() -ne $actual.ToLower()) { Stop-Import 'The download does not match its checksum, so it was not used.' }

    # Every entry must sit under one folder named after the mod, and be a kind of file a mod is made of.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        if ($archive.Entries.Count -gt $MaxEntries) { Stop-Import 'The mod has more files than a mod may have.' }
        $total = 0
        $hasInit = $false
        foreach ($entry in $archive.Entries) {
            $path = $entry.FullName
            if ($path -match '\\' -or $path -match '(^|/)\.\.(/|$)' -or $path -match ':' -or $path.StartsWith('/')) { Stop-Import "The mod holds a path that is not allowed: $path" }
            if (-not $path.StartsWith("$id/")) { Stop-Import "The mod holds a file outside its own folder: $path" }
            if ($path.EndsWith('/')) { continue }
            $kind = [System.IO.Path]::GetExtension($path).ToLower()
            if ($Allowed -notcontains $kind) { Stop-Import "The mod holds a kind of file that is not allowed: $path" }
            $total += $entry.Length
            if ($path -eq "$id/init.lua") { $hasInit = $true }
        }
        if ($total -gt $MaxUnpacked) { Stop-Import 'The mod unpacks to more than a mod may be.' }
        if (-not $hasInit) { Stop-Import 'The mod has no init.lua.' }
    } finally {
        $archive.Dispose()
    }

    $unpacked = Join-Path $temp 'unpacked'
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $unpacked)
    $fresh = Join-Path $unpacked $id
    if (-not (Test-Path -LiteralPath (Join-Path $fresh 'init.lua'))) { Stop-Import 'The mod did not unpack as expected.' }

    # A copy that is already there is kept under another name, never erased.
    $target = Join-Path $mods $id
    $had = Test-Path -LiteralPath $target
    if ($had) {
        $kept = ".removed-$id-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Rename-Item -LiteralPath $target -NewName $kept
    }
    Copy-Item -LiteralPath $fresh -Destination $target -Recurse

    # Marks the folder as a mod from the catalogue, at this version. Wax in the game only updates folders that have this file.
    $installed = [string]$about.latest.version
    $named = [string]$answer.Headers['Content-Disposition']
    if ($named -match ('filename="' + [regex]::Escape($id) + '-([0-9A-Za-z][0-9A-Za-z._+-]{0,31})\.zip"')) { $installed = $Matches[1] }
    if ($installed -match '^[0-9A-Za-z][0-9A-Za-z._+-]{0,31}$') {
        [System.IO.File]::WriteAllText((Join-Path $target 'wax.origin'), "id=$id`r`nversion=$installed`r`n", [System.Text.Encoding]::ASCII)
    }

    $said = "$name $version was added."
    if ($had) { $said = "$name was updated to $version." }
    $lua = "Wax.mods.sync() Wax.mods.set_enabled('$id', true) Wax.mods.request_reload('$id') " +
           "if Wax.ui then Wax.ui.Notify('$said', { title = 'Mods', kind = 'good', seconds = 8 }) end return true"
    if (-not (Send-ToGame $lua)) {
        Show-Message "$said It will be in the Wax menu the next time you start ICARUS."
    }
} catch {
    $text = $_.Exception.Message
    if ($_.Exception -isnot [System.ApplicationException]) { $text = "The mod could not be added. $text" }
    Show-Message $text 'Wax' $true
    exit 1
} finally {
    if ($temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
