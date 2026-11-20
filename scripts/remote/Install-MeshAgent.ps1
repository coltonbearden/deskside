#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the MeshCentral agent from the helper's server and device group, so he can help remotely later.

.DESCRIPTION
    Downloads the Windows agent for the device group from the server (MeshCentral serves it at
    /meshagents?id=4&meshid=<group>&installflags=0: 64-bit, background service plus the tray so the person can see
    sessions and ask for help) and runs it with -fullinstall. The device group's notify setting shows the person a
    notice and a privacy bar for desktop, terminal and file sessions; MeshCentral shows nothing for a TCP port map (the
    SSH route deskside's console uses), which the consent wording says. A "Remove remote help" shortcut goes on the public desktop.

    Needs the owner's 'remote' consent and stops on a work or school PC. The server address and group come in as
    parameters: they never live in this public repo.

.PARAMETER ServerUrl
    https://<the server's public name>

.PARAMETER GroupId
    The device group's mesh id (from the group's "Add Agent" link: the meshid= value).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^https://')][string]$ServerUrl,
    [Parameter(Mandatory)][string]$GroupId,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
Assert-NotManaged
Assert-Consent -Scope remote
if (-not (Test-IsAdministrator)) { throw 'Installing the agent needs administrator rights.' }
if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { throw 'Only 64-bit Intel/AMD Windows is supported for now.' }

$run = New-DesksideRun -Kind 'mesh-install' -OutputDirectory $OutputDirectory
$svc = Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue
if ($svc) {
    $run.Changes.Add([pscustomobject]@{ what = 'MeshCentral agent'; result = 'already installed' })
} elseif ($PSCmdlet.ShouldProcess('MeshCentral agent', 'Download from the server and install')) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $tmp = Join-Path $env:TEMP ('deskside-mesh-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $exe = Join-Path $tmp 'meshagent.exe'
    $url = $ServerUrl.TrimEnd('/') + '/meshagents?id=4&meshid=' + [uri]::EscapeDataString($GroupId) + '&installflags=0'
    Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
    $sig = Get-AuthenticodeSignature -FilePath $exe
    $run.Data['agentSignature'] = [string]$sig.Status
    $p = Start-Process -FilePath $exe -ArgumentList '-fullinstall' -Wait -PassThru -WindowStyle Hidden
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(60)
    do { Start-Sleep -Seconds 2; $svc = Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue } while ((-not $svc -or $svc.Status -ne 'Running') -and (Get-Date) -lt $deadline)
    if (-not $svc -or $svc.Status -ne 'Running') { throw "The agent did not start (installer exit $($p.ExitCode))." }
    Save-BeforeState -Run $run -ItemId 'mesh-agent' -Undo @{ type = 'note'; text = 'Remove the agent with scripts\remote\Remove-RemoteHelp.ps1.' }
    $run.Changes.Add([pscustomobject]@{ what = 'MeshCentral agent'; result = 'installed and running' })
}

# The person's own way out: a desktop shortcut to the removal script.
$appRoot = Get-DesksideRoot
$shortcut = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Remove remote help.cmd'
if ($PSCmdlet.ShouldProcess($shortcut, 'Create removal shortcut')) {
    $remover = Join-Path $appRoot 'scripts\remote\Remove-RemoteHelp.ps1'
    $cmd = "@echo off`r`necho This removes remote help (MeshCentral) and the helper's sign-in from this PC.`r`n" +
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ""Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \""$remover\"" -Confirmed'""`r`n"
    [IO.File]::WriteAllText($shortcut, $cmd, (New-Object Text.ASCIIEncoding))
    $run.Changes.Add([pscustomobject]@{ what = 'Remove remote help shortcut'; result = 'on the desktop' })
}
Complete-DesksideRun -Run $run -SummaryTitle 'Remote help: agent' | Out-Null