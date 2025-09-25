# scripts/deploy/deploy.ps1
# Main deployment orchestrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [string]$ConfigPath = "$(Split-Path -Parent $PSScriptRoot)\config\resources.json",

    [switch]$Destroy,
    [switch]$PlanOnly,
    [switch]$OnlyTerraform,
    [switch]$ContinueOnError,
    [switch]$ClearCache
)

# Import modules
. (Join-Path $PSScriptRoot "core-utils.ps1")
. (Join-Path $PSScriptRoot "azure-auth.ps1")
. (Join-Path $PSScriptRoot "terraform-ops.ps1")
. (Join-Path $PSScriptRoot "automation-ops.ps1")

# ===== Helpers (local) =====

function Confirm-YesNo {
    param([Parameter(Mandatory)][string]$Prompt)
    while ($true) {
        $ans = Read-Host ("{0} (yes/no)" -f $Prompt)
        switch ($ans.ToLower()) {
            'y'   { return $true }
            'yes' { return $true }
            'n'   { return $false }
            'no'  { return $false }
            default { Write-Host "Please answer 'yes' or 'no'." -ForegroundColor Yellow }
        }
    }
}

function Get-RgInventory {
    param([Parameter(Mandatory)][string]$ResourceGroup)

    $rgExists = (& az group exists --name $ResourceGroup 2>$null) -eq 'true'
    if (-not $rgExists) {
        return [ordered]@{
            Exists    = $false
            GroupInfo = $null
            Resources = @()
            Summary   = @()
        }
    }

    $rgInfo = & az group show --name $ResourceGroup | ConvertFrom-Json
    $res = & az resource list -g $ResourceGroup | ConvertFrom-Json
    if ($null -eq $res) { $res = @() }

    $summary = @()
    $res | Group-Object type | Sort-Object Name | ForEach-Object {
        $summary += [pscustomobject]@{
            Type  = $_.Name
            Count = $_.Count
        }
    }

    return [ordered]@{
        Exists    = $true
        GroupInfo = $rgInfo
        Resources = $res
        Summary   = $summary
    }
}

function Show-RgInventory {
    param([Parameter(Mandatory)]$Inv)

    if (-not $Inv.Exists) {
        Write-Log -Level WARN -Message "Resource Group not found. Nothing to delete."
        return
    }

    $rgName = $Inv.GroupInfo.name
    $rgLoc  = $Inv.GroupInfo.location
    Write-Log -Message ("Resource Group: {0} (location: {1})" -f $rgName, $rgLoc)
    Write-Log -Message ("Resources found: {0}" -f $Inv.Resources.Count)

    if ($Inv.Summary.Count -gt 0) {
        Write-Host "`nSummary by type:" -ForegroundColor Cyan
        $Inv.Summary | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
    }

    if ($Inv.Resources.Count -gt 0) {
        Write-Host "`nDetailed list (name / type / location):" -ForegroundColor Cyan
        $Inv.Resources |
            Select-Object name, type, location |
            Sort-Object type, name |
            Format-Table -AutoSize |
            Out-String | ForEach-Object { Write-Host $_ }
    } else {
        Write-Log -Message "RG is empty." -Level INFO
    }
}

function Clear-TerraformArtifacts {
    param([Parameter(Mandatory)][string]$InfraPath)

    Write-Log -Level STEP -Message "Cleaning Terraform artifacts"
    $paths = @(
        (Join-Path $InfraPath '.terraform'),
        (Join-Path $InfraPath '.terraform.lock.hcl')
    )
    foreach ($p in $paths) {
        if (Test-Path $p) {
            try {
                Remove-Item $p -Recurse -Force -ErrorAction Stop
                Write-Log -Message ("Removed: {0}" -f $p)
            } catch {
                Write-Log -Level WARN -Message ("Failed to remove {0}: {1}" -f $p, $_.Exception.Message)
            }
        }
    }

    Get-ChildItem -Path $InfraPath -Filter '*.tfstate*' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $target = $_
        try {
            Remove-Item $target.FullName -Force -ErrorAction Stop
            Write-Log -Message ("Removed: {0}" -f $target.FullName)
        }
        catch {
            Write-Log -Level WARN -Message ("Failed to remove {0}: {1}" -f $target.FullName, $_.Exception.Message)
        }
    }

    $tfvarsJson = Join-Path $InfraPath 'terraform.auto.tfvars.json'
    if (Test-Path $tfvarsJson) {
        try {
            Remove-Item $tfvarsJson -Force -ErrorAction Stop
            Write-Log -Message ("Removed: {0}" -f $tfvarsJson)
        }
        catch {
            Write-Log -Level WARN -Message ("Failed to remove {0}: {1}" -f $tfvarsJson, $_.Exception.Message)
        }
    }
}

function Invoke-SafeRgDestroy {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][string]$InfraPath
    )

    $rg = $Plan.ResourceGroupName

    # 1) Обзор содержимого RG
    $inv = Invoke-Step -Name ("Discover resources in RG '{0}'" -f $rg) -Action {
        Get-RgInventory -ResourceGroup $rg
    }

    if (-not $inv.Exists) {
        Write-Log -Level WARN -Message ("RG '{0}' does not exist in subscription {1}. Nothing to delete." -f $rg, $SubscriptionId)
        return
    }

    Show-RgInventory -Inv $inv

    # 2) Подтверждение
    $ok = Confirm-YesNo -Prompt ("Are you sure you want to DELETE the entire Resource Group '{0}'?" -f $rg)
    if (-not $ok) {
        Write-Log -Level WARN -Message "User declined RG deletion. Aborting destroy."
        return
    }

    # 3) Очистка артефактов Terraform (до удаления)
    Invoke-Step -Name 'Clean Terraform cache/state/json' -Action {
        Clear-TerraformArtifacts -InfraPath $InfraPath
    }

    # 4) Удаление RG (ждём завершения)
    Invoke-Step -Name ("Delete Resource Group '{0}'" -f $rg) -Action {
        & az group delete --name $rg --yes
        if ($LASTEXITCODE -ne 0) { throw "az group delete failed" }
    }

    # 5) Проверка
    Invoke-Step -Name 'Verify deletion' -Action {
        $exists = (& az group exists --name $rg 2>$null) -eq 'true'
        if ($exists) { throw ("RG '{0}' still exists after deletion attempt." -f $rg) }
        Write-Log -Message ("RG '{0}' successfully deleted." -f $rg)
    }

    Write-Log -Message "Destroy completed."
}

function Test-TerraformArchitecture {
    $ver = terraform version 2>$null
    if (-not $ver) { throw 'Terraform not found.' }
    if ($ver -match 'windows_386') {
        throw '32-bit Terraform detected. Install 64-bit Terraform and ensure it is first in PATH.'
    }
}

# ===== Pre-flight checks =====
Invoke-Step -Name 'Pre-flight: tools' -Action {
    if (-not (Test-CommandPresent az)) { throw 'Azure CLI is required.' }
    if (-not $Destroy) {
        if (-not (Test-CommandPresent terraform)) { throw 'Terraform is required.' }
        Test-TerraformArchitecture
        Write-Log -Level DEBUG -Message ("Terraform: " + (terraform version | Out-String).Trim())
        Write-Log -Level DEBUG -Message ("Azure CLI: " + ((az version | Out-String).Trim()))
    }
}

# Paths
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$infraPath = Join-Path $repoRoot 'infra'
Write-Log -Message ("Repo root: {0}" -f $repoRoot)
Write-Log -Message ("Terraform folder: {0}" -f $infraPath)

# Auth
$auth = Invoke-Step -Name 'Authenticate to Azure' -Action {
    Connect-Azure -SubscriptionId $SubscriptionId
}
Write-Log -Message ("Auth: {0}; Tenant: {1}; Subscription: {2}" -f $auth.AuthType, $auth.TenantId, $auth.SubscriptionName)

# Deployment plan (нужен хотя бы RG из конфига для destroy)
$plan = Invoke-Step -Name 'Resolve deployment plan' -Action {
    Resolve-DeploymentPlan -SubscriptionId $SubscriptionId -ConfigPath $ConfigPath
}

# ===== Если destroy — удаляем RG и выходим, без Terraform =====
if ($Destroy) {
    Invoke-SafeRgDestroy -SubscriptionId $SubscriptionId -ConfigPath $ConfigPath -Plan $plan -InfraPath $infraPath
    return
}

# ===== Ниже — обычный путь Terraform (Destroy уже обработан) =====
$tfvarsJson = Join-Path $infraPath 'terraform.auto.tfvars.json'

# Write Terraform variables
Invoke-Step -Name 'Write terraform variables' -Action {
    Write-TfVarsJson -Plan $plan -PathJson $tfvarsJson -SubscriptionId $SubscriptionId
}

# Terraform operations (всегда выполняем для non-destroy пути)
$tfOutput = $null
Push-Location $infraPath
try {
    # Очистка по запросу
    if ($ClearCache) {
        Invoke-Step -Name 'Clear Terraform cache' -Action {
            $cacheDir = Join-Path $infraPath '.terraform'
            $lockFile = Join-Path $infraPath '.terraform.lock.hcl'
            if (Test-Path $cacheDir) { Remove-Item $cacheDir -Recurse -Force }
            if (Test-Path $lockFile) { Remove-Item $lockFile -Force }
            Write-Log "Terraform cache cleared"
        }
    }

    # Terraform init
    Invoke-Step -Name 'Terraform init' -Action {
        & terraform init -upgrade
        if ($LASTEXITCODE -ne 0) { throw "terraform init failed" }
    }

    if ($PlanOnly) {
        Invoke-Step -Name 'Terraform plan' -Action {
            & terraform plan -input=false
            if ($LASTEXITCODE -ne 0) { throw "terraform plan failed" }
        }
        Write-Log "Terraform plan completed (PlanOnly)."
        Pop-Location
        return
    }

    # Terraform validate, plan, apply
    Invoke-Step -Name 'Terraform validate' -Action {
        & terraform validate
        if ($LASTEXITCODE -ne 0) { throw "terraform validate failed" }
    }

    $planOutput = Invoke-Step -Name 'Terraform plan' -Action {
        & terraform plan -input=false 2>&1 | Out-String
    }

    if ($planOutput -match "No changes\.") {
        Write-Log "No infrastructure changes needed"
    } else {
        Invoke-Step -Name 'Terraform apply' -Action {
            & terraform apply -input=false -auto-approve
            if ($LASTEXITCODE -ne 0) { throw "terraform apply failed" }
        }
    }

    $tfOutput = Invoke-Step -Name 'Terraform output' -Action {
        terraform output -json | ConvertFrom-Json
    }
}
finally {
    Pop-Location
}

# Если просили только Terraform — выходим здесь, не делаем пост-этапы
if ($OnlyTerraform) {
    Write-Log "Terraform operations completed (OnlyTerraform)."
    return
}

# ===== Post-Terraform setup (Automation variables) =====
if ($tfOutput) {
    $aaName = $tfOutput.automation_account_name.value
    $aaRg   = $tfOutput.automation_account_resource_group.value

    # Set automation variables
    Invoke-Step -Name 'Seed Automation variables' -Action {
        Set-AutomationVariable -AutomationAccountName $aaName -ResourceGroup $aaRg -Name 'AZURE_SUBSCRIPTION_ID' -Value $SubscriptionId
        Set-AutomationVariable -AutomationAccountName $aaName -ResourceGroup $aaRg -Name 'AZURE_TENANT_ID' -Value $auth.TenantId

        if ($tfOutput.log_analytics_workspace_id.value) {
            Set-AutomationVariable -AutomationAccountName $aaName -ResourceGroup $aaRg -Name 'LOG_ANALYTICS_WORKSPACE_RESOURCE_ID' -Value $tfOutput.log_analytics_workspace_id.value
        }

        if ($tfOutput.user_assigned_identity_id.value) {
            Set-AutomationVariable -AutomationAccountName $aaName -ResourceGroup $aaRg -Name 'USER_ASSIGNED_MI_RESOURCE_ID' -Value $tfOutput.user_assigned_identity_id.value
        }

        Set-AutomationVariable -AutomationAccountName $aaName -ResourceGroup $aaRg -Name 'ARTIFACT_STORAGE_ACCOUNT_NAME' -Value $tfOutput.storage_account_name.value
        Set-AutomationVariable -AutomationAccountName $aaName -ResourceGroup $aaRg -Name 'ARTIFACT_STORAGE_ACCOUNT_RG' -Value $tfOutput.storage_account_resource_group.value
        Set-AutomationVariable -AutomationAccountName $aaName -ResourceGroup $aaRg -Name 'STORAGE_CONTAINER_NAME' -Value $plan.StorageContainerName
        Set-AutomationVariable -AutomationAccountName $aaName -ResourceGroup $aaRg -Name 'STORAGE_FOLDER_PREFIX' -Value $plan.StorageFolderPrefix
    }

    # Summary
    $tfOutputHash = $tfOutput | ConvertTo-Json -Compress | ConvertFrom-Json -AsHashtable
    Invoke-Step -Name 'Deployment summary' -Action {
        Write-DeploymentSummary -Out $tfOutputHash
    }
}

Write-Log "Deployment completed successfully"
