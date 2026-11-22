#Requires -Version 5.1
<#
.SYNOPSIS
    deskside remote help setup, run from a USB drive ("START HERE.cmd"). Nothing to type: the helper's values are in
    values.json beside this script, written there by the helper's console (scripts\console\New-DesksideUsbKit.ps1).

.DESCRIPTION
    In order, and safe to run again:
    1. Stops, changing nothing, on a work or school PC.
    2. Stops, changing nothing, when Smart App Control is on and the agent isn't signed with a certificate Windows
       trusts (it would be blocked).
    3. Puts deskside on the PC from the drive: the usual first visit (bootstrap, with the owner's prompts) when it isn't
       there yet, otherwise a refresh of its scripts (its records stay).
    4. Removes what an earlier attempt can leave behind (a leftover agent download, history lines holding the group id,
       Defender's allow for detection 489403) and says so in readback.txt.
    5. The owner's yes to remote help (asked if it isn't recorded), the agent, the help button, loopback SSH.
    6. Writes what the helper needs into readback.txt on the drive, deletes values.json, and ends.
    The full log goes to log.txt on the drive. The helper's console reads both back and wipes the kit's values.

.PARAMETER CheckOnly
    Only checks 1 and 2, changes nothing, and doesn't elevate.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'An on-screen kit for the person at the PC; the transcript keeps what Write-Host shows.')]
[CmdletBinding()]
param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'

function Read-KitValue {
    <# values.json, checked: an https server, a 64-character group id, an ed25519 public key and the helper's name. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw 'This drive has no values (values.json). Ask the helper to build the drive again.' }
    $v = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $checks = @(
        @{ name = 'serverUrl'; pattern = '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$' },
        @{ name = 'groupId'; pattern = '^[A-Za-z0-9$@]{64}$' },
        @{ name = 'publicKey'; pattern = '^ssh-ed25519 [A-Za-z0-9+/=]{60,}( [!-~]+)?$' },
        @{ name = 'helperName'; pattern = '^[A-Za-z0-9 .-]{1,40}$' }
    )
    foreach ($c in $checks) {
        $p = $v.PSObject.Properties[$c.name]
        if (-not $p -or -not ([string]$p.Value -cmatch $c.pattern)) { throw ("The drive's values are incomplete (" + $c.name + '). Ask the helper to build the drive again.') }
    }
    return $v
}

function Get-AgentSignature {
    <# Downloads the agent for the group to a temporary folder, reads its signature and removes the folder again. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServerUrl, [Parameter(Mandatory)][string]$GroupId)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $tmp = Join-Path $env:TEMP ('deskside-check-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $exe = Join-Path $tmp 'meshagent.exe'
        $url = $ServerUrl.TrimEnd('/') + '/meshagents?id=4&meshid=' + [uri]::EscapeDataString($GroupId) + '&installflags=0'
        try { Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing } catch { throw ('Could not download the agent from the server: ' + $_.Exception.Message) }
        return [string](Get-AuthenticodeSignature -FilePath $exe).Status
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Test-KitCanInstall {
    <#
    .SYNOPSIS
        Checks 1 and 2. Returns Stop (the plain reason, or $null), SmartAppControl and Signature. Changes nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Values, [string]$ForceSmartAppControl)
    $r = [ordered]@{ Stop = $null; SmartAppControl = $null; Signature = $null }
    $m = Test-ManagedDevice
    if ($m.IsManaged) { $r.Stop = 'This PC belongs to a work or school (' + ($m.Reasons -join '; ') + '). deskside changes nothing here.'; return [pscustomobject]$r }
    $r.SmartAppControl = Get-SmartAppControlState
    if ($ForceSmartAppControl) { $r.SmartAppControl = $ForceSmartAppControl }
    $r.Signature = Get-AgentSignature -ServerUrl $Values.serverUrl -GroupId $Values.groupId
    if (Test-AgentBlocked -State $r.SmartAppControl -Signature $r.Signature) { $r.Stop = Get-AgentBlockedText -HelperName $Values.helperName }
    return [pscustomobject]$r
}

function Update-DesksideApp {
    <# Replaces C:\ProgramData\deskside\app with the copy on the drive, the way bootstrap does; data stays. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Zip, [Parameter(Mandatory)][string]$App)
    $base = Split-Path -Parent $App
    $stage = Join-Path $base ('stage-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        Expand-Archive -LiteralPath $Zip -DestinationPath $stage -Force
        $dir = Get-ChildItem -LiteralPath $stage -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'scripts\diagnose\Invoke-Diagnose.ps1') } | Select-Object -First 1
        if (-not $dir) { throw 'The drive''s copy of deskside is damaged. Ask the helper to build the drive again.' }
        if ($PSCmdlet.ShouldProcess($App, 'Replace with the drive''s copy')) {
            if (Test-Path -LiteralPath $App) { Remove-Item -LiteralPath $App -Recurse -Force }
            Move-Item -LiteralPath $dir.FullName -Destination $App
        }
    } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}

# Dot-sourced (the tests): functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

$kit = Split-Path -Parent $MyInvocation.MyCommand.Path
$drive = Split-Path -Parent $kit
$readback = Join-Path $drive 'readback.txt'
$valuesPath = Join-Path $kit 'values.json'
$app = Join-Path $env:ProgramData 'deskside\app'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# The Sandbox proof runs with nobody to answer prompts. It only works inside Windows Sandbox.
$proof = ($env:DESKSIDE_SANDBOX_PROOF -eq '1' -and $env:USERNAME -eq 'WDAGUtilityAccount')

function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Write-Say([string]$Text, [string]$Color = 'White') { Write-Host $Text -ForegroundColor $Color }
function Add-Readback([string[]]$Line) { Add-Content -LiteralPath $readback -Value $Line -Encoding ASCII }
function Exit-Kit([string]$Why) {
    Write-Say ''; Write-Say ('STOPPED: ' + $Why) 'Red'
    try { Add-Readback ('stopped: ' + $Why) } catch { $null = $_ }
    if (-not $CheckOnly) { try { Stop-Transcript | Out-Null } catch { $null = $_ } }
    if (-not $CheckOnly -and -not $proof) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
function Invoke-KitStep([string]$Name, [string]$File, [string[]]$Arguments) {
    # Output goes through the host so the log on the drive keeps it; native stderr must not stop this script (5.1).
    Write-Say ''; Write-Say ('-- ' + $Name + ' ...') 'Cyan'
    $ErrorActionPreference = 'Continue'
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app $File) @Arguments 2>&1 | ForEach-Object { Write-Host ([string]$_) }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) { Exit-Kit ($Name + ' failed (exit ' + $code + '). The log on this drive has the error.') }
    Add-Readback ('step ' + $Name + ': done')
}

if (-not $CheckOnly -and -not (Test-Admin)) {
    Start-Process -FilePath $ps -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $MyInvocation.MyCommand.Path + '"'))
    exit 0
}
if (-not $CheckOnly) { try { Start-Transcript -LiteralPath (Join-Path $drive 'log.txt') -Append | Out-Null } catch { $null = $_ } }
# Each run appends its own section, so running the drive again never loses an earlier run's results.
Add-Readback ('run: ' + (Get-Date).ToString('s'))
Write-Say 'deskside remote help setup' 'Cyan'

Import-Module (Join-Path $kit 'Deskside.Common.psm1') -Force
try { $values = Read-KitValue -Path $valuesPath } catch { Exit-Kit $_.Exception.Message }
$built = $null
try { $built = (Get-Content -LiteralPath (Join-Path $kit 'kit.json') -Raw | ConvertFrom-Json).commit } catch { $null = $_ }
Add-Readback ('kit: ' + $built)

# 1 and 2: work or school, then Smart App Control. Nothing changes before both pass.
$force = $null
if ($proof -and $env:DESKSIDE_FORCE_SAC) { $force = $env:DESKSIDE_FORCE_SAC }
try { $check = Test-KitCanInstall -Values $values -ForceSmartAppControl $force } catch { Exit-Kit $_.Exception.Message }
Write-Say ('Smart App Control: ' + $check.SmartAppControl)
Write-Say ('Agent signature: ' + $check.Signature)
Add-Readback @(('smart app control: ' + $check.SmartAppControl), ('agent signature: ' + $check.Signature))
if ($check.Stop) { Exit-Kit $check.Stop }
if ($CheckOnly) { Write-Say 'Check only: would continue to install.' 'Green'; exit 0 }

# 3. deskside itself, from the drive.
$env:DESKSIDE_SOURCE_ZIP = Join-Path $kit 'deskside.zip'
if (-not (Test-Path -LiteralPath (Join-Path $app 'scripts\diagnose\Invoke-Diagnose.ps1'))) {
    Write-Say ''; Write-Say '-- deskside (first visit: a health check, then setup, each asked first) ...' 'Cyan'
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'bootstrap.ps1')
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $app 'scripts\diagnose\Invoke-Diagnose.ps1'))) { Exit-Kit 'deskside could not be put on this PC. The log on this drive has the error.' }
    Add-Readback 'deskside: first visit'
} else {
    try { Update-DesksideApp -Zip $env:DESKSIDE_SOURCE_ZIP -App $app } catch { Exit-Kit $_.Exception.Message }
    Add-Readback 'deskside: scripts refreshed from the drive'
}

# 4. What an earlier attempt can leave behind.
$gone = Remove-EnrollTrace -GroupId $values.groupId
Add-Readback ('removed: ' + $gone.tempFolders + ' leftover download folder(s), ' + $gone.historyLines + ' history line(s) in ' + $gone.historyFiles + ' file(s); defender allow 489403: ' + $gone.defenderAllow)

# 5. The owner's yes, then agent, help button and SSH.
$consentPath = 'C:\ProgramData\deskside\data\consent.json'
$hasRemote = $false
if (Test-Path -LiteralPath $consentPath) { $hasRemote = [bool]((Get-Content -LiteralPath $consentPath -Raw | ConvertFrom-Json).scopes.PSObject.Properties['remote']) }
if (-not $hasRemote) {
    $yes = @(); if ($proof) { $yes = @('-Confirmed') }
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'scripts\onboard\Grant-Consent.ps1') -Scope remote @yes
    if ($LASTEXITCODE -ne 0) { Exit-Kit 'the owner did not agree to remote help, so nothing was installed.' }
} else { Write-Say 'Owner''s yes to remote help: already recorded.' }
# The agent runs in this process: a child powershell.exe's whole command line, group id included, would be kept in
# the PC's "Windows PowerShell" event log (HostApplication, events 400 and 403).
Write-Say ''; Write-Say '-- MeshCentral agent ...' 'Cyan'
try { & (Join-Path $app 'scripts\remote\Install-MeshAgent.ps1') -ServerUrl $values.serverUrl -GroupId $values.groupId | Out-Host }
catch { Exit-Kit ('MeshCentral agent failed: ' + $_.Exception.Message) }
Add-Readback 'step MeshCentral agent: done'
Invoke-KitStep 'Help button' 'scripts\remote\Install-HelpButton.ps1' @('-HelperName', $values.helperName)
Invoke-KitStep 'Loopback SSH' 'scripts\remote\Enable-LoopbackSsh.ps1' @('-PublicKey', $values.publicKey)

# 6. What the helper needs back, then the values go.
$out = New-Object System.Collections.Generic.List[string]
$r = Get-ChildItem 'C:\ProgramData\deskside\data\runs' -Directory -Filter '*-mesh-install' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
if ($r) { $out.Add('node: ' + (Get-Content -LiteralPath (Join-Path $r.FullName 'record.json') -Raw | ConvertFrom-Json).data.meshNodeId) }
$u = [string](Get-CimInstance Win32_ComputerSystem).UserName
$out.Add('account: ' + ($u -replace '^.*\\', ''))
(Get-Content -LiteralPath $consentPath -Raw | ConvertFrom-Json).scopes.PSObject.Properties | ForEach-Object { $out.Add('consent: ' + $_.Name + ' ' + $_.Value.grantedUtc) }
foreach ($n in 'Mesh Agent', 'sshd') { $out.Add('service ' + $n + ': ' + [string](Get-Service -Name $n -ErrorAction SilentlyContinue).Status) }
$out.Add('port 22 listens on: ' + ((Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue | ForEach-Object LocalAddress | Sort-Object -Unique) -join ', '))
Remove-Item -LiteralPath $valuesPath -Force
$out.Add('values: ' + $(if (Test-Path -LiteralPath $valuesPath) { 'still on the drive' } else { 'removed from the drive' }))
$out.Add('done: ' + (Get-Date).ToString('s'))
Add-Readback $out.ToArray()
Write-Say ''; Write-Say 'Done. Bring the USB drive back to the helper.' 'Green'
try { Stop-Transcript | Out-Null } catch { $null = $_ }
if (-not $proof) { Read-Host 'Press Enter to close' | Out-Null }
