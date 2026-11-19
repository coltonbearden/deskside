#Requires -Version 7.0
<#
.SYNOPSIS
    Runs a deskside script on a family PC from the helper's machine, through MeshCentral's port map and SSH, and
    brings its records back into the private store.

.DESCRIPTION
    1. Checks devices.json for the owner's remote consent.
    2. Opens the port map (MeshCmd route) to the PC's 127.0.0.1:22.
    3. Runs the script with Windows PowerShell on the PC (deskside lives in C:\ProgramData\deskside\app there).
    4. Copies new run folders back to <records>\devices\<alias>\runs\ with scp. Diagnose runs are then deleted from the
       PC; change runs stay there too, because undo reads their undo.json on the PC.
    5. Closes the port map.
    On screen: the script's own counts-only output. Names and app lists stay in the records.

.PARAMETER Script
    A path under scripts\ on the PC, e.g. 'diagnose\Invoke-Diagnose.ps1'.

.PARAMETER Arguments
    Extra arguments for the script, as one string, e.g. '-ProfileName everyone -WhatIf'.

.PARAMETER Shell
    Open an interactive SSH session instead of running a script.

.EXAMPLE
    .\scripts\console\Invoke-DesksideRemote.ps1 -Alias example-pc -Script diagnose\Invoke-Diagnose.ps1
#>
[CmdletBinding(DefaultParameterSetName = 'Script')]
param(
    [Parameter(Mandatory)][string]$Alias,
    [Parameter(ParameterSetName = 'Script', Mandatory)][string]$Script,
    [Parameter(ParameterSetName = 'Script')][string]$Arguments = '',
    [Parameter(ParameterSetName = 'Shell', Mandatory)][switch]$Shell,
    [switch]$KeepOnPc
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Deskside.Console.psm1') -Force
$device = Get-DesksideDevice -Alias $Alias
Assert-RemoteConsent -Device $device

$route = Start-MeshRoute -Device $device
try {
    $ssh = Get-SshArgument -Route $route -Device $device
    $target = "$($device.sshUser)@127.0.0.1"
    if ($Shell) { & ssh.exe @ssh -o BatchMode=no $target; return }

    if ($Script -notmatch '^[A-Za-z]+\\[A-Za-z-]+\.ps1$') { throw "Script must look like 'diagnose\Invoke-Diagnose.ps1'." }
    $before = (& ssh.exe @ssh $target 'Get-ChildItem C:\ProgramData\deskside\data\runs -Directory -EA SilentlyContinue | ForEach-Object Name') -split "`r?`n" | Where-Object { $_ }
    if ($Arguments -match '[;|&`\r\n]') { throw 'Arguments may not contain ; | & backtick or line breaks.' }
    $argText = $Arguments
    $remote = "& 'C:\ProgramData\deskside\app\scripts\$Script' $argText"
    & ssh.exe @ssh $target $remote
    $code = $LASTEXITCODE
    $after = (& ssh.exe @ssh $target 'Get-ChildItem C:\ProgramData\deskside\data\runs -Directory -EA SilentlyContinue | ForEach-Object Name') -split "`r?`n" | Where-Object { $_ }
    $new = @($after | Where-Object { $before -notcontains $_ })

    $dest = Join-Path (Get-RecordsRoot) "devices\$Alias\runs"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $scpArgs = @('-P', $route.LocalPort) + ($ssh | Select-Object -Skip 2) + @('-r')
    foreach ($n in $new) {
        & scp.exe @scpArgs "${target}:C:/ProgramData/deskside/data/runs/$n" $dest
        # Only read-only runs leave the PC. A change run keeps its folder there: its undo.json and backups are what
        # Undo-DesksideRun.ps1 reads on the PC.
        if ($LASTEXITCODE -eq 0 -and -not $KeepOnPc -and $n -like '*-diagnose') { & ssh.exe @ssh $target "Remove-Item -LiteralPath 'C:\ProgramData\deskside\data\runs\$n' -Recurse -Force" }
    }
    Write-Information "Brought back $($new.Count) run(s) to the records store." -InformationAction Continue
    if ($code -ne 0) { throw "The script on the PC exited with $code." }
} finally {
    Stop-MeshRoute -Route $route
}
