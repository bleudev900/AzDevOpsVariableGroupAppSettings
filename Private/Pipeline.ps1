# Azure Pipelines logging-command helpers. When not running in a pipeline (TF_BUILD unset),
# messages fall back to plain host output / Write-Warning.

function Test-AzurePipeline {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    [string]$env:TF_BUILD -eq 'True'
}

function ConvertTo-PipelineCommandData {
    # Escaping for the message part of ##vso commands (see "Logging commands" docs).
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string] $Text)
    $Text.Replace('%', '%AZP25').Replace("`r", '%0D').Replace("`n", '%0A')
}

function Write-PipelineLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Azure Pipelines logging commands must be written to the host/stdout.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Message,
        [ValidateSet('Info', 'Section', 'Command', 'Debug')][string] $Kind = 'Info'
    )
    if (Test-AzurePipeline) {
        switch ($Kind) {
            'Section' { Write-Host "##[section]$Message" }
            'Command' { Write-Host "##[command]$Message" }
            'Debug'   { Write-Host "##[debug]$Message" }
            default   { Write-Host $Message }
        }
    }
    elseif ($Kind -eq 'Debug') { Write-Verbose $Message }
    else { Write-Host $Message }
}

function Write-PipelineGroup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Azure Pipelines logging commands must be written to the host/stdout.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Start')][string] $Start,
        [Parameter(Mandatory, ParameterSetName = 'End')][switch] $End
    )
    if (Test-AzurePipeline) {
        if ($End) { Write-Host '##[endgroup]' } else { Write-Host "##[group]$Start" }
    }
    elseif (-not $End) { Write-Host "== $Start ==" }
}

function Write-PipelineWarning {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Azure Pipelines logging commands must be written to the host/stdout.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)
    if (Test-AzurePipeline) { Write-Host "##vso[task.logissue type=warning]$(ConvertTo-PipelineCommandData $Message)" }
    else { Write-Warning $Message }
}

function Write-PipelineError {
    # Only logs the issue; callers still throw so the step fails.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Azure Pipelines logging commands must be written to the host/stdout.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)
    if (Test-AzurePipeline) { Write-Host "##vso[task.logissue type=error]$(ConvertTo-PipelineCommandData $Message)" }
}

function Register-PipelineSecret {
    <#
        Registers a value with the agent's secret masker (##vso[task.setsecret]) so it is replaced by ***
        in all subsequent log output. Only does anything inside Azure Pipelines; outside a pipeline
        nothing is written (writing the command would print the secret).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Azure Pipelines logging commands must be written to the host/stdout.')]
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string] $Value)
    if (-not (Test-AzurePipeline) -or [string]::IsNullOrEmpty($Value)) { return }
    # The masker works per line, so register each line of multi-line secrets separately.
    foreach ($line in ($Value -split "`r?`n")) {
        if ($line.Trim().Length -ge 1) { Write-Host "##vso[task.setsecret]$line" }
    }
}

function Write-TerminatingPipelineError {
    # Logs the error as a pipeline issue (when in a pipeline) and throws.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)
    Write-PipelineError -Message $Message
    throw $Message
}
