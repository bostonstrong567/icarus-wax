#requires -Version 7
<#
.SYNOPSIS
  Tests wax\runtime\Wax-Import.ps1, the script behind wax:// links, in throwaway folders under build\import-test.
.DESCRIPTION
  The script is run by Windows PowerShell 5.1 (powershell.exe), which is what a link starts, from a copy whose
  settings lines are replaced: the catalogue is a stand-in on 127.0.0.1 with a key of its own (import-stand-in.mjs),
  the question is answered by the copy itself, the link is registered under another scheme name, and the log goes
  to the test's folder. Covered: command lines that try to slip extra arguments in, a good mod from link to game,
  "No" at the question, signatures, size limits, every rule for what a zip may hold, and the registration.
  The real boxes are tested too, from a copy that asks as the shipped file does: it runs on a desktop of its own,
  which no screen shows (hidden-desk.cs), so no window comes up over what the player is doing.
  Nothing here touches the real game, Wax's own folders, the real wax:// registration or the network.
  It needs node and the C# compiler that comes with Windows. It has its own folder, so it can run beside the
  other tests, but not beside itself. It takes about two minutes.
.EXAMPLE
  .\wax\release\test\Test-WaxImport.ps1 *> build\import-test.log
#>
[CmdletBinding()]
param()
. "$PSScriptRoot\..\..\..\scripts\_common.ps1"

$shipped   = Join-Path $Root 'wax\runtime\Wax-Import.ps1'
$work      = Join-Path $BuildDir 'import-test'
$win64     = Join-Path $work 'game\Icarus\Binaries\Win64'
$wax       = Join-Path $win64 'ue4ss\Mods\Wax'
$mods      = Join-Path $wax 'mods'
$copy      = Join-Path $wax 'Wax-Import.ps1'
$logFile   = Join-Path $work 'appdata\Wax\import.log'
$zips      = Join-Path $work 'zips'
$marker    = Join-Path $work 'marker.txt'
$scheme    = 'wax-test-import'
$schemeKey = "HKCU:\Software\Classes\$scheme"
$shell     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$helper    = Join-Path $PSScriptRoot 'import-stand-in.mjs'
$node      = (Get-Command node -CommandType Application | Select-Object -First 1).Source
$ownerKey  = '8b37ac88ea0d9e8a8d239b731f1ba1d12fe163c605f6fe3c3933253e36421a953c5d04fdcb94e3934223e41aeb511593788140a7865c00ab2f6ad67746900d62'
$notALink  = 'This is not a link to a Wax mod. Nothing was downloaded and nothing was changed.'

$script:passed = 0
$script:failures = @()
function Check([string]$What, $Ok, [string]$Detail = '') {
    if ($Ok) { $script:passed++; Write-Host "  ok    $What" }
    else { $script:failures += $What; Write-Host "  FAIL  $What  $Detail" -ForegroundColor Red }
}
function Section([string]$Name) { Write-Host ''; Write-Host $Name -ForegroundColor Cyan }

# Links are removed as links, so clearing the test folder can never reach outside it.
function Clear-Folder([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-ChildItem -LiteralPath $Path -Recurse -Force -Attributes ReparsePoint | ForEach-Object { [System.IO.Directory]::Delete($_.FullName) }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Get-Link([string]$Name) {
    try { [string](Get-ItemProperty -Path "HKCU:\Software\Classes\$Name\shell\open\command" -ErrorAction Stop).'(default)' } catch { '' }
}

# The only way to change what the script uses: a copy with its settings lines replaced.
function Set-Copy {
    param([string]$Question = 'yes', [string]$Catalogue = $script:catalogue.Base, [string]$Key = $script:catalogue.Key)
    $set = [ordered]@{ Catalogue = $Catalogue; PublicKey = $Key; Question = $Question; ClassKey = $schemeKey; LogFile = $logFile }
    $found = @{}
    $lines = foreach ($line in [System.IO.File]::ReadAllLines($shipped)) {
        $hit = $set.Keys | Where-Object { $line -match "^\`$$_\s*=" } | Select-Object -First 1
        if ($hit) { $found[$hit] = 1 + [int]$found[$hit]; "`$$hit = '$($set[$hit])'" } else { $line }
    }
    foreach ($name in $set.Keys) { if ($found[$name] -ne 1) { throw "Wax-Import.ps1 does not set `$$name on exactly one line." } }
    [System.IO.File]::WriteAllText($copy, ($lines -join "`n") + "`n", [System.Text.Encoding]::ASCII)
}

# Starts a program with a command line exactly as given, the way Windows starts what a link is registered to.
function Invoke-Raw([string]$CommandLine, [int]$Seconds = 120) {
    if ($CommandLine -notmatch '(?s)^"([^"]+)" (.*)$') { throw "Not a command line: $CommandLine" }
    $info = [System.Diagnostics.ProcessStartInfo]::new($Matches[1], $Matches[2])
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.WorkingDirectory = $work
    $process = [System.Diagnostics.Process]::Start($info)
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($Seconds * 1000)) {
        $process.Kill()
        return [pscustomobject]@{ Code = -1; Text = "still running after $Seconds seconds"; Error = '' }
    }
    $process.WaitForExit()
    [pscustomobject]@{ Code = $process.ExitCode; Text = $out.Result.Trim() -replace "`r`n", "`n"; Error = $err.Result.Trim() }
}
function Assert-NoBoxes {
    if ([System.IO.File]::ReadAllText($copy) -match "(?m)^\`$Question = 'ask'") { throw 'This copy puts boxes on the screen. It is only run on the hidden desktop.' }
}
function Invoke-Link([string]$Link) { Assert-NoBoxes; Invoke-Raw $script:linkCommand.Replace('%1', $Link) }
function Invoke-Switch([string]$Switch) { Assert-NoBoxes; Invoke-Raw "`"$shell`" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File `"$copy`" $Switch" }

# Runs the link on a desktop of its own and presses the buttons of the boxes that come up, in order.
function Invoke-Hidden([string]$Link, [string[]]$Presses) {
    $boxes = [HiddenDesk]::Run($script:linkCommand.Replace('%1', $Link), $work, $Presses, 90)
    [pscustomobject]@{ Code = [HiddenDesk]::ExitCode; Boxes = @($boxes); Problem = [HiddenDesk]::Problem }
}

function Start-Catalogue([string]$Name) {
    $folder = Join-Path $work $Name
    New-Item -ItemType Directory -Force $folder | Out-Null
    $cases = Join-Path $folder 'cases.json'
    Set-Content -LiteralPath $cases -Value '{}'
    $process = Start-Process -FilePath $node -ArgumentList "`"$helper`" serve `"$cases`" `"$folder`"" -PassThru -WindowStyle Hidden
    $portFile = Join-Path $folder 'port.txt'
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $portFile); $i++) { Start-Sleep -Milliseconds 100 }
    [pscustomobject]@{ Process = $process; Cases = $cases; Requests = Join-Path $folder 'requests.log'
        Base = "http://127.0.0.1:$((Get-Content -LiteralPath $portFile -Raw).Trim())"; Key = (Get-Content -LiteralPath (Join-Path $folder 'key.txt') -Raw).Trim() }
}
function Get-Requests($Server) { @(Get-Content -LiteralPath $Server.Requests | Where-Object { $_ }) }
function Clear-Requests { foreach ($server in $script:catalogue, $script:attacker) { [System.IO.File]::WriteAllText($server.Requests, '') } }
function Set-Cases($Server, $Cases) { $Cases | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Server.Cases }

# Every file and folder under a folder, as one text: two of these are equal only when nothing changed.
function Get-Print([string]$Dir) {
    $base = (Get-Item -LiteralPath $Dir -Force).FullName.TrimEnd('\')
    $lines = @(Get-ChildItem -LiteralPath "$base\" -Recurse -Force | ForEach-Object {
        $relative = $_.FullName.Substring($base.Length + 1)
        if ($_.PSIsContainer) { "dir:$relative" } else { "$relative=" + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    ($lines | Sort-Object) -join "`n"
}
function Get-Log { if (Test-Path -LiteralPath $logFile) { @(Get-Content -LiteralPath $logFile) } else { @() } }
function Get-Taken {
    $file = Join-Path $wax 'run\taken.txt'
    if (Test-Path -LiteralPath $file) { [System.IO.File]::ReadAllText($file) } else { '' }
}
function Clear-Taken { Remove-Item -LiteralPath (Join-Path $wax 'run\taken.txt') -Force -ErrorAction SilentlyContinue }
# The wake file may stay when nothing took the request: the game takes it away the next time it looks.
function Test-RunClean {
    @(Get-ChildItem -LiteralPath (Join-Path $wax 'run\in') -Force | Where-Object Name -ne 'wake').Count -eq 0 -and @(Get-ChildItem -LiteralPath (Join-Path $wax 'run\out') -Force).Count -eq 0
}

$script:zipSpec = [System.Collections.Generic.List[object]]::new()
function Add-Zip([string]$Name, [object[]]$Entries) {
    $out = Join-Path $zips "$Name.zip"
    $script:zipSpec.Add(@{ out = $out; entries = $Entries })
    $out
}
# Another test may have a stand-in for the game up for its own checks. This one waits until that is gone.
function Wait-OtherGames {
    for ($i = 0; $i -lt 600; $i++) {
        $others = @(Get-Process -Name 'Icarus-Win64-Shipping' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and
            $_.Path.StartsWith($BuildDir, [System.StringComparison]::OrdinalIgnoreCase) -and -not $_.Path.StartsWith($work, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($others.Count -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }
}
function Start-Game([string]$Mode = '') {
    Wait-OtherGames
    $process = Start-Process -FilePath $gameExe -ArgumentList "`"$wax`" $Mode" -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 600
    $process
}
function Stop-Game($Process) {
    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    $Process.WaitForExit(5000) | Out-Null
}

$realLinkBefore = Get-Link 'wax'
$realLog = Join-Path $env:LOCALAPPDATA 'Wax\import.log'
function Get-RealLog { if (Test-Path -LiteralPath $realLog) { $item = Get-Item -LiteralPath $realLog; "$($item.Length) $($item.LastWriteTimeUtc.Ticks)" } else { 'none' } }
$realLogBefore = Get-RealLog
$luamodsBefore = (Get-ChildItem -LiteralPath (Join-Path $Root 'luamods') -Force | ForEach-Object Name | Sort-Object) -join '|'

Section 'Setting up build\import-test'
if (Test-Path $schemeKey) { Remove-Item -Path $schemeKey -Recurse -Force }
Get-Process -Name 'Icarus-Win64-Shipping' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($work, [System.StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force
Clear-Folder $work
New-Item -ItemType Directory -Force $work, $mods, (Join-Path $wax 'run\in'), (Join-Path $wax 'run\out'), (Join-Path $wax 'saved'), $zips | Out-Null
Set-Content -LiteralPath (Join-Path $win64 'tbb12.dll') -Value 'a game file'
$state = 'return { enabled = { TestMod = true, MyMod = true }, known = { "TestMod", "MyMod" } }'
Set-Content -LiteralPath (Join-Path $wax 'saved\wax.mods.lua') -Value $state
New-Item -ItemType Directory -Force (Join-Path $mods 'MyMod') | Out-Null
Set-Content -LiteralPath (Join-Path $mods 'MyMod\init.lua') -Value 'print("mine")'
$psVersion = (& $shell -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
Check "powershell.exe is Windows PowerShell 5.1 ($psVersion)" ($psVersion -like '5.1*')

# Stands in for the game: a process with the game's name that takes requests from Wax\run\in as Wax does.
$gameExe = Join-Path $win64 'Icarus-Win64-Shipping.exe'
$gameSource = Join-Path $work 'stand-in.cs'
Set-Content -LiteralPath $gameSource -Value @'
using System;
using System.IO;
using System.Threading;
public static class Stand {
    public static void Main(string[] args) {
        string wax = args[0];
        bool refuse = args.Length > 1 && args[1] == "refuse";
        string inbox = Path.Combine(wax, @"run\in");
        DateTime until = DateTime.UtcNow.AddSeconds(300);
        while (DateTime.UtcNow < until) {
            Thread.Sleep(15);
            string wake = Path.Combine(inbox, "wake");
            if (!File.Exists(wake)) continue;
            try { File.Delete(wake); } catch { }
            foreach (string request in Directory.GetFiles(inbox, "*.lua")) {
                string text;
                try { text = File.ReadAllText(request); File.Delete(request); } catch { continue; }
                File.AppendAllText(Path.Combine(wax, @"run\taken.txt"), text + "[end]");
                string id = text.Substring(5, text.IndexOf('\n') - 5);
                string reply = refuse ? "{\"ok\":false,\"error\":\"no\",\"output\":[],\"id\":\"" + id + "\"}" : "{\"ok\":true,\"values\":[true],\"output\":[],\"id\":\"" + id + "\"}";
                File.WriteAllText(Path.Combine(wax, @"run\out\" + id + ".json"), reply);
            }
        }
    }
}
'@
& (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:winexe "/out:$gameExe" $gameSource | Out-Null
Check 'a stand-in for the game could be built' (Test-Path -LiteralPath $gameExe)

# The zips. Each refused one is paired with the words the refusal has to hold.
$escaped = $work.Replace('\', '/') + '/escaped'
$one = { param($id) @{ name = "$id/init.lua"; text = 'x = 1' } }
$goodEntries = @{ name = 'TestMod/' }, @{ name = 'TestMod/init.lua'; text = 'print("one")' }, @{ name = 'TestMod/mod.lua'; text = 'return { name = "Test Mod", version = "1.0.0" }' },
    @{ name = 'TestMod/art/note.txt'; text = 'a note'; method = 0 }, @{ name = 'TestMod/empty/' }
$good = Add-Zip 'good' $goodEntries
$good2 = Add-Zip 'good2' @(@{ name = 'TestMod/init.lua'; text = 'print("two")' }, @{ name = 'TestMod/mod.lua'; text = 'return { name = "Test Mod", version = "1.1.0" }' })
$plain = { param($id) Add-Zip $id @((& $one $id)) }
$refused = [ordered]@{
    Climber    = @('a path that is not allowed: Climber/\.\./\.\./escaped\.lua', @{ name = 'Climber/../../escaped.lua'; text = 'x = 2' })
    Upward     = @('a path that is not allowed', @{ name = '../Upward/escaped.lua'; text = 'x = 2' })
    Backslash  = @('a path that is not allowed', @{ name = 'Backslash\..\..\escaped.lua'; text = 'x = 2' })
    Drive      = @('a path that is not allowed', @{ name = "$escaped/drive.lua"; text = 'x = 2' })
    Absolute   = @('a path that is not allowed', @{ name = $escaped.Substring(2) + '/absolute.lua'; text = 'x = 2' })
    Stream     = @('a path that is not allowed', @{ name = 'Stream/init.lua:hidden.lua'; text = 'x = 2' })
    Outside    = @('a file outside its own folder: Other/init\.lua', @{ name = 'Other/init.lua'; text = 'x = 2' })
    LowerCase  = @('a file outside its own folder: lowercase/extra\.lua', @{ name = 'lowercase/extra.lua'; text = 'x = 2' })
    NamedCon   = @('a name that Windows keeps for itself: NamedCon/CON\.lua', @{ name = 'NamedCon/CON.lua'; text = 'x = 2' })
    NamedNul   = @('a name that Windows keeps for itself: NamedNul/nul', @{ name = 'NamedNul/nul'; text = 'x = 2' })
    NamedCom   = @('a name that Windows keeps for itself: NamedCom/com1\.txt', @{ name = 'NamedCom/com1.txt'; text = 'x = 2' })
    NamedAux   = @('a name that Windows keeps for itself: NamedAux/aux/inside\.lua', @{ name = 'NamedAux/aux/inside.lua'; text = 'x = 2' })
    NamedLpt   = @('a name that Windows keeps for itself: NamedLpt/LPT9\.tar\.lua', @{ name = 'NamedLpt/LPT9.tar.lua'; text = 'x = 2' })
    NulSpace   = @('a name that Windows keeps for itself: NulSpace/nul \.txt', @{ name = 'NulSpace/nul .txt'; text = 'x = 2' })
    EndDot     = @('a path that is not allowed: EndDot/a\./b\.lua', @{ name = 'EndDot/a./b.lua'; text = 'x = 2' })
    EndSpace   = @('a path that is not allowed: EndSpace/a /b\.lua', @{ name = 'EndSpace/a /b.lua'; text = 'x = 2' })
    FileDot    = @('a path that is not allowed', @{ name = 'FileDot/b.lua.'; text = 'x = 2' })
    Empty      = @('a path that is not allowed', @{ name = 'Empty//b.lua'; text = 'x = 2' })
    Accent     = @('a path that is not allowed', @{ name = "Accent/caf$([char]0xE9).lua"; text = 'x = 2' })
    Dollar     = @('a path that is not allowed', @{ name = 'Dollar/a$b.lua'; text = 'x = 2' })
    Deep       = @('a path that is not allowed', @{ name = 'Deep/' + ((1..16 | ForEach-Object { 'a' }) -join '/') + '/b.lua'; text = 'x = 2' })
    Program    = @('a kind of file that is not allowed: Program/run\.exe', @{ name = 'Program/run.exe'; text = 'MZ' })
    Script     = @('a kind of file that is not allowed: Script/run\.ps1', @{ name = 'Script/run.ps1'; text = 'calc' })
    Library    = @('a kind of file that is not allowed', @{ name = 'Library/bin/hook.dll'; text = 'MZ' })
    Bare       = @('a kind of file that is not allowed', @{ name = 'Bare/LICENSE'; text = 'MIT' })
    Origin     = @('a name that Wax keeps for itself: Origin/wax\.origin', @{ name = 'Origin/wax.origin'; text = "id=Origin`r`nversion=9.9.9`r`n" })
    OriginCaps = @('a name that Wax keeps for itself: OriginCaps/WAX\.ORIGIN', @{ name = 'OriginCaps/WAX.ORIGIN'; text = "id=OriginCaps`r`nversion=9.9.9`r`n" })
    Marked     = @('a name that Wax keeps for itself: Marked/wax\.new', @{ name = 'Marked/wax.new'; text = "new`r`n" })
    MarkedCaps = @('a name that Wax keeps for itself: MarkedCaps/Wax\.New', @{ name = 'MarkedCaps/Wax.New'; text = '' })
    MarkedDeep = @('a name that Wax keeps for itself: MarkedDeep/data/WAX\.NEW', @{ name = 'MarkedDeep/data/WAX.NEW'; text = 'new' })
    MarkFolder = @('a name that Wax keeps for itself: MarkFolder/wax\.new/inside\.lua', @{ name = 'MarkFolder/wax.new/inside.lua'; text = 'x = 2' })
    Link       = @('a link, which is not allowed: Link/link\.lua', @{ name = 'Link/link.lua'; text = '../../saved/wax.mods.lua'; madeBy = 0x0314; attributes = 0xA1FF0000 })
    Device     = @('a link, which is not allowed', @{ name = 'Device/device.lua'; text = ''; madeBy = 0x0314; attributes = 0x21A40000 })
    Twice      = @('the same path twice', @{ name = 'Twice/Init.lua'; text = 'x = 2' })
    Both       = @('one name as a file and as a folder', @{ name = 'Both/a.lua'; text = 'x = 2' }, @{ name = 'Both/a.lua/b.lua'; text = 'x = 3' })
    Locked     = @('a locked file', @{ name = 'Locked/closed.lua'; text = 'x = 2'; flags = 0x0801 })
    Packed     = @('packed in a way that is not allowed', @{ name = 'Packed/odd.lua'; text = 'x = 2'; method = 12 })
    TwoNames   = @('not a zip that can be read', @{ name = 'TwoNames/shown.lua'; localName = 'TwoNames/other.lua'; text = 'x = 2' })
    Liar       = @('does not unpack to the size it gives', @{ name = 'Liar/data.txt'; zeros = 5000; declared = 10 })
    Bomb       = @('unpacks to more than a mod may be, so it was stopped', @{ name = 'Bomb/data.txt'; zeros = 40MB + 4096; declared = 1000 })
    Honest     = @('unpacks to more than a mod may be, so it was not unpacked', @{ name = 'Honest/a.txt'; zeros = 21MB }, @{ name = 'Honest/b.txt'; zeros = 21MB })
}
$refusedZip = @{}
foreach ($id in $refused.Keys) { $refusedZip[$id] = Add-Zip $id (@((& $one $id)) + @($refused[$id] | Select-Object -Skip 1)) }
$refused['NoInit'] = @('has no init\.lua')
$refusedZip['NoInit'] = Add-Zip 'NoInit' @(@{ name = 'NoInit/mod.lua'; text = 'return {}' })
$refused['Nothing'] = @('has no init\.lua')
$refusedZip['Nothing'] = Add-Zip 'Nothing' @()
$refused['Many'] = @('more files than a mod may have')
$refusedZip['Many'] = Add-Zip 'Many' (@((& $one 'Many')) + @(1..500 | ForEach-Object { @{ name = "Many/file$_.txt"; text = 'x' } }))
$refused['NotZip'] = @('not a zip that can be read')
$refusedZip['NotZip'] = $gameSource
$full = Add-Zip 'Full' (@((& $one 'Full')) + @(1..499 | ForEach-Object { @{ name = "Full/file$_.txt"; text = 'x' } }))
$xZip = & $plain 'X'
$yZip = & $plain 'Y'
$signedZip = & $plain 'Signed'
$boxedZip = & $plain 'Boxed'
$specFile = Join-Path $work 'zips.json'
@{ zips = $script:zipSpec } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $specFile
& $node $helper zip $specFile
Check "the helper wrote the $($script:zipSpec.Count) zips the tests use" ($LASTEXITCODE -eq 0 -and @(Get-ChildItem -LiteralPath $zips -Filter *.zip).Count -eq $script:zipSpec.Count)

$script:catalogue = Start-Catalogue 'catalogue'
$script:attacker = Start-Catalogue 'attacker'
try {
    $cases = [ordered]@{
        testmod = @{ id = 'TestMod'; name = 'Test Mod'; author = 'Ada Lovelace'; version = '1.0.0'; zip = $good }
        x = @{ id = 'X'; name = 'X'; author = 'Nobody'; version = '1.0.0'; zip = $xZip }
        y = @{ id = 'Y'; name = 'Y'; author = 'Nobody'; version = '1.0.0'; zip = $yZip }
    }
    Set-Cases $script:catalogue $cases
    Set-Cases $script:attacker $cases
    Check 'two stand-ins for the catalogue are running, each with a key of its own' ($script:catalogue.Key -match '^[0-9a-f]{128}$' -and
        $script:attacker.Key -match '^[0-9a-f]{128}$' -and $script:catalogue.Key -ne $script:attacker.Key -and $script:catalogue.Key -ne $ownerKey)

    Section 'The file that ships'
    $text = [System.IO.File]::ReadAllText($shipped)
    $bytes = [System.IO.File]::ReadAllBytes($shipped)
    Check 'it is plain ASCII' (-not ($bytes | Where-Object { $_ -gt 126 -or ($_ -lt 32 -and $_ -notin 10, 13) }))
    $parsed = & $shell -NoLogo -NoProfile -Command "`$e = `$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$shipped', [ref]`$null, [ref]`$e); @(`$e).Count"
    Check 'Windows PowerShell 5.1 reads it without a syntax error' ("$parsed".Trim() -eq '0') "$parsed"
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($shipped, [ref]$null, [ref]$errors)
    $all = $ast.FindAll({ $true }, $true)
    $variables = @($all | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] })
    Check 'it declares no parameters, so PowerShell binds nothing by name or by the start of a name' ($null -eq $ast.ParamBlock -and
        -not ($all | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -match 'CmdletBinding|Parameter' }))
    Check 'it reads its arguments in one place' (@($variables | Where-Object { $_.VariablePath.UserPath -eq 'args' }).Count -eq 1)
    $outside = @($variables | Where-Object { $_.VariablePath.IsDriveQualified } | ForEach-Object { $_.Extent.Text } | Sort-Object -Unique)
    Check 'it reads nothing from the environment' ($outside.Count -eq 0 -and $text -notmatch 'GetEnvironmentVariable|ExpandEnvironmentVariables|Get-ChildItem\s+env|Get-Item\s+env') ($outside -join ', ')
    $settings = [ordered]@{ Catalogue = 'https://wax-icarus.duckdns.org'; PublicKey = $ownerKey; Question = 'ask'; ClassKey = 'HKCU:\Software\Classes\wax' }
    $assignments = @($all | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] })
    $first = @($ast.EndBlock.Statements | Select-Object -First 5)
    $firstNames = @($first | ForEach-Object { if ($_ -is [System.Management.Automation.Language.AssignmentStatementAst]) { $_.Left.VariablePath.UserPath } })
    Check 'its first five lines of code set the catalogue, the key, the question, the registry key and the log file' (($firstNames -join ',') -eq 'Catalogue,PublicKey,Question,ClassKey,LogFile') ($firstNames -join ',')
    foreach ($name in $settings.Keys) {
        $sets = @($assignments | Where-Object { $_.Left.VariablePath.UserPath -eq $name })
        $value = if ($sets.Count -eq 1) { $sets[0].Right.Extent.Text.Trim() } else { '' }
        Check "`$$name is set once, to a fixed text: $($settings[$name].Substring(0, [math]::Min(40, $settings[$name].Length)))" ($sets.Count -eq 1 -and $value -ceq "'$($settings[$name])'") $value
    }
    Check '$LogFile is set once' (@($assignments | Where-Object { $_.Left.VariablePath.UserPath -eq 'LogFile' }).Count -eq 1)
    $q = [System.Security.Cryptography.ECPoint]::new()
    $q.X = [Convert]::FromHexString($ownerKey.Substring(0, 64))
    $q.Y = [Convert]::FromHexString($ownerKey.Substring(64))
    $point = [System.Security.Cryptography.ECParameters]::new()
    $point.Curve = [System.Security.Cryptography.ECCurve+NamedCurves]::nistP256
    $point.Q = $q
    $onCurve = try { [System.Security.Cryptography.ECDsa]::Create($point).Dispose(); $true } catch { $false }
    Check 'the key in it is a point on the P-256 curve' $onCurve
    $commands = @($all | Where-Object { $_ -is [System.Management.Automation.Language.CommandAst] } | ForEach-Object { $_.GetCommandName() } | Sort-Object -Unique)
    $unwanted = @($commands | Where-Object { $_ -in 'Invoke-Expression', 'iex', 'Invoke-Command', 'Start-Process', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Expand-Archive', 'Import-Module', 'Get-Content', 'Read-Host' })
    Check 'it runs no text as code, starts no program and unpacks with no ready-made command' ($unwanted.Count -eq 0 -and $text -notmatch 'ExtractToDirectory|ScriptBlock|\.Invoke\(') ($unwanted -join ', ')
    Check 'the words Server and Quiet are nowhere in it' ($text -notmatch 'Server|Quiet')
    Check 'it holds no Lua to send to the game' ($text -notmatch 'Wax\.mods|Wax\.ui|set_enabled|request_reload|Notify')
    Check 'the link it registers hides no window and skips no rule for scripts' ($text -match '-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "\{1\}" "%1"' -and
        @([regex]::Matches($text, 'Bypass|Hidden')).Count -eq 2 -and $text -match "'WindowStyle\\s\+Hidden\|ExecutionPolicy\\s\+Bypass'")

    Section "The registration (under the name $scheme, never the real one)"
    Set-Copy
    $run = Invoke-Switch '-Register'
    $wanted = '"{0}" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "{1}" "%1"' -f $shell, $copy
    $script:linkCommand = Get-Link $scheme
    Check '-Register says what it did and exits 0' ($run.Code -eq 0 -and $run.Text -eq 'wax:// links now open this copy of Wax.') "$($run.Text) $($run.Error)"
    Check 'the command is the one the installer writes: a window that shows, RemoteSigned, the script, the link in quotes' ($script:linkCommand -ceq $wanted) $script:linkCommand
    Check 'it hides no window and skips no rule' ($script:linkCommand -notmatch 'Hidden|Bypass|-Command|-EncodedCommand')
    $key = Get-ItemProperty -Path $schemeKey
    Check 'it is a link scheme as Windows wants one' ($key.'(default)' -eq 'URL:Wax mod link' -and $key.PSObject.Properties['URL Protocol'] -and $key.'URL Protocol' -eq '')
    if ($script:linkCommand -cne $wanted) { throw 'Without the registered command the rest cannot run.' }

    Section 'Command lines that try to slip something in beside the link'
    # A mark on the registered command shows whether any of these lines got -Register or -Unregister to run.
    Set-ItemProperty -Path "$schemeKey\shell\open\command" -Name '(Default)' -Value "$wanted #mark"
    $there = $script:attacker.Base
    $attacks = [ordered]@{
        'the review''s attack: a quote, then -Server'      = "wax://install/X`" -Server `"$there"
        'the same with the address the review used'        = 'wax://install/X" -Server "http://attacker.example'
        '-Quiet'                                           = 'wax://install/X" -Quiet "'
        '-Server and -Quiet together'                      = "wax://install/X`" -Quiet -Server `"$there"
        '-Register'                                        = 'wax://install/X" -Register "'
        '-Unregister'                                      = 'wax://install/X" -Unregister "'
        '-Unregister as the last word'                     = 'wax://install/X" -Unregister'
        '-Register with a value'                           = 'wax://install/X" -Register:$true "'
        'a second link'                                    = 'wax://install/X" "wax://install/Y'
        'an empty second argument'                         = 'wax://install/X" "'
        'the link given by name'                           = 'wax://install/X" -Link "wax://install/Y'
        'the names of the settings as if they were switches' = "wax://install/X`" -Catalogue `"$there`" -PublicKey `"$($script:attacker.Key)`" -Question `"yes"
        '--% before -Server'                               = "wax://install/X`" --% -Server `"$there"
        '-- before -Server'                                = "wax://install/X`" -- -Server `"$there"
        'switches of powershell.exe itself'                = 'wax://install/X" -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Set-Content -LiteralPath ''{0}'' -Value 1' -f $marker
        'another -File'                                    = 'wax://install/X" -File "\\attacker.example\share\evil.ps1'
        'back-ticks around the quotes'                     = 'wax://install/X`" -Server `"' + $there
        'a back-tick and a command'                        = 'wax://install/X`"; Set-Content -LiteralPath ''{0}'' -Value 1; `"' -f $marker
        '$() with a command in it'                         = 'wax://install/X$(Set-Content -LiteralPath ''{0}'' -Value 1)' -f $marker
        'a quote, then $() with a command'                 = 'wax://install/X" $(Set-Content -LiteralPath ''{0}'' -Value 1) "' -f $marker
        '; and a command'                                  = 'wax://install/X"; Set-Content -LiteralPath ''{0}'' -Value 1; "' -f $marker
        '& and a command'                                  = 'wax://install/X" & echo 1 > "{0}" & "' -f $marker
        '&& and a command'                                 = 'wax://install/X" && echo 1 > "{0}" && "' -f $marker
        '| and a command'                                  = 'wax://install/X" | Set-Content -LiteralPath ''{0}'' "' -f $marker
        'a redirection'                                    = 'wax://install/X" > "{0}' -f $marker
        'quotes written as %22, left as they are'          = "wax://install/X%22%20-Server%20%22$there"
        'quotes written as %22, decoded on the way'        = [uri]::UnescapeDataString("wax://install/X%22%20-Server%20%22$there")
        'quotes with a backslash before them'              = "wax://install/X\`" -Server \`"$there"
        'a line break and a command'                       = "wax://install/X`nSet-Content -LiteralPath '$marker' -Value 1"
        'a space at the end of the link'                   = 'wax://install/X '
        'a question mark and a server'                     = "wax://install/X?server=$there"
        'a slash at the end'                               = 'wax://install/X/'
        'a path that climbs'                               = 'wax://install/../X'
        'an id that climbs'                                = 'wax://install/..%2F..%2FX'
        'another action'                                   = 'wax://remove/X'
        'no id'                                            = 'wax://install/'
        'an id that starts with a digit'                   = 'wax://install/9lives'
        'an id of 65 letters'                              = 'wax://install/' + ('a' * 65)
        'the link in capital letters'                      = 'WAX://INSTALL/X'
        'an id with a letter that only looks like K'       = "wax://install/$([char]0x212A)ool"
        'an id with an accented letter'                    = "wax://install/Caf$([char]0xE9)"
        'an id that Windows keeps for itself: NUL'         = 'wax://install/NUL'
        'an id that Windows keeps for itself: con'         = 'wax://install/con'
        'an id that Windows keeps for itself: COM1'        = 'wax://install/COM1'
        'the catalogue''s own address'                     = "$($script:catalogue.Base)/api/mods/X"
        'nothing at all'                                   = ''
    }
    $modsBefore = Get-Print $mods
    Clear-Requests
    foreach ($what in $attacks.Keys) {
        $linesBefore = @(Get-Log).Count
        $run = Invoke-Link $attacks[$what]
        $logged = @(Get-Log | Select-Object -Skip $linesBefore)
        Check "refused, with one plain sentence and a line in the log: $what" ($run.Code -eq 1 -and $run.Text -ceq $notALink -and $run.Error -eq '' -and
            $logged.Count -eq 1 -and $logged[0] -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d  -  refused: ') "exit $($run.Code): $($run.Text) $($run.Error)"
    }
    # A lone dash is the one line PowerShell itself turns down, before the script is read.
    $run = Invoke-Link 'wax://install/X" - "'
    Check 'refused by PowerShell before the script starts: a dash on its own' ($run.Code -eq 1 -and $run.Text -eq '' -and $run.Error -match 'Cannot process argument') "exit $($run.Code): $($run.Text)"
    Check 'none of these lines made a request to the catalogue' (@(Get-Requests $script:catalogue).Count -eq 0) ((Get-Requests $script:catalogue) -join '; ')
    Check 'none of them made a request to the address they named' (@(Get-Requests $script:attacker).Count -eq 0) ((Get-Requests $script:attacker) -join '; ')
    Check 'none of them ran the command they carried' (-not (Test-Path -LiteralPath $marker))
    Check 'none of them added, changed or removed anything in the mods folder' ((Get-Print $mods) -eq $modsBefore)
    Check 'none of them got -Register or -Unregister to run' ((Get-Link $scheme) -ceq "$wanted #mark") (Get-Link $scheme)
    Check 'the log holds no line break or other invisible character from a link' (-not (Get-Log | Where-Object { $_ -match '[^\x20-\x7E]' }))
    Set-ItemProperty -Path "$schemeKey\shell\open\command" -Name '(Default)' -Value $wanted
    foreach ($switch in '-Register -Unregister', '-Register extra', '-Unregister "wax://install/X"', '-Reg', '-Server http://attacker.example') {
        $run = Invoke-Switch $switch
        Check "refused when typed by hand as well: $switch" ($run.Code -eq 1 -and $run.Text -ceq $notALink -and (Get-Link $scheme) -ceq $wanted) "exit $($run.Code): $($run.Text)"
    }

    Section 'A good mod, with the game running'
    $modsBefore = Get-Print $mods
    $savedBefore = Get-Print (Join-Path $wax 'saved')
    $game = Start-Game
    try {
        Clear-Requests
        Clear-Taken
        $linesBefore = @(Get-Log).Count
        # Every change in the mods folder while the mod is added, in the order it happened.
        $watcher = [System.IO.FileSystemWatcher]::new($mods)
        $watcher.IncludeSubdirectories = $true
        $watcher.InternalBufferSize = 65536
        foreach ($kind in 'Created', 'Changed', 'Renamed') { Register-ObjectEvent -InputObject $watcher -EventName $kind -SourceIdentifier "mods-$kind" }
        $watcher.EnableRaisingEvents = $true
        $run = Invoke-Link 'wax://install/TestMod'
        Start-Sleep -Milliseconds 500
        $watcher.EnableRaisingEvents = $false
        $changes = @(Get-Event | Where-Object SourceIdentifier -like 'mods-*' | Sort-Object EventIdentifier | ForEach-Object {
            $change = $_.SourceEventArgs
            if ($change -is [System.IO.RenamedEventArgs]) { "Renamed $($change.OldName) to $($change.Name)" } else { "$($change.ChangeType) $($change.Name)" }
        })
        Get-Event | Where-Object SourceIdentifier -like 'mods-*' | Remove-Event
        foreach ($kind in 'Created', 'Changed', 'Renamed') { Unregister-Event -SourceIdentifier "mods-$kind" }
        $watcher.Dispose()
        Set-Content -LiteralPath (Join-Path $work 'changes.txt') -Value $changes
        $asked = "Add this mod to ICARUS?`n`nName: Test Mod`nVersion: 1.0.0`nAuthor: Ada Lovelace`n`nIt comes from the Wax catalogue at 127.0.0.1. " +
            "A mod is code that runs in your game, and it can do whatever a program on this PC can do.`n`nIt stays switched off until you switch it on in the Wax menu.`nAnswered: yes"
        Check 'it exits 0' ($run.Code -eq 0 -and $run.Error -eq '') "exit $($run.Code): $($run.Text) $($run.Error)"
        Check 'it asks first: name, version, author, where the mod comes from, that a mod is code, that it stays switched off' ($run.Text.Contains($asked)) $run.Text
        $requests = Get-Requests $script:catalogue
        Check 'it asks the catalogue about the mod, then downloads the version it showed, and nothing else' (($requests -join '|') -ceq 'GET /api/mods/TestMod|GET /api/mods/TestMod/download/1.0.0') ($requests -join '|')
        Check 'the question comes before the download' ($run.Text.IndexOf('Answered: yes') -gt 0 -and $run.Text.IndexOf('Answered: yes') -lt $run.Text.IndexOf('Downloading the mod.'))
        $folder = Join-Path $mods 'TestMod'
        Check 'the files are in the mods folder, the empty folder too' ((Test-Path -LiteralPath (Join-Path $folder 'init.lua')) -and
            [System.IO.File]::ReadAllText((Join-Path $folder 'init.lua')) -ceq 'print("one")' -and
            [System.IO.File]::ReadAllText((Join-Path $folder 'mod.lua')) -ceq 'return { name = "Test Mod", version = "1.0.0" }' -and
            [System.IO.File]::ReadAllText((Join-Path $folder 'art\note.txt')) -ceq 'a note' -and (Test-Path -LiteralPath (Join-Path $folder 'empty') -PathType Container))
        Check 'it is marked as a mod from the catalogue at that version' ((Test-Path -LiteralPath (Join-Path $folder 'wax.origin')) -and
            [System.IO.File]::ReadAllText((Join-Path $folder 'wax.origin')) -ceq "id=TestMod`r`nversion=1.0.0`r`n")
        Check 'a mod the player did not have is marked as new: wax.new holds the one line "new"' ((Test-Path -LiteralPath (Join-Path $folder 'wax.new') -PathType Leaf) -and
            [System.IO.File]::ReadAllText((Join-Path $folder 'wax.new')) -ceq "new`r`n")
        $at = @{ mark = -1; origin = -1; moved = -1 }
        for ($i = 0; $i -lt $changes.Count; $i++) {
            if ($changes[$i] -match '^Created \.adding-TestMod-[0-9a-f]{8}\\wax\.new$') { $at.mark = $i }
            if ($changes[$i] -match '^Created \.adding-TestMod-[0-9a-f]{8}\\wax\.origin$') { $at.origin = $i }
            if ($changes[$i] -match '^Renamed \.adding-TestMod-[0-9a-f]{8} to TestMod$') { $at.moved = $i }
        }
        Check 'both marks are written while the folder is still being made, and it is moved into place after that, so the game never sees the mod without them' (
            $at.mark -ge 0 -and $at.origin -ge 0 -and $at.moved -gt $at.mark -and $at.moved -gt $at.origin -and -not ($changes | Where-Object { $_ -match '^Created TestMod\\' })) ($changes -join ' | ')
        $names = (Get-ChildItem -LiteralPath $mods -Force | ForEach-Object Name | Sort-Object) -join '|'
        Check 'nothing else was added to the mods folder, and nothing is left of the unpacking' ($names -eq 'MyMod|TestMod' -and
            (Get-ChildItem -LiteralPath $folder -Recurse -Force -File | Measure-Object).Count -eq 5) $names
        $taken = Get-Taken
        Check 'the game was sent one command, in the agreed form: an id, the command, the mod' ($taken -cmatch "\A--id:[0-9a-f]{12}`n--wax:mod-added`nid=TestMod`n\[end\]\z") $taken
        Check 'nothing in it switches the mod on, and nothing in it is Lua' ($taken -notmatch 'enable|Wax\.|return|\(|\)|''|"')
        Check 'the request folders are left clean' (Test-RunClean)
        Check 'it ends by saying the mod is in the Wax menu, switched off' ($run.Text.EndsWith('Test Mod 1.0.0 was added. It is on the Mods page of the Wax menu, switched off until you switch it on there.')) $run.Text
        Check 'the settings that say which mods are on were not touched' ((Get-Print (Join-Path $wax 'saved')) -eq $savedBefore)
        $logged = @(Get-Log | Select-Object -Skip $linesBefore)
        Check 'the log has one line for it: time, id, what happened' ($logged.Count -eq 1 -and $logged[0] -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d  TestMod  added 1\.0\.0, the game was told$') ($logged -join ' / ')

        Section 'The same mod again, as a newer version'
        $cases.testmod = @{ id = 'TestMod'; name = 'Test Mod'; author = 'Ada Lovelace'; version = '1.1.0'; zip = $good2 }
        Set-Cases $script:catalogue $cases
        Set-Content -LiteralPath (Join-Path $folder 'mine.txt') -Value 'something the player put there'
        # The game takes wax.new away when the player switches the mod on. From here on this mod is one the player uses.
        Remove-Item -LiteralPath (Join-Path $folder 'wax.new')
        Clear-Requests
        Clear-Taken
        $run = Invoke-Link 'wax://install/testmod'
        $kept = @(Get-ChildItem -LiteralPath $mods -Directory -Force -Filter '.removed-TestMod-*')
        Check 'a link with the id in other letter case is the same mod, under the name the catalogue lists, and it exits 0' ($run.Code -eq 0 -and
            ((Get-Requests $script:catalogue) -join '|') -ceq 'GET /api/mods/testmod|GET /api/mods/TestMod/download/1.1.0') "exit $($run.Code): $($run.Text) $((Get-Requests $script:catalogue) -join '|')"
        Check 'the question says which version is replaced by which, and that the old copy is kept' ($run.Text.Contains("Replace this mod in ICARUS?`n`nName: Test Mod`nVersion: 1.1.0`nAuthor: Ada Lovelace`n`n" +
            'This replaces version 1.0.0, which you have, with version 1.1.0. The old copy is kept in the mods folder under another name.') -and
            $run.Text.Contains('A mod is code that runs in your game') -and $run.Text.Contains('It stays switched on or off as it is now.')) $run.Text
        Check 'the new files are in place' ([System.IO.File]::ReadAllText((Join-Path $folder 'init.lua')) -ceq 'print("two")' -and
            -not (Test-Path -LiteralPath (Join-Path $folder 'art')) -and [System.IO.File]::ReadAllText((Join-Path $folder 'wax.origin')) -ceq "id=TestMod`r`nversion=1.1.0`r`n")
        Check 'replacing a mod that had no wax.new writes none, so nothing about on or off changes' (-not (Test-Path -LiteralPath (Join-Path $folder 'wax.new')) -and
            (Get-ChildItem -LiteralPath $folder -Recurse -Force -File | Measure-Object).Count -eq 3)
        Check 'the copy before is kept under another name, with what the player had put in it' ($kept.Count -eq 1 -and $kept[0].Name -match '^\.removed-TestMod-\d{8}-\d{6}$' -and
            [System.IO.File]::ReadAllText((Join-Path $kept[0].FullName 'init.lua')) -ceq 'print("one")' -and (Test-Path -LiteralPath (Join-Path $kept[0].FullName 'mine.txt')) -and
            (Test-Path -LiteralPath (Join-Path $kept[0].FullName 'art\note.txt')))
        Check 'the game got the same one command, and still nothing that switches a mod on or off' ((Get-Taken) -cmatch "\A--id:[0-9a-f]{12}`n--wax:mod-added`nid=TestMod`n\[end\]\z") (Get-Taken)
        Check 'which mods are on is left as it was' ((Get-Print (Join-Path $wax 'saved')) -eq $savedBefore -and (Test-RunClean))
        Check 'it ends by saying the mod keeps the state it had' ($run.Text.EndsWith('Test Mod was updated to version 1.1.0, and the copy you had is kept in the mods folder. It is switched on or off as it was.')) $run.Text
        Check 'the other mod in the folder was not touched' ([System.IO.File]::ReadAllText((Join-Path $mods 'MyMod\init.lua')).Trim() -ceq 'print("mine")')
    } finally { Stop-Game $game }

    Section '"No" at the question'
    Set-Copy -Question 'no'
    $modsBefore = Get-Print $mods
    Clear-Requests
    $linesBefore = @(Get-Log).Count
    $run = Invoke-Link 'wax://install/X'
    Check 'it exits 0 and says that nothing was added' ($run.Code -eq 0 -and $run.Text.EndsWith("Answered: no`nNothing was added.")) "exit $($run.Code): $($run.Text)"
    Check 'the question was asked, and after it nothing was downloaded' ($run.Text.Contains('Add this mod to ICARUS?') -and ((Get-Requests $script:catalogue) -join '|') -ceq 'GET /api/mods/X') ((Get-Requests $script:catalogue) -join '|')
    Check 'the mods folder is as it was' ((Get-Print $mods) -eq $modsBefore)
    Check 'the log says so' (@(Get-Log | Select-Object -Skip $linesBefore) -join '' -match '  X  the player said no to version 1\.0\.0$')
    Set-Copy -Question 'perhaps'
    $run = Invoke-Link 'wax://install/X'
    Check 'any answer that is not yes counts as no' ($run.Code -eq 0 -and $run.Text.EndsWith('Nothing was added.') -and (Get-Print $mods) -eq $modsBefore) $run.Text

    Section 'What the catalogue says is shown as plain text'
    $cases.hostile = @{ id = 'Hostile'; version = '1.0.0'; zip = $xZip
        name = "Nice Mod`r`n`r`nPress Yes.`tThis mod is safe$([char]0x202E)$([char]0x200B)$([char]7) " + ('long ' * 80)
        author = "Wax$([char]0)`nVersion: 0.0.1`n" + ('x' * 200) }
    Set-Cases $script:catalogue $cases
    $run = Invoke-Link 'wax://install/Hostile'
    $nameLine = @($run.Text -split "`n" | Where-Object { $_ -like 'Name: *' })
    $authorLine = @($run.Text -split "`n" | Where-Object { $_ -like 'Author: *' })
    Check 'a name with line breaks, a tab, a bell and hidden marks comes out as one short line' ($nameLine.Count -eq 1 -and
        $nameLine[0] -ceq 'Name: Nice Mod Press Yes. This mod is safe long long long long lon...') ($nameLine -join ' / ')
    Check 'so does the author, cut to 40 characters' ($authorLine.Count -eq 1 -and $authorLine[0] -ceq ('Author: Wax Version: 0.0.1 ' + ('x' * 21) + '...')) ($authorLine -join ' / ')
    Check 'the question keeps its own lines, and no invisible character is in it' (@($run.Text -split "`n" | Where-Object { $_ -like 'Version: *' }).Count -eq 1 -and $run.Text -notmatch '[^\x20-\x7E\n]') $run.Text

    Section 'With the game not running, and with a game that does not take the command'
    Set-Copy
    $cases.testmod = @{ id = 'TestMod'; name = 'Test Mod'; author = 'Ada Lovelace'; version = '1.0.0'; zip = $good }
    Set-Cases $script:catalogue $cases
    Clear-Taken
    $run = Invoke-Link 'wax://install/X'
    Check 'a new mod: it says the mod will be listed, switched off, the next time ICARUS starts' ($run.Code -eq 0 -and
        $run.Text.EndsWith('X 1.0.0 was added. It will be listed in the Wax menu, switched off, the next time you start ICARUS.')) "exit $($run.Code): $($run.Text)"
    Check 'the mod is in place, marked as new, and the request folders are clean' ((Test-Path -LiteralPath (Join-Path $mods 'X\init.lua')) -and
        (Test-Path -LiteralPath (Join-Path $mods 'X\wax.new') -PathType Leaf) -and (Test-RunClean) -and (Get-Taken) -eq '')
    $run = Invoke-Link 'wax://install/X'
    Check 'the same version again: the question says it is a new copy of the same version' ($run.Code -eq 0 -and
        $run.Text.Contains('This replaces version 1.0.0, which you have, with a new copy of the same version. The old copy is kept in the mods folder under another name.')) $run.Text
    Check 'the copy the player had was never switched on, so the question says the mod stays switched off' ($run.Text.Contains("`n`nIt stays switched off until you switch it on in the Wax menu.`nAnswered: yes") -and
        -not $run.Text.Contains('as it is now')) $run.Text
    Check 'wax.new is carried over into the new copy, so replacing a mod switches nothing on' ((Test-Path -LiteralPath (Join-Path $mods 'X\wax.new') -PathType Leaf) -and
        [System.IO.File]::ReadAllText((Join-Path $mods 'X\wax.new')) -ceq "new`r`n" -and [System.IO.File]::ReadAllText((Join-Path $mods 'X\wax.origin')) -ceq "id=X`r`nversion=1.0.0`r`n")
    Check 'and it ends by saying the mod stays switched off' ($run.Text.EndsWith('X was updated to version 1.0.0, and the copy you had is kept in the mods folder. It stays switched off until you switch it on in the Wax menu.')) $run.Text
    Remove-Item -LiteralPath (Join-Path $mods 'X\wax.origin'), (Join-Path $mods 'X\wax.new')
    $run = Invoke-Link 'wax://install/X'
    Check 'a copy that does not say its version is still asked about and kept' ($run.Code -eq 0 -and $run.Text.Contains('This replaces the copy you have with version 1.0.0. The old copy is kept') -and
        @(Get-ChildItem -LiteralPath $mods -Directory -Force -Filter '.removed-X-*').Count -eq 2) $run.Text
    Check 'that copy had no wax.new: the question says the mod stays as it is, and the new copy gets no wax.new' ($run.Text.Contains("`n`nIt stays switched on or off as it is now.`nAnswered: yes") -and
        -not (Test-Path -LiteralPath (Join-Path $mods 'X\wax.new')) -and (Test-Path -LiteralPath (Join-Path $mods 'X\wax.origin'))) $run.Text
    Check 'and it ends by saying the state it had comes back at the next start' ($run.Text.EndsWith('X was updated to version 1.0.0, and the copy you had is kept in the mods folder. The next time you start ICARUS it is switched on or off as it was.')) $run.Text
    $game = Start-Game 'refuse'
    try {
        $run = Invoke-Link 'wax://install/Y'
        Check 'a game that answers no to the command: the message is the one for the next start' ($run.Code -eq 0 -and (Get-Taken) -match '--wax:mod-added' -and
            $run.Text.EndsWith('Y 1.0.0 was added. It will be listed in the Wax menu, switched off, the next time you start ICARUS.') -and (Test-RunClean)) "exit $($run.Code): $($run.Text)"
    } finally { Stop-Game $game }

    Section 'Answers from the catalogue that cannot be used'
    $cases.broken = @{ id = 'Broken'; name = 'Broken'; version = '1.0.0'; status = 500 }
    $cases.notjson = @{ id = 'NotJson'; entryRaw = 'this is not json' }
    $cases.list = @{ id = 'List'; entryRaw = '[{"id":"List","latest":{"version":"1.0.0"}}]' }
    $cases.huge = @{ id = 'Huge'; entryRaw = '{"id":"Huge","description":"' + ('a' * 1100000) + '","latest":{"version":"1.0.0"}}' }
    $cases.renamed = @{ id = 'Renamed'; entryId = 'Y'; name = 'Renamed'; version = '1.0.0'; zip = $yZip }
    $cases.oddname = @{ id = 'OddName'; entryId = 'Odd Name!'; name = 'Odd'; version = '1.0.0'; zip = $xZip }
    $cases.unborn = @{ id = 'Unborn'; name = 'Unborn' }
    $cases.oddversion = @{ id = 'OddVersion'; name = 'Odd'; version = '1.0/../../other'; zip = $xZip }
    $cases.spaceversion = @{ id = 'SpaceVersion'; name = 'Odd'; version = "1.0.0`nid=Other"; zip = $xZip }
    $cases.elsewhere = @{ id = 'Elsewhere'; name = 'Elsewhere'; version = '1.0.0'; zip = $xZip; redirect = "$($script:attacker.Base)/api/mods/X/download/1.0.0" }
    Set-Cases $script:catalogue $cases
    $modsBefore = Get-Print $mods
    Clear-Requests
    $answers = [ordered]@{
        Nobody = 'The Wax catalogue has no mod with that name\.'; Broken = 'The Wax catalogue answered with error 500\. Try again later\.'
        NotJson = 'gave an answer that cannot be used, so nothing was added'; List = 'gave an answer that cannot be used'; Huge = 'gave an answer that cannot be used'
        Renamed = 'gave an answer that cannot be used'; OddName = 'gave an answer that cannot be used'; Unborn = 'has no version of this mod yet'
        OddVersion = 'gave an answer that cannot be used'; SpaceVersion = 'gave an answer that cannot be used'
    }
    foreach ($id in $answers.Keys) {
        $run = Invoke-Link "wax://install/$id"
        Check "$id is refused with a plain sentence ($($answers[$id] -replace '\\', '')), before any question" ($run.Code -eq 1 -and $run.Text -match $answers[$id] -and
            $run.Text -cnotmatch 'Answered|Exception|At line|   at ' -and $run.Error -eq '') "exit $($run.Code): $($run.Text) $($run.Error)"
    }
    Check 'none of them led to a download' (-not (Get-Requests $script:catalogue | Where-Object { $_ -match '/download' })) ((Get-Requests $script:catalogue) -join '|')
    $run = Invoke-Link 'wax://install/Elsewhere'
    Check 'a download that is sent on to another address is not followed' ($run.Code -eq 1 -and $run.Text -match 'The Wax catalogue answered with error 302' -and
        @(Get-Requests $script:attacker).Count -eq 0) "exit $($run.Code): $($run.Text)"
    Set-Copy -Catalogue 'http://127.0.0.1:9'
    $run = Invoke-Link 'wax://install/X'
    Check 'no connection: a plain sentence' ($run.Code -eq 1 -and $run.Text -match 'The Wax catalogue could not be reached\. Check your internet connection and try again\.' -and $run.Text -notmatch 'Exception') $run.Text
    Check 'the mods folder is as it was after all of these' ((Get-Print $mods) -eq $modsBefore)

    Section 'Signatures'
    Set-Copy
    $unsigned = 'This download carries no signature of the Wax catalogue, so it was not used\. Nothing was added to your game\.'
    $wrong = 'The signature on this download does not fit it, so it was not used\. Nothing was added to your game\.'
    $signatures = [ordered]@{
        none = @('no signature', $unsigned); bad = @('a signature with one character changed', $wrong); garbage = @('something that is no signature', $wrong)
        version = @('a signature made for another version of the mod', $wrong); id = @('a signature made for another mod', $wrong)
        kind = @('a signature made for the list of files, not for the zip', $wrong); key = @('a signature made with another key', $wrong)
    }
    $modsBefore = Get-Print $mods
    foreach ($kind in $signatures.Keys) {
        $cases.signed = @{ id = 'Signed'; name = 'Signed'; author = 'Ada'; version = '1.0.0'; zip = $signedZip; signature = $kind }
        Set-Cases $script:catalogue $cases
        $run = Invoke-Link 'wax://install/Signed'
        Check "$($signatures[$kind][0]): nothing is installed, and it says so plainly" ($run.Code -eq 1 -and $run.Text -match $signatures[$kind][1] -and
            (Get-Print $mods) -eq $modsBefore -and $run.Text -notmatch 'Exception') "exit $($run.Code): $($run.Text)"
    }
    $cases.signed.signature = 'good'
    Set-Cases $script:catalogue $cases
    Set-Copy -Key $ownerKey
    $run = Invoke-Link 'wax://install/Signed'
    Check 'the same download, well signed by the stand-in, is refused by a copy that holds the owner''s real key' ($run.Code -eq 1 -and $run.Text -match $wrong -and (Get-Print $mods) -eq $modsBefore) $run.Text
    Set-Copy -Key 'not a key'
    $run = Invoke-Link 'wax://install/Signed'
    Check 'a copy without a usable key accepts no signature at all' ($run.Code -eq 1 -and $run.Text -match $wrong -and (Get-Print $mods) -eq $modsBefore) $run.Text
    Set-Copy
    $run = Invoke-Link 'wax://install/Signed'
    Check 'and with the right key the well signed download is installed' ($run.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $mods 'Signed\init.lua'))) "exit $($run.Code): $($run.Text)"

    Section 'Size limits while downloading'
    $cases.bighead = @{ id = 'BigHead'; name = 'Big'; version = '1.0.0'; zeros = 20MB + 1 }
    $cases.bigbody = @{ id = 'BigBody'; name = 'Big'; version = '1.0.0'; zeros = 20MB + 1; length = 'none' }
    $cases.biglie = @{ id = 'BigLie'; name = 'Big'; version = '1.0.0'; zeros = 21MB; length = '1000' }
    $cases.atlimit = @{ id = 'AtLimit'; name = 'Big'; version = '1.0.0'; zeros = 20MB; length = 'none' }
    Set-Cases $script:catalogue $cases
    $modsBefore = Get-Print $mods
    $run = Invoke-Link 'wax://install/BigHead'
    Check 'a download that says it is one byte over 20 MB is refused before it starts' ($run.Code -eq 1 -and $run.Text -match 'The download is larger than a mod may be, so it was not started\.') "exit $($run.Code): $($run.Text)"
    $run = Invoke-Link 'wax://install/BigBody'
    Check 'a download that gives no size and is one byte over 20 MB is stopped while it is read' ($run.Code -eq 1 -and $run.Text -match 'The download is larger than a mod may be, so it was stopped\.') "exit $($run.Code): $($run.Text)"
    $run = Invoke-Link 'wax://install/BigLie'
    Check 'a download of 21 MB that says it is 1000 bytes: what was read is not what was signed, so nothing is installed' ($run.Code -eq 1 -and $run.Text -match $wrong) "exit $($run.Code): $($run.Text)"
    $run = Invoke-Link 'wax://install/AtLimit'
    Check 'a download of exactly 20 MB is read to its end (and then refused, as these bytes are no zip)' ($run.Code -eq 1 -and $run.Text -match 'not a zip that can be read') "exit $($run.Code): $($run.Text)"
    Check 'the mods folder is as it was after all of these' ((Get-Print $mods) -eq $modsBefore)

    Section 'What a zip may hold'
    foreach ($id in $refused.Keys) { $cases[$id.ToLower()] = @{ id = $id; name = $id; author = 'Ada'; version = '1.0.0'; zip = $refusedZip[$id] } }
    $cases.full = @{ id = 'Full'; name = 'Full'; author = 'Ada'; version = '1.0.0'; zip = $full }
    Set-Cases $script:catalogue $cases
    $modsBefore = Get-Print $mods
    foreach ($id in $refused.Keys) {
        $run = Invoke-Link "wax://install/$id"
        Check "$id is refused ($($refused[$id][0] -replace '\\', '')), and nothing of it is left in the mods folder" ($run.Code -eq 1 -and $run.Text -match $refused[$id][0] -and
            $run.Text -match 'Answered: yes' -and $run.Text -notmatch 'Exception|At line|   at ' -and $run.Error -eq '' -and (Get-Print $mods) -eq $modsBefore) "exit $($run.Code): $(($run.Text -split "`n")[-1]) $($run.Error)"
    }
    $strays = @(Get-ChildItem -LiteralPath $work -Recurse -Force | Where-Object { $_.FullName -notlike "$zips\*" -and $_.Name -match 'escaped|drive\.lua|absolute\.lua|hidden\.lua|inside\.lua|extra\.lua' })
    Check 'nothing was written outside the mod''s own folder' ($strays.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $mods 'Other')) -and -not (Test-Path -LiteralPath (Join-Path $mods 'lowercase'))) (($strays | ForEach-Object FullName) -join ', ')
    $run = Invoke-Link 'wax://install/Full'
    Check 'a mod of exactly 500 files is installed' ($run.Code -eq 0 -and @(Get-ChildItem -LiteralPath (Join-Path $mods 'Full') -File -Filter 'file*.txt').Count -eq 499) "exit $($run.Code): $(($run.Text -split "`n")[-1])"

    Section 'The boxes as a player gets them (on a desktop of their own, which no screen shows)'
    Add-Type -TypeDefinition ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'hidden-desk.cs')))
    $deskProbe = Join-Path $work 'desk-name.ps1'
    $deskOut = Join-Path $work 'desk-name.txt'
    Set-Content -LiteralPath $deskProbe -Value @'
Add-Type -Namespace Probe -Name Desk -MemberDefinition @"
[DllImport("kernel32")] public static extern uint GetCurrentThreadId();
[DllImport("user32")] public static extern IntPtr GetThreadDesktop(uint thread);
[DllImport("user32", CharSet = CharSet.Unicode)] public static extern bool GetUserObjectInformation(IntPtr handle, int index, System.Text.StringBuilder text, int size, out int needed);
"@
$text = New-Object System.Text.StringBuilder 512
$needed = 0
[void][Probe.Desk]::GetUserObjectInformation([Probe.Desk]::GetThreadDesktop([Probe.Desk]::GetCurrentThreadId()), 2, $text, 512, [ref]$needed)
Set-Content -LiteralPath $args[0] -Value $text.ToString()
'@
    $null = [HiddenDesk]::Run("`"$shell`" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File `"$deskProbe`" `"$deskOut`"", $work, [string[]]@(), 60)
    $onHidden = (Test-Path -LiteralPath $deskOut) -and (Get-Content -LiteralPath $deskOut -Raw).Trim() -like 'WaxImportTest*'
    Check 'a program started this way runs on a desktop of its own, not on the one the player looks at' $onHidden ([HiddenDesk]::Problem)
    if ($onHidden) {
        $cases.boxed = @{ id = 'Boxed'; name = 'Boxed'; author = 'Ada'; version = '1.0.0'; zip = $boxedZip }
        $cases.signed.signature = 'bad'
        Set-Cases $script:catalogue $cases
        Set-Copy -Question 'ask'
        try {
            $modsBefore = Get-Print $mods
            Clear-Requests
            $run = Invoke-Hidden "wax://install/X`" -Server `"$($script:attacker.Base)" 'ok'
            Check 'the review''s attack: one box with the plain sentence and one button, and no request to any server' ($run.Code -eq 1 -and $run.Boxes.Count -eq 1 -and
                $run.Boxes[0].Title -ceq 'Wax' -and $run.Boxes[0].Text -ceq $notALink -and $run.Boxes[0].Buttons -match '^\d+=[^;]+;$' -and
                @(Get-Requests $script:catalogue).Count -eq 0 -and @(Get-Requests $script:attacker).Count -eq 0 -and (Get-Print $mods) -eq $modsBefore) "exit $($run.Code), $($run.Boxes.Count) boxes, $($run.Problem)"
            $question = "Add this mod to ICARUS?`n`nName: Boxed`nVersion: 1.0.0`nAuthor: Ada`n`nIt comes from the Wax catalogue at 127.0.0.1. " +
                "A mod is code that runs in your game, and it can do whatever a program on this PC can do.`n`nIt stays switched off until you switch it on in the Wax menu."
            $run = Invoke-Hidden 'wax://install/Boxed' 'default'
            $box = if ($run.Boxes.Count -ge 1) { $run.Boxes[0] } else { [SeenBox]::new() }
            Check 'the question is one box, titled Wax, with the whole text' ($run.Boxes.Count -eq 1 -and $box.Title -ceq 'Wax' -and $box.Text -ceq $question) "$($run.Boxes.Count) boxes, $($run.Problem): $($box.Text)"
            Check 'it is put in front of other windows' $box.Topmost
            Check 'it has two buttons, Yes and No, and No is the one that Enter presses' ($box.Buttons -match '^6=[^;]+;7=[^;]+;$' -and $box.Default -eq 7) "$($box.Buttons) default $($box.Default)"
            Check 'pressing what Enter presses adds nothing: no download, nothing in the mods folder, exit 0' ($run.Code -eq 0 -and
                ((Get-Requests $script:catalogue) -join '|') -ceq 'GET /api/mods/Boxed' -and (Get-Print $mods) -eq $modsBefore) "exit $($run.Code): $((Get-Requests $script:catalogue) -join '|')"
            Clear-Requests
            $run = Invoke-Hidden 'wax://install/Boxed' 'no'
            Check 'pressing No does the same' ($run.Code -eq 0 -and $run.Boxes.Count -eq 1 -and ((Get-Requests $script:catalogue) -join '|') -ceq 'GET /api/mods/Boxed' -and (Get-Print $mods) -eq $modsBefore) "exit $($run.Code)"
            Clear-Requests
            $run = Invoke-Hidden 'wax://install/Boxed' 'yes', 'ok'
            Check 'pressing Yes downloads and adds the mod, and a second box says what was done and what comes next' ($run.Code -eq 0 -and $run.Boxes.Count -eq 2 -and
                $run.Boxes[0].Text -ceq $question -and $run.Boxes[1].Topmost -and $run.Boxes[1].Buttons -match '^\d+=[^;]+;$' -and
                $run.Boxes[1].Text -ceq 'Boxed 1.0.0 was added. It will be listed in the Wax menu, switched off, the next time you start ICARUS.' -and
                ((Get-Requests $script:catalogue) -join '|') -ceq 'GET /api/mods/Boxed|GET /api/mods/Boxed/download/1.0.0' -and
                (Test-Path -LiteralPath (Join-Path $mods 'Boxed\init.lua')) -and (Test-Path -LiteralPath (Join-Path $mods 'Boxed\wax.new') -PathType Leaf)) "exit $($run.Code), $($run.Boxes.Count) boxes, $($run.Problem): $(($run.Boxes | ForEach-Object Text) -join ' / ')"
            $modsBefore = Get-Print $mods
            $run = Invoke-Hidden 'wax://install/Signed' 'yes', 'ok'
            Check 'a mod the player has, with a wrong signature: asked with No as the default, then told plainly, and the copy they had is untouched' ($run.Code -eq 1 -and $run.Boxes.Count -eq 2 -and
                $run.Boxes[0].Text.StartsWith("Replace this mod in ICARUS?`n`nName: Signed`nVersion: 1.0.0`nAuthor: Ada`n`nThis replaces version 1.0.0, which you have, with a new copy of the same version.") -and
                $run.Boxes[0].Default -eq 7 -and $run.Boxes[1].Text -ceq 'The signature on this download does not fit it, so it was not used. Nothing was added to your game.' -and
                (Get-Print $mods) -eq $modsBefore) "exit $($run.Code), $($run.Boxes.Count) boxes, $($run.Problem): $(($run.Boxes | ForEach-Object Text) -join ' / ')"
        } finally { Set-Copy }
    }

    Section 'The registration again: an old one is put right, and -Unregister'
    $old = '"{0}" -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" "%1"'
    Set-ItemProperty -Path "$schemeKey\shell\open\command" -Name '(Default)' -Value ($old -f $shell, 'C:\Somewhere\Else\Wax-Import.ps1')
    $null = Invoke-Link 'wax://install/Nobody'
    Check 'a hidden registration that points at another copy is left alone' ((Get-Link $scheme) -ceq ($old -f $shell, 'C:\Somewhere\Else\Wax-Import.ps1'))
    Set-ItemProperty -Path "$schemeKey\shell\open\command" -Name '(Default)' -Value ($old -f $shell, $copy.ToLower())
    $null = Invoke-Link 'wax://remove/Nobody'
    Check 'a link that is refused changes nothing in the registry' ((Get-Link $scheme) -ceq ($old -f $shell, $copy.ToLower()))
    $null = Invoke-Link 'wax://install/Nobody'
    Check 'a hidden registration that points at this copy is replaced by one that shows its window' ((Get-Link $scheme) -ceq $wanted) (Get-Link $scheme)
    $run = Invoke-Switch '-Unregister'
    Check '-Unregister takes the registration away and says so' ($run.Code -eq 0 -and $run.Text -eq 'wax:// links are no longer handled.' -and -not (Test-Path $schemeKey)) "$($run.Text) $($run.Error)"
    $run = Invoke-Switch '-Unregister'
    Check '-Unregister with nothing registered is no error' ($run.Code -eq 0 -and -not (Test-Path $schemeKey)) "$($run.Text) $($run.Error)"
} finally {
    foreach ($server in $script:catalogue, $script:attacker) { Stop-Process -Id $server.Process.Id -Force -ErrorAction SilentlyContinue }
    if (Test-Path $schemeKey) { Remove-Item -Path $schemeKey -Recurse -Force }
}

Section 'What the tests left alone'
Check 'the real wax:// registration is as it was' ((Get-Link 'wax') -ceq $realLinkBefore) (Get-Link 'wax')
Check "nothing is left of the test's own registration" (-not (Test-Path $schemeKey))
Check "the real log ($realLog) is as it was: every run wrote to the test's own" ((Get-RealLog) -eq $realLogBefore)
Check 'the real mods folder of this workspace has the folders it had' (((Get-ChildItem -LiteralPath (Join-Path $Root 'luamods') -Force | ForEach-Object Name | Sort-Object) -join '|') -eq $luamodsBefore)
Check 'the log of the test never grew a line longer than it should' (-not (Get-Log | Where-Object { $_.Length -gt 400 }))
Check 'no stand-in for the game is still running' (@(Get-Process -Name 'Icarus-Win64-Shipping' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($work, [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0)

Write-Host ''
if ($script:failures.Count) {
    Write-Host "$($script:failures.Count) failed, $($script:passed) passed" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
Write-Host "All $($script:passed) checks passed." -ForegroundColor Green
