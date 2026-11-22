#Requires -Version 7.0
BeforeDiscovery {
    $root = Split-Path -Parent $PSScriptRoot
    $script:PcScripts = @(Get-ChildItem (Join-Path $root 'scripts') -Recurse -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '\\scripts\\console\\' } |
        ForEach-Object { @{ Name = $_.FullName.Substring($root.Length + 1); Path = $_.FullName } }) + @(@{ Name = 'bootstrap.ps1'; Path = (Join-Path $root 'bootstrap.ps1') }) +
        @(Get-ChildItem (Join-Path $root 'usb-kit') -Recurse -Include *.ps1, *.cmd | ForEach-Object { @{ Name = $_.FullName.Substring($root.Length + 1); Path = $_.FullName } })
    $changeNames = 'Install-Profile', 'Install-WAU', 'Set-Baseline', 'Remove-Apps', 'Install-MeshAgent', 'Enable-LoopbackSsh', 'Install-HelpButton'
    $script:ChangeScripts = @(Get-ChildItem (Join-Path $root 'scripts') -Recurse -Filter *.ps1 | Where-Object { $changeNames -contains $_.BaseName } |
        ForEach-Object { @{ Name = $_.BaseName; Path = $_.FullName } })
    $script:AllScripts = @(Get-ChildItem $root -Recurse -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        ForEach-Object { @{ Name = $_.FullName.Substring($root.Length + 1); Path = $_.FullName } })
}

Describe '<Name> parses' -ForEach $AllScripts {
    It 'has no syntax errors' {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe 'PC-side <Name>' -ForEach $PcScripts {
    It 'is ASCII only (Windows PowerShell 5.1 reads files without a BOM as ANSI)' {
        @([IO.File]::ReadAllBytes($Path) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It 'needs no PowerShell 7 (#Requires -Version 5.1 or none)' {
        (Get-Content $Path -Raw) | Should -Not -Match '#Requires -Version 7'
    }
}

Describe 'Change script <Name>' -ForEach $ChangeScripts {
    BeforeAll {
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $script:Text = Get-Content $Path -Raw
    }
    It 'supports -WhatIf' {
        $attr = $Ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
        ($attr.NamedArguments | Where-Object ArgumentName -eq 'SupportsShouldProcess') | Should -Not -BeNullOrEmpty
    }
    It 'stops on a work or school PC before anything else' {
        $Text | Should -Match 'Assert-NotManaged'
        if ($Text.Contains('New-DesksideRun')) { $Text.IndexOf('Assert-NotManaged') | Should -BeLessThan $Text.IndexOf('New-DesksideRun') }
    }
    It 'needs the owner''s consent' {
        $Text | Should -Match 'Assert-Consent -Scope (onboard|remote)'
    }
}

Describe 'Remote scope' {
    It 'the agent and SSH scripts need the remote scope, not just onboard' {
        foreach ($n in 'Install-MeshAgent', 'Enable-LoopbackSsh', 'Install-HelpButton', 'Send-HelperNotice') {
            $t = Get-Content (Get-ChildItem (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\remote') -Filter "$n.ps1").FullName -Raw
            $t | Should -Match 'Assert-Consent -Scope remote'
        }
    }
    It 'SSH is configured for 127.0.0.1 and keys only' {
        $t = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\remote\Enable-LoopbackSsh.ps1') -Raw
        $t | Should -Match "'ListenAddress 127\.0\.0\.1'"
        $t | Should -Match "'PasswordAuthentication no'"
        $t | Should -Match "'AuthenticationMethods publickey'"
    }
}

Describe 'bootstrap.ps1' {
    BeforeAll { $script:B = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap.ps1') -Raw }
    It 'checks work or school before it downloads or writes anything' {
        $B.IndexOf('AzureAdJoined') | Should -BeLessThan $B.IndexOf('Invoke-WebRequest')
        $B.IndexOf('$reasons.Count -gt 0') | Should -BeLessThan $B.IndexOf("Join-Path `$env:ProgramData 'deskside'")
    }
    It 'only skips prompts inside Windows Sandbox' {
        $B | Should -Match "DESKSIDE_SANDBOX_PROOF -eq '1' -and \`$env:USERNAME -eq 'WDAGUtilityAccount'"
    }
}

Describe 'The help button' {
    BeforeAll {
        $r = Split-Path -Parent $PSScriptRoot
        $script:Install = Get-Content (Join-Path $r 'scripts\remote\Install-HelpButton.ps1') -Raw
        $script:Common = Get-Content (Join-Path $r 'scripts\common\Deskside.Common.psm1') -Raw
        $script:Ask = Get-Content (Join-Path $r 'scripts\remote\Ask-ForHelp.ps1') -Raw
        $script:Remove = Get-Content (Join-Path $r 'scripts\remote\Remove-RemoteHelp.ps1') -Raw
    }
    It 'downloads only the monitor-only Assistant, which carries no server settings' {
        $Common | Should -Match "id=10006&meshid=' \+ \[uri\]::EscapeDataString\(\`$GroupId\) \+ '&ac=4'"
        $Common | Should -Match "Contains\('MeshServer='\)"
    }
    It 'starts it with -noupdate everywhere' {
        $Install | Should -Match "-noupdate"
        $Ask | Should -Match "'-noupdate'"
    }
    It 'sends one line, without quotes or backslashes' {
        $Ask | Should -Match "-replace '\[\\r\\n"
        $Ask | Should -Match 'Test-AgentConnected'
    }
    It 'is taken away by Remove-RemoteHelp, which checks each piece' {
        foreach ($w in 'help button folder', 'help button running', 'help button task', 'help button shortcut', 'help button setting') { $Remove | Should -Match $w }
        $Remove | Should -Match 'reg.exe load'
    }
}

Describe 'The scheduled check stays silent' {
    It 'Invoke-HealthSweep never sends a notice' {
        $t = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'health\Invoke-HealthSweep.ps1') -Raw
        $t | Should -Not -Match 'Notice|SSH_CONNECTION|DESKSIDE_VIA'
    }
}