#Requires -Version 7.0
<#
.SYNOPSIS
    Removes a PC from the MeshCentral server after its agent was uninstalled, and marks it removed in devices.json.

.DESCRIPTION
    Uninstalling an agent doesn't delete the device on the server. This uses MeshCentral's own command-line client,
    meshctrl.js (shipped with MeshCentral), with the automation login token, to run `removedevice`. Set
    meshcentral.json's "meshctrl" to the path of meshctrl.js (and its node_modules) on this machine.
#>
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$Alias)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Deskside.Console.psm1') -Force
$device = Get-DesksideDevice -Alias $Alias
$s = Get-MeshSetting
if (-not ($s.PSObject.Properties['meshctrl'] -and $s.meshctrl -and (Test-Path -LiteralPath $s.meshctrl))) {
    throw "meshctrl.js isn't set up (meshcentral.json 'meshctrl'). Remove the device in the MeshCentral web page instead: open the device, then Actions > Delete Device."
}
$login = Get-MeshLogin -Settings $s
$wss = ($s.serverUrl.TrimEnd('/') -replace '^https://', 'wss://')
if ($PSCmdlet.ShouldProcess($Alias, 'Remove from the MeshCentral server')) {
    & node $s.meshctrl removedevice --id $device.meshNodeId --url $wss --loginuser $login.User --loginpass $login.Password
    if ($LASTEXITCODE -ne 0) { throw "meshctrl removedevice failed ($LASTEXITCODE)." }
    $path = Join-Path (Get-RecordsRoot) 'devices.json'
    $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    foreach ($d in $doc.devices) { if ($d.alias -eq $Alias) { $d | Add-Member -NotePropertyName removedUtc -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force } }
    ($doc | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path
    Write-Information "Removed '$Alias' from the server and marked it removed in devices.json." -InformationAction Continue
}
