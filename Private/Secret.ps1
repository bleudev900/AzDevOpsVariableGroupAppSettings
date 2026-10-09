function Get-PipelineEnvironmentVariableName {
    # Azure Pipelines maps variable names to environment variables by upper-casing them and
    # replacing '.' and ' ' with '_' (e.g. 'SETTING__Db.Password' -> 'SETTING__DB_PASSWORD').
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Name)
    ($Name -replace '[\. ]', '_').ToUpperInvariant()
}

function ConvertFrom-SecureStringToPlainText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][System.Security.SecureString] $SecureString)
    if ($null -eq $SecureString) { return $null }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function ConvertTo-SecureStringFromPlainText {
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param([AllowNull()][AllowEmptyString()][string] $Value)
    $secure = New-Object System.Security.SecureString
    if ($Value) { foreach ($c in $Value.ToCharArray()) { $secure.AppendChar($c) } }
    $secure.MakeReadOnly()
    $secure
}

function Resolve-SecretVariableValue {
    <#
        Secret variables are returned by the REST API / az without a value. Resolve the value from:
          1. -SecretValues hashtable, keyed by variable name or by app setting name
             (values may be strings or SecureStrings);
          2. an environment variable named exactly like the variable, or its pipeline-normalized form
             (upper-case, '.'/' ' -> '_'). Empty values count as unresolved. Secrets are never mapped into env automatically: map them
             explicitly in the step's env: block.
        Returns @{ Found; Value; Source } (Value is plain text, never logged).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $VariableName,
        [Parameter(Mandatory)][string] $SettingName,
        [AllowNull()][hashtable] $SecretValues
    )
    if ($SecretValues) {
        foreach ($key in @($VariableName, $SettingName)) {
            # Hashtable literals are case-insensitive; also support case-sensitive ones.
            $match = @($SecretValues.Keys | Where-Object { [string]::Equals([string]$_, $key, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
            if ($match.Count -gt 0) {
                $raw = $SecretValues[$match[0]]
                $value = if ($raw -is [System.Security.SecureString]) { ConvertFrom-SecureStringToPlainText $raw } else { [string]$raw }
                return [pscustomobject]@{ Found = $true; Value = $value; Source = 'SecretValues' }
            }
        }
    }

    $candidates = @($VariableName, (Get-PipelineEnvironmentVariableName -Name $VariableName)) | Select-Object -Unique
    foreach ($envName in $candidates) {
        $value = [Environment]::GetEnvironmentVariable($envName)
        if ([string]::IsNullOrEmpty($value)) { continue }
        if ($value -match '^\$\([^)]+\)$') {
            # The YAML mapped $(Name) but the variable didn't exist for the job (group not linked?).
            Write-PipelineWarning "Environment variable '$envName' contains the unexpanded macro '$value'. Link the variable group to the job (variables: - group: ...) so the secret can be mapped."
            continue
        }
        return [pscustomobject]@{ Found = $true; Value = $value; Source = "Environment:$envName" }
    }
    [pscustomobject]@{ Found = $false; Value = $null; Source = $null }
}

function Get-SettingPlainValue {
    # Returns the plain-text value of a setting object produced by Get-AzDoVariableGroupSetting.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Setting)
    if ($Setting.IsSecret) { ConvertFrom-SecureStringToPlainText $Setting.SecureValue }
    else { [string]$Setting.Value }
}
