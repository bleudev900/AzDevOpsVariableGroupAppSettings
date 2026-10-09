function Get-AppServiceTargetArgument {
    # Common az webapp arguments for the target app (resource group, name, optional slot/subscription).
    [CmdletBinding()]
    [OutputType([System.Array])]
    param(
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [Parameter(Mandatory)][string] $AppName,
        [string] $Slot,
        [string] $Subscription
    )
    $result = @('--resource-group', $ResourceGroupName, '--name', $AppName)
    if ($Slot) { $result += @('--slot', $Slot) }
    if ($Subscription) { $result += @('--subscription', $Subscription) }
    , $result
}

function Get-AppServiceAppSettingList {
    # az webapp config appsettings list -> list of { Name; Value; SlotSetting }
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]] $TargetArgument)
    $raw = Invoke-AzCli -Arguments (@('webapp', 'config', 'appsettings', 'list') + $TargetArgument)
    foreach ($s in @($raw | Where-Object { $null -ne $_ })) {
        $sticky = $false
        if ($s.PSObject.Properties['slotSetting'] -and $s.slotSetting) { $sticky = $true }
        [pscustomobject]@{
            Name        = [string]$s.name
            Value       = if ($s.PSObject.Properties['value'] -and $null -ne $s.value) { [string]$s.value } else { $null }
            SlotSetting = $sticky
        }
    }
}

function New-PrivateTempFile {
    # Creates an empty temp file readable only by the current user (chmod 600 on Linux/macOS).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a private temp file only.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $dir = if ($env:AGENT_TEMPDIRECTORY -and (Test-Path -LiteralPath $env:AGENT_TEMPDIRECTORY)) { $env:AGENT_TEMPDIRECTORY } else { [IO.Path]::GetTempPath() }
    $path = Join-Path $dir ('appsettings-{0}.json' -f [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($path, '')
    if (-not (Test-IsWindowsPlatform)) {
        $chmod = Get-Command -Name chmod -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($chmod) { & $chmod 600 $path }
    }
    $path
}

function Set-AppServiceAppSettingValue {
    <#
        Adds/updates app settings with:
          az webapp config appsettings set ... --settings @<temp.json>
        The settings are written to a temp JSON file in the format produced by 'appsettings list'
        ([{ "name", "value", "slotSetting"? }]) so no value ever appears on a command line and no
        shell quoting/escaping is involved (Windows cmd/az.cmd and Linux alike). "slotSetting" is only
        included for settings that must become sticky, so existing sticky flags are not touched otherwise.
        The temp file is always deleted.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal; ShouldProcess is handled by the public command.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $TargetArgument,
        [Parameter(Mandatory)][object[]] $Setting  # { Name; Value; SlotSetting }
    )
    $payload = New-Object System.Collections.Generic.List[object]
    foreach ($s in $Setting) {
        $item = [ordered]@{ name = [string]$s.Name; value = [string]$s.Value }
        if ($s.SlotSetting) { $item.slotSetting = $true }
        $payload.Add([pscustomobject]$item)
    }
    $json = ConvertTo-Json -InputObject @($payload.ToArray()) -Depth 5 -Compress

    $file = New-PrivateTempFile
    try {
        [IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding $false))
        $null = Invoke-AzCli -Arguments (@('webapp', 'config', 'appsettings', 'set') + $TargetArgument + @('--settings', "@$file"))
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Remove-AppServiceAppSettingValue {
    # az webapp config appsettings delete ... --setting-names a b c
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal; ShouldProcess is handled by the public command.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $TargetArgument,
        [Parameter(Mandatory)][string[]] $Name
    )
    $null = Invoke-AzCli -Arguments (@('webapp', 'config', 'appsettings', 'delete') + $TargetArgument + @('--setting-names') + $Name)
}
