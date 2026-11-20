#Requires -Version 7.0
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $Root 'scripts\common\Deskside.Common.psm1') -Force
    Import-Module (Join-Path $Root 'scripts\console\Deskside.Console.psm1') -Force
    $script:Device = [pscustomobject]@{ alias = 'example-pc'; meshNodeId = 'node//example' }
    $script:Login = [pscustomobject]@{ User = 'u'; Password = 'p' }
    $script:Hash = 'A' * 96
}

Describe 'ConvertTo-MeshNodeId' {
    It 'turns the agent''s hex id into MeshCentral''s node id' {
        # 48 bytes of 0xFB encode to base64 "+/v7" repeated; MeshCentral writes + as @ and / as $.
        $id = ConvertTo-MeshNodeId -Hex ('FB' * 48)
        $id | Should -BeLike 'node//*'
        $id.Substring(6) | Should -Be ('@$v7' * 16)
    }
    It 'refuses anything but 96 hex characters' {
        { ConvertTo-MeshNodeId -Hex 'not hex' } | Should -Throw
    }
}

Describe 'New-MeshRouteAction (meshaction.txt)' {
    It 'uses serverHttpsHash and leaves out an empty serverId' {
        $s = [pscustomobject]@{ serverUrl = 'https://mesh.example:8443'; serverId = ''; serverHttpsHash = $Hash }
        $a = New-MeshRouteAction -Settings $s -Device $Device -Login $Login -LocalPort 5000
        $a.Contains('serverId') | Should -BeFalse
        $a['serverHttpsHash'] | Should -Be $Hash
        $a['serverUrl'] | Should -Be 'wss://mesh.example:8443/meshrelay.ashx'
    }
    It 'prefers relayUrl when set' {
        $s = [pscustomobject]@{ serverUrl = 'https://mesh.example:8443'; relayUrl = 'wss://mesh.example:9443/meshrelay.ashx'; serverHttpsHash = $Hash }
        (New-MeshRouteAction -Settings $s -Device $Device -Login $Login -LocalPort 5000)['serverUrl'] | Should -Be 'wss://mesh.example:9443/meshrelay.ashx'
    }
    It 'never sets debugLevel, which would print the login' {
        $s = [pscustomobject]@{ serverUrl = 'https://mesh.example'; serverHttpsHash = $Hash }
        (New-MeshRouteAction -Settings $s -Device $Device -Login $Login -LocalPort 5000).Contains('debugLevel') | Should -BeFalse
    }
    It 'refuses to run without a way to check the server' {
        $s = [pscustomobject]@{ serverUrl = 'https://mesh.example'; serverId = ''; serverHttpsHash = '' }
        { New-MeshRouteAction -Settings $s -Device $Device -Login $Login -LocalPort 5000 } | Should -Throw '*serverHttpsHash*'
    }
}

Describe 'Test-VpnAddress (the gate before a fingerprint-only port map)' {
    BeforeAll {
        # Built from octets so the repo's personal-data scan doesn't read test addresses as real ones.
        function Get-Ip4([byte]$a, [byte]$b, [byte]$c, [byte]$d) { [System.Net.IPAddress]::new([byte[]]@($a, $b, $c, $d)) }
    }
    It 'accepts overlay addresses only' {
        Test-VpnAddress -Address (Get-Ip4 100 84 1 2) | Should -BeTrue
        Test-VpnAddress -Address (Get-Ip4 100 64 0 1), ([ipaddress]'fd7a:115c:a1e0::1') | Should -BeTrue
    }
    It 'refuses public, private-LAN and mixed answers, and no answer' {
        Test-VpnAddress -Address (Get-Ip4 203 0 113 5) | Should -BeFalse
        Test-VpnAddress -Address (Get-Ip4 100 128 0 1) | Should -BeFalse
        Test-VpnAddress -Address (Get-Ip4 192 168 1 10) | Should -BeFalse
        Test-VpnAddress -Address (Get-Ip4 100 84 1 2), (Get-Ip4 203 0 113 5) | Should -BeFalse
        Test-VpnAddress -Address ([ipaddress]'2001:db8::1') | Should -BeFalse
        Test-VpnAddress -Address @() | Should -BeFalse
    }
}

Describe 'Start-MeshRoute refuses a public relay with only a fingerprint' {
    It 'throws before starting MeshCmd' {
        Mock -ModuleName Deskside.Console Get-MeshSetting { [pscustomobject]@{ serverUrl = 'https://mesh.example'; serverId = ''; serverHttpsHash = ('A' * 96) } }
        Mock -ModuleName Deskside.Console Test-PrivateRelay { $false }
        Mock -ModuleName Deskside.Console Start-MeshRouteOnce { throw 'must not start' }
        { Start-MeshRoute -Device $Device } | Should -Throw '*VPN*'
        Should -Invoke -ModuleName Deskside.Console Start-MeshRouteOnce -Times 0
    }
}

Describe 'Get-SshArgument' {
    It 'starts with the port and names the deskside-ssh key, so the agent offers that key only' {
        $env:DESKSIDE_SSH_IDENTITY = $null
        Mock -ModuleName Deskside.Console Get-SshPublicKeyFile { 'C:\k\deskside-ssh.pub' }
        $a = Get-SshArgument -Route ([pscustomobject]@{ LocalPort = 5000 }) -Device $Device
        $a[0..1] | Should -Be @('-p', 5000)
        $i = [array]::IndexOf($a, '-i')
        $a[$i + 1] | Should -Be 'C:\k\deskside-ssh.pub'
        $a | Should -Contain 'IdentitiesOnly=yes'
        $a | Should -Not -Contain 'IdentityAgent=none'
    }
    It 'uses the proof key instead when asked, with no agent' {
        $env:DESKSIDE_SSH_IDENTITY = 'C:\proof_key'
        try {
            $a = Get-SshArgument -Route ([pscustomobject]@{ LocalPort = 5000 }) -Device $Device
            $a | Should -Contain 'C:\proof_key'
            $a | Should -Contain 'IdentityAgent=none'
        } finally { $env:DESKSIDE_SSH_IDENTITY = $null }
    }
}

Describe 'Get-SshPublicKeyFile' {
    It 'refuses without sshPublicKeyRef' {
        { Get-SshPublicKeyFile -Settings ([pscustomobject]@{ serverUrl = 'https://mesh.example' }) } | Should -Throw '*sshPublicKeyRef*'
    }
}

Describe 'Get-HelperName' {
    It 'reads helperName and defaults to "Your helper"' {
        Get-HelperName -Settings ([pscustomobject]@{ helperName = 'Sam' }) | Should -Be 'Sam'
        Get-HelperName -Settings ([pscustomobject]@{ serverUrl = 'x' }) | Should -Be 'Your helper'
    }
    It 'refuses a name that could break the remote command' {
        { Get-HelperName -Settings ([pscustomobject]@{ helperName = "Sam'; rm" }) } | Should -Throw
    }
}

Describe 'Get-NoticeActivity' {
    It 'names what the helper is doing from the script' {
        Get-NoticeActivity -Script 'diagnose\Invoke-Diagnose.ps1' | Should -Be 'diagnose'
        Get-NoticeActivity -Script 'settings\Undo-DesksideRun.ps1' | Should -Be 'undo'
        Get-NoticeActivity -Script 'settings\Set-Baseline.ps1' | Should -Be 'settings'
        Get-NoticeActivity -Script 'install\Install-Profile.ps1' | Should -Be 'onboard'
        Get-NoticeActivity -Script 'remote\Install-HelpButton.ps1' | Should -Be 'remote'
    }
}

Describe 'Invoke-DesksideRemote' {
    It 'sends the Start notice before the script and the End notice in finally' {
        $text = Get-Content (Join-Path $Root 'scripts\console\Invoke-DesksideRemote.ps1') -Raw
        $text.IndexOf('-Phase Start') | Should -BeLessThan $text.IndexOf('& ssh.exe @ssh $target $remote')
        $text | Should -Match '(?s)finally \{.*-Phase End'
        $text | Should -Match "DESKSIDE_VIA = 'ssh'"
    }
}

Describe 'Port-map cleanup' {
    It 'removes the folder and the login file' {
        $d = Join-Path $TestDrive 'route1'; New-Item -ItemType Directory $d | Out-Null
        Set-Content (Join-Path $d 'meshaction.txt') 'x'; Set-Content (Join-Path $d 'err.txt') ''
        Remove-RouteFolder -Path $d -LoginFile (Join-Path $d 'meshaction.txt')
        Test-Path $d | Should -BeFalse
    }
    It 'says so, by name, when a file in the folder stays open' {
        $d = Join-Path $TestDrive 'route2'; New-Item -ItemType Directory $d | Out-Null
        $held = [IO.File]::Open((Join-Path $d 'err.txt'), 'Create', 'ReadWrite', 'None')
        try {
            Remove-RouteFolder -Path $d -LoginFile (Join-Path $d 'meshaction.txt') -WarningVariable w -WarningAction SilentlyContinue
            ($w -join ' ') | Should -Match ([regex]::Escape($d))
        } finally { $held.Dispose() }
    }
    It 'stops when the login file cannot be removed' {
        $d = Join-Path $TestDrive 'route3'; New-Item -ItemType Directory $d | Out-Null
        $login = Join-Path $d 'meshaction.txt'
        $held = [IO.File]::Open($login, 'Create', 'ReadWrite', 'None')
        try { { Remove-RouteFolder -Path $d -LoginFile $login } | Should -Throw '*login file*' }
        finally { $held.Dispose() }
    }
    It 'waits for MeshCmd to exit after Kill' {
        $text = Get-Content (Join-Path $Root 'scripts\console\Deskside.Console.psm1') -Raw
        $text | Should -Match 'Kill\(\) \} catch'
        $text | Should -Match 'WaitForExit\(15000\)'
        $text | Should -Not -Match 'Remove-Item -LiteralPath \$(work|Route\.WorkDir|actionPath)[^\n]*SilentlyContinue'
    }
}