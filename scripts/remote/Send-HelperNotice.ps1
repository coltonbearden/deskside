#Requires -Version 5.1
<#
.SYNOPSIS
    Tells the person signed in at this PC that the helper has connected over SSH (Start) or finished (End).

.DESCRIPTION
    The console (scripts\console\Invoke-DesksideRemote.ps1) runs this over SSH before and after each run or shell. It
    shows a message box in every signed-in session (WTSSendMessage, every Windows edition), records the phase and the
    counts in C:\ProgramData\deskside\data\notice.json (no names), and prints the counts as JSON. With nobody signed in
    nothing appears and the record says so. Needs the owner's 'remote' consent.

.PARAMETER Phase
    Start or End.

.PARAMETER Activity
    What the helper is doing: diagnose, onboard, settings, undo, remote, shell or task.

.PARAMETER HelperName
    The name the person knows the helper by (from the helper's private records; never stored in this repo).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Start', 'End')][string]$Phase,
    [ValidateSet('diagnose', 'onboard', 'settings', 'undo', 'remote', 'shell', 'task')][string]$Activity = 'task',
    [ValidatePattern('^[A-Za-z0-9 .-]{1,40}$')][string]$HelperName = 'Your helper'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
Assert-Consent -Scope remote
$r = Send-HelperNotice -Phase $Phase -Activity $Activity -HelperName $HelperName -SentBy 'console'
[ordered]@{ phase = $r.phase; signedIn = $r.signedIn; shown = $r.shown } | ConvertTo-Json -Compress
