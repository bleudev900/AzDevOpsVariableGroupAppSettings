<#
.SYNOPSIS
    Lint, manifest and test entry point used by CI and for local runs.

.DESCRIPTION
    Tasks:
      Bootstrap - install the pinned Pester and PSScriptAnalyzer versions for the current user if missing.
      Lint      - run PSScriptAnalyzer with ./PSScriptAnalyzerSettings.psd1; fails on any Error or Warning.
      Manifest  - run Test-ModuleManifest.
      Test      - run the Pester 5 suite, write NUnit XML to ./TestResults, fail on any failed test.
    Default runs Lint, Manifest and Test.

.EXAMPLE
    ./build.ps1 -Task Bootstrap, Lint, Manifest, Test
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Build script: console output and GitHub Actions workflow commands must go to the host.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'TestResultPath', Justification = 'Used by Invoke-Test via script scope.')]
[CmdletBinding()]
param(
    [ValidateSet('Bootstrap', 'Lint', 'Manifest', 'Test')]
    [string[]] $Task = @('Lint', 'Manifest', 'Test'),

    [string] $TestResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PesterVersion = '5.7.1'
$PSScriptAnalyzerVersion = '1.25.0'
$ModuleName = 'AzDevOpsVariableGroupAppSettings'
$ManifestPath = Join-Path $PSScriptRoot "$ModuleName.psd1"

function Write-Summary {
    param([string] $Markdown)
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Markdown -Encoding utf8 }
}

function Invoke-Bootstrap {
    $required = [ordered]@{ Pester = $PesterVersion; PSScriptAnalyzer = $PSScriptAnalyzerVersion }
    foreach ($name in $required.Keys) {
        $version = $required[$name]
        if (Get-Module -ListAvailable -Name $name | Where-Object { $_.Version -eq [version]$version }) {
            Write-Host "$name $version already installed."
            continue
        }
        Write-Host "Installing $name $version..."
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            # Windows PowerShell 5.1: make sure TLS 1.2 and the NuGet provider are available.
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $null = Get-PackageProvider -Name NuGet -ForceBootstrap
        }
        # -SkipPublisherCheck: Windows ships Pester 3.4 signed by a different publisher.
        Install-Module -Name $name -RequiredVersion $version -Scope CurrentUser -Repository PSGallery -Force -SkipPublisherCheck -AllowClobber
    }
}

function Invoke-Lint {
    Import-Module PSScriptAnalyzer -RequiredVersion $PSScriptAnalyzerVersion
    $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
    $findings = @(Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse -Settings $settings)
    if ($findings.Count -gt 0) {
        $findings | Sort-Object ScriptName, Line |
            Format-Table -AutoSize Severity, RuleName, ScriptName, Line, Message | Out-String -Width 300 | Write-Host
        foreach ($f in $findings) {
            # GitHub Actions annotations
            if ($env:GITHUB_ACTIONS -eq 'true') {
                $level = if ($f.Severity -eq 'Error') { 'error' } elseif ($f.Severity -eq 'Warning') { 'warning' } else { 'notice' }
                $rel = $f.ScriptPath.Substring($PSScriptRoot.Length).TrimStart([char]92, [char]47) -replace "\\", "/"
                Write-Host "::$level file=$rel,line=$($f.Line),title=$($f.RuleName)::$($f.Message)"
            }
        }
    }
    $blocking = @($findings | Where-Object { $_.Severity -in 'Error', 'Warning', 'ParseError' })
    Write-Summary ("### PSScriptAnalyzer`n{0} finding(s), {1} blocking (Error/Warning).`n" -f $findings.Count, $blocking.Count)
    if ($blocking.Count -gt 0) { throw "PSScriptAnalyzer reported $($blocking.Count) Error/Warning finding(s)." }
    Write-Host "PSScriptAnalyzer: $($findings.Count) finding(s), none blocking."
}

function Invoke-Manifest {
    $manifest = Test-ModuleManifest -Path $ManifestPath -ErrorAction Stop
    Write-Host "Test-ModuleManifest OK: $($manifest.Name) $($manifest.Version)"
    Write-Summary "### Test-ModuleManifest`n$($manifest.Name) $($manifest.Version) is valid.`n"
}

function Invoke-Test {
    Import-Module Pester -RequiredVersion $PesterVersion
    if (-not $TestResultPath) {
        $edition = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }
        $os = if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
        $TestResultPath = Join-Path $PSScriptRoot "TestResults/testResults-$os-$edition.xml"
    }
    $null = New-Item -ItemType Directory -Path (Split-Path $TestResultPath -Parent) -Force

    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $PSScriptRoot 'Tests'
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = $TestResultPath
    if ($env:GITHUB_ACTIONS -eq 'true') { $config.Output.CIFormat = 'GithubActions' }

    $result = Invoke-Pester -Configuration $config
    Write-Summary ("### Pester ({0} {1}, {2})`n| Passed | Failed | Skipped | NotRun |`n|---|---|---|---|`n| {3} | {4} | {5} | {6} |`n" -f
        $PSVersionTable.PSEdition, $PSVersionTable.PSVersion, [Environment]::OSVersion.Platform,
        $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.NotRunCount)
    Write-Host "Test results written to $TestResultPath"
    if ($result.Result -ne 'Passed') {
        throw "Pester run result: $($result.Result) ($($result.FailedCount) failed, $($result.FailedBlocksCount) failed blocks, $($result.FailedContainersCount) failed containers)."
    }
}

if ('Test' -in $Task -and 'Bootstrap' -notin $Task) {
    # Load the pinned Pester before anything can auto-load a different (e.g. 6.x) version;
    # Pester's assembly cannot be swapped once loaded in a process.
    Import-Module Pester -RequiredVersion $PesterVersion
}

foreach ($t in $Task) {
    Write-Host "==> $t" -ForegroundColor Cyan
    & "Invoke-$t"
}
