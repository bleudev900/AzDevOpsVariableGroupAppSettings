function Set-AppServiceSettingFromVariableGroup {
    <#
    .SYNOPSIS
        Applies the prefixed variables of an Azure DevOps variable group as app settings on an App Service.

    .DESCRIPTION
        Designed to run inside an Azure Pipelines deployment (e.g. an AzureCLI@2 task, which logs az in with
        the service connection). Steps:
          1. Read and filter the variable group (Get-AzDoVariableGroupSetting): 'SETTING__Foo__Bar' becomes
             app setting 'Foo__Bar'; secrets are resolved from the step's environment or -SecretValues.
          2. Read the app's current settings and compute a masked diff (Add/Change/Remove/Unchanged/Preserve),
             written to the log (collapsible ##[group] in Azure Pipelines).
          3. Unless -WhatIf: write all added/changed settings in one
             'az webapp config appsettings set --settings @<temp json file>' call (the temp file is deleted
             afterwards), then in Replace mode delete settings not in the group
             ('az webapp config appsettings delete'), protecting WEBSITE_*, APPINSIGHTS_* etc. by default.
        Returns a result object with counts and the masked changes. Changing app settings restarts the app.

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

    .PARAMETER AllowEmpty
        Allow Replace mode to run when no settings were selected from the group (this would delete every
        non-preserved setting). Without it, Replace mode fails in that case as a safety net.

    .PARAMETER PassThru
        Also output the masked per-setting changes after the result object.

    .EXAMPLE
        Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' -ResourceGroupName rg-web-prod -AppName contoso-web-prod

    .EXAMPLE
        Set-AppServiceSettingFromVariableGroup -VariableGroupId 42 -Prefix 'SETTINGS__' -ResourceGroupName rg-web-prod -AppName contoso-web-prod -Slot staging -SlotSetting -Mode Replace -WhatIf
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('AzDevOpsVariableGroupAppSettings.Result', 'AzDevOpsVariableGroupAppSettings.SettingChange')]
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

        [switch] $ShowNonSecretValues,

        [switch] $AllowEmpty,

        [switch] $PassThru
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

        if ($plan.Desired.Count -eq 0) {
            if ($Mode -eq 'Replace' -and -not $AllowEmpty) {
                Write-TerminatingPipelineError 'No settings were selected from the variable group; refusing to run Replace mode (it would delete every non-preserved app setting). Check -Prefix or use -AllowEmpty.'
            }
            Write-PipelineWarning 'No settings were selected from the variable group.'
        }

        $publicDiff = @(ConvertTo-PublicDiff -Diff $plan.Diff -ShowNonSecretValues:$ShowNonSecretValues)
        Write-AppSettingDiff -PublicDiff $publicDiff -Title "App settings for $($plan.TargetDisplay) [$Mode]"

        $toSet = @($plan.Diff | Where-Object { $_.Action -in 'Add', 'Change' })
        $toRemove = @($plan.Diff | Where-Object { $_.Action -eq 'Remove' })
        $applied = $false

        if ($toSet.Count -eq 0 -and $toRemove.Count -eq 0) {
            Write-PipelineLog "No changes needed for $($plan.TargetDisplay)." -Kind Section
        }
        else {
            $action = 'Apply app settings: {0} add, {1} change, {2} remove' -f @($toSet | Where-Object { $_.Action -eq 'Add' }).Count, @($toSet | Where-Object { $_.Action -eq 'Change' }).Count, $toRemove.Count
            if ($PSCmdlet.ShouldProcess($plan.TargetDisplay, $action)) {
                if ($toSet.Count -gt 0) {
                    $payload = foreach ($row in $toSet) { [pscustomobject]@{ Name = $row.Name; Value = $row.NewValue; SlotSetting = $row.SlotSettingChanged -or ($row.SlotSetting -and $row.Action -eq 'Add') } }
                    Set-AppServiceAppSettingValue -TargetArgument $plan.TargetArgument -Setting @($payload)
                    Write-PipelineLog "Updated $($toSet.Count) app setting(s) on $($plan.TargetDisplay)."
                }
                if ($toRemove.Count -gt 0) {
                    Remove-AppServiceAppSettingValue -TargetArgument $plan.TargetArgument -Name @($toRemove | ForEach-Object { $_.Name })
                    Write-PipelineLog "Removed $($toRemove.Count) app setting(s) from $($plan.TargetDisplay)."
                }
                $applied = $true
                Write-PipelineLog "App settings applied to $($plan.TargetDisplay)." -Kind Section
            }
        }

        $count = { param($a) @($publicDiff | Where-Object { $_.Action -eq $a }).Count }
        [pscustomobject]@{
            PSTypeName        = 'AzDevOpsVariableGroupAppSettings.Result'
            VariableGroupName = $plan.VariableGroupName
            VariableGroupId   = $plan.VariableGroupId
            ResourceGroupName = $ResourceGroupName
            AppName           = $AppName
            Slot              = $(if ($Slot) { $Slot } else { $null })
            Subscription      = $(if ($Subscription) { $Subscription } else { $null })
            Mode              = $Mode
            Applied           = $applied
            Added             = & $count 'Add'
            Changed           = & $count 'Change'
            Removed           = & $count 'Remove'
            Unchanged         = & $count 'Unchanged'
            Preserved         = & $count 'Preserve'
            Changes           = @($publicDiff | Where-Object { $_.Action -in 'Add', 'Change', 'Remove' })
        }
        if ($PassThru) { foreach ($row in $publicDiff) { Write-Output -InputObject $row } }
    }
}
