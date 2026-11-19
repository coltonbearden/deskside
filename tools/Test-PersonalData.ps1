#Requires -Version 5.1
<#
.SYNOPSIS
    Fails when tracked files (or the staged diff) contain personal data that must never reach the public repo.

.DESCRIPTION
    Two layers:
      1. Generic patterns: email addresses, Windows SIDs of real accounts, MAC addresses, BitLocker recovery keys,
         serial-number fields, private IP ranges and C:\Users\<name> paths with a real-looking name.
      2. A local deny list of exact words (names of people and PCs, hostnames), one per line, kept OUTSIDE the repo
         at $env:DESKSIDE_DENYLIST (default %USERPROFILE%\.config\deskside\denylist.txt). It never gets committed.
    Lines can opt out with the marker `personal-data: allow` when the match is a documented example.

.PARAMETER Path
    The repo root. Default: this script's parent folder.
#>
[CmdletBinding()]
param([string]$Path = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$allowMarker = 'personal-data: allow'
$patterns = [ordered]@{
    'email address'         = '[A-Za-z0-9._%+-]+@(?!example\.(com|org|net)\b)(?!noreply\.)[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
    'account SID'           = 'S-1-5-21-\d{6,}-\d{6,}-\d{6,}-\d{3,}'
    'MAC address'           = '\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b'
    'BitLocker recovery key' = '\b\d{6}-\d{6}-\d{6}-\d{6}-\d{6}-\d{6}-\d{6}-\d{6}\b'
    'serial number value'   = '(?i)serial ?(number)?\s*[:=]\s*["'']?[A-Z0-9]{6,}'
    'private IP address'    = '\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b|\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b'
    'user profile path'     = '(?i)C:\\Users\\(?!Public\b|Default\b|<|\$|%|WDAGUtilityAccount\b|runneradmin\b)[A-Za-z][A-Za-z0-9._-]+'
}

$deny = @()
$denyFile = $env:DESKSIDE_DENYLIST
if (-not $denyFile) { $denyFile = Join-Path $env:USERPROFILE '.config\deskside\denylist.txt' }
if (Test-Path -LiteralPath $denyFile) { $deny = @(Get-Content -LiteralPath $denyFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }) }

Push-Location $Path
try { $files = @(git ls-files --cached --others --exclude-standard) } finally { Pop-Location }
$skip = '\.(png|jpg|jpeg|gif|ico|zip|exe|msi)$'
$hits = New-Object System.Collections.Generic.List[object]
foreach ($rel in $files) {
    if ($rel -match $skip) { continue }
    $full = Join-Path $Path $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($full)) {
        $n++
        if ($line.Contains($allowMarker)) { continue }
        foreach ($k in $patterns.Keys) { if ($line -match $patterns[$k]) { $hits.Add([pscustomobject]@{ file = $rel; line = $n; kind = $k }) } }
        foreach ($w in $deny) { if ($line.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits.Add([pscustomobject]@{ file = $rel; line = $n; kind = 'deny-list word' }) } }
    }
}
# Report file, line and kind only: never echo the matched text.
foreach ($h in $hits) { Write-Output ("{0}:{1}: {2}" -f $h.file, $h.line, $h.kind) }
Write-Output ("Personal-data scan: {0} file(s), {1} finding(s), deny list {2}." -f $files.Count, $hits.Count, $(if ($deny.Count) { "$($deny.Count) word(s)" } else { 'not found' }))
if ($hits.Count -gt 0) { exit 1 }
