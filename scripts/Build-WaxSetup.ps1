#requires -Version 7
<#
.SYNOPSIS
  Builds the installer program for Wax: build\setup\Wax Setup.exe.
.DESCRIPTION
  One exe for .NET Framework 4.8 (on every Windows 10 and 11), source in wax\setup. The files it installs are packed
  into it: the "game" folder of the player download, as one compressed block, with a list of every file's size and
  SHA-256 that the program checks against when it unpacks and again after it has copied.
  The game folder comes from -Game (Build-WaxRelease.ps1 passes its own), or from build\Wax-<version>.zip.
  Everything dotnet downloads or writes stays under build\.
.EXAMPLE
  .\scripts\Build-WaxSetup.ps1
  .\scripts\Build-WaxSetup.ps1 -Sign 0123456789ABCDEF0123456789ABCDEF01234567   # signs with that certificate
  .\scripts\Build-WaxSetup.ps1 -Bare                                            # also builds it without the files, to see its own size
#>
[CmdletBinding()]
param(
    [string]$Game = '',
    [string]$Sign = '',
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$Bare
)
. "$PSScriptRoot\_common.ps1"

$project = Join-Path $Root 'wax\setup\WaxSetup.csproj'
$work    = Join-Path $BuildDir 'setup'
$packed  = Join-Path $work 'payload'
$exe     = Join-Path $work 'Wax Setup.exe'
$version = (Get-Content (Join-Path $Root 'wax\VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "wax\VERSION should hold a version like 0.1.0, not '$version'." }
New-Item -ItemType Directory -Force $work, $packed | Out-Null

$env:NUGET_PACKAGES = Join-Path $BuildDir '.nuget'
$env:NUGET_HTTP_CACHE_PATH = Join-Path $BuildDir '.nuget-http'
$env:NUGET_PLUGINS_CACHE_PATH = Join-Path $BuildDir '.nuget-plugins'
$env:DOTNET_CLI_HOME = Join-Path $BuildDir '.dotnet'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

if (-not $Game) {
    $zip = Join-Path $BuildDir "Wax-$version.zip"
    if (-not (Test-Path -LiteralPath $zip)) { throw "$zip not found. Run scripts\Build-WaxRelease.ps1, which builds this program as one of its steps." }
    $Game = Join-Path $work 'game'
    if (Test-Path -LiteralPath $Game) { Remove-Item -LiteralPath $Game -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($entry in $archive.Entries | Where-Object { $_.FullName.StartsWith('game/') }) {
            $target = Join-Path $work $entry.FullName.Replace('/', '\')
            if ($entry.FullName.EndsWith('/')) { New-Item -ItemType Directory -Force $target | Out-Null; continue }
            New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $archive.Dispose() }
}
$Game = (Resolve-Path -LiteralPath $Game).Path.TrimEnd('\')
foreach ($needed in 'dwmapi.dll', 'ue4ss\UE4SS.dll', 'ue4ss\Mods\Wax\Scripts\main.lua', 'ue4ss\Mods\Wax\VERSION') {
    if (-not (Test-Path -LiteralPath (Join-Path $Game $needed))) { throw "$Game has no $needed, so it is not the game folder of a Wax release." }
}
$inside = (Get-Content -LiteralPath (Join-Path $Game 'ue4ss\Mods\Wax\VERSION') -Raw).Trim()
if ($inside -ne $version) { throw "The game folder holds Wax $inside and wax\VERSION says $version." }
if (@(Get-ChildItem -LiteralPath $Game -Recurse -Force -Attributes ReparsePoint).Count) { throw "$Game holds links. Only real files go into the program." }

# The list: folders first, then files by kind, so that files alike sit together and pack smaller.
$folders = @(Get-ChildItem -LiteralPath $Game -Recurse -Force -Directory | Sort-Object FullName)
$files = @(Get-ChildItem -LiteralPath $Game -Recurse -Force -File | Sort-Object Extension, FullName)
$total = ($files | Measure-Object Length -Sum).Sum
if ($total -ge 1GB) { throw 'The game folder is larger than this program can hold.' }
$blob = [byte[]]::new($total)
$sha = [System.Security.Cryptography.SHA256]::Create()
$listStream = [System.IO.File]::Create((Join-Path $packed 'payload.list'))
$deflate = [System.IO.Compression.DeflateStream]::new($listStream, [System.IO.Compression.CompressionLevel]::SmallestSize)
$writer = [System.IO.BinaryWriter]::new($deflate)
$readable = [System.Collections.Generic.List[string]]::new()
$writer.Write([string]$version)
$writer.Write([int]($folders.Count + $files.Count))
foreach ($folder in $folders) {
    $writer.Write([string]$folder.FullName.Substring($Game.Length + 1)); $writer.Write($true); $writer.Write([long]0); $writer.Write([byte[]]::new(32))
}
$offset = 0
foreach ($file in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hash = $sha.ComputeHash($bytes)
    [System.Array]::Copy($bytes, 0, $blob, $offset, $bytes.Length)
    $offset += $bytes.Length
    $relative = $file.FullName.Substring($Game.Length + 1)
    $writer.Write([string]$relative); $writer.Write($false); $writer.Write([long]$bytes.Length); $writer.Write([byte[]]$hash)
    $readable.Add(('{0}  {1,10}  {2}' -f [System.Convert]::ToHexString($hash).ToLower(), $bytes.Length, $relative))
}
$writer.Dispose(); $deflate.Dispose(); $listStream.Dispose()
[System.IO.File]::WriteAllLines((Join-Path $packed 'payload.txt'), $readable)

# One block, packed by Windows itself (LZMS), which is what the program asks Windows to unpack.
Add-Type -Namespace WaxBuild -Name Cabinet -MemberDefinition @'
[DllImport("cabinet.dll", SetLastError = true)] public static extern bool CreateCompressor(uint algorithm, IntPtr allocation, out IntPtr handle);
[DllImport("cabinet.dll", SetLastError = true)] public static extern bool Compress(IntPtr handle, byte[] plain, IntPtr plainSize, byte[] packed, IntPtr packedSize, out IntPtr used);
[DllImport("cabinet.dll", SetLastError = true)] public static extern bool CloseCompressor(IntPtr handle);
'@
$handle = [IntPtr]::Zero
if (-not [WaxBuild.Cabinet]::CreateCompressor(5, [IntPtr]::Zero, [ref]$handle)) { throw 'Windows did not start its compressor.' }
$out = [byte[]]::new($blob.Length + 1MB)
$used = [IntPtr]::Zero
$ok = [WaxBuild.Cabinet]::Compress($handle, $blob, [IntPtr]$blob.Length, $out, [IntPtr]$out.Length, [ref]$used)
[void][WaxBuild.Cabinet]::CloseCompressor($handle)
if (-not $ok) { throw 'Windows could not pack the files.' }
$binStream = [System.IO.File]::Create((Join-Path $packed 'payload.bin'))
$binStream.Write([System.BitConverter]::GetBytes([int]$blob.Length), 0, 4)
$binStream.Write($out, 0, $used.ToInt32())
$binStream.Dispose()
$payloadSize = (Get-Item (Join-Path $packed 'payload.bin')).Length + (Get-Item (Join-Path $packed 'payload.list')).Length

$icon = Join-Path $Root 'wax\setup\app.ico'
if (-not (Test-Path -LiteralPath $icon)) { & (Join-Path $Root 'wax\setup\make_icon.ps1') }

function Invoke-Build([string]$Configuration, [string]$Payload) {
    $arguments = @('build', $project, '-c', $Configuration, '-v:q', '-nologo', '--disable-build-servers', '-p:UseSharedCompilation=false',
        "-p:WaxVersion=$version", "-p:PayloadFolder=$Payload")
    & dotnet @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "dotnet build failed ($LASTEXITCODE)." }
    $built = Join-Path $work "bin\$Configuration\Wax Setup.exe"
    if (-not (Test-Path -LiteralPath $built)) { throw "The build did not make $built." }
    $extra = @(Get-ChildItem -LiteralPath (Split-Path $built) -File | Where-Object { $_.Extension -in '.dll', '.config' })
    if ($extra.Count) { throw "The build made files the program would need beside it: $($extra.Name -join ', ')" }
    $built
}

$built = Invoke-Build 'Release' $packed
Copy-Item -LiteralPath $built -Destination $exe -Force

if ($Sign) {
    $signtool = (Get-Command signtool.exe -ErrorAction SilentlyContinue)?.Source
    if (-not $signtool) {
        $signtool = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $signtool) { throw 'signtool.exe was not found. It comes with the Windows SDK (the "Windows SDK Signing Tools" part).' }
    & $signtool sign /sha1 $Sign /fd SHA256 /tr $TimestampUrl /td SHA256 /d 'Wax Setup' /du 'https://wax-icarus.duckdns.org/' $exe
    if ($LASTEXITCODE -ne 0) { throw "signtool could not sign the program ($LASTEXITCODE)." }
    & $signtool verify /pa /q $exe
    if ($LASTEXITCODE -ne 0) { throw 'The signature did not verify.' }
}

$size = (Get-Item -LiteralPath $exe).Length
$signed = (Get-AuthenticodeSignature -LiteralPath $exe).Status
Write-Host "Built $exe"
Write-Host ("  Wax $version, {0:N2} MB: {1:N0} KB of program and {2:N2} MB of files to install ({3} files, {4:N1} MB unpacked)" -f `
    ($size / 1MB), (($size - $payloadSize) / 1KB), ($payloadSize / 1MB), $files.Count, ($total / 1MB))
Write-Host "  Signature: $signed"
if ($Bare) {
    $bare = Invoke-Build 'Bare' ''
    Write-Host ("  Without the files: {0:N0} KB ({1})" -f ((Get-Item -LiteralPath $bare).Length / 1KB), $bare)
}
Write-Host 'Test it with: .\wax\release\test\Test-WaxSetup.ps1'
