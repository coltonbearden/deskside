#Requires -Version 5.1
<#
.SYNOPSIS
    Turns on Windows' OpenSSH Server listening only on this PC (127.0.0.1), with key sign-in only, for the helper's
    public key. It is reached only through the MeshCentral agent's port mapping, never from the home network.

.DESCRIPTION
    1. Installs OpenSSH Server: Windows' optional feature first; if Windows can't install it (no feature source, as in
       Windows Sandbox), winget's Microsoft.OpenSSH.Preview package (Microsoft's Win32-OpenSSH MSI).
    2. Writes sshd_config: ListenAddress 127.0.0.1, PasswordAuthentication no, PubkeyAuthentication yes,
       AuthenticationMethods publickey, administrators_authorized_keys for admins (Microsoft's layout).
    3. Writes the key with Microsoft's ACL (Administrators and SYSTEM only).
    4. Turns off the inbound firewall rules the installers add, so port 22 is never open to the network.
    5. Sets the SSH default shell to Windows PowerShell.
    Before-state (the old sshd_config, how sshd was installed) goes to ssh-state.json for Disable-LoopbackSsh.ps1.

    Sources: learn.microsoft.com/windows-server/administration/openssh/openssh_install_firstuse,
    openssh-server-configuration and openssh_keymanagement.

.PARAMETER PublicKey
    The helper's public key line (ssh-ed25519 AAAA... comment).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+( .*)?$')][string]$PublicKey,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\common\Deskside.Common.psm1') -Force
Assert-NotManaged
Assert-Consent -Scope remote
if (-not (Test-IsAdministrator)) { throw 'Turning on the SSH server needs administrator rights.' }

$run = New-DesksideRun -Kind 'ssh-enable' -OutputDirectory $OutputDirectory
$statePath = Join-Path (Initialize-DataRoot) 'ssh-state.json'
$state = [ordered]@{ schema = 'deskside.ssh-state/v1'; method = 'existing'; configBackup = $null; firewallRulesDisabled = @(); defaultShellBefore = $null }
if (Test-Path -LiteralPath $statePath) {
    $old = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $old.PSObject.Properties) { $state[$p.Name] = $p.Value }
}

# 1. Install
if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess('OpenSSH Server', 'Install')) {
        $installed = $false
        try {
            $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop | Select-Object -First 1
            if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null }
            $state.method = 'capability'; $installed = $true
        } catch {
            $run.Changes.Add([pscustomobject]@{ what = 'OpenSSH Server (Windows feature)'; result = 'not available; using winget' })
        }
        if (-not $installed) {
            $winget = & (Join-Path $PSScriptRoot '..\install\Repair-Winget.ps1')
            & $winget install --id Microsoft.OpenSSH.Preview -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --override '/qn ADDLOCAL=Server,Client'
            if ($LASTEXITCODE -ne 0) { throw "OpenSSH install failed (winget exit $LASTEXITCODE)." }
            $state.method = 'winget'
        }
        $run.Changes.Add([pscustomobject]@{ what = 'OpenSSH Server'; result = "installed ($($state.method))" })
    }
}
if ($WhatIfPreference) { Complete-DesksideRun -Run $run -SummaryTitle 'Remote help: SSH' | Out-Null; return }

# First start creates %ProgramData%\ssh\sshd_config and the host keys.
$sshDir = Join-Path $env:ProgramData 'ssh'
$config = Join-Path $sshDir 'sshd_config'
if (-not (Test-Path -LiteralPath $config)) { Start-Service sshd; Start-Sleep -Seconds 3; Stop-Service sshd }

# 2. Config
$desired = @(
    '# Managed by deskside (Enable-LoopbackSsh.ps1). Reached only through the MeshCentral agent.',
    'ListenAddress 127.0.0.1',
    'PubkeyAuthentication yes',
    'PasswordAuthentication no',
    'AuthenticationMethods publickey',
    'PermitEmptyPasswords no',
    'AuthorizedKeysFile .ssh/authorized_keys',
    'Subsystem sftp sftp-server.exe',
    '',
    'Match Group administrators',
    '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys'
) -join "`n"
$current = ''
if (Test-Path -LiteralPath $config) { $current = [IO.File]::ReadAllText($config) }
if ($current -ne $desired) {
    if (-not $state.configBackup -and $current) {
        $state.configBackup = Join-Path (Get-DesksideDataRoot) 'sshd_config.before'
        Copy-Item -LiteralPath $config -Destination $state.configBackup -Force
    }
    [IO.File]::WriteAllText($config, $desired, (New-Object Text.ASCIIEncoding))
    $run.Changes.Add([pscustomobject]@{ what = 'sshd_config'; result = 'loopback only, keys only' })
}

# 3. Key, with Microsoft's ACL for administrators_authorized_keys.
$keys = Join-Path $sshDir 'administrators_authorized_keys'
$existing = @()
if (Test-Path -LiteralPath $keys) { $existing = @(Get-Content -LiteralPath $keys) }
if ($existing -notcontains $PublicKey) {
    [IO.File]::WriteAllText($keys, ((@($existing) + $PublicKey) -join "`n") + "`n", (New-Object Text.ASCIIEncoding))
    $run.Changes.Add([pscustomobject]@{ what = 'Helper key'; result = 'added' })
}
& icacls.exe $keys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not set the key file permissions.' }

# 4. No inbound rule: SSH is reached only from this PC.
foreach ($rule in @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Direction -eq 'Inbound' -and ($_.Name -like 'OpenSSH*' -or $_.DisplayName -like 'OpenSSH*' -or $_.Name -eq 'sshd') -and $_.Enabled -eq 'True' })) {
    Disable-NetFirewallRule -Name $rule.Name
    $state.firewallRulesDisabled = @($state.firewallRulesDisabled) + $rule.Name
    $run.Changes.Add([pscustomobject]@{ what = 'Firewall rule for SSH'; result = 'turned off' })
}

# 5. Default shell.
$shellKey = 'HKLM:\SOFTWARE\OpenSSH'
$shellState = Get-RegistryState -Path $shellKey -Name 'DefaultShell'
if (-not $state.defaultShellBefore) { $state.defaultShellBefore = $shellState }
Set-RegistryValueSafe -Path $shellKey -Name 'DefaultShell' -Value (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Kind String

(ConvertTo-Json -InputObject $state -Depth 5) | Set-Content -LiteralPath $statePath -Encoding UTF8
Set-Service -Name sshd -StartupType Automatic
Restart-Service -Name sshd
Start-Sleep -Seconds 2
$listen = @(Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue | ForEach-Object { $_.LocalAddress } | Sort-Object -Unique)
$run.Data['listen'] = $listen
if (@($listen | Where-Object { $_ -ne '127.0.0.1' }).Count -gt 0 -or $listen.Count -eq 0) { throw "sshd is not listening on 127.0.0.1 only (listening on: $($listen -join ', '))." }
$run.Changes.Add([pscustomobject]@{ what = 'SSH server'; result = 'running on 127.0.0.1:22 only' })
Complete-DesksideRun -Run $run -SummaryTitle 'Remote help: SSH' | Out-Null