#Requires -Version 5.1
<#
.SYNOPSIS
    Removes remote help from this PC and leaves nothing behind: the MeshCentral agent, the SSH server deskside turned
    on, the helper's key, the desktop shortcut and the 'remote' consent.

.DESCRIPTION
    The person at the PC can run this any time from the "Remove remote help" shortcut on the desktop. It needs no
    consent: taking remote access away is always allowed. The helper also removes the device from the server
    (scripts\console\Remove-DesksideDevice.ps1), since uninstalling an agent doesn't delete it there.

.PARAMETER Confirmed
    Skip the "are you sure" prompt (the desktop shortcut passes it after its own message).
#>
[CmdletBinding(SupportsShouldProcess)]
param([switch]$Confirmed, [string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
if (-not (Test-IsAdministrator)) { throw 'Removing remote help needs administrator rights.' }
if (-not $Confirmed) {
    $a = Read-Host 'Remove remote help from this PC? Type YES to remove'
    if ($a -cne 'YES') { Write-Information 'Nothing was removed.' -InformationAction Continue; return }
}
$run = New-DesksideRun -Kind 'remote-remove' -OutputDirectory $OutputDirectory

# MeshCentral agent
$agentDir = Join-Path $env:ProgramFiles 'Mesh Agent'
$agentExe = Join-Path $agentDir 'MeshAgent.exe'
if ((Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $agentDir)) {
    if ($PSCmdlet.ShouldProcess('MeshCentral agent', 'Uninstall')) {
        if (Test-Path -LiteralPath $agentExe) { Start-Process -FilePath $agentExe -ArgumentList '-fulluninstall' -Wait -WindowStyle Hidden }
        Start-Sleep -Seconds 3
        if (Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue) { & sc.exe stop 'Mesh Agent' | Out-Null; & sc.exe delete 'Mesh Agent' | Out-Null }
        if (Test-Path -LiteralPath $agentDir) { Remove-Item -LiteralPath $agentDir -Recurse -Force -ErrorAction SilentlyContinue }
        foreach ($k in 'HKLM:\SOFTWARE\Open Source\Mesh Agent', 'HKLM:\SOFTWARE\Open Source\MeshAgent2') { if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force } }
        $run.Changes.Add([pscustomobject]@{ what = 'MeshCentral agent'; result = 'removed' })
    }
}

# SSH server, only if deskside put it there.
$statePath = Join-Path (Get-DesksideDataRoot) 'ssh-state.json'
if (Test-Path -LiteralPath $statePath) {
    if ($PSCmdlet.ShouldProcess('SSH server', 'Remove what deskside set up')) {
        & (Join-Path $PSScriptRoot 'Disable-LoopbackSsh.ps1') -OutputDirectory (Join-Path $run.Folder 'ssh') | Out-Null
        $run.Changes.Add([pscustomobject]@{ what = 'SSH server'; result = 'removed' })
    }
}

$shortcut = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Remove remote help.cmd'
if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force; $run.Changes.Add([pscustomobject]@{ what = 'Desktop shortcut'; result = 'removed' }) }
Revoke-Consent -Scope remote

# Verify nothing is left.
$left = @()
if (Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue) { $left += 'Mesh Agent service' }
if (Test-Path -LiteralPath $agentDir) { $left += 'Mesh Agent folder' }
if (Test-Path -LiteralPath $statePath) { $left += 'SSH state' }
$run.Data['leftBehind'] = $left
if ($left.Count -gt 0) { Add-Finding -Run $run -Id 'remove.left' -Rank 'FixNow' -Text "$($left.Count) part(s) of remote help could not be removed; restart the PC and run this again." }
else { Add-Finding -Run $run -Id 'remove.done' -Rank 'Info' -Text 'Remote help is gone from this PC.' }
Complete-DesksideRun -Run $run -SummaryTitle 'Remote help removed' | Out-Null