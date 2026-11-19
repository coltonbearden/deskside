#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers for every deskside script: the work-or-school check, consent records,
    run records, before-state and undo files, restore points and safe screen output.

.NOTES
    Runs on Windows PowerShell 5.1 and PowerShell 7. ASCII only. No PowerShell 7-only syntax.
#>

Set-StrictMode -Version 2.0

$script:SchemaVersion = 'deskside.record/v1'
$script:ModuleRoot = Split-Path -Parent $PSScriptRoot | Split-Path -Parent

function Get-DesksideRoot {
    <# The repo root (two levels above this module). #>
    [CmdletBinding()]
    param()
    return $script:ModuleRoot
}

function Get-DesksideDataRoot {
    <#
    .SYNOPSIS
        Where this PC keeps deskside's records, consent and undo files.
    .DESCRIPTION
        %ProgramData%\deskside\data by default. Override with $env:DESKSIDE_DATA (tests and the Sandbox proof use it).
    #>
    [CmdletBinding()]
    param()
    if ($env:DESKSIDE_DATA) { return $env:DESKSIDE_DATA }
    return (Join-Path $env:ProgramData 'deskside\data')
}

function Read-DesksideCatalog {
    <# Reads a JSON file from catalog\ and returns the parsed object. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path (Join-Path (Get-DesksideRoot) 'catalog') $Name
    if (-not (Test-Path -LiteralPath $path)) { throw "Catalog file not found: catalog\$Name" }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Test-IsAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DsregStatus {
    <# Parses `dsregcmd /status` into a hashtable of NAME = VALUE pairs. Empty when dsregcmd is absent. #>
    [CmdletBinding()]
    param()
    $result = @{}
    $exe = Join-Path $env:SystemRoot 'System32\dsregcmd.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return $result }
    $lines = & $exe /status 2>$null
    foreach ($line in $lines) {
        if ($line -match '^\s*([A-Za-z]+)\s*:\s*(.+?)\s*$') { $result[$Matches[1]] = $Matches[2] }
    }
    return $result
}

$script:BuiltInEnrollmentProviders = @('Local Authority', 'Deploy Authority', 'Cloud Authority', 'WMI_Bridge_Server')

function Get-MdmEnrollment {
    <#
    .SYNOPSIS
        Returns active device-management enrollments under HKLM:\SOFTWARE\Microsoft\Enrollments.
    .DESCRIPTION
        Every Windows PC carries built-in local enrollments (providers 'Local Authority', 'Deploy Authority',
        'Cloud Authority', 'WMI_Bridge_Server'); those are not management by an organization and are skipped.
        Any other provider with an active state (EnrollmentState 1), or any row with a UPN, counts.
    #>
    [CmdletBinding()]
    param([string]$Base = 'HKLM:\SOFTWARE\Microsoft\Enrollments')
    $rows = @()
    if (-not (Test-Path -LiteralPath $Base)) { return $rows }
    foreach ($k in Get-ChildItem -LiteralPath $Base -ErrorAction SilentlyContinue) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $p) { continue }
        $upn = $null; $provider = $null; $type = $null; $state = $null
        if ($p.PSObject.Properties['UPN']) { $upn = $p.UPN }
        if ($p.PSObject.Properties['ProviderID']) { $provider = [string]$p.ProviderID }
        if ($p.PSObject.Properties['EnrollmentType']) { $type = $p.EnrollmentType }
        if ($p.PSObject.Properties['EnrollmentState']) { $state = $p.EnrollmentState }
        if ($provider -and ($script:BuiltInEnrollmentProviders -contains $provider)) { continue }
        if ($upn -or ($provider -and $state -eq 1)) { $rows += [pscustomobject]@{ ProviderID = $provider; EnrollmentType = $type; HasUpn = [bool]$upn } }
    }
    return $rows
}

function Test-ManagedDevice {
    <#
    .SYNOPSIS
        The work-or-school check. True when the PC is joined to a domain or Microsoft Entra, or enrolled in device management.
    .DESCRIPTION
        Such a PC belongs to an organization and its user can't authorize changes, so every deskside script reports and
        changes nothing on it. Returns an object with IsManaged and the reasons (no names or account details).
    #>
    [CmdletBinding()]
    param()
    $reasons = New-Object System.Collections.Generic.List[string]
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.PartOfDomain) { $reasons.Add('joined to an Active Directory domain') }
    } catch { $reasons.Add('could not read domain membership (treated as managed)') }
    $ds = Get-DsregStatus
    if ($ds.ContainsKey('AzureAdJoined') -and $ds['AzureAdJoined'] -eq 'YES') { $reasons.Add('joined to Microsoft Entra ID') }
    if ($ds.ContainsKey('EnterpriseJoined') -and $ds['EnterpriseJoined'] -eq 'YES') { $reasons.Add('enterprise joined') }
    if ($ds.ContainsKey('DomainJoined') -and $ds['DomainJoined'] -eq 'YES' -and -not ($reasons -contains 'joined to an Active Directory domain')) { $reasons.Add('joined to an Active Directory domain') }
    $mdm = @(Get-MdmEnrollment)
    if ($mdm.Count -gt 0) { $reasons.Add('enrolled in device management (MDM)') }
    return [pscustomobject]@{ IsManaged = ($reasons.Count -gt 0); Reasons = @($reasons) }
}

function Assert-NotManaged {
    <# Throws a fixed message when the PC is managed. Change scripts call this first. #>
    [CmdletBinding()]
    param()
    $m = Test-ManagedDevice
    if ($m.IsManaged) {
        throw ("This PC belongs to a work or school (" + ($m.Reasons -join '; ') + "). deskside reports only and changes nothing here.")
    }
}

function Get-ConsentPath {
    [CmdletBinding()]
    param()
    return (Join-Path (Get-DesksideDataRoot) 'consent.json')
}

function Get-Consent {
    <# Returns the consent record, or $null when the owner hasn't said yes yet. #>
    [CmdletBinding()]
    param()
    $p = Get-ConsentPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-ConsentText {
    <# The exact words shown to the PC's owner for each scope. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('diagnose', 'onboard', 'remote')][string]$Scope)
    switch ($Scope) {
        'diagnose' { 'Read this PC''s settings, health and installed apps, and write a report. Nothing is changed.' }
        'onboard' { 'Install the apps and apply the settings on the list you agree to. Each change is recorded and can be undone.' }
        'remote' { 'Install the MeshCentral agent so your helper can connect to this PC when you need help, and turn on a sign-in for him that only works through that agent. You will see when he is connected, and you can remove it any time with "Remove remote help" on the desktop.' }
    }
}

function Grant-Consent {
    <#
    .SYNOPSIS
        Records that the PC's owner said yes to one or more scopes. No names are stored.
    .PARAMETER Confirmed
        Skips the typed prompt. Only for tests and the Sandbox proof, where there is no owner to ask.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('diagnose', 'onboard', 'remote')][string[]]$Scope,
        [switch]$Confirmed
    )
    Assert-NotManaged
    if (-not $Confirmed) {
        Write-Host ''
        Write-Host 'The owner of this PC is asked to agree to the following:' -ForegroundColor Cyan
        foreach ($s in $Scope) { Write-Host (' - ' + (Get-ConsentText -Scope $s)) }
        Write-Host ''
        $answer = Read-Host 'Are you the owner of this PC, and do you agree? Type YES to agree'
        if ($answer -cne 'YES') { throw 'The owner did not agree. Nothing was changed.' }
    }
    $existing = Get-Consent
    $scopes = @{}
    if ($existing -and $existing.PSObject.Properties['scopes']) {
        foreach ($prop in $existing.scopes.PSObject.Properties) { $scopes[$prop.Name] = $prop.Value }
    }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    foreach ($s in $Scope) { $scopes[$s] = [ordered]@{ grantedUtc = $now; text = (Get-ConsentText -Scope $s) } }
    $record = [ordered]@{ schema = 'deskside.consent/v1'; scopes = $scopes }
    $path = Get-ConsentPath
    if ($PSCmdlet.ShouldProcess($path, 'Record consent')) {
        Initialize-DataRoot
        ($record | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $path -Encoding UTF8
    }
    return $record
}

function Revoke-Consent {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateSet('diagnose', 'onboard', 'remote')][string[]]$Scope)
    $existing = Get-Consent
    if ($null -eq $existing) { return }
    $scopes = @{}
    foreach ($prop in $existing.scopes.PSObject.Properties) { if ($Scope -notcontains $prop.Name) { $scopes[$prop.Name] = $prop.Value } }
    if ($PSCmdlet.ShouldProcess((Get-ConsentPath), 'Revoke consent')) {
        ([ordered]@{ schema = 'deskside.consent/v1'; scopes = $scopes } | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Get-ConsentPath) -Encoding UTF8
    }
}

function Assert-Consent {
    <# Throws unless the owner has said yes to the scope. Every change script calls this after Assert-NotManaged. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('diagnose', 'onboard', 'remote')][string]$Scope)
    $c = Get-Consent
    if ($null -eq $c -or -not $c.scopes.PSObject.Properties[$Scope]) {
        throw "The owner of this PC has not agreed to '$Scope'. Run scripts\onboard\Grant-Consent.ps1 -Scope $Scope with them first."
    }
}

function Initialize-DataRoot {
    <# Creates the data folder with an ACL that only Administrators and SYSTEM can read. #>
    [CmdletBinding()]
    param()
    $root = Get-DesksideDataRoot
    if (Test-Path -LiteralPath $root) { return $root }
    New-Item -ItemType Directory -Force -Path $root -WhatIf:$false | Out-Null
    if (-not $env:DESKSIDE_DATA -and (Test-IsAdministrator)) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $none = [System.Security.AccessControl.PropagationFlags]::None
        foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
            $who = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($who, 'FullControl', $inherit, $none, 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $root -AclObject $acl -WhatIf:$false
    }
    return $root
}

function New-DesksideRun {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only creates the run''s own record folder and transcript.')]
    <#
    .SYNOPSIS
        Starts a run: a run id, a folder under the data root, and a transcript.
    .OUTPUTS
        An object with Id, Kind, Folder, Started and a Findings list the script fills in.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [string]$OutputDirectory,
        [switch]$NoTranscript
    )
    $started = Get-Date
    $id = $started.ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + $Kind
    if ($OutputDirectory) { $folder = $OutputDirectory } else { $folder = Join-Path (Join-Path (Initialize-DataRoot) 'runs') $id }
    New-Item -ItemType Directory -Force -Path $folder -WhatIf:$false | Out-Null
    $transcript = $null
    if (-not $NoTranscript) {
        $transcript = Join-Path $folder 'transcript.txt'
        try { Start-Transcript -LiteralPath $transcript -Force -WhatIf:$false | Out-Null } catch { $transcript = $null }
    }
    return [pscustomobject]@{
        Id         = $id
        Kind       = $Kind
        Folder     = $folder
        Started    = $started
        Transcript = $transcript
        Findings   = New-Object System.Collections.Generic.List[object]
        Changes    = New-Object System.Collections.Generic.List[object]
        Errors     = New-Object System.Collections.Generic.List[object]
        Data       = [ordered]@{}
    }
}

function Add-Finding {
    <# Adds a ranked finding. Rank: FixNow, FixSoon, NiceToHave, Info. Text is one plain sentence. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('FixNow', 'FixSoon', 'NiceToHave', 'Info')][string]$Rank,
        [Parameter(Mandatory)][string]$Text,
        $Detail
    )
    $Run.Findings.Add([pscustomobject]@{ id = $Id; rank = $Rank; text = $Text; detail = $Detail })
}

function Invoke-Section {
    <#
    .SYNOPSIS
        Runs one section of a script. On failure the section is recorded as an error and the run goes on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    try {
        $value = & $ScriptBlock
        $Run.Data[$Name] = $value
    } catch {
        $Run.Data[$Name] = $null
        $Run.Errors.Add([pscustomobject]@{ section = $Name; message = $_.Exception.Message })
        Write-Verbose "Section $Name failed: $($_.Exception.Message)"
    }
}

function Complete-DesksideRun {
    <#
    .SYNOPSIS
        Writes record.json (versioned) and summary.md, stops the transcript, prints counts only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [string]$SummaryTitle = 'deskside report'
    )
    $ranks = @('FixNow', 'FixSoon', 'NiceToHave', 'Info')
    $counts = [ordered]@{}
    foreach ($r in $ranks) { $counts[$r] = @($Run.Findings | Where-Object { $_.rank -eq $r }).Count }
    $record = [ordered]@{
        schema      = $script:SchemaVersion
        kind        = $Run.Kind
        runId       = $Run.Id
        startedUtc  = $Run.Started.ToUniversalTime().ToString('o')
        finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
        toolVersion = (Get-DesksideVersion)
        psVersion   = $PSVersionTable.PSVersion.ToString()
        elevated    = (Test-IsAdministrator)
        counts      = $counts
        findings    = $Run.Findings.ToArray()
        changes     = $Run.Changes.ToArray()
        errors      = $Run.Errors.ToArray()
        data        = $Run.Data
    }
    # A section whose data can't be serialized is replaced by an error, so one bad value never loses the record.
    foreach ($k in @($Run.Data.Keys)) {
        try { $null = ConvertTo-Json -InputObject $Run.Data[$k] -Depth 8 -ErrorAction Stop }
        catch {
            $Run.Errors.Add([pscustomobject]@{ section = $k; message = ('could not save: ' + $_.Exception.Message) })
            $Run.Data[$k] = $null
        }
    }
    $json = Join-Path $Run.Folder 'record.json'
    (ConvertTo-Json -InputObject $record -Depth 8) | Set-Content -LiteralPath $json -Encoding UTF8 -WhatIf:$false
    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine("# $SummaryTitle")
    [void]$md.AppendLine('')
    [void]$md.AppendLine("Run $($Run.Id)")
    $labels = @{ FixNow = 'Fix now'; FixSoon = 'Fix soon'; NiceToHave = 'Nice to have'; Info = 'Good to know' }
    foreach ($r in $ranks) {
        $items = @($Run.Findings | Where-Object { $_.rank -eq $r })
        if ($items.Count -eq 0) { continue }
        [void]$md.AppendLine('')
        [void]$md.AppendLine("## $($labels[$r])")
        [void]$md.AppendLine('')
        foreach ($f in $items) { [void]$md.AppendLine("- $($f.text)") }
    }
    if ($Run.Changes.Count -gt 0) {
        [void]$md.AppendLine('')
        [void]$md.AppendLine('## Changes made')
        [void]$md.AppendLine('')
        foreach ($c in $Run.Changes) { [void]$md.AppendLine("- $($c.what): $($c.result)") }
    }
    if ($Run.Errors.Count -gt 0) {
        [void]$md.AppendLine('')
        [void]$md.AppendLine("## Could not check ($($Run.Errors.Count))")
        [void]$md.AppendLine('')
        foreach ($e in $Run.Errors) { [void]$md.AppendLine("- $($e.section)") }
    }
    $mdPath = Join-Path $Run.Folder 'summary.md'
    $md.ToString() | Set-Content -LiteralPath $mdPath -Encoding UTF8 -WhatIf:$false
    if ($Run.Transcript) { try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript to stop.' } }
    Write-SafeSummary -Counts $counts -Changes $Run.Changes.Count -Errors $Run.Errors.Count -Folder $Run.Folder
    return [pscustomobject]@{ Record = $json; Summary = $mdPath; Counts = $counts }
}

function Write-SafeSummary {
    <# Prints counts only: never names, accounts, paths of user files or app lists. #>
    [CmdletBinding()]
    param($Counts, [int]$Changes, [int]$Errors, [string]$Folder)
    $line = 'Fix now: {0}  Fix soon: {1}  Nice to have: {2}  Good to know: {3}' -f $Counts['FixNow'], $Counts['FixSoon'], $Counts['NiceToHave'], $Counts['Info']
    Write-Information $line -InformationAction Continue
    if ($Changes -gt 0) { Write-Information "Changes made: $Changes" -InformationAction Continue }
    if ($Errors -gt 0) { Write-Information "Sections that could not be checked: $Errors" -InformationAction Continue }
    if ($Folder) { Write-Information "Report saved on this PC (readable by administrators only)." -InformationAction Continue }
}

function Get-DesksideVersion {
    [CmdletBinding()]
    param()
    $v = Join-Path (Get-DesksideRoot) 'VERSION'
    if (Test-Path -LiteralPath $v) { return (Get-Content -LiteralPath $v -TotalCount 1).Trim() }
    return 'dev'
}

function Read-JsonArray {
    <#
    .SYNOPSIS
        Reads a JSON array file into a flat PowerShell array on both engines.
    .DESCRIPTION
        Windows PowerShell 5.1's ConvertFrom-Json emits a JSON array as ONE object (an Object[]), so @(...) around it
        gives a one-element array holding the whole list, and appending to that nests the list. foreach unrolls it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $items = @()
    if (-not (Test-Path -LiteralPath $Path)) { return ,$items }
    $parsed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($e in $parsed) { $items += $e }
    return ,$items
}

function Save-BeforeState {
    <#
    .SYNOPSIS
        Records the before-state of one change into the run's undo.json, so Undo-DesksideRun can put it back.
    .PARAMETER Undo
        A hashtable describing how to undo: @{ type = 'registry'; path; name; existed; kind; value } and similar.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$ItemId, [Parameter(Mandatory)][hashtable]$Undo)
    $path = Join-Path $Run.Folder 'undo.json'
    $list = Read-JsonArray -Path $path
    $entry = [ordered]@{ item = $ItemId; savedUtc = (Get-Date).ToUniversalTime().ToString('o') }
    foreach ($k in $Undo.Keys) { $entry[$k] = $Undo[$k] }
    $list += [pscustomobject]$entry
    (ConvertTo-Json -InputObject @($list) -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8 -WhatIf:$false
}

function Get-RegistryState {
    <# Reads one registry value as a before-state hashtable. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $state = @{ type = 'registry'; path = $Path; name = $Name; existed = $false; kind = $null; value = $null; keyExisted = (Test-Path -LiteralPath $Path) }
    if ($state.keyExisted) {
        $key = Get-Item -LiteralPath $Path
        if ($key.GetValueNames() -contains $Name) {
            $state.existed = $true
            $state.kind = $key.GetValueKind($Name).ToString()
            $state.value = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
        }
    }
    return $state
}

function Set-RegistryValueSafe {
    <# Sets a registry value, creating the key if needed. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][ValidateSet('DWord', 'String', 'ExpandString', 'QWord', 'MultiString', 'Binary')][string]$Kind
    )
    if ($PSCmdlet.ShouldProcess("$Path\$Name", "Set to $Value")) {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
    }
}

function Restore-RegistryState {
    <# Puts a registry value back from a before-state entry. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$State)
    $target = "$($State.path)\$($State.name)"
    if (-not $PSCmdlet.ShouldProcess($target, 'Restore previous value')) { return }
    if ($State.existed) {
        if (-not (Test-Path -LiteralPath $State.path)) { New-Item -Path $State.path -Force | Out-Null }
        New-ItemProperty -LiteralPath $State.path -Name $State.name -Value $State.value -PropertyType $State.kind -Force | Out-Null
    } elseif (Test-Path -LiteralPath $State.path) {
        Remove-ItemProperty -LiteralPath $State.path -Name $State.name -ErrorAction SilentlyContinue
        if (-not $State.keyExisted) {
            $key = Get-Item -LiteralPath $State.path
            if ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) { Remove-Item -LiteralPath $State.path -Force }
        }
    }
}

function Test-SystemProtectionOn {
    <# True when System Protection is on for the system drive. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $p = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        if ($p.PSObject.Properties['RPSessionInterval'] -and $p.RPSessionInterval -eq 1) { return $true }
        $points = @(Get-CimInstance -Namespace root\default -ClassName SystemRestore -ErrorAction Stop)
        return ($points.Count -gt 0 -and -not ($p.PSObject.Properties['DisableSR'] -and $p.DisableSR -eq 1))
    } catch { return $false }
}

function New-DesksideRestorePoint {
    <# Makes a restore point before changes when System Protection is on. Never turns it on by itself. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Run, [string]$Description = 'deskside change')
    if (-not (Test-SystemProtectionOn)) {
        $Run.Changes.Add([pscustomobject]@{ what = 'Restore point'; result = 'skipped: System Protection is off' })
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess('System restore', "Create restore point '$Description'")) { return $false }
    try {
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        $Run.Changes.Add([pscustomobject]@{ what = 'Restore point'; result = 'created' })
        return $true
    } catch {
        $Run.Changes.Add([pscustomobject]@{ what = 'Restore point'; result = ('not created: ' + $_.Exception.Message) })
        return $false
    }
}

function Get-WingetPath {
    <# Returns the winget.exe path or $null. Looks in the PATH and in the App Installer package folder (SYSTEM context). #>
    [CmdletBinding()]
    param()
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $local = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    $pkg = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($pkg) {
        $exe = Join-Path $pkg.FullName 'winget.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return $null
}

function Test-RegistryValueCompliant {
    param($Spec)
    $state = Get-RegistryState -Path $Spec.path -Name $Spec.name
    if (-not $state.existed) { return ($Spec.PSObject.Properties['missingIsCompliant'] -and $Spec.missingIsCompliant) }
    $ok = @($Spec.value)
    if ($Spec.PSObject.Properties['compliantValues']) { $ok = @($Spec.compliantValues) }
    foreach ($v in $ok) { if ([string]$state.value -eq [string]$v) { return $true } }
    return $false
}

function Test-DesksideSettingCompliant {
    param($Item)
    switch ($Item.type) {
        'registry' { foreach ($v in $Item.values) { if (-not (Test-RegistryValueCompliant $v)) { return $false } }; return $true }
        'handler' {
            switch ($Item.handler) {
                'SystemProtection' { return (Test-SystemProtectionOn) }
                'DefenderPua' { try { return ([int](Get-MpPreference -ErrorAction Stop).PUAProtection -eq 1) } catch { return $true } }
            }
        }
    }
    throw "Unknown item type $($Item.type)"
}


Export-ModuleMember -Function *
