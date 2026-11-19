#Requires -Version 5.1
<#
.SYNOPSIS
    Applies settings from catalog\settings.json: only items marked yes on the PC's change list, or every item a
    profile names when -Profile is used with -All.

.DESCRIPTION
    For each item: checks whether the PC already complies (skips it if so), saves the before-state to the run's
    undo.json, then applies it. Makes a restore point first when System Protection is on. Safe to run twice.
    Undo with scripts\settings\Undo-DesksideRun.ps1 -Run <run folder>.

    Needs the owner's 'onboard' consent and stops on a work or school PC.

.PARAMETER ChangeList
    A changelist.json from New-ChangeList.ps1. Only setting items with "decision": "yes" are applied.

.PARAMETER ItemId
    Apply these catalog items directly (used by tests and the Sandbox proof).
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName = 'List', Mandatory)][string]$ChangeList,
    [Parameter(ParameterSetName = 'Items', Mandatory)][string[]]$ItemId,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
Assert-NotManaged
Assert-Consent -Scope onboard

$catalog = (Read-DesksideCatalog -Name 'settings.json').items
if ($PSCmdlet.ParameterSetName -eq 'List') {
    $list = Get-Content -LiteralPath $ChangeList -Raw -Encoding UTF8 | ConvertFrom-Json
    $ItemId = @($list.items | Where-Object { $_.kind -eq 'setting' -and $_.decision -eq 'yes' } | ForEach-Object { $_.id })
}
# powershell.exe -File passes "a,b" as one string; accept both forms.
$ItemId = @($ItemId | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$items = @($catalog | Where-Object { $ItemId -contains $_.id })
$unknown = @($ItemId | Where-Object { -not ($catalog.id -contains $_) })
if ($unknown.Count -gt 0) { throw "Unknown setting id(s): $($unknown -join ', ')" }

$run = New-DesksideRun -Kind 'settings' -OutputDirectory $OutputDirectory
if ($items.Count -eq 0) { Complete-DesksideRun -Run $run -SummaryTitle 'Settings' | Out-Null; return }

$nonCompliant = @($items | Where-Object { -not (Test-DesksideSettingCompliant $_) })
foreach ($i in @($items | Where-Object { $nonCompliant -notcontains $_ })) { $run.Changes.Add([pscustomobject]@{ what = $i.title; result = 'already set' }) }
if ($nonCompliant.Count -gt 0) { New-DesksideRestorePoint -Run $run -Description 'deskside settings' | Out-Null }

foreach ($item in $nonCompliant) {
    if (-not $PSCmdlet.ShouldProcess($item.title, 'Apply setting')) { $run.Changes.Add([pscustomobject]@{ what = $item.title; result = 'would apply' }); continue }
    try {
        switch ($item.type) {
            'registry' {
                foreach ($v in $item.values) {
                    if (Test-RegistryValueCompliant $v) { continue }
                    Save-BeforeState -Run $run -ItemId $item.id -Undo (Get-RegistryState -Path $v.path -Name $v.name)
                    Set-RegistryValueSafe -Path $v.path -Name $v.name -Value $v.value -Kind $v.kind
                }
            }
            'handler' {
                switch ($item.handler) {
                    'SystemProtection' {
                        Save-BeforeState -Run $run -ItemId $item.id -Undo @{ type = 'handler'; handler = 'SystemProtection'; wasOn = $false; drive = "$env:SystemDrive\" }
                        Enable-ComputerRestore -Drive "$env:SystemDrive\"
                        New-DesksideRestorePoint -Run $run -Description 'deskside: restore points turned on' | Out-Null
                    }
                    'DefenderPua' {
                        $before = [int](Get-MpPreference).PUAProtection
                        Save-BeforeState -Run $run -ItemId $item.id -Undo @{ type = 'handler'; handler = 'DefenderPua'; value = $before }
                        Set-MpPreference -PUAProtection Enabled
                    }
                }
            }
        }
        $run.Changes.Add([pscustomobject]@{ what = $item.title; result = 'applied' })
    } catch {
        $run.Changes.Add([pscustomobject]@{ what = $item.title; result = 'failed' })
        $run.Errors.Add([pscustomobject]@{ section = $item.id; message = $_.Exception.Message })
    }
}

if (@($nonCompliant | Where-Object { $_.id -eq 'show-extensions' -or $_.id -eq 'ads-tips-off' }).Count -gt 0) {
    Add-Finding -Run $run -Id 'settings.signout' -Rank 'Info' -Text 'Some changes show up after the person signs out and back in.'
}
Complete-DesksideRun -Run $run -SummaryTitle 'Settings' | Out-Null