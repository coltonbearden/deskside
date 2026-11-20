#Requires -Version 7.2
<#
.SYNOPSIS
    The scheduled health sweep: runs deskside's read-only diagnostics on every enrolled PC through MeshCentral, keeps
    one record per PC per run in the private records store, and reports to an uptime monitor.

.DESCRIPTION
    Runs beside the MeshCentral server (PowerShell 7 on Linux or Windows; Node.js for MeshCentral's meshctrl.js).
    1. Lists the device group's devices (meshctrl listdevices --id <group id>).
    2. For each online device, runs the installed diagnostics with -EmitJson through the agent
       (meshctrl runcommand --powershell --reply) and keeps the DESKSIDE-HEALTH line it prints. The agent's PowerShell
       starts a child powershell.exe with -ExecutionPolicy Bypass for that run only, as the console and bootstrap do:
       a PC on the default Restricted policy refuses a bare '& script.ps1'.
    3. Writes devices/<alias>/health/<run>.json into the records checkout, commits and pushes it.
    4. Applies catalog/alerts.json, plus "not seen" (no successful record for 30 days), and pushes one status to the
       monitor: up with a count when nothing needs attention, down with each alias and reason otherwise.

    What leaves the records store is alias-only: the monitor's message names a PC by its devices.json alias, or as
    "a PC not in devices.json", never by its name or node id, and a failure is reported by the step that failed,
    never by the error's own text (which can carry meshctrl output or paths). The details go to this script's own
    output only.

    Settings come from the environment so nothing about the server lives in this public repo:
      DESKSIDE_MESH_URL       wss://<server>
      DESKSIDE_MESH_USER      login token user      DESKSIDE_MESH_PASS   login token key
      DESKSIDE_MESH_GROUP     device group id (mesh//...)
      DESKSIDE_MESHCTRL       path to meshctrl.js
      DESKSIDE_RECORDS        a git checkout of the private records store (push access, an identity for commits)
      DESKSIDE_PUSH_URL       the monitor's push URL, with no query string (optional; without it the result is only
                              printed)
      DESKSIDE_NODE           the Node.js executable (optional; default: node on PATH)
    The login reaches meshctrl through meshctrl's own MESHCTRL_URL, MESHCTRL_LOGINUSER and MESHCTRL_LOGINPASS, never
    its command line, which any local user can read in the process list.

.PARAMETER DryRun
    Don't commit, push or report; print what would be sent. Records are still written into the checkout's working
    tree, so point DESKSIDE_RECORDS at a throwaway clone.

.PARAMETER ListTimeoutSeconds
    How long the device list may take before the run fails.

.PARAMETER RunTimeoutSeconds
    How long one PC's check may take before it counts as failed. An agent already running a command never answers, so
    without a limit one busy PC would hold the whole sweep.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Catalog = (Join-Path (Split-Path -Parent $PSScriptRoot) 'catalog'),
    [ValidateRange(1, 3600)][int]$ListTimeoutSeconds = 60,
    [ValidateRange(1, 7200)][int]$RunTimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
foreach ($v in 'DESKSIDE_MESH_URL', 'DESKSIDE_MESH_USER', 'DESKSIDE_MESH_PASS', 'DESKSIDE_MESH_GROUP', 'DESKSIDE_MESHCTRL', 'DESKSIDE_RECORDS') {
    if (-not [Environment]::GetEnvironmentVariable($v)) { throw "$v is not set." }
}
$alerts = Get-Content (Join-Path $Catalog 'alerts.json') -Raw | ConvertFrom-Json
$records = $env:DESKSIDE_RECORDS
$nodeExe = if ($env:DESKSIDE_NODE) { $env:DESKSIDE_NODE } else { 'node' }
$script:Step = 'starting'

function Invoke-MeshCtrl([string[]]$Arguments, [int]$TimeoutSeconds) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new($nodeExe)
    $psi.ArgumentList.Add($env:DESKSIDE_MESHCTRL)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Environment['MESHCTRL_URL'] = $env:DESKSIDE_MESH_URL
    $psi.Environment['MESHCTRL_LOGINUSER'] = $env:DESKSIDE_MESH_USER
    $psi.Environment['MESHCTRL_LOGINPASS'] = $env:DESKSIDE_MESH_PASS
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill($true) } catch { Write-Verbose "kill: $($_.Exception.Message)" }
        throw "meshctrl $($Arguments[0]) timed out after $TimeoutSeconds s"
    }
    $p.WaitForExit()
    if ($err.Result) { Write-Verbose "meshctrl $($Arguments[0]) stderr: $($err.Result.Trim())" }
    # meshctrl ends with exit code 0 on its own errors too ("Invalid login", "Access denied"), so callers judge the
    # output itself: a JSON list, or a DESKSIDE-HEALTH line.
    return [pscustomobject]@{ Out = $out.Result; Code = $p.ExitCode }
}

function Invoke-Git([string[]]$Arguments) {
    $o = & git -C $records @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments[0]) failed: $($o.Trim())" }
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
    if (git -C $records rev-parse --abbrev-ref '@{upstream}' 2>$null) {
        $script:Step = 'updating the records checkout'
        Invoke-Git @('pull', '--ff-only', '-q')
    }

    $script:Step = 'reading devices.json'
    $aliases = @{}
    $devFile = Join-Path $records 'devices.json'
    if (Test-Path $devFile) { foreach ($d in (Get-Content $devFile -Raw | ConvertFrom-Json).devices) { if ($d.meshNodeId -and $d.alias) { $aliases[$d.meshNodeId] = $d.alias } } }

    $script:Step = 'listing the devices'
    $listed = Invoke-MeshCtrl @('listdevices', '--id', $env:DESKSIDE_MESH_GROUP, '--json') $ListTimeoutSeconds
    $text = $listed.Out.Trim()
    if (-not $text.StartsWith('[')) { throw "meshctrl listdevices did not return a list: $text" }
    $list = @($text | ConvertFrom-Json)

    $script:Step = 'checking the devices'
    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $problems = New-Object System.Collections.Generic.List[string]
    $checked = 0
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\deskside\app\scripts\diagnose\Invoke-Diagnose.ps1' -Quick -EmitJson"

    foreach ($dev in $list) {
        $id = [string]$dev._id
        $label = $aliases[$id]
        if (-not $label) { $label = 'a PC not in devices.json' }
        # Same folder as the console's runs: devices/<alias>; a device not yet in devices.json uses its node id there
        # (the private store only).
        $folder = $aliases[$id]
        if (-not $folder) { $folder = ($id -replace '[^A-Za-z0-9]', '_') }
        $dir = Join-Path $records "devices/$folder/health"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $online = ($dev.PSObject.Properties['conn'] -and (([int]$dev.conn) -band 1))
        $health = $null
        if ($online) {
            try {
                $reply = Invoke-MeshCtrl @('runcommand', '--id', $id, '--run', $cmd, '--powershell', '--reply') $RunTimeoutSeconds
                $line = ($reply.Out -split "`r?`n" | Where-Object { $_ -like 'DESKSIDE-HEALTH *' } | Select-Object -Last 1)
                if (-not $line) { throw 'no DESKSIDE-HEALTH line in the reply' }
                $health = $line.Substring(16) | ConvertFrom-Json
                Write-Information "$label : checked, $($line.Length) characters" -InformationAction Continue
            } catch {
                Write-Warning "$label : $($_.Exception.Message)"
                $problems.Add("$label`: online, but the check failed")
            }
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
        $script:Step = 'committing the records'
        Invoke-Git @('add', '-A', 'devices')
        & git -C $records diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            Invoke-Git @('commit', '-q', '-m', "health sweep $runId")
            $script:Step = 'pushing the records'
            & git -C $records push -q 2>&1 | Out-String | Write-Verbose
            if ($LASTEXITCODE -ne 0) {
                # Someone else pushed in between (the console): replay this run's commit on top, once.
                Invoke-Git @('pull', '--rebase', '-q')
                Invoke-Git @('push', '-q')
            }
        }
    }
    $script:Step = 'reporting'
    if ($problems.Count -eq 0) { Push-Status 'up' "$checked PC(s) checked, nothing needs attention" }
    else { Push-Status 'down' ($problems -join '; ') }
} catch {
    Write-Warning "health sweep failed while $($script:Step): $($_.Exception.Message)"
    Push-Status 'down' "health sweep failed while $($script:Step)"
    throw
}
