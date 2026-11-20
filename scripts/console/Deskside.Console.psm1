#Requires -Version 7.0
<#
.SYNOPSIS
    Helpers for the helper's own machine: the private records store, the device list, MeshCentral settings and logins,
    MeshCmd port maps and SSH.

.DESCRIPTION
    Nothing here runs on a family PC. The private store is a separate private repo (default
    $HOME\Projects\deskside-records, override with $env:DESKSIDE_RECORDS) holding:
      devices.json         the device list: alias, MeshCentral node id, SSH user, profile, consent dates
      meshcentral.json     server URL, device group id, server certificate hash, 1Password references for the logins
      devices\<alias>\runs records and transcripts pulled back from each PC
#>

Set-StrictMode -Version 3.0

function Get-RecordsRoot {
    [CmdletBinding()]
    param()
    $root = $env:DESKSIDE_RECORDS
    if (-not $root) { $root = Join-Path $HOME 'Projects\deskside-records' }
    if (-not (Test-Path -LiteralPath $root)) { throw "The private records store isn't at $root. Clone coltonbearden/deskside-records there or set DESKSIDE_RECORDS." }
    return $root
}

function Get-DesksideDevice {
    <# Returns one device from devices.json by alias, or all of them. #>
    [CmdletBinding()]
    param([string]$Alias)
    $path = Join-Path (Get-RecordsRoot) 'devices.json'
    $list = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).devices
    if (-not $Alias) { return $list }
    $d = $list | Where-Object { $_.alias -eq $Alias } | Select-Object -First 1
    if (-not $d) { throw "No device '$Alias' in devices.json." }
    return $d
}

function Assert-RemoteConsent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Device)
    if (-not ($Device.PSObject.Properties['consent'] -and $Device.consent.PSObject.Properties['remote'] -and $Device.consent.remote)) {
        throw "devices.json has no remote consent date for '$($Device.alias)'. Record when the owner said yes before connecting."
    }
}

function Get-MeshSetting {
    [CmdletBinding()]
    param()
    return (Get-Content -LiteralPath (Join-Path (Get-RecordsRoot) 'meshcentral.json') -Raw | ConvertFrom-Json)
}

function Get-MeshLogin {
    <# Reads the automation login (a MeshCentral login token: user and key) from 1Password by reference. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings)
    $user = (& op read $Settings.login.userRef).Trim()
    $pass = (& op read $Settings.login.passwordRef).Trim()
    if (-not $user -or -not $pass) { throw '1Password did not return the MeshCentral login.' }
    return [pscustomobject]@{ User = $user; Password = $pass }
}

function Get-MeshCmd {
    <# Fetches MeshCmd from the server itself (so its version always matches), at most once a week. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings)
    $dir = Join-Path $env:LOCALAPPDATA 'deskside'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $exe = Join-Path $dir 'meshcmd.exe'
    if (-not (Test-Path -LiteralPath $exe) -or ((Get-Date) - (Get-Item -LiteralPath $exe).LastWriteTime).TotalDays -gt 7) {
        $tmp = "$exe.download"
        Invoke-WebRequest -Uri ($Settings.serverUrl.TrimEnd('/') + '/meshagents?meshcmd=4') -OutFile $tmp
        Move-Item -LiteralPath $tmp -Destination $exe -Force
    }
    return $exe
}

function Get-FreePort {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
    return $port
}

function Get-MeshRelayUrl {
    <# The relay MeshCmd connects to: meshcentral.json's relayUrl when set, else the server URL's /meshrelay.ashx. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings)
    if ($Settings.PSObject.Properties['relayUrl'] -and $Settings.relayUrl) { return $Settings.relayUrl }
    return ($Settings.serverUrl.TrimEnd('/') -replace '^https://', 'wss://') + '/meshrelay.ashx'
}

function New-MeshRouteAction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object in memory; changes nothing.')]
    <#
    .SYNOPSIS
        Builds MeshCmd's route action (the contents of meshaction.txt).
    .NOTES
        MeshCmd checks the server by serverId (the key hash of its own certificate) when serverId is present, otherwise
        by serverHttpsHash (the TLS certificate's fingerprint). Behind a proxy that holds its own certificate only the
        second works, so an empty serverId is left out rather than sent. debugLevel is never set: above 0 MeshCmd
        prints the login.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Device, [Parameter(Mandatory)]$Login, [Parameter(Mandatory)][int]$LocalPort, [int]$RemotePort = 22)
    $a = [ordered]@{
        action = 'route'; localPort = $LocalPort; remoteName = $Device.alias; remoteNodeId = $Device.meshNodeId; remotePort = $RemotePort
        username = $Login.User; password = $Login.Password
    }
    if ($Settings.PSObject.Properties['serverId'] -and $Settings.serverId) { $a['serverId'] = $Settings.serverId }
    elseif ($Settings.PSObject.Properties['serverHttpsHash'] -and $Settings.serverHttpsHash) { $a['serverHttpsHash'] = $Settings.serverHttpsHash }
    else { throw 'meshcentral.json needs serverId or serverHttpsHash so MeshCmd can check the server.' }
    $a['serverUrl'] = Get-MeshRelayUrl -Settings $Settings
    return $a
}

function Start-MeshRoute {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts a local MeshCmd process; changes nothing on either machine.')]
    <#
    .SYNOPSIS
        Maps a free local port to port 22 on the device, through the MeshCentral server (MeshCmd's route action).
    .OUTPUTS
        An object with LocalPort and Process; stop it with Stop-MeshRoute.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Device, [int]$RemotePort = 22, [switch]$NoHashRefresh)
    $s = Get-MeshSetting
    $route = Start-MeshRouteOnce -Settings $s -Device $Device -RemotePort $RemotePort
    # MeshCmd checks the server's certificate only when a connection goes through, so make one now. If the pinned
    # fingerprint no longer matches (the proxy's certificate was renewed), MeshCmd exits printing the new one.
    $newHash = Test-MeshRouteServer -Route $route
    if ($newHash) {
        Stop-MeshRoute -Route $route
        if ($NoHashRefresh -or -not (Test-PrivateRelay -Settings $s)) {
            throw "The MeshCentral server's certificate no longer matches meshcentral.json's serverHttpsHash. Check the server, then set serverHttpsHash to the new fingerprint MeshCmd reports."
        }
        # Over a private VPN relay the VPN already authenticates the server, so a renewed certificate is accepted and
        # recorded, and the helper is told.
        Update-MeshServerHash -Hash $newHash
        Write-Warning "The MeshCentral server's certificate changed; meshcentral.json now holds the new fingerprint."
        $route = Start-MeshRouteOnce -Settings (Get-MeshSetting) -Device $Device -RemotePort $RemotePort
        if (Test-MeshRouteServer -Route $route) { Stop-MeshRoute -Route $route; throw 'MeshCmd rejected the server certificate twice.' }
    }
    return $route
}

function Test-PrivateRelay {
    <# True when the relay's host resolves only to VPN addresses in the shared 100.64/10 range (WireGuard-style overlays such as Tailscale use it). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings)
    $h = ([uri]((Get-MeshRelayUrl -Settings $Settings) -replace '^wss://', 'https://')).Host
    $ips = @([Net.Dns]::GetHostAddresses($h) | Where-Object { $_.AddressFamily -eq 'InterNetwork' })
    if ($ips.Count -eq 0) { return $false }
    foreach ($ip in $ips) { $b = $ip.GetAddressBytes(); if (-not ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127)) { return $false } }
    return $true
}

function Update-MeshServerHash {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates one field of the private store''s settings, only after MeshCmd reported a renewed certificate over a private VPN relay.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[0-9A-F]{96}$')][string]$Hash)
    $path = Join-Path (Get-RecordsRoot) 'meshcentral.json'
    $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $doc.serverHttpsHash = $Hash
    $doc | Add-Member -NotePropertyName serverHttpsHashReadUtc -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
    ($doc | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path
}

function Test-MeshRouteServer {
    <# Opens one connection through the route. Returns the new fingerprint if MeshCmd rejected the server's certificate, else $null. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Route)
    $c = [System.Net.Sockets.TcpClient]::new()
    try { $c.Connect([System.Net.IPAddress]::Loopback, $Route.LocalPort) } catch { Write-Verbose 'Connecting to the local port failed.' }
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline -and -not $Route.Process.HasExited) { Start-Sleep -Milliseconds 300 }
    $c.Close()
    if (-not $Route.Process.HasExited) { return $null }
    $o = Get-Content -LiteralPath (Join-Path $Route.WorkDir 'out.txt') -Raw -ErrorAction SilentlyContinue
    if ($o -match 'Failed to verify server certificate' -and $o -match 'Server TLS hash: ([0-9A-F]{96})') { return $Matches[1] }
    throw "MeshCmd stopped: $(($o -replace '[0-9A-Fa-f]{32,}', '<hex>').Trim())"
}

function Start-MeshRouteOnce {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts a local MeshCmd process; changes nothing on either machine.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Device, [int]$RemotePort = 22)
    $s = $Settings
    $login = Get-MeshLogin -Settings $s
    $exe = Get-MeshCmd -Settings $s
    $port = Get-FreePort
    $work = Join-Path $env:TEMP ('deskside-route-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $work | Out-Null
    $action = New-MeshRouteAction -Settings $s -Device $Device -Login $login -LocalPort $port -RemotePort $RemotePort
    $actionPath = Join-Path $work 'meshaction.txt'
    ($action | ConvertTo-Json) | Set-Content -LiteralPath $actionPath -Encoding ascii
    # MeshCmd reads meshaction.txt from its own current folder, which isn't reliably the working directory given here,
    # so the file is named explicitly.
    $proc = Start-Process -FilePath $exe -ArgumentList 'route', '--actionfile', ('"' + $actionPath + '"') -WorkingDirectory $work -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $work 'out.txt') -RedirectStandardError (Join-Path $work 'err.txt')
    $deadline = (Get-Date).AddSeconds(30)
    $ready = $false
    while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
        Start-Sleep -Milliseconds 500
        if ((Get-Content -LiteralPath (Join-Path $work 'out.txt') -Raw -ErrorAction SilentlyContinue) -match 'Redirecting local port') { $ready = $true; break }
    }
    # The action file holds the login: remove it as soon as MeshCmd has read it.
    Remove-Item -LiteralPath $actionPath -Force -ErrorAction SilentlyContinue
    if (-not $ready) {
        $err = (Get-Content -LiteralPath (Join-Path $work 'out.txt'), (Join-Path $work 'err.txt') -Raw -ErrorAction SilentlyContinue) -join ' '
        if (-not $proc.HasExited) { $proc.Kill() }
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        throw "The port map to '$($Device.alias)' didn't start: $err"
    }
    return [pscustomobject]@{ LocalPort = $port; Process = $proc; WorkDir = $work; Alias = $Device.alias }
}

function Stop-MeshRoute {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stops the local MeshCmd process Start-MeshRoute started.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Route)
    if (-not $Route.Process.HasExited) { $Route.Process.Kill() }
    Remove-Item -LiteralPath $Route.WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-SshArgument {
    <#
        Common ssh options: the port map, a per-device known_hosts, keys from the SSH agent (1Password). With
        $env:DESKSIDE_SSH_IDENTITY set (the Sandbox proof's throwaway key) that key file is used instead. The first two
        items are always '-p' and the port.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Route, [Parameter(Mandatory)]$Device)
    $kh = Join-Path $env:LOCALAPPDATA 'deskside\known_hosts'
    $a = @('-p', $Route.LocalPort, '-o', "HostKeyAlias=deskside-$($Device.alias)", '-o', "UserKnownHostsFile=$kh",
        '-o', 'StrictHostKeyChecking=accept-new', '-o', 'PasswordAuthentication=no', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20')
    if ($env:DESKSIDE_SSH_IDENTITY) { $a += @('-i', $env:DESKSIDE_SSH_IDENTITY, '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none') }
    return $a
}

Export-ModuleMember -Function *
