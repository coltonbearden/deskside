#Requires -Version 5.1
<#
.SYNOPSIS
    Runs inside Windows Sandbox (as its LogonCommand) and proves deskside end to end on a clean Windows.
    Results go to C:\out\proof.jsonl, one JSON line per step; C:\out\DONE marks the end.

.DESCRIPTION
    Reads C:\in\proof-config.json: { source: 'local' | 'github', ref, serverUrl, groupId, publicKey }.
    1. The one-line bootstrap (from C:\in for 'local', from GitHub for 'github'), which in proof mode answers its own
       prompts: consent, diagnose, onboarding with the everyone profile (winget repair, apps, settings).
    2. Checks: winget works, records exist, every everyone app is installed, every everyone setting complies,
       Winget-AutoUpdate's task exists.
    3. Remote: consent, loopback SSH with a throwaway key, an SSH login to 127.0.0.1 with that key, and (when a server
       is given) the MeshCentral agent.
    4. Remove-RemoteHelp, then checks that nothing is left.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'The proof runs the README''s exact one-line bootstrap, irm | iex.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingCmdletAliases', '', Justification = 'The README line uses irm and iex; the proof runs it verbatim.')]
param()
$ErrorActionPreference = 'Continue'
$out = 'C:\out'
$cfg = Get-Content 'C:\in\proof-config.json' -Raw | ConvertFrom-Json
$app = 'C:\ProgramData\deskside\app'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$helper = 'Proof helper'
$sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId

function Write-Step([string]$Name, [bool]$Ok, [string]$Detail) {
    $d = ($Detail -replace '\s+', ' ').Trim()
    if ($d.Length -gt 800) { $d = $d.Substring(0, 800) }
    ([pscustomobject]@{ step = $Name; ok = $Ok; time = (Get-Date).ToString('HH:mm:ss'); detail = $d } | ConvertTo-Json -Compress) | Add-Content "$out\proof.jsonl"
}
function Invoke-Step([string]$Name, [scriptblock]$Body) {
    try { $r = & $Body 2>&1 | Out-String; Write-Step $Name $true $r }
    catch { Write-Step $Name $false ($_.Exception.Message) }
}
function Assert-That([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

Start-Transcript "$out\transcript.txt" | Out-Null
$env:DESKSIDE_SANDBOX_PROOF = '1'
if ($cfg.ref) { $env:DESKSIDE_REF = $cfg.ref }

function Invoke-Bootstrap {
    if ($cfg.source -eq 'local') {
        $env:DESKSIDE_SOURCE_ZIP = 'C:\in\deskside.zip'
        Invoke-Expression (Get-Content 'C:\in\bootstrap.ps1' -Raw)
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        # The exact line from the README.
        irm "https://raw.githubusercontent.com/coltonbearden/deskside/$($cfg.ref)/bootstrap.ps1" | iex
    }
}

# --- 0. A work or school PC: report only, nothing written ---------------------------------------------------------
Invoke-Step 'managed-stop' {
    # Plant an active enrollment from a provider that isn't one of Windows' built-in ones, as Intune's would be.
    $key = 'HKLM:\SOFTWARE\Microsoft\Enrollments\' + [guid]::NewGuid().ToString().ToUpper()
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name ProviderID -Value 'MS DM Server' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $key -Name EnrollmentState -Value 1 -PropertyType DWord -Force | Out-Null
    try { $text = Invoke-Bootstrap *>&1 | Out-String } finally { Remove-Item -Path $key -Recurse -Force }
    Assert-That ($text -match 'belongs to a work or school') 'no work-or-school notice'
    Assert-That ($text -match 'Fix now') 'no on-screen report'
    Assert-That (-not (Test-Path 'C:\ProgramData\deskside')) 'C:\ProgramData\deskside was created'
    'report shown on screen; nothing written; enrollment removed again'
}

# --- 1. The one-line bootstrap ------------------------------------------------------------------------------------
Invoke-Step 'bootstrap' { Invoke-Bootstrap }
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
Import-Module (Join-Path $app 'scripts\common\Deskside.Common.psm1') -Force

# --- 2. What onboarding left behind -------------------------------------------------------------------------------
Invoke-Step 'records' {
    $runs = @(Get-ChildItem 'C:\ProgramData\deskside\data\runs' -Directory | Select-Object -ExpandProperty Name)
    Assert-That ($runs.Count -ge 4) "only $($runs.Count) runs"
    foreach ($r in Get-ChildItem 'C:\ProgramData\deskside\data\runs' -Directory) {
        $rec = Get-Content (Join-Path $r.FullName 'record.json') -Raw | ConvertFrom-Json
        Assert-That ($rec.schema -eq 'deskside.record/v1') "bad schema in $($r.Name)"
    }
    "runs: " + ($runs -join ', ')
}
Invoke-Step 'winget' { $w = Get-WingetPath; Assert-That ([bool]$w) 'winget missing'; & $w --version }
Invoke-Step 'everyone-apps' {
    $w = Get-WingetPath
    $p = Get-Content (Join-Path $app 'catalog\profiles\everyone.json') -Raw | ConvertFrom-Json
    $missing = @()
    foreach ($a in $p.apps) { & $w list --id $a.id -e --source winget --accept-source-agreements --disable-interactivity *> $null; if ($LASTEXITCODE -ne 0) { $missing += $a.id } }
    Assert-That ($missing.Count -eq 0) ("missing: " + ($missing -join ', '))
    "all $(@($p.apps).Count) installed"
}
Invoke-Step 'everyone-settings' {
    $p = Get-Content (Join-Path $app 'catalog\profiles\everyone.json') -Raw | ConvertFrom-Json
    $items = (Get-Content (Join-Path $app 'catalog\settings.json') -Raw | ConvertFrom-Json).items | Where-Object { $p.settings -contains $_.id }
    $bad = @($items | Where-Object { -not (Test-DesksideSettingCompliant $_) } | ForEach-Object { $_.id })
    # Onboarding applied defender-pua with the rest, but Defender doesn't run in Windows Sandbox, so the setting can't be
    # read back here (and Test-DesksideSettingCompliant counts an unreadable Defender as compliant). Record what Defender
    # itself says, so the result shows why rather than repeating this comment.
    $bad = @($bad | Where-Object { $_ -ne 'defender-pua' })
    $mp = try { $s = Get-MpComputerStatus -ErrorAction Stop; "Defender AMServiceEnabled $($s.AMServiceEnabled)" } catch { 'Defender: ' + $_.Exception.Message }
    Assert-That ($bad.Count -eq 0) ("not applied: " + ($bad -join ', '))
    "applied: " + (@($items).Count) + " (defender-pua not provable in Sandbox; $mp)"
}
Invoke-Step 'install-undo-file' {
    $i = Get-ChildItem 'C:\ProgramData\deskside\data\runs' -Directory -Filter '*-install-everyone' | Select-Object -First 1
    $u = Read-JsonArray -Path (Join-Path $i.FullName 'undo.json')
    $ids = @($u | Where-Object { $_.type -eq 'winget' } | ForEach-Object { $_.id })
    Assert-That ($ids.Count -eq 6) ("undo.json lists " + $ids.Count + " app(s): " + ($ids -join ', '))
    "undo.json lists all 6 apps"
}
Invoke-Step 'wau-task' { $t = Get-ScheduledTask -TaskPath '\WAU\' -TaskName 'Winget-AutoUpdate' -ErrorAction Stop; "state " + $t.State }
Invoke-Step 'undo-settings' {
    # Start from extensions hidden (Windows' usual default), apply, undo, apply again.
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    New-ItemProperty -Path $adv -Name HideFileExt -Value 1 -PropertyType DWord -Force | Out-Null
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\settings\Set-Baseline.ps1') -ItemId 'show-extensions' | Out-Null
    $applied = (Get-ItemProperty $adv).HideFileExt
    $run = Get-ChildItem 'C:\ProgramData\deskside\data\runs' -Directory -Filter '*-settings' | Sort-Object Name -Descending | Select-Object -First 1
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\settings\Undo-DesksideRun.ps1') -Run $run.FullName | Out-Null
    $undone = (Get-ItemProperty $adv).HideFileExt
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\settings\Undo-DesksideRun.ps1') -Run $run.FullName | Out-Null
    $twice = (Get-ItemProperty $adv).HideFileExt
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\settings\Set-Baseline.ps1') -ItemId 'show-extensions' | Out-Null
    $again = (Get-ItemProperty $adv).HideFileExt
    Assert-That ($applied -eq 0 -and $undone -eq 1 -and $twice -eq 1 -and $again -eq 0) "applied $applied, undone $undone, undone twice $twice, re-applied $again"
    "show-extensions applied, undone (twice, no harm) and re-applied"
}
Invoke-Step 'idempotent' {
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\settings\Set-Baseline.ps1') -ItemId 'show-extensions,storage-sense,ads-tips-off,restart-notice,smartscreen-apps' | Out-Null
    $last = Get-ChildItem 'C:\ProgramData\deskside\data\runs' -Directory -Filter '*-settings' | Sort-Object Name -Descending | Select-Object -First 1
    $rec = Get-Content (Join-Path $last.FullName 'record.json') -Raw | ConvertFrom-Json
    $applied = @($rec.changes | Where-Object { $_.result -eq 'applied' }).Count
    Assert-That ($applied -eq 0) "second run applied $applied item(s)"
    "second run changed nothing"
}

Invoke-Step 'remove-marked-app' {
    # A change list with one removal marked yes (VLC stands in for trialware), applied by Remove-Apps.ps1.
    $list = [ordered]@{ schema = 'deskside.changelist/v1'; items = @([ordered]@{ kind = 'removal'; id = 'VLC media player'; title = 'Remove VLC media player'; why = 'proof'; verdict = 'recommended'; decision = 'yes' }) }
    $path = Join-Path $env:TEMP 'proof-changelist.json'
    (ConvertTo-Json -InputObject $list -Depth 4) | Set-Content $path
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\onboard\Remove-Apps.ps1') -ChangeList $path | Out-Null
    $w = Get-WingetPath
    & $w list --id VideoLAN.VLC -e --source winget --accept-source-agreements --disable-interactivity *> $null
    Assert-That ($LASTEXITCODE -ne 0) 'VLC is still installed'
    'the marked app was removed'
}
Invoke-Step 'problem-flow' {
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\onboard\Start-Onboarding.ps1') -Flow Problem -Confirmed | Out-Null
    Assert-That ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
    $d = @(Get-ChildItem 'C:\ProgramData\deskside\data\runs' -Directory -Filter '*-diagnose').Count
    "problem flow ran; $d diagnose runs in all"
}
Invoke-Step 'power-profile' {
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\install\Install-Profile.ps1') -ProfileName power | Out-Null
    $w = Get-WingetPath
    $missing = @()
    foreach ($id in 'Microsoft.PowerShell', 'Microsoft.WindowsTerminal', 'Git.Git') { & $w list --id $id -e --source winget --accept-source-agreements --disable-interactivity *> $null; if ($LASTEXITCODE -ne 0) { $missing += $id } }
    $prof = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.PowerShell_profile.ps1'
    Assert-That ($missing.Count -eq 0) ('missing: ' + ($missing -join ', '))
    Assert-That (Test-Path $prof) 'PowerShell profile not copied'
    'PowerShell 7, Windows Terminal, Git and the profile are in place'
}

# --- 3. Remote help -----------------------------------------------------------------------------------------------
Invoke-Step 'consent-remote' { & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\onboard\Grant-Consent.ps1') -Scope remote -Confirmed }
Invoke-Step 'loopback-ssh' {
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\remote\Enable-LoopbackSsh.ps1') -PublicKey $cfg.publicKey 2>&1 | Out-Null
    # The helper's real deskside-ssh public key beside the throwaway one, for the host's real-key login.
    if ($cfg.PSObject.Properties['realPublicKey'] -and $cfg.realPublicKey) { Add-Content -LiteralPath 'C:\ProgramData\ssh\administrators_authorized_keys' -Value $cfg.realPublicKey -Encoding ascii }
    $listen = @(Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue | ForEach-Object { $_.LocalAddress } | Sort-Object -Unique)
    Assert-That ($listen.Count -gt 0 -and @($listen | Where-Object { $_ -ne '127.0.0.1' }).Count -eq 0) ("listening on: " + ($listen -join ','))
    $state = Get-Content 'C:\ProgramData\deskside\data\ssh-state.json' -Raw | ConvertFrom-Json
    "listening on " + ($listen -join ',') + "; installed by " + $state.method
}
Invoke-Step 'ssh-login' {
    $key = 'C:\in\proof_key'
    $ssh = 'C:\Windows\System32\OpenSSH\ssh.exe'
    if (-not (Test-Path $ssh)) { $ssh = Join-Path $env:ProgramFiles 'OpenSSH\ssh.exe' }
    $tmpKey = Join-Path $env:TEMP 'proof_key'
    Copy-Item $key $tmpKey -Force
    & icacls.exe $tmpKey /inheritance:r /grant "${env:USERNAME}:F" | Out-Null
    $o = & $ssh -i $tmpKey -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o BatchMode=yes -p 22 "$env:USERNAME@127.0.0.1" "`$PSVersionTable.PSVersion.ToString(); Test-Path C:\ProgramData\deskside\app\scripts\diagnose\Invoke-Diagnose.ps1" 2>&1 | Out-String
    $pw = & $ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o BatchMode=yes -o PubkeyAuthentication=no -o PreferredAuthentications=password -p 22 "$env:USERNAME@127.0.0.1" 'echo hi' 2>&1 | Out-String
    Remove-Item $tmpKey -Force
    Assert-That ($o -match 'True') "key login failed: $o"
    Assert-That ($pw -notmatch '^hi') 'password login was allowed'
    "key login ok (" + ($o -replace '\s+', ' ').Trim() + "); password login refused"
}
Invoke-Step 'ssh-not-on-network' {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1).IPAddress
    $c = New-Object Net.Sockets.TcpClient
    $open = $false
    try { $iar = $c.BeginConnect($ip, 22, $null, $null); $open = $iar.AsyncWaitHandle.WaitOne(3000) -and $c.Connected } catch { $open = $false } finally { $c.Close() }
    Assert-That (-not $open) "port 22 answered on the network address"
    "port 22 closed on the network address"
}
if ($cfg.serverUrl -and $cfg.groupId) {
    Invoke-Step 'mesh-agent' {
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\remote\Install-MeshAgent.ps1') -ServerUrl $cfg.serverUrl -GroupId $cfg.groupId | Out-Null
        $s = Get-Service 'Mesh Agent' -ErrorAction Stop
        Assert-That ($s.Status -eq 'Running') "agent $($s.Status)"
        $nodeId = Get-MeshNodeId
        Assert-That ([bool]$nodeId) 'the agent gave no node id'
        # For the host side's devices.json (a throwaway Sandbox device in the Proofs group).
        Set-Content -LiteralPath "$out\nodeid.txt" -Value $nodeId -Encoding ascii
        'agent running; node id handed to the host'
    }
    Invoke-Step 'help-button' {
        $before = @(Get-Process -Name MeshCentralAssistant -ErrorAction SilentlyContinue).Count
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\remote\Install-HelpButton.ps1') -HelperName $helper | Out-Null
        $hb = Get-HelpButtonPath -HelperName $helper
        $rec = Get-ChildItem 'C:\ProgramData\deskside\data\runs' -Directory | Where-Object Name -like '*-help-install' | Select-Object -Last 1
        $data = (Get-Content (Join-Path $rec.FullName 'record.json') -Raw | ConvertFrom-Json).data
        foreach ($f in $hb.Exe, $hb.Startup, $hb.Desktop, $hb.StartMenu) { Assert-That (Test-Path -LiteralPath $f) "missing $(Split-Path $f -Leaf)" }
        Assert-That ([bool](Get-ScheduledTask -TaskPath $hb.TaskPath -TaskName $hb.TaskName -ErrorAction SilentlyContinue)) 'no refresh task'
        Start-Sleep -Seconds 15
        $mine = @(Get-Process -Name MeshCentralAssistant -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })
        Assert-That ($mine.Count -ge 1) 'Assistant is not running in the signed-in session'
        $titles = @(Get-Process -Name MeshCentralAssistant | Where-Object { $_.MainWindowTitle } | ForEach-Object { $_.MainWindowTitle })
        # The refresh task, as SYSTEM, the way it runs each week.
        Start-ScheduledTask -TaskPath $hb.TaskPath -TaskName $hb.TaskName; Start-Sleep -Seconds 20
        $state = Get-Content $hb.StateFile -Raw | ConvertFrom-Json
        Assert-That ($state.result -eq 'current') "refresh: $($state.result)"
        "installed ($($data.assistant.result), signature $($data.assistant.signature), sha256 $($data.assistant.sha256.Substring(0,12))); running in session $sessionId (before $before); windows open: $($titles.Count) ($($titles -join '|')); weekly refresh as SYSTEM: $($state.result)"
    }
    Invoke-Step 'help-request' {
        $log = Join-Path $out 'assistant'
        New-Item -ItemType Directory -Force -Path $log | Out-Null
        $stamp = (Get-Date).ToString('HH:mm')
        $o = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\remote\Ask-ForHelp.ps1') -HelperName $helper -Text "deskside Sandbox proof $stamp`r`nsecond line" -LogFolder $log -Quiet 2>&1 | Out-String
        Assert-That ($o -match 'on its way') "button said: $o"
        $deadline = (Get-Date).AddSeconds(60); $sent = $false
        while (-not $sent -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3; $sent = [bool](Select-String -LiteralPath (Join-Path $log 'debug.log') -Pattern 'requesthelp' -Quiet -ErrorAction SilentlyContinue) }
        Assert-That $sent 'Assistant logged no requesthelp to the agent'
        Set-Content -LiteralPath "$out\help-requested.txt" -Value $stamp
        "request sent at $stamp (one line, ""deskside Sandbox proof $stamp second line""); Assistant's log shows requesthelp to the agent"
    }
    # The host side now runs its checks (port map, SSH, Claude Code). It writes C:\out\host-done when finished.
    # Meanwhile every message box titled 'deskside - ' in this session is written down, with the time it appeared.
    $watch = Start-Job -ScriptBlock {
        $out = $using:out
        Add-Type -Namespace Proof -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
public delegate bool EnumProc(IntPtr h, IntPtr p);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
'@
        $seen = @{}
        while (-not (Test-Path "$out\watch-stop")) {
            $cb = [Proof.W+EnumProc] {
                param($h, $p)
                $null = $p
                $sb = New-Object Text.StringBuilder 256
                [void][Proof.W]::GetWindowText($h, $sb, 256)
                $t = $sb.ToString()
                if ($t -like 'deskside - *' -and [Proof.W]::IsWindowVisible($h) -and -not $seen.ContainsKey("$h")) {
                    $seen["$h"] = $true
                    ('{0} {1}' -f (Get-Date).ToString('HH:mm:ss'), $t) | Add-Content "$out\notice-windows.txt"
                }
                $true
            }
            [void][Proof.W]::EnumWindows($cb, [IntPtr]::Zero)
            Start-Sleep -Milliseconds 700
        }
    }
    Write-Step 'waiting-for-host' $true 'agent online; waiting for the host-side checks'
    $deadline = (Get-Date).AddMinutes(30)
    while (-not (Test-Path "$out\host-done") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
    Write-Step 'host-done' (Test-Path "$out\host-done") 'host finished or timed out'
    Invoke-Step 'notice-seen' {
        # Windows shows a session's messages one at a time: the closing one waits until the first is closed. Nobody
        # closes it here, so the first closes itself after 5 minutes, and then the closing one must appear.
        $w = @(Get-Content "$out\notice-windows.txt" -ErrorAction SilentlyContinue)
        $first = @($w | Where-Object { $_ -like '* is connected' }) | Select-Object -First 1
        Assert-That ([bool]$first) 'no "is connected" message appeared'
        $n = Get-Content 'C:\ProgramData\deskside\data\notice.json' -Raw | ConvertFrom-Json
        Assert-That ($n.phase -eq 'End') "notice.json says $($n.phase): the closing message was not sent"
        $deadline = (Get-Date).AddMinutes(7)
        do { Start-Sleep -Seconds 5; $w = @(Get-Content "$out\notice-windows.txt" -ErrorAction SilentlyContinue) } while (@($w | Where-Object { $_ -like '* has finished' }).Count -eq 0 -and (Get-Date) -lt $deadline)
        Assert-That (@($w | Where-Object { $_ -like '* has finished' }).Count -ge 1) 'no "has finished" message appeared within 7 minutes of the run'
        "notice.json: End sent (signedIn $($n.signedIn), shown $($n.shown)); $($w.Count) message(s) in session ${sessionId}, the closing one after the first closed itself: " + ($w -join '; ')
    }
    Invoke-Step 'sweep-silent' {
        # The scheduled check runs the installed diagnostics as SYSTEM through MeshCentral's run-command; this runs
        # them the same way, as SYSTEM with no SSH, and no message may appear.
        $n0 = @(Get-Content "$out\notice-windows.txt" -ErrorAction SilentlyContinue).Count
        $t = 'deskside-proof-sweep'
        $a = New-ScheduledTaskAction -Execute $ps -Argument ("-NoProfile -ExecutionPolicy Bypass -File " + (Join-Path $app 'scripts\diagnose\Invoke-Diagnose.ps1') + ' -Quick')
        Register-ScheduledTask -TaskName $t -Action $a -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
        Start-ScheduledTask -TaskName $t
        $deadline = (Get-Date).AddMinutes(5)
        do { Start-Sleep -Seconds 5 } while ((Get-ScheduledTask -TaskName $t).State -eq 'Running' -and (Get-Date) -lt $deadline)
        Start-Sleep -Seconds 5
        Unregister-ScheduledTask -TaskName $t -Confirm:$false
        $n1 = @(Get-Content "$out\notice-windows.txt" -ErrorAction SilentlyContinue).Count
        $rec = Get-ChildItem 'C:\ProgramData\deskside\data\runs' -Directory | Where-Object Name -like '*-diagnose' | Sort-Object Name | Select-Object -Last 1
        $r = Get-Content (Join-Path $rec.FullName 'record.json') -Raw | ConvertFrom-Json
        Assert-That ($r.data.PSObject.Properties.Name -notcontains 'notice') 'the SYSTEM run recorded a notice'
        Assert-That ($n1 -eq $n0) "$($n1 - $n0) message(s) appeared during the SYSTEM run"
        "diagnose as SYSTEM: no message, no notice in its record"
    }
    'stop' | Set-Content "$out\watch-stop"; $null = $watch | Wait-Job -Timeout 10; $watch | Remove-Job -Force
} else {
    Write-Step 'mesh-agent' $true 'skipped: no MeshCentral server given'
}

# --- 4. Remove remote help ----------------------------------------------------------------------------------------
Invoke-Step 'remove-remote-help' {
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\remote\Remove-RemoteHelp.ps1') -Confirmed | Out-Null
    $left = @()
    if (Get-Service 'Mesh Agent' -ErrorAction SilentlyContinue) { $left += 'agent service' }
    if (Test-Path (Join-Path $env:ProgramFiles 'Mesh Agent')) { $left += 'agent folder' }
    if (Get-Service sshd -ErrorAction SilentlyContinue) { $left += 'sshd service' }
    if (Test-Path 'C:\ProgramData\ssh\administrators_authorized_keys') { $left += 'key file' }
    if (Test-Path (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Remove remote help.cmd')) { $left += 'shortcut' }
    $hb = Get-HelpButtonPath -HelperName $helper
    if (Test-Path $hb.Folder) { $left += 'help button folder' }
    foreach ($l in $hb.Startup, $hb.Desktop, $hb.StartMenu) { if (Test-Path -LiteralPath $l) { $left += (Split-Path $l -Leaf) } }
    if (Get-ScheduledTask -TaskPath $hb.TaskPath -ErrorAction SilentlyContinue) { $left += 'help button task' }
    if (Get-Process -Name $hb.ProcessName -ErrorAction SilentlyContinue) { $left += 'help button running' }
    if (Test-Path 'HKCU:\SOFTWARE\Open Source\MeshCentral Assistant') { $left += 'help button setting' }
    $c = Get-Content 'C:\ProgramData\deskside\data\consent.json' -Raw | ConvertFrom-Json
    if ($c.scopes.PSObject.Properties['remote']) { $left += 'remote consent' }
    Assert-That ($left.Count -eq 0) ("left behind: " + ($left -join ', '))
    'nothing left behind'
}

Copy-Item 'C:\ProgramData\deskside\data\runs' "$out\runs" -Recurse -Force -ErrorAction SilentlyContinue
Stop-Transcript | Out-Null
'done' | Set-Content "$out\DONE"
