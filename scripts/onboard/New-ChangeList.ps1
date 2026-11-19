#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the one list of removals and settings changes for this PC, to be marked yes or no.

.DESCRIPTION
    Reads a diagnose record (record.json) and the profile's settings, and lists only:
      - junk and trialware found on the PC: "recommended" items pre-marked yes, "questionable" items left blank;
      - settings from the profile the PC doesn't already have, pre-marked yes.
    Writes changelist.json and changelist.md next to the record. Nothing is changed until the list is applied with
    Set-Baseline.ps1 -ChangeList and Remove-Apps.ps1 -ChangeList, which act only on items marked "yes".

.PARAMETER Record
    A diagnose record.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Record,
    [ValidateSet('everyone', 'power', 'developer')][string]$ProfileName = 'everyone'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force

$rec = Get-Content -LiteralPath $Record -Raw -Encoding UTF8 | ConvertFrom-Json
if ($rec.schema -ne 'deskside.record/v1' -or $rec.kind -ne 'diagnose') { throw 'That file is not a deskside diagnose record.' }
if ($rec.data.managed.isManaged) { throw 'This PC belongs to a work or school; deskside changes nothing here.' }

$items = New-Object System.Collections.Generic.List[object]
if ($rec.data.apps -and $rec.data.apps.junk) {
    foreach ($j in $rec.data.apps.junk) {
        $decision = ''
        if ($j.verdict -eq 'recommended') { $decision = 'yes' }
        $items.Add([pscustomobject][ordered]@{ kind = 'removal'; id = $j.app; title = "Remove $($j.app)"; why = $j.why; verdict = $j.verdict; decision = $decision })
    }
}

$settings = (Read-DesksideCatalog -Name 'settings.json').items
$prof = Read-DesksideCatalog -Name ("profiles\$ProfileName.json")
$wanted = @($prof.settings)
foreach ($s in @($settings | Where-Object { $wanted -contains $_.id -and -not (Test-DesksideSettingCompliant $_) })) {
    $items.Add([pscustomobject][ordered]@{ kind = 'setting'; id = $s.id; title = $s.title; why = $s.why; verdict = 'recommended'; decision = 'yes' })
}

$list = [ordered]@{
    schema    = 'deskside.changelist/v1'
    fromRun   = $rec.runId
    profile   = $ProfileName
    createdUtc = (Get-Date).ToUniversalTime().ToString('o')
    howTo     = 'Set each decision to "yes" or "no". Only "yes" items are applied. Settings the PC already has are skipped when applied.'
    items     = $items.ToArray()
}
$folder = Split-Path -Parent $Record
$jsonPath = Join-Path $folder 'changelist.json'
(ConvertTo-Json -InputObject $list -Depth 5) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine('# Changes to decide')
[void]$md.AppendLine('')
[void]$md.AppendLine('Mark each line yes or no. Only yes items are applied.')
[void]$md.AppendLine('')
[void]$md.AppendLine('| Decision | Change | Why | Verdict |')
[void]$md.AppendLine('|---|---|---|---|')
foreach ($i in $items) { [void]$md.AppendLine("| $($i.decision) | $($i.title) | $($i.why) | $($i.verdict) |") }
$md.ToString() | Set-Content -LiteralPath (Join-Path $folder 'changelist.md') -Encoding UTF8

Write-Information ("Change list: {0} removal(s), {1} setting(s)." -f @($items | Where-Object { $_.kind -eq 'removal' }).Count, @($items | Where-Object { $_.kind -eq 'setting' }).Count) -InformationAction Continue
return $jsonPath
