#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Winget-AutoUpdate (github.com/Romanitho/Winget-AutoUpdate, MIT) so every winget app on the PC stays
    updated without anyone remembering to do it.

.DESCRIPTION
    Installs the latest release through winget with the MSI properties from WAU's README: daily updates, notifications
    only when something fails, running in the user's context as well as SYSTEM's, and WAU keeping itself updated.
    Its scheduled task (\WAU\Winget-AutoUpdate) is what deskside's diagnostics and health sweep read to tell whether
    app updates are working.
#>
[CmdletBinding(SupportsShouldProcess)]
param([string]$Winget)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
Assert-NotManaged
Assert-Consent -Scope onboard
if (-not $Winget) { $Winget = & (Join-Path $PSScriptRoot 'Repair-Winget.ps1') }

$properties = 'RUN_WAU=YES UPDATESINTERVAL=Daily UPDATESATLOGON=1 NOTIFICATIONLEVEL=ErrorsOnly USERCONTEXT=1 DONOTRUNONMETERED=1 STARTMENUSHORTCUT=0 DESKTOPSHORTCUT=0'
if ($PSCmdlet.ShouldProcess('Winget-AutoUpdate', "Install with $properties")) {
    & $Winget install --id Romanitho.Winget-AutoUpdate -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --override ("/qn " + $properties)
    if ($LASTEXITCODE -ne 0) { throw "Winget-AutoUpdate install failed (winget exit $LASTEXITCODE)." }
}
