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
    # op prints nothing when its 1Password approval times out, so an empty answer is named rather than trimmed.
    $user = ((& op read $Settings.login.userRef) | Out-String).Trim()
    if (-not $user) { throw '1Password did not return the MeshCentral login (approve 1Password''s prompt for op, then run again).' }
    $pass = ((& op read $Settings.login.passwordRef) | Out-String).Trim()
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
    <#
    .NOTES
        MeshCmd's serverHttpsHash is a SHA-384 of a certificate's public key, accepted when it matches ANY certificate the
        server sends, roots included, and with no host-name check. So deskside pins the server's own key (the first
        certificate), never a CA's, and with serverHttpsHash (no serverId) it only maps ports over a relay that resolves
        to VPN addresses, where the VPN itself authenticates the server.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Device, [int]$RemotePort = 22, [switch]$NoHashRefresh)
    $s = Get-MeshSetting
    $byServerId = $s.PSObject.Properties['serverId'] -and $s.serverId
    if (-not $byServerId -and -not (Test-PrivateRelay -Settings $s)) {
        throw "meshcentral.json's relay doesn't resolve to VPN addresses. With only a certificate fingerprint to check the server, deskside maps ports only over a private VPN relay."
    }
    # MeshCmd connects to the server and checks its certificate as the route starts.
    try { return Start-MeshRouteOnce -Settings $s -Device $Device -RemotePort $RemotePort }
    catch {
        if ($_.Exception.Message -notmatch 'Failed to verify server certificate') { throw }
        if ($NoHashRefresh -or $byServerId) {
            throw "MeshCmd rejected the MeshCentral server's certificate. Check the server, then refresh serverHttpsHash (Get-MeshServerKeyHash)."
        }
    }
    # The server's key changed (its certificate was renewed). Over the VPN relay the VPN already authenticates the
    # server, so the new key is read directly, recorded, and the helper is told.
    Update-MeshServerHash -Hash (Get-MeshServerKeyHash -Settings $s)
    Write-Warning "The MeshCentral server's certificate changed; meshcentral.json now holds its new key's fingerprint."
    return Start-MeshRouteOnce -Settings (Get-MeshSetting) -Device $Device -RemotePort $RemotePort
}

function Get-MeshServerKeyHash {
    <# SHA-384 of the relay server's own public key (its first certificate), in MeshCmd's serverHttpsHash form. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings)
    $u = [uri]((Get-MeshRelayUrl -Settings $Settings) -replace '^wss://', 'https://')
    $tcp = [System.Net.Sockets.TcpClient]::new($u.Host, $u.Port)
    try {
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false)
        $ssl.AuthenticateAsClient($u.Host)
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
        $bytes = [System.Security.Cryptography.SHA384]::HashData($cert.PublicKey.EncodedKeyValue.RawData)
        return [Convert]::ToHexString($bytes)
    } finally { $tcp.Dispose() }
}

function Test-PrivateRelay {
    <# True when the relay's host resolves only to VPN addresses in the shared 100.64/10 range (WireGuard-style overlays such as Tailscale use it). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings)
    $h = ([uri]((Get-MeshRelayUrl -Settings $Settings) -replace '^wss://', 'https://')).Host
    return Test-VpnAddress -Address ([Net.Dns]::GetHostAddresses($h))
}

function Test-VpnAddress {
    <#
        True when there is at least one address and every one is a VPN overlay address: IPv4 in 100.64/10, or IPv6 in
        fd7a:115c:a1e0::/48 (Tailscale's own range). Anything else, public addresses included, makes it false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyCollection()][System.Net.IPAddress[]]$Address)
    if (-not $Address -or $Address.Count -eq 0) { return $false }
    foreach ($ip in $Address) {
        $b = $ip.GetAddressBytes()
        if ($ip.AddressFamily -eq 'InterNetwork') {
            if (-not ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127)) { return $false }
        } elseif ($ip.AddressFamily -eq 'InterNetworkV6') {
            if (-not ($b[0] -eq 0xfd -and $b[1] -eq 0x7a -and $b[2] -eq 0x11 -and $b[3] -eq 0x5c -and $b[4] -eq 0xa1 -and $b[5] -eq 0xe0)) { return $false }
        } else { return $false }
    }
    return $true
}

function Update-MeshServerHash {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates one field of the private store''s settings, only after MeshCmd rejected the pinned key over a private VPN relay.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[0-9A-F]{96}$')][string]$Hash)
    $path = Join-Path (Get-RecordsRoot) 'meshcentral.json'
    $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $doc.serverHttpsHash = $Hash
    $doc | Add-Member -NotePropertyName serverHttpsHashReadUtc -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
    ($doc | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path
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
    # The action file holds the login: remove it as soon as MeshCmd has read it, and stop if it can't be.
    if (-not $ready) {
        $err = (Get-Content -LiteralPath (Join-Path $work 'out.txt'), (Join-Path $work 'err.txt') -Raw -ErrorAction SilentlyContinue) -join ' '
        Stop-MeshCmdProcess -Process $proc
        Remove-RouteFolder -Path $work -LoginFile $actionPath
        throw "The port map to '$($Device.alias)' didn't start: $err"
    }
    try { Remove-RouteLoginFile -Path $actionPath }
    catch { Stop-MeshCmdProcess -Process $proc; throw }
    return [pscustomobject]@{ LocalPort = $port; Process = $proc; WorkDir = $work; Alias = $Device.alias }
}

function Stop-MeshRoute {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stops the local MeshCmd process Start-MeshRoute started.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Route)
    Stop-MeshCmdProcess -Process $Route.Process
    Remove-RouteFolder -Path $Route.WorkDir -LoginFile (Join-Path $Route.WorkDir 'meshaction.txt')
}

function Stop-MeshCmdProcess {
    <# Kill() returns before the process is gone (it runs asynchronously), so wait for it before touching its files. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stops the local MeshCmd process Start-MeshRoute started.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Process)
    if (-not $Process.HasExited) { try { $Process.Kill() } catch { Write-Verbose "MeshCmd had already exited: $($_.Exception.Message)" } }
    if (-not $Process.WaitForExit(15000)) { Write-Warning "MeshCmd (pid $($Process.Id)) didn't exit within 15 s." }
}

function Remove-RouteLoginFile {
    <# Removes meshaction.txt (it holds the relay login), retrying briefly; throws if it is still there. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Removes the console''s own temporary login file.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $Path); $i++) {
        try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { Start-Sleep -Milliseconds 250 }
    }
    if (Test-Path -LiteralPath $Path) { throw "The port map's login file couldn't be removed: $Path. It holds the relay login: delete it by hand." }
}

function Remove-RouteFolder {
    <#
        Removes a port map's work folder after MeshCmd has exited, retrying while redirected output files are still
        being closed. The login file must go (throws if it can't); a folder left without it is named in a warning.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Removes the console''s own temporary folder.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$LoginFile)
    Remove-RouteLoginFile -Path $LoginFile
    for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $Path); $i++) {
        try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Milliseconds 250 }
    }
    if (Test-Path -LiteralPath $Path) { Write-Warning "The port map's work folder couldn't be removed: $Path (it holds no login). Delete it by hand." }
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
    else { $a += @('-i', (Get-SshPublicKeyFile), '-o', 'IdentitiesOnly=yes') }
    return $a
}

function Get-SshPublicKeyFile {
    <#
    .SYNOPSIS
        The deskside-ssh public key as a file, so ssh asks 1Password's agent for that one key only.
    .DESCRIPTION
        1Password's agent offers every key it holds, and an OpenSSH server refuses after MaxAuthTries (6) keys
        ("Too many authentication failures"). Naming the public key with IdentitiesOnly is 1Password's own fix. The
        key is read from meshcentral.json's sshPublicKeyRef (an op:// reference) into
        %LOCALAPPDATA%\deskside\deskside-ssh.pub and read again when the reference returns something different.
    #>
    [CmdletBinding()]
    param($Settings = (Get-MeshSetting))
    if (-not ($Settings.PSObject.Properties['sshPublicKeyRef'] -and $Settings.sshPublicKeyRef)) { throw 'meshcentral.json needs sshPublicKeyRef (the op:// reference of the deskside-ssh public key).' }
    $dir = Join-Path $env:LOCALAPPDATA 'deskside'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir 'deskside-ssh.pub'
    $pub = ((& op read $Settings.sshPublicKeyRef) | Out-String).Trim()
    if ($pub -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+') { throw '1Password did not return the deskside-ssh public key.' }
    $pub = ($pub -split '\s+')[0..1] -join ' '
    if (-not (Test-Path -LiteralPath $file) -or (Get-Content -LiteralPath $file -Raw).Trim() -ne "$pub deskside-ssh") {
        Set-Content -LiteralPath $file -Value "$pub deskside-ssh" -Encoding ascii
    }
    return $file
}

function Read-OpValue {
    <# One op read. op prints nothing when its 1Password approval times out, so an empty or malformed answer throws. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][string]$What, [string]$Pattern = '\S')
    if ($Ref -notlike 'op://*') { throw "meshcentral.json has no 1Password reference for $What." }
    $v = ((& op read $Ref) | Out-String).Trim()
    if (-not $v -or $v -notmatch $Pattern) { throw "1Password did not return $What (approve 1Password's prompt for op, then run again)." }
    return $v
}

function Get-UsbKitValue {
    <#
    .SYNOPSIS
        The values a USB kit carries: server URL, device group id, the deskside-ssh public key and the helper's name.
    .DESCRIPTION
        Read each time from meshcentral.json and 1Password (groupRef, or proofGroupRef with -Proof); never kept here.
    #>
    [CmdletBinding()]
    param($Settings = (Get-MeshSetting), [switch]$Proof)
    $refName = if ($Proof) { 'proofGroupRef' } else { 'groupRef' }
    $ref = [string]$Settings.$refName
    $group = Read-OpValue -Ref $ref -What 'the device group id' -Pattern '^[A-Za-z0-9$@]{64}$'
    $pub = Read-OpValue -Ref ([string]$Settings.sshPublicKeyRef) -What 'the deskside-ssh public key' -Pattern '^ssh-ed25519 [A-Za-z0-9+/=]+'
    $pub = (($pub -split '\s+')[0..1] -join ' ') + ' deskside-ssh'
    return [pscustomobject]@{
        Values = [ordered]@{ serverUrl = [string]$Settings.serverUrl; groupId = $group; publicKey = $pub; helperName = (Get-HelperName -Settings $Settings) }
        GroupRefName = $refName
    }
}

function Get-UsbKitRoot {
    <# The kit's folder: a removable drive's root (-Drive) or any folder (-Path, for tests and the Sandbox proof). #>
    [CmdletBinding()]
    param([string]$Drive, [string]$Path)
    if ($Drive) {
        $letter = $Drive.TrimEnd(':\').ToUpper()
        if ($letter -notmatch '^[A-Z]$') { throw "-Drive takes a drive letter such as E:." }
        $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        if (-not $vol) { throw "There is no drive $($letter):." }
        if ($vol.DriveType -ne 'Removable') { throw "Drive $($letter): isn't a removable drive (it is $($vol.DriveType)); deskside writes kits only to USB drives." }
        return "$($letter):\"
    }
    if (-not $Path) { throw 'Name the USB drive with -Drive (or a folder with -Path).' }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "The folder $Path doesn't exist." }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-UsbKitTargetFree {
    <#
    Refuses a target that still holds a kit's values (this kit's or the older single-script kit), or the results of a
    run that haven't been read back yet.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    if (Test-Path -LiteralPath (Join-Path $Root 'deskside\values.json')) { throw 'This drive still holds a kit with its values. Read it back first (Read-DesksideUsbKit.ps1), which wipes them.' }
    if (Test-Path -LiteralPath (Join-Path $Root 'deskside-enroll.ps1')) { throw 'This drive holds an older deskside kit, which may carry its values. Leave it alone; use another drive.' }
    $rb = Join-Path $Root 'readback.txt'
    if ((Test-Path -LiteralPath $rb) -and -not (Test-Path -LiteralPath (Join-Path $Root 'deskside\read-back.json'))) { throw 'This drive holds the results of a run that were not read back yet. Read it back first (Read-DesksideUsbKit.ps1).' }
}

function Find-UsbKitTrace {
    <# How many of the kit's files still contain the text (the group id), and the total count of files looked at. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Text)
    $files = @(Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath (Join-Path $Root 'deskside') -File -Recurse -Force -ErrorAction SilentlyContinue)
    $hits = 0
    foreach ($f in $files) {
        if ($f.Length -gt 64MB) { continue }
        # Both byte forms: a transcript can be UTF-16, the rest ASCII or UTF-8.
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        if ([Text.Encoding]::ASCII.GetString($bytes).Contains($Text) -or [Text.Encoding]::Unicode.GetString($bytes).Contains($Text)) { $hits++ }
    }
    return [pscustomobject]@{ Files = $files.Count; Hits = $hits }
}

function Remove-UsbKitValue {
    <# Overwrites values.json with zeros and deletes it. On flash media the old blocks may survive; the group id is replaceable. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Root)
    $p = Join-Path $Root 'deskside\values.json'
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    if ($PSCmdlet.ShouldProcess('values.json', 'Overwrite and delete')) {
        $len = (Get-Item -LiteralPath $p).Length
        [IO.File]::WriteAllBytes($p, (New-Object byte[] $len))
        Remove-Item -LiteralPath $p -Force
    }
    return $true
}

function ConvertFrom-UsbKitReadback {
    <# The readback's plain findings, without the node id, account or dates: what may be shown on screen. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Line)
    $show = New-Object System.Collections.Generic.List[string]
    # Each run of the kit appends a section that starts 'run: '; the last one is what the drive says now.
    $start = 0
    for ($i = 0; $i -lt $Line.Count; $i++) { if ($Line[$i] -like 'run: *') { $start = $i } }
    $runs = @($Line | Where-Object { $_ -like 'run: *' }).Count
    $show.Add("runs on this drive: $runs (showing the last)")
    $Line = @($Line | Select-Object -Skip $start)
    foreach ($l in $Line) {
        if ($l -match '^(stopped|smart app control|agent signature|deskside|removed|step [^:]+|service [^:]+|port 22 listens on|values):') { $show.Add($l) }
    }
    $consents = @($Line | Where-Object { $_ -like 'consent: *' }).Count
    $show.Add("consent scopes recorded: $consents")
    $show.Add('node id in readback: ' + [bool](@($Line | Where-Object { $_ -match '^node: node//' }).Count))
    return $show.ToArray()
}

function Get-HelperName {
    <# The name the person at the PC knows the helper by: meshcentral.json's helperName, never this repo. #>
    [CmdletBinding()]
    param($Settings = (Get-MeshSetting))
    $name = 'Your helper'
    if ($Settings.PSObject.Properties['helperName'] -and $Settings.helperName) { $name = [string]$Settings.helperName }
    if ($name -notmatch '^[A-Za-z0-9 .-]{1,40}$') { throw 'meshcentral.json helperName may hold only letters, digits, spaces, dots and hyphens (40 at most).' }
    return $name
}

function Get-NoticeActivity {
    <# The notice's activity word for a script under scripts\ (same mapping as the PC side's ConvertTo-NoticeActivity). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Script)
    $folder = ($Script -split '\\')[0]
    $name = ($Script -split '\\')[-1]
    if ($name -match 'Undo') { return 'undo' }
    switch ($folder) {
        'diagnose' { return 'diagnose' }
        'settings' { return 'settings' }
        'onboard' { return 'onboard' }
        'install' { return 'onboard' }
        'remote' { return 'remote' }
    }
    return 'task'
}

function Send-RemoteNotice {
    <#
    .SYNOPSIS
        Runs scripts\remote\Send-HelperNotice.ps1 on the PC over SSH and returns its counts (signedIn, shown).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Ssh,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][ValidateSet('Start', 'End')][string]$Phase,
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][string]$HelperName
    )
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\deskside\app\scripts\remote\Send-HelperNotice.ps1' -Phase $Phase -Activity $Activity -HelperName '$HelperName'"
    $o = (& ssh.exe @Ssh $Target $cmd 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "The $Phase notice could not be sent (exit $LASTEXITCODE)." }
    $line = ($o -split "`r?`n" | Where-Object { $_ -match '^\{.*"phase"' } | Select-Object -Last 1)
    if (-not $line) { throw "The $Phase notice gave no counts." }
    return ($line | ConvertFrom-Json)
}

Export-ModuleMember -Function *
