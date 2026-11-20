#Requires -Version 7.2
# The health sweep end to end against a stub meshctrl (tests/fixtures/meshctrl-stub.js) and a local records store (a
# bare repository and its clone in TestDrive). Each case runs the sweep in its own PowerShell 7 process, as the
# scheduled job does, and reads what the stub was given and what the sweep printed and pushed.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Sweep = Join-Path $Root 'health' 'Invoke-HealthSweep.ps1'
    $script:Stub = Join-Path $Root 'tests' 'fixtures' 'meshctrl-stub.js'
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Secret = 'stub-secret-value'

    function New-RecordsStore {
        $name = [guid]::NewGuid().ToString('N')
        $work = Join-Path $TestDrive "records-$name"
        $bare = Join-Path $TestDrive "records-$name.git"
        git init -q -b main $work
        git -C $work config user.name 'deskside test'
        git -C $work config user.email 'test@example.com'
        git -C $work config commit.gpgsign false
        '{"schema":"deskside.devices/v1","devices":[{"alias":"kitchen-pc","meshNodeId":"node//listed"}]}' | Set-Content (Join-Path $work 'devices.json')
        git -C $work add devices.json
        git -C $work commit -q -m 'init'
        git clone -q --bare $work $bare
        git -C $work remote add origin $bare
        git -C $work fetch -q origin
        git -C $work branch -q -u origin/main
        return [pscustomobject]@{ Work = $work; Bare = $bare }
    }

    function Invoke-Sweep([pscustomobject]$Store, [hashtable]$Environment, [string[]]$Arguments = @()) {
        $log = Join-Path $TestDrive ('stub-' + [guid]::NewGuid().ToString('N') + '.log')
        $psi = [System.Diagnostics.ProcessStartInfo]::new($Pwsh)
        foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $Sweep) + $Arguments) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $vars = @{
            DESKSIDE_MESH_URL = 'wss://mesh.example:443'; DESKSIDE_MESH_USER = '~t:stubuser'; DESKSIDE_MESH_PASS = $Secret
            DESKSIDE_MESH_GROUP = 'mesh//stubgroup'; DESKSIDE_MESHCTRL = $Stub; DESKSIDE_RECORDS = $Store.Work
            DESKSIDE_PUSH_URL = $null; STUB_LOG = $log
            STUB_DEVICES = '[{"_id":"node//listed","name":"x","conn":1}]'
        }
        foreach ($k in $Environment.Keys) { $vars[$k] = $Environment[$k] }
        foreach ($k in $vars.Keys) { if ($null -eq $vars[$k]) { [void]$psi.Environment.Remove($k) } else { $psi.Environment[$k] = [string]$vars[$k] } }
        $p = [System.Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync()
        $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(120000)) { $p.Kill($true); throw 'the sweep did not finish in 120 s' }
        $p.WaitForExit()
        $text = $o.Result + $e.Result
        [pscustomobject]@{
            Code    = $p.ExitCode
            Text    = $text
            Calls   = @(if (Test-Path $log) { Get-Content $log | ForEach-Object { $_ | ConvertFrom-Json } })
            Monitor = ($text -split "`r?`n" | Where-Object { $_ -like 'monitor: *' } | Select-Object -Last 1)
        }
    }

    function Get-PushedFile([pscustomobject]$Store) {
        @(git -C $Store.Bare ls-tree -r --name-only main | Where-Object { $_ -like 'devices/*/health/*.json' })
    }
}

Describe 'Invoke-HealthSweep' {
    It 'passes the login through meshctrl''s environment, never its command line' {
        $s = New-RecordsStore
        $r = Invoke-Sweep $s @{}
        $r.Calls.Count | Should -BeGreaterOrEqual 2
        foreach ($c in $r.Calls) {
            ($c.argv -join ' ') | Should -Not -Match ([regex]::Escape($Secret))
            ($c.argv -join ' ') | Should -Not -Match 'stubuser'
            $c.env.pass | Should -Be $Secret
            $c.env.user | Should -Be '~t:stubuser'
            $c.env.url | Should -Be 'wss://mesh.example:443'
        }
    }

    It 'lists the group by id and runs the diagnostics with the script policy bypassed for that run only' {
        $s = New-RecordsStore
        $r = Invoke-Sweep $s @{}
        $list = $r.Calls | Where-Object { $_.argv[0] -eq 'listdevices' }
        ($list.argv -join ' ') | Should -Match '--id mesh//stubgroup'
        $run = $r.Calls | Where-Object { $_.argv[0] -eq 'runcommand' }
        $run.argv[[array]::IndexOf($run.argv, '--run') + 1] | Should -Match '^powershell\.exe -NoProfile -ExecutionPolicy Bypass -File '
    }

    It 'commits and pushes one record per checked PC and reports up' {
        $s = New-RecordsStore
        $r = Invoke-Sweep $s @{}
        $r.Code | Should -Be 0
        $r.Monitor | Should -Be 'monitor: up 1 PC(s) checked, nothing needs attention'
        @(Get-PushedFile $s | Where-Object { $_ -like 'devices/kitchen-pc/health/*' }).Count | Should -Be 1
        (git -C $s.Bare log -1 --format=%s main) | Should -BeLike 'health sweep *'
    }

    It 'names a PC by its alias only, and an unlisted PC by neither its name nor its node id' {
        $s = New-RecordsStore
        $r = Invoke-Sweep $s @{
            STUB_DEVICES = '[{"_id":"node//listed","name":"x","conn":1},{"_id":"node//unlistedQWERTY","name":"Real Name PC","conn":1}]'
            STUB_HEALTH  = '{"schema":"deskside.health/v1","findings":[{"id":"disk.full"}],"data":{}}'
        }
        $r.Monitor | Should -Be 'monitor: down kitchen-pc: the Windows drive is nearly full; a PC not in devices.json: the Windows drive is nearly full'
        $r.Text | Should -Not -Match 'QWERTY'
        $r.Text | Should -Not -Match 'Real Name PC'
    }

    It 'counts a PC that never answers as failed after the timeout, and still finishes' {
        $s = New-RecordsStore
        $t = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Sweep $s @{ STUB_RUN = 'hang' } @('-RunTimeoutSeconds', '2')
        $t.Elapsed.TotalSeconds | Should -BeLessThan 60
        $r.Code | Should -Be 0
        $r.Monitor | Should -Be 'monitor: down kitchen-pc: online, but the check failed'
    }

    It 'counts a refused run as failed' {
        $s = New-RecordsStore
        $r = Invoke-Sweep $s @{ STUB_RUN = 'denied' }
        $r.Monitor | Should -Be 'monitor: down kitchen-pc: online, but the check failed'
    }

    It 'reports a failed device list by the step that failed, never by meshctrl''s own words' {
        $s = New-RecordsStore
        $r = Invoke-Sweep $s @{ STUB_LIST = 'denied' }
        $r.Code | Should -Not -Be 0
        $r.Monitor | Should -Be 'monitor: down health sweep failed while listing the devices'
    }

    It 'reads a long reply whole' {
        $s = New-RecordsStore
        $r = Invoke-Sweep $s @{ STUB_PAD = '30000' }
        $r.Monitor | Should -Be 'monitor: up 1 PC(s) checked, nothing needs attention'
        $f = Get-PushedFile $s | Select-Object -First 1
        $rec = (git -C $s.Bare show "main:$f") -join "`n" | ConvertFrom-Json
        $rec.pad.Length | Should -Be 30000
    }

    It 'pushes nothing with -DryRun' {
        $s = New-RecordsStore
        $r = Invoke-Sweep $s @{} @('-DryRun')
        $r.Monitor | Should -Be 'monitor: up 1 PC(s) checked, nothing needs attention'
        @(git -C $s.Bare rev-list main).Count | Should -Be 1
    }
}
