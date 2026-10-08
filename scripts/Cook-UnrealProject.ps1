#requires -Version 7
<#
.SYNOPSIS
  Cooks assets of the Icarus project: one mod's own content into a pak (-Content), or everything else for a classic mod (-Mod).
.DESCRIPTION
  Runs the editor's cook headless (no window). Packages are cooked by name, and nothing they refer to, so no
  file of the game and no engine content is cooked along.

  -Content <Name> cooks the packages under Content\Mods\<Name> (the game's /Game/Mods/<Name>). Every import of
  the cooked files is then looked up in the game (check_imports.py), because the game stops on a missing one.
  What passes is packed to build\<Name>.pak with the mount point ../../../Icarus/Content/Mods/<Name>/, so the
  pak can only add files under its own folder. The name is spelled as the folder is.
  A run that stops over the content leaves no build\<Name>.pak. One that cannot start (no editor, too little
  memory, no list of native types) leaves the pak of the last cook as it is.

  Without -Content every asset of the project outside Content\Mods is cooked to build\_cook\_project\Content,
  at the paths the game uses, and its imports are checked the same way. -Mod copies the result into
  mods\<Mod>\content\, which Build-Mod.ps1 then packs. Content\Mods\<Name> belongs to -Content: it is never
  cooked or copied here. Every other asset of the project goes to the one mod named.
  Close the editor first if it has the project open with unsaved changes.

  Files of the game that Get-GameAsset.ps1 copied into the project (unreal\Icarus\GameFiles.txt) are never
  cooked, copied or packed.

  The cooker empties unreal\Icarus\Saved\Cooked\WindowsNoEditor at the start of every cook, so what an earlier
  cook left there is gone after the next one. The editor's own output is in build\cook\.
.EXAMPLE
  .\scripts\Cook-UnrealProject.ps1 -Content WaxSample
.EXAMPLE
  .\scripts\Cook-UnrealProject.ps1 -Mod My_Font_Mod
#>
[CmdletBinding()]
param(
    [string]$Mod,
    [string]$Content,
    [switch]$KeepStage,          # leave build\_cook\<Name> behind to see exactly what went into the pak
    [switch]$Force,              # start the editor although little memory is free
    [switch]$NoNatives,          # check the imports although there is no list of the game's native types
    [int]$TimeoutMinutes = 60
)
. "$PSScriptRoot\_common.ps1"

$cmd        = Join-Path $Root 'engine\UE_4.27\Engine\Binaries\Win64\UE4Editor-Cmd.exe'
$projectDir = Join-Path $Root 'unreal\Icarus'
$project    = Join-Path $projectDir 'Icarus.uproject'
$contentDir = Join-Path $projectDir 'Content'
$cooked     = Join-Path $projectDir 'Saved\Cooked\WindowsNoEditor\Icarus\Content'
$listFile   = Join-Path $projectDir 'GameFiles.txt'
$reader     = Join-Path $PSScriptRoot 'check_imports.py'
$parts      = '.uasset', '.umap', '.uexp', '.ubulk', '.uptnl', '.ufont'
if (-not (Test-Path $cmd)) { throw "Unreal Editor not found. Run scripts\Install-UnrealEditor.ps1." }
if ($Mod -and $Content) { throw 'Use -Content for a pak of new files or -Mod for a classic pak, not both.' }
if ($Mod -and -not (Test-Path (Join-Path $ModsDir $Mod))) { throw "mods\$Mod does not exist. Create it with New-Mod.ps1." }

# The files of the game in the project, as paths under Content with forward slashes.
function Get-GameFileSet {
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path $listFile) {
        foreach ($line in Get-Content $listFile) {
            $line = $line.Trim()
            if ($line -and -not $line.StartsWith('#') -and $line -notlike 'build *' -and $line -notlike 'asked *') { [void]$set.Add($line) }
        }
    }
    , $set
}

# Every package file below a folder: its path under Content, its /Game name, and what kind of file it is.
function Get-Packages([string]$folder) {
    $lines = @(python $reader cooked $folder)
    if ($LASTEXITCODE -ne 0) { throw "The package files under $folder could not be listed (check_imports.py cooked ended with $LASTEXITCODE)." }
    foreach ($line in $lines) {
        $kind, $path = $line -split "`t", 2
        $rel = [IO.Path]::GetRelativePath($contentDir, $path) -replace '\\', '/'
        [pscustomobject]@{ Kind = $kind; Rel = $rel; Name = '/Game/' + ($rel -replace '\.[^./]+$', '') }
    }
}

function Assert-EditorFree {
    $other = @(Get-Process 'UE4Editor-Cmd' -ErrorAction SilentlyContinue)
    if ($other) { throw "Another headless editor is running (process $($other[0].Id)). They share one cooked folder: wait for it to end." }
    $free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
    if ($free -lt 2 -and -not $Force) {
        throw ("Only {0:N1} GB of memory is free and the editor is not started under 2 (it held 0.6 GB in the one cook measured). Close something, or pass -Force." -f $free)
    }
}

# The import check needs a list of the game's native types. Said before the editor starts, not after the cook.
function Assert-NativeList {
    if ($NoNatives) { return }
    $said = @(python $reader natives 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { throw "$($said -join ' ') -NoNatives cooks and checks everything else without it." }
}

function Invoke-Editor([string[]]$Arguments, [string]$Log) {
    Assert-EditorFree
    New-Item -ItemType Directory -Force (Split-Path $Log -Parent) | Out-Null
    $all = @("`"$project`"") + $Arguments + @('-unattended', '-nopause', '-nosplash', '-nullrhi', '-stdout', '-NoLogTimes')
    $process = Start-Process -FilePath $cmd -ArgumentList $all -NoNewWindow -PassThru -RedirectStandardOutput $Log
    $null = $process.Handle
    try { $process.PriorityClass = 'BelowNormal' } catch { }
    if (-not $process.WaitForExit($TimeoutMinutes * 60000)) {
        $process.Kill($true)
        throw "The editor did not finish in $TimeoutMinutes minutes and was stopped. Its output is in $Log."
    }
    $process.ExitCode
}

# Cooks the packages named and nothing they refer to, then moves what was cooked to $stage (a Content folder).
function Invoke-NamedCook($packages, [string]$stage, [string]$log) {
    $batches = @()
    $batch = @()
    $length = 0
    foreach ($package in $packages) {
        if ($batch -and $length + $package.Name.Length -gt 8000) { $batches += , $batch; $batch = @(); $length = 0 }
        $batch += $package
        $length += $package.Name.Length + 1
    }
    if ($batch) { $batches += , $batch }
    $number = 0
    foreach ($batch in $batches) {
        $number++
        $batchLog = if ($batches.Count -gt 1) { $log -replace '\.log$', "-$number.log" } else { $log }
        $code = Invoke-Editor @('-run=cook', '-targetplatform=WindowsNoEditor', '-unversioned', '-cooksinglepackagenorefs',
            "-MAP=$(($batch.Name) -join '+')") $batchLog
        $result = Select-String -LiteralPath $batchLog -Pattern '(Success|Failure) - \d+ error\(s\), \d+ warning\(s\)' | Select-Object -Last 1
        if ($result) { Write-Host "  cook: $($result.Matches[0].Value)" }
        if ($code -ne 0) { throw "Cook failed (exit $code). Its output is in $batchLog." }
        foreach ($package in $batch) {
            $base = $package.Rel -replace '\.[^./]+$', ''
            $made = @($parts | Where-Object { Test-Path -LiteralPath (Join-Path $cooked "$base$_") })
            if (-not ($made | Where-Object { $_ -in '.uasset', '.umap' })) {
                throw "$($package.Name) was not cooked. The reason is in $batchLog."
            }
            foreach ($extension in $made) {
                $target = Join-Path $stage "$base$extension"
                New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
                Move-Item -LiteralPath (Join-Path $cooked "$base$extension") -Destination $target -Force
            }
        }
    }
}

# $folder holds the cooked files, $contentRoot is the Content folder they lie under (it gives each its /Game name).
function Invoke-ImportCheck([string]$folder, [string]$contentRoot) {
    $arguments = @($reader, $folder, '--content', $contentRoot, '--paks', (Get-IcarusPaths).Paks, '--repak', (Get-ToolExe repak))
    if ($NoNatives) { $arguments += '--no-natives' }
    $said = @(python @arguments 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $said | ForEach-Object { Write-Host "  $_" }
    if ($code -eq 0) { return }
    if ($code -eq 1 -and ($said | Where-Object { $_ -like 'result: FAIL*' })) {
        throw 'The cooked files import something the game does not have (above). Nothing was packed or copied.'
    }
    throw "The imports could not be checked (above; check_imports.py ended with $code), so nothing was packed or copied. This says nothing about the files."
}

function Remove-EmptyStages {
    $stages = Join-Path $BuildDir '_cook'
    if ((Test-Path -LiteralPath $stages) -and -not (Get-ChildItem -LiteralPath $stages -Force)) { Remove-Item -LiteralPath $stages }
}

$gameFiles = Get-GameFileSet
$listBuild = if (Test-Path $listFile) { (Get-Content $listFile | Where-Object { $_ -like 'build *' } | Select-Object -First 1) -replace '^build\s+', '' }
$build = (Get-IcarusSteamState)?.BuildId
if ($gameFiles.Count -and $listBuild -and $build -and $listBuild -ne $build) {
    Write-Warning "The game is build $build now and its files in the project were copied from build $listBuild. Run scripts\Get-GameAsset.ps1 -Refresh."
}
$times = [ordered]@{}
$watch = [Diagnostics.Stopwatch]::StartNew()

if ($Content) {
    if ($Content -notmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$' -or $Content -like 'pakchunk*') {
        throw "'$Content' cannot name a mod's content: use a letter, then letters, digits or _ (64 at most), and not a name that starts with pakchunk."
    }
    # The folder's own spelling is the name: it is what the /Game/Mods/<Name> paths inside the assets say.
    $there = @(Get-ChildItem (Join-Path $contentDir 'Mods') -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
    if ($Content -cnotin $there) {
        $same = @($there | Where-Object { $_ -eq $Content })
        if ($same.Count -eq 1) { Write-Host "The folder is Mods\$($same[0]); that name is used."; $Content = $same[0] }
    }
    $modDir = Join-Path $contentDir "Mods\$Content"
    $pak = Join-Path $BuildDir "$Content.pak"
    $packages = @(if (Test-Path $modDir) { Get-Packages $modDir })
    try {
        if (-not (Test-Path $modDir)) {
            throw "unreal\Icarus\Content\Mods\$Content does not exist. Make the mod's assets in the editor under /Game/Mods/$Content.$(if ($there) { " There is: $($there -join ', ')." })"
        }
        if (-not $packages) { throw "unreal\Icarus\Content\Mods\$Content holds no assets." }
        foreach ($package in $packages) {
            if ($gameFiles.Contains($package.Rel)) { throw "Content\$($package.Rel) is on the list of the game's files (GameFiles.txt). A mod's pak never holds a file of the game." }
            if ($package.Kind -eq 'cooked') { throw "Content\$($package.Rel) is a cooked file, so it came from the game or from another mod and is not yours to cook. Take it out of Mods\$Content." }
            if ($package.Kind -eq 'unopened') { throw "Content\$($package.Rel) could not be opened: another program holds it. Close that program and cook again." }
            if ($package.Kind -ne 'source') { throw "Content\$($package.Rel) is not an asset the editor wrote." }
        }
    } catch {
        # the folder no longer gives what the last pak holds
        if (Test-Path -LiteralPath $pak) { Remove-Item -LiteralPath $pak }
        throw
    }
    if (Test-Path (Join-Path $modDir 'ModActor.uasset')) {
        Write-Warning "ModActor at the top of a mod's folder is what UE4SS's own blueprint loader spawns for a pak of this name in LogicMods. Give it another name unless you mean that."
    }

    # Refusals that say nothing about the content come before the last pak is removed.
    Assert-NativeList
    Assert-EditorFree
    if (Test-Path -LiteralPath $pak) { Remove-Item -LiteralPath $pak }

    $stage = Join-Path $BuildDir "_cook\$Content"
    if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    $stageMod = Join-Path $stage "Content\Mods\$Content"
    $cookedMod = Join-Path $cooked "Mods\$Content"
    if (Test-Path $cookedMod) { Remove-Item -LiteralPath $cookedMod -Recurse -Force }

    Write-Host "Cooking $($packages.Count) package(s) of $Content, and nothing they refer to."
    Invoke-NamedCook $packages (Join-Path $stage 'Content') (Join-Path $BuildDir "cook\cook-$Content.log")
    $times['cook'] = $watch.Elapsed.TotalSeconds; $watch.Restart()

    Invoke-ImportCheck $stageMod (Join-Path $stage 'Content')
    $times['import check'] = $watch.Elapsed.TotalSeconds; $watch.Restart()

    $mount = "../../../Icarus/Content/Mods/$Content/"
    $repak = Get-ToolExe repak
    & $repak pack --quiet --version V11 --mount-point $mount $stageMod $pak
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $pak)) { throw 'Packing failed.' }

    # The pak is read back: it holds the mod's own cooked packages and nothing else, at the mod's own mount point, letter for letter.
    $allowed = @($packages | ForEach-Object { 'Icarus/Content/' + ($_.Rel -replace '\.[^./]+$', '') })
    $entries = @(& $repak list $pak)
    $strangers = @($entries | Where-Object { ($_ -replace '\.[^./]+$', '') -cnotin $allowed -or $gameFiles.Contains(($_ -replace '^Icarus/Content/', '')) })
    $info = @(& $repak info $pak)
    if ($strangers -or "mount point: $mount" -cnotin $info -or 'version: V11' -notin $info) {
        Remove-Item -LiteralPath $pak
        throw "The pak did not come out as it must (mount point $mount, version 11, only the mod's own files), so it was deleted. Unexpected: $(($strangers | Select-Object -First 5) -join ', ')"
    }
    $times['pack'] = $watch.Elapsed.TotalSeconds
    if (-not $KeepStage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
        Remove-EmptyStages
    }

    Write-Host ("Took " + (($times.Keys | ForEach-Object { "{0} {1:N0} s" -f $_, $times[$_] }) -join ', ') + '.')
    Write-Host ("Built {0}: {1:N1} KB, {2} file(s) of {3} package(s), mount point {4}{5}" -f $pak, ((Get-Item $pak).Length / 1KB),
        $entries.Count, $packages.Count, $mount, $(if ($build) { ", checked against game build $build" }))
    return
}

# Content\Mods\<Name> is a mod's own pak (-Content); a classic mod gets the project's other assets.
$all = @(Get-Packages $contentDir)
$own = @($all | Where-Object { -not $gameFiles.Contains($_.Rel) })
$inMods = @($own | Where-Object { $_.Rel -like 'Mods/*' })
$rest = @($own | Where-Object { $_.Rel -notlike 'Mods/*' })
$packages = @($rest | Where-Object { $_.Kind -eq 'source' })
$skipped = @($rest | Where-Object { $_.Kind -eq 'cooked' })
$unread = @($rest | Where-Object { $_.Kind -notin 'source', 'cooked' })
if ($skipped) { Write-Warning "$($skipped.Count) cooked file(s) in Content are not on the list of the game's files. A cooked file cannot be cooked again, so they were left out: $(($skipped.Rel | Select-Object -First 3) -join ', ')" }
if ($unread) { Write-Warning "$($unread.Count) file(s) in Content could not be read as packages (not a package, or held by another program) and were left out: $(($unread.Rel | Select-Object -First 3) -join ', ')" }
$stage = Join-Path $BuildDir '_cook\_project'
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
$stageContent = Join-Path $stage 'Content'
Write-Host "Cooking the project's $($packages.Count) own package(s) by name.$(if ($gameFiles.Count) { " Its $($gameFiles.Count) file(s) of the game are not cooked." })"
if ($inMods) {
    $names = @($inMods | ForEach-Object { ($_.Rel -split '/')[1] } | Where-Object { $_ -notmatch '\.' } | Sort-Object -Unique)
    Write-Host "Left out, cooked with -Content: $(if ($names) { $names -join ', ' } else { 'what lies in Content\Mods' }) ($($inMods.Count) package(s) under Content\Mods)."
}
if (-not $packages) {
    Remove-EmptyStages
    Write-Host "Nothing was cooked$(if ($Mod) { ", so nothing was copied to mods\$Mod\content" })."
    return
}
Assert-NativeList
New-Item -ItemType Directory -Force $stageContent | Out-Null
Invoke-NamedCook $packages $stageContent (Join-Path $BuildDir 'cook\cook-project.log')
Invoke-ImportCheck $stageContent $stageContent
$files = @(Get-ChildItem $stageContent -Recurse -File)
Write-Host "Cooked $($files.Count) file(s) under $stageContent"
if ($Mod -and $files) {
    $dest = Join-Path $ModsDir "$Mod\content"
    New-Item -ItemType Directory -Force $dest | Out-Null
    Get-ChildItem -LiteralPath $stageContent | Where-Object Name -ne 'Mods' | Copy-Item -Destination $dest -Recurse -Force
    Write-Host "Copied to mods\$Mod\content. Build with: .\scripts\Build-Mod.ps1 -Name $Mod"
}
