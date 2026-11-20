#Requires -Version 5.1
<#
.SYNOPSIS
    Removes remote help from this PC and leaves nothing behind: the help button (MeshCentral Assistant, its
    shortcuts, refresh task and each profile's setting), the MeshCentral agent, the SSH server deskside turned on, the
    helper's key, the desktop shortcut and the 'remote' consent.

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

# The help button (MeshCentral Assistant), before the agent it attaches to.
$hb = Get-HelpButtonPath
$hbLinks = @($hb.Startup) + @(Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('CommonDesktopDirectory')), (Split-Path $hb.StartMenu -Parent) -Filter 'Ask * for help.lnk' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$hbTask = Get-ScheduledTask -TaskPath $hb.TaskPath -ErrorAction SilentlyContinue
if ((Test-Path -LiteralPath $hb.Folder) -or $hbTask -or @($hbLinks | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0) {
    if ($PSCmdlet.ShouldProcess('Help button', 'Remove')) {
        Get-Process -Name $hb.ProcessName -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill(); $_.WaitForExit(5000) | Out-Null }
        foreach ($t in @($hbTask)) { if ($t) { Unregister-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -Confirm:$false } }
        foreach ($l in $hbLinks) { if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force } }
        if (Test-Path -LiteralPath $hb.Folder) { Remove-Item -LiteralPath $hb.Folder -Recurse -Force }
        $parent = Split-Path $hb.Folder -Parent
        if ((Test-Path -LiteralPath $parent) -and -not (Get-ChildItem -LiteralPath $parent -Force)) { Remove-Item -LiteralPath $parent -Force }
        if (Test-Path -LiteralPath $hb.StateFile) { Remove-Item -LiteralPath $hb.StateFile -Force }
        $run.Changes.Add([pscustomobject]@{ what = 'Help button'; result = 'removed' })
    }
}
# Assistant's own setting (its selected agent) in each person's registry: loaded profiles, then the others.
$assistKey = 'SOFTWARE\Open Source\MeshCentral Assistant'
$lockedProfiles = 0
if ($PSCmdlet.ShouldProcess('MeshCentral Assistant settings', 'Remove from every profile')) {
    $loaded = @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' | ForEach-Object { $_.PSChildName })
    foreach ($sid in $loaded) {
        $k = "Registry::HKEY_USERS\$sid\$assistKey"
        if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force }
    }
    $profiles = Get-CimInstance Win32_UserProfile -Filter 'Special = False' -ErrorAction SilentlyContinue
    foreach ($pr in @($profiles)) {
        if ($loaded -contains $pr.SID) { continue }
        $hive = Join-Path $pr.LocalPath 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $hive)) { continue }
        & reg.exe load 'HKU\deskside-profile' $hive 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $lockedProfiles++; continue }
        try {
            $k = "Registry::HKEY_USERS\deskside-profile\$assistKey"
            if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force }
        } finally {
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            & reg.exe unload 'HKU\deskside-profile' 2>$null | Out-Null
        }
    }
}

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
if (Test-Path -LiteralPath $hb.Folder) { $left += 'help button folder' }
if (Get-Process -Name $hb.ProcessName -ErrorAction SilentlyContinue) { $left += 'help button running' }
if (Get-ScheduledTask -TaskPath $hb.TaskPath -ErrorAction SilentlyContinue) { $left += 'help button task' }
if (@($hbLinks | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0) { $left += 'help button shortcut' }
foreach ($sid in @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' | ForEach-Object { $_.PSChildName })) { if (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid\$assistKey") { $left += 'help button setting'; break } }
$run.Data['profilesLocked'] = $lockedProfiles
$run.Data['leftBehind'] = $left
if ($left.Count -gt 0) { Add-Finding -Run $run -Id 'remove.left' -Rank 'FixNow' -Text "$($left.Count) part(s) of remote help could not be removed; restart the PC and run this again." }
else { Add-Finding -Run $run -Id 'remove.done' -Rank 'Info' -Text 'Remote help is gone from this PC.' }
Complete-DesksideRun -Run $run -SummaryTitle 'Remote help removed' | Out-Null