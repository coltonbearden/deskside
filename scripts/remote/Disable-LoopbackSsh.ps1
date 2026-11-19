#Requires -Version 5.1
<#
.SYNOPSIS
    Undoes Enable-LoopbackSsh.ps1: removes the helper's key and the SSH server deskside installed, puts the old
    sshd_config, firewall rules and default shell back.
#>
[CmdletBinding(SupportsShouldProcess)]
param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
if (-not (Test-IsAdministrator)) { throw 'Needs administrator rights.' }
$statePath = Join-Path (Get-DesksideDataRoot) 'ssh-state.json'
if (-not (Test-Path -LiteralPath $statePath)) { Write-Information 'deskside did not set up SSH on this PC.' -InformationAction Continue; return }
$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$run = New-DesksideRun -Kind 'ssh-disable' -OutputDirectory $OutputDirectory
if (-not $PSCmdlet.ShouldProcess('SSH server', 'Remove deskside setup')) { return }

Stop-Service -Name sshd -ErrorAction SilentlyContinue
$sshDir = Join-Path $env:ProgramData 'ssh'
$keys = Join-Path $sshDir 'administrators_authorized_keys'
if (Test-Path -LiteralPath $keys) { Remove-Item -LiteralPath $keys -Force }
if ($state.configBackup -and (Test-Path -LiteralPath $state.configBackup)) { Copy-Item -LiteralPath $state.configBackup -Destination (Join-Path $sshDir 'sshd_config') -Force; Remove-Item -LiteralPath $state.configBackup -Force }
foreach ($r in @($state.firewallRulesDisabled)) { if ($r) { Enable-NetFirewallRule -Name $r -ErrorAction SilentlyContinue } }
if ($state.defaultShellBefore) { Restore-RegistryState -State $state.defaultShellBefore }

switch ($state.method) {
    'capability' {
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
        if ($cap.State -eq 'Installed') { Remove-WindowsCapability -Online -Name $cap.Name | Out-Null }
        foreach ($r in @($state.firewallRulesDisabled)) { if ($r) { Remove-NetFirewallRule -Name $r -ErrorAction SilentlyContinue } }
    }
    'winget' {
        $winget = & (Join-Path $PSScriptRoot '..\install\Repair-Winget.ps1')
        & $winget uninstall --id Microsoft.OpenSSH.Preview -e --source winget --silent --accept-source-agreements --disable-interactivity
        foreach ($r in @($state.firewallRulesDisabled)) { if ($r) { Remove-NetFirewallRule -Name $r -ErrorAction SilentlyContinue } }
    }
    default { Set-Service -Name sshd -StartupType Manual -ErrorAction SilentlyContinue }
}
Remove-Item -LiteralPath $statePath -Force
$run.Changes.Add([pscustomobject]@{ what = 'SSH server'; result = "removed ($($state.method))" })
Complete-DesksideRun -Run $run -SummaryTitle 'SSH removed' | Out-Null