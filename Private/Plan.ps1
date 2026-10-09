$script:GroupParameterName = @('VariableGroupName', 'VariableGroupId', 'Organization', 'Project', 'Prefix',
    'KeepPrefix', 'CaseSensitive', 'SecretValues', 'SkipUnresolvedSecret')

function Get-AppSettingPlan {
    <#
        Shared by Compare-/Set-AppServiceSettingFromVariableGroup: resolves desired settings (from a variable
        group or piped setting objects), reads the app's current settings and computes the diff.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $BoundParameters,
        [Parameter(Mandatory)][string] $ParameterSetName,
        [AllowEmptyCollection()][object[]] $InputObject = @(),
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $AppName,
        [string] $Slot,
        [string] $Subscription,
        [string] $Mode = 'Merge',
        [string[]] $PreserveSetting = @(),
        [switch] $NoDefaultPreserve,
        [switch] $SlotSetting,
        [string[]] $SlotSettingName = @()
    )

    if ($ParameterSetName -eq 'InputObject') {
        $settings = @($InputObject | Where-Object { $null -ne $_ })
        foreach ($s in $settings) {
            if (-not ($s.PSObject.Properties['Name'] -and $s.PSObject.Properties['IsSecret'])) {
                throw 'InputObject must be setting objects produced by Get-AzDoVariableGroupSetting.'
            }
        }
    }
    else {
        $groupArgs = @{}
        foreach ($k in $script:GroupParameterName) { if ($BoundParameters.ContainsKey($k)) { $groupArgs[$k] = $BoundParameters[$k] } }
        $settings = @(Get-AzDoVariableGroupSetting @groupArgs)
    }

    $names = @{}
    $desired = foreach ($s in $settings) {
        if ($names.ContainsKey($s.Name)) { throw "Duplicate app setting name '$($s.Name)' in input." }
        $names[$s.Name] = $true
        $varName = if ($s.PSObject.Properties['VariableName']) { $s.VariableName } else { $s.Name }
        [pscustomobject]@{
            Name         = $s.Name
            VariableName = $varName
            IsSecret     = [bool]$s.IsSecret
            PlainValue   = Get-SettingPlainValue -Setting $s
            SlotSetting  = [bool]$SlotSetting -or (Test-WildcardMatch -Name $s.Name -Pattern $SlotSettingName)
        }
    }
    $desired = @($desired)

    $target = Get-AppServiceTargetArgument -ResourceGroupName $ResourceGroupName -AppName $AppName -Slot $Slot -Subscription $Subscription
    $current = @(Get-AppServiceAppSettingList -TargetArgument $target)

    $preserve = @($PreserveSetting)
    if (-not $NoDefaultPreserve) { $preserve += $script:DefaultPreservedSetting }
    $diff = @(Get-AppSettingDiff -Desired $desired -Current $current -Mode $Mode -PreservePattern $preserve)

    $groupName = $null; $groupId = $null
    $first = $settings | Select-Object -First 1
    if ($first -and $first.PSObject.Properties['VariableGroupName']) { $groupName = $first.VariableGroupName; $groupId = $first.VariableGroupId }
    elseif ($BoundParameters.ContainsKey('VariableGroupName')) { $groupName = $BoundParameters.VariableGroupName }
    elseif ($BoundParameters.ContainsKey('VariableGroupId')) { $groupId = $BoundParameters.VariableGroupId }

    [pscustomobject]@{
        Desired           = $desired
        Diff              = $diff
        TargetArgument    = $target
        VariableGroupName = $groupName
        VariableGroupId   = $groupId
        TargetDisplay     = ('{0}{1} (resource group {2}{3})' -f $AppName, $(if ($Slot) { "/$Slot" } else { '' }), $ResourceGroupName, $(if ($Subscription) { ", subscription $Subscription" } else { '' }))
    }
}
