#Requires -Version 7.0
<#
.SYNOPSIS
    The host half of the Sandbox proof: reaches the Sandbox through MeshCentral the way the console reaches a real PC.

.DESCRIPTION
    Run by Invoke-SandboxProof.ps1 (-Remote) once the Sandbox's agent is online. Uses a throwaway records store
    holding only meshcentral.json (copied from the real store) and one device, the Sandbox, so nothing of it lands in
    the real records. Steps, each written to <out>\host-steps.jsonl:
      1. route-ssh       MeshCmd port map to the Sandbox's 127.0.0.1:22, SSH in with the proof key, read PowerShell's
                         version.
      1b. real-key       the same route with the console's own deskside-ssh key from 1Password's agent (no proof key).
      2. claude-diagnose Claude Code, on this machine, runs the console's diagnose skill against the Sandbox; the run's
                         record must come back into the throwaway store.
      3. ssh-notice      that record says the console's notice reached the Sandbox's signed-in session.
    The Sandbox is in the Proofs group, which removes the device from the server when it disconnects.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDir,
    [string]$Alias = 'sandbox-proof'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$in = Join-Path $WorkDir 'in'; $out = Join-Path $WorkDir 'out'
$steps = Join-Path $out 'host-steps.jsonl'
Import-Module (Join-Path $root 'scripts\console\Deskside.Console.psm1') -Force

function Write-HostStep([string]$Name, [bool]$Ok, [string]$Detail) {
    [ordered]@{ time = (Get-Date).ToString('HH:mm:ss'); step = $Name; ok = $Ok; detail = $Detail } | ConvertTo-Json -Compress | Add-Content -LiteralPath $steps
    Write-Host ("[host] {0,-16} {1}  {2}" -f $Name, $(if ($Ok) { 'ok' } else { 'FAILED' }), $Detail)
}

$nodeFile = Join-Path $out 'nodeid.txt'
if (-not (Test-Path $nodeFile)) { Write-HostStep 'route-ssh' $false 'the Sandbox handed over no node id'; throw 'no node id' }
$nodeId = (Get-Content -LiteralPath $nodeFile -Raw).Trim()

# A throwaway records store and proof key.
$realSettings = Join-Path (Get-RecordsRoot) 'meshcentral.json'
$store = Join-Path $WorkDir 'records'
New-Item -ItemType Directory -Force -Path $store | Out-Null
Copy-Item -LiteralPath $realSettings -Destination (Join-Path $store 'meshcentral.json') -Force
[ordered]@{ devices = @([ordered]@{
            alias = $Alias; meshNodeId = $nodeId; sshUser = 'WDAGUtilityAccount'; profile = 'everyone'
            consent = [ordered]@{ diagnose = (Get-Date -Format 'yyyy-MM-dd'); onboard = (Get-Date -Format 'yyyy-MM-dd'); remote = (Get-Date -Format 'yyyy-MM-dd') }
        })
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $store 'devices.json')
$key = Join-Path $WorkDir 'host_proof_key'
Copy-Item -LiteralPath (Join-Path $in 'proof_key') -Destination $key -Force
& icacls.exe $key /inheritance:r /grant "${env:USERNAME}:F" | Out-Null
# Each Sandbox has a new host key: forget the last one's.
$kh = Join-Path $env:LOCALAPPDATA 'deskside\known_hosts'
if (Test-Path $kh) { & ssh-keygen.exe -R "deskside-$Alias" -f $kh *> $null }

$saved = @{ records = $env:DESKSIDE_RECORDS; identity = $env:DESKSIDE_SSH_IDENTITY }
$env:DESKSIDE_RECORDS = $store
$env:DESKSIDE_SSH_IDENTITY = $key
$failed = 0
try {
    # 1. The port map and SSH through it. The agent may take a moment to connect, so the route is retried.
    $device = Get-DesksideDevice -Alias $Alias
    $ok = $false; $detail = ''
    for ($try = 1; $try -le 6 -and -not $ok; $try++) {
        try {
            $route = Start-MeshRoute -Device $device
            try {
                $ssh = Get-SshArgument -Route $route -Device $device
                $o = (& ssh.exe @ssh "$($device.sshUser)@127.0.0.1" '$PSVersionTable.PSVersion.ToString()' 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -eq 0 -and $o -match '^\d+\.\d+') { $ok = $true; $detail = "SSH through the port map; Windows PowerShell $o (try $try)" }
                else { $detail = "ssh exit $LASTEXITCODE" }
            } finally { Stop-MeshRoute -Route $route }
        } catch { $detail = $_.Exception.Message }
        if (-not $ok) { Start-Sleep -Seconds 10 }
    }
    Write-HostStep 'route-ssh' $ok $detail
    if (-not $ok) { $failed++ }

    # 1b. The console's own key: deskside-ssh through 1Password's agent, named by its public key file (no proof key).
    if ($ok) {
        $env:DESKSIDE_SSH_IDENTITY = $null
        $kok = $false; $detail = ''
        try {
            $route = Start-MeshRoute -Device $device
            try {
                $ssh = Get-SshArgument -Route $route -Device $device
                $o = (& ssh.exe @ssh "$($device.sshUser)@127.0.0.1" 'whoami /groups | Select-String -SimpleMatch S-1-16-12288 -Quiet' 2>&1 | Out-String).Trim()
                $kok = ($LASTEXITCODE -eq 0 -and $o -eq 'True')
                $detail = if ($kok) { 'deskside-ssh from 1Password''s agent, named by its public key with IdentitiesOnly; elevated login' } else { "ssh exit $LASTEXITCODE" }
            } finally { Stop-MeshRoute -Route $route }
        } catch { $detail = $_.Exception.Message }
        $env:DESKSIDE_SSH_IDENTITY = $key
        Write-HostStep 'real-key' $kok $detail
        if (-not $kok) { $failed++ }
    }

    # 2. Claude Code runs the diagnose skill against the Sandbox.
    if ($ok) {
        $prompt = "Use the diagnose skill on the PC with alias $Alias. Add -Arguments '-Quick'. Then give the summary as the skill says."
        $allowed = 'PowerShell(pwsh -File scripts/console/Invoke-DesksideRemote.ps1:*),Bash(pwsh -File scripts/console/Invoke-DesksideRemote.ps1:*),Read,Glob,Grep,Skill'
        Push-Location $root
        # Tool rules don't stop a shell from writing, so the tree itself is compared before and after.
        $treeBefore = (git -C $root status --porcelain | Out-String)
        # The proof must not be able to patch the code it proves: no edits, only the console's own runner.
        $denied = 'Edit,Write,NotebookEdit'
        try { $reply = ($prompt | & claude -p --allowedTools $allowed --disallowedTools $denied --max-turns 20 2>&1 | Out-String) } finally { Pop-Location }
        $rec = Get-ChildItem -Path (Join-Path $store "devices\$Alias\runs") -Filter record.json -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Directory.Name -like '*-diagnose' } | Select-Object -First 1
        $valid = $false
        if ($rec) { try { $valid = ((Get-Content -LiteralPath $rec.FullName -Raw | ConvertFrom-Json).schema -eq 'deskside.record/v1') } catch { $valid = $false } }
        Set-Content -LiteralPath (Join-Path $out 'claude-reply.txt') -Value $reply
        $treeAfter = (git -C $root status --porcelain | Out-String)
        $untouched = $treeAfter -eq $treeBefore
        $detail = if (-not $untouched) { 'Claude Code changed files in the repo during the proof (git status differs)' }
            elseif ($valid) { 'Claude Code ran diagnose remotely; the record came back to the store; repo untouched' }
            else { 'no diagnose record came back; see claude-reply.txt' }
        $valid = $valid -and $untouched
        Write-HostStep 'claude-diagnose' $valid $detail
        if (-not $valid) { $failed++ }

        # 3. The notice: the pulled record says the console's notice reached the one signed-in session.
        $nok = $false; $detail = 'no record'
        if ($rec) {
            $n = (Get-Content -LiteralPath $rec.FullName -Raw | ConvertFrom-Json).data.notice
            $nok = ($n -and $n.sentBy -eq 'console' -and [int]$n.signedIn -eq 1 -and [int]$n.shown -eq 1)
            $detail = if ($n) { "notice in the record: sentBy $($n.sentBy), signedIn $($n.signedIn), shown $($n.shown)" } else { 'the record has no notice' }
        }
        Write-HostStep 'ssh-notice' $nok $detail
        if (-not $nok) { $failed++ }
    }
} finally {
    $env:DESKSIDE_RECORDS = $saved.records
    $env:DESKSIDE_SSH_IDENTITY = $saved.identity
    Remove-Item -LiteralPath $key -Force -ErrorAction SilentlyContinue
}
if ($failed -gt 0) { throw "$failed host step(s) failed." }
