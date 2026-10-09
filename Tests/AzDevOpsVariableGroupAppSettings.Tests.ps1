#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:ModuleRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:ModuleName = 'AzDevOpsVariableGroupAppSettings'
    Get-Module $script:ModuleName | Remove-Module -Force
    Import-Module (Join-Path $script:ModuleRoot "$($script:ModuleName).psd1") -Force

    $script:EnvNames = @('TF_BUILD', 'SYSTEM_COLLECTIONURI', 'SYSTEM_TEAMFOUNDATIONCOLLECTIONURI', 'SYSTEM_TEAMPROJECT',
        'SYSTEM_ACCESSTOKEN', 'AZURE_DEVOPS_EXT_PAT', 'SETTING__Db__Password', 'SETTING__DB__PASSWORD', 'SETTING__API_KEY',
        'SETTING__Api.Key', 'SETTING__API_KEY2', 'AGENT_TEMPDIRECTORY')
    $script:SavedEnv = @{}
    foreach ($n in $script:EnvNames) { $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }

    function script:Reset-TestEnvironment {
        foreach ($n in $script:EnvNames) { Remove-Item -Path "env:$n" -ErrorAction SilentlyContinue }
        $env:SYSTEM_COLLECTIONURI = 'https://dev.azure.com/contoso/'
        $env:SYSTEM_TEAMPROJECT = 'Web'
    }

    # State shared with mock bodies (they run in this file's script scope).
    $script:State = @{}

    function script:Register-AzMock {
        param(
            # name -> value (string) or @{ isSecret = $true } / @{ value = ...; isSecret = ... }
            [System.Collections.IDictionary] $Variables = [ordered]@{},
            [object[]] $AppSettings = @(),
            [object[]] $Groups = @(@{ id = 7; name = 'MyApp-Prod' }),
            [switch] $FailSet
        )
        $vars = [ordered]@{}
        foreach ($k in $Variables.Keys) {
            $v = $Variables[$k]
            if ($v -is [System.Collections.IDictionary]) {
                $vars[$k] = @{ isSecret = [bool]$v['isSecret']; value = $v['value'] }
            }
            else { $vars[$k] = @{ isSecret = $null; value = $v } }
        }
        $script:State.VariablesJson = ConvertTo-Json -InputObject $vars -Depth 5
        $script:State.GroupsJson = ConvertTo-Json -InputObject @($Groups) -Depth 5
        $script:State.AppSettingsJson = ConvertTo-Json -InputObject @($AppSettings | ForEach-Object {
                [ordered]@{ name = $_.name; value = $_.value; slotSetting = [bool]$_['slotSetting'] } }) -Depth 5
        $script:State.Calls = New-Object System.Collections.Generic.List[object]
        $script:State.SetPayload = $null
        $script:State.SetFile = $null
        $script:State.PatDuringCall = $null
        $script:State.FailSet = [bool]$FailSet
        $script:State.HostLines = New-Object System.Collections.Generic.List[string]

        Mock -ModuleName $script:ModuleName Invoke-AzCli {
            $a = @($Arguments)
            $script:State.Calls.Add($a)
            $script:State.PatDuringCall = $env:AZURE_DEVOPS_EXT_PAT
            $cmd = ($a | Where-Object { $_ -notlike '-*' } | Select-Object -First 4) -join ' '
            switch -Wildcard ($cmd) {
                'pipelines variable-group list*' { $groups = ConvertFrom-Json $script:State.GroupsJson; return $groups }
                'pipelines variable-group show*' {
                    $id = $a[[array]::IndexOf($a, '--group-id') + 1]
                    $groups = ConvertFrom-Json $script:State.GroupsJson
                    $g = foreach ($x in $groups) { if ([string]$x.id -eq $id) { $x } }
                    if (-not $g) { throw "'az pipelines variable-group show' failed with exit code 1. not found" }
                    return $g
                }
                'pipelines variable-group variable list' { return (ConvertFrom-Json $script:State.VariablesJson) }
                'webapp config appsettings list' { $list = ConvertFrom-Json $script:State.AppSettingsJson; return $list }
                'webapp config appsettings set' {
                    $fileArg = $a[[array]::IndexOf($a, '--settings') + 1]
                    $script:State.SetFile = $fileArg.Substring(1)
                    # Assign first: Windows PowerShell 5.1 emits a JSON array as a single object.
                    $parsed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $script:State.SetFile -Raw)
                    $script:State.SetPayload = @(foreach ($x in $parsed) { $x })
                    if ($script:State.FailSet) { throw 'az failed' }
                    return $null
                }
                'webapp config appsettings delete' { return $null }
                default { throw "Unexpected az call: $($a -join ' ')" }
            }
        }
        Mock -ModuleName $script:ModuleName Write-Host { $script:State.HostLines.Add([string]$Object) }
    }

    function script:Get-AzCall {
        param([string] $Command)
        # Returns an array of calls (each call is a string[]), without unrolling a single call.
        $matched = New-Object System.Collections.Generic.List[object]
        foreach ($call in $script:State.Calls) {
            if ((($call | Where-Object { $_ -notlike '-*' } | Select-Object -First 4) -join ' ') -like "$Command*") { $matched.Add($call) }
        }
        , $matched.ToArray()
    }

    function script:Get-ArgValue {
        param([string[]] $Call, [string] $Name)
        $i = [array]::IndexOf($Call, $Name)
        if ($i -lt 0) { return $null }
        $Call[$i + 1]
    }

    $script:Target = @{ ResourceGroupName = 'rg-web'; AppName = 'contoso-web' }
}

AfterAll {
    foreach ($n in $script:EnvNames) {
        if ($null -eq $script:SavedEnv[$n]) { Remove-Item -Path "env:$n" -ErrorAction SilentlyContinue }
        else { Set-Item -Path "env:$n" -Value $script:SavedEnv[$n] }
    }
    Get-Module $script:ModuleName | Remove-Module -Force
}

Describe 'Module' {
    It 'exports the public commands only' {
        $names = (Get-Command -Module $script:ModuleName).Name | Sort-Object
        $names | Should -Be @('Compare-AppServiceSettingFromVariableGroup', 'Get-AzDoVariableGroupSetting', 'Set-AppServiceSettingFromVariableGroup')
    }

    It 'has a valid manifest with license and project URIs' {
        $m = Test-ModuleManifest -Path (Join-Path $script:ModuleRoot "$($script:ModuleName).psd1")
        $m.Author | Should -Be 'algogang'
        $m.LicenseUri | Should -Match 'AzDevOpsVariableGroupAppSettings/blob/main/LICENSE$'
        $m.ProjectUri | Should -Match 'github.com/bleudev900/AzDevOpsVariableGroupAppSettings$'
    }

    It 'has comment-based help with examples for every public command' {
        foreach ($c in Get-Command -Module $script:ModuleName) {
            $help = Get-Help $c.Name -Full
            $help.Synopsis | Should -Not -BeNullOrEmpty
            @($help.Examples.Example).Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Get-AzDoVariableGroupSetting' {
    BeforeEach { Reset-TestEnvironment }

    It 'selects prefixed variables and strips the prefix, keeping double underscores' {
        Register-AzMock -Variables ([ordered]@{
                'SETTING__SomeSettingName__WithUnderscores' = 'a'
                'SETTING__Plain'                            = 'b'
                'OTHER__Ignored'                            = 'c'
                'SETTINGIgnored'                            = 'd'
            })
        $r = @(Get-AzDoVariableGroupSetting -VariableGroupName 'MyApp-Prod')
        $r.Name | Should -Be @('Plain', 'SomeSettingName__WithUnderscores')
        ($r | Where-Object Name -EQ 'SomeSettingName__WithUnderscores').Value | Should -Be 'a'
        ($r | Where-Object Name -EQ 'Plain').VariableName | Should -Be 'SETTING__Plain'
        $r[0].VariableGroupName | Should -Be 'MyApp-Prod'
        $r[0].VariableGroupId | Should -Be 7
        $r[0].IsSecret | Should -BeFalse
        $r[0].ValueSource | Should -Be 'VariableGroup'
    }

    It 'matches the prefix case-insensitively by default' {
        Register-AzMock -Variables ([ordered]@{ 'setting__Lower' = '1'; 'SETTING__Upper' = '2' })
        (Get-AzDoVariableGroupSetting 'MyApp-Prod').Name | Should -Be @('Lower', 'Upper')
    }

    It 'matches case-sensitively with -CaseSensitive' {
        Register-AzMock -Variables ([ordered]@{ 'setting__Lower' = '1'; 'SETTING__Upper' = '2' })
        (Get-AzDoVariableGroupSetting 'MyApp-Prod' -CaseSensitive).Name | Should -Be @('Upper')
    }

    It 'supports a custom prefix and -KeepPrefix' {
        Register-AzMock -Variables ([ordered]@{ 'SETTINGS__A__B' = '1'; 'SETTING__C' = '2' })
        (Get-AzDoVariableGroupSetting 'MyApp-Prod' -Prefix 'SETTINGS__').Name | Should -Be @('A__B')
        (Get-AzDoVariableGroupSetting 'MyApp-Prod' -Prefix 'SETTINGS__' -KeepPrefix).Name | Should -Be @('SETTINGS__A__B')
    }

    It 'selects every variable with an empty prefix' {
        Register-AzMock -Variables ([ordered]@{ 'A' = '1'; 'B' = '2' })
        (Get-AzDoVariableGroupSetting 'MyApp-Prod' -Prefix '').Name | Should -Be @('A', 'B')
    }

    It 'warns and returns nothing when no variable matches' {
        Register-AzMock -Variables ([ordered]@{ 'X' = '1' })
        $r = Get-AzDoVariableGroupSetting 'MyApp-Prod' -WarningVariable w -WarningAction SilentlyContinue
        $r | Should -BeNullOrEmpty
        $w | Should -Match "start with 'SETTING__'"
    }

    It 'skips variables that are empty after removing the prefix' {
        Register-AzMock -Variables ([ordered]@{ 'SETTING__' = '1'; 'SETTING__Ok' = '2' })
        (Get-AzDoVariableGroupSetting 'MyApp-Prod' -WarningAction SilentlyContinue).Name | Should -Be @('Ok')
    }

    Context 'group lookup and connection' {
        It 'finds the group by exact (case-insensitive) name among list results and passes org/project' {
            Register-AzMock -Variables ([ordered]@{ 'SETTING__A' = '1' }) -Groups @(@{ id = 1; name = 'MyApp-Prod-Old' }, @{ id = 2; name = 'myapp-prod' })
            $r = Get-AzDoVariableGroupSetting 'MyApp-Prod'
            $r.VariableGroupId | Should -Be 2
            $list = (Get-AzCall 'pipelines variable-group list')[0]
            Get-ArgValue $list '--group-name' | Should -Be 'MyApp-Prod'
            Get-ArgValue $list '--organization' | Should -Be 'https://dev.azure.com/contoso/'
            Get-ArgValue $list '--project' | Should -Be 'Web'
            Get-ArgValue $list '--detect' | Should -Be 'false'
            Get-ArgValue (Get-AzCall 'pipelines variable-group variable list')[0] '--group-id' | Should -Be '2'
        }

        It 'throws when the group is not found' {
            Register-AzMock -Groups @(@{ id = 1; name = 'Other' })
            { Get-AzDoVariableGroupSetting 'MyApp-Prod' } | Should -Throw "*'MyApp-Prod' was not found*"
        }

        It 'throws when the name is ambiguous' {
            Register-AzMock -Groups @(@{ id = 1; name = 'MyApp-Prod' }, @{ id = 2; name = 'MYAPP-PROD' })
            { Get-AzDoVariableGroupSetting 'MyApp-Prod' } | Should -Throw '*Use -VariableGroupId*'
        }

        It 'reads the group by ID with variable-group show' {
            Register-AzMock -Variables ([ordered]@{ 'SETTING__A' = '1' }) -Groups @(@{ id = 42; name = 'ById' })
            $r = Get-AzDoVariableGroupSetting -VariableGroupId 42
            $r.VariableGroupName | Should -Be 'ById'
            Get-ArgValue (Get-AzCall 'pipelines variable-group show')[0] '--group-id' | Should -Be '42'
            Get-AzCall 'pipelines variable-group list' | Should -BeNullOrEmpty
        }

        It 'uses explicit -Organization/-Project over pipeline variables and expands a bare org name' {
            Register-AzMock -Variables ([ordered]@{ 'SETTING__A' = '1' })
            $null = Get-AzDoVariableGroupSetting 'MyApp-Prod' -Organization fabrikam -Project Api
            $list = (Get-AzCall 'pipelines variable-group list')[0]
            Get-ArgValue $list '--organization' | Should -Be 'https://dev.azure.com/fabrikam'
            Get-ArgValue $list '--project' | Should -Be 'Api'
        }

        It 'falls back to SYSTEM_TEAMFOUNDATIONCOLLECTIONURI' {
            Register-AzMock -Variables ([ordered]@{ 'SETTING__A' = '1' })
            $env:SYSTEM_COLLECTIONURI = $null
            $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI = 'https://contoso.visualstudio.com/'
            $null = Get-AzDoVariableGroupSetting 'MyApp-Prod'
            Get-ArgValue (Get-AzCall 'pipelines variable-group list')[0] '--organization' | Should -Be 'https://contoso.visualstudio.com/'
        }

        It 'throws without organization or project' {
            Register-AzMock
            $env:SYSTEM_COLLECTIONURI = $null
            { Get-AzDoVariableGroupSetting 'MyApp-Prod' } | Should -Throw '*organization URL*'
            $env:SYSTEM_COLLECTIONURI = 'https://dev.azure.com/contoso/'
            $env:SYSTEM_TEAMPROJECT = $null
            { Get-AzDoVariableGroupSetting 'MyApp-Prod' } | Should -Throw '*project*'
        }
    }

    Context 'authentication' {
        It 'uses SYSTEM_ACCESSTOKEN as AZURE_DEVOPS_EXT_PAT during az calls and restores it' {
            Register-AzMock -Variables ([ordered]@{ 'SETTING__A' = '1' })
            $env:SYSTEM_ACCESSTOKEN = 'job-token'
            $null = Get-AzDoVariableGroupSetting 'MyApp-Prod'
            $script:State.PatDuringCall | Should -Be 'job-token'
            $env:AZURE_DEVOPS_EXT_PAT | Should -BeNullOrEmpty
        }

        It 'prefers an existing AZURE_DEVOPS_EXT_PAT' {
            Register-AzMock -Variables ([ordered]@{ 'SETTING__A' = '1' })
            $env:SYSTEM_ACCESSTOKEN = 'job-token'
            $env:AZURE_DEVOPS_EXT_PAT = 'my-pat'
            $null = Get-AzDoVariableGroupSetting 'MyApp-Prod'
            $script:State.PatDuringCall | Should -Be 'my-pat'
            $env:AZURE_DEVOPS_EXT_PAT | Should -Be 'my-pat'
        }

        It 'restores the environment when az fails' {
            Register-AzMock -Groups @()
            $env:SYSTEM_ACCESSTOKEN = 'job-token'
            { Get-AzDoVariableGroupSetting 'MyApp-Prod' } | Should -Throw
            $env:AZURE_DEVOPS_EXT_PAT | Should -BeNullOrEmpty
        }
    }

    Context 'secret variables' {
        BeforeEach {
            Register-AzMock -Variables ([ordered]@{
                    'SETTING__Db__Password' = @{ isSecret = $true; value = $null }
                    'SETTING__Plain'        = 'p'
                })
        }

        It 'resolves a secret from an environment variable with the same name' {
            $env:SETTING__Db__Password = 's3cr3t!'
            $s = Get-AzDoVariableGroupSetting 'MyApp-Prod' | Where-Object Name -EQ 'Db__Password'
            $s.IsSecret | Should -BeTrue
            $s.Value | Should -BeNullOrEmpty
            $s.SecureValue | Should -BeOfType [System.Security.SecureString]
            ([pscredential]::new('x', $s.SecureValue)).GetNetworkCredential().Password | Should -Be 's3cr3t!'
            $s.ValueSource | Should -BeLike 'Environment:*'
        }

        It 'resolves a secret from the pipeline-normalized environment name (upper-case, dots to underscores)' {
            Register-AzMock -Variables ([ordered]@{ 'SETTING__Api.Key' = @{ isSecret = $true } })
            # On Windows env names are case-insensitive; on Linux only the normalized name exists.
            [Environment]::SetEnvironmentVariable('SETTING__API_KEY', 'k')
            $s = Get-AzDoVariableGroupSetting 'MyApp-Prod'
            $s.Name | Should -Be 'Api.Key'
            ([pscredential]::new('x', $s.SecureValue)).GetNetworkCredential().Password | Should -Be 'k'
        }

        It 'prefers -SecretValues (string or SecureString, by variable or setting name) over the environment' {
            $env:SETTING__Db__Password = 'from-env'
            $s = Get-AzDoVariableGroupSetting 'MyApp-Prod' -SecretValues @{ 'SETTING__Db__Password' = 'from-hashtable' } | Where-Object IsSecret
            ([pscredential]::new('x', $s.SecureValue)).GetNetworkCredential().Password | Should -Be 'from-hashtable'
            $s.ValueSource | Should -Be 'SecretValues'

            $secure = (New-Object System.Net.NetworkCredential('', 'secure-value')).SecurePassword
            $s = Get-AzDoVariableGroupSetting 'MyApp-Prod' -SecretValues @{ 'Db__Password' = $secure } | Where-Object IsSecret
            ([pscredential]::new('x', $s.SecureValue)).GetNetworkCredential().Password | Should -Be 'secure-value'
        }

        It 'fails by default when a secret cannot be resolved, naming the variable' {
            { Get-AzDoVariableGroupSetting 'MyApp-Prod' } | Should -Throw '*SETTING__Db__Password*-SecretValues*'
        }

        It 'skips unresolved secrets with -SkipUnresolvedSecret' {
            $r = @(Get-AzDoVariableGroupSetting 'MyApp-Prod' -SkipUnresolvedSecret -WarningVariable w -WarningAction SilentlyContinue)
            $r.Name | Should -Be @('Plain')
            $w | Should -Match 'SETTING__Db__Password'
        }

        It 'treats an unexpanded $(macro) in the environment as unresolved' {
            $env:SETTING__Db__Password = '$(SETTING__Db__Password)'
            { Get-AzDoVariableGroupSetting 'MyApp-Prod' -WarningAction SilentlyContinue } | Should -Throw '*Could not resolve*'
        }

        It 'treats variables without a value (e.g. Key Vault-linked) as secrets' {
            Register-AzMock -Variables ([ordered]@{ 'SETTING__FromKv' = @{ isSecret = $false; value = $null } })
            { Get-AzDoVariableGroupSetting 'MyApp-Prod' } | Should -Throw '*SETTING__FromKv*'
        }

        It 'registers resolved secrets with the log masker only inside Azure Pipelines' {
            $env:SETTING__Db__Password = "line1`nline2"
            $null = Get-AzDoVariableGroupSetting 'MyApp-Prod'
            $script:State.HostLines | Should -BeNullOrEmpty

            $env:TF_BUILD = 'True'
            $null = Get-AzDoVariableGroupSetting 'MyApp-Prod'
            $script:State.HostLines | Should -Contain '##vso[task.setsecret]line1'
            $script:State.HostLines | Should -Contain '##vso[task.setsecret]line2'
        }

        It 'emits a pipeline warning issue in Azure Pipelines' {
            $env:TF_BUILD = 'True'
            $null = Get-AzDoVariableGroupSetting 'MyApp-Prod' -SkipUnresolvedSecret
            ($script:State.HostLines | Where-Object { $_ -like '##vso`[task.logissue type=warning`]*SETTING__Db__Password*' }) | Should -Not -BeNullOrEmpty
        }

        It 'emits a pipeline error issue before failing in Azure Pipelines' {
            $env:TF_BUILD = 'True'
            { Get-AzDoVariableGroupSetting 'MyApp-Prod' } | Should -Throw
            ($script:State.HostLines | Where-Object { $_ -like '##vso`[task.logissue type=error`]*' }) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Compare-AppServiceSettingFromVariableGroup' {
    BeforeEach {
        Reset-TestEnvironment
        $env:SETTING__Db__Password = 'new-secret'
        Register-AzMock -Variables ([ordered]@{
                'SETTING__Same'         = 'same'
                'SETTING__Changed'      = 'new'
                'SETTING__New'          = 'added'
                'SETTING__Db__Password' = @{ isSecret = $true }
            }) -AppSettings @(
            @{ name = 'Same'; value = 'same' }
            @{ name = 'changed'; value = 'old' }
            @{ name = 'Db__Password'; value = 'old-secret' }
            @{ name = 'Legacy'; value = 'x' }
            @{ name = 'WEBSITE_RUN_FROM_PACKAGE'; value = '1' }
            @{ name = 'APPLICATIONINSIGHTS_CONNECTION_STRING'; value = 'ai' }
        )
    }

    It 'reports Add/Change/Unchanged and keeps other settings in Merge mode' {
        $d = Compare-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target
        ($d | Where-Object Name -EQ 'New').Action | Should -Be 'Add'
        ($d | Where-Object Name -EQ 'Changed').Action | Should -Be 'Change'
        ($d | Where-Object Name -EQ 'Db__Password').Action | Should -Be 'Change'
        ($d | Where-Object Name -EQ 'Same').Action | Should -Be 'Unchanged'
        ($d | Where-Object Name -EQ 'Legacy').Action | Should -Be 'Preserve'
        @($d | Where-Object Action -EQ 'Remove').Count | Should -Be 0
        $d[0].PSObject.TypeNames | Should -Contain 'AzDevOpsVariableGroupAppSettings.SettingChange'
    }

    It 'marks non-preserved extra settings as Remove in Replace mode' {
        $d = Compare-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -Mode Replace
        ($d | Where-Object Name -EQ 'Legacy').Action | Should -Be 'Remove'
        ($d | Where-Object Name -EQ 'WEBSITE_RUN_FROM_PACKAGE').Action | Should -Be 'Preserve'
        ($d | Where-Object Name -EQ 'APPLICATIONINSIGHTS_CONNECTION_STRING').Action | Should -Be 'Preserve'
    }

    It 'honours -PreserveSetting and -NoDefaultPreserve' {
        $d = Compare-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -Mode Replace -PreserveSetting 'Leg*'
        ($d | Where-Object Name -EQ 'Legacy').Action | Should -Be 'Preserve'
        $d = Compare-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -Mode Replace -NoDefaultPreserve
        ($d | Where-Object Name -EQ 'WEBSITE_RUN_FROM_PACKAGE').Action | Should -Be 'Remove'
    }

    It 'masks all values by default' {
        $d = Compare-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target
        $values = @($d | ForEach-Object { $_.CurrentValue; $_.NewValue } | Where-Object { $null -ne $_ } | Select-Object -Unique)
        $values | Should -Be @('********')
    }

    It 'shows only non-secret values with -ShowNonSecretValues' {
        $d = Compare-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -ShowNonSecretValues
        $c = $d | Where-Object Name -EQ 'Changed'
        $c.CurrentValue | Should -Be 'old'
        $c.NewValue | Should -Be 'new'
        ($d | Where-Object Name -EQ 'Db__Password').NewValue | Should -Be '********'
        ($d | Where-Object Name -EQ 'Legacy').CurrentValue | Should -Be '********'
    }

    It 'never modifies the app' {
        $null = Compare-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -Mode Replace
        Get-AzCall 'webapp config appsettings set' | Should -BeNullOrEmpty
        Get-AzCall 'webapp config appsettings delete' | Should -BeNullOrEmpty
    }

    It 'passes slot and subscription to az webapp' {
        $null = Compare-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -Slot staging -Subscription 'Contoso-Prod'
        $call = (Get-AzCall 'webapp config appsettings list')[0]
        Get-ArgValue $call '--resource-group' | Should -Be 'rg-web'
        Get-ArgValue $call '--name' | Should -Be 'contoso-web'
        Get-ArgValue $call '--slot' | Should -Be 'staging'
        Get-ArgValue $call '--subscription' | Should -Be 'Contoso-Prod'
    }

    It 'accepts settings from the pipeline' {
        $settings = Get-AzDoVariableGroupSetting 'MyApp-Prod'
        $script:State.Calls.Clear()
        $d = $settings | Compare-AppServiceSettingFromVariableGroup @script:Target
        ($d | Where-Object Name -EQ 'New').Action | Should -Be 'Add'
        Get-AzCall 'pipelines' | Should -BeNullOrEmpty
    }

    It 'reports a Change when a setting must become sticky' {
        $d = Compare-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -SlotSettingName 'Same'
        $s = $d | Where-Object Name -EQ 'Same'
        $s.Action | Should -Be 'Change'
        $s.SlotSettingChanged | Should -BeTrue
        $s.ValueChanged | Should -BeFalse
    }
}

Describe 'Set-AppServiceSettingFromVariableGroup' {
    BeforeEach {
        Reset-TestEnvironment
        $env:SETTING__Db__Password = 'n3w-s3cret;"quoted" & <special> ^%PATH%'
        Register-AzMock -Variables ([ordered]@{
                'SETTING__Same'                    = 'same'
                'SETTING__Changed'                 = 'new "value" with spaces & symbols | > <'
                'SETTING__Logging__LogLevel__Default' = 'Warning'
                'SETTING__Db__Password'            = @{ isSecret = $true }
            }) -AppSettings @(
            @{ name = 'Same'; value = 'same' }
            @{ name = 'Changed'; value = 'old' }
            @{ name = 'Sticky'; value = 's'; slotSetting = $true }
            @{ name = 'Legacy'; value = 'x' }
            @{ name = 'WEBSITE_RUN_FROM_PACKAGE'; value = '1' }
        )
    }

    It 'applies only added/changed settings through a temp JSON file and deletes it' {
        $r = Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target
        $r.Applied | Should -BeTrue
        $r.Added | Should -Be 2
        $r.Changed | Should -Be 1
        $r.Unchanged | Should -Be 1
        $r.Removed | Should -Be 0
        $r.Preserved | Should -Be 3
        $r.VariableGroupName | Should -Be 'MyApp-Prod'
        $r.PSObject.TypeNames | Should -Contain 'AzDevOpsVariableGroupAppSettings.Result'

        $set = (Get-AzCall 'webapp config appsettings set')
        $set.Count | Should -Be 1
        (Get-ArgValue $set[0] '--settings') | Should -BeLike '@*'
        ($set[0] -join ' ') | Should -Not -Match 'n3w-s3cret'

        $payload = $script:State.SetPayload
        ($payload.name | Sort-Object) | Should -Be @('Changed', 'Db__Password', 'Logging__LogLevel__Default')
        ($payload | Where-Object name -EQ 'Db__Password').value | Should -Be 'n3w-s3cret;"quoted" & <special> ^%PATH%'
        ($payload | Where-Object name -EQ 'Changed').value | Should -Be 'new "value" with spaces & symbols | > <'
        @($payload | Where-Object { $_.PSObject.Properties['slotSetting'] }).Count | Should -Be 0
        Test-Path -LiteralPath $script:State.SetFile | Should -BeFalse
        Get-AzCall 'webapp config appsettings delete' | Should -BeNullOrEmpty
    }

    It 'writes the temp file to AGENT_TEMPDIRECTORY when set' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        try {
            $env:AGENT_TEMPDIRECTORY = $dir
            $null = Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target
            (Split-Path $script:State.SetFile -Parent).TrimEnd('\', '/') | Should -Be $dir.TrimEnd('\', '/')
            @(Get-ChildItem -LiteralPath $dir).Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }

    It 'deletes the temp file even when az fails' {
        Register-AzMock -Variables ([ordered]@{ 'SETTING__A' = '1' }) -FailSet
        { Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target } | Should -Throw
        $script:State.SetFile | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $script:State.SetFile | Should -BeFalse
    }

    It 'makes no changes with -WhatIf but still returns the plan' {
        $r = Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -Mode Replace -WhatIf
        $r.Applied | Should -BeFalse
        $r.Added | Should -Be 2
        $r.Removed | Should -Be 2
        Get-AzCall 'webapp config appsettings set' | Should -BeNullOrEmpty
        Get-AzCall 'webapp config appsettings delete' | Should -BeNullOrEmpty
    }

    It 'deletes settings missing from the group in Replace mode, protecting platform settings' {
        $r = Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -Mode Replace
        $r.Removed | Should -Be 2
        $del = (Get-AzCall 'webapp config appsettings delete')[0]
        $i = [array]::IndexOf($del, '--setting-names')
        ($del[($i + 1)..($del.Count - 1)] | Sort-Object) | Should -Be @('Legacy', 'Sticky')
        $del | Should -Not -Contain 'WEBSITE_RUN_FROM_PACKAGE'
    }

    It 'refuses Replace mode when nothing was selected, unless -AllowEmpty' {
        Register-AzMock -Variables ([ordered]@{ 'OTHER' = '1' }) -AppSettings @(@{ name = 'Legacy'; value = 'x' })
        { Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -Mode Replace -WarningAction SilentlyContinue } | Should -Throw '*refusing to run Replace mode*'
        Get-AzCall 'webapp config appsettings delete' | Should -BeNullOrEmpty
        $r = Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -Mode Replace -AllowEmpty -WarningAction SilentlyContinue
        $r.Removed | Should -Be 1
    }

    It 'does nothing when there are no changes' {
        Register-AzMock -Variables ([ordered]@{ 'SETTING__Same' = 'same' }) -AppSettings @(@{ name = 'Same'; value = 'same' })
        $r = Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target
        $r.Applied | Should -BeFalse
        $r.Unchanged | Should -Be 1
        Get-AzCall 'webapp config appsettings set' | Should -BeNullOrEmpty
    }

    It 'marks all settings sticky with -SlotSetting' {
        $null = Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -Slot staging -SlotSetting
        $payload = $script:State.SetPayload
        @($payload | Where-Object { $_.slotSetting -eq $true }).Count | Should -Be 4   # Same becomes a Change (made sticky)
        Get-ArgValue (Get-AzCall 'webapp config appsettings set')[0] '--slot' | Should -Be 'staging'
    }

    It 'marks matching settings sticky with -SlotSettingName' {
        $null = Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -SlotSettingName 'Db__*'
        $payload = $script:State.SetPayload
        @($payload | Where-Object { $_.PSObject.Properties['slotSetting'] }).name | Should -Be @('Db__Password')
    }

    It 'never writes secret or existing values to the host' {
        $null = Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -Mode Replace -ShowNonSecretValues
        $text = $script:State.HostLines -join "`n"
        $text | Should -Not -Match 'n3w-s3cret'
        $text | Should -Match 'Changed'
        $text | Should -Match 'Add\s+Db__Password\s+= \*{8}'
    }

    It 'uses collapsible groups and sections in Azure Pipelines' {
        $env:TF_BUILD = 'True'
        $null = Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target
        $script:State.HostLines | Where-Object { $_ -like '##`[group`]App settings for contoso-web*' } | Should -Not -BeNullOrEmpty
        $script:State.HostLines | Should -Contain '##[endgroup]'
        $script:State.HostLines | Where-Object { $_ -like '##`[section`]App settings applied*' } | Should -Not -BeNullOrEmpty
        # The only line containing the secret is the masker registration.
        @($script:State.HostLines | Where-Object { $_ -match 'n3w-s3cret' }) | Should -Be @('##vso[task.setsecret]n3w-s3cret;"quoted" & <special> ^%PATH%')
    }

    It 'returns the masked changes with -PassThru' {
        $out = @(Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' @script:Target -PassThru)
        $out.Count | Should -BeGreaterThan 1
        $out[0].PSObject.TypeNames | Should -Contain 'AzDevOpsVariableGroupAppSettings.Result'
        $out[1].PSObject.TypeNames | Should -Contain 'AzDevOpsVariableGroupAppSettings.SettingChange'
    }
}

Describe 'Invoke-AzCli' {
    BeforeAll {
        # A fake az: echoes its arguments as JSON, or fails when asked to.
        function global:Invoke-FakeAz {
            if ($args -contains 'fail') { $ErrorActionPreference = 'Continue'; Write-Error 'ERROR: boom'; $global:LASTEXITCODE = 3; return }
            $global:LASTEXITCODE = 0
            if ($args -contains 'empty') { return }
            if ($args -contains 'list') { '['; '{"name":"a"},'; '{"name":"b"}'; ']'; return }
            if ($args -contains 'emptylist') { '[]'; return }
            ConvertTo-Json -Compress -InputObject @{ args = @($args) }
        }
        Mock -ModuleName $script:ModuleName Get-AzCliCommand { Get-Command Invoke-FakeAz }
    }
    AfterAll { Remove-Item function:global:Invoke-FakeAz -ErrorAction SilentlyContinue }

    It 'appends --output json and --only-show-errors and parses JSON' {
        $r = InModuleScope $script:ModuleName { Invoke-AzCli -Arguments 'group', 'show', '--name', 'x' }
        $r.args | Should -Be @('group', 'show', '--name', 'x', '--output', 'json', '--only-show-errors')
    }

    It 'parses multi-line JSON arrays' {
        $r = @(InModuleScope $script:ModuleName { @(Invoke-AzCli -Arguments 'list') })
        $r.Count | Should -Be 2
        $r[0].name | Should -Be 'a'
        $r[1].name | Should -Be 'b'
        @(InModuleScope $script:ModuleName { @(Invoke-AzCli -Arguments 'emptylist') }).Count | Should -Be 0
    }

    It 'returns $null for empty output and raw text with -Raw' {
        InModuleScope $script:ModuleName { Invoke-AzCli -Arguments 'empty' } | Should -BeNullOrEmpty
        InModuleScope $script:ModuleName { Invoke-AzCli -Arguments 'x' -Raw } | Should -BeOfType [string]
    }

    It 'throws with the exit code and stderr, without option values' {
        { InModuleScope $script:ModuleName { Invoke-AzCli -Arguments 'webapp', 'fail', '--settings', '@secret-file' } } |
            Should -Throw "*'az webapp fail' failed with exit code 3*boom*"
        try { InModuleScope $script:ModuleName { Invoke-AzCli -Arguments 'webapp', 'fail', '--settings', '@secret-file' } } catch { $_.Exception.Message | Should -Not -Match 'secret-file' }
    }

    It 'throws a helpful error when az is not installed' {
        Mock -ModuleName $script:ModuleName Get-AzCliCommand { $null }
        { InModuleScope $script:ModuleName { Invoke-AzCli -Arguments 'version' } } | Should -Throw '*Azure CLI (az) was not found*'
    }
}

Describe 'Private helpers' {
    It 'normalizes variable names like Azure Pipelines does' {
        InModuleScope $script:ModuleName { Get-PipelineEnvironmentVariableName -Name 'SETTING__Db.Pass word' } | Should -Be 'SETTING__DB_PASS_WORD'
    }

    It 'escapes logging command data' {
        InModuleScope $script:ModuleName { ConvertTo-PipelineCommandData -Text "50% done`r`nnext" } | Should -Be '50%AZP25 done%0D%0Anext'
    }
}
