#Requires -Version 5.1
<#
.SYNOPSIS
    Undoes a deskside change run from the before-state it saved (undo.json in the run's folder).

.DESCRIPTION
    Works through the entries newest first: registry values go back to what they were (or are removed if they
    weren't set), handler settings go back to their saved state, apps a run installed are uninstalled with winget,
    PowerShell modules are uninstalled, copied files are restored from their backup or removed.
    Safe to run twice: an entry already undone is skipped.

.PARAMETER Run
    The run folder (it contains undo.json), or a run id under the PC's deskside data folder.
#>
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$Run)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force

$folder = $Run
if (-not (Test-Path -LiteralPath $folder)) { $folder = Join-Path (Join-Path (Get-DesksideDataRoot) 'runs') $Run }
$undoPath = Join-Path $folder 'undo.json'
if (-not (Test-Path -LiteralPath $undoPath)) { throw "No undo.json in $folder; that run changed nothing that can be undone." }
$entries = Read-JsonArray -Path $undoPath
[array]::Reverse($entries)
$donePath = Join-Path $folder 'undone.json'
$done = Read-JsonArray -Path $donePath

$out = New-DesksideRun -Kind 'undo'
$out.Data['undoing'] = (Split-Path $folder -Leaf)
$winget = $null

foreach ($e in $entries) {
    $key = ConvertTo-Json -InputObject $e -Compress -Depth 4
    if ($done -contains $key) { continue }
    if (-not $PSCmdlet.ShouldProcess($e.item, "Undo ($($e.type))")) { continue }
    try {
        switch ($e.type) {
            'registry' { Restore-RegistryState -State $e }
            'handler' {
                switch ($e.handler) {
                    'SystemProtection' { if (-not $e.wasOn) { Disable-ComputerRestore -Drive $e.drive } }
                    'DefenderPua' { Set-MpPreference -PUAProtection $e.value }
                }
            }
            'winget' {
                if (-not $winget) { $winget = & (Join-Path $PSScriptRoot '..\install\Repair-Winget.ps1') }
                & $winget uninstall --id $e.id -e --source winget --silent --accept-source-agreements --disable-interactivity
                if ($LASTEXITCODE -ne 0) { throw "winget uninstall exit $LASTEXITCODE" }
            }
            'module' { Uninstall-Module -Name $e.name -AllVersions -Force }
            'file' {
                if ($e.backup -and (Test-Path -LiteralPath $e.backup)) { Copy-Item -LiteralPath $e.backup -Destination $e.path -Force }
                elseif (Test-Path -LiteralPath $e.path) { Remove-Item -LiteralPath $e.path -Force }
            }
            'note' { Add-Finding -Run $out -Id 'undo.note' -Rank 'Info' -Text $e.text }
            default { throw "Unknown undo type $($e.type)" }
        }
        $done += $key
        $out.Changes.Add([pscustomobject]@{ what = $e.item; result = 'undone' })
    } catch {
        $out.Changes.Add([pscustomobject]@{ what = $e.item; result = 'undo failed' })
        $out.Errors.Add([pscustomobject]@{ section = $e.item; message = $_.Exception.Message })
    }
}
(ConvertTo-Json -InputObject @($done)) | Set-Content -LiteralPath $donePath -Encoding UTF8
Complete-DesksideRun -Run $out -SummaryTitle 'Undo' | Out-Null