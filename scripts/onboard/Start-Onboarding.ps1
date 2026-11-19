#Requires -Version 5.1
<#
.SYNOPSIS
    Walks through setting up a PC: a brand-new one (-Flow NewPC) or one with a problem (-Flow Problem).

.DESCRIPTION
    NewPC:   diagnose -> owner agrees to 'onboard' -> one change list (removals + settings) marked yes or no ->
             apply the marked settings (restore points first) -> install the profile's missing apps -> the marked
             removals -> diagnose again.
    Problem: diagnose -> show what needs fixing now -> owner agrees -> the same change list, but no new apps
             unless -ProfileName is given -> apply -> diagnose again.

    In a terminal the list is asked item by item. With -ChangeList, a list already marked (for example by the helper
    over SSH, from changelist.json) is used as is.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('NewPC', 'Problem')][string]$Flow = 'NewPC',
    [ValidateSet('everyone', 'power', 'developer')][string]$ProfileName,
    [string]$ChangeList,
    [switch]$Confirmed
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
Assert-NotManaged
$scripts = Split-Path -Parent $PSScriptRoot
if ($Flow -eq 'NewPC' -and -not $ProfileName) { $ProfileName = 'everyone' }

Write-Information "`nStep 1: health check" -InformationAction Continue
$diag = & (Join-Path $scripts 'diagnose\Invoke-Diagnose.ps1') -Quick -PassThru
$record = $diag.Record
$rec = Get-Content -LiteralPath $record -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Flow -eq 'Problem') {
    $now = @($rec.findings | Where-Object { $_.rank -eq 'FixNow' })
    Write-Information "`nFix now:" -InformationAction Continue
    foreach ($f in $now) { Write-Information " - $($f.text)" -InformationAction Continue }
}

Write-Information "`nStep 2: the owner's agreement" -InformationAction Continue
if (-not (Get-Consent) -or -not (Get-Consent).scopes.PSObject.Properties['onboard']) { Grant-Consent -Scope onboard -Confirmed:$Confirmed | Out-Null }

Write-Information "`nStep 3: the change list" -InformationAction Continue
$listProfile = $ProfileName
if (-not $listProfile) { $listProfile = 'everyone' }
if (-not $ChangeList) {
    $ChangeList = & (Join-Path $PSScriptRoot 'New-ChangeList.ps1') -Record $record -ProfileName $listProfile
    $list = Get-Content -LiteralPath $ChangeList -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $Confirmed) {
        foreach ($i in $list.items) {
            $default = 'no'; if ($i.decision -eq 'yes') { $default = 'yes' }
            $a = Read-Host ("{0}`n   ({1}) yes or no [{2}]" -f $i.title, $i.why, $default)
            if (-not $a) { $a = $default }
            if ($a -match '^(y|yes)$') { $i.decision = 'yes' } else { $i.decision = 'no' }
        }
    }
    (ConvertTo-Json -InputObject $list -Depth 5) | Set-Content -LiteralPath $ChangeList -Encoding UTF8
}

# Settings first: turning restore points on (when marked yes) means the installs and removals after it get a
# restore point of their own.
Write-Information "`nStep 4: settings" -InformationAction Continue
& (Join-Path $scripts 'settings\Set-Baseline.ps1') -ChangeList $ChangeList -WhatIf:$WhatIfPreference | Out-Null
if ($ProfileName) {
    Write-Information "`nStep 5: apps ($ProfileName profile)" -InformationAction Continue
    & (Join-Path $scripts 'install\Install-Profile.ps1') -ProfileName $ProfileName -WhatIf:$WhatIfPreference | Out-Null
}
Write-Information "`nStep 6: removals" -InformationAction Continue
& (Join-Path $PSScriptRoot 'Remove-Apps.ps1') -ChangeList $ChangeList -WhatIf:$WhatIfPreference | Out-Null

Write-Information "`nStep 7: health check again" -InformationAction Continue
& (Join-Path $scripts 'diagnose\Invoke-Diagnose.ps1') -Quick
