@{
    # Default rules, plus checks that every PC-side script works on Windows PowerShell 5.1 (a new PC has only 5.1).
    # Scripts under scripts\console and health run on the helper's side or a server and need PowerShell 7; they're
    # analyzed with PSScriptAnalyzerSettings.Console.psd1 instead.
    Severity     = @('Error', 'Warning')
    IncludeDefaultRules = $true
    ExcludeRules = @(
        # Scripts print plain-English progress for the person at the PC; Write-Host is the intended output there.
        'PSAvoidUsingWriteHost',
        # The diagnostics' Add-Check calls read better positionally (run, check id, values); the rule only warns.
        'PSAvoidUsingPositionalParameters'
    )
    Rules        = @{
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
            IgnoreCommands = @('Get-WindowsCapability', 'Add-WindowsCapability', 'Remove-WindowsCapability', 'Repair-WinGetPackageManager',
                'Get-BitLockerVolume', 'Get-MpComputerStatus', 'Get-MpPreference', 'Set-MpPreference', 'Get-PhysicalDisk', 'Get-StorageReliabilityCounter',
                'Get-NetFirewallProfile', 'Get-NetFirewallRule', 'Disable-NetFirewallRule', 'Enable-NetFirewallRule', 'Remove-NetFirewallRule',
                'Get-NetTCPConnection', 'Get-ScheduledTask', 'Get-ScheduledTaskInfo', 'Confirm-SecureBootUEFI', 'Get-AppxPackage')
        }
        PSUseCompatibleTypes    = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}
