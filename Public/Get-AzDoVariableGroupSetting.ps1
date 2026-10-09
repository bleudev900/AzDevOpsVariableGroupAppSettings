function Get-AzDoVariableGroupSetting {
    <#
    .SYNOPSIS
        Reads an Azure DevOps variable group with the Azure CLI and returns the variables whose names start
        with a prefix, transformed into App Service app setting names.

    .DESCRIPTION
        Uses 'az pipelines variable-group list/show' and 'az pipelines variable-group variable list'
        (azure-devops CLI extension) to read the group, then:
          * selects variables whose name starts with -Prefix (default 'SETTING__', case-insensitive unless
            -CaseSensitive);
          * strips the prefix to form the app setting name (unless -KeepPrefix). Remaining double underscores
            are kept: 'SETTING__Logging__LogLevel__Default' -> 'Logging__LogLevel__Default', which .NET
            configuration maps to the 'Logging:LogLevel:Default' section;
          * resolves secret variables, whose values the API never returns, from -SecretValues or from
            environment variables (see NOTES). Unresolved secrets are an error unless -SkipUnresolvedSecret.

        Secret values are returned only as SecureStrings (SecureValue property) and, inside Azure Pipelines,
        registered with the log masker (##vso[task.setsecret]). Values are never written to the log.

        Authentication for az devops: AZURE_DEVOPS_EXT_PAT if set, otherwise SYSTEM_ACCESSTOKEN (map
        $(System.AccessToken) into the step's env), otherwise the identity az is logged in with.

    .PARAMETER VariableGroupName
        Exact name of the variable group (case-insensitive).

    .PARAMETER VariableGroupId
        ID of the variable group.

    .PARAMETER Organization
        Organization URL (https://dev.azure.com/contoso) or name. Defaults to SYSTEM_COLLECTIONURI /
        SYSTEM_TEAMFOUNDATIONCOLLECTIONURI.

    .PARAMETER Project
        Project that owns the variable group. Defaults to SYSTEM_TEAMPROJECT.

    .PARAMETER Prefix
        Variable name prefix to select. Default 'SETTING__'. An empty string selects every variable.

    .PARAMETER KeepPrefix
        Keep the prefix in the app setting name instead of stripping it.

    .PARAMETER CaseSensitive
        Match the prefix case-sensitively.

    .PARAMETER SecretValues
        Values for secret variables, keyed by variable name or app setting name. Values may be strings or
        SecureStrings. Takes precedence over environment variables.

    .PARAMETER SkipUnresolvedSecret
        Skip (with a warning) secret variables whose value cannot be resolved, instead of failing.

    .EXAMPLE
        Get-AzDoVariableGroupSetting -VariableGroupName 'MyApp-Prod' -Organization https://dev.azure.com/contoso -Project Web

    .EXAMPLE
        # In a pipeline step with SYSTEM_ACCESSTOKEN and SETTING__Db__Password mapped into env:
        Get-AzDoVariableGroupSetting -VariableGroupName 'MyApp-Prod' -Prefix 'SETTINGS__'

    .NOTES
        Secret lookup in the environment tries the variable name as-is and its pipeline-normalized form
        (upper-case, '.' and ' ' replaced with '_'). Azure Pipelines never maps secrets into the
        environment automatically; map each one in the step's env: block, e.g.
            env:
              SETTING__Db__Password: $(SETTING__Db__Password)
        Variables with no value that are not marked secret (e.g. Key Vault-linked groups) are treated as secrets.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    [OutputType('AzDevOpsVariableGroupAppSettings.Setting')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'ByName')]
        [Alias('GroupName')]
        [ValidateNotNullOrEmpty()]
        [string] $VariableGroupName,

        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [Alias('GroupId')]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $VariableGroupId,

        [Alias('OrganizationUrl', 'Org')]
        [string] $Organization,

        [string] $Project,

        [AllowEmptyString()]
        [string] $Prefix = 'SETTING__',

        [switch] $KeepPrefix,

        [switch] $CaseSensitive,

        [hashtable] $SecretValues,

        [switch] $SkipUnresolvedSecret
    )

    $connection = Resolve-AzDoConnection -Organization $Organization -Project $Project
    $groupArgs = @{ Organization = $connection.Organization; Project = $connection.Project }
    if ($PSCmdlet.ParameterSetName -eq 'ById') { $groupArgs.Id = $VariableGroupId } else { $groupArgs.Name = $VariableGroupName }

    $group = Get-AzDoVariableGroup @groupArgs
    Write-Verbose ("Variable group '{0}' (ID {1}) has {2} variable(s)." -f $group.Name, $group.Id, $group.Variables.Count)

    $comparison = if ($CaseSensitive) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
    $selected = @($group.Variables | Where-Object { $_.Name.StartsWith($Prefix, $comparison) } | Sort-Object Name)
    if ($selected.Count -eq 0) {
        Write-PipelineWarning ("No variables in group '{0}' start with '{1}'{2}." -f $group.Name, $Prefix, $(if ($CaseSensitive) { ' (case-sensitive)' } else { '' }))
        return
    }

    $seen = @{}
    $unresolved = New-Object System.Collections.Generic.List[string]
    foreach ($variable in $selected) {
        $settingName = if ($KeepPrefix) { $variable.Name } else { $variable.Name.Substring($Prefix.Length) }
        if (-not $settingName) {
            Write-PipelineWarning "Variable '$($variable.Name)' has no name after removing the prefix; skipped."
            continue
        }
        if ($seen.ContainsKey($settingName)) {
            Write-TerminatingPipelineError "Variables '$($seen[$settingName])' and '$($variable.Name)' both map to app setting '$settingName'."
        }
        if ($settingName -match ':') {
            Write-PipelineWarning "App setting '$settingName' contains ':' which Linux App Service does not allow; use '__' to express configuration sections."
        }

        $isSecret = [bool]$variable.IsSecret -or $null -eq $variable.Value
        $plain = $variable.Value
        $source = 'VariableGroup'
        if ($isSecret) {
            $resolved = Resolve-SecretVariableValue -VariableName $variable.Name -SettingName $settingName -SecretValues $SecretValues
            if (-not $resolved.Found) {
                $unresolved.Add($variable.Name)
                continue
            }
            $plain = $resolved.Value
            $source = $resolved.Source
            Register-PipelineSecret -Value $plain
        }
        $seen[$settingName] = $variable.Name

        [pscustomobject]@{
            PSTypeName        = 'AzDevOpsVariableGroupAppSettings.Setting'
            Name              = $settingName
            VariableName      = $variable.Name
            IsSecret          = $isSecret
            Value             = if ($isSecret) { $null } else { [string]$plain }
            SecureValue       = if ($isSecret) { ConvertTo-SecureStringFromPlainText $plain } else { $null }
            ValueSource       = $source
            VariableGroupName = $group.Name
            VariableGroupId   = $group.Id
        }
        $plain = $null
    }

    if ($unresolved.Count -gt 0) {
        $hint = ($unresolved | ForEach-Object { "$_ (env: $_ or $(Get-PipelineEnvironmentVariableName $_))" }) -join '; '
        $message = "Could not resolve the value of $($unresolved.Count) secret variable(s): $hint. Map each secret into the step's env (e.g. NAME: `$(NAME)) or pass -SecretValues."
        if ($SkipUnresolvedSecret) { Write-PipelineWarning "$message Skipped because -SkipUnresolvedSecret was specified." }
        else { Write-TerminatingPipelineError $message }
    }
}
