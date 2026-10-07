# Adds a mod from the Wax catalogue to this game.
# The "Add to game" button on the Wax site opens a wax:// link, and Windows runs this script with it.
#   Wax-Import.ps1 wax://install/<ModId>     asks first, then adds or updates that mod
#   Wax-Import.ps1 -Register                 makes Windows send wax:// links to this script
#   Wax-Import.ps1 -Unregister               undoes that
# It takes that one argument and nothing else. What it uses is fixed in the five lines below.

$Catalogue = 'https://wax-icarus.duckdns.org'  # the only address this script asks
$PublicKey = '8b37ac88ea0d9e8a8d239b731f1ba1d12fe163c605f6fe3c3933253e36421a953c5d04fdcb94e3934223e41aeb511593788140a7865c00ab2f6ad67746900d62'  # the catalogue owner's key
$Question  = 'ask'  # 'ask' puts the question to the player. A test's copy answers 'yes' or 'no' itself.
$ClassKey  = 'HKCU:\Software\Classes\wax'  # where Windows keeps what opens wax:// links
$LogFile   = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Wax\import.log'  # one line per run

$Given = @($args)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$GameProcess = 'Icarus-Win64-Shipping'
$IdRule = '[A-Za-z][A-Za-z0-9_]{0,63}'
$VersionRule = '[0-9A-Za-z][0-9A-Za-z._+-]{0,31}'
$Reserved = 'CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9]'
$MaxZip = 20MB
$MaxUnpacked = 40MB
$MaxEntries = 500
$Allowed = @('.lua', '.json', '.txt', '.md', '.png', '.jpg', '.jpeg', '.webp', '.ogg', '.wav', '.csv')
$Marks = @('wax.origin', 'wax.new')
$NotALink = 'This is not a link to a Wax mod. Nothing was downloaded and nothing was changed.'
$Damaged = 'The download is not a zip that can be read, so it was not used.'

# Text from outside, made safe to show: one line, nothing invisible, not too long.
function Get-PlainText([string]$Text, [int]$Most) {
    $plain = ([regex]::Replace($Text, '[\p{C}\p{Z}\s]+', ' ')).Trim()
    if ($plain.Length -gt $Most) { $plain = $plain.Substring(0, $Most).Trim() + '...' }
    return $plain
}

function Write-Log([string]$Id, [string]$What) {
    try {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($LogFile))
        if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 256KB) { Remove-Item -LiteralPath $LogFile -Force }
        $line = '{0}  {1}  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Id, ((Get-PlainText $What 300) -replace '[^\x20-\x7E]', '?')
        [System.IO.File]::AppendAllText($LogFile, "$line`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch { }
}

# 0x50000 puts the box in front of other windows, so it is not missed behind the browser.
function Show-Box([string]$Text, [string]$Buttons, [string]$Icon, [string]$Default) {
    Add-Type -AssemblyName System.Windows.Forms
    $front = [Enum]::ToObject([System.Windows.Forms.MessageBoxOptions], 0x50000)
    return [System.Windows.Forms.MessageBox]::Show($Text, 'Wax', [System.Windows.Forms.MessageBoxButtons]$Buttons,
        [System.Windows.Forms.MessageBoxIcon]$Icon, [System.Windows.Forms.MessageBoxDefaultButton]$Default, $front)
}

function Show-Message([string]$Text, [bool]$Problem = $false) {
    Write-Host $Text
    if ($Question -ne 'ask') { return }
    $icon = 'Information'
    if ($Problem) { $icon = 'Warning' }
    [void](Show-Box $Text 'OK' $icon 'Button1')
}

# Yes or No, with No as the answer that Enter gives.
function Confirm-Import([string]$Text) {
    Write-Host $Text
    if ($Question -ne 'ask') { Write-Host "Answered: $Question"; return ($Question -eq 'yes') }
    return ((Show-Box $Text 'YesNo' 'Question' 'Button2') -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Stop-Import([string]$Text) { throw (New-Object System.ApplicationException $Text) }

# What Windows runs for a wax:// link: this script in a window you can see, under the usual rule for local scripts.
function Get-LinkCommand {
    $shell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return '"{0}" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "{1}" "%1"' -f $shell, $PSCommandPath
}

# Asks the catalogue for one thing and stops reading at the limit.
function Read-Catalogue([string]$Path, [long]$Most, [string]$TooLarge, [string]$Stopped) {
    $request = [System.Net.WebRequest]::Create($Catalogue + $Path)
    $request.AllowAutoRedirect = $false
    $request.Timeout = 20000
    $request.ReadWriteTimeout = 20000
    $request.UserAgent = 'Wax-Import'
    $response = $null
    try {
        try { $response = $request.GetResponse() }
        catch {
            $failure = $_.Exception
            while ($failure -and $failure -isnot [System.Net.WebException]) { $failure = $failure.InnerException }
            if (-not $failure -or -not $failure.Response) { Stop-Import 'The Wax catalogue could not be reached. Check your internet connection and try again.' }
            $response = $failure.Response
        }
        $status = [int]$response.StatusCode
        if ($status -eq 404) { Stop-Import 'The Wax catalogue has no mod with that name.' }
        if ($status -ne 200) { Stop-Import "The Wax catalogue answered with error $status. Try again later." }
        if ($response.ContentLength -gt $Most) { Stop-Import $TooLarge }
        $kept = New-Object System.IO.MemoryStream
        $buffer = New-Object byte[] 65536
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $stream = $response.GetResponseStream()
            while ($true) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                if ($kept.Length + $read -gt $Most) { Stop-Import $Stopped }
                if ($clock.Elapsed.TotalSeconds -gt 180) { Stop-Import 'The download took too long and was stopped. Try again later.' }
                $kept.Write($buffer, 0, $read)
            }
        } catch {
            if ($_.Exception -is [System.ApplicationException]) { throw }
            Stop-Import 'The download did not finish. Check your internet connection and try again.'
        }
        return @{ Bytes = $kept.ToArray(); Signature = [string]$response.Headers['X-Wax-Signature'] }
    } finally {
        $request.Abort()
        if ($response) { $response.Close() }
    }
}

function Get-Field($From, [string]$Name) {
    if ($From -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $found = $From.PSObject.Properties[$Name]
    if ($found) { return $found.Value }
    return $null
}

# True when the text carries the owner's signature: ECDSA P-256 with SHA-256, r then s.
function Test-Signature([string]$Text, [string]$Signature) {
    if ($Signature -cnotmatch '\A[A-Za-z0-9+/]{85}[AQgw]==\z' -or $PublicKey -cnotmatch '\A[0-9a-f]{128}\z') { return $false }
    try {
        [byte[]]$blob = (0x45, 0x43, 0x53, 0x31, 32, 0, 0, 0) + (New-Object byte[] 64)
        for ($i = 0; $i -lt 64; $i++) { $blob[8 + $i] = [Convert]::ToByte($PublicKey.Substring($i * 2, 2), 16) }
        $key = [System.Security.Cryptography.CngKey]::Import($blob, [System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
        $checker = New-Object System.Security.Cryptography.ECDsaCng -ArgumentList $key
        $checker.HashAlgorithm = [System.Security.Cryptography.CngAlgorithm]::Sha256
        return [bool]$checker.VerifyData([System.Text.Encoding]::UTF8.GetBytes($Text), [Convert]::FromBase64String($Signature))
    } catch { return $false }
}

function Get-U16([byte[]]$From, [int]$At) { return [int][System.BitConverter]::ToUInt16($From, $At) }
function Get-U32([byte[]]$From, [int]$At) { return [long][System.BitConverter]::ToUInt32($From, $At) }

# Reads the zip's own list of files and holds every entry against the rules for a mod. Nothing is unpacked here.
function Get-ModEntries([byte[]]$Zip, [string]$Id) {
    $size = $Zip.Length
    $end = -1
    for ($at = $size - 22; $at -ge 0 -and $at -ge $size - 65557; $at--) {
        if ($Zip[$at] -eq 0x50 -and $Zip[$at + 1] -eq 0x4B -and $Zip[$at + 2] -eq 5 -and $Zip[$at + 3] -eq 6 -and
            ($at + 22 + (Get-U16 $Zip ($at + 20))) -eq $size) { $end = $at; break }
    }
    if ($end -lt 0) { Stop-Import $Damaged }
    $count = Get-U16 $Zip ($end + 10)
    $start = Get-U32 $Zip ($end + 16)
    if ((Get-U16 $Zip ($end + 4)) -ne 0 -or (Get-U16 $Zip ($end + 6)) -ne 0 -or (Get-U16 $Zip ($end + 8)) -ne $count) { Stop-Import $Damaged }
    if ($count -gt $MaxEntries) { Stop-Import 'The mod has more files than a mod may have.' }
    if ($start + (Get-U32 $Zip ($end + 12)) -ne $end) { Stop-Import $Damaged }

    $entries = New-Object System.Collections.ArrayList
    $seen = @{}
    $folders = @{}
    $declared = 0
    $hasInit = $false
    $at = [int]$start
    for ($i = 0; $i -lt $count; $i++) {
        if ($at + 46 -gt $end -or (Get-U32 $Zip $at) -ne 0x02014b50) { Stop-Import $Damaged }
        $flags = Get-U16 $Zip ($at + 8)
        $method = Get-U16 $Zip ($at + 10)
        $packed = Get-U32 $Zip ($at + 20)
        $length = Get-U32 $Zip ($at + 24)
        $nameLength = Get-U16 $Zip ($at + 28)
        $type = ((Get-U32 $Zip ($at + 38)) -shr 16) -band 0xF000
        $offset = Get-U32 $Zip ($at + 42)
        $next = $at + 46 + $nameLength + (Get-U16 $Zip ($at + 30)) + (Get-U16 $Zip ($at + 32))
        if ($next -gt $end -or (Get-U16 $Zip ($at + 34)) -ne 0) { Stop-Import $Damaged }

        $path = [System.Text.Encoding]::ASCII.GetString($Zip, $at + 46, $nameLength)
        $shown = Get-PlainText $path 80
        $isFolder = $path.EndsWith('/')
        $body = $path
        if ($isFolder) { $body = $path.Substring(0, $path.Length - 1) }
        $parts = @($body.Split('/'))
        if ($nameLength -eq 0 -or $nameLength -gt 240 -or $parts.Count -gt 16 -or $path.Contains('\') -or $path.Contains(':') -or $path.StartsWith('/')) {
            Stop-Import "The mod holds a path that is not allowed: $shown"
        }
        foreach ($part in $parts) {
            if ($part -eq '..' -or $part -cnotmatch '\A[A-Za-z0-9_. -]+\z' -or $part -match '\A | \z|\.\z') { Stop-Import "The mod holds a path that is not allowed: $shown" }
            if ($part -match "\A($Reserved) *(\.|\z)") { Stop-Import "The mod holds a name that Windows keeps for itself: $shown" }
            if ($Marks -ccontains $part.ToLowerInvariant()) { Stop-Import "The mod holds a name that Wax keeps for itself: $shown" }
        }
        if ($parts[0] -cne $Id) { Stop-Import "The mod holds a file outside its own folder: $shown" }
        if ($flags -band 0x2041) { Stop-Import "The mod holds a locked file, which is not allowed: $shown" }
        if ($method -ne 0 -and $method -ne 8) { Stop-Import "The mod holds a file packed in a way that is not allowed: $shown" }
        if ($type -ne 0 -and $type -ne 0x8000 -and $type -ne 0x4000) { Stop-Import "The mod holds a link, which is not allowed: $shown" }
        if ($packed -ge 4294967295 -or $length -ge 4294967295 -or $offset -ge 4294967295) { Stop-Import $Damaged }

        $key = $body.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { Stop-Import "The mod holds the same path twice: $shown" }
        $seen[$key] = $isFolder
        for ($depth = 1; $depth -lt $parts.Count; $depth++) { $folders[($parts[0..($depth - 1)] -join '/').ToLowerInvariant()] = $true }
        if ($isFolder) {
            if ($length -ne 0) { Stop-Import $Damaged }
        } else {
            if ($Allowed -notcontains [System.IO.Path]::GetExtension($parts[-1]).ToLowerInvariant()) { Stop-Import "The mod holds a kind of file that is not allowed: $shown" }
            $declared += $length
            if ($declared -gt $MaxUnpacked) { Stop-Import 'The mod unpacks to more than a mod may be, so it was not unpacked.' }
            if ($path -ceq "$Id/init.lua") { $hasInit = $true }
        }

        if ($offset + 30 -gt $start) { Stop-Import $Damaged }
        $head = [int]$offset
        $localName = Get-U16 $Zip ($head + 26)
        $data = $head + 30 + $localName + (Get-U16 $Zip ($head + 28))
        if ($data + $packed -gt $start -or (Get-U32 $Zip $head) -ne 0x04034b50 -or $localName -ne $nameLength -or
            [System.Text.Encoding]::ASCII.GetString($Zip, $head + 30, $localName) -cne $path -or
            (Get-U16 $Zip ($head + 8)) -ne $method -or ((Get-U16 $Zip ($head + 6)) -band 0x2041)) { Stop-Import $Damaged }

        [void]$entries.Add(@{ Path = $path; Folder = $isFolder; Method = $method; Start = $data; Packed = [int]$packed; Length = $length })
        $at = [int]$next
    }
    if ($at -ne $end) { Stop-Import $Damaged }
    foreach ($key in $seen.Keys) {
        if (-not $seen[$key] -and $folders.ContainsKey($key)) { Stop-Import "The mod holds one name as a file and as a folder: $(Get-PlainText $key 80)" }
    }
    if (-not $hasInit) { Stop-Import 'The mod has no init.lua.' }
    return $entries.ToArray()
}

function New-Folder([string]$Path, $Made) {
    if ([System.IO.Directory]::Exists($Path)) { return }
    New-Folder ([System.IO.Path]::GetDirectoryName($Path)) $Made
    [void][System.IO.Directory]::CreateDirectory($Path)
    [void]$Made.Add($Path)
}

# Unpacks into a folder made for it, counting what is really written. Everything it makes is noted in $Made.
function Expand-Mod([byte[]]$Zip, $Entries, [string]$Id, [string]$Folder, $Made) {
    $root = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\') + '\'
    $buffer = New-Object byte[] 65536
    $written = 0
    foreach ($entry in $Entries) {
        $inside = $entry.Path.Substring($Id.Length + 1).TrimEnd('/').Replace('/', '\')
        if ($inside -eq '') { continue }
        if ($root.Length + $inside.Length -gt 240) { Stop-Import 'The mod holds a path that is too long for the folder your game is in.' }
        $target = [System.IO.Path]::GetFullPath($root + $inside)
        if (-not $target.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { Stop-Import "The mod holds a path that is not allowed: $(Get-PlainText $entry.Path 80)" }
        if ($entry.Folder) { New-Folder $target $Made; continue }
        New-Folder ([System.IO.Path]::GetDirectoryName($target)) $Made

        $source = New-Object System.IO.MemoryStream -ArgumentList $Zip, $entry.Start, $entry.Packed, $false
        if ($entry.Method -eq 8) { $source = New-Object System.IO.Compression.DeflateStream -ArgumentList $source, ([System.IO.Compression.CompressionMode]::Decompress) }
        $file = [System.IO.File]::Open($target, [System.IO.FileMode]::CreateNew)
        [void]$Made.Add($target)
        $size = 0
        try {
            while ($true) {
                $read = $source.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $size += $read
                $written += $read
                if ($written -gt $MaxUnpacked) { Stop-Import 'The mod unpacks to more than a mod may be, so it was stopped.' }
                $file.Write($buffer, 0, $read)
            }
        } catch {
            if ($_.Exception -is [System.ApplicationException]) { throw }
            Stop-Import 'A file in the mod could not be unpacked, so nothing was added.'
        } finally {
            $file.Dispose()
            $source.Dispose()
        }
        if ($size -ne $entry.Length) { Stop-Import 'A file in the mod does not unpack to the size it gives, so nothing was added.' }
    }
}

# Takes away exactly what Expand-Mod made, newest first, and never follows a link.
function Remove-Made($Made) {
    for ($i = $Made.Count - 1; $i -ge 0; $i--) {
        try {
            if ([System.IO.File]::Exists($Made[$i])) { [System.IO.File]::Delete($Made[$i]) }
            elseif ([System.IO.Directory]::Exists($Made[$i])) { [System.IO.Directory]::Delete($Made[$i], $false) }
        } catch { }
    }
    $Made.Clear()
}

# The version of a mod that is already in the mods folder, when its files say.
function Get-HeldVersion([string]$Folder) {
    foreach ($place in @(@('wax.origin', '(?m)^version=([^\r\n]+)'), @('mod.lua', '(?m)^\s*version\s*=\s*["'']([^"''\r\n]+)["'']'))) {
        try {
            $file = Join-Path $Folder $place[0]
            if ((Test-Path -LiteralPath $file -PathType Leaf) -and (Get-Item -LiteralPath $file).Length -lt 65536 -and
                [System.IO.File]::ReadAllText($file) -match $place[1]) { return (Get-PlainText $Matches[1] 32) }
        } catch { }
    }
    return ''
}

# Tells the running game that a mod was added, as a command it knows. Returns $true when the game took it.
function Send-ToGame([string]$Id) {
    if (-not (Get-Process -Name $GameProcess -ErrorAction SilentlyContinue)) { return $false }
    $in = Join-Path $PSScriptRoot 'run\in'
    if (-not (Test-Path -LiteralPath $in -PathType Container)) { return $false }
    $request = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $slot = $null
    foreach ($number in 0..7) {
        $claim = Join-Path $in "$number.claim"
        try {
            if ((Test-Path -LiteralPath $claim) -and ((Get-Date) - (Get-Item -LiteralPath $claim).LastWriteTime).TotalSeconds -gt 60) { Remove-Item -LiteralPath $claim -Force }
            $stream = [System.IO.File]::Open($claim, [System.IO.FileMode]::CreateNew)
            $stream.Close()
            $slot = $number
            break
        } catch { }
    }
    if ($null -eq $slot) { return $false }
    $file = Join-Path $in "$slot.lua"
    try {
        [System.IO.File]::WriteAllText("$file.part", "--id:$request`n--wax:mod-added`nid=$Id`n", (New-Object System.Text.UTF8Encoding $false))
        if ([System.IO.File]::Exists($file)) { [System.IO.File]::Delete($file) }
        [System.IO.File]::Move("$file.part", $file)
        [System.IO.File]::WriteAllText((Join-Path $in 'wake'), '')
        foreach ($wait in 1..150) {
            if (-not (Test-Path -LiteralPath $file)) { break }
            Start-Sleep -Milliseconds 20
        }
        if (Test-Path -LiteralPath $file) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            return $false
        }
        $reply = Join-Path $PSScriptRoot "run\out\$request.json"
        $answer = ''
        foreach ($wait in 1..100) {
            if (Test-Path -LiteralPath $reply) {
                try { $answer = [System.IO.File]::ReadAllText($reply) } catch { }
                Remove-Item -LiteralPath $reply -Force -ErrorAction SilentlyContinue
                break
            }
            Start-Sleep -Milliseconds 20
        }
        return ($answer -match '"ok"\s*:\s*true')
    } finally {
        Remove-Item -LiteralPath "$file.part" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $in "$slot.claim") -Force -ErrorAction SilentlyContinue
    }
}

if ($Given.Count -ne 1 -or $Given[0] -isnot [string]) {
    Write-Log '-' "refused: $($Given.Count) arguments where one link is expected"
    Show-Message $NotALink $true
    exit 1
}
$only = $Given[0]

if ($only -eq '-Register') {
    New-Item -Path "$ClassKey\shell\open\command" -Force | Out-Null
    Set-ItemProperty -Path $ClassKey -Name '(Default)' -Value 'URL:Wax mod link'
    Set-ItemProperty -Path $ClassKey -Name 'URL Protocol' -Value ''
    Set-ItemProperty -Path "$ClassKey\shell\open\command" -Name '(Default)' -Value (Get-LinkCommand)
    Write-Log '-' 'wax:// links were registered to this copy of Wax'
    Write-Output 'wax:// links now open this copy of Wax.'
    exit 0
}
if ($only -eq '-Unregister') {
    if (Test-Path $ClassKey) { Remove-Item -Path $ClassKey -Recurse -Force }
    Write-Log '-' 'the registration of wax:// links was removed'
    Write-Output 'wax:// links are no longer handled.'
    exit 0
}
$id = ''
if ($only -cmatch "\Awax://install/($IdRule)\z") { $id = $Matches[1] }
if ($id -eq '' -or $id -match "\A($Reserved)\z") {
    Write-Log '-' ('refused: not a link to a Wax mod: ' + (Get-PlainText $only 80))
    Show-Message $NotALink $true
    exit 1
}

$made = New-Object System.Collections.ArrayList
$code = 1
try {
    $mods = Join-Path $PSScriptRoot 'mods'
    if (-not (Test-Path -LiteralPath $mods -PathType Container)) { Stop-Import 'The mods folder of Wax is missing, so the mod cannot be added. Install Wax again to put it back.' }

    # An older Wax registered the link with a hidden window and with the script rules skipped. That is put right here.
    try {
        $registered = [string](Get-ItemProperty -Path "$ClassKey\shell\open\command" -ErrorAction Stop).'(default)'
        if ($registered -match 'WindowStyle\s+Hidden|ExecutionPolicy\s+Bypass' -and $registered.IndexOf($PSCommandPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Set-ItemProperty -Path "$ClassKey\shell\open\command" -Name '(Default)' -Value (Get-LinkCommand)
        }
    } catch { }
    try { $Host.UI.RawUI.WindowTitle = 'Wax' } catch { }
    Write-Host 'Wax is looking this mod up in its catalogue. This window closes by itself.'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $unusable = 'The Wax catalogue gave an answer that cannot be used, so nothing was added.'
    $entry = Read-Catalogue "/api/mods/$id" 1MB $unusable $unusable
    $about = $null
    try { $about = ConvertFrom-Json -InputObject ([System.Text.Encoding]::UTF8.GetString($entry.Bytes)) } catch { }
    $listed = Get-Field $about 'id'
    if ($listed -isnot [string] -or $listed -cnotmatch "\A$IdRule\z" -or -not $listed.Equals($id, [System.StringComparison]::OrdinalIgnoreCase)) { Stop-Import $unusable }
    $id = $listed
    $latest = Get-Field $about 'latest'
    if ($null -eq $latest) { Stop-Import 'The Wax catalogue has no version of this mod yet.' }
    $version = Get-Field $latest 'version'
    if ($version -isnot [string] -or $version -cnotmatch "\A$VersionRule\z") { Stop-Import $unusable }
    $name = Get-PlainText ([string](Get-Field $about 'name')) 60
    if ($name -eq '') { $name = $id }
    $author = Get-PlainText ([string](Get-Field $about 'author')) 40
    if ($author -eq '') { $author = 'not given' }

    $target = Join-Path $mods $id
    $had = Test-Path -LiteralPath $target
    $mark = Join-Path $target 'wax.new'
    $off = (-not $had) -or (Test-Path -LiteralPath $mark -PathType Leaf)
    $from = "It comes from the Wax catalogue at $(([uri]$Catalogue).Host). A mod is code that runs in your game, and it can do whatever a program on this PC can do."
    $facts = "Name: $name`nVersion: $version`nAuthor: $author"
    $state = 'It stays switched on or off as it is now.'
    if ($off) { $state = 'It stays switched off until you switch it on in the Wax menu.' }
    if ($had) {
        $held = Get-HeldVersion $target
        $swap = "This replaces the copy you have with version $version."
        if ($held -eq $version) { $swap = "This replaces version $held, which you have, with a new copy of the same version." }
        elseif ($held -ne '') { $swap = "This replaces version $held, which you have, with version $version." }
        $asked = "Replace this mod in ICARUS?`n`n$facts`n`n$swap The old copy is kept in the mods folder under another name.`n`n$from`n`n$state"
    } else {
        $asked = "Add this mod to ICARUS?`n`n$facts`n`n$from`n`n$state"
    }
    if (-not (Confirm-Import $asked)) {
        Write-Log $id "the player said no to version $version"
        Write-Host 'Nothing was added.'
        exit 0
    }

    Write-Host 'Downloading the mod.'
    $large = 'The download is larger than a mod may be, so it was'
    $answer = Read-Catalogue "/api/mods/$id/download/$version" $MaxZip "$large not started." "$large stopped."
    $zip = $answer.Bytes
    if ($answer.Signature -eq '') { Stop-Import 'This download carries no signature of the Wax catalogue, so it was not used. Nothing was added to your game.' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $sum = ([System.BitConverter]::ToString($sha.ComputeHash($zip)) -replace '-', '').ToLowerInvariant()
    $sha.Dispose()
    if (-not (Test-Signature "zip $id $version`n$sum $($zip.Length)`n" $answer.Signature)) {
        Stop-Import 'The signature on this download does not fit it, so it was not used. Nothing was added to your game.'
    }

    $entries = @(Get-ModEntries $zip $id)
    $staging = Join-Path $mods (".adding-$id-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][System.IO.Directory]::CreateDirectory($staging)
    [void]$made.Add($staging)
    Expand-Mod $zip $entries $id $staging $made
    $origin = Join-Path $staging 'wax.origin'
    [System.IO.File]::WriteAllText($origin, "id=$id`r`nversion=$version`r`n", [System.Text.Encoding]::ASCII)
    [void]$made.Add($origin)
    # A mod the player did not have, or has not switched on yet, gets wax.new: the game holds such a mod switched off.
    if ($off -or -not (Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath $mark -PathType Leaf)) {
        $off = $true
        [System.IO.File]::WriteAllText((Join-Path $staging 'wax.new'), "new`r`n", [System.Text.Encoding]::ASCII)
        [void]$made.Add((Join-Path $staging 'wax.new'))
    }

    # A copy that is already there is kept under another name, never erased.
    $kept = ''
    if (Test-Path -LiteralPath $target) {
        $kept = ".removed-$id-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        for ($n = 2; Test-Path -LiteralPath (Join-Path $mods $kept); $n++) { $kept = ".removed-$id-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$n" }
        Rename-Item -LiteralPath $target -NewName $kept
    }
    try { Rename-Item -LiteralPath $staging -NewName $id }
    catch {
        if ($kept -ne '') { Rename-Item -LiteralPath (Join-Path $mods $kept) -NewName $id }
        throw
    }
    $made.Clear()

    $told = $false
    try { $told = Send-ToGame $id } catch { }
    if ($kept -ne '') {
        $said = "$name was updated to version $version, and the copy you had is kept in the mods folder."
        if ($off) { $said += ' It stays switched off until you switch it on in the Wax menu.' }
        elseif ($told) { $said += ' It is switched on or off as it was.' }
        else { $said += ' The next time you start ICARUS it is switched on or off as it was.' }
        Write-Log $id "updated to $version, $(if ($off) { 'still marked as new, ' })the copy before is kept as $kept, the game was $(if ($told) { 'told' } else { 'not told' })"
    } else {
        $said = "$name $version was added."
        if ($told) { $said += ' It is on the Mods page of the Wax menu, switched off until you switch it on there.' }
        else { $said += ' It will be listed in the Wax menu, switched off, the next time you start ICARUS.' }
        Write-Log $id "added $version, the game was $(if ($told) { 'told' } else { 'not told' })"
    }
    Show-Message $said
    $code = 0
} catch {
    $text = $_.Exception.Message
    if ($_.Exception -isnot [System.ApplicationException]) { $text = "The mod could not be added. $(Get-PlainText $text 200)" }
    Write-Log $id "not added: $text"
    Show-Message $text $true
} finally {
    Remove-Made $made
}
exit $code
