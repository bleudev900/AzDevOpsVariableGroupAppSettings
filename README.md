# AzDevOpsVariableGroupAppSettings

[![CI](https://github.com/bleudev900/AzDevOpsVariableGroupAppSettings/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/bleudev900/AzDevOpsVariableGroupAppSettings/actions/workflows/ci.yml)

PowerShell module that turns **Azure DevOps variable group** variables into **Azure App Service app settings**
(environment variables), for use **inside an Azure Pipelines deployment**. It uses the Azure CLI
(`az` with the `azure-devops` extension) for everything, so it runs in an `AzureCLI@2` task with no Az PowerShell
modules.

Every variable whose name starts with a prefix (default `SETTING__`) becomes an app setting with the prefix removed:

| Variable group variable | App setting | .NET configuration key |
|---|---|---|
| `SETTING__SomeSettingName__WithUnderscores` | `SomeSettingName__WithUnderscores` | `SomeSettingName:WithUnderscores` |
| `SETTING__Logging__LogLevel__Default` | `Logging__LogLevel__Default` | `Logging:LogLevel:Default` |
| `SETTING__ConnectionStrings__Default` (secret) | `ConnectionStrings__Default` | `ConnectionStrings:Default` |
| `BuildConfiguration` | *(ignored, no prefix)* | |

Remaining double underscores are kept, so .NET maps them to configuration sections.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+ (`pscore` or `ps` in `AzureCLI@2`)
- Azure CLI with the `azure-devops` extension (both preinstalled on Microsoft-hosted agents;
  otherwise `az extension add --name azure-devops`)
- An `az` login that can write app settings on the target app (in a pipeline: the `AzureCLI@2` service connection,
  e.g. *Website Contributor* on the app)
- Read access to the variable group for the identity used by `az pipelines` (see [Permissions](#permissions))

## Install

Clone or download the repo and import the manifest (or copy the folder to a path in `$env:PSModulePath`):

```powershell
git clone --depth 1 https://github.com/bleudev900/AzDevOpsVariableGroupAppSettings.git
Import-Module ./AzDevOpsVariableGroupAppSettings/AzDevOpsVariableGroupAppSettings.psd1
```

## Commands

| Command | Purpose |
|---|---|
| `Get-AzDoVariableGroupSetting` | Read a variable group, select prefixed variables, strip the prefix and resolve secrets. Returns setting objects (secret values only as `SecureString`). |
| `Compare-AppServiceSettingFromVariableGroup` | Read-only diff between the group and the app: `Add` / `Change` / `Remove` / `Unchanged` / `Preserve`, values masked. |
| `Set-AppServiceSettingFromVariableGroup` | Show the diff and apply it to the app (`-WhatIf`, `-Mode Merge/Replace`, slot settings). Returns a result summary. |

Full help: `Get-Help Set-AppServiceSettingFromVariableGroup -Full`.

Common parameters:

| Parameter | Default | Notes |
|---|---|---|
| `-VariableGroupName` / `-VariableGroupId` | | Exact name (case-insensitive) or ID. |
| `-Organization` | `SYSTEM_COLLECTIONURI`, then `SYSTEM_TEAMFOUNDATIONCOLLECTIONURI` | URL or just the org name. |
| `-Project` | `SYSTEM_TEAMPROJECT` | Project that owns the variable group. |
| `-Prefix` | `SETTING__` | Use e.g. `SETTINGS__` if that's your convention. `''` selects every variable. |
| `-KeepPrefix` | off | Keep the prefix in the app setting name. |
| `-CaseSensitive` | off | Prefix matching is case-insensitive by default. |
| `-SecretValues` | | Hashtable of secret values keyed by variable or app setting name (string or `SecureString`). |
| `-SkipUnresolvedSecret` | off | Skip secrets that can't be resolved instead of failing. |
| `-ResourceGroupName`, `-AppName`, `-Slot`, `-Subscription` | | Target App Service. `-Subscription` defaults to the current `az` subscription. |
| `-Mode` | `Merge` | `Replace` also deletes settings that aren't in the group (see below). |
| `-PreserveSetting` / `-NoDefaultPreserve` | | Extra patterns Replace must never delete / drop the default protected list. |
| `-SlotSetting` / `-SlotSettingName` | | Mark all / matching (wildcards) settings as deployment slot settings (sticky). |
| `-ShowNonSecretValues` | off | Show non-secret values in the diff. Secrets are always masked. |

## Azure Pipelines usage

A complete example is in [`examples/azure-pipelines.yml`](examples/azure-pipelines.yml):

```yaml
variables:
  - group: MyApp-Prod            # needed so $(secret) macros resolve for the env mapping below

steps:
  - pwsh: git clone --depth 1 https://github.com/bleudev900/AzDevOpsVariableGroupAppSettings.git "$(Agent.TempDirectory)/AzDevOpsVariableGroupAppSettings"
    displayName: Get AzDevOpsVariableGroupAppSettings

  - task: AzureCLI@2
    displayName: Apply app settings from variable group
    inputs:
      azureSubscription: my-arm-service-connection
      scriptType: pscore
      scriptLocation: inlineScript
      inlineScript: |
        Import-Module "$(Agent.TempDirectory)/AzDevOpsVariableGroupAppSettings/AzDevOpsVariableGroupAppSettings.psd1"
        Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' `
            -ResourceGroupName 'rg-web-prod' -AppName 'contoso-web-prod'
    env:
      SYSTEM_ACCESSTOKEN: $(System.AccessToken)                                  # auth for az pipelines
      SETTING__ConnectionStrings__Default: $(SETTING__ConnectionStrings__Default)  # one line per secret
```

Dry run (diff only): add `-WhatIf`. Staging slot with sticky settings, removing settings that aren't in the group:

```powershell
Set-AppServiceSettingFromVariableGroup -VariableGroupName 'MyApp-Prod' -ResourceGroupName 'rg-web-prod' `
    -AppName 'contoso-web-prod' -Slot staging -SlotSetting -Mode Replace
```

Two-step use (inspect, then apply the same objects):

```powershell
$settings = Get-AzDoVariableGroupSetting -VariableGroupName 'MyApp-Prod' -Prefix 'SETTINGS__'
$settings | Format-Table Name, VariableName, IsSecret, ValueSource
$settings | Set-AppServiceSettingFromVariableGroup -ResourceGroupName 'rg-web-prod' -AppName 'contoso-web-prod'
```

### Authentication for `az pipelines`

The `azure-devops` extension authenticates with, in order:

1. `AZURE_DEVOPS_EXT_PAT` if it is set (a PAT with *Variable Groups (Read)* scope);
2. otherwise `SYSTEM_ACCESSTOKEN`, which the module copies into `AZURE_DEVOPS_EXT_PAT` for the duration of its
   `az pipelines` calls and then restores. **`$(System.AccessToken)` is not in the environment by default** — map it
   in the step's `env:` block as shown above;
3. otherwise the identity `az` is logged in with (the `AzureCLI@2` service principal works only if it has been
   added to the Azure DevOps organization).

### Permissions

- **Variable group read**: with `SYSTEM_ACCESSTOKEN` the identity is the build service account,
  `<Project> Build Service (<Organization>)` (or `Project Collection Build Service (<Organization>)` when the job
  authorization scope is the collection). In **Pipelines → Library → *your group* → Security**, give it the
  **Reader** role (or grant it at the Library level for all groups). If the group lives in another project, the
  pipeline's *Limit job authorization scope to current project* setting must be off.
- **Pipeline permission**: the `variables: - group:` link requires the pipeline to be authorized to use the group
  (Library → group → *Pipeline permissions*); the first run will ask for approval otherwise.
- **App Service**: the `AzureCLI@2` service connection needs permission to read and write app settings on the app
  (e.g. *Website Contributor*, or *Contributor* on the resource group).

## Secret variables

The variable group API never returns secret values (and Key Vault-linked groups return no values at all). Every
selected variable without a value is resolved, in this order, from:

1. `-SecretValues @{ 'SETTING__Db__Password' = $value }` (key = variable name or app setting name);
2. an environment variable with the **same name as the variable**, or its pipeline-normalized form
   (upper-case, `.` and space → `_`, e.g. `SETTING__Api.Key` → `SETTING__API_KEY`).

Azure Pipelines never maps secrets into the environment automatically, so add one `env:` line per secret
(`NAME: $(NAME)`), and link the variable group to the job so the macro resolves. If the macro doesn't resolve
(the environment variable contains the literal `$(NAME)`), the value is treated as missing.

If any secret can't be resolved the command **fails** and names the variables (never values). Use
`-SkipUnresolvedSecret` to skip them with a warning instead.

## How applying works

1. The group is read with `az pipelines variable-group list --group-name` (exact-name match) or
   `variable-group show --group-id`, then `az pipelines variable-group variable list`.
2. The app's current settings are read with `az webapp config appsettings list`.
3. A diff is computed (names compare case-insensitively, values exactly) and logged with values masked.
4. Unless `-WhatIf`: all `Add`/`Change` settings are written in **one** `az webapp config appsettings set` call.
   The settings are written to a temporary JSON file (in `AGENT_TEMPDIRECTORY` when available, `chmod 600` on
   Linux/macOS) and passed as `--settings @file`, so no value ever appears on a command line and there are no
   quoting/escaping problems with `cmd`/`az.cmd` on Windows or bash on Linux. The file is deleted afterwards, even
   on failure.
5. In `Replace` mode, settings that exist on the app but not in the group are deleted with
   `az webapp config appsettings delete`, except those matching the protected patterns:
   `WEBSITE_*`, `WEBSITES_*`, `SCM_*`, `APPINSIGHTS_*`, `APPLICATIONINSIGHTS_*`, `ApplicationInsightsAgent_*`,
   `XDT_*`, `DiagnosticServices_*`, `InstrumentationEngine_*`, `SnapshotDebugger_*`, `DOCKER_*`, `FUNCTIONS_*`,
   `AzureWebJobs*`, `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET`, `ENABLE_ORYX_BUILD`, `ASPNETCORE_ENVIRONMENT`,
   `DOTNET_ENVIRONMENT`. Add more with `-PreserveSetting`, or drop the defaults with `-NoDefaultPreserve`.
   Replace mode refuses to run if nothing was selected from the group (wrong prefix?) unless `-AllowEmpty`.
6. **Slot settings**: with `-SlotSetting` / `-SlotSettingName` the matching settings are marked sticky. Existing
   sticky flags are never removed.

Changing app settings **restarts the app** (normal App Service behaviour). Unchanged settings are not re-sent.

### Output and logging

When `TF_BUILD` is set (Azure Pipelines), the diff is written in a collapsible `##[group]`, warnings and errors are
raised as `##vso[task.logissue]` so they appear on the run summary, and every resolved secret value is registered
with the agent's log masker (`##vso[task.setsecret]`) before anything else is logged. Outside a pipeline the
output is plain text and `Write-Warning`.

```text
##[group]App settings for contoso-web-prod (resource group rg-web-prod) [Merge]
Add       Api__Url                    = ********  <- SETTING__Api__Url
Change    ConnectionStrings__Default  ******** -> ********  [secret, value] <- SETTING__ConnectionStrings__Default
Unchanged Logging__LogLevel__Default  <- SETTING__Logging__LogLevel__Default
Preserve  WEBSITE_RUN_FROM_PACKAGE
Add: 1, Change: 1, Remove: 0, Unchanged: 1, Preserve: 1
##[endgroup]
```

`Set-AppServiceSettingFromVariableGroup` returns a result object: `VariableGroupName`, `VariableGroupId`,
`ResourceGroupName`, `AppName`, `Slot`, `Subscription`, `Mode`, `Applied`, `Added`, `Changed`, `Removed`,
`Unchanged`, `Preserved` and `Changes` (masked). `-PassThru` also outputs every masked diff row.

## Security

- Secret values are only held in memory, returned as `SecureString`, masked in all diff output and registered
  with the pipeline log masker. The temporary settings file is private to the user and deleted after use.
- Errors from `az` include the command words and az's stderr, never option values.
- Non-secret variable values are read verbatim from the API: macros such as `$(OtherVariable)` inside a value are
  **not** expanded.

## Tests and lint

```powershell
./build.ps1 -Task Bootstrap                 # installs pinned Pester 5.7.1 and PSScriptAnalyzer 1.25.0 (CurrentUser)
./build.ps1 -Task Lint, Manifest, Test      # PSScriptAnalyzer, Test-ModuleManifest, Pester
```

Every `az` call goes through the private `Invoke-AzCli` helper (checks `$LASTEXITCODE`, parses JSON), which the
Pester suite mocks, so no Azure or Azure DevOps access is needed.

### CI

`.github/workflows/ci.yml` runs on pushes to `main`, on pull requests and on demand:

| Job | Runner | Shell |
|---|---|---|
| Lint (PSScriptAnalyzer + Test-ModuleManifest) | ubuntu-latest | pwsh |
| Test | ubuntu-latest | pwsh |
| Test | windows-latest | pwsh |
| Test | windows-latest | Windows PowerShell 5.1 |

## License

Released under the [MIT License](LICENSE). You are free to use, modify, and distribute this module, including for commercial purposes.
