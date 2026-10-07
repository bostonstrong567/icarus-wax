[CmdletBinding()]
param(
    [ValidateSet('Install', 'Update', 'Uninstall')]
    [string]$Action = 'Install',
    [string]$GameDir = '',
    [string]$SteamRoot = '',
    [string]$ReleaseApi = '',
    [ValidateSet('Ask', 'Yes', 'No')]
    [string]$RemoveUE4SS = 'Ask',
    [ValidateSet('Ask', 'Yes', 'No')]
    [string]$RemoveMyFiles = 'Ask'
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$AppId = '1149460'
$GameExe = 'Icarus-Win64-Shipping.exe'
$GameProcess = 'Icarus-Win64-Shipping'
$Repo = 'bostonstrong567/icarus-wax'
$DocsUrl = 'https://wax-icarus.duckdns.org/'
$ReleasePage = "https://github.com/$Repo/releases/latest"
$DefaultApi = "https://api.github.com/repos/$Repo/releases/latest"
$Package = [System.IO.Path]::Combine($PSScriptRoot, 'game')
$WaxPath = 'ue4ss\Mods\Wax'
$Mine = @('mods', 'saved')
$KeptSettings = @(
    'ue4ss\UE4SS-settings.ini',
    'ue4ss\Mods\mods.txt',
    'ue4ss\Mods\mods.json',
    'ue4ss\Mods\BPModLoaderMod\load_order.txt'
)
$StockMods = @(
    'BPML_GenericFunctions', 'BPModLoaderMod', 'CheatManagerEnablerMod', 'ConsoleCommandsMod',
    'ConsoleEnablerMod', 'Keybinds', 'LineTraceMod', 'SplitScreenMod', 'shared'
)

function Combine([string]$Left, [string]$Right) { return [System.IO.Path]::Combine($Left, $Right) }
function Test-File([string]$Path) { return [System.IO.File]::Exists($Path) }
function Test-Folder([string]$Path) { return [System.IO.Directory]::Exists($Path) }
function Stop-Setup([string]$Message) { throw (New-Object System.ApplicationException $Message) }

function Test-Link([string]$Path) {
    if (-not (Test-Folder $Path)) { return $false }
    $attributes = (New-Object System.IO.DirectoryInfo $Path).Attributes
    return [bool]($attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

# A link is removed as a link. What it points to is never touched.
function Remove-Tree([string]$Path) {
    $item = $null
    if (Test-Folder $Path) { $item = New-Object System.IO.DirectoryInfo $Path }
    elseif (Test-File $Path) { $item = New-Object System.IO.FileInfo $Path }
    else { return }
    $link = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    if (-not $link -and ($item.Attributes -band [System.IO.FileAttributes]::ReadOnly)) {
        $item.Attributes = $item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
    }
    if ($item -is [System.IO.DirectoryInfo]) {
        if (-not $link) {
            foreach ($child in $item.GetFileSystemInfos()) { Remove-Tree $child.FullName }
        }
        [System.IO.Directory]::Delete($Path)
    } else {
        [System.IO.File]::Delete($Path)
    }
}

function Copy-File([string]$From, [string]$To) {
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($To))
    if (Test-File $To) { [System.IO.File]::SetAttributes($To, [System.IO.FileAttributes]::Normal) }
    [System.IO.File]::Copy($From, $To, $true)
}

function Copy-Tree([string]$From, [string]$To) {
    if (Test-File $From) { Copy-File $From $To; return }
    [void][System.IO.Directory]::CreateDirectory($To)
    foreach ($child in (New-Object System.IO.DirectoryInfo $From).GetFileSystemInfos()) {
        Copy-Tree $child.FullName (Combine $To $child.Name)
    }
}

function Test-Same([string]$Left, [string]$Right) {
    if (-not (Test-File $Left) -or -not (Test-File $Right)) { return $false }
    if ((New-Object System.IO.FileInfo $Left).Length -ne (New-Object System.IO.FileInfo $Right).Length) { return $false }
    $a = (Get-FileHash -LiteralPath $Left -Algorithm SHA256).Hash
    $b = (Get-FileHash -LiteralPath $Right -Algorithm SHA256).Hash
    return $a -eq $b
}

function Test-Empty([string]$Folder) {
    if (-not (Test-Folder $Folder)) { return $true }
    return @((New-Object System.IO.DirectoryInfo $Folder).GetFileSystemInfos()).Count -eq 0
}

function Remove-IfEmpty([string]$Folder) {
    if ((Test-Folder $Folder) -and -not (Test-Link $Folder) -and (Test-Empty $Folder)) { Remove-Tree $Folder }
}

function Read-Version([string]$File) {
    if (-not (Test-File $File)) { return $null }
    $text = [System.IO.File]::ReadAllText($File).Trim()
    if ($text) { return $text }
    return $null
}

function Get-InstalledVersion([string]$Wax) {
    if (-not (Test-File (Combine $Wax 'Scripts\main.lua'))) { return $null }
    $version = Read-Version (Combine $Wax 'VERSION')
    if ($version) { return $version }
    return '0'
}

function Test-Newer([string]$Candidate, [string]$Current) {
    $a = [regex]::Matches($Candidate, '\d+')
    $b = [regex]::Matches($Current, '\d+')
    for ($i = 0; $i -lt 3; $i++) {
        $left = 0
        $right = 0
        if ($i -lt $a.Count) { $left = [int]$a[$i].Value }
        if ($i -lt $b.Count) { $right = [int]$b[$i].Value }
        if ($left -ne $right) { return $left -gt $right }
    }
    return $false
}

# Takes the game folder, Icarus\Icarus, Binaries\Win64 or the exe, and returns the Win64 folder.
function Get-Win64([string]$Path) {
    if (-not $Path) { return $null }
    $folder = $Path.Trim().Trim('"').Trim()
    if (-not $folder) { return $null }
    try {
        if (Test-File $folder) { $folder = [System.IO.Path]::GetDirectoryName($folder) }
        foreach ($tail in '', 'Binaries\Win64', 'Icarus\Binaries\Win64') {
            $candidate = $folder
            if ($tail) { $candidate = Combine $folder $tail }
            if (Test-File (Combine $candidate $GameExe)) {
                return [System.IO.Path]::GetFullPath($candidate).TrimEnd('\')
            }
        }
    } catch { }
    return $null
}

function Get-SteamRoots {
    if ($SteamRoot) { return @($SteamRoot) }
    $roots = @()
    $keys = 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam'
    foreach ($key in $keys) {
        $values = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $values) { continue }
        foreach ($name in 'SteamPath', 'InstallPath') {
            $value = $values.PSObject.Properties[$name]
            if ($value -and $value.Value) { $roots += ([string]$value.Value).Replace('/', '\') }
        }
    }
    return $roots
}

function Get-SteamLibraries {
    $all = @()
    foreach ($root in @(Get-SteamRoots)) {
        $all += $root
        foreach ($list in 'steamapps\libraryfolders.vdf', 'config\libraryfolders.vdf') {
            $file = Combine $root $list
            if (-not (Test-File $file)) { continue }
            foreach ($line in [System.IO.File]::ReadAllLines($file)) {
                if ($line -notmatch '^\s*"(path|\d+)"\s+"(.+)"\s*$') { continue }
                $value = $Matches[2].Replace('\\', '\')
                if ($Matches[1] -eq 'path' -or $value -match '[\\/:]') { $all += $value }
            }
        }
    }
    $seen = @{}
    $libraries = @()
    foreach ($library in $all) {
        $clean = $library.TrimEnd('\')
        $key = $clean.ToLowerInvariant()
        if ($clean -and -not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $libraries += $clean
        }
    }
    return $libraries
}

function Find-GameInSteam {
    foreach ($library in @(Get-SteamLibraries)) {
        $manifest = Combine $library "steamapps\appmanifest_$AppId.acf"
        if (-not (Test-File $manifest)) { continue }
        $folder = 'Icarus'
        if ([System.IO.File]::ReadAllText($manifest) -match '"installdir"\s+"([^"]+)"') { $folder = $Matches[1] }
        $win64 = Get-Win64 (Combine $library ('steamapps\common\' + $folder))
        if ($win64) { return $win64 }
    }
    return $null
}

function Find-Game {
    if ($GameDir) {
        $win64 = Get-Win64 $GameDir
        if (-not $win64) { Stop-Setup "ICARUS is not in this folder: $GameDir`r`nThe folder to give is the one Steam opens with Manage, Browse local files." }
        return $win64
    }
    $win64 = Find-GameInSteam
    if ($win64) { return $win64 }
    Write-Host 'Steam did not say where ICARUS is installed.'
    Write-Host 'In Steam, right-click ICARUS, choose Manage, then Browse local files.'
    Write-Host 'Copy the folder path from the top of that window and paste it here.'
    while ($true) {
        $answer = Read-Host 'ICARUS folder (leave empty to stop)'
        if (-not $answer -or -not $answer.Trim()) { Stop-Setup 'Stopped. Nothing was changed.' }
        $win64 = Get-Win64 $answer
        if ($win64) { return $win64 }
        Write-Host "$GameExe is not under that folder. Try again."
    }
}

function Test-Locked([string]$File) {
    if (-not (Test-File $File)) { return $false }
    try {
        $stream = [System.IO.File]::Open($File, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $stream.Close()
        return $false
    } catch {
        $problem = $_.Exception
        while ($problem.InnerException) { $problem = $problem.InnerException }
        return ($problem -is [System.IO.IOException])
    }
}

function Assert-GameClosed([string]$Win64) {
    $exe = Combine $Win64 $GameExe
    foreach ($process in @(Get-Process -Name $GameProcess -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $process.Path } catch { }
        if (-not $path -or [string]::Equals($path, $exe, [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-Setup 'ICARUS is running. Close the game, then run this again.'
        }
    }
    foreach ($name in 'dwmapi.dll', 'ue4ss\UE4SS.dll', "$WaxPath\bin\waxco.dll", "$WaxPath\bin\waxnet.dll") {
        if (Test-Locked (Combine $Win64 $name)) {
            Stop-Setup "$name is in use, so the game is probably still running. Close the game, then run this again."
        }
    }
}

function Read-YesNo([string]$Question, [string]$Preset) {
    if ($Preset -eq 'Yes') { return $true }
    if ($Preset -eq 'No') { return $false }
    $answer = Read-Host "$Question Type y and press Enter for yes. Press Enter alone for no"
    return [bool]($answer -match '^\s*y(es)?\s*$')
}

# The "Add to game" button on the Wax site opens a wax:// link. This tells Windows to hand such links to Wax.
function Register-ModLinks([string]$Helper) {
    if ($env:WAX_SETUP_NO_LINKS -or -not (Test-File $Helper)) { return }
    try {
        $key = 'HKCU:\Software\Classes\wax'
        $shell = Combine $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $command = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" "%1"' -f $shell, $Helper
        New-Item -Path "$key\shell\open\command" -Force | Out-Null
        Set-ItemProperty -Path $key -Name '(Default)' -Value 'URL:Wax mod link'
        Set-ItemProperty -Path $key -Name 'URL Protocol' -Value ''
        Set-ItemProperty -Path "$key\shell\open\command" -Name '(Default)' -Value $command
        Write-Host 'The "Add to game" button on the Wax site now works on this PC.'
    } catch {
        Write-Host 'The "Add to game" button on the Wax site could not be set up. Downloading a mod as a zip still works.'
    }
}

function Unregister-ModLinks {
    if ($env:WAX_SETUP_NO_LINKS) { return }
    try {
        $key = 'HKCU:\Software\Classes\wax'
        if (Test-Path $key) { Remove-Item -Path $key -Recurse -Force }
    } catch { }
}

function Install-Wax {
    foreach ($needed in 'dwmapi.dll', 'ue4ss\UE4SS.dll', "$WaxPath\Scripts\main.lua") {
        if (-not (Test-File (Combine $Package $needed))) {
            Stop-Setup 'The "game" folder next to this script is missing or not complete. Extract the whole zip, then run this again.'
        }
    }
    $win64 = Find-Game
    Write-Host 'ICARUS is in:'
    Write-Host "  $win64"
    Assert-GameClosed $win64

    $wax = Combine $win64 $WaxPath
    if (Test-Link $wax) {
        Stop-Setup "This is a link to another folder, not a real folder:`r`n  $wax`r`nRemove the link, then run this again."
    }
    $packageWax = Combine $Package $WaxPath
    $before = Get-InstalledVersion $wax
    $version = Read-Version (Combine $packageWax 'VERSION')
    $hadMods = Test-Folder (Combine $wax 'mods')
    $hadMine = -not ((Test-Empty (Combine $wax 'mods')) -and (Test-Empty (Combine $wax 'saved')))

    $hadUE4SS = (Test-File (Combine $win64 'dwmapi.dll')) -or (Test-File (Combine $win64 'ue4ss\UE4SS.dll'))
    $sameUE4SS = (Test-Same (Combine $Package 'dwmapi.dll') (Combine $win64 'dwmapi.dll')) -and
        (Test-Same (Combine $Package 'ue4ss\UE4SS.dll') (Combine $win64 'ue4ss\UE4SS.dll'))
    $oldLayout = Test-File (Combine $win64 'UE4SS.dll')
    $backup = Combine $win64 ('ue4ss-backup-' + (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    $backedUp = 0
    $kept = @()
    $waxFiles = $packageWax + '\'
    foreach ($file in [System.IO.Directory]::GetFiles($Package, '*', [System.IO.SearchOption]::AllDirectories)) {
        if ($file.StartsWith($waxFiles, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative = $file.Substring($Package.Length + 1)
        $target = Combine $win64 $relative
        if (Test-File $target) {
            if (Test-Same $file $target) { continue }
            if ($sameUE4SS -and ($KeptSettings -contains $relative)) {
                $kept += [System.IO.Path]::GetFileName($relative)
                continue
            }
            Copy-File $target (Combine $backup $relative)
            $backedUp++
        }
        Copy-File $file $target
    }

    [void][System.IO.Directory]::CreateDirectory($wax)
    foreach ($item in (New-Object System.IO.DirectoryInfo $wax).GetFileSystemInfos()) {
        if ($Mine -contains $item.Name -or $item.Name -eq 'run') { continue }
        Remove-Tree $item.FullName
    }
    foreach ($item in (New-Object System.IO.DirectoryInfo $packageWax).GetFileSystemInfos()) {
        if ($Mine -contains $item.Name -or $item.Name -eq 'run') { continue }
        Copy-Tree $item.FullName (Combine $wax $item.Name)
    }
    foreach ($folder in 'saved', 'run\in', 'run\out') {
        [void][System.IO.Directory]::CreateDirectory((Combine $wax $folder))
    }
    if (-not $hadMods) {
        if (Test-Folder (Combine $packageWax 'mods')) { Copy-Tree (Combine $packageWax 'mods') (Combine $wax 'mods') }
        else { [void][System.IO.Directory]::CreateDirectory((Combine $wax 'mods')) }
    }

    Write-Host ''
    if (-not $before) { Write-Host "Wax $version is installed." }
    elseif ($before -eq '0') { Write-Host "Wax $version replaced the copy that was there." }
    elseif ($before -eq $version) { Write-Host "Wax $version was installed again." }
    else { Write-Host "Wax was updated from $before to $version." }
    if ($hadMine) { Write-Host 'Your mods and settings were kept.' }
    Register-ModLinks (Combine $wax 'Wax-Import.ps1')
    if ($backedUp -gt 0) {
        Write-Host ''
        if ($hadUE4SS -and -not $sameUE4SS) { Write-Host 'A different UE4SS was already in the game folder.' }
        else { Write-Host 'Some UE4SS files in the game folder had been changed.' }
        Write-Host 'The old files were copied here before they were replaced:'
        Write-Host "  $backup"
    }
    if ($kept.Count -gt 0) {
        Write-Host ''
        Write-Host ('Your own UE4SS settings were kept: ' + ($kept -join ', '))
    }
    if ($oldLayout) {
        Write-Host ''
        Write-Host 'An older UE4SS is also in the game folder (UE4SS.dll next to the game exe).'
        Write-Host 'It is not loaded any more. Mods in its Mods folder only run after you move them to ue4ss\Mods.'
    }
    Write-Host ''
    Write-Host 'Next:'
    Write-Host '  1. Start ICARUS.'
    Write-Host '  2. Press F8 in the game to open the Wax menu.'
    Write-Host '  3. Put your mods in this folder, one folder per mod. Recipe Browser is there already.'
    Write-Host ('       ' + (Combine $wax 'mods'))
    Write-Host ''
    Write-Host "Docs: $DocsUrl"
}

function Get-LatestRelease([System.Net.WebClient]$Client) {
    $text = $null
    if (Test-File $ReleaseApi) {
        $text = [System.IO.File]::ReadAllText($ReleaseApi)
    } else {
        try {
            $text = $Client.DownloadString($ReleaseApi)
        } catch {
            $problem = $_.Exception
            while ($problem -and -not ($problem -is [System.Net.WebException])) { $problem = $problem.InnerException }
            if ($problem -and ($problem.Response -is [System.Net.HttpWebResponse])) {
                $code = [int]$problem.Response.StatusCode
                if ($code -eq 404) { Stop-Setup "There is no Wax release to download yet. Look here later:`r`n  $ReleasePage" }
                Stop-Setup "GitHub answered with error $code. Try again later."
            }
            Stop-Setup 'GitHub could not be reached. Check your internet connection, then try again.'
        }
    }
    $release = $null
    try { $release = $text | ConvertFrom-Json } catch { }
    if (-not $release -or -not $release.PSObject.Properties['tag_name'] -or -not $release.tag_name) {
        Stop-Setup "There is no Wax release to download yet. Look here later:`r`n  $ReleasePage"
    }
    $url = $null
    if ($release.PSObject.Properties['assets']) {
        foreach ($asset in @($release.assets)) {
            if ($asset.name -match '^Wax-.+\.zip$') { $url = [string]$asset.browser_download_url; break }
        }
    }
    return New-Object PSObject -Property @{ Version = ([string]$release.tag_name -replace '^[vV]', ''); Url = $url }
}

function Update-Wax {
    $win64 = Find-Game
    Write-Host 'ICARUS is in:'
    Write-Host "  $win64"
    $wax = Combine $win64 $WaxPath
    $installed = Get-InstalledVersion $wax
    if (-not $installed) { Stop-Setup 'Wax is not installed in this game yet. Run "Install Wax.cmd" first.' }
    if (Test-Link $wax) { Stop-Setup "This is a link to another folder, so there is nothing to update here:`r`n  $wax" }

    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }
    $client = New-Object System.Net.WebClient
    $client.Headers['User-Agent'] = 'Wax-Setup'
    $release = Get-LatestRelease $client

    Write-Host ''
    if ($installed -eq '0') { Write-Host 'Installed: Wax, version not known' } else { Write-Host "Installed: Wax $installed" }
    Write-Host "Newest:    Wax $($release.Version)"
    if (-not (Test-Newer $release.Version $installed)) {
        Write-Host ''
        Write-Host 'You have the newest version. Nothing was changed.'
        return
    }
    if (-not $release.Url) { Stop-Setup "The newest release has no Wax zip attached yet. Look here later:`r`n  $ReleasePage" }
    if ($ReleaseApi -eq $DefaultApi -and -not $release.Url.StartsWith("https://github.com/$Repo/releases/download/", [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-Setup "The download link in the release is not the one expected, so nothing was downloaded. Get the zip here:`r`n  $ReleasePage"
    }
    Assert-GameClosed $win64

    $work = Combine ([System.IO.Path]::GetTempPath()) ('Wax-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][System.IO.Directory]::CreateDirectory($work)
    try {
        $zip = Combine $work 'Wax.zip'
        $unpacked = Combine $work 'Wax'
        Write-Host ''
        Write-Host "Downloading Wax $($release.Version) ..."
        try {
            $client.Headers['User-Agent'] = 'Wax-Setup'
            $client.DownloadFile($release.Url, $zip)
        } catch {
            Stop-Setup "The download did not finish. Check your internet connection, then try again. You can also get the zip here:`r`n  $ReleasePage"
        }
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $unpacked)
        } catch {
            Stop-Setup 'The downloaded file could not be opened. Try again.'
        }
        $setup = Combine $unpacked 'Wax-Setup.ps1'
        if (-not (Test-File $setup) -or -not (Test-File (Combine $unpacked 'game\dwmapi.dll'))) {
            Stop-Setup "The downloaded file is not a Wax release. Get the zip here:`r`n  $ReleasePage"
        }
        $shell = (Get-Process -Id $PID).Path
        & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup -Action Install -GameDir $win64
        if ($LASTEXITCODE -ne 0) { Stop-Setup 'The new version was downloaded but not installed. The reason is above.' }
    } finally {
        try { Remove-Tree $work } catch { }
    }
}

function Uninstall-Wax {
    $win64 = Find-Game
    Write-Host 'ICARUS is in:'
    Write-Host "  $win64"
    $wax = Combine $win64 $WaxPath
    $ue4ss = Combine $win64 'ue4ss'
    $hasWax = Test-Folder $wax
    $hasUE4SS = (Test-File (Combine $win64 'dwmapi.dll')) -or (Test-Folder $ue4ss)
    if (-not $hasWax -and -not $hasUE4SS) {
        Write-Host ''
        Write-Host 'Wax is not installed in this game. Nothing was changed.'
        return
    }
    Assert-GameClosed $win64
    Write-Host ''

    $keptMine = $false
    if ($hasWax -and (Test-Link $wax)) {
        Remove-Tree $wax
        Write-Host 'Wax was a link to another folder. The link is removed. The folder it points to was not touched.'
    } elseif ($hasWax) {
        $hasMine = -not ((Test-Empty (Combine $wax 'mods')) -and (Test-Empty (Combine $wax 'saved')))
        $removeMine = $true
        if ($hasMine) {
            Write-Host 'Your mods are in Wax\mods and your settings are in Wax\saved.'
            $removeMine = Read-YesNo 'Remove your mods and settings too?' $RemoveMyFiles
        }
        foreach ($item in (New-Object System.IO.DirectoryInfo $wax).GetFileSystemInfos()) {
            if (-not $removeMine -and ($Mine -contains $item.Name)) { continue }
            Remove-Tree $item.FullName
        }
        foreach ($name in $Mine) { Remove-IfEmpty (Combine $wax $name) }
        Remove-IfEmpty $wax
        $keptMine = Test-Folder $wax
        Unregister-ModLinks
        Write-Host 'Wax is removed.'
        if ($keptMine) {
            Write-Host 'Your mods and settings are still here:'
            Write-Host "  $wax"
        }
    } else {
        Write-Host 'Wax is not in this game.'
    }

    if (-not $hasUE4SS) { return }
    $stock = $StockMods
    if (Test-Folder (Combine $Package 'ue4ss\Mods')) {
        $stock = @((New-Object System.IO.DirectoryInfo (Combine $Package 'ue4ss\Mods')).GetDirectories() | ForEach-Object { $_.Name })
    }
    $mods = Combine $ue4ss 'Mods'
    $others = @()
    if (Test-Folder $mods) {
        foreach ($folder in (New-Object System.IO.DirectoryInfo $mods).GetDirectories()) {
            if ($folder.Name -ne 'Wax' -and ($stock -notcontains $folder.Name)) { $others += $folder.Name }
        }
    }
    Write-Host ''
    Write-Host 'UE4SS is the script loader Wax runs on. Other UE4SS mods need it too.'
    if ($others.Count -gt 0) { Write-Host ('These other mods are in ue4ss\Mods: ' + ($others -join ', ')) }
    if (-not (Read-YesNo 'Remove UE4SS too?' $RemoveUE4SS)) {
        Write-Host 'UE4SS is still installed.'
        return
    }
    Remove-Tree (Combine $win64 'dwmapi.dll')
    if (Test-Link $ue4ss) {
        Remove-Tree $ue4ss
    } elseif (Test-Folder $ue4ss) {
        foreach ($item in (New-Object System.IO.DirectoryInfo $ue4ss).GetFileSystemInfos()) {
            if ($item.Name -ne 'Mods') { Remove-Tree $item.FullName }
        }
        if ((Test-Folder $mods) -and -not (Test-Link $mods)) {
            foreach ($item in (New-Object System.IO.DirectoryInfo $mods).GetFileSystemInfos()) {
                if ($item.Name -eq 'Wax' -or ($others -contains $item.Name)) { continue }
                Remove-Tree $item.FullName
            }
        }
        Remove-IfEmpty $mods
        Remove-IfEmpty $ue4ss
    }
    Write-Host 'UE4SS is removed.'
    if ($others.Count -gt 0) {
        Write-Host 'The other mods were left where they are. They do not run without UE4SS.'
    }
    $backups = @([System.IO.Directory]::GetDirectories($win64, 'ue4ss-backup-*'))
    if ($backups.Count -gt 0) {
        Write-Host ''
        Write-Host 'The UE4SS files that were there before Wax are still in:'
        foreach ($folder in $backups) { Write-Host "  $folder" }
    }
}

if (-not $ReleaseApi) { $ReleaseApi = $DefaultApi }
try {
    if ($Action -eq 'Install') { Install-Wax }
    elseif ($Action -eq 'Update') { Update-Wax }
    else { Uninstall-Wax }
    exit 0
} catch {
    $problem = $_.Exception
    while ($problem.InnerException) { $problem = $problem.InnerException }
    Write-Host ''
    if ($problem -is [System.ApplicationException]) {
        Write-Host $problem.Message
    } elseif ($problem -is [System.UnauthorizedAccessException]) {
        Write-Host 'Windows did not let this script change the game folder.'
        Write-Host 'Right-click the .cmd file, choose "Run as administrator", and try again.'
        Write-Host "Details: $($problem.Message)"
    } else {
        Write-Host 'It did not finish. This is what went wrong:'
        Write-Host "  $($problem.Message)"
        Write-Host 'Close the game if it is open, then run this again.'
    }
    exit 1
}
