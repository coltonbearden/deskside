#Requires -Version 5.1
<#
    Test helper, run by Integration.Tests.ps1 under each engine: changes three values under a throwaway test key the
    way change scripts do (before-state first), then prints the run folder. Never touches real settings.
#>
param([Parameter(Mandatory)][string]$Folder)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\scripts\common\Deskside.Common.psm1') -Force
$key = 'HKCU:\Software\deskside-tests\Undo'
New-Item -Path $key -Force | Out-Null
New-ItemProperty -Path $key -Name A -Value 1 -PropertyType DWord -Force | Out-Null
$run = New-DesksideRun -Kind 'test-undo' -OutputDirectory $Folder -NoTranscript
foreach ($n in 'A', 'B', 'C') {
    Save-BeforeState -Run $run -ItemId "value-$n" -Undo (Get-RegistryState -Path $key -Name $n)
    Set-RegistryValueSafe -Path $key -Name $n -Value 9 -Kind DWord
}
Complete-DesksideRun -Run $run -SummaryTitle 'test' | Out-Null
