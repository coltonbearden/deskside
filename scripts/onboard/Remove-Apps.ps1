#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the apps marked "yes" on a change list (junk and trialware).

.DESCRIPTION
    Makes a restore point first when System Protection is on, then uninstalls each marked app with winget by its exact
    name. An app winget can't remove is reported, not forced. Removed apps can't be put back by deskside's undo
    (trialware isn't reinstalled); the restore point is the way back.

    Needs the owner's 'onboard' consent and stops on a work or school PC.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ChangeList,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
Assert-NotManaged
Assert-Consent -Scope onboard

$list = Get-Content -LiteralPath $ChangeList -Raw -Encoding UTF8 | ConvertFrom-Json
$marked = @($list.items | Where-Object { $_.kind -eq 'removal' -and $_.decision -eq 'yes' })
$run = New-DesksideRun -Kind 'remove-apps' -OutputDirectory $OutputDirectory
if ($marked.Count -eq 0) { Complete-DesksideRun -Run $run -SummaryTitle 'App removal' | Out-Null; return }

$winget = & (Join-Path $PSScriptRoot '..\install\Repair-Winget.ps1')
New-DesksideRestorePoint -Run $run -Description 'deskside app removal' | Out-Null
foreach ($m in $marked) {
    if (-not $PSCmdlet.ShouldProcess($m.id, 'Uninstall')) { $run.Changes.Add([pscustomobject]@{ what = $m.title; result = 'would remove' }); continue }
    & $winget uninstall --name $m.id -e --silent --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -eq 0) { $run.Changes.Add([pscustomobject]@{ what = $m.title; result = 'removed' }) }
    else {
        $run.Changes.Add([pscustomobject]@{ what = $m.title; result = 'not removed' })
        $run.Errors.Add([pscustomobject]@{ section = $m.id; message = "winget uninstall exit $LASTEXITCODE; remove it from Settings > Apps" })
    }
}
Complete-DesksideRun -Run $run -SummaryTitle 'App removal' | Out-Null