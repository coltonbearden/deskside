#Requires -Version 7.0
# Runs the real PC-side scripts under Windows PowerShell 5.1 and PowerShell 7. Read-only, or -WhatIf, or inside a
# throwaway data folder: nothing here changes the machine running the tests.

BeforeDiscovery {
    $script:Engines = @(
        @{ Engine = 'PowerShell 7'; Exe = (Join-Path $PSHOME 'pwsh.exe') }
        @{ Engine = 'Windows PowerShell 5.1'; Exe = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }
    )
}

Describe 'On <Engine>' -Tag Integration -ForEach $Engines {
    BeforeAll {
        $script:Root = Split-Path -Parent $PSScriptRoot
        $script:Data = Join-Path $TestDrive 'data'
        $env:DESKSIDE_DATA = $Data
        function Invoke-Engine([string]$Script, [string[]]$Arguments) {
            $out = & $Exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root $Script) @Arguments 2>&1 | Out-String
            return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
        }
    }
    AfterAll { Remove-Item Env:\DESKSIDE_DATA -ErrorAction SilentlyContinue }

    It 'diagnose writes a valid record and prints counts only' {
        $dir = Join-Path $TestDrive 'diag'
        $r = Invoke-Engine 'scripts\diagnose\Invoke-Diagnose.ps1' @('-OutputDirectory', $dir, '-Quick')
        $r.Code | Should -Be 0
        $rec = Get-Content (Join-Path $dir 'record.json') -Raw | ConvertFrom-Json
        $rec.schema | Should -Be 'deskside.record/v1'
        $rec.kind | Should -Be 'diagnose'
        @($rec.findings).Count | Should -BeGreaterThan 3
        foreach ($s in 'os', 'security', 'disks', 'performance', 'startup', 'events', 'backups', 'account', 'apps') { $rec.data.PSObject.Properties.Name | Should -Contain $s }
        $r.Output | Should -Match 'Fix now: \d+'
        $r.Output | Should -Not -Match ([regex]::Escape($env:USERNAME))
        $r.Output | Should -Not -Match ([regex]::Escape($env:COMPUTERNAME))
        Test-Path (Join-Path $dir 'summary.md') | Should -BeTrue
        $script:Record = Join-Path $dir 'record.json'
    }

    It 'screen-only diagnose writes nothing to disk' {
        Remove-Item $Data -Recurse -Force -ErrorAction SilentlyContinue
        $r = Invoke-Engine 'scripts\diagnose\Invoke-Diagnose.ps1' @('-ScreenOnly', '-Quick')
        $r.Code | Should -Be 0
        Test-Path $Data | Should -BeFalse
    }

    It 'the change list holds only recommended or questionable items' {
        $r = Invoke-Engine 'scripts\onboard\New-ChangeList.ps1' @('-Record', $Record)
        $r.Code | Should -Be 0
        $list = Get-Content (Join-Path (Split-Path $Record) 'changelist.json') -Raw | ConvertFrom-Json
        $list.schema | Should -Be 'deskside.changelist/v1'
        foreach ($i in @($list.items)) { $i.verdict | Should -BeIn @('recommended', 'questionable') }
    }

    It 'a change script refuses to run without consent' {
        Remove-Item $Data -Recurse -Force -ErrorAction SilentlyContinue
        $r = Invoke-Engine 'scripts\settings\Set-Baseline.ps1' @('-ItemId', 'show-extensions', '-WhatIf')
        $r.Code | Should -Not -Be 0
        $r.Output | Should -Match 'has not agreed'
    }

    It 'saves every before-state flat and undoes them all (Windows PowerShell 5.1 nests JSON arrays if read naively)' {
        $dir = Join-Path $TestDrive ('undo-' + [guid]::NewGuid())
        try {
            $r = Invoke-Engine 'tests\fixtures\Invoke-UndoRoundTrip.ps1' @('-Folder', $dir)
            $r.Code | Should -Be 0
            $u = @((Get-Content (Join-Path $dir 'undo.json') -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
            $u.Count | Should -Be 3
            @($u | ForEach-Object { $_.item }) | Should -Be @('value-A', 'value-B', 'value-C')
            $r = Invoke-Engine 'scripts\settings\Undo-DesksideRun.ps1' @('-Run', $dir)
            $r.Code | Should -Be 0
            $k = Get-Item 'HKCU:\Software\deskside-tests\Undo'
            $k.GetValue('A') | Should -Be 1
            $k.GetValueNames() | Should -Not -Contain 'B'
            $k.GetValueNames() | Should -Not -Contain 'C'
        } finally { Remove-Item 'HKCU:\Software\deskside-tests' -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'with consent, Set-Baseline -WhatIf changes nothing and reports what it would do' {
        $c = Invoke-Engine 'scripts\onboard\Grant-Consent.ps1' @('-Scope', 'onboard', '-Confirmed')
        $c.Code | Should -Be 0
        $before = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -ErrorAction SilentlyContinue).HideFileExt
        $dir = Join-Path $TestDrive ('settings-' + [guid]::NewGuid())
        $r = Invoke-Engine 'scripts\settings\Set-Baseline.ps1' @('-ItemId', 'show-extensions,storage-sense,ads-tips-off', '-WhatIf', '-OutputDirectory', $dir)
        $r.Code | Should -Be 0
        (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -ErrorAction SilentlyContinue).HideFileExt | Should -Be $before
        Test-Path (Join-Path $dir 'undo.json') | Should -BeFalse
        $rec = Get-Content (Join-Path $dir 'record.json') -Raw | ConvertFrom-Json
        @($rec.changes).Count | Should -BeGreaterThan 0
    }
}
