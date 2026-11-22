#Requires -Version 7.0
BeforeDiscovery {
    # The builder carries the committed HEAD, so it can only build from a clean tree (CI's); a working tree proves the refusal.
    $script:Dirty = @(git -C (Split-Path -Parent $PSScriptRoot) status --porcelain --untracked-files=no).Count -gt 0
}
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $Root 'scripts\common\Deskside.Common.psm1') -Force
    Import-Module (Join-Path $Root 'scripts\console\Deskside.Console.psm1') -Force
    . (Join-Path $Root 'usb-kit\deskside\deskside-enroll.ps1')
    # Shapes only: a made-up group id (with the $ and @ MeshCentral's ids can hold) and key.
    $script:Group = ('Ab3$x@' * 11).Substring(0, 64)
    $script:Key = 'ssh-ed25519 ' + ('A' * 68) + ' deskside-ssh'
    $script:Values = [ordered]@{ serverUrl = 'https://mesh.example'; groupId = $Group; publicKey = $Key; helperName = 'Helper' }
    function script:New-Kit([string]$Dir) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'deskside') | Out-Null
        ($Values | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $Dir 'deskside\values.json')
        (@{ schema = 'deskside.usbkit/v1'; commit = 'abc'; groupRef = 'groupRef' } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $Dir 'deskside\kit.json')
        return $Dir
    }
}

Describe 'Read-KitValue (values.json on the drive)' {
    It 'reads good values, group ids with $ and @ included' {
        $p = Join-Path $TestDrive 'v.json'; ($Values | ConvertTo-Json) | Set-Content $p
        (Read-KitValue -Path $p).groupId | Should -BeExactly $Group
    }
    It 'refuses the template''s placeholders' {
        $p = Join-Path $TestDrive 'p.json'
        (@{ serverUrl = '__SERVER_URL__'; groupId = '__GROUP_ID__'; publicKey = '__SSH_PUBLIC_KEY__'; helperName = 'Helper' } | ConvertTo-Json) | Set-Content $p
        { Read-KitValue -Path $p } | Should -Throw '*incomplete (serverUrl)*'
    }
    It 'refuses an empty group id (a timed-out 1Password read)' {
        $p = Join-Path $TestDrive 'e.json'
        $v = [ordered]@{} + $Values; $v.groupId = ''
        ($v | ConvertTo-Json) | Set-Content $p
        { Read-KitValue -Path $p } | Should -Throw '*incomplete (groupId)*'
    }
    It 'says so when the drive has no values' {
        { Read-KitValue -Path (Join-Path $TestDrive 'none.json') } | Should -Throw '*no values*'
    }
}

Describe 'Test-KitCanInstall (work or school, then Smart App Control; changes nothing)' {
    BeforeEach {
        Mock Test-ManagedDevice { [pscustomobject]@{ IsManaged = $false; Reasons = @() } }
        Mock Get-SmartAppControlState { 'Off' }
        Mock Get-AgentSignature { 'UnknownError' }
    }
    It 'stops on a work or school PC before downloading anything' {
        Mock Test-ManagedDevice { [pscustomobject]@{ IsManaged = $true; Reasons = @('enrolled in device management (MDM)') } }
        $r = Test-KitCanInstall -Values ([pscustomobject]$Values)
        $r.Stop | Should -BeLike '*work or school*'
        Should -Invoke Get-AgentSignature -Times 0
    }
    It 'stops when Smart App Control is on and the agent is signed only by the server' {
        Mock Get-SmartAppControlState { 'On' }
        $r = Test-KitCanInstall -Values ([pscustomobject]$Values)
        $r.Stop | Should -BeLike 'Smart App Control is on*Nothing was changed*Helper says*'
    }
    It 'goes on when Smart App Control is on and the agent''s signature is Valid' {
        Mock Get-SmartAppControlState { 'On' }
        Mock Get-AgentSignature { 'Valid' }
        (Test-KitCanInstall -Values ([pscustomobject]$Values)).Stop | Should -BeNullOrEmpty
    }
    It 'goes on with Smart App Control <_>' -ForEach 'Off', 'Eval' {
        Mock Get-SmartAppControlState { $_ }
        (Test-KitCanInstall -Values ([pscustomobject]$Values)).Stop | Should -BeNullOrEmpty
    }
    It 'takes a forced state (the Sandbox proof''s)' {
        (Test-KitCanInstall -Values ([pscustomobject]$Values) -ForceSmartAppControl 'On').Stop | Should -BeLike 'Smart App Control is on*'
    }
}

Describe 'Get-SmartAppControlState and Test-AgentBlocked' {
    It 'reads Defender''s state first' {
        Mock -ModuleName Deskside.Common Get-MpComputerStatus { [pscustomobject]@{ SmartAppControlState = 'On' } }
        Get-SmartAppControlState | Should -Be 'On'
    }
    It 'falls back to the code-integrity policy value' {
        Mock -ModuleName Deskside.Common Get-MpComputerStatus { throw 'no Defender' }
        Mock -ModuleName Deskside.Common Get-ItemProperty { [pscustomobject]@{ VerifiedAndReputablePolicyState = 2 } }
        Get-SmartAppControlState | Should -Be 'Eval'
    }
    It 'is Unknown when neither can be read' {
        Mock -ModuleName Deskside.Common Get-MpComputerStatus { throw 'no Defender' }
        Mock -ModuleName Deskside.Common Get-ItemProperty { throw 'no value' }
        Get-SmartAppControlState | Should -Be 'Unknown'
    }
    It 'blocks only On with a signature that isn''t Valid' {
        Test-AgentBlocked -State On -Signature UnknownError | Should -BeTrue
        Test-AgentBlocked -State On -Signature NotSigned | Should -BeTrue
        Test-AgentBlocked -State On -Signature Valid | Should -BeFalse
        Test-AgentBlocked -State Eval -Signature NotSigned | Should -BeFalse
        Test-AgentBlocked -State Unknown -Signature NotSigned | Should -BeFalse
    }
}

Describe 'Remove-EnrollTrace' {
    BeforeEach {
        $script:Prof = Join-Path $TestDrive ('p' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:Hist = Join-Path $Prof 'AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine'
        New-Item -ItemType Directory -Force -Path $Hist, (Join-Path $Prof 'AppData\Local\Temp\deskside-mesh-1'), (Join-Path $Prof 'AppData\Local\Temp\keep-me') | Out-Null
        $script:SysTemp = Join-Path $TestDrive ('t' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path (Join-Path $SysTemp 'deskside-check-2') | Out-Null
        Set-Content -LiteralPath (Join-Path $Hist 'ConsoleHost_history.txt') -Value @(
            'Get-Date',
            ".\scripts\remote\Install-MeshAgent.ps1 -ServerUrl https://x -GroupId $Group",
            "echo $Group",
            'winget upgrade --all')
        $env:DESKSIDE_DATA = Join-Path $TestDrive 'data'
        Mock -ModuleName Deskside.Common Get-MpPreference { [pscustomobject]@{ ThreatIDDefaultAction_Ids = @([long]489403) } }
        Mock -ModuleName Deskside.Common Remove-MpPreference { }
    }
    AfterEach { Remove-Item Env:\DESKSIDE_DATA -ErrorAction SilentlyContinue }
    It 'removes leftover downloads, history lines holding the id, and the 489403 allow; returns counts' {
        $r = Remove-EnrollTrace -GroupId $Group -ProfileFolder $Prof -SystemTemp $SysTemp
        $r.tempFolders | Should -Be 2
        $r.historyLines | Should -Be 2
        $r.historyFiles | Should -Be 1
        $r.defenderAllow | Should -Be 'removed'
        Get-Content (Join-Path $Hist 'ConsoleHost_history.txt') | Should -Be @('Get-Date', 'winget upgrade --all')
        Test-Path (Join-Path $Prof 'AppData\Local\Temp\keep-me') | Should -BeTrue
        Should -Invoke -ModuleName Deskside.Common Remove-MpPreference -Times 1 -ParameterFilter { $ThreatIDDefaultAction_Ids -contains 489403 }
    }
    It 'keeps an allow deskside placed itself' {
        New-Item -ItemType Directory -Force -Path $env:DESKSIDE_DATA | Out-Null
        '{}' | Set-Content (Join-Path $env:DESKSIDE_DATA 'defender-allow.json')
        (Remove-EnrollTrace -GroupId $Group -ProfileFolder $Prof -SystemTemp $SysTemp).defenderAllow | Should -BeLike 'kept*'
        Should -Invoke -ModuleName Deskside.Common Remove-MpPreference -Times 0
    }
    It 'changes nothing under -WhatIf' {
        $r = Remove-EnrollTrace -GroupId $Group -ProfileFolder $Prof -SystemTemp $SysTemp -WhatIf
        $r.historyLines | Should -Be 0
        @(Get-Content (Join-Path $Hist 'ConsoleHost_history.txt')).Count | Should -Be 4
        Should -Invoke -ModuleName Deskside.Common Remove-MpPreference -Times 0
    }
}

Describe 'Install-MeshAgent checks Smart App Control before running the agent' {
    BeforeAll { $script:T = Get-Content (Join-Path $Root 'scripts\remote\Install-MeshAgent.ps1') -Raw }
    It 'checks between the signature and Start-Process, and always removes its download' {
        $T.IndexOf('Test-AgentBlocked') | Should -BeGreaterThan $T.IndexOf('Get-AuthenticodeSignature')
        $T.IndexOf('Test-AgentBlocked') | Should -BeLessThan $T.IndexOf('Start-Process -FilePath $exe')
        $T | Should -Match '(?s)try \{.*Invoke-WebRequest.*Start-Process -FilePath \$exe.*\} finally \{ Remove-Item -LiteralPath \$tmp'
    }
}

Describe 'The kit''s order on the PC' {
    BeforeAll { $script:K = Get-Content (Join-Path $Root 'usb-kit\deskside\deskside-enroll.ps1') -Raw; $script:Main = $K.Substring($K.IndexOf("InvocationName -eq '.'")) }
    It 'changes nothing before the work-or-school and Smart App Control checks pass' {
        $check = $Main.IndexOf('if ($check.Stop) { Exit-Kit')
        $check | Should -BeGreaterThan 0
        foreach ($change in 'bootstrap.ps1', 'Update-DesksideApp -Zip', 'Remove-EnrollTrace -GroupId', 'Grant-Consent.ps1', 'Install-MeshAgent.ps1') {
            $Main.IndexOf($change) | Should -BeGreaterThan $check -Because "$change must come after the checks"
        }
    }
    It 'runs no child powershell.exe with the group id (its command line would stay in the event log)' {
        foreach ($l in ($Main -split "`r?`n" | Where-Object { $_ -match '& \$ps ' })) { $l | Should -Not -Match 'groupId' }
        $Main | Should -Match "& \(Join-Path \`$app 'scripts\\remote\\Install-MeshAgent\.ps1'\) -ServerUrl \`$values\.serverUrl -GroupId \`$values\.groupId"
    }
    It 'passes no value on its own command line (nothing for the transcript header)' {
        $Main | Should -Match "-ArgumentList @\('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', \('""' \+ \`$MyInvocation.MyCommand.Path \+ '""'\)\)"
    }
    It 'START HERE.cmd runs the kit with Windows PowerShell' {
        Get-Content (Join-Path $Root 'usb-kit\START HERE.cmd') -Raw | Should -Match 'powershell\.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0deskside\\deskside-enroll\.ps1"'
    }
}

Describe 'Console: reading the kit''s values' {
    AfterEach { Remove-Item Function:\global:op -ErrorAction SilentlyContinue }
    It 'Read-OpValue fails closed on an empty answer' {
        function global:op { '' }
        { Read-OpValue -Ref 'op://v/i/f' -What 'the device group id' } | Should -Throw '*did not return the device group id*'
    }
    It 'Read-OpValue refuses a value of the wrong shape' {
        function global:op { 'not-an-id' }
        { Read-OpValue -Ref 'op://v/i/f' -What 'x' -Pattern '^[A-Za-z0-9$@]{64}$' } | Should -Throw
    }
    It 'Get-UsbKitValue takes the Proofs group with -Proof and names the key' {
        Set-Item Function:\global:op -Value ([scriptblock]::Create("param(`$a, `$ref) if (`$ref -like '*proof*') { '$($Group.Replace("'", "''"))' } elseif (`$ref -like '*ssh*') { 'ssh-ed25519 ' + ('B' * 68) + ' x' } else { throw 'wrong ref' }"))
        $s = [pscustomobject]@{ serverUrl = 'https://mesh.example'; groupRef = 'op://v/group'; proofGroupRef = 'op://v/proof'; sshPublicKeyRef = 'op://v/ssh'; helperName = 'Helper' }
        $kv = Get-UsbKitValue -Settings $s -Proof
        $kv.GroupRefName | Should -Be 'proofGroupRef'
        $kv.Values.groupId | Should -BeExactly $Group
        $kv.Values.publicKey | Should -BeLike 'ssh-ed25519 B* deskside-ssh'
    }
}

Describe 'Console: the drive' {
    It 'refuses a drive that is not removable' {
        Mock -ModuleName Deskside.Console Get-Volume { [pscustomobject]@{ DriveType = 'Fixed' } }
        { Get-UsbKitRoot -Drive 'C:' } | Should -Throw '*isn''t a removable drive*'
    }
    It 'takes a removable drive' {
        Mock -ModuleName Deskside.Console Get-Volume { [pscustomobject]@{ DriveType = 'Removable' } }
        Get-UsbKitRoot -Drive 'e' | Should -Be 'E:\'
    }
    It 'refuses a kit that still holds values' {
        $d = New-Kit (Join-Path $TestDrive 'held')
        { Assert-UsbKitTargetFree -Root $d } | Should -Throw '*still holds a kit with its values*'
    }
    It 'refuses the older single-script kit (the tb-1 drive)' {
        $d = Join-Path $TestDrive 'old'; New-Item -ItemType Directory -Path $d | Out-Null
        'x' | Set-Content (Join-Path $d 'deskside-enroll.ps1')
        { Assert-UsbKitTargetFree -Root $d } | Should -Throw '*older deskside kit*'
    }
    It 'refuses results not read back yet, and allows them once read' {
        $d = Join-Path $TestDrive 'rb'; New-Item -ItemType Directory -Path (Join-Path $d 'deskside') -Force | Out-Null
        'run: x' | Set-Content (Join-Path $d 'readback.txt')
        { Assert-UsbKitTargetFree -Root $d } | Should -Throw '*not read back yet*'
        '{}' | Set-Content (Join-Path $d 'deskside\read-back.json')
        { Assert-UsbKitTargetFree -Root $d } | Should -Not -Throw
    }
}

Describe 'ConvertFrom-UsbKitReadback' {
    It 'shows the last run of several, and never the node or account' {
        $s = ConvertFrom-UsbKitReadback -Line @('run: 1', 'stopped: Smart App Control is on', 'run: 2', 'node: node//N', 'account: someone', 'service Mesh Agent: Running')
        $s | Should -Contain 'runs on this drive: 2 (showing the last)'
        $s | Should -Contain 'service Mesh Agent: Running'
        $s | Should -Not -Contain 'stopped: Smart App Control is on'
        ($s -join '|') | Should -Not -Match 'someone|node//N'
    }
}

Describe 'Read-DesksideUsbKit' {
    BeforeEach {
        $script:Kit = New-Kit (Join-Path $TestDrive ('k' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
        $script:Rec = Join-Path $TestDrive ('r' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $Rec | Out-Null
        Set-Content -LiteralPath (Join-Path $Kit 'readback.txt') -Value @('run: 2026-11-21T10:00:00', 'smart app control: Off', 'agent signature: UnknownError',
            'step MeshCentral agent: done', 'node: node//SECRETNODE', 'account: someperson', 'consent: remote 2026-11-21T10:01:00Z', 'service Mesh Agent: Running', 'values: removed from the drive')
        Set-Content -LiteralPath (Join-Path $Kit 'log.txt') -Value 'transcript'
    }
    It 'saves the results, wipes values.json, finds no id left and shows no node or account' {
        $o = & (Join-Path $Root 'scripts\console\Read-DesksideUsbKit.ps1') -Path $Kit -Alias 'test-pc' -RecordsRoot $Rec 6>&1 | Out-String
        Test-Path (Join-Path $Kit 'deskside\values.json') | Should -BeFalse
        @(Get-ChildItem (Join-Path $Rec 'devices\test-pc\enroll') -Recurse -File).Name | Sort-Object | Should -Be @('log.txt', 'readback.txt')
        $o | Should -Match 'group id still on the drive: 0 of'
        $o | Should -Match 'service Mesh Agent: Running'
        $o | Should -Not -Match 'SECRETNODE|someperson'
        (Get-Content (Join-Path $Kit 'deskside\read-back.json') -Raw | ConvertFrom-Json).filesWithId | Should -Be 0
        { Assert-UsbKitTargetFree -Root $Kit } | Should -Not -Throw
    }
    It 'fails when the id is still in a file on the drive' {
        Add-Content -LiteralPath (Join-Path $Kit 'log.txt') -Value "oops $Group"
        { & (Join-Path $Root 'scripts\console\Read-DesksideUsbKit.ps1') -Path $Kit -Alias 'test-pc' -RecordsRoot $Rec 6>$null } | Should -Throw '*still in 1 file*'
        Test-Path (Join-Path $Kit 'deskside\values.json') | Should -BeFalse
    }
}

Describe 'New-DesksideUsbKit' {
    AfterEach { Remove-Item Function:\global:op -ErrorAction SilentlyContinue; Remove-Item Env:\DESKSIDE_RECORDS -ErrorAction SilentlyContinue }
    It 'refuses an uncommitted tree' -Skip:(-not $Dirty) {
        $d = Join-Path $TestDrive 'dirty'; New-Item -ItemType Directory -Path $d | Out-Null
        { & (Join-Path $Root 'scripts\console\New-DesksideUsbKit.ps1') -Path $d } | Should -Throw '*Commit first*'
    }
    It 'builds a kit from the committed HEAD and prints no value' -Skip:$Dirty {
        $recs = Join-Path $TestDrive 'recs'; New-Item -ItemType Directory -Path $recs | Out-Null
        (@{ serverUrl = 'https://mesh.example'; groupRef = 'op://v/group'; proofGroupRef = 'op://v/proof'; sshPublicKeyRef = 'op://v/ssh'; helperName = 'Helper' } | ConvertTo-Json) | Set-Content (Join-Path $recs 'meshcentral.json')
        $env:DESKSIDE_RECORDS = $recs
        Set-Item Function:\global:op -Value ([scriptblock]::Create("param(`$a, `$ref) if (`$ref -like '*ssh*') { 'ssh-ed25519 ' + ('C' * 68) } else { '$($Group.Replace("'", "''"))' }"))
        $d = Join-Path $TestDrive 'kit'; New-Item -ItemType Directory -Path $d | Out-Null
        $o = & (Join-Path $Root 'scripts\console\New-DesksideUsbKit.ps1') -Path $d 6>&1 | Out-String
        $o | Should -Not -Match ([regex]::Escape($Group))
        $o | Should -Match 'USB kit built from commit'
        foreach ($f in 'START HERE.cmd', 'deskside\deskside-enroll.ps1', 'deskside\Deskside.Common.psm1', 'deskside\bootstrap.ps1', 'deskside\deskside.zip', 'deskside\kit.json', 'deskside\values.json') {
            Test-Path (Join-Path $d $f) | Should -BeTrue -Because $f
        }
        (Read-KitValue -Path (Join-Path $d 'deskside\values.json')).groupId | Should -BeExactly $Group
        { & (Join-Path $Root 'scripts\console\New-DesksideUsbKit.ps1') -Path $d } | Should -Throw '*still holds a kit*'
    }
}
