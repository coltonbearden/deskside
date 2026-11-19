#Requires -Version 7.0
<#
.SYNOPSIS
    The scheduled health sweep: runs deskside's read-only diagnostics on every enrolled PC through MeshCentral, keeps
    one record per PC per run in the private records store, and reports to an uptime monitor.

.DESCRIPTION
    Runs beside the MeshCentral server (PowerShell 7 on Linux or Windows; Node.js for MeshCentral's meshctrl.js).
    1. Lists the device group's devices (meshctrl listdevices).
    2. For each online device, runs the installed diagnostics with -EmitJson through the agent
       (meshctrl runcommand --powershell --reply) and keeps the DESKSIDE-HEALTH line it prints.
    3. Writes devices/<alias>/health/<run>.json into the records checkout, commits and pushes it.
    4. Applies catalog/alerts.json, plus "not seen" (no successful record for 30 days), and pushes one status to the
       monitor: up with a count when nothing needs attention, down with each alias and reason otherwise.
    The PCs' names never go into the monitor message: devices.json's alias is used, or the node id's tail.

    Settings come from the environment so nothing about the server lives in this public repo:
      DESKSIDE_MESH_URL       wss://<server>
      DESKSIDE_MESH_USER      login token user      DESKSIDE_MESH_PASS   login token key
      DESKSIDE_MESH_GROUP     device group id (mesh//...)
      DESKSIDE_MESHCTRL       path to meshctrl.js
      DESKSIDE_RECORDS        a git checkout of the private records store (push access)
      DESKSIDE_PUSH_URL       the monitor's push URL (optional; without it the result is only printed)

.PARAMETER DryRun
    Don't commit, push or report; print what would be sent.
#>
[CmdletBinding()]
param([switch]$DryRun, [string]$Catalog = (Join-Path (Split-Path -Parent $PSScriptRoot) 'catalog'))

$ErrorActionPreference = 'Stop'
foreach ($v in 'DESKSIDE_MESH_URL', 'DESKSIDE_MESH_USER', 'DESKSIDE_MESH_PASS', 'DESKSIDE_MESH_GROUP', 'DESKSIDE_MESHCTRL', 'DESKSIDE_RECORDS') {
    if (-not [Environment]::GetEnvironmentVariable($v)) { throw "$v is not set." }
}
$alerts = Get-Content (Join-Path $Catalog 'alerts.json') -Raw | ConvertFrom-Json
$records = $env:DESKSIDE_RECORDS

function Invoke-MeshCtrl([string[]]$Arguments) {
    $all = @($env:DESKSIDE_MESHCTRL) + $Arguments + @('--url', $env:DESKSIDE_MESH_URL, '--loginuser', $env:DESKSIDE_MESH_USER, '--loginpass', $env:DESKSIDE_MESH_PASS)
    $o = & node @all 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "meshctrl $($Arguments[0]) failed: $o" }
    return $o
}

function Get-ValueAtPath($Object, [string]$Path) {
    $cur = $Object
    foreach ($p in $Path.Split('.')) { if ($null -eq $cur -or -not $cur.PSObject.Properties[$p]) { return $null }; $cur = $cur.$p }
    return $cur
}

function Push-Status([string]$Status, [string]$Message) {
    if ($Message.Length -gt 250) { $Message = $Message.Substring(0, 247) + '...' }
    Write-Information "monitor: $Status $Message" -InformationAction Continue
    if ($DryRun -or -not $env:DESKSIDE_PUSH_URL) { return }
    $u = $env:DESKSIDE_PUSH_URL + '?status=' + $Status + '&msg=' + [uri]::EscapeDataString($Message) + '&ping='
    Invoke-RestMethod -Uri $u -TimeoutSec 30 | Out-Null
}

try {
    $aliases = @{}
    $devFile = Join-Path $records 'devices.json'
    if (Test-Path $devFile) { foreach ($d in (Get-Content $devFile -Raw | ConvertFrom-Json).devices) { if ($d.meshNodeId) { $aliases[$d.meshNodeId] = $d.alias } } }

    $list = Invoke-MeshCtrl @('listdevices', '--group', $env:DESKSIDE_MESH_GROUP, '--json') | ConvertFrom-Json
    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $problems = New-Object System.Collections.Generic.List[string]
    $checked = 0

    foreach ($dev in @($list)) {
        $id = $dev._id
        $label = $aliases[$id]
        if (-not $label) { $label = 'node ' + $id.Substring([Math]::Max(0, $id.Length - 6)) }
        # Same folder as the console's runs: devices/<alias>; a device not yet in devices.json uses its node id.
        $folder = $aliases[$id]
        if (-not $folder) { $folder = ($id -replace '[^A-Za-z0-9]', '_') }
        $dir = Join-Path $records "devices/$folder/health"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $online = ($dev.PSObject.Properties['conn'] -and (([int]$dev.conn) -band 1))
        $health = $null
        if ($online) {
            $cmd = "& 'C:\ProgramData\deskside\app\scripts\diagnose\Invoke-Diagnose.ps1' -Quick -EmitJson"
            try {
                $reply = Invoke-MeshCtrl @('runcommand', '--id', $id, '--run', $cmd, '--powershell', '--reply')
                $line = ($reply -split "`r?`n" | Where-Object { $_ -like 'DESKSIDE-HEALTH *' } | Select-Object -Last 1)
                if ($line) { $health = $line.Substring(16) | ConvertFrom-Json }
            } catch { Write-Warning "$label : $($_.Exception.Message)" }
        }
        if ($health) {
            $checked++
            ($health | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $dir "$runId.json")
            foreach ($r in $alerts.rules) {
                $hit = $false
                if ($r.when -eq 'finding') { $hit = [bool](@($health.findings | Where-Object { $r.findings -contains $_.id }).Count) }
                elseif ($r.when -eq 'olderThan') {
                    $v = Get-ValueAtPath $health.data $r.path
                    if ($v) { $hit = (((Get-Date).ToUniversalTime() - [datetime]$v).TotalDays -gt $r.days) }
                }
                if ($hit) { $problems.Add("$label`: $($r.message)") }
            }
        } else {
            # Age from the newest record, or from when the sweep first saw the device (first-seen.txt).
            $newest = Get-ChildItem $dir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
            $since = $null
            if ($newest) { $since = [datetime]::ParseExact($newest.BaseName, 'yyyyMMddTHHmmssZ', $null) }
            else {
                $marker = Join-Path $dir 'first-seen.txt'
                if (-not (Test-Path $marker)) { $runId | Set-Content $marker }
                $since = [datetime]::ParseExact((Get-Content $marker -TotalCount 1).Trim(), 'yyyyMMddTHHmmssZ', $null)
            }
            if (((Get-Date).ToUniversalTime() - $since).TotalDays -gt $alerts.notSeenDays) { $problems.Add("$label`: not seen for $($alerts.notSeenDays) days") }
        }
    }

    if (-not $DryRun) {
        & git -C $records add -A devices
        & git -C $records diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            & git -C $records commit -q -m "health sweep $runId"
            & git -C $records push -q
            if ($LASTEXITCODE -ne 0) { throw 'Could not push the health records.' }
        }
    }
    if ($problems.Count -eq 0) { Push-Status 'up' "$checked PC(s) checked, nothing needs attention" }
    else { Push-Status 'down' ($problems -join '; ') }
} catch {
    Push-Status 'down' ("health sweep failed: " + $_.Exception.Message)
    throw
}
