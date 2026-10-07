#requires -Version 7
<#
.SYNOPSIS
  Downloads or updates every tool listed in tools.json into tools\.
.DESCRIPTION
  Re-run any time to pull the newest releases. Tools that are already current are skipped.
  Archives are extracted over the existing folder without wiping it, so portable apps keep their settings.
  Folders that are not in the manifest (the "manual" tools) are never touched.
  An entry that downloads one file may give its "sha256". A download that does not match is refused and nothing of it
  is installed. Entries that follow the newest build on purpose have none.
.EXAMPLE
  .\scripts\Get-Tools.ps1
  .\scripts\Get-Tools.ps1 -Name pak\repak,assets\FModel -Force
#>
[CmdletBinding()]
param(
    [string[]]$Name,
    [switch]$Force
)
. "$PSScriptRoot\_common.ps1"

$manifest = (Get-ToolManifest).tools
# `pwsh -File` passes "a,b" as one string, so split it here.
$Name = @($Name | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object Trim)
$unknown = @($Name | Where-Object { $_ -notin $manifest.name })
if ($unknown) { throw "Not in tools.json: $($unknown -join ', ')" }
# Selecting a tool also selects the patches layered on it.
if ($Name) { $Name += @($manifest | Where-Object { $_.PSObject.Properties['dest']?.Value -in $Name } | ForEach-Object name) }

$tempDir  = Join-Path $ToolsDir '_downloads'
$statePath = Join-Path $ToolsDir '.versions.json'
New-Item -ItemType Directory -Force $tempDir | Out-Null
$state = if (Test-Path $statePath) { Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
@($state.Keys) | Where-Object { $_ -notin $manifest.name } | ForEach-Object { $state.Remove($_) }   # tools since dropped from the manifest
$useGh = [bool](Get-Command gh -ErrorAction SilentlyContinue)

function Invoke-GitHubApi([string]$Path) {
    if ($useGh) {
        $out = gh api $Path 2>&1
        if ($LASTEXITCODE -ne 0) { throw "gh api $Path failed: $out" }
        return $out | ConvertFrom-Json
    }
    $headers = @{ 'User-Agent' = 'IcarusModding' }
    if ($env:GITHUB_TOKEN) { $headers.Authorization = "Bearer $env:GITHUB_TOKEN" }
    Invoke-RestMethod "https://api.github.com/$Path" -Headers $headers
}

function Save-Url([string]$Url, [string]$OutFile) {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest $Url -OutFile $OutFile -Headers @{ 'User-Agent' = 'IcarusModding' } -MaximumRetryCount 3 -RetryIntervalSec 3
}

function Install-Payload([string]$File, [string]$Dest, [bool]$Extract) {
    New-Item -ItemType Directory -Force $Dest | Out-Null
    if (-not ($Extract -and $File -match '\.zip$')) {
        Copy-Item -LiteralPath $File -Destination $Dest -Force
        return
    }
    $unpacked = "$File.unpacked"
    Expand-Archive -LiteralPath $File -DestinationPath $unpacked -Force
    # Many release zips wrap everything in one folder, often version-stamped. Hoist its contents so
    # the tool's path stays the same across updates.
    $top = @(Get-ChildItem -LiteralPath $unpacked -Force)
    $source = if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $top[0].FullName } else { $unpacked }
    Copy-Item -Path (Join-Path $source '*') -Destination $Dest -Recurse -Force
}

function Build-Lua([string]$Tarball, [string]$Dest) {
    $gcc = Get-Command gcc -ErrorAction SilentlyContinue
    if (-not $gcc) { throw 'gcc is needed to build Lua (e.g. scoop install mingw)' }
    $work = Split-Path $Tarball
    # Windows' own tar, by its full path: from a Git shell "tar" is GNU tar, which reads D:\ as a host name
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -xzf $Tarball -C $work
    if ($LASTEXITCODE -ne 0) { throw 'could not unpack the Lua source' }
    $src = Join-Path (Get-ChildItem $work -Directory -Filter 'lua-*' | Select-Object -First 1).FullName 'src'
    New-Item -ItemType Directory -Force $Dest | Out-Null
    # Everything except luac.c (the separate compiler front end) makes up the interpreter.
    $sources = Get-ChildItem $src -Filter *.c | Where-Object Name -ne 'luac.c' | ForEach-Object FullName
    & $gcc.Source -O2 -std=gnu99 -o (Join-Path $Dest 'lua.exe') @sources -lm
    if ($LASTEXITCODE -ne 0) { throw 'gcc failed to build Lua' }
}

$results = foreach ($tool in $manifest) {
    if ($Name -and $tool.name -notin $Name) { continue }
    # "dest" lets an entry install on top of another tool's folder (a patch over a full release).
    $dest    = Join-Path $ToolsDir ($tool.PSObject.Properties['dest']?.Value ?? $tool.name)
    $extract =if ($null -ne $tool.PSObject.Properties['extract']) { [bool]$tool.extract } else { $true }
    $row     = [ordered]@{ Tool = $tool.name; Version = ''; Status = '' }
    try {
        $downloads = @()
        switch ($tool.type) {
            'github-release' {
                $tag = $tool.PSObject.Properties['tag']?.Value
                $rel = if ($tag) { Invoke-GitHubApi "repos/$($tool.repo)/releases/tags/$tag" }
                       else      { Invoke-GitHubApi "repos/$($tool.repo)/releases/latest" }
                $assets = foreach ($pattern in $tool.assets) {
                    $hit = @($rel.assets | Where-Object { $_.name -like $pattern })
                    if (-not $hit) { throw "no release asset matches '$pattern'" }
                    # Some rolling tags keep every past build as a separate asset.
                    if ($tool.PSObject.Properties['pick']?.Value -eq 'newest') {
                        $hit = $hit | Sort-Object { [datetime]$_.updated_at } | Select-Object -Last 1
                    }
                    $hit
                }
                # Rolling tags reuse the tag name, so the asset timestamp is part of the version.
                $stamp   = ($assets | ForEach-Object { [datetime]$_.updated_at } | Sort-Object | Select-Object -Last 1).ToString('yyyy-MM-dd')
                $version = "$($rel.tag_name) ($stamp)"
                $downloads = $assets | ForEach-Object { @{ Url = $_.browser_download_url; File = $_.name } }
            }
            'github-raw' {
                $sha  = (Invoke-GitHubApi "repos/$($tool.repo)/commits/HEAD").sha
                $tree = (Invoke-GitHubApi "repos/$($tool.repo)/git/trees/$sha").tree | Where-Object type -eq 'blob'
                # A pattern such as Icarus_Mod_Manager_*.zip follows the author's renames; the highest name wins.
                $files = @(foreach ($pattern in $tool.files) {
                    $hit = $tree.path | Where-Object { $_ -like $pattern } | Sort-Object | Select-Object -Last 1
                    if (-not $hit) { throw "no file in the repo matches '$pattern'" }
                    $hit
                })
                $version   = "$($sha.Substring(0, 10)) ($($files[0]))"
                $downloads = $files | ForEach-Object {
                    @{ Url = "https://raw.githubusercontent.com/$($tool.repo)/$sha/$([uri]::EscapeDataString($_))"; File = $_ }
                }
            }
            'url' {
                $head    = Invoke-WebRequest $tool.url -Method Head -Headers @{ 'User-Agent' = 'IcarusModding' }
                $version = [string]($head.Headers['Last-Modified'] | Select-Object -First 1)
                $downloads = @(@{ Url = $tool.url; File = (Split-Path $tool.url -Leaf) })
            }
            'lua-source' {
                # lua.org publishes source only; it is one gcc command to build.
                $version   = $tool.version
                $downloads = @(@{ Url = "https://www.lua.org/ftp/lua-$version.tar.gz"; File = "lua-$version.tar.gz"; Build = 'lua' })
            }
            default { throw "unknown type '$($tool.type)'" }
        }

        $sha256 = $tool.PSObject.Properties['sha256']?.Value
        if ($sha256) {
            if ($sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'its sha256 in tools.json is not 64 lower-case hex digits' }
            if (@($downloads).Count -ne 1) { throw 'a sha256 in tools.json is for an entry that downloads one file, and this one downloads several' }
        }
        $row.Version = $version
        if (-not $Force -and $state[$tool.name] -eq $version -and (Test-Path $dest)) {
            $row.Status = 'up to date'
        } else {
            $work = Join-Path $tempDir ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force $work | Out-Null
            try {
                # Everything is downloaded and checked before anything that is installed is touched.
                foreach ($d in $downloads) {
                    $file = Join-Path $work $d.File
                    Save-Url $d.Url $file
                    if ($sha256) {
                        $got = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()
                        if ($got -cne $sha256) { throw "$($d.File) is not the file tools.json names: its sha256 is $got, not $sha256. Nothing of it was installed." }
                    }
                }
                if (-not $extract -and (Test-Path $dest)) {
                    # Archives kept zipped carry their version in the file name; clear the old ones first.
                    foreach ($pattern in $tool.assets) { Get-ChildItem -LiteralPath $dest -Filter $pattern -File | Remove-Item -Force }
                }
                foreach ($d in $downloads) {
                    $file = Join-Path $work $d.File
                    if ($d['Build'] -eq 'lua') { Build-Lua $file $dest } else { Install-Payload $file $dest $extract }
                }
            } finally {
                Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
            }
            $row.Status = if ($state[$tool.name]) { "updated (was $($state[$tool.name]))" } else { 'installed' }
            $state[$tool.name] = $version
            # Reinstalling a tool wipes any patch layered on it; forget those so they reapply later in this run.
            $manifest | Where-Object { $_.PSObject.Properties['dest']?.Value -eq $tool.name } | ForEach-Object { $state.Remove($_.name) }
            $state | ConvertTo-Json | Set-Content $statePath
        }
    } catch {
        $row.Status = "FAILED: $($_.Exception.Message)"
    }
    Write-Host ("{0,-40} {1,-46} {2}" -f $row.Tool, $row.Version, $row.Status)
    [pscustomobject]$row
}

if (-not (Get-ChildItem -LiteralPath $tempDir -Force)) { Remove-Item -LiteralPath $tempDir -Force }

$failed = @($results | Where-Object Status -like 'FAILED*')
if ($failed) { Write-Warning "$($failed.Count) tool(s) failed."; exit 1 }
