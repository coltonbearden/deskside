#Requires -Version 7.0
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $Root 'scripts\common\Deskside.Common.psm1') -Force
}

Describe 'Test-ManagedDevice (the work-or-school check)' {
    BeforeEach {
        Mock -ModuleName Deskside.Common Get-CimInstance { [pscustomobject]@{ PartOfDomain = $false } } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
        Mock -ModuleName Deskside.Common Get-DsregStatus { @{ AzureAdJoined = 'NO'; EnterpriseJoined = 'NO'; DomainJoined = 'NO' } }
        Mock -ModuleName Deskside.Common Get-MdmEnrollment { @() }
    }
    It 'is not managed for a home PC' {
        (Test-ManagedDevice).IsManaged | Should -BeFalse
    }
    It 'is managed when joined to a domain' {
        Mock -ModuleName Deskside.Common Get-CimInstance { [pscustomobject]@{ PartOfDomain = $true } } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
        (Test-ManagedDevice).IsManaged | Should -BeTrue
    }
    It 'is managed when joined to Microsoft Entra' {
        Mock -ModuleName Deskside.Common Get-DsregStatus { @{ AzureAdJoined = 'YES' } }
        $m = Test-ManagedDevice
        $m.IsManaged | Should -BeTrue
        $m.Reasons | Should -Contain 'joined to Microsoft Entra ID'
    }
    It 'is managed when enrolled in MDM' {
        Mock -ModuleName Deskside.Common Get-MdmEnrollment { @([pscustomobject]@{ ProviderID = 'MS DM Server'; EnrollmentType = 6; HasUpn = $true }) }
        (Test-ManagedDevice).IsManaged | Should -BeTrue
    }
    It 'treats an unreadable domain state as managed' {
        Mock -ModuleName Deskside.Common Get-CimInstance { throw 'no WMI' } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
        (Test-ManagedDevice).IsManaged | Should -BeTrue
    }
    It 'Assert-NotManaged throws on a managed PC' {
        Mock -ModuleName Deskside.Common Get-DsregStatus { @{ AzureAdJoined = 'YES' } }
        { Assert-NotManaged } | Should -Throw '*work or school*'
    }
}

Describe 'Get-MdmEnrollment skips Windows built-in enrollments' {
    BeforeAll {
        $script:Base = 'HKCU:\Software\deskside-tests\Enrollments'
        Remove-Item $Base -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($p in 'Local Authority', 'Deploy Authority', 'Cloud Authority') {
            $k = New-Item -Path (Join-Path $Base ([guid]::NewGuid())) -Force
            New-ItemProperty -LiteralPath $k.PSPath -Name ProviderID -Value $p | Out-Null
            New-ItemProperty -LiteralPath $k.PSPath -Name EnrollmentState -Value 1 -PropertyType DWord | Out-Null
        }
    }
    AfterAll { Remove-Item 'HKCU:\Software\deskside-tests' -Recurse -Force -ErrorAction SilentlyContinue }
    It 'returns nothing for the built-in providers' {
        @(Get-MdmEnrollment -Base $Base).Count | Should -Be 0
    }
    It 'returns a real MDM provider' {
        $k = New-Item -Path (Join-Path $Base ([guid]::NewGuid())) -Force
        New-ItemProperty -LiteralPath $k.PSPath -Name ProviderID -Value 'MS DM Server' | Out-Null
        New-ItemProperty -LiteralPath $k.PSPath -Name EnrollmentState -Value 1 -PropertyType DWord | Out-Null
        @(Get-MdmEnrollment -Base $Base).Count | Should -Be 1
    }
}

Describe 'Consent' {
    BeforeAll { $env:DESKSIDE_DATA = Join-Path $TestDrive 'data' }
    AfterAll { Remove-Item Env:\DESKSIDE_DATA -ErrorAction SilentlyContinue }
    BeforeEach {
        Remove-Item $env:DESKSIDE_DATA -Recurse -Force -ErrorAction SilentlyContinue
        Mock -ModuleName Deskside.Common Test-ManagedDevice { [pscustomobject]@{ IsManaged = $false; Reasons = @() } }
    }
    It 'refuses a scope the owner has not agreed to' {
        { Assert-Consent -Scope onboard } | Should -Throw '*has not agreed*'
    }
    It 'records a yes without any name and then allows the scope' {
        Grant-Consent -Scope onboard, remote -Confirmed | Out-Null
        { Assert-Consent -Scope onboard } | Should -Not -Throw
        { Assert-Consent -Scope remote } | Should -Not -Throw
        $raw = Get-Content (Join-Path $env:DESKSIDE_DATA 'consent.json') -Raw
        $raw | Should -Not -Match ([regex]::Escape($env:USERNAME))
        $raw | Should -Not -Match ([regex]::Escape($env:COMPUTERNAME))
    }
    It 'keeps earlier scopes when a new one is granted' {
        Grant-Consent -Scope diagnose -Confirmed | Out-Null
        Grant-Consent -Scope onboard -Confirmed | Out-Null
        { Assert-Consent -Scope diagnose } | Should -Not -Throw
    }
    It 'revokes a scope' {
        Grant-Consent -Scope onboard, remote -Confirmed | Out-Null
        Revoke-Consent -Scope remote
        { Assert-Consent -Scope remote } | Should -Throw
        { Assert-Consent -Scope onboard } | Should -Not -Throw
    }
    It 'refuses to record consent on a managed PC' {
        Mock -ModuleName Deskside.Common Test-ManagedDevice { [pscustomobject]@{ IsManaged = $true; Reasons = @('enrolled in device management (MDM)') } }
        { Grant-Consent -Scope onboard -Confirmed } | Should -Throw '*work or school*'
    }
}

Describe 'Registry before-state and restore' {
    BeforeAll { $script:Key = 'HKCU:\Software\deskside-tests\Reg' }
    AfterAll { Remove-Item 'HKCU:\Software\deskside-tests' -Recurse -Force -ErrorAction SilentlyContinue }
    BeforeEach { Remove-Item 'HKCU:\Software\deskside-tests' -Recurse -Force -ErrorAction SilentlyContinue }
    It 'restores a value that existed' {
        New-Item $Key -Force | Out-Null
        New-ItemProperty $Key -Name V -Value 5 -PropertyType DWord | Out-Null
        $s = Get-RegistryState -Path $Key -Name V
        Set-RegistryValueSafe -Path $Key -Name V -Value 9 -Kind DWord
        (Get-ItemProperty $Key).V | Should -Be 9
        Restore-RegistryState -State ([pscustomobject]$s)
        (Get-ItemProperty $Key).V | Should -Be 5
    }
    It 'removes a value and its new key that did not exist before' {
        $s = Get-RegistryState -Path $Key -Name V
        Set-RegistryValueSafe -Path $Key -Name V -Value 'x' -Kind String
        Restore-RegistryState -State ([pscustomobject]$s)
        Test-Path $Key | Should -BeFalse
    }
    It 'does nothing under -WhatIf' {
        Set-RegistryValueSafe -Path $Key -Name V -Value 1 -Kind DWord -WhatIf
        Test-Path $Key | Should -BeFalse
    }
}

Describe 'Run records' {
    BeforeAll { $env:DESKSIDE_DATA = Join-Path $TestDrive 'data2' }
    AfterAll { Remove-Item Env:\DESKSIDE_DATA -ErrorAction SilentlyContinue }
    It 'writes a versioned record, a summary and counts' {
        $run = New-DesksideRun -Kind 'test' -NoTranscript
        Add-Finding -Run $run -Id 'a' -Rank FixNow -Text 'First.'
        Add-Finding -Run $run -Id 'b' -Rank Info -Text 'Second.'
        Invoke-Section -Run $run -Name 'ok' -ScriptBlock { [ordered]@{ x = 1 } }
        Invoke-Section -Run $run -Name 'bad' -ScriptBlock { throw 'boom' }
        $out = Complete-DesksideRun -Run $run 6>$null
        $rec = Get-Content $out.Record -Raw | ConvertFrom-Json
        $rec.schema | Should -Be 'deskside.record/v1'
        $rec.counts.FixNow | Should -Be 1
        $rec.errors[0].section | Should -Be 'bad'
        $rec.data.ok.x | Should -Be 1
        Get-Content $out.Summary -Raw | Should -Match '## Fix now'
    }
    It 'records undo entries in order' {
        $run = New-DesksideRun -Kind 'test2' -NoTranscript
        Save-BeforeState -Run $run -ItemId 'one' -Undo @{ type = 'note'; text = 'a' }
        Save-BeforeState -Run $run -ItemId 'two' -Undo @{ type = 'note'; text = 'b' }
        $u = @(Get-Content (Join-Path $run.Folder 'undo.json') -Raw | ConvertFrom-Json)
        $u.Count | Should -Be 2
        $u[1].item | Should -Be 'two'
    }
}
