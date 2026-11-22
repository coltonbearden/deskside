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
        'remote' { 'Install the MeshCentral agent so your helper can connect to this PC when you need help, turn on a sign-in for him that only works through that agent, and add an "Ask for help" button that sends him your request. If he views your screen, a terminal or your files, you will see a notice and a bar at the top of the screen. When he connects to run checks or fixes, a message appears on your screen saying so and what he is doing, and another when he finishes. If no one is signed in, nothing appears, but the visit is recorded on this PC. The closing message shows once the first is closed (each closes itself after 5 minutes), and may not appear if the connection drops. The automatic check every 6 hours only reads and shows nothing. You can remove all of it any time with "Remove remote help" on the desktop.' }
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

$script:WtsSource = @'
using System;
using System.Runtime.InteropServices;
namespace Deskside {
    public static class Wts {
        [StructLayout(LayoutKind.Sequential)]
        public struct SessionInfo { public int SessionId; public IntPtr WinStationName; public int State; }
        [DllImport("wtsapi32.dll", SetLastError = true)]
        public static extern bool WTSEnumerateSessions(IntPtr server, int reserved, int version, out IntPtr info, out int count);
        [DllImport("wtsapi32.dll")]
        public static extern void WTSFreeMemory(IntPtr memory);
        [DllImport("wtsapi32.dll", SetLastError = true)]
        public static extern bool WTSQuerySessionInformation(IntPtr server, int session, int infoClass, out IntPtr buffer, out int bytes);
        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool WTSSendMessage(IntPtr server, int session, string title, int titleBytes, string message, int messageBytes, int style, int timeout, out int response, bool wait);
    }
}
'@

function Initialize-WtsType {
    [CmdletBinding()]
    param()
    if (-not ('Deskside.Wts' -as [type])) { Add-Type -TypeDefinition $script:WtsSource }
}

function Get-SignedInSession {
    <#
    .SYNOPSIS
        The ids of the Windows sessions where someone is signed in and active (the console or a remote desktop).
    .DESCRIPTION
        WTSEnumerateSessions and WTSQuerySessionInformation (WTSUserName), from wtsapi32 on every Windows edition.
        Returns session ids only; the user names are read to tell a signed-in session from an empty one and dropped.
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param()
    Initialize-WtsType
    $ptr = [IntPtr]::Zero; $count = 0
    $ids = @()
    if (-not [Deskside.Wts]::WTSEnumerateSessions([IntPtr]::Zero, 0, 1, [ref]$ptr, [ref]$count)) { return }
    try {
        $size = [Runtime.InteropServices.Marshal]::SizeOf([type][Deskside.Wts+SessionInfo])
        for ($i = 0; $i -lt $count; $i++) {
            $si = [Runtime.InteropServices.Marshal]::PtrToStructure([IntPtr]($ptr.ToInt64() + $i * $size), [type][Deskside.Wts+SessionInfo])
            if ($si.State -ne 0) { continue }   # WTSActive only
            $buf = [IntPtr]::Zero; $bytes = 0
            $hasUser = $false
            if ([Deskside.Wts]::WTSQuerySessionInformation([IntPtr]::Zero, $si.SessionId, 5, [ref]$buf, [ref]$bytes)) {
                $hasUser = [bool][Runtime.InteropServices.Marshal]::PtrToStringUni($buf)
                [Deskside.Wts]::WTSFreeMemory($buf)
            }
            if ($hasUser) { $ids += $si.SessionId }
        }
    } finally { [Deskside.Wts]::WTSFreeMemory($ptr) }
    return $ids
}

function Send-SessionNotice {
    <#
    .SYNOPSIS
        Shows a message box in every signed-in session (WTSSendMessage), without waiting for anyone to answer.
    .OUTPUTS
        signedIn (how many sessions had someone signed in) and shown (how many took the message).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Text,
        [int]$TimeoutSeconds = 300
    )
    Initialize-WtsType
    $sessions = @(Get-SignedInSession)
    $shown = 0
    foreach ($s in $sessions) {
        $resp = 0
        # MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND | MB_TOPMOST
        $style = 0x00000040 -bor 0x00010000 -bor 0x00040000
        if ([Deskside.Wts]::WTSSendMessage([IntPtr]::Zero, $s, $Title, $Title.Length * 2, $Text, $Text.Length * 2, $style, $TimeoutSeconds, [ref]$resp, $false)) { $shown++ }
    }
    return [pscustomobject]@{ signedIn = $sessions.Count; shown = $shown }
}

function Get-HelperNoticeText {
    <# The words the person at the PC sees when the helper connects over SSH and when he leaves. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Start', 'End')][string]$Phase,
        [ValidateSet('diagnose', 'onboard', 'settings', 'undo', 'remote', 'shell', 'task')][string]$Activity = 'task',
        [string]$HelperName = 'Your helper'
    )
    if ($Phase -eq 'End') {
        return [pscustomobject]@{ Title = "deskside - $HelperName has finished"; Text = "$HelperName has finished and is no longer connected to this PC." }
    }
    $what = switch ($Activity) {
        'diagnose' { 'to run a health check. It only reads settings and changes nothing.' }
        'onboard' { 'to install the apps and settings you agreed to. Every change is recorded and can be undone.' }
        'settings' { 'to apply the settings you agreed to. Every change is recorded and can be undone.' }
        'undo' { 'to undo an earlier change.' }
        'remote' { 'to update or remove remote help on this PC.' }
        'shell' { 'to work on this PC from his computer, using a command line.' }
        default { 'to run a deskside task.' }
    }
    return [pscustomobject]@{
        Title = "deskside - $HelperName is connected"
        Text  = "$HelperName is connected to this PC from his computer $what You don't need to do anything; you can close this message. Another one will say when he has finished."
    }
}

function Get-NoticePath {
    [CmdletBinding()]
    param()
    return (Join-Path (Get-DesksideDataRoot) 'notice.json')
}

function Send-HelperNotice {
    <#
    .SYNOPSIS
        Tells whoever is signed in that the helper has connected (Start) or finished (End), and records it.
    .DESCRIPTION
        Writes notice.json beside the data (phase, time, counts; no names). Windows shows a session's messages one at a
        time, so a second waits until the first is closed; each closes itself after 5 minutes, so the End message waits
        at most that long and an empty PC never collects a queue.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Start', 'End')][string]$Phase,
        [string]$Activity = 'task',
        [string]$HelperName = 'Your helper',
        [string]$SentBy = 'console'
    )
    $t = Get-HelperNoticeText -Phase $Phase -Activity $Activity -HelperName $HelperName
    $timeout = 300
    $r = Send-SessionNotice -Title $t.Title -Text $t.Text -TimeoutSeconds $timeout
    $rec = [ordered]@{ schema = 'deskside.notice/v1'; phase = $Phase; activity = $Activity; sentBy = $SentBy; sentUtc = (Get-Date).ToUniversalTime().ToString('o'); signedIn = $r.signedIn; shown = $r.shown }
    Initialize-DataRoot | Out-Null
    ($rec | ConvertTo-Json) | Set-Content -LiteralPath (Get-NoticePath) -Encoding UTF8 -WhatIf:$false
    return [pscustomobject]$rec
}

function Test-DesksideSshRun {
    <# True when this process runs under the helper's SSH sign-in (sshd's SSH_CONNECTION, or the console's marker). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ([bool]$env:SSH_CONNECTION -or $env:DESKSIDE_VIA -eq 'ssh')
}

function ConvertTo-NoticeActivity {
    <# Maps a run kind or a script path to the notice's activity word. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    switch -Regex ($Name) {
        'diagnose' { return 'diagnose' }
        'undo' { return 'undo' }
        'settings|baseline' { return 'settings' }
        'onboard|install|apps|profile|winget|consent|changelist' { return 'onboard' }
        'remote|mesh|ssh|help' { return 'remote' }
    }
    return 'task'
}

function Get-RunNotice {
    <#
    .SYNOPSIS
        For a run over the helper's SSH sign-in: the Start notice the console sent in the last 10 minutes, or one sent
        now. Returns $null for every other run (the scheduled check, a person at the PC).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Kind)
    if (-not (Test-DesksideSshRun)) { return $null }
    $path = Get-NoticePath
    $n = $null
    if (Test-Path -LiteralPath $path) {
        try { $n = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Verbose "notice.json unreadable: $($_.Exception.Message)" }
    }
    # The console announced this visit itself (DESKSIDE_ANNOUNCED): stamp its Start whatever its age and never send
    # another, so a long run's later child runs can't say "has finished" while the helper is still connected.
    if ($env:DESKSIDE_ANNOUNCED -eq '1') {
        if ($n -and $n.phase -eq 'Start') { return $n }
        return $null
    }
    if ($n -and $n.phase -eq 'Start') {
        $age = (Get-Date).ToUniversalTime() - ([datetime]::Parse($n.sentUtc)).ToUniversalTime()
        if ($age.TotalMinutes -lt 10) { return $n }
    }
    if ($env:DESKSIDE_NOTICE_SENT) { return $null }
    $env:DESKSIDE_NOTICE_SENT = '1'
    $helper = 'Your helper'
    if ($env:DESKSIDE_HELPER) { $helper = $env:DESKSIDE_HELPER }
    $sent = Send-HelperNotice -Phase Start -Activity (ConvertTo-NoticeActivity -Name $Kind) -HelperName $helper -SentBy 'run'
    $sent | Add-Member -NotePropertyName sentNow -NotePropertyValue $true
    return $sent
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
    $run = [pscustomobject]@{
        Id         = $id
        Kind       = $Kind
        Folder     = $folder
        Started    = $started
        Transcript = $transcript
        Findings   = New-Object System.Collections.Generic.List[object]
        Changes    = New-Object System.Collections.Generic.List[object]
        Errors     = New-Object System.Collections.Generic.List[object]
        Data       = [ordered]@{}
        NoticeSent = $false
    }
    # A run over the helper's SSH sign-in tells the person at the PC; the scheduled check and local runs don't.
    if (Test-DesksideSshRun) {
        $n = $null
        try { $n = Get-RunNotice -Kind $Kind } catch { $run.Errors.Add([pscustomobject]@{ section = 'notice'; message = $_.Exception.Message }) }
        if ($n) {
            $run.Data['notice'] = [ordered]@{ sentBy = $n.sentBy; signedIn = $n.signedIn; shown = $n.shown }
            $run.NoticeSent = [bool]($n.PSObject.Properties['sentNow'] -and $n.sentNow)
            if ([int]$n.signedIn -eq 0) { Add-Finding -Run $run -Id 'notice.nobody' -Rank 'Info' -Text 'No one was signed in at the PC to see the notice that the helper was connected.' }
        } else {
            $run.Data['notice'] = [ordered]@{ sentBy = 'none'; signedIn = $null; shown = $null }
        }
    }
    return $run
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
    if ($Run.PSObject.Properties['NoticeSent'] -and $Run.NoticeSent) {
        $helper = 'Your helper'
        if ($env:DESKSIDE_HELPER) { $helper = $env:DESKSIDE_HELPER }
        try { Send-HelperNotice -Phase End -Activity (ConvertTo-NoticeActivity -Name $Run.Kind) -HelperName $helper -SentBy 'run' | Out-Null } catch { Write-Verbose "End notice not sent: $($_.Exception.Message)" }
    }
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

function ConvertTo-MeshNodeId {
    <# MeshAgent.exe -nodeid prints the id as hex; MeshCentral names the device node//<base64 with / as $ and + as @>. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{96}$')][string]$Hex)
    $bytes = New-Object byte[] 48
    for ($i = 0; $i -lt 48; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return 'node//' + [Convert]::ToBase64String($bytes).Replace('/', '$').Replace('+', '@')
}

function Get-MeshNodeId {
    <# The installed agent's MeshCentral node id, or $null when there is no agent or it has no id yet. #>
    [CmdletBinding()]
    param([string]$AgentPath = (Join-Path $env:ProgramFiles 'Mesh Agent\MeshAgent.exe'))
    if (-not (Test-Path -LiteralPath $AgentPath)) { return $null }
    $out = (& $AgentPath -nodeid 2>$null | Out-String).Trim()
    if ($out -match '^[0-9A-Fa-f]{96}$') { return ConvertTo-MeshNodeId -Hex $out }
    return $null
}

function Get-MeshAgentSetting {
    <#
    .SYNOPSIS
        The server address and device group of the installed agent, from its own MeshAgent.msh (no copy is kept).
    .OUTPUTS
        ServerUrl (https://host:port) and GroupId (the group's id as the server's download links take it), or $null.
    #>
    [CmdletBinding()]
    param([string]$MshPath = (Join-Path $env:ProgramFiles 'Mesh Agent\MeshAgent.msh'))
    if (-not (Test-Path -LiteralPath $MshPath)) { return $null }
    $server = $null; $meshHex = $null
    foreach ($line in Get-Content -LiteralPath $MshPath) {
        if ($line -match '^MeshServer=wss://([^/]+)/') { $server = 'https://' + $Matches[1] }
        elseif ($line -match '^MeshID=0x([0-9A-Fa-f]{96})\s*$') { $meshHex = $Matches[1] }
    }
    if (-not $server -or -not $meshHex) { return $null }
    $bytes = New-Object byte[] 48
    for ($i = 0; $i -lt 48; $i++) { $bytes[$i] = [Convert]::ToByte($meshHex.Substring($i * 2, 2), 16) }
    $group = [Convert]::ToBase64String($bytes).Replace('/', '$').Replace('+', '@')
    return [pscustomobject]@{ ServerUrl = $server; GroupId = $group }
}

function Get-HelpButtonPath {
    <# Where the help button lives: the program, its shortcuts and its refresh task. #>
    [CmdletBinding()]
    param([string]$HelperName = 'your helper')
    $folder = Join-Path $env:ProgramFiles 'deskside\Help'
    $programs = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $label = "Ask $HelperName for help.lnk"
    return [pscustomobject]@{
        Folder      = $folder
        Exe         = Join-Path $folder 'MeshCentralAssistant.exe'
        Startup     = Join-Path $programs 'StartUp\deskside help button.lnk'
        Desktop     = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) $label
        StartMenu   = Join-Path $programs $label
        TaskPath    = '\deskside\'
        TaskName    = 'help-refresh'
        StateFile   = Join-Path (Get-DesksideDataRoot) 'help-refresh.json'
        ProcessName = 'MeshCentralAssistant'
    }
}

function Save-HelpButtonFile {
    <#
    .SYNOPSIS
        Downloads MeshCentral Assistant from the helper's own server in its monitor-only form and puts it in place
        when it differs from the copy there.
    .DESCRIPTION
        /meshagents?id=10006&meshid=<group>&ac=4 is MeshCentral's "system tray, monitor only" Assistant: it carries no
        server details and attaches to the installed agent, so the agent's (patched) relay code stays the only one.
        A running copy keeps running from the renamed old file; the old file goes on the next refresh.
    .OUTPUTS
        result (installed, updated, current), sha256, signature.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidatePattern('^https://')][string]$ServerUrl, [Parameter(Mandatory)][string]$GroupId)
    $p = Get-HelpButtonPath
    Get-ChildItem -LiteralPath $p.Folder -Filter '*.old' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $tmp = Join-Path $env:TEMP ('deskside-help-' + [guid]::NewGuid() + '.exe')
    $url = $ServerUrl.TrimEnd('/') + '/meshagents?id=10006&meshid=' + [uri]::EscapeDataString($GroupId) + '&ac=4'
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
        $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($tmp))
        if ($text -notmatch 'AutoConnect=4') { throw 'The server did not send the monitor-only Assistant.' }
        if ($text.Contains('MeshServer=')) { throw 'The Assistant the server sent carries its own server settings; refusing it.' }
        $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
        $sig = [string](Get-AuthenticodeSignature -FilePath $tmp).Status
        $result = 'current'
        $have = $null
        if (Test-Path -LiteralPath $p.Exe) { $have = (Get-FileHash -LiteralPath $p.Exe -Algorithm SHA256).Hash }
        if ($have -ne $hash -and $PSCmdlet.ShouldProcess($p.Exe, 'Put MeshCentral Assistant in place')) {
            New-Item -ItemType Directory -Force -Path $p.Folder | Out-Null
            if ($have) { Move-Item -LiteralPath $p.Exe -Destination ($p.Exe + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.old') -Force; $result = 'updated' }
            else { $result = 'installed' }
            Move-Item -LiteralPath $tmp -Destination $p.Exe -Force
        }
        return [pscustomobject]@{ result = $result; sha256 = $hash; signature = $sig }
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
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
function Get-SmartAppControlState {
    <#
    .SYNOPSIS
        Smart App Control's state: On, Eval, Off or Unknown.
    .DESCRIPTION
        Defender's status first (SmartAppControlState), then the code-integrity policy value Windows keeps it in
        (HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy, VerifiedAndReputablePolicyState: 0 Off, 1 On, 2 Eval).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $state = $null
    try { $state = [string](Get-MpComputerStatus -ErrorAction Stop).SmartAppControlState } catch { $state = $null }
    if ($state -in 'On', 'Off', 'Eval') { return $state }
    try {
        $v = [int](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction Stop).VerifiedAndReputablePolicyState
        switch ($v) { 0 { return 'Off' } 1 { return 'On' } 2 { return 'Eval' } }
    } catch { $null = $_ }
    return 'Unknown'
}

function Test-AgentBlocked {
    <#
    .SYNOPSIS
        True when Smart App Control would block the agent: it is on and the agent's signature isn't one Windows trusts.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$State, [Parameter(Mandatory)][AllowEmptyString()][string]$Signature)
    return ($State -eq 'On' -and $Signature -ne 'Valid')
}

function Get-AgentBlockedText {
    <# The plain message shown when Smart App Control would block the agent. #>
    [CmdletBinding()]
    param([string]$HelperName = 'your helper')
    return ('Smart App Control is on and the agent is not yet signed with a certificate Windows trusts, so Windows would block it. Nothing was changed. Run this again once ' + $HelperName + ' says the agent is signed.')
}

function Get-ProfileFolder {
    <# Every local profile folder (C:\Users\<name>) that isn't a special account. #>
    [CmdletBinding()]
    param()
    $list = @()
    foreach ($p in @(Get-CimInstance Win32_UserProfile -Filter 'Special = False' -ErrorAction SilentlyContinue)) {
        if ($p.LocalPath -and (Test-Path -LiteralPath $p.LocalPath)) { $list += $p.LocalPath }
    }
    return $list
}

function Remove-EnrollTrace {
    <#
    .SYNOPSIS
        Removes what an earlier enroll attempt can leave behind on this PC and returns counts only.
    .DESCRIPTION
        - Temp folders a failed agent download left: deskside-mesh-* and deskside-check-* in each profile's Temp and
          Windows' own Temp.
        - Lines in each profile's PowerShell history (PSReadLine's *_history.txt) that ran Install-MeshAgent or carry a
          device group id (-GroupId, meshid=, or the id itself), since a hand-typed one holds the group id.
        - Defender's allow for detection 489403 (PUA:Win32/MeshCenAgent), a rejected suggestion, unless deskside's own
          record says deskside placed it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$GroupId, [string[]]$ProfileFolder = @(Get-ProfileFolder), [string]$SystemTemp = (Join-Path $env:SystemRoot 'Temp'))
    $result = [ordered]@{ tempFolders = 0; historyLines = 0; historyFiles = 0; defenderAllow = 'none' }
    $temps = @($SystemTemp) + @($ProfileFolder | ForEach-Object { Join-Path $_ 'AppData\Local\Temp' })
    foreach ($t in $temps) {
        foreach ($f in 'deskside-mesh-*', 'deskside-check-*') {
            foreach ($d in @(Get-ChildItem -LiteralPath $t -Directory -Filter $f -Force -ErrorAction SilentlyContinue)) {
                if ($PSCmdlet.ShouldProcess($d.Name, 'Remove leftover agent download')) {
                    Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    if (-not (Test-Path -LiteralPath $d.FullName)) { $result.tempFolders++ }
                }
            }
        }
    }
    $patterns = @('Install-MeshAgent', '-GroupId', 'meshid=')
    foreach ($p in $ProfileFolder) {
        $dir = Join-Path $p 'AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine'
        foreach ($h in @(Get-ChildItem -LiteralPath $dir -Filter '*_history.txt' -File -Force -ErrorAction SilentlyContinue)) {
            $lines = @([IO.File]::ReadAllLines($h.FullName))
            $keep = New-Object System.Collections.Generic.List[string]
            $drop = 0
            foreach ($l in $lines) {
                $hit = $false
                foreach ($pat in $patterns) { if ($l.IndexOf($pat, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true } }
                if ($GroupId -and $l.Contains($GroupId)) { $hit = $true }
                if ($hit) { $drop++ } else { $keep.Add($l) }
            }
            if ($drop -gt 0 -and $PSCmdlet.ShouldProcess($h.Name, "Remove $drop history line(s)")) {
                [IO.File]::WriteAllLines($h.FullName, $keep.ToArray(), (New-Object Text.UTF8Encoding($false)))
                $result.historyLines += $drop
                $result.historyFiles++
            }
        }
    }
    try {
        $ids = @((Get-MpPreference -ErrorAction Stop).ThreatIDDefaultAction_Ids)
        if ($ids -contains 489403) {
            $ours = Test-Path -LiteralPath (Join-Path (Get-DesksideDataRoot) 'defender-allow.json')
            if ($ours) { $result.defenderAllow = 'kept (deskside placed it)' }
            elseif ($PSCmdlet.ShouldProcess('Defender allow for detection 489403', 'Remove')) {
                Remove-MpPreference -ThreatIDDefaultAction_Ids 489403 -ErrorAction Stop
                $result.defenderAllow = 'removed'
            }
        }
    } catch { $result.defenderAllow = 'could not read Defender' }
    return [pscustomobject]$result
}

Export-ModuleMember -Function *
