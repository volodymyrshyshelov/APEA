# Publish / update ALL runbooks from local folder to Azure Automation (NO schedules)
# Two modes:
#   Explicit:  -AutomationAccountName -ResourceGroupName [-RunbooksPath]
#   ByContext: -SubscriptionId -ConfigPath             [-RunbooksPath]
[CmdletBinding(DefaultParameterSetName='ByContext')]
param(
    # --- Explicit ---
    [Parameter(ParameterSetName='Explicit', Mandatory)]
    [string]$AutomationAccountName,
    [Parameter(ParameterSetName='Explicit', Mandatory)]
    [string]$ResourceGroupName,

    # --- ByContext ---
    [Parameter(ParameterSetName='ByContext', Mandatory)]
    [string]$SubscriptionId,
    [Parameter(ParameterSetName='ByContext', Mandatory)]
    [string]$ConfigPath,

    # Common
    [string]$RunbooksPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'runbooks')
)
$ErrorActionPreference = 'Stop'

# Logging helpers
. (Join-Path (Split-Path -Parent $PSScriptRoot) "deploy\core-utils.ps1")

function Invoke-AzCliStrict {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AsJson,
        [switch]$AllowFailure
    )
    $out = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "Azure CLI failed (az $($Arguments -join ' ')): $out"
    }
    if ($AsJson -and $out) { try { return $out | ConvertFrom-Json } catch { return $null } }
    return $out
}

# Resolve context from config
if ($PSCmdlet.ParameterSetName -eq 'ByContext') {
    if (-not (Test-Path $ConfigPath)) { throw "Config '$ConfigPath' not found." }
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if (-not $cfg.automation_account_name) { throw "Config missing 'automation_account_name'." }
    if (-not $cfg.resource_group_name)     { throw "Config missing 'resource_group_name'." }
    $AutomationAccountName = "$($cfg.automation_account_name)"
    $ResourceGroupName     = "$($cfg.resource_group_name)"
    Write-Log "Context resolved: AA='$AutomationAccountName', RG='$ResourceGroupName'"

    if ($SubscriptionId) {
        Write-Log "Setting Azure subscription context to $SubscriptionId"
        az account set --subscription $SubscriptionId | Out-Null
    }
}

Write-Log "Starting runbook publication to '$AutomationAccountName' (RG '$ResourceGroupName')."

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI is required.' }
if (-not (Test-Path $RunbooksPath)) { throw "Runbooks folder not found: $RunbooksPath" }

# Collect *.ps1 runbooks (exclude helper/underscore files)
$files = Get-ChildItem -Path $RunbooksPath -Filter '*.ps1' -File |
         Where-Object { $_.Name -notmatch '^_' }
if (-not $files -or $files.Count -eq 0) {
    Write-Log -Level WARN -Message "No *.ps1 runbooks found in '$RunbooksPath'."
    return
}

foreach ($f in $files) {
    $rb = $f.BaseName
    Write-Log "Publishing runbook '$rb'"

    $existing = Invoke-AzCliStrict -Arguments @(
        'automation','runbook','show',
        '--automation-account-name',$AutomationAccountName,
        '--resource-group',$ResourceGroupName,
        '--name',$rb
    ) -AsJson -AllowFailure

    if (-not $existing) {
        Write-Log "Creating runbook '$rb'"
        Invoke-AzCliStrict -Arguments @(
            'automation','runbook','create',
            '--automation-account-name',$AutomationAccountName,
            '--resource-group',$ResourceGroupName,
            '--name',$rb,
            '--type','PowerShell',
            '--log-verbose','true',
            '--log-progress','true'
        ) | Out-Null
    } else {
        Write-Log "Updating runbook '$rb' settings"
        Invoke-AzCliStrict -Arguments @(
            'automation','runbook','update',
            '--automation-account-name',$AutomationAccountName,
            '--resource-group',$ResourceGroupName,
            '--name',$rb,
            '--type','PowerShell',
            '--log-verbose','true',
            '--log-progress','true'
        ) | Out-Null
    }

    # Replace content
    $contentPath = $f.FullName
    if ($contentPath -match '\s') { $contentPath = "`"$contentPath`"" }
    Write-Log "Replacing content from $contentPath"
    Invoke-AzCliStrict -Arguments @(
        'automation','runbook','replace-content',
        '--automation-account-name',$AutomationAccountName,
        '--resource-group',$ResourceGroupName,
        '--name',$rb,
        '--content',"@${contentPath}"
    ) | Out-Null

    # Publish
    Write-Log "Publishing '$rb'"
    Invoke-AzCliStrict -Arguments @(
        'automation','runbook','publish',
        '--automation-account-name',$AutomationAccountName,
        '--resource-group',$ResourceGroupName,
        '--name',$rb
    ) | Out-Null

    Write-Log "Successfully published '$rb'"
}

Write-Log "Runbook publication complete."
