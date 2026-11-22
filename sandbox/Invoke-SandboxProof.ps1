#Requires -Version 7.0
<#
.SYNOPSIS
    Proves deskside end to end in Windows Sandbox: a clean Windows that is thrown away when it closes.

.DESCRIPTION
    Builds the proof folder (the repo as a zip, the bootstrap, a throwaway SSH key pair, the config), writes a .wsb
    with networking on, the inputs mapped read-only and a results folder mapped writable, starts Windows Sandbox and
    waits for sandbox\proof-inner.ps1 to finish. Prints each step's result and exits 1 if any failed.

    -Source local proves the working tree (before a push); -Source github runs the README's exact one-liner.
    With -ServerUrl and -GroupId the MeshCentral agent is installed too and -HostCheck runs on this machine while
    the Sandbox waits (port map, SSH through it, Claude Code running the diagnostics remotely).

    -Remote does that from the private records store: the agent address from meshcentral.json, the group id read from
    1Password by its "proofGroupRef" (a group that removes devices when they disconnect), and
    sandbox\Invoke-HostCheck.ps1 as the host check.

    -UsbKit proves the USB kit instead (sandbox\kit-inner.ps1): New-DesksideUsbKit.ps1 -Proof builds a kit of the
    committed HEAD into a folder mapped writable at C:\kit, the Sandbox runs it (stopped by a forced Smart App Control,
    then for real, then again). -KitPath takes a kit built beforehand (1Password asks for approval per terminal, so an
    unattended run can't build one). Afterwards read the kit folder back with
    Read-DesksideUsbKit.ps1 -Path <kit> -Alias sandbox-proof -RecordsRoot <a temporary folder>.

    Only one Windows Sandbox can run at a time; close any other first.
#>
[CmdletBinding()]
param(
    [ValidateSet('local', 'github')][string]$Source = 'local',
    [string]$Ref = 'main',
    [string]$ServerUrl,
    [string]$GroupId,
    [scriptblock]$HostCheck,
    [switch]$Remote,
    [switch]$UsbKit,
    [string]$KitPath,
    [string]$WorkDir = (Join-Path $env:TEMP 'deskside-proof'),
    [int]$TimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($Remote) {
    Import-Module (Join-Path $root 'scripts\console\Deskside.Console.psm1') -Force
    $ms = Get-MeshSetting
    $ServerUrl = $ms.serverUrl
    $GroupId = (& op read $ms.proofGroupRef).Trim()
    if (-not $GroupId) { throw '1Password did not return the proof group id.' }
    $hostScript = Join-Path $PSScriptRoot 'Invoke-HostCheck.ps1'
    $proofDir = $WorkDir
    $HostCheck = { & $hostScript -WorkDir $proofDir }.GetNewClosure()
}
if (Get-Process -Name WindowsSandbox, WindowsSandboxClient, WindowsSandboxRemoteSession -ErrorAction SilentlyContinue) { throw 'A Windows Sandbox is already running; close it first.' }

Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
$in = Join-Path $WorkDir 'in'; $out = Join-Path $WorkDir 'out'
New-Item -ItemType Directory -Force -Path $in, $out | Out-Null

# The repo as GitHub would serve it: a zip with one top folder.
$stage = Join-Path $WorkDir 'stage\deskside-main'
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Push-Location $root
try { $files = @(git ls-files --cached --others --exclude-standard) } finally { Pop-Location }
foreach ($f in $files) {
    $dst = Join-Path $stage $f
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $f) -Destination $dst
}
Compress-Archive -Path $stage -DestinationPath (Join-Path $in 'deskside.zip')
Copy-Item (Join-Path $root 'bootstrap.ps1'), (Join-Path $PSScriptRoot 'proof-inner.ps1') $in

# A throwaway key pair, used only inside this Sandbox.
& ssh-keygen.exe -q -t ed25519 -N '' -C 'deskside-sandbox-proof' -f (Join-Path $in 'proof_key') | Out-Null
if (-not (Test-Path (Join-Path $in 'proof_key.pub'))) { throw 'ssh-keygen did not make the proof key.' }
$pub = (Get-Content (Join-Path $in 'proof_key.pub') -Raw).Trim()
# With -Remote the helper's own deskside-ssh public key goes in too, so one host login proves the real key path.
$realPub = $null
if ($Remote) { $realPub = (Get-Content -LiteralPath (Get-SshPublicKeyFile -Settings $ms) -Raw).Trim() }
[ordered]@{ source = $Source; ref = $Ref; serverUrl = $ServerUrl; groupId = $GroupId; publicKey = $pub; realPublicKey = $realPub } | ConvertTo-Json | Set-Content (Join-Path $in 'proof-config.json')

$inner = 'proof-inner.ps1'
$kitMap = ''
if ($UsbKit) {
    # The kit stands in for a USB drive: built here from 1Password, run in the Sandbox, read back here.
    # 1Password approves op per terminal, so a run left in the background can't ask it: build the kit first in the
    # helper's own window (-KitPath) when this runs unattended.
    if ($KitPath) { $kitDir = (Resolve-Path -LiteralPath $KitPath).Path }
    else {
        $kitDir = Join-Path $WorkDir 'kit'
        New-Item -ItemType Directory -Force -Path $kitDir | Out-Null
        & (Join-Path $root 'scripts\console\New-DesksideUsbKit.ps1') -Path $kitDir -Proof
    }
    if (-not (Test-Path -LiteralPath (Join-Path $kitDir 'deskside\values.json'))) { throw "No built kit with values in $kitDir." }
    Copy-Item (Join-Path $PSScriptRoot 'kit-inner.ps1') $in
    $inner = 'kit-inner.ps1'
    $kitMap = "<MappedFolder><HostFolder>$kitDir</HostFolder><SandboxFolder>C:\kit</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>"
    $HostCheck = $null
}

$wsb = @"
<Configuration>
  <Networking>Enable</Networking>
  <vGPU>Disable</vGPU>
  <MappedFolders>
    <MappedFolder><HostFolder>$in</HostFolder><SandboxFolder>C:\in</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$out</HostFolder><SandboxFolder>C:\out</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
    $kitMap
  </MappedFolders>
  <LogonCommand><Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\in\$inner</Command></LogonCommand>
</Configuration>
"@
$wsbPath = Join-Path $WorkDir 'proof.wsb'
Set-Content -LiteralPath $wsbPath -Value $wsb -Encoding utf8
Start-Process -FilePath $wsbPath
Write-Host "Windows Sandbox started; results in $out"

$seen = 0
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$hostRan = $false
while (-not (Test-Path (Join-Path $out 'DONE')) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $lines = @(Get-Content (Join-Path $out 'proof.jsonl') -ErrorAction SilentlyContinue)
    for ($i = $seen; $i -lt $lines.Count; $i++) {
        $s = $lines[$i] | ConvertFrom-Json
        Write-Host ("[{0}] {1,-20} {2}  {3}" -f $s.time, $s.step, $(if ($s.ok) { 'ok' } else { 'FAILED' }), $s.detail)
        if ($s.step -eq 'waiting-for-host' -and $HostCheck -and -not $hostRan) {
            $hostRan = $true
            try { & $HostCheck; 'ok' | Set-Content (Join-Path $out 'host-result.txt') } catch { "FAILED: $($_.Exception.Message)" | Set-Content (Join-Path $out 'host-result.txt') }
            'done' | Set-Content (Join-Path $out 'host-done')
        } elseif ($s.step -eq 'waiting-for-host' -and -not $HostCheck) { 'done' | Set-Content (Join-Path $out 'host-done') }
    }
    $seen = $lines.Count
}
Get-Process -Name WindowsSandbox, WindowsSandboxClient, WindowsSandboxRemoteSession -ErrorAction SilentlyContinue | Stop-Process -Force
$results = @(Get-Content (Join-Path $out 'proof.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json })
if (-not (Test-Path (Join-Path $out 'DONE'))) { Write-Host 'The proof timed out.' -ForegroundColor Red; exit 1 }
$failed = @($results | Where-Object { -not $_.ok })
$hostSteps = @(Get-Content (Join-Path $out 'host-steps.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json })
foreach ($h in $hostSteps) { Write-Host ("[{0}] host:{1,-15} {2}  {3}" -f $h.time, $h.step, $(if ($h.ok) { 'ok' } else { 'FAILED' }), $h.detail) }
$results += $hostSteps
$failed = @($results | Where-Object { -not $_.ok })
if (Test-Path (Join-Path $out 'host-result.txt')) {
    $hr = (Get-Content (Join-Path $out 'host-result.txt') -Raw).Trim()
    Write-Host "host check: $hr"
    if ($hr -ne 'ok' -and $hostSteps.Count -eq 0) { $failed += [pscustomobject]@{ step = 'host'; ok = $false } }
}
Write-Host ("{0} step(s), {1} failed." -f $results.Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
