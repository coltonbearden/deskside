#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only health check of a Windows PC, with a plain-English summary.

.DESCRIPTION
    Reads Windows' version and support dates, updates, antivirus, firewall, SmartScreen, drive encryption, disk health
    and space, battery, memory and processor load, start-up apps and scheduled tasks, devices with driver problems,
    crashes, backups, the account type, installed apps, junk and trialware, and remote-access tools.

    It changes nothing. It writes record.json (schema deskside.record/v1) and summary.md to the PC's deskside data
    folder (administrators only), or to -OutputDirectory. On screen it prints counts only.

.PARAMETER OutputDirectory
    Where to write the record. Default: %ProgramData%\deskside\data\runs\<run id>.

.PARAMETER ScreenOnly
    Write nothing to disk; print the findings' sentences instead. Used on work or school PCs.

.PARAMETER Quick
    Skip the Windows Update search for pending updates (it can take minutes).

.PARAMETER PassThru
    Return the record and summary paths (used by Start-Onboarding.ps1).

.PARAMETER EmitJson
    Print one line of compact JSON (findings and the health-relevant values, no app lists or names) for the health
    sweep, which reads it through MeshCentral's run-command. Nothing is kept on the PC.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\diagnose\Invoke-Diagnose.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Quick', Justification = 'Used inside the windowsUpdate section script block.')]
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$ScreenOnly,
    [switch]$Quick,
    [switch]$PassThru,
    [switch]$EmitJson
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
$checks = (Read-DesksideCatalog -Name 'checks.json').checks

function Add-Check {
    param($Run, [string]$Id, [object[]]$Values, $Detail)
    $c = $checks.$Id
    if ($null -eq $c) { throw "Unknown check id $Id" }
    $text = $c.text
    if ($Values) { $text = [string]::Format($text, $Values) }
    Add-Finding -Run $Run -Id $Id -Rank $c.rank -Text $text -Detail $Detail
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $p.$Name
    } catch { return $null }
}

function Get-RegisteredDesktopApp {
    <# Desktop apps from the Uninstall keys: HKLM (64- and 32-bit views) and each loaded user hive. Adapted from winscript. #>
    $apps = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $views = @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)
    if (-not [Environment]::Is64BitOperatingSystem) { $views = @([Microsoft.Win32.RegistryView]::Default) }
    $sources = New-Object System.Collections.Generic.List[object]
    foreach ($v in $views) { $sources.Add(@{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = $v; Sub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine' }) }
    try {
        $users = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, [Microsoft.Win32.RegistryView]::Default)
        foreach ($sid in $users.GetSubKeyNames()) {
            if ($sid -match '^S-1-(5-21|12-1)-[\d-]+$') {
                $sources.Add(@{ Hive = [Microsoft.Win32.RegistryHive]::Users; View = [Microsoft.Win32.RegistryView]::Default; Sub = "$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; Scope = 'User' })
            }
        }
        $users.Dispose()
    } catch { Write-Verbose 'Could not list user hives.' }
    foreach ($s in $sources) {
        $base = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($s.Hive, $s.View)
            $key = $base.OpenSubKey($s.Sub)
            if ($null -eq $key) { continue }
            foreach ($name in $key.GetSubKeyNames()) {
                $sub = $key.OpenSubKey($name)
                if ($null -eq $sub) { continue }
                $display = $sub.GetValue('DisplayName')
                $isComponent = $sub.GetValue('SystemComponent')
                $parent = $sub.GetValue('ParentKeyName')
                if ($display -and $isComponent -ne 1 -and -not $parent) {
                    $ver = [string]$sub.GetValue('DisplayVersion')
                    $k = ($display + '|' + $ver).ToLowerInvariant()
                    if (-not $seen.ContainsKey($k)) {
                        $seen[$k] = $true
                        $apps.Add([pscustomobject]@{
                            name      = [string]$display
                            version   = $ver
                            publisher = [string]$sub.GetValue('Publisher')
                            scope     = $s.Scope
                            quietUninstall = [bool]$sub.GetValue('QuietUninstallString')
                        })
                    }
                }
                $sub.Close()
            }
            $key.Close()
        } catch { Write-Verbose "Uninstall key read failed: $($_.Exception.Message)" }
        finally { if ($base) { $base.Dispose() } }
    }
    return $apps
}

function Get-StoreApp {
    try {
        return @(Get-AppxPackage -ErrorAction Stop | Where-Object { -not $_.IsFramework -and $_.SignatureKind -eq 'Store' } |
            ForEach-Object { [pscustomobject]@{ name = $_.Name; version = $_.Version.ToString() } })
    } catch { return @() }
}

$managed = Test-ManagedDevice
if ($ScreenOnly -or $EmitJson) { $run = New-DesksideRun -Kind 'diagnose' -OutputDirectory (Join-Path ([IO.Path]::GetTempPath()) ('deskside-' + [guid]::NewGuid())) -NoTranscript }
else { $run = New-DesksideRun -Kind 'diagnose' -OutputDirectory $OutputDirectory }
$isAdmin = Test-IsAdministrator
$run.Data['managed'] = [ordered]@{ isManaged = $managed.IsManaged; reasons = $managed.Reasons }
if ($managed.IsManaged) { Add-Check $run 'run.managed' }
if (-not $isAdmin) { Add-Check $run 'run.not-elevated' }

# --- Windows version and support ----------------------------------------------------------------------------------
Invoke-Section -Run $run -Name 'os' -ScriptBlock {
    $os = Get-CimInstance Win32_OperatingSystem
    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int](Get-RegValue $cv 'CurrentBuild')
    $display = Get-RegValue $cv 'DisplayVersion'
    $edition = Get-RegValue $cv 'EditionID'
    $life = Read-DesksideCatalog -Name 'lifecycle.json'
    $today = (Get-Date).Date
    $readOn = [datetime]::ParseExact($life.readOn, 'yyyy-MM-dd', $null)
    if (($today - $readOn).TotalDays -gt $life.staleAfterDays) { Add-Check $run 'os.lifecycle-stale' @($life.readOn) }
    $family = 'Windows 10'
    if ($build -ge 22000) { $family = 'Windows 11' }
    $endDate = $null
    if ($family -eq 'Windows 11') {
        $row = $life.windows11HomePro | Where-Object { $_.version -eq $display } | Select-Object -First 1
        if ($row) {
            $endDate = [datetime]::ParseExact($row.end, 'yyyy-MM-dd', $null)
            $label = "11 $display"
            if ($endDate -le $today) { Add-Check $run 'os.unsupported' @($label, $endDate.ToString('MMMM d, yyyy')) }
            elseif (($endDate - $today).TotalDays -le 120) { Add-Check $run 'os.ending-soon' @($label, $endDate.ToString('MMMM d, yyyy')) }
            else { Add-Check $run 'os.supported' @($label, $endDate.ToString('MMMM d, yyyy')) }
        }
    } else {
        $esuEnd = [datetime]::ParseExact($life.windows10.consumerEsuEnd, 'yyyy-MM-dd', $null)
        Add-Check $run 'os.win10-esu' @($esuEnd.ToString('MMMM d, yyyy'))
        $tpm = 'unknown'; $sb = 'unknown'
        try { $t = Get-CimInstance -Namespace 'root\cimv2\security\microsofttpm' -ClassName Win32_Tpm -ErrorAction Stop; if ($t) { $tpm = ([string]$t.SpecVersion).Split(',')[0].Trim() } else { $tpm = 'none' } } catch { $tpm = 'unknown' }
        try { if (Confirm-SecureBootUEFI -ErrorAction Stop) { $sb = 'on' } else { $sb = 'off' } } catch { $sb = 'unsupported or unknown' }
        if ($tpm -like '2*' -and $sb -eq 'on') { Add-Check $run 'os.win11-capable' @($tpm, $sb, $esuEnd.ToString('MMMM yyyy')) }
        else { Add-Check $run 'os.win11-not-capable' @($tpm, $sb, $esuEnd.ToString('MMMM yyyy')) }
    }
    [ordered]@{
        family = $family; caption = $os.Caption; edition = $edition; displayVersion = $display; build = $build
        installDate = $os.InstallDate; lastBoot = $os.LastBootUpTime; supportEnds = $(if ($endDate) { $endDate.ToString('yyyy-MM-dd') } else { $null })
        architecture = $os.OSArchitecture
    }
}

# --- Windows Update -----------------------------------------------------------------------------------------------
Invoke-Section -Run $run -Name 'windowsUpdate' -ScriptBlock {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $total = $searcher.GetTotalHistoryCount()
    $failed = 0; $lastSuccess = $null
    if ($total -gt 0) {
        $since = (Get-Date).AddDays(-30)
        foreach ($h in $searcher.QueryHistory(0, [Math]::Min($total, 200))) {
            if ($h.Operation -ne 1) { continue }
            if ($h.ResultCode -eq 2 -or $h.ResultCode -eq 3) { if ($null -eq $lastSuccess -or $h.Date -gt $lastSuccess) { $lastSuccess = $h.Date } }
            elseif (($h.ResultCode -eq 4 -or $h.ResultCode -eq 5) -and $h.Date -gt $since) { $failed++ }
        }
    }
    $pending = $null
    if (-not $Quick) {
        try { $pending = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'").Updates.Count } catch { $pending = $null }
    }
    $reboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    if ($pending -gt 0) { Add-Check $run 'update.pending' @($pending) }
    if ($failed -gt 0) { Add-Check $run 'update.failed' @($failed) }
    if ($lastSuccess -and ((Get-Date) - $lastSuccess).TotalDays -gt 45) { Add-Check $run 'update.stale' @($lastSuccess.ToString('MMMM d, yyyy')) }
    if ($reboot) { Add-Check $run 'update.reboot' }
    $lastSuccessText = $null
    if ($lastSuccess) { $lastSuccessText = $lastSuccess.ToUniversalTime().ToString('o') }
    [ordered]@{ historyCount = $total; failedLast30Days = $failed; lastSuccessUtc = $lastSuccessText; pending = $pending; rebootRequired = $reboot }
}

# --- Antivirus, firewall, SmartScreen -----------------------------------------------------------------------------
Invoke-Section -Run $run -Name 'security' -ScriptBlock {
    $result = [ordered]@{}
    $products = @()
    try { $products = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop) } catch { $products = @() }
    $active = @($products | Where-Object { (([int]$_.productState -shr 12) -band 0xF) -eq 1 })
    $third = @($products | Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' })
    $result.antivirusProducts = @($products | ForEach-Object { [ordered]@{ name = $_.displayName; active = ((([int]$_.productState -shr 12) -band 0xF) -eq 1) } })
    if ($third.Count -gt 0) { Add-Check $run 'av.thirdparty' @($third.Count) }
    $defender = $null
    try { $defender = Get-MpComputerStatus -ErrorAction Stop } catch { $defender = $null }
    if ($defender) {
        $result.defender = [ordered]@{ service = $defender.AMServiceEnabled; realtime = $defender.RealTimeProtectionEnabled; signatureAgeDays = $defender.AntivirusSignatureAge }
        if ($defender.AMServiceEnabled -and -not $defender.RealTimeProtectionEnabled -and $third.Count -eq 0) { Add-Check $run 'av.realtime-off' }
        if ($defender.AMServiceEnabled -and $defender.AntivirusSignatureAge -gt 7) { Add-Check $run 'av.signatures-old' @($defender.AntivirusSignatureAge) }
        try {
            $pref = Get-MpPreference -ErrorAction Stop
            $result.defender.pua = [int]$pref.PUAProtection
            if ($defender.AMServiceEnabled -and [int]$pref.PUAProtection -ne 1) { Add-Check $run 'pua.off' }
        } catch { $result.defender.pua = $null }
    }
    if ($products.Count -gt 0 -and $active.Count -eq 0) { Add-Check $run 'av.off' }
    elseif ($products.Count -eq 0 -and $defender -and -not $defender.AMServiceEnabled) { Add-Check $run 'av.off' }
    try {
        $fw = @(Get-NetFirewallProfile -ErrorAction Stop)
        $off = @($fw | Where-Object { -not $_.Enabled })
        $result.firewall = @($fw | ForEach-Object { [ordered]@{ profile = $_.Name; enabled = [bool]$_.Enabled } })
        if ($off.Count -gt 0) { Add-Check $run 'fw.off' @($off.Count) }
    } catch { $result.firewall = $null }
    $ss = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled'
    $ssPolicy = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen'
    $result.smartScreen = [ordered]@{ value = $ss; policy = $ssPolicy }
    if ($ssPolicy -eq 0) { Add-Check $run 'smartscreen.policy-off' }
    elseif ($ss -eq 'Off') { Add-Check $run 'smartscreen.off' }
    $result
}

# --- Drive encryption ---------------------------------------------------------------------------------------------
Invoke-Section -Run $run -Name 'encryption' -ScriptBlock {
    $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    $types = @($vol.KeyProtector | ForEach-Object { [string]$_.KeyProtectorType })
    $on = ([string]$vol.ProtectionStatus -eq 'On') -or ([string]$vol.VolumeStatus -ne 'FullyDecrypted')
    if (-not $on) { Add-Check $run 'crypt.off' }
    elseif ($types -notcontains 'RecoveryPassword') { Add-Check $run 'crypt.no-recovery' }
    else { Add-Check $run 'crypt.check-key' }
    [ordered]@{ protection = [string]$vol.ProtectionStatus; volumeStatus = [string]$vol.VolumeStatus; method = [string]$vol.EncryptionMethod; protectorTypes = $types }
}

# --- Disks --------------------------------------------------------------------------------------------------------
Invoke-Section -Run $run -Name 'disks' -ScriptBlock {
    $physical = @()
    try {
        foreach ($d in Get-PhysicalDisk -ErrorAction Stop) {
            $wear = $null
            try { $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop; $wear = $rc.Wear } catch { $wear = $null }
            $physical += [ordered]@{ mediaType = [string]$d.MediaType; bus = [string]$d.BusType; sizeGB = [math]::Round($d.Size / 1GB); health = [string]$d.HealthStatus; operational = ([string[]]$d.OperationalStatus) -join ','; wearPercent = $wear }
            if ([string]$d.HealthStatus -ne 'Healthy' -and [string]$d.HealthStatus) { Add-Check $run 'disk.unhealthy' @([string]$d.HealthStatus) }
            if ($wear -ge 80) { Add-Check $run 'disk.wear' @($wear) }
        }
    } catch { Write-Verbose 'Get-PhysicalDisk unavailable.' }
    $logical = @()
    foreach ($l in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
        $freeGB = [math]::Round($l.FreeSpace / 1GB, 1)
        $pct = 0
        if ($l.Size -gt 0) { $pct = [math]::Round(100 * $l.FreeSpace / $l.Size) }
        $logical += [ordered]@{ drive = $l.DeviceID; sizeGB = [math]::Round($l.Size / 1GB); freeGB = $freeGB; freePercent = $pct }
        if ($l.DeviceID -eq $env:SystemDrive) {
            if ($pct -lt 5 -or $freeGB -lt 5) { Add-Check $run 'disk.full' @($freeGB) }
            elseif ($pct -lt 15 -or $freeGB -lt 20) { Add-Check $run 'disk.low' @($freeGB) }
        }
    }
    [ordered]@{ physical = $physical; volumes = $logical }
}

# --- Battery ------------------------------------------------------------------------------------------------------
Invoke-Section -Run $run -Name 'battery' -ScriptBlock {
    $b = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    if ($b.Count -eq 0) { return [ordered]@{ present = $false } }
    $design = $null; $full = $null
    try { $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity } catch { $design = $null }
    try { $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity } catch { $full = $null }
    $health = $null
    if ($design -gt 0 -and $full -gt 0) {
        $health = [math]::Round(100 * $full / $design)
        if ($health -lt 60) { Add-Check $run 'battery.worn' @($health) }
        elseif ($health -lt 80) { Add-Check $run 'battery.tired' @($health) }
    }
    [ordered]@{ present = $true; designedCapacity = $design; fullChargeCapacity = $full; healthPercent = $health; chargePercent = $b[0].EstimatedChargeRemaining }
}

# --- Memory and processor -----------------------------------------------------------------------------------------
Invoke-Section -Run $run -Name 'performance' -ScriptBlock {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $usedPct = [math]::Round(100 * (1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)))
    $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    if ($null -eq $cpu) { $cpu = 0 }
    $cpu = [math]::Round($cpu)
    if ($usedPct -ge 90) { Add-Check $run 'perf.memory-high' @($usedPct) }
    if ($totalGB -lt 7.5) { Add-Check $run 'perf.memory-small' @([math]::Round($totalGB)) }
    if ($cpu -ge 80) { Add-Check $run 'perf.cpu-high' @($cpu) }
    $topMem = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object { [ordered]@{ process = $_.ProcessName; memoryMB = [math]::Round($_.WorkingSet64 / 1MB) } })
    $topCpu = @(Get-Process | Where-Object { $_.CPU } | Sort-Object CPU -Descending | Select-Object -First 5 | ForEach-Object { [ordered]@{ process = $_.ProcessName; cpuSeconds = [math]::Round($_.CPU) } })
    $proc = Get-CimInstance Win32_Processor | Select-Object -First 1
    [ordered]@{ memoryGB = $totalGB; memoryUsedPercent = $usedPct; cpuLoadPercent = $cpu; cpu = $proc.Name; cores = $proc.NumberOfCores; topMemory = $topMem; topCpu = $topCpu }
}

# --- Start-up apps and scheduled tasks ----------------------------------------------------------------------------
Invoke-Section -Run $run -Name 'startup' -ScriptBlock {
    $items = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name = $_.Name; location = $_.Location } })
    if ($items.Count -gt 12) { Add-Check $run 'startup.many' @($items.Count) }
    $tasks = @()
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' } |
            ForEach-Object { [ordered]@{ path = $_.TaskPath; name = $_.TaskName; state = [string]$_.State } })
    } catch { $tasks = @() }
    if ($tasks.Count -gt 0) { Add-Check $run 'tasks.thirdparty' @($tasks.Count) }
    [ordered]@{ startupApps = $items; thirdPartyTasks = $tasks }
}

# --- Devices ------------------------------------------------------------------------------------------------------
Invoke-Section -Run $run -Name 'devices' -ScriptBlock {
    $bad = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue |
        ForEach-Object { [ordered]@{ name = $_.Name; class = $_.PNPClass; errorCode = $_.ConfigManagerErrorCode } })
    if ($bad.Count -gt 0) { Add-Check $run 'devices.errors' @($bad.Count) }
    [ordered]@{ withErrors = $bad }
}

# --- Crashes and critical errors ----------------------------------------------------------------------------------
Invoke-Section -Run $run -Name 'events' -ScriptBlock {
    $since = (Get-Date).AddDays(-30)
    $count = {
        param($filter)
        try { @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop).Count } catch { 0 }
    }
    $kernelPower = & $count @{ LogName = 'System'; Id = 41; StartTime = $since }
    $bugcheck = & $count @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since }
    $appCrash = & $count @{ LogName = 'Application'; Id = 1000; StartTime = $since }
    $critical = & $count @{ LogName = 'System'; Level = 1; StartTime = $since }
    $crashes = $kernelPower + $bugcheck
    if ($crashes -gt 0) { Add-Check $run 'events.crashes' @($crashes) }
    if ($appCrash -ge 10) { Add-Check $run 'events.app-crashes' @($appCrash) }
    if ($critical -gt 0) { Add-Check $run 'events.critical' @($critical) }
    [ordered]@{ unexpectedShutdowns = $kernelPower; bugChecks = $bugcheck; appCrashes = $appCrash; critical = $critical }
}

# --- Backups ------------------------------------------------------------------------------------------------------
Invoke-Section -Run $run -Name 'backups' -ScriptBlock {
    $shell = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $odRoots = @()
    foreach ($v in @('OneDrive', 'OneDriveConsumer', 'OneDriveCommercial')) { $p = [Environment]::GetEnvironmentVariable($v); if ($p) { $odRoots += $p } }
    $folders = [ordered]@{ Desktop = 'Desktop'; Documents = 'Personal'; Pictures = 'My Pictures' }
    $backedUp = @()
    foreach ($k in $folders.Keys) {
        $val = [Environment]::ExpandEnvironmentVariables([string](Get-RegValue $shell $folders[$k]))
        foreach ($r in $odRoots) { if ($val -and $val.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { $backedUp += $k; break } }
    }
    $fileHistory = Test-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\FileHistory\Configuration\Config1.xml')
    $points = $null; $newest = $null
    try {
        $rp = @(Get-CimInstance -Namespace root\default -ClassName SystemRestore -ErrorAction Stop)
        $points = $rp.Count
        if ($rp.Count -gt 0) { $newest = ($rp | ForEach-Object { [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime) } | Sort-Object -Descending | Select-Object -First 1) }
    } catch { $points = $null }
    if ($backedUp.Count -gt 0) { Add-Check $run 'backup.onedrive' @($backedUp.Count) }
    if ($fileHistory) { Add-Check $run 'backup.filehistory' }
    if ($backedUp.Count -eq 0 -and -not $fileHistory) { Add-Check $run 'backup.none' }
    if ($points -eq 0) { Add-Check $run 'backup.restorepoints-none' }
    elseif ($newest -and ((Get-Date) - $newest).TotalDays -gt 30) { Add-Check $run 'backup.restorepoints-old' @($newest.ToString('MMMM d, yyyy')) }
    $newestText = $null
    if ($newest) { $newestText = $newest.ToUniversalTime().ToString('o') }
    [ordered]@{ oneDriveFolders = $backedUp; fileHistory = $fileHistory; restorePoints = $points; newestRestorePointUtc = $newestText; systemProtection = (Test-SystemProtectionOn) }
}

# --- Account ------------------------------------------------------------------------------------------------------
Invoke-Section -Run $run -Name 'account' -ScriptBlock {
    $msa = $false
    $idc = 'HKCU:\Software\Microsoft\IdentityCRL\UserExtendedProperties'
    if (Test-Path $idc) { $msa = (@(Get-ChildItem $idc -ErrorAction SilentlyContinue).Count -gt 0) }
    $admins = $null
    try { $admins = @(Get-CimInstance -ClassName Win32_Group -Filter "SID='S-1-5-32-544'" | Get-CimAssociatedInstance -ResultClassName Win32_UserAccount -ErrorAction Stop).Count } catch { $admins = $null }
    if ($isAdmin) { Add-Check $run 'account.admin-daily' }
    if (-not $msa) { Add-Check $run 'account.local' }
    if ($admins) { Add-Check $run 'account.admins' @($admins) }
    [ordered]@{ isAdministrator = $isAdmin; microsoftAccount = $msa; administratorAccounts = $admins }
}

# --- Installed apps, junk and remote-access tools -----------------------------------------------------------------
Invoke-Section -Run $run -Name 'apps' -ScriptBlock {
    $desktop = @(Get-RegisteredDesktopApp)
    $store = @(Get-StoreApp)
    Add-Check $run 'apps.count' @($desktop.Count, $store.Count)
    $names = @($desktop | ForEach-Object { $_.name }) + @($store | ForEach-Object { $_.name })
    $junk = (Read-DesksideCatalog -Name 'junk.json').items
    $junkFound = @()
    foreach ($j in $junk) {
        foreach ($n in $names) {
            if ($n -match $j.pattern) { $junkFound += [ordered]@{ app = $n; label = $j.label; verdict = $j.verdict; why = $j.why } }
        }
    }
    $rec = @($junkFound | Where-Object { $_.verdict -eq 'recommended' }).Count
    $q = @($junkFound | Where-Object { $_.verdict -eq 'questionable' }).Count
    if ($rec -gt 0) { Add-Check $run 'apps.junk-recommended' @($rec) }
    if ($q -gt 0) { Add-Check $run 'apps.junk-questionable' @($q) }
    $rt = Read-DesksideCatalog -Name 'remote-tools.json'
    $remote = @(); $mesh = $false
    foreach ($n in $names) {
        $isExpected = $false
        foreach ($e in $rt.expected) { if ($n -match $e.pattern) { $isExpected = $true; $mesh = $true } }
        if ($isExpected) { continue }
        foreach ($t in $rt.items) { if ($n -match $t.pattern) { $remote += [ordered]@{ app = $n; tool = $t.name }; break } }
    }
    if (Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue) { $mesh = $true }
    if ($remote.Count -gt 0) { Add-Check $run 'remote.unknown-tools' @($remote.Count) }
    if ($mesh) { Add-Check $run 'remote.mesh-agent' }
    [ordered]@{ desktop = $desktop; store = $store; junk = $junkFound; remoteTools = $remote; meshAgent = $mesh }
}

# --- SSH server ---------------------------------------------------------------------------------------------------
Invoke-Section -Run $run -Name 'sshd' -ScriptBlock {
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $svc) { return [ordered]@{ installed = $false } }
    $listen = @()
    try { $listen = @(Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction Stop | ForEach-Object { $_.LocalAddress } | Sort-Object -Unique) } catch { $listen = @() }
    $exposed = @($listen | Where-Object { $_ -ne '127.0.0.1' -and $_ -ne '::1' })
    if ($exposed.Count -gt 0) { Add-Check $run 'remote.sshd-exposed' @($exposed -join ', ') }
    elseif ($listen.Count -gt 0) { Add-Check $run 'remote.sshd' @($listen -join ', ') }
    [ordered]@{ installed = $true; status = [string]$svc.Status; listen = $listen }
}

# --- The help button (MeshCentral Assistant) and its weekly refresh ----------------------------------------------
Invoke-Section -Run $run -Name 'helpButton' -ScriptBlock {
    $hb = Get-HelpButtonPath
    if (-not (Test-Path -LiteralPath $hb.Exe)) { return [ordered]@{ installed = $false } }
    $state = $null
    if (Test-Path -LiteralPath $hb.StateFile) { try { $state = Get-Content -LiteralPath $hb.StateFile -Raw | ConvertFrom-Json } catch { $state = $null } }
    $lastOk = $null
    if ($state -and $state.PSObject.Properties['lastSuccessUtc'] -and $state.lastSuccessUtc) { $lastOk = [datetime]::Parse($state.lastSuccessUtc) }
    elseif ($state -and $state.result -notlike 'failed*') { $lastOk = [datetime]::Parse($state.lastUtc) }
    $task = Get-ScheduledTask -TaskPath $hb.TaskPath -TaskName $hb.TaskName -ErrorAction SilentlyContinue
    if (-not $task -or -not $lastOk -or ((Get-Date) - $lastOk).TotalDays -gt 21) {
        $text = 'never'; if ($lastOk) { $text = $lastOk.ToString('MMMM d, yyyy') }
        Add-Check $run 'help.refresh-failing' @($text)
    } else { Add-Check $run 'help.button' @($lastOk.ToString('MMMM d, yyyy')) }
    $okUtc = $null; if ($lastOk) { $okUtc = $lastOk.ToUniversalTime().ToString('o') }
    [ordered]@{ installed = $true; running = @(Get-Process -Name $hb.ProcessName -ErrorAction SilentlyContinue).Count; task = [bool]$task; lastSuccessUtc = $okUtc }
}

# --- App updates (Winget-AutoUpdate) ------------------------------------------------------------------------------
Invoke-Section -Run $run -Name 'appUpdates' -ScriptBlock {
    $task = $null
    try { $task = Get-ScheduledTask -TaskPath '\WAU\' -TaskName 'Winget-AutoUpdate' -ErrorAction Stop } catch { $task = $null }
    if (-not $task) { Add-Check $run 'updates.wau-missing'; return [ordered]@{ wau = $false } }
    $info = Get-ScheduledTaskInfo -InputObject $task
    $last = $info.LastRunTime
    $ok = ($info.LastTaskResult -eq 0)
    $lastText = 'never'
    if ($last -and $last.Year -gt 2000) { $lastText = $last.ToString('MMMM d, yyyy') }
    if (-not $ok -or $lastText -eq 'never' -or ((Get-Date) - $last).TotalDays -gt 7) { Add-Check $run 'updates.wau-failing' @($lastText) }
    else { Add-Check $run 'updates.wau-ok' @($lastText) }
    $lastUtc = $null
    if ($lastText -ne 'never') { $lastUtc = $last.ToUniversalTime().ToString('o') }
    [ordered]@{ wau = $true; lastRunUtc = $lastUtc; lastResult = $info.LastTaskResult }
}

if ($ScreenOnly) {
    $labels = @{ FixNow = 'Fix now'; FixSoon = 'Fix soon'; NiceToHave = 'Nice to have'; Info = 'Good to know' }
    foreach ($r in 'FixNow', 'FixSoon', 'NiceToHave', 'Info') {
        $items = @($run.Findings | Where-Object { $_.rank -eq $r })
        if ($items.Count -eq 0) { continue }
        Write-Information "`n$($labels[$r])" -InformationAction Continue
        foreach ($f in $items) { Write-Information " - $($f.text)" -InformationAction Continue }
    }
    Remove-Item -LiteralPath $run.Folder -Recurse -Force -ErrorAction SilentlyContinue
    return
}

$out = Complete-DesksideRun -Run $run -SummaryTitle 'PC health report'
if ($EmitJson) {
    $pick = [ordered]@{}
    foreach ($k in 'os', 'windowsUpdate', 'disks', 'battery', 'backups', 'appUpdates', 'events') { if ($run.Data.Contains($k)) { $pick[$k] = $run.Data[$k] } }
    if ($run.Data['security']) { $pick['security'] = [ordered]@{ defender = $run.Data['security'].defender; firewall = $run.Data['security'].firewall } }
    $compact = [ordered]@{ schema = 'deskside.health/v1'; runId = $run.Id; finishedUtc = (Get-Date).ToUniversalTime().ToString('o'); counts = $out.Counts; findings = $run.Findings.ToArray(); data = $pick }
    Write-Output ('DESKSIDE-HEALTH ' + (ConvertTo-Json -InputObject $compact -Depth 6 -Compress))
    # The sweep keeps its own copy in the records store; nothing stays on the PC.
    Remove-Item -LiteralPath $run.Folder -Recurse -Force -ErrorAction SilentlyContinue
    return
}
if ($PassThru) { $out }
