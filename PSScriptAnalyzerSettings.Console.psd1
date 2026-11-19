@{
    # The helper's side (scripts\console), the health sweep (health\) and Invoke-Check.ps1 run on PowerShell 7 only.
    Severity     = @('Error', 'Warning')
    IncludeDefaultRules = $true
    # The PowerShell 7 profile uses Starship's documented 'Invoke-Expression (& starship init powershell)'.
    ExcludeRules = @('PSAvoidUsingWriteHost', 'PSAvoidUsingInvokeExpression')
    Rules        = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('7.4') }
    }
}
