# PSScriptAnalyzer settings used by build.ps1 -Task Lint (locally and in CI).
@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @()
    Rules        = @{
        # The module supports Windows PowerShell 5.1 and PowerShell 7+; flag syntax that 5.1 cannot parse.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
