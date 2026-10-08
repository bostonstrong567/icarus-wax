[CmdletBinding()]
param(
    [ValidateSet('Install', 'Update', 'Uninstall')]
    [string]$Action = 'Install',
    [string]$GameDir = '',
    [string]$SteamRoot = '',
    [ValidateSet('Ask', 'Yes', 'No')]
    [string]$ModLinks = 'Ask',
    [ValidateSet('Ask', 'Yes', 'No')]
    [string]$RemoveUE4SS = 'Ask',
    [ValidateSet('Ask', 'Yes', 'No')]
    [string]$RemoveMyFiles = 'Ask'
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# Where "Update" looks, the key a release is signed with, the kind of link Windows hands to Wax, and Wax's folder under %LOCALAPPDATA%. Only this file sets them.
$ReleaseApi = 'https://api.github.com/repos/bostonstrong567/icarus-wax/releases/latest'
$DownloadRoot = 'https://github.com/bostonstrong567/icarus-wax/releases/download/'
$SigningKey = '8b37ac88ea0d9e8a8d239b731f1ba1d12fe163c605f6fe3c3933253e36421a953c5d04fdcb94e3934223e41aeb511593788140a7865c00ab2f6ad67746900d62'
$LinkScheme = 'wax'
$LocalFolder = 'Wax'

$AppId = '1149460'
$GameExe = 'Icarus-Win64-Shipping.exe'
$GameProcess = 'Icarus-Win64-Shipping'
$DocsUrl = 'https://wax-icarus.duckdns.org/'
$InstallPage = 'https://wax-icarus.duckdns.org/docs/install/'
$ReleasePage = 'https://github.com/bostonstrong567/icarus-wax/releases/latest'
$MaxZip = 200MB
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
# UE4SS's own mods that Wax ships switched off.
$CheatMods = @('CheatManagerEnablerMod', 'ConsoleCommandsMod', 'ConsoleEnablerMod')
$AclOnItem = [bool]([System.IO.DirectoryInfo].GetMethod('SetAccessControl'))

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

# The SHA-256 of a file in lower-case hex.
function Get-Sha256([string]$File) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($File)
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Test-Same([string]$Left, [string]$Right) {
    if (-not (Test-File $Left) -or -not (Test-File $Right)) { return $false }
    if ((New-Object System.IO.FileInfo $Left).Length -ne (New-Object System.IO.FileInfo $Right).Length) { return $false }
    return (Get-Sha256 $Left) -ceq (Get-Sha256 $Right)
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
    $a = [regex]::Matches($Candidate, '\d{1,9}')
    $b = [regex]::Matches($Current, '\d{1,9}')
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

# The file Windows starts for a link of Wax's kind: the last full path in the registered command. Nothing registered gives nothing.
function Get-LinkTarget {
    $command = $null
    try { $command = [string](Get-ItemProperty -Path "HKCU:\Software\Classes\$LinkScheme\shell\open\command" -ErrorAction Stop).'(default)' } catch { return $null }
    $target = $null
    foreach ($quoted in [regex]::Matches($command, '"([^"]*)"')) {
        if ($quoted.Groups[1].Value -match '^([A-Za-z]:\\|\\\\)') { $target = $quoted.Groups[1].Value }
    }
    if (-not $target -and $command -match '^\s*(([A-Za-z]:\\|\\\\)\S+)') { $target = $Matches[1] }
    return $target
}

function Register-ModLinks([string]$Helper) {
    if (-not (Test-File $Helper) -or $Helper.Contains('%') -or $Helper.Contains('"')) { return $false }
    try {
        # Written again as a file made on this PC, so Windows runs it under its usual rule for local scripts.
        $fresh = "$Helper.new"
        [System.IO.File]::WriteAllBytes($fresh, [System.IO.File]::ReadAllBytes($Helper))
        Move-Item -LiteralPath $fresh -Destination $Helper -Force
        $key = "HKCU:\Software\Classes\$LinkScheme"
        $shell = Combine $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $command = '"{0}" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "{1}" "%1"' -f $shell, $Helper
        New-Item -Path "$key\shell\open\command" -Force | Out-Null
        Set-ItemProperty -Path $key -Name '(Default)' -Value 'URL:Wax mod link'
        Set-ItemProperty -Path $key -Name 'URL Protocol' -Value ''
        Set-ItemProperty -Path "$key\shell\open\command" -Name '(Default)' -Value $command
        return $true
    } catch {
        return $false
    }
}

# Takes the registration away when it starts a file in this folder, or a file that is gone.
function Remove-DeadModLinks([string]$Folder) {
    $target = Get-LinkTarget
    if (-not $target) { return }
    $inside = $target.StartsWith($Folder.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $inside -and (Test-File $target)) { return }
    try {
        Remove-Item -LiteralPath "HKCU:\Software\Classes\$LinkScheme" -Recurse -Force
        Write-Host ('Windows no longer hands ' + $LinkScheme + ':// links to Wax. The registry entry for them is removed.')
    } catch {
        Write-Host ('The registry entry for ' + $LinkScheme + ':// links could not be removed. README.txt says how to remove it by hand.')
    }
}

# Wax-Import.ps1 keeps one log outside the game, import.log. Its folder is removed when that log is all it holds.
function Remove-ImportLog {
    try {
        $folder = Combine ([System.Environment]::GetFolderPath('LocalApplicationData')) $LocalFolder
        if (-not [System.IO.Path]::IsPathRooted($folder) -or -not (Test-Folder $folder) -or (Test-Link $folder)) { return }
        foreach ($item in (New-Object System.IO.DirectoryInfo $folder).GetFileSystemInfos()) {
            if ($item.Name -ne 'import.log' -or $item -isnot [System.IO.FileInfo] -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                Write-Host ''
                Write-Host 'The log of mods added through links was left where it is, because its folder holds other files too:'
                Write-Host "  $folder"
                return
            }
        }
        Remove-Tree $folder
        Write-Host ''
        Write-Host 'The log of mods added through links is removed too:'
        Write-Host "  $folder"
    } catch { }
}

# The question is put once for each copy of Wax. The answer is kept in run\links.txt, and later installs leave things as they are.
function Set-ModLinks([string]$Wax) {
    $helper = Combine $Wax 'Wax-Import.ps1'
    $note = Combine $Wax 'run\links.txt'
    $target = Get-LinkTarget
    $here = $target -and [string]::Equals($target, $helper, [System.StringComparison]::OrdinalIgnoreCase)
    $button = 'The "Add to game" button on the Wax site'
    if ($ModLinks -eq 'Ask' -and (Test-File $note)) {
        # A yes also holds after the game was moved: then the registration names a file that is gone, and it is written for the new place.
        $moved = $target -and -not $here -and -not (Test-File $target) -and (Read-Version $note) -eq 'yes'
        if (($here -or $moved) -and -not (Register-ModLinks $helper)) { Write-Host "$button could not be set up again. Downloading a mod as a zip still works." }
        return
    }
    $want = ($ModLinks -eq 'Yes')
    if ($ModLinks -eq 'Ask') {
        Write-Host ''
        Write-Host "$button adds a mod without a download by hand."
        Write-Host ('For that, Windows has to hand links that start with ' + $LinkScheme + ':// to Wax. That takes one entry in your own')
        Write-Host ('part of the registry (HKEY_CURRENT_USER\Software\Classes\' + $LinkScheme + '). Uninstalling Wax removes it.')
        Write-Host 'Such a link can come from any web page, not only from the Wax site. Wax shows you the mod and asks'
        Write-Host 'before it downloads anything, and a mod it adds stays switched off until you switch it on.'
        Write-Host 'Without the entry everything else works: download a mod as a zip and put it in the mods folder.'
        $want = Read-YesNo 'Let that button open Wax on this PC?' 'Ask'
    }
    $answer = 'no'
    if ($want) { $answer = 'yes' }
    try { [System.IO.File]::WriteAllText($note, "$answer`r`n", [System.Text.Encoding]::ASCII) } catch { }
    if ($want) {
        if (Register-ModLinks $helper) { Write-Host "$button now opens Wax on this PC." }
        else { Write-Host "$button could not be set up. Downloading a mod as a zip still works." }
        return
    }
    if ($here) { Remove-DeadModLinks $Wax }
    if (-not $here -and $target -and (Test-File $target)) {
        Write-Host "$button opens another copy of Wax on this PC, and that was left as it is:"
        Write-Host "  $target"
        return
    }
    Write-Host "$button is not set up. README.txt says how to switch it on later."
}

# The account at the desk. It is another one than this runs as when a second account was used to run this as administrator.
function Get-DeskUser {
    try {
        $session = (Get-Process -Id $PID).SessionId
        foreach ($shell in @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'")) {
            if ($shell.SessionId -ne $session) { continue }
            $owner = Invoke-CimMethod -InputObject $shell -MethodName GetOwnerSid
            if ($owner -and $owner.Sid) { return New-Object System.Security.Principal.SecurityIdentifier ([string]$owner.Sid) }
        }
    } catch { }
    return $null
}

function Get-Rules($Item) {
    if ($AclOnItem) { return $Item.GetAccessControl() }
    return [System.IO.FileSystemAclExtensions]::GetAccessControl($Item)
}

function Set-Rules($Item, $Rules) {
    if ($AclOnItem) { $Item.SetAccessControl($Rules) }
    else { [System.IO.FileSystemAclExtensions]::SetAccessControl($Item, $Rules) }
}

function New-Rules($Item) {
    if ($Item -is [System.IO.DirectoryInfo]) { return New-Object System.Security.AccessControl.DirectorySecurity }
    return New-Object System.Security.AccessControl.FileSecurity
}

# Makes a file or folder the installing user's. With -Plain it also loses rules of its own, so the rules of Wax's folder apply to it.
function Reset-Rules($Item, $Me, [switch]$Plain) {
    $sid = [System.Security.Principal.SecurityIdentifier]
    $now = Get-Rules $Item
    if ($Plain -and ($now.AreAccessRulesProtected -or $now.GetAccessRules($true, $false, $sid).Count -gt 0)) {
        $rules = New-Rules $Item
        $rules.SetAccessRuleProtection($false, $false)
        Set-Rules $Item $rules
    }
    if ($now.GetOwner($sid).Value -ne $Me.Value) {
        $rules = New-Rules $Item
        $rules.SetOwner($Me)
        Set-Rules $Item $rules
    }
}

# Wax's folder stops taking rules from the folder above. The installing user, Administrators and SYSTEM may change it, other users may read it.
function Protect-Folder([string]$Wax) {
    if (-not (Test-Folder $Wax) -or (Test-Link $Wax)) { return }
    $stuck = 0
    try {
        $well = [System.Security.Principal.WellKnownSidType]
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $change = @($me)
        $change += New-Object System.Security.Principal.SecurityIdentifier ($well::BuiltinAdministratorsSid, $null)
        $change += New-Object System.Security.Principal.SecurityIdentifier ($well::LocalSystemSid, $null)
        $desk = Get-DeskUser
        if ($desk -and $desk.Value -ne $me.Value) { $change += $desk }
        $users = New-Object System.Security.Principal.SecurityIdentifier ($well::BuiltinUsersSid, $null)
        $inside = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $none = [System.Security.AccessControl.PropagationFlags]::None
        $allow = [System.Security.AccessControl.AccessControlType]::Allow
        $rights = [System.Security.AccessControl.FileSystemRights]
        $rules = New-Object System.Security.AccessControl.DirectorySecurity
        $rules.SetAccessRuleProtection($true, $false)
        foreach ($who in $change) {
            $rules.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule ($who, $rights::FullControl, $inside, $none, $allow)))
        }
        $rules.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule ($users, $rights::ReadAndExecute, $inside, $none, $allow)))
        $top = New-Object System.IO.DirectoryInfo $Wax
        Set-Rules $top $rules
        Reset-Rules $top $me

        # A link inside is left as it is and not looked into.
        $folders = New-Object System.Collections.Stack
        $folders.Push($top)
        while ($folders.Count -gt 0) {
            foreach ($item in $folders.Pop().GetFileSystemInfos()) {
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                try { Reset-Rules $item $me -Plain } catch { $stuck++ }
                if ($item -is [System.IO.DirectoryInfo]) { $folders.Push($item) }
            }
        }
    } catch {
        $problem = $_.Exception
        while ($problem.InnerException) { $problem = $problem.InnerException }
        Write-Host 'Wax is installed, but Windows did not let this script close its folder to the other accounts on this PC:'
        Write-Host "  $($problem.Message)"
        return
    }
    if ($stuck -gt 0) {
        Write-Host "Wax's folder can now only be changed by your Windows account and by administrators, except for $stuck things in it"
        Write-Host 'that Windows did not let this script reach.'
    } else {
        Write-Host "Wax's folder can now only be changed by your Windows account and by administrators. Other accounts can read it."
    }
}

# True when a UE4SS mod list in the game is the one that came with Wax before: today's list with all three mods switched on.
function Test-EarlierList([string]$Shipped, [string]$Installed) {
    $name = [System.IO.Path]::GetFileName($Shipped)
    if ($name -ne 'mods.txt' -and $name -ne 'mods.json') { return $false }
    $earlier = [System.IO.File]::ReadAllText($Shipped)
    foreach ($mod in $CheatMods) {
        $earlier = [regex]::Replace($earlier, "(?m)^($mod\s*:\s*)0", '${1}1')
        $earlier = [regex]::Replace($earlier, "(`"mod_name`"\s*:\s*`"$mod`"\s*,\s*`"mod_enabled`"\s*:\s*)false", '${1}true')
    }
    return $earlier -ceq [System.IO.File]::ReadAllText($Installed)
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
    $switchedOff = $false
    $waxFiles = $packageWax + '\'
    foreach ($file in [System.IO.Directory]::GetFiles($Package, '*', [System.IO.SearchOption]::AllDirectories)) {
        if ($file.StartsWith($waxFiles, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative = $file.Substring($Package.Length + 1)
        $target = Combine $win64 $relative
        if (Test-File $target) {
            if (Test-Same $file $target) { continue }
            if ($sameUE4SS -and ($KeptSettings -contains $relative)) {
                if (-not (Test-EarlierList $file $target)) {
                    $kept += [System.IO.Path]::GetFileName($relative)
                    continue
                }
                $switchedOff = $true
            } else {
                Copy-File $target (Combine $backup $relative)
                $backedUp++
            }
        }
        Copy-File $file $target
    }
    $stillOn = @()
    if ($kept -contains 'mods.txt') {
        $list = [System.IO.File]::ReadAllText((Combine $win64 'ue4ss\Mods\mods.txt'))
        foreach ($mod in $CheatMods) {
            if ($list -match "(?m)^$mod\s*:\s*1") { $stillOn += $mod }
        }
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
    Protect-Folder $wax
    Set-ModLinks $wax
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
    $modList = Combine $win64 'ue4ss\Mods\mods.txt'
    if ($switchedOff) {
        Write-Host ''
        Write-Host ("UE4SS's own cheat and console mods are now switched off: " + ($CheatMods -join ', ') + '.')
        Write-Host 'Wax does not need them, and earlier versions of Wax left them on. To switch one back on, change its 0 to 1 in:'
        Write-Host "  $modList"
    }
    if ($stillOn.Count -gt 0) {
        Write-Host ''
        Write-Host ("In your mods.txt these mods of UE4SS are switched on: " + ($stillOn -join ', ') + '.')
        Write-Host 'They open the game''s console and cheat commands. Wax does not need them, and a new install has them off.'
        Write-Host 'Your file was not changed. To switch one off, change its 1 to 0 in:'
        Write-Host "  $modList"
    }
    if ($oldLayout) {
        Write-Host ''
        Write-Host 'An older UE4SS is also in the game folder (UE4SS.dll next to the game exe).'
        Write-Host 'It is not loaded any more. Mods in its Mods folder only run after you move them to ue4ss\Mods.'
    }
    if ($PSScriptRoot -match '\\Wax-update-[0-9a-f]{8}\\Wax$') {
        Write-Host ''
        Write-Host 'This update was started by an "Update Wax.cmd" from an older Wax. That file installs what it downloads'
        Write-Host 'without checking who made it. The one that comes with this version checks the author''s signature first.'
        Write-Host "Download Wax $version once from the site, use the files of that zip from now on, and delete the older folder:"
        Write-Host "  $InstallPage"
    }
    Write-Host ''
    Write-Host 'Next:'
    Write-Host '  1. Start ICARUS.'
    Write-Host '  2. Press F8 in the game to open the Wax menu.'
    Write-Host '  3. Put your mods in this folder, one folder per mod. Prospector''s Codex is there already.'
    Write-Host ('       ' + (Combine $wax 'mods'))
    Write-Host ''
    Write-Host "Docs: $DocsUrl"
}

# Opens an address. A redirect is followed five times at most, and only to an address of the same kind as the release addresses (https).
function Open-Address([string]$Address) {
    $kind = (New-Object System.Uri $DownloadRoot).Scheme
    $uri = New-Object System.Uri $Address
    for ($hop = 0; $hop -le 5; $hop++) {
        if ($uri.Scheme -cne $kind) { break }
        $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($uri)
        $request.UserAgent = 'Wax-Setup'
        $request.AllowAutoRedirect = $false
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 30000
        $response = $request.GetResponse()
        $code = [int]$response.StatusCode
        if ($code -lt 300 -or $code -gt 399) { return $response }
        $next = $response.Headers['Location']
        $response.Close()
        if (-not $next) { break }
        $uri = New-Object System.Uri ($uri, $next)
    }
    throw (New-Object System.Net.WebException 'The address led somewhere that is not followed.')
}

# Copies an answer into a stream and stops at the limit. Returns the number of bytes, or -1 when there were more.
function Read-Answer($Response, [System.IO.Stream]$Into, [long]$Limit) {
    if ($Response.ContentLength -gt $Limit) { return -1 }
    $from = $Response.GetResponseStream()
    try {
        $buffer = New-Object byte[] 65536
        $total = [long]0
        while ($true) {
            $count = $from.Read($buffer, 0, $buffer.Length)
            if ($count -le 0) { return $total }
            $total += $count
            if ($total -gt $Limit) { return -1 }
            $Into.Write($buffer, 0, $count)
        }
    } finally {
        $from.Dispose()
    }
}

# A small file as bytes, or nothing when it is larger than the limit.
function Get-Small([string]$Address, [long]$Limit) {
    $response = Open-Address $Address
    $memory = New-Object System.IO.MemoryStream
    try {
        if ((Read-Answer $response $memory $Limit) -lt 0) { return $null }
        return , $memory.ToArray()
    } finally {
        $response.Close()
        $memory.Dispose()
    }
}

# The HTTP error behind a failed request, or 0 when there was no answer at all.
function Get-HttpError($Failure) {
    $problem = $Failure.Exception
    while ($problem -and -not ($problem -is [System.Net.WebException])) { $problem = $problem.InnerException }
    if ($problem -and ($problem.Response -is [System.Net.HttpWebResponse])) { return [int]$problem.Response.StatusCode }
    return 0
}

# True when the text carries the signature of the key above: ECDSA on P-256 with SHA-256, the signature as r then s.
function Test-Signature([byte[]]$Text, [string]$Signature) {
    if ($Signature -cnotmatch '^[A-Za-z0-9+/]{85}[AQgw]==$') { return $false }
    try {
        $blob = New-Object byte[] 72
        [System.Text.Encoding]::ASCII.GetBytes('ECS1').CopyTo($blob, 0)
        $blob[4] = 32
        for ($i = 0; $i -lt 64; $i++) { $blob[8 + $i] = [System.Convert]::ToByte($SigningKey.Substring($i * 2, 2), 16) }
        $key = [System.Security.Cryptography.CngKey]::Import($blob, [System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
        $ecdsa = New-Object System.Security.Cryptography.ECDsaCng $key
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return [bool]$ecdsa.VerifyHash($sha.ComputeHash($Text), [System.Convert]::FromBase64String($Signature)) }
        finally { $sha.Dispose(); $ecdsa.Dispose(); $key.Dispose() }
    } catch {
        return $false
    }
}

# True when an address is the one this file of this release has under the project's releases, and nothing else.
function Test-ReleaseAddress([string]$Address, [string]$Tag, [string]$Name) {
    $uri = $null
    if (-not [System.Uri]::TryCreate($Address, [System.UriKind]::Absolute, [ref]$uri)) { return $false }
    $wanted = New-Object System.Uri ($DownloadRoot + $Tag + '/' + $Name)
    return ($uri.Scheme -ceq $wanted.Scheme) -and ($uri.Host -ceq $wanted.Host) -and ($uri.Port -eq $wanted.Port) -and
        [string]::Equals($uri.AbsolutePath, $wanted.AbsolutePath, [System.StringComparison]::OrdinalIgnoreCase) -and
        (-not $uri.Query) -and (-not $uri.Fragment) -and (-not $uri.UserInfo)
}

# The signed list of a release: "release <version>", then one line "<sha256> <size> <name>" for each file. Returns the line of one file.
function Read-ReleaseList([byte[]]$Bytes, [string]$Version, [string]$Name) {
    $unreadable = "The signed list of files of this release could not be read, so nothing was installed. Get Wax from the site:`r`n  $InstallPage"
    $lines = [System.Text.Encoding]::ASCII.GetString($Bytes).Split([char]10)
    if ($lines.Count -lt 2 -or $lines[$lines.Count - 1] -ne '' -or $lines[0] -cnotmatch '^release (\d{1,5}\.\d{1,5}\.\d{1,5})$') { Stop-Setup $unreadable }
    if ($Matches[1] -cne $Version) {
        Stop-Setup "The signed list of files is for Wax $($Matches[1]), not for Wax $Version, so nothing was installed. Get Wax from the site:`r`n  $InstallPage"
    }
    $found = $null
    for ($i = 1; $i -lt $lines.Count - 1; $i++) {
        if ($lines[$i] -cnotmatch '^([0-9a-f]{64}) (\d{1,12}) ([A-Za-z0-9._-]{1,100})$') { Stop-Setup $unreadable }
        if ($Matches[3] -cne $Name) { continue }
        if ($found) { Stop-Setup $unreadable }
        $found = New-Object PSObject -Property @{ Hash = $Matches[1]; Size = [long]$Matches[2] }
    }
    if (-not $found -or $found.Size -lt 1 -or $found.Size -gt $MaxZip) {
        Stop-Setup "The signed list of files does not name a Wax zip this updater can use, so nothing was installed. Get Wax from the site:`r`n  $InstallPage"
    }
    return $found
}

# What GitHub says the newest release is: its version, its tag, and the address it gives for each of its files.
function Get-LatestRelease {
    $none = "There is no Wax release to download yet. Look here later:`r`n  $ReleasePage"
    $bytes = $null
    try {
        $bytes = Get-Small $ReleaseApi 2MB
    } catch {
        $code = Get-HttpError $_
        if ($code -eq 404) { Stop-Setup $none }
        if ($code -ne 0) { Stop-Setup "GitHub answered with error $code. Try again later." }
        Stop-Setup 'GitHub could not be reached. Check your internet connection, then try again.'
    }
    $release = $null
    try { $release = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json } catch { }
    if (-not $release -or -not $release.PSObject.Properties['tag_name'] -or -not $release.tag_name) { Stop-Setup $none }
    $tag = [string]$release.tag_name
    if ($tag -cnotmatch '^[vV]?(\d{1,5}\.\d{1,5}\.\d{1,5})$') {
        Stop-Setup "The newest release is called $tag, which this updater does not understand. Get Wax from the site:`r`n  $InstallPage"
    }
    $version = $Matches[1]
    $files = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
    if ($release.PSObject.Properties['assets']) {
        foreach ($asset in @($release.assets)) {
            if ($asset -and $asset.PSObject.Properties['name'] -and $asset.PSObject.Properties['browser_download_url']) {
                $files[[string]$asset.name] = [string]$asset.browser_download_url
            }
        }
    }
    return New-Object PSObject -Property @{ Version = $version; Tag = $tag; Files = $files }
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
    $release = Get-LatestRelease

    Write-Host ''
    if ($installed -eq '0') { Write-Host 'Installed: Wax, version not known' } else { Write-Host "Installed: Wax $installed" }
    Write-Host "Newest:    Wax $($release.Version)"
    if (-not (Test-Newer $release.Version $installed)) {
        Write-Host ''
        Write-Host 'You have the newest version. Nothing was changed.'
        return
    }
    $zipName = "Wax-$($release.Version).zip"
    $listName = "Wax-$($release.Version).manifest"
    $signatureName = "$listName.sig"
    if (-not $release.Files.ContainsKey($zipName)) { Stop-Setup "The newest release has no Wax zip attached yet. Look here later:`r`n  $ReleasePage" }
    if (-not $release.Files.ContainsKey($listName) -or -not $release.Files.ContainsKey($signatureName)) {
        Stop-Setup "This release has no signed list of its files, so this updater does not install it. Download Wax by hand from the site:`r`n  $InstallPage"
    }
    foreach ($name in $zipName, $listName, $signatureName) {
        if (-not (Test-ReleaseAddress $release.Files[$name] $release.Tag $name)) {
            Stop-Setup "The release gives an address for $name that is not under the Wax project's releases, so nothing was downloaded. Download Wax by hand from the site:`r`n  $InstallPage"
        }
    }
    Assert-GameClosed $win64

    $unfinished = "The download did not finish. Check your internet connection, then try again. You can also get Wax from the site:`r`n  $InstallPage"
    $from = $DownloadRoot + $release.Tag + '/'
    $work = Combine ([System.IO.Path]::GetTempPath()) ('Wax-checked-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][System.IO.Directory]::CreateDirectory($work)
    try {
        Write-Host ''
        Write-Host "Checking the signature of Wax $($release.Version) ..."
        $list = $null
        $signature = $null
        try {
            $list = Get-Small ($from + $listName) 65536
            $signature = Get-Small ($from + $signatureName) 1024
        } catch {
            Stop-Setup $unfinished
        }
        $signed = $false
        if ($null -ne $list -and $null -ne $signature) { $signed = Test-Signature $list ([System.Text.Encoding]::ASCII.GetString($signature).Trim()) }
        if (-not $signed) {
            Stop-Setup "The list of files of this release does not carry the signature of Wax's author, so nothing was installed. Download Wax by hand from the site:`r`n  $InstallPage"
        }
        $entry = Read-ReleaseList $list $release.Version $zipName

        Write-Host "Downloading Wax $($release.Version) ..."
        $zip = Combine $work $zipName
        $unpacked = Combine $work 'Wax'
        $read = [long]0
        try {
            $response = Open-Address ($from + $zipName)
            $file = [System.IO.File]::Create($zip)
            try { $read = Read-Answer $response $file $entry.Size }
            finally { $file.Dispose(); $response.Close() }
        } catch {
            Stop-Setup $unfinished
        }
        if ($read -lt 0) {
            Stop-Setup 'The download is larger than the signed list says the zip is, so it was stopped and nothing was installed. Try again later.'
        }
        if ($read -ne $entry.Size -or (Get-Sha256 $zip) -cne $entry.Hash) {
            Stop-Setup 'The downloaded zip is not the file the signed list describes, so nothing was installed. Try again later.'
        }
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $unpacked)
        } catch {
            Stop-Setup 'The downloaded file could not be opened. Try again.'
        }
        $setup = Combine $unpacked 'Wax-Setup.ps1'
        if (-not (Test-File $setup) -or -not (Test-File (Combine $unpacked 'game\dwmapi.dll'))) {
            Stop-Setup "The downloaded file is not a Wax release. Get Wax from the site:`r`n  $InstallPage"
        }
        $inside = Read-Version (Combine $unpacked "game\$WaxPath\VERSION")
        if ($inside -cne $release.Version) {
            Stop-Setup "The downloaded zip holds Wax $inside, not Wax $($release.Version), so nothing was installed. Get Wax from the site:`r`n  $InstallPage"
        }
        $shell = (Get-Process -Id $PID).Path
        & $shell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File $setup -Action Install -GameDir $win64
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
        Write-Host 'Wax is not installed in this game. Nothing was changed in the game folder.'
        Remove-DeadModLinks $wax
        Remove-ImportLog
        return
    }
    Assert-GameClosed $win64
    Write-Host ''
    try {
        Remove-Wax $win64 $wax $hasWax
    } finally {
        Remove-DeadModLinks $wax
    }
    if ($hasUE4SS) { Remove-UE4SS $win64 }
    Remove-ImportLog
}

function Remove-Wax([string]$Win64, [string]$Wax, [bool]$HasWax) {
    if ($HasWax -and (Test-Link $Wax)) {
        Remove-Tree $Wax
        Write-Host 'Wax was a link to another folder. The link is removed. The folder it points to was not touched.'
    } elseif ($HasWax) {
        $hasMine = -not ((Test-Empty (Combine $Wax 'mods')) -and (Test-Empty (Combine $Wax 'saved')))
        $removeMine = $true
        if ($hasMine) {
            Write-Host 'Your mods are in Wax\mods and your settings are in Wax\saved.'
            $removeMine = Read-YesNo 'Remove your mods and settings too?' $RemoveMyFiles
        }
        foreach ($item in (New-Object System.IO.DirectoryInfo $Wax).GetFileSystemInfos()) {
            if (-not $removeMine -and ($Mine -contains $item.Name)) { continue }
            Remove-Tree $item.FullName
        }
        foreach ($name in $Mine) { Remove-IfEmpty (Combine $Wax $name) }
        Remove-IfEmpty $Wax
        Write-Host 'Wax is removed.'
        if (Test-Folder $Wax) {
            Write-Host 'Your mods and settings are still here:'
            Write-Host "  $Wax"
        }
    } else {
        Write-Host 'Wax is not in this game.'
    }
}

function Remove-UE4SS([string]$Win64) {
    $ue4ss = Combine $Win64 'ue4ss'
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
    Remove-Tree (Combine $Win64 'dwmapi.dll')
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
    $backups = @([System.IO.Directory]::GetDirectories($Win64, 'ue4ss-backup-*'))
    if ($backups.Count -gt 0) {
        Write-Host ''
        Write-Host 'The UE4SS files that were there before Wax are still in:'
        foreach ($folder in $backups) { Write-Host "  $folder" }
    }
}

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
        Write-Host 'It may belong to another Windows account on this PC: Wax''s folder can only be changed by the account that installed it.'
        Write-Host 'Right-click the .cmd file, choose "Run as administrator", and try again.'
        Write-Host "Details: $($problem.Message)"
    } else {
        Write-Host 'It did not finish. This is what went wrong:'
        Write-Host "  $($problem.Message)"
        Write-Host 'Close the game if it is open, then run this again.'
    }
    exit 1
}
