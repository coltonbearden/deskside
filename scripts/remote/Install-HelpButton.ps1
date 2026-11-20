#Requires -Version 5.1
<#
.SYNOPSIS
    Adds the one-click help button: MeshCentral Assistant beside the agent, started at every sign-in, and an "Ask
    <helper> for help" entry on the desktop and in the Start menu that sends the helper a help request.

.DESCRIPTION
    MeshCentral Assistant (Apache License 2.0, Intel; see README, Third-party software) is downloaded from the
    helper's own MeshCentral server in its monitor-only form (/meshagents?id=10006&meshid=<group>&ac=4): it carries
    no server settings and attaches to the agent already installed, so the agent's own relay code stays the only one.
    The server emails the helper when a request arrives (its device group's "Email for help requests").

    It is started with -noupdate (its own update needs the person's OK and can't write to Program Files). A weekly
    SYSTEM task, \deskside\help-refresh, downloads it again from the server and swaps the file when it changed
    (scripts\remote\Update-HelpButton.ps1); the server is its source. Remove-RemoteHelp.ps1 takes all of it away.

    Needs the owner's 'remote' consent, administrator rights and the installed agent; stops on a work or school PC.

.PARAMETER ServerUrl
    https://<the server's agent address>. Read from the agent's MeshAgent.msh when left out.

.PARAMETER GroupId
    The device group's id. Read from the agent's MeshAgent.msh when left out.

.PARAMETER HelperName
    The name the person knows the helper by; it names the shortcut.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^https://')][string]$ServerUrl,
    [string]$GroupId,
    [ValidatePattern('^[A-Za-z0-9 .-]{1,40}$')][string]$HelperName = 'your helper',
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
Assert-NotManaged
Assert-Consent -Scope remote
if (-not (Test-IsAdministrator)) { throw 'Adding the help button needs administrator rights.' }
if (-not (Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue)) { throw 'The MeshCentral agent is not installed; run Install-MeshAgent.ps1 first.' }

$agent = Get-MeshAgentSetting
if (-not $ServerUrl) { if (-not $agent) { throw 'The agent''s MeshAgent.msh gave no server; pass -ServerUrl and -GroupId.' }; $ServerUrl = $agent.ServerUrl }
if (-not $GroupId) { if (-not $agent) { throw 'The agent''s MeshAgent.msh gave no group; pass -GroupId.' }; $GroupId = $agent.GroupId }

$run = New-DesksideRun -Kind 'help-install' -OutputDirectory $OutputDirectory
$p = Get-HelpButtonPath -HelperName $HelperName
$app = Get-DesksideRoot
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# 1. The program, from the server.
$file = Save-HelpButtonFile -ServerUrl $ServerUrl -GroupId $GroupId -WhatIf:$WhatIfPreference
$run.Data['assistant'] = [ordered]@{ result = $file.result; sha256 = $file.sha256; signature = $file.signature }
$run.Changes.Add([pscustomobject]@{ what = 'MeshCentral Assistant'; result = $file.result })
Save-BeforeState -Run $run -ItemId 'help-button' -Undo @{ type = 'note'; text = 'Remove the help button with scripts\remote\Remove-RemoteHelp.ps1.' }

# 2. Shortcuts: at every sign-in, and the button itself.
$shell = New-Object -ComObject WScript.Shell
$ask = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$(Join-Path $app 'scripts\remote\Ask-ForHelp.ps1')"" -HelperName ""$HelperName"""
$links = @(
    @{ Path = $p.Startup; Target = $p.Exe; Arguments = '-noupdate'; Description = 'Lets you ask for help (deskside)' }
    @{ Path = $p.Desktop; Target = $ps; Arguments = $ask; Description = "Send $HelperName a request for help" }
    @{ Path = $p.StartMenu; Target = $ps; Arguments = $ask; Description = "Send $HelperName a request for help" }
)
foreach ($l in $links) {
    if (-not $PSCmdlet.ShouldProcess($l.Path, 'Create shortcut')) { continue }
    New-Item -ItemType Directory -Force -Path (Split-Path $l.Path -Parent) | Out-Null
    $s = $shell.CreateShortcut($l.Path)
    $s.TargetPath = $l.Target; $s.Arguments = $l.Arguments; $s.Description = $l.Description; $s.WindowStyle = 7
    $s.WorkingDirectory = $p.Folder
    $s.IconLocation = "$($p.Exe),0"
    $s.Save()
}
$run.Changes.Add([pscustomobject]@{ what = 'Help shortcuts'; result = 'desktop, Start menu and sign-in' })

# 3. The weekly refresh from the server, as SYSTEM.
if ($PSCmdlet.ShouldProcess("$($p.TaskPath)$($p.TaskName)", 'Register weekly refresh')) {
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File ""$(Join-Path $app 'scripts\remote\Update-HelpButton.ps1')"""
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Wednesday -At '11:00'
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskPath $p.TaskPath -TaskName $p.TaskName -Action $action -Trigger $trigger -Settings $set -Principal $principal -Force | Out-Null
    $state = [ordered]@{ schema = 'deskside.help-refresh/v1'; lastUtc = (Get-Date).ToUniversalTime().ToString('o'); result = $file.result; sha256 = $file.sha256 }
    ($state | ConvertTo-Json) | Set-Content -LiteralPath $p.StateFile -Encoding UTF8
    $run.Changes.Add([pscustomobject]@{ what = 'Help button refresh'; result = 'weekly' })
}

# 4. Start it now in each signed-in session, as that person (a one-off task for the interactive users).
if (@(Get-SignedInSession).Count -gt 0 -and $PSCmdlet.ShouldProcess('signed-in sessions', 'Start MeshCentral Assistant')) {
    $once = 'help-start'
    $a = New-ScheduledTaskAction -Execute $p.Exe -Argument '-noupdate' -WorkingDirectory $p.Folder
    $pr = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    Register-ScheduledTask -TaskPath $p.TaskPath -TaskName $once -Action $a -Principal $pr -Force | Out-Null
    Start-ScheduledTask -TaskPath $p.TaskPath -TaskName $once
    Start-Sleep -Seconds 5
    Unregister-ScheduledTask -TaskPath $p.TaskPath -TaskName $once -Confirm:$false
    $running = @(Get-Process -Name $p.ProcessName -ErrorAction SilentlyContinue).Count
    $run.Data['assistantRunning'] = $running
    $run.Changes.Add([pscustomobject]@{ what = 'MeshCentral Assistant'; result = "started ($running running)" })
}
Add-Finding -Run $run -Id 'help.installed' -Rank 'Info' -Text "The help button is on the desktop and in the Start menu."
Complete-DesksideRun -Run $run -SummaryTitle 'Remote help: help button' | Out-Null
