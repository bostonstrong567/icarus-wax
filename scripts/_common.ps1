# Shared helpers for the Icarus modding workspace. Dot-source from other scripts:
#   . "$PSScriptRoot\_common.ps1"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:IcarusAppId = 1149460
$script:Root        = Split-Path -Parent $PSScriptRoot
$script:ToolsDir    = Join-Path $Root 'tools'
$script:RefDir      = Join-Path $Root 'reference'
$script:GameDataDir = Join-Path $Root 'game-data'
$script:ModsDir     = Join-Path $Root 'mods'
$script:BuildDir    = Join-Path $Root 'build'
$script:BackupDir   = Join-Path $Root 'backups'

function Get-WorkspaceConfig {
    $path = Join-Path $Root 'icarus.config.json'
    if (Test-Path $path) { return Get-Content $path -Raw | ConvertFrom-Json -AsHashtable }
    return @{}
}

function Get-SteamLibraries {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return @() }
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (-not (Test-Path $vdf)) { return @($steam) }
    Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' |
        ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' }
}

# Reads the Steam app manifest for Icarus. Returns $null if Steam doesn't know about the game.
function Get-IcarusSteamState {
    foreach ($lib in Get-SteamLibraries) {
        $acf = Join-Path $lib "steamapps\appmanifest_$IcarusAppId.acf"
        if (-not (Test-Path $acf)) { continue }
        $text = Get-Content $acf -Raw
        $get = { param($k) if ($text -match "`"$k`"\s+`"([^`"]*)`"") { $Matches[1] } }
        $flags = [int](& $get 'StateFlags')
        $toDl  = [double](& $get 'BytesToDownload')
        $dl    = [double](& $get 'BytesDownloaded')
        return [pscustomobject]@{
            Library        = $lib
            GameDir        = Join-Path $lib ('steamapps\common\' + (& $get 'installdir'))
            StagingDir     = Join-Path $lib "steamapps\downloading\$IcarusAppId"
            BuildId        = & $get 'buildid'
            TargetBuildId  = & $get 'TargetBuildID'
            StateFlags     = $flags
            FullyInstalled = [bool]($flags -band 4) -and -not ($flags -band 2)
            DownloadPct    = if ($toDl -gt 0) { [math]::Round(100 * $dl / $toDl, 1) } else { $null }
        }
    }
}

# Game root (the folder containing Icarus\ and Engine\). Config override wins over Steam detection.
function Get-IcarusGameDir {
    param([switch]$AllowMissing)
    $cfg = Get-WorkspaceConfig
    $dir = if ($cfg['gameDir']) { $cfg['gameDir'] } else { (Get-IcarusSteamState)?.GameDir }
    $exe = if ($dir) { Join-Path $dir 'Icarus\Binaries\Win64\Icarus-Win64-Shipping.exe' }
    if ($dir -and (Test-Path $exe)) { return $dir }
    if ($AllowMissing) { return $null }
    $state = Get-IcarusSteamState
    if ($state -and -not $state.FullyInstalled) {
        throw "Icarus is not fully installed yet (Steam download at $($state.DownloadPct)%). Let Steam finish, then re-run."
    }
    throw "Icarus install not found. Set `"gameDir`" in icarus.config.json."
}

function Get-IcarusPaths {
    $game = Get-IcarusGameDir
    $content = Join-Path $game 'Icarus\Content'
    [pscustomobject]@{
        GameDir  = $game
        Content  = $content
        DataPak  = Join-Path $content 'Data\data.pak'
        Paks     = Join-Path $content 'Paks'
        ModsPaks = Join-Path $content 'Paks\mods'
        Win64    = Join-Path $game 'Icarus\Binaries\Win64'
        Saved    = Join-Path $env:LOCALAPPDATA 'Icarus\Saved'
    }
}

function Get-ToolManifest {
    Get-Content (Join-Path $Root 'tools.json') -Raw | ConvertFrom-Json
}

# Resolves a tool's executable from tools.json by its short name, e.g. 'repak' for "pak\repak".
function Get-ToolExe {
    param([Parameter(Mandatory)][string]$Name)
    $manifest = Get-ToolManifest
    $tool = @($manifest.tools) + @($manifest.manual) |
        Where-Object { (Split-Path $_.name -Leaf) -eq $Name -and $_.PSObject.Properties['exe'] } | Select-Object -First 1
    if (-not $tool) { throw "No tool named '$Name' with an exe in tools.json." }
    $exe = Join-Path $ToolsDir $tool.name $tool.exe
    if (-not (Test-Path $exe)) { throw "$Name not found at $exe. Run scripts\Get-Tools.ps1." }
    $exe
}

function Assert-GameNotRunning {
    if (Get-Process 'Icarus-Win64-Shipping' -ErrorAction SilentlyContinue) {
        throw 'Icarus is running. Close the game first.'
    }
}
