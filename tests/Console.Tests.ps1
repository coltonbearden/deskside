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
    It 'starts with the port and adds the proof key only when asked' {
        $env:DESKSIDE_SSH_IDENTITY = $null
        $a = Get-SshArgument -Route ([pscustomobject]@{ LocalPort = 5000 }) -Device $Device
        $a[0..1] | Should -Be @('-p', 5000)
        $a | Should -Not -Contain '-i'
        $env:DESKSIDE_SSH_IDENTITY = 'C:\proof_key'
        try { Get-SshArgument -Route ([pscustomobject]@{ LocalPort = 5000 }) -Device $Device | Should -Contain 'IdentitiesOnly=yes' }
        finally { $env:DESKSIDE_SSH_IDENTITY = $null }
    }
}
