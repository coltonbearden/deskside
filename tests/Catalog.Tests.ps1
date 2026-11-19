#Requires -Version 7.0
BeforeDiscovery {
    $root = Split-Path -Parent $PSScriptRoot
    $script:JsonFiles = @(Get-ChildItem (Join-Path $root 'catalog') -Recurse -Filter *.json | ForEach-Object { @{ Name = $_.FullName.Substring($root.Length + 1); Path = $_.FullName } })
    $script:SettingItems = @((Get-Content (Join-Path $root 'catalog\settings.json') -Raw | ConvertFrom-Json).items | ForEach-Object { @{ Id = $_.id; Item = $_ } })
    $script:Profiles = @(Get-ChildItem (Join-Path $root 'catalog\profiles') -Filter *.json | ForEach-Object { @{ Name = $_.BaseName; Path = $_.FullName } })
}

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Checks = (Get-Content (Join-Path $Root 'catalog\checks.json') -Raw | ConvertFrom-Json).checks
    $script:Settings = (Get-Content (Join-Path $Root 'catalog\settings.json') -Raw | ConvertFrom-Json).items
}

Describe 'Catalog file <Name>' -ForEach $JsonFiles {
    It 'is valid JSON with a schema' {
        $j = Get-Content $Path -Raw | ConvertFrom-Json
        $j.schema | Should -Match '^deskside\.[a-z-]+/v\d+$'
    }
}

Describe 'Setting <Id>' -ForEach $SettingItems {
    It 'says what it does, why, where Microsoft documents it, and how it is undone' {
        $Item.what | Should -Not -BeNullOrEmpty
        $Item.why | Should -Not -BeNullOrEmpty
        $Item.undo | Should -Not -BeNullOrEmpty
        $Item.source | Should -Match '^https://(learn|support)\.microsoft\.com/'
    }
    It 'has a known type' {
        $Item.type | Should -BeIn @('registry', 'handler')
        if ($Item.type -eq 'handler') { $Item.handler | Should -BeIn @('SystemProtection', 'DefenderPua') }
        else { foreach ($v in $Item.values) { $v.path | Should -Match '^HK(LM|CU):\\'; $v.kind | Should -BeIn @('DWord', 'String') } }
    }
}

Describe 'Profile <Name>' -ForEach $Profiles {
    BeforeAll { $script:P = Get-Content $Path -Raw | ConvertFrom-Json }
    It 'names only settings that exist' {
        foreach ($s in @($P.settings)) { $Settings.id | Should -Contain $s }
    }
    It 'installs apps by winget id' {
        foreach ($a in @($P.apps)) { $a.id | Should -Match '^[A-Za-z0-9]+(\.[A-Za-z0-9-]+)+$' }
    }
    It 'does not install Claude Code (it runs on the helper''s machine only)' {
        (Get-Content $Path -Raw) | Should -Not -Match '(?i)anthropic|claude'
    }
    It 'includes only profiles that exist' {
        if ($P.PSObject.Properties['includes']) { foreach ($i in @($P.includes)) { Test-Path (Join-Path $Root "catalog\profiles\$i.json") | Should -BeTrue } }
    }
}

Describe 'The everyone profile' {
    It 'matches the list Colton marked on 2026-11-19' {
        $e = Get-Content (Join-Path $Root 'catalog\profiles\everyone.json') -Raw | ConvertFrom-Json
        @($e.apps.id) | Should -Be @('Romanitho.Winget-AutoUpdate', '7zip.7zip', 'VideoLAN.VLC', 'Bitwarden.Bitwarden', 'Google.Chrome', 'SumatraPDF.SumatraPDF')
        @($e.settings) | Should -Be @('restore-points', 'defender-pua', 'smartscreen-apps', 'restart-notice', 'show-extensions', 'storage-sense', 'ads-tips-off')
    }
}

Describe 'Checks' {
    It 'every check id the scripts use is in checks.json' {
        $used = Select-String -Path (Join-Path $Root 'scripts\diagnose\*.ps1') -Pattern "Add-Check \`$run '([a-z0-9.-]+)'" -AllMatches |
            ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $used.Count | Should -BeGreaterThan 30
        foreach ($u in $used) { $Checks.PSObject.Properties.Name | Should -Contain $u }
    }
    It 'every check has a known rank and a sentence' {
        foreach ($p in $Checks.PSObject.Properties) {
            $p.Value.rank | Should -BeIn @('FixNow', 'FixSoon', 'NiceToHave', 'Info')
            $p.Value.text | Should -Match '\.$'
        }
    }
}

Describe 'Pattern lists' {
    It 'junk and remote-tool patterns are valid regular expressions' {
        $all = @((Get-Content (Join-Path $Root 'catalog\junk.json') -Raw | ConvertFrom-Json).items.pattern) +
            @((Get-Content (Join-Path $Root 'catalog\remote-tools.json') -Raw | ConvertFrom-Json).items.pattern)
        foreach ($p in $all) { { [regex]::new($p) } | Should -Not -Throw }
    }
    It 'recognizes common remote tools and junk' {
        $rt = (Get-Content (Join-Path $Root 'catalog\remote-tools.json') -Raw | ConvertFrom-Json).items
        @($rt | Where-Object { 'AnyDesk' -match $_.pattern }).Count | Should -Be 1
        @($rt | Where-Object { 'TeamViewer 15' -match $_.pattern }).Count | Should -Be 1
        $junk = (Get-Content (Join-Path $Root 'catalog\junk.json') -Raw | ConvertFrom-Json).items
        @($junk | Where-Object { 'McAfee LiveSafe' -match $_.pattern }).verdict | Should -Be 'questionable'
        @($junk | Where-Object { 'Driver Booster 11' -match $_.pattern }).verdict | Should -Be 'recommended'
    }
}

Describe 'Windows support dates' {
    It 'are copied from Microsoft with the date they were read' {
        $l = Get-Content (Join-Path $Root 'catalog\lifecycle.json') -Raw | ConvertFrom-Json
        $l.readOn | Should -Match '^\d{4}-\d{2}-\d{2}$'
        ($l.windows11HomePro | Where-Object version -eq '24H2').end | Should -Be '2026-10-14'
        ($l.windows11HomePro | Where-Object version -eq '25H2').end | Should -Be '2027-10-13'
        $l.windows10.consumerEsuEnd | Should -Be '2027-10-12'
    }
}
