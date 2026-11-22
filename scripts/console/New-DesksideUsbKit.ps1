#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the USB kit that enrolls a PC for remote help with nothing typed: double-click "START HERE.cmd" on the PC.

.DESCRIPTION
    Writes, to the root of a removable drive (or a folder with -Path):
      START HERE.cmd               runs deskside\deskside-enroll.ps1 (the kit, usb-kit\ in this repo)
      deskside\deskside.zip        deskside at the committed HEAD, put on the PC by the kit
      deskside\bootstrap.ps1, deskside\Deskside.Common.psm1, deskside\deskside-enroll.ps1   from that same commit
      deskside\kit.json            the commit, build time and which 1Password reference the group id came from
      deskside\values.json         server URL, device group id, deskside-ssh public key, helper's name
    The values are read from meshcentral.json and 1Password each time and printed nowhere. The kit deletes values.json
    after a finished run; Read-DesksideUsbKit.ps1 reads the results back and wipes them in any case.

    Refuses a drive that still holds a kit's values, an older kit, or results not yet read back.

.PARAMETER Proof
    Use the Proofs device group (proofGroupRef), whose devices are removed when they disconnect: for the Sandbox proof.
#>
[CmdletBinding()]
param([string]$Drive, [string]$Path, [switch]$Proof)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $PSScriptRoot 'Deskside.Console.psm1') -Force

$root = Get-UsbKitRoot -Drive $Drive -Path $Path
Assert-UsbKitTargetFree -Root $root
$dirty = @(git -C $repo status --porcelain --untracked-files=no)
if ($dirty.Count -gt 0) { throw 'The repo has uncommitted changes; the kit carries the committed HEAD. Commit first.' }
$commit = (git -C $repo rev-parse --short=12 HEAD).Trim()

$kv = Get-UsbKitValue -Proof:$Proof

$work = Join-Path ([IO.Path]::GetTempPath()) ('deskside-kit-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $zip = Join-Path $work 'deskside.zip'
    git -C $repo archive --format=zip --prefix=deskside-main/ -o $zip HEAD
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $zip)) { throw 'git archive did not make the zip.' }
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'x')
    $src = Join-Path $work 'x\deskside-main'

    $kitDir = Join-Path $root 'deskside'
    New-Item -ItemType Directory -Force -Path $kitDir | Out-Null
    foreach ($old in 'readback.txt', 'log.txt') { Remove-Item -LiteralPath (Join-Path $root $old) -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Join-Path $kitDir 'read-back.json') -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $src 'usb-kit\START HERE.cmd') -Destination $root -Force
    Copy-Item -LiteralPath (Join-Path $src 'usb-kit\deskside\deskside-enroll.ps1') -Destination $kitDir -Force
    Copy-Item -LiteralPath (Join-Path $src 'scripts\common\Deskside.Common.psm1') -Destination $kitDir -Force
    Copy-Item -LiteralPath (Join-Path $src 'bootstrap.ps1') -Destination $kitDir -Force
    Copy-Item -LiteralPath $zip -Destination $kitDir -Force
    [ordered]@{ schema = 'deskside.usbkit/v1'; commit = $commit; built = (Get-Date).ToUniversalTime().ToString('s') + 'Z'; groupRef = $kv.GroupRefName } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $kitDir 'kit.json') -Encoding ascii
    [IO.File]::WriteAllText((Join-Path $kitDir 'values.json'), ($kv.Values | ConvertTo-Json), [Text.ASCIIEncoding]::new())
} finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

$group = if ($Proof) { 'the Proofs group' } else { 'the Friends and family group' }
Write-Information "USB kit built from commit $commit for $group. On the PC: double-click START HERE.cmd." -InformationAction Continue
