#Requires -Version 7.0
<#
.SYNOPSIS
    deskside's whole check: PSScriptAnalyzer, Pester under PowerShell 7, every PC-side script run for real under
    Windows PowerShell 5.1 and PowerShell 7 (-Integration), a secret scan (gitleaks) and the personal-data scan.

.DESCRIPTION
    The same check runs in GitHub Actions on a Windows runner for every push and pull request
    (.github/workflows/check.yml). Exit code 0 means everything passed.

.PARAMETER Integration
    Also run the Integration-tagged tests, which launch powershell.exe (5.1) and pwsh.exe (7) on the real scripts.

.PARAMETER SkipSecrets
    Skip gitleaks (for a machine without it). CI never skips it.
#>
[CmdletBinding()]
param([switch]$Integration, [switch]$SkipSecrets)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$failed = New-Object System.Collections.Generic.List[string]

Write-Host '== PSScriptAnalyzer' -ForegroundColor Cyan
Import-Module PSScriptAnalyzer
$pcSide = @(Get-ChildItem -Path $root -Recurse -Include *.ps1, *.psm1 |
    Where-Object { $_.FullName -notmatch '\\(scripts\\console|health|tests|profiles|\.git)\\' -and $_.Name -notin 'Invoke-Check.ps1', 'Invoke-SandboxProof.ps1' })
$consoleSide = @(Get-ChildItem -Path (Join-Path $root 'scripts\console'), (Join-Path $root 'health'), (Join-Path $root 'profiles') -Recurse -Include *.ps1, *.psm1 -ErrorAction SilentlyContinue) +
    @(Get-Item (Join-Path $root 'Invoke-Check.ps1'), (Join-Path $root 'sandbox\Invoke-SandboxProof.ps1'))
$results = @()
foreach ($f in $pcSide) { $results += Invoke-ScriptAnalyzer -Path $f.FullName -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1') }
foreach ($f in $consoleSide) { $results += Invoke-ScriptAnalyzer -Path $f.FullName -Settings (Join-Path $root 'PSScriptAnalyzerSettings.Console.psd1') }
if ($results.Count -gt 0) {
    $results | Sort-Object ScriptName, Line | Format-Table Severity, RuleName, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    if (@($results | Where-Object Severity -in 'Error', 'Warning').Count -gt 0) { $failed.Add('PSScriptAnalyzer') }
} else { Write-Host 'No findings.' }

Write-Host '== ASCII only (Windows PowerShell 5.1 reads BOM-less files as ANSI)' -ForegroundColor Cyan
$nonAscii = @($pcSide | Where-Object { [IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 } | Select-Object -First 1 })
if ($nonAscii.Count -gt 0) { $nonAscii | ForEach-Object { Write-Host "non-ASCII: $($_.FullName.Substring($root.Length + 1))" }; $failed.Add('ASCII') } else { Write-Host 'All PC-side scripts are ASCII.' }

Write-Host '== Pester' -ForegroundColor Cyan
Import-Module Pester -MinimumVersion 5.5
$cfg = New-PesterConfiguration
$cfg.Run.Path = Join-Path $root 'tests'
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Detailed'
if (-not $Integration) { $cfg.Filter.ExcludeTag = @('Integration') }
$pester = Invoke-Pester -Configuration $cfg
if ($pester.FailedCount -gt 0 -or $pester.Result -ne 'Passed') { $failed.Add('Pester') }

if (-not $SkipSecrets) {
    Write-Host '== gitleaks' -ForegroundColor Cyan
    $gl = Get-Command gitleaks -ErrorAction SilentlyContinue
    if (-not $gl) { Write-Host 'gitleaks is not on PATH.'; $failed.Add('gitleaks missing') }
    else {
        & $gl.Source dir $root --no-banner --redact --exit-code 1 --config (Join-Path $root '.gitleaks.toml')
        if ($LASTEXITCODE -ne 0) { $failed.Add('gitleaks (files)') }
        if (Test-Path (Join-Path $root '.git')) {
            & $gl.Source git $root --no-banner --redact --exit-code 1 --config (Join-Path $root '.gitleaks.toml')
            if ($LASTEXITCODE -ne 0) { $failed.Add('gitleaks (history)') }
        }
    }
}

Write-Host '== Personal data' -ForegroundColor Cyan
& (Join-Path $root 'tools\Test-PersonalData.ps1') -Path $root
if ($LASTEXITCODE -ne 0) { $failed.Add('personal data') }

Write-Host ''
if ($failed.Count -gt 0) { Write-Host ("FAILED: " + ($failed -join ', ')) -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
exit 0
