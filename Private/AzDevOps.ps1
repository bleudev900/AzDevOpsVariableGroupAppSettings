function Resolve-AzDoConnection {
    <#
        Resolves organization URL and project, defaulting to the Azure Pipelines predefined variables
        SYSTEM_COLLECTIONURI / SYSTEM_TEAMFOUNDATIONCOLLECTIONURI and SYSTEM_TEAMPROJECT.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string] $Organization,
        [AllowNull()][AllowEmptyString()][string] $Project
    )
    if (-not $Organization) { $Organization = $env:SYSTEM_COLLECTIONURI }
    if (-not $Organization) { $Organization = $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI }
    if (-not $Project) { $Project = $env:SYSTEM_TEAMPROJECT }

    if (-not $Organization) {
        Write-TerminatingPipelineError 'No Azure DevOps organization URL. Pass -Organization (e.g. https://dev.azure.com/contoso) or run inside Azure Pipelines (SYSTEM_COLLECTIONURI).'
    }
    if (-not $Project) {
        Write-TerminatingPipelineError 'No Azure DevOps project. Pass -Project or run inside Azure Pipelines (SYSTEM_TEAMPROJECT).'
    }
    if ($Organization -notmatch '^https?://') {
        # Allow just the organization name.
        $Organization = "https://dev.azure.com/$Organization"
    }
    [pscustomobject]@{ Organization = $Organization; Project = $Project }
}

function Invoke-WithAzDevOpsAuth {
    <#
        Runs a script block with AZURE_DEVOPS_EXT_PAT set for the az devops/pipelines extension.
        Precedence: existing AZURE_DEVOPS_EXT_PAT > SYSTEM_ACCESSTOKEN (must be mapped into the step's env
        in YAML) > whatever az itself is logged in with (az login / AzureCLI@2 service connection).
        The environment variable is restored afterwards.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock] $ScriptBlock)

    $previous = $env:AZURE_DEVOPS_EXT_PAT
    $changed = $false
    try {
        if (-not $previous -and $env:SYSTEM_ACCESSTOKEN) {
            Write-Verbose 'Using SYSTEM_ACCESSTOKEN as AZURE_DEVOPS_EXT_PAT for az devops commands.'
            $env:AZURE_DEVOPS_EXT_PAT = $env:SYSTEM_ACCESSTOKEN
            $changed = $true
        }
        elseif ($previous) {
            Write-Verbose 'Using AZURE_DEVOPS_EXT_PAT for az devops commands.'
        }
        else {
            Write-Verbose 'Neither AZURE_DEVOPS_EXT_PAT nor SYSTEM_ACCESSTOKEN is set; relying on the current az login.'
        }
        & $ScriptBlock
    }
    finally {
        if ($changed) { $env:AZURE_DEVOPS_EXT_PAT = $previous }
    }
}

function ConvertTo-AzDoVariableList {
    # Converts az's "variables" object ({ "name": { "isSecret": bool, "value": "..." } }) to a list.
    [CmdletBinding()]
    param([AllowNull()] $Variables)
    if ($null -eq $Variables) { return }
    $props = if ($Variables -is [System.Collections.IDictionary]) {
        foreach ($k in $Variables.Keys) { [pscustomobject]@{ Name = [string]$k; Value = $Variables[$k] } }
    }
    else { $Variables.PSObject.Properties }
    foreach ($p in $props) {
        $entry = $p.Value
        $isSecret = $false
        $value = $null
        if ($null -ne $entry) {
            if ($entry.PSObject.Properties['isSecret'] -and $entry.isSecret) { $isSecret = [bool]$entry.isSecret }
            if ($entry.PSObject.Properties['value']) { $value = $entry.value }
        }
        [pscustomobject]@{
            Name     = [string]$p.Name
            IsSecret = $isSecret
            Value    = if ($null -eq $value) { $null } else { [string]$value }
        }
    }
}

function Get-AzDoVariableGroup {
    <#
        Finds a variable group by exact name (case-insensitive) or ID and returns
        @{ Id; Name; Variables = list of { Name; IsSecret; Value } }.
        Uses: az pipelines variable-group list / show, az pipelines variable-group variable list.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Name and Id are used inside the script block passed to Invoke-WithAzDevOpsAuth.')]
    [CmdletBinding()]
    param(
        [string] $Name,
        [int] $Id,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Project
    )
    $common = @('--organization', $Organization, '--project', $Project, '--detect', 'false')

    Invoke-WithAzDevOpsAuth {
        if ($Name) {
            $groups = @(Invoke-AzCli -Arguments (@('pipelines', 'variable-group', 'list', '--group-name', $Name) + $common) | Where-Object { $null -ne $_ })
            $exact = @($groups | Where-Object { [string]::Equals([string]$_.name, $Name, [StringComparison]::OrdinalIgnoreCase) })
            if ($exact.Count -eq 0) {
                Write-TerminatingPipelineError "Variable group '$Name' was not found in project '$Project' ($Organization), or the identity running az cannot read it."
            }
            if ($exact.Count -gt 1) {
                Write-TerminatingPipelineError "More than one variable group is named '$Name' (IDs: $(($exact | ForEach-Object { $_.id }) -join ', ')). Use -VariableGroupId."
            }
            $group = $exact[0]
        }
        else {
            $group = Invoke-AzCli -Arguments (@('pipelines', 'variable-group', 'show', '--group-id', [string]$Id) + $common)
            if ($null -eq $group) { Write-TerminatingPipelineError "Variable group $Id was not found in project '$Project' ($Organization)." }
        }

        $groupId = [int]$group.id
        $variables = Invoke-AzCli -Arguments (@('pipelines', 'variable-group', 'variable', 'list', '--group-id', [string]$groupId) + $common)

        [pscustomobject]@{
            Id        = $groupId
            Name      = [string]$group.name
            Variables = @(ConvertTo-AzDoVariableList -Variables $variables)
        }
    }
}
