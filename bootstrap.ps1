<#
.SYNOPSIS
    deskside's one-line entry point. In an administrator PowerShell window:

        irm https://raw.githubusercontent.com/coltonbearden/deskside/main/bootstrap.ps1 | iex

.DESCRIPTION
    1. Checks, before downloading or writing anything, whether the PC belongs to a work or school (joined to a domain
       or Microsoft Entra, or enrolled in device management). If it does, it shows a read-only health report on
       screen, keeps nothing, and stops: such a PC is its organization's, and its user can't authorize changes.
    2. Otherwise it puts deskside in %ProgramData%\deskside\app (replacing an older copy), asks the PC's owner to
       agree to a read-only health check, runs it and shows the summary.
    3. Then it offers to set the PC up (scripts\onboard\Start-Onboarding.ps1), which asks again before changing
       anything.

    Works on Windows PowerShell 5.1, which every Windows 10 and 11 PC has.
#>

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $ref = 'main'
    if ($env:DESKSIDE_REF) { $ref = $env:DESKSIDE_REF }
    $zipUrl = "https://github.com/coltonbearden/deskside/archive/refs/heads/$ref.zip"

    # The Sandbox proof runs without anyone to answer prompts. It only works inside Windows Sandbox.
    $proof = ($env:DESKSIDE_SANDBOX_PROOF -eq '1' -and $env:USERNAME -eq 'WDAGUtilityAccount')

    # --- 1. Work-or-school check, in memory -----------------------------------------------------------------------
    $reasons = @()
    try { if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { $reasons += 'domain' } } catch { $reasons += 'unknown' }
    $ds = Join-Path $env:SystemRoot 'System32\dsregcmd.exe'
    if (Test-Path $ds) {
        $s = (& $ds /status 2>$null) -join "`n"
        if ($s -match 'AzureAdJoined\s*:\s*YES') { $reasons += 'entra' }
        if ($s -match 'EnterpriseJoined\s*:\s*YES') { $reasons += 'enterprise' }
    }
    $builtIn = @('Local Authority', 'Deploy Authority', 'Cloud Authority', 'WMI_Bridge_Server')
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $prov = $null; if ($p.PSObject.Properties['ProviderID']) { $prov = [string]$p.ProviderID }
        $upn = $null; if ($p.PSObject.Properties['UPN']) { $upn = $p.UPN }
        $st = $null; if ($p.PSObject.Properties['EnrollmentState']) { $st = $p.EnrollmentState }
        if ($prov -and $builtIn -contains $prov) { continue }
        if ($upn -or ($prov -and $st -eq 1)) { $reasons += 'mdm' }
    }
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    function Get-DesksideZip([string]$Into) {
        $zip = Join-Path $Into 'deskside.zip'
        if ($env:DESKSIDE_SOURCE_ZIP) { Copy-Item -LiteralPath $env:DESKSIDE_SOURCE_ZIP -Destination $zip }
        else { Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing }
        Expand-Archive -LiteralPath $zip -DestinationPath $Into -Force
        Remove-Item -LiteralPath $zip -Force
        $dir = Get-ChildItem -LiteralPath $Into -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'scripts\diagnose\Invoke-Diagnose.ps1') } | Select-Object -First 1
        if (-not $dir) { throw 'The download did not contain deskside.' }
        return $dir.FullName
    }

    if ($reasons.Count -gt 0 -or -not $isAdmin) {
        if ($reasons.Count -gt 0) { Write-Host "`nThis PC belongs to a work or school. deskside only shows a report here and changes nothing." -ForegroundColor Yellow }
        else { Write-Host "`nThis window isn't running as administrator, so deskside only shows a report. To set the PC up, open PowerShell with 'Run as administrator' and run the line again." -ForegroundColor Yellow }
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('deskside-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $root = Get-DesksideZip $tmp
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\diagnose\Invoke-Diagnose.ps1') -ScreenOnly -Quick
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        return
    }

    # --- 2. Put deskside in place ---------------------------------------------------------------------------------
    $base = Join-Path $env:ProgramData 'deskside'
    $app = Join-Path $base 'app'
    $stage = Join-Path $base ('stage-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $root = Get-DesksideZip $stage
    if (Test-Path $app) { Remove-Item -LiteralPath $app -Recurse -Force }
    Move-Item -LiteralPath $root -Destination $app
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "deskside is in $app" -ForegroundColor Cyan

    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $run = { param($script, [string[]]$more) & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app $script) @more; if ($LASTEXITCODE) { throw "$script failed ($LASTEXITCODE)" } }
    $yes = @(); if ($proof) { $yes = @('-Confirmed') }

    & $run 'scripts\onboard\Grant-Consent.ps1' (@('-Scope', 'diagnose') + $yes)
    & $run 'scripts\diagnose\Invoke-Diagnose.ps1' @()
    $latest = Get-ChildItem (Join-Path $base 'data\runs') -Directory -Filter '*-diagnose' | Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) { Write-Host ''; Get-Content (Join-Path $latest.FullName 'summary.md') | Write-Host }

    # --- 3. Offer to set the PC up --------------------------------------------------------------------------------
    $go = $proof
    if (-not $proof) { $go = ((Read-Host "`nSet this PC up now (apps and settings, each asked first)? yes or no") -match '^(y|yes)$') }
    if ($go) { & $run 'scripts\onboard\Start-Onboarding.ps1' (@('-Flow', 'NewPC') + $yes) }
    else { Write-Host "Nothing was changed. To set it up later: $ps -ExecutionPolicy Bypass -File `"$app\scripts\onboard\Start-Onboarding.ps1`"" }
}
