# Update specific runbook(s) content from local files. Optional publish.
# Two modes:
#   Explicit:  -AutomationAccountName -ResourceGroupName [-RunbooksPath] [-RunbookName ...]
#   ByContext: -SubscriptionId -ConfigPath             [-RunbooksPath] [-RunbookName ...]
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
    [string[]]$RunbookName,   # если не задано — возьмём все из папки
    [switch]$Publish,         # если указан — после обновления делаем publish
    [switch]$DryRun,          # показать, что будет сделано
    [string]$RunbooksPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'runbooks')
)
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) "deploy\core-utils.ps1")

function Invoke-AzCliStrict {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed (az $($Arguments -join ' ')): $out" }
    return $out
}

# Resolve context
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

if (-not (Test-Path $RunbooksPath)) { throw "Runbooks folder not found: $RunbooksPath" }

# Determine target runbooks
$localRunbooks = Get-ChildItem -Path $RunbooksPath -Filter '*.ps1' -File |
                 Where-Object { $_.Name -notmatch '^_' }

if ($RunbookName -and $RunbookName.Count -gt 0) {
    $selected = foreach ($n in $RunbookName) {
        $m = $localRunbooks | Where-Object { $_.BaseName -ieq $n }
        if (-not $m) {
            Write-Log -Level WARN "Local runbook '$n' not found in $RunbooksPath"
        }
        $m
    }
    $files = $selected | Where-Object { $_ }
} else {
    $files = $localRunbooks
}

if (-not $files -or $files.Count -eq 0) {
    Write-Log -Level WARN "No runbooks selected for update."
    return
}

foreach ($f in $files) {
    $rb = $f.BaseName
    $contentPath = $f.FullName
    if ($contentPath -match '\s') { $contentPath = "`"$contentPath`"" }

    Write-Log "Updating runbook '$rb' (content=$($f.Name))"

    if ($DryRun) {
        Write-Log -Level DEBUG "DRY-RUN: az automation runbook replace-content --name $rb --content @$contentPath"
        if ($Publish) { Write-Log -Level DEBUG "DRY-RUN: az automation runbook publish --name $rb" }
        continue
    }

    # Ensure runbook exists (create if missing)
    $exists = (& az automation runbook show `
        --automation-account-name $AutomationAccountName `
        --resource-group $ResourceGroupName `
        --name $rb 2>&1)
    if ($LASTEXITCODE -ne 0) {
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
    }

    # Replace content
    Invoke-AzCliStrict -Arguments @(
        'automation','runbook','replace-content',
        '--automation-account-name',$AutomationAccountName,
        '--resource-group',$ResourceGroupName,
        '--name',$rb,
        '--content',"@${contentPath}"
    ) | Out-Null

    if ($Publish) {
        Invoke-AzCliStrict -Arguments @(
            'automation','runbook','publish',
            '--automation-account-name',$AutomationAccountName,
            '--resource-group',$ResourceGroupName,
            '--name',$rb
        ) | Out-Null
        Write-Log "Updated and published '$rb'"
    } else {
        Write-Log "Updated '$rb' (not published — use -Publish to publish)"
    }
}

Write-Log "Update-runbooks finished."
