$script:DefaultPreservedSetting = @(
    'WEBSITE_*', 'WEBSITES_*', 'SCM_*', 'APPINSIGHTS_*', 'APPLICATIONINSIGHTS_*', 'ApplicationInsightsAgent_*',
    'XDT_*', 'DiagnosticServices_*', 'InstrumentationEngine_*', 'SnapshotDebugger_*', 'DOCKER_*',
    'FUNCTIONS_*', 'AzureWebJobs*', 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET', 'ENABLE_ORYX_BUILD',
    'ASPNETCORE_ENVIRONMENT', 'DOTNET_ENVIRONMENT'
)

$script:MaskedValue = '********'

function Test-WildcardMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Name, [string[]] $Pattern)
    foreach ($p in @($Pattern | Where-Object { $_ })) { if ($Name -like $p) { return $true } }
    $false
}

function Get-AppSettingDiff {
    <#
        Computes the diff between desired settings (from the variable group) and the app's current settings.
        Returns internal rows: Action (Add/Change/Remove/Unchanged/Preserve), Name, VariableName, IsSecret,
        SlotSetting, CurrentValue, NewValue (plain text - internal only, never output), ValueChanged,
        SlotSettingChanged.
        App setting names are compared case-insensitively (they become environment variables).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Desired,   # { Name; VariableName; IsSecret; PlainValue; SlotSetting }
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Current,   # { Name; Value; SlotSetting }
        [ValidateSet('Merge', 'Replace')][string] $Mode = 'Merge',
        [string[]] $PreservePattern = @()
    )
    $currentByName = @{}
    foreach ($c in $Current) { $currentByName[$c.Name] = $c }
    $desiredNames = @{}

    foreach ($d in $Desired) {
        $desiredNames[$d.Name] = $true
        $cur = $currentByName[$d.Name]
        if ($null -eq $cur) {
            $action = 'Add'; $valueChanged = $true; $stickyChanged = [bool]$d.SlotSetting
            $curValue = $null
        }
        else {
            $curValue = $cur.Value
            $valueChanged = -not [string]::Equals([string]$cur.Value, [string]$d.PlainValue, [StringComparison]::Ordinal)
            # Only request sticky -> true; never un-stick existing settings implicitly.
            $stickyChanged = [bool]$d.SlotSetting -and -not [bool]$cur.SlotSetting
            $action = if ($valueChanged -or $stickyChanged) { 'Change' } else { 'Unchanged' }
        }
        [pscustomobject]@{
            Action             = $action
            Name               = $d.Name
            VariableName       = $d.VariableName
            IsSecret           = [bool]$d.IsSecret
            SlotSetting        = [bool]$d.SlotSetting -or ($null -ne $cur -and [bool]$cur.SlotSetting)
            CurrentValue       = $curValue
            NewValue           = $d.PlainValue
            ValueChanged       = $valueChanged
            SlotSettingChanged = $stickyChanged
        }
    }

    foreach ($c in $Current) {
        if ($desiredNames.ContainsKey($c.Name)) { continue }
        $action = if ($Mode -eq 'Replace' -and -not (Test-WildcardMatch -Name $c.Name -Pattern $PreservePattern)) { 'Remove' } else { 'Preserve' }
        [pscustomobject]@{
            Action             = $action
            Name               = $c.Name
            VariableName       = $null
            IsSecret           = $true   # unknown origin: always masked
            SlotSetting        = [bool]$c.SlotSetting
            CurrentValue       = $c.Value
            NewValue           = $null
            ValueChanged       = $action -eq 'Remove'
            SlotSettingChanged = $false
        }
    }
}

function ConvertTo-PublicDiff {
    # Masks values in diff rows so they are safe to output/log.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Diff,
        [switch] $ShowNonSecretValues
    )
    $order = @{ Add = 0; Change = 1; Remove = 2; Unchanged = 3; Preserve = 4 }
    foreach ($row in ($Diff | Sort-Object @{ Expression = { $order[$_.Action] } }, Name)) {
        $reveal = $ShowNonSecretValues -and -not $row.IsSecret
        $mask = {
            param($v)
            if ($null -eq $v) { $null } elseif ($reveal) { $v } else { $script:MaskedValue }
        }
        $obj = [pscustomobject]@{
            PSTypeName         = 'AzDevOpsVariableGroupAppSettings.SettingChange'
            Action             = $row.Action
            Name               = $row.Name
            VariableName       = $row.VariableName
            IsSecret           = $row.IsSecret
            SlotSetting        = $row.SlotSetting
            ValueChanged       = $row.ValueChanged
            SlotSettingChanged = $row.SlotSettingChanged
            CurrentValue       = & $mask $row.CurrentValue
            NewValue           = & $mask $row.NewValue
        }
        $obj
    }
}

function Write-AppSettingDiff {
    # Writes a human-readable (masked) diff to the log.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $PublicDiff,
        [Parameter(Mandatory)][string] $Title
    )
    Write-PipelineGroup -Start $Title
    try {
        if ($PublicDiff.Count -eq 0) { Write-PipelineLog '(no settings)'; return }
        $width = [Math]::Max(4, ($PublicDiff | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum)
        foreach ($row in $PublicDiff) {
            $notes = New-Object System.Collections.Generic.List[string]
            if ($row.IsSecret -and $row.VariableName) { $notes.Add('secret') }
            if ($row.SlotSetting) { $notes.Add('slot setting') }
            if ($row.Action -eq 'Change') {
                if ($row.ValueChanged) { $notes.Add('value') }
                if ($row.SlotSettingChanged) { $notes.Add('made sticky') }
            }
            $detail = ''
            if ($row.Action -eq 'Add') { $detail = "= $($row.NewValue)" }
            elseif ($row.Action -eq 'Change' -and $row.ValueChanged) { $detail = "$($row.CurrentValue) -> $($row.NewValue)" }
            $source = if ($row.VariableName -and $row.VariableName -ne $row.Name) { " <- $($row.VariableName)" } else { '' }
            $line = '{0,-9} {1}{2}{3}{4}' -f $row.Action, $row.Name.PadRight($width), $(if ($detail) { "  $detail" } else { '' }),
                $(if ($notes.Count) { "  [$($notes -join ', ')]" } else { '' }), $source
            Write-PipelineLog $line.TrimEnd()
        }
        $counts = foreach ($a in 'Add', 'Change', 'Remove', 'Unchanged', 'Preserve') {
            '{0}: {1}' -f $a, @($PublicDiff | Where-Object { $_.Action -eq $a }).Count
        }
        Write-PipelineLog ($counts -join ', ')
    }
    finally { Write-PipelineGroup -End }
}
