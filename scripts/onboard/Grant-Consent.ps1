#Requires -Version 5.1
<#
.SYNOPSIS
    Asks the PC's owner to agree, in plain words, to what deskside will do, and records their yes.

.DESCRIPTION
    Scopes: diagnose (read-only report), onboard (install apps and apply the agreed settings), remote (MeshCentral
    agent and a sign-in that only works through it). Every change script refuses to run without the matching scope.
    The record holds the scope, its wording and the time, never a name. Stops on a work or school PC, whose user
    can't agree on the organization's behalf.

.PARAMETER Revoke
    Withdraws the given scopes.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('diagnose', 'onboard', 'remote')][string[]]$Scope,
    [switch]$Revoke,
    [switch]$Confirmed
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
if ($Revoke) { Revoke-Consent -Scope $Scope; Write-Information 'Consent withdrawn.' -InformationAction Continue; return }
Grant-Consent -Scope $Scope -Confirmed:$Confirmed | Out-Null
Write-Information ("Recorded the owner's yes to: " + ($Scope -join ', ')) -InformationAction Continue
