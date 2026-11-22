#Requires -Version 7.0
<#
.SYNOPSIS
    Reads a USB kit's results back into the private records store and wipes the kit's values from the drive.

.DESCRIPTION
    Copies readback.txt and log.txt to <records>\devices\<alias>\enroll\<UTC stamp>\ (the alias needn't be in
    devices.json yet), overwrites and deletes deskside\values.json if the run left it, then looks through every file of
    the kit for the group id and reports how many still hold it. The group id comes from values.json when it is still
    there, otherwise from 1Password by the reference kit.json names.

    On screen: the readback's plain findings only (stopped and why, the checks, steps, services, removals), never the
    node id, account or dates; those are in the records store for devices.json.

.PARAMETER RecordsRoot
    Where to save the results instead of the records store (the Sandbox proof uses a temporary folder).
#>
[CmdletBinding()]
param([string]$Drive, [string]$Path, [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{2,32}$')][string]$Alias, [string]$RecordsRoot)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Deskside.Console.psm1') -Force

$root = Get-UsbKitRoot -Drive $Drive -Path $Path
$kitDir = Join-Path $root 'deskside'
if (-not (Test-Path -LiteralPath (Join-Path $kitDir 'kit.json'))) { throw 'This drive holds no deskside USB kit (deskside\kit.json).' }
if (-not $RecordsRoot) { $RecordsRoot = Get-RecordsRoot }

$rbPath = Join-Path $root 'readback.txt'
$lines = @()
if (Test-Path -LiteralPath $rbPath) { $lines = @(Get-Content -LiteralPath $rbPath) }
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$dest = Join-Path $RecordsRoot "devices\$Alias\enroll\$stamp"
$copied = 0
foreach ($f in 'readback.txt', 'log.txt') {
    $p = Join-Path $root $f
    if (Test-Path -LiteralPath $p) {
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item -LiteralPath $p -Destination $dest
        $copied++
    }
}

# The group id: from values.json if the run left it, else 1Password by kit.json's reference.
$kit = Get-Content -LiteralPath (Join-Path $kitDir 'kit.json') -Raw | ConvertFrom-Json
$valuesPath = Join-Path $kitDir 'values.json'
$group = $null
if (Test-Path -LiteralPath $valuesPath) { $group = [string](Get-Content -LiteralPath $valuesPath -Raw | ConvertFrom-Json).groupId }
$wiped = Remove-UsbKitValue -Root $root
if (-not $group) {
    $settings = Get-MeshSetting
    $group = Read-OpValue -Ref ([string]$settings.($kit.groupRef)) -What 'the device group id' -Pattern '^[A-Za-z0-9$@]{64}$'
}
$trace = Find-UsbKitTrace -Root $root -Text $group
$group = $null
[ordered]@{ read = (Get-Date).ToUniversalTime().ToString('s') + 'Z'; alias = $Alias; valuesWiped = $wiped; filesChecked = $trace.Files; filesWithId = $trace.Hits } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $kitDir 'read-back.json') -Encoding ascii

$show = @("results saved: $copied file(s) to the records store (devices\$Alias\enroll\$stamp)")
if ($lines.Count -eq 0) { $show += 'no readback on the drive: the kit has not run' }
else { $show += ConvertFrom-UsbKitReadback -Line $lines }
$show += "values.json: " + $(if ($wiped) { 'wiped by this read-back' } else { 'already removed by the kit' })
$show += "group id still on the drive: $($trace.Hits) of $($trace.Files) file(s)"
$show | ForEach-Object { Write-Information $_ -InformationAction Continue }
if ($trace.Hits -gt 0) { throw "The group id is still in $($trace.Hits) file(s) on the drive. Delete the kit folder from the drive." }
