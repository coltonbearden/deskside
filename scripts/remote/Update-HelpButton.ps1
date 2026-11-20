#Requires -Version 5.1
<#
.SYNOPSIS
    The help button's weekly refresh (task \deskside\help-refresh, as SYSTEM): downloads MeshCentral Assistant again
    from the helper's server and swaps the file when it changed.

.DESCRIPTION
    The server and group come from the agent's own MeshAgent.msh, so nothing extra is kept on the PC. A running copy
    keeps running from the renamed old file until the person next signs in. The result goes to
    C:\ProgramData\deskside\data\help-refresh.json, which the diagnostics read (help.refresh-failing).
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
$p = Get-HelpButtonPath
$state = [ordered]@{ schema = 'deskside.help-refresh/v1'; lastUtc = (Get-Date).ToUniversalTime().ToString('o'); result = $null; sha256 = $null; lastSuccessUtc = $null }
$old = $null
if (Test-Path -LiteralPath $p.StateFile) { try { $old = Get-Content -LiteralPath $p.StateFile -Raw | ConvertFrom-Json } catch { $old = $null } }
if ($old -and $old.PSObject.Properties['lastSuccessUtc']) { $state.lastSuccessUtc = $old.lastSuccessUtc }
try {
    if (-not (Test-Path -LiteralPath $p.Exe)) { throw 'the help button is not installed' }
    $agent = Get-MeshAgentSetting
    if (-not $agent) { throw 'the agent''s MeshAgent.msh gave no server' }
    $r = Save-HelpButtonFile -ServerUrl $agent.ServerUrl -GroupId $agent.GroupId -WhatIf:$WhatIfPreference
    $state.result = $r.result; $state.sha256 = $r.sha256; $state.lastSuccessUtc = $state.lastUtc
} catch {
    $state.result = 'failed: ' + $_.Exception.Message
}
if ($PSCmdlet.ShouldProcess($p.StateFile, 'Record the refresh')) {
    Initialize-DataRoot | Out-Null
    ($state | ConvertTo-Json) | Set-Content -LiteralPath $p.StateFile -Encoding UTF8
}
if ($state.result -like 'failed*') { exit 1 }
