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

function Start-MeshRoute {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts a local MeshCmd process; changes nothing on either machine.')]
    <#
    .SYNOPSIS
        Maps a free local port to port 22 on the device, through the MeshCentral server (MeshCmd's route action).
    .OUTPUTS
        An object with LocalPort and Process; stop it with Stop-MeshRoute.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Device, [int]$RemotePort = 22)
    $s = Get-MeshSetting
    $login = Get-MeshLogin -Settings $s
    $exe = Get-MeshCmd -Settings $s
    $port = Get-FreePort
    $work = Join-Path $env:TEMP ('deskside-route-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $work | Out-Null
    $wss = ($s.serverUrl.TrimEnd('/') -replace '^https://', 'wss://') + '/meshrelay.ashx'
    $action = [ordered]@{
        action = 'route'; localPort = $port; remoteName = $Device.alias; remoteNodeId = $Device.meshNodeId; remotePort = $RemotePort
        username = $login.User; password = $login.Password; serverId = $s.serverId; serverHttpsHash = $s.serverHttpsHash
        debugLevel = 0; serverUrl = $wss
    }
    $actionPath = Join-Path $work 'meshaction.txt'
    ($action | ConvertTo-Json) | Set-Content -LiteralPath $actionPath -Encoding ascii
    $proc = Start-Process -FilePath $exe -WorkingDirectory $work -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $work 'out.txt') -RedirectStandardError (Join-Path $work 'err.txt')
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
    <# Common ssh options: the port map, a per-device known_hosts, keys from the 1Password SSH agent only. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Route, [Parameter(Mandatory)]$Device)
    $kh = Join-Path $env:LOCALAPPDATA 'deskside\known_hosts'
    return @('-p', $Route.LocalPort, '-o', "HostKeyAlias=deskside-$($Device.alias)", '-o', "UserKnownHostsFile=$kh",
        '-o', 'StrictHostKeyChecking=accept-new', '-o', 'PasswordAuthentication=no', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20')
}

Export-ModuleMember -Function *
