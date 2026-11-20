#Requires -Version 7.0
<#
.SYNOPSIS
    Removes a PC from the MeshCentral server after its agent was uninstalled, and marks it removed in devices.json.

.DESCRIPTION
    Uninstalling an agent doesn't delete the device on the server. A relay-only login (the console's) can't delete
    devices, so there are two ways:

    - meshctrl: set meshcentral.json's "meshctrl" to MeshCentral's meshctrl.js on this machine and "removeLogin"
      ({ userRef, passwordRef }) to 1Password references for a login allowed to remove devices from the group. The
      script then runs `meshctrl removedevice` and marks the device removed.
    - The web page (the default): the script prints the steps. Delete the device there, then run this again with
      -RemovedInWebUi to mark it removed in devices.json.

    A device in a group that removes devices when they disconnect (the Proofs group) needs neither.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Alias,
    [switch]$RemovedInWebUi
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Deskside.Console.psm1') -Force
$device = Get-DesksideDevice -Alias $Alias
$s = Get-MeshSetting

function Set-DeviceRemoved {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only inside the script''s own ShouldProcess blocks.')]
    param()
    $path = Join-Path (Get-RecordsRoot) 'devices.json'
    $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    foreach ($d in $doc.devices) { if ($d.alias -eq $Alias) { $d | Add-Member -NotePropertyName removedUtc -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force } }
    ($doc | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path
}

$canMeshctrl = $s.PSObject.Properties['meshctrl'] -and $s.meshctrl -and (Test-Path -LiteralPath $s.meshctrl) -and
    $s.PSObject.Properties['removeLogin'] -and $s.removeLogin -and $s.removeLogin.userRef -and $s.removeLogin.passwordRef

if ($RemovedInWebUi) {
    if ($PSCmdlet.ShouldProcess($Alias, 'Mark removed in devices.json')) {
        Set-DeviceRemoved
        Write-Information "Marked '$Alias' removed in devices.json." -InformationAction Continue
    }
} elseif ($canMeshctrl) {
    $login = Get-MeshLogin -Settings ([pscustomobject]@{ login = $s.removeLogin })
    # The console's relay host (the private one when set), not the agents' public address.
    $wss = (Get-MeshRelayUrl -Settings $s) -replace '/meshrelay\.ashx$', ''
    if ($PSCmdlet.ShouldProcess($Alias, 'Remove from the MeshCentral server')) {
        & node $s.meshctrl removedevice --id $device.meshNodeId --url $wss --loginuser $login.User --loginpass $login.Password
        if ($LASTEXITCODE -ne 0) { throw "meshctrl removedevice failed ($LASTEXITCODE)." }
        Set-DeviceRemoved
        Write-Information "Removed '$Alias' from the server and marked it removed in devices.json." -InformationAction Continue
    }
} else {
    $web = if ($s.PSObject.Properties['webUi'] -and $s.webUi) { ($s.webUi -split ' ')[0] } else { $s.serverUrl }
    Write-Information @"
Remove '$Alias' from the server in its web page ($web):
  1. Sign in with your own MeshCentral login.
  2. Open the device, then Actions > Delete Device, and confirm.
Then mark it removed here:
  pwsh -File scripts/console/Remove-DesksideDevice.ps1 -Alias $Alias -RemovedInWebUi
"@ -InformationAction Continue
}
