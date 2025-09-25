# Terraform operations and deployment planning
# All defaults (tags, storage rules, etc.) are taken from config/resources.json

function Test-RgExists {
    param($Name)
    return (& az group exists --name $Name) -eq 'true'
}

function Get-ByIdOrNull {
    param([Parameter(Mandatory)][string[]]$Args)
    try {
        return & az $Args 2>$null | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Test-AaExists {
    param($Rg,$Name)
    $obj = Get-ByIdOrNull -Args @(
        'resource','show',
        '--resource-group',$Rg,
        '--name',$Name,
        '--resource-type','Microsoft.Automation/automationAccounts'
    )
    return $null -ne $obj
}

function Test-SaExists {
    param($Rg,$Name)
    return $null -ne (Get-ByIdOrNull -Args @('storage','account','show','-g',$Rg,'-n',$Name))
}

function Test-LaExists {
    param($Rg,$Name)
    return $null -ne (Get-ByIdOrNull -Args @('monitor','log-analytics','workspace','show','-g',$Rg,'-n',$Name))
}

function Resolve-DeploymentPlan {
    param(
        [string]$SubscriptionId,
        [string]$ConfigPath
    )

    # 0) Load configuration
    $Config = $null
    if (Test-Path $ConfigPath) {
        try {
            $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            Write-Log "Loaded config: $ConfigPath"
        }
        catch {
            Write-Log -Level WARN "Config $ConfigPath cannot be parsed. $_"
        }
    }

    if ($null -eq $Config) {
        throw "Configuration not loaded from $ConfigPath"
    }

    # 1) Location / Resource Group — CONFIG-FIRST
    $location = $Config.location
    if (-not (Test-StringNotEmpty $location)) { $location = 'northeurope' }

    $rg = $Config.resource_group_name
    if (-not (Test-StringNotEmpty $rg)) { $rg = "rg-apea-$location-001" }

    # 2) Existence checks
    $rgExists = Test-RgExists $rg

    # 3) Names
    $aaNameCfg = if (Test-StringNotEmpty $Config.automation_account_name) { $Config.automation_account_name } else { "aa-apea-$location-001" }

    $saNameCfg = $Config.storage_account_name
    if (-not (Test-StringNotEmpty $saNameCfg)) { throw "storage_account_name is missing in config/resources.json" }
    $saNameCfg = $saNameCfg.Trim().ToLower()
    if ($saNameCfg -notmatch '^[a-z0-9]{3,24}$') {
        throw "Invalid storage_account_name '$saNameCfg'. Azure requires: 3–24 chars, only lowercase letters and digits."
    }

    $laNameCfg = if (Test-StringNotEmpty $Config.log_analytics_workspace_name) { $Config.log_analytics_workspace_name } else { "la-apea-$location-001" }

    $hwgName  = if (Test-StringNotEmpty $Config.hybrid_worker_group_name) { $Config.hybrid_worker_group_name } else { "apea-hybrid-worker-group" }

    # 4) Optional explicit resource IDs from config
    $uamiIdCfg = if (Test-StringNotEmpty $Config.user_assigned_identity_resource_id) { $Config.user_assigned_identity_resource_id } else { $null }
    $lawIdCfg  = if (Test-StringNotEmpty $Config.log_analytics_workspace_resource_id) { $Config.log_analytics_workspace_resource_id } else { $null }

    # 5) Existing resources?
    $aaExists = $rgExists -and (Test-AaExists $rg $aaNameCfg)
    $saExists = $rgExists -and (Test-SaExists $rg $saNameCfg)
    $laExists = $false
    $laResourceId = $null

    if ($lawIdCfg) {
        $laExists = $true
        $laResourceId = $lawIdCfg
    } else {
        $laExists = $rgExists -and (Test-LaExists $rg $laNameCfg)
        if ($laExists) {
            $laResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$rg/providers/Microsoft.OperationalInsights/workspaces/$laNameCfg"
        }
    }

    # 6) Defaults moved from code -> config
    $tags = @{}
    if ($Config.tags -and $Config.tags.PSObject.Properties.Count -gt 0) {
        $tags = @{}
        foreach ($p in $Config.tags.PSObject.Properties) { $tags[$p.Name] = [string]$p.Value }
    }

    $useAvmStorageModule = [bool]$Config.use_avm_storage_module
    $storageSharedKey    = [bool]$Config.storage_shared_access_key_enabled

    $storageNetworkRules = @{
        default_action = 'Deny'
        bypass         = @()
    }
    if ($Config.storage_network_rules) {
        if ($Config.storage_network_rules.default_action) { $storageNetworkRules.default_action = $Config.storage_network_rules.default_action }
        if ($Config.storage_network_rules.bypass) { $storageNetworkRules.bypass = @($Config.storage_network_rules.bypass) }
    }

    $containerName = if (Test-StringNotEmpty $Config.storage_container_name) { $Config.storage_container_name } else { 'reports' }
    $folderPrefix  = if (Test-StringNotEmpty $Config.storage_folder_prefix) { $Config.storage_folder_prefix } else { 'policy-compliance' }

    # 7) Final plan object
    $plan = [ordered]@{
        Location                        = $location
        ResourceGroupName               = $rg
        CreateResourceGroup             = -not $rgExists

        AutomationAccountName           = $aaNameCfg
        UseExistingAutomationAccount    = [bool]$aaExists
        ExistingAutomationAccountName   = ($aaExists ? $aaNameCfg : $null)
        ExistingAutomationAccountRg     = ($aaExists ? $rg       : $null)

        UseExistingStorageAccount       = [bool]$saExists
        StorageAccountName              = $saNameCfg
        ExistingStorageAccountName      = ($saExists ? $saNameCfg : $null)
        ExistingStorageAccountRg        = ($saExists ? $rg        : $null)

        LogAnalyticsWorkspaceName       = $laNameCfg
        LogAnalyticsWorkspaceResourceId = $laResourceId
        UseExistingLogAnalytics         = [bool]$laExists

        UserAssignedIdentityResourceId  = $uamiIdCfg

        HybridWorkerGroupName           = $hwgName

        StorageContainerName            = $containerName
        StorageFolderPrefix             = $folderPrefix

        Tags                            = $tags
        UseAvmStorageModule             = $useAvmStorageModule
        StorageSharedAccessKeyEnabled   = $storageSharedKey
        StorageNetworkRules             = $storageNetworkRules
    }


    # 8) Human-friendly log
    Write-Log -Message "Deployment plan (config-first):"
    Write-Log -Message ("  RG:   {0} (exists: {1}, create: {2})" -f $rg, $rgExists, $plan.CreateResourceGroup)
    Write-Log -Message ("  AA:   {0} (useExisting: {1})" -f $plan.AutomationAccountName, $plan.UseExistingAutomationAccount)
    Write-Log -Message ("  SA:   {0} (useExisting: {1})" -f $plan.StorageAccountName, $plan.UseExistingStorageAccount)
    Write-Log -Message ("  LAW:  {0} (useExisting: {1})" -f $plan.LogAnalyticsWorkspaceName, $plan.UseExistingLogAnalytics)
    Write-Log -Message ("  HWG:  {0}" -f $plan.HybridWorkerGroupName)
    Write-Log -Message ("  Container: {0}, Prefix: {1}" -f $plan.StorageContainerName, $plan.StorageFolderPrefix)

    if ($plan.Tags.Keys.Count -gt 0) {
        $tagPairs = foreach ($k in $plan.Tags.Keys) { "{0}={1}" -f $k, $plan.Tags[$k] }
        Write-Log -Message ("  Tags: {0}" -f ($tagPairs -join ', '))
    }

    $bypassJoined = @($plan.StorageNetworkRules.bypass) -join '|'
    Write-Log -Message ("  SA rules: default_action={0}; bypass={1}" -f $plan.StorageNetworkRules.default_action, $bypassJoined)
    Write-Log -Message ("  use_avm_storage_module={0}; shared_key_enabled={1}" -f $plan.UseAvmStorageModule, $plan.StorageSharedAccessKeyEnabled)


    return $plan
}

function Write-TfVarsJson {
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][string]$PathJson,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    $payload = [ordered]@{
        "subscription_id"                      = $SubscriptionId
        "location"                             = $Plan.Location
        "tags"                                 = $Plan.Tags

        "create_resource_group"                = [bool]$Plan.CreateResourceGroup
        "resource_group_name"                  = $Plan.ResourceGroupName

        "automation_account_name"              = $Plan.AutomationAccountName
        "use_existing_automation_account"      = [bool]$Plan.UseExistingAutomationAccount
        "existing_automation_account_name"     = $Plan.ExistingAutomationAccountName
        "existing_automation_account_rg"       = $Plan.ExistingAutomationAccountRg

        "use_existing_storage_account"         = [bool]$Plan.UseExistingStorageAccount
        "storage_account_name"                 = $Plan.StorageAccountName
        "existing_storage_account_name"        = $Plan.ExistingStorageAccountName
        "existing_storage_account_rg"          = $Plan.ExistingStorageAccountRg

        "use_existing_log_analytics"           = [bool]$Plan.UseExistingLogAnalytics
        "log_analytics_workspace_name"         = $Plan.LogAnalyticsWorkspaceName
        "log_analytics_workspace_resource_id"  = $Plan.LogAnalyticsWorkspaceResourceId

        "user_assigned_identity_resource_id"   = $Plan.UserAssignedIdentityResourceId

        "storage_container_name"               = $Plan.StorageContainerName
        "storage_folder_prefix"                = $Plan.StorageFolderPrefix

        "hybrid_worker_group_name"             = $Plan.HybridWorkerGroupName

        "use_avm_storage_module"               = [bool]$Plan.UseAvmStorageModule
        "storage_shared_access_key_enabled"    = [bool]$Plan.StorageSharedAccessKeyEnabled
        "storage_network_rules"                = @{
            default_action = $Plan.StorageNetworkRules.default_action
            bypass         = @($Plan.StorageNetworkRules.bypass)
        }
    }

    foreach ($key in @(
        'existing_automation_account_name', 'existing_automation_account_rg',
        'existing_storage_account_name', 'existing_storage_account_rg',
        'log_analytics_workspace_resource_id', 'user_assigned_identity_resource_id'
    )) {
        if ($null -eq $payload[$key]) { $payload[$key] = "" }
    }

    ($payload | ConvertTo-Json -Depth 8) | Set-Content -Path $PathJson -Encoding UTF8
    Write-Log "Terraform variables written to: $PathJson"
}
