function Test-IsWindowsPlatform {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Get-AzCliCommand {
    # Resolves the az executable (az.cmd on Windows). Separate function so tests can substitute a fake.
    [CmdletBinding()]
    param()
    Get-Command -Name 'az' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Invoke-AzCli {
    <#
    .SYNOPSIS
        Runs the Azure CLI (az) and returns its parsed JSON output.

    .DESCRIPTION
        Single choke point for every az call made by the module (tests mock this function).
        Appends '--output json' and '--only-show-errors', captures stdout and stderr separately,
        throws if $LASTEXITCODE is non-zero (the error message contains az's stderr, never the
        arguments, which may reference files with secret values), and converts stdout from JSON.

    .PARAMETER Arguments
        Arguments for az, e.g. 'pipelines', 'variable-group', 'list', '--group-name', 'MyGroup'.

    .PARAMETER Raw
        Return stdout as a single string instead of parsing it as JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]] $Arguments,

        [switch] $Raw
    )

    $azCommand = Get-AzCliCommand
    if (-not $azCommand) {
        throw 'The Azure CLI (az) was not found on PATH. Install it (https://aka.ms/azure-cli) or run inside an AzureCLI@2 task.'
    }

    $allArgs = @($Arguments)
    if ($allArgs -notcontains '--output' -and $allArgs -notcontains '-o') { $allArgs += @('--output', 'json') }
    if ($allArgs -notcontains '--only-show-errors') { $allArgs += '--only-show-errors' }

    # Display form for verbose/errors: only the leading command words, never option values.
    $words = foreach ($a in $Arguments) { if ($a -like '-*') { break }; $a }
    $commandText = 'az ' + (@($words) -join ' ')
    Write-Verbose "Running: $commandText"

    $previousEap = $ErrorActionPreference
    $previousOutputEncoding = $null
    $previousPythonEncoding = $env:PYTHONIOENCODING
    try {
        # Native stderr must not turn into terminating errors (PS 5.1 with 2>&1, PS 7.3+ native preference).
        $ErrorActionPreference = 'Continue'
        Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local
        # az is Python: make it emit UTF-8 and make PowerShell decode it as UTF-8 (non-ASCII values on Windows).
        $env:PYTHONIOENCODING = 'utf-8'
        try {
            $previousOutputEncoding = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        }
        catch { $previousOutputEncoding = $null }

        $global:LASTEXITCODE = 0
        $output = @(& $azCommand @allArgs 2>&1)
        $exitCode = $global:LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousEap
        $env:PYTHONIOENCODING = $previousPythonEncoding
        if ($null -ne $previousOutputEncoding) {
            try { [Console]::OutputEncoding = $previousOutputEncoding } catch { Write-Verbose 'Could not restore console output encoding.' }
        }
    }

    $stdout = New-Object System.Collections.Generic.List[string]
    $stderr = New-Object System.Collections.Generic.List[string]
    foreach ($line in $output) {
        if ($line -is [System.Management.Automation.ErrorRecord]) { $stderr.Add($line.ToString()) }
        else { $stdout.Add([string]$line) }
    }

    if ($exitCode -ne 0) {
        $message = ($stderr | Where-Object { $_ -and $_.Trim() }) -join [Environment]::NewLine
        if (-not $message) { $message = '(no error output)' }
        throw "'$commandText' failed with exit code $exitCode. $message"
    }

    $text = ($stdout -join [Environment]::NewLine).Trim()
    if ($Raw) { return $text }
    if (-not $text) { return $null }
    try {
        $parsed = ConvertFrom-Json -InputObject $text
    }
    catch {
        throw "'$commandText' returned output that is not valid JSON: $($_.Exception.Message)"
    }
    # Enumerate JSON arrays the same way on Windows PowerShell 5.1 (which emits them as one object) and 7+.
    # Callers wrap list results in @().
    if ($parsed -is [array]) { foreach ($item in $parsed) { $item } } else { $parsed }
}
