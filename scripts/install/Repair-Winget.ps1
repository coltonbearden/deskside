#Requires -Version 5.1
<#
.SYNOPSIS
    Makes sure winget works, installing or repairing it when it's missing or broken.

.DESCRIPTION
    Uses Microsoft's documented method (learn.microsoft.com/windows/package-manager/winget, "Install WinGet on Windows
    Sandbox"): the NuGet package provider, the Microsoft.WinGet.Client module, then Repair-WinGetPackageManager.
    The module is removed again afterwards so nothing is left that needs updating; winget itself is kept current by
    Windows (App Installer) and by Winget-AutoUpdate.

.OUTPUTS
    The path to winget.exe.
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
Assert-NotManaged

function Test-WingetWorking {
    $exe = Get-WingetPath
    if (-not $exe) { return $null }
    try {
        $v = & $exe --version 2>$null
        if ($LASTEXITCODE -eq 0 -and $v -match '^v\d') { return $exe }
    } catch { Write-Verbose "winget failed to run: $($_.Exception.Message)" }
    return $null
}

$exe = Test-WingetWorking
if ($exe) { Write-Verbose "winget works: $exe"; return $exe }

if (-not (Test-IsAdministrator)) { throw 'winget is missing or broken, and repairing it needs administrator rights. Run this again as administrator.' }
if (-not $PSCmdlet.ShouldProcess('winget', 'Install or repair (NuGet provider, Microsoft.WinGet.Client, Repair-WinGetPackageManager)')) { return $null }

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
}
$hadModule = [bool](Get-Module -ListAvailable -Name Microsoft.WinGet.Client)
if (-not $hadModule) { Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Force -Scope AllUsers -AllowClobber | Out-Null }
# The repair runs in a child Windows PowerShell so the module isn't loaded here and can be removed afterwards.
$child = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$repair = 'Import-Module Microsoft.WinGet.Client; Repair-WinGetPackageManager -AllUsers -Latest -Force | Out-Null'
& $child -NoProfile -ExecutionPolicy Bypass -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($repair)))
if ($LASTEXITCODE -ne 0) { Write-Verbose "Repair-WinGetPackageManager exited $LASTEXITCODE." }

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$env:Path = $machinePath + ';' + $userPath + ';' + (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')

if (-not $hadModule) {
    try { Uninstall-Module -Name Microsoft.WinGet.Client -AllVersions -Force -ErrorAction Stop } catch { Write-Verbose 'Could not remove the Microsoft.WinGet.Client module.' }
}

$exe = Test-WingetWorking
if (-not $exe) { throw 'winget still does not work after the repair.' }
return $exe
