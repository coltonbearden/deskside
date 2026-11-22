#Requires -Version 5.1
<#
.SYNOPSIS
    Runs inside Windows Sandbox (as its LogonCommand) and proves the USB kit on a clean Windows. The kit is in C:\kit
    (mapped writable, as a USB drive would be), built by the host with New-DesksideUsbKit.ps1 -Proof. Results go to
    C:\out\proof.jsonl, one JSON line per step; C:\out\DONE marks the end.

.DESCRIPTION
    1. Plants what a failed hand-typed attempt leaves: a history line with the group id and a deskside-mesh-* folder.
    2. Runs the kit with Smart App Control forced on: it must stop, say why and change nothing.
    3. Runs the kit for real: deskside's first visit from the drive's zip, the agent (Proofs group), the help button,
       loopback SSH; the planted traces go and values.json goes.
    4. Puts the values back and runs it again: deskside's scripts are refreshed from the drive, nothing breaks.
    5. Waits while the host reads the drive back (Read-DesksideUsbKit.ps1), then removes remote help.
#>
param()
$ErrorActionPreference = 'Continue'
$out = 'C:\out'
$kit = 'C:\kit'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

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
function Invoke-Kit {
    & $ps -NoProfile -ExecutionPolicy Bypass -File "$kit\deskside\deskside-enroll.ps1" *> $null
    return $LASTEXITCODE
}
function Get-Readback { @(Get-Content -LiteralPath "$kit\readback.txt" -ErrorAction SilentlyContinue) }

Start-Transcript "$out\transcript.txt" | Out-Null
$env:DESKSIDE_SANDBOX_PROOF = '1'
$values = "$kit\deskside\values.json"
$saved = Join-Path $env:TEMP 'kit-values.json'
$hist = Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
$leftover = Join-Path $env:TEMP 'deskside-mesh-planted'

Invoke-Step 'plant-traces' {
    $g = (Get-Content -LiteralPath $values -Raw | ConvertFrom-Json).groupId
    New-Item -ItemType Directory -Force -Path (Split-Path $hist -Parent), $leftover | Out-Null
    Set-Content -LiteralPath $hist -Value @('Get-Date', ('C:\ProgramData\deskside\app\scripts\remote\Install-MeshAgent.ps1 -ServerUrl https://x -GroupId ' + $g), 'Get-Service') -Encoding ascii
    Copy-Item -LiteralPath $values -Destination $saved
    Set-Content -LiteralPath (Join-Path $env:TEMP 'kit-group.txt') -Value $g -Encoding ascii
    'one history line with the group id, one leftover download folder'
}

Invoke-Step 'kit-stops-on-sac' {
    $env:DESKSIDE_FORCE_SAC = 'On'
    try { $code = Invoke-Kit } finally { Remove-Item Env:\DESKSIDE_FORCE_SAC }
    $rb = Get-Readback
    Assert-That ($code -eq 1) "exit $code"
    Assert-That (@($rb | Where-Object { $_ -like 'stopped: Smart App Control is on*Nothing was changed*' }).Count -eq 1) ('readback: ' + ($rb -join ' / '))
    Assert-That (-not (Test-Path 'C:\ProgramData\deskside')) 'C:\ProgramData\deskside was created'
    Assert-That ((Test-Path $leftover) -and @(Get-Content $hist).Count -eq 3) 'the planted traces were touched'
    Assert-That (Test-Path $values) 'values.json is gone'
    'stopped with the plain message; nothing on the PC changed; values kept for the next run'
}

Invoke-Step 'kit-first-visit' {
    $t0 = Get-Date
    $code = Invoke-Kit
    $rb = Get-Readback
    Assert-That ($code -eq 0) ("exit $code; readback: " + ($rb -join ' / '))
    foreach ($want in 'deskside: first visit', 'step MeshCentral agent: done', 'step Help button: done', 'step Loopback SSH: done', 'service Mesh Agent: Running', 'service sshd: Running', 'port 22 listens on: 127.0.0.1', 'values: removed from the drive') {
        Assert-That ($rb -contains $want) "readback lacks '$want'"
    }
    $removed = @($rb | Where-Object { $_ -like 'removed: *' })[0]
    Assert-That ($removed -like 'removed: 1 leftover download folder(s), 1 history line(s) in 1 file(s);*') "readback: $removed"
    Assert-That (-not (Test-Path $leftover)) 'the leftover download folder is still there'
    Assert-That (@(Get-Content $hist) -join '|' -eq 'Get-Date|Get-Service') 'the history line is still there'
    Assert-That (-not (Test-Path $values)) 'values.json is still on the drive'
    Assert-That (@(Get-ChildItem 'C:\ProgramData\deskside\data\runs' -Directory -Filter '*-mesh-install').Count -eq 1) 'no mesh-install record'
    "kit ran in $([int]((Get-Date) - $t0).TotalMinutes) min; $removed"
}

Invoke-Step 'kit-again' {
    Copy-Item -LiteralPath $saved -Destination $values
    $code = Invoke-Kit
    $rb = Get-Readback
    Assert-That ($code -eq 0) ("exit $code; readback: " + ($rb -join ' / '))
    Assert-That ($rb -contains 'deskside: scripts refreshed from the drive') 'not refreshed'
    Assert-That ($rb -contains 'service Mesh Agent: Running') 'agent not running'
    Assert-That (-not (Test-Path $values)) 'values.json is still on the drive'
    Remove-Item -LiteralPath $saved -Force
    'second run: scripts refreshed, agent still running, values removed again'
}

Invoke-Step 'no-id-on-pc' {
    # The group id must not be left on the PC outside the agent's own settings: not in an event log (a child
    # powershell.exe's command line is kept there), a history file or a run record.
    $g = (Get-Content -LiteralPath (Join-Path $env:TEMP 'kit-group.txt') -Raw).Trim()
    $where = @()
    foreach ($log in 'Windows PowerShell', 'Microsoft-Windows-PowerShell/Operational', 'Application') {
        $n = @(Get-WinEvent -LogName $log -ErrorAction SilentlyContinue | Where-Object { $_.Message -and $_.Message.Contains($g) }).Count
        if ($n) { $where += "$n event(s) in $log" }
    }
    $files = @(Get-ChildItem 'C:\ProgramData\deskside', (Split-Path $hist -Parent) -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 32MB -and [IO.File]::ReadAllText($_.FullName).Contains($g) })
    if ($files.Count) { $where += "$($files.Count) file(s): " + (($files | ForEach-Object { $_.Name }) -join ', ') }
    Remove-Item -LiteralPath (Join-Path $env:TEMP 'kit-group.txt') -Force
    Assert-That ($where.Count -eq 0) ('the group id is on the PC: ' + ($where -join '; '))
    'the group id is in no PowerShell or Application event, history file or deskside file'
}

Write-Step 'waiting-for-host' $true 'kit done; the host reads the drive back'
$deadline = (Get-Date).AddMinutes(20)
while (-not (Test-Path "$out\host-done") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
Write-Step 'host-done' (Test-Path "$out\host-done") 'host finished or timed out'

Invoke-Step 'remove-remote-help' {
    & $ps -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\deskside\app\scripts\remote\Remove-RemoteHelp.ps1' -Confirmed | Out-Null
    $left = @()
    if (Get-Service 'Mesh Agent' -ErrorAction SilentlyContinue) { $left += 'agent service' }
    if (Get-Service sshd -ErrorAction SilentlyContinue) { $left += 'sshd service' }
    if (Test-Path (Join-Path $env:ProgramFiles 'deskside\Help')) { $left += 'help button' }
    Assert-That ($left.Count -eq 0) ('left behind: ' + ($left -join ', '))
    'nothing left behind'
}

Copy-Item 'C:\ProgramData\deskside\data\runs' "$out\runs" -Recurse -Force -ErrorAction SilentlyContinue
Stop-Transcript | Out-Null
'done' | Set-Content "$out\DONE"
