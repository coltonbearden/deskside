#Requires -Version 5.1
<#
.SYNOPSIS
    Installs what a profile in catalog\profiles lists and the PC doesn't have yet.

.DESCRIPTION
    Resolves the profile and the profiles it includes, makes sure winget works (Repair-Winget.ps1), checks each app with
    `winget list`, and installs only what's missing, always the latest version from the winget source. Records every
    install in the run's undo.json so Undo-DesksideRun.ps1 can uninstall them again. Settings listed by the profile are
    left to Set-Baseline.ps1 and the change list.

    Needs the owner's 'onboard' consent and stops on a work or school PC.

.PARAMETER ProfileName
    everyone, power or developer.

.EXAMPLE
    .\scripts\install\Install-Profile.ps1 -ProfileName everyone -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('everyone', 'power', 'developer')][string]$ProfileName,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
Assert-NotManaged
Assert-Consent -Scope onboard

function Resolve-DesksideProfile {
    param([string]$Id, [hashtable]$Seen)
    if ($Seen.ContainsKey($Id)) { return @() }
    $Seen[$Id] = $true
    $p = Read-DesksideCatalog -Name ("profiles\$Id.json")
    $list = @()
    if ($p.PSObject.Properties['includes']) { foreach ($inc in $p.includes) { $list += Resolve-DesksideProfile -Id $inc -Seen $Seen } }
    $list += $p
    return $list
}

$profiles = @(Resolve-DesksideProfile -Id $ProfileName -Seen @{})
$run = New-DesksideRun -Kind ("install-$ProfileName") -OutputDirectory $OutputDirectory
$run.Data['profile'] = $ProfileName

$winget = & (Join-Path $PSScriptRoot 'Repair-Winget.ps1') -WhatIf:$WhatIfPreference
if (-not $winget -and -not $WhatIfPreference) { throw 'winget is not available.' }
$common = @('--source', 'winget', '--accept-source-agreements', '--disable-interactivity')

New-DesksideRestorePoint -Run $run -Description "deskside install $ProfileName" | Out-Null

$defaults = @()
foreach ($p in $profiles) {
    foreach ($app in $p.apps) {
        $installed = $false
        if ($winget) {
            & $winget list --id $app.id -e @common *> $null
            $installed = ($LASTEXITCODE -eq 0)
        }
        if ($installed) {
            $run.Changes.Add([pscustomobject]@{ what = $app.name; result = 'already installed' })
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($app.name, 'Install with winget')) {
            $run.Changes.Add([pscustomobject]@{ what = $app.name; result = 'would install' })
            continue
        }
        if ($app.PSObject.Properties['installer'] -and $app.installer -eq 'Install-WAU') {
            & (Join-Path $PSScriptRoot 'Install-WAU.ps1') -Winget $winget | Out-Null
            $code = $LASTEXITCODE
        } else {
            & $winget install --id $app.id -e --silent --accept-package-agreements @common *> (Join-Path $run.Folder ("winget-" + $app.id + '.log'))
            $code = $LASTEXITCODE
        }
        # winget's list can lag behind a fresh install by a few seconds; ask again before calling it failed.
        $found = $false
        for ($try = 0; $try -lt 6 -and -not $found; $try++) {
            if ($try -gt 0) { Start-Sleep -Seconds 5 }
            & $winget list --id $app.id -e @common *> $null
            $found = ($LASTEXITCODE -eq 0)
        }
        if ($found) {
            Save-BeforeState -Run $run -ItemId $app.id -Undo @{ type = 'winget'; id = $app.id; name = $app.name }
            $run.Changes.Add([pscustomobject]@{ what = $app.name; result = 'installed' })
            if ($app.PSObject.Properties['default']) { $defaults += $app }
        } else {
            $run.Changes.Add([pscustomobject]@{ what = $app.name; result = "install failed (winget exit $code)" })
            $run.Errors.Add([pscustomobject]@{ section = $app.id; message = "winget exit $code" })
        }
    }
    if ($p.PSObject.Properties['modules']) {
        foreach ($m in $p.modules) {
            if (Get-Module -ListAvailable -Name $m.name) { $run.Changes.Add([pscustomobject]@{ what = "Module $($m.name)"; result = 'already installed' }); continue }
            if ($PSCmdlet.ShouldProcess($m.name, 'Install PowerShell module for the current user')) {
                Install-Module -Name $m.name -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
                Save-BeforeState -Run $run -ItemId ("module-" + $m.name) -Undo @{ type = 'module'; name = $m.name }
                $run.Changes.Add([pscustomobject]@{ what = "Module $($m.name)"; result = 'installed' })
            }
        }
    }
    if ($p.PSObject.Properties['wsl']) {
        $wslOk = $false
        try { & wsl.exe --status *> $null; $wslOk = ($LASTEXITCODE -eq 0) } catch { $wslOk = $false }
        if (-not $wslOk -and $PSCmdlet.ShouldProcess('WSL', "Install with distribution $($p.wsl.distribution)")) {
            & wsl.exe --install -d $p.wsl.distribution --no-launch
            Save-BeforeState -Run $run -ItemId 'wsl' -Undo @{ type = 'note'; text = 'WSL was installed; remove it from Settings > Apps if it is not wanted.' }
            $run.Changes.Add([pscustomobject]@{ what = 'WSL'; result = 'installed; a restart is needed' })
        }
    }
    if ($p.PSObject.Properties['files']) {
        foreach ($f in $p.files) {
            $src = Join-Path (Get-DesksideRoot) $f.from
            $dst = [Environment]::ExpandEnvironmentVariables($f.to)
            $seedOnly = ($f.PSObject.Properties['mode'] -and $f.mode -eq 'seed-if-missing')
            if ((Test-Path -LiteralPath $dst) -and $seedOnly) { $run.Changes.Add([pscustomobject]@{ what = (Split-Path $dst -Leaf); result = 'kept existing file' }); continue }
            if ($PSCmdlet.ShouldProcess($dst, "Copy $($f.from)")) {
                $backup = $null
                if (Test-Path -LiteralPath $dst) { $backup = Join-Path $run.Folder ('backup-' + (Split-Path $dst -Leaf)); Copy-Item -LiteralPath $dst -Destination $backup -Force }
                New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
                Copy-Item -LiteralPath $src -Destination $dst -Force
                Save-BeforeState -Run $run -ItemId ("file-" + (Split-Path $dst -Leaf)) -Undo @{ type = 'file'; path = $dst; backup = $backup }
                $run.Changes.Add([pscustomobject]@{ what = (Split-Path $dst -Leaf); result = 'copied' })
            }
        }
    }
}

if ($defaults.Count -gt 0) {
    $run.Data['defaultsToSet'] = @($defaults | ForEach-Object { [ordered]@{ app = $_.name; what = $_.default.what } })
    Add-Finding -Run $run -Id 'defaults.hands' -Rank 'FixSoon' -Text ('Windows only lets the person at the PC choose default apps: open Settings > Apps > Default apps and set ' + (($defaults | ForEach-Object { "$($_.name) for $($_.default.what)" }) -join ' and ') + '.')
    if ([Environment]::UserInteractive -and -not $env:SSH_CONNECTION -and -not $WhatIfPreference) {
        try { Start-Process 'ms-settings:defaultapps' } catch { Write-Verbose 'Could not open Settings.' }
    }
}

Complete-DesksideRun -Run $run -SummaryTitle "Install: $ProfileName profile" | Out-Null
