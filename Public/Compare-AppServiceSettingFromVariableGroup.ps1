function Compare-AppServiceSettingFromVariableGroup {
    <#
    .SYNOPSIS
        Shows what applying a variable group to an App Service would change (read-only).

    .DESCRIPTION
        Reads the variable group (see Get-AzDoVariableGroupSetting) and the app's current settings
        ('az webapp config appsettings list') and returns one row per setting with Action Add, Change,
        Remove (Replace mode only), Unchanged or Preserve (existing setting that is kept). Values are masked
        unless -ShowNonSecretValues is used (secrets are always masked). Nothing is modified.

    .PARAMETER VariableGroupName
        Exact name of the variable group (case-insensitive).

    .PARAMETER VariableGroupId
        ID of the variable group.

    .PARAMETER InputObject
        Setting objects from Get-AzDoVariableGroupSetting (pipeline input) instead of reading a group.

    .PARAMETER Organization
        Organization URL or name. Defaults to SYSTEM_COLLECTIONURI / SYSTEM_TEAMFOUNDATIONCOLLECTIONURI.

    .PARAMETER Project
        Project that owns the variable group. Defaults to SYSTEM_TEAMPROJECT.

    .PARAMETER Prefix
        Variable name prefix to select and strip. Default 'SETTING__'.

    .PARAMETER KeepPrefix
        Keep the prefix in the app setting name.

    .PARAMETER CaseSensitive
        Match the prefix case-sensitively (default: case-insensitive).

    .PARAMETER SecretValues
        Values for secret variables keyed by variable or app setting name (string or SecureString).

    .PARAMETER SkipUnresolvedSecret
        Skip secret variables whose value cannot be resolved instead of failing.

    .PARAMETER ResourceGroupName
        Resource group of the target App Service.

    .PARAMETER AppName
        Name of the target App Service (web app / function app).

    .PARAMETER Slot
        Deployment slot. Omit for the production slot.

    .PARAMETER Subscription
        Subscription name or ID of the target app. Defaults to the az CLI's current subscription.

    .PARAMETER Mode
        Merge (default): add/update settings from the group, keep all other existing settings.
        Replace: also delete existing settings that are not in the group, except those matching the
        preserved patterns (see -PreserveSetting / -NoDefaultPreserve).

    .PARAMETER PreserveSetting
        Additional wildcard patterns of existing settings that Replace mode must never delete.

    .PARAMETER NoDefaultPreserve
        Do not protect the default platform settings (WEBSITE_*, APPINSIGHTS_*, APPLICATIONINSIGHTS_*, ...).

    .PARAMETER SlotSetting
        Mark every applied setting as a deployment slot setting (sticky).

    .PARAMETER SlotSettingName
        Wildcard patterns of app setting names to mark as slot settings (sticky).

    .PARAMETER ShowNonSecretValues
        Show values of non-secret settings in the diff. Secret values are always masked.

    .EXAMPLE
        Compare-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' -ResourceGroupName rg-web-prod -AppName contoso-web-prod -Mode Replace

    .EXAMPLE
        Get-AzDoVariableGroupSetting 'MyApp-Prod' | Compare-AppServiceSettingFromVariableGroup -ResourceGroupName rg-web-prod -AppName contoso-web-prod
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    [OutputType('AzDevOpsVariableGroupAppSettings.SettingChange')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'ByName')]
        [Alias('GroupName')]
        [ValidateNotNullOrEmpty()]
        [string] $VariableGroupName,

        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [Alias('GroupId')]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $VariableGroupId,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'InputObject')]
        [AllowEmptyCollection()]
        [object[]] $InputObject,

        [Parameter(ParameterSetName = 'ByName')]
        [Parameter(ParameterSetName = 'ById')]
        [Alias('OrganizationUrl', 'Org')]
        [string] $Organization,

        [Parameter(ParameterSetName = 'ByName')]
        [Parameter(ParameterSetName = 'ById')]
        [string] $Project,

        [Parameter(ParameterSetName = 'ByName')]
        [Parameter(ParameterSetName = 'ById')]
        [AllowEmptyString()]
        [string] $Prefix = 'SETTING__',

        [Parameter(ParameterSetName = 'ByName')]
        [Parameter(ParameterSetName = 'ById')]
        [switch] $KeepPrefix,

        [Parameter(ParameterSetName = 'ByName')]
        [Parameter(ParameterSetName = 'ById')]
        [switch] $CaseSensitive,

        [Parameter(ParameterSetName = 'ByName')]
        [Parameter(ParameterSetName = 'ById')]
        [hashtable] $SecretValues,

        [Parameter(ParameterSetName = 'ByName')]
        [Parameter(ParameterSetName = 'ById')]
        [switch] $SkipUnresolvedSecret,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [Alias('Name', 'WebAppName')]
        [ValidateNotNullOrEmpty()]
        [string] $AppName,

        [string] $Slot,

        [string] $Subscription,

        [ValidateSet('Merge', 'Replace')]
        [string] $Mode = 'Merge',

        [string[]] $PreserveSetting = @(),

        [switch] $NoDefaultPreserve,

        [switch] $SlotSetting,

        [string[]] $SlotSettingName = @(),

        [switch] $ShowNonSecretValues
    )

    begin { $collected = New-Object System.Collections.Generic.List[object] }
    process { if ($PSCmdlet.ParameterSetName -eq 'InputObject') { foreach ($o in $InputObject) { $collected.Add($o) } } }
    end {
        $planArgs = @{
            BoundParameters   = $PSBoundParameters
            ParameterSetName  = $PSCmdlet.ParameterSetName
            InputObject       = $collected.ToArray()
            ResourceGroupName = $ResourceGroupName
            AppName           = $AppName
            Slot              = $Slot
            Subscription      = $Subscription
            Mode              = $Mode
            PreserveSetting   = $PreserveSetting
            NoDefaultPreserve = $NoDefaultPreserve
            SlotSetting       = $SlotSetting
            SlotSettingName   = $SlotSettingName
        }
        $plan = Get-AppSettingPlan @planArgs
        ConvertTo-PublicDiff -Diff $plan.Diff -ShowNonSecretValues:$ShowNonSecretValues
    }
}
